import AppKit
import Foundation
import Testing

@testable import PalantirInspector

@MainActor
struct ScreenshotTests {
  /// `window` on the screen, transparent, so its display cycle runs: a hidden window never
  /// settles.
  private func show(_ window: NSWindow) {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFront(nil)
  }

  /// A window on the screen whose 800 by 600 point content is white with a red 100 by 50 point
  /// corner at its top-left.
  private func window() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let corner = NSView(frame: NSRect(x: 0, y: 550, width: 100, height: 50))
    corner.wantsLayer = true
    corner.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    content.addSubview(corner)
    window.contentView = content
    show(window)
    return window
  }

  private func image(_ result: ScreenshotResult) throws -> NSBitmapImageRep {
    try #require(NSBitmapImageRep(data: result.png))
  }

  // [utest->req~inspector.screenshots~1]
  @Test func aScreenshotHasThePixelsOfTheDisplay() async throws {
    let window = window()
    defer { window.orderOut(nil) }
    let scale = Double(window.backingScaleFactor)
    let inspector = Inspector(window: { window }, sections: [])

    let whole = try await inspector.screenshot(of: nil, timeout: nil)
    #expect(whole.scale == scale)
    #expect(whole.width == Int(800 * scale) && whole.height == Int(600 * scale))
    let wholeImage = try image(whole)
    #expect(wholeImage.pixelsWide == whole.width && wholeImage.pixelsHigh == whole.height)

    let corner = try await inspector.screenshot(
      of: Rect(x: 0, y: 0, width: 100, height: 50), timeout: nil)
    #expect(corner.width == Int(100 * scale) && corner.height == Int(50 * scale))
    let cornerImage = try image(corner)
    let red = try #require(cornerImage.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    #expect(red.redComponent > 0.9 && red.greenComponent < 0.3 && red.blueComponent < 0.3)
    let below = try await inspector.screenshot(
      of: Rect(x: 0, y: 50, width: 100, height: 50), timeout: nil)
    let white = try #require(try image(below).colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    #expect(white.redComponent > 0.9 && white.greenComponent > 0.9 && white.blueComponent > 0.9)
  }

  // [utest->req~inspector.screenshots~1]
  @Test func aRetinaWindowGivesTheExampleSizes() async throws {
    let window = window()
    defer { window.orderOut(nil) }
    try #require(window.backingScaleFactor == 2, "this machine's display is not 2x")
    let inspector = Inspector(window: { window }, sections: [])
    let whole = try await inspector.screenshot(of: nil, timeout: nil)
    #expect((whole.width, whole.height) == (1600, 1200))
    let corner = try await inspector.screenshot(
      of: Rect(x: 0, y: 0, width: 100, height: 50), timeout: nil)
    #expect((corner.width, corner.height) == (200, 100))
  }

  // [utest->req~inspector.screenshots~1]
  @Test(arguments: [NSScroller.Style.legacy, .overlay])
  func aScreenshotDrawsTheScrollerKnobWhereTheScrollerHasIt(style: NSScroller.Style) async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    scroll.hasVerticalScroller = true
    scroll.backgroundColor = .white
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
    window.contentView = scroll
    show(window)
    defer { window.orderOut(nil) }
    try #require(window.backingScaleFactor == 2, "this machine's display is not 2x")
    let inspector = Inspector(window: { window }, sections: [])
    // On the screen AppKit gives the scrollers the system's style; set the one under test after.
    _ = try await inspector.waitForSettledLayout(timeout: nil)
    scroll.scrollerStyle = style
    // Off the middle, so a knob drawn upside down lands somewhere else.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 225))
    scroll.reflectScrolledClipView(scroll.contentView)
    _ = try await inspector.waitForSettledLayout(timeout: nil)
    let scroller = try #require(scroll.verticalScroller)
    try #require(scroller.scrollerStyle == style)
    try #require(scroll.isFlipped, "the content's points must run from its top-left")
    let strip = scroller.convert(scroller.bounds, to: scroll)
    let knob = scroller.convert(scroller.rect(for: .knob), to: scroll)

    let shot = try image(
      try await inspector.screenshot(
        of: Rect(
          x: Double(strip.minX), y: Double(strip.minY), width: Double(strip.width),
          height: Double(strip.height)),
        timeout: nil))
    let column = Int(((knob.midX - strip.minX) * 2).rounded(.down))
    let brightness = (0..<shot.pixelsHigh).map {
      shot.colorAt(x: column, y: $0)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
    }
    let track = try #require(brightness.max())
    let rows = brightness.indices.filter { brightness[$0] < track - 0.15 }
    let drawn = try #require(rows.first)...(try #require(rows.last))
    let expected = (knob.minY - strip.minY) * 2...(knob.maxY - strip.minY) * 2
    #expect(CGFloat(drawn.lowerBound) >= expected.lowerBound - 2, "\(drawn) against \(expected)")
    #expect(CGFloat(drawn.upperBound) <= expected.upperBound + 2, "\(drawn) against \(expected)")
    #expect(
      CGFloat(drawn.count) >= (expected.upperBound - expected.lowerBound) * 0.8,
      "\(drawn) against \(expected)")
  }

  // [utest->req~inspector.settled-layout~1]
  // [utest->req~inspector.never-drives~1]
  @Test func aHiddenWindowWithLayoutPendingIsNeitherSettledNorRendered() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    // Without a layer, nothing lays the view out while the window is off the screen.
    let content = NSView()
    window.contentView = content
    let inspector = Inspector(window: { window }, sections: [])
    content.needsLayout = true
    let waited = await #expect(throws: InspectorError.self) {
      try await inspector.waitForSettledLayout(timeout: 1)
    }
    #expect(waited?.code == -32_003)
    content.needsLayout = true
    let shot = await #expect(throws: InspectorError.self) {
      try await inspector.screenshot(of: nil, timeout: 1)
    }
    // It refused before rendering, which would have done the pending work.
    #expect(shot?.code == -32_003)
  }

  @Test(arguments: [
    Rect(x: 0, y: 0, width: 0, height: 10), Rect(x: -1, y: 0, width: 10, height: 10),
    Rect(x: 700, y: 0, width: 101, height: 10), Rect(x: 0, y: 590, width: 10, height: 11),
  ])
  func aRectOutsideTheContentIsAnError(rect: Rect) async throws {
    let window = window()
    defer { window.orderOut(nil) }
    let inspector = Inspector(window: { window }, sections: [])
    let error = await #expect(throws: InspectorError.self) {
      try await inspector.screenshot(of: rect, timeout: nil)
    }
    #expect(error?.code == -32_602)
  }
}
