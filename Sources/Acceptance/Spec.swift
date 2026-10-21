import CryptoKit
import Foundation

/// The phase an example line belongs to.
enum Phase: String, Codable, Equatable {
  case given, when, then
}

/// One rule of a feature file: its heading, ID and example, as a check is generated from them.
struct Rule: Equatable {
  /// The ID written in the feature file, such as `req~heading-folding.fold~1`.
  let id: String
  let feature: String
  let slug: String
  let version: Int
  /// The rule's heading line, `## Rule: …`, through the end of its example, without its `From:`
  /// and `Decided in:` lines.
  let block: String
  /// The title of the rule's first example.
  let exampleTitle: String?
  /// The example's lines that start with `* `, verbatim.
  let exampleLines: [String]

  /// The sha256 of `block`.
  var blockSha256: String { Digest.sha256(Data(block.utf8)) }

  /// `feature.slug`, the rule's ID without its `req~` prefix and version.
  var name: String { "\(feature).\(slug)" }

  /// Whether the layer gives the rule a check.
  var isChecked: Bool {
    !Settings.uncheckedFeatures.contains(feature) && !Settings.uncheckedRules.contains(name)
  }

  /// The phase of each of `exampleLines`: a line starting `And` or `But` takes the one before.
  ///
  /// - Throws: `SpecError` when the first line, or any other, starts with no known word.
  func phases() throws -> [Phase] { try Phase.sequence(of: exampleLines, for: id) }
}

extension Phase {
  /// The phase of each example line: a line starting `And` or `But` takes the one before.
  ///
  /// - Throws: `SpecError` when a line starts with no known word, or the first is an `And`.
  static func sequence(of lines: [String], for rule: String) throws -> [Phase] {
    var current: Phase?
    return try lines.map { line in
      switch line.dropFirst(2).prefix(while: { $0 != " " }) {
      case "Given": current = .given
      case "When": current = .when
      case "Then": current = .then
      case "And", "But": break
      default:
        throw SpecError("\(rule): the example line \"\(line)\" starts with no Given, When or Then")
      }
      guard let phase = current else {
        throw SpecError("\(rule): the example starts with \"\(line)\"")
      }
      return phase
    }
  }
}

/// A feature file the layer cannot read.
struct SpecError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

enum Spec {
  /// The rules of every `*.md` file in `features`, sorted by ID.
  ///
  /// - Throws: `SpecError` for a rule heading without an ID line, an ID in a file of another
  ///   feature or one written twice.
  static func rules(in features: URL) throws -> [Rule] {
    let names = try FileManager.default.contentsOfDirectory(atPath: features.path)
      .filter { $0.hasSuffix(".md") }.sorted()
    var rules: [Rule] = []
    for name in names {
      let text = try String(contentsOf: features.appending(path: name), encoding: .utf8)
      rules += try parse(text, file: String(name.dropLast(3)))
    }
    let ids = rules.map(\.id)
    if let twice = Dictionary(grouping: ids, by: { $0 }).first(where: { $1.count > 1 }) {
      throw SpecError("\(twice.key) is written twice")
    }
    return rules.sorted { $0.id < $1.id }
  }

  /// The feature a rule block's ID line names, for a `rule.md` that holds one block.
  static func feature(ofBlock text: String) -> String? {
    text.components(separatedBy: "\n").lazy.compactMap {
      $0.firstMatch(of: /^`req~([a-z0-9-]+)\./)?.1
    }
    .first.map(String.init)
  }

  /// The rule with `id` among `rules`, or the one a check's `rule` names.
  static func rule(_ id: String, in rules: [Rule]) -> Rule? { rules.first { $0.id == id } }

  /// The rules of one feature file's `text`; `file` is its name without `.md`.
  static func parse(_ text: String, file: String) throws -> [Rule] {
    let lines = text.components(separatedBy: "\n")
    var rules: [Rule] = []
    var index = 0
    while index < lines.count {
      guard lines[index].hasPrefix("## Rule: ") else {
        index += 1
        continue
      }
      let start = index
      index += 1
      while index < lines.count, !lines[index].hasPrefix("## ") && !lines[index].hasPrefix("# ") {
        index += 1
      }
      rules.append(try rule(Array(lines[start..<index]), file: file))
    }
    return rules
  }

  private static var idPattern: Regex<(Substring, Substring, Substring, Substring)> {
    /^`req~([a-z0-9-]+)\.([a-z0-9-]+)~([0-9]+)`$/
  }

  private static func rule(_ section: [String], file: String) throws -> Rule {
    guard section.count > 1, let match = section[1].wholeMatch(of: idPattern) else {
      throw SpecError("\(file): \"\(section[0])\" is not followed by its `req~…` ID line")
    }
    let feature = String(match.1)
    guard feature == file else {
      throw SpecError(
        "\(file): the rule req~\(feature).\(match.2)~\(match.3) is in another feature's file")
    }
    var block = section.filter { !$0.hasPrefix("From: ") && !$0.hasPrefix("Decided in: ") }
    while let last = block.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      block.removeLast()
    }
    return Rule(
      id: "req~\(feature).\(match.2)~\(match.3)", feature: feature, slug: String(match.2),
      version: Int(match.3) ?? 0, block: block.joined(separator: "\n"),
      exampleTitle: block.first { $0.hasPrefix("### Example: ") }
        .map { String($0.dropFirst("### Example: ".count)) },
      exampleLines: block.filter { $0.hasPrefix("* ") })
  }
}

enum RuleID {
  /// A rule ID without its version, such as `req~heading-folding.fold`.
  static func name(of id: String) -> String {
    String(id.split(separator: "~").prefix(2).joined(separator: "~"))
  }

  /// The version number in a rule ID such as `req~heading-folding.fold~2`.
  static func version(of id: String) -> Int? { id.split(separator: "~").last.flatMap { Int($0) } }
}

enum Digest {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
