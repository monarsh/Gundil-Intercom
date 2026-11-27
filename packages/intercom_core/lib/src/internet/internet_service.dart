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
import '../net_interfaces.dart';

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

  /// For tests: the UDP socket in use now.
  UdpMux? get muxForTest => _mux;
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
    _stopped = false;
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

  /// The UDP socket, made anew when the system broke the old one.
  Future<UdpMux?> _currentMux() async {
    final mux = _mux;
    if (mux == null || _stopped || !mux.dead) return mux;
    _log('UDP socket broken: making a new one');
    return _rebind();
  }

  /// A new UDP socket (after a network switch, the old one is tied to the
  /// old network). The old one stays for calls still on it, then closes.
  Future<UdpMux?> _rebind() async {
    final old = _mux;
    final UdpMux fresh;
    try {
      fresh = await UdpMux.bind();
    } catch (e) {
      _log('could not open a new UDP socket: $e');
      return old;
    }
    if (_stopped) {
      fresh.close();
      return null;
    }
    _mux = fresh;
    if (old != null) _retire(old);
    _log('new UDP socket (port ${fresh.port})');
    return fresh;
  }

  /// Closes [old] once no call uses it, after 5 minutes at the latest.
  void _retire(UdpMux old) {
    if (old.idle || old.dead) {
      old.close();
      return;
    }
    var waited = 0;
    Timer.periodic(const Duration(seconds: 15), (t) {
      waited += 15;
      if (old.idle || old.dead || waited >= 300 || _stopped) {
        t.cancel();
        old.close();
      }
    });
  }

  Future<(StunResult?, NatType)> _stun({bool fresh = false}) async {
    final c = _stunCache;
    if (!fresh && c != null && DateTime.now().difference(c.$1).inSeconds < 60) {
      return (c.$2, c.$3);
    }
    final mux = await _currentMux();
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
      final ifaces = await usableInterfaces();
      return {
        for (final i in ifaces)
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      };
    } catch (_) {
      return {};
    }
  }

  /// Our public address from STUN, then LAN addresses (same port), for
  /// [mux].
  Future<List<String>> _candidates(UdpMux mux) async {
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
    final rv = _rv, mux = await _currentMux();
    if (rv == null || mux == null) {
      throw InternetException('internet mode is off');
    }
    final who = name ?? peerId;
    final sid = toHex(List.generate(8, (_) => _rng.nextInt(256)));
    final answer = Completer<Signal>();
    _answers[sid] = answer;
    try {
      final cands = await _candidates(mux);
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
        final rv = _rv, mux = await _currentMux();
        if (rv == null || mux == null) return;
        _log('offer from ${s.from}: answering and punching');
        final cands = await _candidates(mux);
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
  ///
  /// A new UDP socket: the old one is tied to the old network (on phones
  /// switching Wi-Fi ⇄ mobile data it may stop working, and STUN then
  /// never answers until internet calls are turned off and on). STUN is
  /// asked again, and again after 3 and 10 s while the new network comes
  /// up.
  void networkChanged() {
    if (_stopped) return;
    _stunCache = null;
    unawaited(() async {
      await _rebind();
      for (final wait in const [
        Duration.zero,
        Duration(seconds: 3),
        Duration(seconds: 10),
      ]) {
        if (_stopped) return;
        await Future<void>.delayed(wait);
        final (r, _) = await _stun(fresh: true);
        if (r != null) break;
      }
      announce();
    }());
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
