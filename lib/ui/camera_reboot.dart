import 'package:flutter/material.dart';

import '../src/intercom_service.dart';

/// Asks to confirm, then asks [cam] to restart, showing how it went in a
/// snack bar. Returns whether the camera accepted.
Future<bool> confirmRebootCamera(
  BuildContext context,
  IntercomService service,
  SavedCamera cam,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Reboot ${cam.name}?'),
      content: const Text(
        'The camera restarts and is offline for about a minute. A call '
        'with it ends, and the picture comes back when it\'s up again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Reboot'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  final error = Theme.of(context).colorScheme.error;
  void snack(String msg, {bool failed = false}) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: failed ? error : null),
    );
  snack('Asking ${cam.name} to restart…');
  try {
    snack(await service.rebootCamera(cam.peerId));
    return true;
  } on CameraException catch (err) {
    snack(err.message, failed: true);
    return false;
  }
}
