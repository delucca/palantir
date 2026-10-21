import Foundation

/// A run that ended without a verdict: the layer could not tell whether palantir keeps the rule.
struct NoVerdict: Error, CustomStringConvertible {
  enum Kind: String, Codable {
    /// The driver has no Accessibility grant.
    case driver
    /// A palantir that did not launch, or did not answer.
    case launch
    /// A subprocess or the replay ran past its time limit.
    case timeout
    /// A palantir that had to be terminated because its Quit menu item did not quit it.
    case teardown
  }

  let kind: Kind
  let message: String

  var description: String { message }
}

/// The running processes, as far as the launcher needs them.
protocol Processes {
  /// The pids of every process whose executable is named palantir.
  func palantirPids() -> Set<Int32>
  /// The arguments of a running process, its executable's path first.
  func arguments(of pid: Int32) -> [String]?
  func isRunning(_ pid: Int32) -> Bool
  func terminate(_ pid: Int32)
}

/// Launches builds of palantir and quits them. It never runs sandboxed: LaunchServices drops
/// `--args` for a caller in a Seatbelt sandbox, and palantir would start without its inspector.
struct Launcher {
  let runner: any Runner
  let processes: any Processes
  /// The folder holding `palantir-drive` and `palantir-inspect`.
  let bin: URL
  let apps: [Build: URL]
  var deadline = Settings.launchDeadline
  var quitGrace = Settings.quitGrace
  var pollInterval = 0.1

  var drive: String { bin.appending(path: Settings.driverName).path }
  var inspect: String { bin.appending(path: Settings.inspectorName).path }

  func executable(of build: Build) -> URL? {
    apps[build]?.appending(path: "Contents/MacOS/palantir")
  }

