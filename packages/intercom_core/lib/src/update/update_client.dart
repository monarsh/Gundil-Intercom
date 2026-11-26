/// Self-update: asks the update server (gundil-update-server, reached
/// through Nostr relays, STUN and UDP hole punching, see
/// gateway/update_proto.go) which version this device should run, and
/// downloads the file from the server or, when that fails, from GitHub.
/// Every file is checked against the SHA-256 the server sent over the
/// encrypted link.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show SHA256Digest;

import '../debug_log.dart';
import '../internet/nostr.dart';
import '../internet/schnorr.dart' show toHex;
import '../internet/stun.dart';
import '../internet/udp_link.dart';
import '../peer_connection.dart';
import '../protocol.dart';
import '../secure_channel.dart';

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The update server's public key, written as a server code
/// (`GUNDIL-UPDATE-` + base64url(key + 3 check bytes)).
class UpdateServerCode {
  UpdateServerCode._(this.publicKey);
  final Uint8List publicKey;

  static const String prefix = 'GUNDIL-UPDATE-';

  /// Throws [FormatException] with a message for people.
  static UpdateServerCode parse(String text) {
    final s = text.trim();
    if (!s.toUpperCase().startsWith(prefix)) {
      throw const FormatException(
        'Not an update server code (it starts with GUNDIL-UPDATE-)',
      );
    }
    Uint8List b;
    try {
      b = base64Url.decode(base64Url.normalize(s.substring(prefix.length)));
    } catch (_) {
      throw const FormatException('The update server code is incomplete');
    }
    if (b.length != 35) {
      throw const FormatException('The update server code is incomplete');
    }
    final pub = Uint8List.sublistView(b, 0, 32);
    final sum = SHA256Digest().process(pub);
    if (sum[0] != b[32] || sum[1] != b[33] || sum[2] != b[34]) {
      throw const FormatException('The update server code has a typo');
    }
    return UpdateServerCode._(Uint8List.fromList(pub));
  }

  static UpdateServerCode? tryParse(String text) {
    try {
      return parse(text);
    } on FormatException {
      return null;
    }
  }

  String get text {
    final sum = SHA256Digest().process(publicKey);
    return prefix +
        base64Url
            .encode([...publicKey, ...sum.sublist(0, 3)])
            .replaceAll('=', '');
  }

  /// Where the server listens on the relays.
  String get topic => toHex(
    hkdf(
      publicKey,
      Uint8List(0),
      Uint8List.fromList(utf8.encode('gundil/v1/update/topic')),
      16,
    ),
  );
}

/// What this installed copy is, for the server.
class UpdateIdentity {
  const UpdateIdentity({
    required this.id,
    required this.name,
    required this.package,
    required this.version,
    required this.os,
  });
  final String id, name;

  /// e.g. `android-arm64-v8a`, `windows-x64-setup`, `appimage-x86_64`
  /// (gateway/update_proto.go lists them).
  final String package;
  final String version, os;
}

/// The server's answer to a check-in.
class UpdateOffer {
  UpdateOffer({
    required this.mode,
    this.version,
    this.file,
    this.size = 0,
    this.sha256,
    this.url,
    this.local = false,
    this.downgrade = false,
    this.message,
  });

  /// "off", "ask" or "auto".
  final String mode;
  final String? version, file, sha256, url, message;
  final int size;

  /// A copy is on the server (otherwise only [url], on GitHub).
  final bool local;
  final bool downgrade;

  bool get hasUpdate => version != null && file != null && sha256 != null;

  static UpdateOffer fromJson(Map<String, Object?> m) {
    final t = m['target'];
    final mode = (m['mode'] as String?) ?? 'off';
    if (t is! Map) {
      return UpdateOffer(mode: mode, message: m['message'] as String?);
    }
    return UpdateOffer(
      mode: mode,
      version: t['version'] as String?,
      file: t['file'] as String?,
      size: (t['size'] as num?)?.toInt() ?? 0,
      sha256: (t['sha256'] as String?)?.toLowerCase(),
      url: t['url'] as String?,
      local: t['local'] == true,
      downgrade: t['downgrade'] == true,
      message: m['message'] as String?,
    );
  }
}

