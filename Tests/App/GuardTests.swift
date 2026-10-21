import AppKit
import ApplicationServices
import Foundation
import PalantirInspector
import PalantirNotebook
import PalantirNotebookInspector
import Testing

@testable import Palantir
@testable import PalantirDriver
@testable import PalantirNotebookUI

/// The feature folders under `Sources`: every folder but the app's, the inspector's and the
/// driver's, sorted.
func featureFolders() -> [String] {
  let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
  let names = (try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? []
  return names.filter { !["App", "Inspector", "Driver"].contains($0) && !$0.hasPrefix(".") }
    .sorted()
}

/// The guard every feature passes: each menu command can be driven, each feature reports state,
/// and each view palantir draws itself has an accessibility label.
struct GuardTests {
  private typealias MenuEntry = (path: [String], item: NSMenuItem)

  /// The items of `menu` and its submenus, separators left out, each with its path of titles.
  @MainActor private static func items(_ menu: NSMenu, _ parent: [String] = []) -> [MenuEntry] {
    menu.items.filter { !$0.isSeparatorItem }.flatMap { item in
      [(parent + [item.title], item)]
        + (item.submenu.map { items($0, parent + [item.title]) } ?? [])
    }
  }

  /// The paths of the menu bar a palantir process makes.
  @MainActor private static func menuPaths() -> [[String]] {
    items(MainMenu.make(name: "palantir")).map(\.path)
  }

  // Structural only: what AXPress needs of an item, read in-process. Whether the tree agents read
  // offers the press is the launched test below.
  // [utest->req~main-menu.drivable~1]
  @MainActor @Test func everyMenuBarItemIsShownWithATitleAndAnActionOrASubmenu() throws {
    let items = Self.items(MainMenu.make(name: "palantir"))
    try #require(items.count > 20)
    for (path, item) in items {
      let name = path.joined(separator: " > ")
      #expect(!item.isHidden, "\(name) is hidden")
      #expect(!item.title.isEmpty, "\(name) has no title")
      #expect(item.action != nil || item.submenu != nil, "\(name) has no action and no submenu")
      #expect(
        item.isAccessibilityElement() && item.accessibilityRole() == .menuItem,
        "\(name) is not an accessibility menu item")
      #expect(item.accessibilityTitle() == item.title, "\(name) has no accessibility title")
    }
  }

  // [utest->req~main-menu.drivable~1]
  @Test(.launchesPalantir)
  func everyMenuBarItemShowsInTheAccessibilityTreeWithItsTitleAndAPress() async throws {
    try #require(AXIsProcessTrusted(), "the app running the tests needs the Accessibility grant")
    let launched = try await LaunchedPalantir(
      LaunchedPalantir.built("palantir"), arguments: [InspectorListener.launchFlag])
    let expected = await Self.menuPaths()
    let shown = try MenuBar(of: Palantir(pid: launched.pid)).items
    try #require(expected.count > 20)
    for path in expected {
      let item = shown.first { $0.path == path }
      #expect(item != nil, "\(path.joined(separator: " > ")) is not in the accessibility tree")
      #expect(item?.canPress == true, "\(path.joined(separator: " > ")) has no press action")
    }
  }

  // [utest->req~inspector.state-per-feature~1]
  @Test(.launchesPalantir) func everyFeatureReportsStateInALaunchedApp() async throws {
    let launched = try await LaunchedPalantir(
      LaunchedPalantir.built("palantir"), arguments: [InspectorListener.launchFlag])
    let client = try InspectorClient(pid: launched.pid)
    let response = try await Task.detached { try client.call(.state, NoParams(), timeout: 5) }.value
    let result = try #require(
      (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"]
        as? [String: Any])
    let sections = try #require(result["sections"] as? [String: [String: Any]])
    let features = featureFolders()
    try #require(!features.isEmpty)
    for feature in features {
      #expect(sections[feature.lowercased()]?.isEmpty == false, "\(feature) reports no state")
    }
  }

  /// The views palantir draws itself in `window`: those of its own classes, and the views it adds
  /// to them, as opposed to the private views AppKit adds.
  @MainActor private static func ownViews(_ view: NSView) -> [NSView] {
    let own = String(reflecting: type(of: view)).hasPrefix("Palantir")
    let added =
      own ? view.subviews.filter { !NSStringFromClass(type(of: $0)).hasPrefix("_") } : []
    return (own ? [view] : []) + added + view.subviews.flatMap(ownViews)
  }

  /// Every element under `element` in the accessibility hierarchy AppKit serves.
  @MainActor private static func accessibilityElements(_ element: Any) -> [Any] {
    let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
    return [element] + children.flatMap(accessibilityElements)
  }

  /// For each feature folder, a window showing every view the feature draws itself; a feature
  /// folder without one fails the label guard, so a new feature has to add its own.
  @MainActor private static func labelFixture(_ feature: String) throws -> NSWindowController? {
    switch feature {
    case "Notebook":
      let controller = try openNotebook("# Tasks\n## Fix the reaper\nIt leaks.\n# Notes\n")
      let view = controller.textView
      let heading = try view.heading(startingWith: "## Fix the reaper")
      try #require(try choose("Fold Heading", at: heading.range.location + 1, in: controller))
      let content = try #require(controller.window?.contentView)
      let views = ownViews(content)
      try #require(views.contains { $0 === view } && views.contains { $0 is NSImageView })
      #expect(view.foldedMarkers[heading.range.location]?.accessibilityLabel() == "Folded")
      return controller
    default:
      return nil
    }
  }

  // [utest->req~accessibility.custom-view-labels~1]
  @MainActor @Test func everyViewPalantirDrawsHasAnAccessibilityLabel() throws {
    let features = featureFolders()
    try #require(!features.isEmpty)
    for feature in features {
      let controller = try #require(
        try Self.labelFixture(feature), "\(feature) has no label fixture in GuardTests")
      let content = try #require(controller.window?.contentView)
      let views = Self.ownViews(content)
      try #require(!views.isEmpty, "\(feature)'s fixture shows no view palantir draws")
      let tree = Self.accessibilityElements(content)
      for own in views {
        let name = String(reflecting: type(of: own))
        #expect(own.accessibilityLabel()?.isEmpty == false, "\(name) has no accessibility label")
        #expect(tree.contains { ($0 as AnyObject) === own }, "\(name) is not in the tree")
      }
    }
  }
}
