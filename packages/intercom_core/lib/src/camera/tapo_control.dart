/// The Tapo camera's local control interface (HTTPS, port 443): the
/// commands the Tapo app sends, such as restarting the camera.
///
/// TP-Link doesn't document it. This follows the pytapo project
/// (https://github.com/JurajNyiri/pytapo, MIT licence), which Home
/// Assistant's Tapo integration uses.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class TapoControlException implements Exception {
  TapoControlException(this.message, {this.badLogin = false});
  final String message;
  final bool badLogin;

  @override
  String toString() => message;
}

class TapoControl {
  TapoControl({
    required this.host,
    required this.cloudPassword,
    this.port = 443,
    this.timeout = const Duration(seconds: 10),
    this.useTls = true,
  });

  /// Tests only: plain HTTP.
  final bool useTls;

  final String host;
  final int port;
  final String cloudPassword;
  final Duration timeout;

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  static String _sha256(String s) =>
      _hex(SHA256Digest().process(utf8.encode(s)));
  static String _md5(String s) => _hex(MD5Digest().process(utf8.encode(s)));

  String? _stok;
  bool _secure = false;
  String _cnonce = '', _hashed = '';
  Uint8List? _lsk, _ivb;
  int _seq = 0;

  /// Restarts the camera.
  Future<void> reboot() async {
    await _login();
    await _call({
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
    });
  }

  Future<void> _login() async {
    // Newer firmware: a secure login (nonces, then encrypted requests).
    final probe = await _post('/', {
      'method': 'login',
      'params': {'encrypt_type': '3', 'username': 'admin'},
    });
    final data = _map(_map(probe['result'])['data']);
    final types = data['encrypt_type'];
    _secure =
        (types is List && types.map((t) => '$t').contains('3')) || types == '3';
    if (!_secure) {
      final r = await _post('/', {
        'method': 'login',
        'params': {
          'hashed': true,
          'password': _md5(cloudPassword),
          'username': 'admin',
        },
      });
      _check(r);
      _stok = '${_map(r['result'])['stok'] ?? ''}';
      if (_stok!.isEmpty) throw TapoControlException('The camera login failed');
      return;
    }

    final rnd = Random.secure();
    _cnonce = _hex(List.generate(8, (_) => rnd.nextInt(256)));
    final r1 = await _post('/', {
      'method': 'login',
      'params': {'cnonce': _cnonce, 'encrypt_type': '3', 'username': 'admin'},
    });
    final d1 = _map(_map(r1['result'])['data']);
    final nonce = '${d1['nonce'] ?? ''}';
    final confirm = '${d1['device_confirm'] ?? ''}';
    if (nonce.isEmpty || confirm.isEmpty) _check(r1, login: true);
    // The camera proves it knows the password, as SHA-256 or MD5.
    String proof(String h) => '${_sha256(_cnonce + h + nonce)}$nonce$_cnonce';
    final sha = _sha256(cloudPassword), md5 = _md5(cloudPassword);
    if (confirm == proof(sha)) {
      _hashed = sha;
    } else if (confirm == proof(md5)) {
      _hashed = md5;
    } else {
      throw TapoControlException(
        'The camera refused the cloud password',
        badLogin: true,
      );
    }
    final digest = '${_sha256(_hashed + _cnonce + nonce)}$_cnonce$nonce';
    final r2 = await _post('/', {
      'method': 'login',
      'params': {
        'cnonce': _cnonce,
        'encrypt_type': '3',
        'digest_passwd': digest,
        'username': 'admin',
      },
    });
    _check(r2, login: true);
    final res = _map(r2['result']);
    _stok = '${res['stok'] ?? ''}';
    if (_stok!.isEmpty) throw TapoControlException('The camera login failed');
    _seq = res['start_seq'] is int ? res['start_seq'] as int : 0;
    final key = _sha256(_cnonce + _hashed + nonce);
    Uint8List token(String kind) => Uint8List.sublistView(
      SHA256Digest().process(utf8.encode(kind + _cnonce + nonce + key)),
      0,
      16,
    );
    _lsk = token('lsk');
    _ivb = token('ivb');
  }

