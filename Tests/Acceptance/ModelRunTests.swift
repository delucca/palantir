import Foundation
import Testing

@testable import PalantirAcceptance

/// A config whose tools are fakes in a temporary folder: `sandbox-exec` logs its arguments, then
/// prints a Claude result event or writes the Codex last message.
struct FakeTools {
  let root: URL
  let config: ModelConfig
  let argumentsLog: URL

  init(sleepSeconds: Int = 0) throws {
    root = FileManager.default.temporaryDirectory.appending(path: "fake-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    argumentsLog = root.appending(path: "arguments.log")
    let script = root.appending(path: "sandbox-exec")
    try Data(
      """
      #!/bin/bash
      printf '%s\\n' "$@" > '\(argumentsLog.path)'
      env | grep -E '^(TMPDIR|CLAUDE_CODE_TMPDIR|CLAUDE_CODE_SHELL|CODEX_HOME)=' | sort >> '\(argumentsLog.path)'
      sleep \(sleepSeconds)
      while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then printf '{"verdict":"ok"}' > "$2"; fi
        shift
      done
      echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bin/palantir-accept lint work/check.json rule.md"}}]}}'
      echo '{"type":"result","num_turns":4,"total_cost_usd":0.25,"result":"done"}'
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    config = ModelConfig(
      home: URL(fileURLWithPath: "/home/fake"), sandboxExec: script.path,
      claude: "/fake/claude", codex: "/fake/codex", codexHome: root.appending(path: "codex-home"),
      generatorProfile: try Resources.url("generator.sb"),
      codexProfile: try Resources.url("codex.sb"))
  }

  func run(_ name: String) throws -> URL {
    let run = root.appending(path: name)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    try Data("do the thing".utf8).write(to: run.appending(path: "prompt.md"))
    try Data("rule".utf8).write(to: run.appending(path: "rule.md"))
    return run
  }

  func request(_ role: ModelRole, run: URL, schema: URL? = nil, timeLimit: Double = 20)
    -> ModelRequest
  {
    ModelRequest(
      role: role, model: role.usesClaude ? Settings.generatorModel : Settings.judgeModel, run: run,
      logPrefix: root.appending(path: "log-\(role)"), schema: schema, timeLimit: timeLimit,
      maxTurns: nil)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Executors that record the commands they were given.
final class SpyExecutor: Executor, @unchecked Sendable {
  var commands: [Command] = []

  func execute(
    _ command: Command, prompt: URL, stdout: URL, stderr: URL, directory: URL, timeout: Double
  ) throws -> Int32 {
    commands.append(command)
    FileManager.default.createFile(atPath: stdout.path, contents: nil)
    return 0
  }
}

@Suite(.layer(.unit))
struct ModelCommandTests {
  let run = URL(fileURLWithPath: "/runs/one")

  func tools() throws -> FakeTools { try FakeTools() }

  // req~acceptance.generate~1
  @Test func everyRolesCommandIsSandboxExecWithAProfileOfTheLayer() throws {
    let tools = try tools()
    defer { tools.remove() }
    for role in ModelRole.allCases {
      let request = tools.request(role, run: run, schema: role.usesClaude ? nil : run)
      let command = ModelCommands.command(for: request, config: tools.config)
      #expect(command.executable == tools.config.sandboxExec, "\(role)")
      let profile = role.usesClaude ? tools.config.generatorProfile : tools.config.codexProfile
      let flag = try #require(command.arguments.firstIndex(of: "-f"))
      #expect(command.arguments[flag + 1] == profile.path, "\(role)")
      #expect(command.arguments.first == "-D", "\(role)")
      try ModelCommands.check(command, config: tools.config)
      let program = command.arguments[flag + 2]
      #expect(program == (role.usesClaude ? "/fake/claude" : "/fake/codex"), "\(role)")
    }
  }

  // req~acceptance.generate~1
  @Test func aCommandThatStartsTheModelDirectlyOrWithoutAProfileIsRefused() throws {
    let tools = try tools()
    defer { tools.remove() }
    let direct = Command(executable: "/fake/claude", arguments: ["-p"], environment: [:])
    #expect(throws: ModelRunError.self) { try ModelCommands.check(direct, config: tools.config) }
    let bare = Command(
      executable: tools.config.sandboxExec, arguments: ["/fake/claude", "-p"], environment: [:])
    #expect(throws: ModelRunError.self) { try ModelCommands.check(bare, config: tools.config) }
    let other = Command(
      executable: tools.config.sandboxExec, arguments: ["-f", "/tmp/allow-all.sb", "/fake/claude"],
      environment: [:])
    #expect(throws: ModelRunError.self) { try ModelCommands.check(other, config: tools.config) }
    let noPath = Command(executable: tools.config.sandboxExec, arguments: ["-f"], environment: [:])
    #expect(throws: ModelRunError.self) { try ModelCommands.check(noPath, config: tools.config) }
  }

  // req~acceptance.generate~1
  @Test func theRunnerHandsTheExecutorOnlySandboxedCommandsForEveryRole() throws {
    let tools = try tools()
    defer { tools.remove() }
    let spy = SpyExecutor()
    let runner = ModelRunner(config: tools.config, executor: spy)
    for role in ModelRole.allCases {
      let folder = try tools.run("spy-\(role)")
      let schema = tools.root.appending(path: "schema-\(role).json")
      try Data("{}".utf8).write(to: schema)
      _ = try runner.run(tools.request(role, run: folder, schema: role.usesClaude ? nil : schema))
    }
    #expect(spy.commands.count == ModelRole.allCases.count)
    for command in spy.commands { try ModelCommands.check(command, config: tools.config) }
  }

  @Test func aClaudeRunKeepsToSafeModeThreeToolsAndItsOwnTemporaryFolder() throws {
    let tools = try tools()
    defer { tools.remove() }
    let command = ModelCommands.command(
      for: tools.request(.generator, run: run), config: tools.config)
    let arguments = command.arguments
    func value(after flag: String) -> String? {
      arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }
    #expect(value(after: "--model") == "claude-opus-5-5")
    #expect(value(after: "--tools") == "Bash,Read,Write")
    #expect(value(after: "--permission-mode") == "bypassPermissions")
    #expect(value(after: "--max-turns") == "30")
    #expect(value(after: "--max-budget-usd") == "3")
    #expect(arguments.contains("--safe-mode") && arguments.contains("--strict-mcp-config"))
    #expect(arguments.contains("--no-session-persistence"))
    #expect(!arguments.contains("--bare"))
    #expect(command.environment["TMPDIR"] == "/runs/one/tmp")
    #expect(command.environment["CLAUDE_CODE_TMPDIR"] == "/runs/one/tmp")
    #expect(command.environment["CLAUDE_CODE_SHELL"] == "/bin/bash")
    #expect(arguments.contains("RUN=/runs/one") && arguments.contains("CLAUDE=/fake/claude"))
  }

  @Test func anExplorerGetsItsOwnTurnLimit() throws {
    let tools = try tools()
    defer { tools.remove() }
    var request = tools.request(.explorer, run: run)
    request.maxTurns = Settings.explorerTurns
    let arguments = ModelCommands.command(for: request, config: tools.config).arguments
    #expect(arguments.firstIndex(of: "--max-turns").map { arguments[$0 + 1] } == "60")
  }

  @Test func aCodexRunUsesItsOwnHomeEphemeralAndASchema() throws {
    let tools = try tools()
    defer { tools.remove() }
    let request = tools.request(.judge, run: run, schema: run)
    let command = ModelCommands.command(for: request, config: tools.config)
    let arguments = command.arguments
    #expect(arguments.contains("--ephemeral") && arguments.contains("--json"))
    #expect(arguments.contains("model_reasoning_effort=\"high\""))
    #expect(arguments.contains("gpt-6-astra"))
    #expect(
      arguments.firstIndex(of: "--output-schema").map { arguments[$0 + 1] }
        == "/runs/one/schema.json")
    #expect(arguments.firstIndex(of: "-C").map { arguments[$0 + 1] } == "/runs/one")
    #expect(arguments.firstIndex(of: "-o").map { arguments[$0 + 1] } == "/runs/one/last.json")
    #expect(command.environment["CODEX_HOME"] == tools.config.codexHome.path)
    #expect(arguments.last == "-")
  }

  @Test func noModelOfTheLayerIsAFableModel() {
    for model in [
      Settings.generatorModel, Settings.judgeModel, Settings.mutantModel, Settings.triageModel,
    ] { #expect(!model.lowercased().contains("fable")) }
  }

  @Test func theProfilesDenyTheHomeFolderTheSharedTemporaryFoldersAndBuilds() throws {
    let generator = try Resources.text("generator.sb")
    #expect(generator.contains("(deny file-read* file-write* (subpath (param \"HOME\")))"))
    #expect(generator.contains("(subpath \"/private/tmp\")"))
    #expect(generator.contains("(subpath \"/private/var/folders\")"))
    #expect(generator.contains("(deny process-exec*)"))
    let codex = try Resources.text("codex.sb")
    for tool in ["swift", "swiftc", "xcodebuild", "xcrun"] {
      #expect(codex.contains("(literal \"/usr/bin/\(tool)\")"))
    }
    #expect(codex.contains("(literal \"/usr/bin/open\")"))
  }
}

@Suite(.layer(.integration), .serialized)
struct ModelRunTests {
  @Test func aClaudeRunKeepsItsLogAndReadsTurnsCostAndToolCalls() throws {
    let tools = try FakeTools()
    defer { tools.remove() }
    let run = try tools.run("claude-run")
    let request = tools.request(.generator, run: run)
    let result = try ModelRunner(config: tools.config).run(request)
    #expect(result.exit == 0)
    #expect(result.turns == 4)
    #expect(result.costUSD == 0.25)
    #expect(result.toolCalls == ["Bash: bin/palantir-accept lint work/check.json rule.md"])
    #expect(result.lastMessage.map { String(decoding: $0, as: UTF8.self) } == "done")
    #expect(result.inputs.keys.sorted() == ["prompt.md", "rule.md"])
    #expect(result.inputs["rule.md"] == Digest.sha256(Data("rule".utf8)))
    let log = try Data(contentsOf: result.log)
    #expect(result.logSha256 == Digest.sha256(log))
    #expect(
      try String(contentsOf: request.logPrefix.appendingPathExtension("meta"), encoding: .utf8)
        .contains("exit 0"))
    let seen = try String(contentsOf: tools.argumentsLog, encoding: .utf8)
    #expect(seen.contains("TMPDIR=\(run.path)/tmp"))
    #expect(seen.contains("CLAUDE_CODE_SHELL=/bin/bash"))
    #expect(FileManager.default.fileExists(atPath: run.appending(path: "tmp").path))
  }

  @Test func aCodexRunReturnsItsLastMessageAndCopiesTheSchemaIntoTheWorkspace() throws {
    let tools = try FakeTools()
    defer { tools.remove() }
    let run = try tools.run("codex-run")
    let schema = tools.root.appending(path: "judge.schema.json")
    try Data("{\"type\":\"object\"}".utf8).write(to: schema)
    let result = try ModelRunner(config: tools.config).run(
      tools.request(.judge, run: run, schema: schema))
    #expect(
      result.lastMessage.map { String(decoding: $0, as: UTF8.self) } == "{\"verdict\":\"ok\"}")
    #expect(result.inputs["schema.json"] == Digest.sha256(Data("{\"type\":\"object\"}".utf8)))
    let seen = try String(contentsOf: tools.argumentsLog, encoding: .utf8)
    #expect(seen.contains("CODEX_HOME=\(tools.config.codexHome.path)"))
  }

  @Test func aRunPastItsTimeLimitIsKilledAndThrows() throws {
    let tools = try FakeTools(sleepSeconds: 5)
    defer { tools.remove() }
    let run = try tools.run("slow")
    #expect(throws: TimedOut.self) {
      _ = try ModelRunner(config: tools.config).run(
        tools.request(.generator, run: run, timeLimit: 0.3))
    }
  }

  @Test func aRunWithoutAPromptThrows() throws {
    let tools = try FakeTools()
    defer { tools.remove() }
    let run = try tools.run("no-prompt")
    try FileManager.default.removeItem(at: run.appending(path: "prompt.md"))
    #expect(throws: ModelRunError.self) {
      _ = try ModelRunner(config: tools.config).run(tools.request(.generator, run: run))
    }
  }
}

@Suite(.layer(.integration), .serialized)
struct SystemRunnerTimeoutTests {
  @Test(arguments: [false, true])
  func timedOutChildrenAreTerminatedEvenWhenTheyIgnoreTERM(ignoreTERM: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "timeout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appending(path: "pid")
    let script =
      "\(ignoreTERM ? "trap '' TERM" : "trap 'exit 0' TERM"); echo $$ > \"$1\"; while :; do :; done"
    let began = Date()
    #expect(throws: TimedOut.self) {
      try SystemRunner().run("/bin/sh", ["-c", script, "timeout-test", pidFile.path], timeout: 0.5)
    }
    let pid = try #require(
      Int32(
        String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
      ))
    defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
    let deadline = Date().addingTimeInterval(3)
    while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(Date().timeIntervalSince(began) < 7)
    if ignoreTERM { #expect(Date().timeIntervalSince(began) >= 2) }
  }
}

@Suite(.layer(.integration), .serialized)
struct ModelSandboxTests {
  @Test func executableConfigurationCannotBeChangedButWorkspaceFilesCan() throws {
    let root = URL(fileURLWithPath: Paths.real(FileManager.default.temporaryDirectory.path))
      .appending(path: "sandbox-\(UUID().uuidString)")
    let home = root.appending(path: "home")
    let manager = FileManager.default
    for path in ["home/.claude", "repo/.git", "repo/Sources", "codex-home", "bin"] {
      try manager.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
    }
    defer { try? manager.removeItem(at: root) }
    for (profile, protected) in [
      ("generator.sb", "home/.claude/settings.json"),
      ("generator.sb", "home/.claude.json"),
      ("generator.sb", "bin/palantir-accept"),
      ("codex.sb", "repo/.git/config"),
    ] {
      let protectedFile = root.appending(path: protected)
      try Data("original".utf8).write(to: protectedFile)
      let permitted = root.appending(path: "repo/Sources/allowed")
      let output = try SystemRunner().run(
        "/usr/bin/sandbox-exec",
        [
          "-D", "HOME=\(home.path)", "-D", "RUN=\(root.path)",
          "-D", "CODEX_HOME=\(root.appending(path: "codex-home").path)",
          "-D", "CLAUDE=/bin/sh", "-f", try Resources.url(profile).path,
          "/bin/sh", "-c", "echo allowed > \"$1\"; echo changed > \"$2\"", "sandbox-test",
          permitted.path, protectedFile.path,
        ])
      #expect(output.exit != 0)
      try #require(manager.fileExists(atPath: permitted.path), "\(output.stderr)")
      #expect(try String(contentsOf: protectedFile, encoding: .utf8) == "original")
      #expect(try String(contentsOf: permitted, encoding: .utf8) == "allowed\n")
    }
  }
}

@Suite(.layer(.unit))
struct SandboxPathTests {
  // A symlinked run folder reaches the profile as its real path, or its allow rule never matches.
  @Test func aSymlinkedRunFolderIsPassedToTheProfileAsItsRealPath() throws {
    let tools = try FakeTools()
    defer { tools.remove() }
    let real = tools.root.appending(path: "real-run")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = tools.root.appending(path: "link-run")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    for role in ModelRole.allCases {
      let command = ModelCommands.command(for: tools.request(role, run: link), config: tools.config)
      let runs = command.arguments.filter { $0.hasPrefix("RUN=") }
      #expect(runs == ["RUN=\(Paths.real(real.path))"], "\(role)")
      #expect(!runs.contains("RUN=\(link.path)"))
    }
  }

  @Test func theRealPathOfATemporaryFolderIsUnderPrivateVar() {
    let path = Paths.real(NSTemporaryDirectory())
    #expect(path.hasPrefix("/private/var/") || !path.hasPrefix("/var/"))
  }

  @Test func aPathThatDoesNotExistYetKeepsItsNameUnderTheResolvedParent() throws {
    let tools = try FakeTools()
    defer { tools.remove() }
    #expect(Paths.real(tools.root.appending(path: "no/such").path).hasSuffix("/no/such"))
  }
}
