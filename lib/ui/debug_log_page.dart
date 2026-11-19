import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/app_log.dart';
import '../src/intercom_service.dart';

/// Which lines the page shows.
enum _Filter { all, cameras, video, app }

/// The debug log: what the app did with cameras, calls and the network,
/// newest at the bottom. Copy or save it to send with a problem report.
class DebugLogPage extends StatefulWidget {
  const DebugLogPage({super.key, required this.service});

  final IntercomService service;

  /// Tests: called instead of opening the save window.
  @visibleForTesting
  static Future<String?> Function(String name, List<int> bytes)? debugSave;

  static Future<void> open(BuildContext context, IntercomService service) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => DebugLogPage(service: service)),
      );

  /// The lines at the top of a copied or saved log: app, device, cameras
  /// (no passwords).
  static List<String> header(IntercomService service) => [
    'Gundil Intercom $appVersion debug log',
    'Device: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'Saved: ${DateTime.now()}',
    for (final c in service.cameras)
      'Camera "${c.name}": ${c.isTapo ? 'Tapo' : 'RTSP'} at ${c.host} '
          '(stream port ${c.port}, RTSP port ${c.rtspPort}'
          '${c.isTapo ? '' : ', path ${c.rtspPath}'}), '
          'cloud password ${c.cloudPassword.isEmpty ? 'not set' : 'set'}, '
          'camera account ${c.rtspUser.isEmpty ? 'not set' : 'set'}, '
          '${(service.peer(c.peerId)?.reachable ?? false) ? 'online' : 'offline'}',
  ];

  @override
  State<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends State<DebugLogPage> {
  _Filter _filter = _Filter.all;
  Timer? _pending;

  static const _cameraTags = {
    'tapo',
    'rtsp',
    'camera',
    'check',
    'control',
    'ptz',
  };
  static const _videoTags = {'video', 'player', 'fvp'};

  @override
  void initState() {
    super.initState();
    DebugLog.instance.addListener(_changed);
  }

  @override
  void dispose() {
    DebugLog.instance.removeListener(_changed);
    _pending?.cancel();
    super.dispose();
  }

  /// New lines can come many per second: repaint at most 4 times a second.
  void _changed() {
    _pending ??= Timer(const Duration(milliseconds: 250), () {
      _pending = null;
      if (mounted) setState(() {});
    });
  }

  bool _shows(LogEntry e) => switch (_filter) {
    _Filter.all => true,
    _Filter.cameras => _cameraTags.contains(e.tag),
    _Filter.video => _videoTags.contains(e.tag),
    _Filter.app => !_cameraTags.contains(e.tag) && !_videoTags.contains(e.tag),
  };

  String _text() =>
      DebugLog.instance.dump(header: DebugLogPage.header(widget.service));

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text()));
    if (mounted) _say('Log copied. Paste it into a message or a note.');
  }

  Future<void> _save() async {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name =
        'gundil-intercom-log-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.txt';
    final bytes = utf8.encode(_text());
    try {
      final where =
          await (DebugLogPage.debugSave?.call(name, bytes) ??
              FilePicker.saveFile(
                dialogTitle: 'Save the debug log',
                fileName: name,
                bytes: bytes,
                mimeType: 'text/plain',
              ));
      if (where != null && mounted) _say('Log saved');
    } catch (e) {
      if (mounted) _say('Could not open the save window ($e). Use Copy.');
    }
  }

  void _clear() {
    DebugLog.instance.clear();
    debugLog('app', 'log cleared');
  }

  static Color? _color(LogEntry e, ColorScheme scheme) {
    final t = e.text.toLowerCase();
    if (t.contains('error') ||
        t.contains('failed') ||
        t.contains('refused') ||
        t.contains('could not') ||
        t.contains('no new picture') ||
        t.contains('nothing received') ||
        t.contains('ended')) {
      return scheme.error;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = DebugLog.instance.entries.where(_shows).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug log'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: _copy,
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Save to a file',
            onPressed: _save,
            icon: const Icon(Icons.save_alt),
          ),
          PopupMenuButton<void Function()>(
            tooltip: 'More',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                checked: detailedLog,
                value: () => setState(() => detailedLog = !detailedLog),
                child: const Text('Detailed log'),
              ),
              PopupMenuItem(
                value: _clear,
                child: const ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Clear'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              'Do what goes wrong (call the camera, turn on its picture), '
              'then Copy or Save the log and send it. Passwords are never '
              'in it. Detailed log (⋮) adds much more: use it only while '
              'trying the problem.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                for (final f in _Filter.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(switch (f) {
                        _Filter.all => 'All',
                        _Filter.cameras => 'Cameras & sound',
                        _Filter.video => 'Picture',
                        _Filter.app => 'App & calls',
                      }),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: lines.isEmpty
                ? const Center(child: Text('Nothing logged yet'))
                : SelectionArea(
                    child: ListView.builder(
                      // Newest at the bottom, and stays there.
                      reverse: true,
                      padding: const EdgeInsets.all(8),
                      itemCount: lines.length,
                      itemBuilder: (context, i) {
                        final e = lines[lines.length - 1 - i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            e.toString(),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: _color(e, scheme),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
