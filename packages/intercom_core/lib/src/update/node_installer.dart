/// Installs an update of the headless node: unpacks the release tarball,
/// puts the new program and audio library next to the running one, and
/// exits; systemd (Restart=always) starts the new version.
library;

import 'dart:io';

import 'update_client.dart';
import 'update_manager.dart';

class NodeInstaller extends UpdateInstaller {
  NodeInstaller(this.log, {this.exitAfter = true});

  final void Function(String) log;

  /// Tests: don't end the process.
  final bool exitAfter;

  @override
  bool get canInstall => Platform.isLinux;

  @override
  Future<void> install(File file, UpdateOffer offer) async {
    final exe = File(Platform.resolvedExecutable);
    final home = exe.parent;
    final tmp = await Directory.systemTemp.createTemp('gundil-node');
    try {
      final r = await Process.run('tar', ['xzf', file.path, '-C', tmp.path]);
      if (r.exitCode != 0) {
        throw UpdateException('could not unpack: ${r.stderr}');
      }
      final newExe = await _find(tmp, 'gundil-intercom-node');
      if (newExe == null) throw UpdateException('no program in the update');
      final newLib = await _find(tmp, 'libintercom_audio.so');
      // Rename over the running files (allowed on Linux; the old ones stay
      // in use until this process ends).
      await _replace(newExe, exe.path, executable: true);
      if (newLib != null) {
        await Directory('${home.path}/lib').create(recursive: true);
        await _replace(newLib, '${home.path}/lib/libintercom_audio.so');
      }
      log('Installed ${offer.version}; restarting');
    } finally {
      await tmp.delete(recursive: true);
    }
    await file.delete();
    if (exitAfter) exit(0);
  }

  static Future<File?> _find(Directory d, String name) async {
    await for (final e in d.list(recursive: true)) {
      if (e is File && e.uri.pathSegments.last == name) return e;
    }
    return null;
  }

  static Future<void> _replace(
    File from,
    String to, {
    bool executable = false,
  }) async {
    final staged = '$to.new';
    await from.copy(staged);
    if (executable) await Process.run('chmod', ['755', staged]);
    await File(staged).rename(to);
  }
}
