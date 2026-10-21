import Foundation

let usage = """
  usage: palantir-accept <command>

  Replays checks generated from palantir's spec through palantir-drive and palantir-inspect, and
  decides each rule in code. Only generate, triage and explore call a model, and only inside a
  sandbox.

    replay <check.json>... [--record <dir>] [--app <bundle>] [--release-app <bundle>] [--bin <dir>]
      Replays checks against built palantirs; exit 0 when all pass, 1 when one fails, 2 when one
      ends with no verdict.
    replay --all [--json <verdicts.json>] [--spec <dir>] [--checks <dir>] [--record <dir>]
      Replays the check of every current rule and prints one verdict per rule ID: pass, fail, error,
      missing, ungated, stale, changed or orphan. Exit 0 only when every rule passes.
    lint <check.json> (<rule.md> | --spec <dir>)
      Checks a check against its rule without palantir.
    lint --probe <probe.json> <feature.md>
      Checks an exploration's probe against its feature's rules.
    status [--spec <dir>] [--checks <dir>]
      One line per rule: current, missing, stale, changed, ungated or orphan; exit 1 unless every rule
      is current.
    gate <rule> [--spec <dir>] [--checks <dir>]
      Re-verifies a rule's stored folder from its files, running nothing.
    generate [<rule>...] [--keep-going] [--vm] [--resume <run>] [--spec <dir>] [--checks <dir>]
      Generates, judges and mutant-gates a check for each rule given, or for every missing and stale
      one. Replays run behind the command in PALANTIR_ACCEPT_REPLAY_WRAPPER when it is set.
    triage <rule> --replay <dir> [--vm] [--spec <dir>] [--checks <dir>]
      Reads a failed replay: blames palantir (the check is left alone) or the check (a replacement is
      generated and swapped in only if it passes the gate and fails every mutant the old check
      failed).
    explore [<feature>] [--vm] [--resume <run>] [--spec <dir>]
      Probes a feature around its rules, replays the probes and reports candidate spec changes. It
      never fails a rule and exits 0.
    build-mutant <patch> <palantir.app>
      Applies a patch to the layer's mutant workspace, builds it there and bundles the result, as
      generation does.
    probe <prompt.md> [--codex] [--run <dir>] [--log <prefix>]
      Runs a prompt in the generator's sandbox (or Codex's), to check what the sandbox keeps out.
    vm-replay [--json <verdicts.json>] [--spec <dir>] [--checks <dir>] [--app <bundle>]
      [--release-app <bundle>] [--bin <dir>]
      Replays every rule's check in a run clone of the prepared Tart VM, headless, and brings the
      verdicts back; this Mac's desktop is not used. Needs PALANTIR_ACCEPT_TART and TART_HOME.
    compare <host verdicts.json> <vm verdicts.json>
      Fails on any rule whose verdicts differ between the machines, and prints both machines'
      macOS builds.
    launch [--release] [--no-inspector] [--app <bundle>] [--release-app <bundle>] [--bin <dir>]
      Launches a palantir and prints its pid.

  Exit codes: 0 pass or done; 1 a verdict that is not pass; 2 an error before a verdict; 64 usage.
  """

/// The commands, in the order the usage lists them.
let commandNames = [
  "replay", "lint", "status", "gate", "generate", "triage", "explore", "build-mutant", "probe",
  "vm-replay", "compare", "launch",
]

func run(_ words: [String]) throws {
  var arguments = Arguments(words)
  guard let command = arguments.words.first else { throw Usage("no command") }
  arguments = Arguments(Array(arguments.words.dropFirst()))
  switch command {
  case "help", "--help", "-h": print(usage)
  case "replay": try ReplayCommand.run(&arguments)
  case "lint": try LintCommand.run(&arguments)
  case "status": try StatusCommand.run(&arguments)
  case "gate": try GateCommand.run(&arguments)
  case "generate": try GenerateCommand.run(&arguments)
  case "explore": try ExploreCommand.run(&arguments)
  case "triage": try TriageCommand.run(&arguments)
  case "vm-replay": try VMReplayCommand.run(&arguments)
  case "compare": try CompareCommand.run(&arguments)
  case "build-mutant": try BuildMutantCommand.run(&arguments)
  case "probe": try ProbeCommand.run(&arguments)
  case "launch": try LaunchCommand.run(&arguments)
  default: throw Usage("no command \(command)")
  }
}

/// The folders and bundles the commands that launch palantir share.
struct Locations {
  var bin: URL
  var debugApp: URL
  var releaseApp: URL

