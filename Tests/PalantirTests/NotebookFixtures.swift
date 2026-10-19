import AppKit
import PalantirCore
import Testing

@testable import Palantir

@MainActor
func temporaryNotebook(_ data: Data) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appending(path: "notebook.md")
  try data.write(to: url)
  return url
}

@MainActor
func temporaryNotebook(_ text: String) throws -> URL {
  try temporaryNotebook(Data(text.utf8))
}

@MainActor
func openNotebook(_ text: String) throws -> NotebookWindowController {
  let controller = NotebookWindowController()
  try controller.open(try temporaryNotebook(text))
  return controller
}

@MainActor
func longNotebook(before: Int, owned: Int, after: Int) -> String {
  (1...before).map { "Filler line \($0).\n" }.joined() + "# Tasks\n## Fix the reaper\n"
    + (1...owned).map { "It leaks, line \($0).\n" }.joined() + "# Notes\n"
    + (1...after).map { "Filler line \($0).\n" }.joined()
}

@MainActor
func sectionsNotebook() -> String {
  "Intro.\n"
    + (1...10).map { section in
      "# Section \(section)\n" + (1...100).map { "Body \(section).\($0)\n" }.joined()
    }.joined()
}

@MainActor
func wrappingSectionsNotebook() -> String {
  let words = String(repeating: "word ", count: 30)
  return "Intro.\n"
    + (1...10).map { section in
      "# Section \(section)\n" + (1...60).map { "Body \(section).\($0) \(words)\n" }.joined()
    }.joined()
}

@MainActor
func wrappingPartsNotebook() -> String {
  let words = String(repeating: "word ", count: 30)
  return "Intro.\n"
    + (1...12).map { part in
      "# Part \(part)\n"
        + (1...4).map { item in
          "## Item \(part).\(item)\n"
            + (1...6).map { "Body \(part).\(item).\($0) \(words)\n" }.joined()
        }.joined()
    }.joined()
}

/// The text with each range removed; a range inside another goes with it.
func removing(_ ranges: [NSRange], from text: String) -> String {
  let result = NSMutableString(string: text)
  let outer = ranges.filter { range in
    !ranges.contains { $0 != range && NSLocationInRange(range.location, $0) }
  }
  for range in outer.sorted(by: { $0.location > $1.location }) {
    result.deleteCharacters(in: range)
  }
  return result as String
}

@MainActor
func heading(_ index: Int, of view: NotebookTextView) throws -> OutlineHeading {
  let headings = view.outline.headings
  try #require(headings.indices.contains(index), "\(headings.count) headings, no index \(index)")
  return headings[index]
}

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
private func laidOutParagraphs(_ view: NSTextView) throws -> [(string: String, frame: CGRect)] {
  let layout = try #require(view.textLayoutManager)
  var rows: [(String, CGRect)] = []
  var unavailable: [String] = []
  layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) {
    let string = ($0.textElement as? NSTextParagraph)?.attributedString.string ?? ""
    if $0.state != .layoutAvailable { unavailable.append(string) }
    rows.append(
      (
        string,
        $0.layoutFragmentFrame.offsetBy(
          dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
      ))
    return true
  }
  try #require(unavailable.isEmpty, "paragraphs without layout: \(unavailable.prefix(3))")
  return rows
}

@MainActor
private func layoutFragments(_ view: NSTextView) throws -> [(text: String, frame: CGRect)] {
  try laidOutParagraphs(view).map { ($0.string.trimmingCharacters(in: .newlines), $0.frame) }
}

@MainActor
func visibleParagraphs(_ view: NSTextView) throws -> [String] {
  try layoutFragments(view).map(\.text)
}

@MainActor
func visibleText(_ view: NSTextView) throws -> String {
  try laidOutParagraphs(view).map(\.string).joined()
}

@MainActor
func layoutBreaks(_ view: NSTextView) throws -> [String] {
  let rows = try layoutFragments(view)
  var breaks: [String] = []
  if let first = rows.first, first.frame.minY != view.textContainerOrigin.y {
    breaks.append("top->\(first.text): \(first.frame.minY - view.textContainerOrigin.y)")
  }
  for (first, second) in zip(rows, rows.dropFirst()) where second.frame.minY != first.frame.maxY {
    breaks.append("\(first.text)->\(second.text): \(second.frame.minY - first.frame.maxY)")
  }
  return breaks
}

@MainActor
func textHeight(_ view: NSTextView) throws -> CGFloat {
  let last = try #require(try layoutFragments(view).last)
  return last.frame.maxY - view.textContainerOrigin.y
}

@MainActor
func layoutFragment(_ view: NSTextView, at offset: Int) throws -> NSTextLayoutFragment {
  let storage = try #require(view.textContentStorage)
  let location = try #require(storage.location(storage.documentRange.location, offsetBy: offset))
  return try #require(view.textLayoutManager?.textLayoutFragment(for: location))
}

