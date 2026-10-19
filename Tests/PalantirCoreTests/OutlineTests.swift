import Foundation
import PalantirCore
import Testing

struct OutlineTests {
  private let introTasksNotes = "Intro.\n# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\nDone."

  private func text(_ string: String, _ range: NSRange) -> String {
    (string as NSString).substring(with: range)
  }

  // [utest->req~heading-outline.owned-range~1]
  @Test func headingsOwnTheLinesUpToTheNextPeerOrHigherHeading() throws {
    let notebook = "# Tasks\n## Fix the reaper\nIt leaks.\n## Ship bilbo\n# Notes\nDone.\n"
    let outline = Outline(parsing: notebook)
    try #require(outline.headings.map(\.lines.lowerBound) == [1, 2, 4, 5])
    #expect(outline.headings.map(\.ownedLines) == [2..<5, 3..<4, 5..<5, 6..<7])
    #expect(
      text(notebook, outline.headings[0].ownedRange)
        == "## Fix the reaper\nIt leaks.\n## Ship bilbo\n")
    #expect(text(notebook, outline.headings[1].ownedRange) == "It leaks.\n")
    #expect(outline.headings[2].ownedRange.length == 0)
    #expect(text(notebook, outline.headings[3].ownedRange) == "Done.\n")
  }

  // [utest->req~heading-outline.owned-range~1]
  @Test func ownedRangesAreUTF16OffsetsOfTheText() throws {
    let notebook = "Intro 🎉 é.\r\n# Tâsks 🎉\r\nNaïve 👩‍👩‍👧 text.\n\nSetext\n======\nbody\n# Last"
    let outline = Outline(parsing: notebook)
    try #require(outline.headings.map(\.level) == [1, 1, 1])
    #expect(text(notebook, outline.headings[0].range) == "# Tâsks 🎉\r\n")
    #expect(text(notebook, outline.headings[0].ownedRange) == "Naïve 👩‍👩‍👧 text.\n\n")
    #expect(text(notebook, outline.headings[1].range) == "Setext\n======\n")
    #expect(text(notebook, outline.headings[1].ownedRange) == "body\n")
    #expect(text(notebook, outline.headings[2].range) == "# Last")
    #expect(
      outline.headings[2].ownedRange == NSRange(location: (notebook as NSString).length, length: 0))
  }

  // [utest->req~heading-outline.owned-range~1]
  @Test func classicMacLineEndingsBreakLines() throws {
    let notebook = "# Tasks\r## Fix the reaper\rIt leaks.\r# Notes\rDone.\r"
    let outline = Outline(parsing: notebook)
    try #require(outline.headings.map(\.lines.lowerBound) == [1, 2, 4])
    #expect(outline.headings.map(\.ownedLines) == [2..<4, 3..<4, 5..<6])
    #expect(text(notebook, outline.headings[0].ownedRange) == "## Fix the reaper\rIt leaks.\r")
    #expect(text(notebook, outline.headings[1].ownedRange) == "It leaks.\r")
    #expect(text(notebook, outline.headings[2].ownedRange) == "Done.\r")
  }

  // [utest->req~heading-outline.owned-range~1]
  @Test func setextHeadingsEndAtTheirUnderline() {
    let notebook = "Setext\n------\n# Next\nTwo line\nsetext\n===\n\nbody\n"
    let outline = Outline(parsing: notebook)
    #expect(outline.headings.map(\.lines) == [1...2, 3...3, 4...6])
    #expect(outline.headings.map(\.ownedLines) == [3..<3, 4..<4, 7..<9])
  }

  // [utest->req~heading-outline.owned-range~1]
  @Test func setextHeadingWithAStrikethroughSpanningLines() throws {
    let notebook = "~~Two line\nsetext~~\n===\nbody\n# Next\n"
    let outline = Outline(parsing: notebook)
    try #require(outline.headings.map(\.lines) == [1...3, 5...5])
    #expect(outline.headings.map(\.ownedLines) == [4..<5, 6..<6])
    #expect(text(notebook, outline.headings[0].ownedRange) == "body\n")
  }

  // [utest->req~heading-outline.owned-range~1]
  @Test func setextHeadingWithALinkSpanningLines() throws {
    let notebook = "[link](   /uri\n  \"title\"  )\n===\nbody\n# Next\n"
    let outline = Outline(parsing: notebook)
    try #require(outline.headings.map(\.lines) == [1...3, 5...5])
    #expect(outline.headings.map(\.ownedLines) == [4..<5, 6..<6])
    #expect(text(notebook, outline.headings[0].range) == "[link](   /uri\n  \"title\"  )\n===\n")
    #expect(text(notebook, outline.headings[0].ownedRange) == "body\n")
  }

  // [utest->req~heading-outline.fenced-code~1]
  @Test func hashLinesInFencedCodeAreNotHeadings() throws {
    let notebook = "# Setup\n```sh\n# install deps\n```\n## Run\n"
    let outline = Outline(parsing: notebook)
    try #require(outline.headings.map(\.lines.lowerBound) == [1, 5])
    #expect(outline.headings[0].ownedLines == 2..<6)
  }

  @Test func headingsInsideQuotesAndListsAreNotOutlineHeadings() {
    let outline = Outline(parsing: "# A\n> # quoted\n- # listed\n## B\n")
    #expect(outline.headings.map(\.lines.lowerBound) == [1, 4])
  }

  // [utest->req~heading-folding.fold~1]
  @Test func innermostHeadingHoldsTheOffset() {
    let notebook = introTasksNotes
    let outline = Outline(parsing: notebook)
    let string = notebook as NSString
    #expect(outline.innermostHeading(at: string.range(of: "Fix").location)?.lines.lowerBound == 3)
    #expect(outline.innermostHeading(at: string.range(of: "leaks").location)?.lines.lowerBound == 3)
    #expect(
      outline.innermostHeading(at: string.range(of: "# Tasks").location)?.lines.lowerBound == 2)
    #expect(outline.innermostHeading(at: string.length)?.lines.lowerBound == 5)
    #expect(outline.clampedOffset(string.length) == string.length - 1)
  }

  // [utest->req~heading-folding.disabled-without-heading~1]
  @Test func noHeadingHoldsTheTextBeforeTheFirstHeading() {
    let outline = Outline(parsing: introTasksNotes)
    #expect(outline.innermostHeading(at: 0) == nil)
  }

  // [utest->req~heading-folding.fold-all~1]
  @Test func topLevelHeadingsAreTheOnesNoHeadingOwns() {
    let outline = Outline(parsing: introTasksNotes)
    #expect(outline.topLevelHeadings.map(\.lines.lowerBound) == [2, 5])
  }

  // [utest->req~heading-folding.fold-all~1]
  @Test func topLevelHeadingsDependOnOwnershipNotOnLevel() {
    let outline = Outline(
      parsing: "## Unowned\nText.\n# Top\n### Deeper\n## Still under top\nBody.\n# Next\n")
    #expect(outline.topLevelHeadings.map(\.lines.lowerBound) == [1, 3, 7])
  }

  // [utest->req~heading-folding.fold-all~1]
  @Test func topLevelHeadingsTakeOnePassOverTheHeadings() {
    let outline = Outline(parsing: String(repeating: "#\n", count: 20_000))
    let clock = ContinuousClock()
    var topLevel: [OutlineHeading] = []
    let elapsed = clock.measure { topLevel = outline.topLevelHeadings }
    #expect(topLevel.count == 20_000)
    #expect(elapsed < .seconds(1))
  }
}
