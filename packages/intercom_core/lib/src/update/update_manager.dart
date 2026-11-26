/// Self-update on a schedule: checks in with the update server a minute
/// after start and every 6 hours, downloads what it offers, and installs it
/// the way the platform allows ([UpdateInstaller]). Used by the Flutter app
/// and the headless node.
library;

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import '../debug_log.dart';
import '../internet/nostr.dart' show defaultRelays;
import '../internet/stun.dart' show defaultStunServers;
import 'update_client.dart';

/// How one platform installs a downloaded file.
abstract class UpdateInstaller {
  /// False where the app can't install anything itself (iPhone): the offer
  /// is only shown.
  bool get canInstall;

  /// False where an older version can't be installed over a newer one
  /// (Android).
  bool get canDowngrade => true;

  /// What to tell people instead, when [canInstall] is false or a downgrade
  /// isn't possible.
  String get manualHint => 'Install the new version by hand.';

  /// Installs [file] (checked already). May end this process (restart).
  Future<void> install(File file, UpdateOffer offer);
}

enum UpdateState {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  installing,
  failed,
}

class UpdateManager {
  UpdateManager({
    required this.serverCode,
    required this.identity,
    required this.installer,
    required this.downloadDir,
    this.isIdle,
    this.relays,
    this.stunServers,
  });

  /// The server code (built in, or from the settings); empty: off.
  String serverCode;
  final UpdateIdentity Function() identity;
  final UpdateInstaller installer;
  final Directory downloadDir;

  /// No call right now ("install automatically" waits for this).
  final bool Function()? isIdle;
  final List<String>? relays;
  final List<(String, int)>? stunServers;

  static Duration firstCheck = const Duration(minutes: 1);
  static Duration checkEvery = const Duration(hours: 6);

  UpdateState state = UpdateState.idle;
  UpdateOffer? offer;
  String? error;
  DateTime? lastCheck;
  int received = 0, total = 0;
  File? _file;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Something above changed.
  Stream<void> get changes => _changes.stream;

  Timer? _timer;
  bool _busy = false;
  bool _stopped = false;

  bool get enabled => UpdateServerCode.tryParse(serverCode) != null;

  void _set(UpdateState s, {String? err}) {
    state = s;
    error = err;
    if (!_changes.isClosed) _changes.add(null);
  }

  void _log(String m) => debugLog('update', m);

  void start() {
    _timer?.cancel();
    _timer = Timer(firstCheck, () {
      unawaited(check());
      _timer = Timer.periodic(checkEvery, (_) => unawaited(check()));
    });
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _changes.close();
  }

  UpdateClient? _client() {
    final code = UpdateServerCode.tryParse(serverCode);
    if (code == null) return null;
    return UpdateClient(
      server: code,
      identity: identity(),
      relays: relays ?? defaultRelays,
      stunServers: stunServers ?? defaultStunServers,
    );
  }

  /// Whether [offer] can be installed here (not only shown).
  bool get installable {
    final o = offer;
    if (o == null || !o.hasUpdate || !installer.canInstall) return false;
    return !o.downgrade || installer.canDowngrade;
  }

  /// Asks the server; with "install automatically" downloads and installs
  /// (when no call is on).
  Future<void> check() async {
    if (_busy || _stopped) return;
    final c = _client();
    if (c == null) return;
    _busy = true;
    _set(UpdateState.checking);
    try {
      final o = await c.check();
      lastCheck = DateTime.now();
      offer = o;
      if (!o.hasUpdate) {
        _log(
          'check-in: nothing to install'
          '${o.message != null ? ' (${o.message})' : ''}',
        );
        offer = null;
        _set(UpdateState.upToDate);
        return;
      }
      _log(
        'check-in: ${o.downgrade ? 'downgrade' : 'update'} to ${o.version} (${o.mode})',
      );
      _set(UpdateState.available);
      if (o.mode == 'auto' && installable) {
        _busy = false;
        await download(c);
        if (state == UpdateState.ready) await _installWhenIdle();
      }
    } catch (e) {
      _log('check-in failed: $e');
      lastCheck = DateTime.now();
      _set(UpdateState.failed, err: e.toString());
    } finally {
      _busy = false;
    }
  }

  /// Downloads the offered file.
  Future<void> download([UpdateClient? client]) async {
    final o = offer;
    final c = client ?? _client();
    if (_busy || o == null || c == null || !o.hasUpdate) return;
    _busy = true;
    received = 0;
    total = o.size;
    _set(UpdateState.downloading);
    try {
      _file = await c.download(
        o,
        downloadDir,
        onProgress: (n, t) {
          received = n;
          total = t;
          if (!_changes.isClosed) _changes.add(null);
        },
      );
      _log('downloaded ${o.file}');
      _set(UpdateState.ready);
    } catch (e) {
      _log('download failed: $e');
      _set(UpdateState.failed, err: e.toString());
    } finally {
      _busy = false;
    }
  }

  /// Downloads (if needed) and installs the offer now.
  Future<void> installNow() async {
    if (!installable) return;
    if (state != UpdateState.ready || _file == null) await download();
    final f = _file, o = offer;
    if (state != UpdateState.ready || f == null || o == null) return;
    _set(UpdateState.installing);
    try {
      _log('installing ${o.version}');
      await installer.install(f, o);
      // Still running: the installer handed over to the system (Android's
      // prompt, a download shown in Finder).
      _set(UpdateState.ready);
    } catch (e) {
      _log('install failed: $e');
      _set(UpdateState.failed, err: e.toString());
    }
  }

  Future<void> _installWhenIdle() async {
    while (!_stopped && !(isIdle?.call() ?? true)) {
      await Future<void>.delayed(const Duration(seconds: 30));
    }
    if (!_stopped) await installNow();
  }
}

/// The update server code built into this build
/// (`--define=GUNDIL_UPDATE_SERVER=...`, from the GitHub repository variable).
const String builtInUpdateServer = String.fromEnvironment(
  'GUNDIL_UPDATE_SERVER',
);

/// The CPU, as release files name it: "x86_64", "aarch64", "arm"…
String cpuName() => switch (Abi.current()) {
  Abi.linuxX64 || Abi.windowsX64 || Abi.macosX64 => 'x86_64',
  Abi.linuxArm64 || Abi.windowsArm64 || Abi.macosArm64 => 'aarch64',
  Abi.linuxArm => 'arm',
  _ => 'unknown',
};

/// A short OS description for the server's device list.
String osDescription() =>
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'.trim();
