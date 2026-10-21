import Foundation

/// A failure to run something in the isolated machine.
struct MachineError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

/// Where Tart and its VMs are.
struct VMConfig {
  var tart: String
  /// `TART_HOME`: where Tart keeps its images and VMs.
  var tartHome: URL
  var prepared = Settings.preparedVM
  var guestRoot = Settings.guestRoot
  var bootTimeout = Settings.vmBootTimeout
  var diskFloor = Settings.diskFloor
  var availableBytes: () -> Int64 = { Disk.availableBytes() }

  /// Tart as the environment names it: `PALANTIR_ACCEPT_TART` and `TART_HOME`, else `tart` on PATH
  /// and Tart's own home.
  static func resolve() throws -> VMConfig {
    let environment = ProcessInfo.processInfo.environment
    var tart = environment["PALANTIR_ACCEPT_TART"]
    if tart == nil {
      tart = (environment["PATH"] ?? "").split(separator: ":")
        .map { "\($0)/tart" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    guard let tart else {
      throw MachineError("Tart is not installed: set PALANTIR_ACCEPT_TART to its executable")
    }
    let home =
      environment["TART_HOME"] ?? "\(NSHomeDirectory())/.tart"
    return VMConfig(tart: tart, tartHome: URL(fileURLWithPath: home))
  }
}

/// One run clone of the prepared VM: cloned, booted headless, used over `tart exec`, then stopped
/// and deleted on every exit.
final class VMSession {
  let config: VMConfig
  let executor: any Executor
  let name: String
  /// Where the session keeps its staging files and the tar streams it moves.
  let scratch: URL
  private var process: Process?
  private var cloned = false

  init(config: VMConfig, executor: any Executor, scratch: URL, name: String? = nil) {
    self.config = config
    self.executor = executor
    self.scratch = scratch
    self.name = name ?? "palantir-acceptance-run-\(Int(Date().timeIntervalSince1970))-\(getpid())"
  }

  private var environment: [String: String] {
    ["TART_HOME": config.tartHome.path, "TART_NO_AUTO_PRUNE": "1"]
  }

  /// Runs `tart <arguments>` with `stdin` as its input and returns what it printed.
  @discardableResult
  func tart(
    _ arguments: [String], stdin: URL = URL(fileURLWithPath: "/dev/null"), timeout: Double = 120
  ) throws -> Output {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let out = scratch.appending(path: "\(id).out")
    let err = scratch.appending(path: "\(id).err")
    defer {
      try? FileManager.default.removeItem(at: out)
      try? FileManager.default.removeItem(at: err)
    }
    let exit = try executor.execute(
      Command(executable: config.tart, arguments: arguments, environment: environment),
      prompt: stdin, stdout: out, stderr: err, directory: scratch, timeout: timeout)
    return Output(
      exit: exit, stdout: (try? String(contentsOf: out, encoding: .utf8)) ?? "",
      stderr: (try? String(contentsOf: err, encoding: .utf8)) ?? "")
  }

  /// Clones the prepared VM, boots the clone headless and waits until `tart exec` answers.
  ///
  /// - Throws: `MachineError` when the disk is under the floor, the prepared VM is missing, or the
  ///   clone does not come up; the clone is gone by then.
  func start() throws {
    guard config.availableBytes() >= config.diskFloor else {
      throw MachineError(
        "the disk has less than \(config.diskFloor >> 30) GiB free; no VM clone starts")
    }
    let listed = try tart(["list", "--quiet"])
    guard
      listed.stdout.split(separator: "\n").contains(where: {
        $0.trimmingCharacters(in: .whitespaces) == config.prepared
      })
    else {
      throw MachineError(
        "the prepared VM \(config.prepared) does not exist; see the machine decision")
    }
    let cloning = try tart(["clone", config.prepared, name])
    guard cloning.exit == 0 else { throw MachineError("tart clone failed: \(cloning.stderr)") }
    cloned = true
    do {
      try boot()
      try waitUntilReady()
    } catch {
      shutdown()
      throw error
    }
  }

  private func boot() throws {
    let run = Process()
    run.executableURL = URL(fileURLWithPath: config.tart)
    run.arguments = ["run", "--no-graphics", "--no-audio", "--no-clipboard", name]
    run.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    run.standardInput = FileHandle.nullDevice
    run.standardOutput = FileHandle.nullDevice
    run.standardError = FileHandle.nullDevice
    try run.run()
    process = run
  }

  private func waitUntilReady() throws {
    let end = Date().addingTimeInterval(config.bootTimeout)
    while Date() < end {
      if process?.isRunning == false { throw MachineError("the VM \(name) stopped while booting") }
      if let probe = try? tart(["exec", name, "/usr/bin/true"], timeout: 15), probe.exit == 0 {
        return
      }
      Thread.sleep(forTimeInterval: 1)
    }
    throw MachineError(
      "the VM \(name) did not answer tart exec within \(Int(config.bootTimeout)) s")
  }

  /// Runs a program in the guest.
  @discardableResult
  func exec(_ arguments: [String], timeout: Double = 120) throws -> Output {
    try tart(["exec", name] + arguments, timeout: timeout)
  }

  /// Unpacks the tar file at `archive` into the guest folder `directory`.
  func put(archive: URL, into directory: String) throws {
    let made = try exec(["/bin/mkdir", "-p", directory])
    guard made.exit == 0 else { throw MachineError("mkdir \(directory) failed: \(made.stderr)") }
    let result = try tart(
      ["exec", "-i", name, "/usr/bin/tar", "-C", directory, "-xf", "-"], stdin: archive,
      timeout: 300)
    guard result.exit == 0 else {
      throw MachineError("copying into the guest failed: \(result.stderr)")
    }
  }

  /// Fetches the guest folder `directory` into `destination` as a tar stream.
  func fetch(_ directory: String, into destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let archive = scratch.appending(path: "\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: archive) }
    let exit = try executor.execute(
      Command(
        executable: config.tart,
        arguments: ["exec", name, "/usr/bin/tar", "-C", directory, "-cf", "-", "."],
        environment: environment),
      prompt: URL(fileURLWithPath: "/dev/null"), stdout: archive,
      stderr: scratch.appending(path: "fetch.err"), directory: scratch, timeout: 300)
    guard exit == 0 else {
      throw MachineError("fetching \(directory) from the guest failed (exit \(exit))")
    }
    let unpacked = try SystemRunner().run(
      "/usr/bin/tar", ["-C", destination.path, "-xf", archive.path])
    guard unpacked.exit == 0 else {
      throw MachineError("unpacking the fetched files failed: \(unpacked.stderr)")
    }
  }

  /// Stops and deletes the clone, and ends `tart run`. Safe to call twice.
  func shutdown() {
    if cloned {
      _ = try? tart(["stop", name], timeout: 60)
      _ = try? tart(["delete", name], timeout: 120)
      cloned = false
    }
    if let process, process.isRunning {
      process.terminate()
      let end = Date().addingTimeInterval(10)
      while process.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.1) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process = nil
  }

  deinit { shutdown() }

  // MARK: Preflight

  /// What the guest looks like: its macOS, a session that is not locked, jq present, and a
  /// Finder window in front so that every input borrows the front and gives it back.
  func preflight() throws -> Machine {
    let version = try exec(["/usr/bin/sw_vers", "-productVersion"]).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let build = try exec(["/usr/bin/sw_vers", "-buildVersion"]).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let session = try exec(["/usr/sbin/ioreg", "-n", "Root", "-d1"]).stdout
    if session.contains("\"CGSSessionScreenIsLocked\"=Yes") {
      throw MachineError("the guest's screen is locked; nothing can be driven")
    }
    guard try exec(["/usr/bin/jq", "--version"]).exit == 0 else {
      throw MachineError("the guest has no /usr/bin/jq")
    }
    _ = try exec(["/usr/bin/open", "-a", "Finder", config.guestRoot])
    Thread.sleep(forTimeInterval: 2)
    return Machine(host: name, macos: "Version \(version) (Build \(build))")
  }
}

/// Builds the files a guest needs and the tar archive that carries them.
struct GuestStage {
  let scratch: URL
  /// The host's build under test and the CLIs, the runner, the checks and the spec.
  func build(
    debugApp: URL, releaseApp: URL?, bin: URL, checks: URL?, spec: URL?, into stage: URL
  ) throws -> URL {
    let manager = FileManager.default
    try? manager.removeItem(at: stage)
    for folder in ["bin", "release", "out"] {
      try manager.createDirectory(
        at: stage.appending(path: folder), withIntermediateDirectories: true)
    }
    for name in [Settings.driverName, Settings.inspectorName, "palantir-accept"] {
      try manager.copyItem(at: bin.appending(path: name), to: stage.appending(path: "bin/\(name)"))
    }
    try manager.copyItem(at: debugApp, to: stage.appending(path: "palantir.app"))
    if let releaseApp, manager.fileExists(atPath: releaseApp.path) {
      try manager.copyItem(at: releaseApp, to: stage.appending(path: "release/palantir.app"))
    }
    if let checks { try manager.copyItem(at: checks, to: stage.appending(path: "checks")) }
    if let spec {
      try manager.createDirectory(
        at: stage.appending(path: "spec"), withIntermediateDirectories: true)
      try manager.copyItem(at: spec, to: stage.appending(path: "spec/features"))
    }
    let archive = stage.appendingPathExtension("tar")
    try? manager.removeItem(at: archive)
    let packed = try SystemRunner().run(
      "/usr/bin/tar", ["-C", stage.path, "-cf", archive.path, "."])
    guard packed.exit == 0 else { throw MachineError("tar failed: \(packed.stderr)") }
    return archive
  }
}

/// `vm-replay`: every rule's check replayed in a run clone, with the verdicts brought back.
enum VMReplay {
  struct Result {
    var exit: Int32
    var output: String
    var verdicts: VerdictsFile?
  }

  /// Replays every check in `session`'s guest and fetches `verdicts.json` and the replay folders
  /// into `destination`.
  static func run(
    session: VMSession, stage: URL, destination: URL, host: Machine = .current
  ) throws -> Result {
    let root = session.config.guestRoot
    try session.put(archive: stage, into: root)
    let guest = try session.preflight()
    let command = [
      "\(root)/bin/palantir-accept", "replay", "--all", "--spec", "\(root)/spec/features",
      "--checks", "\(root)/checks", "--app", "\(root)/palantir.app", "--release-app",
      "\(root)/release/palantir.app", "--bin", "\(root)/bin", "--json", "\(root)/out/verdicts.json",
      "--record", "\(root)/out/replays",
    ]
    let replayed = try session.exec(command, timeout: Settings.vmRunTimeout)
    try session.fetch("\(root)/out", into: destination)
    try Data(replayed.stdout.utf8).write(to: destination.appending(path: "stdout.txt"))
    var verdicts: VerdictsFile?
    if let data = try? Data(contentsOf: destination.appending(path: "verdicts.json")),
      var decoded = try? JSONDecoder().decode(VerdictsFile.self, from: data)
    {
      decoded.host = host
      decoded.machine = Machine(host: guest.host, macos: guest.macos)
      verdicts = decoded
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(decoded).write(to: destination.appending(path: "verdicts.json"))
    }
    return Result(exit: replayed.exit, output: replayed.stdout, verdicts: verdicts)
  }
}

/// `compare`: whether two machines gave the same verdict to every rule of the same build.
enum Compare {
  /// The lines that say how the two files differ; none means they agree.
  static func differences(host: VerdictsFile, vm: VerdictsFile) -> [String] {
    var lines: [String] = []
    if host.build.debugAppSha256 != vm.build.debugAppSha256 {
      lines.append(
        "the debug build differs: host \(host.build.debugAppSha256 ?? "-"), vm \(vm.build.debugAppSha256 ?? "-")"
      )
    }
    if host.build.releaseAppSha256 != vm.build.releaseAppSha256 {
      lines.append(
        "the release build differs: host \(host.build.releaseAppSha256 ?? "-"), vm \(vm.build.releaseAppSha256 ?? "-")"
      )
    }
    for id in Set(host.verdicts.keys).union(vm.verdicts.keys).sorted() {
      let a = host.verdicts[id] ?? "absent"
      let b = vm.verdicts[id] ?? "absent"
      if a != b { lines.append("\(id)\thost \(a)\tvm \(b)") }
    }
    return lines
  }
}

/// Replays one check at a time in a run clone that stays booted between replays, for generation.
/// A host lockfile is held around each replay, so lanes never mix their input.
final class VMReplayService: ReplayService, @unchecked Sendable {
  let config: VMConfig
  let executor: any Executor
  let cache: URL
  let bin: URL
  let debugApp: URL
  let releaseApp: URL
  private var session: VMSession?
  private var count = 0

  init(
    config: VMConfig, executor: any Executor = SystemExecutor(), cache: URL, bin: URL,
    debugApp: URL, releaseApp: URL
  ) {
    self.config = config
    self.executor = executor
    self.cache = cache
    self.bin = bin
    self.debugApp = debugApp
    self.releaseApp = releaseApp
  }

  func replay(check: URL, app: URL?, into directory: URL) throws -> ReplayReport {
    let lock = try FileLock(cache.appending(path: "vm-replay.lock"))
    defer { lock.release() }
    let session = try startedSession()
    count += 1
    let root = config.guestRoot
    let work = "\(root)/work/\(count)"
    let stage = session.scratch.appending(path: "replay-\(count)")
    let manager = FileManager.default
    try? manager.removeItem(at: stage)
    try manager.createDirectory(at: stage, withIntermediateDirectories: true)
    try manager.copyItem(at: check, to: stage.appending(path: "check.json"))
    if let app {
      try manager.copyItem(at: app, to: stage.appending(path: "palantir.app"))
      try manager.copyItem(
        at: Mutant.releaseBundle(for: app), to: stage.appending(path: "palantir-release.app"))
    }
    let archive = stage.appendingPathExtension("tar")
    let packed = try SystemRunner().run(
      "/usr/bin/tar", ["-C", stage.path, "-cf", archive.path, "."])
    guard packed.exit == 0 else { throw MachineError("tar failed: \(packed.stderr)") }
    try session.put(archive: archive, into: work)
    let command = [
      "\(root)/bin/palantir-accept", "replay", "\(work)/check.json", "--record", "\(work)/rec",
      "--app", app == nil ? "\(root)/palantir.app" : "\(work)/palantir.app", "--release-app",
      app == nil ? "\(root)/release/palantir.app" : "\(work)/palantir-release.app", "--bin",
      "\(root)/bin",
    ]
    _ = try session.exec(command, timeout: Settings.replayDeadline + 120)
    try session.fetch("\(work)/rec", into: directory)
    guard let data = try? Data(contentsOf: directory.appending(path: "replay.json")) else {
      throw MachineError("the replay in the guest left no replay.json")
    }
    return try JSONDecoder().decode(ReplayReport.self, from: data)
  }

  private func startedSession() throws -> VMSession {
    if let session { return session }
    let scratch = cache.appending(path: "vm-generate-\(Int(Date().timeIntervalSince1970))")
    let session = VMSession(config: config, executor: executor, scratch: scratch)
    try session.start()
    let stage = try GuestStage(scratch: scratch).build(
      debugApp: debugApp, releaseApp: releaseApp, bin: bin, checks: nil, spec: nil,
      into: scratch.appending(path: "stage"))
    try session.put(archive: stage, into: config.guestRoot)
    _ = try session.preflight()
    self.session = session
    return session
  }

  /// Stops and deletes the run clone.
  func finish() {
    session?.shutdown()
    session = nil
  }
}

enum Termination {
  /// Runs `body` when this process is asked to end by SIGTERM or SIGINT, then exits 143, so a
  /// run clone is deleted even when a time limit kills the command.
  nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

  static func handle(_ body: @escaping @Sendable () -> Void) {
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        body()
        exit(143)
      }
      source.resume()
      sources.append(source)
    }
  }
}
