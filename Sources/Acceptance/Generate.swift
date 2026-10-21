import Foundation

/// Replays a check against a build of palantir, wherever replays run.
protocol ReplayService {
  /// Replays `check` against `app`, or against the debug build under test when `app` is nil, and
  /// leaves `replay.json` and `record.json` in `directory`.
  ///
  /// - Throws: `DesktopRefused` when the desktop would not take the session.
  func replay(check: URL, app: URL?, into directory: URL) throws -> ReplayReport
}

/// The wrapper around a host replay refused it, as `with-desktop.sh` does with exit 75.
struct DesktopRefused: Error, CustomStringConvertible {
  var description: String {
    "the desktop refused the replay (exit 75); the run keeps its state and resumes later"
  }
}

/// A replay with no verdict twice in a row.
struct ReplayFailed: Error, CustomStringConvertible {
  let description: String

  init(_ report: ReplayReport) {
    description =
      "the replay ended without a verdict: \(report.failure?.kind ?? "?"): \(report.failure?.message ?? "")"
  }
}

/// How a generation ended.
enum GenerationOutcome: Equatable {
  case accepted
  /// Generation gave up at `stage`: the rule has no accepted check.
  case ungated(stage: String)
}

/// The state of one generation run, kept after every stage so a run resumes where it stopped.
struct GenerationState: Codable, Equatable {
  enum Stage: String, Codable {
    case draft, revise, replay, judge, mutantWrite, mutantReplay, accept, done
  }

  var stage: Stage = .draft
  /// For `revise`: `replay`, `review` or `gate-signal`, and the folder holding what it feeds back.
  var reason: String?
  var feedback: String?
  var replayRevisions = 0
  var judgeRounds = 0
  var mutantWriters = 0
  var signalRevisions = 0
  /// The sha256 of the check every later stage works on; snapshots sit in `checks/<sha>.json`.
  var checkSha256: String?
  var baseReplays = 0
  var lastBaseReplay: String?
  var lastReview: String?
  var generatorRuns: [GeneratorRunRecord] = []
  var judgeRecords: [JudgeRoundRecord] = []
  var mutants: [MutantRecord] = []
  /// The writer whose mutant is being replayed, and the one that survived a check.
  var currentWriter: Int?
  var survivor: Int?
  /// The writers whose mutants the check failed as the gate asks, in order.
  var valid: [Int] = []
  var outcome: GenerationOutcome?
  var started: String
}

extension GenerationOutcome: Codable {
  enum CodingKeys: String, CodingKey { case accepted, ungated }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let stage = try container.decodeIfPresent(String.self, forKey: .ungated) {
      self = .ungated(stage: stage)
    } else {
      self = .accepted
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .accepted: try container.encode(true, forKey: .accepted)
    case .ungated(let stage): try container.encode(stage, forKey: .ungated)
    }
  }
}

/// One generation run: draft, replay, judge, mutant, accept, for one rule.
final class GenerationRun {
  let rule: Rule
  let run: URL
  let checks: URL
  let models: ModelRunner
  let replays: any ReplayService
  let mutants: any MutantBuilding
  let jq: any JQ
  /// The `palantir-accept` binary the generator may run in its workspace, for `lint`.
  let tool: URL
  let build: BuildRecord
  private(set) var state: GenerationState

  init(
    rule: Rule, run: URL, checks: URL, models: ModelRunner, replays: any ReplayService,
    mutants: any MutantBuilding, jq: any JQ, tool: URL, build: BuildRecord
  ) throws {
    self.rule = rule
    self.run = run
    self.checks = checks
    self.models = models
    self.replays = replays
    self.mutants = mutants
    self.jq = jq
    self.tool = tool
    self.build = build
    let file = run.appending(path: "state.json")
    if let data = try? Data(contentsOf: file) {
      state = try JSONDecoder().decode(GenerationState.self, from: data)
    } else {
      state = GenerationState(started: Self.now())
    }
  }

  static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

