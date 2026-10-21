import Testing

@testable import PalantirAcceptance

@Suite(.layer(.unit))
struct UsageTests {
  @Test func noCommandIsAUsageError() {
    #expect(throws: Usage.self) { try run([]) }
  }

  @Test func anUnknownCommandIsAUsageError() {
    let error = #expect(throws: Usage.self) { try run(["frobnicate"]) }
    #expect(error?.message == "no command frobnicate")
  }
}

@Suite(.layer(.unit))
struct HelpTests {
  @Test func theUsageDescribesEveryCommand() {
    for name in commandNames {
      #expect(usage.contains("\n  \(name) ") || usage.contains("\n  \(name)\n"), "\(name)")
    }
  }

  @Test func everyCommandNameIsHandled() {
    for name in commandNames {
      // A command that is handled complains about its arguments; an unknown one says it has none.
      let error = #expect(throws: (any Error).self) { try run([name, "--no-such-option"]) }
      #expect((error as? Usage)?.message != "no command \(name)", "\(name)")
    }
  }

  @Test func helpPrintsAndThrowsNothing() throws {
    try run(["--help"])
  }
}
