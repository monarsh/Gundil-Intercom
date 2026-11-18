import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
String sha(String s) => hex(SHA256Digest().process(utf8.encode(s)));
String md5(String s) => hex(MD5Digest().process(utf8.encode(s)));

/// A Tapo camera's local control interface (plain HTTP here), with the
/// old login ([secure] false) or the newer secure one.
class FakeTapoControl {
  FakeTapoControl._(this.server, this.password, this.secure, this.sha256) {
    server.listen(_serve);
  }

  static Future<FakeTapoControl> start(
    String password, {
    bool secure = true,
    bool sha256 = true,
  }) async => FakeTapoControl._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    password,
    secure,
    sha256,
  );

  final HttpServer server;
  final String password;
  final bool secure, sha256;
  int get port => server.port;

  final requests = <Map<String, Object?>>[];
  final String nonce = 'ABCDEF0123456789';
  String cnonce = '';
  int seq = 7;
  Uint8List? lsk, ivb;

  String get hashed => sha256 ? sha(password) : md5(password);

  Future<void> _serve(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final j = jsonDecode(body) as Map<String, Object?>;
    final params = (j['params'] as Map?)?.cast<String, Object?>() ?? {};
    Object? answer;
    if (req.uri.path == '/') {
      expect(j['method'], 'login');
      if (!secure) {
        if (params['encrypt_type'] == '3') {
          answer = {'error_code': -40401};
        } else if (params['password'] == md5(password) &&
            params['hashed'] == true) {
          answer = {
            'error_code': 0,
            'result': {'stok': 'tok1'},
          };
        } else {
          answer = {'error_code': -40401};
        }
      } else if (!params.containsKey('cnonce')) {
        answer = {
          'error_code': -40413,
          'result': {
            'data': {
              'encrypt_type': ['3'],
            },
          },
        };
      } else if (!params.containsKey('digest_passwd')) {
        cnonce = params['cnonce'] as String;
        answer = {
          'error_code': -40413,
          'result': {
            'data': {
              'nonce': nonce,
              'device_confirm': '${sha(cnonce + hashed + nonce)}$nonce$cnonce',
            },
          },
        };
      } else if (params['digest_passwd'] ==
          '${sha(hashed + cnonce + nonce)}$cnonce$nonce') {
        final key = sha(cnonce + hashed + nonce);
        Uint8List token(String k) => Uint8List.sublistView(
          SHA256Digest().process(utf8.encode(k + cnonce + nonce + key)),
          0,
          16,
        );
        lsk = token('lsk');
        ivb = token('ivb');
        answer = {
          'error_code': 0,
          'result': {'stok': 'tok2', 'start_seq': seq},
        };
      } else {
        answer = {'error_code': -40401};
      }
    } else if (!secure) {
      expect(req.uri.path, '/stok=tok1/ds');
      requests.add(j);
      answer = {
        'error_code': 0,
        'result': {
          'responses': [
            {'method': 'rebootDevice', 'error_code': 0},
          ],
        },
      };
    } else {
      expect(req.uri.path, '/stok=tok2/ds');
      expect(j['method'], 'securePassthrough');
      expect(req.headers.value('seq'), '$seq');
      expect(
        req.headers.value('tapo_tag'),
        sha('${sha(hashed + cnonce)}$body$seq'),
      );
      seq++;
      final inner = utf8.decode(
        _aes(base64.decode(params['request'] as String), false),
      );
      requests.add(jsonDecode(inner) as Map<String, Object?>);
      final reply = jsonEncode({
        'error_code': 0,
        'result': {
          'responses': [
            {'method': 'rebootDevice', 'error_code': 0},
          ],
        },
      });
      answer = {
        'error_code': 0,
        'result': {'response': base64.encode(_aes(utf8.encode(reply), true))},
      };
    }
    req.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(answer));
    await req.response.close();
  }

  Uint8List _aes(List<int> data, bool encrypt) =>
      (PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
            encrypt,
            PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
              ParametersWithIV(KeyParameter(lsk!), ivb!),
              null,
            ),
          ))
          .process(Uint8List.fromList(data));
}

void main() {
  const reboot = {
    'method': 'multipleRequest',
    'params': {
      'requests': [
        {
          'method': 'rebootDevice',
          'params': {
            'system': {'reboot': 'null'},
          },
        },
      ],
    },
  };

  TapoControl control(FakeTapoControl cam, String password) => TapoControl(
    host: '127.0.0.1',
    port: cam.port,
    cloudPassword: password,
    useTls: false,
  );

  test('restarts a camera with the secure login (SHA-256)', () async {
    final cam = await FakeTapoControl.start('hunter2');
    addTearDown(() => cam.server.close(force: true));
    await control(cam, 'hunter2').reboot();
    expect(cam.requests, [reboot]);
  });

  test('restarts a camera with the secure login (MD5)', () async {
    final cam = await FakeTapoControl.start('hunter2', sha256: false);
    addTearDown(() => cam.server.close(force: true));
    await control(cam, 'hunter2').reboot();
    expect(cam.requests, [reboot]);
  });

  test('restarts a camera with the old login', () async {
    final cam = await FakeTapoControl.start('hunter2', secure: false);
    addTearDown(() => cam.server.close(force: true));
    await control(cam, 'hunter2').reboot();
    expect(cam.requests, [reboot]);
  });

  for (final secure in [true, false]) {
    test('a wrong cloud password is refused (secure: $secure)', () async {
      final cam = await FakeTapoControl.start('hunter2', secure: secure);
      addTearDown(() => cam.server.close(force: true));
      await expectLater(
        control(cam, 'nope').reboot(),
        throwsA(
          isA<TapoControlException>().having(
            (e) => e.message,
            'message',
            contains('refused the cloud password'),
          ),
        ),
      );
      expect(cam.requests, isEmpty);
    });
  }

  test('an unreachable camera says so', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    await expectLater(
      TapoControl(
        host: '127.0.0.1',
        port: port,
        cloudPassword: 'x',
        useTls: false,
      ).reboot(),
      throwsA(isA<TapoControlException>()),
    );
  });
}
