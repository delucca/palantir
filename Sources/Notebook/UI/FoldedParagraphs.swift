import AppKit

final class FoldedParagraphs: NSObject, NSTextContentStorageDelegate {
  var hiddenRanges: [NSRange] = [] {
    didSet {
      hiddenOffsets = hiddenRanges.compactMap { Range($0) }.reduce(into: IndexSet()) {
        $0.insert(integersIn: $1)
      }
    }
  }
  private var hiddenOffsets = IndexSet()

  // TextKit asks about every hidden paragraph it passes, thousands of times a layout.
  func hides(_ offset: Int) -> Bool {
    hiddenOffsets.contains(offset)
  }

  func textContentManager(
    _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
    options: NSTextContentManager.EnumerationOptions
  ) -> Bool {
    guard let storage = textContentManager as? NSTextContentStorage,
      let start = textElement.elementRange?.location
    else { return true }
    return !hides(storage.offset(from: storage.documentRange.location, to: start))
  }
}
