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

  test('the filter leaves out the others, keeps loopback', () async {
    usableInterfaceNames = () async => <String>{};
    final l = await listInterfaces(includeLoopback: true);
    for (final i in l.usable) {
      expect(i.addresses.every((a) => a.isLoopback), isTrue, reason: i.name);
    }
    expect(
      l.ignored.every((i) => i.addresses.any((a) => !a.isLoopback)),
      isTrue,
    );
  });

  test("a filter that fails or can't tell uses every interface", () async {
    final all = (await listInterfaces()).usable.length;
    usableInterfaceNames = () async => null;
    expect((await listInterfaces()).usable.length, all);
    usableInterfaceNames = () async => throw StateError('no');
    expect((await listInterfaces()).usable.length, all);
  });
}
