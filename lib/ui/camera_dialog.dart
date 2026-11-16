import 'package:flutter/material.dart';

import '../src/intercom_service.dart';

/// Dialog to add or edit a TP-Link Tapo camera. Saves it through
/// [service] and returns the saved camera (null = cancelled).
Future<SavedCamera?> showCameraDialog(
  BuildContext context, {
  required IntercomService service,
  SavedCamera? camera,
}) => showDialog<SavedCamera>(
  context: context,
  builder: (_) => _CameraDialog(service: service, camera: camera),
);

class _CameraDialog extends StatefulWidget {
  const _CameraDialog({required this.service, this.camera});

  final IntercomService service;
  final SavedCamera? camera;

  @override
  State<_CameraDialog> createState() => _CameraDialogState();
}

class _CameraDialogState extends State<_CameraDialog> {
  late final _name = TextEditingController(text: widget.camera?.name ?? '');
  late final _host = TextEditingController(text: widget.camera?.host ?? '');
  late final _cloud = TextEditingController(
    text: widget.camera?.cloudPassword ?? '',
  );
  late final _rtspUser = TextEditingController(
    text: widget.camera?.rtspUser ?? '',
  );
  late final _rtspPassword = TextEditingController(
    text: widget.camera?.rtspPassword ?? '',
  );
  bool _showPasswords = false;
  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  @override
  void dispose() {
    for (final c in [_name, _host, _cloud, _rtspUser, _rtspPassword]) {
      c.dispose();
    }
    super.dispose();
  }

  SavedCamera get _draft => SavedCamera(
    key: widget.camera?.key ?? 'draft',
    name: _name.text.trim(),
    host: _host.text.trim(),
    cloudPassword: _cloud.text,
    rtspUser: _rtspUser.text.trim(),
    rtspPassword: _rtspPassword.text,
    port: widget.camera?.port ?? 8800,
    rtspPort: widget.camera?.rtspPort ?? 554,
  );

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    String text;
    var ok = false;
    try {
      final status = await widget.service.testCamera(_draft);
      ok = status.talk;
      text = status.summary;
    } catch (e) {
      text = 'Not working: $e';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = text;
      _resultOk = ok;
    });
  }

  void _save() {
    final d = _draft;
    try {
      final saved = widget.service.saveCamera(
        key: widget.camera?.key,
        name: d.name,
        host: d.host,
        cloudPassword: d.cloudPassword,
        rtspUser: d.rtspUser,
        rtspPassword: d.rtspPassword,
        port: d.port,
        rtspPort: d.rtspPort,
      );
      Navigator.pop(context, saved);
    } on ArgumentError catch (e) {
      setState(() {
        _result = '${e.message}';
        _resultOk = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.camera == null ? 'Add Tapo camera' : 'Edit camera'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Front door',
                ),
              ),
              TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Camera IP address',
                  hintText: '192.168.1.50',
                ),
              ),
              const SizedBox(height: 16),
              Text('To listen and talk', style: text.labelLarge),
              TextField(
                controller: _cloud,
                obscureText: !_showPasswords,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Tapo account password',
                  helperText:
                      'The password you sign in to the Tapo app with. '
                      'Kept on this device, sent only to the camera.',
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    tooltip: _showPasswords ? 'Hide' : 'Show',
                    icon: Icon(
                      _showPasswords ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPasswords = !_showPasswords),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('To listen only (optional)', style: text.labelLarge),
              Text(
                'The "camera account" from the Tapo app (Advanced settings). '
                'Used when the camera refuses the password above.',
                style: text.bodySmall,
              ),
              TextField(
                controller: _rtspUser,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Camera account username',
                ),
              ),
              TextField(
                controller: _rtspPassword,
                obscureText: !_showPasswords,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Camera account password',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check, size: 18),
                    label: Text(_testing ? 'Testing…' : 'Test'),
                  ),
                ],
              ),
              if (_result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _result!,
                    style: TextStyle(
                      color: _resultOk ? Colors.green.shade700 : scheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(widget.camera == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}
