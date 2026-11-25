/// The home key: a random 256-bit key that lets intercoms without an
/// intercom password use Internet calls. One device makes it; the others
/// get it by pairing (approved over the LAN, or a pairing code / QR).
///
/// It replaces the password for the relay topic, the relay encryption and
/// the internet links' network secret. No scrypt is needed: it's random.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../secure_channel.dart';
import 'schnorr.dart' show toHex, fromHex;

class HomeKey {
  HomeKey._(this.bytes);

  /// The 32 secret bytes.
  final Uint8List bytes;

  /// Starts every pairing code.
  static const String prefix = 'GUNDIL-PAIR-';

  static final Uint8List _salt = Uint8List.fromList(
    utf8.encode('gundil-intercom/v1/home-key'),
  );

  /// A new random key.
  factory HomeKey.generate() => HomeKey._(randomBytes(32));

  /// From 64 hex digits (settings); null if it isn't one.
  static HomeKey? tryHex(String hex) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) return null;
    return HomeKey._(fromHex(hex.toLowerCase()));
  }

  /// From a pairing code (or 64 hex digits). Throws [FormatException] with a
  /// message for the user.
  static HomeKey parse(String text) {
    final t = text.replaceAll(RegExp(r'\s'), '');
    final hex = tryHex(t);
    if (hex != null) return hex;
    if (!t.toUpperCase().startsWith(prefix)) {
      throw const FormatException(
        'Not a Gundil pairing code (it starts with $prefix)',
      );
    }
    final Uint8List raw;
    try {
      raw = base64Url.decode(base64Url.normalize(t.substring(prefix.length)));
    } catch (_) {
      throw const FormatException('The pairing code is damaged');
    }
    if (raw.length != 35) {
      throw const FormatException('The pairing code is incomplete');
    }
    final key = Uint8List.fromList(raw.sublist(0, 32));
    final sum = _sha256(key);
    if (sum[0] != raw[32] || sum[1] != raw[33] || sum[2] != raw[34]) {
      throw const FormatException(
        'The pairing code has a typo (its check digits don\'t match)',
      );
    }
    return HomeKey._(key);
  }

  String get hex => toHex(bytes);

  /// What one device shows and the other scans or pastes.
  String get pairingText {
    final sum = _sha256(bytes);
    final raw = Uint8List.fromList([...bytes, sum[0], sum[1], sum[2]]);
    return prefix + base64Url.encode(raw).replaceAll('=', '');
  }

  /// A few characters to compare between devices ("7F3A-91C2"); reveals
  /// nothing useful about the key.
  String get fingerprint {
    final h = toHex(
      hkdf(
        bytes,
        _salt,
        Uint8List.fromList(utf8.encode('gundil/v1/fingerprint')),
        4,
      ),
    ).toUpperCase();
    return '${h.substring(0, 4)}-${h.substring(4)}';
  }

  /// Root of the relay topic and content key (see `RendezvousKeys`).
  Uint8List get rendezvousRoot => hkdf(
    bytes,
    _salt,
    Uint8List.fromList(utf8.encode('gundil/v1/internet')),
    32,
  );

  /// The network secret mixed into internet links' key exchange (in place
  /// of the password's).
  Uint8List get linkSecret =>
      hkdf(bytes, _salt, Uint8List.fromList(utf8.encode('gundil/v1/link')), 32);

  @override
  bool operator ==(Object other) => other is HomeKey && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  static Uint8List _sha256(Uint8List data) => SHA256Digest().process(data);
}
