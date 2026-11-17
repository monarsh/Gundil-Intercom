import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

Future<void> eventually(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'no hang-up beep for our own hang up; the other side gets one',
    () async {
      final aliceAudio = FakeAudioEngine(), bobAudio = FakeAudioEngine();
      IntercomCore node(String id, FakeAudioEngine audio) => IntercomCore(
        selfId: id,
        name: id,
        audio: audio,
        preferredPort: 0,
        enableDiscovery: false,
        echoSuppression: false,
      );
      final alice = node('alice-id', aliceAudio),
          bob = node('bob-id', bobAudio);
      await Future.wait([alice.start(), bob.start()]);
      addTearDown(() => Future.wait([alice.shutdown(), bob.shutdown()]));

      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!);
      alice.selectTarget(const PeerTarget('bob-id'));
      await alice.connect();
      await eventually(
        () =>
            alice.inConversation && (alice.conversation?.isConnected ?? false),
      );
      await eventually(() => bob.conversation?.isConnected ?? false);

      // Connected: both played the connect beep. Start counting from here.
      final tone = IntercomCore.hangupTone(alice.sampleRate);
      aliceAudio.played.clear();
      bobAudio.played.clear();

      alice.hangUp();
      await eventually(() => bob.conversation == null);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      bool heardHangup(FakeAudioEngine a) =>
          a.played.length >= tone.length && a.played.any((v) => v.abs() > 3000);
      expect(heardHangup(aliceAudio), isFalse);
      expect(heardHangup(bobAudio), isTrue);
    },
  );
}
