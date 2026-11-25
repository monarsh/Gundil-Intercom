import 'dart:async';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

import 'support/fake_relay.dart';
import 'support/fake_stun.dart';

Future<void> eventually(bool Function() ok, {int seconds = 10}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late FakeRelay relay;
  late FakeStun stun;
  setUpAll(() => IntercomCore.internetScryptN = 1024);
  setUp(() async {
    relay = await FakeRelay.start();
    stun = await FakeStun.start();
  });
  tearDown(() async {
    await relay.close();
    stun.close();
  });

  IntercomCore node(String id, FakeAudioEngine audio, {String? password}) =>
      IntercomCore(
        selfId: id,
        name: id.toUpperCase(),
        audio: audio,
        preferredPort: 0,
        enableDiscovery: false,
        rogerBeep: false,
        echoSuppression: false,
        password: password ?? 'correct horse battery',
        internetMode: true,
        internetRelays: [relay.url],
        stunServers: [('127.0.0.1', stun.port), ('127.0.0.1', stun.port)],
      );

  test('found over the relay, called over a punched UDP path', () async {
    final aAudio = FakeAudioEngine(), bAudio = FakeAudioEngine();
    final alice = node('alice', aAudio), bob = node('bob', bAudio);
    String? key;
    addTearDown(() async {
      await Future.wait([alice.shutdown(), bob.shutdown()]);
    });
    await Future.wait([alice.start(), bob.start()]);
    // They know nothing of each other but the relay.
    await eventually(
      () =>
          (alice.peer('bob')?.internet ?? false) &&
          (bob.peer('alice')?.internet ?? false),
    );
    expect(alice.peer('bob')!.online, isTrue);
    expect(alice.peer('bob')!.name, 'BOB');
    key = alice.internetRelaysConnected.toString();
    expect(key, '1');

    await alice.connect(const PeerTarget('bob'));
    await eventually(() => alice.inConversation && bob.inConversation);
    expect(alice.routeTo('bob'), 'internet');
    aAudio.inject(Int16List.fromList(List.filled(1600, 3000)));
    bAudio.inject(Int16List.fromList(List.filled(1600, -3000)));
    // ADPCM isn't exact: close to the sent level is enough.
    await eventually(() => bAudio.played.any((s) => s > 2000));
    await eventually(() => aAudio.played.any((s) => s < -2000));

    final check = await alice.checkInternet();
    expect(check!.relays, 1);
    expect(check.nat, NatType.cone);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a short password is refused for Internet calls', () async {
    final c = IntercomCore(
      selfId: 'x',
      name: 'X',
      audio: FakeAudioEngine(),
      preferredPort: 0,
      enableDiscovery: false,
      password: 'short',
      internetRelays: [relay.url],
    );
    await c.start();
    addTearDown(c.shutdown);
    expect(() => c.setInternetMode(true), throwsArgumentError);
    expect(c.internetMode, isFalse);
  });

  test('another password never meets', () async {
    final alice = node('alice', FakeAudioEngine());
    final eve = node('eve', FakeAudioEngine(), password: 'something else!!');
    addTearDown(() async {
      await Future.wait([alice.shutdown(), eve.shutdown()]);
    });
    await Future.wait([alice.start(), eve.start()]);
    await eventually(
      () =>
          alice.internetRelaysConnected == 1 &&
          eve.internetRelaysConnected == 1,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(alice.peer('eve'), isNull);
    expect(eve.peer('alice'), isNull);
  });

  test('turning it off says goodbye', () async {
    final alice = node('alice', FakeAudioEngine());
    final bob = node('bob', FakeAudioEngine());
    addTearDown(() async {
      await Future.wait([alice.shutdown(), bob.shutdown()]);
    });
    await Future.wait([alice.start(), bob.start()]);
    await eventually(() => bob.peer('alice')?.internet ?? false);
    await alice.setInternetMode(false);
    await eventually(() => !(bob.peer('alice')?.online ?? false));
  });
}
