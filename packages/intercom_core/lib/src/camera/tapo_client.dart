/// TP-Link Tapo camera stream (port 8800): the camera's microphone, and
/// talking through its speaker.
///
/// TP-Link doesn't document this protocol. It was worked out by the go2rtc
/// project (https://github.com/AlexxIT/go2rtc, MIT licence, pkg/tapo),
/// which this follows.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'byte_reader.dart';
import 'mpegts.dart';

class TapoException implements Exception {
  TapoException(this.message, {this.badLogin = false});
  final String message;

  /// The camera refused the cloud password.
  final bool badLogin;

  @override
  String toString() => message;
}

String _hex(Uint8List b, {bool upper = false}) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return upper ? s.toUpperCase() : s;
}

Uint8List _md5(String s) => MD5Digest().process(utf8.encode(s));
String _md5Hex(List<String> parts) => _hex(_md5(parts.join(':')));

/// One authenticated connection to the camera's stream port.
class _TapoConn {
  _TapoConn(this.socket, this.reader, this.key, this.iv);

  final Socket socket;
  final ByteReader reader;
  final Uint8List key, iv;

  static const _clientBoundary = '--client-stream-boundary--';
  static const _deviceBoundary = '--device-stream-boundary--';

  static Future<_TapoConn> open(
    String host,
    int port,
    String cloudPassword, {
    void Function(String step)? onStep,
    void Function(Socket socket)? onSocket,
  }) async {
    onStep?.call('connecting');
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    onSocket?.call(socket);
    socket.setOption(SocketOption.tcpNoDelay, true);
    // Write errors (camera gone) show up on the reader; don't let them
    // escape as uncaught errors.
    socket.done.catchError((Object _) {});
    final reader = ByteReader(socket);
    onStep?.call('logging in');
    try {
      String request([String? auth]) =>
          'POST /stream HTTP/1.1\r\n'
          'Host: $host:$port\r\n'
          'User-Agent: Go-http-client/1.1\r\n'
          'Content-Length: 0\r\n'
          'Content-Type: multipart/mixed; boundary=$_clientBoundary\r\n'
          '${auth == null ? '' : 'Authorization: $auth\r\n'}'
          '\r\n';

      socket.add(latin1.encode(request()));
      var status = await reader.readLine();
      var headers = await reader.readHeaders();
      await reader.read(int.tryParse(headers['content-length'] ?? '') ?? 0);
      final challenge = headers['www-authenticate'] ?? '';
      if (!status.contains(' 401') || !challenge.startsWith('Digest')) {
        throw TapoException('Unexpected answer from the camera: $status');
      }

      var username = 'admin';
      var password = _hashPassword(cloudPassword, challenge);
      final realm = between(challenge, 'realm="', '"');
      final nonce = between(challenge, 'nonce="', '"');
      final qop = between(challenge, 'qop="', '"');
      const uri = '/stream';
      final ha1 = _md5Hex([username, realm, password]);
      final ha2 = _md5Hex(['POST', uri]);
      const nc = '00000001';
      final cnonce = _random(32);
      final response = _md5Hex([ha1, nonce, nc, cnonce, qop, ha2]);
      var auth =
          'Digest username="$username", realm="$realm", nonce="$nonce", '
          'uri="$uri", qop=$qop, nc=$nc, cnonce="$cnonce", '
          'response="$response"';
      final opaque = between(challenge, 'opaque="', '"');
      if (opaque.isNotEmpty) auth += ', opaque="$opaque", algorithm=MD5';

      socket.add(latin1.encode(request(auth)));
      status = await reader.readLine();
      headers = await reader.readHeaders();
      if (status.contains(' 401')) {
        throw TapoException(
          'The camera refused the cloud password',
          badLogin: true,
        );
      }
      if (!status.contains(' 200')) {
        throw TapoException('The camera answered: $status');
      }

      final exchange = headers['key-exchange'] ?? '';
      final keyNonce = between(exchange, 'nonce="', '"');
      password = _hashPassword(cloudPassword, exchange);
      if (exchange.contains('username="none"')) {
        username = 'none';
        password = 'TPL075526460603';
      }
      return _TapoConn(
        socket,
        reader,
        _md5('$keyNonce:$password'),
        _md5('$username:$keyNonce'),
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// Upper-case hex MD5 of the cloud password, or SHA-256 on firmware that
  /// asks for it.
  static String _hashPassword(String cloudPassword, String header) {
    final bytes = utf8.encode(cloudPassword);
    return header.contains('encrypt_type="3"')
        ? _hex(SHA256Digest().process(bytes), upper: true)
        : _hex(MD5Digest().process(bytes), upper: true);
  }

  static String _random(int n) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  void writePart(
    String contentType,
    Uint8List body, {
    String extra = '',
    bool crlf = true,
  }) {
    final head = latin1.encode(
      '--$_clientBoundary\r\n'
      'Content-Type: $contentType\r\n'
      '$extra'
      'Content-Length: ${body.length}\r\n\r\n',
    );
    final out = Uint8List(head.length + body.length + (crlf ? 2 : 0))
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + body.length, body);
    if (crlf) {
      out[out.length - 2] = 13;
      out[out.length - 1] = 10;
    }
    socket.add(out);
  }

  /// The next part the camera sends: its headers and body.
  Future<(Map<String, String>, Uint8List)> readPart() async {
    while (true) {
      final line = await reader.readLine(max: 1 << 20);
      if (line.startsWith('--$_deviceBoundary')) break;
    }
    final headers = await reader.readHeaders();
    final length = int.tryParse(headers['content-length'] ?? '');
    if (length == null || length < 0 || length > (8 << 20)) {
      throw TapoException('Unexpected data from the camera');
    }
    return (headers, await reader.read(length));
  }

  /// Sends a JSON request and returns the session id of the answer.
  Future<String> request(String json) async {
    writePart('application/json', utf8.encode(json));
    await socket.flush();
    while (true) {
      final (headers, body) = await readPart();
      if (!(headers['content-type'] ?? '').contains('json')) continue;
      final Object? v;
      try {
        v = jsonDecode(utf8.decode(decryptIfNeeded(headers, body)));
      } catch (_) {
        throw TapoException('The camera sent an answer we cannot read');
      }
      final params = v is Map ? v['params'] : null;
      if (params is! Map) throw TapoException('The camera refused: $v');
      final code = params['error_code'];
      if (code is int && code != 0) {
        throw TapoException('The camera refused (error $code)');
      }
      return '${params['session_id'] ?? ''}';
    }
  }

  Uint8List decryptIfNeeded(Map<String, String> headers, Uint8List body) =>
      headers['x-if-encrypt'] == '1' ? decrypt(body) : body;

  /// AES-128-CBC with the same IV for every part, PKCS#7 padded.
  Uint8List decrypt(Uint8List body) {
    if (body.isEmpty || body.length % 16 != 0) return body;
    final cbc = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(body.length);
    for (var i = 0; i < body.length; i += 16) {
      cbc.processBlock(body, i, out, i);
    }
    final pad = out.last;
    if (pad < 1 || pad > 16) return out;
    return Uint8List.sublistView(out, 0, out.length - pad);
  }

  void close() {
    reader.cancel();
    socket.destroy();
  }
}

/// A live session with a Tapo camera: [onAudio] gets what its microphone
/// hears; [sendAudio] plays through its speaker once [startTalk] succeeded.
class TapoClient {
  TapoClient({
    required this.host,
    required this.cloudPassword,
    this.port = 8800,
    required this.onAudio,
    required this.onClosed,
  });

  final String host;
  final int port;
  final String cloudPassword;

  /// G.711 audio from the camera (see [TsAudio.streamType]).
  final void Function(TsAudio audio) onAudio;

  /// The stream ended (null = we closed it).
  final void Function(Object? error) onClosed;

  _TapoConn? _listen, _talk;
  String _talkSession = '';
  final TsAudioMuxer _muxer = TsAudioMuxer();
  bool _closed = false;

  /// Last time the camera sent anything.
  DateTime lastData = DateTime.now();

  bool get canTalk => _talk != null;

  /// What [start] and [startTalk] are doing (or were doing when they
  /// failed): 'connecting', 'logging in', 'starting the stream', ...
  String listenStep = '', talkStep = '';

  /// Every connection we opened, so [close] also drops one that is still
  /// logging in (a Tapo only takes a few connections at a time).
  final List<Socket> _sockets = [];

  void _opened(Socket socket) {
    if (_closed) {
      socket.destroy();
    } else {
      _sockets.add(socket);
    }
  }

  /// Logs in and starts receiving the camera's stream.
  Future<void> start() async {
    final conn = await _TapoConn.open(
      host,
      port,
      cloudPassword,
      onStep: (s) => listenStep = s,
      onSocket: _opened,
    );
    if (_closed) {
      conn.close();
      return;
    }
    _listen = conn;
    listenStep = 'starting the stream';
    // The small picture: we only use the sound.
    await conn.request(
      '{"params":{"preview":{"audio":["default"],"channels":[0],'
      '"resolutions":["VGA"]},"method":"get"},"seq":1,"type":"request"}',
    );
    unawaited(_receive(conn));
  }

  Future<void> _receive(_TapoConn conn) async {
    final demux = TsAudioDemuxer();
    try {
      while (!_closed) {
        final (headers, body) = await conn.readPart();
        lastData = DateTime.now();
        if (headers['content-type'] != 'video/mp2t') continue;
        // Media is always encrypted (go2rtc decrypts unconditionally).
        final ts = headers['x-if-encrypt'] == '0' ? body : conn.decrypt(body);
        for (final a in demux.add(ts)) {
          onAudio(a);
        }
      }
    } catch (e) {
      if (!_closed) {
        close();
        onClosed(e);
      }
    }
  }

  /// Opens the line to the camera's speaker.
  Future<void> startTalk() async {
    final conn = await _TapoConn.open(
      host,
      port,
      cloudPassword,
      onStep: (s) => talkStep = s,
      onSocket: _opened,
    );
    talkStep = 'opening the speaker';
    try {
      _talkSession = await conn.request(
        '{"params":{"talk":{"mode":"aec"},"method":"get"},"seq":3,'
        '"type":"request"}',
      );
    } catch (_) {
      conn.close();
      rethrow;
    }
    if (_closed) {
      conn.close();
      return;
    }
    _talk = conn;
    _writeTalk(_muxer.header());
    // Read (and ignore) whatever it answers, to notice when it hangs up.
    unawaited(() async {
      try {
        while (true) {
          await conn.readPart();
        }
      } catch (_) {
        if (identical(_talk, conn)) _talk = null;
        conn.close();
      }
    }());
  }

  void _writeTalk(Uint8List ts) {
    try {
      _talk?.writePart(
        'audio/mp2t',
        ts,
        extra: 'X-If-Encrypt: 0\r\nX-Session-Id: $_talkSession\r\n',
        crlf: false,
      );
    } catch (_) {
      _talk?.close();
      _talk = null;
    }
  }

  /// Plays A-law audio (8 kHz) through the camera's speaker.
  void sendAudio(Uint8List alaw) {
    if (_talk == null || alaw.isEmpty) return;
    _writeTalk(_muxer.audio(alaw));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _listen?.close();
    _talk?.close();
    _listen = null;
    _talk = null;
    for (final s in _sockets) {
      s.destroy();
    }
    _sockets.clear();
  }
}
