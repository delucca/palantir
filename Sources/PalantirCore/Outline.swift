package import Foundation
import Markdown

package struct OutlineHeading: Equatable, Sendable {
  package let level: Int
  package let lines: ClosedRange<Int>
  package let ownedLines: Range<Int>
  package let range: NSRange
  package let ownedRange: NSRange
}

package struct Outline: Equatable, Sendable {
  package let headings: [OutlineHeading]
  private let length: Int

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
      return (heading.level, first...underline)
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

  package func clampedOffset(_ offset: Int) -> Int {
    min(offset, max(length - 1, 0))
  }

  package func innermostHeading(at offset: Int) -> OutlineHeading? {
    let offset = clampedOffset(offset)
    return headings.last {
      $0.range.location <= offset && offset < NSMaxRange($0.ownedRange)
    }
  }

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
