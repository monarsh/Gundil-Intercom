import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/ui/pairing.dart';

Future<IntercomService> _open(
  WidgetTester tester, {
  String password = '',
}) async {
  final service = IntercomService(
    selfId: 'me',
    name: 'Me',
    audio: FakeAudioEngine(),
    enableDiscovery: false,
    password: password,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showPairingDialog(context, service),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return service;
}

void main() {
  testWidgets('first intercom: make a home key, show its code', (tester) async {
    final service = await _open(tester);
    expect(find.text('Not paired yet'), findsOneWidget);
    expect(find.text('Ask an intercom on this Wi-Fi'), findsOneWidget);
    expect(find.text('Paste pairing code'), findsOneWidget);
    // The scanner is for phones; the test runs on a desktop.
    expect(find.text('Scan pairing QR'), findsNothing);

    await tester.tap(find.text('This is the first intercom'));
    await tester.pumpAndSettle();
    final key = service.homeKey!;
    expect(find.text('Paired'), findsOneWidget);
    expect(find.text('Home key ${key.fingerprint}'), findsOneWidget);

    await tester.tap(find.text('Show pairing code'));
    await tester.pumpAndSettle();
    expect(find.byType(QrView), findsOneWidget);
    expect(find.text(key.pairingText), findsOneWidget);
    expect(find.text('Copy pairing code'), findsOneWidget);

    // A new key (lost phone) asks first, then replaces the old one.
    await tester.ensureVisible(find.text('New home key'));
    await tester.tap(find.text('New home key'));
    await tester.pumpAndSettle();
    expect(find.text('Make a new home key?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'New home key'));
    await tester.pumpAndSettle();
    expect(service.homeKey, isNot(key));
    expect(
      find.text('Home key ${service.homeKey!.fingerprint}'),
      findsOneWidget,
    );
  });

  testWidgets('unpair: back to every pairing option', (tester) async {
    final service = await _open(tester);
    await tester.tap(find.text('This is the first intercom'));
    await tester.pumpAndSettle();
    expect(find.text('This is the first intercom'), findsNothing);
    await tester.ensureVisible(find.text('Unpair this device'));
    await tester.tap(find.text('Unpair this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Unpair'));
    await tester.pumpAndSettle();
    expect(service.homeKey, isNull);
    expect(find.text('Not paired yet'), findsOneWidget);
    expect(find.text('Ask an intercom on this Wi-Fi'), findsOneWidget);
    expect(find.text('This is the first intercom'), findsOneWidget);
  });

  testWidgets('asking with nobody on the Wi-Fi says so', (tester) async {
    final service = await _open(tester);
    await tester.tap(find.text('Ask an intercom on this Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No intercom is connected'), findsOneWidget);
    expect(service.homeKey, isNull);
  });

  testWidgets('with a password it says the password is used', (tester) async {
    await _open(tester, password: 'correct horse battery');
    expect(
      find.textContaining('Internet calls use the password'),
      findsOneWidget,
    );
  });
}
