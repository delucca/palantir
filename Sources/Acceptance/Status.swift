import Foundation

/// Where a rule's check stands against the spec.
enum RuleState: String, Equatable {
  /// An accepted check made from the rule's block as it is now.
  case current
  case missing
  /// The check cites an older version of the rule.
  case stale
  /// The rule's text changed under the same version.
  case changed
  /// Generation gave up, or the folder no longer passes the gate: no accepted check.
  case ungated
  /// A check folder whose rule is gone.
  case orphan
}

struct RuleStatus: Equatable {
  var id: String
  var state: RuleState
  var detail: String
}

enum Status {
  /// One status for each checked rule of `rules`, then one for each orphan folder, sorted by ID.
  static func of(rules: [Rule], checks: URL, jq: some JQ) throws -> [RuleStatus] {
    let checked = rules.filter(\.isChecked)
    var statuses = try checked.map { try status(of: $0, checks: checks, jq: jq) }
    let known = Set(checked.map { "\($0.feature)/\($0.slug)" })
    for (feature, slug) in CheckFolder.all(in: checks) where !known.contains("\(feature)/\(slug)") {
      let folder = CheckFolder(checks.appending(path: feature).appending(path: slug))
      statuses.append(
        RuleStatus(
          id: id(in: folder) ?? "req~\(feature).\(slug)~?", state: .orphan,
          detail: "no rule \(feature).\(slug) in the spec"))
    }
    return statuses.sorted { $0.id < $1.id }
  }

  static func status(of rule: Rule, checks: URL, jq: some JQ) throws -> RuleStatus {
    let folder = CheckFolder(rule: rule, in: checks)
    func make(_ state: RuleState, _ detail: String = "") -> RuleStatus {
      RuleStatus(id: rule.id, state: state, detail: detail)
    }
    guard folder.exists, folder.has(folder.check) || folder.has(folder.ungated) else {
      return make(.missing)
    }
    if let cited = id(in: folder), let version = RuleID.version(of: cited),
      version < rule.version
    {
      return make(.stale, "\(version) < \(rule.version)")
    }
    if let generation = try? folder.decode(Generation.self, at: folder.generation),
      generation.blockSha256 != rule.blockSha256
    {
      return make(.changed, "block digest differs")
    }
    if folder.has(folder.ungated), !folder.has(folder.check) {
      let stage = (try? folder.decode(Ungated.self, at: folder.ungated))?.stage ?? "unknown"
      return make(.ungated, stage)
    }
    let problems = try Gate.problems(of: folder, for: rule, jq: jq)
    if let first = problems.first { return make(.ungated, "gate: \(first)") }
    return make(.current)
  }

  /// The rule ID a folder's check, or else its ungated.json, names.
  private static func id(in folder: CheckFolder) -> String? {
    if let data = try? Data(contentsOf: folder.check), let check = try? Check.decode(data) {
      return check.rule
    }
    return (try? folder.decode(Ungated.self, at: folder.ungated))?.rule
  }

  /// A status as one tab-separated line.
  static func line(_ status: RuleStatus) -> String {
    [status.id, status.state.rawValue, status.detail].filter { !$0.isEmpty }.joined(separator: "\t")
  }
}
