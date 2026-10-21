import Foundation

/// One rule's line in `test-acceptance`: the rule, a word, and what it adds.
struct RuleVerdict: Equatable {
  var id: String
  /// `pass`, `fail` or `error` for a replayed check; `missing`, `ungated`, `stale`, `changed` or
  /// `orphan` for a rule that has no current check to replay.
  var word: String
  var detail: String

  var line: String { [id, word, detail].filter { !$0.isEmpty }.joined(separator: "\t") }
}

/// `replay --all`: a verdict for every rule, and no rule left out.
enum ReplayAll {
  /// Replays the check of every current rule and gives every other rule the word that says why it
  /// has none. A rule with a `missing`, `ungated`, `stale`, `changed` or `orphan` check is never
  /// replayed as if it were current.
  static func run(
    rules: [Rule], checks: URL, jq: some JQ,
    replay: (_ rule: Rule, _ check: URL) throws -> ReplayReport
  ) throws -> [RuleVerdict] {
    let statuses = try Status.of(rules: rules, checks: checks, jq: jq)
    return try statuses.map { status in
      guard status.state == .current, let rule = Spec.rule(status.id, in: rules) else {
        return RuleVerdict(id: status.id, word: status.state.rawValue, detail: status.detail)
      }
      let report = try replay(rule, CheckFolder(rule: rule, in: checks).check)
      return RuleVerdict(id: rule.id, word: report.verdict.rawValue, detail: detail(of: report))
    }
  }

  /// What follows the word: the seconds of a pass; where a fail stopped; why an error ended.
  static func detail(of report: ReplayReport) -> String {
    switch report.verdict {
    case .pass: return String(format: "%.1fs", report.seconds)
    case .fail:
      guard let failure = report.failure, let step = failure.step, let phase = failure.phase,
        step < report.steps.count
      else { return report.failure?.message ?? "" }
      return "\(phase.rawValue) step \(step): \(report.steps[step].line)"
    case .error:
      return report.failure.map { "\($0.kind): \($0.message ?? "")" } ?? ""
    }
  }

  /// `21 rules: 1 pass, 20 missing`.
  static func summary(_ verdicts: [RuleVerdict]) -> String {
    let order = [
      "pass", "current", "fail", "error", "missing", "ungated", "stale", "changed", "orphan",
    ]
    let parts = order.compactMap { word -> String? in
      let count = verdicts.filter { $0.word == word }.count
      return count == 0 ? nil : "\(count) \(word)"
    }
    return "\(verdicts.count) rules: \(parts.joined(separator: ", "))"
  }

  /// 0 when every rule passed, 2 when any replay ended with no verdict, otherwise 1.
  static func exitCode(_ verdicts: [RuleVerdict]) -> Int32 {
    if verdicts.contains(where: { $0.word == "error" }) { return 2 }
    return verdicts.allSatisfy { $0.word == "pass" } ? 0 : 1
  }
}

/// The file `replay --all --json` writes, for `compare`.
struct VerdictsFile: Codable, Equatable {
  struct Build: Codable, Equatable {
    var debugAppSha256: String?
    var releaseAppSha256: String?
  }

  var build: Build
  /// The machine the replays ran on.
  var machine: Machine
  /// For a replay in a VM: the machine that hosted it.
  var host: Machine? = nil
  var verdicts: [String: String]
}