  /// Fails with `NoVerdict` when the driver has no Accessibility grant: it checks before it looks
  /// for palantir, so asking about this very process tells a missing grant from a missing palantir.
  func preflight() throws {
    let output: Output
    do {
      output = try runner.run(drive, ["--pid", String(getpid()), "menus"], timeout: 15)
    } catch let timeout as TimedOut {
      throw NoVerdict(kind: .timeout, message: "\(timeout)")
    }
    if output.stderr.contains("Accessibility grant") {
      throw NoVerdict(
        kind: .driver,
        message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// Launches `build` behind the person's windows and waits until it answers; returns its pid.
  ///
  /// Readiness is `palantir-inspect wait` for a debug build launched with the inspector flag, and
  /// `palantir-drive menus` for every other launch: a release build has no inspector, flag or not.
  /// The launched process's arguments must hold every flag asked for.
  func launch(build: Build, inspector: Bool) throws -> Int32 {
    guard let app = apps[build], FileManager.default.fileExists(atPath: app.path) else {
      throw NoVerdict(kind: .launch, message: "no \(build.rawValue) palantir.app to launch")
    }
    let before = processes.palantirPids()
    let front = frontPid()
    let opened = try run(
      Settings.open, ["-g", "-n", app.path] + (inspector ? ["--args", "--inspector"] : []))
    guard opened.exit == 0 else {
      throw NoVerdict(kind: .launch, message: "open failed: \(opened.stderr)")
    }
    let end = Date().addingTimeInterval(deadline)
    var found: Int32?
    while found == nil, Date() < end {
      found = processes.palantirPids().subtracting(before).sorted().first
      if found == nil { Thread.sleep(forTimeInterval: pollInterval) }
    }
    guard let pid = found else {
      throw NoVerdict(kind: .launch, message: "no new palantir appeared after open")
    }
    do {
      try confirmFlag(pid, wanted: inspector, until: end)
      try waitUntilReady(pid, readsInspector: inspector && build == .debug, until: end)
    } catch {
      giveFrontBack(from: pid, to: front)
      _ = quit(pid)
      throw error
    }
    giveFrontBack(from: pid, to: front)
    return pid
  }

  /// Quits palantir through its Quit menu item and waits for it to exit; answers false when it had
  /// to be terminated instead.
  @discardableResult
  func quit(_ pid: Int32) -> Bool {
    guard processes.isRunning(pid) else { return true }
    _ = try? runner.run(
      drive, ["--pid", String(pid), "menu", "palantir > Quit palantir"], timeout: 20)
    let end = Date().addingTimeInterval(quitGrace)
    while processes.isRunning(pid), Date() < end { Thread.sleep(forTimeInterval: pollInterval) }
    guard processes.isRunning(pid) else { return true }
    processes.terminate(pid)
    return false
  }

  private func run(_ program: String, _ arguments: [String]) throws -> Output {
    do { return try runner.run(program, arguments) } catch let timeout as TimedOut {
      throw NoVerdict(kind: .timeout, message: "\(timeout)")
    }
  }

  private func confirmFlag(_ pid: Int32, wanted: Bool, until end: Date) throws {
    guard wanted else { return }
    var arguments = processes.arguments(of: pid)
    while arguments == nil, Date() < end {
      Thread.sleep(forTimeInterval: pollInterval)
      arguments = processes.arguments(of: pid)
    }
    guard let arguments, arguments.contains("--inspector") else {
      throw NoVerdict(
        kind: .launch,
        message: "palantir \(pid) started without --inspector; the launch dropped the flag")
    }
  }

  private func waitUntilReady(_ pid: Int32, readsInspector: Bool, until end: Date) throws {
    repeat {
      let (program, arguments) =
        readsInspector
        ? (inspect, ["--pid", String(pid), "wait", "--timeout", "3"])
        : (drive, ["--pid", String(pid), "menus"])
      let probe = try? runner.run(program, arguments, timeout: Settings.probeTimeout)
      if probe?.exit == 0 { return }
      Thread.sleep(forTimeInterval: pollInterval)
    } while Date() < end
    throw NoVerdict(
      kind: .launch,
      message: "palantir \(pid) did not answer within \(Int(deadline)) s of its launch")
  }

  private func frontPid() -> Int32? {
    guard
      let front = try? runner.run(Settings.lsappinfo, ["front"], timeout: 10).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines), !front.isEmpty,
      let info = try? runner.run(Settings.lsappinfo, ["info", "-only", "pid", front], timeout: 10)
        .stdout,
      let match = info.firstMatch(of: /pid"?\s*=\s*(\d+)/)
    else { return nil }
    return Int32(match.1)
  }

  /// Gives the front back when the launch took it; a launch behind the person's windows still can.
  private func giveFrontBack(from pid: Int32, to front: Int32?) {
    guard let front, front != pid, frontPid() == pid else { return }
    _ = try? runner.run(
      drive, ["--pid", String(pid), "restore", "--to", String(front)], timeout: 15)
  }
}

/// The processes of this Mac, through libproc.
struct SystemProcesses: Processes {
  func palantirPids() -> Set<Int32> {
    var pids = [Int32](repeating: 0, count: 8192)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    var found: Set<Int32> = []
    var buffer = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
      guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
      if String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        .hasSuffix("/palantir")
      {
        found.insert(pid)
      }
    }
    return found
  }

  func arguments(of pid: Int32) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return ProcessArguments.parse(Data(buffer.prefix(size)))
  }

  func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

  func terminate(_ pid: Int32) { kill(pid, SIGTERM) }
}

enum ProcessArguments {
  /// The arguments in a `KERN_PROCARGS2` buffer: an `int` argc, the executable's path, its padding
  /// of NULs, then argc NUL-ended strings. The path comes first in the answer.
  static func parse(_ data: Data) -> [String]? {
    guard data.count > MemoryLayout<Int32>.size else { return nil }
    let argc = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    let fields = Array(data.dropFirst(4).split(separator: 0, omittingEmptySubsequences: false))
    guard let path = fields.first else { return nil }
    // Skip the padding between the path and argv[0].
    let rest = fields.dropFirst().drop { $0.isEmpty }
    let arguments = rest.prefix(Int(max(argc, 0))).map { String(decoding: $0, as: UTF8.self) }
    return [String(decoding: path, as: UTF8.self)] + arguments
  }
}
