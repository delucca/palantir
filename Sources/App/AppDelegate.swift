import AppKit
import Foundation
import PalantirNotebookUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private(set) lazy var notebook = NotebookWindowController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    notebook.window?.center()
    notebook.showWindow(nil)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  // The responder chain reaches the notebook window's controller only while that window is key
  // or main.
  @objc func openDocument(_ sender: Any?) { notebook.openDocument(sender) }
}
