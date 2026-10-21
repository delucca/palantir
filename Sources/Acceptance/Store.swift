import Foundation

/// The judge's verdict on a check, `review.json`.
struct Review: Codable, Equatable {
  struct Line: Codable, Equatable {
    struct Problem: Codable, Equatable {
      enum Severity: String, Codable { case blocking, advisory }
      var severity: Severity
      var at: String
      var problem: String
    }

    var line: String
    var faithful: Bool
    var problems: [Problem]
  }

  enum Verdict: String, Codable { case faithful, unfaithful }

  var rule: String
  var verdict: Verdict
  var lines: [Line]
  var summary: String
  /// The sha256 of the `check.json` the judge read; code adds it when it stores the review.
  var checkSha256: String?

  /// The verdict the problems give: faithful when none is blocking. A judge that says otherwise
  /// is wrong, not the problems.
  var computedVerdict: Verdict {
    lines.contains { $0.problems.contains { $0.severity == .blocking } } ? .unfaithful : .faithful
  }
}

/// One generator run, as `generation.json` keeps it.
struct GeneratorRunRecord: Codable, Equatable {
  /// `draft` or `revise`.
  var kind: String
  /// For a revision: `replay`, `review` or `gate-signal`.
  var reason: String?
  /// The sha256 of each file in the run's workspace when it began, by name.
  var inputs: [String: String]
  var seconds: Double
  var turns: Int?
  var costUSD: Double?
  var log: String
  var logSha256: String
  var toolCalls: [String]
}

struct JudgeRoundRecord: Codable, Equatable {
  var verdict: String
  var seconds: Double
  var logSha256: String
  var inputs: [String: String]
}

struct MutantRecord: Codable, Equatable {
  var n: Int
  var model: String
  var valid: Bool
  var seconds: Double
  var patchSha256: String
  var replay: String?
  /// Why a mutant was not valid.
  var note: String?
}

struct Harness: Codable, Equatable {
  var harness: String
  var model: String
}

struct BuildRecord: Codable, Equatable {
  var commit: String
  var dirty: Bool
}

/// `generation.json`: where an accepted check came from, and every input of every round.
/// `Gate` checks the accepted check, rule and recorded input provenance.
struct Generation: Codable, Equatable {
  var rule: String
  /// The sha256 of the accepted `check.json`; absent when generation gave up.
  var checkSha256: String?
  /// The sha256 of the rule's block the check was generated from.
  var blockSha256: String
  var inputs: [String: String]? = nil
  var generator: Harness? = nil
  var generatorRuns: [GeneratorRunRecord]? = nil
  var judge: Harness? = nil
  var judgeRounds: [JudgeRoundRecord]? = nil
  var mutants: [MutantRecord]? = nil
  var replays: [String: String]? = nil
  var build: BuildRecord? = nil
  var started: String? = nil
  var ended: String? = nil
}

/// `ungated.json`: why generation gave up on a rule.
struct Ungated: Codable, Equatable {
  var rule: String
  var stage: String
  var run: String
}

/// A rule's folder under the checks folder, `<checks>/<feature>/<slug>/`.
struct CheckFolder {
  let url: URL

  init(_ url: URL) { self.url = url }

  init(rule: Rule, in checks: URL) {
    url = checks.appending(path: rule.feature).appending(path: rule.slug)
  }

  var check: URL { url.appending(path: "check.json") }
  var generation: URL { url.appending(path: "generation.json") }
  var review: URL { url.appending(path: "review.json") }
  var replay: URL { url.appending(path: "replay.json") }
  var ungated: URL { url.appending(path: "ungated.json") }

  var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

  /// The mutant folders, `mutants/<n>/`, in numeric order.
  /// - Complexity: O(n log n) time and O(n) space for n directory entries on each access.
  var mutants: [URL] {
    let root = url.appending(path: "mutants")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.compactMap { name in Int(name).map { ($0, root.appending(path: name)) } }
      .sorted { $0.0 < $1.0 }.map(\.1)
  }

  func has(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

  func decode<T: Decodable>(_ type: T.Type, at file: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
  }

  /// The checks folders of every feature: `<feature>/<slug>` pairs that exist on disk.
  static func all(in checks: URL) -> [(feature: String, slug: String)] {
    let features = (try? FileManager.default.contentsOfDirectory(atPath: checks.path)) ?? []
    return features.sorted().flatMap { feature -> [(String, String)] in
      var isFolder: ObjCBool = false
      let path = checks.appending(path: feature)
      guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isFolder),
        isFolder.boolValue
      else { return [] }
      let slugs = (try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
      return slugs.sorted().filter { !$0.hasPrefix(".") }.map { (feature, $0) }
    }
  }
}
