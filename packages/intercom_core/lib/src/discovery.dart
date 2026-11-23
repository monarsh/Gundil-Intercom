import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

/// A beacon received from another intercom on the LAN.
class DiscoveryBeacon {
  DiscoveryBeacon({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.tcpPort,
    this.version = 1,
    this.leaving = false,
    this.every,
  });

  final String id;
  final String name;
  final String platform;
  final InternetAddress address;
  final int tcpPort;
  final int version;
  final bool leaving;

  /// How often the sender announces itself, when slower than usual (it
  /// saves battery); null: the usual 2 s.
  final Duration? every;
}

/// LAN peer discovery via periodic UDP broadcast beacons.
///
/// Each node broadcasts a small JSON datagram every [interval] on
/// [discoveryPort] and listens for everybody else's. Beacons are sent both to
/// the limited broadcast address and to the /24 directed broadcast of every
/// local IPv4 interface, which makes it work on multi-homed Windows machines
/// where 255.255.255.255 only leaves through one adapter.
class Discovery {
  Discovery({
    required this.selfId,
    required this.name,
    required this.tcpPort,
    this.port = discoveryPort,
    this.interval = const Duration(seconds: 2),
  });

  final String selfId;
  String name;
  int tcpPort;
  final int port;
  final Duration interval;

  /// How often to announce ourselves (at least [interval]; null: not at
  /// all, e.g. on mobile data where there's no LAN). Beacons from others
  /// are still heard.
  late Duration? announceEvery = interval;
  DateTime? _lastAnnounce;

  RawDatagramSocket? _socket;
  Timer? _timer;
  List<InternetAddress> _targets = [InternetAddress('255.255.255.255')];
  int _tick = 0;
  final StreamController<DiscoveryBeacon> _beacons =
      StreamController<DiscoveryBeacon>.broadcast();

  Stream<DiscoveryBeacon> get beacons => _beacons.stream;
  bool get running => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    await _bind();
    _timer ??= Timer.periodic(interval, (_) {
      if (++_tick % 15 == 0) _refreshTargets();
      final every = announceEvery;
      if (every == null) return;
      final last = _lastAnnounce;
      if (last != null &&
          DateTime.now().difference(last) <
              every - const Duration(milliseconds: 500)) {
        return;
      }
      _announce();
    });
  }

  Future<void> _bind() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: Platform.isLinux || Platform.isAndroid || Platform.isMacOS,
    );
    socket.broadcastEnabled = true;
    socket.listen(
      (event) {
        if (event == RawSocketEvent.read) _read(socket);
        if (event == RawSocketEvent.closed) _lost(socket);
      },
      onError: (Object _) => _lost(socket),
      onDone: () => _lost(socket),
    );
    _socket = socket;
    await _refreshTargets();
    _announce();
  }

  /// The system closed the socket under us (the network went away on some
  /// phones): bind a new one.
  void _lost(RawDatagramSocket s) {
    if (!identical(_socket, s) || _timer == null) return;
    _socket = null;
    s.close();
    Future<void>.delayed(const Duration(seconds: 1), () async {
      if (_socket != null || _timer == null) return;
      try {
        await _bind();
      } catch (_) {
        // No network right now; [restart] tries again on the next change.
      }
    });
  }

  /// After a network change: a fresh socket, the new interfaces' broadcast
  /// addresses, and a beacon right away so peers see us at once.
  Future<void> restart() async {
    if (_timer == null) return start();
    final old = _socket;
    _socket = null;
    old?.close();
    try {
      await _bind();
    } catch (_) {
      // No network right now; tried again on the next change.
    }
  }

  /// Sends an immediate beacon (e.g. after a name change).
  void announceNow() => _announce();

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final s = _socket;
    if (s != null) {
      _send(s, leaving: true);
      s.close();
    }
    _socket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _beacons.close();
  }

  Future<void> _refreshTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          final parts = a.address.split('.');
          if (parts.length == 4) {
            targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (_) {}
    _targets = targets.map(InternetAddress.new).toList();
  }

  void _announce() {
    final s = _socket;
    _lastAnnounce = DateTime.now();
    if (s != null) _send(s);
  }

  void _send(RawDatagramSocket s, {bool leaving = false}) {
    final data = utf8.encode(
      jsonEncode({
        'app': 'p2p-intercom',
        'v': protocolVersion,
        'id': selfId,
        'name': name,
        'platform': Platform.operatingSystem,
        'port': tcpPort,
        if (leaving) 'bye': true,
        // Announcing less often: don't count us as gone between beacons.
        if (announceEvery != interval)
          'every': (announceEvery ?? interval).inSeconds,
      }),
    );
    for (final t in _targets) {
      try {
        s.send(data, t, port);
      } catch (_) {
        // Interface may have gone away; ignore.
      }
    }
  }

  void _read(RawDatagramSocket s) {
    Datagram? d;
    while ((d = s.receive()) != null) {
      final beacon = parseBeacon(d!.data, d.address, selfId);
      if (beacon != null && !_beacons.isClosed) _beacons.add(beacon);
    }
  }

  /// Parses a beacon datagram; returns null for foreign/invalid/own packets.
  static DiscoveryBeacon? parseBeacon(
    List<int> data,
    InternetAddress from,
    String selfId,
  ) {
    try {
      final m = jsonDecode(utf8.decode(data));
      if (m is! Map || m['app'] != 'p2p-intercom') return null;
      final id = m['id'];
      final port = m['port'];
      if (id is! String || id == selfId || port is! int) return null;
      if (port <= 0 || port > 65535) return null;
      return DiscoveryBeacon(
        id: id,
        name: (m['name'] as String?) ?? 'Unknown',
        platform: (m['platform'] as String?) ?? '?',
        address: from,
        tcpPort: port,
        version: (m['v'] as int?) ?? 1,
        leaving: m['bye'] == true,
        every: m['every'] is int && (m['every'] as int) > 0
            ? Duration(seconds: (m['every'] as int).clamp(1, 120))
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}
