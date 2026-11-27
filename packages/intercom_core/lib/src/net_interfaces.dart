/// The network interfaces the intercom may use.
///
/// A phone also has interfaces that aren't for apps: the carrier's VoLTE /
/// IMS link (rmnet…, ccmni…) keeps an address even with Wi-Fi, mobile data
/// and VPN off. Using it would send LAN discovery to the carrier, offer it
/// to peers as a way to reach this phone, and treat its changes as a
/// network switch. The app on Android sets [usableInterfaceNames] (from
/// ConnectivityManager: networks with internet, Wi-Fi, Ethernet, VPN);
/// elsewhere every interface is used.
library;

import 'dart:io';

/// Returns the names of the interfaces apps may use, or null when it can't
/// tell (then every interface is used).
typedef InterfaceNames = Future<Set<String>?> Function();

/// Set by the app (Android); null: use every interface.
InterfaceNames? usableInterfaceNames;

/// Whether interface [name] is in [allowed]; "v4-rmnet_data0" (Android's
/// IPv4 over an IPv6-only network, 464XLAT) counts as "rmnet_data0".
bool interfaceAllowed(String name, Set<String> allowed) =>
    allowed.contains(name) ||
    (name.startsWith('v4-') && allowed.contains(name.substring(3)));

/// The IPv4 interfaces in use: [usable] ones, and the [ignored] ones (a
/// carrier link without internet), for showing them.
Future<({List<NetworkInterface> usable, List<NetworkInterface> ignored})>
listInterfaces({bool includeLoopback = false}) async {
  final all = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: includeLoopback,
  );
  Set<String>? names;
  final f = usableInterfaceNames;
  if (f != null) {
    try {
      names = await f();
    } catch (_) {
      names = null;
    }
  }
  if (names == null) return (usable: all, ignored: <NetworkInterface>[]);
  final usable = <NetworkInterface>[];
  final ignored = <NetworkInterface>[];
  for (final i in all) {
    final loop = i.addresses.every((a) => a.isLoopback);
    (loop || interfaceAllowed(i.name, names) ? usable : ignored).add(i);
  }
  return (usable: usable, ignored: ignored);
}

/// The IPv4 interfaces the intercom may use (see [listInterfaces]).
Future<List<NetworkInterface>> usableInterfaces({
  bool includeLoopback = false,
}) async => (await listInterfaces(includeLoopback: includeLoopback)).usable;
