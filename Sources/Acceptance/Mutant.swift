import Foundation

/// What a mutant writer says about its change, `mutant.json` without the layer's fields.
struct MutantNotes: Codable, Equatable {
  var files: [String]
  var breaks: String
  var keeps: String
}

/// `mutant.json`: the writer's notes and what the layer added.
struct MutantFile: Codable, Equatable {
  var files: [String]
  var breaks: String
  var keeps: String
  var model: String
  var patchSha256: String
}

enum Mutant {
  /// The release counterpart of a mutant's debug app bundle.
  static func releaseBundle(for debug: URL) -> URL {
    debug.deletingLastPathComponent().appending(path: "palantir-release.app")
  }

  /// The paths a mutant of `rule` may change: feature code, and for an inspector rule the
  /// inspector's library and its notebook section, never its command-line tool.
  static func allowedPaths(for rule: Rule) -> [String] {
    var paths = ["Sources/App/", "Sources/Notebook/Model/", "Sources/Notebook/UI/"]
    if rule.feature == "inspector" {
      paths += ["Sources/Inspector/", "Sources/Notebook/Inspector/"]
    }
    return paths
  }

  /// The paths a mutant must not touch even inside an allowed folder.
  static let forbiddenPaths = ["Sources/Inspector/CLI/"]

  /// The files a unified diff changes, new and old names alike.
  static func files(in patch: String) -> [String] {
    var files: [String] = []
    for line in patch.split(separator: "\n", omittingEmptySubsequences: true)
    where line.hasPrefix("diff --git ") {
      for part in line.dropFirst("diff --git ".count).split(separator: " ") {
        let name =
          part.hasPrefix("a/") || part.hasPrefix("b/") ? String(part.dropFirst(2)) : String(part)
        if !files.contains(name) { files.append(name) }
      }
    }
    return files
  }

  /// The reason `patch` is not an acceptable mutant of `rule`, or nil.
  static func problem(with patch: String, for rule: Rule) -> String? {
    let files = Self.files(in: patch)
    guard !files.isEmpty else { return "the patch changes nothing" }
    let allowed = allowedPaths(for: rule)
    for file in files {
      if file.contains("..") || forbiddenPaths.contains(where: { file.hasPrefix($0) })
        || !allowed.contains(where: { file.hasPrefix($0) })
      {
        return "the patch changes \(file), outside the paths a mutant of \(rule.id) may change"
      }
    }
    return nil
  }

  /// The writer's prompt for `rule`.
  static func prompt(for rule: Rule) throws -> String {
    let hints =
      try JSONSerialization.jsonObject(
        with: Data(Resources.text("mutant-hints.json").utf8)) as? [String: String] ?? [:]
    let hint = hints[rule.name].map {
      "- A direction that has worked for this rule: \($0). Another that breaks the rule is as good.\n"
    }
    return try Resources.text("mutant.md")
      .replacingOccurrences(of: "@RULE@", with: rule.block)
      .replacingOccurrences(
        of: "@PATHS@", with: allowedPaths(for: rule).map { "`\($0)`" }.joined(separator: ", ")
      )
      .replacingOccurrences(of: "@HINT@", with: hint ?? "")
  }

  /// Whether `report`, the check replayed against a mutant, shows the check catching the rule: it
  /// failed at a Then line because an expectation printed false, so every Given and When step
  /// passed. An action failing, a jq error or a crash shows only that the mutant broke something.
  static func isCaught(by report: ReplayReport) -> Bool {
    guard report.verdict == .fail, let failure = report.failure else { return false }
    return failure.phase == .then && failure.kind == "expect" && failure.value == "false"
  }
}

/// Builds a mutant's patch outside any sandbox.
protocol MutantBuilding {
  /// A fresh clone of the repository at its HEAD, without the generated checks, for a writer to
  /// change; its path is inside `run`.
  func writerWorkspace(in run: URL) throws -> URL
  /// What the writer changed, as a unified diff.
  func patch(of workspace: URL) throws -> String
  /// Builds `patch` in the layer's mutant workspace and returns the bundle.
  ///
  /// - Throws: `MutantBuildError` when the patch does not apply or the build fails.
  func build(patch: String, into bundle: URL, release: Bool) throws
}

extension MutantBuilding {
  /// Builds the debug and the release bundle.
  func build(patch: String, into bundle: URL) throws {
    try build(patch: patch, into: bundle, release: true)
  }
}

struct MutantBuildError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

