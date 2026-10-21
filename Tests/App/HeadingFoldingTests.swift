import AppKit
import PalantirNotebook
import PalantirNotebookInspector
import Testing

@testable import PalantirNotebookUI

@MainActor
struct HeadingFoldingTests {
  private let tasksAndNotes = "# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\n"

  // [utest->req~heading-folding.fold~1]
  @Test func foldHeadingHidesTheTextItOwnsAndMarksIt() throws {
    let controller = try openNotebook(tasksAndNotes)
    let view = controller.textView
    let heading = try view.heading(startingWith: "## Fix the reaper")
    #expect(try choose("Fold Heading", at: heading.range.location + 1, in: controller))
    #expect(try view.visibleParagraphs() == ["# Tasks", "## Fix the reaper", "# Notes"])
    #expect(try view.markerIsShown(heading: heading))
  }

  // [utest->req~heading-folding.fold~1]
  @Test func markerIsShownAfterTheLastLineOfAWrappingHeading() throws {
    let title = "## " + String(repeating: "Fix the reaper again and again ", count: 12)
    let controller = try openNotebook("# Tasks\n\(title)\nIt leaks.\n# Notes\n")
    let view = controller.textView
    let heading = try view.heading(startingWith: title)
    #expect(try choose("Fold Heading", at: heading.range.location + 1, in: controller))
    #expect(try view.markerIsShown(heading: heading))
  }

  // [utest->req~heading-folding.fold~1]
  @Test(arguments: 100...130)
  func markerFitsWhenTheHeadingEndsAtTheRightEdge(length: Int) throws {
    let controller = try openNotebook(
      "## " + String(repeating: "x", count: length) + "\nIt leaks.\n")
    let view = controller.textView
    #expect(try choose("Fold Heading", at: 1, in: controller))
    #expect(try view.markerIsShown(heading: try view.heading(startingWith: "## ")))
  }

  // [utest->req~heading-folding.fold~1]
  @Test(arguments: [
    "# Notes", "# " + String(repeating: "Fix the reaper again and again ", count: 12),
  ])
  func markerSitsOnTheLastHeadingsTextNotOnTheEmptyLineAfterIt(title: String) throws {
    let controller = try openNotebook("# Tasks\nIt leaks.\n\(title)\n")
    let view = controller.textView
    let last = try view.heading(startingWith: title)
    #expect(try choose("Fold Heading", at: last.range.location + 1, in: controller))
    #expect(try view.markerIsShown(heading: last))
  }

  // [utest->req~heading-folding.fold~1]
  @Test(arguments: ["=====", "-----"])
  func markerSitsAfterASetextHeadingsUnderline(underline: String) throws {
    let controller = try openNotebook("Tasks\n\(underline)\nIt leaks.\n# Notes\n")
    let view = controller.textView
    let tasks = try view.heading(startingWith: "Tasks")
    #expect(try choose("Fold Heading", at: 1, in: controller))
    #expect(try view.visibleParagraphs() == ["Tasks", underline, "# Notes"])
    #expect(try view.markerIsShown(heading: tasks))
  }

  // [utest->req~heading-folding.fold~1]
  @Test func foldHeadingWithTheCaretAtTheEndOfTheText() throws {
    let text = "# Tasks\nIt leaks.\n# Notes\nDone."
    let controller = try openNotebook(text)
    let view = controller.textView
    #expect(try choose("Fold Heading", at: (text as NSString).length, in: controller))
    #expect(view.foldedHeadingStarts == [18])
    #expect(view.selectedRange() == NSRange(location: 18, length: 0))
    #expect(try view.visibleParagraphs() == ["# Tasks", "It leaks.", "# Notes"])
  }

