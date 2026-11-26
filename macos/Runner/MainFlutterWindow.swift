import AVFoundation
import Cocoa
import FlutterMacOS
import ServiceManagement
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var platformChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Gundil Intercom"

    RegisterGeneratedPlugins(registry: flutterViewController)

    // "p2p_intercom/platform" (lib/src/platform_bridge.dart): only the
    // microphone permission on macOS; the rest is Android-only.
    let ch = FlutterMethodChannel(
      name: "p2p_intercom/platform",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "requestMicrophone":
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
          result(true)
        case .notDetermined:
          AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { result(granted) }
          }
        default:
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    platformChannel = ch

    MenuBar.shared.attach(
      window: self, messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// "Keep running in the menu bar": minimize hides the window to the menu
  /// bar instead of the Dock.
  override func miniaturize(_ sender: Any?) {
    if MenuBar.shared.enabled {
      MenuBar.shared.hideWindow()
    } else {
      super.miniaturize(sender)
    }
  }
}

/// The menu bar icon and running in the background on macOS, the
/// counterpart of the Windows / Linux tray ("gundil/window" channel,
/// lib/src/window_bridge.dart):
/// * a menu bar icon with the status ("Gate is speaking"), Open and Quit;
/// * with "Keep running in the menu bar" on, minimize and the close button
///   hide the window (and its Dock icon) and the intercom keeps receiving;
/// * App Nap is off, so talk plays at once while the window is hidden;
/// * notifications while the window is hidden ("Gate wants to talk");
/// * the login item (macOS 13+): launched at login it starts hidden.
final class MenuBar: NSObject, NSWindowDelegate, UNUserNotificationCenterDelegate {
  static let shared = MenuBar()

  private static let enabledKey = "gundil.menuBar"

  private weak var window: NSWindow?
  private var channel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private let statusLine = NSMenuItem(title: "Gundil Intercom", action: nil, keyEquivalent: "")
  private var activity: NSObjectProtocol?
  private var askedNotifications = false

  /// "Quit" was chosen: closing and terminating really quit.
  private(set) var quitting = false

  /// "Keep running in the menu bar" (from Dart; remembered here too, so a
  /// launch at login can start hidden before Dart runs). On by default.
  var enabled: Bool {
    get { UserDefaults.standard.object(forKey: MenuBar.enabledKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: MenuBar.enabledKey) }
  }

  func attach(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    window.delegate = self
    window.isReleasedWhenClosed = false

    let ch = FlutterMethodChannel(name: "gundil/window", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch

    // The intercom must answer at once while hidden: no App Nap. The Mac
    // may still sleep when idle.
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Receiving intercom calls")

    UNUserNotificationCenter.current().delegate = self
    makeStatusItem()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "trayAvailable":
      result(true)
    case "setTrayEnabled":
      enabled = call.arguments as? Bool ?? true
      result(nil)
    case "setTooltip":
      let text = call.arguments as? String ?? "Gundil Intercom"
      statusItem?.button?.toolTip = text
      statusLine.title = text
      result(nil)
    case "notify":
      let args = call.arguments as? [String: Any]
      notify(title: args?["title"] as? String ?? "Gundil Intercom",
             text: args?["text"] as? String ?? "")
      result(nil)
    case "show":
      showWindow()
      result(nil)
    case "revealFile":
      // Self-update: the new version, downloaded to Downloads.
      if let path = call.arguments as? String {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
      result(nil)
    case "getLoginItem":
      if #available(macOS 13.0, *) {
        result(SMAppService.mainApp.status == .enabled)
      } else {
        result(nil)
      }
    case "setLoginItem":
      let on = call.arguments as? Bool ?? false
      if #available(macOS 13.0, *) {
        do {
          if on {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
        } catch {
          NSLog("Login item: \(error)")
        }
        result(SMAppService.mainApp.status == .enabled)
      } else {
        result(false)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Menu bar icon

  private func makeStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(
        systemSymbolName: "antenna.radiowaves.left.and.right",
        accessibilityDescription: "Gundil Intercom")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "Gundil Intercom"
    }
    let menu = NSMenu()
    statusLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(.separator())
    let open = NSMenuItem(title: "Open Gundil Intercom", action: #selector(openClicked), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    let quit = NSMenuItem(title: "Quit Gundil Intercom", action: #selector(quitClicked), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  @objc private func openClicked() { showWindow() }

  @objc private func quitClicked() {
    quitting = true
    NSApp.terminate(nil)
  }

  // MARK: Window

  /// Hides the window and its Dock icon; the menu bar icon stays.
  func hideWindow() {
    window?.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  func showWindow() {
    NSApp.setActivationPolicy(.regular)
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  var windowShown: Bool {
    guard let w = window else { return false }
    return w.isVisible && !w.isMiniaturized
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if enabled && !quitting {
      hideWindow()
      return false
    }
    return true
  }

  // MARK: Notifications

  private func notify(title: String, text: String) {
    // Only while the window isn't visible (the app shows it itself).
    guard !windowShown else { return }
    let center = UNUserNotificationCenter.current()
    let post = {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = text
      content.sound = .default
      center.add(UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil))
    }
    if askedNotifications {
      post()
    } else {
      askedNotifications = true
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        if granted { DispatchQueue.main.async(execute: post) }
      }
    }
  }

  // Shown even while the app is in front (it only notifies when hidden).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  // Clicking a notification opens the window.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    DispatchQueue.main.async { self.showWindow() }
    completionHandler()
  }
}
