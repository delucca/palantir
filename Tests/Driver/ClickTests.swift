import CoreGraphics
import Testing

@testable import PalantirDriver

@Suite(.layer(.unit))
struct ClickTests {
  private struct Failed: Error {}

  private func send(failingOn failing: CGEventType?) -> [CGEventType] {
    var released: [CGEventType] = []
    _ = try? Input.sendClicks(
      count: 1,
      makeEvent: { type, _ in
        CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)
      },
      post: { if $0.type == failing { throw Failed() } },
      release: { released.append($0.type) })
    return released
  }

  @Test func aMouseUpIsReleasedWhenPostingTheMouseDownFails() {
    #expect(send(failingOn: .leftMouseDown) == [.leftMouseUp])
  }

  @Test func aMouseUpIsReleasedWhenPostingItFails() {
    #expect(send(failingOn: .leftMouseUp) == [.leftMouseUp])
  }

  @Test func aCleanClickReleasesNothingExtra() {
    #expect(send(failingOn: nil).isEmpty)
  }
}
