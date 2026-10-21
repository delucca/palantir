import Foundation
import Testing

@Suite(.layer(.unit))
struct LayerTests {
  private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// The Swift files under `Tests`.
  private static func testSources() -> [URL] {
    let files = FileManager.default.enumerator(
      at: root.appending(path: "Tests"), includingPropertiesForKeys: nil)
    return (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
  }

  @Test func withoutTheVariableEveryLayerButE2ERuns() throws {
    #expect(try Layer.selected(in: [:]) == [.unit, .integration, .release])
  }

  @Test func theVariableNamesTheLayersToRun() throws {
    #expect(try Layer.selected(in: ["PALANTIR_TEST_LAYERS": "unit,e2e"]) == [.unit, .e2e])
  }

  @Test(arguments: [("unti", "unti"), ("unit,unti", "unti"), ("", ""), (",", ",")])
  func aValueThatNamesNoLayerIsAnError(_ value: String, _ name: String) {
    let error = #expect(throws: UnknownLayer.self) {
      try Layer.selected(in: ["PALANTIR_TEST_LAYERS": value])
    }
    #expect(error.map { String($0.name) } == name)
    #expect(error?.description == "PALANTIR_TEST_LAYERS names \"\(name)\", which is no layer")
  }

  @Test func theLayerTraitEnablesOnlyTheSelectedLayers() async throws {
    #expect(try await ConditionTrait.layer(.unit, in: [:]).evaluate())
    #expect(try await !ConditionTrait.layer(.e2e, in: [:]).evaluate())
  }

  @Test func theLayerTraitFailsOnAValueThatNamesNoLayer() async {
    await #expect(throws: UnknownLayer.self) {
      try await ConditionTrait.layer(.unit, in: ["PALANTIR_TEST_LAYERS": "unti"]).evaluate()
    }
  }

  @Test func aLaunchOutsideTheE2ELayerIsRefused() async {
    await #expect(throws: LaunchError.self) {
      _ = try await LaunchedPalantir(
        LaunchedPalantir.built("palantir"), environment: ["PALANTIR_TEST_LAYERS": "unit"])
    }
  }

  @Test func everyTestTargetDeclaresTheSameLayers() throws {
    let manifest = try String(
      contentsOf: Self.root.appending(path: "Package.swift"), encoding: .utf8)
    let paths = manifest.matches(of: /\.testTarget\([^)]*?path: "([^"]+)"/).map { String($0.1) }
    try #require(!paths.isEmpty)
    #expect(paths.count == manifest.components(separatedBy: ".testTarget(").count - 1)
    let copies = try paths.map {
      try String(contentsOf: Self.root.appending(path: "\($0)/Layer.swift"), encoding: .utf8)
    }
    for (path, copy) in zip(paths, copies) {
      #expect(copy == copies[0], "\(path)/Layer.swift differs from \(paths[0])/Layer.swift")
    }
  }

  @Test func everySuiteCarriesALayer() throws {
    let declaration =
      /^(@.*\s+)?((private|fileprivate|internal|package|public|final)\s+)*(struct|class|actor|enum|extension)\s+(\w+)/
    var layered: Set<Substring> = []
    var extensions: [(at: String, type: Substring)] = []
    for file in Self.testSources() {
      let lines = try String(contentsOf: file, encoding: .utf8).split(
        separator: "\n", omittingEmptySubsequences: false)
      // The attributes and comments above the current line, a wrapped attribute's lines included.
      var header = ""
      var index = 0
      while index < lines.count {
        let line = lines[index]
        let at = "\(file.lastPathComponent):\(index + 1)"
        if !line.hasPrefix(" "), !line.hasPrefix("//"), line.contains("@Test") {
          Issue.record("\(at) is a test outside a suite")
        }
        guard let match = line.firstMatch(of: declaration) else {
          let continues =
            line.hasPrefix("@") || line.hasPrefix("//") || (line.hasPrefix(" ") && !header.isEmpty)
          header = continues ? header + line : ""
          index += 1
          continue
        }
        // A top-level type ends at its closing brace in column 0.
        let end = line.hasSuffix("}") ? index : lines[index...].firstIndex(of: "}") ?? index
        let attributes = header + line
        if attributes.contains("@Suite"), attributes.contains(".layer(") {
          layered.insert(match.output.5)
        } else if lines[index...end].contains(where: { $0.contains("@Test") }) {
          if match.output.4 == "extension" {
            extensions.append((at, match.output.5))
          } else {
            Issue.record("\(at) holds tests without a layer")
          }
        }
        header = ""
        index = end + 1
      }
    }
    for (at, type) in extensions where !layered.contains(type) {
      Issue.record("\(at) extends \(type), which holds tests without a layer")
    }
  }
}
