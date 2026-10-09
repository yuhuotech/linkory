import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    migrateSandboxPreferences()
    super.applicationWillFinishLaunching(notification)
  }

  /// Earlier builds were sandboxed and kept their settings (server, device identity, sign-in) inside
  /// ~/Library/Containers/<bundle id>. This build is not sandboxed, so bring those preferences over
  /// once, before Flutter reads them.
  private func migrateSandboxPreferences() {
    if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return }  // still sandboxed
    guard let id = Bundle.main.bundleIdentifier else { return }
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let old = home.appendingPathComponent("Library/Containers/\(id)/Data/Library/Preferences/\(id).plist")
    let new = home.appendingPathComponent("Library/Preferences/\(id).plist")
    guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
    try? fm.copyItem(at: old, to: new)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the window hides to the tray; the app keeps running (PRD 4.10).
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows { window.makeKeyAndOrderFront(self) }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
