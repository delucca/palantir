import Foundation

/// Compiles jq expressions without running them.
protocol JQ {
  /// The compile error for `expression`, or nil when it compiles.
  func compileError(_ expression: String) throws -> String?
}

/// Checks a check against its rule without palantir: the format, the rule's ID and example, and
/// jq expressions that compile.
enum Lint {
  /// The names an action's `as` may not take: the record's own keys.
  static let reservedNames: Set<String> = ["files", "out", "uid", "pid"]

  /// The problems in `data` as a check for `rule`; none means the check is clean.
  static func problems(in data: Data, for rule: Rule, jq: some JQ) throws -> [String] {
    let check: Check
    do { check = try Check.decode(data) } catch { return ["not a check: \(error)"] }
    return try problems(in: check, for: rule, jq: jq)
  }

  /// - Parameter followsExample: whether the check must be the rule's own check: its example's
  ///   title and lines verbatim. A probe of an exploration varies the example and is not.
  static func problems(
    in check: Check, for rule: Rule, jq: some JQ, followsExample: Bool = true
  ) throws -> [String] {
    var problems: [String] = []
    if check.rule != rule.id { problems.append("rule is \(check.rule), not \(rule.id)") }
    if followsExample {
      if check.example != rule.exampleTitle {
        problems.append("example is \"\(check.example)\", not \"\(rule.exampleTitle ?? "")\"")
      }
      if check.steps.map(\.line) != rule.exampleLines {
        problems.append("the steps' lines are not the example's lines, in order and verbatim")
      }
    }
    for name in check.files.keys.sorted()
    where name.isEmpty || name.contains("/") || name.hasPrefix(".") {
      problems.append("the fixture name \"\(name)\" is empty, holds a folder or starts with a dot")
    }
    var scan = Scan(files: Set(check.files.keys))
    let phases = try? Phase.sequence(of: check.steps.map(\.line), for: check.rule)
    for (index, step) in check.steps.enumerated() {
      scan.phase = phases?[index]
      for action in step.actions { scan.visit(action) }
      for expectation in step.expect { scan.expressions.append(expectation.that) }
    }
    problems += scan.problems
    for expression in scan.expressions {
      if let message = try jq.compileError(expression) {
        problems.append("jq does not compile: \(expression): \(message)")
      }
    }
    return problems
  }

  /// A walk over the actions in the order they run.
  private struct Scan {
    let files: Set<String>
    var problems: [String] = []
    var expressions: [String] = []
    var names: Set<String> = []
    var outs: Set<String> = []
    var launched = false

    init(files: Set<String>) { self.files = files }

    /// The phase of the step being walked, when the example's lines give one.
    var phase: Phase?

    mutating func visit(_ action: Action) {
      if phase == .then, case .code(let code) = action.exit, code != 0 {
        problems.append(
          "a Then step expects exit \(code) from an action; record the exit with \"exit\": \"any\" and \"as\", and assert it in an expectation"
        )
      }
      if let name = action.name {
        if name.wholeMatch(of: /[a-zA-Z][a-zA-Z0-9]*/) == nil {
          problems.append("the observation name \"\(name)\" is not a letter and letters or digits")
        } else if Lint.reservedNames.contains(name) {
          problems.append("the observation name \"\(name)\" is a key of the record")
        } else if !names.insert(name).inserted {
          problems.append("the observation name \"\(name)\" is used twice")
        }
      }
      switch action.verb {
      case .launch: launched = true
      case .drive(let arguments):
        needsLaunch("drive")
        for argument in arguments { visitArgument(argument) }
      case .inspect(let arguments):
        if case .text("list") = arguments.first {} else { needsLaunch("inspect") }
        for argument in arguments { visitArgument(argument) }
      case .file(let name): fixture(name)
      case .stat(let argument): visitArgument(argument)
      case .symbols: break
      case .sleep(let seconds):
        if !(0...Settings.sleepLimit).contains(seconds) {
          problems.append("sleep takes 0 to \(Int(Settings.sleepLimit)) seconds, not \(seconds)")
        }
      case .quit:
        needsLaunch("quit")
        launched = false
      case .repeat(let body, let until, let max):
        if !(1...Settings.repeatLimit).contains(max) {
          problems.append("repeat takes max 1 to \(Settings.repeatLimit), not \(max)")
        }
        expressions.append(until)
        for inner in body { visit(inner) }
      }
    }

    private mutating func needsLaunch(_ verb: String) {
      if !launched { problems.append("\(verb) comes before any launch") }
    }

    private mutating func fixture(_ name: String) {
      if !files.contains(name) { problems.append("no fixture named \"\(name)\"") }
    }

    private mutating func visitArgument(_ argument: Argument) {
      switch argument {
      case .text, .number: break
      case .file(let name): fixture(name)
      case .jq(let expression): expressions.append(expression)
      case .out(let name):
        if name.wholeMatch(of: /[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.png/) == nil {
          problems.append("the out name \"\(name)\" is not a file name ending in .png")
        } else if !outs.insert(name).inserted {
          problems.append("the out name \"\(name)\" is used twice")
        }
      }
    }
  }
}
