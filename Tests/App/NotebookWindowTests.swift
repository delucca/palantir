import AppKit
import PalantirNotebook
import Testing
import UniformTypeIdentifiers

@testable import Palantir
@testable import PalantirNotebookUI

@MainActor
struct NotebookWindowTests {
  // [utest->req~notebook-window.open~1]
  @Test func openingANotebookShowsItsWholeText() throws {
    let first =
      "# Tâsks 🎉\r\nNaïve 👩‍👩‍👧 line.\n```\n# code\n```\nEnd without newline\n"
      + longNotebook(before: 60, owned: 40, after: 5)
    let second = "# Short\nOnly a line.\n"
    let notebooks = [try writeTemporaryNotebook(first), try writeTemporaryNotebook(second)]
    defer { for url in notebooks { removeTemporaryNotebook(url) } }
    var urls = notebooks
    let delegate = AppDelegate()
    var panels: [NSOpenPanel] = []
    var alerts: [NSAlert] = []
    delegate.notebook.runOpenPanel = { panel in
      panels.append(panel)
      return urls.isEmpty ? nil : urls.removeFirst()
    }
    delegate.notebook.runAlert = { alerts.append($0) }
    let window = try delegate.notebook.transparentWindow()
    defer { window.orderOut(nil) }
    let (open, action) = try openMenuItem()
    let app = NSApplication.shared
    let previous = app.delegate
    app.delegate = delegate
    defer { app.delegate = previous }
    #expect(open.target == nil)
    try #require(app.target(forAction: action, to: nil, from: open) as AnyObject? === delegate)

    #expect(app.sendAction(action, to: nil, from: open))
    let view = delegate.notebook.textView
    #expect(view.string == first)
    #expect(try view.visibleText() == first)
    #expect(view.window === delegate.notebook.window)
    #expect(view.textLayoutManager != nil)
    #expect(window.isVisible)
    window.orderOut(nil)

    let heading = try view.heading(startingWith: "## Fix the reaper")
    try view.scrollToTop(offset: heading.range.location)
    try #require(try choose("Fold Heading", at: heading.range.location + 1, in: delegate.notebook))
    let content = try #require(view.enclosingScrollView?.contentSize.height)
    #expect(view.minSize.height > content)
    #expect(view.foldedMarkers.count == 1)

    #expect(app.sendAction(action, to: nil, from: open))
    #expect(try view.visibleText() == second)
    #expect(view.foldedMarkers.isEmpty && view.foldedHeadingStarts.isEmpty)
    #expect(view.markerViews().isEmpty)
    #expect(view.minSize.height == content && view.frame.height == content)
    #expect(window.isVisible)
    #expect(panels.count == 2 && panels.allSatisfy { $0.allowedContentTypes == [.markdown] })
    #expect(alerts.isEmpty)
  }

  // [utest->req~notebook-window.open~1]
  @Test func fileOpenInTheNotebookWindowGoesToItsController() throws {
    let text = "# Tasks\nIt leaks.\n"
    let url = try writeTemporaryNotebook(text)
    defer { removeTemporaryNotebook(url) }
    let controller = NotebookWindowController()
    var panels: [NSOpenPanel] = []
    controller.runOpenPanel = { panel in
      panels.append(panel)
      return url
    }
    let window = try controller.transparentWindow()
    defer { window.orderOut(nil) }
    let (open, action) = try openMenuItem()
    let responder = try #require(window.firstResponder)
    let target = sequence(first: responder, next: \.nextResponder).first { $0.responds(to: action) }
    #expect(target === controller)

    #expect(responder.tryToPerform(action, with: open))
    #expect(try controller.textView.visibleText() == text)
    #expect(window.isVisible)
    #expect(panels.map(\.allowedContentTypes) == [[.markdown]])
  }

  // [utest->req~notebook-window.open~1]
  @Test func reopeningAFoldedNotebookShowsItAll() throws {
    let text = "# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\n"
    let url = try writeTemporaryNotebook(text)
    defer { removeTemporaryNotebook(url) }
    let controller = NotebookWindowController()
    try controller.open(url)
    let view = controller.textView
    try #require(try choose("Fold Heading", at: 10, in: controller))
    #expect(try view.visibleText() != text)
    try controller.open(url)
    #expect(try view.visibleText() == text)
    #expect(view.foldedHeadingStarts.isEmpty && view.markerViews().isEmpty)
  }

