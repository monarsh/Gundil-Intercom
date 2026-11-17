import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/camera_viewer.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/ui/camera_stream.dart';
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
          body: PeerList(service: service, onAddPeer: () {}),
        ),
      ),
    );
    expect(find.text('Add peer'), findsOneWidget);
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
          body: PeerList(service: service, onAddPeer: () {}),
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
}
