package import Foundation

/// A document-level Markdown heading and the text it owns.
package struct OutlineHeading: Equatable, Sendable {
  /// UTF-16 offsets of the heading's own lines in the text, line endings included; a setext
  /// heading ends at its underline.
  package let range: NSRange
  /// UTF-16 offsets of the lines after it, up to the next heading of the same or a higher level;
  /// empty when the heading owns nothing.
  let ownedRange: NSRange
}
