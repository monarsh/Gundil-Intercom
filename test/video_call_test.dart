import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/src/video_call.dart';
import 'package:p2p_intercom/ui/video_view.dart';
import 'package:p2p_intercom/ui/zoomable.dart';

Future<void> eventually(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const method = MethodChannel('p2p_intercom/camera');
  const frames = EventChannel('p2p_intercom/camera/frames');

  late IntercomService alice, bob;
  late VideoCall video;
  late List<MethodCall> calls;
  late bool permission;
  MockStreamHandlerEventSink? sink;

  IntercomService node(String id, String name) => IntercomService(
    selfId: id,
    name: name,
    audio: FakeAudioEngine(),
    preferredPort: 0,
    enableDiscovery: false,
    rogerBeep: false,
    echoSuppression: false,
    videoReceive: true,
  );

  setUp(() async {
    VideoCall.debugSupported = true;
    calls = [];
    permission = true;
    sink = null;
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return switch (call.method) {
        'requestPermission' => permission,
        'list' => [
          {'id': 'front', 'name': 'Front camera', 'facing': 'front'},
          {'id': 'back', 'name': 'Back camera', 'facing': 'back'},
        ],
        _ => null,
      };
    });
    messenger.setMockStreamHandler(
      frames,
      MockStreamHandler.inline(
        onListen: (args, events) => sink = events,
        onCancel: (args) => sink = null,
      ),
    );
    alice = node('alice-id', 'Alice');
    bob = node('bob-id', 'Bob');
    await Future.wait([alice.start(), bob.start()]);
    await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!);
    video = VideoCall(alice);
  });

  tearDown(() async {
    video.dispose();
    await Future.wait([alice.shutdown(), bob.shutdown()]);
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(frames, null);
    VideoCall.debugSupported = null;
  });

  Future<void> call() async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
  }

  final jpeg = Uint8List.fromList([0xFF, 0xD8, 9, 9, 0xFF, 0xD9]);

  test('needs a call; never starts by itself', () async {
    expect(await video.start(), contains('Connect first'));
    await call();
    expect(video.on, isFalse);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
  });

  test('camera on: front camera first, pictures reach the peer', () async {
    await call();
    expect(await video.start(), isNull);
    expect(video.on, isTrue);
    expect(alice.cameraOn, isTrue);
    final start = calls.lastWhere((c) => c.method == 'start');
    expect((start.arguments as Map)['id'], 'front');
    expect(video.camera!.facing, CameraFacing.front);

    sink!.success({'jpeg': jpeg, 'rotation': 0, 'mirror': true});
    await eventually(() => video.preview != null);
    expect(video.preview, jpeg);
    expect(video.mirror, isTrue);
    await eventually(() => bob.remoteVideo('alice-id') != null);
    expect(bob.remoteVideo('alice-id')!.jpeg, jpeg);
  });

  testWidgets('a peer\'s video tile can be zoomed', (tester) async {
    await tester.runAsync(() async {
      await call();
      alice.setCamera(true);
      alice.sendVideoFrame(jpeg, rotation: 0);
      await eventually(() => bob.remoteVideo('alice-id') != null);
    });
    final bobVideo = VideoCall(bob);
    addTearDown(bobVideo.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoStage(service: bob, video: bobVideo),
        ),
      ),
    );
    expect(find.byType(ZoomableView), findsOneWidget);
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    expect(find.byTooltip('Zoom out'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(find.text('1.5×'), findsOneWidget);
  });

  test('SD/HD: restarts the capture, the peer keeps the video', () async {
    final remembered = <bool>[];
    video.dispose();
    video = VideoCall(alice, onHdChanged: remembered.add);
    await call();
    expect(await video.start(), isNull);
    var start = calls.lastWhere((c) => c.method == 'start').arguments as Map;
    expect([start['width'], start['height']], [640, 480]);
    sink!.success({'jpeg': jpeg, 'rotation': 0, 'mirror': false});
    await eventually(() => bob.remoteVideo('alice-id') != null);

    calls.clear();
    expect(await video.setHd(true), isNull);
    expect(video.hd, isTrue);
    expect(remembered, [true]);
    expect(calls.map((c) => c.method), ['stop', 'start']);
    start = calls.last.arguments as Map;
    expect([start['width'], start['height']], [1280, 720]);
    expect(start['quality'], VideoCall.hdQuality);
    expect(video.on, isTrue);
    expect(alice.cameraOn, isTrue);
    // Still streaming: the next picture arrives, no "camera off" between.
    final hdJpeg = Uint8List.fromList([0xFF, 0xD8, 7, 7, 7, 0xFF, 0xD9]);
    sink!.success({'jpeg': hdJpeg, 'rotation': 0, 'mirror': false});
    await eventually(
      () => bob.remoteVideo('alice-id')?.jpeg.length == hdJpeg.length,
    );

    // Off: the choice is kept for next time, nothing restarts.
    await video.stop();
    calls.clear();
    await video.setHd(false);
    expect(calls, isEmpty);
    expect(remembered, [true, false]);
  });

  test('switch flips front and back', () async {
    await call();
    await video.start();
    expect(await video.switchCamera(), isNull);
    expect(video.on, isTrue);
    expect(video.camera!.facing, CameraFacing.back);
    expect(
      calls.where((c) => c.method == 'start').map((c) => c.arguments['id']),
      ['front', 'back'],
    );
    await video.switchCamera();
    expect(video.camera!.facing, CameraFacing.front);
  });

  test('camera off tells the peer', () async {
    await call();
    await video.start();
    sink!.success({'jpeg': jpeg});
    await eventually(() => bob.remoteVideo('alice-id') != null);
    await video.toggle();
    expect(video.on, isFalse);
    expect(calls.last.method, 'stop');
    await eventually(() => bob.remoteVideo('alice-id') == null);
  });

  test('hanging up releases the camera', () async {
    await call();
    await video.start();
    alice.hangUp();
    await eventually(() => !video.on);
    await eventually(() => calls.last.method == 'stop');
  });

  test('permission denied', () async {
    permission = false;
    await call();
    expect(await video.start(), 'Camera permission denied');
    expect(video.on, isFalse);
  });

  test('CameraInfo.fromMap', () {
    expect(CameraInfo.fromMap({'id': 'x'})!.facing, CameraFacing.external);
    expect(CameraInfo.fromMap({'id': 'x'})!.name, 'x');
    expect(CameraInfo.fromMap({'name': 'no id'}), isNull);
  });
}
