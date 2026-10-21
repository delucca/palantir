#if DEBUG
  package import AppKit
  package import PalantirNotebook
  package import PalantirNotebookUI

  /// A measurement the layout probes could not make.
  package struct LayoutProbeError: Error, CustomStringConvertible {
    package let description: String

    init(_ description: String) { self.description = description }
  }

  func required<Value>(_ value: Value?, _ message: @autoclosure () -> String) throws -> Value {
    guard let value else { throw LayoutProbeError(message()) }
    return value
  }

  extension NSTextView {
    private func laidOutParagraphs() throws -> [(string: String, frame: CGRect)] {
      let layout = try required(textLayoutManager, "no text layout manager")
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
      guard unavailable.isEmpty else {
        throw LayoutProbeError("paragraphs without layout: \(unavailable.prefix(3))")
      }
      return rows
    }

    private func layoutFragments() throws -> [(text: String, frame: CGRect)] {
      try laidOutParagraphs().map { ($0.string.trimmingCharacters(in: .newlines), $0.frame) }
    }

    package func visibleParagraphs() throws -> [String] {
      try layoutFragments().map(\.text)
    }

    package func visibleText() throws -> String {
      try laidOutParagraphs().map(\.string).joined()
    }

    package func layoutBreaks() throws -> [String] {
      let rows = try layoutFragments()
      var breaks: [String] = []
      if let first = rows.first, first.frame.minY != textContainerOrigin.y {
        breaks.append("top->\(first.text): \(first.frame.minY - textContainerOrigin.y)")
      }
      for (first, second) in zip(rows, rows.dropFirst()) where second.frame.minY != first.frame.maxY
      {
        breaks.append("\(first.text)->\(second.text): \(second.frame.minY - first.frame.maxY)")
      }
      return breaks
    }

    package func textHeight() throws -> CGFloat {
      let last = try required(try layoutFragments().last, "no paragraph")
      return last.frame.maxY - textContainerOrigin.y
    }

    package func layoutFragment(at offset: Int) throws -> NSTextLayoutFragment {
      let storage = try required(textContentStorage, "no text content storage")
      let location = try required(
        storage.location(storage.documentRange.location, offsetBy: offset), "no offset \(offset)")
      return try required(
        textLayoutManager?.textLayoutFragment(for: location), "no fragment at \(offset)")
    }

    package func fragmentFrame(at offset: Int) throws -> CGRect {
      try layoutFragment(at: offset).layoutFragmentFrame.offsetBy(
        dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    package func screenY(offset: Int) throws -> CGFloat {
      let clip = try required(enclosingScrollView?.contentView, "no clip view")
      return try fragmentFrame(at: offset).minY - clip.bounds.minY
    }

    package func isNoTallerThanTextPlusOneWindow() throws -> Bool {
      let clip = try required(enclosingScrollView?.contentView, "no clip view")
      return frame.height <= (try textHeight()) + clip.bounds.height
    }
  }

  extension NSView {
    package func markerViews() -> [NSImageView] {
      subviews.compactMap { $0 as? NSImageView }
    }
  }

  extension NotebookTextView {
    package var foldedHeadingStarts: Set<Int> { Set(folds.foldedHeadings.map(\.range.location)) }

    /// The heading whose first line starts with `line`.
    package func heading(startingWith line: String) throws -> OutlineHeading {
      let start = (string as NSString).range(of: line).location
      guard start != NSNotFound else { throw LayoutProbeError("no \(line)") }
      let heading = try required(folds.innermostHeading(at: start), "no heading at \(line)")
      guard heading.range.location == start else {
        throw LayoutProbeError("\(line) does not start a heading")
      }
      return heading
    }

    /// The paragraphs the last viewport layout drew in the window, from the drawn top line down.
    package func drawnParagraphs() throws -> [(offset: Int, frame: CGRect)] {
      let storage = try required(textContentStorage, "no text content storage")
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

    /// Where a drawn paragraph does not start at the bottom of the one drawn above it: the offsets
    /// of both and the space between them, negative where they overlap.
    package func drawnGaps() throws -> [(after: Int, before: Int, height: CGFloat)] {
      Self.gaps(between: try drawnParagraphs())
    }

    /// The gaps between consecutive paragraphs of `drawn`, top to bottom.
    package static func gaps(between drawn: [(offset: Int, frame: CGRect)]) -> [(
      after: Int, before: Int, height: CGFloat
    )] {
      zip(drawn, drawn.dropFirst()).compactMap { first, second in
        second.frame.minY == first.frame.maxY
          ? nil : (first.offset, second.offset, second.frame.minY - first.frame.maxY)
      }
    }

    package func drawnTopLine() throws -> (offset: Int, screenY: CGFloat) {
      let top = try required(try drawnParagraphs().first, "no paragraph drawn in the window")
      return (top.offset, top.frame.minY - visibleRect.minY)
    }

    package func markerIsShown(heading: OutlineHeading) throws -> Bool {
      guard let marker = foldedMarkers[heading.range.location] else { return false }
      let text = string as NSString
      let lastLine = text.paragraphRange(
        for: NSRange(location: NSMaxRange(heading.range) - 1, length: 0))
      let fragment = try layoutFragment(at: lastLine.location)
      let line = try required(
        fragment.textLineFragments.last { $0.characterRange.length > 0 }, "no line with text")
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
#endif
