import AppKit
import UniformTypeIdentifiers

@main
enum App {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    MainMenu.install(in: app)
    withExtendedLifetime(delegate) { app.run() }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private(set) lazy var notebook = NotebookWindowController()
  var chooseNotebook: @MainActor () -> URL? = AppDelegate.runOpenPanel
  var presentNotebook: @MainActor (NotebookWindowController) -> Void = { $0.showWindow(nil) }
  var presentError: @MainActor (any Error) -> Void = { _ = NSApp.presentError($0) }

  func applicationDidFinishLaunching(_ notification: Notification) {
    notebook.window?.center()
    notebook.showWindow(nil)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  @objc func openDocument(_ sender: Any?) {
    guard let url = chooseNotebook() else { return }
    do {
      try notebook.open(url)
      presentNotebook(notebook)
    } catch {
      presentError(error)
    }
  }

  private static func runOpenPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.markdown]
    return panel.runModal() == .OK ? panel.url : nil
  }
}
