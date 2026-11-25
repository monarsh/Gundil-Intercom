import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

class _Hooks extends PlatformHooks {
  _Hooks(this.kind);
  final NetworkKind kind;
  @override
  Future<NetworkKind> networkKind() async => kind;
}

IntercomCore _node(String id, NetworkKind kind) => IntercomCore(
  selfId: id,
  name: id,
  audio: FakeAudioEngine(),
  preferredPort: 0,
  enableDiscovery: false,
  rogerBeep: false,
  echoSuppression: false,
  hooks: _Hooks(kind),
);

/// Forwards a TCP connection and counts what goes through.
class _Counter {
  _Counter._(this._server, int target) {
    _server.listen((client) async {
      final up = await Socket.connect(InternetAddress.loopbackIPv4, target);
      _sockets.addAll([client, up]);
      client.listen(
        (d) {
          chunks++;
          up.add(d);
        },
        onDone: up.destroy,
        onError: (_) => up.destroy(),
      );
      up.listen(
        (d) {
          chunks++;
          client.add(d);
        },
        onDone: client.destroy,
        onError: (_) => client.destroy(),
      );
    });
  }
  static Future<_Counter> start(int target) async => _Counter._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    target,
  );
  final ServerSocket _server;
  final List<Socket> _sockets = [];
  int chunks = 0;
  int get port => _server.port;
  Future<void> close() async {
    await _server.close();
    for (final s in _sockets) {
      s.destroy();
    }
  }
}

Future<void> _eventually(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// How many pieces go over an idle link in 8 s between a phone on [kind]
/// and a PC (no saving).
Future<int> _idleTraffic(NetworkKind kind) async {
  final phone = _node('phone', kind), pc = _node('pc', NetworkKind.unknown);
  await Future.wait([phone.start(), pc.start()]);
  final relay = await _Counter.start(pc.listenPort!);
  addTearDown(() async {
    await relay.close();
    await Future.wait([phone.shutdown(), pc.shutdown()]);
  });
  expect(phone.networkKind, kind);
  expect(await phone.addSavedPeer(host: '127.0.0.1', port: relay.port), true);
  await _eventually(() => pc.peer('phone')?.connected ?? false);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  relay.chunks = 0;
  await Future<void>.delayed(const Duration(seconds: 8));
  // Still linked either way.
  expect(pc.peer('phone')!.connected, isTrue);
  expect(phone.peer('pc')!.connected, isTrue);
  return relay.chunks;
}

void main() {
  test('idle intervals by network', () {
    expect(IntercomCore.idlePing(NetworkKind.unknown).inSeconds, 5);
    expect(IntercomCore.idlePing(NetworkKind.wifi).inSeconds, 15);
    expect(IntercomCore.idlePing(NetworkKind.mobile).inSeconds, 30);
    expect(IntercomCore.idleAnnounce(NetworkKind.mobile), isNull);
    expect(IntercomCore.idleAnnounce(NetworkKind.wifi)!.inSeconds, 10);
    expect(
      IntercomCore.idleRetry(
        NetworkKind.mobile,
        const Duration(seconds: 5),
      ).inSeconds,
      60,
    );
  });

  test('without saving, an idle link is pinged every 5 s', () async {
    expect(await _idleTraffic(NetworkKind.unknown), greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('on mobile data, the PC pings the idle phone rarely too', () async {
    expect(await _idleTraffic(NetworkKind.mobile), 0);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('on Wi-Fi, also quiet for more than 5 s', () async {
    expect(await _idleTraffic(NetworkKind.wifi), 0);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a slower announcer stays online between its beacons', () {
    final b = Discovery.parseBeacon(
      utf8.encode(
        jsonEncode({
          'app': 'p2p-intercom',
          'id': 'phone',
          'port': 47801,
          'every': 10,
        }),
      ),
      InternetAddress.loopbackIPv4,
      'me',
    )!;
    expect(b.every, const Duration(seconds: 10));
    final p = Peer(
      id: 'phone',
      name: 'Phone',
      platform: 'android',
      address: InternetAddress.loopbackIPv4,
      port: 47801,
    )..lastBeacon = DateTime.now().subtract(const Duration(seconds: 12));
    expect(p.online, isFalse); // The usual 7 s.
    p.beaconEvery = b.every;
    expect(p.online, isTrue); // Up to 23 s.
  });
}
