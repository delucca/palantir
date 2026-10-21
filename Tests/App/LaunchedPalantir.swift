import AppKit
import ApplicationServices
import Foundation
import PalantirInspector
import Testing

extension Trait where Self == ConditionTrait {
  /// Runs a test that launches palantir only when `LaunchedPalantir.allowed`.
  static var launchesPalantir: Self {
    .enabled(if: LaunchedPalantir.allowed, "it launches palantir; run it with just test-desktop")
  }
}

/// A palantir executable started by a test in the background, so that it takes no focus, and
/// quit when the test ends.
final class LaunchedPalantir {
  let application: NSRunningApplication
  var pid: pid_t { application.processIdentifier }
  private let bundle: URL

  /// How long a launch may take to show its window.
  static let launchTimeout = 10.0

  /// Whether tests may launch palantir: only under `just test-desktop`, which sets
  /// `PALANTIR_DESKTOP_TESTS=1`, since each launch puts a palantir window on the person's desktop.
  static var allowed: Bool { ProcessInfo.processInfo.environment["PALANTIR_DESKTOP_TESTS"] == "1" }

  /// Launches `executable` from an app bundle of its own, with `arguments`.
  init(_ executable: URL, arguments: [String] = []) async throws {
    guard Self.allowed else {
      throw LaunchError("a test that launches palantir needs the .launchesPalantir trait")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    bundle = FileManager.default.temporaryDirectory.appending(
      path: "\(UUID().uuidString)/palantir.app", directoryHint: .isDirectory)
    let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: executable, to: macOS.appending(path: "palantir"))
    try FileManager.default.copyItem(
      at: root.appending(path: "Sources/App/Info.plist"),
      to: bundle.appending(path: "Contents/Info.plist"))
    let front = NSWorkspace.shared.frontmostApplication
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    configuration.arguments = arguments
    application = try await NSWorkspace.shared.openApplication(
      at: bundle, configuration: configuration)
    let deadline = Date().addingTimeInterval(Self.launchTimeout)
    while !hasWindow {
      guard Date() < deadline, kill(pid, 0) == 0 else {
        terminate()
        throw LaunchError("\(executable.path) showed no window within \(Self.launchTimeout) s")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    // A launch without the inspector flag activates palantir; give the front back.
    if let front, front.processIdentifier != pid,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    {
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(front.processIdentifier), kAXFrontmostAttribute as CFString,
        kCFBooleanTrue)
    }
  }

  deinit { terminate() }

  /// Whether the process has a normal window on screen, which it shows when it has finished
  /// launching.
  var hasWindow: Bool {
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return windows.contains {
      $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
    }
  }

  var socket: URL { SocketDirectory.socket(for: pid) }

  func terminate() {
    if kill(pid, 0) == 0 {
      application.forceTerminate()
      let deadline = Date().addingTimeInterval(5)
      while kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
    }
    unlink(socket.path)
    try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
  }

  /// The executable that `swift build` made beside this test bundle.
  static func built(_ name: String) -> URL {
    Bundle(for: LaunchedPalantir.self).bundleURL.deletingLastPathComponent().appending(path: name)
  }
}

struct LaunchError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}
