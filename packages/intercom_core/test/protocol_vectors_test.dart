/// Fixed inputs and the bytes they must give. The Go gateway
/// (`gateway/`) checks the same file, so both sides stay compatible.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:intercom_core/src/internet/rendezvous.dart';
import 'package:intercom_core/src/internet/schnorr.dart';
import 'package:intercom_core/src/secure_channel.dart';
import 'package:test/test.dart';

Map<String, Object> vectors() {
  const password = 'correct horse battery';
  final secret = networkSecret(password);
  final a = KeyPair.fromPrivate(
    Uint8List.fromList(List.generate(32, (i) => i + 1)),
  );
  final b = KeyPair.fromPrivate(
    Uint8List.fromList(List.generate(32, (i) => 200 - i)),
  );
  final ka = SessionKeys.derive(a, b.publicKey, secret);
  final sealed = FrameCipher(
    ka.sendKey,
  ).seal(MessageType.hello.code, Uint8List.fromList(utf8.encode('{"id":"x"}')));
  final rv = RendezvousKeys.derive(password, n: 1024);
  final punch = hkdf(
    rv.contentKey,
    Uint8List(0),
    Uint8List.fromList(utf8.encode('gundil/v1/punch/0011223344556677')),
    36,
  );
  final home = HomeKey.tryHex(
    toHex(List.generate(32, (i) => (i * 7 + 3) & 0xff)),
  )!;
  final homeRv = RendezvousKeys.fromRoot(home.rendezvousRoot);
  return {
    'homeKeyHex': home.hex,
    'homePairing': home.pairingText,
    'homeFingerprint': home.fingerprint,
    'homeLinkSecret': toHex(home.linkSecret),
    'homeTopic': homeRv.topic,
    'homeContentKey': toHex(homeRv.contentKey),
    'password': password,
    'networkSecret': toHex(secret),
    'noPasswordSecret': toHex(networkSecret('')),
    'privA': toHex(a.privateKey),
    'pubA': toHex(a.publicKey),
    'privB': toHex(b.privateKey),
    'pubB': toHex(b.publicKey),
    'sendKeyA': toHex(ka.sendKey),
    'receiveKeyA': toHex(ka.receiveKey),
    'securityCode': ka.securityCode,
    'sealedHelloA0': toHex(sealed),
    'scryptN': 1024,
    'topic': rv.topic,
    'contentKey': toHex(rv.contentKey),
    'punchSid': '0011223344556677',
    'punchKey': toHex(punch.sublist(0, 32)),
    'punchConnId': ByteData.sublistView(punch, 32, 36).getUint32(0),
  };
}

void main() {
  test('protocol vectors match gateway/testdata/vectors.json', () {
    final file = File('../../gateway/testdata/vectors.json');
    final now = const JsonEncoder.withIndent('  ').convert(vectors());
    if (Platform.environment['UPDATE_VECTORS'] == '1' || !file.existsSync()) {
      file.writeAsStringSync('$now\n');
    }
    expect(file.readAsStringSync().trim(), now);
  });
}
