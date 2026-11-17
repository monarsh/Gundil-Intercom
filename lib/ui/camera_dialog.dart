import 'package:flutter/material.dart';

import '../src/intercom_service.dart';

/// The kinds of camera the Add camera dialog offers.
enum CameraKind { tapo, rtsp }

/// Dialog to add or edit a camera: a TP-Link Tapo (listen, talk, picture)
/// or another camera that streams RTSP (picture, listen when it can). Saves
/// it through [service] and returns the saved camera (null = cancelled).
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
  late final _host = TextEditingController(
    text: widget.camera?.isTapo ?? true ? widget.camera?.host ?? '' : '',
  );
  late final _url = TextEditingController(
    text: widget.camera?.isTapo ?? true ? '' : widget.camera!.rtspUrl,
  );
  late final _cloud = TextEditingController(
    text: widget.camera?.cloudPassword ?? '',
  );
  late final _rtspUser = TextEditingController(
    text: widget.camera?.rtspUser ?? '',
  );
  late final _rtspPassword = TextEditingController(
    text: widget.camera?.rtspPassword ?? '',
  );
  late CameraKind _kind = widget.camera?.isTapo ?? true
      ? CameraKind.tapo
      : CameraKind.rtsp;
  bool _showPasswords = false;
  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  @override
  void dispose() {
    for (final c in [_name, _host, _url, _cloud, _rtspUser, _rtspPassword]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The camera as entered. Throws [ArgumentError] for a bad RTSP address.
  SavedCamera get _draft {
    if (_kind == CameraKind.tapo) {
      return SavedCamera(
        key: widget.camera?.key ?? 'draft',
        name: _name.text.trim(),
        host: _host.text.trim(),
        cloudPassword: _cloud.text,
        rtspUser: _rtspUser.text.trim(),
        rtspPassword: _rtspPassword.text,
        port: widget.camera?.port ?? 8800,
        rtspPort: widget.camera?.rtspPort ?? 554,
      );
    }
    final u = SavedCamera.parseRtspUrl(_url.text);
    // A login typed into the address counts too.
    final user = _rtspUser.text.trim().isEmpty ? u.user : _rtspUser.text.trim();
    final password = _rtspPassword.text.isEmpty
        ? u.password
        : _rtspPassword.text;
    return SavedCamera(
      key: widget.camera?.key ?? 'draft',
      name: _name.text.trim(),
      kind: SavedCamera.kindRtsp,
      host: u.host,
      rtspPort: u.port,
      rtspPath: u.path,
      rtspUser: user,
      rtspPassword: password,
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    String text;
    var ok = false;
    try {
      final cam = _draft;
      try {
        final status = await widget.service.testCamera(cam);
        ok = cam.isTapo ? status.talk : true;
        text = cam.isTapo
            ? status.summary
            : 'Works: picture and listening (no talking to this camera)';
      } on CameraException catch (e) {
        if (cam.isTapo || !e.message.contains('G.711')) rethrow;
        ok = true;
        text =
            'Works: the picture can be shown. Its sound isn\'t a kind the app '
            'can play (only G.711), so calling it isn\'t possible.';
      }
      if (cam.isTapo && !cam.hasVideo) {
        text += '\nTo see the picture, also enter the camera account.';
      }
    } on ArgumentError catch (e) {
      text = '${e.message}';
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
    try {
      final d = _draft;
      final saved = widget.service.saveCamera(
        key: widget.camera?.key,
        name: d.name,
        host: d.host,
        kind: d.kind,
        cloudPassword: d.cloudPassword,
        rtspUser: d.rtspUser,
        rtspPassword: d.rtspPassword,
        port: d.port,
        rtspPort: d.rtspPort,
        rtspPath: d.rtspPath,
      );
      Navigator.pop(context, saved);
    } on ArgumentError catch (e) {
      setState(() {
        _result = '${e.message}';
        _resultOk = false;
      });
    }
  }

  Widget _passwordToggle() => IconButton(
    tooltip: _showPasswords ? 'Hide' : 'Show',
    icon: Icon(_showPasswords ? Icons.visibility_off : Icons.visibility),
    onPressed: () => setState(() => _showPasswords = !_showPasswords),
  );

  List<Widget> _tapoFields(TextTheme text) => [
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
        suffixIcon: _passwordToggle(),
      ),
    ),
    const SizedBox(height: 16),
    Text('To see the picture', style: text.labelLarge),
    Text(
      'The "camera account" from the Tapo app (camera settings → Advanced '
      'settings → Camera account). Also lets you listen when the camera '
      'refuses the password above.',
      style: text.bodySmall,
    ),
    TextField(
      controller: _rtspUser,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'Camera account username'),
    ),
    TextField(
      controller: _rtspPassword,
      obscureText: !_showPasswords,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(labelText: 'Camera account password'),
    ),
  ];

  List<Widget> _rtspFields(TextTheme text) => [
    TextField(
      controller: _url,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'RTSP address',
        hintText: 'rtsp://192.168.1.20:554/stream1',
        helperText:
            'From the camera\'s manual or its app. The picture and the '
            'camera\'s microphone (if its sound is G.711); you can\'t talk to '
            'it.',
        helperMaxLines: 4,
      ),
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _rtspUser,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'Username (if needed)'),
    ),
    TextField(
      controller: _rtspPassword,
      obscureText: !_showPasswords,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: 'Password (if needed)',
        suffixIcon: _passwordToggle(),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.camera == null ? 'Add camera' : 'Edit camera'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.camera == null) ...[
                SegmentedButton<CameraKind>(
                  segments: const [
                    ButtonSegment(
                      value: CameraKind.tapo,
                      label: Text('TP-Link Tapo'),
                    ),
                    ButtonSegment(
                      value: CameraKind.rtsp,
                      label: Text('Other (RTSP)'),
                    ),
                  ],
                  selected: {_kind},
                  showSelectedIcon: false,
                  onSelectionChanged: (k) => setState(() {
                    _kind = k.first;
                    _result = null;
                  }),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Front door',
                ),
              ),
              ...(_kind == CameraKind.tapo
                  ? _tapoFields(text)
                  : _rtspFields(text)),
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
