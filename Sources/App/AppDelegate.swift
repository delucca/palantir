import AppKit
import Foundation
import PalantirNotebookUI

#if DEBUG
  import PalantirInspector
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
  private(set) lazy var notebook = NotebookWindowController()
  #if DEBUG
    private(set) var inspector: InspectorListener?
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    notebook.window?.center()
    #if DEBUG
      if CommandLine.arguments.contains(InspectorListener.launchFlag) {
        // An agent's palantir starts behind the person's windows without taking focus; its
        // driver brings it forward only for the input it sends.
        // The socket exists before the window does, so a caller that sees the window can connect.
        listen()
        notebook.window?.orderBack(nil)
        return
      }
    #endif
    notebook.showWindow(nil)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    #if DEBUG
      inspector?.stop()
    #endif
  }

  // The responder chain reaches the notebook window's controller only while that window is key
  // or main.
  @objc func openDocument(_ sender: Any?) { notebook.openDocument(sender) }

  #if DEBUG
    private func listen() {
      do {
        inspector = try InspectorListener(serving: makeInspector())
      } catch {
        NSLog("palantir: the inspector cannot listen: %@", "\(error)")
      }
    }
  #endif
}
