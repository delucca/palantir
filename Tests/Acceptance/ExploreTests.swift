import Foundation
import Testing

@testable import PalantirAcceptance

@Suite(.layer(.integration), .serialized)
struct ExploreTests {
  struct World {
    let accepted: AcceptedFolder
    let script: Script
    let run: URL
    let rules: [Rule]

    init() throws {
      accepted = try AcceptedFolder()
      script = try Script(rule: accepted.rule)
      run = accepted.checks.appending(path: "explore-run")
      rules = try Spec.rules(in: repositoryRoot.appending(path: "spec/features"))
        .filter { $0.feature == "heading-folding" }
      try Data("binary".utf8).write(to: accepted.checks.appending(path: "tool"))
    }

    var probe: String {
      accepted.checkText.replacingOccurrences(
        of: "\"example\": \"folding a task\"", with: "\"example\": \"a second fold\"")
    }

    func exploration(replays: (any ReplayService)? = nil) throws -> ExploreRun {
      ExploreRun(
        feature: "heading-folding", rules: rules, run: run,
        models: ModelRunner(config: try FakeTools().config, executor: script),
        replays: replays ?? script, jq: SystemJQ(runner: SystemRunner()),
        tool: accepted.checks.appending(path: "tool"))
    }

    func remove() { accepted.remove() }
  }

  func candidate(path: String, value: String) -> String {
    """
    {"rule":"req~heading-folding.fold~1","kind":"rule-gap","observed":"o","screenshot":null,
     "proposal":"p","evidence":[{"probe":"1","path":"\(path)","value":"\(value)"}]}
    """
  }

  @Test func probesAreReplayedAndOnlyCandidatesWithMatchingEvidenceAreKept() throws {
    let world = try World()
    defer { world.remove() }
    world.script.probes = ["1.json": world.probe]
    world.script.record = { _ in
      "{\"after\":{\"json\":{\"sections\":{\"notebook\":{\"folded\":[{\"offset\":8}]}}}}}"
    }
    let good = candidate(
      path: ".after.json.sections.notebook.folded", value: "[{\\\"offset\\\":8}]")
    let bad = candidate(path: ".after.json.sections.notebook.folded", value: "[]")
    world.script.report = {
      """
      {"feature":"heading-folding","candidates":[\(good),\(bad)],
       "probes":[{"probe":"1","question":"q","answer":"a"}]}
      """
    }
    let report = try world.exploration().execute()
    #expect(report.candidates.count == 1)
    #expect(report.rejected.count == 1)
    #expect(report.rejected[0].problems.first?.contains("is [{\"offset\":8}]") == true)
    #expect(report.probes.count == 1)
    #expect(report.probes[0].verdict == "pass")
    #expect(report.probes[0].variation == "a second fold")
    #expect(report.probes[0].question == "q")
    #expect(FileManager.default.fileExists(atPath: world.run.appending(path: "report.json").path))
    #expect(FileManager.default.fileExists(atPath: world.run.appending(path: "report.md").path))
    #expect(
      FileManager.default.fileExists(
        atPath: world.run.appending(path: "explorer/work/replays/1/table.md").path))
    #expect(world.script.replayCalls.count == 1)
  }

  @Test func editingTheExplorersCopyCannotChangeItsEvidence() throws {
    let world = try World()
    defer { world.remove() }
    world.script.probes = ["1.json": world.probe]
    world.script.record = { _ in "{\"value\":1}" }
    let madeUp = candidate(path: ".value", value: "2")
    world.script.report = {
      try? Data("{\"value\":2}".utf8).write(
        to: world.run.appending(path: "explorer/work/replays/1/record.json"))
      return "{\"feature\":\"heading-folding\",\"candidates\":[\(madeUp)],\"probes\":[]}"
    }
    let report = try world.exploration().execute()
    #expect(report.candidates.isEmpty)
    #expect(report.rejected.count == 1)
    #expect(
      try String(contentsOf: world.run.appending(path: "replays/1/record.json"), encoding: .utf8)
        == "{\"value\":1}")
  }

  // req~acceptance.exploration~1
  @Test func aProbeThatFailsItsReplayFailsNothingAndIsReportedAsFailed() throws {
    let world = try World()
    defer { world.remove() }
    world.script.probes = ["1.json": world.probe]
    world.script.verdict = { _, _ in
      (.fail, Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    }
    world.script.report = { "{\"feature\":\"heading-folding\",\"candidates\":[],\"probes\":[]}" }
    let report = try world.exploration().execute()
    #expect(report.probes[0].verdict == "fail")
    #expect(report.candidates.isEmpty)
  }

  @Test func theExplorerSeesOnlyTheFeaturesRulesWithoutProvenanceLines() throws {
    let world = try World()
    defer { world.remove() }
    _ = try world.exploration().execute()
    let text = try String(
      contentsOf: world.run.appending(path: "explorer/feature.md"), encoding: .utf8)
    #expect(
      text.contains("req~heading-folding.fold~1") && text.contains("req~heading-folding.unfold~1"))
    #expect(!text.contains("From:") && !text.contains("Decided in:"))
    #expect(!text.contains("req~heading-outline") && !text.contains("req~inspector"))
    #expect(world.script.explorerWorkspaces.first?.contains("feature.md") == true)
    #expect(world.script.generatorRuns == 0 && world.script.judgeRuns == 0)
  }

  @Test func anInvalidReportFailsAndResumeRunsTheReportAgain() throws {
    let world = try World()
    defer { world.remove() }
    world.script.probes = ["1.json": world.probe]
    world.script.report = { "{broken" }
    #expect(throws: ModelRunError.self) { try world.exploration().execute() }
    #expect(!FileManager.default.fileExists(atPath: world.run.appending(path: "report.done").path))
    world.script.report = { "{\"feature\":\"heading-folding\",\"candidates\":[],\"probes\":[]}" }
    let report = try world.exploration().execute()
    #expect(report.probes.count == 1)
    #expect(world.script.replayCalls.count == 1)
    #expect(world.script.explorerWorkspaces.count == 3)
  }

  @Test func aProbeThatIsNotACheckOrNamesNoRuleOrFailsLintIsListedAsNotRun() throws {
    let world = try World()
    defer { world.remove() }
    world.script.probes = [
      "1.json": "{\"nope\": true}",
      "2.json": world.probe.replacingOccurrences(
        of: "req~heading-folding.fold~1", with: "req~heading-folding.zzz~1"),
      "3.json": world.probe.replacingOccurrences(of: "\"* Given", with: "\"* Maybe"),
    ]
    let report = try world.exploration().execute()
    #expect(report.probes.map(\.verdict) == ["not-run", "not-run", "not-run"])
    #expect(report.probes[0].note == "the probe is not a check")
    #expect(report.probes[1].note == "the probe names no rule of heading-folding")
    #expect(
      report.probes[2].note?.hasPrefix("lint:") == true
        || report.probes[2].note?.contains("Given") == true)
    #expect(world.script.replayCalls.isEmpty)
  }

  @Test func aRefusedDesktopListsTheRestAsNotRunAndSkipsTheReport() throws {
    let world = try World()
    defer { world.remove() }
    world.script.probes = ["1.json": world.probe, "2.json": world.probe]
    world.script.verdict = { _, _ in throw DesktopRefused() }
    let report = try world.exploration().execute()
    #expect(report.probes.map(\.verdict) == ["not-run", "not-run"])
    #expect(report.probes[0].note?.contains("desktop refused") == true)
    #expect(world.script.explorerWorkspaces.count == 1)
  }
}

