import Foundation
import Testing

@testable import PalantirAcceptance

@Suite(.layer(.unit))
struct CheckTests {
  static let fold = fixtures.appending(path: "fold-check.json")

  /// A one-step check around `actions`, as JSON text.
  static func check(
    actions: String, extra: String = "", files: String = "{}", expect: String = "[]"
  ) -> Data {
    Data(
      """
      {"format": 1, "rule": "req~a.b~1", "example": "x", "files": \(files)\(extra),
       "steps": [{"line": "* Given x", "do": [\(actions)], "expect": \(expect)}]}
      """.utf8)
  }

  @Test func theAcceptedFoldCheckDecodes() throws {
    let check = try Check.decode(Data(contentsOf: Self.fold))
    #expect(check.rule == "req~heading-folding.fold~1")
    #expect(check.steps.count == 6)
    #expect(check.steps[0].actions.first?.verb == .launch(build: .debug, inspector: true))
    #expect(check.files["notebook.md"] == "# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\n")
  }

  @Test func everyActionVerbDecodes() throws {
    let check = try Check.decode(
      Self.check(
        actions: """
          {"launch": {"build": "release", "inspector": false}, "as": "l"},
          {"drive": ["click", 3, {"jq": ".pid"}, {"file": "n.md"}, {"out": "a.png"}], "exit": 1},
          {"inspect": ["state"], "as": "s"}, {"file": "n.md", "as": "f"},
          {"stat": "/tmp"}, {"symbols": "release"}, {"sleep": 0.5}, {"quit": true},
          {"repeat": [{"sleep": 1}], "until": "true", "max": 3}
          """, files: "{\"n.md\": \"x\"}"))
    let actions = check.steps[0].actions
    #expect(actions.count == 9)
    #expect(actions[0].name == "l")
    #expect(
      actions[1].verb
        == .drive([.text("click"), .number(3), .jq(".pid"), .file("n.md"), .out("a.png")]))
    #expect(actions[1].exit == 1)
    #expect(actions[4].verb == .stat(.text("/tmp")))
    #expect(
      actions[8].verb == .repeat(body: [Action(verb: .sleep(1))], until: "true", max: 3))
  }

  @Test func aRepeatWithoutMaxRunsTheDefaultRounds() throws {
    let check = try Check.decode(
      Self.check(actions: "{\"repeat\": [{\"quit\": true}], \"until\": \"true\"}"))
    guard case .repeat(_, _, let max) = check.steps[0].actions[0].verb else {
      Issue.record("not a repeat")
      return
    }
    #expect(max == Settings.repeatDefault)
  }

  @Test func anUnknownKeyAtTheTopFails() {
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "", extra: ", \"note\": 1"))
    }
  }

  @Test func anUnknownKeyInAStepFails() {
    let data = Data(
      """
      {"format": 1, "rule": "r", "example": "x", "files": {},
       "steps": [{"line": "l", "do": [], "expect": [], "why": "y"}]}
      """.utf8)
    #expect(throws: CheckError.self) { try Check.decode(data) }
  }

  @Test func anUnknownKeyInAnExpectationFails() {
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "", expect: "[{\"that\": \"true\", \"because\": 1}]"))
    }
  }

  @Test func anUnknownKeyInAnActionFails() {
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "{\"quit\": true, \"wait\": 1}"))
    }
  }

  @Test func anActionNamingTwoVerbsOrNoneFails() {
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "{\"quit\": true, \"sleep\": 1}"))
    }
    #expect(throws: CheckError.self) { try Check.decode(Self.check(actions: "{\"as\": \"x\"}")) }
  }

  @Test func anArgumentWithAnUnknownKeyFails() {
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "{\"drive\": [{\"path\": \"x\"}]}"))
    }
  }

  @Test func aFormatOtherThanOneFails() {
    let data = Data(
      #"{"format": 2, "rule": "r", "example": "x", "files": {}, "steps": []}"#.utf8)
    #expect(throws: (any Error).self) { try Check.decode(data) }
  }

  @Test func aMissingKeyNamesWhereDecodingStopped() {
    let data = Data(#"{"format": 1, "rule": "r", "files": {}, "steps": []}"#.utf8)
    let error = #expect(throws: CheckError.self) { try Check.decode(data) }
    #expect(error?.description.contains("example") == true)
  }

  @Test func untilBelongsToRepeatOnly() {
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "{\"quit\": true, \"until\": \"true\"}"))
    }
  }

  @Test func exitAnyNeedsAnAsAndOtherStringsAreRefused() throws {
    let ok = try Check.decode(
      Self.check(actions: "{\"sleep\": 0, \"exit\": \"any\", \"as\": \"s\"}"))
    #expect(ok.steps[0].actions[0].exit == .any)
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "{\"sleep\": 0, \"exit\": \"any\"}"))
    }
    #expect(throws: CheckError.self) {
      try Check.decode(Self.check(actions: "{\"sleep\": 0, \"exit\": \"some\", \"as\": \"s\"}"))
    }
  }

  @Test func aCheckUsesReleaseOnlyThroughALaunchOrSymbolsOfTheReleaseBuild() throws {
    func uses(_ actions: String) throws -> Bool {
      try Check.decode(Self.check(actions: actions)).usesRelease
    }
    #expect(try !uses("{\"launch\": {\"build\": \"debug\", \"inspector\": true}}"))
    #expect(try uses("{\"launch\": {\"build\": \"release\", \"inspector\": true}}"))
    #expect(try uses("{\"symbols\": \"release\"}"))
    #expect(try !uses("{\"symbols\": \"debug\"}"))
    #expect(try uses("{\"repeat\": [{\"symbols\": \"release\"}], \"until\": \"true\"}"))
  }
}