  // [utest->req~heading-folding.fold~1]
  @Test func headingThatOwnsNothingGetsAMarkerAndLosesIt() throws {
    let controller = try openNotebook("# Tasks\n## Ship bilbo\n# Notes\n")
    let view = controller.textView
    let heading = try view.heading(startingWith: "## Ship bilbo")
    #expect(try choose("Fold Heading", at: heading.range.location + 1, in: controller))
    #expect(try view.visibleParagraphs() == ["# Tasks", "## Ship bilbo", "# Notes"])
    #expect(try view.markerIsShown(heading: heading))
    #expect(try choose("Unfold Heading", in: controller))
    #expect(view.foldedMarkers.isEmpty && view.markerViews().isEmpty)
  }

  @Test func foldingMovesTheCaretToTheOutermostFoldedHeading() throws {
    let controller = try openNotebook(tasksAndNotes)
    let view = controller.textView
    #expect(try choose("Fold Heading", at: 28, in: controller))
    #expect(view.selectedRange() == NSRange(location: 8, length: 0))
    #expect(try choose("Fold All", at: 28, in: controller))
    #expect(view.selectedRange() == NSRange(location: 0, length: 0))
  }

  @Test func aSelectionReachingIntoFoldedTextShrinksToTheHeading() throws {
    let controller = try openNotebook(tasksAndNotes)
    let view = controller.textView
    view.setSelectedRange(NSRange(location: 11, length: 20))
    #expect(try choose("Fold Heading", in: controller))
    #expect(view.foldedHeadingStarts == [8])
    #expect(view.selectedRange() == NSRange(location: 8, length: 0))
  }

  @Test func unfoldingKeepsASelectionThatReachesIntoAnotherFold() throws {
    let text = "# Tasks\nIt leaks.\n# Notes\nDone.\n"
    let controller = try openNotebook(text)
    let view = controller.textView
    let notes = try view.heading(startingWith: "# Notes")
    try #require(try choose("Fold Heading", at: 1, in: controller))
    try #require(try choose("Fold Heading", at: notes.range.location + 1, in: controller))
    view.selectAll(nil)
    let all = NSRange(location: 0, length: (text as NSString).length)
    try #require(view.selectedRange() == all)
    #expect(try choose("Unfold Heading", in: controller))
    #expect(view.foldedHeadingStarts == [notes.range.location])
    #expect(try view.visibleText() == "# Tasks\nIt leaks.\n# Notes\n")
    #expect(view.selectedRange() == all)
  }

  // [utest->req~heading-folding.unfold~1]
  @Test func unfoldHeadingShowsTheSameTextAndClearsTheMarker() throws {
    let controller = try openNotebook(tasksAndNotes)
    let view = controller.textView
    let before = try view.visibleParagraphs()
    let heading = try view.heading(startingWith: "## Fix the reaper")
    try #require(try choose("Fold Heading", at: heading.range.location + 1, in: controller))
    #expect(view.markerViews().count == 1)
    #expect(try choose("Unfold Heading", in: controller))
    #expect(try view.visibleParagraphs() == before)
    #expect(view.foldedMarkers[8] == nil)
    #expect(view.markerViews().isEmpty)
  }

