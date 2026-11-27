import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => usableInterfaceNames = null);

  test('names match, and v4- (464XLAT) counts as its network', () {
    final ok = {'wlan0', 'rmnet_data0'};
    expect(interfaceAllowed('wlan0', ok), isTrue);
    expect(interfaceAllowed('v4-rmnet_data0', ok), isTrue);
    expect(interfaceAllowed('rmnet_data1', ok), isFalse); // e.g. VoLTE
    expect(interfaceAllowed('v4-rmnet_data1', ok), isFalse);
  });

  test('without a filter every interface is used', () async {
    final l = await listInterfaces(includeLoopback: true);
    expect(l.ignored, isEmpty);
    expect(l.usable, isNotEmpty);
  });

  test('only carrier interfaces are ever left out', () {
    for (final n in [
      'rmnet_data1',
      'rmnet_ims00',
      'r_rmnet_data0',
      'ccmni1',
      'seth_lte1',
      'ims0',
      'epdg1',
      'pdp_ip1',
      'ipsec0',
      'v4-rmnet_data2',
    ]) {
      expect(carrierInterface(n), isTrue, reason: n);
    }
    for (final n in [
      'wlan0',
      'en0',
      'eth0',
      'ap0',
      'swlan0',
      'tun0',
      'utun3',
      'bridge100',
      'lo',
    ]) {
      expect(carrierInterface(n), isFalse, reason: n);
    }
  });

  test(
    'an empty list from the system keeps every non-carrier interface',
    () async {
      final all = (await listInterfaces(includeLoopback: true)).usable;
      usableInterfaceNames = () async => <String>{};
      final l = await listInterfaces(includeLoopback: true);
      expect(l.usable.map((i) => i.name), [
        for (final i in all)
          if (!carrierInterface(i.name)) i.name,
      ]);
      expect(l.ignored.every((i) => carrierInterface(i.name)), isTrue);
    },
  );

  test("a filter that fails or can't tell uses every interface", () async {
    final all = (await listInterfaces()).usable.length;
    usableInterfaceNames = () async => null;
    expect((await listInterfaces()).usable.length, all);
    usableInterfaceNames = () async => throw StateError('no');
    expect((await listInterfaces()).usable.length, all);
  });
}
