import Foundation

/// How a replay ended.
enum Verdict: String, Codable, Equatable {
  case pass, fail, error
}

/// Why a replay did not pass.
struct Failure: Codable, Equatable {
  /// The index in `steps` of the step that failed, and its phase; absent for an error.
  var step: Int?
  var phase: Phase?
  /// `action` or `expect` for a fail; `driver`, `launch`, `timeout`, `teardown` or `replay` for an error.
  var kind: String
  /// The text of a failed action or of an error.
  var message: String?
  /// For `expect`: the expression and what jq printed. A jq failure prints `error: <message>`.
  var that: String?
  var value: String?
}

/// What one action did.
struct ActionReport: Codable, Equatable {
  var action: String
  var arguments: [String]
  var exit: Int32?
  var stderr: String?
  var seconds: Double
  /// The name the action's observation took in the record.
  var name: String? = nil
}

struct ExpectationReport: Codable, Equatable {
  var that: String
  var value: String
}

struct StepReport: Codable, Equatable {
  var line: String
  var phase: Phase
  var actions: [ActionReport]
  var expect: [ExpectationReport]
}

/// The machine a replay ran on.
struct Machine: Codable, Equatable {
  var host: String
  var macos: String

  static var current: Machine {
    Machine(
      host: ProcessInfo.processInfo.hostName,
      macos: ProcessInfo.processInfo.operatingSystemVersionString)
  }
}

/// `replay.json`: what a replay did and decided. The record, `record.json`, sits beside it.
struct ReplayReport: Codable, Equatable {
  var rule: String
  var verdict: Verdict
  var failure: Failure?
  var steps: [StepReport]
  var check: String
  var checkSha256: String
  var app: String?
  var appSha256: String?
  var releaseApp: String?
  var releaseAppSha256: String?
  var cliSha256: [String: String]
  var jq: String
  var machine: Machine
  var seconds: Double
  /// Always 0: a replay calls no model.
  var modelCalls: Int
  /// The programs the replay started, by absolute path.
  var subprocesses: [String]
}

/// A step's action that ended other than the check expects: the replay fails.
private struct ActionFailure: Error {
  let message: String
}

/// Replays a check: launches palantir, runs each step's actions through the two CLIs, and decides
/// pass or fail from what they return and from jq. It calls no model.
final class Replayer {
  let launcher: Launcher
  let runner: any Runner
  let jq: SystemJQ
  let deadline: Double
  /// The programs the runner started, when it is a `SystemRunner`.
  let programs: () -> [String]

  init(
    launcher: Launcher, runner: any Runner, programs: @escaping () -> [String],
    deadline: Double = Settings.replayDeadline
  ) {
    self.launcher = launcher
    self.runner = runner
    self.jq = SystemJQ(runner: runner)
    self.programs = programs
    self.deadline = deadline
  }

