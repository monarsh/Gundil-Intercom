import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart';

import '../src/intercom_service.dart';

/// The QR scanner works on phones (Android, iPhone).
bool get canScanQr => Platform.isAndroid || Platform.isIOS;

/// Settings → Internet calls → Pairing: the home key, which lets intercoms
/// without a password use Internet calls.
Future<void> showPairingDialog(BuildContext context, IntercomService service) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => _PairingDialog(service: service),
    );

class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.service});
  final IntercomService service;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  IntercomService get service => widget.service;
  bool _showCode = false;
  String? _message;
  bool _error = false;

  void _say(String m, {bool error = false}) => setState(() {
    _message = m;
    _error = error;
  });

  Future<void> _useKey(HomeKey key) async {
    await service.setHomeKey(key);
    _say('Paired. Home key ${key.fingerprint}');
  }

  Future<void> _paste() async {
    final ctl = TextEditingController();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text?.trim().toUpperCase().startsWith(HomeKey.prefix) ?? false) {
      ctl.text = clip!.text!.trim();
    }
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste pairing code'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 3,
          minLines: 2,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            hintText: '${HomeKey.prefix}…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (text == null || text.trim().isEmpty) return;
    try {
      await _useKey(HomeKey.parse(text));
    } on FormatException catch (e) {
      _say(e.message, error: true);
    }
  }

  Future<void> _scan() async {
    final text = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    if (text == null) return;
    try {
      await _useKey(HomeKey.parse(text));
    } on FormatException catch (e) {
      _say(e.message, error: true);
    }
  }

  Future<void> _ask() async {
    final peers = service.pairablePeers;
    if (peers.isEmpty) {
      _say(
        'No intercom is connected on this Wi-Fi. Open the app on a paired '
        'intercom at home, on the same Wi-Fi, and try again.',
        error: true,
      );
      return;
    }
    final peer = peers.length == 1
        ? peers.single
        : await showDialog<Peer>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('Ask which intercom?'),
              children: [
                for (final p in peers)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, p),
                    child: Text(service.displayName(p.id)),
                  ),
              ],
            ),
          );
    if (peer == null || !mounted) return;
    final name = service.displayName(peer.id);
    final code = service.securityCode(peer.id) ?? '?';
    final result = service.requestHomeKey(peer.id);
    final waiting = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Waiting for $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Text('On $name, tap Allow. Check that it shows the same code:'),
            const SizedBox(height: 8),
            Center(
              child: SelectableText(
                code,
                style: Theme.of(ctx).textTheme.headlineSmall,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    var open = true;
    unawaited(waiting.then((_) => open = false));
    try {
      final key = await result;
      _say('Paired by $name. Home key ${key.fingerprint}');
    } on StateError catch (e) {
      _say(e.message, error: true);
    }
    if (open && mounted) Navigator.of(context).pop();
  }

  Future<void> _newKey({required bool replace}) async {
    if (replace) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Make a new home key?'),
          content: const Text(
            'Every device paired with the old key, including a lost phone, '
            'can no longer reach your intercoms over the internet. Then '
            'pair your own devices and the gateway again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('New home key'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final key = await service.newHomeKey();
    setState(() => _showCode = false);
    _say(
      'New home key ${key.fingerprint}. Pair the other intercoms with this '
      'one.',
    );
  }

  Future<void> _unpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair this device?'),
        content: const Text(
          'This device forgets the home key and stops Internet calls until '
          'you pair it again. Your other intercoms keep the key and keep '
          'working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await service.setHomeKey(null);
    setState(() => _showCode = false);
    _say('Unpaired. Pair again, or make a new home key.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final key = service.homeKey;
        final theme = Theme.of(context);
        return AlertDialog(
          title: const Text('Pairing'),
          scrollable: true,
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Intercoms without a password use a home key for Internet '
                  'calls. One intercom makes it; pair the others once.',
                  style: theme.textTheme.bodySmall,
                ),
                if (service.internetUsesPassword) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This intercom has a password, so Internet calls use '
                    'the password, not the home key.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    key == null ? Icons.link_off : Icons.verified_user,
                    color: key == null ? null : theme.colorScheme.primary,
                  ),
                  title: Text(key == null ? 'Not paired yet' : 'Paired'),
                  subtitle: key == null
                      ? null
                      : Text('Home key ${key.fingerprint}'),
                ),
                if (key == null) ...[
                  _action(
                    Icons.wifi,
                    'Ask an intercom on this Wi-Fi',
                    'A paired intercom at home taps Allow.',
                    _ask,
                  ),
                  if (canScanQr)
                    _action(
                      Icons.qr_code_scanner,
                      'Scan pairing QR',
                      'Shown by a paired intercom: Pairing → Show pairing '
                          'code.',
                      _scan,
                    ),
                  _action(
                    Icons.content_paste,
                    'Paste pairing code',
                    'Copied from a paired intercom (GUNDIL-PAIR-…).',
                    _paste,
                  ),
                  _action(
                    Icons.add_circle_outline,
                    'This is the first intercom',
                    'Makes a new home key.',
                    () => _newKey(replace: false),
                  ),
                ] else ...[
                  if (!_showCode)
                    _action(
                      Icons.qr_code,
                      'Show pairing code',
                      'For a phone to scan, or to copy to a PC, the node or '
                          'the gateway.',
                      () async => setState(() => _showCode = true),
                    )
                  else ...[
                    Center(child: QrView(data: key.pairingText, size: 220)),
                    const SizedBox(height: 8),
                    SelectableText(
                      key.pairingText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      'Anyone with this code can reach your intercoms and '
                      'shared cameras. Show it only to your own devices.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy pairing code'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: key.pairingText),
                            );
                            _say('Copied');
                          },
                        ),
                        TextButton(
                          onPressed: () => setState(() => _showCode = false),
                          child: const Text('Hide'),
                        ),
                      ],
                    ),
                  ],
                  _action(
                    Icons.autorenew,
                    'New home key',
                    'Locks out every other device (e.g. a lost phone).',
                    () => _newKey(replace: true),
                  ),
                  _action(
                    Icons.link_off,
                    'Unpair this device',
                    'Forgets the home key here only, to pair again or be '
                        'the first intercom. Your other devices keep working.',
                    _unpair,
                  ),
                ],
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _message!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: _error ? theme.colorScheme.error : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _action(
    IconData icon,
    String title,
    String subtitle,
    Future<void> Function() onTap,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    onTap: onTap,
  );
}

