import Foundation

/// The replay's record: one JSON object that holds the fixtures' paths, the user's id, the pid of
/// the palantir launched last and every named observation. Expectations are jq expressions over it.
struct Record {
  private(set) var values: [String: Any]

  init(files: [String: String], uid: Int) {
    values = ["files": files, "uid": uid, "out": [String: String]()]
  }

  subscript(name: String) -> Any? {
    get { values[name] }
    set { values[name] = newValue }
  }

  var files: [String: String] { values["files"] as? [String: String] ?? [:] }

  mutating func addOut(_ name: String, path: String) {
    var outs = values["out"] as? [String: String] ?? [:]
    outs[name] = path
    values["out"] = outs
  }

  /// The record as JSON, keys sorted.
  func json(pretty: Bool = false) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: values,
      options: pretty
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes])
  }
}

/// jq, run as `/usr/bin/jq`. The runner evaluates nothing else itself.
struct SystemJQ: JQ {
  let runner: any Runner

  /// jq's version, such as `jq-1.7.1-apple`.
  func version() throws -> String {
    try runner.run(Settings.jq, ["--version"]).stdout.trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  /// What `expression` prints over `record`, one line per output; or `error: <message>` when jq
  /// failed, so a failure is never read as `false`.
  func evaluate(_ expression: String, over record: Record) throws -> String {
    try evaluate(expression, overJSON: record.json())
  }

  /// What `expression` prints over `json`, one compact line per output, or `error: <message>`.
  func evaluate(_ expression: String, overJSON json: Data) throws -> String {
    let output = try runner.run(
      Settings.jq, ["-c", expression], stdin: json, timeout: Settings.subprocessTimeout)
    guard output.exit == 0 else { return "error: \(Self.firstLine(output.stderr))" }
    return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The raw output of `expression` over `record`, which must be exactly one line.
  func line(_ expression: String, over record: Record) throws -> String {
    let output = try runner.run(
      Settings.jq, ["-r", expression], stdin: try record.json(), timeout: Settings.subprocessTimeout
    )
    guard output.exit == 0 else {
      throw ArgumentError("jq \(expression): \(Self.firstLine(output.stderr))")
    }
    let text = output.stdout
    guard text.hasSuffix("\n"), text.dropLast().firstIndex(of: "\n") == nil else {
      throw ArgumentError(
        "jq \(expression) printed \(text.isEmpty ? "nothing" : "more than one line")")
    }
    return String(text.dropLast())
  }

  func compileError(_ expression: String) throws -> String? {
    let output = try runner.run(Settings.jq, ["-n", expression])
    return output.exit == 3 ? Self.firstLine(output.stderr) : nil
  }

  private static func firstLine(_ text: String) -> String {
    text.split(separator: "\n").first.map(String.init) ?? ""
  }
}

/// An action argument that cannot be built.
struct ArgumentError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}