class UpdateClient {
  UpdateClient({
    required this.server,
    required this.identity,
    this.relays = defaultRelays,
    this.stunServers = defaultStunServers,
    this.githubFallback = true,
  });

  final UpdateServerCode server;
  final UpdateIdentity identity;
  final List<String> relays;
  final List<(String, int)> stunServers;

  /// Download from GitHub when the server can't send the file.
  final bool githubFallback;

  /// How long to wait for the server's answer on the relays.
  static Duration answerTimeout = const Duration(seconds: 20);

  /// A download from the server that gets nothing for this long moves to
  /// GitHub.
  static Duration stallTimeout = const Duration(seconds: 30);

  void _log(String m) => debugLog('update', m);

  /// Asks the server what to run.
  Future<UpdateOffer> check() async {
    final s = await _Session.open(this);
    try {
      return s.offer;
    } finally {
      s.close();
    }
  }

  /// Downloads [offer]'s file into [dir] (resuming a partial one), from the
  /// server when it keeps a copy, otherwise (or when that fails) from
  /// GitHub. Returns the checked file.
  Future<File> download(
    UpdateOffer offer,
    Directory dir, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!offer.hasUpdate) throw UpdateException('nothing to download');
    await dir.create(recursive: true);
    final name = offer.file!.split(RegExp(r'[\\/]')).last;
    final done = File('${dir.path}/$name');
    if (await done.exists() &&
        await done.length() == offer.size &&
        await _sha256OfFile(done) == offer.sha256) {
      return done;
    }
    final part = File('${done.path}.part');
    Object? serverError;
    if (offer.local) {
      try {
        await _fromServer(offer, part, onProgress);
      } catch (e) {
        serverError = e;
        _log('from the server: $e');
      }
    }
    if (!offer.local || serverError != null) {
      if (!githubFallback || offer.url == null || offer.url!.isEmpty) {
        throw UpdateException(
          serverError?.toString() ?? 'the file is not available',
        );
      }
      await _fromUrl(offer, part, onProgress);
    }
    if (await _sha256OfFile(part) != offer.sha256) {
      await part.delete();
      throw UpdateException('the downloaded file is damaged (SHA-256)');
    }
    if (await done.exists()) await done.delete();
    return part.rename(done.path);
  }

  Future<void> _fromServer(
    UpdateOffer offer,
    File part,
    void Function(int, int)? onProgress,
  ) async {
    var offset = await part.exists() ? await part.length() : 0;
    if (offset > offer.size) {
      await part.delete();
      offset = 0;
    }
    final s = await _Session.open(this);
    final raf = await part.open(mode: FileMode.append);
    try {
      _log('downloading ${offer.file} from the server (from $offset)');
      s.conn.send(
        Frame.json(MessageType.updGet, {'file': offer.file, 'offset': offset}),
      );
      var pos = offset;
      final end = Completer<void>();
      Timer? stall;
      void armStall() {
        stall?.cancel();
        stall = Timer(stallTimeout, () {
          if (!end.isCompleted) {
            end.completeError(UpdateException('the server stopped sending'));
          }
        });
      }

      armStall();
      final sub = s.frames.listen((f) async {
        if (f.type == MessageType.updData && f.payload.length >= 8) {
          final at = ByteData.sublistView(f.payload, 0, 8).getUint64(0);
          if (at != pos) {
            if (!end.isCompleted) {
              end.completeError(UpdateException('out of order data'));
            }
            return;
          }
          final bytes = Uint8List.sublistView(f.payload, 8);
          raf.writeFromSync(bytes);
          pos += bytes.length;
          onProgress?.call(pos, offer.size);
          armStall();
        } else if (f.type == MessageType.updEnd) {
          final m = f.json;
          if (end.isCompleted) return;
          if (m['ok'] == true) {
            end.complete();
          } else {
            end.completeError(
              UpdateException((m['error'] as String?) ?? 'refused'),
            );
          }
        }
      });
      unawaited(
        s.conn.done.then((_) {
          if (!end.isCompleted) {
            end.completeError(UpdateException('the link to the server broke'));
          }
        }),
      );
      try {
        await end.future;
      } finally {
        stall?.cancel();
        await sub.cancel();
      }
      if (pos != offer.size) throw UpdateException('incomplete download');
    } finally {
      await raf.close();
      s.close();
    }
  }

  Future<void> _fromUrl(
    UpdateOffer offer,
    File part,
    void Function(int, int)? onProgress,
  ) async {
    _log('downloading ${offer.file} from GitHub');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      var offset = await part.exists() ? await part.length() : 0;
      final req = await client.getUrl(Uri.parse(offer.url!));
      req.headers.set('User-Agent', 'gundil-intercom');
      if (offset > 0 && offset < offer.size) {
        req.headers.set('Range', 'bytes=$offset-');
      }
      final resp = await req.close();
      if (resp.statusCode == 200) {
        offset = 0; // Whole file.
      } else if (resp.statusCode != 206) {
        throw UpdateException('download failed (HTTP ${resp.statusCode})');
      }
      final sink = part.openWrite(
        mode: offset == 0 ? FileMode.write : FileMode.append,
      );
      var pos = offset;
      try {
        await for (final chunk in resp.timeout(stallTimeout)) {
          sink.add(chunk);
          pos += chunk.length;
          onProgress?.call(pos, offer.size);
        }
      } on TimeoutException {
        throw UpdateException('the download stopped');
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }
}

