import Foundation

enum Blame: String, Codable, Equatable {
  case palantir, check
}

/// The model's verdict on a failed replay, `triage.schema.json`.
struct TriageVerdict: Codable, Equatable {
  struct Observation: Codable, Equatable {
    /// A jq path into `record.json`.
    var path: String
    /// Its value as compact JSON.
    var value: String
  }

  var rule: String
  var blame: Blame
  var line: String
  var expectation: String
  var observed: [Observation]
  var reason: String
}

enum Triage {
  /// What a replay's result lets triage do.
  enum Kind: Equatable {
    /// The replay passed: nothing to triage.
    case passed
    /// The replay ended with no verdict: never triaged, rerun and reported.
    case noVerdict
    /// A Given or When step failed: the check's setup, not a rule's outcome.
    case setup
    /// A Then step failed, by an expectation (`expect`) or by an action (`action`).
    case outcome
  }

  static func classify(_ report: ReplayReport) -> Kind {
    switch report.verdict {
    case .pass: return .passed
    case .error: return .noVerdict
    case .fail:
      guard let failure = report.failure, let phase = failure.phase else { return .noVerdict }
      return phase == .then ? .outcome : .setup
    }
  }

  /// Writes the triage workspace: the rule's block, the check, the two references, the failed
  /// replay and its record, and the prompt.
  static func prepare(run: URL, rule: Rule, check: Data, replay: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: run, withIntermediateDirectories: true)
    try Data(rule.block.utf8).write(to: run.appending(path: "rule.md"))
    try check.write(to: run.appending(path: "check.json"))
    for name in ["cli.md", "format.md"] {
      try Data(Resources.text(name).utf8).write(to: run.appending(path: name))
    }
    for name in ["replay.json", "record.json"] {
      let target = run.appending(path: name)
      try? manager.removeItem(at: target)
      try manager.copyItem(at: replay.appending(path: name), to: target)
    }
    try Data(Resources.text("triage.md").utf8).write(to: run.appending(path: "prompt.md"))
  }

  /// The ways `verdict` fails to rest on what the replay shows; none means its evidence holds.
  ///
  /// Every observed path, evaluated over the record, must equal the value the model cites; the
  /// expectation it quotes must be the replay's failing one (or, for a failed action, the failure's
  /// message); the line must be the failing step's; and blaming palantir needs a failure at a Then
  /// step and at least one observation.
  static func evidenceProblems(
    _ verdict: TriageVerdict, report: ReplayReport, record: Data, rule: Rule, jq: SystemJQ
  ) throws -> [String] {
    var problems: [String] = []
    if verdict.rule != rule.id { problems.append("the verdict is for \(verdict.rule)") }
    guard report.verdict == .fail, let failure = report.failure, let step = failure.step,
      step < report.steps.count
    else { return problems + ["the replay has no failing step to blame"] }
    if verdict.line != report.steps[step].line {
      problems.append("the line cited is not the failing step's")
    }
    let cited = failure.kind == "expect" ? failure.that : failure.message
    if verdict.expectation != cited {
      problems.append("the expectation cited is not the replay's failing one")
    }
    if verdict.blame == .palantir {
      if failure.phase != .then {
        problems.append("palantir is blamed for a failure before the Then lines")
      }
      if verdict.observed.isEmpty { problems.append("palantir is blamed with no observation") }
    }
    for observation in verdict.observed {
      let printed = try jq.evaluate(observation.path, overJSON: record)
      if !sameJSON(printed, observation.value) {
        problems.append("\(observation.path) is \(printed) in the record, not \(observation.value)")
      }
    }
    return problems
  }

  /// Whether two JSON texts hold the same value, or else the same text.
  static func sameJSON(_ a: String, _ b: String) -> Bool {
    func parse(_ text: String) -> Any? {
      try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }
    if let x = parse(a), let y = parse(b),
      let left = try? JSONSerialization.data(
        withJSONObject: x, options: [.fragmentsAllowed, .sortedKeys]),
      let right = try? JSONSerialization.data(
        withJSONObject: y, options: [.fragmentsAllowed, .sortedKeys])
    {
      return left == right
    }
    return a.trimmingCharacters(in: .whitespacesAndNewlines)
      == b.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// What triage concluded, written beside the run.
struct TriageReport: Codable, Equatable {
  /// `palantir-breaks-the-rule`, `replaced`, `not-replaced`, `setup-failure`, `no-verdict`,
  /// `triage-error` or `pass`.
  var outcome: String
  var verdict: TriageVerdict?
  var evidence: [String]
  var detail: String?
  /// The sha256 of the rule's `check.json` before and after triage; they differ only when it was
  /// replaced.
  var checkSha256Before: String?
  var checkSha256After: String?
}

/// Triage of one failed replay.
final class TriageRun {
  let rule: Rule
  let checks: URL
  let run: URL
  let models: ModelRunner
  let jq: SystemJQ
  let replays: any ReplayService
  let mutants: any MutantBuilding
  let tool: URL
  let build: BuildRecord

  init(
    rule: Rule, checks: URL, run: URL, models: ModelRunner, jq: SystemJQ,
    replays: any ReplayService, mutants: any MutantBuilding, tool: URL, build: BuildRecord
  ) {
    self.rule = rule
    self.checks = checks
    self.run = run
    self.models = models
    self.jq = jq
    self.replays = replays
    self.mutants = mutants
    self.tool = tool
    self.build = build
  }

  private var folder: CheckFolder { CheckFolder(rule: rule, in: checks) }

  private func sha() -> String? {
    (try? Data(contentsOf: folder.check)).map(Digest.sha256)
  }

  /// Triages the failed replay in `replay`.
  func execute(replay: URL) throws -> TriageReport {
    let before = sha()
    func report(
      _ outcome: String, verdict: TriageVerdict? = nil, evidence: [String] = [],
      detail: String? = nil
    )
      -> TriageReport
    {
      TriageReport(
        outcome: outcome, verdict: verdict, evidence: evidence, detail: detail,
        checkSha256Before: before, checkSha256After: sha())
    }
    let replayReport = try JSONDecoder().decode(
      ReplayReport.self, from: Data(contentsOf: replay.appending(path: "replay.json")))
    let record = try Data(contentsOf: replay.appending(path: "record.json"))
    switch Triage.classify(replayReport) {
    case .passed: return report("pass", detail: "the replay passed; there is nothing to triage")
    case .noVerdict:
      return report(
        "no-verdict",
        detail: "the replay ended with no verdict (\(replayReport.failure?.kind ?? "?")); rerun it")
    case .setup, .outcome: break
    }
    let check = try Data(contentsOf: folder.check)
    guard Digest.sha256(check) == replayReport.checkSha256 else {
      return report(
        "triage-error", detail: "the replay ran another check.json than the one in the folder")
    }
    var verdict: TriageVerdict?
    var problems: [String] = []
    for attempt in 1...2 {
      let workspace = run.appending(path: "triage-\(attempt)")
      try? FileManager.default.removeItem(at: workspace)
      try Triage.prepare(run: workspace, rule: rule, check: check, replay: replay)
      let logs = run.appending(path: "logs")
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      let result = try models.run(
        ModelRequest(
          role: .triage, model: Settings.triageModel, run: workspace,
          logPrefix: logs.appending(path: "triage-\(attempt)"),
          schema: try Resources.url("triage.schema.json"), timeLimit: Settings.triageTime,
          maxTurns: nil))
      guard result.exit == 0, let message = result.lastMessage,
        let decoded = try? JSONDecoder().decode(TriageVerdict.self, from: message)
      else {
        problems = ["the triage run gave no verdict (exit \(result.exit))"]
        continue
      }
      problems = try Triage.evidenceProblems(
        decoded, report: replayReport, record: record, rule: rule, jq: jq)
      verdict = decoded
      if problems.isEmpty { break }
    }
    guard let verdict, problems.isEmpty else {
      return report("triage-error", verdict: verdict, evidence: problems)
    }
    if verdict.blame == .palantir {
      return report(
        "palantir-breaks-the-rule", verdict: verdict,
        detail: "palantir breaks \(rule.id); the check is unchanged")
    }
    return try replace(verdict: verdict, report: report)
  }

  /// Generates a replacement from the rule's block alone, and swaps it in only when it passes the
  /// gate and fails every mutant the old check failed.
  private func replace(
    verdict: TriageVerdict,
    report: (String, TriageVerdict?, [String], String?) -> TriageReport
  ) throws -> TriageReport {
    let manager = FileManager.default
    let scratch = run.appending(path: "new-checks")
    try? manager.removeItem(at: scratch)
    let generation = try GenerationRun(
      rule: rule, run: run.appending(path: "replacement"), checks: scratch, models: models,
      replays: replays, mutants: mutants, jq: jq, tool: tool, build: build)
    let outcome = try generation.execute()
    guard outcome == .accepted else {
      return report(
        "not-replaced", verdict, [], "the replacement ended ungated at \(outcome)")
    }
    let fresh = CheckFolder(rule: rule, in: scratch)
    let check = fresh.check
    var kept = fresh.mutants.count
    for old in folder.mutants {
      kept += 1
      let patch = try String(contentsOf: old.appending(path: "mutant.patch"), encoding: .utf8)
      let bundle = run.appending(path: "old-mutant-\(old.lastPathComponent)/palantir.app")
      do {
        try mutants.build(
          patch: patch, into: bundle,
          release: (try? Check.decode(Data(contentsOf: check)))?.usesRelease ?? true)
      } catch {
        return report("not-replaced", verdict, [], "an old mutant no longer builds: \(error)")
      }
      let directory = run.appending(path: "old-mutant-\(old.lastPathComponent)-replay")
      let replayed = try replays.replay(check: check, app: bundle, into: directory)
      guard Mutant.isCaught(by: replayed) else {
        return report(
          "not-replaced", verdict, [],
          "the replacement does not fail the old mutant \(old.lastPathComponent) at a Then expectation"
        )
      }
      let target = fresh.url.appending(path: "mutants/\(kept)")
      try manager.createDirectory(at: target, withIntermediateDirectories: true)
      for name in ["mutant.patch", "mutant.json"] {
        try manager.copyItem(at: old.appending(path: name), to: target.appending(path: name))
      }
      try manager.copyItem(
        at: directory.appending(path: "replay.json"), to: target.appending(path: "replay.json"))
    }
    let problems = try Gate.problems(of: fresh, for: rule, jq: jq)
    guard problems.isEmpty else {
      return report("not-replaced", verdict, problems, "the replacement does not pass the gate")
    }
    let backup = run.appending(path: "replaced-folder")
    try? manager.removeItem(at: backup)
    try manager.moveItem(at: folder.url, to: backup)
    try manager.moveItem(at: fresh.url, to: folder.url)
    return report(
      "replaced", verdict, [], "the check was replaced; the old folder is in \(backup.path)")
  }
}
