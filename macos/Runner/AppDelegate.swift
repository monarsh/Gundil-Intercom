import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var launchedAtLogin = false

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Started by the login item (Settings > Start automatically at login).
    let event = NSAppleEventManager.shared().currentAppleEvent
    launchedAtLogin =
      event?.eventID == AEEventID(kAEOpenApplication)
      && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        == OSType(keyAELaunchedAsLogInItem)
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // (FlutterAppDelegate has no applicationDidFinishLaunching: no super.)
    // At login: straight to the menu bar, ready to receive.
    if launchedAtLogin && MenuBar.shared.enabled { MenuBar.shared.hideWindow() }
  }

  // With "Keep running in the menu bar" on, closing the window doesn't quit.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !MenuBar.shared.enabled || MenuBar.shared.quitting
  }

  // Clicking the Dock icon (or opening the app again) shows the window.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { MenuBar.shared.showWindow() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
