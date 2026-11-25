import 'dart:io';
import 'dart:typed_data';

/// A STUN server on loopback that answers with the address it saw.
class FakeStun {
  FakeStun._(this.socket) {
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null || d.data.length < 20) return;
      final ip = d.address.rawAddress;
      final port = d.port ^ 0x2112;
      final resp = BytesBuilder()
        ..add([0x01, 0x01, 0x00, 0x0C])
        ..add(d.data.sublist(4, 20))
        ..add([0x00, 0x20, 0x00, 0x08, 0x00, 0x01, port >> 8, port & 0xff])
        ..add([ip[0] ^ 0x21, ip[1] ^ 0x12, ip[2] ^ 0xA4, ip[3] ^ 0x42]);
      socket.send(Uint8List.fromList(resp.takeBytes()), d.address, d.port);
    });
  }

  static Future<FakeStun> start() async =>
      FakeStun._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  final RawDatagramSocket socket;
  int get port => socket.port;
  void close() => socket.close();
}
