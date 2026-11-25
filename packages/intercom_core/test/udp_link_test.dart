import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:intercom_core/src/internet/udp_link.dart';
import 'package:test/test.dart';

Future<void> eventually(bool Function() ok, {int seconds = 10}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A UDP "network" between two ports that loses and reorders packets.
class LossyPath {
  LossyPath._(this.a, this.b, this.loss);
  final RawDatagramSocket a, b;
  final double loss;
  final Random _rng = Random(7);
  int dropped = 0;

  /// [aPort]/[bPort]: the real sockets; send to [toB] to reach B and
  /// [toA] to reach A.
  static Future<LossyPath> start(int aPort, int bPort, double loss) async {
    final a = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final b = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = LossyPath._(a, b, loss);
    p._forward(a, b, bPort);
    p._forward(b, a, aPort);
    return p;
  }

  int get toB => a.port; // A sends here; it comes out of `b` to B.
  int get toA => b.port;

  void _forward(RawDatagramSocket from, RawDatagramSocket out, int port) {
    from.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = from.receive();
      if (d == null) return;
      if (_rng.nextDouble() < loss) {
        dropped++;
        return;
      }
      // Up to 30 ms of jitter reorders packets.
      Timer(Duration(milliseconds: _rng.nextInt(30)), () {
        out.send(d.data, InternetAddress.loopbackIPv4, port);
      });
    });
  }

  void close() {
    a.close();
    b.close();
  }
}

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final secret = networkSecret('correct horse battery');

  Future<(PeerConnection, PeerConnection, UdpMux, UdpMux)> pair({
    double loss = 0,
  }) async {
    final ma = await UdpMux.bind(), mb = await UdpMux.bind();
    final lo = InternetAddress.loopbackIPv4;
    LossyPath? path;
    var toB = mb.port, toA = ma.port;
    if (loss > 0) {
      path = await LossyPath.start(ma.port, mb.port, loss);
      toB = path.toB;
      toA = path.toA;
    }
    final results = await Future.wait([
      ma.punch(connId: 42, key: key, candidates: [(lo, toB)]),
      mb.punch(connId: 42, key: key, candidates: [(lo, toA)]),
    ]);
    final a = PeerConnection.over(results[0], outgoing: true, secret: secret);
    final b = PeerConnection.over(results[1], outgoing: false, secret: secret);
    addTearDown(() async {
      await a.close();
      await b.close();
      ma.close();
      mb.close();
      path?.close();
    });
    return (a, b, ma, mb);
  }

  test('punch, then encrypted frames and datagram audio', () async {
    final (a, b, _, _) = await pair();
    expect(a.route, 'internet');
    final got = <Frame>[];
    b.frames.listen(got.add);
    a.send(Frame.json(MessageType.hello, {'id': 'alice'}));
    await eventually(() => got.isNotEmpty);
    expect(got.first.json['id'], 'alice');
    expect(a.securityCode, b.securityCode);

    final pcm = Int16List(320);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (6000 * sin(i / 5)).round();
    }
    a.send(Frame(MessageType.audio, pcm.buffer.asUint8List()));
    await eventually(() => got.any((f) => f.type == MessageType.audio));
    final audio = got.firstWhere((f) => f.type == MessageType.audio);
    expect(audio.payload.length, 640); // PCM again after ADPCM.
  });

  test('a wrong password fails like over TCP', () async {
    final ma = await UdpMux.bind(), mb = await UdpMux.bind();
    final lo = InternetAddress.loopbackIPv4;
    final r = await Future.wait([
      ma.punch(connId: 7, key: key, candidates: [(lo, mb.port)]),
      mb.punch(connId: 7, key: key, candidates: [(lo, ma.port)]),
    ]);
    final a = PeerConnection.over(r[0], outgoing: true, secret: secret);
    final b = PeerConnection.over(
      r[1],
      outgoing: false,
      secret: networkSecret('another password'),
    );
    a.send(Frame.json(MessageType.hello, {'id': 'alice'}));
    await expectLater(b.ready, throwsA(isA<LinkException>()));
    expect(b.failure, LinkFailure.wrongPassword);
    await a.close();
    ma.close();
    mb.close();
  });

  test('punching without the right key never connects', () async {
    final ma = await UdpMux.bind(), mb = await UdpMux.bind();
    final lo = InternetAddress.loopbackIPv4;
    final other = Uint8List.fromList(List.filled(32, 9));
    final r = Future.wait([
      ma.punch(
        connId: 5,
        key: key,
        candidates: [(lo, mb.port)],
        timeout: const Duration(seconds: 1),
      ),
      mb.punch(
        connId: 5,
        key: other,
        candidates: [(lo, ma.port)],
        timeout: const Duration(seconds: 1),
      ),
    ]);
    await expectLater(r, throwsA(isA<TimeoutException>()));
    ma.close();
    mb.close();
  });

  test('20% loss and reordering: frames still arrive, in order', () async {
    final (a, b, _, _) = await pair(loss: 0.2);
    final got = <int>[];
    b.frames.listen((f) {
      if (f.type == MessageType.hello) got.add(f.json['n'] as int);
    });
    // Both sides say hello, as the engine does (proves the keys match).
    b.send(Frame.json(MessageType.hello, {'id': 'bob'}));
    for (var i = 0; i < 300; i++) {
      // Some big ones (several packets each).
      a.send(
        Frame.json(MessageType.hello, {'n': i, 'pad': 'x' * (i % 7 * 500)}),
      );
    }
    await eventually(() => got.length == 300, seconds: 40);
    expect(got, List.generate(300, (i) => i));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
