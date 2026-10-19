import AppKit
import Testing

@testable import Palantir

@MainActor
struct MainMenuTests {
  // [utest->req~main-menu.hig-order~1]
  @Test func menusFollowTheHIGOrder() {
    let titles = MainMenu.make().items.map(\.title)
    #expect(titles.dropFirst() == ["File", "Edit", "View", "Window", "Help"])
  }

  // [utest->req~main-menu.view-fold-commands~1]
  @Test func viewMenuHoldsTheFoldCommandsWithoutKeyEquivalents() throws {
    let view = try #require(MainMenu.make().item(withTitle: "View")?.submenu)
    #expect(
      view.items.map(\.title) == ["Fold Heading", "Unfold Heading", "Fold All", "Unfold All"])
    #expect(view.items.allSatisfy { $0.keyEquivalent.isEmpty })
    #expect(view.items.allSatisfy { $0.target == nil })
    #expect(
      view.items.map(\.action) == [
        #selector(NotebookTextView.foldHeading(_:)),
        #selector(NotebookTextView.unfoldHeading(_:)),
        #selector(NotebookTextView.foldAll(_:)),
        #selector(NotebookTextView.unfoldAll(_:)),
      ])
  }
}
