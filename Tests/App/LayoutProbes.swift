import AppKit
import PalantirNotebook
import Testing

@testable import PalantirNotebookUI

extension NSTextView {
  private func laidOutParagraphs() throws -> [(string: String, frame: CGRect)] {
    let layout = try #require(textLayoutManager)
    var rows: [(String, CGRect)] = []
    var unavailable: [String] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) {
      let string = ($0.textElement as? NSTextParagraph)?.attributedString.string ?? ""
      if $0.state != .layoutAvailable { unavailable.append(string) }
      rows.append(
        (
          string,
          $0.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        ))
      return true
    }
    try #require(unavailable.isEmpty, "paragraphs without layout: \(unavailable.prefix(3))")
    return rows
  }

  private func layoutFragments() throws -> [(text: String, frame: CGRect)] {
    try laidOutParagraphs().map { ($0.string.trimmingCharacters(in: .newlines), $0.frame) }
  }

  func visibleParagraphs() throws -> [String] {
    try layoutFragments().map(\.text)
  }

  func visibleText() throws -> String {
    try laidOutParagraphs().map(\.string).joined()
  }

  func layoutBreaks() throws -> [String] {
    let rows = try layoutFragments()
    var breaks: [String] = []
    if let first = rows.first, first.frame.minY != textContainerOrigin.y {
      breaks.append("top->\(first.text): \(first.frame.minY - textContainerOrigin.y)")
    }
    for (first, second) in zip(rows, rows.dropFirst()) where second.frame.minY != first.frame.maxY {
      breaks.append("\(first.text)->\(second.text): \(second.frame.minY - first.frame.maxY)")
    }
    return breaks
  }

  func textHeight() throws -> CGFloat {
    let last = try #require(try layoutFragments().last)
    return last.frame.maxY - textContainerOrigin.y
  }

  func layoutFragment(at offset: Int) throws -> NSTextLayoutFragment {
    let storage = try #require(textContentStorage)
    let location = try #require(storage.location(storage.documentRange.location, offsetBy: offset))
    return try #require(textLayoutManager?.textLayoutFragment(for: location))
  }

  func fragmentFrame(at offset: Int) throws -> CGRect {
    try layoutFragment(at: offset).layoutFragmentFrame.offsetBy(
      dx: textContainerOrigin.x, dy: textContainerOrigin.y)
  }

  func scroll(toY y: CGFloat, layingOut: Bool = true) throws {
    let scroll = try #require(enclosingScrollView)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    if layingOut { textLayoutManager?.textViewportLayoutController.layoutViewport() }
  }

  func scrollToTop(offset: Int) throws {
    try scroll(toY: try fragmentFrame(at: offset).minY)
  }

  func screenY(offset: Int) throws -> CGFloat {
    let clip = try #require(enclosingScrollView?.contentView)
    return try fragmentFrame(at: offset).minY - clip.bounds.minY
  }

  func isNoTallerThanTextPlusOneWindow() throws -> Bool {
    let clip = try #require(enclosingScrollView?.contentView)
    return frame.height <= (try textHeight()) + clip.bounds.height
  }
}

extension NSView {
  func markerViews() -> [NSImageView] {
    subviews.compactMap { $0 as? NSImageView }
  }
}

extension NotebookTextView {
  var foldedHeadingStarts: Set<Int> { Set(folds.foldedHeadings.map(\.range.location)) }

  /// The heading whose first line starts with `line`.
  func heading(startingWith line: String) throws -> OutlineHeading {
    let start = (string as NSString).range(of: line).location
    try #require(start != NSNotFound, "no \(line)")
    let heading = try #require(folds.innermostHeading(at: start), "no heading at \(line)")
    try #require(heading.range.location == start, "\(line) does not start a heading")
    return heading
  }

  /// The paragraphs the last viewport layout drew in the window, from the drawn top line down.
  func drawnParagraphs() throws -> [(offset: Int, frame: CGRect)] {
    let storage = try #require(textContentStorage)
    let visible = visibleRect
    return
      laidOut
      .filter { $0.state == .layoutAvailable }
      .map {
        (
          storage.offset(from: storage.documentRange.location, to: $0.rangeInElement.location),
          $0.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)
        )
      }
      .filter { $0.1.maxY > visible.minY && $0.1.minY < visible.maxY }
      .sorted { $0.1.minY < $1.1.minY }
  }

  func drawnTopLine() throws -> (offset: Int, screenY: CGFloat) {
    let top = try #require(try drawnParagraphs().first, "no paragraph drawn in the window")
    return (top.offset, top.frame.minY - visibleRect.minY)
  }

  /// Scrolls, laying out as display would, until the paragraph at `offset` is the drawn top line,
  /// 5 points above the top edge. A width change leaves paragraphs away from the window with empty
  /// frames, so it first bisects on the drawn top line.
  func scrollDrawnTopLine(to offset: Int) throws {
    var low: CGFloat = 0
    var high = frame.height
    while high - low > 1 {
      let middle = (low + high) / 2
      try scroll(toY: middle)
      let drawn = try drawnTopLine().offset
      if drawn == offset { break }
      if drawn < offset { low = middle } else { high = middle }
    }
    try scroll(toY: try fragmentFrame(at: offset).minY + 5)
  }

  func markerIsShown(heading: OutlineHeading) throws -> Bool {
    guard let marker = foldedMarkers[heading.range.location] else { return false }
    let text = string as NSString
    let lastLine = text.paragraphRange(
      for: NSRange(location: NSMaxRange(heading.range) - 1, length: 0))
    let fragment = try layoutFragment(at: lastLine.location)
    let line = try #require(fragment.textLineFragments.last { $0.characterRange.length > 0 })
    let lineFrame = line.typographicBounds.offsetBy(
      dx: fragment.layoutFragmentFrame.minX + textContainerOrigin.x,
      dy: fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
    let x = min(lineFrame.maxX + NotebookTextView.markerGap, bounds.maxX - marker.frame.width)
    return marker.image != nil && marker.superview === self && !marker.isHiddenOrHasHiddenAncestor
      && marker.alphaValue > 0 && marker.frame.width > 0 && marker.frame.height > 0
      && bounds.contains(marker.frame) && marker.frame.minX >= lineFrame.maxX
      && abs(marker.frame.minX - x) <= 0.5
      && lineFrame.minY <= marker.frame.midY && marker.frame.midY <= lineFrame.maxY
  }
}
