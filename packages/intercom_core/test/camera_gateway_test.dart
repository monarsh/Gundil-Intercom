import 'dart:async';
import 'dart:io';

import 'package:intercom_core/intercom_core.dart';
import 'package:intercom_core/src/internet/tunnel.dart';
import 'package:test/test.dart';

import 'support/fake_relay.dart';
import 'support/fake_stun.dart';

Future<void> eventually(bool Function() ok, {int seconds = 15}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late FakeRelay relay;
  late FakeStun stun;
  late ServerSocket camera;
  final normalCheck = IntercomCore.cameraOnlineCheck;
  setUpAll(() {
    IntercomCore.cameraOnlineCheck = const Duration(seconds: 3);
    IntercomCore.internetScryptN = 1024;
    TunnelHub.debugAnyTarget = true;
    IntercomCore.debugSharedSubnets = ['127.0.0.0/24'];
  });
  tearDownAll(() {
    IntercomCore.cameraOnlineCheck = normalCheck;
    TunnelHub.debugAnyTarget = false;
    IntercomCore.debugSharedSubnets = null;
  });
  setUp(() async {
    relay = await FakeRelay.start();
    stun = await FakeStun.start();
    // The "camera": echoes what it gets, upper-cased.
    camera = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    camera.listen((s) {
      s.listen((d) => s.add(String.fromCharCodes(d).toUpperCase().codeUnits));
    });
  });
  tearDown(() async {
    await relay.close();
    stun.close();
    await camera.close();
    IntercomCore.debugCameraUnreachable.clear();
  });

  IntercomCore node(String id, {bool share = false}) => IntercomCore(
    selfId: id,
    name: id.toUpperCase(),
    audio: FakeAudioEngine(),
    preferredPort: 0,
    enableDiscovery: false,
    password: 'correct horse battery',
    internetMode: true,
    shareCameras: share,
    internetRelays: [relay.url],
    stunServers: [('127.0.0.1', stun.port), ('127.0.0.1', stun.port)],
  );

  test('away from home, a camera is reached through the gateway', () async {
    final home = node('home', share: true), phone = node('phone');
    addTearDown(() async {
      await Future.wait([home.shutdown(), phone.shutdown()]);
    });
    await Future.wait([home.start(), phone.start()]);
    await eventually(
      () => phone.peer('home')?.sharesSubnets.isNotEmpty ?? false,
    );
    final cam = phone.saveCamera(
      name: 'Porch',
      host: '127.0.0.1',
      kind: SavedCamera.kindRtsp,
      rtspPort: camera.port,
      rtspPath: '/live',
    );
    // From the phone, the camera's LAN address doesn't answer.
    IntercomCore.debugCameraUnreachable.add(cam.peerId);
    // Two missed checks, ten seconds apart, then through the gateway.
    await eventually(
      () => phone.cameraGateway(cam.peerId) == 'HOME',
      seconds: 30,
    );
    await eventually(
      () => phone.cameraFor(cam.peerId)!.rtspPort != camera.port,
    );
    expect(phone.peer(cam.peerId)!.online, isTrue);
    final local = phone.cameraFor(cam.peerId)!;
    expect(local.host, '127.0.0.1');
    expect(local.videoUrl(), contains(':${local.rtspPort}/live'));

    // Bytes go phone → gateway → camera and back.
    final s = await Socket.connect(local.host, local.rtspPort);
    final got = StringBuffer();
    s.listen((d) => got.write(String.fromCharCodes(d)));
    s.add('describe rtsp'.codeUnits);
    await eventually(() => got.toString() == 'DESCRIBE RTSP');
    expect(phone.routeTo('home'), 'internet');
    s.destroy();

    // Back home: directly again.
    IntercomCore.debugCameraUnreachable.clear();
    await eventually(
      () => phone.cameraGateway(cam.peerId) == null,
      seconds: 45,
    );
    expect(phone.cameraFor(cam.peerId)!.rtspPort, camera.port);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a gateway that does not share refuses tunnels', () async {
    final home = node('home'), phone = node('phone');
    addTearDown(() async {
      await Future.wait([home.shutdown(), phone.shutdown()]);
    });
    await Future.wait([home.start(), phone.start()]);
    await eventually(() => phone.peer('home')?.internet ?? false);
    // Not sharing: no subnets announced, so no camera goes through it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(phone.peer('home')!.sharesSubnets, isEmpty);
  });

  test('subnet check', () {
    expect(inSubnet('192.168.50.203', '192.168.50.0/24'), isTrue);
    expect(inSubnet('192.168.51.203', '192.168.50.0/24'), isFalse);
    expect(inSubnet('camera.local', '192.168.50.0/24'), isFalse);
  });
}
