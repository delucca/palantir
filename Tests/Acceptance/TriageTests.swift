import Foundation
import Testing

@testable import PalantirAcceptance

@Suite(.layer(.integration), .serialized)
struct TriageTests {
  struct World {
    let accepted: AcceptedFolder
    let script: Script
    let run: URL
    let replay: URL
    let realJQ = SystemJQ(runner: SystemRunner())

    /// A folder with an accepted check, and a failed replay of it whose record holds a folded list.
    init(failure: Failure? = nil, verdict: Verdict = .fail, phase: Phase = .then) throws {
      accepted = try AcceptedFolder()
      script = try Script(rule: accepted.rule)
      run = accepted.checks.appending(path: "triage-run")
      replay = accepted.checks.appending(path: "failed-replay")
      try FileManager.default.createDirectory(at: replay, withIntermediateDirectories: true)
      try Data("binary".utf8).write(to: accepted.checks.appending(path: "tool"))
      let sha = Digest.sha256(try Data(contentsOf: accepted.folder.check))
      var report = AcceptedFolder.report(
        rule: accepted.rule.id, sha: sha, verdict: verdict,
        failure: failure
          ?? Failure(
            step: 4, phase: phase, kind: "expect", that: ".x.folded == [1]", value: "false"))
      report.steps = accepted.rule.exampleLines.enumerated().map { index, line in
        StepReport(
          line: line, phase: index < 2 ? .given : index == 2 ? .when : .then, actions: [],
          expect: [])
      }
      try accepted.encode(report, to: replay.appending(path: "replay.json"))
      try Data("{\"x\":{\"folded\":[],\"n\":3}}".utf8).write(
        to: replay.appending(path: "record.json"))
      let rule = accepted.rule
      script.triage = { _ in
        """
        {"rule":"\(rule.id)","blame":"palantir","line":"\(rule.exampleLines[4].replacingOccurrences(of: "\"", with: "\\\""))","expectation":".x.folded == [1]","observed":[{"path":".x.folded","value":"[]"}],"reason":"r"}
        """
      }
    }

    func triage() -> TriageRun {
      let tools = try! FakeTools()
      return TriageRun(
        rule: accepted.rule, checks: accepted.checks, run: run,
        models: ModelRunner(config: tools.config, executor: script), jq: realJQ, replays: script,
        mutants: script, tool: accepted.checks.appending(path: "tool"),
        build: BuildRecord(commit: "abc", dirty: false))
    }

    func remove() { accepted.remove() }
  }

  // req~acceptance.triage~1
  @Test func aThenFailureWithEvidenceThatHoldsBlamesPalantirAndLeavesTheCheckAlone() throws {
    let world = try World()
    defer { world.remove() }
    let report = try world.triage().execute(replay: world.replay)
    #expect(report.outcome == "palantir-breaks-the-rule")
    #expect(report.evidence == [])
    #expect(report.verdict?.blame == .palantir)
    #expect(report.checkSha256Before != nil && report.checkSha256Before == report.checkSha256After)
    #expect(world.script.triageRuns == 1)
    #expect(world.script.generatorRuns == 0)
  }

