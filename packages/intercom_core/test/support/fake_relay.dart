import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A tiny Nostr relay on loopback: stores events, keeps the latest
/// addressable event per author and `d` tag, and forwards matching events
/// to open subscriptions.
class FakeRelay {
  FakeRelay._(this._server) {
    _server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _clients.add(ws);
      final subs = <String, Map<String, Object?>>{};
      ws.listen(
        (d) {
          final m = jsonDecode(d as String) as List;
          switch (m[0]) {
            case 'REQ':
              final id = m[1] as String;
              final f = (m[2] as Map).cast<String, Object?>();
              subs[id] = f;
              for (final e in _stored) {
                if (_matches(f, e)) ws.add(jsonEncode(['EVENT', id, e]));
              }
              ws.add(jsonEncode(['EOSE', id]));
            case 'EVENT':
              final e = (m[1] as Map).cast<String, Object?>();
              received.add(e);
              ws.add(jsonEncode(['OK', e['id'], true, '']));
              final kind = e['kind'] as int;
              if (kind >= 30000 && kind < 40000) {
                String d(Map<String, Object?> x) =>
                    (x['tags'] as List).cast<List>().firstWhere(
                          (t) => t[0] == 'd',
                          orElse: () => ['d', ''],
                        )[1]
                        as String;
                _stored.removeWhere(
                  (o) =>
                      o['kind'] == kind &&
                      o['pubkey'] == e['pubkey'] &&
                      d(o) == d(e),
                );
                _stored.add(e);
              } else if (kind < 20000 || kind >= 30000) {
                _stored.add(e);
              }
              for (final c in _subs.entries) {
                for (final s in c.value.entries) {
                  if (_matches(s.value, e)) {
                    c.key.add(jsonEncode(['EVENT', s.key, e]));
                  }
                }
              }
            case 'CLOSE':
              subs.remove(m[1]);
          }
        },
        onDone: () {
          _clients.remove(ws);
          _subs.remove(ws);
        },
      );
      _subs[ws] = subs;
    });
  }

  static Future<FakeRelay> start() async =>
      FakeRelay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final List<WebSocket> _clients = [];
  final Map<WebSocket, Map<String, Map<String, Object?>>> _subs = {};
  final List<Map<String, Object?>> _stored = [];
  final List<Map<String, Object?>> received = [];

  String get url => 'ws://127.0.0.1:${_server.port}';

  static bool _matches(Map<String, Object?> f, Map<String, Object?> e) {
    final kinds = f['kinds'];
    if (kinds is List && !kinds.contains(e['kind'])) return false;
    final t = f['#t'];
    if (t is List) {
      final tags = (e['tags'] as List).cast<List>();
      if (!tags.any((x) => x[0] == 't' && t.contains(x[1]))) return false;
    }
    final since = f['since'];
    if (since is int && (e['created_at'] as int) < since) return false;
    return true;
  }

  /// Drops every connection (a relay restart).
  Future<void> kick() async {
    for (final c in _clients.toList()) {
      await c.close();
    }
  }

  Future<void> close() async {
    await kick();
    await _server.close(force: true);
  }
}
