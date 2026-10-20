import AppKit
import PalantirNotebookUI

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
    panel.allowedContentTypes = NotebookWindowController.readableContentTypes
    return panel.runModal() == .OK ? panel.url : nil
  }
}