  Future<Map<String, Object?>> _call(Map<String, Object?> request) async {
    final path = '/stok=$_stok/ds';
    if (!_secure) {
      final r = await _post(path, request);
      _check(r);
      return r;
    }
    final body = jsonEncode({
      'method': 'securePassthrough',
      'params': {
        'request': base64.encode(_aes(utf8.encode(jsonEncode(request)), true)),
      },
    });
    final tag = _sha256('${_sha256(_hashed + _cnonce)}$body$_seq');
    final outer = await _send(path, body, {'Seq': '$_seq', 'Tapo_tag': tag});
    _seq++;
    _check(outer);
    final inner = '${_map(outer['result'])['response'] ?? ''}';
    if (inner.isEmpty) return outer;
    final Object? v;
    try {
      v = jsonDecode(utf8.decode(_aes(base64.decode(inner), false)));
    } catch (_) {
      throw TapoControlException('The camera sent an answer we cannot read');
    }
    final r = _map(v);
    _check(r);
    // multipleRequest: each answer has its own error code.
    final list = _map(r['result'])['responses'];
    if (list is List) {
      for (final a in list) {
        _check(_map(a));
      }
    }
    return r;
  }

  Uint8List _aes(List<int> data, bool encrypt) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            encrypt,
            PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
              ParametersWithIV(KeyParameter(_lsk!), _ivb!),
              null,
            ),
          );
    return cipher.process(Uint8List.fromList(data));
  }

  static Map<String, Object?> _map(Object? v) =>
      v is Map ? v.cast<String, Object?>() : const {};

  static void _check(Map<String, Object?> r, {bool login = false}) {
    final code = r['error_code'];
    if (code is! int || code == 0) return;
    // -40401: wrong password; -40404/-40413: login refused.
    if (login || code == -40401) {
      throw TapoControlException(
        code == -40404
            ? 'The camera blocked logins for a while (too many tries)'
            : 'The camera refused the cloud password',
        badLogin: true,
      );
    }
    if (code == -40106 || code == -40210) {
      throw TapoControlException('This camera does not allow that command');
    }
    throw TapoControlException('The camera refused (error $code)');
  }

  Future<Map<String, Object?>> _post(String path, Map<String, Object?> json) =>
      _send(path, jsonEncode(json), const {});

  Future<Map<String, Object?>> _send(
    String path,
    String body,
    Map<String, String> extra,
  ) async {
    // The camera's certificate is its own (self-signed): accept it for
    // this camera only.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..badCertificateCallback = (_, h, p) => h == host && p == port;
    try {
      return await () async {
        final hostPart = host.contains(':') ? '[$host]' : host;
        final req = await client.postUrl(
          Uri.parse('${useTls ? 'https' : 'http'}://$hostPart:$port$path'),
        );
        final bytes = utf8.encode(body);
        req.headers
          ..set('Content-Type', 'application/json; charset=UTF-8')
          ..set('Accept', 'application/json')
          ..set('User-Agent', 'Tapo CameraClient Android')
          ..set('Referer', 'https://$hostPart')
          ..set('requestByApp', 'true')
          ..contentLength = bytes.length;
        extra.forEach(req.headers.set);
        req.add(bytes);
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        if (res.statusCode == 401) {
          throw TapoControlException(
            'The camera refused the cloud password',
            badLogin: true,
          );
        }
        final Object? v;
        try {
          v = jsonDecode(text);
        } catch (_) {
          throw TapoControlException(
            'The camera answered HTTP ${res.statusCode}',
          );
        }
        return _map(v);
      }().timeout(timeout);
    } on TimeoutException {
      throw TapoControlException('The camera did not answer');
    } on SocketException catch (e) {
      throw TapoControlException(e.osError?.message ?? e.message);
    } on HandshakeException {
      throw TapoControlException('Could not set up a secure connection');
    } finally {
      client.close(force: true);
    }
  }
}
