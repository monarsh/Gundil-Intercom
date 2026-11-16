import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

void main() {
  test('choosing a microphone during a call reopens it', () async {
    final audio = _CountingAudio()
      ..fakeDevices = const [
        AudioDevice('Built-in', isDefault: true),
        AudioDevice('USB mic'),
      ];
    final a = IntercomCore(
      selfId: 'a',
      name: 'A',
      audio: audio,
      preferredPort: 0,
      enableDiscovery: false,
      rogerBeep: false,
    );
    final b = IntercomCore(
      selfId: 'b',
      name: 'B',
      audio: FakeAudioEngine(),
      preferredPort: 0,
      enableDiscovery: false,
      rogerBeep: false,
    );
    await Future.wait([a.start(), b.start()]);
    addTearDown(() => Future.wait([a.shutdown(), b.shutdown()]));

    expect(a.audioDevices(AudioDeviceKind.microphone).map((d) => d.name), [
      'Built-in',
      'USB mic',
    ]);
    // Outside a call: remembered, nothing reopened.
    a.selectAudioDevice(AudioDeviceKind.microphone, 'USB mic');
    expect(audio.selected[AudioDeviceKind.microphone], 'USB mic');
    expect(audio.captureStarts, 0);

    await a.addSavedPeer(host: '127.0.0.1', port: b.listenPort!);
    await a.connect(const PeerTarget('b'));
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!a.inConversation) {
      if (DateTime.now().isAfter(end)) fail('no call');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final before = audio.captureStarts;
    a.selectAudioDevice(AudioDeviceKind.microphone, '');
    expect(audio.selected[AudioDeviceKind.microphone], '');
    expect(audio.captureStarts, before + 1);
    expect(audio.capturing, isTrue);

    final playBefore = audio.playbackStarts;
    a.selectAudioDevice(AudioDeviceKind.speaker, 'Headphones');
    expect(audio.playbackStarts, playBefore + 1);
    expect(audio.playing, isTrue);
  });
}

class _CountingAudio extends FakeAudioEngine {
  int captureStarts = 0, playbackStarts = 0;

  @override
  void startCapture() {
    captureStarts++;
    super.startCapture();
  }

  @override
  void startPlayback() {
    playbackStarts++;
    super.startPlayback();
  }
}
