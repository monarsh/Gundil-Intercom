import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/app_log.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/ui/debug_log_page.dart';

void main() {
  testWidgets('the debug log shows, filters, copies and saves', (tester) async {
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
      cameras: [
        SavedCamera(
          key: 'p',
          name: 'Porch',
          host: '192.168.1.40',
          cloudPassword: 'hunter2',
          rtspUser: 'cam',
          rtspPassword: 'secret',
        ),
      ],
    );
    DebugLog.instance
      ..printer = null
      ..clear();
    debugLog('tapo', 'Porch listen: logged in');
    debugLog('video', 'Porch SD: opening rtsp://cam:secret@192.168.1.40/s');
    debugLog('app', 'Network changed');

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    String? savedName, saved;
    DebugLogPage.debugSave = (name, bytes) async {
      savedName = name;
      saved = utf8.decode(bytes);
      return name;
    };
    addTearDown(() => DebugLogPage.debugSave = null);

    await tester.pumpWidget(MaterialApp(home: DebugLogPage(service: service)));
    expect(find.textContaining('[tapo] Porch listen: logged in'), findsOne);
    expect(find.textContaining('rtsp://***@192.168.1.40'), findsOne);
    expect(find.textContaining('[app] Network changed'), findsOne);

    await tester.tap(find.text('Picture'));
    await tester.pump();
    expect(find.textContaining('[video]'), findsOne);
    expect(find.textContaining('[tapo]'), findsNothing);

    await tester.tap(find.text('Cameras & sound'));
    await tester.pump();
    expect(find.textContaining('[tapo]'), findsOne);
    expect(find.textContaining('[app]'), findsNothing);

    // New lines show up by themselves.
    debugLog('rtsp', 'Porch: playing');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('[rtsp] Porch: playing'), findsOne);

    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(copied, startsWith('Gundil Intercom $appVersion debug log\n'));
    expect(copied, contains('Camera "Porch": Tapo at 192.168.1.40'));
    expect(copied, contains('cloud password set, camera account set'));
    expect(copied, contains('[tapo] Porch listen: logged in'));
    expect(copied, isNot(contains('hunter2')));
    expect(copied, isNot(contains('secret')));

    await tester.tap(find.byTooltip('Save to a file'));
    await tester.pump();
    expect(savedName, matches(r'^gundil-intercom-log-\d{8}-\d{4}\.txt$'));
    expect(saved, contains('[rtsp] Porch: playing'));
    expect(find.text('Log saved'), findsOne);

    expect(detailedLog, isFalse);
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Detailed log'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(detailedLog, isTrue);
    detailedLog = false;

    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Clear'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(find.textContaining('[tapo]'), findsNothing);
    expect(find.textContaining('log cleared'), findsOne);
  });
}
