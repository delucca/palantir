import AppKit

/// The menu bar, in the order the macOS HIG requires.
enum MainMenu {
  static func install(in app: NSApplication) {
    let menu = make()
    app.mainMenu = menu
    app.windowsMenu = menu.item(withTitle: "Window")?.submenu
    app.helpMenu = menu.item(withTitle: "Help")?.submenu
  }

  static func make() -> NSMenu {
    let name = ProcessInfo.processInfo.processName
    let menu = NSMenu()

    menu.addSubmenu(
      name,
      [
        item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
        item(
          "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
          [.command, .option]),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
      ])

    menu.addSubmenu(
      "File",
      [
        item("Open…", #selector(AppDelegate.openDocument(_:)), "o")
      ])

    menu.addSubmenu(
      "Edit",
      [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
      ])

    menu.addSubmenu(
      "View",
      [
        item("Fold Heading", #selector(NotebookTextView.foldHeading(_:))),
        item("Unfold Heading", #selector(NotebookTextView.unfoldHeading(_:))),
        item("Fold All", #selector(NotebookTextView.foldAll(_:))),
        item("Unfold All", #selector(NotebookTextView.unfoldAll(_:))),
      ])

    menu.addSubmenu(
      "Window",
      [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
        .separator(),
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
      ])

    menu.addSubmenu("Help", [])

    return menu
  }

  private static func item(
    _ title: String, _ action: Selector, _ key: String = "",
    _ modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
  }
}

extension NSMenu {
  fileprivate func addSubmenu(_ title: String, _ items: [NSMenuItem]) {
    let submenu = NSMenu(title: title)
    submenu.items = items
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    addItem(item)
  }
}
