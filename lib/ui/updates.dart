import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intercom_core/intercom_core.dart';

import '../src/app_updater.dart';

/// Settings → Updates: status, Check now, Install, and the update server.
Future<void> showUpdatesDialog(BuildContext context, AppUpdater u) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _UpdatesDialog(updater: u),
  );
}

/// One line for the Settings list, e.g. "Up to date (1.9.1)".
String updateSummary(AppUpdater u) {
  final m = u.manager;
  if (!u.settings.updatesEnabled) return 'Off';
  if (!m.enabled) return 'No update server set';
  final o = m.offer;
  return switch (m.state) {
    UpdateState.checking => 'Checking…',
    UpdateState.downloading => 'Downloading ${o?.version ?? ''}…',
    UpdateState.ready || UpdateState.available when o != null =>
      '${o.downgrade ? 'Version' : 'Update'} ${o.version} available',
    UpdateState.installing => 'Installing…',
    UpdateState.failed => 'Last check failed',
    UpdateState.upToDate => 'Up to date ($appVersion)',
    _ => 'This is $appVersion',
  };
}

class _UpdatesDialog extends StatefulWidget {
  const _UpdatesDialog({required this.updater});
  final AppUpdater updater;
  @override
  State<_UpdatesDialog> createState() => _UpdatesDialogState();
}

class _UpdatesDialogState extends State<_UpdatesDialog> {
  late final TextEditingController _code = TextEditingController(
    text: widget.updater.settings.updateServer,
  );
  String? _codeError;

  AppUpdater get u => widget.updater;
  UpdateManager get m => u.manager;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _saveCode() {
    final t = _code.text.trim();
    if (t.isNotEmpty) {
      try {
        UpdateServerCode.parse(t);
      } on FormatException catch (e) {
        setState(() => _codeError = e.message);
        return;
      }
    }
    setState(() => _codeError = null);
    u.settings.updateServer = t;
    u.settingsChanged();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          t.isEmpty
              ? 'Using the built-in update server'
              : 'Update server saved',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: m.changes,
      builder: (context, _) {
        final o = m.offer;
        final busy =
            m.state == UpdateState.checking ||
            m.state == UpdateState.downloading ||
            m.state == UpdateState.installing;
        final builtIn = builtInUpdateServer.isNotEmpty;
        return AlertDialog(
          title: const Text('Updates'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This is Gundil Intercom $appVersion.'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Check for updates'),
                  subtitle: const Text(
                    'Asks your update server at start and every 6 hours, '
                    'directly over the internet (no VPN needed).',
                  ),
                  value: u.settings.updatesEnabled,
                  onChanged: (v) => setState(() {
                    u.settings.updatesEnabled = v;
                    u.settingsChanged();
                  }),
                ),
                if (u.settings.updatesEnabled) ...[
                  const SizedBox(height: 8),
                  _status(context, o),
                  if (m.state == UpdateState.downloading && m.total > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: m.received / m.total),
                    Text(
                      '${(m.received / 1048576).toStringAsFixed(1)} of '
                      '${(m.total / 1048576).toStringAsFixed(1)} MB',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (m.lastCheck != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Last check: ${TimeOfDay.fromDateTime(m.lastCheck!).format(context)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Update server'),
                  subtitle: Text(
                    u.settings.updateServer.isNotEmpty
                        ? 'Your own code'
                        : builtIn
                        ? 'Built in'
                        : 'None set',
                  ),
                  children: [
                    TextField(
                      controller: _code,
                      decoration: InputDecoration(
                        labelText: 'Server code',
                        hintText: builtIn
                            ? 'Empty = the built-in server'
                            : 'GUNDIL-UPDATE-…',
                        errorText: _codeError,
                        suffixIcon: IconButton(
                          tooltip: 'Paste',
                          icon: const Icon(Icons.content_paste),
                          onPressed: () async {
                            final d = await Clipboard.getData('text/plain');
                            if (d?.text != null) _code.text = d!.text!.trim();
                          },
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _saveCode,
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            if (u.settings.updatesEnabled && m.enabled)
              TextButton(
                onPressed: busy ? null : () => m.check(),
                child: const Text('Check now'),
              ),
            if (m.installable)
              FilledButton(
                onPressed: busy ? null : () => m.installNow(),
                child: Text(
                  o!.downgrade
                      ? 'Install ${o.version}'
                      : 'Update to ${o.version}',
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _status(BuildContext context, UpdateOffer? o) {
    final style = Theme.of(context).textTheme.bodyMedium;
    if (!m.enabled) {
      return Text(
        'No update server is set. Paste the server code below (from the '
        "update server's web page, Server tab).",
        style: style,
      );
    }
    switch (m.state) {
      case UpdateState.checking:
        return const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Asking the update server…'),
          ],
        );
      case UpdateState.failed:
        return Text(
          'Problem: ${m.error}',
          style: style?.copyWith(color: Theme.of(context).colorScheme.error),
        );
      case UpdateState.upToDate:
        return Text('Up to date.', style: style);
      case UpdateState.installing:
        return Text('Installing…', style: style);
      default:
    }
    if (o == null || !o.hasUpdate) {
      return Text(
        "Not checked yet. It checks a minute after start.",
        style: style,
      );
    }
    final what = o.downgrade
        ? 'Your administrator asks to go back to version ${o.version}.'
        : 'Version ${o.version} is available.';
    final size = o.size > 0
        ? ' (${(o.size / 1048576).toStringAsFixed(1)} MB)'
        : '';
    final notInstallable = !m.installable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$what$size', style: style?.copyWith(fontWeight: FontWeight.w600)),
        if (notInstallable)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(m.installer.manualHint, style: style),
          ),
        if (o.mode == 'auto' && m.installable)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'It installs by itself when no call is on.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
