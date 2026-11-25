/// Internet mode: meets the other intercoms with the same password on public
/// Nostr relays, learns this device's public address from public STUN
/// servers, and sets up hole-punched UDP links on demand (when a call
/// starts). No server of our own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../debug_log.dart';
import '../secure_channel.dart';
import 'nostr.dart';
import 'rendezvous.dart';
import 'schnorr.dart';
import 'stun.dart';
import 'udp_link.dart';

class InternetException implements Exception {
  InternetException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What "Check network" shows.
class NetworkCheck {
  NetworkCheck({
    required this.relays,
    required this.relaysTotal,
    required this.nat,
    this.publicAddress,
  });
  final int relays, relaysTotal;
  final NatType nat;
  final String? publicAddress;
}

class InternetService {
  InternetService({
    required this.selfId,
    required this.keys,
    required this.nostrSecret,
    required this.presence,
    required this.onPresence,
    required this.onIncoming,
    this.relays = defaultRelays,
    this.stunServers = defaultStunServers,
  });

  final String selfId;
  final RendezvousKeys keys;
  final Uint8List nostrSecret;
  final List<String> relays;
  final List<(String, int)> stunServers;

  /// Who we are right now (name, subnets, ...), for presence.
  final Presence Function() presence;
  final void Function(Presence p) onPresence;

  /// Someone punched through to us: hand the link to the engine.
  final void Function(UdpTransport link) onIncoming;

  UdpMux? _mux;
  Rendezvous? _rv;
  Timer? _refresh;
  Duration _refreshEvery = const Duration(minutes: 5);
  final Map<String, Completer<Signal>> _answers = {};
  final Random _rng = Random.secure();
  (DateTime, StunResult?, NatType)? _stunCache;
  bool _stopped = false;

  void _log(String m) => debugLog('net', m);

  int get relaysConnected => _rv?.client.connectedCount ?? 0;
  NatType get natType => _stunCache?.$3 ?? NatType.unknown;
  String? get publicAddress => _stunCache?.$2?.toString();
  Stream<void> get relayStatus =>
      _rv?.client.statusChanged ?? const Stream.empty();

  /// How often presence is published again (less on mobile data).
  set refreshEvery(Duration d) {
    if (d == _refreshEvery) return;
    _refreshEvery = d;
    if (_refresh != null) _startRefresh();
  }

  Future<void> start() async {
    final mux = await UdpMux.bind();
    _mux = mux;
    final rv = Rendezvous(
      client: NostrClient(relays: relays),
      keys: keys,
      selfId: selfId,
      secret: nostrSecret,
    );
    _rv = rv;
    rv.presence.listen(onPresence);
    rv.signals.listen(_onSignal);
    rv.client.onConnected = announce;
    rv.start();
    _startRefresh();
    _log('internet mode on (UDP port ${mux.port}, ${relays.length} relays)');
    unawaited(_stun()); // Learn the NAT type early, for "Check network".
  }

  void _startRefresh() {
    _refresh?.cancel();
    _refresh = Timer.periodic(_refreshEvery, (_) => announce());
  }

  void announce() {
    final rv = _rv;
    if (rv == null || _stopped) return;
    rv.announce(presence());
  }

  Future<(StunResult?, NatType)> _stun({bool fresh = false}) async {
    final c = _stunCache;
    if (!fresh && c != null && DateTime.now().difference(c.$1).inSeconds < 60) {
      return (c.$2, c.$3);
    }
    final mux = _mux;
    if (mux == null) return (null, NatType.unknown);
    final (r, nat) = await mux.stun.check(
      servers: stunServers,
      localAddresses: await _localIPv4(),
    );
    _stunCache = (DateTime.now(), r, nat);
    _log('STUN: public address ${r ?? 'unknown'}, NAT ${nat.name}');
    return (r, nat);
  }

