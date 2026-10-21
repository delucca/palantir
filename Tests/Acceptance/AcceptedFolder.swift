import Foundation
import Testing

@testable import PalantirAcceptance

/// A rule's folder as generation leaves it, built from the accepted fold check.
struct AcceptedFolder {
  let checks: URL
  let rule: Rule
  var folder: CheckFolder { CheckFolder(rule: rule, in: checks) }
  let checkText: String

  init() throws {
    checks = FileManager.default.temporaryDirectory.appending(path: "checks-\(UUID().uuidString)")
    let rules = try Spec.rules(in: repositoryRoot.appending(path: "spec/features"))
    rule = try #require(rules.first { $0.id == "req~heading-folding.fold~1" })
    checkText = try String(contentsOf: fixtures.appending(path: "fold-check.json"), encoding: .utf8)
    try write()
  }

  /// Writes the whole folder; `edit` may change any part first.
  func write(
    review: (inout Review) -> Void = { _ in }, base: (inout ReplayReport) -> Void = { _ in },
    mutant: (inout ReplayReport) -> Void = { _ in }
  ) throws {
    let folder = self.folder
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    let data = Data(checkText.utf8)
    let sha = Digest.sha256(data)
    try data.write(to: folder.check)
    try encode(
      Generation(
        rule: rule.id, checkSha256: sha, blockSha256: rule.blockSha256,
        inputs: ["cli.md": sha, "format.md": sha, "generate.md": sha, "palantir-accept": sha],
        generatorRuns: [
          GeneratorRunRecord(
            kind: "draft",
            inputs: [
              "rule.md": rule.blockSha256, "cli.md": sha, "format.md": sha, "prompt.md": sha,
            ], seconds: 1, log: "draft.jsonl", logSha256: sha, toolCalls: [])
        ],
        judgeRounds: [
          JudgeRoundRecord(
            verdict: "faithful", seconds: 1, logSha256: sha,
            inputs: [
              "rule.md": rule.blockSha256, "cli.md": sha, "format.md": sha,
              "prompt.md": sha, "schema.json": sha, "check.json": sha,
            ])
        ]),
      to: folder.generation)
    var reviewed = Review(
      rule: rule.id, verdict: .faithful,
      lines: rule.exampleLines.map {
        Review.Line(line: $0, faithful: true, problems: [])
      }, summary: "faithful", checkSha256: sha)
    review(&reviewed)
    try encode(reviewed, to: folder.review)
    var passed = Self.report(rule: rule.id, sha: sha, verdict: .pass, failure: nil)
    base(&passed)
    try encode(passed, to: folder.replay)
    let mutantFolder = folder.url.appending(path: "mutants/1")
    try FileManager.default.createDirectory(at: mutantFolder, withIntermediateDirectories: true)
    try Data("diff".utf8).write(to: mutantFolder.appending(path: "mutant.patch"))
    try Data("{}".utf8).write(to: mutantFolder.appending(path: "mutant.json"))
    var failed = Self.report(
      rule: rule.id, sha: sha, verdict: .fail,
      failure: Failure(step: 3, phase: .then, kind: "expect", that: "x", value: "false"))
    mutant(&failed)
    try encode(failed, to: mutantFolder.appending(path: "replay.json"))
  }

  static func report(rule: String, sha: String, verdict: Verdict, failure: Failure?) -> ReplayReport
  {
    ReplayReport(
      rule: rule, verdict: verdict, failure: failure, steps: [], check: "check.json",
      checkSha256: sha,
      cliSha256: [:], jq: "jq-1.7.1-apple", machine: Machine(host: "h", macos: "m"), seconds: 1,
      modelCalls: 0, subprocesses: [])
  }

  func encode<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url)
  }

  func remove() { try? FileManager.default.removeItem(at: checks) }
}
