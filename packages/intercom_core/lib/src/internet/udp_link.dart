/// Hole-punched UDP paths between two intercoms, and a [LinkTransport] on
/// top: a reliable ordered byte stream (for the encrypted frames, exactly
/// like TCP) plus unreliable datagrams (for audio and video).
///
/// Packets start with 0xC7, which a STUN message never does, so one socket
/// serves STUN, punching and every link:
///   `[0xC7][kind][connId:4][...]`
///   kind 1 PUNCH    `[mac:16]`         "here I am" (both sides, repeatedly)
///   kind 2 PUNCH_OK `[mac:16]`         "heard you"
///   kind 3 DATA     `[seq:4][bytes]`   reliable stream segment
///   kind 4 ACK      `[next:4]`         everything before `next` arrived
///   kind 5 DGRAM    `[msg:4][i][n][piece]`  piece i of n of a datagram
///   kind 6 CLOSE
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../debug_log.dart';
import '../link_transport.dart';
import 'stun.dart';

const int _tag = 0xC7;
const int _punch = 1, _punchOk = 2, _data = 3, _ack = 4, _dgram = 5;
const int _close = 6;

/// Payload per packet: fits a 1280-byte path with room for headers.
const int segmentSize = 1100;

Uint8List _mac(Uint8List key, int kind, int connId) {
  final h = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  final msg = Uint8List(5)
    ..[0] = kind
    ..buffer.asByteData().setUint32(1, connId);
  final out = h.process(msg);
  return Uint8List.sublistView(out, 0, 16);
}

bool _sameMac(Uint8List a, List<int> b) {
  if (b.length < 16) return false;
  var d = 0;
  for (var i = 0; i < 16; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

class _Punch {
  _Punch(this.connId, this.key, this.completer);
  final int connId;
  final Uint8List key;
  final Completer<UdpTransport> completer;
}

/// The app's one UDP socket for the internet.
class UdpMux {
  UdpMux._(this.socket) : stun = StunClient(socket) {
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = socket.receive()) != null) {
        _onPacket(d!);
      }
    });
  }

  static Future<UdpMux> bind({int port = 0}) async {
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    return UdpMux._(s);
  }

  final RawDatagramSocket socket;
  final StunClient stun;
  final Map<int, UdpTransport> _links = {};
  final Map<int, _Punch> _punches = {};
  final Map<int, Uint8List> _keys = {};
  bool _closed = false;

  int get port => socket.port;

  void _send(Uint8List data, InternetAddress to, int port) {
    if (_closed) return;
    try {
      socket.send(data, to, port);
    } catch (_) {}
  }

  static Uint8List _header(int kind, int connId, int extra) {
    final b = Uint8List(6 + extra);
    b[0] = _tag;
    b[1] = kind;
    b.buffer.asByteData().setUint32(2, connId);
    return b;
  }

  void _onPacket(Datagram d) {
    final p = d.data;
    if (p.isEmpty) return;
    if (p[0] != _tag) {
      stun.handle(p);
      return;
    }
    if (p.length < 6) return;
    final kind = p[1];
    final connId = ByteData.sublistView(p).getUint32(2);
    final body = Uint8List.sublistView(p, 6);
    if (kind == _punch || kind == _punchOk) {
      final key = _keys[connId];
      if (key == null || !_sameMac(_mac(key, kind, connId), body)) return;
      // Always answer: the other side may still be punching.
      if (kind == _punch) {
        _send(
          Uint8List.fromList([
            ..._header(_punchOk, connId, 0),
            ..._mac(key, _punchOk, connId),
          ]),
          d.address,
          d.port,
        );
      }
      final pending = _punches.remove(connId);
      if (pending != null && !pending.completer.isCompleted) {
        final link = UdpTransport._(this, connId, d.address, d.port);
        _links[connId] = link;
        debugLog(
          'net',
          'punched through to ${d.address.address}:${d.port} '
              '(${kind == _punch ? 'their punch arrived' : 'they heard ours'})',
        );
        pending.completer.complete(link);
      }
      return;
    }
    final link = _links[connId];
    if (link == null) return;
    // Their NAT may have moved them to another port: follow it once a
    // packet that belongs to the link arrives (it's authenticated above
    // this layer; a forged one just fails to decrypt).
    link._onPacket(kind, body, d.address, d.port);
  }

  /// Punches to every candidate until the other side's punch (or its
  /// answer to ours) arrives, then returns the link. Both sides must call
  /// this with the same [connId] and [key] (from the encrypted signal).
  Future<UdpTransport> punch({
    required int connId,
    required Uint8List key,
    required List<(InternetAddress, int)> candidates,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final existing = _links[connId];
    if (existing != null && !existing._closed) return existing;
    _keys[connId] = key;
    final c = Completer<UdpTransport>();
    _punches[connId] = _Punch(connId, key, c);
    final packet = Uint8List.fromList([
      ..._header(_punch, connId, 0),
      ..._mac(key, _punch, connId),
    ]);
    debugLog(
      'net',
      'punching to ${candidates.map((e) => '${e.$1.address}:${e.$2}').join(', ')}',
    );
    final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      for (final (a, p) in candidates) {
        _send(packet, a, p);
      }
    });
    for (final (a, p) in candidates) {
      _send(packet, a, p);
    }
    try {
      return await c.future.timeout(timeout);
    } finally {
      timer.cancel();
      _punches.remove(connId);
    }
  }

  void _forget(int connId) {
    _links.remove(connId);
    _keys.remove(connId);
  }

  void close() {
    if (_closed) return;
    for (final l in _links.values.toList()) {
      l.destroy();
    }
    _closed = true;
    socket.close();
  }
}

