package import Foundation
import Markdown

/// A document-level Markdown heading and the text it owns.
package struct OutlineHeading: Equatable, Sendable {
  /// 1 to 6; a setext heading underlined with `=` is 1, with `-` is 2.
  package let level: Int
  /// The heading's own lines, 1-based; a setext heading ends at its underline.
  package let lines: ClosedRange<Int>
  /// The lines after it, up to the next heading of the same or a higher level.
  package let ownedLines: Range<Int>
  /// UTF-16 offsets of `lines` in the text, line endings included.
  package let range: NSRange
  /// UTF-16 offsets of `ownedLines` in the text; empty when the heading owns nothing.
  package let ownedRange: NSRange
}

/// The document-level headings of a Markdown text.
package struct Outline: Equatable, Sendable {
  /// In document order.
  package let headings: [OutlineHeading]
  private let length: Int

  /// Headings inside code blocks, quotes and lists do not count.
  package init(parsing text: String) {
    let lineStarts = Self.lineStarts(of: text)
    let length = text.utf16.count
    self.length = length
    func start(ofLine line: Int) -> Int {
      line <= lineStarts.count ? lineStarts[line - 1] : length
    }
    let source = text as NSString
    func line(_ number: Int) -> String {
      let lineStart = start(ofLine: number)
      let range = NSRange(location: lineStart, length: start(ofLine: number + 1) - lineStart)
      return source.substring(with: range).trimmingCharacters(in: .newlines)
    }
    let document = Document(parsing: text)
    let parsed: [(level: Int, lines: ClosedRange<Int>)] = document.children.compactMap { child in
      guard let heading = child as? Heading, let range = heading.range else { return nil }
      let first = range.lowerBound.line
      guard range.upperBound.line > first else { return (heading.level, first...first) }
      // swift-markdown 0.9.0 ends a setext heading, and some inlines in it, on the wrong line.
      let underline =
        stride(from: first + 1, through: lineStarts.count, by: 1).first {
          Self.isSetextUnderline(line($0))
        } ?? first
      // cmark starts a setext heading at the link reference definitions that open its paragraph;
      // they are the longest run of its lines that parses to nothing.
      guard Self.mayOpenLinkReferenceDefinition(line(first)) else {
        return (heading.level, first...underline)
      }
      let title =
        stride(from: underline - 1, to: first, by: -1).first {
          Document(parsing: (first..<$0).map(line).joined(separator: "\n")).childCount == 0
        } ?? first
      return (heading.level, title...underline)
    }
    headings = parsed.enumerated().map { index, heading in
      let stop =
        parsed[(index + 1)...].first { $0.level <= heading.level }?.lines.lowerBound
        ?? lineStarts.count + 1
      let firstOwned = heading.lines.upperBound + 1
      let ownedLines = firstOwned..<max(firstOwned, stop)
      let headingStart = start(ofLine: heading.lines.lowerBound)
      let ownedStart = start(ofLine: ownedLines.lowerBound)
      let ownedEnd = start(ofLine: ownedLines.upperBound)
      return OutlineHeading(
        level: heading.level,
        lines: heading.lines,
        ownedLines: ownedLines,
        range: NSRange(location: headingStart, length: ownedStart - headingStart),
        ownedRange: NSRange(location: ownedStart, length: ownedEnd - ownedStart)
      )
    }
  }

  private static func isSetextUnderline(_ line: String) -> Bool {
    line.wholeMatch(of: #/ {0,3}(?:=+|-+)[ \t]*/#) != nil
  }

  private static func mayOpenLinkReferenceDefinition(_ line: String) -> Bool {
    line.prefixMatch(of: #/ {0,3}\[/#) != nil
  }

  private static func lineStarts(of text: String) -> [Int] {
    var starts = [0]
    let units = Array(text.utf16)
    var index = 0
    while index < units.count {
      let unit = units[index]
      if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A {
        index += 1
      }
      if unit == 0x0A || unit == 0x0D, index + 1 < units.count {
        starts.append(index + 1)
      }
      index += 1
    }
    return starts
  }

  /// An offset at or past the end of the text becomes its last character's offset, or 0 if empty.
  package func clampedOffset(_ offset: Int) -> Int {
    min(offset, max(length - 1, 0))
  }

  /// The deepest heading whose own or owned text holds `offset`; nil before the first heading.
  package func innermostHeading(at offset: Int) -> OutlineHeading? {
    let offset = clampedOffset(offset)
    return headings.last {
      $0.range.location <= offset && offset < NSMaxRange($0.ownedRange)
    }
  }

  /// The headings no other heading owns, the ones Fold All folds. O(n) in the headings.
  package var topLevelHeadings: [OutlineHeading] {
    var sectionEnd = 0
    var topLevel: [OutlineHeading] = []
    for heading in headings {
      if heading.range.location >= sectionEnd { topLevel.append(heading) }
      sectionEnd = max(sectionEnd, NSMaxRange(heading.ownedRange))
    }
    return topLevel
  }
}
