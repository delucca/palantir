import ApplicationServices
import Foundation

/// palantir's menu bar as the accessibility tree shows it.
struct MenuBar {
  /// A menu bar item: its titles from the menu bar down, whether it is enabled, whether the tree
  /// offers a press for it, and its key equivalent in `Chord` notation or "-". A separator has an
  /// empty title.
  struct Item: Equatable {
    var path: [String]
    var isEnabled: Bool
    var canPress: Bool
    var keyEquivalent: String
    fileprivate var element: AXUIElement

    var title: String { path.joined(separator: " > ") }

    static func == (lhs: Item, rhs: Item) -> Bool {
      lhs.path == rhs.path && lhs.isEnabled == rhs.isEnabled && lhs.canPress == rhs.canPress
        && lhs.keyEquivalent == rhs.keyEquivalent
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
            keyEquivalent: KeyEquivalent.text(
              char: Accessibility.string(child, kAXMenuItemCmdCharAttribute),
              virtualKey: (Accessibility.value(child, kAXMenuItemCmdVirtualKeyAttribute)
                as? NSNumber)?
                .intValue,
              modifiers: (Accessibility.value(child, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?
                .intValue ?? 0),
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
    guard
      item.isEnabled
        || Self.becomesEnabled(
          read: { Accessibility.value(item.element, kAXEnabledAttribute) as? Bool ?? false })
    else { throw DriverError("\(path) is disabled") }
    let error = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    guard error == .success else {
      throw DriverError("pressing \(path) failed: AXError \(error.rawValue)")
    }
  }

  /// How long a disabled item is re-read before it is believed, and how often: right after palantir
  /// takes the front AppKit has not revalidated its items yet.
  static let enableTimeout = 1.0
  static let enablePoll = 0.05

  /// Whether `read` answers true within `timeout` seconds, asking every `poll` seconds.
  static func becomesEnabled(
    timeout: Double = enableTimeout, poll: Double = enablePoll, read: () -> Bool,
    now: () -> Double = { Date().timeIntervalSinceReferenceDate },
    sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) -> Bool {
    let end = now() + timeout
    while now() < end {
      sleep(poll)
      if read() { return true }
    }
    return false
  }

  /// The titles in a path written as "View > Fold All".
  static func titles(_ path: String) -> [String] {
    path.components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }
  }
}

/// A menu item's key equivalent as the accessibility tree reports it.
enum KeyEquivalent {
  /// What a menu item without a key equivalent prints.
  static let none = "-"

  /// The key equivalent in `Chord` notation, such as "cmd+o" or "cmd+shift+g", or `none`.
  ///
  /// - Parameters:
  ///   - char: the item's command character, empty or nil when it has none. A control character
  ///     or a function-key glyph is no name, so such an item falls back to `virtualKey`.
  ///   - virtualKey: its virtual key code, for a key with no character.
  ///   - modifiers: the menu modifier mask: 0 is Command alone, bit 0 adds Shift, bit 1 Option,
  ///     bit 2 Control, and bit 3 drops Command.
  static func text(char: String?, virtualKey: Int?, modifiers: Int) -> String {
    let key: String
    if let char, char.unicodeScalars.allSatisfy(Self.isPrintable), !char.isEmpty {
      key = char.lowercased()
    } else if let virtualKey,
      let name = Chord.keys.first(where: { Int($0.value) == virtualKey })?.key
    {
      key = name
    } else {
      return none
    }
    var parts: [String] = []
    if modifiers & 0b1000 == 0 { parts.append("cmd") }
    if modifiers & 0b0001 != 0 { parts.append("shift") }
    if modifiers & 0b0010 != 0 { parts.append("opt") }
    if modifiers & 0b0100 != 0 { parts.append("ctrl") }
    return (parts + [key]).joined(separator: "+")
  }

  private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 0x20 && scalar.value != 0x7f && !(0xF700...0xF8FF).contains(scalar.value)
      && scalar.properties.generalCategory != .control
  }
}
