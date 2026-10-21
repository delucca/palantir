import AppKit
import Foundation
import PalantirNotebook
import PalantirNotebookInspector
import Testing

@testable import Palantir
@testable import PalantirNotebookUI

/// The feature folders under `Sources`: every folder but the app's, the inspector's, the driver's
/// and the acceptance layer's, sorted.
func featureFolders() -> [String] {
  let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
  let names = (try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? []
  return names.filter {
    !["App", "Inspector", "Driver", "Acceptance"].contains($0) && !$0.hasPrefix(".")
  }
  .sorted()
}

/// The guard every feature passes: each menu command can be driven and each view palantir draws
/// itself has an accessibility label.
@Suite(.layer(.integration))
struct GuardTests {
  private typealias MenuEntry = (path: [String], item: NSMenuItem)

  /// The items of `menu` and its submenus, separators left out, each with its path of titles.
  @MainActor private static func items(_ menu: NSMenu, _ parent: [String] = []) -> [MenuEntry] {
    menu.items.filter { !$0.isSeparatorItem }.flatMap { item in
      [(parent + [item.title], item)]
        + (item.submenu.map { items($0, parent + [item.title]) } ?? [])
    }
  }

  // Structural only: what AXPress needs of an item, read in-process, not the tree a launched
  // palantir serves.
  // req~main-menu.drivable~1
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

  // req~accessibility.custom-view-labels~1
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
