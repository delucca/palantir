import Foundation
import Testing

@testable import PalantirNotebookUI

@MainActor
struct FoldedParagraphsTests {
  // [utest->req~heading-folding.fold~1]
  @Test(
    arguments: [
      [10..<60, 20..<30, 25..<27, 40..<55],
      [0..<3, 3..<7, 7..<9, 20..<25, 25..<30],
      [5..<5, 5..<8, 12..<12, 20..<20, 30..<34, 34..<34],
      [40..<45, 0..<10, 8..<38],
      [],
    ] as [[Range<Int>]])
  func hiddenParagraphsAreTheOffsetsInAFoldedRange(ranges: [Range<Int>]) {
    let folding = FoldedParagraphs()
    folding.hiddenRanges = ranges.map { NSRange($0) }
    for offset in 0...70 {
      let linear = folding.hiddenRanges.contains { NSLocationInRange(offset, $0) }
      #expect(folding.hides(offset) == linear, "offset \(offset)")
    }
  }

  // [utest->req~heading-folding.fold~1]
  @Test func hidesAnswersWithoutScanningEveryRange() {
    let folding = FoldedParagraphs()
    folding.hiddenRanges = (0..<40_000).map { NSRange(location: $0 * 4, length: 2) }
    let clock = ContinuousClock()
    var hidden = 0
    let elapsed = clock.measure {
      for offset in 0..<160_000 where folding.hides(offset) { hidden += 1 }
    }
    #expect(hidden == 80_000)
    #expect(elapsed < .seconds(1))
  }
}