Future<String> _sha256OfFile(File f) async {
  final d = SHA256Digest();
  await for (final chunk in f.openRead()) {
    final b = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    d.update(b, 0, b.length);
  }
  final out = Uint8List(32);
  d.doFinal(out, 0);
  return toHex(out);
}

/// One encrypted link to the server, after the check-in.
class _Session {
  _Session._(this.conn, this.frames, this.offer, this._mux);

  final PeerConnection conn;
  final Stream<Frame> frames;
  final UpdateOffer offer;
  final UdpMux _mux;

  static Future<_Session> open(UpdateClient c) async {
    final rng = Random.secure();
    final eph = KeyPair.generate();
    final serverPub = c.server.publicKey;
    final shared = x25519(eph.privateKey, serverPub);
    final root = hkdf(
      shared,
      Uint8List.fromList(utf8.encode('gundil-update/v1')),
      Uint8List.fromList([...eph.publicKey, ...serverPub]),
      32,
    );
    Uint8List derive(String info) =>
        hkdf(root, Uint8List(0), Uint8List.fromList(utf8.encode(info)), 32);
    final contentKey = derive('gundil/v1/update/content');
    final linkSecret = derive('gundil/v1/update/link');
    final topic = c.server.topic;
    final sid = toHex(List.generate(8, (_) => rng.nextInt(256)));
    final nostrKey = Uint8List.fromList(
      List.generate(32, (_) => rng.nextInt(256)),
    );

    final mux = await UdpMux.bind();
    final nostr = NostrClient(relays: c.relays);
    final answer = Completer<List<String>>();
    final sub = nostr.events.listen((e) {
      if (e.kind != 21078 || e.content.startsWith('{')) return;
      try {
        final plain = openMessage(contentKey, base64.decode(e.content));
        final m = jsonDecode(utf8.decode(plain));
        if (m is Map && m['sid'] == sid && m['type'] == 'answer') {
          final cands = m['c'];
          if (!answer.isCompleted) {
            answer.complete([
              if (cands is List)
                for (final x in cands.take(8))
                  if (x is String) x,
            ]);
          }
        }
      } catch (_) {
        // Someone else's answer.
      }
    });
    var ok = false;
    try {
      nostr.start({
        'kinds': [21078],
        '#t': [topic],
        'since': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
      });
      final (pub, _) = await mux.stun.check(
        servers: c.stunServers,
        localAddresses: await _localIPv4(),
      );
      final cands = [
        if (pub != null) pub.toString(),
        for (final a in await _localIPv4()) '$a:${mux.port}',
      ];
      // Wait for a relay before sending the offer.
      final until = DateTime.now().add(const Duration(seconds: 10));
      while (nostr.connectedCount == 0 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (nostr.connectedCount == 0) {
        throw UpdateException('no relay connected (no internet?)');
      }
      final box = sealMessage(
        contentKey,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'sid': sid,
              'c': cands,
              'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            }),
          ),
        ),
      );
      final sent = nostr.publish(
        NostrEvent.sign(
          secret: nostrKey,
          kind: 21078,
          tags: [
            ['t', topic],
          ],
          content: jsonEncode({
            'e': base64.encode(eph.publicKey),
            'm': base64.encode(box),
          }),
        ),
      );
      debugLog('update', 'offer to the update server via $sent relays');
      final List<String> theirs;
      try {
        theirs = await answer.future.timeout(UpdateClient.answerTimeout);
      } on TimeoutException {
        throw UpdateException("the update server didn't answer (offline?)");
      }
      final k = hkdf(
        contentKey,
        Uint8List(0),
        Uint8List.fromList(utf8.encode('gundil/v1/punch/$sid')),
        36,
      );
      final UdpTransport link;
      try {
        link = await mux.punch(
          connId: ByteData.sublistView(k, 32, 36).getUint32(0),
          key: Uint8List.sublistView(k, 0, 32),
          candidates: _parse(theirs),
        );
      } on TimeoutException {
        throw UpdateException(
          "can't reach the update server directly (strict NAT)",
        );
      }
      final conn = PeerConnection.over(
        link,
        outgoing: true,
        secret: linkSecret,
      );
      final frames = conn.frames.asBroadcastStream();
      final info = Completer<UpdateOffer>();
      final isub = frames.listen((f) {
        if (f.type == MessageType.updInfo && !info.isCompleted) {
          info.complete(UpdateOffer.fromJson(f.json));
        }
      });
      unawaited(
        conn.done.then((_) {
          if (!info.isCompleted) {
            info.completeError(
              UpdateException('the update server closed the link'),
            );
          }
        }),
      );
      final id = c.identity;
      conn.send(
        Frame.json(MessageType.updCheck, {
          'id': id.id,
          'name': id.name,
          'package': id.package,
          'version': id.version,
          'os': id.os,
        }),
      );
      final UpdateOffer offer;
      try {
        offer = await info.future.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        unawaited(conn.close());
        throw UpdateException('no answer on the link (wrong server key?)');
      } finally {
        await isub.cancel();
      }
      ok = true;
      await sub.cancel();
      // The relays are no longer needed once the link is up.
      unawaited(nostr.dispose());
      return _Session._(conn, frames, offer, mux);
    } finally {
      if (!ok) {
        await sub.cancel();
        unawaited(nostr.dispose());
        mux.close();
      }
    }
  }

  void close() {
    unawaited(conn.close());
    // Give the close a moment to leave before the socket goes.
    Timer(const Duration(milliseconds: 300), _mux.close);
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

  static List<(InternetAddress, int)> _parse(List<String> cands) => [
    for (final c in cands)
      if (c.lastIndexOf(':') case final i when i > 0)
        if (InternetAddress.tryParse(c.substring(0, i)) case final a?)
          if (int.tryParse(c.substring(i + 1)) case final p?)
            if (a.type == InternetAddressType.IPv4 && p > 0 && p < 65536)
              (a, p),
  ];
}
