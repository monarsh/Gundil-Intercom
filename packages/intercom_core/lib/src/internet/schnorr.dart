/// BIP-340 Schnorr signatures on secp256k1, which Nostr events need.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

final ECDomainParameters _curve = ECCurve_secp256k1();
final BigInt _n = _curve.n;
final BigInt _p = BigInt.parse(
  'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
  radix: 16,
);

Uint8List sha256(List<int> data) =>
    SHA256Digest().process(Uint8List.fromList(data));

Uint8List _tagged(String tag, List<int> msg) {
  final t = sha256(tag.codeUnits);
  return sha256([...t, ...t, ...msg]);
}

BigInt _int(List<int> b) {
  var x = BigInt.zero;
  for (final v in b) {
    x = (x << 8) | BigInt.from(v);
  }
  return x;
}

Uint8List _bytes(BigInt x) {
  final out = Uint8List(32);
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String s) => Uint8List.fromList([
  for (var i = 0; i + 1 < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

/// The x-only public key (32 bytes) of [secret].
Uint8List schnorrPublicKey(Uint8List secret) {
  final d = _int(secret);
  if (d == BigInt.zero || d >= _n) throw ArgumentError('bad secret key');
  final p = (_curve.G * d)!;
  return _bytes(p.x!.toBigInteger()!);
}

/// Signs the 32-byte [msg] with [secret], using [aux] (32 random bytes).
Uint8List schnorrSign(Uint8List msg, Uint8List secret, Uint8List aux) {
  var d = _int(secret);
  if (d == BigInt.zero || d >= _n) throw ArgumentError('bad secret key');
  final p = (_curve.G * d)!;
  if (p.y!.toBigInteger()!.isOdd) d = _n - d;
  final px = _bytes(p.x!.toBigInteger()!);
  final t = _bytes(d ^ _int(_tagged('BIP0340/aux', aux)));
  final k0 = _int(_tagged('BIP0340/nonce', [...t, ...px, ...msg])) % _n;
  if (k0 == BigInt.zero) throw StateError('bad nonce');
  final r = (_curve.G * k0)!;
  final k = r.y!.toBigInteger()!.isOdd ? _n - k0 : k0;
  final rx = _bytes(r.x!.toBigInteger()!);
  final e = _int(_tagged('BIP0340/challenge', [...rx, ...px, ...msg])) % _n;
  return Uint8List.fromList([...rx, ..._bytes((k + e * d) % _n)]);
}

/// Checks a signature from [pub] (x-only) over [msg].
bool schnorrVerify(Uint8List msg, Uint8List pub, Uint8List sig) {
  if (pub.length != 32 || sig.length != 64) return false;
  final x = _int(pub);
  if (x >= _p) return false;
  final c = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
  final y0 = c.modPow((_p + BigInt.one) >> 2, _p);
  if (y0.modPow(BigInt.two, _p) != c) return false;
  final y = y0.isEven ? y0 : _p - y0;
  final pt = _curve.curve.createPoint(x, y);
  final r = _int(sig.sublist(0, 32));
  final s = _int(sig.sublist(32));
  if (r >= _p || s >= _n) return false;
  final e =
      _int(
        _tagged('BIP0340/challenge', [...sig.sublist(0, 32), ...pub, ...msg]),
      ) %
      _n;
  final rr = ((_curve.G * s)! + (pt * (_n - e))!);
  if (rr == null || rr.isInfinity) return false;
  if (rr.y!.toBigInteger()!.isOdd) return false;
  return rr.x!.toBigInteger() == r;
}
