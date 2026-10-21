import Foundation

/// The observations a `drive` or `inspect` action stores besides its exit code and text.
enum Outputs {
  /// The rows of `palantir-drive menus`: `path`, `enabled`, `press` and `key` of each item.
  static func menus(_ text: String) -> [[String: Any]] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      var item: [String: Any] = ["path": fields.first ?? ""]
      if fields.count > 1 { item["enabled"] = fields[1] == "enabled" }
      if fields.count > 2 { item["press"] = fields[2] == "press" }
      if fields.count > 3 { item["key"] = fields[3] }
      return item
    }
  }

  /// The lines of `palantir-drive tree`: `depth`, `role`, `title`, `label`, `frame` and `actions`.
  static func tree(_ text: String) -> [[String: Any]] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
      let body = line.trimmingCharacters(in: .whitespaces)
      var element: [String: Any] = [
        "depth": line.prefix { $0 == " " }.count / 2, "role": String(body.prefix { $0 != " " }),
      ]
      for key in ["title", "label"] {
        if let match = body.firstMatch(of: try! Regex("\(key)=\"((?:[^\"\\\\]|\\\\.)*)\"")) {
          element[key] = unescape(String(match.output[1].substring ?? ""))
        }
      }
      if let match = body.firstMatch(of: /frame=(-?\d+),(-?\d+),(\d+),(\d+)/) {
        element["frame"] = [match.1, match.2, match.3, match.4].compactMap { Int($0) }
      }
      if let match = body.firstMatch(of: /actions=(\S+)/) {
        element["actions"] = match.1.split(separator: ",").map(String.init)
      }
      return element
    }
  }

  /// The rows of `palantir-inspect list`: `pid` and `path` of each socket.
  static func sockets(_ text: String) -> [[String: Any]] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      return ["pid": Int(fields.first ?? "") ?? 0, "path": fields.count > 1 ? fields[1] : ""]
    }
  }

  /// A Swift `debugDescription` string's escapes undone.
  private static func unescape(_ text: String) -> String {
    let wrapped = "\"\(text)\""
    guard let data = wrapped.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        as? String
    else { return text }
    return decoded
  }
}
