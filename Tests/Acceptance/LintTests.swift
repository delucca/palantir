import Foundation
import Testing

@testable import PalantirAcceptance

/// A jq that finds a compile error in any expression holding "BAD".
struct FakeJQ: JQ {
  func compileError(_ expression: String) throws -> String? {
    expression.contains("BAD") ? "syntax error" : nil
  }
}

@Suite(.layer(.unit))
struct LintTests {
  static let rule: Rule = {
    let rules = try? Spec.rules(in: repositoryRoot.appending(path: "spec/features"))
    return rules!.first { $0.id == "req~heading-folding.fold~1" }!
  }()

  /// The fold check with `edit` applied to its JSON text.
  static func fold(_ edit: (String) -> String = { $0 }) throws -> Data {
    Data(edit(try String(contentsOf: CheckTests.fold, encoding: .utf8)).utf8)
  }

  static func problems(_ data: Data) throws -> [String] {
    try Lint.problems(in: data, for: rule, jq: FakeJQ())
  }

  @Test func quittingRequiresANewLaunchAndRepeatBodiesCannotReuseObservationNames() throws {
    let launch = "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}"
    for tail in [
      "{\"inspect\": [\"state\"]}", "{\"drive\": [\"menu\", \"x\"]}", "{\"quit\": true}",
    ] {
      #expect(
        try lint("\(launch), {\"quit\": true}, \(tail)").contains {
          $0.contains("before any launch")
        })
    }
    let observe = "{\"inspect\": [\"state\"], \"as\": \"s\"}"
    #expect(
      try lint("\(launch), \(observe), {\"repeat\": [\(observe)], \"until\": \"true\"}").contains {
        $0.contains("used twice")
      })
    #expect(
      try lint("\(launch), {\"repeat\": [\(observe), \(observe)], \"until\": \"true\"}").contains {
        $0.contains("used twice")
      })
    #expect(try lint("\(launch), {\"repeat\": [\(observe)], \"until\": \"true\"}").isEmpty)
  }

  @Test func theAcceptedFoldCheckIsClean() throws {
    #expect(try Self.problems(Self.fold()) == [])
  }

  @Test func aCheckForAnotherRuleIsNamed() throws {
    let problems = try Self.problems(
      Self.fold {
        $0.replacingOccurrences(
          of: "req~heading-folding.fold~1", with: "req~heading-folding.fold~2")
      })
    #expect(problems.contains("rule is req~heading-folding.fold~2, not req~heading-folding.fold~1"))
  }

  @Test func aStepLineThatDiffersFromTheExampleIsFlagged() throws {
    let problems = try Self.problems(
      Self.fold {
        $0.replacingOccurrences(of: "shows the folded marker\"", with: "shows a marker\"")
      })
    #expect(problems.contains { $0.contains("steps' lines") })
  }

  @Test func aMissingStepIsFlagged() throws {
    let data = Data(
      #"{"format": 1, "rule": "req~heading-folding.fold~1", "example": "folding a task", "files": {}, "steps": []}"#
        .utf8)
    #expect(try Self.problems(data).contains { $0.contains("steps' lines") })
  }

  @Test func aBadExpressionInTheFoldCheckIsFlaggedWhereItIs() throws {
    let problems = try Self.problems(
      Self.fold {
        $0.replacingOccurrences(of: ".opened.json.sections.notebook.length", with: "BAD")
      })
    #expect(problems.contains { $0.hasPrefix("jq does not compile: ") && $0.contains("BAD") })
  }

  private func lint(_ actions: String, files: String = "{}", expect: String = "[]") throws
    -> [String]
  {
    let rule = try #require(
      try Spec.parse("## Rule: A\n`req~a.b~1`\n### Example: x\n* Given x\n", file: "a").first)
    return try Lint.problems(
      in: CheckTests.check(actions: actions, files: files, expect: expect), for: rule, jq: FakeJQ())
  }

  @Test func ajqExpressionInAnActionOrAnExpectationIsCompiled() throws {
    #expect(
      try lint("{\"quit\": true}", expect: "[{\"that\": \"BAD\"}]").contains { $0.contains("BAD") })
    #expect(
      try lint(
        "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}, {\"drive\": [{\"jq\": \"BAD\"}]}"
      )
      .contains { $0.contains("BAD") })
    #expect(
      try lint(
        "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}, {\"repeat\": [{\"sleep\": 1}], \"until\": \"BAD\"}"
      ).contains { $0.contains("BAD") })
  }

  @Test func aDriveBeforeAnyLaunchIsFlaggedButInspectListIsNot() throws {
    #expect(try lint("{\"drive\": [\"menus\"]}").contains("drive comes before any launch"))
    #expect(try lint("{\"inspect\": [\"state\"]}").contains("inspect comes before any launch"))
    #expect(try lint("{\"inspect\": [\"list\"]}").isEmpty)
  }

  @Test func aFixtureThatIsNotDefinedIsFlagged() throws {
    #expect(try lint("{\"file\": \"n.md\"}").contains("no fixture named \"n.md\""))
    #expect(try lint("{\"stat\": {\"file\": \"n.md\"}}").contains("no fixture named \"n.md\""))
    #expect(try lint("{\"file\": \"n.md\"}", files: "{\"n.md\": \"x\"}").isEmpty)
  }

  @Test func aFixtureNameWithAFolderIsFlagged() throws {
    #expect(try lint("{\"quit\": true}", files: "{\"a/b.md\": \"x\"}").count == 2)
  }

  @Test func anObservationNameIsUniqueAndNotARecordKey() throws {
    let launch = "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}"
    #expect(
      try lint(
        "\(launch), {\"inspect\": [\"state\"], \"as\": \"s\"}, {\"inspect\": [\"state\"], \"as\": \"s\"}"
      )
      .contains("the observation name \"s\" is used twice"))
    #expect(
      try lint("{\"sleep\": 1, \"as\": \"pid\"}").contains(
        "the observation name \"pid\" is a key of the record"))
    #expect(try lint("{\"sleep\": 1, \"as\": \"1x\"}").count == 1)
  }

  @Test func aRepeatBodyMayReuseItsNameAcrossRounds() throws {
    let launch = "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}"
    #expect(
      try lint(
        "\(launch), {\"repeat\": [{\"inspect\": [\"state\"], \"as\": \"s\"}], \"until\": \"true\"}"
      ).isEmpty)
  }

  @Test func sleepAndRepeatStayWithinTheirLimits() throws {
    #expect(try lint("{\"sleep\": 6}").count == 1)
    #expect(
      try lint("{\"repeat\": [{\"sleep\": 1}], \"until\": \"true\", \"max\": 201}").count == 1)
    #expect(try lint("{\"repeat\": [{\"sleep\": 1}], \"until\": \"true\", \"max\": 0}").count == 1)
  }

  @Test func anOutNameIsAPngFileNameUsedOnce() throws {
    let launch = "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}"
    #expect(
      try lint("\(launch), {\"inspect\": [\"screenshot\", {\"out\": \"a/b.png\"}]}").count == 1)
    #expect(try lint("\(launch), {\"inspect\": [\"screenshot\", {\"out\": \"a.txt\"}]}").count == 1)
    #expect(
      try lint(
        "\(launch), {\"inspect\": [\"screenshot\", {\"out\": \"a.png\"}]}, {\"inspect\": [\"screenshot\", {\"out\": \"a.png\"}]}"
      )
      .contains("the out name \"a.png\" is used twice"))
  }

  @Test func textThatIsNotACheckIsOneProblem() throws {
    let problems = try Self.problems(Data("{}".utf8))
    #expect(problems.count == 1 && problems[0].hasPrefix("not a check"))
  }

  // A rule whose example has a Given and a Then line.
  private func lintThen(_ given: String, _ then: String) throws -> [String] {
    let rule = try #require(
      try Spec.parse(
        "## Rule: A\n`req~a.b~1`\n### Example: x\n* Given x\n* Then y\n", file: "a"
      ).first)
    let data = Data(
      """
      {"format": 1, "rule": "req~a.b~1", "example": "x", "files": {},
       "steps": [{"line": "* Given x", "do": [\(given)], "expect": []},
                 {"line": "* Then y", "do": [\(then)], "expect": []}]}
      """.utf8)
    return try Lint.problems(in: data, for: rule, jq: FakeJQ())
  }

  @Test func aNonZeroExpectedExitIsRightForSetupAndWrongInAThenStep() throws {
    let launch = "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}"
    let state = "{\"inspect\": [\"state\"], \"exit\": 2}"
    #expect(try lintThen("\(launch), \(state)", "{\"sleep\": 0}").isEmpty)
    let found = try lintThen(launch, state)
    #expect(found.count == 1 && found[0].contains("a Then step expects exit 2"))
    #expect(
      try lintThen(launch, "{\"inspect\": [\"state\"], \"exit\": \"any\", \"as\": \"s\"}").isEmpty)
  }
}
