import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to the system tray of the desktop runners:
/// windows/runner/flutter_window.cpp, linux/runner/window_tray.cc and the
/// menu bar icon in macos/Runner/MainFlutterWindow.swift.
/// Every call is a no-op on other platforms.
class WindowBridge {
  static const MethodChannel _channel = MethodChannel('gundil/window');

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Whether a tray icon can be shown. Always on Windows and macOS (the
  /// menu bar); on Linux it needs
  /// libayatana-appindicator3 and a desktop with a tray (plain GNOME needs
  /// the AppIndicator extension). Without one the window just minimizes to
  /// the taskbar and closing quits.
  static Future<bool> trayAvailable() async {
    if (Platform.isWindows) return true;
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('trayAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// When on, minimize and the close button hide the window to the tray
  /// (the intercom keeps receiving); right-click the tray icon > Exit quits
  /// (macOS: the menu bar icon > Quit, or Cmd+Q).
  static Future<void> setTrayEnabled(bool enabled) =>
      _invoke('setTrayEnabled', enabled);

  /// Text shown when hovering the tray icon (max ~127 characters).
  static Future<void> setTooltip(String text) => _invoke('setTooltip', text);

  /// Shows a notification (Windows, Linux, macOS), only while the window
  /// is hidden or minimized.
  static Future<void> notify(String title, String text) =>
      _invoke('notify', {'title': title, 'text': text});

  /// Brings the window back from the tray.
  static Future<void> show() => _invoke('show');

  /// macOS 13+: the app as a login item (System Settings > General >
  /// Login Items). Null where it isn't available.
  static Future<bool?> getLoginItem() => _getBool('getLoginItem');
  static Future<bool?> setLoginItem(bool enabled) =>
      _getBool('setLoginItem', enabled);

  static Future<bool?> _getBool(String method, [Object? args]) async {
    if (!Platform.isMacOS) return null;
    try {
      return await _channel.invokeMethod<bool>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> _invoke(String method, [Object? args]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // Best effort.
    } on MissingPluginException {
      // Running in a test harness.
    }
  }
}
