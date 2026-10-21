import Foundation

/// One finding of an exploration, as the explorer wrote it.
struct Candidate: Codable, Equatable {
  struct Evidence: Codable, Equatable {
    var probe: String
    var path: String
    var value: String
  }

  enum Kind: String, Codable {
    case undefinedBehavior = "undefined-behavior"
    case ruleGap = "rule-gap"
    case wording
  }

  var rule: String?
  var kind: Kind
  var observed: String
  var evidence: [Evidence]
  var screenshot: String?
  var proposal: String
}

/// `work/report.json` as the explorer writes it.
struct ModelReport: Codable, Equatable {
  struct Answer: Codable, Equatable {
    var probe: String
    var question: String
    var answer: String
  }

  var feature: String
  var candidates: [Candidate]
  var probes: [Answer]
}

/// `report.json` of an exploration: what the probes did, and the candidates whose evidence holds.
struct ExploreReport: Codable, Equatable {
  struct Probe: Codable, Equatable {
    var probe: String
    var rule: String?
    var variation: String?
    var check: String
    /// `pass`, `fail` or `error` as replayed, or `not-run` with why in `note`. Advisory: nothing
    /// reads it as a verdict.
    var verdict: String
    var note: String?
    var screenshots: [String]
    var question: String?
    var answer: String?
  }

  struct Rejected: Codable, Equatable {
    var candidate: Candidate
    var problems: [String]
  }

  var feature: String
  var probes: [Probe]
  var candidates: [Candidate]
  var rejected: [Rejected]
}

enum Explore {
  /// The observation table of a replay: after each action that named its observation, the state's
  /// selection, scroll position, folded headings and gaps, one row each.
  static func table(replay: ReplayReport, record: Data) throws -> String {
    guard let root = try JSONSerialization.jsonObject(with: record) as? [String: Any] else {
      return ""
    }
    var rows = [
      "| step | observation | selection | scroll | folded | gaps |",
      "| --- | --- | --- | --- | --- | --- |",
    ]
    for step in replay.steps {
      for action in step.actions {
        guard let name = action.name,
          let section = ((root[name] as? [String: Any])?["json"] as? [String: Any])
            .flatMap({ ($0["sections"] as? [String: Any])?["notebook"] as? [String: Any] })
        else { continue }
        let selection = (section["selection"] as? [String: Any]).map {
          "\($0["location"] ?? "?")+\($0["length"] ?? "?")"
        }
        let scroll = (section["scroll"] as? [String: Any]).map {
          "y \($0["y"] ?? "?") of \($0["documentHeight"] ?? "?")"
        }
        let folded = (section["folded"] as? [[String: Any]])?.map { "\($0["offset"] ?? "?")" }
        let gaps = (section["gaps"] as? [[String: Any]])?.count
        rows.append(
          "| \(step.line.prefix(60)) | \(name) | \(selection ?? "-") | \(scroll ?? "-") | \(folded.map { $0.joined(separator: ",") } ?? "-") | \(gaps.map(String.init) ?? "-") |"
        )
      }
    }
    return rows.joined(separator: "\n") + "\n"
  }

  /// The candidates of `report` split by whether every evidence value matches its probe's record.
  static func checkEvidence(
    _ report: ModelReport, records: [String: Data], jq: SystemJQ
  ) throws -> (kept: [Candidate], rejected: [ExploreReport.Rejected]) {
    var kept: [Candidate] = []
    var rejected: [ExploreReport.Rejected] = []
    for candidate in report.candidates {
      var problems: [String] = []
      if candidate.evidence.isEmpty { problems.append("no evidence") }
      for item in candidate.evidence {
        guard let record = records[item.probe] else {
          problems.append("no record for probe \(item.probe)")
          continue
        }
        let printed = try jq.evaluate(item.path, overJSON: record)
        if !Triage.sameJSON(printed, item.value) {
          problems.append("probe \(item.probe) \(item.path) is \(printed), not \(item.value)")
        }
      }
      if problems.isEmpty {
        kept.append(candidate)
      } else {
        rejected.append(.init(candidate: candidate, problems: problems))
      }
    }
    return (kept, rejected)
  }

