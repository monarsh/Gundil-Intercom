import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'internet/adpcm.dart';
import 'link_transport.dart';
import 'protocol.dart';
import 'secure_channel.dart';

/// Why a connection ended before it was usable.
enum LinkFailure {
  /// The other side's frames don't decrypt: it uses another intercom
  /// password.
  wrongPassword,

  /// The other side runs a version without encryption (before 1.2.0).
  outdated,

  /// No key exchange within [PeerConnection.handshakeTimeout], or a broken
  /// one.
  handshake,

  /// The socket closed during the key exchange.
  closed,
}

class LinkException implements Exception {
  LinkException(this.failure);
  final LinkFailure failure;

  String get message => switch (failure) {
    LinkFailure.wrongPassword => 'uses a different intercom password',
    LinkFailure.outdated => 'runs an older version without encryption',
    LinkFailure.handshake => 'secure connection could not be set up',
    LinkFailure.closed => 'connection closed',
  };

  @override
  String toString() => message;
}

/// A single encrypted TCP link to a remote peer, speaking the framed
/// [protocol].
///
/// It starts with a key exchange (see `secure_channel.dart`): both sides
/// send a [MessageType.key] frame, then every frame is sealed. Frames sent
/// before that are queued. [frames] only delivers decrypted frames — with
/// one exception: a plaintext HELLO/OPEN from an older, unencrypted peer
/// is delivered with [legacy] set, so the app can show "Needs update".
class PeerConnection {
  PeerConnection(
    Socket socket, {
    required bool outgoing,
    required Uint8List secret,
  }) : this.over(SocketTransport(socket), outgoing: outgoing, secret: secret);

  /// Over any [LinkTransport] (a hole-punched UDP path, for instance).
  PeerConnection.over(
    this.socket, {
    required this.outgoing,
    required this.secret,
  }) : remoteAddress = socket.remoteAddress,
       remotePort = socket.remotePort,
       localAddress = socket.localAddress {
    socket.datagrams?.onReceive = _onDatagram;
    // Failures are also reported via [failure]; don't treat an unawaited
    // [ready] as an uncaught error.
    _ready.future.catchError((Object _) {});
    // Write errors (peer vanished) are reported on `done`; without a handler
    // they would surface as uncaught async errors.
    socket.done.then((_) => _close(null), onError: (Object e) => _close(e));
    _sub = socket.listen(
      _onData,
      onError: (Object e) => _close(e),
      onDone: () => _close(null),
      cancelOnError: true,
    );
    _write(
      Frame(
        MessageType.key,
        Uint8List.fromList([keyExchangeVersion, ..._keys.publicKey]),
      ),
    );
    _handshakeTimer = Timer(handshakeTimeout, () {
      if (!_openedAny && !legacy) _fail(LinkFailure.handshake);
    });
  }

