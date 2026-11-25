import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:intercom_core/src/internet/adpcm.dart';
import 'package:intercom_core/src/internet/schnorr.dart';
import 'package:intercom_core/src/internet/stun.dart';
import 'package:test/test.dart';

void main() {
  group('BIP-340', () {
    test('test vector 0', () {
      final sk = fromHex('${'00' * 31}03');
      expect(
        toHex(schnorrPublicKey(sk)).toUpperCase(),
        'F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9',
      );
      final sig = schnorrSign(Uint8List(32), sk, Uint8List(32));
      expect(
        toHex(sig).toUpperCase(),
        'E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215'
        '25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0',
      );
      expect(schnorrVerify(Uint8List(32), schnorrPublicKey(sk), sig), isTrue);
    });

    test('test vector 1', () {
      final sk = fromHex(
        'B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF',
      );
      final msg = fromHex(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final aux = fromHex('${'00' * 31}01');
      final pub = schnorrPublicKey(sk);
      expect(
        toHex(pub).toUpperCase(),
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final sig = schnorrSign(msg, sk, aux);
      expect(
        toHex(sig).toUpperCase(),
        '6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341'
        '8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A',
      );
      expect(schnorrVerify(msg, pub, sig), isTrue);
      final bad = Uint8List.fromList(sig)..[63] ^= 1;
      expect(schnorrVerify(msg, pub, bad), isFalse);
    });
  });

  test('ADPCM keeps speech-like audio close (SNR > 20 dB)', () {
    final pcm = Int16List(320);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] =
          (8000 * sin(2 * pi * 440 * i / 16000) +
                  3000 * sin(2 * pi * 1200 * i / 16000))
              .round();
    }
    final enc = AdpcmEncoder();
    enc.encode(pcm); // Warm up the step size.
    final packet = enc.encode(pcm);
    expect(packet.length, 5 + 160);
    final out = adpcmDecode(packet);
    expect(out.length, pcm.length);
    var signal = 0.0, noise = 0.0;
    for (var i = 0; i < pcm.length; i++) {
      signal += pcm[i] * pcm[i].toDouble();
      final e = (pcm[i] - out[i]).toDouble();
      noise += e * e;
    }
    expect(10 * log(signal / noise) / ln10, greaterThan(20));
  });

  test('STUN against a fake server', () async {
    final server = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = server.receive();
      if (d == null) return;
      // Answer with XOR-MAPPED-ADDRESS = 203.0.113.7:40000.
      final resp = BytesBuilder()
        ..add([0x01, 0x01, 0x00, 0x0C])
        ..add(d.data.sublist(4, 20));
      const port = 40000 ^ 0x2112;
      final ip = [203 ^ 0x21, 0 ^ 0x12, 113 ^ 0xA4, 7 ^ 0x42];
      resp.add([
        0x00,
        0x20,
        0x00,
        0x08,
        0x00,
        0x01,
        port >> 8,
        port & 0xff,
        ...ip,
      ]);
      server.send(resp.takeBytes(), d.address, d.port);
    });
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final stun = StunClient(socket);
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) stun.handle(d.data);
    });
    final r = await stun.query('127.0.0.1', server.port);
    expect(r.toString(), '203.0.113.7:40000');
    final (pub, nat) = await stun.check(
      servers: [('127.0.0.1', server.port), ('127.0.0.1', server.port)],
    );
    expect(pub.toString(), '203.0.113.7:40000');
    expect(nat, NatType.cone);
    socket.close();
    server.close();
  });
}
