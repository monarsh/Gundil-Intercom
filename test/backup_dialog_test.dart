import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/ui/backup_dialog.dart';

IntercomService _service(
  String id, {
  List<SavedPeer> peers = const [],
  List<SavedCamera> cameras = const [],
}) => IntercomService(
  selfId: id,
  name: id,
  audio: FakeAudioEngine(),
  enableDiscovery: false,
  savedPeers: peers,
  cameras: cameras,
);

Widget _host(IntercomService service) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => Column(
        children: [
          TextButton(
            onPressed: () => BackupDialogs.export(context, service),
            child: const Text('export'),
          ),
          TextButton(
            onPressed: () => BackupDialogs.import(context, service),
            child: const Text('import'),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  final alicePeers = [
    SavedPeer(key: 'k1', host: '127.0.0.1', port: 1, label: 'Garage'),
  ];
  final aliceCameras = [
    SavedCamera(
      key: 'c1',
      name: 'Yard',
      kind: SavedCamera.kindRtsp,
      host: '127.0.0.1',
      rtspUser: 'admin',
      rtspPassword: 'yard-secret',
      rtspPort: 1,
      rtspPath: '/live',
    ),
  ];

  tearDown(() {
    BackupDialogs.debugSave = null;
    BackupDialogs.debugOpen = null;
  });

  testWidgets('export saves a file that import loads elsewhere', (
    tester,
  ) async {
    String? savedName, savedText;
    BackupDialogs.debugSave = (name, Uint8List bytes) async {
      savedName = name;
      savedText = utf8.decode(bytes);
      return Uri.file('/tmp/$name');
    };
    final alice = _service('alice', peers: alicePeers, cameras: aliceCameras);
    await tester.pumpWidget(_host(alice));
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
    expect(find.text('Export peers and cameras'), findsOneWidget);
    expect(find.textContaining('your 1 peer and 1 camera'), findsOneWidget);

    // Leave the passwords out.
    await tester.tap(find.text('Include camera passwords'));
    await tester.pump();
    await tester.tap(find.text('Save file'));
    await tester.pumpAndSettle();
    expect(find.text('List exported'), findsOneWidget);
    expect(savedName, matches(RegExp(r'^gundil-intercom-list-.*\.json$')));
    expect(savedText, contains('Garage'));
    expect(savedText, isNot(contains('yard-secret')));

    final bob = _service('bob');
    BackupDialogs.debugOpen = () async => savedText;
    await tester.pumpWidget(_host(bob));
    await tester.pumpAndSettle();
    await tester.tap(find.text('import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open file'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Added 1 peer and 1 camera. 1 camera has no password: edit to add it.',
      ),
      findsOneWidget,
    );
    expect(bob.savedPeers.single.label, 'Garage');
    expect(bob.cameras.single.rtspUser, 'admin');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await alice.shutdown();
    await bob.shutdown();
  });

  testWidgets('copy and paste work too, and a wrong text is refused', (
    tester,
  ) async {
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String?;
        } else if (call.method == 'Clipboard.getData') {
          return {'text': clip};
        }
        return null;
      },
    );
    final alice = _service('alice', peers: alicePeers, cameras: aliceCameras);
    await tester.pumpWidget(_host(alice));
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('List copied'), findsOneWidget);
    expect(clip, contains('yard-secret'));

    final bob = _service('bob');
    await tester.pumpWidget(_host(bob));
    await tester.pumpAndSettle();
    final good = clip;
    clip = 'my shopping list';
    await tester.tap(find.text('import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(
      find.text('This is not a Gundil Intercom peers and cameras list'),
      findsOneWidget,
    );
    expect(find.text('Import peers and cameras'), findsOneWidget);

    clip = good;
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(find.text('Import peers and cameras'), findsNothing);
    expect(bob.cameras.single.rtspPassword, 'yard-secret');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await alice.shutdown();
    await bob.shutdown();
  });
}
