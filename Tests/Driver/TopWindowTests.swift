import CoreGraphics
import Testing

@testable import PalantirDriver

@Suite(.layer(.unit))
struct TopWindowTests {
  static let palantir: pid_t = 5534
  static let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
  static let cursorLayer = 2_147_483_630

  static func window(
    _ owner: pid_t, _ bundleID: String?, layer: Int, _ bounds: CGRect
  ) -> TopWindow.Info {
    TopWindow.Info(owner: owner, ownerBundleID: bundleID, layer: layer, bounds: bounds)
  }

  static let menuBar = window(
    167, "com.apple.WindowServer", layer: 24, CGRect(x: 0, y: 0, width: 1024, height: 30))
  static let palantirWindow = window(
    palantir, "dev.delucca.palantir", layer: 0, CGRect(x: 31, y: 42, width: 962, height: 632))
  static let dock = window(5522, "com.apple.dock", layer: 20, screen)
  static let banner = window(
    395, "com.apple.notificationcenterui", layer: 25, CGRect(x: 8, y: 38, width: 360, height: 180))

  static func owner(_ windows: [TopWindow.Info], at point: CGPoint) -> pid_t? {
    TopWindow.owner(at: point, in: windows, displays: [screen], cursorLayer: cursorLayer)
  }

  // A guest's window list with the Dock not autohiding, as in
  // T/machine/logs/33-dock-autohide-off-probe.log.
  @Test func aFullScreenDockWindowAbovePalantirIsNotOnTop() {
    let windows = [Self.menuBar, Self.dock, Self.palantirWindow]
    #expect(Self.owner(windows, at: CGPoint(x: 500, y: 300)) == Self.palantir)
  }

  @Test func aFullDisplayNotificationCenterWindowIsNotOnTop() {
    let overlay = Self.window(395, "com.apple.notificationcenterui", layer: 25, Self.screen)
    #expect(
      Self.owner([overlay, Self.palantirWindow], at: CGPoint(x: 500, y: 300)) == Self.palantir)
  }

  @Test func aNotificationBannerOverPalantirStillCoversIt() {
    let windows = [Self.banner, Self.palantirWindow]
    #expect(Self.owner(windows, at: CGPoint(x: 100, y: 100)) == 395)
    #expect(Self.owner(windows, at: CGPoint(x: 500, y: 300)) == Self.palantir)
  }

  @Test func aSmallDockWindowOverPalantirCoversIt() {
    let shelf = Self.window(
      5522, "com.apple.dock", layer: 20, CGRect(x: 400, y: 700, width: 300, height: 68))
    let low = Self.window(
      5534, "dev.delucca.palantir", layer: 0, CGRect(x: 0, y: 0, width: 1024, height: 768))
    #expect(Self.owner([shelf, low], at: CGPoint(x: 500, y: 720)) == 5522)
  }

  @Test func aFullScreenWindowOfAnotherAppStillCoversPalantir() {
    let cover = Self.window(900, "com.apple.Safari", layer: 25, Self.screen)
    #expect(Self.owner([cover, Self.palantirWindow], at: CGPoint(x: 500, y: 300)) == 900)
  }

  @Test func aNormalLayerDockOwnedWindowCountsAsAnyWindow() {
    let flat = Self.window(5522, "com.apple.dock", layer: 0, Self.screen)
    #expect(Self.owner([flat, Self.palantirWindow], at: CGPoint(x: 500, y: 300)) == 5522)
  }

  @Test func thePointerIsNoWindow() {
    let pointer = Self.window(1, nil, layer: Self.cursorLayer, Self.screen)
    #expect(
      Self.owner([pointer, Self.palantirWindow], at: CGPoint(x: 500, y: 300)) == Self.palantir)
  }

  @Test func noWindowAtThePointMeansNoOwner() {
    #expect(Self.owner([Self.palantirWindow], at: CGPoint(x: 1000, y: 10)) == nil)
  }
}
