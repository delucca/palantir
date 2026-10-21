import AppKit
import Foundation
import PalantirInspector
import PalantirNotebook
import Testing

@testable import PalantirNotebookInspector
@testable import PalantirNotebookUI

@MainActor
@Suite(.layer(.integration))
struct NotebookStateTests {
  private struct State: Decodable {
    struct Sections: Decodable { var notebook: NotebookState }
    var sections: Sections
  }

  private func notebookState(of controller: NotebookWindowController) async throws -> NotebookState
  {
    let inspector = Inspector(
      window: { controller.window }, sections: [controller.makeStateSection()])
    let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"state"}"#.utf8)
    let response = try JSONDecoder().decode(
      InspectorResponse<State>.self, from: await inspector.respond(to: line))
    return try #require(response.result).sections.notebook
  }

  private func open(_ text: String) -> NotebookWindowController {
    let controller = NotebookWindowController()
    controller.textView.show(text)
    return controller
  }

  // [utest->req~inspector.notebook-state~1]
  @Test func stateListsTheFoldedHeadingAndTheDrawnLinesAsTheProbesMeasureThem() async throws {
    let controller = open("# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\n")
    let view = controller.textView
    let heading = try view.heading(startingWith: "## Fix the reaper")
    view.setSelectedRange(NSRange(location: heading.range.location + 1, length: 0))
    view.foldHeading(nil)
    try #require(view.foldedHeadingStarts == [heading.range.location])

    let state = try await notebookState(of: controller)
    #expect(state.folded == [.init(offset: heading.range.location, line: "## Fix the reaper")])
    #expect(state.drawn.map(\.text) == ["# Tasks", "## Fix the reaper", "# Notes"])
    let clip = try #require(view.enclosingScrollView?.contentView)
    for line in state.drawn {
      let frame = try view.fragmentFrame(at: line.offset)
      #expect(line.rect == Rect(frame.offsetBy(dx: 0, dy: -clip.bounds.minY)))
    }
    #expect(state.gaps.isEmpty)
    #expect(try view.drawnGaps().isEmpty)
    let selected = view.selectedRange()
    #expect(state.selection == .init(location: selected.location, length: selected.length))
    #expect(
      state.scroll
        == .init(y: clip.bounds.minY, height: clip.bounds.height, documentHeight: view.frame.height)
    )
    let marker = try #require(view.foldedMarkers[heading.range.location])
    #expect(
      state.markers == [
        .init(heading: heading.range.location, label: "Folded", rect: Rect(marker.frame))
      ])
  }

  // [utest->req~inspector.notebook-state~1]
  @Test func aGapIsTheSpaceBetweenTwoDrawnParagraphsAndAnOverlapIsNegative() {
    let drawn = [
      (offset: 0, frame: CGRect(x: 25, y: 0, width: 50, height: 16)),
      (offset: 8, frame: CGRect(x: 25, y: 16, width: 50, height: 16)),
      (offset: 20, frame: CGRect(x: 25, y: 40, width: 50, height: 16)),
      (offset: 30, frame: CGRect(x: 25, y: 50, width: 50, height: 16)),
    ]
    let gaps = NotebookTextView.gaps(between: drawn).map { [$0.after, $0.before, Int($0.height)] }
    #expect(gaps == [[8, 20, 8], [20, 30, -6]])
  }

  // [utest->req~inspector.notebook-state~1]
  @Test func drawnLinesInAScrolledNotebookAreTheOnesInTheWindow() async throws {
    let text = (1...200).map { "Line \($0).\n" }.joined()
    let controller = open(text)
    let view = controller.textView
    let scroll = try #require(view.enclosingScrollView)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1003))
    scroll.reflectScrolledClipView(scroll.contentView)
    view.textLayoutManager?.textViewportLayoutController.layoutViewport()

    let state = try await notebookState(of: controller)
    let drawn = try view.drawnParagraphs()
    #expect(state.drawn.map(\.offset) == drawn.map(\.offset))
    let top = try view.drawnTopLine()
    #expect(state.drawn.first?.rect.y == Double(top.screenY))
    #expect(try #require(state.drawn.first).rect.y < 0)
    #expect(state.drawn.allSatisfy { $0.rect.y < scroll.contentSize.height })
    #expect(state.scroll.y == 1003)
    #expect(state.gaps.isEmpty)
    #expect(state.folded.isEmpty && state.markers.isEmpty)
  }
}
