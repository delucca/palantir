import Foundation

/// What a model run is for.
enum ModelRole: CaseIterable {
  /// Claude writes or revises a check from one rule.
  case generator
  /// Claude writes probe checks around a feature's rules and reads their records.
  case explorer
  /// Codex reads a check against its rule.
  case judge
  /// Codex changes palantir's source to break a rule.
  case mutant
  /// Codex reads a failed replay and blames palantir or the check.
  case triage

  var usesClaude: Bool { self == .generator || self == .explorer }
}

/// A program to start with its environment, as the model runs build them.
struct Command: Equatable {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
}

/// The paths and tools the model runs need, found on this machine.
struct ModelConfig {
  var home: URL
  /// `/usr/bin/sandbox-exec`; a test points it at a fake.
  var sandboxExec = "/usr/bin/sandbox-exec"
  /// Claude's resolved executable: the profile allows running exactly this file.
  var claude: String
  var codex: String
  /// A home for Codex holding only a link to the user's credentials and a two-line config.
  var codexHome: URL
  var generatorProfile: URL
  var codexProfile: URL
  /// The tools' versions, by name, for `generation.json`.
  var versions: [String: String] = [:]

  /// The tools of this machine. Creates `codexHome` under `cache` when it is missing.
  static func resolve(cache: URL) throws -> ModelConfig {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let link = home.appending(path: ".local/bin/claude").resolvingSymlinksInPath()
    guard FileManager.default.isExecutableFile(atPath: link.path) else {
      throw ModelRunError("claude is not installed at ~/.local/bin/claude")
    }
    let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    guard
      let codex = search.map({ URL(fileURLWithPath: String($0)).appending(path: "codex") })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    else { throw ModelRunError("codex is not on PATH") }
    let codexHome = cache.appending(path: "codex-home")
    try prepare(codexHome: codexHome, home: home)
    var config = ModelConfig(
      home: home, claude: link.path, codex: codex.resolvingSymlinksInPath().path,
      codexHome: codexHome, generatorProfile: try Resources.url("generator.sb"),
      codexProfile: try Resources.url("codex.sb"))
    let runner = SystemRunner()
    for (name, path) in [("claude", config.claude), ("codex", config.codex)] {
      let text = (try? runner.run(path, ["--version"], timeout: 30).stdout) ?? ""
      let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
      config.versions[name] = version.hasPrefix(name) ? version : "\(name) \(version)"
    }
    return config
  }

  static func prepare(codexHome: URL, home: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let auth = codexHome.appending(path: "auth.json")
    if (try? manager.destinationOfSymbolicLink(atPath: auth.path)) == nil {
      try? manager.removeItem(at: auth)
      try manager.createSymbolicLink(
        at: auth, withDestinationURL: home.appending(path: ".codex/auth.json"))
    }
    try Data(
      "model = \"\(Settings.mutantModel)\"\nmodel_reasoning_effort = \"\(Settings.codexEffort)\"\n"
        .utf8
    ).write(to: codexHome.appending(path: "config.toml"))
  }
}

enum Paths {
  /// `path` with every symlink resolved, as Seatbelt matches it: `/var/folders/x` is
  /// `/private/var/folders/x`, and a rule written for one never matches the other. A path that does
  /// not exist yet keeps its last component under the resolved parent. (`URL.resolvingSymlinksInPath`
  /// would turn `/private/var` back into `/var`.)
  static func real(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(path, &buffer) != nil {
      return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
    let url = URL(fileURLWithPath: path)
    guard url.path != "/" else { return path }
    return URL(fileURLWithPath: real(url.deletingLastPathComponent().path))
      .appending(path: url.lastPathComponent).path
  }
}

/// The files that ship with the program.
enum Resources {
  static func url(_ name: String) throws -> URL {
    guard
      let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    else { throw ModelRunError("the resource \(name) is missing from the build") }
    return url
  }