@Suite(.layer(.unit))
struct ExploreTableTests {
  @Test func theTableHoldsTheSelectionScrollFoldedAndGapsAfterEachNamedAction() throws {
    var report = AcceptedFolder.report(rule: "r", sha: "s", verdict: .pass, failure: nil)
    report.steps = [
      StepReport(
        line: "* Given a", phase: .given,
        actions: [
          ActionReport(
            action: "inspect", arguments: ["state"], exit: 0, stderr: "", seconds: 0, name: "opened"
          ),
          ActionReport(
            action: "sleep", arguments: ["1"], exit: nil, stderr: nil, seconds: 1, name: nil),
        ], expect: []),
      StepReport(
        line: "* When b", phase: .when,
        actions: [
          ActionReport(
            action: "inspect", arguments: ["state"], exit: 0, stderr: "", seconds: 0, name: "after")
        ], expect: []),
    ]
    let record = """
      {"opened":{"json":{"sections":{"notebook":{"selection":{"location":0,"length":0},
        "scroll":{"y":0,"documentHeight":600},"folded":[],"gaps":[]}}}},
       "after":{"json":{"sections":{"notebook":{"selection":{"location":8,"length":1},
        "scroll":{"y":6,"documentHeight":606},"folded":[{"offset":8}],"gaps":[{"after":1}]}}}}}
      """
    let table = try Explore.table(replay: report, record: Data(record.utf8))
    let rows = table.split(separator: "\n")
    #expect(rows.count == 4)
    #expect(rows[2].contains("opened") && rows[2].contains("0+0") && rows[2].contains("y 0 of 600"))
    #expect(rows[3].contains("after") && rows[3].contains("8+1") && rows[3].contains("y 6 of 606"))
    #expect(rows[3].hasSuffix("| 8 | 1 |"))
  }
}
