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
    expect(find.text('Cameras (1)'), findsOneWidget);
    expect(find.text('Add peer'), findsOneWidget);
    expect(find.text('Porch'), findsNothing);
    expect(find.text('Add camera'), findsNothing);
    await tester.tap(find.text('Cameras (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Porch'), findsOneWidget);
    expect(find.text('Add camera'), findsOneWidget);
    expect(find.textContaining('Tapo · 127.0.0.1'), findsOneWidget);
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
}
