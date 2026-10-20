package import AppKit
import Foundation
import UniformTypeIdentifiers

/// The window that shows a Markdown notebook, read-only, with its headings folded on command.
package final class NotebookWindowController: NSWindowController {
  let textView: NotebookTextView
  // The two modal loops of File > Open, which tests stand in for.
  var runOpenPanel: @MainActor (NSOpenPanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil }
  var runAlert: @MainActor (NSAlert) -> Void = { _ = $0.runModal() }

  /// The notebook's File menu items, for the menu bar: Open….
  package static func makeFileMenuItems() -> [NSMenuItem] {
    [NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")]
  }

  /// The notebook's View menu items, for the menu bar: the fold commands.
  package static func makeViewMenuItems() -> [NSMenuItem] {
    [
      ("Fold Heading", #selector(NotebookTextView.foldHeading(_:))),
      ("Unfold Heading", #selector(NotebookTextView.unfoldHeading(_:))),
      ("Fold All", #selector(NotebookTextView.foldAll(_:))),
      ("Unfold All", #selector(NotebookTextView.unfoldAll(_:))),
    ].map { NSMenuItem(title: $0, action: $1, keyEquivalent: "") }
  }

  /// Makes the window, empty until a notebook is opened.
  package init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "palantír"
    let scroll = NSScrollView(frame: window.contentLayoutRect)
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    textView = NotebookTextView(usingTextLayoutManager: true)
    textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
    textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainerInset = NotebookTextView.markerInset
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    scroll.documentView = textView
    window.contentView = scroll
    super.init(window: window)
    window.makeFirstResponder(textView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// File > Open: asks for a Markdown file, shows it in the window and brings the window forward,
  /// or shows an alert and keeps the text when the file cannot be read.
  @objc package func openDocument(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.markdown]
    guard let url = runOpenPanel(panel) else { return }
    do {
      try open(url)
      showWindow(nil)
    } catch {
      runAlert(NSAlert(error: error))
    }
  }

  func open(_ url: URL) throws {
    textView.show(try String(contentsOf: url, encoding: .utf8))
  }
}
