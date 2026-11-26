// This device, Check network and Updates are in the More menu (first, above Export
// list), not in Settings.
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
  testWidgets(
    'This device, Check network and Updates are in More, not in Settings',
    (tester) async {
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
          home: HomePage(
            service: service,
            settings: settings,
            updater: updater,
          ),
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
      final device = find.text('This device');
      final check = find.text('Check network');
      final updates = find.text('Updates');
      final export = find.text('Export list');
      expect(device, findsOneWidget);
      expect(check, findsOneWidget);
      expect(
        tester.getTopLeft(device).dy,
        lessThan(tester.getTopLeft(check).dy),
      );
      expect(updates, findsOneWidget);
      expect(export, findsOneWidget);
      expect(
        tester.getTopLeft(check).dy,
        lessThan(tester.getTopLeft(updates).dy),
      );
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

      // This device opens its dialog.
      await tester.tap(find.byTooltip('More'));
      await settle();
      await tester.tap(find.text('This device'));
      await settle(); // The menu closes and the action starts.
      // It reads the network interfaces (real I/O) before it opens.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await settle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('TCP port:'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await settle();

      // Check network opens its dialog (internet calls are off here).
      await tester.tap(find.byTooltip('More'));
      await settle();
      await tester.tap(find.text('Check network'));
      await settle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Internet calls are off'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await settle();

      // Neither is in Settings any more.
      await tester.tap(find.byTooltip('Settings'));
      await settle();
      expect(find.text('Updates'), findsNothing);
      expect(find.text('Check network'), findsNothing);
      expect(find.text('This device'), findsNothing);
    },
  );
}
