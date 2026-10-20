import AppKit
import Foundation
import PalantirNotebook

final class NotebookTextView: NSTextView {
  static let markerGap: CGFloat = 4
  static let markerInset = NSSize(width: markerGap + 16, height: 0)

  private let folding = FoldedParagraphs()
  private(set) var folds = Folds(outline: Outline(parsing: ""))
  private(set) var foldedMarkers: [Int: NSImageView] = [:]
  private(set) var laidOut: [NSTextLayoutFragment] = []
  private var foldedHeadingEndingAt: [Int: Int] = [:]
  private(set) var foldedTop: CGFloat?

  func show(_ text: String) {
    textContentStorage?.delegate = folding
    folding.hiddenRanges = []
    foldedHeadingEndingAt = [:]
    foldedTop = nil
    if let scroll = enclosingScrollView { minSize.height = scroll.contentSize.height }
    string = text
    folds = Folds(outline: Outline(parsing: text))
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
    setFolded { $0.fold(heading) }
  }

  @objc func unfoldHeading(_ sender: Any?) {
    guard let heading = headingAtSelection else { return }
    setFolded { $0.unfold(heading) }
  }

  @objc func foldAll(_ sender: Any?) {
    setFolded { $0.foldAll() }
  }

  @objc func unfoldAll(_ sender: Any?) {
    setFolded { $0.unfoldAll() }
  }

  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(foldHeading(_:)), #selector(unfoldHeading(_:)):
      headingAtSelection != nil
    case #selector(foldAll(_:)), #selector(unfoldAll(_:)):
      folds.hasHeadings
    default:
      super.validateMenuItem(menuItem)
    }
  }

  private var headingAtSelection: OutlineHeading? {
    folds.innermostHeading(at: selectedRange().location)
  }

  override var minSize: NSSize {
    get { super.minSize }
    // NSTextView resets minSize to the clip view's height on every resize, dropping a fold's floor.
    set {
      var size = newValue
      if let foldedTop, let scroll = enclosingScrollView {
        size.height = max(size.height, foldedTop + scroll.contentSize.height)
      }
      super.minSize = size
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    guard newSize.width != frame.width,
      foldedTop != nil,
      let layout = textLayoutManager,
      let storage = textContentStorage,
      let scroll = enclosingScrollView
    else { return super.setFrameSize(newSize) }
    // After a scroll, the viewport may not be laid out yet; display would do it.
    layout.textViewportLayoutController.layoutViewport()
    let anchor = topLine(layout, storage)
    super.setFrameSize(newSize)
    // The new width leaves every paragraph without layout; lay out up to the top line.
    guard let anchor,
      let location = storage.location(storage.documentRange.location, offsetBy: anchor.offset),
      let range = NSTextRange(
        location: storage.documentRange.location,
        end: storage.location(location, offsetBy: 1) ?? location)
    else { return }
    layout.ensureLayout(for: range)
    guard let fragment = layout.textLayoutFragment(for: location) else { return }
    let paragraph = fragment.layoutFragmentFrame
    // A paragraph that the new width shortens can end above the window at its old screen y.
    let screenY = paragraph.height + anchor.screenY > 0 ? anchor.screenY : 0
    let top = max(0, paragraph.minY + textContainerOrigin.y - screenY)
    // Lay out a window below the top line: enough to tell whether the floor still binds.
    let windowBottom = top + scroll.contentSize.height
    layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) {
      $0.layoutFragmentFrame.maxY + textContainerOrigin.y < windowBottom
    }
    let textBottom = layout.usageBoundsForTextContainer.maxY + textContainerOrigin.y
    foldedTop = top > 0 && windowBottom > textBottom ? top : nil
    // Without a floor the frame follows the text, which has layout only down to the window.
    if foldedTop == nil { layout.ensureLayout(for: layout.documentRange) }
    minSize.height = (foldedTop ?? 0) + scroll.contentSize.height
    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: top))
    scroll.reflectScrolledClipView(scroll.contentView)
    // The frame takes the new text height only in a viewport layout; until then a resize can pull
    // the clip view up to the old height.
    layout.textViewportLayoutController.layoutViewport()
  }

  private func setFolded(_ change: (inout Folds) -> Void) {
    guard let layout = textLayoutManager,
      let storage = textContentStorage,
      let scroll = enclosingScrollView
    else { return }
    // After a width change or a scroll, the viewport may not be laid out yet; display would do it.
    layout.textViewportLayoutController.layoutViewport()
    let anchor = topLine(layout, storage)
    let previous = folds
    change(&folds)
    // Markers move on every viewport layout; find the paragraph each one sits on once, here.
    let text = string as NSString
    foldedHeadingEndingAt = [:]
    for heading in folds.foldedHeadings {
      let last = NSRange(location: NSMaxRange(heading.range) - 1, length: 0)
      foldedHeadingEndingAt[text.paragraphRange(for: last).location] = heading.range.location
    }
    folding.hiddenRanges = folds.hiddenRanges
    if let caret = folds.caret(for: selectedRange(), since: previous) {
      setSelectedRange(NSRange(location: caret, length: 0))
    }
    let changed = Set(previous.hiddenRanges.map(\.location))
      .symmetricDifference(folding.hiddenRanges.map(\.location))
    if let first = changed.min(),
      let start = storage.location(storage.documentRange.location, offsetBy: first),
      let range = NSTextRange(location: start, end: storage.documentRange.endLocation)
    {
      // Fragments below a change keep stale positions and estimated heights until laid out again.
      layout.invalidateLayout(for: range)
    }
    // A width change drops the layout of every paragraph outside the viewport; lay them out after
    // finding the top line on screen, or it shifts. Every command pays for this in time linear in
    // the text, on the main actor.
    layout.ensureLayout(for: layout.documentRange)
    // The clip view keeps its pixel offset, so put the top line back at its screen y.
    var top = scroll.contentView.bounds.minY
    if let anchor {
      let hiding = folds.heading(hiding: anchor.offset)
      let screenY = hiding == nil ? anchor.screenY : max(0, anchor.screenY)
      if let y = minY(of: hiding?.range.location ?? anchor.offset, layout, storage) {
        top = max(0, y - screenY)
      }
    }
    // Room below the last line, or a fold near the end lets the clip view scroll the text down.
    let textBottom = layout.usageBoundsForTextContainer.maxY + textContainerOrigin.y
    foldedTop = top > 0 && top + scroll.contentSize.height > textBottom ? top : nil
    minSize.height = (foldedTop ?? 0) + scroll.contentSize.height
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
        x: min(x, self.bounds.maxX - side),
        y: textContainerOrigin.y + frame.minY + bounds.minY,
        width: side,
        height: side)
    }
    for (offset, marker) in foldedMarkers where !shown.contains(offset) {
      marker.removeFromSuperview()
      foldedMarkers[offset] = nil
    }
  }

  private func makeMarker(_ offset: Int) -> NSImageView {
    // "ellipsis" is an SF Symbol in every macOS release that has them, so the image exists.
    let marker = NSImageView(
      image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Folded")!)
    marker.contentTintColor = .secondaryLabelColor
    addSubview(marker)
    foldedMarkers[offset] = marker
    return marker
  }
}
