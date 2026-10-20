import AppKit
import Testing

@testable import Palantir
@testable import PalantirNotebookUI

@MainActor
struct MainMenuTests {
  // [utest->req~main-menu.hig-order~1]
  @Test func menusFollowTheHIGOrder() {
    let titles = MainMenu.make().items.map(\.title)
    #expect(titles.dropFirst() == ["File", "Edit", "View", "Window", "Help"])
  }

  // [utest->req~main-menu.hig-order~1]
  @Test func launchingInstallsTheMenuBar() throws {
    let app = NSApplication.shared
    let (menu, windows, help) = (app.mainMenu, app.windowsMenu, app.helpMenu)
    defer {
      app.mainMenu = menu
      app.windowsMenu = windows
      app.helpMenu = help
    }
    MainMenu.install(in: app)
    let installed = try #require(app.mainMenu)
    #expect(installed.items.map(\.title).dropFirst() == ["File", "Edit", "View", "Window", "Help"])
    #expect(app.windowsMenu === installed.item(withTitle: "Window")?.submenu)
    #expect(app.helpMenu === installed.item(withTitle: "Help")?.submenu)
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
