import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
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
    await tester.tap(find.text('Camera'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Add Tapo camera'), findsOneWidget);

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
}
