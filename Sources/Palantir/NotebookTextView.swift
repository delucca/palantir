import AppKit
import PalantirCore

final class FoldedParagraphs: NSObject, NSTextContentStorageDelegate {
  var hiddenRanges: [NSRange] = [] {
    didSet {
      hiddenOffsets = hiddenRanges.compactMap { Range($0) }.reduce(into: IndexSet()) {
        $0.insert(integersIn: $1)
      }
    }
  }
  private var hiddenOffsets = IndexSet()

  // TextKit asks about every hidden paragraph it passes, thousands of times a layout.
  func hides(_ offset: Int) -> Bool {
    hiddenOffsets.contains(offset)
  }

  func textContentManager(
    _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
    options: NSTextContentManager.EnumerationOptions
  ) -> Bool {
    guard let storage = textContentManager as? NSTextContentStorage,
      let start = textElement.elementRange?.location
    else { return true }
    return !hides(storage.offset(from: storage.documentRange.location, to: start))
  }
}

final class NotebookTextView: NSTextView {
  static let markerGap: CGFloat = 4
  static let markerInset = NSSize(width: markerGap + 16, height: 0)

  private let folding = FoldedParagraphs()
  private(set) var outline = Outline(parsing: "")
  private(set) var foldedHeadingStarts: Set<Int> = []
  private(set) var foldedMarkers: [Int: NSImageView] = [:]
  private var laidOut: [NSTextLayoutFragment] = []
  private var foldedHeadingEndingAt: [Int: Int] = [:]