  static func text(_ name: String) throws -> String {
    try String(contentsOf: url(name), encoding: .utf8)
  }
}

/// A model run that cannot start or did not finish.
struct ModelRunError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

/// One model run to make.
struct ModelRequest {
  var role: ModelRole
  var model: String
  /// The run's workspace: the only folder the sandbox lets the model touch. It holds `prompt.md`.
  var run: URL
  /// Where the event log, the stderr and the meta file go, outside the workspace: `<prefix>.jsonl`.
  var logPrefix: URL
  /// For a Codex run: the schema its last message must follow, copied into the workspace.
  var schema: URL?
  var timeLimit: Double
  var maxTurns: Int?
}

/// The only place a model run's command line is built. A model never runs outside
/// `sandbox-exec` with its profile: every command starts with it, and `check` refuses any other.
enum ModelCommands {
  static func command(for request: ModelRequest, config: ModelConfig) -> Command {
    request.role.usesClaude ? claude(request, config) : codex(request, config)
  }

  /// Throws unless `command` starts with `sandbox-exec -f <one of the layer's profiles>`.
  static func check(_ command: Command, config: ModelConfig) throws {
    let profiles = [config.generatorProfile.path, config.codexProfile.path]
    guard command.executable == config.sandboxExec,
      let flag = command.arguments.firstIndex(of: "-f"), flag + 1 < command.arguments.count,
      profiles.contains(command.arguments[flag + 1])
    else {
      throw ModelRunError(
        "\(command.executable) would run a model outside sandbox-exec and a profile of the layer")
    }
  }

  private static func claude(_ request: ModelRequest, _ config: ModelConfig) -> Command {
    let tmp = request.run.appending(path: "tmp").path
    let inner = [
      config.claude, "-p", "--model", request.model, "--safe-mode", "--strict-mcp-config",
      "--tools", "Bash,Read,Write", "--permission-mode", "bypassPermissions",
      "--output-format", "stream-json", "--verbose", "--include-hook-events",
      "--no-session-persistence", "--max-turns",
      String(request.maxTurns ?? Settings.generatorTurns), "--max-budget-usd",
      String(Settings.claudeBudget),
    ]
    return sandboxed(
      profile: config.generatorProfile, config: config,
      parameters: ["HOME": config.home.path, "RUN": request.run.path, "CLAUDE": config.claude],
      inner: inner,
      environment: [
        "TMPDIR": tmp, "CLAUDE_CODE_TMPDIR": tmp, "CLAUDE_CODE_SHELL": "/bin/bash",
      ])
  }

  private static func codex(_ request: ModelRequest, _ config: ModelConfig) -> Command {
    var inner = [
      config.codex, "exec", "-m", request.model, "-c",
      "model_reasoning_effort=\"\(Settings.codexEffort)\"", "--ephemeral", "--skip-git-repo-check",
      "--dangerously-bypass-approvals-and-sandbox", "-C", request.run.path, "--json",
    ]
    if request.schema != nil {
      inner += ["--output-schema", request.run.appending(path: "schema.json").path]
    }
    inner += ["-o", request.run.appending(path: "last.json").path, "-"]
    return sandboxed(
      profile: config.codexProfile, config: config,
      parameters: [
        "HOME": config.home.path, "RUN": request.run.path, "CODEX_HOME": config.codexHome.path,
      ],
      inner: inner,
      environment: [
        "CODEX_HOME": config.codexHome.path, "TMPDIR": request.run.appending(path: "tmp").path,
      ])
  }

  private static func sandboxed(
    profile: URL, config: ModelConfig, parameters: [String: String], inner: [String],
    environment: [String: String]
  ) -> Command {
    var arguments: [String] = []
    for (name, value) in parameters.sorted(by: { $0.key < $1.key }) {
      arguments += ["-D", "\(name)=\(Paths.real(value))"]
    }
    arguments += ["-f", profile.path]
    return Command(
      executable: config.sandboxExec, arguments: arguments + inner, environment: environment)
  }
}

/// Starts a command with its prompt on stdin and its output in two files.
protocol Executor {
  /// - Returns: the exit status.
  /// - Throws: `TimedOut` after `timeout` seconds, the process killed.
  func execute(
    _ command: Command, prompt: URL, stdout: URL, stderr: URL, directory: URL, timeout: Double
  ) throws -> Int32
}

struct SystemExecutor: Executor {
  func execute(
    _ command: Command, prompt: URL, stdout: URL, stderr: URL, directory: URL, timeout: Double
  ) throws -> Int32 {
    for file in [stdout, stderr] {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
    process.standardInput = try FileHandle(forReadingFrom: prompt)
    process.standardOutput = try FileHandle(forWritingTo: stdout)
    process.standardError = try FileHandle(forWritingTo: stderr)
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 5) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
      }
      throw TimedOut(command: command.executable, seconds: timeout)
    }
    return process.terminationStatus
  }
}

