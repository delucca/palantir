import ApplicationServices
import Foundation

/// palantir's menu bar as the accessibility tree shows it.
struct MenuBar {
  /// A menu bar item: its titles from the menu bar down, whether it is enabled, and whether the
  /// tree offers a press for it. A separator has an empty title.
  struct Item: Equatable {
    var path: [String]
    var isEnabled: Bool
    var canPress: Bool
    fileprivate var element: AXUIElement

    var title: String { path.joined(separator: " > ") }

    static func == (lhs: Item, rhs: Item) -> Bool {
      lhs.path == rhs.path && lhs.isEnabled == rhs.isEnabled && lhs.canPress == rhs.canPress
    }
  }

  let items: [Item]

  init(of palantir: Palantir) throws {
    guard let bar = Accessibility.value(palantir.element, kAXMenuBarAttribute) else {
      throw DriverError("palantir \(palantir.pid) shows no menu bar in the accessibility tree")
    }
    var items: [Item] = []
    func walk(_ element: AXUIElement, _ path: [String]) {
      for child in Accessibility.children(element) {
        let role = Accessibility.string(child, kAXRoleAttribute)
        guard role == kAXMenuBarItemRole || role == kAXMenuItemRole else {
          walk(child, path)
          continue
        }
        let itemPath = path + [Accessibility.string(child, kAXTitleAttribute) ?? ""]
        items.append(
          Item(
            path: itemPath,
            isEnabled: Accessibility.value(child, kAXEnabledAttribute) as? Bool ?? false,
            canPress: Accessibility.actions(child).contains(kAXPressAction),
            element: child))
        walk(child, itemPath)
      }
    }
    walk(bar as! AXUIElement, [])
    self.items = items
  }

  /// Presses the item at `path`, such as "View > Fold All". The press returns once palantir has
  /// run the item's action.
  func press(_ path: String) throws {
    let titles = Self.titles(path)
    guard let item = items.first(where: { $0.path == titles }) else {
      throw DriverError("no menu item \(path)")
    }
    guard item.isEnabled else { throw DriverError("\(path) is disabled") }
    let error = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    guard error == .success else {
      throw DriverError("pressing \(path) failed: AXError \(error.rawValue)")
    }
  }

  /// The titles in a path written as "View > Fold All".
  static func titles(_ path: String) -> [String] {
    path.components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