  /// Runs the stages to the end and writes the rule's folder under `checks`.
  ///
  /// - Throws: `ModelRunError`, `TimedOut`, `DesktopRefused` or `ReplayFailed` with the run's state
  ///   kept, so that the next run of the same folder resumes.
  func execute() throws -> GenerationOutcome {
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    while state.stage != .done {
      switch state.stage {
      case .draft: try generate(kind: "draft", reason: nil)
      case .revise: try generate(kind: "revise", reason: state.reason)
      case .replay: try replayBase()
      case .judge: try judge()
      case .mutantWrite: try writeMutant()
      case .mutantReplay: try replayMutant()
      case .accept: try accept()
      case .done: break
      }
      try save()
    }
    try finish()
    return state.outcome ?? .ungated(stage: "unknown")
  }

  private func save() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(state).write(to: run.appending(path: "state.json"))
  }

  private func giveUp(_ stage: String) {
    state.outcome = .ungated(stage: stage)
    state.stage = .done
  }

  // MARK: Generator

  private var draft: URL { run.appending(path: "draft") }
  private var snapshots: URL { run.appending(path: "checks") }

  private func generate(kind: String, reason: String?) throws {
    let manager = FileManager.default
    let revising = kind == "revise"
    for folder in ["work", "bin", "tmp"] {
      try manager.createDirectory(
        at: draft.appending(path: folder), withIntermediateDirectories: true)
    }
    try Data(rule.block.utf8).write(to: draft.appending(path: "rule.md"))
    for name in ["cli.md", "format.md"] {
      try Data(Resources.text(name).utf8).write(to: draft.appending(path: name))
    }
    let binary = draft.appending(path: "bin/palantir-accept")
    try? manager.removeItem(at: binary)
    try manager.copyItem(at: tool, to: binary)
    for stale in ["review.json", "replay.json", "record.json", "gate-signal.txt"] {
      try? manager.removeItem(at: draft.appending(path: stale))
    }
    try? manager.removeItem(at: draft.appending(path: "work/answer.md"))
    if revising, let reason {
      try feed(reason: reason)
    }
    try Data(prompt(revising: revising, reason: reason).utf8).write(
      to: draft.appending(path: "prompt.md"))
    let index = state.generatorRuns.count
    let name = revising ? "revise-\(index)" : "draft"
    let result = try models.run(
      ModelRequest(
        role: .generator, model: Settings.generatorModel, run: draft,
        logPrefix: logPrefix(name), schema: nil, timeLimit: Settings.draftTime,
        maxTurns: Settings.generatorTurns))
    guard result.exit == 0 else {
      throw ModelRunError(
        "the generator's run ended with exit \(result.exit); see \(result.log.path)")
    }
    state.generatorRuns.append(
      GeneratorRunRecord(
        kind: kind, reason: reason, inputs: result.inputs, seconds: result.seconds,
        turns: result.turns, costUSD: result.costUSD, log: result.log.path,
        logSha256: result.logSha256, toolCalls: result.toolCalls))
    let file = draft.appending(path: "work/check.json")
    guard let data = try? Data(contentsOf: file) else {
      giveUp(revising ? "revise" : "draft")
      return
    }
    guard (try? Lint.problems(in: data, for: rule, jq: jq))?.isEmpty == true else {
      giveUp(revising ? "revise" : "draft")
      return
    }
    try manager.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let sha = Digest.sha256(data)
    try data.write(to: snapshots.appending(path: "\(sha).json"))
    state.checkSha256 = sha
    state.reason = nil
    state.feedback = nil
    state.stage = .replay
  }

  private func feed(reason: String) throws {
    let manager = FileManager.default
    switch reason {
    case "review":
      guard let review = state.lastReview else { return }
      try manager.copyItem(
        at: URL(fileURLWithPath: review), to: draft.appending(path: "review.json"))
    case "replay":
      guard let folder = state.feedback else { return }
      for name in ["replay.json", "record.json"] {
        try manager.copyItem(
          at: URL(fileURLWithPath: folder).appending(path: name), to: draft.appending(path: name))
      }
    default:
      try Data(Settings.gateSignal.utf8).write(to: draft.appending(path: "gate-signal.txt"))
    }
  }

  /// The generator's prompt: the draft prompt, or the revision prompt with the section for `reason`.
  private func prompt(revising: Bool, reason: String?) throws -> String {
    guard revising else { return try Resources.text("generate.md") }
    let parts = try Resources.text("revise.md").components(separatedBy: "---- ")
    let section = parts.dropFirst().first { reason.map($0.hasPrefix) ?? false } ?? ""
    let body = section.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    return parts[0] + body
  }

  private func logPrefix(_ name: String) -> URL {
    let logs = run.appending(path: "logs")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    return logs.appending(path: name)
  }

  // MARK: Replay

  private var currentCheck: URL {
    snapshots.appending(path: "\(state.checkSha256 ?? "").json")
  }

  private func replayBase() throws {
    state.baseReplays += 1
    let directory = run.appending(path: "replays/base-\(state.baseReplays)")
    var report = try replays.replay(check: currentCheck, app: nil, into: directory)
    if report.verdict == .error {
      state.baseReplays += 1
      let again = run.appending(path: "replays/base-\(state.baseReplays)")
      report = try replays.replay(check: currentCheck, app: nil, into: again)
      guard report.verdict != .error else { throw ReplayFailed(report) }
      state.lastBaseReplay = again.path
    } else {
      state.lastBaseReplay = directory.path
    }
    switch report.verdict {
    case .pass: state.stage = .judge
    case .fail:
      guard state.replayRevisions < Settings.replayRevisions else {
        giveUp("replay")
        return
      }
      state.replayRevisions += 1
      state.reason = "replay"
      state.feedback = state.lastBaseReplay
      state.stage = .revise
    case .error: break
    }
  }

  // MARK: Judge

  private func judge() throws {
    let round = state.judgeRounds + 1
    let folder = run.appending(path: "judge-\(round)")
    try? FileManager.default.removeItem(at: folder)
    guard let sha = state.checkSha256 else { return }
    try Judge.prepare(run: folder, rule: rule, check: Data(contentsOf: currentCheck))
    var review: Review?
    var lastResult: ModelResult?
    var attempt = 0
    while review == nil {
      attempt += 1
      let result = try models.run(
        ModelRequest(
          role: .judge, model: Settings.judgeModel, run: folder,
          logPrefix: logPrefix("judge-\(round)-\(attempt)"),
          schema: try Resources.url("judge.schema.json"), timeLimit: Settings.judgeTime,
          maxTurns: nil))
      lastResult = result
      do {
        guard result.exit == 0, let message = result.lastMessage else {
          throw JudgeError("the judge's run ended with exit \(result.exit)")
        }
        review = try Judge.decode(message, rule: rule)
      } catch let error as JudgeError {
        if attempt >= 2 { throw error }
      }
    }
    guard var decided = review, let result = lastResult else { return }
    decided.checkSha256 = sha
    let file = run.appending(path: "review-\(round).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(decided).write(to: file)
    state.lastReview = file.path
    state.judgeRecords.append(
      JudgeRoundRecord(
        verdict: decided.verdict.rawValue, seconds: result.seconds, logSha256: result.logSha256,
        inputs: result.inputs))
    state.judgeRounds = round
    if decided.verdict == .faithful {
      state.stage = state.survivor == nil ? .mutantWrite : .mutantReplay
      state.currentWriter = state.survivor
    } else if round >= Settings.judgeRounds {
      giveUp("judge")
    } else {
      state.reason = "review"
      state.stage = .revise
    }
  }

  // MARK: Mutants

  private func writerFolder(_ writer: Int) -> URL { run.appending(path: "mutant-\(writer)") }

  private func writeMutant() throws {
    guard state.mutantWriters < Settings.mutantWriters else {
      giveUp("mutant")
      return
    }
    state.mutantWriters += 1
    let writer = state.mutantWriters
    let folder = writerFolder(writer)
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let workspace = try mutants.writerWorkspace(in: folder)
    try Data(Mutant.prompt(for: rule).utf8).write(to: folder.appending(path: "prompt.md"))
    let result = try models.run(
      ModelRequest(
        role: .mutant, model: Settings.mutantModel, run: folder,
        logPrefix: logPrefix("mutant-\(writer)"),
        schema: try Resources.url("mutant.schema.json"), timeLimit: Settings.mutantTime,
        maxTurns: nil))
    func invalid(_ note: String, patch: String = "") {
      state.mutants.append(
        MutantRecord(
          n: writer, model: Settings.mutantModel, valid: false, seconds: result.seconds,
          patchSha256: Digest.sha256(Data(patch.utf8)), replay: nil, note: note))
    }
    guard result.exit == 0, let message = result.lastMessage,
      let notes = try? JSONDecoder().decode(MutantNotes.self, from: message)
    else {
      invalid("the writer's run gave no notes (exit \(result.exit))")
      return
    }
    let patch = try mutants.patch(of: workspace)
    if let problem = Mutant.problem(with: patch, for: rule) {
      invalid(problem, patch: patch)
      return
    }
    try Data(patch.utf8).write(to: run.appending(path: "mutant-\(writer).patch"))
    try Data(
      JSONEncoder().encode(
        MutantFile(
          files: Mutant.files(in: patch), breaks: notes.breaks, keeps: notes.keeps,
          model: Settings.mutantModel, patchSha256: Digest.sha256(Data(patch.utf8)))
      )
    ).write(to: run.appending(path: "mutant-\(writer).json"))
    do {
      try mutants.build(
        patch: patch, into: bundle(writer),
        release: (try? Check.decode(Data(contentsOf: currentCheck)))?.usesRelease ?? true)
    } catch let error as MutantBuildError {
      invalid("the mutant does not build: \(error)", patch: patch)
      return
    }
    state.currentWriter = writer
    state.stage = .mutantReplay
  }

  private func bundle(_ writer: Int) -> URL {
    run.appending(path: "mutant-\(writer)-build/palantir.app")
  }

  private func replayMutant() throws {
    guard let writer = state.currentWriter else {
      state.stage = .mutantWrite
      return
    }
    var directory = run.appending(path: "mutant-\(writer)-replay-\(state.signalRevisions)")
    var report = try replays.replay(check: currentCheck, app: bundle(writer), into: directory)
    if report.verdict == .error {
      directory = directory.appendingPathExtension("retry")
      report = try replays.replay(check: currentCheck, app: bundle(writer), into: directory)
      guard report.verdict != .error else { throw ReplayFailed(report) }
    }
    let patchFile = run.appending(path: "mutant-\(writer).patch")
    let patchSha = Digest.sha256((try? Data(contentsOf: patchFile)) ?? Data())
    func record(valid: Bool, note: String?) {
      state.mutants.removeAll { $0.n == writer }
      state.mutants.append(
        MutantRecord(
          n: writer, model: Settings.mutantModel, valid: valid, seconds: report.seconds,
          patchSha256: patchSha, replay: directory.path, note: note))
    }
    if Mutant.isCaught(by: report) {
      record(valid: true, note: nil)
      state.valid.append(writer)
      state.survivor = nil
      state.stage = .accept
    } else if report.verdict == .pass {
      guard state.signalRevisions < Settings.signalRevisions else {
        record(valid: false, note: "the check passes against the mutant after its revision")
        giveUp("mutant-survives")
        return
      }
      record(valid: false, note: "the check passes against the mutant")
      state.signalRevisions += 1
      state.survivor = writer
      state.reason = "gate-signal"
      state.stage = .revise
    } else {
      record(valid: false, note: "the replay against the mutant is not a caught Then expectation")
      state.survivor = nil
      state.currentWriter = nil
      state.stage = .mutantWrite
    }
  }

  // MARK: Accept

  private func accept() throws {
    let manager = FileManager.default
    guard let sha = state.checkSha256, let base = state.lastBaseReplay,
      let review = state.lastReview, !state.valid.isEmpty
    else {
      giveUp("accept")
      return
    }
    let target = CheckFolder(rule: rule, in: checks)
    let staging = CheckFolder(
      target.url.deletingLastPathComponent().appending(path: ".\(rule.slug).new"))
    try? manager.removeItem(at: staging.url)
    try manager.createDirectory(at: staging.url, withIntermediateDirectories: true)
    let check = try Data(contentsOf: currentCheck)
    try check.write(to: staging.check)
    try manager.copyItem(at: URL(fileURLWithPath: review), to: staging.review)
    try manager.copyItem(
      at: URL(fileURLWithPath: base).appending(path: "replay.json"), to: staging.replay)
    var number = 0
    for writer in state.valid {
      number += 1
      let folder = staging.url.appending(path: "mutants/\(number)")
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      try manager.copyItem(
        at: run.appending(path: "mutant-\(writer).patch"),
        to: folder.appending(path: "mutant.patch"))
      try manager.copyItem(
        at: run.appending(path: "mutant-\(writer).json"), to: folder.appending(path: "mutant.json"))
      guard let record = state.mutants.last(where: { $0.n == writer }), let replay = record.replay
      else { continue }
      try manager.copyItem(
        at: URL(fileURLWithPath: replay).appending(path: "replay.json"),
        to: folder.appending(path: "replay.json"))
    }
    try writeGeneration(to: staging.generation, checkSha: sha)
    let problems = try Gate.problems(of: staging, for: rule, jq: jq)
    guard problems.isEmpty else {
      try? manager.removeItem(at: staging.url)
      try writeUngated(stage: "gate: \(problems[0])")
      giveUp("gate")
      return
    }
    try? manager.removeItem(at: target.url)
    try manager.moveItem(at: staging.url, to: target.url)
    state.outcome = .accepted
    state.stage = .done
  }

  private func writeGeneration(to file: URL, checkSha: String?) throws {
    let claude = models.config.versions["claude"] ?? "claude"
    let codex = models.config.versions["codex"] ?? "codex"
    let tools = (try? Data(contentsOf: tool)).map(Digest.sha256) ?? ""
    let generation = Generation(
      rule: rule.id, checkSha256: checkSha, blockSha256: rule.blockSha256,
      inputs: [
        "cli.md": Digest.sha256(Data(try Resources.text("cli.md").utf8)),
        "format.md": Digest.sha256(Data(try Resources.text("format.md").utf8)),
        "generate.md": Digest.sha256(Data(try Resources.text("generate.md").utf8)),
        "palantir-accept": tools,
      ],
      generator: Harness(harness: claude, model: Settings.generatorModel),
      generatorRuns: state.generatorRuns,
      judge: Harness(harness: codex, model: Settings.judgeModel),
      judgeRounds: state.judgeRecords, mutants: state.mutants,
      replays: state.lastBaseReplay.map { ["base": $0] }, build: build, started: state.started,
      ended: Self.now())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(generation).write(to: file)
  }

  /// Writes the folder of a rule generation gave up on: `ungated.json`, `generation.json`, and no
  /// check.
  func writeUngated(stage: String) throws {
    let manager = FileManager.default
    let target = CheckFolder(rule: rule, in: checks)
    try? manager.removeItem(at: target.url)
    try manager.createDirectory(at: target.url, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Ungated(rule: rule.id, stage: stage, run: run.lastPathComponent)).write(
      to: target.ungated)
    try writeGeneration(to: target.generation, checkSha: nil)
  }

  /// Finishes a run that ended `ungated` by writing its folder.
  func finish() throws {
    if case .ungated(let stage) = state.outcome {
      try writeUngated(stage: stage)
    }
  }
}

