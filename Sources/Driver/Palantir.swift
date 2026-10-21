import AppKit
import ApplicationServices

/// A running palantir the driver uses.
struct Palantir {
  let pid: pid_t
  let element: AXUIElement

  /// How long `activate()` waits for palantir to come to the front.
  static let activationTimeout = 3.0

  init(pid: pid_t) {
    self.pid = pid
    element = AXUIElementCreateApplication(pid)
  }

  /// The palantir with `pid`, or the only palantir running when `pid` is nil.
  static func find(pid: pid_t?) throws -> Palantir {
    let running = NSWorkspace.shared.runningApplications.filter {
      $0.executableURL?.lastPathComponent == "palantir"
    }
    if let pid {
      guard running.contains(where: { $0.processIdentifier == pid }) else {
        throw DriverError("no palantir with pid \(pid)")
      }
      return Palantir(pid: pid)
    }
    guard let only = running.first else { throw DriverError("no palantir is running") }
    guard running.count == 1 else {
      throw DriverError(
        "several palantirs are running (pids \(running.map { String($0.processIdentifier) }.joined(separator: ", "))); pass --pid"
      )
    }
    return Palantir(pid: only.processIdentifier)
  }

  var isFrontmost: Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  }

  /// Makes palantir the active app with a focused window and, with `raising`, waits until that
  /// window is on top too.
  func activate(raising: Bool = true) throws {
    func done() -> Bool { raising ? isInFront : isFrontmost && focusedWindow != nil }
    if done() { return }
    AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    let deadline = Date().addingTimeInterval(Self.activationTimeout)
    while Date() < deadline {
      if done() { return }
      // A window that palantir ordered behind the others stays there when it only activates, and
      // the window may not be there to raise right after activating.
      if raising,
        let window = Accessibility.value(element, kAXMainWindowAttribute) ?? focusedWindow,
        CFGetTypeID(window) == AXUIElementGetTypeID()
      {
        AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let front = NSWorkspace.shared.frontmostApplication
    throw DriverError(
      "palantir \(pid) did not come to the front; \(front?.localizedName ?? "nothing") (\(front?.processIdentifier ?? -1)) is frontmost"
    )
  }

  /// Runs `input` with palantir frontmost, and with `raising` its window on top. When another app
  /// was in front it gets the front back on every exit, once palantir has handled the input, so an
  /// agent takes the person's focus only while its input lasts. Menu validation and key
  /// equivalents need palantir active, as they do for a person.
  func borrowingFocus(raising: Bool = false, _ input: () throws -> Void) throws {
    guard !isFrontmost, let previous = NSWorkspace.shared.frontmostApplication else {
      try activate(raising: raising)
      return try input()
    }
    try Borrow.run(
      from: previous.processIdentifier, record: FrontRecord(palantir: pid),
      activate: { try activate(raising: raising) }, input: input,
      giveBack: { app in
        // An accessibility request is answered on palantir's main thread, after the events
        // queued before it.
        _ = Accessibility.value(element, kAXFocusedUIElementAttribute)
        return giveFront(to: app)
      })
  }

  /// Brings palantir to the front and records the app that was there, for `restore()`.
  func activateRemembering() throws {
    if !isFrontmost, let previous = NSWorkspace.shared.frontmostApplication {
      try FrontRecord(palantir: pid).save(previous.processIdentifier)
    }
    try activate()
  }

  /// Gives the front back to the app `activateRemembering()` or a failed borrow recorded, or to
  /// `app`.
  func restore(to app: pid_t? = nil) throws {
    try Borrow.restore(record: FrontRecord(palantir: pid), to: app, giveBack: giveFront)
  }

  /// Gives the front to `app` if palantir has it, and answers whether `app` is frontmost now. The
  /// front of a third app, which the person moved to, is left alone.
  private func giveFront(to app: pid_t) -> Bool {
    switch Borrow.step(
      front: NSWorkspace.shared.frontmostApplication?.processIdentifier, palantir: pid,
      previous: app)
    {
    case .done: true
    case .bringBack: Self.bringToFront(app)
    case .leave: false
    }
  }

  /// Makes `pid` the frontmost app and answers whether it became so in time.
  private static func bringToFront(_ pid: pid_t) -> Bool {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    let deadline = Date().addingTimeInterval(activationTimeout)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
      guard Date() < deadline else { return false }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
  }

  /// Whether palantir is the frontmost app and its focused window is on top in the middle of its
  /// content: switching apps briefly lays other windows over it.
  private var isInFront: Bool {
    guard isFrontmost, focusedWindow != nil, let content = try? contentFrame() else { return false }
    return ownsTopWindow(at: CGPoint(x: content.midX, y: content.midY))
  }

  /// Fails unless palantir is frontmost; input is sent only then.
  func requireFrontmost() throws {
    guard isFrontmost else {
      throw DriverError(
        "palantir \(pid) is not in front, so the rest of the input was not sent; read the state and run the command again"
      )
    }
  }

  var focusedWindow: AXUIElement? {
    guard let window = Accessibility.value(element, kAXFocusedWindowAttribute),
      CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    return (window as! AXUIElement)
  }

  /// The screen rect of the focused window's content: the area under its title bar.
  func contentFrame() throws -> CGRect {
    guard let window = focusedWindow else { throw DriverError("palantir has no focused window") }
    let frame = try Accessibility.frame(window)
    let content =
      Accessibility.children(window).first {
        Accessibility.string($0, kAXRoleAttribute) == kAXScrollAreaRole
      }
    return try content.map(Accessibility.frame) ?? frame
  }

  /// Whether the topmost window at `point`, in screen points from the top-left, is palantir's. The
  /// transparent full-screen windows the Dock and Notification Center keep above everything do not
  /// count.
  func ownsTopWindow(at point: CGPoint) -> Bool {
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    var count: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(UInt32(displays.count), &displays, &count)
    return TopWindow.owner(
      at: point,
      in: windows.compactMap { info in
        var bounds = CGRect.null
        guard let dictionary = info[kCGWindowBounds as String] as! CFDictionary?,
          CGRectMakeWithDictionaryRepresentation(dictionary, &bounds),
          let owner = info[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }
        return TopWindow.Info(
          owner: owner,
          ownerBundleID: NSRunningApplication(processIdentifier: owner)?.bundleIdentifier,
          layer: info[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds)
      },
      displays: displays.prefix(Int(count)).map(CGDisplayBounds),
      cursorLayer: Int(CGWindowLevelForKey(.cursorWindow))) == pid
  }

  /// The CoreGraphics id of palantir's frontmost normal window.
  func windowID() throws -> CGWindowID {
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    for info in windows
    where info[kCGWindowOwnerPID as String] as? pid_t == pid
      && info[kCGWindowLayer as String] as? Int == 0
    {
      if let id = info[kCGWindowNumber as String] as? CGWindowID { return id }
    }
    throw DriverError("palantir \(pid) has no window on screen")
  }
}

struct DriverError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

/// The app to give the front back to after palantir took it, kept in a file so that a later
/// `palantir-drive restore` finds it when giving it back failed.
struct FrontRecord {
  let url: URL

  init(palantir pid: pid_t, in directory: URL = FileManager.default.temporaryDirectory) {
    url = directory.appending(path: "palantir-drive-\(pid).front")
  }

  func save(_ app: pid_t) throws {
    try String(app).write(to: url, atomically: true, encoding: .utf8)
  }

  var saved: pid_t? { (try? String(contentsOf: url, encoding: .utf8)).flatMap { pid_t($0) } }

  func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Taking the front for input and giving it back.
enum Borrow {
  /// Runs `activate` then `input`, with the front taken from `previous`. The record is written
  /// before anything else and removed only once `giveBack` brought `previous` to the front, which
  /// runs on every exit, so a failure at any step leaves something `restore` can give back from.
  static func run(
    from previous: pid_t, record: FrontRecord, activate: () throws -> Void,
    input: () throws -> Void, giveBack: (pid_t) -> Bool
  ) throws {
    try record.save(previous)
    var failure: (any Error)?
    do {
      try activate()
      try input()
    } catch {
      failure = error
    }
    if giveBack(previous) {
      record.clear()
    } else {
      let notBack =
        "the front did not go back to pid \(previous); palantir-drive restore tries again"
      failure = DriverError(failure.map { "\($0); \(notBack)" } ?? notBack)
    }
    if let failure { throw failure }
  }

  /// Gives the front back to `app`, or to the recorded app; the record goes only once `giveBack`
  /// found that app frontmost.
  static func restore(record: FrontRecord, to app: pid_t?, giveBack: (pid_t) -> Bool) throws {
    guard let previous = app ?? record.saved else {
      throw DriverError("palantir-drive recorded no app to give the front back to")
    }
    guard giveBack(previous) else {
      throw DriverError("pid \(previous) is not frontmost again; the record is kept")
    }
    record.clear()
  }

  /// What giving the front back to `previous` takes while `front` is frontmost.
  enum Step: Equatable {
    /// `previous` is frontmost already.
    case done
    /// palantir has the front: hand it to `previous`.
    case bringBack
    /// A third app has it, one the person moved to; it is not palantir's to give.
    case leave
  }

  static func step(front: pid_t?, palantir: pid_t, previous: pid_t) -> Step {
    if front == previous { return .done }
    return front == palantir ? .bringBack : .leave
  }
}

/// Which window is on top at a point of the screen.
enum TopWindow {
  /// An on-screen window, as the window server lists it.
  struct Info: Equatable {
    var owner: pid_t
    var ownerBundleID: String?
    var layer: Int
    var bounds: CGRect
  }

  /// The apps whose windows above the normal layer can span a whole display without showing
  /// anything: the Dock's, whenever it does not autohide, and Notification Center's.
  static let overlayOwners: Set<String> = ["com.apple.dock", "com.apple.notificationcenterui"]

  /// The pid that owns the topmost window at `point`, given `windows` front to back, or nil when
  /// none does. The pointer, a window above `cursorLayer`, is not a window, and neither is an
  /// overlay: a window of `overlayOwners` above layer 0 that covers a whole display.
  static func owner(
    at point: CGPoint, in windows: [Info], displays: [CGRect], cursorLayer: Int
  ) -> pid_t? {
    windows.first { window in
      guard window.layer < cursorLayer, window.bounds.contains(point) else { return false }
      return !isOverlay(window, displays: displays)
    }?.owner
  }

  private static func isOverlay(_ window: Info, displays: [CGRect]) -> Bool {
    guard window.layer > 0, let bundleID = window.ownerBundleID, overlayOwners.contains(bundleID)
    else { return false }
    return displays.contains { window.bounds.contains($0) }
  }
}
