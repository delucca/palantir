import Foundation
import Testing

@testable import PalantirAcceptance

@Suite(.layer(.unit))
struct GateTests {
  func problems(_ accepted: AcceptedFolder) throws -> [String] {
    try Gate.problems(of: accepted.folder, for: accepted.rule, jq: FakeJQ())
  }

  // req~acceptance.gate~1
  @Test func anAcceptedFolderPasses() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    #expect(try problems(accepted) == [])
  }

  // req~acceptance.gate~1
  @Test func aCheckEditedAfterItsGateFailsOnEveryFileMadeOnTheOldOne() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try Data((accepted.checkText + "\n").utf8).write(to: accepted.folder.check)
    let found = try problems(accepted)
    #expect(found.contains("check.json is not the check generation.json recorded"))
    #expect(found.contains("the review was made on another check.json"))
    #expect(found.contains("replay.json ran another check.json"))
    #expect(found.contains("mutants/1 replayed another check.json"))
  }

  // req~acceptance.gate~1
  @Test func missingMalformedAndInconsistentGenerationInputsAreRefused() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let original = try accepted.folder.decode(Generation.self, at: accepted.folder.generation)
    let changes: [(inout Generation) -> Void] = [
      { $0.inputs = nil },
      { $0.inputs?["palantir-accept"] = nil },
      { $0.inputs?["cli.md"] = "not a sha256" },
      { $0.generatorRuns = [] },
      { $0.generatorRuns?[0].inputs["rule.md"] = String(repeating: "0", count: 64) },
      { $0.inputs?["generate.md"] = String(repeating: "0", count: 64) },
      { $0.judgeRounds = nil },
      { $0.judgeRounds?[0].inputs["check.json"] = String(repeating: "0", count: 64) },
    ]
    for change in changes {
      var altered = original
      change(&altered)
      try accepted.encode(altered, to: accepted.folder.generation)
      #expect(try problems(accepted).contains { $0.hasPrefix("generation.json") })
    }
    try accepted.encode(original, to: accepted.folder.generation)
    #expect(try problems(accepted).isEmpty)
  }

  @Test func aReviewMadeOnAnotherCheckFails() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try accepted.write(review: { $0.checkSha256 = "0000" })
    #expect(try problems(accepted) == ["the review was made on another check.json"])
  }

  // req~acceptance.gate~1
  @Test func aBlockingProblemFailsEvenWhenTheJudgeSaidFaithful() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try accepted.write(review: {
      $0.lines[0].problems = [.init(severity: .blocking, at: "x", problem: "p")]
    })
    #expect(
      try problems(accepted) == [
        "the review has a blocking problem",
        "review.json says faithful but its problems say otherwise",
      ])
  }

  @Test func anAdvisoryProblemDoesNotFail() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try accepted.write(review: {
      $0.lines[0].problems = [.init(severity: .advisory, at: "x", problem: "p")]
    })
    #expect(try problems(accepted) == [])
  }

  @Test func aBasePassThatFailedIsRefused() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try accepted.write(base: { $0.verdict = .fail })
    #expect(try problems(accepted) == ["replay.json is a fail, not a pass"])
  }

  // req~acceptance.gate~1
  @Test func aMutantMustFailAtAThenExpectationPrintingFalse() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let bad = "mutants/1 does not fail at a Then expectation printing false"
    try accepted.write(mutant: { $0.failure?.kind = "action" })
    #expect(try problems(accepted) == [bad])
    try accepted.write(mutant: { $0.failure?.value = "error: jq broke" })
    #expect(try problems(accepted) == [bad])
    try accepted.write(mutant: { $0.failure?.phase = .when })
    #expect(try problems(accepted) == [bad])
    try accepted.write(mutant: { $0.verdict = .error })
    #expect(try problems(accepted) == [bad])
  }

  @Test func aFolderWithNoMutantIsRefused() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try FileManager.default.removeItem(at: accepted.folder.url.appending(path: "mutants"))
    #expect(try problems(accepted) == ["no mutant: the check was never shown to fail one"])
  }

  @Test func aMutantMissingItsPatchIsRefused() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try FileManager.default.removeItem(
      at: accepted.folder.url.appending(path: "mutants/1/mutant.patch"))
    #expect(try problems(accepted) == ["mutants/1/mutant.patch is missing"])
  }

  @Test func aRuleWhoseBlockChangedIsRefused() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let changed = Rule(
      id: accepted.rule.id, feature: accepted.rule.feature, slug: accepted.rule.slug,
      version: 1, block: accepted.rule.block + " ", exampleTitle: accepted.rule.exampleTitle,
      exampleLines: accepted.rule.exampleLines)
    let found = try Gate.problems(of: accepted.folder, for: changed, jq: FakeJQ())
    #expect(found == ["the rule's block differs from the one the check was generated from"])
  }

  @Test func aLintProblemIsAGateProblem() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    let found = try Gate.problems(of: accepted.folder, for: accepted.rule, jq: AlwaysBadJQ())
    #expect(found.contains { $0.hasPrefix("lint: jq does not compile") })
  }

  // req~acceptance.gate~1
  @Test func anUngatedFolderHasNoAcceptedCheck() throws {
    let accepted = try AcceptedFolder()
    defer { accepted.remove() }
    try FileManager.default.removeItem(at: accepted.folder.check)
    try Data("{}".utf8).write(to: accepted.folder.ungated)
    #expect(
      try problems(accepted) == ["the rule is ungated: generation gave up and left no check"])
  }
}

struct AlwaysBadJQ: JQ {
  func compileError(_ expression: String) throws -> String? { "bad" }
}
