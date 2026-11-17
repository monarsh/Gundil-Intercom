import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/intercom_service.dart';

/// Saves and loads the peers and cameras lists as a backup file, e.g. to
/// move them to another phone or computer.
class BackupDialogs {
  /// Test hooks: stand in for the system's save / open file windows.
  static Future<Uri?> Function(String name, Uint8List bytes)? debugSave;
  static Future<String?> Function()? debugOpen;

  static String _fileName() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'gundil-intercom-list-${d.year}-${two(d.month)}-${two(d.day)}.json';
  }

  static void _say(BuildContext context, String text) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));

  static Future<void> export(BuildContext context, IntercomService service) {
    final peers = service.savedPeers.length, cams = service.cameras.length;
    final camPasswords = service.cameras.any(
      (c) => c.cloudPassword.isNotEmpty || c.rtspPassword.isNotEmpty,
    );
    var passwords = true;
    return showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> done(String message) async {
            Navigator.pop(ctx);
            _say(context, message);
          }

          Future<void> save() async {
            final text = service.exportContacts(passwords: passwords);
            final bytes = Uint8List.fromList(utf8.encode(text));
            try {
              final uri =
                  await (debugSave?.call(_fileName(), bytes) ??
                      FilePicker.saveFile(
                        dialogTitle: 'Save the peers and cameras list',
                        fileName: _fileName(),
                        bytes: bytes,
                        mimeType: 'application/json',
                      ));
              if (uri == null || !ctx.mounted) return;
              await done('List exported');
            } catch (e) {
              if (!ctx.mounted) return;
              _say(
                context,
                'Could not open the save window ($e). Use Copy instead.',
              );
            }
          }

          Future<void> copy() async {
            await Clipboard.setData(
              ClipboardData(text: service.exportContacts(passwords: passwords)),
            );
            if (!ctx.mounted) return;
            await done(
              'List copied. Paste it into a note or message to keep it.',
            );
          }

          return AlertDialog(
            title: const Text('Export peers and cameras'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Saves your $peers peer${peers == 1 ? '' : 's'} and '
                    '$cams camera${cams == 1 ? '' : 's'} to a file. Load it '
                    'later with "Import list", on this device or another '
                    'phone or computer.',
                  ),
                  if (camPasswords) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Include camera passwords'),
                      subtitle: Text(
                        passwords
                            ? 'Anyone with the file can see your cameras: '
                                  'keep it private.'
                            : 'You will type the passwords again after '
                                  'importing.',
                      ),
                      value: passwords,
                      onChanged: (v) => setLocal(() => passwords = v ?? true),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(onPressed: copy, child: const Text('Copy')),
              FilledButton.icon(
                onPressed: save,
                icon: const Icon(Icons.save_alt),
                label: const Text('Save file'),
              ),
            ],
          );
        },
      ),
    );
  }

  static Future<void> import(BuildContext context, IntercomService service) {
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        void load(String? text) {
          if (text == null) return;
          try {
            final result = service.importContacts(text);
            Navigator.pop(ctx);
            _say(context, result.toString());
          } on FormatException catch (e) {
            _say(context, e.message);
          }
        }

        Future<void> open() async {
          try {
            String? text;
            if (debugOpen != null) {
              text = await debugOpen!();
            } else {
              final file = await FilePicker.pickFile(
                dialogTitle: 'Open a peers and cameras list',
              );
              if (file == null) return;
              final bytes = await file.readAsBytes();
              if (bytes.length > 1 << 20) {
                text = '';
              } else {
                text = utf8.decode(bytes, allowMalformed: true);
              }
            }
            if (!ctx.mounted) return;
            load(text);
          } catch (e) {
            if (!ctx.mounted) return;
            _say(
              context,
              'Could not open the file ($e). Copy its text and use Paste.',
            );
          }
        }

        Future<void> paste() async {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          if (!ctx.mounted) return;
          final text = data?.text ?? '';
          if (text.trim().isEmpty) {
            _say(context, 'Nothing to paste: copy the list first.');
            return;
          }
          load(text);
        }

        return AlertDialog(
          title: const Text('Import peers and cameras'),
          content: const SizedBox(
            width: 380,
            child: Text(
              'Adds the peers and cameras from a file saved with "Export '
              'list". Those already here are kept as they are; nothing is '
              'removed.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(onPressed: paste, child: const Text('Paste')),
            FilledButton.icon(
              onPressed: open,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open file'),
            ),
          ],
        );
      },
    );
  }
}
