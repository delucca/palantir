#if DEBUG
  import AppKit

  /// Renders a window's content from its view hierarchy, without Screen Recording: what AppKit
  /// draws, not Metal layers or what covers the window.
  enum Screenshot {
    /// A PNG of the window's content, or of `rect` in window points from its top-left, at the
    /// display's pixels per point.
    @MainActor static func render(_ window: NSWindow, _ rect: Rect?) throws -> ScreenshotResult {
      guard let content = window.contentView else { throw InspectorError.noWindow }
      let bounds = content.bounds
      let area = rect?.cgRect ?? CGRect(origin: .zero, size: bounds.size)
      guard area.width > 0, area.height > 0,
        CGRect(origin: .zero, size: bounds.size).contains(area)
      else {
        throw InspectorError.invalidParams(
          "rect \(area) is not inside the content, 0,0 to \(bounds.width),\(bounds.height)")
      }
      let flipped = CGRect(
        x: bounds.minX + area.minX,
        y: content.isFlipped ? bounds.minY + area.minY : bounds.maxY - area.maxY,
        width: area.width, height: area.height)
      guard let bitmap = content.bitmapImageRepForCachingDisplay(in: flipped) else {
        throw InspectorError.stateUnavailable("no bitmap for \(area)")
      }
      content.cacheDisplay(in: flipped, to: bitmap)
      drawScrollers(of: content, in: flipped, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw InspectorError.stateUnavailable("no PNG for \(area)")
      }
      return ScreenshotResult(
        png: png, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
        scale: window.backingScaleFactor)
    }

    /// Draws the scrollers `cacheDisplay` leaves out, as AppKit puts them in layers of their own:
    /// every one shown, legacy or overlay.
    @MainActor private static func drawScrollers(
      of content: NSView, in area: CGRect, to bitmap: NSBitmapImageRep
    ) {
      let shown = scrollers(in: content).filter {
        !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0
      }
      guard !shown.isEmpty, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = context
      for scroller in shown {
        let frame = scroller.convert(scroller.bounds, to: content)
        guard frame.intersects(area) else { continue }
        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(
          by: frame.minX - area.minX,
          yBy: content.isFlipped ? area.maxY - frame.maxY : frame.minY - area.minY)
        if scroller.isFlipped {
          transform.translateX(by: 0, yBy: frame.height)
          transform.scaleX(by: 1, yBy: -1)
        }
        transform.concat()
        NSBezierPath.clip(scroller.bounds)
        scroller.draw(scroller.bounds)
        context.restoreGraphicsState()
      }
    }

    @MainActor private static func scrollers(in view: NSView) -> [NSScroller] {
      view.subviews.flatMap { subview in
        (subview as? NSScroller).map { [$0] } ?? scrollers(in: subview)
      }
    }
  }
#endif
