import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// What a [PeerConnection] runs over: a TCP socket, or a hole-punched UDP
/// path (`internet/udp_link.dart`). Both carry a reliable, ordered byte
/// stream; UDP adds unreliable datagrams for audio and video.
abstract class LinkTransport {
  InternetAddress get remoteAddress;
  int get remotePort;

  /// Our own address on this link (null if unknown or not meaningful).
  InternetAddress? get localAddress;

  StreamSubscription<List<int>> listen(
    void Function(List<int> data) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  });

  void add(List<int> data);
  Future<void> flush();
  void destroy();
  Future<void> get done;

  /// Unreliable, unordered datagrams (null: not available, e.g. TCP).
  DatagramChannel? get datagrams;

  /// "internet" for a hole-punched path; null for an ordinary socket.
  String? get route => null;
}

abstract class DatagramChannel {
  /// Sends [blob] (any size: split and rebuilt as needed). Lost as a whole
  /// if a piece is lost.
  void send(Uint8List blob);
  void Function(Uint8List blob)? onReceive;
}

class SocketTransport implements LinkTransport {
  SocketTransport(this.socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
  }

  final Socket socket;

  @override
  InternetAddress get remoteAddress => socket.remoteAddress;
  @override
  int get remotePort => socket.remotePort;
  @override
  InternetAddress? get localAddress {
    try {
      return socket.address;
    } catch (_) {
      return null;
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> data) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) => socket.add(data);
  @override
  Future<void> flush() => socket.flush();
  @override
  void destroy() => socket.destroy();
  @override
  Future<void> get done => socket.done;
  @override
  DatagramChannel? get datagrams => null;
  @override
  String? get route => null;
}
