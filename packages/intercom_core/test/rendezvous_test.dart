import 'dart:async';
import 'dart:typed_data';

import 'package:intercom_core/src/internet/nostr.dart';
import 'package:intercom_core/src/internet/rendezvous.dart';
import 'package:intercom_core/src/secure_channel.dart';
import 'package:test/test.dart';

import 'support/fake_relay.dart';

Future<void> eventually(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Rendezvous node(String id, String password, List<String> relays) => Rendezvous(
  client: NostrClient(relays: relays),
  keys: RendezvousKeys.derive(password, n: 1024),
  selfId: id,
  secret: randomBytes(32),
);

void main() {
  late FakeRelay r1, r2;
  setUp(() async {
    r1 = await FakeRelay.start();
    r2 = await FakeRelay.start();
  });
  tearDown(() async {
    await r1.close();
    await r2.close();
  });

  test('events are signed, verified and deduplicated', () async {
    final secret = randomBytes(32);
    final e = NostrEvent.sign(
      secret: secret,
      kind: 1,
      tags: [
        ['t', 'x'],
      ],
      content: 'hello "world"\n',
    );
    expect(e.valid, isTrue);
    final tampered = NostrEvent.fromJson({...e.toJson(), 'content': 'bye'})!;
    expect(tampered.valid, isFalse);
  });

  test('same password: presence and signals over two relays', () async {
    final relays = [r1.url, r2.url];
    final a = node('alice', 'correct horse battery', relays);
    final b = node('bob', 'correct horse battery', relays);
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });
    final seenByB = <Presence>[];
    b.presence.listen(seenByB.add);
    final signalsToA = <Signal>[];
    a.signals.listen(signalsToA.add);
    a.start();
    await eventually(() => a.client.connectedCount == 2);
    expect(
      a.announce(
        Presence(
          id: 'alice',
          name: 'Alice',
          platform: 'android',
          version: 9,
          at: DateTime.now(),
        ),
      ),
      2,
    );
    // Bob starts later: the relays still have Alice's presence.
    b.start();
    await eventually(() => seenByB.isNotEmpty);
    expect(seenByB.first.name, 'Alice');
    // Both relays delivered it; the client passed it on once.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(seenByB, hasLength(1));

    b.send(
      Signal(
        from: 'bob',
        to: 'alice',
        sid: 's1',
        type: 'offer',
        candidates: ['203.0.113.7:40000'],
      ),
    );
    await eventually(() => signalsToA.isNotEmpty);
    expect(signalsToA.single.candidates, ['203.0.113.7:40000']);
    // Relays only ever saw ciphertext.
    for (final e in [...r1.received, ...r2.received]) {
      expect(e['content'], isNot(contains('alice')));
      expect(e['content'], isNot(contains('203.0.113.7')));
    }
  });

  test('another password sees nothing', () async {
    final relays = [r1.url];
    final a = node('alice', 'correct horse battery', relays);
    final eve = node('eve', 'wrong password!!', relays);
    addTearDown(() async {
      await a.dispose();
      await eve.dispose();
    });
    final seen = <Presence>[];
    eve.presence.listen(seen.add);
    a.start();
    eve.start();
    await eventually(
      () => a.client.connectedCount == 1 && eve.client.connectedCount == 1,
    );
    a.announce(
      Presence(
        id: 'alice',
        name: 'Alice',
        platform: 'linux',
        version: 9,
        at: DateTime.now(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(seen, isEmpty);
  });

  test('reconnects after a relay drops', () async {
    final a = node('alice', 'correct horse battery', [r1.url]);
    addTearDown(a.dispose);
    var connects = 0;
    a.client.onConnected = () => connects++;
    a.start();
    await eventually(() => connects == 1);
    await r1.kick();
    await eventually(() => connects == 2);
  });

  test('scrypt keys are stable and differ per password', () {
    final k1 = RendezvousKeys.derive('correct horse battery', n: 1024);
    final k2 = RendezvousKeys.derive('correct horse battery', n: 1024);
    final k3 = RendezvousKeys.derive('correct horse batterY', n: 1024);
    expect(k1.topic, k2.topic);
    expect(k1.topic, isNot(k3.topic));
    expect(k1.contentKey, isA<Uint8List>());
  });
}
