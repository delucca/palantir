import Foundation

/// A command line the program does not accept.
struct Usage: Error {
  let message: String

  init(_ message: String) { self.message = message }
}

/// The words of a command line, taken apart flag by flag.
struct Arguments {
  private(set) var words: [String]

  init(_ words: [String]) { self.words = words }

  /// Removes `name` and answers whether it was there.
  mutating func takeFlag(_ name: String) -> Bool {
    guard let index = words.firstIndex(of: name) else { return false }
    words.remove(at: index)
    return true
  }

  /// Removes `name` and its value.
  mutating func takeOption(_ name: String) throws -> String? {
    guard let index = words.firstIndex(of: name) else { return nil }
    guard index + 1 < words.count else { throw Usage("\(name) needs a value") }
    defer { words.removeSubrange(index...(index + 1)) }
    return words[index + 1]
  }

  /// Fails when anything starting with `-` is left, then returns the rest.
  func positional() throws -> [String] {
    if let stray = words.first(where: { $0.hasPrefix("-") }) { throw Usage("no option \(stray)") }
    return words
  }
}
