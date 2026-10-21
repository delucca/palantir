import ApplicationServices
import Foundation

/// Reads of the accessibility tree.
enum Accessibility {
  static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as? String
  }

  static func children(_ element: AXUIElement) -> [AXUIElement] {
    value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }

  static func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
  }

  static func frame(_ element: AXUIElement) throws -> CGRect {
    guard let position = value(element, kAXPositionAttribute),
      let size = value(element, kAXSizeAttribute)
    else { throw DriverError("an element without a frame") }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
  }

  /// The tree under `element`, one line per element: role, title, label and actions, indented.
  static func describe(_ element: AXUIElement, depth: Int = 0) -> [String] {
    let role = string(element, kAXRoleAttribute) ?? "?"
    var line = String(repeating: "  ", count: depth) + role
    if let title = string(element, kAXTitleAttribute), !title.isEmpty {
      line += " title=\(title.debugDescription)"
    }
    if let label = string(element, kAXDescriptionAttribute), !label.isEmpty {
      line += " label=\(label.debugDescription)"
    }
    if let frame = try? frame(element) {
      line +=
        " frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
    }
    let actions = actions(element)
    if !actions.isEmpty { line += " actions=\(actions.joined(separator: ","))" }
    return [line] + children(element).flatMap { describe($0, depth: depth + 1) }
  }
}
