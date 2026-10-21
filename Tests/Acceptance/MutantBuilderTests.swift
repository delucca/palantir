import Foundation
import Testing

@testable import PalantirAcceptance

/// A runner that answers from a closure and records what it was asked.
final class RecordingRunner: Runner, @unchecked Sendable {
  var calls: [[String]] = []
  var answer: ([String]) throws -> Output = { _ in Output(exit: 0, stdout: "", stderr: "") }

  func run(_ program: String, _ arguments: [String], stdin: Data?, timeout: Double) throws -> Output
  {
    let call = [program] + arguments
    calls.append(call)
    return try answer(call)
  }
}

@Suite(.layer(.integration), .serialized)
struct MutantBuilderTests {
  let root = FileManager.default.temporaryDirectory.appending(path: "mutant-\(UUID().uuidString)")
  var cache: URL { root.appending(path: "cache") }
  var repository: URL { root.appending(path: "repo") }

  func builder(_ runner: RecordingRunner, available: Int64 = 100 << 30) -> GitMutantBuilder {
    var builder = GitMutantBuilder(runner: runner, repository: repository, cache: cache)
    builder.availableBytes = { available }
    return builder
  }

  /// A runner that makes what git and swift would make.
  func fakes() -> RecordingRunner {
    let runner = RecordingRunner()
    let workspace = cache.appending(path: "mutants/workspace")
    let bin = root.appending(path: "bin")
    runner.answer = { call in
      let manager = FileManager.default
      if call.contains("clone"), let target = call.last {
        try? manager.createDirectory(
          at: URL(fileURLWithPath: target).appending(path: ".git"),
          withIntermediateDirectories: true)
        try? manager.createDirectory(
          at: URL(fileURLWithPath: target).appending(path: "Sources/App"),
          withIntermediateDirectories: true)
        try? Data("plist".utf8).write(
          to: URL(fileURLWithPath: target).appending(path: "Sources/App/Info.plist"))
        try? manager.createDirectory(
          at: URL(fileURLWithPath: target).appending(path: "Tests/Acceptance/Checks"),
          withIntermediateDirectories: true)
      }
      if call.contains("--show-bin-path") {
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try? Data("exe".utf8).write(to: bin.appending(path: "palantir"))
        return Output(exit: 0, stdout: bin.path + "\n", stderr: "")
      }
      if call.contains("diff") {
        return Output(exit: 0, stdout: "diff --git a/x b/x\n", stderr: "")
      }
      _ = workspace
      return Output(exit: 0, stdout: "", stderr: "")
    }
    return runner
  }

