import Foundation
import Testing

@testable import PalantirAcceptance

/// A fake `tart` that keeps its VMs as files and logs every call, and a guest whose answers the
/// test sets.
struct FakeTart {
  let root: URL
  var script: URL { root.appending(path: "tart") }
  var log: URL { root.appending(path: "tart.log") }
  var out: URL { root.appending(path: "guest-out") }
  var vms: URL { root.appending(path: "vms") }

  init(
    answersTrue: Bool = true, locked: Bool = false, replayExit: Int = 0, replayStdout: String = ""
  ) throws {
    root = FileManager.default.temporaryDirectory.appending(path: "fake-tart-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appending(path: "vms"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "guest-out"), withIntermediateDirectories: true)
    try Data(replayStdout.utf8).write(to: root.appending(path: "replay-stdout"))
    try Data("palantir-acceptance\n".utf8).write(to: vms.appending(path: ".prepared"))
    let text = """
      #!/bin/bash
      echo "$@" >> '\(log.path)'
      V='\(vms.path)'
      case "$1" in
        list) echo palantir-acceptance ;;
        clone) touch "$V/$3" ;;
        run) name="${@: -1}"; touch "$V/$name.running"; while [ -e "$V/$name" ]; do sleep 0.05; done ;;
        stop) rm -f "$V/$2.running" ;;
        delete) rm -f "$V/$2" ;;
        exec)
          shift
          if [ "$1" = "-i" ]; then shift; cat > "$V/stdin.last"; fi
          shift
          case "$*" in
            "/usr/bin/true") \(answersTrue ? "exit 0" : "exit 1") ;;
            *"sw_vers -productVersion"*|"/usr/bin/sw_vers -productVersion") echo 27.0.0 ;;
            "/usr/bin/sw_vers -buildVersion") echo 26A428 ;;
            "/usr/sbin/ioreg -n Root -d1") echo '"CGSSessionScreenIsLocked"=\(locked ? "Yes" : "No")' ;;
            "/usr/bin/jq --version") echo jq-1.7.1 ;;
            *"/usr/bin/tar"*"-cf -"*) tar -C '\(out.path)' -cf - . ;;
            *"palantir-accept replay"*|*"palantir-accept"*) cat '\(root.path)/replay-stdout'; exit \(replayExit) ;;
            *) : ;;
          esac ;;
      esac
      """
    try Data(text.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  }

  func config(available: Int64 = 100 << 30, bootTimeout: Double = 20) -> VMConfig {
    var config = VMConfig(tart: script.path, tartHome: root.appending(path: "home"))
    config.availableBytes = { available }
    config.bootTimeout = bootTimeout
    return config
  }

  var calls: [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.layer(.integration), .serialized)
struct MachineTests {
  func session(_ tart: FakeTart, available: Int64 = 100 << 30, bootTimeout: Double = 20)
    -> VMSession
  {
    VMSession(
      config: tart.config(available: available, bootTimeout: bootTimeout),
      executor: SystemExecutor(),
      scratch: tart.root.appending(path: "scratch"), name: "run-1")
  }

  // req~acceptance.machines~1
  @Test func aRunCloneIsClonedBootedHeadlessAndStoppedAndDeletedAtTheEnd() throws {
    let tart = try FakeTart()
    defer { tart.remove() }
    let session = session(tart)
    try session.start()
    #expect(FileManager.default.fileExists(atPath: tart.vms.appending(path: "run-1").path))
    session.shutdown()
    let calls = tart.calls
    #expect(calls.first == "list --quiet")
    #expect(calls.contains("clone palantir-acceptance run-1"))
    #expect(calls.contains("run --no-graphics --no-audio --no-clipboard run-1"))
    let clone = try #require(calls.firstIndex(of: "clone palantir-acceptance run-1"))
    let stop = try #require(calls.firstIndex(of: "stop run-1"))
    let delete = try #require(calls.firstIndex(of: "delete run-1"))
    #expect(clone < stop && stop < delete)
    #expect(!FileManager.default.fileExists(atPath: tart.vms.appending(path: "run-1").path))
    session.shutdown()
    #expect(tart.calls.filter { $0 == "delete run-1" }.count == 1)
  }

  // req~acceptance.machines~1
  @Test func noCloneStartsBelowTheDiskFloor() throws {
    let tart = try FakeTart()
    defer { tart.remove() }
    #expect(throws: MachineError.self) { try session(tart, available: 5 << 30).start() }
    #expect(!tart.calls.contains { $0.hasPrefix("clone") })
  }

  @Test func aCloneThatNeverAnswersIsStoppedAndDeletedAndTheStartFails() throws {
    let tart = try FakeTart(answersTrue: false)
    defer { tart.remove() }
    let error = #expect(throws: MachineError.self) { try session(tart, bootTimeout: 2).start() }
    #expect(error?.description.contains("did not answer tart exec") == true)
    #expect(tart.calls.contains("delete run-1"))
    #expect(!FileManager.default.fileExists(atPath: tart.vms.appending(path: "run-1").path))
  }

  @Test func theGuestIsAskedItsMacOSAndALockedSessionFailsThePreflight() throws {
    let open = try FakeTart()
    defer { open.remove() }
    let session1 = session(open)
    try session1.start()
    defer { session1.shutdown() }
    let machine = try session1.preflight()
    #expect(machine.macos == "Version 27.0.0 (Build 26A428)")
    let locked = try FakeTart(locked: true)
    defer { locked.remove() }
    let session2 = session(locked)
    try session2.start()
    defer { session2.shutdown() }
    #expect(throws: MachineError.self) { _ = try session2.preflight() }
  }

  // req~acceptance.machines~1
  @Test func aVMReplayCopiesTheBuildInRunsEveryCheckAndBringsTheVerdictsBack() throws {
    let tart = try FakeTart(replayExit: 0, replayStdout: "req~a.b~1\tpass\t1.0s\n1 rules: 1 pass\n")
    defer { tart.remove() }
    let file = VerdictsFile(
      build: .init(debugAppSha256: "abc", releaseAppSha256: nil),
      machine: Machine(host: "guest", macos: "x"), verdicts: ["req~a.b~1": "pass"])
    try JSONEncoder().encode(file).write(to: tart.out.appending(path: "verdicts.json"))
    let stage = tart.root.appending(path: "stage.tar")
    try Data("tar".utf8).write(to: stage)
    let session = session(tart)
    try session.start()
    defer { session.shutdown() }
    let destination = tart.root.appending(path: "result")
    let result = try VMReplay.run(session: session, stage: stage, destination: destination)
    #expect(result.exit == 0)
    #expect(result.output.contains("1 rules: 1 pass"))
    #expect(result.verdicts?.verdicts == ["req~a.b~1": "pass"])
    #expect(result.verdicts?.machine.macos == "Version 27.0.0 (Build 26A428)")
    #expect(result.verdicts?.host?.macos.isEmpty == false)
    let stored = try JSONDecoder().decode(
      VerdictsFile.self, from: Data(contentsOf: destination.appending(path: "verdicts.json")))
    #expect(stored.host != nil)
    let replay = try #require(tart.calls.first { $0.contains("replay --all") })
    #expect(replay.contains("--json /Users/admin/acceptance/out/verdicts.json"))
    #expect(replay.contains("--checks /Users/admin/acceptance/checks"))
    #expect(try Data(contentsOf: tart.vms.appending(path: "stdin.last")) == Data("tar".utf8))
  }

  @Test func aFailingReplayInTheGuestKeepsItsExitCode() throws {
    let tart = try FakeTart(replayExit: 1, replayStdout: "req~a.b~1\tfail\n")
    defer { tart.remove() }
    try Data("tar".utf8).write(to: tart.root.appending(path: "stage.tar"))
    let session = session(tart)
    try session.start()
    defer { session.shutdown() }
    let result = try VMReplay.run(
      session: session, stage: tart.root.appending(path: "stage.tar"),
      destination: tart.root.appending(path: "result"))
    #expect(result.exit == 1)
  }

  // req~acceptance.machines~1
  @Test func generationReplaysShareOneBootedCloneAndHoldTheHostLockPerReplay() throws {
    let tart = try FakeTart()
    defer { tart.remove() }
    let report = AcceptedFolder.report(rule: "req~a.b~1", sha: "s", verdict: .pass, failure: nil)
    try JSONEncoder().encode(report).write(to: tart.out.appending(path: "replay.json"))
    let bin = tart.root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["palantir-drive", "palantir-inspect", "palantir-accept"] {
      try Data(name.utf8).write(to: bin.appending(path: name))
    }
    let app = tart.root.appending(path: "palantir.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let check = tart.root.appending(path: "check.json")
    try Data("{}".utf8).write(to: check)
    let service = VMReplayService(
      config: tart.config(), cache: tart.root.appending(path: "cache"), bin: bin, debugApp: app,
      releaseApp: app)
    defer { service.finish() }
    let first = try service.replay(check: check, app: nil, into: tart.root.appending(path: "r1"))
    try FileManager.default.createDirectory(
      at: Mutant.releaseBundle(for: app), withIntermediateDirectories: true)
    let second = try service.replay(check: check, app: app, into: tart.root.appending(path: "r2"))
    #expect(first.verdict == .pass && second.verdict == .pass)
    #expect(tart.calls.filter { $0.hasPrefix("clone") }.count == 1)
    #expect(tart.calls.filter { $0.hasPrefix("run ") }.count == 1)
    #expect(
      FileManager.default.fileExists(atPath: tart.root.appending(path: "cache/vm-replay.lock").path)
    )
    #expect(
      tart.calls.contains {
        $0.contains("replay /Users/admin/acceptance/work/2/check.json")
          && $0.contains("--app /Users/admin/acceptance/work/2/palantir.app")
          && $0.contains("--release-app /Users/admin/acceptance/work/2/palantir-release.app")
      })
    #expect(
      tart.calls.contains {
        $0.contains("work/1/check.json")
          && $0.contains("--app /Users/admin/acceptance/palantir.app")
      })
    service.finish()
    #expect(tart.calls.contains { $0.hasPrefix("delete ") })
  }
}

@Suite(.layer(.unit))
struct CompareTests {
  func file(_ verdicts: [String: String], sha: String = "a") -> VerdictsFile {
    VerdictsFile(
      build: .init(debugAppSha256: sha, releaseAppSha256: nil),
      machine: Machine(host: "h", macos: "m"),
      verdicts: verdicts)
  }

