/// A small STUN client (RFC 5389 Binding requests): what public IPv4
/// address and port the NAT gives a UDP socket, and what kind of NAT it is.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Public STUN servers (no account needed).
const List<(String, int)> defaultStunServers = [
  ('stun.l.google.com', 19302),
  ('stun1.l.google.com', 19302),
  ('stun.cloudflare.com', 3478),
];

const int _magic = 0x2112A442;

/// How the NAT maps one socket to the outside.
enum NatType {
  /// Not checked yet, or no STUN server answered.
  unknown,

  /// The same public port whatever the destination: hole punching works.
  cone,

  /// A different public port per destination: direct calls may fail.
  symmetric,

  /// The public address is the device's own: no NAT at all.
  open,
}

class StunResult {
  StunResult(this.address, this.port);
  final InternetAddress address;
  final int port;
  @override
  String toString() => '${address.address}:$port';
}

/// A Binding request for [id] (12 random bytes).
Uint8List stunRequest(Uint8List id) {
  final b = Uint8List(20);
  final d = ByteData.sublistView(b);
  d.setUint16(0, 0x0001); // Binding request
  d.setUint16(2, 0); // No attributes
  d.setUint32(4, _magic);
  b.setRange(8, 20, id);
  return b;
}

/// Whether [data] looks like a STUN message (first two bits 0, magic
/// cookie), so the link can tell STUN answers from its own packets.
bool isStun(Uint8List data) =>
    data.length >= 20 &&
    (data[0] & 0xC0) == 0 &&
    ByteData.sublistView(data).getUint32(4) == _magic;

/// Parses a Binding success response to the request [id]: the mapped
/// address (XOR-MAPPED-ADDRESS, or MAPPED-ADDRESS from old servers).
StunResult? parseStunResponse(Uint8List data, Uint8List id) {
  if (!isStun(data)) return null;
  final d = ByteData.sublistView(data);
  if (d.getUint16(0) != 0x0101) return null;
  for (var i = 0; i < 12; i++) {
    if (data[8 + i] != id[i]) return null;
  }
  final length = d.getUint16(2);
  var off = 20;
  final end = min(20 + length, data.length);
  StunResult? plain;
  while (off + 4 <= end) {
    final type = d.getUint16(off);
    final len = d.getUint16(off + 2);
    final v = off + 4;
    if (v + len > end) break;
    if ((type == 0x0020 || type == 0x0001) && len >= 8 && data[v + 1] == 1) {
      var port = d.getUint16(v + 2);
      final ip = Uint8List.fromList(data.sublist(v + 4, v + 8));
      if (type == 0x0020) {
        port ^= _magic >> 16;
        for (var k = 0; k < 4; k++) {
          ip[k] ^= (_magic >> (24 - 8 * k)) & 0xFF;
        }
        return StunResult(InternetAddress.fromRawAddress(ip), port);
      }
      plain = StunResult(InternetAddress.fromRawAddress(ip), port);
    }
    off = v + ((len + 3) & ~3);
  }
  return plain;
}

/// Asks STUN servers through a socket that is already in use for other
/// things: the owner passes every received datagram to [handle] first.
class StunClient {
  StunClient(this.socket);
  final RawDatagramSocket socket;
  final Map<String, Completer<StunResult>> _pending = {};
  final Random _rng = Random.secure();

  static String _key(Uint8List id) => id.join(',');

  /// Returns true when [data] was a STUN answer (consumed).
  bool handle(Uint8List data) {
    if (!isStun(data) || data.length < 20) return false;
    final id = Uint8List.fromList(data.sublist(8, 20));
    final c = _pending.remove(_key(id));
    if (c == null) return true;
    final r = parseStunResponse(data, id);
    if (r != null && !c.isCompleted) c.complete(r);
    return true;
  }

  /// The public address one server sees, retrying a few times.
  Future<StunResult?> query(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final List<InternetAddress> addrs;
    try {
      addrs = (await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      )).toList();
    } catch (_) {
      return null;
    }
    if (addrs.isEmpty) return null;
    final id = Uint8List.fromList(List.generate(12, (_) => _rng.nextInt(256)));
    final c = Completer<StunResult>();
    _pending[_key(id)] = c;
    final req = stunRequest(id);
    final end = DateTime.now().add(timeout);
    var wait = const Duration(milliseconds: 250);
    try {
      while (!c.isCompleted && DateTime.now().isBefore(end)) {
        try {
          socket.send(req, addrs.first, port);
        } catch (_) {}
        try {
          return await c.future.timeout(wait);
        } on TimeoutException {
          wait *= 2;
        }
      }
      return c.isCompleted ? await c.future : null;
    } finally {
      _pending.remove(_key(id));
    }
  }

  /// Asks two servers: the public address, and whether the NAT keeps the
  /// same public port for both (cone) or not (symmetric).
  Future<(StunResult?, NatType)> check({
    List<(String, int)> servers = defaultStunServers,
    Set<String> localAddresses = const {},
  }) async {
    final results = await Future.wait([
      for (final (h, p) in servers) query(h, p),
    ]);
    final ok = results.whereType<StunResult>().toList();
    if (ok.isEmpty) return (null, NatType.unknown);
    final first = ok.first;
    if (localAddresses.contains(first.address.address)) {
      return (first, NatType.open);
    }
    if (ok.length < 2) return (first, NatType.unknown);
    final same = ok.every(
      (r) => r.port == first.port && r.address == first.address,
    );
    return (first, same ? NatType.cone : NatType.symmetric);
  }
}
