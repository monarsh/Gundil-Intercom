/// A small RTSP client that plays only the audio track (G.711) of an IP
/// camera, over the RTSP connection itself (interleaved RTP).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'byte_reader.dart';

class RtspException implements Exception {
  RtspException(this.message, {this.badLogin = false});
  final String message;
  final bool badLogin;

  @override
  String toString() => message;
}

class RtspAudioClient {
  RtspAudioClient({
    required this.host,
    this.port = 554,
    this.path = '/stream2',
    required this.username,
    required this.password,
    required this.onAudio,
    required this.onClosed,
  });

  final String host;
  final int port;
  final String path;
  final String username, password;

  /// G.711 payload; [alaw] false means µ-law. [rate] is 8000 or 16000.
  final void Function(
    Uint8List payload, {
    required bool alaw,
    required int rate,
  })
  onAudio;
  final void Function(Object? error) onClosed;

  Socket? _socket;
  late ByteReader _reader;
  int _cseq = 0;
  String _session = '';
  String? _realm, _nonce;
  bool _basic = false;
  bool _closed = false;
  Timer? _keepAlive;
  bool _alaw = true;
  int _rate = 8000;

  DateTime lastData = DateTime.now();

  String get _url => 'rtsp://$host:$port$path';

  static String _md5(String s) => MD5Digest()
      .process(utf8.encode(s))
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();

  String _auth(String method, String uri) {
    if (_basic) {
      return 'Authorization: Basic '
          '${base64.encode(utf8.encode('$username:$password'))}\r\n';
    }
    if (_nonce == null) return '';
    final ha1 = _md5('$username:$_realm:$password');
    final ha2 = _md5('$method:$uri');
    final response = _md5('$ha1:$_nonce:$ha2');
    return 'Authorization: Digest username="$username", realm="$_realm", '
        'nonce="$_nonce", uri="$uri", response="$response"\r\n';
  }

  void _write(String method, String uri, [String extra = '']) {
    _socket!.add(
      latin1.encode(
        '$method $uri RTSP/1.0\r\n'
        'CSeq: ${++_cseq}\r\n'
        'User-Agent: GundilIntercom\r\n'
        '${_auth(method, uri)}'
        '${_session.isEmpty ? '' : 'Session: $_session\r\n'}'
        '$extra\r\n',
      ),
    );
  }

  Future<(int, Map<String, String>, String)> _response() async {
    final status = await _reader.readLine();
    final headers = await _reader.readHeaders();
    final n = int.tryParse(headers['content-length'] ?? '') ?? 0;
    final body = n > 0 ? latin1.decode(await _reader.read(n)) : '';
    final code = int.tryParse(status.split(' ').elementAtOrNull(1) ?? '') ?? 0;
    return (code, headers, body);
  }

  /// Sends a request; answers a login challenge once.
  Future<(int, Map<String, String>, String)> _request(
    String method,
    String uri, [
    String extra = '',
  ]) async {
    _write(method, uri, extra);
    var r = await _response();
    if (r.$1 == 401 && _nonce == null && !_basic) {
      final challenge = r.$2['www-authenticate'] ?? '';
      if (challenge.startsWith('Digest')) {
        _realm = between(challenge, 'realm="', '"');
        _nonce = between(challenge, 'nonce="', '"');
      } else {
        _basic = true;
      }
      _write(method, uri, extra);
      r = await _response();
    }
    if (r.$1 == 401) {
      throw RtspException(
        'The camera refused the camera account',
        badLogin: true,
      );
    }
    if (r.$1 != 200) throw RtspException('RTSP $method failed (${r.$1})');
    return r;
  }

  /// What [start] is doing (or was doing when it failed).
  String step = '';

  Future<void> start() async {
    step = 'connecting';
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    _socket = socket;
    socket.done.catchError((Object _) {});
    _reader = ByteReader(socket);
    step = 'logging in';
    try {
      final (_, headers, sdp) = await _request(
        'DESCRIBE',
        _url,
        'Accept: application/sdp\r\n',
      );
      final control = _audioControl(sdp);
      if (control == null) {
        throw RtspException('The camera stream has no G.711 audio');
      }
      var base = headers['content-base'] ?? _url;
      if (!base.endsWith('/')) base = '$base/';
      final track = control.startsWith('rtsp://') ? control : '$base$control';
      step = 'starting the stream';
      final (_, setup, _) = await _request(
        'SETUP',
        track,
        'Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n',
      );
      _session = (setup['session'] ?? '').split(';').first.trim();
      await _request('PLAY', base, 'Range: npt=0.000-\r\n');
    } catch (_) {
      close();
      rethrow;
    }
    _keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
      try {
        _write('OPTIONS', _url);
      } catch (_) {}
    });
    unawaited(_receive());
  }

  /// The control URL of the first G.711 audio track in [sdp].
  String? _audioControl(String sdp) {
    var inAudio = false;
    var ok = false;
    for (final line in const LineSplitter().convert(sdp)) {
      if (line.startsWith('m=')) {
        if (ok) break;
        inAudio = line.startsWith('m=audio');
        if (inAudio) {
          final pt = line.split(' ').elementAtOrNull(3);
          if (pt == '8' || pt == '0') {
            ok = true;
            _alaw = pt == '8';
            _rate = 8000;
          }
        }
      } else if (inAudio && line.startsWith('a=rtpmap:')) {
        final m = RegExp(
          r'(PCMA|PCMU)/(\d+)',
          caseSensitive: false,
        ).firstMatch(line);
        if (m != null) {
          ok = true;
          _alaw = m[1]!.toUpperCase() == 'PCMA';
          _rate = int.parse(m[2]!);
        }
      } else if (inAudio && ok && line.startsWith('a=control:')) {
        return line.substring('a=control:'.length).trim();
      }
    }
    return null;
  }

  Future<void> _receive() async {
    try {
      while (!_closed) {
        if (await _reader.peekByte() != 0x24) {
          await _response(); // Answer to a keep-alive.
          continue;
        }
        final h = await _reader.read(4);
        final data = await _reader.read((h[2] << 8) | h[3]);
        lastData = DateTime.now();
        if (h[1] != 0 || data.length < 12) continue; // RTCP etc.
        var off = 12 + (data[0] & 0x0F) * 4;
        if ((data[0] & 0x10) != 0 && data.length >= off + 4) {
          off += 4 + ((data[off + 2] << 8) | data[off + 3]) * 4;
        }
        var end = data.length;
        if ((data[0] & 0x20) != 0) end -= data.last; // Padding.
        if (off < end) {
          onAudio(
            Uint8List.sublistView(data, off, end),
            alaw: _alaw,
            rate: _rate,
          );
        }
      }
    } catch (e) {
      if (!_closed) {
        close();
        onClosed(e);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    try {
      if (_session.isNotEmpty) _write('TEARDOWN', _url);
    } catch (_) {}
    _reader.cancel();
    _socket?.destroy();
  }
}
