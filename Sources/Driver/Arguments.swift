import Foundation

/// Command-line values the driver checks before it touches anything.
enum Arguments {
  /// The most lines one `scroll` takes, either way.
  static let scrollLimit: Int32 = 1_000

  /// A process id given to `option`: a positive number.
  static func pid(_ text: String, option: String) throws -> pid_t {
    guard let pid = pid_t(text), pid > 0 else { throw Usage("\(option) \(text)") }
    return pid
  }

  static func scrollLines(_ text: String) throws -> Int32 {
    guard let lines = Int32(text), (-scrollLimit...scrollLimit).contains(lines) else {
      throw Usage("scroll takes a number of lines from -\(scrollLimit) to \(scrollLimit)")
    }
    return lines
  }

  /// Fails when `command` was given arguments it does not take.
  static func noneLeft(_ rest: [String], for command: String) throws {
    guard rest.isEmpty else { throw Usage("\(command) takes no \(rest.joined(separator: " "))") }
  }
}
