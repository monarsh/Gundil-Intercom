import 'dart:typed_data';

import 'native_audio_bindings.dart';

/// Microphones or speakers (see [AudioEngine.devices]).
enum AudioDeviceKind { microphone, speaker }

/// One microphone or speaker the system offers.
class AudioDevice {
  const AudioDevice(this.name, {this.isDefault = false});
  final String name;

  /// The one the system uses when none is chosen.
  final bool isDefault;
}

/// Abstraction over the microphone/speaker so the intercom logic can be tested
/// without real audio hardware. Capture and playback are independent because
/// a walkie-talkie only ever does one of them at a time.
abstract class AudioEngine {
  int get sampleRate;
  void init(int sampleRate);

  void startCapture();
  void stopCapture();
  void startPlayback();
  void stopPlayback();

  /// Returns all microphone samples captured since the last call.
  Int16List readCaptured();

  /// Queues samples for the speaker.
  void play(Int16List samples);

  /// Samples waiting to be played.
  int get queued;

  /// Drops queued playback (used to cap latency).
  void flushPlayback();

  /// The microphones or speakers to choose from (after [init]). Empty when
  /// the platform picks devices itself (Android, tests).
  List<AudioDevice> devices(AudioDeviceKind kind) => const [];

  /// Uses the device called [name] the next time capture / playback starts
  /// ('' = the system default).
  void selectDevice(AudioDeviceKind kind, String name) {}
}

/// Real audio through the native `intercom_audio` FFI plugin.
class NativeAudioEngine extends AudioEngine {
  IntercomAudio get _a => IntercomAudio.instance;
  int _rate = 16000;

  @override
  int get sampleRate => _rate;

  @override
  void init(int sampleRate) {
    _rate = sampleRate;
    _a.init(sampleRate);
  }

  @override
  void startCapture() => _a.startCapture();
  @override
  void stopCapture() => _a.stopCapture();
  @override
  void startPlayback() => _a.startPlayback();
  @override
  void stopPlayback() => _a.stopPlayback();

  @override
  Int16List readCaptured() => _a.readCapture();

  @override
  void play(Int16List samples) => _a.writePlayback(samples);

  @override
  int get queued => _a.playbackQueued;

  @override
  void flushPlayback() => _a.clearPlayback();

  @override
  List<AudioDevice> devices(AudioDeviceKind kind) => [
    for (final (name, isDefault) in _a.devices(kind.index))
      AudioDevice(name, isDefault: isDefault),
  ];

  @override
  void selectDevice(AudioDeviceKind kind, String name) =>
      _a.selectDevice(kind.index, name);
}

/// Silent engine used in tests or when no audio device is available.
/// Captured audio can be injected with [inject]; played audio is collected in
/// [played].
class FakeAudioEngine extends AudioEngine {
  /// What [selectDevice] was last called with.
  final Map<AudioDeviceKind, String> selected = {};
  List<AudioDevice> fakeDevices = const [];

  @override
  List<AudioDevice> devices(AudioDeviceKind kind) => fakeDevices;
  @override
  void selectDevice(AudioDeviceKind kind, String name) => selected[kind] = name;

  int _rate = 16000;
  bool capturing = false;
  bool playing = false;
  final List<Int16List> _toCapture = [];
  final List<int> played = [];

  void inject(Int16List samples) => _toCapture.add(samples);

  @override
  int get sampleRate => _rate;
  @override
  void init(int sampleRate) => _rate = sampleRate;
  @override
  void startCapture() => capturing = true;
  @override
  void stopCapture() => capturing = false;
  @override
  void startPlayback() => playing = true;
  @override
  void stopPlayback() => playing = false;

  @override
  Int16List readCaptured() {
    if (!capturing || _toCapture.isEmpty) return Int16List(0);
    final all = Int16List.fromList(_toCapture.expand((e) => e).toList());
    _toCapture.clear();
    return all;
  }

  @override
  void play(Int16List samples) => played.addAll(samples);
  @override
  int get queued => 0;
  @override
  void flushPlayback() {}
}
