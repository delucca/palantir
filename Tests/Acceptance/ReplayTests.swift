import Foundation
import Testing

@testable import PalantirAcceptance

/// Serialized: a replay blocks its thread on subprocesses, and several at once would take every
/// thread of the pool that delivers their exits.
@Suite(.layer(.integration), .serialized)
struct ReplayTests {
  /// A check of `steps`, each `(line, actions, expectations)` as JSON text.
  static func check(
    _ steps: [(String, String, String)], files: String = "{\"n.md\": \"# One\\n\"}"
  ) throws -> (Check, Data) {
    let body = steps.map {
      """
      {"line": "\($0.0)", "do": [\($0.1)], "expect": \($0.2)}
      """
    }.joined(separator: ",")
    let data = Data(
      """
      {"format": 1, "rule": "req~a.b~1", "example": "x", "files": \(files), "steps": [\(body)]}
      """.utf8)
    return (try Check.decode(data), data)
  }

  static let launch = "{\"launch\": {\"build\": \"debug\", \"inspector\": true}}"

  func replay(_ world: FakeWorld, _ check: (Check, Data)) throws -> (ReplayReport, URL) {
    let directory = world.root.appending(path: "out-\(UUID().uuidString)")
    let report = try world.replayer().replay(
      check.0, data: check.1, path: "check.json", into: directory)
    return (report, directory)
  }