  @Test func theWriterGetsACloneWithoutTheGeneratedChecksAndItsPatchIsAStagedDiff() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = fakes()
    let run = root.appending(path: "run")
    let workspace = try builder(runner).writerWorkspace(in: run)
    #expect(workspace == run.appending(path: "repo"))
    #expect(
      runner.calls[0] == [
        "/usr/bin/git", "clone", "--local", "--quiet", repository.path, workspace.path,
      ])
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.appending(path: "Tests/Acceptance/Checks").path))
    let patch = try builder(runner).patch(of: workspace)
    #expect(patch == "diff --git a/x b/x\n")
    #expect(runner.calls.contains(["/usr/bin/git", "-C", workspace.path, "add", "-A"]))
    #expect(runner.calls.last?.contains("--cached") == true)
  }

  // req~acceptance.gate~1
  @Test func aPatchIsBuiltInTheLayersCacheOutsideTheWritersFolderAndBundled() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = fakes()
    let bundle = root.appending(path: "run/mutant-1-build/palantir.app")
    try builder(runner).build(patch: "diff --git a/x b/x\n", into: bundle)
    let workspace = cache.appending(path: "mutants/workspace").path
    let swift = try #require(runner.calls.first { $0.first == "/usr/bin/swift" })
    #expect(swift.contains("--package-path") && swift.contains(workspace))
    #expect(swift.contains("--product") && swift.contains("palantir"))
    #expect(runner.calls.contains { $0.contains("apply") && $0.contains(workspace) })
    #expect(!runner.calls.joined().joined(separator: " ").contains("/run/repo"))
    #expect(
      runner.calls.last?.starts(with: ["/usr/bin/codesign", "--force", "--sign", "-"]) == true)
    #expect(
      FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/MacOS/palantir").path)
    )
    #expect(
      FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
    #expect(FileManager.default.fileExists(atPath: cache.appending(path: "mutant-build.lock").path))
    #expect(
      FileManager.default.fileExists(
        atPath: Mutant.releaseBundle(for: bundle).appending(path: "Contents/MacOS/palantir").path))
    for configuration in ["debug", "release"] {
      #expect(
        runner.calls.contains {
          $0.first == "/usr/bin/swift" && $0.contains(configuration)
            && !$0.contains("--show-bin-path")
        })
    }
  }

  @Test func theWorkspaceIsResetBeforeEveryPatchSoMutantsDoNotStack() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = fakes()
    let build = builder(runner)
    try build.build(patch: "p1", into: root.appending(path: "a/palantir.app"))
    try build.build(patch: "p2", into: root.appending(path: "b/palantir.app"))
    let resets = runner.calls.filter { $0.contains("reset") }
    #expect(resets.count == 2)
    #expect(runner.calls.filter { $0.contains("clone") }.count == 1)
  }

  @Test func committedChecksAreOmittedWithoutBecomingMutantDeletionsAndBuildsRefreshHEAD() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let real = SystemRunner()
    let manager = FileManager.default
    try manager.createDirectory(
      at: repository.appending(path: "Sources/App"), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: repository.appending(path: "Tests/Acceptance/Checks"), withIntermediateDirectories: true)
    func git(_ arguments: [String]) throws -> String {
      let result = try real.run(
        "/usr/bin/git",
        [
          "-C", repository.path, "-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c",
          "user.email=test@invalid",
        ] + arguments)
      #expect(result.exit == 0, "\(result.stderr)")
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try Data("old\n".utf8).write(to: repository.appending(path: "Sources/App/A.swift"))
    try Data("plist".utf8).write(to: repository.appending(path: "Sources/App/Info.plist"))
    try Data("check".utf8).write(
      to: repository.appending(path: "Tests/Acceptance/Checks/check.json"))
    _ = try git(["init", "--quiet"])
    _ = try git(["add", "-A"])
    _ = try git(["commit", "--quiet", "-m", "fixture"])
    let runner = fakes()
    let fake = runner.answer
    runner.answer = { call in
      if call[0] == "/usr/bin/git" {
        return try real.run(call[0], Array(call.dropFirst()))
      }
      return try fake(call)
    }
    let builder = builder(runner)
    let writer = try builder.writerWorkspace(in: root.appending(path: "writer"))
    #expect(
      !manager.fileExists(atPath: writer.appending(path: "Tests/Acceptance/Checks/check.json").path)
    )
    try Data("new\n".utf8).write(to: writer.appending(path: "Sources/App/A.swift"))
    let patch = try builder.patch(of: writer)
    #expect(Mutant.files(in: patch) == ["Sources/App/A.swift"])
    #expect(patch.contains("+new"))
    try builder.build(patch: patch, into: root.appending(path: "first.app"))
    try Data("advanced".utf8).write(to: repository.appending(path: "Sources/App/version"))
    _ = try git(["add", "-A"])
    _ = try git(["commit", "--quiet", "-m", "advance fixture"])
    let head = try git(["rev-parse", "HEAD"])
    try builder.build(patch: patch, into: root.appending(path: "second.app"))
    let workspace = cache.appending(path: "mutants/workspace")
    let builtHead = try real.run("/usr/bin/git", ["-C", workspace.path, "rev-parse", "HEAD"]).stdout
    #expect(builtHead.trimmingCharacters(in: .whitespacesAndNewlines) == head)
    #expect(
      try String(contentsOf: workspace.appending(path: "Sources/App/version"), encoding: .utf8)
        == "advanced")
  }

  @Test func noBuildStartsBelowTheDiskFloor() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = fakes()
    #expect(throws: MutantBuildError.self) {
      try builder(runner, available: 5 << 30).build(patch: "p", into: root.appending(path: "a"))
    }
    #expect(!runner.calls.contains { $0.first == "/usr/bin/swift" })
  }

  @Test func aPatchThatDoesNotApplyOrABuildThatFailsIsABuildError() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = fakes()
    let answer = runner.answer
    runner.answer = { call in
      call.contains("apply")
        ? Output(exit: 1, stdout: "", stderr: "corrupt patch") : try answer(call)
    }
    #expect(throws: MutantBuildError.self) {
      try builder(runner).build(patch: "p", into: root.appending(path: "a"))
    }
    let failing = fakes()
    let ok = failing.answer
    failing.answer = { call in
      call.first == "/usr/bin/swift" && !call.contains("--show-bin-path")
        ? Output(exit: 1, stdout: "", stderr: "error: compile") : try ok(call)
    }
    let error = #expect(throws: MutantBuildError.self) {
      try builder(failing).build(patch: "p", into: root.appending(path: "b"))
    }
    #expect(error?.description.contains("swift build failed") == true)
  }

  // req~acceptance.gate~1
  @Test func theBuildLockIsHeldFromTheResetToTheBundleCopyAndReleasedAfter() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = fakes()
    let answer = runner.answer
    let lockFile = cache.appending(path: "mutant-build.lock")
    nonisolated(unsafe) var heldAt: [String] = []
    runner.answer = { call in
      let probe = open(lockFile.path, O_RDWR)
      if probe >= 0 {
        if flock(probe, LOCK_EX | LOCK_NB) != 0 {
          heldAt.append(call.dropFirst().first ?? call[0])
        } else {
          flock(probe, LOCK_UN)
        }
        close(probe)
      }
      return try answer(call)
    }
    let bundle = root.appending(path: "a/palantir.app")
    try builder(runner).build(patch: "p", into: bundle)
    #expect(heldAt.contains("-C"))  // reset, clean, apply
    #expect(runner.calls.last?.first == "/usr/bin/codesign")
    #expect(heldAt.count >= runner.calls.count - 2)
    let after = open(lockFile.path, O_RDWR)
    defer { close(after) }
    #expect(flock(after, LOCK_EX | LOCK_NB) == 0)
  }

  // O3
  @Test func aDebugOnlyBuildMakesNoReleaseBundle() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = fakes()
    let bundle = root.appending(path: "a/palantir.app")
    try builder(runner).build(patch: "p", into: bundle, release: false)
    let builds = runner.calls.filter {
      $0.first == "/usr/bin/swift" && !$0.contains("--show-bin-path")
    }
    #expect(builds.count == 1 && builds[0].contains("debug"))
    #expect(!runner.calls.contains { $0.contains("release") })
    #expect(!FileManager.default.fileExists(atPath: Mutant.releaseBundle(for: bundle).path))
    let both = fakes()
    try builder(both).build(patch: "p", into: root.appending(path: "b/palantir.app"))
    #expect(both.calls.filter { $0.first == "/usr/bin/swift" && $0.contains("release") }.count == 2)
  }
}
