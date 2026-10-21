import Foundation

/// A check: one JSON file that mirrors one rule's example line by line. Decoding is strict, so a
/// key the format does not name is an error.
struct Check: Decodable, Equatable {
  struct Step: Decodable, Equatable {
    var line: String
    var actions: [Action]
    var expect: [Expectation]

    enum CodingKeys: String, CodingKey, CaseIterable {
      case line
      case actions = "do"
      case expect
    }

    init(from decoder: any Decoder) throws {
      try decoder.allowKeys(CodingKeys.allCases)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      line = try container.decode(String.self, forKey: .line)
      actions = try container.decode([Action].self, forKey: .actions)
      expect = try container.decode([Expectation].self, forKey: .expect)
    }
  }

  /// A jq expression over the record that must print `true`.
  struct Expectation: Decodable, Equatable {
    var that: String
    var why: String

    enum CodingKeys: String, CodingKey, CaseIterable { case that, why }

    init(from decoder: any Decoder) throws {
      try decoder.allowKeys(CodingKeys.allCases)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      that = try container.decode(String.self, forKey: .that)
      why = try container.decodeIfPresent(String.self, forKey: .why) ?? ""
    }
  }

  var format: Int
  /// The ID of the rule the check is for, such as `req~heading-folding.fold~1`.
  var rule: String
  var example: String
  /// Fixture files: name to text.
  var files: [String: String]
  var steps: [Step]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case format, rule, example, files, steps
  }

  init(from decoder: any Decoder) throws {
    try decoder.allowKeys(CodingKeys.allCases)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    format = try container.decode(Int.self, forKey: .format)
    guard format == Settings.checkFormat else {
      throw DecodingError.dataCorruptedError(
        forKey: .format, in: container, debugDescription: "format is not \(Settings.checkFormat)")
    }
    rule = try container.decode(String.self, forKey: .rule)
    example = try container.decode(String.self, forKey: .example)
    files = try container.decode([String: String].self, forKey: .files)
    steps = try container.decode([Step].self, forKey: .steps)
  }

  /// Whether the check launches or reads the release build, so a mutant needs a release bundle.
  var usesRelease: Bool {
    func uses(_ action: Action) -> Bool {
      switch action.verb {
      case .launch(let build, _): return build == .release
      case .symbols(let build): return build == .release
      case .repeat(let body, _, _): return body.contains(where: uses)
      default: return false
      }
    }
    return steps.contains { $0.actions.contains(where: uses) }
  }

  /// Decodes `data` as a check.
  ///
  /// - Throws: `CheckError` with where decoding stopped.
  static func decode(_ data: Data) throws -> Check {
    do {
      return try JSONDecoder().decode(Check.self, from: data)
    } catch let error as DecodingError {
      throw CheckError(error.readable)
    }
  }
}

/// A check file that is not a check.
struct CheckError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

/// The exit an action must end with: a code, or `any` for an action that never fails on its exit
/// (the exit still lands in the record).
enum ExpectedExit: Decodable, Equatable, ExpressibleByIntegerLiteral, CustomStringConvertible {
  case code(Int32)
  case any

  init(integerLiteral value: Int32) { self = .code(value) }

  init(from decoder: any Decoder) throws {
    let single = try decoder.singleValueContainer()
    if let code = try? single.decode(Int32.self) {
      self = .code(code)
    } else if (try? single.decode(String.self)) == "any" {
      self = .any
    } else {
      throw CheckError("exit is an integer or \"any\"")
    }
  }

  var description: String {
    switch self {
    case .code(let code): return String(code)
    case .any: return "any"
    }
  }
}

/// The build a `launch` or `symbols` action names.
enum Build: String, Decodable, Equatable {
  case debug, release
}

/// One action of a step.
struct Action: Decodable, Equatable {
  enum Verb: Equatable {
    case launch(build: Build, inspector: Bool)
    case drive([Argument])
    case inspect([Argument])
    case file(String)
    case stat(Argument)
    case symbols(Build)
    case sleep(Double)
    case quit
    case `repeat`(body: [Action], until: String, max: Int)
  }

  var verb: Verb
  /// The name the action's observation takes in the record.
  var name: String?
  /// The exit code the action must end with, or `any`.
  var exit: ExpectedExit

  init(verb: Verb, name: String? = nil, exit: ExpectedExit = 0) {
    self.verb = verb
    self.name = name
    self.exit = exit
  }

  struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ string: String) { stringValue = string }
  }

  private static let verbs: Set<String> = [
    "launch", "drive", "inspect", "file", "stat", "symbols", "sleep", "quit", "repeat",
  ]
  private static let options: Set<String> = ["as", "exit", "until", "max"]

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    let keys = Set(container.allKeys.map(\.stringValue))
    let named = keys.intersection(Self.verbs)
    guard named.count == 1, let word = named.first else {
      throw CheckError(
        "an action names exactly one of \(Self.verbs.sorted().joined(separator: ", ")); it names \(keys.sorted())"
      )
    }
    if let unknown = keys.subtracting(Self.verbs).subtracting(Self.options).sorted().first {
      throw CheckError("an action has the key \(unknown), which the format does not")
    }
    name = try container.decodeIfPresent(String.self, forKey: Key("as"))
    exit = try container.decodeIfPresent(ExpectedExit.self, forKey: Key("exit")) ?? 0
    if exit == .any, name == nil {
      throw CheckError("an action with \"exit\": \"any\" needs an \"as\", or its exit is lost")
    }
    let key = Key(word)
    switch word {
    case "launch":
      struct Launch: Decodable {
        var build: Build
        var inspector: Bool
      }
      let launch = try container.decode(Launch.self, forKey: key)
      verb = .launch(build: launch.build, inspector: launch.inspector)
    case "drive": verb = .drive(try container.decode([Argument].self, forKey: key))
    case "inspect": verb = .inspect(try container.decode([Argument].self, forKey: key))
    case "file": verb = .file(try container.decode(String.self, forKey: key))
    case "stat": verb = .stat(try container.decode(Argument.self, forKey: key))
    case "symbols": verb = .symbols(try container.decode(Build.self, forKey: key))
    case "sleep": verb = .sleep(try container.decode(Double.self, forKey: key))
    case "quit":
      guard try container.decode(Bool.self, forKey: key) else {
        throw CheckError("quit takes true")
      }
      verb = .quit
    default:
      guard let until = try container.decodeIfPresent(String.self, forKey: Key("until")) else {
        throw CheckError("repeat needs an until expression")
      }
      verb = .repeat(
        body: try container.decode([Action].self, forKey: key), until: until,
        max: try container.decodeIfPresent(Int.self, forKey: Key("max")) ?? Settings.repeatDefault)
    }
    if word != "repeat", let stray = keys.intersection(["until", "max"]).sorted().first {
      throw CheckError("\(stray) belongs to repeat only")
    }
  }
}

/// An argument of a `drive`, `inspect` or `stat` action.
enum Argument: Decodable, Equatable {
  case text(String)
  case number(Double)
  /// The absolute path of a fixture.
  case file(String)
  /// A new path in the replay's folder, for a screenshot or a capture.
  case out(String)
  /// The raw output of a jq expression over the record so far.
  case jq(String)

  init(from decoder: any Decoder) throws {
    let single = try decoder.singleValueContainer()
    if let text = try? single.decode(String.self) {
      self = .text(text)
    } else if let number = try? single.decode(Double.self) {
      self = .number(number)
    } else {
      let container = try decoder.container(keyedBy: Action.Key.self)
      guard container.allKeys.count == 1, let key = container.allKeys.first else {
        throw CheckError("an argument is a string, a number, or one of file, out and jq")
      }
      let value = try container.decode(String.self, forKey: key)
      switch key.stringValue {
      case "file": self = .file(value)
      case "out": self = .out(value)
      case "jq": self = .jq(value)
      default:
        throw CheckError("an argument has the key \(key.stringValue), which the format does not")
      }
    }
  }
}

extension Decoder {
  /// Fails when the object being decoded has a key outside `allowed`.
  func allowKeys<Key: CodingKey>(_ allowed: [Key]) throws {
    let container = try self.container(keyedBy: Action.Key.self)
    let known = Set(allowed.map(\.stringValue))
    if let unknown = container.allKeys.map(\.stringValue).sorted().first(where: {
      !known.contains($0)
    }) {
      throw CheckError("the key \(unknown) is not in the format")
    }
  }
}

extension DecodingError {
  /// A one-line description with the path to where decoding stopped.
  var readable: String {
    func path(_ context: Context) -> String {
      context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }
    switch self {
    case .keyNotFound(let key, let context):
      return "missing \(key.stringValue) at \(path(context))"
    case .typeMismatch(_, let context), .valueNotFound(_, let context),
      .dataCorrupted(let context):
      return "\(context.debugDescription) at \(path(context))"
    @unknown default: return "\(self)"
    }
  }
}
