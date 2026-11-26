/// Where intercoms with the same password meet on Nostr: who is there
/// (presence) and messages to set up a direct connection (signals). Both are
/// encrypted with a key from the password; relays see only random keys, a
/// hash tag and ciphertext.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../secure_channel.dart';
import 'nostr.dart';
import 'schnorr.dart';

const int presenceKind = 30078;
const int signalKind = 21078;

/// Presence older than this means the device is gone.
const Duration presenceTimeout = Duration(minutes: 15);

/// The topic tag and the content key for a password. Slow on purpose
/// (scrypt): the topic is public, so it must be hard to guess passwords from.
class RendezvousKeys {
  RendezvousKeys._(this.topic, this.contentKey);

  final String topic;
  final Uint8List contentKey;

  static RendezvousKeys derive(String password, {int n = 1 << 15}) {
    final scrypt = Scrypt()
      ..init(
        ScryptParameters(
          n,
          8,
          1,
          32,
          Uint8List.fromList(utf8.encode('gundil-intercom/v1/internet')),
        ),
      );
    return fromRoot(scrypt.process(Uint8List.fromList(utf8.encode(password))));
  }

  /// From a 32-byte root key: the password's scrypt hash, or a home key's
  /// [HomeKey.rendezvousRoot].
  static RendezvousKeys fromRoot(Uint8List key) {
    final topic = hkdf(
      key,
      Uint8List(0),
      Uint8List.fromList(utf8.encode('gundil/v1/topic')),
      16,
    );
    final content = hkdf(
      key,
      Uint8List(0),
      Uint8List.fromList(utf8.encode('gundil/v1/content')),
      32,
    );
    return RendezvousKeys._(toHex(topic), content);
  }

  /// [derive] off the main isolate (it takes a moment).
  static Future<RendezvousKeys> deriveAsync(String password) async {
    final (t, k) = await Isolate.run(() {
      final r = derive(password);
      return (r.topic, r.contentKey);
    });
    return RendezvousKeys._(t, k);
  }
}

class Presence {
  Presence({
    required this.id,
    required this.name,
    required this.platform,
    required this.version,
    required this.at,
    this.subnets = const [],
    this.gone = false,
  });
  final String id, name, platform;

  /// The device is leaving (internet mode off, app closing).
  final bool gone;
  final int version;
  final DateTime at;

  /// LAN subnets it shares cameras on ("192.168.50.0/24"); empty: none.
  final List<String> subnets;
}

class Signal {
  Signal({
    required this.from,
    required this.to,
    required this.sid,
    required this.type,
    this.candidates = const [],
  });
  final String from, to, sid, type;

  /// "ip:port" addresses to punch to.
  final List<String> candidates;
}

class Rendezvous {
  Rendezvous({
    required this.client,
    required this.keys,
    required this.selfId,
    required this.secret,
  });

  final NostrClient client;
  final RendezvousKeys keys;
  final String selfId;

  /// This device's Nostr key (random, kept in settings).
  final Uint8List secret;

  final StreamController<Presence> _presence =
      StreamController<Presence>.broadcast();
  final StreamController<Signal> _signals =
      StreamController<Signal>.broadcast();
  StreamSubscription<NostrEvent>? _sub;

  Stream<Presence> get presence => _presence.stream;
  Stream<Signal> get signals => _signals.stream;

  void start() {
    _sub = client.events.listen(_onEvent);
    final since =
        DateTime.now().subtract(presenceTimeout).millisecondsSinceEpoch ~/ 1000;
    client.start({
      'kinds': [presenceKind, signalKind],
      '#t': [keys.topic],
      'since': since,
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await client.stop();
  }

  String _seal(Map<String, Object?> m) => base64.encode(
    sealMessage(
      keys.contentKey,
      Uint8List.fromList(utf8.encode(jsonEncode(m))),
    ),
  );

  Map<String, Object?>? _open(String content) {
    try {
      final plain = openMessage(keys.contentKey, base64.decode(content));
      final m = jsonDecode(utf8.decode(plain));
      return m is Map<String, Object?> ? m : null;
    } catch (_) {
      return null; // Another password, or garbage.
    }
  }

  /// Publishes who we are (relays keep the latest one).
  int announce(Presence p) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return client.publish(
      NostrEvent.sign(
        secret: secret,
        kind: presenceKind,
        tags: [
          ['d', 'gundil:${keys.topic}:$selfId'],
          ['t', keys.topic],
          ['expiration', '${now + presenceTimeout.inSeconds}'],
        ],
        content: _seal({
          'id': p.id,
          'name': p.name,
          'platform': p.platform,
          'v': p.version,
          'ts': now,
          if (p.subnets.isNotEmpty) 'subnets': p.subnets,
          if (p.gone) 'gone': true,
        }),
      ),
    );
  }

  int send(Signal s) => client.publish(
    NostrEvent.sign(
      secret: secret,
      kind: signalKind,
      tags: [
        ['t', keys.topic],
      ],
      content: _seal({
        'from': s.from,
        'to': s.to,
        'sid': s.sid,
        'type': s.type,
        'c': s.candidates,
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }),
    ),
  );

  void _onEvent(NostrEvent e) {
    if (!e.tags.any(
      (t) => t.length >= 2 && t[0] == 't' && t[1] == keys.topic,
    )) {
      return;
    }
    final m = _open(e.content);
    if (m == null) return;
    final ts = m['ts'];
    if (ts is! int) return;
    final at = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    if (e.kind == presenceKind) {
      final id = m['id'];
      if (id is! String || id == selfId) return;
      if (DateTime.now().difference(at) > presenceTimeout) return;
      final subnets = m['subnets'];
      _presence.add(
        Presence(
          id: id,
          name: (m['name'] as String?) ?? 'Unknown',
          platform: (m['platform'] as String?) ?? '?',
          version: (m['v'] as int?) ?? 0,
          at: at,
          gone: m['gone'] == true,
          subnets: [
            if (subnets is List)
              for (final s in subnets.take(32))
                if (s is String) s,
          ],
        ),
      );
    } else if (e.kind == signalKind) {
      final to = m['to'], from = m['from'], sid = m['sid'], type = m['type'];
      if (to != selfId ||
          from is! String ||
          sid is! String ||
          type is! String) {
        return;
      }
      // Old signals (a relay replaying) are useless for punching.
      if (DateTime.now().difference(at).abs() > const Duration(minutes: 2)) {
        return;
      }
      final c = m['c'];
      _signals.add(
        Signal(
          from: from,
          to: selfId,
          sid: sid,
          type: type,
          candidates: [
            if (c is List)
              for (final x in c.take(8))
                if (x is String) x,
          ],
        ),
      );
    }
  }

  Future<void> dispose() async {
    await stop();
    await _presence.close();
    await _signals.close();
  }
}
