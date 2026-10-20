import Foundation
import Markdown

/// The document-level headings of a Markdown text.
package struct Outline: Equatable, Sendable {
  /// The headings outside code blocks, quotes and lists, in document order.
  let headings: [OutlineHeading]
  private let length: Int

  /// Reads the headings of the Markdown `text`, leaving out those inside code blocks, quotes and
  /// lists.
  package init(parsing text: String) {
    let lineStarts = Self.lineStarts(of: text)
    let length = text.utf16.count
    self.length = length
    func start(ofLine line: Int) -> Int {
      line <= lineStarts.count ? lineStarts[line - 1] : length
    }
    let source = text as NSString
    func rawLine(_ number: Int) -> String {
      let lineStart = start(ofLine: number)
      return source.substring(
        with: NSRange(location: lineStart, length: start(ofLine: number + 1) - lineStart))
    }
    func line(_ number: Int) -> String {
      rawLine(number).trimmingCharacters(in: .newlines)
    }
    // swift-markdown 0.9.0 ends a setext heading, and some inlines in it, on the wrong line.
    func underline(after title: Int) -> Int? {
      stride(from: title + 1, through: lineStarts.count, by: 1).first {
        Self.isSetextUnderline(line($0))
      }
    }
    let document = Document(parsing: text)
    let parsed: [(level: Int, lines: ClosedRange<Int>)] = document.children.compactMap { child in
      guard let heading = child as? Heading, let range = heading.range else { return nil }
      let first = range.lowerBound.line
      guard range.upperBound.line > first else { return (heading.level, first...first) }
      // cmark starts a setext heading at the link reference definitions that open its paragraph,
      // and no position in the tree marks their end: inline lines count from the heading's start
      // and miss the newlines inside a link's parentheses.
      var title = first
      if Self.mayOpenLinkReferenceDefinition(line(first)), let end = underline(after: first) {
        title += Self.linkReferenceDefinitionLines(opening: (first..<end).map(rawLine))
      }
      return (heading.level, title...(underline(after: title) ?? title))
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
        range: NSRange(location: headingStart, length: ownedStart - headingStart),
        ownedRange: NSRange(location: ownedStart, length: ownedEnd - ownedStart)
      )
    }
  }

  private static func isSetextUnderline(_ line: String) -> Bool {
    line.wholeMatch(of: #/ {0,3}(?:=+|-+)[ \t]*/#) != nil
  }

  private static func mayOpenLinkReferenceDefinition(_ line: String) -> Bool {
    line.prefixMatch(of: #/ {0,3}\^?\[/#) != nil
  }

  /// How many of a paragraph's `lines`, line endings included, the link reference definitions that
  /// open it take up. A port of how swift-cmark 0.9.0 strips them, in
  /// `resolve_reference_link_definitions`; linear in the lines.
  private static func linkReferenceDefinitionLines(opening lines: [String]) -> Int {
    // cmark adds each line to the paragraph without its leading spaces and tabs.
    var text: [UInt8] = []
    var lineStarts: [Int] = []
    for line in lines {
      lineStarts.append(text.count)
      text += line.replacingOccurrences(of: "\0", with: "\u{FFFD}").utf8.drop {
        $0 == 0x20 || $0 == 0x09
      }
    }
    lineStarts.append(text.count)
    func byte(_ index: Int) -> UInt8 { index < text.count ? text[index] : 0 }
    func isPunctuation(_ byte: UInt8) -> Bool {
      (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte)
        || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
    }
    func isSpace(_ byte: UInt8) -> Bool { [0x09, 0x0A, 0x0D, 0x20].contains(byte) }
    func skipSpaces(_ index: inout Int) {
      while byte(index) == 0x20 || byte(index) == 0x09 { index += 1 }
    }
    func skipLineEnd(_ index: inout Int) -> Bool {
      let start = index
      if byte(index) == 0x0D { index += 1 }
      if byte(index) == 0x0A { index += 1 }
      return index > start || index >= text.count
    }
    func skipSpacesAndALineEnd(_ index: inout Int) {
      skipSpaces(&index)
      if skipLineEnd(&index) { skipSpaces(&index) }
    }
    // `link_label`: at most 1,000 bytes between the brackets, not all of them spaces.
    func label(_ index: inout Int) -> Bool {
      guard byte(index) == 0x5B else { return false }
      var end = index + 1
      while byte(end) != 0, byte(end) != 0x5B, byte(end) != 0x5D {
        end += byte(end) == 0x5C && isPunctuation(byte(end + 1)) ? 2 : 1
        if end - index - 1 > 1_000 { return false }
      }
      guard byte(end) == 0x5D, text[(index + 1)..<end].contains(where: { !isSpace($0) }) else {
        return false
      }
      index = end + 1
      return true
    }
    // `manual_scan_link_url`: a destination that does not reach the end of the paragraph.
    func destination(_ index: inout Int) -> Bool {
      var end = index
      if byte(end) == 0x3C {
        end += 1
        while end < text.count {
          if byte(end) == 0x3E {
            end += 1
            break
          } else if byte(end) == 0x5C {
            end += 2
          } else if byte(end) == 0x0A || byte(end) == 0x3C {
            return false
          } else {
            end += 1
          }
        }
      } else {
        var depth = 0
        while end < text.count {
          if byte(end) == 0x5C, isPunctuation(byte(end + 1)) {
            end += 2
          } else if byte(end) == 0x28 {
            depth += 1
            end += 1
            if depth > 32 { return false }
          } else if byte(end) == 0x29 {
            if depth == 0 { break }
            depth -= 1
            end += 1
          } else if isSpace(byte(end)) {
            if end == index { return false }
            break
          } else {
            end += 1
          }
        }
      }
      guard end < text.count else { return false }
      index = end
      return true
    }
    // `scan_link_title`: the length of the longest quoted or parenthesized title, or 0.
    func titleLength(at index: Int) -> Int {
      let open = byte(index)
      guard open == 0x22 || open == 0x27 || open == 0x28 else { return 0 }
      let close: UInt8 = open == 0x28 ? 0x29 : open
      var length = 0
      var end = index + 1
      while end < text.count {
        let escaped = end > index + 1 && byte(end - 1) == 0x5C
        if byte(end) == close {
          length = end + 1 - index
          if !escaped { break }
        } else if open == 0x28, byte(end) == 0x28, !escaped {
          break
        }
        end += 1
      }
      return length
    }
    // `cmark_parse_reference_inline`
    func definition(_ index: inout Int) -> Bool {
      var end = index
      guard label(&end), byte(end) == 0x3A else { return false }
      end += 1
      skipSpacesAndALineEnd(&end)
      guard destination(&end) else { return false }
      let beforeTitle = end
      skipSpacesAndALineEnd(&end)
      let title = end == beforeTitle ? 0 : titleLength(at: end)
      end = title > 0 ? end + title : beforeTitle
      skipSpaces(&end)
      if !skipLineEnd(&end) {
        guard title > 0 else { return false }
        end = beforeTitle
        skipSpaces(&end)
        guard skipLineEnd(&end) else { return false }
      }
      index = end
      return true
    }
    // `cmark_parse_reference_attributes_inline`
    func attributes(_ index: inout Int) -> Bool {
      guard byte(index) == 0x5E else { return false }
      var end = index + 1
      guard label(&end), byte(end) == 0x3A else { return false }
      end += 1
      skipSpacesAndALineEnd(&end)
      let start = end
      while byte(end) != 0, byte(end) != 0x0A, byte(end) != 0x0D { end += 1 }
      guard end > start, skipLineEnd(&end) else { return false }
      index = end
      return true
    }
    var consumed = 0
    while definition(&consumed) || attributes(&consumed) {}
    return lineStarts.firstIndex(of: consumed) ?? 0
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
  func clampedOffset(_ offset: Int) -> Int {
    min(offset, max(length - 1, 0))
  }

  /// The deepest heading whose own or owned text holds `offset`; nil before the first heading.
  func innermostHeading(at offset: Int) -> OutlineHeading? {
    let offset = clampedOffset(offset)
    return headings.last {
      $0.range.location <= offset && offset < NSMaxRange($0.ownedRange)
    }
  }

  /// The headings no other heading owns, the ones Fold All folds. O(n) in the headings.
  var topLevelHeadings: [OutlineHeading] {
    var sectionEnd = 0
    var topLevel: [OutlineHeading] = []
    for heading in headings {
      if heading.range.location >= sectionEnd { topLevel.append(heading) }
      sectionEnd = max(sectionEnd, NSMaxRange(heading.ownedRange))
    }
    return topLevel
  }
}