class _Segment {
  _Segment(this.seq, this.data);
  final int seq;
  final Uint8List data;
  DateTime? sentAt;
  int sends = 0;
}

class _Parts {
  _Parts(this.count) : parts = List<Uint8List?>.filled(count, null);
  final int count;
  final List<Uint8List?> parts;
  int have = 0;
  final DateTime started = DateTime.now();
}

/// One punched path: a reliable stream (like TCP, with acknowledgements,
/// retransmission and a congestion window) plus datagrams.
class UdpTransport implements LinkTransport, DatagramChannel {
  UdpTransport._(this._mux, this.connId, this._addr, this._port) {
    _tick = Timer.periodic(const Duration(milliseconds: 50), (_) => _onTick());
  }

  final UdpMux _mux;
  final int connId;
  InternetAddress _addr;
  int _port;

  // Sending.
  final Queue<Uint8List> _out = Queue<Uint8List>();
  int _outLen = 0;
  int _outHead = 0; // Bytes of _out.first already sent.
  final SplayTreeMap<int, _Segment> _inFlight = SplayTreeMap();
  int _nextSeq = 0;
  double _cwnd = 10;
  Duration _srtt = const Duration(milliseconds: 300);
  int _dupAcks = 0;
  int _lastAck = 0;
  DateTime _lastCut = DateTime(2000);
  Completer<void>? _flushed;

  // Receiving.
  int _expected = 0;
  final Map<int, Uint8List> _early = {};
  final StreamController<List<int>> _in = StreamController<List<int>>();

  // Datagrams.
  int _msgId = 0;
  final Map<int, _Parts> _assembling = {};
  @override
  void Function(Uint8List blob)? onReceive;

  late final Timer _tick;
  bool _closed = false;
  final Completer<void> _done = Completer<void>();
  DateTime _lastHeard = DateTime.now();

  /// A link that hears nothing at all for this long is gone.
  /// (Idle links are pinged every 30 s at most; see the battery saving.)
  static const Duration silenceTimeout = Duration(seconds: 100);