  @Test func unsafeFixtureNamesCannotWriteOutsideTheReplayDirectory() throws {
    let world = try FakeWorld()
    for name in ["../escaped", "../../escaped", "/escaped", "", ".hidden", "x\0y"] {
      var check = try Self.check([])
      check.0.files = [name: "overwrite"]
      let directory = world.root.appending(path: "unsafe")
      #expect(throws: CheckError.self) {
        try world.replayer().replay(check.0, data: check.1, path: "check.json", into: directory)
      }
      #expect(!FileManager.default.fileExists(atPath: directory.path))
      #expect(!FileManager.default.fileExists(atPath: world.root.appending(path: "escaped").path))
      #expect(world.palantirPids().isEmpty)
    }
  }

  @Test func aCheckWhoseExpectationsAreTrueIsAPass() throws {
    let world = try FakeWorld()
    world.inspect = { _ in Output(exit: 0, stdout: "{\"length\": 7}", stderr: "") }
    let check = try Self.check([
      (
        "* Given x", "\(Self.launch), {\"inspect\": [\"state\"], \"as\": \"s\"}",
        "[{\"that\": \".s.json.length == 7\"}]"
      ),
      ("* Then y", "{\"quit\": true}", "[{\"that\": \".uid | type == \\\"number\\\"\"}]"),
    ])
    let (report, directory) = try replay(world, check)
    #expect(report.verdict == .pass)
    #expect(report.failure == nil)
    #expect(report.steps.map(\.phase) == [.given, .then])
    #expect(
      report.steps[0].expect == [ExpectationReport(that: ".s.json.length == 7", value: "true")])
    #expect(report.modelCalls == 0)
    #expect(report.jq.hasPrefix("jq-"))
    for name in ["replay.json", "record.json"] {
      #expect(FileManager.default.fileExists(atPath: directory.appending(path: name).path))
    }
    #expect(world.palantirPids().isEmpty)
  }

  @Test func anUnexpectedReadErrorStillQuitsAndWritesANoVerdictReport() throws {
    let world = try FakeWorld()
    let directory = world.root.appending(path: "io-error")
    var removed = false
    world.inspect = { _ in
      if !removed {
        do {
          try FileManager.default.removeItem(at: directory.appending(path: "files/n.md"))
          removed = true
        } catch { Issue.record(error) }
      }
      return Output(exit: 0, stdout: "{}", stderr: "")
    }
    let check = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"inspect\": [\"state\"]}, {\"file\": \"n.md\", \"as\": \"contents\"}",
        "[]"
      )
    ])
    let report = try world.replayer().replay(
      check.0, data: check.1, path: "check.json", into: directory)
    #expect(report.verdict == .error)
    #expect(report.failure?.kind == "replay")
    #expect(world.palantirPids().isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "replay.json").path))
  }

  @Test func anExpectationThatPrintsFalseFailsAtItsStepAndPhase() throws {
    let world = try FakeWorld()
    world.inspect = { _ in Output(exit: 0, stdout: "{\"length\": 7}", stderr: "") }
    let check = try Self.check([
      ("* Given x", "\(Self.launch), {\"inspect\": [\"state\"], \"as\": \"s\"}", "[]"),
      ("* When z", "{\"sleep\": 0}", "[]"),
      ("* Then y", "{\"sleep\": 0}", "[{\"that\": \".s.json.length == 8\"}]"),
      ("* And w", "{\"sleep\": 0}", "[]"),
    ])
    let (report, _) = try replay(world, check)
    #expect(report.verdict == .fail)
    #expect(report.failure?.kind == "expect")
    #expect(report.failure?.step == 2)
    #expect(report.failure?.phase == .then)
    #expect(report.failure?.value == "false")
    #expect(report.failure?.that == ".s.json.length == 8")
    #expect(report.steps.count == 3)
    #expect(world.palantirPids().isEmpty)
  }

  // req~acceptance.replay~1
  @Test func aJQErrorIsRecordedAsAnErrorAndNeverAsFalse() throws {
    let world = try FakeWorld()
    let check = try Self.check([
      ("* Given x", Self.launch, "[{\"that\": \".uid | error(\\\"boom\\\")\"}]")
    ])
    let (report, _) = try replay(world, check)
    #expect(report.verdict == .fail)
    #expect(report.failure?.kind == "expect")
    #expect(report.failure?.value?.hasPrefix("error: ") == true)
    #expect(report.failure?.value?.contains("boom") == true)
  }

  @Test func anActionThatExitsOtherThanExpectedFailsAndAnExpectedNonZeroExitPasses() throws {
    let world = try FakeWorld()
    world.drive = { _ in Output(exit: 1, stdout: "", stderr: "is disabled") }
    let failing = try Self.check([
      ("* Given x", "\(Self.launch), {\"drive\": [\"menu\", \"View > Fold All\"]}", "[]")
    ])
    let (failed, _) = try replay(world, failing)
    #expect(failed.verdict == .fail)
    #expect(failed.failure?.kind == "action")
    #expect(failed.failure?.message?.contains("exited 1, the check expects 0") == true)
    let passing = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"drive\": [\"menu\", \"View > Fold All\"], \"exit\": 1, \"as\": \"m\"}",
        "[{\"that\": \".m.stderr == \\\"is disabled\\\"\"}]"
      )
    ])
    #expect(try replay(world, passing).0.verdict == .pass)
  }

  // O1
  @Test func anUnsafeOutNameWritesNothingAndFailsTheAction() throws {
    let world = try FakeWorld()
    for name in ["../escape.png", "a/b.png", ".hidden.png", ""] {
      let check = try Self.check([
        (
          "* Given x",
          "\(Self.launch), {\"inspect\": [\"screenshot\", {\"out\": \"\(name)\"}]}", "[]"
        )
      ])
      let (report, directory) = try replay(world, check)
      #expect(report.verdict == .fail, "\(name)")
      #expect(report.failure?.message?.hasPrefix("unsafe out name") == true, "\(name)")
      #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "escape.png").path))
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.deletingLastPathComponent().appending(path: "escape.png").path))
    }
  }

  @Test func exitAnyNeverFailsOnTheExitAndTheExitLandsInTheRecord() throws {
    let world = try FakeWorld()
    world.inspect = { arguments in
      Output(exit: arguments.first == "state" ? 2 : 0, stdout: "", stderr: "no inspector")
    }
    let check = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"inspect\": [\"state\"], \"exit\": \"any\", \"as\": \"s\"}",
        "[{\"that\": \".s.exit == 2\"}]"
      )
    ])
    let (report, _) = try replay(world, check)
    #expect(report.verdict == .pass)
    let wrong = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"inspect\": [\"state\"], \"exit\": \"any\", \"as\": \"s\"}",
        "[{\"that\": \".s.exit == 0\"}]"
      )
    ])
    let (failed, _) = try replay(world, wrong)
    #expect(failed.verdict == .fail)
    #expect(failed.failure?.kind == "expect" && failed.failure?.value == "false")
  }

  @Test func menusAndTreeAndListAreParsedIntoTheRecord() throws {
    let world = try FakeWorld()
    world.drive = { arguments in
      switch arguments.first {
      case "menus":
        return Output(
          exit: 0,
          stdout: "View > Fold All\tenabled\tpress\tcmd+shift+f\nView\tdisabled\tno-press\t-\n",
          stderr: "")
      case "tree":
        return Output(
          exit: 0,
          stdout:
            "AXWindow title=\"palantir\" frame=1,2,30,40 actions=AXRaise\n  AXTextArea label=\"Folded \\\"x\\\"\"\n",
          stderr: "")
      default: return Output(exit: 0, stdout: "", stderr: "")
      }
    }
    world.inspect = { arguments in
      arguments.first == "list"
        ? Output(exit: 0, stdout: "123\t/tmp/a.sock\n", stderr: "")
        : Output(exit: 0, stdout: "{}", stderr: "")
    }
    let check = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"drive\": [\"menus\"], \"as\": \"m\"}, {\"drive\": [\"tree\"], \"as\": \"t\"}, {\"inspect\": [\"list\"], \"as\": \"l\"}",
        "[{\"that\": \".m.items[0] == {path: \\\"View > Fold All\\\", enabled: true, press: true, key: \\\"cmd+shift+f\\\"}\"}, {\"that\": \".m.items[1].enabled == false and .m.items[1].press == false\"}, {\"that\": \".t.elements[0] == {depth: 0, role: \\\"AXWindow\\\", title: \\\"palantir\\\", frame: [1,2,30,40], actions: [\\\"AXRaise\\\"]}\"}, {\"that\": \".t.elements[1].label == \\\"Folded \\\\\\\"x\\\\\\\"\\\" and .t.elements[1].depth == 1\"}, {\"that\": \".l.sockets == [{pid: 123, path: \\\"/tmp/a.sock\\\"}]\"}]"
      )
    ])
    let (report, _) = try replay(world, check)
    #expect(report.failure == nil)
    #expect(report.verdict == .pass)
  }

  @Test func repeatRunsItsBodyUntilTheConditionHoldsOrFailsAfterMax() throws {
    let world = try FakeWorld()
    let counter = Counter()
    world.drive = { _ in Output(exit: 0, stdout: "\(counter.next())", stderr: "") }
    let ok = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"repeat\": [{\"drive\": [\"scroll\", 1], \"as\": \"d\"}], \"until\": \".d.stdout == \\\"3\\\"\", \"max\": 5}",
        "[]"
      )
    ])
    #expect(try replay(world, ok).0.verdict == .pass)
    let never = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"repeat\": [{\"drive\": [\"scroll\", 1], \"as\": \"d\"}], \"until\": \".d.stdout == \\\"zzz\\\"\", \"max\": 2}",
        "[]"
      )
    ])
    let (report, _) = try replay(world, never)
    #expect(report.verdict == .fail)
    #expect(report.failure?.kind == "action")
    #expect(report.failure?.message?.contains("still not true after 2 rounds") == true)
  }

  @Test func aJQArgumentThatPrintsTwoLinesFailsTheAction() throws {
    let world = try FakeWorld()
    let check = try Self.check([
      ("* Given x", "\(Self.launch), {\"drive\": [\"click\", {\"jq\": \"1, 2\"}, 3]}", "[]")
    ])
    let (report, _) = try replay(world, check)
    #expect(report.verdict == .fail)
    #expect(report.failure?.kind == "action")
    #expect(report.failure?.message?.contains("more than one line") == true)
  }

  @Test func fileStatAndSymbolsObservePathsAndTheBuild() throws {
    let world = try FakeWorld()
    let check = try Self.check([
      (
        "* Given x",
        "{\"file\": \"n.md\", \"as\": \"f\"}, {\"stat\": {\"file\": \"n.md\"}, \"as\": \"s\"}, {\"stat\": \"/no/such/path\", \"as\": \"gone\"}",
        "[{\"that\": \".f.size == 6 and (.f.sha256 | length) == 64 and .f.mtime > 0\"}, {\"that\": \".s.exists and (.s.isDirectory | not) and .s.uid == .uid\"}, {\"that\": \".gone == {exists: false}\"}]"
      )
    ])
    let (report, _) = try replay(world, check)
    #expect(report.failure == nil)
    #expect(report.verdict == .pass)
  }

  // req~acceptance.replay~1
  @Test func aReplayStartsOnlyTheAllowedPrograms() throws {
    let world = try FakeWorld()
    let check = try Self.check([
      (
        "* Given x",
        "\(Self.launch), {\"drive\": [\"menus\"]}, {\"inspect\": [\"state\"]}, {\"symbols\": \"debug\"}, {\"quit\": true}",
        "[{\"that\": \"true\"}]"
      )
    ])
    let (report, _) = try replay(world, check)
    let allowed: Set<String> = [
      Settings.open, Settings.lsappinfo, Settings.jq, Settings.nm,
      world.bin.appending(path: Settings.driverName).path,
      world.bin.appending(path: Settings.inspectorName).path,
    ]
    #expect(Set(report.subprocesses).isSubset(of: allowed))
    #expect(report.subprocesses.contains(Settings.open))
    #expect(report.modelCalls == 0)
  }

  // req~acceptance.replay~1
  @Test func theSourcesImportOnlyFoundationAndCryptoKit() throws {
    let sources = repositoryRoot.appending(path: "Sources/Acceptance")
    let files = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var imports: Set<String> = []
    for case let file as URL in files where file.pathExtension == "swift" {
      for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
      where line.hasPrefix("import ") {
        imports.insert(String(line.dropFirst(7)))
      }
    }
    #expect(imports.isSubset(of: ["Foundation", "CryptoKit"]))
    #expect(imports.contains("Foundation"))
  }

  @Test func anUntrustedDriverMakesTheVerdictAnErrorNeverAFail() throws {
    let world = try FakeWorld()
    world.drive = { _ in
      Output(
        exit: 1, stdout: "",
        stderr:
          "palantir-drive: the app this runs under has no Accessibility grant; grant it in System Settings"
      )
    }
    let check = try Self.check([("* Given x", Self.launch, "[{\"that\": \"false\"}]")])
    let (report, _) = try replay(world, check)
    #expect(report.verdict == .error)
    #expect(report.failure?.kind == "driver")
    #expect(report.failure?.message?.contains("Accessibility grant") == true)
    #expect(
      world.calls(to: "palantir-drive").first?.starts(with: ["--pid", String(getpid())]) == true)
    #expect(world.calls.contains { $0.program == Settings.open } == false)
  }

  @Test func aPalantirThatWillNotQuitIsTerminatedAndTheVerdictIsAnError() throws {
    let world = try FakeWorld()
    world.ignoresQuit = true
    let check = try Self.check([("* Given x", Self.launch, "[{\"that\": \"true\"}]")])
    let (report, _) = try replay(world, check)
    #expect(report.verdict == .error)
    #expect(report.failure?.kind == "teardown")
    #expect(world.palantirPids().isEmpty)
  }

  @Test func aLaunchThatDropsTheInspectorFlagIsAnErrorNamingTheCause() throws {
    let world = try FakeWorld()
    world.dropsArguments = true
    let check = try Self.check([("* Given x", Self.launch, "[]")])
    let (report, _) = try replay(world, check)
    #expect(report.verdict == .error)
    #expect(report.failure?.kind == "launch")
    #expect(report.failure?.message?.contains("dropped the flag") == true)
    #expect(world.palantirPids().isEmpty)
  }

  @Test func aReplayPastItsDeadlineEndsAsAnError() throws {
    let world = try FakeWorld()
    let check = try Self.check([
      ("* Given x", "\(Self.launch), {\"sleep\": 0.3}, {\"sleep\": 0.3}", "[]")
    ])
    let directory = world.root.appending(path: "slow")
    let report = try world.replayer(deadline: 0.2).replay(
      check.0, data: check.1, path: "c.json", into: directory)
    #expect(report.verdict == .error)
    #expect(report.failure?.kind == "timeout")
  }

  @Test func theOutArgumentIsANewPathInTheReplayFolderAndTheRecordHoldsIt() throws {
    let world = try FakeWorld()
    let check = try Self.check([
      (
        "* Given x", "\(Self.launch), {\"inspect\": [\"screenshot\", {\"out\": \"a.png\"}]}",
        "[{\"that\": \".out[\\\"a.png\\\"] | endswith(\\\"/out/a.png\\\")\"}]"
      )
    ])
    let (report, directory) = try replay(world, check)
    #expect(report.verdict == .pass)
    #expect(
      world.calls(to: "palantir-inspect").contains {
        $0.last == directory.appending(path: "out/a.png").path
      })
  }
}

final class Counter: @unchecked Sendable {
  private var value = 0
  private let lock = NSLock()

  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}
