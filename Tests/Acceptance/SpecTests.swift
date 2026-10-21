import Foundation
import Testing

@testable import PalantirAcceptance

/// The repository, found from this file.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

/// The fixtures the runner's own tests read.
let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(
  path: "Fixtures")

@Suite(.layer(.unit))
struct SpecTests {
  static let sample = fixtures.appending(path: "spec/features")

  @Test func aRuleIsItsHeadingIDAndExampleWithoutProvenanceLines() throws {
    let rules = try Spec.rules(in: Self.sample)
    let rule = try #require(rules.first { $0.id == "req~sample.thing~1" })
    #expect(rule.block.hasPrefix("## Rule: A thing shall happen\n`req~sample.thing~1`\n"))
    #expect(!rule.block.contains("From:"))
    #expect(!rule.block.contains("Decided in:"))
    #expect(rule.block.hasSuffix("* But nothing else does"))
    #expect(rule.feature == "sample" && rule.slug == "thing" && rule.version == 1)
    #expect(rule.exampleTitle == "a thing happens")
    #expect(rule.blockSha256.count == 64)
  }

  @Test func theExampleLinesAreTheStarLinesAndTheirPhasesFollowAnd() throws {
    let rule = try #require(try Spec.rules(in: Self.sample).first { $0.slug == "thing" })
    #expect(rule.exampleLines.count == 5)
    #expect(try rule.phases() == [.given, .given, .when, .then, .then])
  }

  @Test func aTableUnderALineBelongsToTheLine() throws {
    let rule = try #require(try Spec.rules(in: Self.sample).first { $0.slug == "other" })
    #expect(rule.exampleLines == ["* Given a table", "* Then it is read"])
    #expect(rule.block.contains("  | 1 | 2 |"))
    #expect(rule.version == 2)
  }

  @Test func rulesComeSortedByID() throws {
    #expect(
      try Spec.rules(in: Self.sample).map(\.id) == ["req~sample.other~2", "req~sample.thing~1"])
  }

  @Test func theBlockDigestChangesWithAnyWordOfTheBlock() throws {
    let text = try String(contentsOf: Self.sample.appending(path: "sample.md"), encoding: .utf8)
    let before = try Spec.parse(text, file: "sample")
    let after = try Spec.parse(
      text.replacingOccurrences(of: "the thing happens", with: "the thing happened"), file: "sample"
    )
    #expect(before[0].blockSha256 != after[0].blockSha256)
    #expect(before[1].blockSha256 == after[1].blockSha256)
  }

  @Test func aRuleWithoutAnIDLineIsAnError() {
    #expect(throws: SpecError.self) {
      try Spec.parse("## Rule: Nothing\n\n### Example: none\n", file: "sample")
    }
  }

  @Test func aRuleInAnotherFeaturesFileIsAnError() {
    #expect(throws: SpecError.self) {
      try Spec.parse("## Rule: A\n`req~other.a~1`\n", file: "sample")
    }
  }

  @Test func anExampleLineWithoutGivenWhenOrThenIsAnError() throws {
    let rule = try #require(
      try Spec.parse("## Rule: A\n`req~sample.a~1`\n* Maybe this\n", file: "sample").first)
    #expect(throws: SpecError.self) { try rule.phases() }
  }

  // req~acceptance.every-rule~1
  @Test func theRealSpecHasTwentyOneCheckedRulesAndEveryRuleIsFound() throws {
    let rules = try Spec.rules(in: repositoryRoot.appending(path: "spec/features"))
    #expect(rules.count == 29)
    let checked = rules.filter(\.isChecked)
    #expect(checked.count == 21)
    #expect(rules.filter { $0.feature == "acceptance" }.count == 7)
    #expect(rules.contains { $0.id == "req~inspector.notebook-state~1" && !$0.isChecked })
    #expect(checked.allSatisfy { !$0.exampleLines.isEmpty && $0.exampleTitle != nil })
    #expect(try checked.allSatisfy { try !$0.phases().isEmpty })
  }
}