@MainActor
func fragmentFrame(_ view: NSTextView, at offset: Int) throws -> CGRect {
  let fragment = try layoutFragment(view, at: offset)
  return fragment.layoutFragmentFrame.offsetBy(
    dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
}

@MainActor
func scroll(_ view: NSTextView, toY y: CGFloat, layingOut: Bool = true) throws {
  let scroll = try #require(view.enclosingScrollView)
  scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
  scroll.reflectScrolledClipView(scroll.contentView)
  if layingOut { view.textLayoutManager?.textViewportLayoutController.layoutViewport() }
}

@MainActor
func scrollToTop(_ view: NSTextView, offset: Int) throws {
  try scroll(view, toY: try fragmentFrame(view, at: offset).minY)
}

/// Scrolls, laying out as display would, until the paragraph at `offset` is the drawn top line,
/// 5 points above the top edge. A width change leaves paragraphs away from the window with empty
/// frames, so it first bisects on the drawn top line.
@MainActor
func scrollDrawnTopLine(_ view: NSTextView, to offset: Int) throws {
  var low: CGFloat = 0
  var high = view.frame.height
  while high - low > 1 {
    let middle = (low + high) / 2
    try scroll(view, toY: middle)
    let drawn = try drawnTopLine(view).offset
    if drawn == offset { break }
    if drawn < offset { low = middle } else { high = middle }
  }
  try scroll(view, toY: try fragmentFrame(view, at: offset).minY + 5)
}

@MainActor
func screenY(_ view: NSTextView, offset: Int) throws -> CGFloat {
  let clip = try #require(view.enclosingScrollView?.contentView)
  return try fragmentFrame(view, at: offset).minY - clip.bounds.minY
}

@MainActor
func markerViews(_ view: NSView) -> [NSImageView] {
  view.subviews.compactMap { $0 as? NSImageView }
}

@MainActor
func markerIsShown(_ view: NotebookTextView, heading: OutlineHeading) throws -> Bool {
  guard let marker = view.foldedMarkers[heading.range.location] else { return false }
  let text = view.string as NSString
  let lastLine = text.paragraphRange(
    for: NSRange(location: NSMaxRange(heading.range) - 1, length: 0))
  let fragment = try layoutFragment(view, at: lastLine.location)
  let line = try #require(fragment.textLineFragments.last { $0.characterRange.length > 0 })
  let lineFrame = line.typographicBounds.offsetBy(
    dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
    dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
  let x = min(
    lineFrame.maxX + NotebookTextView.markerGap, view.bounds.maxX - marker.frame.width)
  return marker.image != nil && marker.superview === view && !marker.isHiddenOrHasHiddenAncestor
    && marker.alphaValue > 0 && marker.frame.width > 0 && marker.frame.height > 0
    && view.bounds.contains(marker.frame) && marker.frame.minX >= lineFrame.maxX
    && abs(marker.frame.minX - x) <= 0.5
    && lineFrame.minY <= marker.frame.midY && marker.frame.midY <= lineFrame.maxY
}

@MainActor
func isNoTallerThanTextPlusOneWindow(_ view: NSTextView) throws -> Bool {
  let clip = try #require(view.enclosingScrollView?.contentView)
  return view.frame.height <= (try textHeight(view)) + clip.bounds.height
}

@MainActor
func openMenuItem() throws -> (NSMenuItem, Selector) {
  let item = try #require(
    MainMenu.make().item(withTitle: "File")?.submenu?.item(withTitle: "Open…"))
  let action = try #require(item.action)
  try #require(action == #selector(AppDelegate.openDocument(_:)))
  return (item, action)
}

@MainActor
func drawnTopLine(_ view: NSTextView) throws -> (offset: Int, screenY: CGFloat) {
  let layout = try #require(view.textLayoutManager)
  let storage = try #require(view.textContentStorage)
  let viewport = try #require(layout.textViewportLayoutController.viewportRange)
  let top = view.visibleRect.minY
  var found: (Int, CGFloat)?
  layout.enumerateTextLayoutFragments(from: viewport.location, options: []) {
    let frame = $0.layoutFragmentFrame.offsetBy(dx: 0, dy: view.textContainerOrigin.y)
    guard frame.maxY > top else { return true }
    found = (
      storage.offset(from: storage.documentRange.location, to: $0.rangeInElement.location),
      frame.minY - top
    )
    return false
  }
  return try #require(found)
}

/// The View menu with each item aimed where AppKit sends it from the key window: the first
/// responder up the chain that answers the action. A test process has no key window, so AppKit's
/// own search finds no target and disables every item.
@MainActor
func viewMenuAimedAtTheResponderChain(_ controller: NotebookWindowController) throws -> NSMenu {
  let menu = try #require(MainMenu.make().item(withTitle: "View")?.submenu)
  let responder = try #require(controller.window?.firstResponder)
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