  // req~acceptance.machines~1
  @Test func machinesThatGiveEveryRuleTheSameVerdictOfTheSameBuildAgree() {
    let a = file(["r1": "pass", "r2": "fail"])
    #expect(Compare.differences(host: a, vm: file(["r1": "pass", "r2": "fail"])) == [])
  }

  // req~acceptance.machines~1
  @Test func aRuleWhoseVerdictsDifferOrIsMissingOnOneSideIsADifference() {
    let diffs = Compare.differences(
      host: file(["r1": "pass", "r2": "pass"]), vm: file(["r1": "fail", "r3": "pass"]))
    #expect(
      diffs == ["r1\thost pass\tvm fail", "r2\thost pass\tvm absent", "r3\thost absent\tvm pass"])
  }

  // req~acceptance.machines~1
  @Test func releaseBuildDifferencesIncludeAMissingReleaseHash() {
    var host = file(["r1": "pass"])
    var vm = host
    host.build.releaseAppSha256 = "release-a"
    #expect(Compare.differences(host: host, vm: vm).count == 1)
    vm.build.releaseAppSha256 = "release-b"
    #expect(
      Compare.differences(host: host, vm: vm) == [
        "the release build differs: host release-a, vm release-b"
      ])
    vm.build.releaseAppSha256 = "release-a"
    #expect(Compare.differences(host: host, vm: vm).isEmpty)
  }

  @Test func aDifferentBuildIsADifferenceEvenWhenTheVerdictsAgree() {
    let diffs = Compare.differences(
      host: file(["r1": "pass"], sha: "a"), vm: file(["r1": "pass"], sha: "b"))
    #expect(diffs.count == 1 && diffs[0].hasPrefix("the debug build differs"))
  }
}

