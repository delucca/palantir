import AppKit
import Testing

@testable import Palantir
@testable import PalantirNotebookUI

@MainActor
func viewMenuItem(_ title: String) throws -> NSMenuItem {
  try #require(MainMenu.make().item(withTitle: "View")?.submenu?.item(withTitle: title))
}

@MainActor
func choose(_ title: String, in controller: NotebookWindowController) throws -> Bool {
  let item = try viewMenuItem(title)
  guard controller.textView.validateMenuItem(item) else { return false }
  let action = try #require(item.action)
  let responder = try #require(controller.window?.firstResponder)
  return responder.tryToPerform(action, with: item)
}

@MainActor
func choose(
  _ title: String, at offset: Int, in controller: NotebookWindowController
) throws -> Bool {
  controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
  return try choose(title, in: controller)
}

@MainActor
func openMenuItem() throws -> (NSMenuItem, Selector) {
  let item = try #require(
    MainMenu.make().item(withTitle: "File")?.submenu?.item(withTitle: "Open…"))
  let action = try #require(item.action)
  try #require(action == #selector(AppDelegate.openDocument(_:)))
  return (item, action)
}

extension NotebookWindowController {
  /// The View menu with each item aimed where AppKit sends it from the key window: the first
  /// responder up the chain that answers the action. A test process has no key window, so AppKit's
  /// own search finds no target and disables every item.
  func viewMenuAimedAtTheResponderChain() throws -> NSMenu {
    let menu = try #require(MainMenu.make().item(withTitle: "View")?.submenu)
    let responder = try #require(window?.firstResponder)
    for item in menu.items {
      try #require(item.target == nil, "\(item.title) has a target")
      let action = try #require(item.action)
      let target: NSResponder = try #require(
        sequence(first: responder, next: \.nextResponder).first { $0.responds(to: action) },
        "no responder answers \(item.title)")
      item.target = target
    }
    return menu
  }
}
