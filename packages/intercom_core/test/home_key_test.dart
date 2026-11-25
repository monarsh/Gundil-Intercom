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
  group('HomeKey', () {
    test('pairing code round trip, hex, fingerprint', () {
      final k = HomeKey.generate();
      final text = k.pairingText;
      expect(text, startsWith(HomeKey.prefix));
      expect(text.length, HomeKey.prefix.length + 47);
      expect(HomeKey.parse(text), k);
      expect(
        HomeKey.parse(' ${text.substring(0, 20)}\n${text.substring(20)} '),
        k,
      );
      expect(
        HomeKey.parse(
          text.toLowerCase().replaceRange(
            HomeKey.prefix.length,
            null,
            text.substring(HomeKey.prefix.length),
          ),
        ),
        k,
      );
      expect(HomeKey.parse(k.hex), k);
      expect(HomeKey.tryHex(k.hex), k);
      expect(k.fingerprint, matches(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$')));
      expect(k.linkSecret, isNot(equals(k.rendezvousRoot)));
      expect(k.linkSecret.length, 32);
    });

    test('a typo or junk is refused', () {
      final text = HomeKey.generate().pairingText;
      final i = HomeKey.prefix.length + 10;
      final typo = text.replaceRange(i, i + 1, text[i] == 'A' ? 'B' : 'A');
      expect(() => HomeKey.parse(typo), throwsFormatException);
      expect(
        () => HomeKey.parse(text.substring(0, text.length - 3)),
        throwsFormatException,
      );
      expect(() => HomeKey.parse('hello'), throwsFormatException);
      expect(HomeKey.tryHex('12'), isNull);
    });
  });

  late FakeRelay relay;
  late FakeStun stun;
  setUp(() async {
    relay = await FakeRelay.start();
    stun = await FakeStun.start();
  });
  tearDown(() async {
    await relay.close();
    stun.close();
  });

  IntercomCore node(
    String id,
    FakeAudioEngine audio, {
    HomeKey? key,
    bool internet = true,
    void Function(String)? onKey,
  }) => IntercomCore(
    selfId: id,
    name: id.toUpperCase(),
    audio: audio,
    preferredPort: 0,
    enableDiscovery: false,
    rogerBeep: false,
    echoSuppression: false,
    internetMode: internet,
    homeKey: key?.hex ?? '',
    onHomeKeyChanged: onKey,
    internetRelays: [relay.url],
    stunServers: [('127.0.0.1', stun.port), ('127.0.0.1', stun.port)],
  );

  test('no password and no home key: Internet calls are refused', () async {
    final c = node('x', FakeAudioEngine(), internet: false);
    await c.start();
    addTearDown(c.shutdown);
    expect(() => c.setInternetMode(true), throwsArgumentError);
    expect(c.internetMode, isFalse);
    await c.newHomeKey();
    await c.setInternetMode(true);
    expect(c.internetMode, isTrue);
    expect(c.internetUsesPassword, isFalse);
  });

  test('same home key, no password: found and called over the internet; '
      'another key never meets', () async {
    final key = HomeKey.generate();
    final aAudio = FakeAudioEngine(), bAudio = FakeAudioEngine();
    final alice = node('alice', aAudio, key: key);
    final bob = node('bob', bAudio, key: key);
    final eve = node('eve', FakeAudioEngine(), key: HomeKey.generate());
    addTearDown(() async {
      await Future.wait([alice.shutdown(), bob.shutdown(), eve.shutdown()]);
    });
    await Future.wait([alice.start(), bob.start(), eve.start()]);
    await eventually(
      () =>
          (alice.peer('bob')?.internet ?? false) &&
          (bob.peer('alice')?.internet ?? false),
    );
    await alice.connect(const PeerTarget('bob'));
    await eventually(() => alice.inConversation && bob.inConversation);
    expect(alice.routeTo('bob'), 'internet');
    aAudio.inject(Int16List.fromList(List.filled(1600, 3000)));
    await eventually(() => bAudio.played.any((s) => s > 2000));
    expect(alice.peer('eve'), isNull);
    expect(eve.peer('alice'), isNull);
  }, timeout: const Timeout(Duration(seconds: 40)));

  group('pairing on the LAN', () {
    late IntercomCore alice, bob;
    String? saved;
    setUp(() async {
      saved = null;
      alice = node(
        'alice',
        FakeAudioEngine(),
        key: HomeKey.generate(),
        internet: false,
      );
      bob = node(
        'bob',
        FakeAudioEngine(),
        internet: false,
        onKey: (k) => saved = k,
      );
      await Future.wait([alice.start(), bob.start()]);
      await bob.addSavedPeer(host: '127.0.0.1', port: alice.listenPort!);
      await eventually(
        () =>
            bob.securityCode('alice') != null &&
            alice.securityCode('bob') != null,
      );
    });
    tearDown(() async {
      await Future.wait([alice.shutdown(), bob.shutdown()]);
    });

    test('allowed: the key arrives and is saved', () async {
      final asks = <IntercomEvent>[];
      final sub = alice.events.listen((e) {
        if (e.kind == IntercomEventKind.pairRequest) asks.add(e);
      });
      addTearDown(sub.cancel);
      final got = bob.requestHomeKey('alice');
      await eventually(() => alice.pairRequests.isNotEmpty);
      expect(asks.single.peerId, 'bob');
      final r = alice.pairRequests.single;
      expect(r.name, 'BOB');
      // Both sides show the same code to compare.
      expect(r.securityCode, bob.securityCode('alice'));
      // Nothing is sent before Allow.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(bob.homeKey, isNull);
      alice.answerPairRequest('bob', true);
      final key = await got;
      expect(key, alice.homeKey);
      expect(bob.homeKey, alice.homeKey);
      expect(saved, alice.homeKey!.hex);
      expect(alice.pairRequests, isEmpty);
    });

    test('denied: an error, no key', () async {
      final got = bob.requestHomeKey('alice');
      await eventually(() => alice.pairRequests.isNotEmpty);
      alice.answerPairRequest('bob', false);
      await expectLater(got, throwsA(isA<StateError>()));
      expect(bob.homeKey, isNull);
    });

    test('an intercom without a home key says so', () async {
      await expectLater(
        alice.requestHomeKey('bob'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no home key'),
          ),
        ),
      );
      expect(bob.pairRequests, isEmpty);
    });

    test('nobody answers: refused after the timeout', () async {
      final was = IntercomCore.pairTimeout;
      IntercomCore.pairTimeout = const Duration(milliseconds: 300);
      addTearDown(() => IntercomCore.pairTimeout = was);
      await expectLater(
        bob.requestHomeKey('alice'),
        throwsA(isA<StateError>()),
      );
      expect(alice.pairRequests, isEmpty);
      expect(bob.homeKey, isNull);
    });
  });
}
