// The release signature check, against the fixture the Go test uses
// (signed with openssl, as the release build signs).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;
import 'package:test/test.dart';

void main() {
  final v =
      jsonDecode(
            File('../../gateway/testdata/release_sig.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  final key = v['key'] as String,
      sums = v['sums'] as String,
      sig = v['sig'] as String,
      asset = v['asset'] as String,
      sha = v['sha256'] as String;

  String? check({String? k, String? s, String? g, String? a, String? h}) =>
      releaseProblem(
        key: k ?? key,
        sums: s ?? sums,
        sig: g ?? sig,
        asset: a ?? asset,
        sha256: h ?? sha,
      );

  test('a signed release file is accepted', () {
    expect(check(), isNull);
    expect(check(h: sha.toUpperCase()), isNull);
  });

  test('a build without a key does not check', () {
    expect(releaseProblem(key: '', asset: 'x', sha256: 'y'), isNull);
  });

  test('anything else is refused', () {
    final other = '0' * 64;
    final broken = base64.decode(sig)..last ^= 1;
    expect(check(s: '', g: ''), contains('not signed'));
    expect(check(h: other), contains('SHA-256'));
    expect(check(a: 'app-evil-9.9.9.tar.gz'), contains('not in the signed'));
    expect(
      check(s: sums.replaceFirst(sha, other), h: other),
      contains('not signed by'),
    );
    expect(check(g: base64.encode(broken)), contains('not signed by'));
    expect(check(k: 'AAAA'), contains('release key'));
  });

  test('UpdateClient refuses an unsigned offer before showing it', () {
    final c = UpdateClient(
      server: UpdateServerCode.parse(_dummyCode()),
      identity: const UpdateIdentity(
        id: 'x',
        name: 'x',
        package: 'linux-x86_64',
        version: '1.0.0',
        os: 'linux',
      ),
      releaseKey: key,
    );
    final good = UpdateOffer(
      mode: 'ask',
      version: '9.9.9',
      file: 'gundil-gateway-9.9.9-linux-x86_64.tar.gz',
      sha256: sha,
      asset: asset,
      sums: sums,
      sig: sig,
    );
    expect(c.problemWith(good), isNull);
    final unsigned = UpdateOffer(
      mode: 'auto',
      version: '9.9.9',
      file: 'x',
      sha256: sha,
    );
    expect(c.problemWith(unsigned), isNotNull);
  });
}

String _dummyCode() {
  // A syntactically valid server code: 32-byte key + 3 bytes of its SHA-256.
  final key = List<int>.generate(32, (i) => i + 1);
  final sum = SHA256Digest().process(Uint8List.fromList(key));
  return 'GUNDIL-UPDATE-${base64Url.encode([...key, ...sum.sublist(0, 3)]).replaceAll('=', '')}';
}
