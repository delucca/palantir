import Foundation

/// The judge: a model of another family reads a check against its rule and says whether each step
/// is faithful. Code decides from the problems it lists, not from the verdict it states.
enum Judge {
  /// Writes the judge's workspace: the rule's block, the check and the two references, and the
  /// prompt.
  static func prepare(run: URL, rule: Rule, check: Data) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: run, withIntermediateDirectories: true)
    try Data(rule.block.utf8).write(to: run.appending(path: "rule.md"))
    try check.write(to: run.appending(path: "check.json"))
    for name in ["cli.md", "format.md"] {
      try Data(Resources.text(name).utf8).write(to: run.appending(path: name))
    }
    try Data(Resources.text("judge.md").utf8).write(to: run.appending(path: "prompt.md"))
  }

  /// Decodes the judge's last message strictly.
  ///
  /// - Throws: `JudgeError` when it is not a review of `rule`, or says faithful with a blocking
  ///   problem or unfaithful with none.
  static func decode(_ data: Data, rule: Rule) throws -> Review {
    let review: Review
    do { review = try JSONDecoder().decode(Review.self, from: data) } catch {
      throw JudgeError("the judge's last message is not a review: \(error)")
    }
    guard review.rule == rule.id else {
      throw JudgeError("the judge reviewed \(review.rule), not \(rule.id)")
    }
    guard review.verdict == review.computedVerdict else {
      throw JudgeError(
        "the judge says \(review.verdict.rawValue) but its problems say \(review.computedVerdict.rawValue)"
      )
    }
    return review
  }
}

/// A judge that did not give a usable review.
struct JudgeError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}