  /// Replays `check`, writing `replay.json`, `record.json`, the fixtures and any screenshots into
  /// `directory`, and returns the report.
  func replay(_ check: Check, data: Data, path: String, into directory: URL) throws
    -> ReplayReport
  {
    for name in check.files.keys {
      guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), !name.contains("\0") else {
        throw CheckError("unsafe fixture name: \(name)")
      }
    }
    let started = Date()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let filesDirectory = directory.appending(path: "files")
    try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    var paths: [String: String] = [:]
    for (name, text) in check.files {
      let url = filesDirectory.appending(path: name)
      try Data(text.utf8).write(to: url)
      paths[name] = url.path
    }
    var run = Run(
      record: Record(files: paths, uid: Int(getuid())), directory: directory, started: started)
    var report = ReplayReport(
      rule: check.rule, verdict: .pass, failure: nil, steps: [], check: path,
      checkSha256: Digest.sha256(data), app: launcher.apps[.debug]?.path,
      appSha256: sha256(of: launcher.executable(of: .debug)),
      releaseApp: launcher.apps[.release]?.path,
      releaseAppSha256: sha256(of: launcher.executable(of: .release)), cliSha256: cliHashes(),
      jq: (try? jq.version()) ?? "", machine: .current, seconds: 0, modelCalls: 0, subprocesses: [])
    do {
      try launcher.preflight()
      let phases = try Phase.sequence(of: check.steps.map(\.line), for: check.rule)
      for (index, step) in check.steps.enumerated() {
        var result = StepReport(line: step.line, phase: phases[index], actions: [], expect: [])
        report.steps.append(result)
        do {
          for action in step.actions { try perform(action, in: &run, log: &result.actions) }
        } catch let failure as ActionFailure {
          report.steps[index] = result
          report.verdict = .fail
          report.failure = Failure(
            step: index, phase: phases[index], kind: "action", message: failure.message)
          break
        } catch let failure as ArgumentError {
          report.steps[index] = result
          report.verdict = .fail
          report.failure = Failure(
            step: index, phase: phases[index], kind: "action", message: failure.description)
          break
        } catch {
          report.steps[index] = result
          throw error
        }
        var failed = false
        for expectation in step.expect {
          let value = try evaluate(expectation.that, run)
          result.expect.append(ExpectationReport(that: expectation.that, value: value))
          if value != "true" {
            report.verdict = .fail
            report.failure = Failure(
              step: index, phase: phases[index], kind: "expect", that: expectation.that,
              value: value)
            failed = true
            break
          }
        }
        report.steps[index] = result
        if failed { break }
      }
    } catch let error as NoVerdict {
      report.verdict = .error
      report.failure = Failure(kind: error.kind.rawValue, message: error.message)
    } catch let error as TimedOut {
      report.verdict = .error
      report.failure = Failure(kind: NoVerdict.Kind.timeout.rawValue, message: "\(error)")
    } catch let error as SpecError {
      report.verdict = .error
      report.failure = Failure(kind: NoVerdict.Kind.launch.rawValue, message: "\(error)")
    } catch {
      report.verdict = .error
      report.failure = Failure(kind: "replay", message: "\(error)")
    }
    let stuck = run.launched.filter { !launcher.quit($0) }
    if !stuck.isEmpty {
      report.verdict = .error
      report.failure = Failure(
        kind: NoVerdict.Kind.teardown.rawValue,
        message:
          "palantir \(stuck.map(String.init).joined(separator: ", ")) did not quit by its Quit menu item; it was terminated"
      )
    }
    report.seconds = Date().timeIntervalSince(started)
    report.subprocesses = programs()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: directory.appending(path: "replay.json"))
    try run.record.json(pretty: true).write(to: directory.appending(path: "record.json"))
    return report
  }

  /// The state of one replay.
  private struct Run {
    var record: Record
    let directory: URL
    let started: Date
    /// The palantir that `drive` and `inspect` reach.
    var current: Int32?
    var launched: [Int32] = []
  }

  private func evaluate(_ expression: String, _ run: Run) throws -> String {
    do { return try jq.evaluate(expression, over: run.record) } catch let timeout as TimedOut {
      throw NoVerdict(kind: .timeout, message: "\(timeout)")
    }
  }

  private func perform(_ action: Action, in run: inout Run, log: inout [ActionReport]) throws {
    if Date().timeIntervalSince(run.started) > deadline {
      throw NoVerdict(kind: .timeout, message: "the replay ran over \(Int(deadline)) s")
    }
    let began = Date()
    var entry = ActionReport(
      action: "", arguments: [], exit: nil, stderr: nil, seconds: 0, name: action.name)
    var observation: [String: Any] = [:]
    var output: Output?
    func finish() {
      entry.seconds = Date().timeIntervalSince(began)
      if let output {
        entry.exit = output.exit
        entry.stderr = output.stderr
      }
    }
    do {
      defer {
        finish()
        if entry.action != "repeat" { log.append(entry) }
      }
      switch action.verb {
      case .launch(let build, let inspector):
        entry.action = "launch"
        entry.arguments = [build.rawValue, inspector ? "--inspector" : "no flag"]
        let pid = try launcher.launch(build: build, inspector: inspector)
        run.current = pid
        run.launched.append(pid)
        run.record["pid"] = Int(pid)
        observation = ["pid": Int(pid)]
      case .drive(let arguments):
        guard let pid = run.current else { throw ActionFailure(message: "drive before any launch") }
        let resolved = try arguments.map { try resolve($0, in: &run) }
        entry.action = "drive"
        entry.arguments = resolved
        let result = try call(launcher.drive, ["--pid", String(pid)] + resolved)
        output = result
        observation = ["exit": Int(result.exit), "stdout": result.stdout, "stderr": result.stderr]
        if resolved.first == "menus" { observation["items"] = Outputs.menus(result.stdout) }
        if resolved.first == "tree" { observation["elements"] = Outputs.tree(result.stdout) }
      case .inspect(let arguments):
        let resolved = try arguments.map { try resolve($0, in: &run) }
        entry.action = "inspect"
        entry.arguments = resolved
        let isList = resolved.first == "list"
        guard isList || run.current != nil else {
          throw ActionFailure(message: "inspect before any launch")
        }
        let pidArguments = isList ? [] : ["--pid", String(run.current!)]
        let result = try call(launcher.inspect, pidArguments + resolved)
        output = result
        observation = ["exit": Int(result.exit), "stdout": result.stdout, "stderr": result.stderr]
        if isList {
          observation["sockets"] = Outputs.sockets(result.stdout)
        } else if let json = try? JSONSerialization.jsonObject(
          with: Data(result.stdout.utf8), options: .fragmentsAllowed)
        {
          observation["json"] = json
        }
      case .file(let name):
        entry.action = "file"
        entry.arguments = [name]
        guard let path = run.record.files[name] else {
          throw ActionFailure(message: "no fixture \(name)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        observation = [
          "sha256": Digest.sha256(data), "size": data.count,
          "mtime": (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
        ]
      case .stat(let argument):
        let path = try resolve(argument, in: &run)
        entry.action = "stat"
        entry.arguments = [path]
        var info = stat()
        if lstat(path, &info) == 0 {
          observation = [
            "exists": true, "mode": String(info.st_mode & 0o7777, radix: 8),
            "uid": Int(info.st_uid),
            "isDirectory": info.st_mode & S_IFMT == S_IFDIR,
          ]
        } else {
          observation = ["exists": false]
        }
      case .symbols(let build):
        entry.action = "symbols"
        guard let executable = launcher.executable(of: build)?.path else {
          throw ActionFailure(message: "no \(build.rawValue) palantir.app to read")
        }
        entry.arguments = [executable]
        let defined = try call(Settings.nm, ["-g", "-j", "-U", executable])
        let undefined = try call(Settings.nm, ["-u", executable])
        guard defined.exit == 0, undefined.exit == 0 else {
          throw ActionFailure(message: "nm failed on \(executable)")
        }
        observation = [
          "defined": defined.stdout.split(separator: "\n").map(String.init),
          "undefined": undefined.stdout.split(separator: "\n").map(String.init),
        ]
      case .sleep(let seconds):
        entry.action = "sleep"
        entry.arguments = [String(seconds)]
        Thread.sleep(forTimeInterval: seconds)
      case .quit:
        entry.action = "quit"
        guard let pid = run.current else { throw ActionFailure(message: "quit before any launch") }
        entry.arguments = [String(pid)]
        guard launcher.quit(pid) else {
          run.launched.removeAll { $0 == pid }
          throw NoVerdict(
            kind: .teardown,
            message: "palantir \(pid) did not quit by its Quit menu item; it was terminated")
        }
        run.launched.removeAll { $0 == pid }
        run.current = nil
      case .repeat(let body, let until, let max):
        entry.action = "repeat"
        entry.arguments = [until]
        for round in 1...max {
          for inner in body { try perform(inner, in: &run, log: &log) }
          if try evaluate(until, run) == "true" {
            entry.arguments.append("rounds: \(round)")
            log.append(entry)
            return
          }
        }
        entry.arguments.append("rounds: \(max)")
        log.append(entry)
        throw ActionFailure(message: "\(until) was still not true after \(max) rounds")
      }
    }
    if let name = action.name, !observation.isEmpty { run.record[name] = observation }
    if let output, action.exit != .any, action.exit != .code(output.exit) {
      throw ActionFailure(
        message:
          "\(entry.action) \(entry.arguments.joined(separator: " ")) exited \(output.exit), the check expects \(action.exit)"
      )
    }
  }

  private func call(_ program: String, _ arguments: [String]) throws -> Output {
    do { return try runner.run(program, arguments) } catch let timeout as TimedOut {
      throw NoVerdict(kind: .timeout, message: "\(timeout)")
    }
  }

  private func resolve(_ argument: Argument, in run: inout Run) throws -> String {
    switch argument {
    case .text(let text): return text
    case .number(let number):
      return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    case .file(let name):
      guard let path = run.record.files[name] else { throw ArgumentError("no fixture \(name)") }
      return path
    case .out(let name):
      guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), !name.contains("\0") else {
        throw ArgumentError("unsafe out name: \(name)")
      }
      let folder = run.directory.appending(path: "out")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let path = folder.appending(path: name).path
      run.record.addOut(name, path: path)
      return path
    case .jq(let expression):
      do { return try jq.line(expression, over: run.record) } catch let timeout as TimedOut {
        throw NoVerdict(kind: .timeout, message: "\(timeout)")
      }
    }
  }

  private func sha256(of url: URL?) -> String? {
    url.flatMap { try? Data(contentsOf: $0) }.map(Digest.sha256)
  }

  private func cliHashes() -> [String: String] {
    var hashes: [String: String] = [:]
    for name in [Settings.driverName, Settings.inspectorName] {
      if let hash = sha256(of: launcher.bin.appending(path: name)) { hashes[name] = hash }
    }
    return hashes
  }
}
