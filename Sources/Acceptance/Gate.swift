import Foundation

/// The gate a check passes to be accepted. `verify` re-checks a stored folder from its files
/// alone, without running anything.
enum Gate {
  /// The problems that keep the folder's check from being accepted; none means it passes.
  ///
  /// - Parameters:
  ///   - folder: the rule's folder.
  ///   - rule: the rule in the spec now, or nil to leave the spec out.
  ///   - jq: compiles the check's expressions for the lint.
  static func problems(of folder: CheckFolder, for rule: Rule?, jq: some JQ) throws -> [String] {
    var problems: [String] = []
    guard folder.has(folder.check) else {
      return [
        folder.has(folder.ungated)
          ? "the rule is ungated: generation gave up and left no check"
          : "no check.json"
      ]
    }
    let data = try Data(contentsOf: folder.check)
    let checkSha = Digest.sha256(data)
    let check: Check
    do { check = try Check.decode(data) } catch { return ["check.json is not a check: \(error)"] }
    if let rule {
      problems += try Lint.problems(in: check, for: rule, jq: jq).map { "lint: \($0)" }
    }

    guard folder.has(folder.generation),
      let generation = try? folder.decode(Generation.self, at: folder.generation)
    else {
      return problems + ["generation.json is missing or does not decode"]
    }
    if generation.rule != check.rule {
      problems.append("generation.json is for \(generation.rule), the check for \(check.rule)")
    }
    if generation.checkSha256 != checkSha {
      problems.append("check.json is not the check generation.json recorded")
    }
    if let rule, generation.blockSha256 != rule.blockSha256 {
      problems.append("the rule's block differs from the one the check was generated from")
    }

    problems += provenance(of: generation, checkSha: checkSha)
    problems += review(of: folder, checkSha: checkSha, rule: check.rule)
    problems += replay(of: folder, checkSha: checkSha, rule: check.rule)
    problems += mutants(of: folder, checkSha: checkSha)
    return problems
  }

  private static func provenance(of generation: Generation, checkSha: String) -> [String] {
    func isDigest(_ value: String?) -> Bool {
      guard let value else { return false }
      return value.wholeMatch(of: /[0-9a-f]{64}/) != nil
    }
    guard let inputs = generation.inputs,
      ["cli.md", "format.md", "generate.md", "palantir-accept"].allSatisfy({ isDigest(inputs[$0]) }
      ),
      inputs.values.allSatisfy({ isDigest($0) }),
      let runs = generation.generatorRuns, let draft = runs.first, draft.kind == "draft",
      let rounds = generation.judgeRounds, let lastJudge = rounds.last
    else { return ["generation.json has missing or malformed input provenance"] }
    var problems: [String] = []
    for run in runs {
      if !run.inputs.values.allSatisfy({ isDigest($0) }) || !isDigest(run.inputs["prompt.md"])
        || run.inputs["rule.md"] != generation.blockSha256
        || run.inputs["cli.md"] != inputs["cli.md"]
        || run.inputs["format.md"] != inputs["format.md"]
      {
        problems.append(
          "generation.json generator inputs do not match its recorded rule and references")
        break
      }
    }
    if draft.inputs["prompt.md"] != inputs["generate.md"] {
      problems.append("generation.json draft prompt does not match its recorded generate.md")
    }
    for round in rounds {
      if !round.inputs.values.allSatisfy({ isDigest($0) })
        || !["prompt.md", "schema.json", "check.json"].allSatisfy({ isDigest(round.inputs[$0]) })
        || round.inputs["rule.md"] != generation.blockSha256
        || round.inputs["cli.md"] != inputs["cli.md"]
        || round.inputs["format.md"] != inputs["format.md"]
      {
        problems.append(
          "generation.json judge inputs do not match its recorded rule and references")
        break
      }
    }
    if lastJudge.inputs["check.json"] != checkSha {
      problems.append("generation.json final judge read another check.json")
    }
    return problems
  }

  private static func review(of folder: CheckFolder, checkSha: String, rule: String) -> [String] {
    guard folder.has(folder.review), let review = try? folder.decode(Review.self, at: folder.review)
    else { return ["review.json is missing or does not decode"] }
    var problems: [String] = []
    if review.rule != rule { problems.append("review.json is for \(review.rule)") }
    if review.checkSha256 != checkSha {
      problems.append("the review was made on another check.json")
    }
    if review.computedVerdict != .faithful {
      problems.append("the review has a blocking problem")
    }
    if review.verdict != review.computedVerdict {
      problems.append("review.json says \(review.verdict.rawValue) but its problems say otherwise")
    }
    return problems
  }

  private static func replay(of folder: CheckFolder, checkSha: String, rule: String) -> [String] {
    guard folder.has(folder.replay),
      let replay = try? folder.decode(ReplayReport.self, at: folder.replay)
    else { return ["replay.json is missing or does not decode"] }
    var problems: [String] = []
    if replay.rule != rule { problems.append("replay.json is for \(replay.rule)") }
    if replay.checkSha256 != checkSha { problems.append("replay.json ran another check.json") }
    if replay.verdict != .pass {
      problems.append("replay.json is a \(replay.verdict.rawValue), not a pass")
    }
    return problems
  }

  private static func mutants(of folder: CheckFolder, checkSha: String) -> [String] {
    let mutants = folder.mutants
    guard !mutants.isEmpty else { return ["no mutant: the check was never shown to fail one"] }
    var problems: [String] = []
    for mutant in mutants {
      let name = "mutants/\(mutant.lastPathComponent)"
      for file in ["mutant.patch", "mutant.json"]
      where !FileManager.default.fileExists(atPath: mutant.appending(path: file).path) {
        problems.append("\(name)/\(file) is missing")
      }
      guard
        let data = try? Data(contentsOf: mutant.appending(path: "replay.json")),
        let replay = try? JSONDecoder().decode(ReplayReport.self, from: data)
      else {
        problems.append("\(name)/replay.json is missing or does not decode")
        continue
      }
      if replay.checkSha256 != checkSha { problems.append("\(name) replayed another check.json") }
      let failure = replay.failure
      if replay.verdict != .fail || failure?.phase != .then || failure?.kind != "expect"
        || failure?.value != "false"
      {
        problems.append(
          "\(name) does not fail at a Then expectation printing false"
        )
      }
    }
    return problems
  }
}
