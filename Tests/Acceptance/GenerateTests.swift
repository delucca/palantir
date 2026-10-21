import Foundation
import Testing

@testable import PalantirAcceptance

/// What a generation test scripts: one closure per kind of model run or replay.
final class Script: Executor, ReplayService, MutantBuilding, @unchecked Sendable {
  var checkText: (Int) -> String
  /// The workspace's files at the start of each generator run, by run.
  var generatorWorkspaces: [[String: String]] = []
  var generatorRuns = 0
  var judgeRuns = 0
  var mutantRuns = 0
  var triageRuns = 0
  var probes: [String: String] = [:]
  var report: () -> String = { "{}" }
  var explorerWorkspaces: [[String]] = []
  var record: (URL) -> String = { _ in "{}" }
  var triage: (Int) -> String = { _ in "{}" }
  var judge: (Int) -> String
  var mutantNotes = "{\"files\":[\"Sources/App/A.swift\"],\"breaks\":\"b\",\"keeps\":\"k\"}"
  var patches: [String] = [
    "diff --git a/Sources/App/A.swift b/Sources/App/A.swift\n--- a/Sources/App/A.swift\n+++ b/Sources/App/A.swift\n@@ -1 +1 @@\n-x\n+y\n"
  ]
  /// Answers a replay of the check against the base (`nil`) or a mutant bundle.
  var verdict: (_ attempt: Int, _ mutant: URL?) throws -> (Verdict, Failure?)
  var builds: [String] = []
  var buildFails = false
  var replayCalls: [(app: URL?, check: String)] = []
  let rule: Rule

  init(rule: Rule) throws {
    self.rule = rule
    let text = try String(contentsOf: fixtures.appending(path: "fold-check.json"), encoding: .utf8)
    checkText = { _ in text }
    judge = { _ in Script.review(rule: rule, blocking: false) }
    verdict = { _, mutant in
      mutant == nil
        ? (.pass, nil)
        : (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    }
  }

  static func review(rule: Rule, blocking: Bool) -> String {
    let problems =
      blocking ? "[{\"severity\":\"blocking\",\"at\":\"x\",\"problem\":\"p\"}]" : "[]"
    let verdict = blocking ? "unfaithful" : "faithful"
    return """
      {"rule":"\(rule.id)","verdict":"\(verdict)","summary":"s","lines":[
       {"line":"\(rule.exampleLines[0].replacingOccurrences(of: "\"", with: "\\\""))","faithful":\(!blocking),"problems":\(problems)}]}
      """
  }

  // Executor
  func execute(
    _ command: Command, prompt: URL, stdout: URL, stderr: URL, directory: URL, timeout: Double
  ) throws -> Int32 {
    let manager = FileManager.default
    var out = ""
    if command.arguments.contains("--safe-mode"),
      let prompt = try? String(contentsOf: directory.appending(path: "prompt.md"), encoding: .utf8),
      prompt.contains("You explore palantir")
    {
      explorerWorkspaces.append(
        (try? manager.contentsOfDirectory(atPath: directory.path).sorted()) ?? [])
      if prompt.contains("Write at most 3 probes") {
        try manager.createDirectory(
          at: directory.appending(path: "work/probes"), withIntermediateDirectories: true)
        for (name, text) in probes {
          try Data(text.utf8).write(to: directory.appending(path: "work/probes/\(name)"))
        }
      } else {
        try Data(report().utf8).write(to: directory.appending(path: "work/report.json"))
      }
      out = "{\"type\":\"result\",\"num_turns\":2,\"total_cost_usd\":0.1,\"result\":\"done\"}\n"
    } else if command.arguments.contains("--safe-mode") {
      generatorRuns += 1
      var files: [String: String] = [:]
      for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
        files[name] = try? String(contentsOf: directory.appending(path: name), encoding: .utf8)
      }
      generatorWorkspaces.append(files)
      try manager.createDirectory(
        at: directory.appending(path: "work"), withIntermediateDirectories: true)
      try Data(checkText(generatorRuns).utf8).write(
        to: directory.appending(path: "work/check.json"))
      out = "{\"type\":\"result\",\"num_turns\":3,\"total_cost_usd\":0.5,\"result\":\"done\"}\n"
    } else {
      let schema =
        (try? String(contentsOf: directory.appending(path: "schema.json"), encoding: .utf8)) ?? ""
      if schema.contains("blame") {
        triageRuns += 1
        try Data(triage(triageRuns).utf8).write(to: directory.appending(path: "last.json"))
      } else if schema.contains("verdict") {
        judgeRuns += 1
        try Data(judge(judgeRuns).utf8).write(to: directory.appending(path: "last.json"))
      } else {
        mutantRuns += 1
        try Data(mutantNotes.utf8).write(to: directory.appending(path: "last.json"))
      }
    }
    try Data(out.utf8).write(to: stdout)
    return 0
  }