/// Replays by starting `palantir-accept replay` as a process of its own, behind the command that
/// takes the desktop when one is set.
struct ProcessReplay: ReplayService {
  let runner: any Runner
  let tool: URL
  let wrapper: [String]
  let debugApp: URL
  let releaseApp: URL
  let bin: URL

  func replay(check: URL, app: URL?, into directory: URL) throws -> ReplayReport {
    var words =
      wrapper + [
        tool.path, "replay", check.path, "--record", directory.path, "--app",
        (app ?? debugApp).path, "--release-app",
        (app.map { Mutant.releaseBundle(for: $0) } ?? releaseApp).path, "--bin", bin.path,
      ]
    let program = words.removeFirst()
    // A wrapper that takes the desktop lock may wait up to 30 minutes for it.
    let output = try runner.run(
      program, words, stdin: nil,
      timeout: Settings.replayDeadline + (wrapper.isEmpty ? 120 : 2100))
    if output.exit == 75 { throw DesktopRefused() }
    let file = directory.appending(path: "replay.json")
    guard let data = try? Data(contentsOf: file) else {
      throw ModelRunError("the replay left no replay.json (exit \(output.exit)): \(output.stderr)")
    }
    return try JSONDecoder().decode(ReplayReport.self, from: data)
  }
}
