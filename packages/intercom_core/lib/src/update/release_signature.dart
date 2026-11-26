/// Signed releases (the same check as gateway/release_sig.go).
///
/// The release build signs the release's SHA256SUMS.txt with a P-256 key
/// that only GitHub holds and attaches SHA256SUMS.txt.sig. Builds carry the
/// public half ([builtInReleaseKey], from the repository variable
/// GUNDIL_RELEASE_KEY). An update is installed only when the signature is
/// good and the file's SHA-256 is the one in the signed list, so an update
/// server (even a stolen one) can only offer files from real releases.
/// Builds without a key don't check (forks, development builds).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Base64 of the uncompressed P-256 public key (65 bytes, 04||X||Y), set at
/// build time (`--dart-define=GUNDIL_RELEASE_KEY=...`).
const String builtInReleaseKey = String.fromEnvironment('GUNDIL_RELEASE_KEY');

/// The SHA-256 of [name] in a sha256sum list (`<hex>  <name>` lines), or null.
String? sumsLookup(String sums, String name) {
  for (final line in sums.split('\n')) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length == 2) {
      final n = f[1].startsWith('*') ? f[1].substring(1) : f[1];
      if (n == name) return f[0].toLowerCase();
    }
  }
  return null;
}

/// Why an offered file must not be installed, or null when it's a file of a
/// signed release. [key] is the release key (empty: no check), [sums] the
/// release's SHA256SUMS.txt, [sig] its signature (base64 DER), [asset] the
/// file's name in the release, [sha256] what the server offers.
String? releaseProblem({
  required String key,
  String? sums,
  String? sig,
  String? asset,
  String? sha256,
}) {
  if (key.trim().isEmpty) return null;
  final ECPublicKey pub;
  try {
    pub = _publicKey(key);
  } catch (_) {
    return 'the release key is not a P-256 public key';
  }
  if (sums == null || sums.isEmpty || sig == null || sig.isEmpty) {
    return 'the release is not signed (the update server has no signature '
        'for it: add the release again there)';
  }
  if (!verifySums(pub, sums, sig)) {
    return 'the release is not signed by the Gundil release key';
  }
  final want = asset == null ? null : sumsLookup(sums, asset);
  if (want == null) return '$asset is not in the signed release';
  if (want != sha256?.toLowerCase()) {
    return '$asset is not the file of the signed release (SHA-256)';
  }
  return null;
}

ECPublicKey _publicKey(String b64) {
  final b = base64.decode(b64.trim());
  if (b.length != 65 || b[0] != 4) throw const FormatException('key');
  final domain = ECDomainParameters('prime256v1');
  return ECPublicKey(domain.curve.decodePoint(b), domain);
}

/// Checks the signature (base64 DER, as openssl writes it) of [sums].
bool verifySums(ECPublicKey pub, String sums, String sigB64) {
  try {
    final (r, s) = _derSignature(base64.decode(sigB64.trim()));
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(pub));
    return signer.verifySignature(
      Uint8List.fromList(utf8.encode(sums)),
      ECSignature(r, s),
    );
  } catch (_) {
    return false;
  }
}

/// SEQUENCE { INTEGER r, INTEGER s }.
(BigInt, BigInt) _derSignature(List<int> d) {
  var i = 0;
  int length() {
    final l = d[i++];
    if (l < 0x80) return l;
    var n = 0;
    for (var k = 0; k < (l & 0x7f); k++) {
      n = (n << 8) | d[i++];
    }
    return n;
  }

  BigInt integer() {
    if (d[i++] != 0x02) throw const FormatException('not an INTEGER');
    final l = length();
    final v = d.sublist(i, i + l);
    i += l;
    var x = BigInt.zero;
    for (final byte in v) {
      x = (x << 8) | BigInt.from(byte);
    }
    return x;
  }

  if (d[i++] != 0x30) throw const FormatException('not a SEQUENCE');
  length();
  final r = integer();
  final s = integer();
  if (i != d.length) throw const FormatException('trailing bytes');
  return (r, s);
}
