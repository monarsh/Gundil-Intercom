import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/camera_viewer.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/ui/camera_stream.dart';
import 'package:p2p_intercom/ui/contacts_pane.dart';
import 'package:p2p_intercom/ui/intercom_panel.dart';
import 'package:p2p_intercom/ui/peer_list.dart';

void main() {
  testWidgets('a camera can be added and shows in the list', (tester) async {
    List<SavedCamera> stored = const [];
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
      onCamerasChanged: (c) => stored = c,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerList(service: service, onAddPeer: () {}, cameras: true),
        ),
      ),
    );
    expect(find.textContaining('No cameras yet'), findsOneWidget);
    await tester.tap(find.text('Add camera'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('TP-Link Tapo'), findsOneWidget);

    // Nothing filled in: refused with a reason.
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump();
    expect(find.textContaining('IP address, e.g.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'Front door');
    await tester.enterText(find.byType(TextField).at(1), '127.0.0.1');
    await tester.enterText(find.byType(TextField).at(2), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(stored.single.host, '127.0.0.1');
    expect(stored.single.cloudPassword, 'secret');
    expect(find.text('Front door'), findsOneWidget);
    expect(find.byIcon(Icons.videocam), findsWidgets);
    // Let the reachability check finish (nothing listens: refused at once).
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
  });

  testWidgets('another RTSP camera can be added', (tester) async {
    List<SavedCamera> stored = const [];
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
      onCamerasChanged: (c) => stored = c,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerList(service: service, onAddPeer: () {}, cameras: true),
        ),
      ),
    );
    await tester.tap(find.text('Add camera'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Other (RTSP)'));
    await tester.pump();
    expect(find.text('RTSP address'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), 'http://nope');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump();
    expect(find.textContaining('RTSP address, e.g.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'Gate');
    await tester.enterText(
      find.byType(TextField).at(1),
      'rtsp://admin:pw@127.0.0.1:8554/live?ch=1',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump(const Duration(milliseconds: 500));
    final cam = stored.single;
    expect(cam.isTapo, isFalse);
    expect(cam.rtspUser, 'admin');
    expect(cam.rtspPassword, 'pw');
    expect(cam.videoUrl(), 'rtsp://admin:pw@127.0.0.1:8554/live?ch=1');
    expect(find.text('Gate'), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
  });

  testWidgets('the camera on/off button is there for cameras only', (
    tester,
  ) async {
    CameraStream.debugPlayer = (url) => Text('playing $url');
    addTearDown(() => CameraStream.debugPlayer = null);
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
    );
    final tapo = service.saveCamera(
      name: 'Porch',
      host: '127.0.0.1',
      cloudPassword: 'x',
    );
    final gate = service.saveCamera(
      name: 'Gate',
      host: '127.0.0.1',
      kind: SavedCamera.kindRtsp,
      rtspPath: '/live',
    );
    final viewer = CameraViewer();
    final messages = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: CameraStage(service: service, viewer: viewer),
              ),
              IntercomPanel(
                service: service,
                viewer: viewer,
                compact: true,
                onMessage: (m, {error = false}) => messages.add(m),
              ),
            ],
          ),
        ),
      ),
    );
    // Everyone (or any intercom): no camera button.
    expect(find.text('Turn on camera'), findsNothing);

    // A Tapo without its camera account: says what's missing.
    service.selectTarget(PeerTarget(tapo.peerId));
    await tester.pump();
    await tester.tap(find.text('Turn on camera'));
    await tester.pump();
    expect(viewer.on, isFalse);
    expect(messages.single, contains('camera account'));

    service.selectTarget(PeerTarget(gate.peerId));
    await tester.pump();
    await tester.tap(find.text('Turn on camera'));
    await tester.pump();
    expect(viewer.isShowing(gate.peerId), isTrue);
    expect(find.text('playing rtsp://127.0.0.1:554/live'), findsOneWidget);
    expect(find.text('Turn off camera'), findsOneWidget);
    await tester.tap(find.text('Turn off camera'));
    await tester.pump();
    expect(viewer.on, isFalse);
    expect(find.textContaining('playing'), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await service.shutdown();
  });

  testWidgets('cameras have their own list, not the peer list', (tester) async {
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
    );
    service.saveCamera(name: 'Porch', host: '127.0.0.1', cloudPassword: 'x');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsPane(service: service, onAddPeer: () {}),
        ),
      ),
    );
    expect(find.text('Cameras · 0 online'), findsOneWidget);
    expect(find.text('Peers · 0 online'), findsOneWidget);
    expect(find.text('Add peer'), findsOneWidget);
    expect(find.text('Porch'), findsNothing);
    expect(find.text('Add camera'), findsNothing);
    await tester.tap(find.text('Cameras · 0 online'));
    await tester.pumpAndSettle();
    expect(find.text('Porch'), findsOneWidget);
    expect(find.text('Add camera'), findsOneWidget);
    expect(find.textContaining('Tapo · 127.0.0.1'), findsOneWidget);

    // A camera that answers counts as online on its tab.
    await tester.runAsync(() async {
      final fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      fake.listen((c) => c.destroy());
      service.saveCamera(
        name: 'Gate',
        host: '127.0.0.1',
        kind: SavedCamera.kindRtsp,
        rtspPort: fake.port,
        rtspPath: '/live',
      );
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!service.entries.any((e) => e.name == 'Gate' && e.online) &&
          DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await fake.close();
    });
    await tester.pump();
    expect(find.text('Cameras · 1 online'), findsOneWidget);
    expect(find.text('Peers · 0 online'), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('zoom, and pan & tilt for a Tapo', (tester) async {
    CameraStream.debugPlayer = (url) => const SizedBox.expand();
    final moves = <String>[];
    CameraStage.debugPanTilt = (cam, x, y) async => moves.add('$x,$y');
    addTearDown(() {
      CameraStream.debugPlayer = null;
      CameraStage.debugPanTilt = null;
    });
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
    );
    final tapo = service.saveCamera(
      name: 'Porch',
      host: '127.0.0.1',
      cloudPassword: 'x',
      rtspUser: 'cam',
      rtspPassword: 'y',
    );
    final gate = service.saveCamera(
      name: 'Gate',
      host: '127.0.0.1',
      kind: SavedCamera.kindRtsp,
      rtspPath: '/live',
    );
    final viewer = CameraViewer()..show(tapo.peerId);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraStage(service: service, viewer: viewer),
        ),
      ),
    );
    final zoomOut = find.byTooltip('Zoom out');
    IconButton button(Finder f) => tester.widget<IconButton>(
      find.ancestor(of: f, matching: find.byType(IconButton)).first,
    );
    expect(button(zoomOut).onPressed, isNull);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(find.text('Porch · 1.5×'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(find.text('Porch · 2.3×'), findsOneWidget);
    await tester.tap(zoomOut);
    await tester.tap(zoomOut);
    await tester.pump();
    expect(find.text('Porch'), findsOneWidget);

    // Double tap: 2× on that spot; again: back out.
    final picture = find.byType(InteractiveViewer);
    Future<void> doubleTap(Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));
    }

    final corner = tester.getTopLeft(picture) + const Offset(100, 150);
    await doubleTap(corner);
    expect(find.text('Porch · 2.0×'), findsOneWidget);
    final m = tester
        .widget<InteractiveViewer>(picture)
        .transformationController!
        .value;
    // The tapped spot stays where it was.
    final local = corner - tester.getTopLeft(picture);
    expect(m.getTranslation().x, closeTo(-local.dx, 0.5));
    expect(m.getTranslation().y, closeTo(-local.dy, 0.5));
    await doubleTap(corner);
    expect(find.text('Porch'), findsOneWidget);

    // Pinch with two fingers zooms too.
    final c = tester.getCenter(picture);
    final f1 = await tester.startGesture(c - const Offset(40, 0));
    final f2 = await tester.startGesture(c + const Offset(40, 0));
    for (var i = 1; i <= 8; i++) {
      await f1.moveTo(c - Offset(40.0 + i * 10, 0));
      await f2.moveTo(c + Offset(40.0 + i * 10, 0));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Porch · '), findsOneWidget);
    await doubleTap(c);
    expect(find.text('Porch'), findsOneWidget);

    // Pan & tilt: arrows appear; a press moves one step.
    expect(find.byTooltip('Pan right'), findsNothing);
    await tester.tap(find.byTooltip('Pan & tilt'));
    await tester.pump();
    await tester.tap(find.byTooltip('Pan right'));
    await tester.pump();
    await tester.tap(find.byTooltip('Tilt down'));
    await tester.pump();
    expect(moves, ['1,0', '0,-1']);

    // Another RTSP camera: zoom, but no pan & tilt.
    viewer.show(gate.peerId);
    await tester.pump();
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    expect(find.byTooltip('Pan & tilt'), findsNothing);
    expect(find.byTooltip('Pan right'), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Reboot camera is in the menu of Tapo cameras only', (
    tester,
  ) async {
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
    );
    service.saveCamera(name: 'Porch', host: '127.0.0.1', cloudPassword: 'x');
    service.saveCamera(
      name: 'Gate',
      host: '127.0.0.1',
      kind: SavedCamera.kindRtsp,
      rtspPath: '/live',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerList(service: service, onAddPeer: () {}, cameras: true),
        ),
      ),
    );
    await tester.pump();
    Finder menuOf(String name) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
      matching: find.byIcon(Icons.more_vert),
    );

    await tester.tap(menuOf('Porch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Reboot camera'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Reboot Porch?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Reboot'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // No camera here (and widget tests answer every HTTP request with 400):
    // it says why it failed.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.textContaining('Could not restart Porch. cloud password: '),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5)); // Snack bar gone.
    await tester.tap(menuOf('Gate'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Reboot camera'), findsNothing);
    expect(find.text('Edit…'), findsOneWidget);
  });

  testWidgets('a Tapo picture that keeps failing: check, then Reboot camera?', (
    tester,
  ) async {
    final opened = <String>[];
    CameraStream.debugOpen = (url) async {
      opened.add(url);
      throw 'reader open error';
    };
    final checked = <String>[];
    CameraStream.check = (url, {name}) async {
      checked.add(url);
      return 'port 554 accepts the connection but never answers';
    };
    addTearDown(() {
      CameraStream.debugOpen = null;
      CameraStream.check = checkRtsp;
    });
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
    );
    late ServerSocket fake;
    late SavedCamera cam;
    // Online: something answers on its Tapo port.
    await tester.runAsync(() async {
      fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      fake.listen((c) => c.destroy());
      cam = service.saveCamera(
        name: 'Sons',
        host: '127.0.0.1',
        cloudPassword: 'x',
        port: fake.port,
        rtspUser: 'cam',
        rtspPassword: 'y',
      );
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!(service.peer(cam.peerId)?.online ?? false) &&
          DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    expect(service.peer(cam.peerId)!.online, isTrue);
    final viewer = CameraViewer()..show(cam.peerId);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraStage(service: service, viewer: viewer),
        ),
      ),
    );
    await tester.pump();
    expect(opened, hasLength(1));
    expect(checked, hasLength(1));
    expect(find.textContaining('Check: port 554 accepts'), findsOneWidget);
    expect(find.textContaining('Reboot camera?'), findsNothing);

    // Two more failures in a row (one every 5 s); the check runs once a
    // minute at most.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(opened, hasLength(3));
    expect(checked, hasLength(1));
    expect(
      find.text("The camera isn't answering. Reboot camera?"),
      findsOneWidget,
    );
    await tester.tap(find.text('Reboot'));
    await tester.pumpAndSettle();
    expect(find.text('Reboot Sons?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reboot camera?'), findsOneWidget);

    // Not now: it doesn't come back for this camera.
    await tester.tap(find.byTooltip('Not now'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('Reboot camera?'), findsNothing);

    viewer.stop();
    await tester.pump();
    await tester.runAsync(() async {
      await fake.close();
      await service.shutdown();
    });
  });

  testWidgets('a picture that opens resets the count', (tester) async {
    var fail = true;
    CameraStream.debugOpen = (url) async {
      if (fail) throw 'reader open error';
    };
    CameraStream.check = (url, {name}) async => 'stuck';
    addTearDown(() {
      CameraStream.debugOpen = null;
      CameraStream.check = checkRtsp;
    });
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
    );
    final cam = service.saveCamera(
      name: 'Gate',
      host: '127.0.0.1',
      kind: SavedCamera.kindRtsp,
      rtspPath: '/live',
    );
    final viewer = CameraViewer()..show(cam.peerId);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraStage(service: service, viewer: viewer),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    // Not a Tapo: no reboot to offer.
    expect(find.textContaining('Reboot camera?'), findsNothing);
    fail = false;
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('No picture'), findsNothing);
    viewer.stop();
    await tester.pump();
    await tester.runAsync(service.shutdown);
  });
}
