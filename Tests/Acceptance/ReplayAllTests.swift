import Foundation
import Testing

@testable import PalantirAcceptance

@Suite(.layer(.unit))
struct ReplayAllTests {
  func rules() throws -> [Rule] {
    try Spec.rules(in: repositoryRoot.appending(path: "spec/features"))
  }

  /// A replay that answers with `verdict` for every check and records which rules it was asked about.
  final class Spy: @unchecked Sendable {
    var replayed: [String] = []
    var verdict: Verdict = .pass
    var failure: Failure?

    func replay(_ rule: Rule, _ check: URL) -> ReplayReport {
      replayed.append(rule.id)
      var report = AcceptedFolder.report(
        rule: rule.id, sha: "s", verdict: verdict, failure: failure)
      report.steps = [
        StepReport(line: "* Given a", phase: .given, actions: [], expect: []),
        StepReport(line: "* Then b", phase: .then, actions: [], expect: []),
      ]
      return report
    }
  }

  // req~acceptance.every-rule~1
  @Test func everyCheckedRuleGetsALineAndNoOtherDoes() throws {
    let empty = FileManager.default.temporaryDirectory.appending(path: "none-\(UUID().uuidString)")
    let spy = Spy()
    let verdicts = try ReplayAll.run(
      rules: rules(), checks: empty, jq: FakeJQ(), replay: spy.replay)
    #expect(verdicts.count == 21)
    #expect(verdicts.allSatisfy { $0.word == "missing" })
    #expect(spy.replayed.isEmpty)
    #expect(
      !verdicts.contains {
        $0.id.hasPrefix("req~acceptance.") || $0.id == "req~inspector.notebook-state~1"
      })
    #expect(ReplayAll.summary(verdicts) == "21 rules: 21 missing")
    #expect(ReplayAll.exitCode(verdicts) == 1)
  }

  // req~acceptance.every-rule~1
  @Test func aCurrentCheckIsReplayedAndAPassPrintsItsSeconds() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let spy = Spy()
    let verdicts = try ReplayAll.run(
      rules: rules(), checks: accepted.checks, jq: FakeJQ(), replay: spy.replay)
    #expect(spy.replayed == ["req~heading-folding.fold~1"])
    let fold = try #require(verdicts.first { $0.id == "req~heading-folding.fold~1" })
    #expect(fold.word == "pass" && fold.detail == "1.0s")
    #expect(fold.line == "req~heading-folding.fold~1\tpass\t1.0s")
    #expect(ReplayAll.summary(verdicts) == "21 rules: 1 pass, 20 missing")
  }

  @Test func aFailNamesTheStepAndAnErrorNamesItsCause() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let spy = Spy()
    spy.verdict = .fail
    spy.failure = Failure(step: 1, phase: .then, kind: "expect", that: "x", value: "false")
    var verdicts = try ReplayAll.run(
      rules: rules(), checks: accepted.checks, jq: FakeJQ(), replay: spy.replay)
    #expect(verdicts.first { $0.word == "fail" }?.detail == "then step 1: * Then b")
    #expect(ReplayAll.exitCode(verdicts) == 1)
    spy.verdict = .error
    spy.failure = Failure(kind: "launch", message: "no palantir appeared")
    verdicts = try ReplayAll.run(
      rules: rules(), checks: accepted.checks, jq: FakeJQ(), replay: spy.replay)
    #expect(verdicts.first { $0.word == "error" }?.detail == "launch: no palantir appeared")
    #expect(ReplayAll.exitCode(verdicts) == 2)
  }

  // req~acceptance.every-rule~1
  @Test func anUngatedStaleChangedOrOrphanRuleIsNeverReplayedAndMakesTheExitOne() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let all = try rules()
    // Ungated: the folder lost its check.
    try FileManager.default.removeItem(at: accepted.folder.check)
    try accepted.encode(
      Ungated(rule: accepted.rule.id, stage: "judge", run: "r"), to: accepted.folder.ungated)
    let spy = Spy()
    var verdicts = try ReplayAll.run(
      rules: all, checks: accepted.checks, jq: FakeJQ(), replay: spy.replay)
    #expect(
      verdicts.first { $0.id == accepted.rule.id }?.line
        == "req~heading-folding.fold~1\tungated\tjudge")
    #expect(spy.replayed.isEmpty)
    #expect(ReplayAll.exitCode(verdicts) == 1)
    // Stale: the spec moved to ~2 and the folder still holds ~1.
    try accepted.write()
    let bumped = all.map { rule -> Rule in
      guard rule.id == accepted.rule.id else { return rule }
      return Rule(
        id: "req~heading-folding.fold~2", feature: rule.feature, slug: rule.slug, version: 2,
        block: rule.block, exampleTitle: rule.exampleTitle, exampleLines: rule.exampleLines)
    }
    verdicts = try ReplayAll.run(
      rules: bumped, checks: accepted.checks, jq: FakeJQ(), replay: spy.replay)
    #expect(
      verdicts.first { $0.id == "req~heading-folding.fold~2" }?.line
        == "req~heading-folding.fold~2\tstale\t1 < 2")
    // Changed: same version, other words.
    let reworded = all.map { rule -> Rule in
      guard rule.id == accepted.rule.id else { return rule }
      return Rule(
        id: rule.id, feature: rule.feature, slug: rule.slug, version: 1, block: rule.block + "!",
        exampleTitle: rule.exampleTitle, exampleLines: rule.exampleLines)
    }
    verdicts = try ReplayAll.run(
      rules: reworded, checks: accepted.checks, jq: FakeJQ(), replay: spy.replay)
    #expect(
      verdicts.first { $0.id == accepted.rule.id }?.line
        == "req~heading-folding.fold~1\tchanged\tblock digest differs")
    // Orphan: the rule left the spec.
    verdicts = try ReplayAll.run(
      rules: all.filter { $0.id != accepted.rule.id }, checks: accepted.checks, jq: FakeJQ(),
      replay: spy.replay)
    #expect(verdicts.contains { $0.word == "orphan" && $0.id == "req~heading-folding.fold~1" })
    #expect(spy.replayed.isEmpty)
    #expect(ReplayAll.exitCode(verdicts) == 1)
  }

  @Test func allPassesIsExitZero() {
    #expect(ReplayAll.exitCode([RuleVerdict(id: "a", word: "pass", detail: "1s")]) == 0)
    #expect(ReplayAll.exitCode([]) == 0)
  }

  @Test func theVerdictsFileRoundTripsForCompare() throws {
    let file = VerdictsFile(
      build: .init(debugAppSha256: "a", releaseAppSha256: nil),
      machine: Machine(host: "h", macos: "m"),
      verdicts: ["req~a.b~1": "pass"])
    let data = try JSONEncoder().encode(file)
    #expect(try JSONDecoder().decode(VerdictsFile.self, from: data) == file)
  }

  @Test func theSummaryCountsCurrentRulesToo() {
    let verdicts =
      [RuleVerdict(id: "a", word: "current", detail: "")]
      + (1...20).map { RuleVerdict(id: "m\($0)", word: "missing", detail: "") }
    #expect(ReplayAll.summary(verdicts) == "21 rules: 1 current, 20 missing")
  }
}