  // [utest->req~notebook-window.open~1]
  @Test func openingAnotherNotebookShowsItFromItsFirstLine() throws {
    let controller = try openNotebook(sectionsNotebook())
    let view = controller.textView
    try view.scroll(toY: 6000)
    try #require(view.visibleRect.minY == 6000)
    let next = try writeTemporaryNotebook(longNotebook(before: 300, owned: 10, after: 300))
    defer { removeTemporaryNotebook(next) }
    try controller.open(next)
    #expect(view.visibleRect.minY == 0)
    #expect(try view.drawnTopLine().offset == 0)
    #expect(view.selectedRange() == NSRange(location: 0, length: 0))
    #expect(view.visibleRect.contains(try view.fragmentFrame(at: 0)))
  }

  @Test func anUnreadableNotebookShowsAnErrorAndKeepsTheText() throws {
    let text = "# Tasks\nIt leaks.\n"
    let notebooks = [
      try writeTemporaryNotebook(text),
      try writeTemporaryNotebook(Data([0x23, 0x20, 0x54, 0xE2, 0x63, 0x68, 0x65, 0x0A])),
    ]
    defer { for url in notebooks { removeTemporaryNotebook(url) } }
    var urls = notebooks
    let delegate = AppDelegate()
    var alerts: [NSAlert] = []
    delegate.notebook.runOpenPanel = { _ in urls.isEmpty ? nil : urls.removeFirst() }
    delegate.notebook.runAlert = { alerts.append($0) }
    let window = try delegate.notebook.transparentWindow()
    defer { window.orderOut(nil) }
    let (open, action) = try openMenuItem()
    let app = NSApplication.shared
    let previous = app.delegate
    app.delegate = delegate
    defer { app.delegate = previous }
    try #require(app.target(forAction: action, to: nil, from: open) as AnyObject? === delegate)

    #expect(app.sendAction(action, to: nil, from: open))
    #expect(window.isVisible)
    window.orderOut(nil)
    #expect(app.sendAction(action, to: nil, from: open))
    #expect(alerts.map(\.messageText) == [CocoaError(.fileReadCorruptFile).localizedDescription])
    #expect(!window.isVisible)
    #expect(delegate.notebook.textView.string == text)
    #expect(try delegate.notebook.textView.visibleText() == text)
  }

  @Test func cancellingFileOpenKeepsTheNotebookAndShowsNoError() throws {
    let text = "# Tasks\nIt leaks.\n"
    let url = try writeTemporaryNotebook(text)
    defer { removeTemporaryNotebook(url) }
    var urls = [url]
    let delegate = AppDelegate()
    var alerts: [NSAlert] = []
    delegate.notebook.runOpenPanel = { _ in urls.isEmpty ? nil : urls.removeFirst() }
    delegate.notebook.runAlert = { alerts.append($0) }
    let window = try delegate.notebook.transparentWindow()
    defer { window.orderOut(nil) }
    let (open, action) = try openMenuItem()
    let app = NSApplication.shared
    let previous = app.delegate
    app.delegate = delegate
    defer { app.delegate = previous }
    try #require(app.target(forAction: action, to: nil, from: open) as AnyObject? === delegate)

    #expect(app.sendAction(action, to: nil, from: open))
    #expect(window.isVisible)
    window.orderOut(nil)
    #expect(app.sendAction(action, to: nil, from: open))
    #expect(!window.isVisible)
    #expect(alerts.isEmpty)
    #expect(try delegate.notebook.textView.visibleText() == text)
  }

  @Test func launchingShowsTheNotebookWindowCentered() throws {
    let delegate = AppDelegate()
    let window = try delegate.notebook.transparentWindow()
    defer { window.orderOut(nil) }
    let centered = try #require(NotebookWindowController().window)
    centered.center()
    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification))
    #expect(window.isVisible)
    #expect(window.frame == centered.frame)
  }

  // [utest->req~notebook-window.read-only~1]
  @Test func cutAndPasteStayDisabledOnASelection() throws {
    let controller = try openNotebook("# Tasks\nIt leaks.\n")
    let view = controller.textView
    view.setSelectedRange(NSRange(location: 0, length: 7))
    let menu = try #require(MainMenu.make().item(withTitle: "Edit")?.submenu)
    let items = try ["Cut", "Copy", "Paste"].map { title in
      let item = try #require(menu.item(withTitle: title))
      try #require(item.target == nil)
      item.target = view
      return item
    }
    menu.update()
    #expect(items.map(\.isEnabled) == [false, true, false])
  }

  // [utest->req~notebook-window.read-only~1]
  @Test func typingIntoTheNotebookChangesNothing() throws {
    let text = "# Tasks\nIt leaks.\n"
    let controller = try openNotebook(text)
    let view = controller.textView
    #expect(view.isSelectable && !view.isEditable)
    let firstLine = NSRange(location: 0, length: 7)
    view.setSelectedRange(firstLine)
    let window = try #require(controller.window)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "x",
        charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
    view.keyDown(with: event)
    view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.string == text)
    #expect(view.selectedRange() == firstLine)
  }
}
