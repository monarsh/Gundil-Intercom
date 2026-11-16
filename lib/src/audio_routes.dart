import 'package:flutter/foundation.dart';

import 'package:intercom_core/intercom_core.dart' show IntercomAudio;

import 'platform_bridge.dart';

/// Kind of audio output on Android.
enum AudioRouteType { speaker, earpiece, bluetooth, wired, other }

/// One selectable audio output (e.g. "Speaker", "Galaxy Buds").
class AudioRoute {
  const AudioRoute({required this.id, required this.type, required this.name});

  final String id;
  final AudioRouteType type;
  final String name;

  static AudioRoute? fromMap(Object? m) {
    if (m is! Map) return null;
    final id = m['id'], name = m['name'];
    if (id is! String) return null;
    return AudioRoute(
      id: id,
      type: switch (m['type']) {
        'speaker' => AudioRouteType.speaker,
        'earpiece' => AudioRouteType.earpiece,
        'bluetooth' => AudioRouteType.bluetooth,
        'wired' => AudioRouteType.wired,
        _ => AudioRouteType.other,
      },
      name: name is String && name.isNotEmpty ? name : id,
    );
  }
}

/// One microphone Android offers.
class AudioInput {
  const AudioInput({required this.id, required this.type, required this.name});

  /// Android's device id (changes when a device is plugged in again).
  final String id;

  /// 'builtin', 'wired', 'usb' or 'bluetooth'.
  final String type;
  final String name;

  /// What is remembered as the user's choice: survives re-plugging.
  String get key => '$type|$name';

  static AudioInput? fromMap(Object? m) {
    if (m is! Map) return null;
    final id = m['id'], type = m['type'], name = m['name'];
    if (id is! String || type is! String || name is! String) return null;
    return AudioInput(id: id, type: type, name: name);
  }
}

/// Android audio-output picker state: available outputs and the current
/// one, kept in sync with the phone (headset connected / removed, ...).
class AudioRoutes extends ChangeNotifier {
  AudioRoutes() {
    PlatformBridge.onAudioRoutesChanged(apply);
  }

  /// The app-wide instance (only meaningful on Android).
  static final AudioRoutes instance = AudioRoutes();

  List<AudioRoute> _routes = const [];
  String? _currentId;
  bool _active = false;

  List<AudioRoute> get routes => _routes;

  // ---------------------------------------------------------- microphones

  List<AudioInput> _inputs = const [];
  String _micChoice = '';
  int _micDevice = 0;
  bool _bluetoothTried = false;

  /// Sets the native microphone device (Android id, 0 = automatic).
  @visibleForTesting
  void Function(int deviceId) setNativeMic = (id) =>
      IntercomAudio.instance.setAndroidDevice(0, id);

  /// Called when the microphone must be opened again (a call is running).
  void Function()? onMicChanged;

  /// The microphones to choose from.
  List<AudioInput> get inputs => _inputs;

  /// The chosen microphone ([AudioInput.key]); '' = automatic: the
  /// microphone that belongs to the sound output.
  String get micChoice => _micChoice;

  /// Chooses the microphone; takes effect at once.
  void setMicChoice(String key) {
    _micChoice = key;
    _bluetoothTried = false;
    _applyMic();
    notifyListeners();
  }

  /// The chosen microphone, if it is plugged in right now.
  AudioInput? get chosenInput {
    if (_micChoice.isEmpty) return null;
    final type = _micChoice.split('|').first;
    return _inputs.where((i) => i.key == _micChoice).firstOrNull ??
        _inputs.where((i) => i.type == type).firstOrNull;
  }

  void _applyMic() {
    final input = chosenInput;
    var device = 0;
    if (input != null && input.type == 'bluetooth') {
      // A Bluetooth microphone only works together with the Bluetooth
      // output (that is how Android's call audio works): switch to it.
      final bt = _routes
          .where((r) => r.type == AudioRouteType.bluetooth)
          .firstOrNull;
      if (!_active) _bluetoothTried = false;
      if (_active && bt != null && bt.id != _currentId && !_bluetoothTried) {
        _bluetoothTried = true; // Once per call: the user may switch away.
        select(bt);
      }
    } else if (input != null) {
      device = int.tryParse(input.id) ?? 0;
    }
    if (device == _micDevice) return;
    _micDevice = device;
    try {
      setNativeMic(device);
    } catch (_) {
      return; // Audio library not available (tests).
    }
    if (_active) onMicChanged?.call();
  }

  /// Call audio is running (outputs only matter then).
  bool get active => _active;

  AudioRoute? get current =>
      _routes.where((r) => r.id == _currentId).firstOrNull;

  /// Applies a state map from Android.
  @visibleForTesting
  void apply(Map<Object?, Object?> state) {
    final list = state['routes'];
    _routes = list is List
        ? list.map(AudioRoute.fromMap).whereType<AudioRoute>().toList()
        : const [];
    final cur = state['current'];
    _currentId = cur is String ? cur : null;
    _active = state['active'] == true;
    final inputs = state['inputs'];
    if (inputs is List) {
      _inputs = inputs.map(AudioInput.fromMap).whereType<AudioInput>().toList();
    }
    _applyMic();
    notifyListeners();
  }

  Future<void> refresh() async {
    final s = await PlatformBridge.getAudioRoutes();
    if (s != null) apply(s);
  }

  Future<void> select(AudioRoute route) async {
    final s = await PlatformBridge.setAudioRoute(route.id);
    if (s != null) apply(s);
  }
}