  /// The feature's rules in the form the explorer reads: blocks without provenance lines.
  static func featureText(_ rules: [Rule]) -> String {
    rules.map(\.block).joined(separator: "\n\n") + "\n"
  }
}

/// An exploration of one feature: probes written, replayed, read. It fails nothing.
final class ExploreRun {
  let feature: String
  let rules: [Rule]
  let run: URL
  let models: ModelRunner
  let replays: any ReplayService
  let jq: SystemJQ
  let tool: URL

  init(
    feature: String, rules: [Rule], run: URL, models: ModelRunner, replays: any ReplayService,
    jq: SystemJQ, tool: URL
  ) {
    self.feature = feature
    self.rules = rules
    self.run = run
    self.models = models
    self.replays = replays
    self.jq = jq
    self.tool = tool
  }

  private var workspace: URL { run.appending(path: "explorer") }

  func execute() throws -> ExploreReport {
    let manager = FileManager.default
    for folder in ["work/probes", "work/replays", "bin", "tmp"] {
      try manager.createDirectory(
        at: workspace.appending(path: folder), withIntermediateDirectories: true)
    }
    try Data(Explore.featureText(rules).utf8).write(to: workspace.appending(path: "feature.md"))
    for name in ["cli.md", "format.md"] {
      try Data(Resources.text(name).utf8).write(to: workspace.appending(path: name))
    }
    let binary = workspace.appending(path: "bin/palantir-accept")
    try? manager.removeItem(at: binary)
    try manager.copyItem(at: tool, to: binary)

    let probesDone = run.appending(path: "probes.done")
    if !manager.fileExists(atPath: probesDone.path) {
      try explorer(section: "probes", name: "probes")
      try Data().write(to: probesDone)
    }
    var probes = try replayProbes()
    let blocked = probes.contains {
      $0.verdict == "not-run" && $0.note?.contains("desktop") == true
    }
    var model: ModelReport?
    if !blocked, probes.contains(where: { $0.verdict != "not-run" }) {
      let reportDone = run.appending(path: "report.done")
      if !manager.fileExists(atPath: reportDone.path) {
        try explorer(section: "report", name: "report")
      }
      do {
        let data = try Data(contentsOf: workspace.appending(path: "work/report.json"))
        model = try JSONDecoder().decode(ModelReport.self, from: data)
        try Data().write(to: reportDone)
      } catch {
        try? manager.removeItem(at: reportDone)
        throw ModelRunError("the explorer left no valid report.json: \(error)")
      }
    }
    var records: [String: Data] = [:]
    for probe in probes {
      records[probe.probe] = try? Data(
        contentsOf: run.appending(path: "replays/\(probe.probe)/record.json"))
    }
    var kept: [Candidate] = []
    var rejected: [ExploreReport.Rejected] = []
    if let model {
      (kept, rejected) = try Explore.checkEvidence(model, records: records, jq: jq)
      for answer in model.probes {
        if let index = probes.firstIndex(where: { $0.probe == answer.probe }) {
          probes[index].question = answer.question
          probes[index].answer = answer.answer
        }
      }
    }
    let report = ExploreReport(
      feature: feature, probes: probes, candidates: kept, rejected: rejected)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: run.appending(path: "report.json"))
    try Data(markdown(report).utf8).write(to: run.appending(path: "report.md"))
    return report
  }

  private func explorer(section: String, name: String) throws {
    let parts = try Resources.text("explore.md").components(separatedBy: "---- ")
    let head = parts[0]
    let body =
      parts.dropFirst().first { $0.hasPrefix(section) }
      .flatMap { $0.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) } ?? ""
    try Data((head + body).utf8).write(to: workspace.appending(path: "prompt.md"))
    if section == "report" {
      try Data(Resources.text("explore.schema.json").utf8).write(
        to: workspace.appending(path: "report.schema.json"))
    }
    let logs = run.appending(path: "logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let result = try models.run(
      ModelRequest(
        role: .explorer, model: Settings.generatorModel, run: workspace,
        logPrefix: logs.appending(path: name), schema: nil, timeLimit: Settings.exploreTime,
        maxTurns: Settings.explorerTurns))
    guard result.exit == 0 else {
      throw ModelRunError(
        "the explorer's run ended with exit \(result.exit); see \(result.log.path)")
    }
  }

  private func replayProbes() throws -> [ExploreReport.Probe] {
    let manager = FileManager.default
    let folder = workspace.appending(path: "work/probes")
    let names = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasSuffix(".json") }
      .sorted { (Int($0.dropLast(5)) ?? 0) < (Int($1.dropLast(5)) ?? 0) }
    var probes: [ExploreReport.Probe] = []
    var refused = false
    for name in names {
      let id = String(name.dropLast(5))
      let file = folder.appending(path: name)
      var probe = ExploreReport.Probe(
        probe: id, rule: nil, variation: nil, check: file.path, verdict: "not-run", note: nil,
        screenshots: [])
      defer { probes.append(probe) }
      let data = try Data(contentsOf: file)
      guard let check = try? Check.decode(data) else {
        probe.note = "the probe is not a check"
        continue
      }
      probe.rule = check.rule
      probe.variation = check.example
      guard let rule = Spec.rule(check.rule, in: rules) else {
        probe.note = "the probe names no rule of \(feature)"
        continue
      }
      let problems =
        try Lint.problems(in: check, for: rule, jq: jq, followsExample: false)
        + ((try? Phase.sequence(of: check.steps.map(\.line), for: check.rule)) == nil
          ? ["a step's line starts with no Given, When, Then or And"] : [])
      guard problems.isEmpty else {
        probe.note = "lint: \(problems[0])"
        continue
      }
      guard !refused else {
        probe.note = "not run: the desktop refused an earlier probe"
        continue
      }
      let directory = run.appending(path: "replays/\(id)")
      let report: ReplayReport
      do {
        // A probe replayed before an interruption is not replayed again.
        if let kept = try? Data(contentsOf: directory.appending(path: "replay.json")),
          let earlier = try? JSONDecoder().decode(ReplayReport.self, from: kept)
        {
          report = earlier
        } else {
          report = try replays.replay(check: file, app: nil, into: directory)
        }
      } catch is DesktopRefused {
        refused = true
        probe.note = "not run: the desktop refused the replay"
        continue
      }
      probe.verdict = report.verdict.rawValue
      if let record = try? Data(contentsOf: directory.appending(path: "record.json")) {
        try Data(Explore.table(replay: report, record: record).utf8).write(
          to: directory.appending(path: "table.md"))
      }
      let copy = workspace.appending(path: "work/replays/\(id)")
      try? manager.removeItem(at: copy)
      try manager.copyItem(at: directory, to: copy)
      let out = copy.appending(path: "out")
      probe.screenshots = ((try? manager.contentsOfDirectory(atPath: out.path)) ?? []).sorted()
        .map { out.appending(path: $0).path }
    }
    return probes
  }

  private func markdown(_ report: ExploreReport) -> String {
    var text = "# Exploration of \(report.feature)\n\n"
    text +=
      "\(report.candidates.count) candidate spec changes, \(report.rejected.count) rejected for evidence that does not match the records.\n\n"
    for (index, candidate) in report.candidates.enumerated() {
      text += "## \(index + 1). \(candidate.kind.rawValue)"
      text += candidate.rule.map { " near \($0)\n\n" } ?? "\n\n"
      text += "\(candidate.observed)\n\nProposal: \(candidate.proposal)\n\n"
      for item in candidate.evidence {
        text += "- probe \(item.probe) `\(item.path)` = `\(item.value)`\n"
      }
      if let screenshot = candidate.screenshot { text += "- screenshot: \(screenshot)\n" }
      text += "\n"
    }
    text += "## Probes\n\n"
    for probe in report.probes {
      text += "- \(probe.probe) \(probe.rule ?? "?") \(probe.verdict)"
      text += probe.variation.map { ": \($0)" } ?? ""
      text += probe.note.map { " (\($0))" } ?? ""
      text += "\n"
    }
    return text
  }
}