/// "Allow Phone to use Internet calls?" on a paired intercom.
Future<void> showPairRequestDialog(
  BuildContext context,
  IntercomService service,
  String peerId,
) async {
  final r = service.pairRequests.where((r) => r.peerId == peerId).firstOrNull;
  if (r == null) return;
  final allow = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.vpn_key),
      title: Text('Allow ${r.name} to use Internet calls?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${r.name} gets this intercom\'s home key: it can then call your '
            'intercoms and watch shared cameras from anywhere. Allow only '
            'your own devices.\n\nCheck that ${r.name} shows the same code:',
          ),
          const SizedBox(height: 8),
          Text(r.securityCode, style: Theme.of(ctx).textTheme.headlineSmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  service.answerPairRequest(peerId, allow ?? false);
}

/// A QR code, drawn from the `qr` package's modules.
class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 200});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(
      QrCode(
        payload: QrPayload.fromString(data),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      ),
    );
    return Container(
      color: Colors.white, // Scanners need dark on light, also in dark mode.
      padding: const EdgeInsets.all(12),
      child: CustomPaint(size: Size.square(size), painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final cell = size.width / n;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing QR')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_done) return;
              for (final b in capture.barcodes) {
                final v = b.rawValue?.trim() ?? '';
                if (v.toUpperCase().startsWith(HomeKey.prefix)) {
                  _done = true;
                  Navigator.of(context).pop(v);
                  return;
                }
              }
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'The camera is not available: ${error.errorCode.name}. '
                  'Allow the camera for Gundil Intercom, or use Paste '
                  'pairing code.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Point at the QR code on a paired intercom\n'
                '(Settings → Pairing → Show pairing code)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
