import 'dart:convert';

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
  final nodes = <IntercomCore>[];
  Future<IntercomCore> node(String id, String name) async {
    final c = IntercomCore(
      selfId: id,
      name: name,
      audio: FakeAudioEngine(),
      preferredPort: 0,
      enableDiscovery: false,
      rogerBeep: false,
      echoSuppression: false,
    );
    nodes.add(c);
    await c.start();
    return c;
  }

  tearDown(() async {
    await Future.wait([for (final n in nodes) n.shutdown()]);
    nodes.clear();
  });

  /// Alice with Bob (online), an offline peer and two cameras.
  Future<(IntercomCore, IntercomCore)> aliceAndBob() async {
    final alice = await node('alice-id', 'Alice');
    final bob = await node('bob-id', 'Bob');
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    await alice.addSavedPeer(
      host: '127.0.0.2',
      port: 1,
      label: 'Garage',
      altHost: '100.64.0.9',
    );
    alice.saveCamera(
      name: 'Door',
      host: '127.0.0.1',
      cloudPassword: 'cloud-secret',
      rtspUser: 'cam',
      rtspPassword: 'cam-secret',
      port: 1,
      rtspPort: 1,
    );
    alice.saveCamera(
      name: 'Yard',
      kind: SavedCamera.kindRtsp,
      host: 'yard.local',
      rtspUser: 'admin',
      rtspPassword: 'yard-secret',
      rtspPort: 8554,
      rtspPath: '/live',
    );
    return (alice, bob);
  }

  test('a list exported on one device is added on another', () async {
    final (alice, bob) = await aliceAndBob();
    final file = alice.exportContacts();
    expect(file, contains('cloud-secret'));

    final carol = await node('carol-id', 'Carol');
    final result = carol.importContacts(file);
    expect(result.peersAdded, 2);
    expect(result.camerasAdded, 2);
    expect(result.skipped, 0);
    expect(result.camerasWithoutLogin, 0);
    expect(result.toString(), 'Added 2 peers and 2 cameras.');

    final garage = carol.savedPeers.firstWhere((s) => s.label == 'Garage');
    expect(garage.altHost, '100.64.0.9');
    final door = carol.cameras.firstWhere((c) => c.name == 'Door');
    expect(door.cloudPassword, 'cloud-secret');
    expect(door.rtspPassword, 'cam-secret');
    expect(door.key, isNot(alice.cameras.first.key));
    final yard = carol.cameras.firstWhere((c) => c.name == 'Yard');
    expect(yard.isTapo, isFalse);
    expect(yard.rtspUrl, 'rtsp://yard.local:8554/live');

    // Imported peers are dialled at once.
    await eventually(() => carol.peer('bob-id')?.online ?? false);
    expect(bob.peer('carol-id'), isNotNull);

    // Loading the same list again adds nothing.
    final again = carol.importContacts(file);
    expect(again.peersAdded + again.camerasAdded, 0);
    expect(again.skipped, 4);
    expect(carol.savedPeers, hasLength(2));
    expect(carol.cameras, hasLength(2));
  });

  test('a device skips itself when it loads a list it is in', () async {
    final (alice, bob) = await aliceAndBob();
    final result = bob.importContacts(alice.exportContacts());
    expect(result.peersAdded, 1); // the garage
    expect(result.skipped, 1); // Bob himself
    expect(bob.savedPeers.where((s) => s.peerId == 'bob-id'), isEmpty);
  });

  test('without passwords, the cameras come without them', () async {
    final (alice, _) = await aliceAndBob();
    final file = alice.exportContacts(passwords: false);
    expect(file, isNot(contains('secret')));
    expect((jsonDecode(file) as Map)['passwords'], isFalse);

    final carol = await node('carol-id', 'Carol');
    final result = carol.importContacts(file);
    expect(result.camerasAdded, 2);
    expect(result.camerasWithoutLogin, 2);
    expect(result.toString(), contains('2 cameras have no password'));
    final door = carol.cameras.firstWhere((c) => c.name == 'Door');
    expect(door.rtspUser, 'cam');
    expect(door.cloudPassword, isEmpty);
  });

  test('a file that is not a list is refused', () async {
    final carol = await node('carol-id', 'Carol');
    for (final text in ['', 'hello', '[1,2]', '{"peers":[]}']) {
      expect(() => carol.importContacts(text), throwsFormatException);
    }
    expect(
      () => carol.importContacts(
        jsonEncode({'format': contactsFormat, 'version': 2}),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('newer version'),
        ),
      ),
    );
    expect(carol.savedPeers, isEmpty);
  });
}
