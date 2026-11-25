/// A minimal Nostr client (NIP-01) used only as a public meeting place:
/// intercoms publish small encrypted events and subscribe to each other's.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../debug_log.dart';
import 'schnorr.dart';

/// Public relays, run by different people: one being down doesn't matter.
const List<String> defaultRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://nostr.mom',
  'wss://relay.nostr.band',
];

class NostrEvent {
  NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  final String id, pubkey, content, sig;
  final int createdAt, kind;
  final List<List<String>> tags;

  static String computeId(
    String pubkey,
    int createdAt,
    int kind,
    List<List<String>> tags,
    String content,
  ) => toHex(
    sha256(
      utf8.encode(jsonEncode([0, pubkey, createdAt, kind, tags, content])),
    ),
  );

  factory NostrEvent.sign({
    required Uint8List secret,
    required int kind,
    required List<List<String>> tags,
    required String content,
    int? createdAt,
  }) {
    final pubkey = toHex(schnorrPublicKey(secret));
    final at = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = computeId(pubkey, at, kind, tags, content);
    final rng = Random.secure();
    final aux = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    final sig = toHex(schnorrSign(fromHex(id), secret, aux));
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: at,
      kind: kind,
      tags: tags,
      content: content,
      sig: sig,
    );
  }

  static NostrEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return NostrEvent(
        id: j['id'] as String,
        pubkey: j['pubkey'] as String,
        createdAt: j['created_at'] as int,
        kind: j['kind'] as int,
        tags: [
          for (final t in j['tags'] as List)
            [for (final v in t as List) v as String],
        ],
        content: j['content'] as String,
        sig: j['sig'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  /// The id matches the content and the signature is the author's.
  bool get valid {
    try {
      if (computeId(pubkey, createdAt, kind, tags, content) != id) return false;
      return schnorrVerify(fromHex(id), fromHex(pubkey), fromHex(sig));
    } catch (_) {
      return false;
    }
  }
}

/// Connects to several relays at once, keeps one subscription open on each,
/// and publishes every event to all of them.
class NostrClient {
  NostrClient({
    List<String> relays = defaultRelays,
    this.pingInterval = const Duration(seconds: 120),
  }) : relays = List.unmodifiable(relays);

  final List<String> relays;
  final Duration pingInterval;

  final Map<String, _Relay> _conns = {};
  Map<String, Object>? _filter;
  final StreamController<NostrEvent> _events =
      StreamController<NostrEvent>.broadcast();
  final StreamController<void> _status = StreamController<void>.broadcast();
  final List<String> _seen = [];
  final Set<String> _seenSet = {};
  bool _stopped = true;

  /// Verified events matching the subscription, each once.
  Stream<NostrEvent> get events => _events.stream;

  /// Fires when a relay connects or drops.
  Stream<void> get statusChanged => _status.stream;

  /// Called after a relay (re)connects, e.g. to publish presence again.
  void Function()? onConnected;

  int get connectedCount => _conns.values.where((r) => r.connected).length;

  void start(Map<String, Object> filter) {
    _filter = filter;
    _stopped = false;
    for (final url in relays) {
      (_conns[url] ??= _Relay(this, url)).connect();
    }
  }

  Future<void> stop() async {
    _stopped = true;
    for (final r in _conns.values) {
      await r.close();
    }
    _conns.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _status.close();
  }

  /// Sends [e] to every connected relay. Returns how many it went to.
  int publish(NostrEvent e) {
    var n = 0;
    final msg = jsonEncode(['EVENT', e.toJson()]);
    for (final r in _conns.values) {
      if (r.send(msg)) n++;
    }
    return n;
  }

  void _received(String url, String text) {
    final Object? m;
    try {
      m = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (m is! List || m.isEmpty) return;
    switch (m[0]) {
      case 'EVENT' when m.length >= 3:
        final e = NostrEvent.fromJson(m[2]);
        if (e == null || _seenSet.contains(e.id) || !e.valid) return;
        _seenSet.add(e.id);
        _seen.add(e.id);
        if (_seen.length > 2000) _seenSet.remove(_seen.removeAt(0));
        if (!_events.isClosed) _events.add(e);
      case 'NOTICE' when m.length >= 2:
        debugLog('net', 'relay $url: ${m[1]}');
      case 'OK' when m.length >= 4 && m[2] == false:
        debugLog('net', 'relay $url refused an event: ${m[3]}');
      case 'CLOSED' when m.length >= 3:
        debugLog('net', 'relay $url closed the subscription: ${m[2]}');
    }
  }
}

class _Relay {
  _Relay(this.client, this.url);
  final NostrClient client;
  final String url;
  WebSocket? _ws;
  bool _connecting = false;
  bool _closed = false;
  Timer? _retry;
  Duration _backoff = const Duration(seconds: 2);

  bool get connected => _ws != null;

  Future<void> connect() async {
    if (_connecting || _ws != null || _closed) return;
    _connecting = true;
    try {
      final ws = await WebSocket.connect(
        url,
      ).timeout(const Duration(seconds: 10));
      if (_closed || client._stopped) {
        await ws.close();
        return;
      }
      ws.pingInterval = client.pingInterval;
      _ws = ws;
      _backoff = const Duration(seconds: 2);
      debugLog('net', 'relay $url connected');
      final f = client._filter;
      if (f != null) ws.add(jsonEncode(['REQ', 'gundil', f]));
      ws.listen(
        (d) {
          if (d is String) client._received(url, d);
        },
        onDone: _lost,
        onError: (Object _) => _lost(),
        cancelOnError: true,
      );
      if (!client._status.isClosed) client._status.add(null);
      client.onConnected?.call();
    } catch (e) {
      debugLog('net', 'relay $url: could not connect: $e');
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _lost() {
    if (_ws == null) return;
    _ws = null;
    if (!client._status.isClosed) client._status.add(null);
    if (!_closed) {
      debugLog('net', 'relay $url disconnected');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_closed || client._stopped) return;
    _retry?.cancel();
    _retry = Timer(_backoff, connect);
    _backoff *= 2;
    if (_backoff > const Duration(minutes: 5)) {
      _backoff = const Duration(minutes: 5);
    }
  }

  bool send(String msg) {
    final ws = _ws;
    if (ws == null) return false;
    try {
      ws.add(msg);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