  String get debugState =>
      'closed=$_closed inFlight=${_inFlight.length} '
      'first=${_inFlight.isEmpty ? '-' : '${_inFlight.firstKey()} x${_inFlight.values.first.sends}'} '
      'out=$_outLen cwnd=${_cwnd.toStringAsFixed(1)} '
      'next=$_nextSeq lastAck=$_lastAck expected=$_expected early=${_early.length} '
      'srtt=${_srtt.inMilliseconds}ms';

  @override
  InternetAddress get remoteAddress => _addr;
  @override
  int get remotePort => _port;
  @override
  InternetAddress? get localAddress => null;
  @override
  String? get route => 'internet';
  @override
  int get pending =>
      _outLen + _inFlight.values.fold(0, (n, s) => n + s.data.length);
  @override
  DatagramChannel? get datagrams => this;
  @override
  Future<void> get done => _done.future;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> data) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _in.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  void _raw(int kind, List<int> body) {
    final p = Uint8List(6 + body.length);
    p[0] = _tag;
    p[1] = kind;
    p.buffer.asByteData().setUint32(2, connId);
    p.setRange(6, p.length, body);
    _mux._send(p, _addr, _port);
  }

  @override
  void add(List<int> data) {
    if (_closed) throw const SocketException('link closed');
    if (data.isEmpty) return;
    _out.add(data is Uint8List ? data : Uint8List.fromList(data));
    _outLen += data.length;
    _pump();
  }

  /// Sends new segments while the window allows.
  void _pump() {
    while (_outLen > 0 && _inFlight.length < _cwnd.floor()) {
      final n = min(segmentSize, _outLen);
      final chunk = Uint8List(n);
      var filled = 0;
      while (filled < n) {
        final head = _out.first;
        final take = min(n - filled, head.length - _outHead);
        chunk.setRange(filled, filled + take, head, _outHead);
        filled += take;
        _outHead += take;
        if (_outHead == head.length) {
          _out.removeFirst();
          _outHead = 0;
        }
      }
      _outLen -= n;
      final s = _Segment(_nextSeq++, chunk);
      _inFlight[s.seq] = s;
      _transmit(s);
    }
    _checkFlushed();
  }

  void _transmit(_Segment s) {
    s.sentAt = DateTime.now();
    s.sends++;
    final b = Uint8List(4 + s.data.length);
    b.buffer.asByteData().setUint32(0, s.seq);
    b.setRange(4, b.length, s.data);
    _raw(_data, b);
  }

  Duration get _rto {
    final ms = (_srtt.inMilliseconds * 2).clamp(200, 3000);
    return Duration(milliseconds: ms);
  }

  void _onTick() {
    if (_closed) return;
    final now = DateTime.now();
    if (now.difference(_lastHeard) > silenceTimeout) {
      debugLog('net', 'link to ${_addr.address}:$_port went silent');
      _shutdown(const SocketException('link went silent'));
      return;
    }
    var lost = false;
    for (final s in _inFlight.values) {
      final sent = s.sentAt;
      if (sent == null) continue;
      var rto = _rto * (1 << min(s.sends - 1, 3));
      if (rto > const Duration(seconds: 3)) rto = const Duration(seconds: 3);
      if (now.difference(sent) >= rto) {
        if (s.sends >= 15) {
          _shutdown(const SocketException('link stopped answering'));
          return;
        }
        lost = true;
        _transmit(s);
      }
    }
    // One halving per round trip at most, not per lost packet.
    if (lost && now.difference(_lastCut) > _srtt) {
      _cwnd = max(4, _cwnd / 2);
      _lastCut = now;
    }
    final stale = _assembling.entries
        .where((e) => now.difference(e.value.started).inSeconds > 2)
        .map((e) => e.key)
        .toList();
    stale.forEach(_assembling.remove);
  }

  void _onPacket(int kind, Uint8List body, InternetAddress from, int port) {
    if (_closed) return;
    _lastHeard = DateTime.now();
    if (from != _addr || port != _port) {
      debugLog(
        'net',
        'link moved: ${_addr.address}:$_port → ${from.address}:$port',
      );
      _addr = from;
      _port = port;
    }
    switch (kind) {
      case _data when body.length >= 4:
        final seq = ByteData.sublistView(body).getUint32(0);
        final data = Uint8List.fromList(body.sublist(4));
        if (seq >= _expected && !_early.containsKey(seq)) _early[seq] = data;
        while (_early.containsKey(_expected)) {
          _in.add(_early.remove(_expected)!);
          _expected++;
        }
        final a = Uint8List(4)..buffer.asByteData().setUint32(0, _expected);
        _raw(_ack, a);
      case _ack when body.length >= 4:
        _onAck(ByteData.sublistView(body).getUint32(0));
      case _dgram when body.length >= 6:
        final msg = ByteData.sublistView(body).getUint32(0);
        final i = body[4], n = body[5];
        if (n == 0 || i >= n) return;
        final piece = Uint8List.fromList(body.sublist(6));
        if (n == 1) {
          onReceive?.call(piece);
          return;
        }
        final parts = _assembling.putIfAbsent(msg, () => _Parts(n));
        if (parts.count != n || parts.parts[i] != null) return;
        parts.parts[i] = piece;
        if (++parts.have == n) {
          _assembling.remove(msg);
          final b = BytesBuilder(copy: false);
          for (final x in parts.parts) {
            b.add(x!);
          }
          onReceive?.call(b.takeBytes());
        }
      case _close:
        _shutdown(null, notify: false);
      case _punch || _punchOk:
        break; // Handled by the mux.
    }
  }

  void _onAck(int next) {
    if (next == _lastAck) {
      // The same ack again: something after it was lost.
      if (++_dupAcks == 3) {
        final s = _inFlight[next];
        if (s != null) {
          final now = DateTime.now();
          if (now.difference(_lastCut) > _srtt) {
            _cwnd = max(4, _cwnd / 2);
            _lastCut = now;
          }
          _transmit(s);
        }
      }
      return;
    }
    if (next < _lastAck) return;
    _lastAck = next;
    _dupAcks = 0;
    final acked = _inFlight.keys.takeWhile((k) => k < next).toList();
    final now = DateTime.now();
    for (final k in acked) {
      final s = _inFlight.remove(k)!;
      if (s.sends == 1 && s.sentAt != null) {
        final sample = now.difference(s.sentAt!);
        _srtt = Duration(
          microseconds: (_srtt.inMicroseconds * 7 + sample.inMicroseconds) ~/ 8,
        );
      }
      _cwnd = min(256, _cwnd + 1 / _cwnd);
    }
    _pump();
  }

  void _checkFlushed() {
    final f = _flushed;
    if (f != null && _outLen == 0 && _inFlight.isEmpty) {
      _flushed = null;
      if (!f.isCompleted) f.complete();
    }
  }

  @override
  Future<void> flush() {
    if (_outLen == 0 && _inFlight.isEmpty) return Future.value();
    final f = _flushed ??= Completer<void>();
    return f.future;
  }

  @override
  void send(Uint8List blob) {
    if (_closed) return;
    final n = max(1, (blob.length + segmentSize - 1) ~/ segmentSize);
    if (n > 255) return; // Too big for a datagram: drop.
    final msg = _msgId++;
    for (var i = 0; i < n; i++) {
      final start = i * segmentSize;
      final end = min(blob.length, start + segmentSize);
      final b = Uint8List(6 + end - start);
      final h = b.buffer.asByteData();
      h.setUint32(0, msg);
      b[4] = i;
      b[5] = n;
      b.setRange(6, b.length, blob, start);
      _raw(_dgram, b);
    }
  }

  @override
  void destroy() => _shutdown(null);

  void _shutdown(Object? error, {bool notify = true}) {
    if (_closed) return;
    if (notify) _raw(_close, const []);
    _closed = true;
    _tick.cancel();
    _mux._forget(connId);
    final f = _flushed;
    if (f != null && !f.isCompleted) f.complete();
    if (error != null) _in.addError(error);
    _in.close();
    if (!_done.isCompleted) _done.complete();
  }
}
