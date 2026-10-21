import Foundation
import Testing

@testable import PalantirNotebook

@Suite(.layer(.unit))
struct FoldsTests {
  private let tasksAndNotes = "# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\n"
  private let introTasksNotes = "Intro.\n# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\nDone."

  private func unfolded(_ text: String) -> Folds {
    Folds(outline: Outline(parsing: text))
  }

  // [utest->req~heading-folding.fold~1]
  @Test func foldHeadingFoldsTheInnermostHeadingAtTheSelection() throws {
    var folds = unfolded(tasksAndNotes)
    #expect(folds.headingStarts.isEmpty)
    let heading = try #require(folds.innermostHeading(at: 28))
    #expect(heading.range.location == 8)
    folds.fold(heading)
    #expect(folds.headingStarts == [8])
    #expect(folds.foldedHeadings == [heading])
    #expect(folds.hiddenRanges == [NSRange(location: 26, length: 10)])
  }

  // [utest->req~heading-folding.fold~1]
  @Test func foldedTextIsTheOwnedTextOfEachFoldedHeadingInDocumentOrder() throws {
    var folds = unfolded(introTasksNotes)
    for offset in [52, 36, 10] {
      let heading = try #require(folds.innermostHeading(at: offset))
      folds.fold(heading)
    }
    #expect(folds.foldedHeadings.map(\.range.location) == [7, 15, 43])
    #expect(
      folds.hiddenRanges == [
        NSRange(location: 15, length: 28), NSRange(location: 33, length: 10),
        NSRange(location: 51, length: 5),
      ])
  }

  // [utest->req~heading-folding.fold~1]
  @Test func aHeadingThatOwnsNothingFoldsAndHidesNothing() throws {
    var folds = unfolded("# Tasks\n## Ship bilbo\n# Notes\n")
    let heading = try #require(folds.innermostHeading(at: 9))
    folds.fold(heading)
    #expect(folds.headingStarts == [8])
    #expect(folds.hiddenRanges.isEmpty)
  }

  // [utest->req~heading-folding.unfold~1]
  @Test func unfoldHeadingShowsExactlyTheTextItsFoldHid() throws {
    let before = unfolded(tasksAndNotes)
    var folds = before
    let heading = try #require(folds.innermostHeading(at: 10))
    folds.fold(heading)
    try #require(folds.hiddenRanges == [NSRange(location: 26, length: 10)])
    folds.unfold(heading)
    #expect(folds == before)
    #expect(folds.hiddenRanges.isEmpty)
  }

  // [utest->req~heading-folding.unfold~1]
  @Test func unfoldingAFoldedParentKeepsItsFoldedChildFolded() throws {
    var folds = unfolded(tasksAndNotes)
    let child = try #require(folds.innermostHeading(at: 10))
    let parent = try #require(folds.innermostHeading(at: 1))
    folds.fold(child)
    folds.fold(parent)
    folds.unfold(parent)
    #expect(folds.headingStarts == [8])
    #expect(folds.hiddenRanges == [child.ownedRange])
  }

  // [utest->req~heading-folding.fold-all~1]
  @Test func foldAllFoldsEveryHeadingNoOtherHeadingOwns() {
    var folds = unfolded(introTasksNotes)
    folds.foldAll()
    #expect(folds.headingStarts == [7, 43])
    #expect(
      folds.hiddenRanges == [NSRange(location: 15, length: 28), NSRange(location: 51, length: 5)])
  }

  // [utest->req~heading-folding.fold-all~1]
  @Test func foldAllKeepsAFoldedChildFolded() throws {
    var folds = unfolded(introTasksNotes)
    let child = try #require(folds.innermostHeading(at: 36))
    folds.fold(child)
    folds.foldAll()
    #expect(folds.headingStarts == [7, 15, 43])
    let tasks = try #require(folds.innermostHeading(at: 10))
    folds.unfold(tasks)
    #expect(folds.hiddenRanges == [child.ownedRange, NSRange(location: 51, length: 5)])
  }

  // [utest->req~heading-folding.fold-all~1]
  @Test func foldAllFoldsAnUnownedHeadingOfAnyLevel() {
    var folds = unfolded(
      "## Unowned\nText.\n# Top\n### Deeper\n## Still under top\nBody.\n# Next\n")
    folds.foldAll()
    #expect(folds.headingStarts == [0, 17, 59])
  }

  // [utest->req~heading-folding.unfold-all~1]
  @Test func unfoldAllUnfoldsEveryHeading() throws {
    let before = unfolded(introTasksNotes)
    var folds = before
    for heading in folds.outline.headings { folds.fold(heading) }
    try #require(folds.headingStarts == [7, 15, 43])
    folds.unfoldAll()
    #expect(folds == before)
    #expect(folds.hiddenRanges.isEmpty)
  }

  // [utest->req~heading-folding.disabled-without-heading~1]
  @Test func foldHeadingAndUnfoldHeadingFindNoHeadingBeforeTheFirstOne() {
    let folds = unfolded("Intro.\n# Tasks\n")
    #expect(folds.innermostHeading(at: 2) == nil)
    #expect(folds.innermostHeading(at: 9)?.range.location == 7)
  }

  @Test func foldAllAndUnfoldAllNeedAHeading() {
    #expect(!unfolded("Intro.\nNo heading here.\n").hasHeadings)
    #expect(unfolded("Intro.\n# Tasks\n").hasHeadings)
  }

  @Test func aCaretInFoldedTextGoesToTheOutermostFoldedHeading() throws {
    var folds = unfolded(tasksAndNotes)
    var previous = folds
    let heading = try #require(folds.innermostHeading(at: 28))
    folds.fold(heading)
    #expect(folds.caret(for: NSRange(location: 28, length: 0), since: previous) == 8)
    previous = folds
    folds.foldAll()
    #expect(folds.caret(for: NSRange(location: 28, length: 0), since: previous) == 0)
    #expect(folds.caret(for: NSRange(location: 37, length: 0), since: previous) == nil)
  }

  @Test func aCaretInAnEarlierFoldGoesToItsHeading() throws {
    var folds = unfolded(tasksAndNotes)
    let heading = try #require(folds.innermostHeading(at: 10))
    folds.fold(heading)
    let previous = folds
    #expect(folds.caret(for: NSRange(location: 28, length: 0), since: previous) == 8)
  }

  @Test func aSelectionReachingIntoNewlyFoldedTextShrinksToItsHeading() throws {
    var folds = unfolded(tasksAndNotes)
    let previous = folds
    let heading = try #require(folds.innermostHeading(at: 11))
    folds.fold(heading)
    #expect(folds.caret(for: NSRange(location: 11, length: 20), since: previous) == 8)
    #expect(folds.caret(for: NSRange(location: 11, length: 15), since: previous) == nil)
  }

  @Test func aSelectionReachingIntoAnEarlierFoldStays() throws {
    let text = "# Tasks\nIt leaks.\n# Notes\nDone.\n"
    var folds = unfolded(text)
    let tasks = try #require(folds.innermostHeading(at: 1))
    let notes = try #require(folds.innermostHeading(at: 19))
    folds.fold(tasks)
    folds.fold(notes)
    let previous = folds
    folds.unfold(tasks)
    let all = NSRange(location: 0, length: (text as NSString).length)
    #expect(folds.caret(for: all, since: previous) == nil)
    #expect(folds.caret(for: all, since: unfolded(text)) == notes.range.location)
  }

  @Test func aCaretAtTheEndOfTheTextIsOnItsLastCharacter() throws {
    let text = "# Tasks\nIt leaks.\n# Notes\nDone."
    var folds = unfolded(text)
    let previous = folds
    let end = (text as NSString).length
    let notes = try #require(folds.innermostHeading(at: end))
    folds.fold(notes)
    #expect(notes.range.location == 18)
    #expect(folds.caret(for: NSRange(location: end, length: 0), since: previous) == 18)
  }

  @Test func theOutermostFoldedHeadingHidesAnOffset() throws {
    var folds = unfolded(tasksAndNotes)
    let tasks = try #require(folds.innermostHeading(at: 1))
    let fix = try #require(folds.innermostHeading(at: 10))
    folds.fold(fix)
    folds.fold(tasks)
    #expect(folds.heading(hiding: 28) == tasks)
    #expect(folds.heading(hiding: 10) == tasks)
    #expect(folds.heading(hiding: 37) == nil)
    folds.unfold(tasks)
    #expect(folds.heading(hiding: 28) == fix)
    #expect(folds.heading(hiding: 10) == nil)
  }
}
