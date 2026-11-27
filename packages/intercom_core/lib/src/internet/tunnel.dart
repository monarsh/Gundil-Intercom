/// TCP tunnels through an intercom at home (the gateway), so the app can
/// reach cameras on the home LAN from outside: the phone listens on local
/// ports, the gateway connects to the camera on its LAN, and the bytes go
/// through the (encrypted) link between them.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../camera/camera.dart';
import '../debug_log.dart';
import '../peer_connection.dart';
import '../protocol.dart';
import '../net_interfaces.dart';

/// A sender slows down while this much waits to go out on the link.
const int _maxPending = 512 * 1024;
const int _chunk = 16 * 1024;

void _log(String m) => debugLog('net', m);

/// The /24 networks of this device's private IPv4 addresses, and the
/// addresses themselves. (dart:io doesn't give the netmask; home LANs are
/// /24 almost always.)
Future<(List<String>, Set<String>)> localSubnets() async {
  final nets = <String>{};
  final own = <String>{};
  try {
    for (final i in await usableInterfaces()) {
      for (final a in i.addresses) {
        final b = a.rawAddress;
        final private =
            b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
            (b[0] == 192 && b[1] == 168);
        if (a.isLoopback || !private) continue;
        own.add(a.address);
        nets.add('${b[0]}.${b[1]}.${b[2]}.0/24');
      }
    }
  } catch (_) {}
  return (nets.toList()..sort(), own);
}

/// [host] (IPv4) is in [subnet]: "192.168.50.203" is in "192.168.50.0/24",
/// "10.20.3.4" in "10.20.0.0/16" (gateways may share other subnets than
/// their own /24).
bool inSubnet(String host, String subnet) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final slash = subnet.indexOf('/');
  if (slash < 0) return false;
  final net = InternetAddress.tryParse(subnet.substring(0, slash));
  final bits = int.tryParse(subnet.substring(slash + 1));
  if (net == null ||
      net.type != InternetAddressType.IPv4 ||
      bits == null ||
      bits < 0 ||
      bits > 32) {
    return false;
  }
  int value(List<int> b) => (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  final mask = bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
  return value(ip.rawAddress) & mask == value(net.rawAddress) & mask;
}

class _Tunnel {
  _Tunnel(this.link, this.tid);
  final PeerConnection link;
  final int tid;
  Socket? socket;
  StreamSubscription<Uint8List>? sub;
  final Completer<void> opened = Completer<void>();
  bool closed = false;
  Timer? drain;

  /// Socket → link, slowing the socket while the link is behind.
  void pipe(Socket s) {
    socket = s;
    sub = s.listen(
      (data) {
        for (var off = 0; off < data.length; off += _chunk) {
          final end = min(data.length, off + _chunk);
          final f = Uint8List(4 + end - off)
            ..buffer.asByteData().setUint32(0, tid)
            ..setRange(4, 4 + end - off, data, off);
          link.send(Frame(MessageType.tunnelData, f));
        }
        if (link.pendingBytes > _maxPending && drain == null) {
          sub?.pause();
          drain = Timer.periodic(const Duration(milliseconds: 50), (t) {
            if (closed || link.pendingBytes < _maxPending ~/ 2) {
              t.cancel();
              drain = null;
              sub?.resume();
            }
          });
        }
      },
      onDone: () => close(notify: true),
      onError: (Object _) => close(notify: true),
      cancelOnError: true,
    );
  }

  void close({bool notify = false}) {
    if (closed) return;
    closed = true;
    drain?.cancel();
    if (notify && !link.isClosed) {
      link.send(
        Frame(
          MessageType.tunnelClose,
          Uint8List(4)..buffer.asByteData().setUint32(0, tid),
        ),
      );
    }
    sub?.cancel();
    socket?.destroy();
    if (!opened.isCompleted) {
      opened.completeError(const SocketException('tunnel closed'));
    }
  }
}

/// The local stand-ins for one camera reached through a gateway.
class _Proxies {
  _Proxies(this.servers, this.camera);
  final List<ServerSocket> servers;
  final SavedCamera camera;
}

class TunnelHub {
  TunnelHub({required this.linkTo, required this.sharing});

  /// Tests: forward to any address (loopback too).
  static bool debugAnyTarget = false;

  /// A link to the gateway (punched on demand).
  final Future<PeerConnection> Function(String gatewayId) linkTo;

  /// Whether this device shares its LAN (gateway role).
  final bool Function() sharing;

  final Map<PeerConnection, Map<int, _Tunnel>> _tunnels = {};
  final Map<String, _Proxies> _proxies = {};
  int _nextTid = 1;

  /// Tunnels open on [c] (it must stay up).
  bool busy(PeerConnection c) => _tunnels[c]?.isNotEmpty ?? false;

  void _add(_Tunnel t) => (_tunnels[t.link] ??= {})[t.tid] = t;
  void _remove(_Tunnel t) => _tunnels[t.link]?.remove(t.tid);

  // ------------------------------------------------------------- client