  // ReplayService
  var attempts: [String: Int] = [:]

  func replay(check: URL, app: URL?, into directory: URL) throws -> ReplayReport {
    let key = app?.path ?? "base"
    attempts[key, default: 0] += 1
    replayCalls.append((app, check.lastPathComponent))
    let data = try Data(contentsOf: check)
    let (verdict, failure) = try verdict(attempts[key] ?? 0, app)
    let report = AcceptedFolder.report(
      rule: rule.id, sha: Digest.sha256(data), verdict: verdict, failure: failure)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    try encoder.encode(report).write(to: directory.appending(path: "replay.json"))
    try Data(record(directory).utf8).write(to: directory.appending(path: "record.json"))
    return report
  }

  // MutantBuilding
  func writerWorkspace(in run: URL) throws -> URL {
    let repo = run.appending(path: "repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    return repo
  }

  func patch(of workspace: URL) throws -> String {
    let index = max(mutantRuns - 1, 0)
    return patches[min(index, patches.count - 1)]
  }

  var releaseRequests: [Bool] = []

  func build(patch: String, into bundle: URL, release: Bool) throws {
    releaseRequests.append(release)
    if buildFails { throw MutantBuildError("does not compile") }
    builds.append(bundle.path)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  }
}

@Suite(.layer(.integration), .serialized)
struct GenerateTests {
  struct World {
    let script: Script
    let cache: URL
    let checks: URL
    let rule: Rule

    init() throws {
      cache = FileManager.default.temporaryDirectory.appending(
        path: "generate-\(UUID().uuidString)")
      checks = cache.appending(path: "checks")
      let rules = try Spec.rules(in: repositoryRoot.appending(path: "spec/features"))
      rule = try #require(rules.first { $0.id == "req~heading-folding.fold~1" })
      script = try Script(rule: rule)
    }

    func generation(run: String = "run-1") throws -> GenerationRun {
      let tools = try FakeTools()
      var config = tools.config
      config.versions = ["claude": "claude 9", "codex": "codex 9"]
      let tool = cache.appending(path: "palantir-accept")
      try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
      try Data("binary".utf8).write(to: tool)
      return try GenerationRun(
        rule: rule, run: cache.appending(path: "runs/\(run)"), checks: checks,
        models: ModelRunner(config: config, executor: script), replays: script, mutants: script,
        jq: FakeJQ(), tool: tool, build: BuildRecord(commit: "abc", dirty: false))
    }

    func remove() { try? FileManager.default.removeItem(at: cache) }
  }

  func problems(_ world: World) throws -> [String] {
    try Gate.problems(
      of: CheckFolder(rule: world.rule, in: world.checks), for: world.rule, jq: FakeJQ())
  }

  // req~acceptance.generate~1
  @Test func aCheckThatPassesTheJudgeAndFailsItsMutantIsAcceptedAndPassesTheGate() throws {
    let world = try World()
    defer { world.remove() }
    let outcome = try world.generation().execute()
    #expect(outcome == .accepted)
    #expect(try problems(world) == [])
    let folder = CheckFolder(rule: world.rule, in: world.checks)
    let generation = try folder.decode(Generation.self, at: folder.generation)
    #expect(generation.blockSha256 == world.rule.blockSha256)
    #expect(generation.checkSha256 == Digest.sha256(try Data(contentsOf: folder.check)))
    #expect(generation.generator?.model == "claude-opus-5-5")
    #expect(generation.judge?.model == "gpt-6-astra")
    #expect(generation.generatorRuns?.count == 1)
    #expect(
      generation.generatorRuns?[0].inputs["rule.md"] == Digest.sha256(Data(world.rule.block.utf8)))
    #expect(generation.generatorRuns?[0].inputs["cli.md"] != nil)
    #expect(generation.inputs?["palantir-accept"] == Digest.sha256(Data("binary".utf8)))
    #expect(generation.mutants?.count == 1 && generation.mutants?[0].valid == true)
    #expect(generation.build == BuildRecord(commit: "abc", dirty: false))
    #expect(folder.mutants.count == 1)
    #expect(world.script.releaseRequests == [false])
    #expect(world.script.generatorRuns == 1 && world.script.judgeRuns == 1)
  }

