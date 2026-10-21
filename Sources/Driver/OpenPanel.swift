import ApplicationServices
import Foundation

/// The system open panel palantir shows for File > Open…: Command-Shift-G for the Go to Folder
/// sheet, the path typed into the sheet's field and sent with Return, then the panel's Open button
/// through the accessibility tree. The sheet does not take a value set through accessibility, and
/// another process draws the panel, so a key reaches it only through the system's event stream. Each
/// key is checked against palantir's focused window first, Return also against the field holding
/// exactly the path, and each step waits until the tree shows its effect, so nothing is on its way
/// when the front goes back.
struct OpenPanel {
  let palantir: Palantir

  /// How long each step may take to show in the accessibility tree.
  static let stepTimeout = 3.0
  /// How many times Open is pressed before the panel counts as stuck: the panel may still be
  /// selecting the file.
  static let openAttempts = 3

  /// How `choose` got the path in and the sheet closed, printed on stderr.
  struct Route: CustomStringConvertible {
    var description: String { "path by keys, Go to Folder by Return, Open by accessibility" }
  }

  func choose(_ path: String) throws -> Route {
    // The panel is modal, and while it is up it, not the notebook's window, is the main window.
    let windows = Accessibility.value(palantir.element, kAXWindowsAttribute) as? [AXUIElement] ?? []
    guard
      let panel = windows.first(where: {
        Accessibility.value($0, kAXModalAttribute) as? Bool == true
      })
    else { throw DriverError("palantir shows no open panel; press File > Open… first") }
    AXUIElementPerformAction(panel, kAXRaiseAction as CFString)
    try wait(for: "the open panel in front") {
      palantir.focusedWindow.map { CFEqual($0, panel) } == true ? true : nil
    }
    var input = Input(palantir: palantir, system: true)
    input.panel = panel

    try input.press(Chord.goToFolder)
    let goTo = try wait(for: "the Go to Folder sheet") { sheet(in: panel) }
    let field = try wait(for: "the Go to Folder sheet's field") {
      Accessibility.children(goTo).first {
        Accessibility.string($0, kAXRoleAttribute) == kAXTextFieldRole
      }
    }
    func typed() -> String? { Accessibility.string(field, kAXValueAttribute) }
    // Typing replaces what the field holds.
    var all = CFRange(location: 0, length: (typed() ?? "").utf16.count)
    if let range = AXValueCreate(.cfRange, &all) {
      AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, range)
    }
    try input.type(path)
    try wait(
      for: "the path in the Go to Folder sheet", showing: { String(reflecting: typed() ?? "") },
      { typed() == path ? true : nil })

    // Return goes only to a sheet whose field holds exactly the path.
    guard typed() == path else {
      throw DriverError(
        "the Go to Folder sheet holds \(String(reflecting: typed() ?? "")), not the path; no Return was sent"
      )
    }
    try input.press(Chord("return"))
    try wait(for: "the Go to Folder sheet to close") { sheet(in: panel) == nil ? true : nil }

    let open = try wait(for: "the open panel's Open button") { button(titled: "Open", in: panel) }
    for attempt in 1...Self.openAttempts {
      AXUIElementPerformAction(open, kAXPressAction as CFString)
      do {
        try wait(for: "the open panel to close") {
          let shown =
            Accessibility.value(palantir.element, kAXWindowsAttribute) as? [AXUIElement] ?? []
          return shown.contains { CFEqual($0, panel) } ? nil : ()
        }
        return Route()
      } catch  where attempt < Self.openAttempts {}
    }
    return Route()
  }

  private func sheet(in panel: AXUIElement) -> AXUIElement? {
    Accessibility.children(panel).first {
      Accessibility.string($0, kAXRoleAttribute) == kAXSheetRole
    }
  }

  private func button(titled title: String, in element: AXUIElement) -> AXUIElement? {
    for child in Accessibility.children(element) {
      if Accessibility.string(child, kAXRoleAttribute) == kAXButtonRole,
        Accessibility.string(child, kAXTitleAttribute) == title
      {
        return child
      }
      if let found = button(titled: title, in: child) { return found }
    }
    return nil
  }

  @discardableResult private func wait<Value>(
    for step: String, showing shown: (() -> String)? = nil, _ found: () -> Value?
  ) throws -> Value {
    let deadline = Date().addingTimeInterval(Self.stepTimeout)
    while Date() < deadline {
      if let value = found() { return value }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    throw DriverError("timed out waiting for \(step)" + (shown.map { "; it shows \($0())" } ?? ""))
  }
}
