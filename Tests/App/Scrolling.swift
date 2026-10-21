import AppKit
import PalantirNotebookInspector
import Testing

@testable import PalantirNotebookUI

extension NSTextView {
  func scroll(toY y: CGFloat, layingOut: Bool = true) throws {
    let scroll = try #require(enclosingScrollView)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    if layingOut { textLayoutManager?.textViewportLayoutController.layoutViewport() }
  }

  func scrollToTop(offset: Int) throws {
    try scroll(toY: try fragmentFrame(at: offset).minY)
  }
}

extension NotebookTextView {
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
}
