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
    int port = 0,
  }) async => FakeTapo._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, port),
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

  group('saved camera', () {
    test('an RTSP address is split up', () {
      final r = SavedCamera.parseRtspUrl(
        'rtsp://admin:p%40ss:w@192.168.1.20:8554/cam/realmonitor?channel=1',
      );
      expect(r.host, '192.168.1.20');
      expect(r.port, 8554);
      expect(r.path, '/cam/realmonitor?channel=1');
      expect(r.user, 'admin');
      expect(r.password, 'p@ss:w');
      expect(SavedCamera.parseRtspUrl('rtsp://cam.local').port, 554);
      expect(SavedCamera.parseRtspUrl('rtsp://cam.local').path, '/');
      expect(
        () => SavedCamera.parseRtspUrl('http://1.2.3.4/x'),
        throwsArgumentError,
      );
      expect(() => SavedCamera.parseRtspUrl('nonsense'), throwsArgumentError);
    });

    test('picture address and saving', () {
      final tapo = SavedCamera(
        key: 't',
        name: 'Porch',
        host: '192.168.1.50',
        cloudPassword: 'x',
      );
      expect(tapo.hasVideo, isFalse, reason: 'needs the camera account');
      expect(tapo.videoUrl(), isNull);
      final tapo2 = SavedCamera.fromJson({
        ...tapo.toJson(),
        'rtspUser': 'me',
        'rtspPassword': 'a b@c',
      })!;
      expect(tapo2.videoUrl(), 'rtsp://me:a%20b%40c@192.168.1.50:554/stream2');
      expect(tapo2.videoUrl(hd: true), endsWith(':554/stream1'));
      expect(tapo2.probePort, 8800);

      final gate = SavedCamera(
        key: 'g',
        name: 'Gate',
        host: 'gate.local',
        kind: SavedCamera.kindRtsp,
        rtspPort: 8554,
        rtspPath: '/live?x=1',
      );
      expect(gate.hasVideo, isTrue);
      expect(gate.videoUrl(), 'rtsp://gate.local:8554/live?x=1');
      expect(gate.rtspUrl, 'rtsp://gate.local:8554/live?x=1');
      expect(gate.probePort, 8554);
      final back = SavedCamera.fromJson(gate.toJson())!;
      expect(back.kind, SavedCamera.kindRtsp);
      expect(back.videoUrl(), gate.videoUrl());
      // Saved by 1.7.0 (no kind): a Tapo.
      expect(SavedCamera.fromJson(tapo.toJson())!.isTapo, isTrue);
    });
  });

  group('camera session', () {
    test('a camera account that is refused says where it failed', () async {
      final r = await FakeRtsp.start();
      addTearDown(r.close);
      final s = CameraSession(
        SavedCamera(
          key: 'x',
          name: 'Gate',
          host: '127.0.0.1',
          rtspUser: 'cam',
          rtspPassword: 'wrong-password',
          rtspPort: r.port,
        ),
        onAudio: (_) {},
        onClosed: (_) {},
      );
      await expectLater(
        s.start(),
        throwsA(
          isA<CameraException>().having(
            (e) => e.message,
            'message',
            startsWith('Camera account (logging in, after '),
          ),
        ),
      );
    });

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
      expect(
        status.summary,
        matches(r'^Listen and talk work \(connected in \d+\.\d s\)$'),
      );
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
            allOf(
              contains('refused the cloud password'),
              matches(r'^Listen \(logging in, after \d+\.\d s\): '),
            ),
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
      expect(
        status.talkProblem,
        startsWith('Talk (opening the speaker, after '),
      );
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
      expect(status.talkProblem, contains('refused the cloud password'));
      await eventually(() => heard.length > 1600);
      expect(heard.last, closeTo(6000, 300));
      s.close();
    });

    test('the debug log shows each step, without the passwords', () async {
      DebugLog.instance.clear();
      final s = CameraSession(cam(), onAudio: (_) {}, onClosed: (_) {});
      await s.start();
      await eventually(
        () => DebugLog.instance.entries.any(
          (e) => e.text.contains('first audio'),
        ),
      );
      s.close();
      final fallback = CameraSession(
        cam(password: 'nope', withRtsp: true),
        onAudio: (_) {},
        onClosed: (_) {},
      );
      await fallback.start();
      fallback.close();
      final log = DebugLog.instance.dump();
      for (final line in [
        'Porch: starting (call): Tapo at 127.0.0.1',
        'Porch listen: connecting to 127.0.0.1:',
        'Porch listen: logged in',
        'Porch talk: speaker open',
        'stream contents: pid ',
        'G.711 A-law 8 kHz audio',
        'first audio after',
        'Porch: Listen and talk work',
        'Porch: closed (call)',
        'Porch listen: login failed after',
        'trying RTSP (listen only)',
        '[rtsp] Porch: audio track: A-law 8000 Hz',
        'Porch: Listen only',
      ]) {
        expect(log, contains(line));
      }
      expect(log, isNot(contains('hunter2')));
      expect(log, isNot(contains('secret')));
    });

    test('another RTSP camera is heard (listen only)', () async {
      final heard = <int>[];
      final s = CameraSession(
        SavedCamera(
          key: 'g',
          name: 'Gate',
          host: '127.0.0.1',
          kind: SavedCamera.kindRtsp,
          rtspUser: 'cam',
          rtspPassword: 'secret',
          rtspPort: rtsp.port,
          rtspPath: '/live/ch0?subtype=1',
        ),
        onAudio: heard.addAll,
        onClosed: (_) {},
      );
      final status = await s.start();
      expect(status.via, 'rtsp');
      expect(status.talk, isFalse);
      await eventually(() => heard.length > 1600);
      s.close();
    });

    test('Everyone leaves out other RTSP cameras', () async {
      final core = IntercomCore(
        selfId: 'me',
        name: 'Me',
        audio: FakeAudioEngine(),
        preferredPort: 0,
        enableDiscovery: false,
        rogerBeep: false,
        echoSuppression: false,
      );
      await core.start();
      addTearDown(core.shutdown);
      final c = core.saveCamera(
        name: 'Gate',
        host: '127.0.0.1',
        kind: SavedCamera.kindRtsp,
        rtspPort: rtsp.port,
        rtspPath: '/live',
      );
      await eventually(() => core.peer(c.peerId)?.online ?? false);
      await core.connect(const EveryoneTarget());
      expect(core.conversation, isNull);
      // Calling it on its own: listen only.
      final withLogin = core.saveCamera(
        key: c.key,
        name: 'Gate',
        host: '127.0.0.1',
        kind: SavedCamera.kindRtsp,
        rtspUser: 'cam',
        rtspPassword: 'secret',
        rtspPort: rtsp.port,
        rtspPath: '/live',
      );
      await core.connect(PeerTarget(withLogin.peerId));
      await eventually(() => core.cameraCanTalk(c.peerId) != null);
      expect(core.cameraCanTalk(c.peerId), isFalse);
      core.hangUp();
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

    test('a busy camera that refuses is tried again', () async {
      final core = IntercomCore(
        selfId: 'me',
        name: 'Me',
        audio: FakeAudioEngine(),
        preferredPort: 0,
        enableDiscovery: false,
        rogerBeep: false,
      );
      await core.start();
      addTearDown(core.shutdown);
      final port = tapo.port;
      final c = core.saveCamera(
        name: 'Porch',
        host: '127.0.0.1',
        cloudPassword: 'hunter2',
        port: port,
      );
      await eventually(() => core.peer(c.peerId)?.online ?? false);
      // Busy: every connection is refused for a while.
      await tapo.close();
      final events = <String>[];
      core.events.listen((e) => events.add(e.message));
      final call = core.connect(PeerTarget(c.peerId));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(
        core.conversation?.members[c.peerId],
        MemberState.calling,
        reason: '$events',
      );
      // The camera is free again.
      tapo = await FakeTapo.start('hunter2', port: port);
      await eventually(
        () => core.conversation?.isConnected ?? false,
        timeout: const Duration(seconds: 8),
      );
      await call;
      expect(events.where((m) => m.contains('Could not reach')), isEmpty);
      core.hangUp();
    });

    test('a camera call waits a moment after the last one ended', () async {
      final before = IntercomCore.cameraReconnectDelay;
      IntercomCore.cameraReconnectDelay = const Duration(seconds: 1);
      addTearDown(() => IntercomCore.cameraReconnectDelay = before);
      final core = IntercomCore(
        selfId: 'me',
        name: 'Me',
        audio: FakeAudioEngine(),
        preferredPort: 0,
        enableDiscovery: false,
        rogerBeep: false,
      );
      await core.start();
      addTearDown(core.shutdown);
      final c = core.saveCamera(
        name: 'Porch',
        host: '127.0.0.1',
        cloudPassword: 'hunter2',
        port: tapo.port,
      );
      await eventually(() => core.peer(c.peerId)?.online ?? false);
      await core.connect(PeerTarget(c.peerId));
      await eventually(() => core.conversation?.isConnected ?? false);
      core.hangUp();

      final again = DateTime.now();
      final call = core.connect(PeerTarget(c.peerId));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(core.conversation?.members[c.peerId], MemberState.calling);
      await call;
      expect(core.conversation?.isConnected, isTrue);
      expect(
        DateTime.now().difference(again),
        greaterThanOrEqualTo(const Duration(milliseconds: 950)),
      );
      core.hangUp();
    });

    test('no hang-up beep when the camera connection is lost', () async {
      final audio = FakeAudioEngine();
      final core = IntercomCore(
        selfId: 'me',
        name: 'Me',
        audio: audio,
        preferredPort: 0,
        enableDiscovery: false,
        echoSuppression: false,
      );
      await core.start();
      addTearDown(core.shutdown);
      final c = core.saveCamera(
        name: 'Porch',
        host: '127.0.0.1',
        cloudPassword: 'hunter2',
        port: tapo.port,
      );
      await eventually(() => core.peer(c.peerId)?.online ?? false);
      await core.connect(PeerTarget(c.peerId));
      await eventually(() => core.conversation?.isConnected ?? false);
      final events = <String>[];
      core.events.listen((e) => events.add(e.message));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      audio.played.clear();

      await tapo.close(); // The camera goes away mid-call.
      await eventually(() => core.conversation == null);
      expect(events, contains('Lost connection to Porch'));
      // The hang-up beep's samples (speaker volume 100%) are not played.
      final tone = IntercomCore.hangupTone(core.sampleRate);
      final start = tone.indexWhere((v) => v != 0) + 40;
      final piece = tone.sublist(start, start + 40);
      final played = audio.played;
      var found = false;
      for (var i = 0; i + piece.length <= played.length && !found; i++) {
        var all = true;
        for (var j = 0; j < piece.length && all; j++) {
          all = played[i + j] == piece[j];
        }
        found = all;
      }
      expect(found, isFalse);
    });
  });

  group('RTSP check', () {
    test('a camera that answers: names its tracks', () async {
      final r = await FakeRtsp.start();
      addTearDown(r.close);
      final msg = await checkRtsp('rtsp://cam:secret@127.0.0.1:${r.port}/s');
      expect(msg, startsWith('the camera answers normally'));
      expect(msg, contains('H264, PCMA'));
    });

    test('a wrong camera account', () async {
      final r = await FakeRtsp.start();
      addTearDown(r.close);
      final msg = await checkRtsp('rtsp://cam:nope@127.0.0.1:${r.port}/s');
      expect(msg, contains('refused the camera account'));
    });

    test('a stuck server: connects but never answers', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() async {
        await server.close();
        for (final s in held) {
          s.destroy();
        }
      });
      final msg = await checkRtsp(
        'rtsp://127.0.0.1:${server.port}/stream2',
        wait: const Duration(milliseconds: 300),
      );
      expect(msg, contains('never answers'));
    });

    test('no free stream (453)', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) {
        final r = ByteReader(s);
        () async {
          try {
            while (true) {
              final line = await r.readLine();
              final h = await r.readHeaders();
              final code = line.startsWith('OPTIONS')
                  ? '200 OK'
                  : '453 Not Enough Bandwidth';
              s.add(
                latin1.encode('RTSP/1.0 $code\r\nCSeq: ${h['cseq']}\r\n\r\n'),
              );
            }
          } catch (_) {
            s.destroy();
          }
        }();
      });
      addTearDown(server.close);
      final msg = await checkRtsp('rtsp://127.0.0.1:${server.port}/stream2');
      expect(msg, contains('no free stream'));
    });

    test('nothing listening on the port', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final msg = await checkRtsp('rtsp://127.0.0.1:$port/stream2');
      expect(msg, startsWith('could not connect to port $port'));
    });
  });
}
