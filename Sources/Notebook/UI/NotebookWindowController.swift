package import AppKit
package import UniformTypeIdentifiers

package final class NotebookWindowController: NSWindowController {
  package static let readableContentTypes: [UTType] = [.markdown]

  let textView: NotebookTextView

  package static func makeViewMenuItems() -> [NSMenuItem] {
    [
      ("Fold Heading", #selector(NotebookTextView.foldHeading(_:))),
      ("Unfold Heading", #selector(NotebookTextView.unfoldHeading(_:))),
      ("Fold All", #selector(NotebookTextView.foldAll(_:))),
      ("Unfold All", #selector(NotebookTextView.unfoldAll(_:))),
    ].map { NSMenuItem(title: $0, action: $1, keyEquivalent: "") }
  }

  package init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
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

  package func open(_ url: URL) throws {
    textView.show(try String(contentsOf: url, encoding: .utf8))
  }
}