  /// Takes `--bin`, `--app` and `--release-app` from `arguments`. Without `--bin` the folder of
  /// this executable, where SwiftPM builds the two CLIs too.
  init(_ arguments: inout Arguments) throws {
    bin =
      try arguments.takeOption("--bin").map { URL(fileURLWithPath: $0) }
      ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .deletingLastPathComponent()
    debugApp = URL(fileURLWithPath: try arguments.takeOption("--app") ?? ".build/palantir.app")
    releaseApp = URL(
      fileURLWithPath: try arguments.takeOption("--release-app")
        ?? "\(Settings.cache)/release/palantir.app")
  }

  func launcher(runner: any Runner) -> Launcher {
    Launcher(
      runner: runner, processes: SystemProcesses(), bin: bin,
      apps: [.debug: debugApp, .release: releaseApp])
  }
}

enum ReplayCommand {
  static func run(_ arguments: inout Arguments) throws {
    let record = try arguments.takeOption("--record")
    let json = try arguments.takeOption("--json")
    let all = arguments.takeFlag("--all")
    let folders = try Folders(&arguments)
    let locations = try Locations(&arguments)
    let paths = try arguments.positional()
    let runner = SystemRunner()
    let replayer = Replayer(
      launcher: locations.launcher(runner: runner), runner: runner, programs: { runner.programs })
    let stamp = Int(Date().timeIntervalSince1970)
    let base = URL(
      fileURLWithPath: record
        ?? (all ? "\(Settings.cache)/test-acceptance/\(stamp)" : "replay-\(stamp)"))
    if all {
      guard paths.isEmpty else { throw Usage("replay --all takes no check") }
      let rules = try Spec.rules(in: folders.spec)
      let verdicts = try ReplayAll.run(
        rules: rules, checks: folders.checks, jq: SystemJQ(runner: runner)
      ) { rule, check in
        let data = try Data(contentsOf: check)
        return try replayer.replay(
          try Check.decode(data), data: data, path: check.path,
          into: base.appending(path: rule.name))
      }
      for verdict in verdicts { print(verdict.line) }
      print(ReplayAll.summary(verdicts))
      if let json {
        let file = VerdictsFile(
          build: .init(
            debugAppSha256: sha256(of: locations.launcher(runner: runner).executable(of: .debug)),
            releaseAppSha256: sha256(
              of: locations.launcher(runner: runner).executable(of: .release))),
          machine: .current,
          verdicts: Dictionary(uniqueKeysWithValues: verdicts.map { ($0.id, $0.word) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: URL(fileURLWithPath: json))
      }
      let code = ReplayAll.exitCode(verdicts)
      if code != 0 { exit(code) }
      return
    }
    guard !paths.isEmpty else { throw Usage("replay takes a check") }
    var code: Int32 = 0
    for (index, path) in paths.enumerated() {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      let check = try Check.decode(data)
      let directory = paths.count == 1 ? base : base.appending(path: "\(index + 1)")
      let report = try replayer.replay(check, data: data, path: path, into: directory)
      print(Verdicts.line(report))
      if report.verdict == .error {
        code = 2
      } else if report.verdict == .fail, code == 0 {
        code = 1
      }
    }
    if code != 0 { exit(code) }
  }

  private static func sha256(of url: URL?) -> String? {
    url.flatMap { try? Data(contentsOf: $0) }.map(Digest.sha256)
  }
}

enum LintCommand {
  static func run(_ arguments: inout Arguments) throws {
    let probe = arguments.takeFlag("--probe")
    let spec = try arguments.takeOption("--spec")
    let paths = try arguments.positional()
    guard paths.count == (spec == nil ? 2 : 1) else {
      throw Usage("lint takes a check and a rule.md, or a check and --spec")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
    let runner = SystemRunner()
    let jq = SystemJQ(runner: runner)
    var problems: [String]
    if probe {
      let text = try String(contentsOfFile: paths[1], encoding: .utf8)
      let rules = try Spec.parse(text, file: Spec.feature(ofBlock: text) ?? "")
      let check = try Check.decode(data)
      guard let rule = Spec.rule(check.rule, in: rules) else {
        throw Usage("\(paths[1]) holds no rule \(check.rule)")
      }
      problems = try Lint.problems(in: check, for: rule, jq: jq, followsExample: false)
      if (try? Phase.sequence(of: check.steps.map(\.line), for: check.rule)) == nil {
        problems.append("a step's line starts with no Given, When, Then or And")
      }
    } else {
      let rule: Rule
      if let spec {
        let id = try Check.decode(data).rule
        guard let found = Spec.rule(id, in: try Spec.rules(in: URL(fileURLWithPath: spec))) else {
          throw Usage("no rule \(id) in \(spec)")
        }
        rule = found
      } else {
        let text = try String(contentsOfFile: paths[1], encoding: .utf8)
        let rules = try Spec.parse(text, file: Spec.feature(ofBlock: text) ?? "")
        guard let only = rules.first, rules.count == 1 else {
          throw Usage("\(paths[1]) holds \(rules.count) rules, not one")
        }
        rule = only
      }
      problems = try Lint.problems(in: data, for: rule, jq: jq)
    }
    for problem in problems { print(problem) }
    print(problems.isEmpty ? "lint: ok" : "lint: \(problems.count) problems")
    if !problems.isEmpty { exit(1) }
  }
}

enum LaunchCommand {
  static func run(_ arguments: inout Arguments) throws {
    let release = arguments.takeFlag("--release")
    let inspector = !arguments.takeFlag("--no-inspector")
    let locations = try Locations(&arguments)
    try arguments.positional().isEmpty ? () : { throw Usage("launch takes no arguments") }()
    let runner = SystemRunner()
    let pid = try locations.launcher(runner: runner).launch(
      build: release ? .release : .debug, inspector: inspector)
    print(pid)
  }
}

enum Verdicts {
  /// The one line a replay prints: the rule, the verdict, and where it stopped.
  static func line(_ report: ReplayReport) -> String {
    var fields = [report.rule, report.verdict.rawValue]
    if let failure = report.failure {
      var stopped = failure.kind
      if let step = failure.step, let phase = failure.phase, step < report.steps.count {
        stopped = "\(phase.rawValue) step \(step): \(report.steps[step].line)"
      }
      fields.append(failure.message.map { "\(stopped) (\($0))" } ?? stopped)
    } else {
      fields.append(String(format: "%.1fs", report.seconds))
    }
    return fields.joined(separator: "\t")
  }
}

/// The spec and checks folders `status` and `gate` read.
struct Folders {
  var spec: URL
  var checks: URL

  init(_ arguments: inout Arguments) throws {
    spec = URL(fileURLWithPath: try arguments.takeOption("--spec") ?? "spec/features")
    checks = URL(fileURLWithPath: try arguments.takeOption("--checks") ?? "Tests/Acceptance/Checks")
  }
}

enum StatusCommand {
  static func run(_ arguments: inout Arguments) throws {
    let folders = try Folders(&arguments)
    guard try arguments.positional().isEmpty else { throw Usage("status takes no arguments") }
    let statuses = try Status.of(
      rules: Spec.rules(in: folders.spec), checks: folders.checks,
      jq: SystemJQ(runner: SystemRunner()))
    for status in statuses { print(Status.line(status)) }
    let current = statuses.filter { $0.state == .current }.count
    print(
      ReplayAll.summary(
        statuses.map { RuleVerdict(id: $0.id, word: $0.state.rawValue, detail: "") }))
    if current != statuses.count { exit(1) }
  }
}

enum GateCommand {
  static func run(_ arguments: inout Arguments) throws {
    let folders = try Folders(&arguments)
    let names = try arguments.positional()
    guard names.count == 1 else { throw Usage("gate takes one rule") }
    let rules = try Spec.rules(in: folders.spec)
    guard
      let rule = rules.first(where: {
        $0.id == names[0] || $0.name == names[0] || "req~\($0.name)" == names[0]
      })
    else { throw Usage("no rule \(names[0])") }
    let problems = try Gate.problems(
      of: CheckFolder(rule: rule, in: folders.checks), for: rule,
      jq: SystemJQ(runner: SystemRunner()))
    for problem in problems { print(problem) }
    print(problems.isEmpty ? "gate: ok \(rule.id)" : "gate: \(problems.count) problems")
    if !problems.isEmpty { exit(1) }
  }
}

enum ProbeCommand {
  static func run(_ arguments: inout Arguments) throws {
    let codex = arguments.takeFlag("--codex")
    let cache = URL(fileURLWithPath: Settings.cache)
    let stamp = Int(Date().timeIntervalSince1970)
    let folder = URL(
      fileURLWithPath: try arguments.takeOption("--run") ?? "\(Settings.cache)/runs/probe-\(stamp)")
    let prefix = URL(
      fileURLWithPath: try arguments.takeOption("--log")
        ?? "\(Settings.cache)/runs/probe-\(stamp)-log")
    let names = try arguments.positional()
    guard names.count == 1 else { throw Usage("probe takes one prompt file") }
    let manager = FileManager.default
    try manager.createDirectory(
      at: folder.appending(path: "work"), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
    let prompt = folder.appending(path: "prompt.md")
    try? manager.removeItem(at: prompt)
    try manager.copyItem(at: URL(fileURLWithPath: names[0]), to: prompt)
    let runner = ModelRunner(config: try ModelConfig.resolve(cache: cache))
    let result = try runner.run(
      ModelRequest(
        role: codex ? .judge : .generator,
        model: codex ? Settings.judgeModel : Settings.generatorModel, run: folder,
        logPrefix: prefix,
        schema: nil, timeLimit: Settings.draftTime, maxTurns: nil))
    print("exit \(result.exit) seconds \(Int(result.seconds)) turns \(result.turns ?? -1)")
    for call in result.toolCalls { print("tool \(call)") }
    print(result.lastMessage.map { String(decoding: $0, as: UTF8.self) } ?? "")
  }
}

enum GenerateCommand {
  static func run(_ arguments: inout Arguments) throws {
    let keepGoing = arguments.takeFlag("--keep-going")
    let inVM = arguments.takeFlag("--vm")
    let resume = try arguments.takeOption("--resume")
    let folders = try Folders(&arguments)
    let locations = try Locations(&arguments)
    let names = try arguments.positional()
    let rules = try Spec.rules(in: folders.spec)
    let runner = SystemRunner()
    let jq = SystemJQ(runner: runner)
    var targets: [Rule] = []
    if names.isEmpty {
      for status in try Status.of(rules: rules, checks: folders.checks, jq: jq)
      where status.state == .missing || status.state == .stale || status.state == .changed {
        if let rule = rules.first(where: { RuleID.name(of: $0.id) == RuleID.name(of: status.id) }) {
          targets.append(rule)
        }
      }
    } else {
      for name in names {
        guard
          let rule = rules.first(where: {
            $0.id == name || $0.name == name || "req~\($0.name)" == name
          })
        else { throw Usage("no rule \(name)") }
        targets.append(rule)
      }
    }
    guard resume == nil || targets.count == 1 else { throw Usage("--resume takes one rule") }
    let cache = URL(fileURLWithPath: Settings.cache)
    let config = try ModelConfig.resolve(cache: cache)
    let tool = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let build = try BuildInfo.current(runner: runner)
    let machine: VMReplayService? =
      inVM
      ? VMReplayService(
        config: try VMConfig.resolve(), cache: cache, bin: locations.bin,
        debugApp: locations.debugApp, releaseApp: locations.releaseApp) : nil
    if let machine { Termination.handle { machine.finish() } }
    let code = Batch.run(
      targets, keepGoing: keepGoing, machine: machine,
      attempt: { rule, id in
        let generation = try GenerationRun(
          rule: rule, run: cache.appending(path: "runs/\(id)"), checks: folders.checks,
          models: ModelRunner(config: config),
          replays: machine
            ?? ProcessReplay(
              runner: runner, tool: tool, wrapper: Settings.replayWrapper,
              debugApp: locations.debugApp, releaseApp: locations.releaseApp, bin: locations.bin),
          mutants: GitMutantBuilder(
            runner: runner,
            repository: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            cache: cache),
          jq: jq, tool: tool, build: build)
        return try generation.execute()
      }, id: { rule in resume ?? "\(rule.name)-\(Int(Date().timeIntervalSince1970))" })
    if code != 0 { exit(code) }
  }
}

/// The loop of `generate` over its rules. The run clone is stopped and deleted before it returns,
/// whatever the outcomes, because the command's `exit` runs no `defer`.
enum Batch {
  static func run(
    _ rules: [Rule], keepGoing: Bool, machine: VMReplayService?,
    attempt: (Rule, String) throws -> GenerationOutcome, id: (Rule) -> String
  ) -> Int32 {
    defer { machine?.finish() }
    var worst: Int32 = 0
    for rule in rules {
      let name = id(rule)
      do {
        switch try attempt(rule, name) {
        case .accepted: print("\(rule.id)\taccepted\t\(name)")
        case .ungated(let stage):
          print("\(rule.id)\tungated\t\(stage)\t\(name)")
          worst = max(worst, 1)
        }
      } catch {
        print("\(rule.id)\terror\t\(error)\t\(name)")
        worst = 2
        if !keepGoing { break }
      }
    }
    return worst
  }
}

enum BuildInfo {
  /// The repository's HEAD and whether its working tree differs from it.
  static func current(runner: any Runner) throws -> BuildRecord {
    let head = try runner.run("/usr/bin/git", ["rev-parse", "HEAD"], timeout: 30).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let status = try runner.run("/usr/bin/git", ["status", "--porcelain"], timeout: 60).stdout
    return BuildRecord(commit: head, dirty: !status.isEmpty)
  }
}

enum TriageCommand {
  static func run(_ arguments: inout Arguments) throws {
    guard let replay = try arguments.takeOption("--replay") else {
      throw Usage("triage needs --replay")
    }
    let inVM = arguments.takeFlag("--vm")
    let folders = try Folders(&arguments)
    let locations = try Locations(&arguments)
    let names = try arguments.positional()
    guard names.count == 1 else { throw Usage("triage takes one rule") }
    let rules = try Spec.rules(in: folders.spec)
    guard
      let rule = rules.first(where: {
        $0.id == names[0] || $0.name == names[0] || "req~\($0.name)" == names[0]
      })
    else { throw Usage("no rule \(names[0])") }
    let runner = SystemRunner()
    let cache = URL(fileURLWithPath: Settings.cache)
    let tool = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let directory = cache.appending(
      path: "triage/\(rule.name)-\(Int(Date().timeIntervalSince1970))")
    let machine: VMReplayService? =
      inVM
      ? VMReplayService(
        config: try VMConfig.resolve(), cache: cache, bin: locations.bin,
        debugApp: locations.debugApp, releaseApp: locations.releaseApp) : nil
    defer { machine?.finish() }
    if let machine { Termination.handle { machine.finish() } }
    let triage = TriageRun(
      rule: rule, checks: folders.checks, run: directory,
      models: ModelRunner(config: try ModelConfig.resolve(cache: cache)),
      jq: SystemJQ(runner: runner),
      replays: machine
        ?? ProcessReplay(
          runner: runner, tool: tool, wrapper: Settings.replayWrapper, debugApp: locations.debugApp,
          releaseApp: locations.releaseApp, bin: locations.bin),
      mutants: GitMutantBuilder(
        runner: runner, repository: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        cache: cache),
      tool: tool, build: try BuildInfo.current(runner: runner))
    let report = try triage.execute(replay: URL(fileURLWithPath: replay))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    try data.write(to: directory.appending(path: "triage.json"))
    print(String(decoding: data, as: UTF8.self))
    print("triage: \(report.outcome)\t\(directory.appending(path: "triage.json").path)")
    machine?.finish()
    switch report.outcome {
    case "replaced", "pass": break
    case "triage-error", "no-verdict": exit(2)
    default: exit(1)
    }
  }
}

enum BuildMutantCommand {
  static func run(_ arguments: inout Arguments) throws {
    let words = try arguments.positional()
    guard words.count == 2 else { throw Usage("build-mutant takes a patch and a bundle") }
    let patch = try String(contentsOfFile: words[0], encoding: .utf8)
    try GitMutantBuilder(
      runner: SystemRunner(),
      repository: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      cache: URL(fileURLWithPath: Settings.cache)
    ).build(patch: patch, into: URL(fileURLWithPath: words[1]))
    print(words[1])
  }
}

enum ExploreCommand {
  static func run(_ arguments: inout Arguments) throws {
    let inVM = arguments.takeFlag("--vm")
    let resume = try arguments.takeOption("--resume")
    let folders = try Folders(&arguments)
    let locations = try Locations(&arguments)
    let names = try arguments.positional()
    guard names.count <= 1 else { throw Usage("explore takes one feature") }
    guard resume == nil || names.count == 1 else { throw Usage("--resume takes one feature") }
    let rules = try Spec.rules(in: folders.spec).filter(\.isChecked)
    let features = names.isEmpty ? Array(Set(rules.map(\.feature))).sorted() : names
    let runner = SystemRunner()
    let cache = URL(fileURLWithPath: Settings.cache)
    let tool = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let machine: VMReplayService? =
      inVM
      ? VMReplayService(
        config: try VMConfig.resolve(), cache: cache, bin: locations.bin,
        debugApp: locations.debugApp, releaseApp: locations.releaseApp) : nil
    defer { machine?.finish() }
    if let machine { Termination.handle { machine.finish() } }
    for feature in features {
      let own = rules.filter { $0.feature == feature }
      guard !own.isEmpty else { throw Usage("no feature \(feature) with rules to explore") }
      let id = resume ?? "\(feature)-\(Int(Date().timeIntervalSince1970))"
      let directory = cache.appending(path: "explore/\(id)")
      do {
        let exploration = ExploreRun(
          feature: feature, rules: own, run: directory,
          models: ModelRunner(config: try ModelConfig.resolve(cache: cache)),
          replays: machine
            ?? ProcessReplay(
              runner: runner, tool: tool, wrapper: Settings.replayWrapper,
              debugApp: locations.debugApp,
              releaseApp: locations.releaseApp, bin: locations.bin),
          jq: SystemJQ(runner: runner), tool: tool)
        let report = try exploration.execute()
        print(
          "\(feature)\t\(report.candidates.count) candidates\t\(report.probes.count) probes\t\(directory.path)"
        )
      } catch {
        print("\(feature)\tnot finished\t\(error)\t\(id)")
      }
    }
  }
}

enum VMReplayCommand {
  static func run(_ arguments: inout Arguments) throws {
    let json = try arguments.takeOption("--json")
    let folders = try Folders(&arguments)
    let locations = try Locations(&arguments)
    guard try arguments.positional().isEmpty else { throw Usage("vm-replay takes no argument") }
    let cache = URL(fileURLWithPath: Settings.cache)
    let config = try VMConfig.resolve()
    let lock = try FileLock(cache.appending(path: "vm-replay.lock"))
    defer { lock.release() }
    let runner = SystemRunner()
    let destination = cache.appending(path: "vm-replay/\(Int(Date().timeIntervalSince1970))")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    func hostState(_ name: String) {
      let front = (try? runner.run(Settings.lsappinfo, ["front"], timeout: 10).stdout) ?? ""
      let info =
        (try? runner.run(
          Settings.lsappinfo,
          ["info", "-only", "name", front.trimmingCharacters(in: .whitespacesAndNewlines)],
          timeout: 10
        ).stdout) ?? ""
      let frontName = info.firstMatch(of: /"([^"]*)"/).map { String($0.1) } ?? "?"
      let idle =
        (try? runner.run("/usr/sbin/ioreg", ["-c", "IOHIDSystem"], timeout: 10).stdout) ?? ""
      let seconds = idle.split(separator: "\n").first { $0.contains("HIDIdleTime") }
        .flatMap { $0.split(separator: " ").last }.flatMap { Double($0) }.map {
          Int($0 / 1_000_000_000)
        }
      let line =
        "host front \(frontName) HID idle \(seconds.map(String.init) ?? "?") s"
      try? Data((line + "\n").utf8).write(to: destination.appending(path: "host-\(name).txt"))
      print("\(name): \(line)")
    }
    hostState("before")
    let session = VMSession(
      config: config, executor: SystemExecutor(), scratch: destination.appending(path: "scratch"))
    defer { session.shutdown() }
    let stage = try GuestStage(scratch: destination).build(
      debugApp: locations.debugApp, releaseApp: locations.releaseApp, bin: locations.bin,
      checks: folders.checks, spec: folders.spec, into: destination.appending(path: "stage"))
    try session.start()
    let result = try VMReplay.run(session: session, stage: stage, destination: destination)
    session.shutdown()
    hostState("after")
    print(result.output, terminator: "")
    if let json, let verdicts = result.verdicts {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(verdicts).write(to: URL(fileURLWithPath: json))
    }
    if result.exit != 0 { exit(result.exit) }
  }
}

enum CompareCommand {
  static func run(_ arguments: inout Arguments) throws {
    let names = try arguments.positional()
    guard names.count == 2 else {
      throw Usage("compare takes the host's and the VM's verdicts.json")
    }
    func load(_ path: String) throws -> VerdictsFile {
      try JSONDecoder().decode(
        VerdictsFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    let host = try load(names[0])
    let vm = try load(names[1])
    print("host: \(host.machine.macos)")
    print("vm:   \(vm.machine.macos) (hosted by \(vm.host?.macos ?? "?"))")
    let differences = Compare.differences(host: host, vm: vm)
    for line in differences { print(line) }
    print(
      differences.isEmpty
        ? "machines agree on \(host.verdicts.count) rules" : "\(differences.count) differences")
    if !differences.isEmpty { exit(1) }
  }
}
