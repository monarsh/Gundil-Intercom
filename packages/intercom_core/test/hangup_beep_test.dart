import 'dart:async';

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

  test('no hang-up beep when we decline an incoming call', () async {
    final aliceAudio = FakeAudioEngine(), bobAudio = FakeAudioEngine();
    final alice = IntercomCore(
      selfId: 'alice-id',
      name: 'alice',
      audio: aliceAudio,
      preferredPort: 0,
      enableDiscovery: false,
      echoSuppression: false,
    );
    final bob = IntercomCore(
      selfId: 'bob-id',
      name: 'bob',
      audio: bobAudio,
      preferredPort: 0,
      enableDiscovery: false,
      echoSuppression: false,
      autoAnswer: false,
    );
    await Future.wait([alice.start(), bob.start()]);
    addTearDown(() => Future.wait([alice.shutdown(), bob.shutdown()]));

    await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!);
    alice.selectTarget(const PeerTarget('bob-id'));
    unawaited(alice.connect());
    await eventually(() => bob.conversation?.ringing.isNotEmpty ?? false);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Only the ring tone so far; the hang-up tone is a sequence of its own.
    final tone = IntercomCore.hangupTone(bob.sampleRate);
    bobAudio.played.clear();
    bob.decline();
    await eventually(() => alice.conversation == null);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    bool contains(List<int> hay, List<int> needle) {
      // The tone's loudest stretch, which is never part of the ring.
      final start = needle.indexWhere((v) => v.abs() > 2000);
      final part = needle.sublist(start, start + 64);
      for (var i = 0; i + part.length <= hay.length; i++) {
        var ok = true;
        for (var j = 0; j < part.length && ok; j++) {
          ok = hay[i + j] == part[j];
        }
        if (ok) return true;
      }
      return false;
    }

    expect(contains(bobAudio.played, tone), isFalse);
  });
}