  func show(_ text: String) {
    textContentStorage?.delegate = folding
    folding.hiddenRanges = []
    foldedHeadingStarts = []
    foldedHeadingEndingAt = [:]
    if let scroll = enclosingScrollView { minSize.height = scroll.contentSize.height }
    string = text
    outline = Outline(parsing: text)
    setSelectedRange(NSRange(location: 0, length: 0))
    guard let layout = textLayoutManager else { return }
    layout.ensureLayout(for: layout.documentRange)
    if let scroll = enclosingScrollView {
      scroll.contentView.scroll(to: .zero)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    layout.textViewportLayoutController.layoutViewport()
  }

  @objc func foldHeading(_ sender: Any?) {
    guard let heading = headingAtSelection else { return }
    setFolded(foldedHeadingStarts.union([heading.range.location]))
  }

  @objc func unfoldHeading(_ sender: Any?) {
    guard let heading = headingAtSelection else { return }
    setFolded(foldedHeadingStarts.subtracting([heading.range.location]))
  }

  @objc func foldAll(_ sender: Any?) {
    setFolded(foldedHeadingStarts.union(outline.topLevelHeadings.map(\.range.location)))
  }

  @objc func unfoldAll(_ sender: Any?) {
    setFolded([])
  }

  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(foldHeading(_:)), #selector(unfoldHeading(_:)):
      headingAtSelection != nil
    case #selector(foldAll(_:)), #selector(unfoldAll(_:)):
      !outline.headings.isEmpty
    default:
      super.validateMenuItem(menuItem)
    }
  }

  private var headingAtSelection: OutlineHeading? {
    outline.innermostHeading(at: selectedRange().location)
  }

  override func setFrameSize(_ newSize: NSSize) {
    // A fold's floor holds the top line of the old wrap; at a new width it only leaves blank space.
    if newSize.width != frame.width, let scroll = enclosingScrollView {
      minSize.height = scroll.contentSize.height
    }
    super.setFrameSize(newSize)
  }

  private func setFolded(_ headingStarts: Set<Int>) {
    guard let layout = textLayoutManager, let storage = textContentStorage,
      let scroll = enclosingScrollView
    else { return }
    let before = Set(folding.hiddenRanges.map(\.location))
    // After a width change or a scroll, the viewport may not be laid out yet; display would do it.
    layout.textViewportLayoutController.layoutViewport()
    let anchor = topLine(layout, storage)
    foldedHeadingStarts = headingStarts
    let folded = outline.headings.filter { headingStarts.contains($0.range.location) }
    // Markers move on every viewport layout; find the paragraph each one sits on once, here.
    let text = string as NSString
    foldedHeadingEndingAt = [:]
    for heading in folded {
      let last = NSRange(location: NSMaxRange(heading.range) - 1, length: 0)
      foldedHeadingEndingAt[text.paragraphRange(for: last).location] = heading.range.location
    }
    folding.hiddenRanges = folded.map(\.ownedRange).filter { $0.length > 0 }
    let selection = selectedRange()
    let caret = outline.clampedOffset(selection.location)
    if let hiding = folded.first(where: {
      NSLocationInRange(caret, $0.ownedRange)
        || NSIntersectionRange(selection, $0.ownedRange).length > 0
    }) {
      setSelectedRange(NSRange(location: hiding.range.location, length: 0))
    }
    let changed = before.symmetricDifference(folding.hiddenRanges.map(\.location))
    if let first = changed.min(),
      let start = storage.location(storage.documentRange.location, offsetBy: first),
      let range = NSTextRange(location: start, end: storage.documentRange.endLocation)
    {
      // Fragments below a change keep stale positions and estimated heights until laid out again.
      layout.invalidateLayout(for: range)
    }
    // A width change drops the layout of every paragraph outside the viewport; lay them out after
    // finding the top line on screen, or it shifts.
    layout.ensureLayout(for: layout.documentRange)
    // The clip view keeps its pixel offset, so put the top line back at its screen y.
    var top = scroll.contentView.bounds.minY
    if let anchor {
      let hiding = folded.first { NSLocationInRange(anchor.offset, $0.ownedRange) }
      let screenY = hiding == nil ? anchor.screenY : max(0, anchor.screenY)
      if let y = minY(of: hiding?.range.location ?? anchor.offset, layout, storage) {
        top = max(0, y - screenY)
      }
    }
    // Room below the last line, or a fold near the end lets the clip view scroll the text down.
    minSize.height = max(scroll.contentSize.height, top + scroll.contentSize.height)
    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: top))
    scroll.reflectScrolledClipView(scroll.contentView)
    layout.textViewportLayoutController.layoutViewport()
  }

  private func topLine(_ layout: NSTextLayoutManager, _ storage: NSTextContentStorage) -> (
    offset: Int, screenY: CGFloat
  )? {
    let visibleTop = visibleRect.minY
    var found: (offset: Int, screenY: CGFloat)?
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) {
      // Outside the viewport, a width change leaves empty or estimated frames.
      let frame = $0.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)
      guard $0.state == .layoutAvailable, frame.maxY > visibleTop else { return true }
      found = (
        storage.offset(from: storage.documentRange.location, to: $0.rangeInElement.location),
        frame.minY - visibleTop
      )
      return false
    }
    return found
  }

  private func minY(
    of offset: Int, _ layout: NSTextLayoutManager, _ storage: NSTextContentStorage
  ) -> CGFloat? {
    guard let location = storage.location(storage.documentRange.location, offsetBy: offset),
      let fragment = layout.textLayoutFragment(for: location)
    else { return nil }
    return fragment.layoutFragmentFrame.minY + textContainerOrigin.y
  }

  override func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController)
  {
    super.textViewportLayoutControllerWillLayout(controller)
    laidOut = []
  }

  override func textViewportLayoutController(
    _ controller: NSTextViewportLayoutController,
    configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
  ) {
    super.textViewportLayoutController(controller, configureRenderingSurfaceFor: textLayoutFragment)
    laidOut.append(textLayoutFragment)
  }

  override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController)
  {
    super.textViewportLayoutControllerDidLayout(controller)
    updateMarkers()
  }

  private func updateMarkers() {
    guard let storage = textContentStorage else { return }
    var shown: Set<Int> = []
    for fragment in laidOut {
      let offset = storage.offset(
        from: storage.documentRange.location, to: fragment.rangeInElement.location)
      // The last line fragment of the last paragraph is empty when the text ends with a newline.
      guard let heading = foldedHeadingEndingAt[offset],
        let line = fragment.textLineFragments.last(where: { $0.characterRange.length > 0 })
      else { continue }
      shown.insert(heading)
      let marker = foldedMarkers[heading] ?? makeMarker(heading)
      let bounds = line.typographicBounds
      let frame = fragment.layoutFragmentFrame
      let side = bounds.height
      let x = textContainerOrigin.x + frame.minX + bounds.maxX + Self.markerGap
      marker.frame = NSRect(
        x: min(x, self.bounds.maxX - side), y: textContainerOrigin.y + frame.minY + bounds.minY,
        width: side, height: side)
    }
    for (offset, marker) in foldedMarkers where !shown.contains(offset) {
      marker.removeFromSuperview()
      foldedMarkers[offset] = nil
    }
  }

  private func makeMarker(_ offset: Int) -> NSImageView {
    let marker = NSImageView(
      image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Folded")!)
    marker.contentTintColor = .secondaryLabelColor
    addSubview(marker)
    foldedMarkers[offset] = marker
    return marker
  }
}
