import AppKit

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
