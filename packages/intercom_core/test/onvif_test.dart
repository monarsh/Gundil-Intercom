import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:intercom_core/intercom_core.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

/// A camera that speaks just enough ONVIF, with WS-Security digest login
/// (user "cam", password "secret").
class FakeOnvif {
  FakeOnvif._(this.server) {
    server.listen(_serve);
  }
  static Future<FakeOnvif> start() async =>
      FakeOnvif._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer server;
  int get port => server.port;
  final moves = <String>[];
  bool relative = true;

  static String? tag(String xml, String name) =>
      RegExp('<(?:\\w+:)?$name(?:\\s[^>]*)?>([^<]*)<').firstMatch(xml)?[1];

  Future<void> _serve(HttpRequest req) async {
    // Like a Tapo: a request without a length gets the line hung up.
    if (req.headers.chunkedTransferEncoding || req.contentLength <= 0) {
      final s = await req.response.detachSocket(writeHeaders: false);
      s.destroy();
      return;
    }
    final body = await utf8.decodeStream(req);
    final res = req.response
      ..headers.contentType = ContentType.parse('application/soap+xml');
    String env(String b) =>
        '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:tt="http://www.onvif.org/ver10/schema"><env:Body>$b'
        '</env:Body></env:Envelope>';
    if (body.contains('GetSystemDateAndTime')) {
      final t = DateTime.now().toUtc();
      res.write(
        env(
          '<tds:GetSystemDateAndTimeResponse><tt:UTCDateTime><tt:Time>'
          '<tt:Hour>${t.hour}</tt:Hour><tt:Minute>${t.minute}</tt:Minute>'
          '<tt:Second>${t.second}</tt:Second></tt:Time><tt:Date>'
          '<tt:Year>${t.year}</tt:Year><tt:Month>${t.month}</tt:Month>'
          '<tt:Day>${t.day}</tt:Day></tt:Date></tt:UTCDateTime>'
          '</tds:GetSystemDateAndTimeResponse>',
        ),
      );
      return res.close();
    }
    final nonce = base64.decode(tag(body, 'Nonce') ?? '');
    final created = tag(body, 'Created') ?? '';
    final want = base64.encode(
      SHA1Digest().process(
        Uint8List.fromList([
          ...nonce,
          ...utf8.encode(created),
          ...utf8.encode('secret'),
        ]),
      ),
    );
    if (tag(body, 'Username') != 'cam' || tag(body, 'Password') != want) {
      res
        ..statusCode = 400
        ..write(
          env(
            '<env:Fault><env:Reason><env:Text>Sender not '
            'authorized</env:Text></env:Reason>ter:NotAuthorized</env:Fault>',
          ),
        );
      return res.close();
    }
    final base = 'http://127.0.0.1:$port/onvif/service';
    if (body.contains('GetCapabilities')) {
      res.write(
        env(
          '<tds:GetCapabilitiesResponse><tds:Capabilities>'
          '<tt:Media><tt:XAddr>$base</tt:XAddr></tt:Media>'
          '<tt:PTZ><tt:XAddr>$base</tt:XAddr></tt:PTZ>'
          '</tds:Capabilities></tds:GetCapabilitiesResponse>',
        ),
      );
    } else if (body.contains('GetProfiles')) {
      res.write(
        env(
          '<trt:GetProfilesResponse><trt:Profiles fixed="true" '
          'token="profile_1"><tt:Name>main</tt:Name></trt:Profiles>'
          '</trt:GetProfilesResponse>',
        ),
      );
    } else if (body.contains('RelativeMove') && relative) {
      expect(body, contains('<tptz:ProfileToken>profile_1<'));
      final m = RegExp(r'PanTilt x="([^"]+)" y="([^"]+)"').firstMatch(body)!;
      moves.add('rel ${m[1]} ${m[2]}');
      res.write(env('<tptz:RelativeMoveResponse/>'));
    } else if (body.contains('ContinuousMove')) {
      final m = RegExp(r'PanTilt x="([^"]+)" y="([^"]+)"').firstMatch(body)!;
      moves.add('cont ${m[1]} ${m[2]}');
      res.write(env('<tptz:ContinuousMoveResponse/>'));
    } else if (body.contains('<tptz:Stop>')) {
      moves.add('stop');
      res.write(env('<tptz:StopResponse/>'));
    } else {
      res
        ..statusCode = 400
        ..write(
          env(
            '<env:Fault><env:Reason><env:Text>Optional Action Not '
            'Implemented</env:Text></env:Reason></env:Fault>',
          ),
        );
    }
    await res.close();
  }
}

void main() {
  late FakeOnvif cam;
  setUp(() async => cam = await FakeOnvif.start());
  tearDown(() => cam.server.close(force: true));

  OnvifPtz ptz({String password = 'secret'}) => OnvifPtz(
    host: '127.0.0.1',
    port: cam.port,
    username: 'cam',
    password: password,
  );

  test('pans and tilts one step at a time', () async {
    final p = ptz();
    await p.move(1, 0);
    await p.move(0, -1);
    expect(cam.moves, ['rel 0.1 0.0', 'rel 0.0 -0.1']);
    p.close();
  });

  test('uses ContinuousMove and Stop when RelativeMove is refused', () async {
    cam.relative = false;
    final p = ptz();
    await p.move(-1, 0);
    expect(cam.moves, ['cont -0.5 0.0', 'stop']);
    p.close();
  });

  test('a wrong camera account is reported', () async {
    final p = ptz(password: 'nope');
    await expectLater(
      p.move(1, 0),
      throwsA(
        isA<OnvifException>().having(
          (e) => e.message,
          'message',
          contains('refused the camera account'),
        ),
      ),
    );
    p.close();
  });
}