  static Future<Set<String>> _localIPv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return {
        for (final i in ifaces)
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      };
    } catch (_) {
      return {};
    }
  }

  /// Our public address from STUN, then LAN addresses (same port).
  Future<List<String>> _candidates() async {
    final mux = _mux!;
    final (pub, _) = await _stun();
    return [
      if (pub != null) pub.toString(),
      for (final a in await _localIPv4()) '$a:${mux.port}',
    ];
  }

  static List<(InternetAddress, int)> _parse(List<String> cands) => [
    for (final c in cands)
      if (c.lastIndexOf(':') case final i when i > 0)
        if (InternetAddress.tryParse(c.substring(0, i)) case final a?)
          if (int.tryParse(c.substring(i + 1)) case final p?)
            if (a.type == InternetAddressType.IPv4 && p > 0 && p < 65536)
              (a, p),
  ];

  (int, Uint8List) _linkKeys(String sid) {
    final k = hkdf(
      keys.contentKey,
      Uint8List(0),
      Uint8List.fromList(utf8.encode('gundil/v1/punch/$sid')),
      36,
    );
    return (
      ByteData.sublistView(k, 32, 36).getUint32(0),
      Uint8List.sublistView(k, 0, 32),
    );
  }

  /// Sets up a direct link to [peerId]: offer, answer, punch.
  Future<UdpTransport> connect(String peerId, {String? name}) async {
    final rv = _rv, mux = _mux;
    if (rv == null || mux == null) {
      throw InternetException('internet mode is off');
    }
    final who = name ?? peerId;
    final sid = toHex(List.generate(8, (_) => _rng.nextInt(256)));
    final answer = Completer<Signal>();
    _answers[sid] = answer;
    try {
      final cands = await _candidates();
      final sent = rv.send(
        Signal(
          from: selfId,
          to: peerId,
          sid: sid,
          type: 'offer',
          candidates: cands,
        ),
      );
      if (sent == 0) {
        throw InternetException('no relay connected (no internet?)');
      }
      _log('offer to $who: ${cands.length} addresses, via $sent relays');
      final Signal a;
      try {
        a = await answer.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        throw InternetException(
          "$who didn't answer over the internet (offline, or Internet calls "
          'off there)',
        );
      }
      final (connId, key) = _linkKeys(sid);
      try {
        return await mux.punch(
          connId: connId,
          key: key,
          candidates: _parse(a.candidates),
        );
      } on TimeoutException {
        throw InternetException(
          "Can't reach $who directly: the two networks block it (strict "
          'NAT). Try Wi-Fi, or Tailscale',
        );
      }
    } finally {
      _answers.remove(sid);
    }
  }

  Future<void> _onSignal(Signal s) async {
    switch (s.type) {
      case 'answer':
        final c = _answers[s.sid];
        if (c != null && !c.isCompleted) c.complete(s);
      case 'offer':
        final rv = _rv, mux = _mux;
        if (rv == null || mux == null) return;
        _log('offer from ${s.from}: answering and punching');
        final cands = await _candidates();
        rv.send(
          Signal(
            from: selfId,
            to: s.from,
            sid: s.sid,
            type: 'answer',
            candidates: cands,
          ),
        );
        final (connId, key) = _linkKeys(s.sid);
        try {
          final link = await mux.punch(
            connId: connId,
            key: key,
            candidates: _parse(s.candidates),
          );
          if (!_stopped) onIncoming(link);
        } on TimeoutException {
          _log("couldn't punch through to ${s.from} (strict NAT?)");
        }
    }
  }

  /// The device moved to another network: its public address changed.
  void networkChanged() {
    _stunCache = null;
    unawaited(_stun());
    announce();
  }

  /// For "Check network": relays, NAT type and public address (fresh).
  Future<NetworkCheck> check() async {
    final (r, nat) = await _stun(fresh: true);
    return NetworkCheck(
      relays: relaysConnected,
      relaysTotal: relays.length,
      nat: nat,
      publicAddress: r?.toString(),
    );
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _refresh?.cancel();
    final rv = _rv;
    if (rv != null) {
      // Tell the others we're gone, so they don't wait for the timeout.
      final p = presence();
      rv.announce(
        Presence(
          id: p.id,
          name: p.name,
          platform: p.platform,
          version: p.version,
          at: DateTime.now(),
          gone: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await rv.dispose();
    }
    _mux?.close();
    _log('internet mode off');
  }
}
