// Makes the README screenshot (docs/screenshot.png) from the current app:
// two real intercoms on this machine, "Office-PC" (shown) connected to
// "Gate", which is talking. Skipped unless asked for:
//
//   README_SCREENSHOT=1 flutter test test/readme_screenshot_test.dart
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/src/settings.dart';
import 'package:p2p_intercom/ui/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFonts() async {
  final fonts =
      '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
      '/bin/cache/artifacts/material_fonts';
  Future<ByteData> f(String n) async =>
      ByteData.sublistView(await File('$fonts/$n').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final n in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]) {
    roboto.addFont(f(n));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(f('MaterialIcons-Regular.otf'))).load();
}

void main() {
  final run = Platform.environment['README_SCREENSHOT'] == '1';

  testWidgets('README screenshot', (tester) async {
    await tester.runAsync(_loadFonts);
    // Real shadows (tests draw them as black outlines by default).
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    final gateAudio = FakeAudioEngine();
    late IntercomService office, gate;
    await tester.runAsync(() async {
      gate = IntercomService(
        selfId: 'gate',
        name: 'Gate',
        audio: gateAudio,
        enableDiscovery: false,
        preferredPort: 0,
        echoSuppression: false,
      );
      office = IntercomService(
        selfId: 'office',
        name: 'Office-PC',
        audio: FakeAudioEngine(),
        enableDiscovery: false,
        preferredPort: 0,
        savedPeers: [
          SavedPeer(
            key: 'f',
            host: '192.0.2.2',
            port: 47801,
            label: 'Front desk',
            platform: 'windows',
          ),
          SavedPeer(
            key: 'g',
            host: '192.0.2.99',
            port: 47801,
            label: 'Garage',
            platform: 'node',
          ),
        ],
      );
      await gate.start();
      await office.start();
      await office.addSavedPeer(host: '127.0.0.1', port: gate.listenPort!);
      for (
        var i = 0;
        i < 100 && !(office.peer('gate')?.connected ?? false);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await office.shutdown();
        await gate.shutdown();
      });
    });

    final shot = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF00897B),
            useMaterial3: true,
            fontFamily: 'Roboto',
          ),
          home: HomePage(service: office, settings: settings),
        ),
      ),
    );
    office.selectTarget(const PeerTarget('gate'));
    await tester.runAsync(() async {
      await office.connect();
      // Gate talks: a voice-like tone, fed for a few seconds.
      final rng = Random(3);
      for (var i = 0; i < 60; i++) {
        final s = Int16List(320);
        for (var k = 0; k < s.length; k++) {
          final t = (i * 320 + k) / 16000;
          s[k] =
              (9000 *
                          sin(2 * pi * 220 * t) *
                          (0.6 + 0.4 * sin(2 * pi * 3 * t)) +
                      rng.nextInt(800) -
                      400)
                  .round();
        }
        gateAudio.inject(s);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // The "Gate connected" message goes away; no keyboard focus ring.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() async {
        final s = Int16List(320);
        for (var k = 0; k < s.length; k++) {
          s[k] = (9000 * sin(2 * pi * 220 * k / 16000)).round();
        }
        gateAudio.inject(s);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump(const Duration(milliseconds: 150));
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('speaking'), findsWidgets);

    final boundary =
        shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final png = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    File('docs/screenshot.png').writeAsBytesSync(png!);
    debugDisableShadows = true;
  }, skip: !run);
}
