import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'intercom_service.dart';
import 'settings.dart';

/// Self-update in the app: what this installed copy is, and how this
/// platform installs a new version (see UpdateManager in intercom_core).
class AppUpdater {
  AppUpdater._(this.manager, this.settings);

  final UpdateManager manager;
  final Settings settings;

  static const MethodChannel _phone = MethodChannel('p2p_intercom/platform');
  static const MethodChannel _window = MethodChannel('gundil/window');

  /// The server code in use: the one from Settings, else the built-in one.
  static String codeFor(Settings s) => s.updateServer.trim().isNotEmpty
      ? s.updateServer.trim()
      : builtInUpdateServer;

  static Future<AppUpdater> create(
    Settings settings,
    IntercomService service,
  ) async {
    final pkg = await _package();
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/gundil-update',
    );
    final m = UpdateManager(
      serverCode: settings.updatesEnabled ? codeFor(settings) : '',
      identity: () => UpdateIdentity(
        id: settings.deviceId,
        name: service.name,
        package: pkg,
        version: appVersion,
        os: osDescription(),
      ),
      installer: _installerFor(pkg),
      downloadDir: dir,
      isIdle: () => service.conversation == null,
    );
    return AppUpdater._(m, settings);
  }

  /// The release package this copy is (gateway/update_proto.go).
  static Future<String> _package() async {
    if (Platform.isAndroid) {
      String abi = '';
      try {
        abi = await _phone.invokeMethod<String>('supportedAbi') ?? '';
      } catch (_) {}
      return switch (abi) {
        'arm64-v8a' => 'android-arm64-v8a',
        'armeabi-v7a' => 'android-armeabi-v7a',
        'x86_64' => 'android-x86_64',
        _ => 'android-universal',
      };
    }
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) {
      final dir = File(Platform.resolvedExecutable).parent.path;
      return File('$dir\\unins000.exe').existsSync()
          ? 'windows-x64-setup'
          : 'windows-x64-portable';
    }
    final arm = cpuName() == 'aarch64';
    if (Platform.environment['APPIMAGE'] != null) {
      return arm ? 'appimage-aarch64' : 'appimage-x86_64';
    }
    return arm ? 'linux-arm64' : 'linux-x64';
  }

  static UpdateInstaller _installerFor(String pkg) => switch (pkg) {
    'ios' => _ManualInstaller(
      'Install the new .ipa with AltStore or Sideloadly, from the release '
      'page on GitHub.',
    ),
    'windows-x64-portable' => _ManualInstaller(
      'This is the portable copy: download the new portable zip from the '
      'release page on GitHub and unzip it over this one.',
    ),
    'linux-x64' || 'linux-arm64' => _ManualInstaller(
      'Download the new tar.gz (or the AppImage, which updates itself) from '
      'the release page on GitHub.',
    ),
    'macos' => _MacInstaller(),
    'windows-x64-setup' => _WindowsInstaller(),
    _ when pkg.startsWith('appimage-') => _AppImageInstaller(),
    _ => _AndroidInstaller(),
  };

  /// Applies a change of Settings → Updates.
  void settingsChanged() {
    manager.serverCode = settings.updatesEnabled ? codeFor(settings) : '';
  }
}

class _ManualInstaller extends UpdateInstaller {
  _ManualInstaller(this.hint);
  final String hint;
  @override
  bool get canInstall => false;
  @override
  String get manualHint => hint;
  @override
  Future<void> install(File file, UpdateOffer offer) async {}
}

/// Android: hands the APK to the system installer (always asks).
class _AndroidInstaller extends UpdateInstaller {
  @override
  bool get canInstall => true;
  @override
  bool get canDowngrade => false;
  @override
  String get manualHint =>
      "Android can't install an older version over a newer one. Uninstall "
      'the app first (this deletes its settings), then install the older '
      'APK by hand.';

  @override
  Future<void> install(File file, UpdateOffer offer) async {
    final r = await AppUpdater._phone.invokeMethod<String>('installApk', {
      'path': file.path,
    });
    if (r == 'permission') {
      throw UpdateException(
        'Allow Gundil Intercom to install apps (the settings page just '
        'opened), then press Install again.',
      );
    }
  }
}

/// Windows (installed copy): runs the setup silently; it closes the app,
/// installs and starts the new version. Windows asks for administrator
/// approval, as for any installation.
class _WindowsInstaller extends UpdateInstaller {
  @override
  bool get canInstall => true;

  @override
  Future<void> install(File file, UpdateOffer offer) async {
    await Process.start(file.path, [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
    ], mode: ProcessStartMode.detached);
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(0);
  }
}

/// AppImage: replaces the file and starts the new one.
class _AppImageInstaller extends UpdateInstaller {
  @override
  bool get canInstall => true;

  @override
  Future<void> install(File file, UpdateOffer offer) async {
    final target = Platform.environment['APPIMAGE']!;
    final staged = '$target.new';
    try {
      await file.copy(staged);
      await Process.run('chmod', ['755', staged]);
      await File(staged).rename(target);
    } on FileSystemException catch (e) {
      throw UpdateException(
        "Can't replace ${e.path ?? target} (${e.osError?.message ?? e.message}). "
        'Move the AppImage to a folder you can write to.',
      );
    }
    await file.delete();
    await Process.start(target, [], mode: ProcessStartMode.detached);
    exit(0);
  }
}

/// Mac: the app can't replace itself (App Sandbox), so the zip goes to
/// Downloads and is shown in Finder.
class _MacInstaller extends UpdateInstaller {
  @override
  bool get canInstall => true;
  @override
  String get manualHint =>
      'Unzip the new version from Downloads and move it to Applications.';

  @override
  Future<void> install(File file, UpdateOffer offer) async {
    final downloads = await getDownloadsDirectory();
    if (downloads == null) throw UpdateException('no Downloads folder');
    final dst = File('${downloads.path}/${file.uri.pathSegments.last}');
    await file.copy(dst.path);
    try {
      await AppUpdater._window.invokeMethod<void>('revealFile', dst.path);
    } catch (_) {}
  }
}
