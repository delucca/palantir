import Foundation

@testable import PalantirAcceptance

/// A stand-in for the machine: palantir-drive, palantir-inspect, open and the process table, with
/// the real jq and nm. Every program started is recorded.
final class FakeWorld: Runner, Processes, @unchecked Sendable {
  struct Call: Equatable {
    var program: String
    var arguments: [String]
  }

  let bin = URL(fileURLWithPath: "/fake/bin")
  let root: URL
  private let real = SystemRunner()
  private let lock = NSLock()
  private var recorded: [Call] = []
  private var pids: Set<Int32> = []
  private var arguments: [Int32: [String]] = [:]
  private var nextPid: Int32 = 4242

  /// Answers a `palantir-drive` call, without `--pid <pid>`.
  var drive: ([String]) -> Output = { _ in Output(exit: 0, stdout: "", stderr: "") }
  /// Answers a `palantir-inspect` call, without `--pid <pid>`.
  var inspect: ([String]) -> Output = { _ in Output(exit: 0, stdout: "{}", stderr: "") }
  /// Whether `open` drops the arguments, as a sandboxed caller does.
  var dropsArguments = false
  /// Whether a palantir ignores its Quit menu item.
  var ignoresQuit = false

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "fake-world-\(UUID().uuidString)")
    for build in ["debug", "release"] {
      let executable = root.appending(path: "\(build).app/Contents/MacOS")
      try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
      try Data("\(build)".utf8).write(to: executable.appending(path: "palantir"))
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var calls: [Call] { lock.withLock { recorded } }

  /// The calls to one program, such as `palantir-inspect`.
  func calls(to name: String) -> [[String]] {
    calls.filter { $0.program.hasSuffix("/\(name)") }.map(\.arguments)
  }

  var launcher: Launcher {
    Launcher(
      runner: self, processes: self, bin: bin,
      apps: [
        .debug: root.appending(path: "debug.app"), .release: root.appending(path: "release.app"),
      ],
      deadline: 1, quitGrace: 0.3, pollInterval: 0.01)
  }

  func replayer(deadline: Double = 30) -> Replayer {
    Replayer(
      launcher: launcher, runner: self,
      programs: { Array(Set(self.calls.map(\.program))).sorted() }, deadline: deadline)
  }

  func run(_ program: String, _ arguments: [String], stdin: Data?, timeout: Double) throws -> Output
  {
    lock.withLock { recorded.append(Call(program: program, arguments: arguments)) }
    switch program {
    case Settings.jq, Settings.nm:
      return try real.run(program, arguments, stdin: stdin, timeout: timeout)
    case Settings.open:
      return opened(arguments)
    case Settings.lsappinfo:
      return Output(exit: 0, stdout: "", stderr: "")
    case bin.appending(path: Settings.driverName).path:
      return driven(arguments)
    case bin.appending(path: Settings.inspectorName).path:
      return inspect(
        Array(arguments.drop { $0 == "--pid" }.dropFirst(arguments.first == "--pid" ? 1 : 0)))
    default:
      preconditionFailure("the runner started \(program)")
    }
  }

  private func opened(_ arguments: [String]) -> Output {
    lock.withLock {
      let pid = nextPid
      nextPid += 1
      pids.insert(pid)
      let flags = Array(arguments.drop { $0 != "--args" }.dropFirst())
      self.arguments[pid] = ["/fake/palantir"] + (dropsArguments ? [] : flags)
    }
    return Output(exit: 0, stdout: "", stderr: "")
  }

  private func driven(_ arguments: [String]) -> Output {
    var rest = arguments
    var pid: Int32?
    if rest.first == "--pid" {
      pid = Int32(rest[1])
      rest = Array(rest.dropFirst(2))
    }
    if rest.first == "menu", rest.last == "palantir > Quit palantir", let pid {
      if !ignoresQuit { lock.withLock { _ = pids.remove(pid) } }
      return Output(exit: 0, stdout: "", stderr: "")
    }
    return drive(rest)
  }

  func palantirPids() -> Set<Int32> { lock.withLock { pids } }
  func arguments(of pid: Int32) -> [String]? { lock.withLock { arguments[pid] } }
  func isRunning(_ pid: Int32) -> Bool { lock.withLock { pids.contains(pid) } }
  func terminate(_ pid: Int32) { lock.withLock { _ = pids.remove(pid) } }
}
