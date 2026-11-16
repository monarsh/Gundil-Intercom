import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:intercom_core/src/camera/byte_reader.dart';
import 'package:intercom_core/src/camera/g711.dart';
import 'package:intercom_core/src/camera/mpegts.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List md5(String s) => MD5Digest().process(utf8.encode(s));

/// Stands in for a Tapo camera's stream port, following the protocol as
/// go2rtc describes it.
class FakeTapo {
  FakeTapo._(this._server, this.cloudPassword, this.sha256) {
    _server.listen(_serve);
  }

  static Future<FakeTapo> start(
    String cloudPassword, {
    bool sha256 = false,
  }) async => FakeTapo._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    cloudPassword,
    sha256,
  );

  final ServerSocket _server;
  final String cloudPassword;
  final bool sha256;
  bool allowTalk = true;
  static const nonce = 'abc123nonce';

  /// A-law bytes that arrived for the speaker.
  final List<int> spoken = [];
  final List<Socket> _sockets = [];
  final List<Timer> _timers = [];

  int get port => _server.port;

  String get _hash {
    final bytes = utf8.encode(cloudPassword);
    final d = sha256
        ? SHA256Digest().process(bytes)
        : MD5Digest().process(bytes);
    return hex(d).toUpperCase();
  }

  Future<void> _serve(Socket s) async {
    _sockets.add(s);
    s.done.catchError((Object _) {});
    final r = ByteReader(s);
    try {
      // First request: no credentials.
      await r.readLine();
      await r.readHeaders();
      s.add(
        latin1.encode(
          'HTTP/1.1 401 Unauthorized\r\n'
          'WWW-Authenticate: Digest realm="TP-LINK IP-Camera", '
          'nonce="$nonce", qop="auth"'
          '${sha256 ? ', encrypt_type="3"' : ''}\r\n'
          'Content-Length: 0\r\n\r\n',
        ),
      );
      final line = await r.readLine();
      final h = await r.readHeaders();
      expect(line, 'POST /stream HTTP/1.1');
      final auth = h['authorization'] ?? '';
      final ha1 = hex(md5('admin:TP-LINK IP-Camera:$_hash'));
      final ha2 = hex(md5('POST:/stream'));
      final cnonce = between(auth, 'cnonce="', '"');
      final want = hex(md5('$ha1:$nonce:00000001:$cnonce:auth:$ha2'));
      if (between(auth, 'response="', '"') != want) {
        s.add(
          latin1.encode(
            'HTTP/1.1 401 Unauthorized\r\n'
            'WWW-Authenticate: Digest realm="TP-LINK IP-Camera", '
            'nonce="$nonce", qop="auth"\r\nContent-Length: 0\r\n\r\n',
          ),
        );
        return;
      }
      s.add(
        latin1.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: multipart/mixed;boundary=--device-stream-boundary--\r\n'
          'Key-Exchange: realm="TP-LINK IP-Camera", algorithm=AES-128-CBC, '
          'nonce="$nonce"${sha256 ? ', encrypt_type="3"' : ''}\r\n\r\n',
        ),
      );

      final demux = TsAudioDemuxer();
      while (true) {
        var l = await r.readLine();
        while (!l.startsWith('----client-stream-boundary--')) {
          l = await r.readLine();
        }
        final ph = await r.readHeaders();
        final body = await r.read(int.parse(ph['content-length']!));
        if (ph['content-type'] == 'application/json') {
          final json = jsonDecode(utf8.decode(body)) as Map;
          final params = json['params'] as Map;
          if (params.containsKey('preview')) {
            _part(
              s,
              'application/json',
              utf8.encode(
                '{"type":"response","seq":1,"params":{"error_code":0,"session_id":"1"}}',
              ),
            );
            _stream(s);
          } else if (params.containsKey('talk')) {
            _part(
              s,
              'application/json',
              utf8.encode(
                allowTalk
                    ? '{"type":"response","seq":3,"params":{"error_code":0,"session_id":"2"}}'
                    : '{"type":"response","seq":3,"params":{"error_code":-52414}}',
              ),
            );
          }
        } else if (ph['content-type'] == 'audio/mp2t') {
          expect(ph['x-session-id'], '2');
          for (final a in demux.add(body)) {
            spoken.addAll(a.payload);
          }
        }
      }
    } catch (_) {
      s.destroy();
    }
  }

  void _part(Socket s, String type, Uint8List body, {String extra = ''}) {
    s.add(
      latin1.encode(
        '----device-stream-boundary--\r\n'
        'Content-Type: $type\r\n$extra'
        'Content-Length: ${body.length}\r\n\r\n',
      ),
    );
    s.add(body);
    s.add(const [13, 10]);
  }

  /// Sends the "microphone": a constant sample value, encrypted.
  void _stream(Socket s) {
    final mux = TsAudioMuxer();
    final key = md5('$nonce:$_hash');
    final iv = md5('admin:$nonce');
    var first = true;
    _timers.add(
      Timer.periodic(const Duration(milliseconds: 40), (_) {
        final alaw = alawEncode(Int16List.fromList(List.filled(320, 8000)));
        final b = BytesBuilder();
        if (first) b.add(mux.header());
        first = false;
        b.add(mux.audio(alaw));
        final plain = b.takeBytes();
        final pad = 16 - plain.length % 16;
        final padded = Uint8List(plain.length + pad)
          ..setRange(0, plain.length, plain)
          ..fillRange(plain.length, plain.length + pad, pad);
        final cbc = CBCBlockCipher(AESEngine())
          ..init(true, ParametersWithIV(KeyParameter(key), iv));
        final out = Uint8List(padded.length);
        for (var i = 0; i < padded.length; i += 16) {
          cbc.processBlock(padded, i, out, i);
        }
        try {
          _part(
            s,
            'video/mp2t',
            out,
            extra: 'X-If-Encrypt: 1\r\nX-Session-Id: 1\r\n',
          );
        } catch (_) {}
      }),
    );
  }

  Future<void> close() async {
    for (final t in _timers) {
      t.cancel();
    }
    await _server.close();
    for (final s in _sockets) {
      s.destroy();
    }
  }
}

