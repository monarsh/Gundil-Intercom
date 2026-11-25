/// The app against the real Go gateway (gateway/): presence, punching, the
/// encrypted link and a camera tunnel. Skipped when Go isn't installed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

import 'support/fake_relay.dart';
import 'support/fake_stun.dart';

Future<void> eventually(bool Function() ok, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<String?> buildGateway(Directory tmp) async {
  final given = Platform.environment['GUNDIL_GATEWAY_BIN'];
  if (given != null && given.isNotEmpty) return given;
  try {
    final out = '${tmp.path}/gundil-gateway';
    final r = await Process.run(
      'go',
      ['build', '-o', out, '.'],
      workingDirectory: '../../gateway',
      environment: {'GOTOOLCHAIN': 'local', 'CGO_ENABLED': '0'},
    );
    if (r.exitCode != 0) {
      print('go build failed: ${r.stderr}');
      return null;
    }
    return out;
  } on ProcessException {
    return null; // No Go here.
  }
}

void main() {
  late Directory tmp;
  String? bin;
  setUpAll(() async {
    IntercomCore.internetScryptN = 1024;
    IntercomCore.cameraOnlineCheck = const Duration(seconds: 3);
    tmp = await Directory.systemTemp.createTemp('gw');
    bin = await buildGateway(tmp);
  });
  tearDownAll(() async {
    IntercomCore.cameraOnlineCheck = const Duration(seconds: 30);
    IntercomCore.debugCameraUnreachable.clear();
    await tmp.delete(recursive: true);
  });

  test('phone ↔ Go gateway: hidden from calls, camera through it', () async {
    if (bin == null) {
      markTestSkipped('Go is not installed');
      return;
    }
    final relay = await FakeRelay.start();
    final stun = await FakeStun.start();
    final camera = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    camera.listen((s) {
      s.listen((d) => s.add(utf8.encode(utf8.decode(d).toUpperCase())));
    });
    final conf = File('${tmp.path}/gateway.conf')
      ..writeAsStringSync('''
password = correct horse battery
name = Home router
share_cameras = true
relays = ${relay.url}
stun = 127.0.0.1:${stun.port}, 127.0.0.1:${stun.port}
state = ${tmp.path}/state.json
test_any_host = true
test_subnets = 127.0.0.0/24
test_scrypt_n = 1024
''');
    final gw = await Process.start(bin!, ['--config=${conf.path}']);
    final gwLog = StringBuffer();
    gw.stdout.transform(utf8.decoder).listen(gwLog.write);
    gw.stderr.transform(utf8.decoder).listen(gwLog.write);
    final phone = IntercomCore(
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
    addTearDown(() async {
      await phone.shutdown();
      gw.kill();
      await relay.close();
      stun.close();
      await camera.close();
    });
    try {
      await phone.start();
      // The gateway shows up (hidden: it can't be called).
      await eventually(() => phone.peers.any((p) => p.isGateway && p.internet));
      final g = phone.peers.firstWhere((p) => p.isGateway);
      expect(g.name, 'Home router');
      expect(g.sharesSubnets, ['127.0.0.0/24']);
      expect(phone.entries.any((e) => e.live?.isGateway ?? false), isFalse);
      expect(phone.onlinePeers.any((p) => p.isGateway), isFalse);

      final cam = phone.saveCamera(
        name: 'Porch',
        host: '127.0.0.1',
        kind: SavedCamera.kindRtsp,
        rtspPort: camera.port,
        rtspPath: '/stream2',
      );
      IntercomCore.debugCameraUnreachable.add(cam.peerId);
      await eventually(() => phone.cameraGateway(cam.peerId) == 'Home router');
      await eventually(
        () => phone.cameraFor(cam.peerId)!.rtspPort != camera.port,
      );
      final local = phone.cameraFor(cam.peerId)!;
      final s = await Socket.connect(local.host, local.rtspPort);
      final got = StringBuffer();
      s.listen((d) => got.write(utf8.decode(d)));
      s.add(utf8.encode('options rtsp://camera/stream2'));
      await eventually(() => got.toString() == 'OPTIONS RTSP://CAMERA/STREAM2');
      // A bigger transfer (several UDP segments, both ways).
      got.clear();
      final big = 'x' * 200000;
      s.add(utf8.encode(big));
      await eventually(() => got.length == big.length);
      expect(got.toString(), 'X' * 200000);
      expect(phone.routeTo(g.id), 'internet');
      s.destroy();
    } catch (e) {
      print('--- gateway log ---\n$gwLog');
      rethrow;
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
