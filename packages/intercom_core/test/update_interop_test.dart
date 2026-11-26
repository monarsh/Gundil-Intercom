/// The app's update client against the real Go update server
/// (gateway/, built with -tags updateserver): check-in over the relays and a
/// hole-punched link, download from the server, GitHub fallback, damaged
/// files and a wrong server code. Skipped when Go isn't installed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;
import 'package:test/test.dart';

import 'support/fake_relay.dart';
import 'support/fake_stun.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String _sha(List<int> b) => _hex(SHA256Digest().process(Uint8List.fromList(b)));

Future<String?> _buildServer(Directory tmp) async {
  final given = Platform.environment['GUNDIL_UPDATE_SERVER_BIN'];
  if (given != null && given.isNotEmpty) return given;
  try {
    final out = '${tmp.path}/gundil-update-server';
    final r = await Process.run(
      'go',
      ['build', '-tags', 'updateserver', '-o', out, '.'],
      workingDirectory: '../../gateway',
      environment: {'GOTOOLCHAIN': 'local', 'CGO_ENABLED': '0'},
    );
    if (r.exitCode != 0) {
      print('go build failed: ${r.stderr}');
      return null;
    }
    return out;
  } on ProcessException {
    return null;
  }
}

void main() {
  late Directory tmp;
  String? bin;
  late FakeRelay relay;
  late FakeStun stun;
  late HttpServer github;
  late Process server;
  late String code;
  final serverLog = StringBuffer();

  // A 1.9.1 APK kept on the server, and a gateway file only "on GitHub".
  final apk = Uint8List.fromList(
    List.generate(300000, (i) => Random(1).nextInt(256) ^ (i & 0xff)),
  );
  final gwFile = Uint8List.fromList(utf8.encode('gateway build ' * 5000));
  var githubServes = gwFile;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('upd');
    bin = await _buildServer(tmp);
    if (bin == null) return;
    relay = await FakeRelay.start();
    stun = await FakeStun.start();
    github = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    github.listen((req) {
      req.response.add(githubServes);
      req.response.close();
    });
    final data = Directory('${tmp.path}/data')..createSync();
    const apkName = 'Gundil_Intercom-1.9.1-android-arm64-v8a.apk';
    const gwName = 'gundil-gateway-1.9.1-linux-arm64.tar.gz';
    Directory('${data.path}/files/1.9.1').createSync(recursive: true);
    File('${data.path}/files/1.9.1/$apkName').writeAsBytesSync(apk);
    File('${data.path}/versions.json').writeAsStringSync(
      jsonEncode([
        {
          'version': '1.9.1',
          'source': 'upload',
          'added': DateTime.now().toUtc().toIso8601String(),
          'files': [
            {
              'name': apkName,
              'asset': 'app-$apkName',
              'package': 'android-arm64-v8a',
              'size': apk.length,
              'sha256': _sha(apk),
              'local': true,
            },
            {
              'name': gwName,
              'asset': 'app-$gwName',
              'package': 'gateway-linux-arm64',
              'size': gwFile.length,
              'sha256': _sha(gwFile),
              'url': 'http://127.0.0.1:${github.port}/$gwName',
              'local': false,
            },
          ],
        },
      ]),
    );
    // A "new" gateway for this machine (linux x86_64), kept on the server.
    final gwDir = Directory(
      '${tmp.path}/gw-new/gundil-gateway-9.9.9-linux-x86_64',
    )..createSync(recursive: true);
    File('${gwDir.path}/gundil-gateway').writeAsStringSync('NEW GATEWAY');
    const newName = 'gundil-gateway-9.9.9-linux-x86_64.tar.gz';
    Directory('${data.path}/files/9.9.9').createSync(recursive: true);
    await Process.run('tar', [
      'czf',
      '${data.path}/files/9.9.9/$newName',
      '-C',
      '${tmp.path}/gw-new',
      'gundil-gateway-9.9.9-linux-x86_64',
    ]);
    final newBytes = File(
      '${data.path}/files/9.9.9/$newName',
    ).readAsBytesSync();
    final versions =
        jsonDecode(File('${data.path}/versions.json').readAsStringSync())
            as List;
    versions.insert(0, {
      'version': '9.9.9',
      'source': 'upload',
      'added': DateTime.now().toUtc().toIso8601String(),
      'files': [
        {
          'name': newName,
          'asset': 'app-$newName',
          'package': 'gateway-linux-x86_64',
          'size': newBytes.length,
          'sha256': _sha(newBytes),
          'local': true,
        },
      ],
    });
    File('${data.path}/versions.json').writeAsStringSync(jsonEncode(versions));
    File('${data.path}/policy.json').writeAsStringSync(
      jsonEncode({
        'android': {'target': 'latest', 'mode': 'auto'},
        'gateway': {'target': 'latest', 'mode': 'auto'},
      }),
    );
    final conf = File('${tmp.path}/server.conf')
      ..writeAsStringSync('''
listen = 127.0.0.1:0
data_dir = ${data.path}
relays = ${relay.url}
stun = 127.0.0.1:${stun.port}, 127.0.0.1:${stun.port}
test_scrypt_n = 16
''');
    final c = await Process.run(bin!, ['--config=${conf.path}', 'code']);
    code = (c.stdout as String).trim();
    server = await Process.start(bin!, ['--config=${conf.path}']);
    server.stdout.transform(utf8.decoder).listen(serverLog.write);
    server.stderr.transform(utf8.decoder).listen(serverLog.write);
    // Wait until it listens on the relay.
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!serverLog.toString().contains('server code') &&
        DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });

  tearDownAll(() async {
    if (bin != null) {
      server.kill();
      await relay.close();
      stun.close();
      await github.close(force: true);
    }
    await tmp.delete(recursive: true);
  });

  UpdateClient client(String package, String version, {String? withCode}) =>
      UpdateClient(
        server: UpdateServerCode.parse(withCode ?? code),
        identity: UpdateIdentity(
          id: 'device-$package',
          name: 'Test $package',
          package: package,
          version: version,
          os: 'test',
        ),
        relays: [relay.url],
        stunServers: [('127.0.0.1', stun.port), ('127.0.0.1', stun.port)],
      );

  test('server code round trip and typos', () {
    final k = Uint8List.fromList(List.generate(32, (i) => i));
    final c = UpdateServerCode.parse(
      UpdateServerCode.parse(
        'GUNDIL-UPDATE-${base64Url.encode([...k, ...SHA256Digest().process(k).sublist(0, 3)]).replaceAll('=', '')}',
      ).text,
    );
    expect(c.publicKey, k);
    expect(
      () => UpdateServerCode.parse(
        '${c.text.substring(0, 30)}x${c.text.substring(31)}',
      ),
      throwsFormatException,
    );
    expect(
      () => UpdateServerCode.parse('GUNDIL-PAIR-abc'),
      throwsFormatException,
    );
  });

  test('checks in and downloads from the server', () async {
    if (bin == null) return markTestSkipped('Go is not installed');
    final c = client('android-arm64-v8a', '1.9.0');
    final offer = await c.check();
    expect(offer.mode, 'auto');
    expect(offer.version, '1.9.1');
    expect(offer.local, isTrue);
    expect(offer.downgrade, isFalse);
    final dir = Directory('${tmp.path}/dl1');
    var last = 0;
    final f = await c.download(offer, dir, onProgress: (n, _) => last = n);
    expect(await f.readAsBytes(), apk);
    expect(last, apk.length);
    expect(
      f.path.endsWith('Gundil_Intercom-1.9.1-android-arm64-v8a.apk'),
      isTrue,
    );
    expect(serverLog.toString(), contains('Test android-arm64-v8a'));
    expect(serverLog.toString(), contains('sent Gundil_Intercom-1.9.1'));
    // Up to date: nothing to do.
    final again = await client('android-arm64-v8a', '1.9.1').check();
    expect(again.hasUpdate, isFalse);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('without a copy on the server it downloads from GitHub', () async {
    if (bin == null) return markTestSkipped('Go is not installed');
    final c = client('gateway-linux-arm64', '1.9.0');
    final offer = await c.check();
    expect(offer.mode, 'auto');
    expect(offer.local, isFalse);
    final f = await c.download(offer, Directory('${tmp.path}/dl2'));
    expect(await f.readAsBytes(), gwFile);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a damaged file is refused', () async {
    if (bin == null) return markTestSkipped('Go is not installed');
    githubServes = Uint8List.fromList(utf8.encode('evil'));
    addTearDown(() => githubServes = gwFile);
    final c = client('gateway-linux-arm64', '1.9.0');
    final offer = await c.check();
    final dir = Directory('${tmp.path}/dl3');
    await expectLater(c.download(offer, dir), throwsA(isA<UpdateException>()));
    expect(dir.listSync(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the gateway updates itself and exits for a restart', () async {
    if (bin == null) return markTestSkipped('Go is not installed');
    if (Platform.isWindows || cpuName() != 'x86_64') {
      return markTestSkipped('needs linux x86_64');
    }
    final gwBin = '${tmp.path}/gwbin/gundil-gateway';
    Directory('${tmp.path}/gwbin').createSync();
    final b = await Process.run(
      'go',
      ['build', '-o', gwBin, '.'],
      workingDirectory: '../../gateway',
      environment: {'GOTOOLCHAIN': 'local', 'CGO_ENABLED': '0'},
    );
    expect(b.exitCode, 0, reason: '${b.stderr}');
    final conf = File('${tmp.path}/gw.conf')
      ..writeAsStringSync('''
password = correct horse battery
name = Router
relays = ${relay.url}
stun = 127.0.0.1:${stun.port}, 127.0.0.1:${stun.port}
state = ${tmp.path}/gw-state.json
test_scrypt_n = 1024
update_server = $code
test_update_delay = 1
web_listen = 127.0.0.1:0
''');
    final gw = await Process.start(gwBin, ['--config=${conf.path}']);
    final gwLog = StringBuffer();
    gw.stdout.transform(utf8.decoder).listen(gwLog.write);
    gw.stderr.transform(utf8.decoder).listen(gwLog.write);
    final exit = await gw.exitCode.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        gw.kill();
        return -1;
      },
    );
    expect(exit, 75, reason: gwLog.toString());
    expect(gwLog.toString(), contains('installed 9.9.9'));
    expect(File(gwBin).readAsStringSync(), 'NEW GATEWAY');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('another server key gets no answer', () async {
    if (bin == null) return markTestSkipped('Go is not installed');
    final k = Uint8List.fromList(List.generate(32, (i) => 7));
    final other =
        'GUNDIL-UPDATE-${base64Url.encode([...k, ...SHA256Digest().process(k).sublist(0, 3)]).replaceAll('=', '')}';
    UpdateClient.answerTimeout = const Duration(seconds: 3);
    addTearDown(() => UpdateClient.answerTimeout = const Duration(seconds: 20));
    await expectLater(
      client('android-arm64-v8a', '1.9.0', withCode: other).check(),
      throwsA(isA<UpdateException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
