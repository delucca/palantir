import Foundation
import Testing

@testable import PalantirAcceptance

/// What the generator and the judge are told must match what the tools print and what the
/// runner does.
@Suite(.layer(.unit))
struct CLIReferenceTests {
  /// The text of the `let usage = """…"""` literal in a Swift source, indentation removed.
  func usage(in path: String) throws -> String {
    let source = try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    let lines = source.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex { $0.contains("let usage = \"\"\"") })
    let end = try #require(
      lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "\"\"\"" })
    let indent = lines[end].prefix { $0 == " " }.count
    return lines[(start + 1)..<end].map {
      String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count)))
    }
    .joined(separator: "\n")
  }

  @Test func theReferenceHoldsTheDriversUsageVerbatim() throws {
    let text = try usage(in: "Sources/Driver/main.swift")
    #expect(try Resources.text("cli.md").contains(text))
  }

  @Test func theReferenceHoldsTheInspectorsUsageVerbatim() throws {
    let text = try usage(in: "Sources/Inspector/CLI/main.swift")
    #expect(try Resources.text("cli.md").contains(text))
  }

  @Test func theFormatReferenceNamesEveryAction() throws {
    let format = try Resources.text("format.md")
    for verb in [
      "launch", "drive", "inspect", "file", "stat", "symbols", "sleep", "quit", "repeat",
    ] {
      #expect(format.contains("| `{\"\(verb)\":"), "\(verb)")
    }
    for argument in ["{\"file\"", "{\"out\"", "{\"jq\""] {
      #expect(format.contains(argument), "\(argument)")
    }
    #expect(format.contains("\"rule\": \"req~<feature>.<slug>~<version>\""))
  }

  @Test func theReferenceStatesTheTwoInstrumentFactsAndNoRuleOutcome() throws {
    let cli = try Resources.text("cli.md")
    #expect(cli.contains("What the tools show, for every check alike"))
    #expect(cli.contains("The state holds no outline"))
    #expect(cli.contains("enabled state is right only while palantir is in front"))
  }

  @Test func theJudgeSchemaIsTheReviewTheCodeDecodes() throws {
    let schema =
      try JSONSerialization.jsonObject(
        with: Data(Resources.text("judge.schema.json").utf8)) as? [String: Any]
    #expect(
      (schema?["required"] as? [String])?.sorted() == ["lines", "rule", "summary", "verdict"])
  }
}

@Suite(.layer(.unit))
struct JudgePromptTests {
  @Test func theJudgePromptBlocksOnlyWhatTheToolsCouldHaveCaught() throws {
    let prompt = try Resources.text("judge.md")
    #expect(prompt.contains("blocking only if a check written with the same two tools"))
    #expect(prompt.contains("advisory, never blocking"))
    #expect(prompt.contains("A check that misses something the tools do expose stays blocking"))
  }

  @Test func theJudgePromptJudgesTheChecksOwnSituation() throws {
    let prompt = try Resources.text("judge.md")
    #expect(prompt.contains("Judge the check for the situation it sets up itself"))
    #expect(prompt.contains("another fixture,\nanother window size"))
    #expect(prompt.contains("samples that can skip\ntext between two scrolls"))
  }
}
