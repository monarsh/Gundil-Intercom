import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/src/platform_bridge.dart';
import 'package:p2p_intercom/src/settings.dart';
import 'package:p2p_intercom/ui/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _openSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await Settings.load();
  final service = IntercomService(
    selfId: 'me',
    name: 'Me',
    audio: FakeAudioEngine(),
    enableDiscovery: false,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(service: service, settings: settings),
    ),
  );
  await tester.tap(find.byTooltip('Settings').first);
  // The dialog first reads the device's addresses (real I/O).
  // (The home page has running animations: no pumpAndSettle.)
  for (
    var i = 0;
    i < 5 && find.text('Device name shown to peers').evaluate().isEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
  expect(find.text('Device name shown to peers'), findsOneWidget);
}

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.text('Cancel'));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpWidget(const SizedBox());
}

void main() {
  tearDown(() => PlatformBridge.hasBackgroundMode = false);

  testWidgets('phones (Android, iPhone) get "Run in background"', (
    tester,
  ) async {
    PlatformBridge.hasBackgroundMode = true;
    await _openSettings(tester);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Run in background'), findsOneWidget);
    // "Start when phone turns on" is Android only (the test runs on Linux).
    expect(find.text('Start when phone turns on'), findsNothing);
    await _close(tester);
  });

  testWidgets('desktops don\'t', (tester) async {
    PlatformBridge.hasBackgroundMode = false;
    await _openSettings(tester);
    expect(find.text('Run in background'), findsNothing);
    await _close(tester);
  });
}