  // req~acceptance.triage~1
  @Test func evidenceThatTheRecordContradictsIsRerunOnceThenATriageError() throws {
    let world = try World()
    defer { world.remove() }
    let id = world.accepted.rule.id
    let line = world.accepted.rule.exampleLines[4].replacingOccurrences(of: "\"", with: "\\\"")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"palantir","line":"\(line)","expectation":".x.folded == [1]","observed":[{"path":".x.n","value":"4"}],"reason":"r"}
      """
    }
    let report = try world.triage().execute(replay: world.replay)
    #expect(report.outcome == "triage-error")
    #expect(report.evidence.first?.contains(".x.n is 3 in the record, not 4") == true)
    #expect(world.script.triageRuns == 2)
  }

  @Test func aQuotedExpectationThatIsNotTheFailingOneFailsTheEvidence() throws {
    let world = try World()
    defer { world.remove() }
    let id = world.accepted.rule.id
    let line = world.accepted.rule.exampleLines[4].replacingOccurrences(of: "\"", with: "\\\"")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"palantir","line":"\(line)","expectation":".x.folded == [2]","observed":[{"path":".x.folded","value":"[]"}],"reason":"r"}
      """
    }
    let report = try world.triage().execute(replay: world.replay)
    #expect(report.outcome == "triage-error")
    #expect(report.evidence.contains("the expectation cited is not the replay's failing one"))
  }

  @Test func palantirIsNeverBlamedForAFailureBeforeTheThenLines() throws {
    let world = try World(
      failure: Failure(
        step: 1, phase: .given, kind: "expect", that: ".x.folded == [1]", value: "false"))
    defer { world.remove() }
    let id = world.accepted.rule.id
    let line = world.accepted.rule.exampleLines[1].replacingOccurrences(of: "\"", with: "\\\"")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"palantir","line":"\(line)","expectation":".x.folded == [1]","observed":[{"path":".x.folded","value":"[]"}],"reason":"r"}
      """
    }
    let report = try world.triage().execute(replay: world.replay)
    #expect(report.outcome == "triage-error")
    #expect(report.evidence.contains("palantir is blamed for a failure before the Then lines"))
  }

  // req~acceptance.triage~1
  @Test func aFailedActionAtAThenLineIsTriagedByItsMessage() throws {
    let world = try World(
      failure: Failure(
        step: 4, phase: .then, kind: "action", message: "drive scroll exited 1, the check expects 0"
      ))
    defer { world.remove() }
    let id = world.accepted.rule.id
    let line = world.accepted.rule.exampleLines[4].replacingOccurrences(of: "\"", with: "\\\"")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"palantir","line":"\(line)","expectation":"drive scroll exited 1, the check expects 0","observed":[{"path":".x.n","value":"3"}],"reason":"r"}
      """
    }
    #expect(try world.triage().execute(replay: world.replay).outcome == "palantir-breaks-the-rule")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"palantir","line":"\(line)","expectation":"another message","observed":[{"path":".x.n","value":"3"}],"reason":"r"}
      """
    }
    #expect(try world.triage().execute(replay: world.replay).outcome == "triage-error")
  }

  @Test func aReplayWithNoVerdictIsNotTriagedAndAPassHasNothingToTriage() throws {
    let world = try World(failure: Failure(kind: "launch", message: "x"), verdict: .error)
    defer { world.remove() }
    #expect(try world.triage().execute(replay: world.replay).outcome == "no-verdict")
    #expect(world.script.triageRuns == 0)
    let passed = try World(verdict: .pass)
    defer { passed.remove() }
    try passed.accepted.encode(
      AcceptedFolder.report(
        rule: passed.accepted.rule.id,
        sha: Digest.sha256(try Data(contentsOf: passed.accepted.folder.check)),
        verdict: .pass, failure: nil),
      to: passed.replay.appending(path: "replay.json"))
    #expect(try passed.triage().execute(replay: passed.replay).outcome == "pass")
  }

  // req~acceptance.triage~1
  @Test func blamingTheCheckGeneratesAReplacementThatMustFailEveryOldMutant() throws {
    let world = try World()
    defer { world.remove() }
    let id = world.accepted.rule.id
    let line = world.accepted.rule.exampleLines[4].replacingOccurrences(of: "\"", with: "\\\"")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"check","line":"\(line)","expectation":".x.folded == [1]","observed":[{"path":".x.folded","value":"[]"}],"reason":"r"}
      """
    }
    let oldCheck = try Data(contentsOf: world.accepted.folder.check)
    let replacement = String(decoding: oldCheck, as: UTF8.self) + "\n"
    world.script.checkText = { _ in replacement }
    let report = try world.triage().execute(replay: world.replay)
    #expect(report.outcome == "replaced")
    #expect(report.checkSha256Before != report.checkSha256After)
    let folder = world.accepted.folder
    #expect(try Data(contentsOf: folder.check) == Data(replacement.utf8))
    #expect(folder.mutants.count == 2)
    #expect(try Gate.problems(of: folder, for: world.accepted.rule, jq: FakeJQ()) == [])
    // The generator never saw what the old check did.
    for workspace in world.script.generatorWorkspaces {
      #expect(workspace["replay.json"] == nil && workspace["review.json"] == nil)
      #expect(workspace["gate-signal.txt"] == nil)
    }
    // The old mutant was rebuilt from its kept patch and replayed against the new check.
    #expect(world.script.builds.count == 2)
  }

  // req~acceptance.triage~1
  @Test func aReplacementThatSurvivesAnOldMutantIsNotSwappedIn() throws {
    let world = try World()
    defer { world.remove() }
    let id = world.accepted.rule.id
    let line = world.accepted.rule.exampleLines[4].replacingOccurrences(of: "\"", with: "\\\"")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"check","line":"\(line)","expectation":".x.folded == [1]","observed":[{"path":".x.folded","value":"[]"}],"reason":"r"}
      """
    }
    let oldCheck = try Data(contentsOf: world.accepted.folder.check)
    world.script.checkText = { _ in String(decoding: oldCheck, as: UTF8.self) + "\n" }
    world.script.verdict = { _, mutant in
      guard let mutant else { return (.pass, nil) }
      return mutant.path.contains("old-mutant")
        ? (.pass, nil)
        : (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    }
    let report = try world.triage().execute(replay: world.replay)
    #expect(report.outcome == "not-replaced")
    #expect(report.detail?.contains("does not fail the old mutant") == true)
    #expect(try Data(contentsOf: world.accepted.folder.check) == oldCheck)
    #expect(report.checkSha256Before == report.checkSha256After)
  }

  @Test func aReplacementThatGoesUngatedLeavesTheOldCheckInPlace() throws {
    let world = try World()
    defer { world.remove() }
    let id = world.accepted.rule.id
    let line = world.accepted.rule.exampleLines[4].replacingOccurrences(of: "\"", with: "\\\"")
    world.script.triage = { _ in
      """
      {"rule":"\(id)","blame":"check","line":"\(line)","expectation":".x.folded == [1]","observed":[],"reason":"r"}
      """
    }
    world.script.checkText = { _ in "{\"format\": 1}" }
    let before = try Data(contentsOf: world.accepted.folder.check)
    #expect(try world.triage().execute(replay: world.replay).outcome == "not-replaced")
    #expect(try Data(contentsOf: world.accepted.folder.check) == before)
  }
}

@Suite(.layer(.unit))
struct TriageClassificationTests {
  @Test func theReplayDecidesWhatTriageDoes() {
    func report(_ verdict: Verdict, _ phase: Phase?) -> ReplayReport {
      AcceptedFolder.report(
        rule: "r", sha: "s", verdict: verdict,
        failure: phase.map { Failure(step: 0, phase: $0, kind: "expect") })
    }
    #expect(Triage.classify(report(.pass, nil)) == .passed)
    #expect(Triage.classify(report(.error, nil)) == .noVerdict)
    #expect(Triage.classify(report(.fail, .given)) == .setup)
    #expect(Triage.classify(report(.fail, .when)) == .setup)
    #expect(Triage.classify(report(.fail, .then)) == .outcome)
  }

  @Test func jsonEvidencePreservesBooleanAndNumberTypesAtEveryDepth() {
    #expect(!Triage.sameJSON("true", "1"))
    #expect(!Triage.sameJSON("false", "0"))
    #expect(!Triage.sameJSON("{\"x\":[true]}", "{\"x\":[1]}"))
    #expect(Triage.sameJSON("1", "1.0"))
    #expect(Triage.sameJSON("{\"a\":1,\"b\":true}", "{\"b\":true,\"a\":1.0}"))
  }

  @Test func theSameJSONComparesValuesNotText() {
    #expect(Triage.sameJSON("{\"a\":1,\"b\":2}", "{\"b\":2,\"a\":1}"))
    #expect(Triage.sameJSON("[ ]", "[]"))
    #expect(!Triage.sameJSON("[1]", "[2]"))
    #expect(Triage.sameJSON("plain", " plain "))
  }
}