/// A minimal RTSP camera with one A-law audio track and digest login.
class FakeRtsp {
  FakeRtsp._(this._server) {
    _server.listen(_serve);
  }
  static Future<FakeRtsp> start() async =>
      FakeRtsp._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final List<Socket> _sockets = [];
  Timer? _timer;
  int get port => _server.port;

  Future<void> _serve(Socket s) async {
    _sockets.add(s);
    s.done.catchError((Object _) {});
    final r = ByteReader(s);
    try {
      while (true) {
        final line = await r.readLine();
        final h = await r.readHeaders();
        final method = line.split(' ').first;
        final cseq = h['cseq'];
        void reply(String status, [String headers = '', String body = '']) =>
            s.add(
              latin1.encode(
                'RTSP/1.0 $status\r\nCSeq: $cseq\r\n$headers'
                '${body.isEmpty ? '' : 'Content-Length: ${body.length}\r\n'}'
                '\r\n$body',
              ),
            );
        final auth = h['authorization'] ?? '';
        final uri = line.split(' ')[1];
        final want = hex(
          md5('${hex(md5('cam:R:secret'))}:N:${hex(md5('$method:$uri'))}'),
        );
        if (between(auth, 'response="', '"') != want) {
          reply(
            '401 Unauthorized',
            'WWW-Authenticate: Digest realm="R", nonce="N"\r\n',
          );
          continue;
        }
        switch (method) {
          case 'DESCRIBE':
            reply(
              '200 OK',
              'Content-Base: $uri/\r\nContent-Type: application/sdp\r\n',
              'v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n'
                  'a=control:track1\r\nm=audio 0 RTP/AVP 8\r\n'
                  'a=rtpmap:8 PCMA/8000\r\na=control:track2\r\n',
            );
          case 'SETUP':
            expect(uri, endsWith('/track2'));
            reply('200 OK', 'Session: 42;timeout=60\r\n');
          case 'PLAY':
            reply('200 OK');
            var seq = 0;
            _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
              final alaw = alawEncode(
                Int16List.fromList(List.filled(160, 6000)),
              );
              final rtp = Uint8List(12 + alaw.length)
                ..[0] = 0x80
                ..[1] = 8
                ..[2] = seq >> 8
                ..[3] = seq++ & 0xFF
                ..setRange(12, 12 + alaw.length, alaw);
              try {
                s.add([0x24, 0, rtp.length >> 8, rtp.length & 0xFF]);
                s.add(rtp);
              } catch (_) {}
            });
          default:
            reply('200 OK');
        }
      }
    } catch (_) {
      s.destroy();
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    await _server.close();
    for (final s in _sockets) {
      s.destroy();
    }
  }
}

