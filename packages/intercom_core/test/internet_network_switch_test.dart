// Wi-Fi ⇄ mobile data: STUN must keep answering without turning internet
// calls off and on (a new UDP socket on each network change, and a new one
// when the system broke the old).
import 'dart:async';

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

  test(
    'STUN answers after a network change and after a broken socket',
    () async {
      final node = IntercomCore(
        selfId: 'phone',
        name: 'Phone',
        audio: FakeAudioEngine(),
        preferredPort: 0,
        enableDiscovery: false,
        password: 'correct horse battery',
        internetMode: true,
        internetRelays: [relay.url],
        stunServers: [('127.0.0.1', stun.port), ('127.0.0.1', stun.port)],
      );
      addTearDown(node.shutdown);
      await node.start();
      final svc = node.internetServiceForTest!;
      expect((await node.checkInternet())!.nat, NatType.cone);
      final first = svc.muxForTest!;

      // The network changed: a new socket; the old one (idle) is closed.
      node.networkChanged();
      await eventually(() => svc.muxForTest != first);
      expect(first.dead, isTrue);
      expect(svc.muxForTest!.port, isNot(first.port));
      expect((await node.checkInternet())!.nat, NatType.cone);

      // The system broke the socket: the next use makes a new one.
      final second = svc.muxForTest!;
      second.socket.close();
      await eventually(() => second.dead);
      final check = await node.checkInternet();
      expect(check!.nat, NatType.cone);
      expect(svc.muxForTest, isNot(second));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
