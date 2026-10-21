import AppKit
import Darwin
import Foundation
import PalantirNotebook
import PalantirNotebookInspector
import Testing

@testable import Palantir
@testable import PalantirInspector
@testable import PalantirNotebookUI

@MainActor
@Suite(.layer(.integration))
struct InspectorTests {
  /// What an inspector call could change: the text, the folds, the selection, the scroll
  /// position, the window, and what the last layout drew.
  private struct Snapshot: Equatable {
    var text: String
    var folds: Set<Int>
    var selection: NSRange
    var scroll: CGRect
    var window: CGRect
    var frame: CGRect
    var drawn: [String]
    var markers: [CGRect]

    @MainActor init(_ controller: NotebookWindowController) throws {
      let view = controller.textView
      text = view.string
      folds = view.foldedHeadingStarts
      selection = view.selectedRange()
      scroll = try #require(view.enclosingScrollView?.contentView.bounds)
      window = try #require(controller.window?.frame)
      frame = view.frame
      drawn = zip(laidOutOffsets(view), view.laidOut).map { "\($0) \($1.layoutFragmentFrame)" }
      markers = view.foldedMarkers.sorted { $0.key < $1.key }.map(\.value.frame)
    }
  }

  private func request(_ method: InspectorMethod, _ params: String = "{}") -> Data {
    Data(#"{"jsonrpc":"2.0","id":1,"method":"\#(method.rawValue)","params":\#(params)}"#.utf8)
  }

  /// A delegate whose notebook window is on screen, transparent, with `text` open.
  private func showing(_ text: String) throws -> (AppDelegate, NSWindow) {
    let delegate = AppDelegate()
    let url = try writeTemporaryNotebook(text)
    defer { removeTemporaryNotebook(url) }
    try delegate.notebook.open(url)
    let window = try delegate.notebook.transparentWindow()
    delegate.notebook.showWindow(nil)
    return (delegate, window)
  }

  // [utest->req~inspector.settled-layout~1]
  @Test func theWaitAfterFoldAllAnswersWithTheStateASecondLaterHas() async throws {
    let (delegate, window) = try showing(sectionsNotebook())
    defer { window.orderOut(nil) }
    let inspector = delegate.makeInspector()
    let view = delegate.notebook.textView
    try view.scrollToTop(offset: try view.heading(startingWith: "# Section 5\n").range.location)
    _ = try await inspector.waitForSettledLayout(timeout: 30)

    #expect(try choose("Fold All", in: delegate.notebook))
    let waited = try await inspector.waitForSettledLayout(timeout: 30)
    let settled = await inspector.respond(to: request(.state))
    try await Task.sleep(for: .seconds(1))
    let later = await inspector.respond(to: request(.state))
    #expect(settled == later)
    #expect(waited.looks >= 4)
    let state = try JSONDecoder().decode(InspectorResponse<StateResult>.self, from: settled)
    let notebook = try #require(state.result?.sections.notebook)
    #expect(notebook.folded.count == 10)
    #expect(notebook.drawn.map(\.text).contains("# Section 5"))
    #expect(notebook.gaps.isEmpty)
  }

  // [utest->req~inspector.settled-layout~1]
  @Test func aScrollThatDisplayHasNotLaidOutIsPendingLayout() async throws {
    let (delegate, window) = try showing(sectionsNotebook())
    defer { window.orderOut(nil) }
    let inspector = delegate.makeInspector()
    _ = try await inspector.waitForSettledLayout(timeout: 30)
    try #require(Settling.pending(window) == nil)
    let before = laidOutOffsets(delegate.notebook.textView)

    try delegate.notebook.textView.scroll(toY: 4000, layingOut: false)
    #expect(Settling.pending(window) != nil)
    _ = try await inspector.waitForSettledLayout(timeout: 30)
    #expect(Settling.pending(window) == nil)
    #expect(laidOutOffsets(delegate.notebook.textView) != before)
  }

  // [utest->req~inspector.never-drives~1]
  @Test func noInspectorCallChangesTheNotebookItsFoldsTheSelectionTheScrollOrTheWindow()
    async throws
  {
    let (delegate, window) = try showing(longNotebook(before: 60, owned: 40, after: 200))
    defer { window.orderOut(nil) }
    let inspector = delegate.makeInspector()
    let view = delegate.notebook.textView
    let heading = try view.heading(startingWith: "## Fix the reaper")
    try #require(try choose("Fold Heading", at: heading.range.location + 1, in: delegate.notebook))
    view.setSelectedRange(
      (view.string as NSString).lineRange(for: NSRange(location: 30, length: 0)))
    try view.scroll(toY: 700)
    _ = try await inspector.waitForSettledLayout(timeout: 30)
    let before = try Snapshot(delegate.notebook)
    try #require(!before.folds.isEmpty && before.selection.length > 0 && before.scroll.minY > 0)

    var calls = InspectorMethod.allCases.map { ($0, request($0)) }
    calls.append((.wait, request(.wait, #"{"timeout":1}"#)))
    calls.append(
      (.screenshot, request(.screenshot, #"{"rect":{"x":10,"y":20,"width":300,"height":100}}"#)))
    let fields: [InspectorMethod: Set<String>] = [
      .state: ["window", "sections"], .wait: ["waited", "looks"],
      .screenshot: ["png", "width", "height", "scale"],
    ]
    for (method, call) in calls {
      let name = String(decoding: call, as: UTF8.self)
      let response = await inspector.respond(to: call)
      // Each call must have done its work, or an inspector that fails every call would pass.
      let result = try #require(
        (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"]
          as? [String: Any], "\(name): \(String(decoding: response, as: UTF8.self).prefix(200))")
      #expect(Set(result.keys) == fields[method], "\(name)")
      if method == .screenshot {
        let png = try #require((result["png"] as? String).flatMap { Data(base64Encoded: $0) })
        let image = try #require(NSBitmapImageRep(data: png), "\(name)")
        #expect(
          image.pixelsWide == result["width"] as? Int
            && image.pixelsHigh == result["height"] as? Int)
      }
      #expect(try Snapshot(delegate.notebook) == before, "\(name)")
    }
  }

  // [utest->req~inspector.state-per-feature~1]
  @Test func theStateHoldsASectionForEveryFeature() async throws {
    let (delegate, window) = try showing("# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\n")
    defer { window.orderOut(nil) }
    let inspector = delegate.makeInspector()
    let features = featureFolders().map { $0.lowercased() }
    #expect(inspector.sections.map(\.name).sorted() == features)
    let response = await inspector.respond(to: request(.state))
    let result = try #require(
      (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"]
        as? [String: Any])
    let sections = try #require(result["sections"] as? [String: [String: Any]])
    #expect(sections.keys.sorted() == features)
    #expect(sections.values.allSatisfy { !$0.isEmpty })
  }
}

/// The tests that launch palantir, one at a time: two launches at once hand the front to each other.
@Suite(.serialized, .layer(.e2e))
struct InspectorLaunchTests {
  // [utest->req~inspector.debug-only~1]
  @Test func aDebugBuildListensOnlyWithTheLaunchFlag() async throws {
    let executable = LaunchedPalantir.built("palantir")
    let quiet = try await LaunchedPalantir(executable)
    #expect(!FileManager.default.fileExists(atPath: quiet.socket.path))
    #expect(throws: (any Error).self) {
      try InspectorClient(pid: quiet.pid).call(.state, NoParams(), timeout: 2)
    }
    quiet.terminate()

    let listening = try await LaunchedPalantir(
      executable, arguments: [InspectorListener.launchFlag])
    let client = try InspectorClient(pid: listening.pid)
    let response = try await Task.detached { try client.call(.state, NoParams(), timeout: 5) }.value
    #expect((try JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"] != nil)
    var directory = stat()
    lstat(listening.socket.deletingLastPathComponent().path, &directory)
    #expect(directory.st_mode & S_IFMT == S_IFDIR && directory.st_mode & 0o777 == 0o700)
    #expect(directory.st_uid == getuid())
  }

  // Only the socket the inspector would make; a listener elsewhere is what ReleaseBuildTests'
  // import check catches.
  // [utest->req~inspector.no-release-listener~1]
  @Test(.timeLimit(.minutes(10)))
  func aReleaseBuildLaunchedWithTheFlagCreatesNoSocket() async throws {
    let launched = try await LaunchedPalantir(
      try ReleaseBuild.executable(), arguments: [InspectorListener.launchFlag])
    try await Task.sleep(for: .seconds(1))
    #expect(kill(launched.pid, 0) == 0)
    #expect(!FileManager.default.fileExists(atPath: launched.socket.path))
  }
}

/// The offset of each paragraph the last viewport layout drew.
@MainActor func laidOutOffsets(_ view: NotebookTextView) -> [Int] {
  guard let storage = view.textContentStorage else { return [] }
  return view.laidOut.map {
    storage.offset(from: storage.documentRange.location, to: $0.rangeInElement.location)
  }
}

/// The parts of `state` these tests read.
struct StateResult: Decodable {
  struct Sections: Decodable { var notebook: NotebookState }
  var sections: Sections
}
