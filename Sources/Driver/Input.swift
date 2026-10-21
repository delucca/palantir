import AppKit
import ApplicationServices
import CoreGraphics

/// Keys, text, clicks and scrolls as system events, sent only while palantir is frontmost.
struct Input {
  let palantir: Palantir
  /// Whether events go to the system's event stream instead of to palantir's own queue. A system
  /// panel such as File > Open… is another process's view in palantir's window and gets only these.
  let system: Bool
  /// The open panel this input answers, set only by `OpenPanel`: before each event, palantir's
  /// focused window must be the panel or its sheet, and Command-Shift-G goes through for the
  /// panel's Go to Folder sheet.
  var panel: AXUIElement? = nil

  /// The pause after each event, so palantir handles them one at a time.
  static let pause: useconds_t = 15_000
  /// How long the system may take to record a system-stream event.
  static let deliveryTimeout = 1.0

  /// Fails for a chord the system's event stream must not carry: any with Command, since one that
  /// lands after palantir lost the front could quit, close or hide the person's app. The one
  /// exception is Command-Shift-G for an open panel's Go to Folder sheet, sent by `choose`.
  static func checkSystemStream(_ chord: Chord, forPanel: Bool) throws {
    guard chord.flags.contains(.maskCommand), !(forPanel && chord == Chord.goToFolder) else {
      return
    }
    throw DriverError("Command keys go to palantir's own queue only; drop --system")
  }

  // Checking before each post narrows the race with a focus change; it cannot close it, since the
  // window server delivers the event to whichever app is in front by then.
  private func post(_ event: CGEvent) throws {
    try palantir.requireFrontmost()
    if let panel {
      guard let focused = palantir.focusedWindow,
        CFEqual(focused, panel)
          || Accessibility.children(panel).contains(where: { CFEqual($0, focused) })
      else {
        throw DriverError("the open panel is not palantir's focused window; nothing was sent")
      }
    }
    if system {
      let posted = Date()
      event.post(tap: .cghidEventTap)
      try delivered(event.type, postedAt: posted)
    } else {
      event.postToPid(palantir.pid)
    }
    usleep(Self.pause)
    guard palantir.isFrontmost else {
      throw DriverError("palantir stopped being frontmost while an event was sent")
    }
  }

  /// Waits until the system has recorded an event of `type` posted at `posted`: posting is
  /// asynchronous, and an event still in flight when the driver exits is lost now and then. A lost
  /// mouse-up leaves the button down for every app, and AppKit then holds back menu actions.
  private func delivered(_ type: CGEventType, postedAt posted: Date) throws {
    let deadline = Date().addingTimeInterval(Self.deliveryTimeout)
    while CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
      > Date().timeIntervalSince(posted)
    {
      guard Date() < deadline else {
        throw DriverError("the system did not take the event of type \(type.rawValue)")
      }
      usleep(1_000)
    }
  }

  func press(_ chord: Chord) throws {
    if system { try Self.checkSystemStream(chord, forPanel: panel != nil) }
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: chord.key, keyDown: down)
      else { throw DriverError("cannot make a key event") }
      event.flags = chord.flags
      try post(event)
    }
  }

  func type(_ text: String) throws {
    let source = CGEventSource(stateID: .privateState)
    for character in text {
      var units = Array(String(character).utf16)
      for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
          throw DriverError("cannot make a key event")
        }
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        try post(event)
      }
    }
  }

  /// Clicks at `point` in the focused window's content, in points from its top-left corner. Mouse
  /// events reach a window only through the system's event stream.
  func click(at point: CGPoint, count: Int) throws {
    let content = try palantir.contentFrame()
    let location = CGPoint(x: content.minX + point.x, y: content.minY + point.y)
    guard content.contains(location) else {
      throw DriverError("\(point.x),\(point.y) is outside the window's content")
    }
    // A click goes to whatever window is on top at its point, so that must be palantir's.
    guard palantir.ownsTopWindow(at: location) else {
      throw DriverError("another app's window covers \(point.x),\(point.y)")
    }
    let source = CGEventSource(stateID: .privateState)
    try Self.sendClicks(
      count: count,
      makeEvent: { type, click in
        let event = CGEvent(
          mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
          mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        return event
      },
      post: post,
      // Releasing needs no frontmost check: a button left down holds back every app's menus.
      release: { $0.post(tap: .cghidEventTap) })
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
      throw DriverError("the system still has the left mouse button down after the click")
    }
  }

  /// Sends `count` clicks, each a mouse-down and a mouse-up. Once a mouse-down was handed to `post`,
  /// the mouse-up reaches `release` on every exit, since a button left down is held for every app.
  static func sendClicks(
    count: Int, makeEvent: (CGEventType, Int) -> CGEvent?, post: (CGEvent) throws -> Void,
    release: (CGEvent) -> Void
  ) throws {
    for click in 1...count {
      guard let down = makeEvent(.leftMouseDown, click), let up = makeEvent(.leftMouseUp, click)
      else { throw DriverError("cannot make a mouse event") }
      do {
        try post(down)
        try post(up)
      } catch {
        release(up)
        throw error
      }
    }
  }

  /// Scrolls the window's content by `lines`, down when positive. Like a click, a scroll reaches
  /// the window under the pointer only through the system's event stream.
  func scroll(lines: Int32) throws {
    let content = try palantir.contentFrame()
    let centre = CGPoint(x: content.midX, y: content.midY)
    guard palantir.ownsTopWindow(at: centre) else {
      throw DriverError("another app's window covers the middle of palantir's window")
    }
    let source = CGEventSource(stateID: .privateState)
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: -lines, wheel2: 0,
        wheel3: 0)
    else { throw DriverError("cannot make a scroll event") }
    event.location = centre
    try post(event)
  }
}

/// A key with its modifiers, written like "cmd+shift+g" or "pagedown".
struct Chord: Equatable {
  var key: CGKeyCode
  var flags: CGEventFlags

  init(key: CGKeyCode, flags: CGEventFlags) {
    self.key = key
    self.flags = flags
  }

  init(_ text: String) throws {
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    for part in text.lowercased().split(separator: "+").map(String.init) {
      if let modifier = Self.modifiers[part] {
        flags.insert(modifier)
      } else if let code = Self.keys[part], key == nil {
        key = code
      } else {
        throw DriverError("\(text): unknown key \(part)")
      }
    }
    guard let key else { throw DriverError("\(text) names no key") }
    // AppKit reads arrows and the keys above them as function keys only with these flags.
    if Self.functionKeys.contains(key) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
    self.init(key: key, flags: flags)
  }

  /// Command-Shift-G, which opens the Go to Folder sheet of a system file panel.
  static let goToFolder = Chord(key: 5, flags: [.maskCommand, .maskShift])

  static let modifiers: [String: CGEventFlags] = [
    "cmd": .maskCommand, "shift": .maskShift, "opt": .maskAlternate, "ctrl": .maskControl,
  ]

  /// US-layout virtual key codes.
  static let keys: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "return": 36, "tab": 48, "space": 49,
    "delete": 51, "escape": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116,
    "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
  ]

  static let functionKeys: Set<CGKeyCode> = [115, 116, 117, 119, 121, 123, 124, 125, 126]
}
