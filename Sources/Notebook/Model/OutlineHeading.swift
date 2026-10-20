package import Foundation

/// A document-level Markdown heading and the text it owns.
package struct OutlineHeading: Equatable, Sendable {
  /// 1 to 6; a setext heading underlined with `=` is 1, with `-` is 2.
  let level: Int
  /// The heading's own lines, 1-based; a setext heading ends at its underline.
  let lines: ClosedRange<Int>
  /// The lines after it, up to the next heading of the same or a higher level.
  let ownedLines: Range<Int>
  /// UTF-16 offsets of `lines` in the text, line endings included.
  package let range: NSRange
  /// UTF-16 offsets of `ownedLines` in the text; empty when the heading owns nothing.
  let ownedRange: NSRange
}
