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
  });

  final String host;
  final int port;
  final String username, password;

  /// Pan/tilt step of one press, in the camera's -1..1 range.
  static const double step = 0.1;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  Duration _clockOffset = Duration.zero;
  String? _ptzUrl, _profile;
  Future<void>? _ready;

  /// The camera refused RelativeMove: use ContinuousMove and Stop instead.
  bool _continuous = false;

  String get _deviceUrl => 'http://$host:$port/onvif/device_service';

  /// Moves the camera one step: [x] right (+) / left (-), [y] up (+) /
  /// down (-), each -1, 0 or 1.
  Future<void> move(int x, int y) async {
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
      final req = await _http.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType(
        'application',
        'soap+xml',
        charset: 'utf-8',
      );
      req.add(utf8.encode(envelope));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await utf8.decodeStream(res);
      if (res.statusCode == 200) return text;
      if (res.statusCode == 401 ||
          text.contains('NotAuthorized') ||
          text.contains('FailedAuthentication')) {
        throw OnvifException('The camera refused the camera account');
      }
      final reason =
          _between(text, '<env:Text', '</env:Text>') ??
          _between(text, '<SOAP-ENV:Text', '</SOAP-ENV:Text>') ??
          'HTTP ${res.statusCode}';
      throw OnvifException(
        'The camera refused: ${reason.replaceFirst(RegExp(r'^[^>]*>'), '')}',
      );
    } on OnvifException {
      rethrow;
    } on TimeoutException {
      throw OnvifException('The camera did not answer');
    } on SocketException catch (e) {
      throw OnvifException(e.osError?.message ?? e.message);
    } on HttpException catch (e) {
      throw OnvifException(e.message);
    }
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

  void close() => _http.close(force: true);
}
