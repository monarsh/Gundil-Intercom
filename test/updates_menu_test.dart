// Updates is in the More menu (first, above Export list), not in Settings.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/app_updater.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/src/settings.dart';
import 'package:p2p_intercom/ui/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoInstaller extends UpdateInstaller {
  @override
  bool get canInstall => false;
  @override
  Future<void> install(File file, UpdateOffer offer) async {}
}

void main() {
  testWidgets('Updates is in More, above Export list, not in Settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
      preferredPort: 0,
    );
    await tester.runAsync(service.start);
    addTearDown(() => tester.runAsync(service.shutdown));
    final updater = AppUpdater.forTest(
      UpdateManager(
        serverCode: '',
        identity: () => const UpdateIdentity(
          id: 'me',
          name: 'Me',
          package: 'linux-x64',
          version: '1.0.0',
          os: 'linux',
        ),
        installer: _NoInstaller(),
        downloadDir: Directory.systemTemp,
      ),
      settings,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(service: service, settings: settings, updater: updater),
      ),
    );
    // The page animates all the time: pump time instead of settling.
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    await tester.tap(find.byTooltip('More'));
    await settle();
    final updates = find.text('Updates');
    final export = find.text('Export list');
    expect(updates, findsOneWidget);
    expect(export, findsOneWidget);
    expect(
      tester.getTopLeft(updates).dy,
      lessThan(tester.getTopLeft(export).dy),
    );

    // It opens the Updates dialog.
    await tester.tap(updates);
    await settle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // Close it.
    await settle();

    // Not in Settings any more.
    await tester.tap(find.byTooltip('Settings'));
    await settle();
    expect(find.text('Updates'), findsNothing);
  });
}