void main() {
  test('A-law survives a round trip, and resampling keeps the level', () {
    final pcm = Int16List.fromList([
      0,
      100,
      -100,
      1000,
      -1000,
      12000,
      -12000,
      32000,
    ]);
    final back = alawDecode(alawEncode(pcm));
    for (var i = 0; i < pcm.length; i++) {
      expect((back[i] - pcm[i]).abs(), lessThan(pcm[i].abs() * 0.05 + 20));
    }
    final up = Upsampler2().process(Int16List.fromList(List.filled(8, 500)));
    expect(up.length, 16);
    expect(up.last, 500);
    expect(downsample2(up).last, 500);
    expect(ulawDecode(Uint8List.fromList([0xFF]))[0], 0);
  });

  test('MPEG-TS audio survives a round trip in odd chunks', () {
    final mux = TsAudioMuxer();
    final a = Uint8List.fromList(List.generate(500, (i) => i & 0xFF));
    final b = Uint8List.fromList(List.generate(160, (i) => 255 - i));
    final ts = Uint8List.fromList([
      ...mux.header(),
      ...mux.audio(a),
      ...mux.audio(b),
    ]);
    expect(ts.length % tsPacketSize, 0);
    final demux = TsAudioDemuxer();
    final got = <TsAudio>[];
    for (var i = 0; i < ts.length; i += 77) {
      got.addAll(
        demux.add(Uint8List.sublistView(ts, i, (i + 77).clamp(0, ts.length))),
      );
    }
    expect(got.map((g) => g.payload), [a, b]);
    expect(got.first.streamType, streamTypePcmaTapo);
  });

  group('camera session', () {
    late FakeTapo tapo;
    late FakeRtsp rtsp;

    setUp(() async {
      tapo = await FakeTapo.start('hunter2');
      rtsp = await FakeRtsp.start();
    });
    tearDown(() async {
      await tapo.close();
      await rtsp.close();
    });

    SavedCamera cam({String password = 'hunter2', bool withRtsp = false}) =>
        SavedCamera(
          key: 'k',
          name: 'Porch',
          host: '127.0.0.1',
          cloudPassword: password,
          port: tapo.port,
          rtspUser: withRtsp ? 'cam' : '',
          rtspPassword: 'secret',
          rtspPort: rtsp.port,
        );

    test('listens and talks over the Tapo stream', () async {
      final heard = <int>[];
      final s = CameraSession(cam(), onAudio: heard.addAll, onClosed: (_) {});
      final status = await s.start();
      expect(status.talk, isTrue);
      expect(status.via, 'tapo');
      await eventually(() => heard.length > 1600);
      expect(heard.last, closeTo(8000, 400)); // 16 kHz, same level.
      s.sendAudio(Int16List.fromList(List.filled(320, -4000)));
      await eventually(() => tapo.spoken.length >= 160);
      expect(
        alawDecode(Uint8List.fromList(tapo.spoken)).last,
        closeTo(-4000, 200),
      );
      s.close();
    });

    test('works with firmware that wants SHA-256', () async {
      await tapo.close();
      tapo = await FakeTapo.start('hunter2', sha256: true);
      final s = CameraSession(cam(), onAudio: (_) {}, onClosed: (_) {});
      expect((await s.start()).talk, isTrue);
      s.close();
    });

    test('a wrong cloud password is reported', () async {
      final s = CameraSession(
        cam(password: 'nope'),
        onAudio: (_) {},
        onClosed: (_) {},
      );
      await expectLater(
        s.start(),
        throwsA(
          isA<CameraException>().having(
            (e) => e.message,
            'message',
            contains('refused the cloud password'),
          ),
        ),
      );
    });

    test('a camera that refuses talking is listen only', () async {
      tapo.allowTalk = false;
      final s = CameraSession(cam(), onAudio: (_) {}, onClosed: (_) {});
      final status = await s.start();
      expect(status.talk, isFalse);
      expect(status.summary, contains('Listen only'));
      s.close();
    });

    test('falls back to RTSP for listening', () async {
      final heard = <int>[];
      final s = CameraSession(
        cam(password: 'nope', withRtsp: true),
        onAudio: heard.addAll,
        onClosed: (_) {},
      );
      final status = await s.start();
      expect(status.via, 'rtsp');
      expect(status.talk, isFalse);
      await eventually(() => heard.length > 1600);
      expect(heard.last, closeTo(6000, 300));
      s.close();
    });

    test('a call with a camera: hear it and talk to it', () async {
      final audio = FakeAudioEngine();
      List<SavedCamera> stored = const [];
      final core = IntercomCore(
        selfId: 'me',
        name: 'Me',
        audio: audio,
        preferredPort: 0,
        enableDiscovery: false,
        rogerBeep: false,
        echoSuppression: false,
        onCamerasChanged: (c) => stored = c,
      );
      await core.start();
      addTearDown(core.shutdown);
      final c = core.saveCamera(
        name: 'Porch',
        host: '127.0.0.1',
        cloudPassword: 'hunter2',
        port: tapo.port,
      );
      expect(stored.single.name, 'Porch');
      await eventually(() => core.peer(c.peerId)?.online ?? false);
      expect(core.entries.single.platform, 'camera');

      await core.connect(PeerTarget(c.peerId));
      await eventually(() => core.inConversation);
      expect(core.cameraCanTalk(c.peerId), isTrue);
      await eventually(() => audio.played.any((v) => (v - 8000).abs() < 400));
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (tapo.spoken.length < 160) {
        if (DateTime.now().isAfter(end)) fail('camera heard nothing');
        audio.inject(Int16List.fromList(List.filled(1600, 5000)));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        alawDecode(Uint8List.fromList(tapo.spoken)).last,
        closeTo(5000, 250),
      );

      core.hangUp();
      expect(core.conversation, isNull);
      // Still in the list as online right after hanging up.
      expect(core.peer(c.peerId)!.connected, isFalse);
      expect(core.peer(c.peerId)!.online, isTrue);
      core.removePeer(core.entries.single);
      expect(core.entries, isEmpty);
      expect(stored, isEmpty);
    });
  });
}