  /// Connects to [host]:[port].
  static Future<PeerConnection> connect(
    InternetAddress host,
    int port, {
    required Uint8List secret,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return PeerConnection(socket, outgoing: true, secret: secret);
  }

  static const Duration handshakeTimeout = Duration(seconds: 6);

  final LinkTransport socket;

  /// "internet" for a hole-punched UDP path; null for the LAN or a VPN.
  String? get route => socket.route;

  /// Bytes queued for sending (UDP paths; 0 on TCP).
  int get pendingBytes => socket.pending;

  // Audio and video as datagrams (UDP paths only): no retransmission, so a
  // lost packet is a short gap instead of a delay. Audio is IMA ADPCM.
  DatagramCipher? _dgSealer, _dgOpener;
  final AdpcmEncoder _adpcm = AdpcmEncoder();
  static const int _adpcmFlag = 0x80;

  /// Whether we initiated this connection.
  final bool outgoing;

  /// Network secret from the intercom password ([networkSecret]).
  final Uint8List secret;

  /// Remote peer id, known once its HELLO arrives.
  String? remoteId;

  final KeyPair _keys = KeyPair.generate();
  FrameCipher? _sealer, _opener;
  String? _securityCode;
  bool _openedAny = false;
  final List<Frame> _queue = [];
  Timer? _handshakeTimer;
  bool _legacy = false;
  LinkFailure? _failure;

  final FrameDecoder _decoder = FrameDecoder();
  late final StreamSubscription<List<int>> _sub;
  final StreamController<Frame> _frames = StreamController<Frame>();
  final Completer<void> _closed = Completer<void>();
  final Completer<void> _ready = Completer<void>();
  bool _isClosed = false;

  Stream<Frame> get frames => _frames.stream;
  Future<void> get done => _closed.future;
  bool get isClosed => _isClosed;

  /// Completes once the link is encrypted and the other side's first frame
  /// decrypted (same password); fails with a [LinkException].
  Future<void> get ready => _ready.future;

  /// The key exchange is done: everything is encrypted from here on.
  bool get secure => _sealer != null;

  /// A frame from the other side decrypted: the keys (and the password)
  /// match, so the link really works.
  bool get verified => _openedAny;

  /// The other side is an old, unencrypted version.
  bool get legacy => _legacy;

  /// Why the link failed, if it did.
  LinkFailure? get failure => _failure;

  /// Six digits, the same on both devices unless someone intercepts the
  /// link (compare them to be sure the call is private).
  String? get securityCode => _securityCode;

  /// Kept from the start: the socket can't tell any more once closed.
  final InternetAddress remoteAddress;
  final int remotePort;

  /// Our own address on this link (null if unknown). When the device loses
  /// that address (Wi-Fi → mobile data, VPN down, ...) the link is dead.
  final InternetAddress? localAddress;

  /// Last time anything arrived from the other side. A link that stays
  /// silent despite pings is dead (e.g. the network changed under it),
  /// which TCP itself would only notice after many minutes.
  DateTime lastReceived = DateTime.now();

  /// Last keep-alive ping sent (managed by the engine).
  DateTime? lastPing;

  /// How often the other side wants idle keep-alives (it saves battery on
  /// mobile data or Wi-Fi); null: the usual interval.
  Duration? peerPingEvery;

  /// The engine checks this link after a network change: it's closed unless
  /// something arrives before this time.
  DateTime? probeDeadline;

  /// Sends [frame] encrypted (queued until the key exchange is done).
  void send(Frame frame) {
    if (_isClosed || _legacy) return;
    final sealer = _sealer;
    if (sealer == null) {
      _queue.add(frame);
      return;
    }
    final dg = _dgSealer;
    final channel = socket.datagrams;
    if (dg != null &&
        channel != null &&
        (frame.type == MessageType.audio || frame.type == MessageType.video)) {
      var type = frame.type.code;
      var payload = frame.payload;
      if (frame.type == MessageType.audio && payload.length >= 4) {
        final pcm = Uint8List.fromList(
          payload.sublist(0, payload.length & ~1),
        ).buffer.asInt16List();
        payload = _adpcm.encode(pcm);
        type |= _adpcmFlag;
      }
      final (seq, sealed) = dg.seal(type, payload);
      final blob = Uint8List(8 + sealed.length);
      blob.buffer.asByteData().setUint64(0, seq);
      blob.setRange(8, blob.length, sealed);
      channel.send(blob);
      return;
    }
    _write(
      Frame(MessageType.sealed, sealer.seal(frame.type.code, frame.payload)),
    );
  }

  /// Unencrypted reply to an old peer (only to tell it we can't talk).
  void sendLegacy(Frame frame) {
    if (_legacy) _write(frame);
  }

  void _write(Frame frame) {
    if (_isClosed) return;
    try {
      socket.add(frame.encode());
    } catch (e) {
      _close(e);
    }
  }

  void _onData(List<int> data) {
    lastReceived = DateTime.now();
    probeDeadline = null;
    try {
      for (final f in _decoder.add(data)) {
        if (_isClosed) return;
        _onFrame(f);
      }
    } on ProtocolException catch (e) {
      _close(e);
    }
  }

  void _onFrame(Frame f) {
    if (secure) {
      if (f.type != MessageType.sealed) return; // Plaintext: ignore.
      final (int code, Uint8List payload) inner;
      try {
        inner = _opener!.open(f.payload);
      } catch (_) {
        // The very first frame failing means the keys differ: the other
        // side derived them with another password.
        _fail(_openedAny ? LinkFailure.handshake : LinkFailure.wrongPassword);
        return;
      }
      if (!_openedAny) {
        _openedAny = true;
        _handshakeTimer?.cancel();
        if (!_ready.isCompleted) _ready.complete();
      }
      final type = MessageType.fromCode(inner.$1);
      if (type == null || type == MessageType.key) return;
      if (type == MessageType.sealed) return;
      _frames.add(Frame(type, inner.$2));
      return;
    }
    switch (f.type) {
      case MessageType.key:
        _onKey(f.payload);
      case MessageType.hello || MessageType.open:
        // An old version speaks plaintext right away.
        if (!_legacy) {
          _legacy = true;
          _failure = LinkFailure.outdated;
          _queue.clear();
          _handshakeTimer?.cancel();
          if (!_ready.isCompleted) {
            _ready.completeError(LinkException(LinkFailure.outdated));
          }
        }
        _frames.add(f);
      default:
        break; // Nothing else is allowed before the key exchange.
    }
  }

  void _onKey(Uint8List payload) {
    if (_legacy || payload.length != 33 || payload[0] != keyExchangeVersion) {
      _fail(LinkFailure.handshake);
      return;
    }
    final SessionKeys keys;
    try {
      keys = SessionKeys.derive(
        _keys,
        Uint8List.sublistView(payload, 1),
        secret,
      );
    } on KeyExchangeException {
      _fail(LinkFailure.handshake);
      return;
    }
    _sealer = FrameCipher(keys.sendKey);
    _opener = FrameCipher(keys.receiveKey);
    if (socket.datagrams != null) {
      final label = Uint8List.fromList('gundil/v1/datagram'.codeUnits);
      _dgSealer = DatagramCipher(hkdf(keys.sendKey, Uint8List(0), label, 32));
      _dgOpener = DatagramCipher(
        hkdf(keys.receiveKey, Uint8List(0), label, 32),
      );
    }
    _securityCode = keys.securityCode;
    final queued = List.of(_queue);
    _queue.clear();
    queued.forEach(send);
    // [ready] completes when the other side's first frame (its HELLO)
    // decrypts, which proves both sides have the same keys.
  }

  void _onDatagram(Uint8List blob) {
    final opener = _dgOpener;
    if (_isClosed || opener == null || !_openedAny || blob.length < 8) return;
    final (int code, Uint8List payload) inner;
    try {
      inner = opener.open(
        blob.buffer.asByteData(blob.offsetInBytes).getUint64(0),
        Uint8List.sublistView(blob, 8),
      );
    } catch (_) {
      return; // Forged, damaged or replayed: drop it.
    }
    lastReceived = DateTime.now();
    var code = inner.$1;
    var payload = inner.$2;
    if (code & _adpcmFlag != 0) {
      code &= ~_adpcmFlag;
      final pcm = adpcmDecode(payload);
      payload = Uint8List.view(
        pcm.buffer,
        pcm.offsetInBytes,
        pcm.lengthInBytes,
      );
    }
    final type = MessageType.fromCode(code);
    if (type == MessageType.audio || type == MessageType.video) {
      _frames.add(Frame(type!, payload));
    }
  }

  void _fail(LinkFailure failure) {
    _failure ??= failure;
    _close(LinkException(failure));
  }

  Future<void> close() async {
    if (_isClosed) return;
    try {
      await socket.flush().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    _close(null);
  }

  void _close(Object? error) {
    if (_isClosed) return;
    _isClosed = true;
    _handshakeTimer?.cancel();
    if (!_ready.isCompleted) {
      _ready.completeError(
        error is LinkException ? error : LinkException(LinkFailure.closed),
      );
    }
    _sub.cancel();
    socket.destroy();
    _frames.close();
    _closed.complete();
  }
}