/// The real builder: git for the clones, swift for the build, in the layer's cache.
struct GitMutantBuilder: MutantBuilding {
  let runner: any Runner
  /// The repository the mutants are cut from.
  let repository: URL
  /// The layer's cache: `mutants/workspace` holds the build tree every mutant reuses.
  let cache: URL
  var buildTimeout = 1500.0
  var diskFloor = Settings.diskFloor
  var availableBytes: () -> Int64 = { Disk.availableBytes() }

  private var workspace: URL { cache.appending(path: "mutants/workspace") }

  func writerWorkspace(in run: URL) throws -> URL {
    let clone = run.appending(path: "repo")
    try? FileManager.default.removeItem(at: clone)
    try git(["clone", "--local", "--quiet", repository.path, clone.path])
    try git([
      "-C", clone.path, "sparse-checkout", "set", "--no-cone",
      "/*", "!/Tests/Acceptance/Checks/",
    ])
    let checks = clone.appending(path: "Tests/Acceptance/Checks")
    try? FileManager.default.removeItem(at: checks)
    try git(["-C", clone.path, "config", "user.email", "layer@palantir.invalid"])
    try git(["-C", clone.path, "config", "user.name", "layer"])
    return clone
  }

  func patch(of workspace: URL) throws -> String {
    try git(["-C", workspace.path, "add", "-A"])
    return try git(["-C", workspace.path, "diff", "--cached", "--no-ext-diff", "--binary"])
  }

  func build(patch: String, into bundle: URL, release: Bool) throws {
    guard availableBytes() >= diskFloor else {
      throw MutantBuildError(
        "the disk has less than \(diskFloor >> 30) GiB free; no mutant build starts")
    }
    let manager = FileManager.default
    try manager.createDirectory(
      at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lock = try FileLock(cache.appending(path: "mutant-build.lock"))
    defer { lock.release() }
    if !manager.fileExists(atPath: workspace.appending(path: ".git").path) {
      try git(["clone", "--local", "--quiet", repository.path, workspace.path])
    }
    try git(["-C", workspace.path, "fetch", "--quiet", "--no-tags", repository.path, "HEAD"])
    try git(["-C", workspace.path, "reset", "--hard", "--quiet", "FETCH_HEAD"])
    try git(["-C", workspace.path, "clean", "-fdq"])
    let patchFile = workspace.deletingLastPathComponent().appending(path: "current.patch")
    try Data(patch.utf8).write(to: patchFile)
    do { try git(["-C", workspace.path, "apply", "--whitespace=nowarn", patchFile.path]) } catch {
      throw MutantBuildError("the patch does not apply: \(error)")
    }
    var targets = [("debug", bundle)]
    if release { targets.append(("release", Mutant.releaseBundle(for: bundle))) }
    for (configuration, target) in targets {
      let built = try runner.run(
        "/usr/bin/swift",
        [
          "build", "--package-path", workspace.path, "--configuration", configuration, "--product",
          "palantir",
        ],
        stdin: nil, timeout: buildTimeout)
      guard built.exit == 0 else {
        throw MutantBuildError("swift build failed: \(String(built.stderr.suffix(2000)))")
      }
      let shown = try runner.run(
        "/usr/bin/swift",
        [
          "build", "--package-path", workspace.path, "--configuration", configuration, "--product",
          "palantir", "--show-bin-path",
        ],
        stdin: nil, timeout: 120)
      let bin = URL(fileURLWithPath: shown.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      try? manager.removeItem(at: target)
      let macOS = target.appending(path: "Contents/MacOS")
      try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
      try manager.copyItem(
        at: bin.appending(path: "palantir"), to: macOS.appending(path: "palantir"))
      try manager.copyItem(
        at: workspace.appending(path: "Sources/App/Info.plist"),
        to: target.appending(path: "Contents/Info.plist"))
      let signed = try runner.run(
        "/usr/bin/codesign", ["--force", "--sign", "-", target.path], stdin: nil, timeout: 120)
      guard signed.exit == 0 else { throw MutantBuildError("codesign failed: \(signed.stderr)") }
    }
  }

  @discardableResult
  private func git(_ arguments: [String]) throws -> String {
    let output = try runner.run("/usr/bin/git", arguments, stdin: nil, timeout: 300)
    guard output.exit == 0 else {
      throw MutantBuildError("git \(arguments.first ?? "") failed: \(output.stderr)")
    }
    return output.stdout
  }
}

enum Disk {
  /// The free bytes on the volume that holds the current folder.
  static func availableBytes(at path: String = ".") -> Int64 {
    let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
    return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
  }
}

/// An exclusive lock on a file, held until released.
final class FileLock {
  private let descriptor: Int32

  init(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
      throw MutantBuildError("cannot lock \(url.path)")
    }
  }

  func release() {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
