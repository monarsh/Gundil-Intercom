/// A small RTSP client that plays only the audio track (G.711) of an IP
/// camera, over the RTSP connection itself (interleaved RTP).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../debug_log.dart';
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
    String? name,
  }) : name = name ?? host;

  /// The camera's name in the debug log.
  final String name;

  void _log(String m) => debugLog('rtsp', '$name: $m');
  final Stopwatch _since = Stopwatch()..start();
  final Stopwatch _reportClock = Stopwatch()..start();
  Timer? _report;
  int _packets = 0, _audioPackets = 0, _bytes = 0;
  bool _heard = false;

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
    final clock = Stopwatch()..start();
    _log('→ $method $uri');
    _write(method, uri, extra);
    var r = await _response();
    _log('← ${r.$1} after ${msSince(clock)}');
    if (r.$1 == 401 && _nonce == null && !_basic) {
      final challenge = r.$2['www-authenticate'] ?? '';
      if (challenge.startsWith('Digest')) {
        _realm = between(challenge, 'realm="', '"');
        _nonce = between(challenge, 'nonce="', '"');
      } else {
        _basic = true;
      }
      _log(
        '→ $method again with the camera account '
        '(${_basic ? 'Basic' : 'Digest'} login as "$username")',
      );
      _write(method, uri, extra);
      r = await _response();
      _log('← ${r.$1} after ${msSince(clock)}');
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
    _log('connecting to $host:$port (audio only, path $path)');
    final Socket socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
    } catch (e) {
      _log('could not connect after ${msSince(_since)}: $e');
      rethrow;
    }
    _log('connected in ${msSince(_since)}');
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
      for (final line in const LineSplitter().convert(sdp)) {
        if (line.startsWith('m=') || line.startsWith('a=rtpmap:')) {
          _log('stream description: $line');
        }
      }
      final control = _audioControl(sdp);
      if (control == null) {
        _log('no G.711 audio track: nothing to hear over RTSP');
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
      _log(
        'audio track: ${_alaw ? 'A-law' : 'µ-law'} $_rate Hz; transport: '
        '${setup['transport'] ?? '-'}',
      );
      await _request('PLAY', base, 'Range: npt=0.000-\r\n');
    } catch (e) {
      _log('failed at "$step" after ${msSince(_since)}: $e');
      close();
      rethrow;
    }
    _log('playing after ${msSince(_since)}');
    _report = Timer.periodic(const Duration(seconds: 10), (_) {
      final secs = (_reportClock.elapsedMilliseconds / 1000).round();
      _reportClock.reset();
      _log(
        _packets == 0
            ? 'nothing received in the last $secs s'
            : '$_packets packets (${formatBytes(_bytes)}) in $secs s, '
                  '$_audioPackets audio',
      );
      _packets = _audioPackets = _bytes = 0;
    });
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
          final (code, _, _) = await _response(); // Answer to a keep-alive.
          if (code != 200) _log('keep-alive answered $code');
          continue;
        }
        final h = await _reader.read(4);
        final data = await _reader.read((h[2] << 8) | h[3]);
        lastData = DateTime.now();
        _packets++;
        _bytes += data.length;
        if (h[1] == 0) {
          _audioPackets++;
          if (!_heard) {
            _heard = true;
            _log('first audio packet after ${msSince(_since)}');
          }
        }
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
        _log('stream ended after ${msSince(_since)}: $e');
        close();
        onClosed(e);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    _report?.cancel();
    _log('closed after ${msSince(_since)}');
    try {
      if (_session.isNotEmpty) _write('TEARDOWN', _url);
    } catch (_) {}
    _reader.cancel();
    _socket?.destroy();
  }
}
