/// Pan & tilt through ONVIF, the standard camera control protocol. TP-Link
/// Tapo cameras answer it on port 2020 with their "camera account".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class OnvifException implements Exception {
  OnvifException(this.message);
  final String message;

  @override
  String toString() => message;
}

class OnvifPtz {
  OnvifPtz({
    required this.host,
    this.port = 2020,
    required this.username,
    required this.password,
    this.reversePan = false,
  });

  final String host;
  final int port;
  final String username, password;

  /// The camera turns the other way than ONVIF says for pan (Tapo C200
  /// family: a positive x turns it left), so right/left are swapped.
  final bool reversePan;

  /// Pan/tilt step of one press, in the camera's -1..1 range.
  static const double step = 0.1;

  Duration _clockOffset = Duration.zero;
  String? _ptzUrl, _profile;
  Future<void>? _ready;

  /// The camera refused RelativeMove: use ContinuousMove and Stop instead.
  bool _continuous = false;

  String get _deviceUrl => 'http://$host:$port/onvif/device_service';

  /// Moves the camera one step: [x] right (+) / left (-), [y] up (+) /
  /// down (-), each -1, 0 or 1.
  Future<void> move(int x, int y) async {
    if (reversePan) x = -x;
    await (_ready ??= _connect().catchError((Object e) {
      _ready = null;
      throw e;
    }));
    if (!_continuous) {
      try {
        await _call(
          _ptzUrl!,
          '<tptz:RelativeMove><tptz:ProfileToken>$_profile</tptz:ProfileToken>'
          '<tptz:Translation><tt:PanTilt x="${x * step}" y="${y * step}"/>'
          '</tptz:Translation></tptz:RelativeMove>',
        );
        return;
      } on OnvifException catch (e) {
        if (e.message.contains('refused the camera account')) rethrow;
        _continuous = true;
      }
    }
    await _call(
      _ptzUrl!,
      '<tptz:ContinuousMove><tptz:ProfileToken>$_profile</tptz:ProfileToken>'
      '<tptz:Velocity><tt:PanTilt x="${x * 0.5}" y="${y * 0.5}"/>'
      '</tptz:Velocity></tptz:ContinuousMove>',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _call(
      _ptzUrl!,
      '<tptz:Stop><tptz:ProfileToken>$_profile</tptz:ProfileToken>'
      '<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>false</tptz:Zoom>'
      '</tptz:Stop>',
    );
  }

  Future<void> _connect() async {
    // The login proof includes the time: use the camera's clock.
    try {
      final r = await _post(
        _deviceUrl,
        _envelope('<tds:GetSystemDateAndTime/>', secure: false),
      );
      final utc = _between(r, 'UTCDateTime>', 'UTCDateTime>');
      int? n(String tag) =>
          int.tryParse(_between(utc ?? '', '$tag>', '</') ?? '');
      final y = n('Year'), mo = n('Month'), d = n('Day');
      final h = n('Hour'), mi = n('Minute'), s = n('Second');
      if (y != null && mo != null && d != null && h != null && mi != null) {
        final cam = DateTime.utc(y, mo, d, h, mi, s ?? 0);
        _clockOffset = cam.difference(DateTime.now().toUtc());
      }
    } catch (_) {}
    final caps = await _call(
      _deviceUrl,
      '<tds:GetCapabilities><tds:Category>All</tds:Category>'
      '</tds:GetCapabilities>',
    );
    final ptz = _xaddr(caps, 'PTZ');
    final media = _xaddr(caps, 'Media');
    if (ptz == null) throw OnvifException('This camera has no pan & tilt');
    final profiles = await _call(media ?? _deviceUrl, '<trt:GetProfiles/>');
    final token = RegExp(
      r'Profiles[^>]*token="([^"]+)"',
    ).firstMatch(profiles)?[1];
    if (token == null) throw OnvifException('The camera has no profile');
    _ptzUrl = ptz;
    _profile = token;
  }

  static String? _xaddr(String xml, String service) => RegExp(
    '<(?:\\w+:)?$service>\\s*<(?:\\w+:)?XAddr>\\s*([^<\\s]+)',
  ).firstMatch(xml)?[1];

  static String? _between(String s, String a, String b) {
    final i = s.indexOf(a);
    if (i < 0) return null;
    final j = s.indexOf(b, i + a.length);
    return j < 0 ? null : s.substring(i + a.length, j);
  }

  Future<String> _call(String url, String body) => _post(url, _envelope(body));

  Future<String> _post(String url, String envelope) async {
    try {
      final (status, text) = await _send(
        Uri.parse(url),
        utf8.encode(envelope),
      ).timeout(const Duration(seconds: 8));
      if (status == 200) return text;
      if (status == 401 ||
          text.contains('NotAuthorized') ||
          text.contains('FailedAuthentication')) {
        throw OnvifException('The camera refused the camera account');
      }
      final reason =
          _between(text, '<env:Text', '</env:Text>') ??
          _between(text, '<SOAP-ENV:Text', '</SOAP-ENV:Text>') ??
          'HTTP $status';
      throw OnvifException(
        'The camera refused: ${reason.replaceFirst(RegExp(r'^[^>]*>'), '')}',
      );
    } on OnvifException {
      rethrow;
    } on TimeoutException {
      throw OnvifException('The camera did not answer');
    } on SocketException catch (e) {
      throw OnvifException(e.osError?.message ?? e.message);
    } on FormatException {
      throw OnvifException('The camera sent an answer the app can\'t read');
    }
  }

  /// One HTTP POST, written by hand: a fixed Content-Length (the camera's
  /// small web server hangs up on a chunked request, which is what Dart's
  /// HttpClient sends) and Connection: close, so the answer ends when the
  /// camera closes the connection.
  static Future<(int, String)> _send(Uri uri, List<int> body) async {
    final socket = await Socket.connect(
      uri.host,
      uri.hasPort ? uri.port : 80,
      timeout: const Duration(seconds: 5),
    );
    try {
      final path = uri.path.isEmpty ? '/' : uri.path;
      final query = uri.hasQuery ? '?${uri.query}' : '';
      socket.add(
        latin1.encode(
          'POST $path$query HTTP/1.1\r\n'
          'Host: ${uri.host}:${uri.hasPort ? uri.port : 80}\r\n'
          'Content-Type: application/soap+xml; charset=utf-8\r\n'
          'Content-Length: ${body.length}\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
      socket.add(body);
      await socket.flush();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in socket) {
        bytes.add(chunk);
      }
      return _parseResponse(bytes.takeBytes());
    } finally {
      socket.destroy();
    }
  }

  static (int, String) _parseResponse(Uint8List data) {
    var end = -1;
    for (var i = 0; i + 3 < data.length; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        end = i;
        break;
      }
    }
    if (end < 0) {
      throw const SocketException('The camera closed the connection');
    }
    final head = latin1.decode(data.sublist(0, end)).split('\r\n');
    final status = int.tryParse(head.first.split(' ').elementAtOrNull(1) ?? '');
    if (status == null) throw const FormatException('not HTTP');
    final headers = {
      for (final h in head.skip(1))
        if (h.contains(':'))
          h.substring(0, h.indexOf(':')).trim().toLowerCase(): h
              .substring(h.indexOf(':') + 1)
              .trim(),
    };
    var body = Uint8List.sublistView(data, end + 4);
    if ((headers['transfer-encoding'] ?? '').toLowerCase().contains(
      'chunked',
    )) {
      body = _dechunk(body);
    } else {
      final n = int.tryParse(headers['content-length'] ?? '');
      if (n != null && n < body.length) {
        body = Uint8List.sublistView(body, 0, n);
      }
    }
    return (status, utf8.decode(body, allowMalformed: true));
  }

  static Uint8List _dechunk(Uint8List data) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < data.length) {
      var j = i;
      while (j + 1 < data.length && !(data[j] == 13 && data[j + 1] == 10)) {
        j++;
      }
      final size = int.tryParse(
        latin1.decode(data.sublist(i, j)).split(';').first.trim(),
        radix: 16,
      );
      if (size == null || size == 0) break;
      final start = j + 2;
      final stop = (start + size).clamp(0, data.length);
      out.add(Uint8List.sublistView(data, start, stop));
      i = stop + 2;
    }
    return out.takeBytes();
  }

  String _envelope(String body, {bool secure = true}) =>
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
      'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
      'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
      'xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema">'
      '<s:Header>${secure ? _security() : ''}</s:Header>'
      '<s:Body>$body</s:Body></s:Envelope>';

  /// WS-Security UsernameToken with a password digest.
  String _security() {
    final rnd = math.Random.secure();
    final nonce = Uint8List.fromList(
      List.generate(16, (_) => rnd.nextInt(256)),
    );
    final created = DateTime.now()
        .toUtc()
        .add(_clockOffset)
        .toIso8601String()
        .replaceFirst(RegExp(r'\.\d+'), '');
    final digest = SHA1Digest().process(
      Uint8List.fromList([
        ...nonce,
        ...utf8.encode(created),
        ...utf8.encode(password),
      ]),
    );
    return '<Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/'
        'wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
        '<UsernameToken><Username>${_xml(username)}</Username>'
        '<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-'
        'wss-username-token-profile-1.0#PasswordDigest">'
        '${base64.encode(digest)}</Password>'
        '<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-'
        '200401-wss-soap-message-security-1.0#Base64Binary">'
        '${base64.encode(nonce)}</Nonce>'
        '<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-'
        'wss-wssecurity-utility-1.0.xsd">$created</Created>'
        '</UsernameToken></Security>';
  }

  static String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Nothing stays open between moves; kept for symmetry with the rest.
  void close() {}
}
