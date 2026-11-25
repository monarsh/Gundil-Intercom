import 'dart:io';

import 'package:flutter/services.dart';

import 'package:intercom_core/intercom_core.dart';

/// Thin bridge to Android-only platform features implemented in
/// `MainActivity.kt`. Every call is a no-op on desktop platforms.
class PlatformBridge {
  static const MethodChannel _channel = MethodChannel('p2p_intercom/platform');

  static bool get _android => Platform.isAndroid;

  /// Requests RECORD_AUDIO at runtime. Returns true when granted.
  static Future<bool> requestMicrophone() async {
    // iOS and macOS answer this one too (AppDelegate / MainFlutterWindow).
    if (!_android && !Platform.isIOS && !Platform.isMacOS) return true;
    try {
      return await _channel.invokeMethod<bool>('requestMicrophone') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Puts Android audio into voice-communication mode (enables the phone's
  /// echo canceller) and picks the output (see [getAudioRoutes]). On
  /// Android and iPhone this also turns on ear detection: held to the ear,
  /// the call moves to the earpiece.
  static Future<void> startCallAudio() => _invokePhone('startCallAudio');
  static Future<void> stopCallAudio() => _invokePhone('stopCallAudio');

  /// Android and iOS (AppDelegate.swift) both implement these.
  static Future<void> _invokePhone(String method) async {
    if (!_android && !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // Best effort.
    } on MissingPluginException {
      // Running in a test harness.
    }
  }

  /// Audio outputs: `{"active", "routes": [{"id","type","name"}], "current"}`.
  static Future<Map<Object?, Object?>?> getAudioRoutes() =>
      _map('getAudioRoutes');

  /// Switches the output; returns the new state.
  static Future<Map<Object?, Object?>?> setAudioRoute(String id) =>
      _map('setAudioRoute', {'id': id});

  /// Called by Android whenever outputs or the current output change.
  static void onAudioRoutesChanged(
    void Function(Map<Object?, Object?> state) handler,
  ) {
    if (!_android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'audioRoutesChanged' && call.arguments is Map) {
        handler(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
  }

  static Future<Map<Object?, Object?>?> _map(
    String method, [
    Object? args,
  ]) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<Map<Object?, Object?>>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Updates the background notification (Android background mode):
  /// e.g. "Connected with Gate". Empty title = back to "ready".
  static Future<void> setStatus(String title, String text) =>
      _invoke('setStatus', {'title': title, 'text': text});

  /// Android: whether the phone is on Wi-Fi or mobile data (a VPN counts
  /// as what it runs over). [NetworkKind.unknown] elsewhere.
  static Future<NetworkKind> networkKind() async {
    if (!_android) return NetworkKind.unknown;
    try {
      return switch (await _channel.invokeMethod<String>('networkKind')) {
        'wifi' => NetworkKind.wifi,
        'mobile' => NetworkKind.mobile,
        _ => NetworkKind.unknown,
      };
    } on PlatformException {
      return NetworkKind.unknown;
    } on MissingPluginException {
      return NetworkKind.unknown;
    }
  }

  /// Many Android devices drop broadcast/multicast packets unless a Wi-Fi
  /// multicast lock is held.
  static Future<void> acquireMulticastLock() => _invoke('acquireMulticastLock');
  static Future<void> releaseMulticastLock() => _invoke('releaseMulticastLock');

  // ---------------------------------------------- background mode (phones)

  /// "Run in background" exists here: Android (a background service with a
  /// notification) and iPhone (a silent audio loop keeps the app running).
  static bool hasBackgroundMode = Platform.isAndroid || Platform.isIOS;

  /// Whether background mode is on.
  static Future<bool> getBackground() => _getPhone('getBackground');

  /// Turns background mode on/off and remembers the choice.
  static Future<bool> setBackground(bool enabled) =>
      _getPhone('setBackground', {'enabled': enabled});

  static Future<bool> _getPhone(String method, [Object? args]) async {
    if (!_android && !Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Whether the background service starts after the phone boots.
  static Future<bool> getStartOnBoot() => _get('getStartOnBoot');
  static Future<bool> setStartOnBoot(bool enabled) =>
      _get('setStartOnBoot', {'enabled': enabled});

  /// Android 13+: permission to show the background notification.
  static Future<bool> requestNotifications() => _get('requestNotifications');

  static Future<bool> isIgnoringBatteryOptimizations() =>
      _get('isIgnoringBatteryOptimizations');

  /// Opens the system prompt to exempt the app from battery optimization,
  /// so Android doesn't cut its network while the screen is off.
  static Future<void> requestIgnoreBatteryOptimizations() =>
      _invoke('requestIgnoreBatteryOptimizations');

  static Future<bool> _get(String method, [Object? args]) async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> _invoke(String method, [Object? args]) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // Best effort.
    } on MissingPluginException {
      // Running in a test harness.
    }
  }
}

/// Android implementations of the engine's platform hooks.
class FlutterPlatformHooks extends PlatformHooks {
  const FlutterPlatformHooks();

  @override
  Future<bool> requestMicrophone() => PlatformBridge.requestMicrophone();

  @override
  Future<void> acquireMulticastLock() => PlatformBridge.acquireMulticastLock();

  @override
  Future<void> releaseMulticastLock() => PlatformBridge.releaseMulticastLock();

  @override
  Future<void> startCallAudio() => PlatformBridge.startCallAudio();

  @override
  Future<void> stopCallAudio() => PlatformBridge.stopCallAudio();

  @override
  Future<NetworkKind> networkKind() => PlatformBridge.networkKind();
}