  // [utest->req~heading-folding.unfold~1]
  @Test func unfoldingAParentKeepsAFoldedChildFolded() throws {
    let controller = try openNotebook(
      "# Tasks\n## Fix the reaper\nIt leaks.\n## Ship bilbo\n# Notes\n")
    let view = controller.textView
    try #require(try choose("Fold Heading", at: 10, in: controller))
    try #require(try choose("Fold Heading", at: 1, in: controller))
    #expect(try choose("Unfold Heading", in: controller))
    #expect(
      try view.visibleParagraphs() == ["# Tasks", "## Fix the reaper", "## Ship bilbo", "# Notes"])
    #expect(view.foldedHeadingStarts == [8])
    #expect(view.foldedMarkers.keys.sorted() == [8])
    #expect(view.markerViews().count == 1)
    #expect(try view.markerIsShown(heading: try view.heading(startingWith: "## Fix the reaper")))
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: [(before: 60, owned: 3, after: 200), (60, 40, 5), (600, 20, 600)])
  func foldingLeavesNoGapAndKeepsTheHeadingInPlace(before: Int, owned: Int, after: Int) throws {
    let text = longNotebook(before: before, owned: owned, after: after)
    let controller = try openNotebook(text)
    let view = controller.textView
    var switches = 0
    let token = NotificationCenter.default.addObserver(
      forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: view, queue: nil
    ) { _ in MainActor.assumeIsolated { switches += 1 } }
    defer { NotificationCenter.default.removeObserver(token) }
    let heading = try view.heading(startingWith: "## Fix the reaper")
    let notes = try view.heading(startingWith: "# Notes")
    let total = text.components(separatedBy: "\n").count - 1
    try view.scrollToTop(offset: heading.range.location)
    view.setSelectedRange(NSRange(location: heading.range.location + 1, length: 0))
    try #require(try view.screenY(offset: heading.range.location) == 0)

    #expect(try choose("Fold Heading", in: controller))
    try expectInPlace(view, heading.range.location)
    #expect(
      try view.fragmentFrame(at: notes.range.location).minY
        == view.fragmentFrame(at: heading.range.location).maxY)
    #expect(try view.visibleParagraphs().count == total - owned)

    #expect(try choose("Unfold Heading", in: controller))
    try expectInPlace(view, heading.range.location)
    #expect(try view.visibleParagraphs().count == total)
    #expect(switches == 0)
    #expect(view.textLayoutManager != nil)
  }

  private func section(_ number: Int, in view: NotebookTextView) throws -> OutlineHeading {
    try view.heading(startingWith: "# Section \(number)\n")
  }

  /// Expects the paragraph at `line` at screen y `y`, and the view to fit the laid-out text.
  private func expectInPlace(_ view: NotebookTextView, _ line: Int, at y: CGFloat = 0) throws {
    let screen = try view.screenY(offset: line)
    let breaks = try view.layoutBreaks()
    let fits = try view.isNoTallerThanTextPlusOneWindow()
    let textHeight = try view.textHeight()
    #expect(screen == y)
    #expect(breaks.isEmpty)
    #expect(fits)
    #expect(view.frame.height >= textHeight)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test func foldAllKeepsTheTopLineInPlace() throws {
    let controller = try openNotebook(sectionsNotebook())
    let view = controller.textView
    let five = try section(5, in: view)
    try view.scrollToTop(offset: five.range.location)
    #expect(try choose("Fold All", in: controller))
    try expectInPlace(view, five.range.location)
    #expect(try view.visibleParagraphs().count == 11)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test func unfoldAllKeepsTheTopLineInPlace() throws {
    let text = sectionsNotebook()
    let controller = try openNotebook(text)
    let view = controller.textView
    for number in 1...4 {
      try #require(
        try choose(
          "Fold Heading", at: try section(number, in: view).range.location, in: controller))
    }
    let five = try section(5, in: view)
    try view.scrollToTop(offset: five.range.location)
    try #require(try view.screenY(offset: five.range.location) == 0)
    #expect(try choose("Unfold All", in: controller))
    try expectInPlace(view, five.range.location)
    #expect(try view.visibleText() == text)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: [0, 5] as [CGFloat])
  func foldingAHeadingAboveTheWindowKeepsTheTopLineInPlace(partly: CGFloat) throws {
    let controller = try openNotebook(sectionsNotebook())
    let view = controller.textView
    let five = try section(5, in: view)
    try view.scroll(toY: try view.fragmentFrame(at: five.range.location).minY + partly)
    try #require(try view.screenY(offset: five.range.location) == -partly)
    #expect(
      try choose("Fold Heading", at: try section(1, in: view).range.location, in: controller))
    try expectInPlace(view, five.range.location, at: -partly)
    #expect(try choose("Unfold Heading", in: controller))
    try expectInPlace(view, five.range.location, at: -partly)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test func foldingAfterAScrollWithoutLayoutKeepsTheTopLineInPlace() throws {
    let controller = try openNotebook(sectionsNotebook())
    let view = controller.textView
    let five = try section(5, in: view)
    view.setSelectedRange(NSRange(location: try section(7, in: view).range.location, length: 0))
    try view.scrollToTop(offset: try section(9, in: view).range.location)
    try view.scroll(toY: try view.fragmentFrame(at: five.range.location).minY, layingOut: false)
    try #require(try view.screenY(offset: five.range.location) == 0)
    #expect(try choose("Fold Heading", in: controller))
    try expectInPlace(view, five.range.location)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: [0, 5] as [CGFloat])
  func foldingTheTopLinesHeadingPutsItAtTheTop(partly: CGFloat) throws {
    let controller = try openNotebook(sectionsNotebook())
    let view = controller.textView
    let five = try section(5, in: view)
    let body = (view.string as NSString).range(of: "Body 5.10\n").location
    try view.scroll(toY: try view.fragmentFrame(at: body).minY + partly)
    try #require(try view.screenY(offset: body) == -partly)
    #expect(try choose("Fold Heading", at: five.range.location + 1, in: controller))
    try expectInPlace(view, five.range.location)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: WidthChange.all)
  func aCommandAfterTheWindowChangesWidthKeepsTheTopLineInPlace(change: WidthChange) throws {
    if change.command == "inside a child" { return try foldInsideAChild(width: change.width) }
    let text = wrappingSectionsNotebook() as NSString
    func section(_ number: Int) -> Int { text.range(of: "# Section \(number)\n").location }
    func resized() throws -> NotebookWindowController {
      let controller = try openNotebook(text as String)
      let folds =
        change.command == "Unfold All" ? [1, 2] : change.command == "Unfold Heading" ? [2] : []
      for number in folds {
        try #require(try choose("Fold Heading", at: section(number), in: controller))
      }
      try controller.textView.scrollToTop(offset: section(8))
      try #require(controller.window).setContentSize(NSSize(width: change.width, height: 600))
      return controller
    }
    func shifted(_ view: NSTextView) -> CGFloat {
      min(max(0, view.visibleRect.minY + change.shift), view.frame.height - view.visibleRect.height)
    }
    // The twin lays out its viewport, as display would: its top line is the one on screen.
    let twin = try resized()
    try twin.textView.scroll(toY: shifted(twin.textView))
    let top = try twin.textView.drawnTopLine()
    let owner = try #require(twin.textView.folds.innermostHeading(at: top.offset))
    try #require(owner.range.location > section(2))

    let controller = try resized()
    let view = controller.textView
    // A scroll without layout leaves the window over text the width change left unlaid. At 1400
    // points the last shift ends where the viewport draws its first line below the top edge.
    try view.scroll(toY: shifted(view), layingOut: false)
    switch change.command {
    case "above":
      #expect(try choose("Fold Heading", at: section(2) + 1, in: controller))
      try expectAfterACommand(view, text as String, folded: [section(2)], line: top)
    case "top line's heading":
      #expect(try choose("Fold Heading", at: owner.range.location + 1, in: controller))
      try expectAfterACommand(
        view, text as String, folded: [owner.range.location],
        line: (owner.range.location, max(0, top.screenY)), marked: owner)
    case "Fold All":
      #expect(try choose("Fold All", in: controller))
      try expectAfterACommand(
        view, text as String, folded: Set((1...10).map(section)),
        line: (owner.range.location, max(0, top.screenY)), marked: owner, clamped: true)
    case "Unfold Heading":
      #expect(try choose("Unfold Heading", at: section(2) + 1, in: controller))
      try expectAfterACommand(view, text as String, folded: [], line: top)
    default:
      #expect(try choose("Unfold All", in: controller))
      try expectAfterACommand(view, text as String, folded: [], line: top)
    }
  }

  private func foldInsideAChild(width: CGFloat) throws {
    let text = wrappingPartsNotebook()
    let controller = try openNotebook(text)
    let view = controller.textView
    let body = (text as NSString).range(of: "Body 6.2.3 ").location
    try view.scrollToTop(offset: body)
    try #require(controller.window).setContentSize(NSSize(width: width, height: 600))
    try view.scrollDrawnTopLine(to: body)
    let parent = try view.heading(startingWith: "# Part 6\n")
    let child = try #require(view.folds.innermostHeading(at: body))
    var top = try view.drawnTopLine()
    // The line setFolded anchors on lies in the text the child hides.
    try #require(
      view.folds.innermostHeading(at: top.offset) == child
        && top.offset >= NSMaxRange(child.range))

    #expect(try choose("Fold Heading", at: child.range.location + 1, in: controller))
    try expectAfterACommand(
      view, text, folded: [child.range.location],
      line: (child.range.location, max(0, top.screenY)), marked: child)
    top = try view.drawnTopLine()
    #expect(try choose("Fold Heading", at: parent.range.location + 1, in: controller))
    try expectAfterACommand(
      view, text, folded: [child.range.location, parent.range.location],
      line: (parent.range.location, max(0, top.screenY)), marked: parent)
    top = try view.drawnTopLine()
    #expect(try choose("Unfold Heading", at: parent.range.location + 1, in: controller))
    try expectAfterACommand(view, text, folded: [child.range.location], line: top)
  }

  private func expectAfterACommand(
    _ view: NotebookTextView, _ text: String, folded: Set<Int>,
    line: (offset: Int, screenY: CGFloat), marked: OutlineHeading? = nil, clamped: Bool = false
  ) throws {
    #expect(view.foldedHeadingStarts == folded)
    #expect(try view.visibleText() == text.removing(view.folds.hiddenRanges))
    if folded.isEmpty { #expect(view.foldedMarkers.isEmpty && view.markerViews().isEmpty) }
    let y = try view.screenY(offset: line.offset)
    // Fold All can leave less text above the heading than its screen y.
    #expect(
      abs(y - line.screenY) < 0.01 || (clamped && view.visibleRect.minY == 0 && y < line.screenY))
    for heading in view.folds.foldedHeadings
    where view.folds.heading(hiding: heading.range.location) == nil {
      if view.visibleRect.intersects(try view.fragmentFrame(at: heading.range.location)) {
        #expect(try view.markerIsShown(heading: heading))
      }
    }
    if let marked { #expect(try view.markerIsShown(heading: marked)) }
    let textHeight = try view.textHeight()
    #expect(try view.layoutBreaks().isEmpty)
    #expect(try view.isNoTallerThanTextPlusOneWindow())
    #expect(view.frame.height >= textHeight)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: [600, 1400] as [CGFloat])
  func aFoldedNotebookStaysFoldedWhenTheWindowChangesWidth(width: CGFloat) throws {
    let text = wrappingSectionsNotebook() as NSString
    let controller = try openNotebook(text as String)
    let view = controller.textView
    let five = text.range(of: "# Section 5\n").location
    try #require(try choose("Fold Heading", at: five + 1, in: controller))
    let heading = try #require(view.folds.innermostHeading(at: five))
    try #require(controller.window).setContentSize(NSSize(width: width, height: 600))
    try view.scrollDrawnTopLine(to: five)

    let drawn = try view.drawnParagraphs()
    try #require(drawn.first?.offset == five)
    #expect(drawn.dropFirst().first?.offset == text.range(of: "# Section 6\n").location)
    #expect(!drawn.contains { view.folds.heading(hiding: $0.offset) != nil })
    #expect(zip(drawn, drawn.dropFirst()).allSatisfy { $1.frame.minY == $0.frame.maxY })
    #expect(try view.markerIsShown(heading: heading))
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: ResizeAfterAFold.all)
  func aResizeAfterFoldingTheLastSectionKeepsTheTopLineInPlace(resize: ResizeAfterAFold) throws {
    let text = (resize.wraps ? wrappingSectionsNotebook() : sectionsNotebook()) as NSString
    let controller = try openNotebook(text as String)
    let view = controller.textView
    let ten = text.range(of: "# Section 10\n").location
    let heading = try #require(view.folds.innermostHeading(at: ten))
    try view.scrollToTop(offset: ten)
    try #require(try choose("Fold Heading", at: ten + 1, in: controller))
    // Less text than a window is left below the top edge.
    try #require(try view.textHeight() < view.visibleRect.maxY)
    if resize.partly { try view.scroll(toY: view.visibleRect.minY - 5) }
    let before = try view.drawnTopLine()
    try #require(resize.partly == (before.screenY < -16))

    try #require(controller.window).setContentSize(
      NSSize(width: resize.width, height: resize.height))
    let layout = try #require(view.textLayoutManager)
    layout.textViewportLayoutController.layoutViewport()
    let after = try view.drawnTopLine()
    #expect(after.offset == before.offset)
    #expect(after.screenY == (resize.toTheEdge ? 0 : before.screenY))
    #expect(try view.markerIsShown(heading: heading))
    // The next command lays out the whole text: the line stays, and the view fits the text.
    layout.ensureLayout(for: layout.documentRange)
    layout.textViewportLayoutController.layoutViewport()
    try expectInPlace(view, after.offset, at: after.screenY)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: [600, 1400] as [CGFloat])
  func aFoldThatLeavesAWindowOfTextBelowSetsNoFloor(width: CGFloat) throws {
    let text = wrappingSectionsNotebook() as NSString
    let controller = try openNotebook(text as String)
    let view = controller.textView
    let scroll = try #require(view.enclosingScrollView)
    let five = text.range(of: "# Section 5\n").location
    try view.scrollToTop(offset: five)
    #expect(try choose("Fold Heading", at: five + 1, in: controller))
    try #require(try view.textHeight() > view.visibleRect.maxY)
    #expect(view.foldedTop == nil)
    #expect(view.minSize.height == scroll.contentSize.height)
    let clipY = scroll.contentView.bounds.minY
    try #require(controller.window).setContentSize(NSSize(width: width, height: 600))
    // Without a floor, a width change is a plain resize: the clip view keeps its offset.
    #expect(scroll.contentView.bounds.minY == clipY)
    #expect(view.foldedTop == nil)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test(arguments: [true, false])
  func aResizeAfterScrollingUpFromAFloorDropsIt(toTheTop: Bool) throws {
    let text = wrappingSectionsNotebook() as NSString
    let controller = try openNotebook(text as String)
    let view = controller.textView
    let clip = try #require(view.enclosingScrollView)
    let ten = text.range(of: "# Section 10\n").location
    try view.scrollToTop(offset: ten)
    try #require(try choose("Fold Heading", at: ten + 1, in: controller))
    try #require(view.foldedTop != nil)
    try view.scroll(toY: toTheTop ? 0 : view.visibleRect.minY - 1000)
    let before = try view.drawnTopLine()
    try #require(controller.window).setContentSize(NSSize(width: 600, height: 600))
    // More than a window of text is left below the top line: the floor no longer binds.
    #expect(view.foldedTop == nil)
    #expect(view.minSize.height <= clip.contentSize.height)
    let layout = try #require(view.textLayoutManager)
    layout.textViewportLayoutController.layoutViewport()
    let after = try view.drawnTopLine()
    #expect(after.offset == before.offset)
    #expect(after.screenY == before.screenY)
    layout.ensureLayout(for: layout.documentRange)
    layout.textViewportLayoutController.layoutViewport()
    try expectInPlace(view, before.offset, at: before.screenY)
  }

  // [utest->req~heading-folding.no-gap~1]
  @Test func aResizeLaysOutTheWindowBeforeFindingTheTopLine() throws {
    let text = wrappingSectionsNotebook() as NSString
    let controller = try openNotebook(text as String)
    let view = controller.textView
    let ten = text.range(of: "# Section 10\n").location
    try view.scrollToTop(offset: ten)
    try #require(try choose("Fold Heading", at: ten + 1, in: controller))
    try view.scroll(toY: view.visibleRect.minY - 300)
    try #require(view.foldedTop != nil)
    let before = try view.drawnTopLine()
    // The window's paragraphs have no layout, as after a scroll that display has not caught up with.
    let layout = try #require(view.textLayoutManager)
    let storage = try #require(view.textContentStorage)
    let top = try #require(
      storage.location(storage.documentRange.location, offsetBy: before.offset))
    layout.invalidateLayout(
      for: try #require(NSTextRange(location: top, end: storage.documentRange.endLocation)))
    try #require(controller.window).setContentSize(NSSize(width: 600, height: 600))
    layout.textViewportLayoutController.layoutViewport()
    let after = try view.drawnTopLine()
    #expect(after.offset == before.offset)
    #expect(after.screenY == before.screenY)
    #expect(view.foldedTop != nil)
  }

  @Test func aLargeNotebookOpensAndFoldsWithinTwoSeconds() throws {
    let words = String(repeating: "word ", count: 12)
    let text =
      "Intro.\n"
      + (1...100).map { section in
        "# Section \(section)\n" + (1...99).map { "Body \(section).\($0) \(words)\n" }.joined()
      }.joined()
    let clock = ContinuousClock()
    var opened: NotebookWindowController?
    let open = try clock.measure { opened = try openNotebook(text) }
    let controller = try #require(opened)
    let fold = try clock.measure { try #require(try choose("Fold All", in: controller)) }
    #expect(try controller.textView.visibleParagraphs().count == 101)
    #expect(open < .seconds(2))
    #expect(fold < .seconds(2))
  }

  // [utest->req~heading-folding.fold-all~1]
  @Test func foldAllLeavesTheTopLevelHeadingsAndTheTextBeforeThem() throws {
    let controller = try openNotebook(
      "Intro.\n# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\nDone.")
    let view = controller.textView
    #expect(view.foldedHeadingStarts.isEmpty)
    #expect(try choose("Fold All", in: controller))
    #expect(try view.visibleParagraphs() == ["Intro.", "# Tasks", "# Notes"])
    #expect(view.foldedHeadingStarts == [7, 43])
    #expect(try choose("Unfold Heading", at: 8, in: controller))
    #expect(
      try view.visibleParagraphs() == [
        "Intro.", "# Tasks", "## Fix the reaper", "It leaks.", "# Notes",
      ])
  }

  // [utest->req~heading-folding.unfold-all~1]
  @Test func unfoldAllShowsTheWholeFile() throws {
    let text = "Intro.\n# Tasks\n## Fix the reaper\nIt leaks.\n## Ship bilbo\n# Notes\nDone."
    let controller = try openNotebook(text)
    let view = controller.textView
    for line in ["# Notes", "## Ship bilbo", "## Fix the reaper", "# Tasks"] {
      let heading = try view.heading(startingWith: line)
      try #require(try choose("Fold Heading", at: heading.range.location, in: controller))
    }
    #expect(view.foldedHeadingStarts.count == 4)
    #expect(!view.markerViews().isEmpty)
    #expect(try choose("Unfold All", in: controller))
    #expect(try view.visibleText() == text)
    #expect(view.foldedMarkers.isEmpty)
    #expect(view.markerViews().isEmpty)
  }

  // [utest->req~heading-folding.disabled-without-heading~1]
  @Test func foldCommandsAreDisabledWithoutAHeadingAtTheSelection() throws {
    let controller = try openNotebook("Intro.\n# Tasks\n")
    let view = controller.textView
    let fold = try viewMenuItem("Fold Heading")
    let unfold = try viewMenuItem("Unfold Heading")
    view.setSelectedRange(NSRange(location: 2, length: 0))
    #expect(!view.validateMenuItem(fold))
    #expect(!view.validateMenuItem(unfold))
    view.setSelectedRange(NSRange(location: 9, length: 0))
    #expect(view.validateMenuItem(fold))
    #expect(view.validateMenuItem(unfold))
  }

  // [utest->req~heading-folding.disabled-without-heading~1]
  @Test func appKitMenuValidationDisablesTheFoldCommandsWithoutAHeading() throws {
    let controller = try openNotebook("Intro.\n# Tasks\n")
    let view = controller.textView
    let menu = try controller.viewMenuAimedAtTheResponderChain()
    view.setSelectedRange(NSRange(location: 2, length: 0))
    menu.update()
    #expect(menu.items.map(\.isEnabled) == [false, false, true, true])
    view.setSelectedRange(NSRange(location: 9, length: 0))
    menu.update()
    #expect(menu.items.map(\.isEnabled) == [true, true, true, true])
  }

  @Test func everyViewItemIsDisabledInANotebookWithNoHeading() throws {
    let controller = try openNotebook("Intro.\nNo heading here.\n")
    let menu = try controller.viewMenuAimedAtTheResponderChain()
    menu.update()
    #expect(menu.items.map(\.isEnabled) == [false, false, false, false])
  }

  // [utest->req~heading-folding.file-untouched~1]
  @Test func foldingNeverWritesTheFile() throws {
    let url = try writeTemporaryNotebook(tasksAndNotes)
    defer { removeTemporaryNotebook(url) }
    let controller = NotebookWindowController()
    try controller.open(url)
    let view = controller.textView
    let data = try Data(contentsOf: url)
    let modified = try #require(
      try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    view.setSelectedRange(NSRange(location: 1, length: 0))
    for _ in 1...20 {
      for title in ["Fold Heading", "Unfold Heading", "Fold All", "Unfold All"] {
        #expect(try choose(title, in: controller))
      }
    }
    #expect(try Data(contentsOf: url) == data)
    let after = try #require(
      try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    #expect(after == modified)
  }
}

/// One case of a resize after folding the last section: whether the notebook's lines wrap, the new
/// window size, and whether the top line is the paragraph above the heading, partly above the
/// window.
struct ResizeAfterAFold: Codable, Sendable, CustomTestStringConvertible {
  let wraps: Bool
  let width: CGFloat
  let height: CGFloat
  let partly: Bool
  /// The new width shortens the top line so that, at its old screen y, it ends above the window.
  let toTheEdge: Bool

  var testDescription: String {
    "\(wraps ? "wrapping" : "short") lines at \(Int(width))x\(Int(height))"
      + (partly ? ", top line partly above" : "")
  }

  static let all: [ResizeAfterAFold] =
    [true, false].flatMap { wraps in
      [(600, 600), (961, 600), (1400, 600), (960, 500), (960, 700)].map {
        ResizeAfterAFold(wraps: wraps, width: $0, height: $1, partly: false, toTheEdge: false)
      }
    } + [
      ResizeAfterAFold(wraps: true, width: 600, height: 600, partly: true, toTheEdge: false),
      ResizeAfterAFold(wraps: true, width: 1400, height: 600, partly: true, toTheEdge: true),
    ]
}

/// One case of the resize test: the new window width, the command, and the scroll without layout
/// before it.
struct WidthChange: Codable, Sendable, CustomTestStringConvertible {
  let width: CGFloat
  let command: String
  let shift: CGFloat

  var testDescription: String { "\(command) at \(Int(width)) points, shift \(Int(shift))" }

  static let all: [WidthChange] = ([600, 1400] as [CGFloat]).flatMap { width in
    ["above", "top line's heading", "Fold All", "Unfold All", "Unfold Heading"].flatMap { command in
      ([0, -2500, 5000] as [CGFloat]).map { WidthChange(width: width, command: command, shift: $0) }
    } + [WidthChange(width: width, command: "inside a child", shift: 0)]
  }
}
