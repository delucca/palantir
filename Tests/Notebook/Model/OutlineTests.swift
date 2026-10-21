import Foundation
import Testing

@testable import PalantirNotebook

@Suite(.layer(.unit))
struct OutlineTests {
  private let introTasksNotes = "Intro.\n# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\nDone."

  private func text(_ string: String, _ range: NSRange) -> String {
    (string as NSString).substring(with: range)
  }

  /// The UTF-16 offsets of the 1-based `lines` of `string`, line endings included.
  private func range(of lines: Range<Int>, in string: String) -> NSRange {
    let text = string as NSString
    var starts = [0]
    while let last = starts.last, last < text.length {
      starts.append(NSMaxRange(text.lineRange(for: NSRange(location: last, length: 0))))
    }
    let start = starts[min(lines.lowerBound, starts.count) - 1]
    let end = starts[min(lines.upperBound, starts.count) - 1]
    return NSRange(location: start, length: end - start)
  }

  private func range(of lines: ClosedRange<Int>, in string: String) -> NSRange {
    range(of: lines.lowerBound..<lines.upperBound + 1, in: string)
  }

  // req~heading-outline.owned-range~1
  @Test func headingsOwnTheLinesUpToTheNextPeerOrHigherHeading() throws {
    let notebook = "# Tasks\n## Fix the reaper\nIt leaks.\n## Ship bilbo\n# Notes\nDone.\n"
    let outline = Outline(parsing: notebook)
    try #require(
      outline.headings.map(\.range)
        == [1...1, 2...2, 4...4, 5...5].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange)
        == [2..<5, 3..<4, 5..<5, 6..<7].map { range(of: $0, in: notebook) })
    #expect(
      text(notebook, outline.headings[0].ownedRange)
        == "## Fix the reaper\nIt leaks.\n## Ship bilbo\n")
    #expect(text(notebook, outline.headings[1].ownedRange) == "It leaks.\n")
    #expect(outline.headings[2].ownedRange.length == 0)
    #expect(text(notebook, outline.headings[3].ownedRange) == "Done.\n")
  }

  // req~heading-outline.owned-range~1
  @Test func ownedRangesAreUTF16OffsetsOfTheText() throws {
    let notebook = "Intro 🎉 é.\r\n# Tâsks 🎉\r\nNaïve 👩‍👩‍👧 text.\n\nSetext\n======\nbody\n# Last"
    let outline = Outline(parsing: notebook)
    try #require(outline.headings.count == 3)
    #expect(text(notebook, outline.headings[0].range) == "# Tâsks 🎉\r\n")
    #expect(text(notebook, outline.headings[0].ownedRange) == "Naïve 👩‍👩‍👧 text.\n\n")
    #expect(text(notebook, outline.headings[1].range) == "Setext\n======\n")
    #expect(text(notebook, outline.headings[1].ownedRange) == "body\n")
    #expect(text(notebook, outline.headings[2].range) == "# Last")
    #expect(
      outline.headings[2].ownedRange == NSRange(location: (notebook as NSString).length, length: 0))
  }

  // req~heading-outline.owned-range~1
  @Test func classicMacLineEndingsBreakLines() throws {
    let notebook = "# Tasks\r## Fix the reaper\rIt leaks.\r# Notes\rDone.\r"
    let outline = Outline(parsing: notebook)
    try #require(
      outline.headings.map(\.range) == [1...1, 2...2, 4...4].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange)
        == [2..<4, 3..<4, 5..<6].map { range(of: $0, in: notebook) })
    #expect(text(notebook, outline.headings[0].ownedRange) == "## Fix the reaper\rIt leaks.\r")
    #expect(text(notebook, outline.headings[1].ownedRange) == "It leaks.\r")
    #expect(text(notebook, outline.headings[2].ownedRange) == "Done.\r")
  }

  // req~heading-outline.owned-range~1
  @Test func setextHeadingsEndAtTheirUnderline() {
    let notebook = "Setext\n------\n# Next\nTwo line\nsetext\n===\n\nbody\n"
    let outline = Outline(parsing: notebook)
    #expect(
      outline.headings.map(\.range) == [1...2, 3...3, 4...6].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange)
        == [3..<3, 4..<4, 7..<9].map { range(of: $0, in: notebook) })
  }

  // req~heading-outline.owned-range~1
  @Test func setextHeadingWithAStrikethroughSpanningLines() throws {
    let notebook = "~~Two line\nsetext~~\n===\nbody\n# Next\n"
    let outline = Outline(parsing: notebook)
    try #require(
      outline.headings.map(\.range) == [1...3, 5...5].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange) == [4..<5, 6..<6].map { range(of: $0, in: notebook) })
    #expect(text(notebook, outline.headings[0].ownedRange) == "body\n")
  }

  // req~heading-outline.owned-range~1
  @Test func setextHeadingWithALinkSpanningLines() throws {
    let notebook = "[link](   /uri\n  \"title\"  )\n===\nbody\n# Next\n"
    let outline = Outline(parsing: notebook)
    try #require(
      outline.headings.map(\.range) == [1...3, 5...5].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange) == [4..<5, 6..<6].map { range(of: $0, in: notebook) })
    #expect(text(notebook, outline.headings[0].range) == "[link](   /uri\n  \"title\"  )\n===\n")
    #expect(text(notebook, outline.headings[0].ownedRange) == "body\n")
  }

  // req~heading-outline.owned-range~1
  @Test(arguments: ["", "   "])
  func setextHeadingAfterLinkDefinitionsStartsAtItsText(indent: String) throws {
    let notebook = "# Tasks\nBody.\n\n\(indent)[ref]: /url\nTitle\n===\n"
    let outline = Outline(parsing: notebook)
    try #require(
      outline.headings.map(\.range) == [1...1, 5...6].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange) == [2..<5, 7..<7].map { range(of: $0, in: notebook) })
    #expect(text(notebook, outline.headings[0].ownedRange) == "Body.\n\n\(indent)[ref]: /url\n")
  }

  // req~heading-outline.owned-range~1
  @Test func aLongSetextHeadingIsParsedOnce() {
    let title = String(repeating: "Fix the reaper\n", count: 2_000)
    let notebook = "# Tasks\nBody.\n\n" + title + "===\nbody\n"
    let clock = ContinuousClock()
    var outline = Outline(parsing: "")
    let elapsed = clock.measure { outline = Outline(parsing: notebook) }
    #expect(
      outline.headings.map(\.range) == [1...1, 4...2_004].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange)
        == [2..<4, 2_005..<2_006].map { range(of: $0, in: notebook) })
    #expect(elapsed < .seconds(1))
  }

  // req~heading-outline.owned-range~1
  @Test func aLongSetextHeadingThatStartsWithABracketIsParsedOnce() {
    let title = "[2026-10-20 10:00] start\n" + String(repeating: "log line\n", count: 2_000)
    let notebook = "# Tasks\nBody.\n\n" + title + "===\nbody\n"
    let clock = ContinuousClock()
    var outline = Outline(parsing: "")
    let elapsed = clock.measure { outline = Outline(parsing: notebook) }
    #expect(
      outline.headings.map(\.range) == [1...1, 4...2_005].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange)
        == [2..<4, 2_006..<2_007].map { range(of: $0, in: notebook) })
    #expect(elapsed < .seconds(1))
  }

  // req~heading-outline.owned-range~1
  @Test func aLongSetextHeadingAfterALinkDefinitionIsParsedOnce() {
    let title = String(repeating: "Fix the reaper\n", count: 2_000)
    let notebook = "# Tasks\nBody.\n\n[ref]: /url\n" + title + "===\nbody\n"
    let clock = ContinuousClock()
    var outline = Outline(parsing: "")
    let elapsed = clock.measure { outline = Outline(parsing: notebook) }
    #expect(
      outline.headings.map(\.range) == [1...1, 5...2_005].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange)
        == [2..<5, 2_006..<2_007].map { range(of: $0, in: notebook) })
    #expect(elapsed < .seconds(1))
  }

  // req~heading-outline.owned-range~1
  @Test func aSetextHeadingWhoseTextLooksLikeAnUnderlineStartsAfterTheDefinitions() throws {
    let notebook = "# Tasks\nBody.\n\n[ref]: /url\n===\n===\nbody\n"
    let outline = Outline(parsing: notebook)
    try #require(
      outline.headings.map(\.range) == [1...1, 5...6].map { range(of: $0, in: notebook) })
    #expect(
      outline.headings.map(\.ownedRange) == [2..<5, 7..<8].map { range(of: $0, in: notebook) })
    #expect(text(notebook, outline.headings[1].range) == "===\n===\n")
    #expect(text(notebook, outline.headings[1].ownedRange) == "body\n")
  }

  // req~heading-outline.owned-range~1
  @Test(
    arguments: [
      ("[ref]: /url\nTitle", 1),
      ("[a]: /u\n[b]: /v\nTitle", 2),
      ("[a]: /u\n[a]: /v\nTitle", 2),
      ("[a]: /u\n\"title\"\nTitle", 2),
      ("[a]: /u \"title\"\nTitle", 1),
      ("[a]: /u (title)\nTitle", 1),
      ("[a]: /u\n\"multi\nline title\"\nTitle", 3),
      ("[a]: /u\n(title\nspanning)\nTitle", 3),
      ("[a]: /u\n\"unclosed\nTitle", 1),
      ("[a]: /u\n(unclosed\nTitle", 1),
      ("[a]: /u \"t\" junk\nTitle", 0),
      ("[a]: /u \"t\"x\nTitle", 0),
      ("[a]: /u\n\"t\" x\nTitle", 1),
      ("[a]: /u ((not a title\nTitle", 0),
      ("[a]: /u\n(a(b))\nTitle", 1),
      ("[a]: /u\n(a\\(b\\))\nTitle", 2),
      ("[a]: /u \"esc\\\"aped\"\nTitle", 1),
      ("[a]: /u\n'it\\'s'\nTitle", 2),
      ("[a]: /u\n\"t\\\\\"\nTitle", 2),
      ("[a]: /u\n'x\"y'\nTitle", 2),
      ("[a]: /u\n\"\"\nTitle", 2),
      ("[a]: /u\n\t\"title\"\nTitle", 2),
      ("[a]:\n/u\nTitle", 2),
      ("[a\nb]: /u\nTitle", 2),
      ("[a]:/u\nTitle", 1),
      ("[a]: /u\t\nTitle", 1),
      ("[a]: \\\nTitle", 1),
      ("[a]: <dest with spaces>\nTitle", 1),
      ("[a]: <x\\>y>\nTitle", 1),
      ("[a]: <>\nTitle", 1),
      ("[a]: <unclosed\nTitle", 0),
      ("[a]: /u(nested(paren))\nTitle", 1),
      ("[\\]]: /u\nTitle", 1),
      ("[ ]: /u\nTitle", 0),
      ("[\(String(repeating: "x", count: 1_000))]: /u\nTitle", 1),
      ("[\(String(repeating: "x", count: 1_001))]: /u\nTitle", 0),
      ("  [a]: /u\n   Title", 1),
      ("[a]: /u\r\nTitle", 1),
      ("[a]: /u\r\"t\"\rTitle", 2),
      ("[foo]: /url \"title\" \n[bar]: /u\nTitle", 2),
      ("[a]: /u\n[b]: /v 'single'\n[c]: /w (paren)\nTitle", 3),
      ("[a]: /u\n\"title with [brackets]\"\nTitle", 2),
      ("^[attr]: rest\nTitle", 1),
      ("[2026-10-20 10:00] start\nlog line", 0),
      ("[link](   /uri\n  \"title\"  )", 0),
      ("[a]: /u\n[b]:\nTitle", 3),
      ("^[x]:\nTitle", 2),
    ] as [(String, Int)])
  func aSetextHeadingStartsAfterTheLinkReferenceDefinitionsCmarkStrips(
    paragraph: String, definitions: Int
  ) {
    // The counts are what cmark's own parse gives for each paragraph.
    let notebook = "# Top\n\n" + paragraph + "\n===\nbody\n"
    var lines = 0
    paragraph.enumerateLines { _, _ in lines += 1 }
    let setext = definitions < lines ? [(3 + definitions)...(3 + lines)] : []
    #expect(
      Outline(parsing: notebook).headings.map(\.range)
        == ([1...1] + setext).map { range(of: $0, in: notebook) })
  }

  // req~heading-outline.fenced-code~1
  @Test func hashLinesInFencedCodeAreNotHeadings() throws {
    let notebook = "# Setup\n```sh\n# install deps\n```\n## Run\n"
    let outline = Outline(parsing: notebook)
    try #require(
      outline.headings.map(\.range) == [1...1, 5...5].map { range(of: $0, in: notebook) })
    #expect(outline.headings[0].ownedRange == range(of: 2..<6, in: notebook))
  }

  @Test func headingsInsideQuotesAndListsAreNotOutlineHeadings() {
    let notebook = "# A\n> # quoted\n- # listed\n## B\n"
    let outline = Outline(parsing: notebook)
    #expect(outline.headings.map(\.range) == [1...1, 4...4].map { range(of: $0, in: notebook) })
  }

  // req~heading-folding.fold~1
  @Test func innermostHeadingHoldsTheOffset() {
    let notebook = introTasksNotes
    let outline = Outline(parsing: notebook)
    let string = notebook as NSString
    let fix = range(of: 3...3, in: notebook)
    #expect(outline.innermostHeading(at: string.range(of: "Fix").location)?.range == fix)
    #expect(outline.innermostHeading(at: string.range(of: "leaks").location)?.range == fix)
    #expect(
      outline.innermostHeading(at: string.range(of: "# Tasks").location)?.range
        == range(of: 2...2, in: notebook))
    #expect(outline.innermostHeading(at: string.length)?.range == range(of: 5...5, in: notebook))
    #expect(outline.clampedOffset(string.length) == string.length - 1)
  }

  // req~heading-folding.disabled-without-heading~1
  @Test func noHeadingHoldsTheTextBeforeTheFirstHeading() {
    let outline = Outline(parsing: introTasksNotes)
    #expect(outline.innermostHeading(at: 0) == nil)
  }

  // req~heading-folding.fold-all~1
  @Test func topLevelHeadingsAreTheOnesNoHeadingOwns() {
    let outline = Outline(parsing: introTasksNotes)
    #expect(
      outline.topLevelHeadings.map(\.range)
        == [2...2, 5...5].map { range(of: $0, in: introTasksNotes) })
  }

  // req~heading-folding.fold-all~1
  @Test func topLevelHeadingsDependOnOwnershipNotOnLevel() {
    let notebook = "## Unowned\nText.\n# Top\n### Deeper\n## Still under top\nBody.\n# Next\n"
    let outline = Outline(parsing: notebook)
    #expect(
      outline.topLevelHeadings.map(\.range)
        == [1...1, 3...3, 7...7].map { range(of: $0, in: notebook) })
  }

  // req~heading-folding.fold-all~1
  @Test func topLevelHeadingsTakeOnePassOverTheHeadings() {
    let outline = Outline(parsing: String(repeating: "#\n", count: 20_000))
    let clock = ContinuousClock()
    var topLevel: [OutlineHeading] = []
    let elapsed = clock.measure { topLevel = outline.topLevelHeadings }
    #expect(topLevel.count == 20_000)
    #expect(elapsed < .seconds(1))
  }
}
