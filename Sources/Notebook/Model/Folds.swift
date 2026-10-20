package import Foundation

/// The folded headings of an outline and the text they hide.
package struct Folds: Equatable, Sendable {
  let outline: Outline
  /// The `range.location` of each folded heading.
  private(set) var headingStarts: Set<Int> = []

  package init(outline: Outline) {
    self.outline = outline
  }

  /// The folded headings, in document order. O(n) in the headings.
  package var foldedHeadings: [OutlineHeading] {
    outline.headings.filter { headingStarts.contains($0.range.location) }
  }

  /// The owned text of each folded heading that owns any, in document order. O(n) in the headings.
  package var hiddenRanges: [NSRange] {
    foldedHeadings.map(\.ownedRange).filter { $0.length > 0 }
  }

  package func innermostHeading(at offset: Int) -> OutlineHeading? {
    outline.innermostHeading(at: offset)
  }

  package var hasHeadings: Bool {
    !outline.headings.isEmpty
  }

  package mutating func fold(_ heading: OutlineHeading) {
    headingStarts.insert(heading.range.location)
  }

  package mutating func unfold(_ heading: OutlineHeading) {
    headingStarts.remove(heading.range.location)
  }

  package mutating func foldAll() {
    headingStarts.formUnion(outline.topLevelHeadings.map(\.range.location))
  }

  package mutating func unfoldAll() {
    headingStarts = []
  }

  /// The outermost folded heading that hides `offset`: the first one in document order.
  package func heading(hiding offset: Int) -> OutlineHeading? {
    foldedHeadings.first { NSLocationInRange(offset, $0.ownedRange) }
  }

  /// Where a selection goes after the folds change from `previous`: to the start of the first
  /// folded heading whose owned text holds the caret, or that `previous` did not fold and whose
  /// owned text holds part of the selection. Nil keeps the selection.
  package func caret(for selection: NSRange, since previous: Folds) -> Int? {
    let caret = outline.clampedOffset(selection.location)
    return foldedHeadings.first {
      NSLocationInRange(caret, $0.ownedRange)
        || !previous.headingStarts.contains($0.range.location)
          && NSIntersectionRange(selection, $0.ownedRange).length > 0
    }?.range.location
  }
}
