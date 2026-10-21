import Foundation
import PalantirInspector
import Testing

@Suite(.layer(.release))
struct ReleaseBuildTests {
  /// Text that only inspector code puts in a binary: its modules' names, its launch flag, its
  /// protocol and its socket directory.
  private static let inspectorStrings = [
    "PalantirInspector", "PalantirNotebookInspector", InspectorListener.launchFlag, "jsonrpc",
    SocketDirectory.url.lastPathComponent,
  ]

  // req~inspector.no-release-listener~1
  @Test(.timeLimit(.minutes(10)))
  func aReleaseBuildHoldsNoInspectorCode() throws {
    let executable = try ReleaseBuild.executable()
    let symbols = try ReleaseBuild.run("/usr/bin/nm", [executable.path]).split(separator: "\n")
    #expect(!symbols.isEmpty)
    #expect(
      symbols.filter { $0.contains("PalantirInspector") || $0.contains("NotebookInspector") }
        .isEmpty)
    let strings = try ReleaseBuild.run("/usr/bin/strings", ["-a", executable.path])
    for text in Self.inspectorStrings { #expect(!strings.contains(text), "\(text)") }
    // A listener under another name still needs these calls; debug palantir imports all four.
    let imports = try ReleaseBuild.run("/usr/bin/nm", ["-u", executable.path])
      .split(separator: "\n")
    for call in ["_socket", "_bind", "_listen", "_accept"] {
      #expect(!imports.contains { $0 == call }, "release palantir imports \(call)")
    }
  }
}