@Suite(.layer(.integration), .serialized)
struct BatchTests {
  func service(_ tart: FakeTart) throws -> (VMReplayService, URL) {
    let report = AcceptedFolder.report(rule: "req~a.b~1", sha: "s", verdict: .pass, failure: nil)
    try JSONEncoder().encode(report).write(to: tart.out.appending(path: "replay.json"))
    let bin = tart.root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["palantir-drive", "palantir-inspect", "palantir-accept"] {
      try Data(name.utf8).write(to: bin.appending(path: name))
    }
    let app = tart.root.appending(path: "palantir.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let check = tart.root.appending(path: "check.json")
    try Data("{}".utf8).write(to: check)
    return (
      VMReplayService(
        config: tart.config(), cache: tart.root.appending(path: "cache"), bin: bin, debugApp: app,
        releaseApp: app), check
    )
  }

  let rule = Rule(
    id: "req~a.b~1", feature: "a", slug: "b", version: 1, block: "b", exampleTitle: nil,
    exampleLines: [])

  func runs(_ tart: FakeTart) -> Int { tart.calls.filter { $0.hasPrefix("clone") }.count }
  func clones(_ tart: FakeTart) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: tart.vms.path)) ?? []).filter {
      $0.hasPrefix("palantir-acceptance-run") && !$0.hasSuffix(".running")
    }
  }

  // req~acceptance.machines~1
  @Test func theCloneIsDeletedWhenEveryRuleIsAccepted() throws {
    let tart = try FakeTart()
    defer { tart.remove() }
    let (machine, check) = try service(tart)
    let code = Batch.run(
      [rule], keepGoing: true, machine: machine,
      attempt: { _, _ in
        _ = try machine.replay(check: check, app: nil, into: tart.root.appending(path: "r"))
        return .accepted
      }, id: { _ in "id" })
    #expect(code == 0)
    #expect(runs(tart) == 1 && clones(tart).isEmpty)
    #expect(tart.calls.contains { $0.hasPrefix("delete ") })
  }

  // req~acceptance.machines~1
  @Test func theCloneIsDeletedWhenARuleEndsUngatedOrFailsWithAnError() throws {
    let tart = try FakeTart()
    defer { tart.remove() }
    let (machine, check) = try service(tart)
    var next = 0
    var outcomes: [String] = []
    let code = Batch.run(
      [rule, rule], keepGoing: true, machine: machine,
      attempt: { _, name in
        _ = try machine.replay(check: check, app: nil, into: tart.root.appending(path: name))
        outcomes.append(name)
        if name == "second" {
          throw ReplayFailed(
            AcceptedFolder.report(
              rule: "r", sha: "s", verdict: .error, failure: Failure(kind: "launch")))
        }
        return .ungated(stage: "judge")
      },
      id: { _ in
        next += 1
        return next == 1 ? "first" : "second"
      })
    #expect(outcomes == ["first", "second"])
    #expect(code == 2)
    #expect(clones(tart).isEmpty)
    let one = try FakeTart()
    defer { one.remove() }
    let (machine1, check1) = try service(one)
    let code1 = Batch.run(
      [rule], keepGoing: false, machine: machine1,
      attempt: { _, _ in
        _ = try machine1.replay(check: check1, app: nil, into: one.root.appending(path: "r"))
        return .ungated(stage: "mutant")
      }, id: { _ in "id" })
    #expect(code1 == 1)
    #expect(clones(one).isEmpty)
  }
}
