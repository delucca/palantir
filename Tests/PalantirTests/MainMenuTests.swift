import AppKit
import Testing

@testable import Palantir

@MainActor
struct MainMenuTests {
  @Test func menusFollowTheHIGOrder() {
    let titles = MainMenu.make().items.map(\.title)
    #expect(titles.dropFirst() == ["Edit", "Window", "Help"])
  }
}
