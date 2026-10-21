import Foundation
import Testing

@testable import PalantirAcceptance

@Suite(.layer(.unit))
struct StatusTests {
  func status(_ accepted: AcceptedFolder, rule: Rule? = nil) throws -> RuleStatus {
    try Status.status(of: rule ?? accepted.rule, checks: accepted.checks, jq: FakeJQ())
  }

  /// The fold rule as the spec would hold it after a bump or a rewording.
  func rule(_ accepted: AcceptedFolder, version: Int, block: String? = nil) -> Rule {
    Rule(
      id: "req~heading-folding.fold~\(version)", feature: "heading-folding", slug: "fold",
      version: version, block: block ?? accepted.rule.block,
      exampleTitle: accepted.rule.exampleTitle, exampleLines: accepted.rule.exampleLines)
  }

  @Test func anAcceptedFolderIsCurrent() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    #expect(try status(accepted).state == .current)
  }

  // req~acceptance.every-rule~1
  @Test func aRuleWithNoFolderIsMissing() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try FileManager.default.removeItem(at: accepted.folder.url)
    #expect(try status(accepted).state == .missing)
  }

  // req~acceptance.every-rule~1
  @Test func anUngatedFolderIsUngatedWithTheStageThatGaveUp() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try FileManager.default.removeItem(at: accepted.folder.check)
    try accepted.encode(
      Ungated(rule: accepted.rule.id, stage: "judge", run: "r"), to: accepted.folder.ungated)
    let result = try status(accepted)
    #expect(result.state == .ungated)
    #expect(result.detail == "judge")
  }

  // req~acceptance.generate~1
  @Test func aBumpedRuleMakesItsCheckStale() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let result = try status(accepted, rule: rule(accepted, version: 2))
    #expect(result.state == .stale)
    #expect(result.detail == "1 < 2")
  }

  // req~acceptance.generate~1
  @Test func aRewordedRuleMakesItsCheckChanged() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let result = try status(
      accepted, rule: rule(accepted, version: 1, block: accepted.rule.block + "x"))
    #expect(result.state == .changed)
  }

  @Test func aFolderThatNoLongerPassesTheGateIsUngated() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try Data((accepted.checkText + "\n").utf8).write(to: accepted.folder.check)
    #expect(try status(accepted).state == .ungated)
  }

  // req~acceptance.every-rule~1
  @Test func aFolderWhoseRuleIsGoneIsAnOrphan() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let others = try Spec.rules(in: repositoryRoot.appending(path: "spec/features"))
      .filter { $0.id != accepted.rule.id }
    let statuses = try Status.of(rules: others, checks: accepted.checks, jq: FakeJQ())
    let orphan = try #require(statuses.first { $0.state == .orphan })
    #expect(orphan.id == "req~heading-folding.fold~1")
    #expect(statuses.filter { $0.state == .missing }.count == 20)
  }

  // req~acceptance.every-rule~1
  @Test func theRealSpecWithNoChecksIsTwentyOneMissingRules() throws {
    let empty = FileManager.default.temporaryDirectory.appending(path: "empty-\(UUID().uuidString)")
    let statuses = try Status.of(
      rules: Spec.rules(in: repositoryRoot.appending(path: "spec/features")), checks: empty,
      jq: FakeJQ())
    #expect(statuses.count == 21)
    #expect(statuses.allSatisfy { $0.state == .missing })
    #expect(!statuses.contains { $0.id.hasPrefix("req~acceptance.") })
    #expect(!statuses.contains { $0.id == "req~inspector.notebook-state~1" })
    #expect(statuses.map(\.id) == statuses.map(\.id).sorted())
  }

  @Test func aLineIsTabSeparatedAndOmitsAnEmptyDetail() {
    #expect(Status.line(RuleStatus(id: "r", state: .missing, detail: "")) == "r\tmissing")
    #expect(Status.line(RuleStatus(id: "r", state: .stale, detail: "a < b")) == "r\tstale\ta < b")
  }
}