/// What a model run left behind.
struct ModelResult: Equatable {
  var exit: Int32
  var seconds: Double
  /// The run's event log, and its sha256.
  var log: URL
  var logSha256: String
  /// The sha256 of each file in the workspace when the run began, by name.
  var inputs: [String: String]
  /// A Claude run's turns and cost, from its result event.
  var turns: Int?
  var costUSD: Double?
  /// A Claude run's tool calls, one line each: `Bash: <command>`, `Read: <path>`.
  var toolCalls: [String]
  /// A Claude run's final text, or a Codex run's last message.
  var lastMessage: Data?
}

/// Runs models in the layer's sandboxes.
struct ModelRunner {
  let config: ModelConfig
  var executor: any Executor = SystemExecutor()

  /// Runs `request`, keeping its event log, stderr and meta file at `request.logPrefix`.
  ///
  /// - Throws: `ModelRunError` for a run that would not be sandboxed or has no prompt;
  ///   `TimedOut` past the time limit.
  func run(_ request: ModelRequest) throws -> ModelResult {
    var runConfig = config
    if !request.role.usesClaude {
      runConfig.codexHome = config.codexHome.appending(path: UUID().uuidString)
      try ModelConfig.prepare(codexHome: runConfig.codexHome, home: config.home)
    }
    defer {
      if !request.role.usesClaude { try? FileManager.default.removeItem(at: runConfig.codexHome) }
    }
    let command = ModelCommands.command(for: request, config: runConfig)
    try ModelCommands.check(command, config: runConfig)
    let prompt = request.run.appending(path: "prompt.md")
    guard FileManager.default.fileExists(atPath: prompt.path) else {
      throw ModelRunError("no prompt.md in \(request.run.path)")
    }
    let manager = FileManager.default
    try manager.createDirectory(
      at: request.run.appending(path: "tmp"), withIntermediateDirectories: true)
    if let schema = request.schema {
      let copy = request.run.appending(path: "schema.json")
      try? manager.removeItem(at: copy)
      try manager.copyItem(at: schema, to: copy)
    }
    try? manager.removeItem(at: request.run.appending(path: "last.json"))
    let inputs = try Self.hashes(of: request.run)
    let log = request.logPrefix.appendingPathExtension("jsonl")
    let started = Date()
    let exit = try executor.execute(
      command, prompt: prompt, stdout: log,
      stderr: request.logPrefix.appendingPathExtension("stderr"), directory: request.run,
      timeout: request.timeLimit)
    let seconds = Date().timeIntervalSince(started)
    var result = ModelResult(
      exit: exit, seconds: seconds, log: log,
      logSha256: Digest.sha256((try? Data(contentsOf: log)) ?? Data()), inputs: inputs,
      turns: nil, costUSD: nil, toolCalls: [], lastMessage: nil)
    if request.role.usesClaude {
      Self.readEvents(of: log, into: &result)
    } else {
      result.lastMessage = try? Data(contentsOf: request.run.appending(path: "last.json"))
    }
    try Data(
      "role \(request.role) model \(request.model) exit \(exit) seconds \(Int(seconds))\n".utf8
    ).write(to: request.logPrefix.appendingPathExtension("meta"))
    return result
  }

  /// The sha256 of every regular file directly in `folder`, by name.
  static func hashes(of folder: URL) throws -> [String: String] {
    var hashes: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
    where !name.hasPrefix(".") {
      let url = folder.appending(path: name)
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
        !isFolder.boolValue
      else { continue }
      hashes[name] = Digest.sha256(try Data(contentsOf: url))
    }
    return hashes
  }

  private static func readEvents(of log: URL, into result: inout ModelResult) {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return }
    for line in text.split(separator: "\n") {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { continue }
      switch object["type"] as? String {
      case "assistant":
        let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        for item in content where item["type"] as? String == "tool_use" {
          let input = item["input"] as? [String: Any] ?? [:]
          let argument = input["command"] ?? input["file_path"] ?? input["path"] ?? ""
          result.toolCalls.append("\(item["name"] ?? "?"): \(argument)")
        }
      case "result":
        result.turns = object["num_turns"] as? Int
        result.costUSD = object["total_cost_usd"] as? Double
        result.lastMessage = (object["result"] as? String).map { Data($0.utf8) }
      default: break
      }
    }
  }
}
