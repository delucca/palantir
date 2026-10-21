import Foundation
import PalantirInspector
import Testing

@Suite(.serialized)
struct ReleaseBuildTests {
  /// Text that only inspector code puts in a binary: its modules' names, its launch flag, its
  /// protocol and its socket directory.
  private static let inspectorStrings = [
    "PalantirInspector", "PalantirNotebookInspector", InspectorListener.launchFlag, "jsonrpc",
    SocketDirectory.url.lastPathComponent,
  ]

  /// Runs `executable` and returns its standard output, failing on a non-zero exit.
  private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "\(executable) \(arguments) failed")
    return String(decoding: data, as: UTF8.self)
  }

  /// Builds release palantir and returns its executable. A build of its own, in a scratch path of
  /// its own, so it does not wait on the lock of the build that runs this test.
  private func releaseExecutable() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let scratch = root.appending(path: ".build/release-check")
    _ = try run(
      "/usr/bin/xcrun",
      [
        "swift", "build", "-c", "release", "--product", "palantir", "--package-path", root.path,
        "--scratch-path", scratch.path, "--only-use-versions-from-resolved-file",
      ])
    return scratch.appending(path: "release/palantir")
  }

  // [utest->req~inspector.no-release-listener~1]
  @Test(.timeLimit(.minutes(10)))
  func aReleaseBuildHoldsNoInspectorCode() throws {
    let executable = try releaseExecutable()
    let symbols = try run("/usr/bin/nm", [executable.path]).split(separator: "\n")
    #expect(!symbols.isEmpty)
    #expect(
      symbols.filter { $0.contains("PalantirInspector") || $0.contains("NotebookInspector") }
        .isEmpty)
    let strings = try run("/usr/bin/strings", ["-a", executable.path])
    for text in Self.inspectorStrings { #expect(!strings.contains(text), "\(text)") }
    // A listener under another name still needs these calls; debug palantir imports all four.
    let imports = try run("/usr/bin/nm", ["-u", executable.path]).split(separator: "\n")
    for call in ["_socket", "_bind", "_listen", "_accept"] {
      #expect(!imports.contains { $0 == call }, "release palantir imports \(call)")
    }
  }

  // Only the socket the inspector would make; a listener elsewhere is what the imports above catch.
  // [utest->req~inspector.no-release-listener~1]
  @Test(.timeLimit(.minutes(10)), .launchesPalantir)
  func aReleaseBuildLaunchedWithTheFlagCreatesNoSocket() async throws {
    let launched = try await LaunchedPalantir(
      try releaseExecutable(), arguments: [InspectorListener.launchFlag])
    try await Task.sleep(for: .seconds(1))
    #expect(kill(launched.pid, 0) == 0)
    #expect(!FileManager.default.fileExists(atPath: launched.socket.path))
  }
}