  /// [cam] as seen through local stand-ins for its ports, forwarded via
  /// [gatewayId]. Kept until [closeProxies].
  Future<SavedCamera> proxy(SavedCamera cam, String gatewayId) async {
    final have = _proxies[cam.peerId];
    if (have != null) return have.camera;
    final ports = [cam.port, cam.rtspPort, cam.onvifPort, cam.controlPort];
    final servers = <ServerSocket>[];
    for (final port in ports) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) => _accept(s, gatewayId, cam.host, port));
      servers.add(server);
    }
    final local = cam.copyWith(
      host: '127.0.0.1',
      port: servers[0].port,
      rtspPort: servers[1].port,
      onvifPort: servers[2].port,
      controlPort: servers[3].port,
    );
    _proxies[cam.peerId] = _Proxies(servers, local);
    _log('${cam.name}: reached through $gatewayId (local stand-ins ready)');
    return local;
  }

  void closeProxies(String cameraPeerId) {
    final p = _proxies.remove(cameraPeerId);
    if (p == null) return;
    for (final s in p.servers) {
      s.close();
    }
  }

  Future<void> _accept(
    Socket s,
    String gatewayId,
    String host,
    int port,
  ) async {
    final PeerConnection link;
    try {
      link = await linkTo(gatewayId);
    } catch (e) {
      _log('tunnel to $host:$port: no link to the gateway: $e');
      s.destroy();
      return;
    }
    final t = _Tunnel(link, _nextTid++);
    _add(t);
    t.opened.future.catchError((Object _) {});
    link.send(
      Frame.json(MessageType.tunnelOpen, {
        'tid': t.tid,
        'host': host,
        'port': port,
      }),
    );
    try {
      await t.opened.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _log('tunnel to $host:$port failed: $e');
      t.close();
      _remove(t);
      s.destroy();
      return;
    }
    t.pipe(s);
    t.socket!.done.whenComplete(() => _remove(t)).catchError((Object _) {});
  }

  // ------------------------------------------------------------ gateway

  Future<void> onOpen(PeerConnection c, Map<String, Object?> m) async {
    final tid = m['tid'], host = m['host'], port = m['port'];
    if (tid is! int || host is! String || port is! int) return;
    void reply(bool ok, [String? error]) => c.send(
      Frame.json(MessageType.tunnelReply, {
        'tid': tid,
        'ok': ok,
        'error': ?error,
      }),
    );
    if (!sharing()) {
      reply(false, 'this intercom does not share its cameras');
      return;
    }
    final (nets, own) = await localSubnets();
    if (!debugAnyTarget &&
        (own.contains(host) || !nets.any((n) => inSubnet(host, n)))) {
      _log('tunnel refused: $host:$port is not on this LAN');
      reply(false, '$host is not on the gateway\'s LAN');
      return;
    }
    if (port <= 0 || port > 65535) {
      reply(false, 'bad port');
      return;
    }
    final t = _Tunnel(c, tid);
    _add(t);
    try {
      final s = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      if (c.isClosed || t.closed) {
        s.destroy();
        return;
      }
      reply(true);
      if (!t.opened.isCompleted) t.opened.complete();
      t.pipe(s);
      s.done.whenComplete(() => _remove(t)).catchError((Object _) {});
      _log('tunnel to $host:$port opened for ${c.remoteId}');
    } catch (e) {
      _remove(t);
      reply(
        false,
        e is SocketException ? (e.osError?.message ?? e.message) : '$e',
      );
    }
  }

  // ------------------------------------------------------------- both

  void onReply(PeerConnection c, Map<String, Object?> m) {
    final t = _tunnels[c]?[m['tid']];
    if (t == null || t.opened.isCompleted) return;
    if (m['ok'] == true) {
      t.opened.complete();
    } else {
      t.opened.completeError(
        SocketException('${m['error'] ?? 'refused by the gateway'}'),
      );
    }
  }

  void onData(PeerConnection c, Uint8List payload) {
    if (payload.length < 4) return;
    final tid = payload.buffer.asByteData(payload.offsetInBytes).getUint32(0);
    final t = _tunnels[c]?[tid];
    if (t == null) return;
    try {
      t.socket?.add(Uint8List.sublistView(payload, 4));
    } catch (_) {
      t.close(notify: true);
      _remove(t);
    }
  }

  void onClose(PeerConnection c, Uint8List payload) {
    if (payload.length < 4) return;
    final tid = payload.buffer.asByteData(payload.offsetInBytes).getUint32(0);
    final t = _tunnels[c]?.remove(tid);
    t?.close();
  }

  void connectionClosed(PeerConnection c) {
    final ts = _tunnels.remove(c);
    if (ts == null) return;
    for (final t in ts.values) {
      t.close();
    }
  }

  void dispose() {
    for (final id in _proxies.keys.toList()) {
      closeProxies(id);
    }
    for (final c in _tunnels.keys.toList()) {
      connectionClosed(c);
    }
  }
}