  // req~acceptance.generate~1
  @Test func theGeneratorSeesOnlyTheRuleTheReferencesAndItsPromptOnTheFirstDraft() throws {
    let world = try World()
    defer { world.remove() }
    _ = try world.generation().execute()
    let files = world.script.generatorWorkspaces[0]
    #expect(
      Set(files.keys).subtracting(["bin", "work", "tmp"]) == [
        "rule.md", "cli.md", "format.md", "prompt.md",
      ])
    #expect(files["rule.md"] == world.rule.block)
    #expect(!world.rule.block.contains("From:") && !world.rule.block.contains("Decided in:"))
  }

  @Test func aFailedReplayIsFedBackAsItsReplayAndRecordUntilThePassOrThreeRevisions() throws {
    let world = try World()
    defer { world.remove() }
    world.script.verdict = { attempt, mutant in
      if mutant != nil {
        return (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
      }
      return attempt < 3
        ? (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
        : (.pass, nil)
    }
    #expect(try world.generation().execute() == .accepted)
    #expect(world.script.generatorRuns == 3)
    for revision in world.script.generatorWorkspaces.dropFirst() {
      #expect(revision["replay.json"] != nil && revision["record.json"] != nil)
      #expect(revision["review.json"] == nil && revision["gate-signal.txt"] == nil)
    }
  }

  // req~acceptance.triage~1
  @Test func aDraftThatKeepsFailingGoesUngatedAtReplayAndIsNeverAccepted() throws {
    let world = try World()
    defer { world.remove() }
    world.script.verdict = { _, _ in
      (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    }
    #expect(try world.generation().execute() == .ungated(stage: "replay"))
    #expect(world.script.generatorRuns == 4)
    let folder = CheckFolder(rule: world.rule, in: world.checks)
    #expect(
      !folder.has(folder.check) && folder.has(folder.ungated) && folder.has(folder.generation))
    #expect(try folder.decode(Ungated.self, at: folder.ungated).stage == "replay")
  }

  @Test func anUnfaithfulReviewIsFedBackAndTheCheckIsReplayedAndJudgedAgain() throws {
    let world = try World()
    defer { world.remove() }
    let rule = world.rule
    world.script.judge = { Script.review(rule: rule, blocking: $0 < 2) }
    #expect(try world.generation().execute() == .accepted)
    #expect(world.script.judgeRuns == 2)
    #expect(world.script.generatorRuns == 2)
    let revision = world.script.generatorWorkspaces[1]
    #expect(revision["review.json"]?.contains("unfaithful") == true)
    #expect(revision["replay.json"] == nil)
    let base = world.script.replayCalls.filter { $0.app == nil }
    #expect(base.count == 2)
  }

  @Test func threeUnfaithfulRoundsLeaveTheRuleUngatedAtTheJudge() throws {
    let world = try World()
    defer { world.remove() }
    let rule = world.rule
    world.script.judge = { _ in Script.review(rule: rule, blocking: true) }
    #expect(try world.generation().execute() == .ungated(stage: "judge"))
    #expect(world.script.judgeRuns == 3)
    #expect(world.script.mutantRuns == 0)
  }

  @Test func aJudgeThatSaysFaithfulWithABlockingProblemIsRerunOnceThenAnError() throws {
    let world = try World()
    defer { world.remove() }
    let rule = world.rule
    let wrong = Script.review(rule: rule, blocking: true).replacingOccurrences(
      of: "\"unfaithful\"", with: "\"faithful\"")
    world.script.judge = { $0 == 1 ? wrong : Script.review(rule: rule, blocking: false) }
    #expect(try world.generation().execute() == .accepted)
    #expect(world.script.judgeRuns == 2)
    world.script.judge = { _ in wrong }
    let again = try World()
    defer { again.remove() }
    again.script.judge = { _ in wrong }
    #expect(throws: JudgeError.self) { _ = try again.generation().execute() }
  }

  // req~acceptance.gate~1
  @Test func aMutantWhoseReplayFailsByAnActionOrAJQErrorIsNotValidAndTheNextWriterIsTried() throws {
    let world = try World()
    defer { world.remove() }
    world.script.patches = [
      "diff --git a/Sources/App/A.swift b/Sources/App/A.swift\n--- a/Sources/App/A.swift\n+++ b/Sources/App/A.swift\n@@ -1 +1 @@\n-x\n+y\n",
      "diff --git a/Sources/App/B.swift b/Sources/App/B.swift\n--- a/Sources/App/B.swift\n+++ b/Sources/App/B.swift\n@@ -1 +1 @@\n-x\n+z\n",
    ]
    world.script.verdict = { _, mutant in
      guard let mutant else { return (.pass, nil) }
      return mutant.path.contains("mutant-1-build")
        ? (.fail, Failure(step: 3, phase: .then, kind: "action", message: "exited 1"))
        : (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    }
    #expect(try world.generation().execute() == .accepted)
    #expect(world.script.mutantRuns == 2)
    let folder = CheckFolder(rule: world.rule, in: world.checks)
    #expect(folder.mutants.count == 1)
    let patch = try String(
      contentsOf: folder.mutants[0].appending(path: "mutant.patch"), encoding: .utf8)
    #expect(patch.contains("B.swift"))
    let generation = try folder.decode(Generation.self, at: folder.generation)
    #expect(generation.mutants?.map(\.valid) == [false, true])
  }

  @Test func aJQErrorOrAGivenFailureAtAMutantIsNotValidEither() throws {
    for failure in [
      Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "error: boom"),
      Failure(step: 1, phase: .given, kind: "expect", that: "x", value: "false"),
    ] {
      let world = try World()
      defer { world.remove() }
      world.script.verdict = { _, mutant in mutant == nil ? (.pass, nil) : (.fail, failure) }
      #expect(try world.generation().execute() == .ungated(stage: "mutant"))
      #expect(world.script.mutantRuns == 2)
    }
  }

  @Test func aPatchOutsideTheAllowedPathsOrAMutantThatDoesNotBuildIsNotValid() throws {
    let world = try World()
    defer { world.remove() }
    world.script.patches = [
      "diff --git a/Sources/Driver/main.swift b/Sources/Driver/main.swift\n--- a/x\n+++ b/x\n"
    ]
    #expect(try world.generation().execute() == .ungated(stage: "mutant"))
    #expect(world.script.builds.isEmpty)
    let other = try World()
    defer { other.remove() }
    other.script.buildFails = true
    #expect(try other.generation().execute() == .ungated(stage: "mutant"))
  }

  // req~acceptance.generate~1
  @Test func aCheckThatSurvivesItsMutantGetsOnlyTheFixedSignalAndIsRetestedOnTheSameMutant() throws
  {
    let world = try World()
    defer { world.remove() }
    world.script.verdict = { attempt, mutant in
      guard mutant != nil else { return (.pass, nil) }
      return attempt == 1
        ? (.pass, nil)
        : (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    }
    #expect(try world.generation().execute() == .accepted)
    #expect(world.script.generatorRuns == 2)
    #expect(world.script.mutantRuns == 1)
    let revision = world.script.generatorWorkspaces[1]
    #expect(revision["gate-signal.txt"] == Settings.gateSignal)
    #expect(revision["review.json"] == nil && revision["replay.json"] == nil)
    for (name, text) in revision {
      #expect(!text.contains("A.swift"), "\(name) names a palantir file")
      #expect(!text.contains("\"breaks\""), "\(name) holds the writer's notes")
    }
    let base = world.script.replayCalls.filter { $0.app == nil }
    #expect(base.count == 2)
    #expect(world.script.replayCalls.filter { $0.app != nil }.count == 2)
    #expect(world.script.builds.count == 1)
  }

  @Test func aCheckThatSurvivesAgainAfterItsRevisionEndsUngated() throws {
    let world = try World()
    defer { world.remove() }
    world.script.verdict = { _, mutant in mutant == nil ? (.pass, nil) : (.pass, nil) }
    #expect(try world.generation().execute() == .ungated(stage: "mutant-survives"))
    #expect(world.script.generatorRuns == 2)
    let folder = CheckFolder(rule: world.rule, in: world.checks)
    #expect(!folder.has(folder.check))
    #expect(try Status.status(of: world.rule, checks: world.checks, jq: FakeJQ()).state == .ungated)
  }

  // req~acceptance.generate~1
  @Test func aDraftThatDoesNotLintGoesUngatedAtTheDraft() throws {
    let world = try World()
    defer { world.remove() }
    world.script.checkText = { _ in "{\"format\": 1}" }
    #expect(try world.generation().execute() == .ungated(stage: "draft"))
    #expect(world.script.replayCalls.isEmpty)
  }

  @Test func everyValidMutantInTheStateIsKeptInTheFolderAsMutantsN() throws {
    let world = try World()
    defer { world.remove() }
    world.script.patches = [
      "diff --git a/Sources/App/A.swift b/Sources/App/A.swift\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-x\n+y\n",
      "diff --git a/Sources/App/B.swift b/Sources/App/B.swift\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-x\n+z\n",
    ]
    let first = try world.generation()
    world.script.verdict = { _, mutant in
      guard mutant != nil else { return (.pass, nil) }
      return (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    }
    #expect(try first.execute() == .accepted)
    // A second run of the same state with a second writer's mutant also valid keeps both.
    var state = first.state
    state.valid = [1, 1]
    let encoder = JSONEncoder()
    try FileManager.default.removeItem(at: CheckFolder(rule: world.rule, in: world.checks).url)
    state.stage = .accept
    state.outcome = nil
    try encoder.encode(state).write(to: world.cache.appending(path: "runs/run-1/state.json"))
    #expect(try world.generation().execute() == .accepted)
    #expect(CheckFolder(rule: world.rule, in: world.checks).mutants.count == 2)
  }

  // req~acceptance.generate~1
  @Test func aRunThatLosesTheDesktopResumesWithoutRunningTheGeneratorAgain() throws {
    let world = try World()
    defer { world.remove() }
    let original = world.script.verdict
    world.script.verdict = { _, _ in throw DesktopRefused() }
    #expect(throws: DesktopRefused.self) { _ = try world.generation().execute() }
    #expect(world.script.generatorRuns == 1)
    let saved = try JSONDecoder().decode(
      GenerationState.self,
      from: Data(contentsOf: world.cache.appending(path: "runs/run-1/state.json")))
    #expect(saved.stage == .replay)
    world.script.verdict = original
    #expect(try world.generation().execute() == .accepted)
    #expect(world.script.generatorRuns == 1)
  }

  @Test func aMutantWithNoVerdictIsRetriedBeforeConsumingAnotherWriter() throws {
    let world = try World()
    defer { world.remove() }
    world.script.verdict = { attempt, mutant in
      if mutant == nil { return (.pass, nil) }
      if attempt == 1 { return (.error, Failure(kind: "timeout")) }
      return (.fail, Failure(step: 3, phase: .then, kind: "expect", value: "false"))
    }
    #expect(try world.generation().execute() == .accepted)
    #expect(world.script.mutantRuns == 1)
    #expect(world.script.replayCalls.filter { $0.app != nil }.count == 2)
  }

  @Test func aLaterUngatedRunReplacesTheEarlierRunsMetadata() throws {
    let world = try World()
    defer { world.remove() }
    world.script.checkText = { _ in "{}" }
    let first = try world.generation(run: "first")
    _ = try first.execute()
    try first.finish()
    let second = try world.generation(run: "second")
    _ = try second.execute()
    try second.finish()
    let folder = CheckFolder(rule: world.rule, in: world.checks)
    #expect(try folder.decode(Ungated.self, at: folder.ungated).run == "second")
  }

  @Test func theRevisionPromptCarriesTheSectionOfItsReason() throws {
    let world = try World()
    defer { world.remove() }
    let rule = world.rule
    world.script.judge = { Script.review(rule: rule, blocking: $0 < 2) }
    _ = try world.generation().execute()
    let prompt = try #require(world.script.generatorWorkspaces[1]["prompt.md"])
    #expect(prompt.contains("found it unfaithful"))
    #expect(!prompt.contains("did not pass"))
    #expect(!prompt.contains("---- "))
  }
}

@Suite(.layer(.unit))
struct MutantTests {
  let rule = Rule(
    id: "req~heading-folding.fold~1", feature: "heading-folding", slug: "fold", version: 1,
    block: "b",
    exampleTitle: "t", exampleLines: [])
  let inspectorRule = Rule(
    id: "req~inspector.debug-only~1", feature: "inspector", slug: "debug-only", version: 1,
    block: "b",
    exampleTitle: "t", exampleLines: [])

  func patch(_ files: String...) -> String {
    files.map { "diff --git a/\($0) b/\($0)\n--- a/\($0)\n+++ b/\($0)\n@@ -1 +1 @@\n-x\n+y\n" }
      .joined()
  }

  @Test func aFeatureRuleMayChangeAppModelAndUIButNotTheInspectorOrTheDriver() {
    #expect(
      Mutant.problem(with: patch("Sources/Notebook/UI/A.swift", "Sources/App/B.swift"), for: rule)
        == nil)
    #expect(Mutant.problem(with: patch("Sources/Inspector/Server.swift"), for: rule) != nil)
    #expect(Mutant.problem(with: patch("Sources/Driver/main.swift"), for: rule) != nil)
    #expect(Mutant.problem(with: patch("Tests/App/A.swift"), for: rule) != nil)
    #expect(Mutant.problem(with: patch("Package.swift"), for: rule) != nil)
    #expect(Mutant.problem(with: patch("spec/features/a.md"), for: rule) != nil)
    #expect(Mutant.problem(with: patch("Sources/Acceptance/Check.swift"), for: rule) != nil)
    #expect(Mutant.problem(with: patch("Sources/App/../Driver/x.swift"), for: rule) != nil)
  }

  @Test func anAccessibilityRuleCannotMutateTheInspector() {
    let accessibility = Rule(
      id: "req~accessibility.custom-view-labels~1", feature: "accessibility",
      slug: "custom-view-labels", version: 1, block: "b", exampleTitle: "t", exampleLines: [])
    #expect(
      Mutant.problem(with: patch("Sources/Inspector/Server.swift"), for: accessibility) != nil)
    #expect(
      Mutant.problem(with: patch("Sources/Notebook/UI/View.swift"), for: accessibility) == nil)
  }

  @Test func anInspectorRuleMayAlsoChangeTheInspectorLibraryButNotItsCLI() {
    #expect(
      Mutant.problem(with: patch("Sources/Inspector/Server.swift"), for: inspectorRule) == nil)
    #expect(
      Mutant.problem(with: patch("Sources/Notebook/Inspector/State.swift"), for: inspectorRule)
        == nil)
    #expect(
      Mutant.problem(with: patch("Sources/Inspector/CLI/main.swift"), for: inspectorRule) != nil)
  }

  @Test func anEmptyPatchIsNotAMutant() {
    #expect(Mutant.problem(with: "", for: rule) != nil)
  }

  @Test func thePromptNamesTheRuleThePathsAndTheHintButNoOtherRule() throws {
    let text = try Mutant.prompt(for: rule)
    #expect(text.contains("`Sources/App/`") && !text.contains("@"))
    #expect(text.contains("Fold Heading calls unfold"))
  }

  @Test func aCaughtMutantFailedAtAThenExpectationPrintingFalse() {
    func report(_ failure: Failure?, _ verdict: Verdict) -> ReplayReport {
      AcceptedFolder.report(rule: "r", sha: "s", verdict: verdict, failure: failure)
    }
    #expect(
      Mutant.isCaught(
        by: report(Failure(step: 3, phase: .then, kind: "expect", value: "false"), .fail)))
    #expect(!Mutant.isCaught(by: report(Failure(step: 3, phase: .then, kind: "action"), .fail)))
    #expect(
      !Mutant.isCaught(
        by: report(Failure(step: 1, phase: .given, kind: "expect", value: "false"), .fail)))
    #expect(!Mutant.isCaught(by: report(nil, .pass)))
    #expect(!Mutant.isCaught(by: report(Failure(kind: "launch"), .error)))
  }
}
