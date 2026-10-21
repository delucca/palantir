import AppKit
import ApplicationServices

let usage = """
  usage: palantir-drive [--pid <pid>] <command>

  Uses a running palantir like a person, from outside: menu items through the accessibility tree,
  keys, clicks and scrolls as system events, sent only while palantir is in front.

    menus                      every menu bar item: path, enabled or disabled, press or not,
                               key equivalent or -
    menu <path>                presses a menu item, such as "View > Fold All"
    key [--system] <chord>...  presses keys, such as cmd+a down shift+pagedown
    type [--system] <text>     types text, a key event per character
    choose <file>              answers the open panel File > Open… shows with an absolute path
    click <x> <y> [--count n]  clicks in window points from the content's top-left corner
    scroll <lines>             scrolls the window's content, down when positive
    capture <out.png>          the window as the screen shows it, title bar included
    tree                       the focused window's accessibility tree
    restore [--to <pid>]       gives the front back to the app a failed command recorded, or to
                               the app with that pid
    activate                   brings palantir to the front and records the app it took it from

  Each command that sends input takes the front when another app has it, sends the input, waits
  for palantir to take it, and gives the front back on every exit; when giving it back fails it
  says so and keeps a record for restore. Keys go to palantir's own queue; key --system,
  type --system, click and scroll go through the system's event stream, which reaches whichever
  app is in front, and --system refuses Command keys, which could quit, close or hide another
  app if they landed late. Without --pid it uses the only palantir running.
  """

func run(_ arguments: [String]) throws {
  var arguments = arguments
  func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
  }
  func option(_ name: String) throws -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { throw Usage("\(name) needs a value") }
    defer { arguments.removeSubrange(index...(index + 1)) }
    return arguments[index + 1]
  }
  let pid = try option("--pid").map { try Arguments.pid($0, option: "--pid") }
  guard let command = arguments.first else { throw Usage("no command") }
  arguments.removeFirst()
  if command == "key", arguments.contains("--system") {
    for chord in try arguments.filter({ $0 != "--system" }).map(Chord.init) {
      do { try Input.checkSystemStream(chord, forPanel: false) } catch {
        throw Usage("key --system takes no Command keys; send those without --system")
      }
    }
  }
  guard AXIsProcessTrusted() else {
    throw DriverError(
      "the app this runs under has no Accessibility grant; grant it in System Settings > Privacy & Security"
    )
  }
  let palantir = try Palantir.find(pid: pid)
  switch command {
  case "activate":
    try Arguments.noneLeft(arguments, for: command)
    try palantir.activateRemembering()
  case "restore":
    let app = try option("--to").map { try Arguments.pid($0, option: "--to") }
    try Arguments.noneLeft(arguments, for: command)
    try palantir.restore(to: app)
  case "menus":
    try Arguments.noneLeft(arguments, for: command)
    for item in try MenuBar(of: palantir).items {
      print(
        [
          item.title, item.isEnabled ? "enabled" : "disabled", item.canPress ? "press" : "no-press",
          item.keyEquivalent,
        ].joined(separator: "\t"))
    }
  case "menu":
    guard arguments.count == 1 else { throw Usage("menu takes one path") }
    try palantir.borrowingFocus { try MenuBar(of: palantir).press(arguments[0]) }
  case "key":
    let input = Input(palantir: palantir, system: flag("--system"))
    let chords = try arguments.map(Chord.init)
    guard !chords.isEmpty else { throw Usage("key needs a chord") }
    try send(input) { for chord in chords { try input.press(chord) } }
  case "type":
    let input = Input(palantir: palantir, system: flag("--system"))
    guard arguments.count == 1 else { throw Usage("type takes one text") }
    try send(input) { try input.type(arguments[0]) }
  case "choose":
    guard arguments.count == 1, arguments[0].hasPrefix("/") else {
      throw Usage("choose takes an absolute path")
    }
    try palantir.borrowingFocus(raising: true) {
      let route = try OpenPanel(palantir: palantir).choose(arguments[0])
      FileHandle.standardError.write(Data("palantir-drive: chose \(arguments[0]): \(route)\n".utf8))
    }
  case "click":
    let count = try option("--count").map {
      guard let count = Int($0), count > 0 else { throw Usage("--count \($0)") }
      return count
    }
    guard arguments.count == 2, let x = Double(arguments[0]), let y = Double(arguments[1]) else {
      throw Usage("click takes x and y")
    }
    try palantir.borrowingFocus(raising: true) {
      try Input(palantir: palantir, system: true).click(at: CGPoint(x: x, y: y), count: count ?? 1)
    }
  case "scroll":
    guard arguments.count == 1 else { throw Usage("scroll takes a number of lines") }
    let lines = try Arguments.scrollLines(arguments[0])
    try palantir.borrowingFocus(raising: true) {
      try Input(palantir: palantir, system: true).scroll(lines: lines)
    }
  case "capture":
    guard arguments.count == 1 else { throw Usage("capture takes a file") }
    try palantir.borrowingFocus(raising: true) {
      let screencapture = Process()
      screencapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      screencapture.arguments = ["-x", "-o", "-l", String(try palantir.windowID()), arguments[0]]
      try screencapture.run()
      screencapture.waitUntilExit()
      guard screencapture.terminationStatus == 0 else {
        throw DriverError("screencapture failed; the app this runs under needs Screen Recording")
      }
    }
  case "tree":
    try Arguments.noneLeft(arguments, for: command)
    guard let window = palantir.focusedWindow else { throw DriverError("no focused window") }
    print(Accessibility.describe(window).joined(separator: "\n"))
  default:
    throw Usage("no command \(command)")
  }
}

/// Sends keys with the front borrowed: to palantir's own queue, or through the system's event
/// stream to palantir's key window, raised.
func send(_ input: Input, _ body: () throws -> Void) throws {
  try input.palantir.borrowingFocus(raising: input.system, body)
}

struct Usage: Error {
  let message: String

  init(_ message: String) { self.message = message }
}

do {
  try run(Array(CommandLine.arguments.dropFirst()))
} catch let error as Usage {
  FileHandle.standardError.write(Data("palantir-drive: \(error.message)\n\n\(usage)\n".utf8))
  exit(64)
} catch {
  FileHandle.standardError.write(Data("palantir-drive: \(error)\n".utf8))
  exit(1)
}
