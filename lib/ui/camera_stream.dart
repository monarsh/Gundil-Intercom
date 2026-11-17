import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../src/camera_viewer.dart';
import '../src/intercom_service.dart';

/// The picture of the camera [viewer] shows, with its name, a close button
/// and (Tapo) an HD switch.
class CameraStage extends StatelessWidget {
  const CameraStage({super.key, required this.service, required this.viewer});

  final IntercomService service;
  final CameraViewer viewer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewer,
      builder: (context, _) {
        final id = viewer.showing;
        final cam = id == null ? null : service.camera(id);
        if (cam == null) return const SizedBox.shrink();
        final url = cam.videoUrl(hd: viewer.hd);
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              children: [
                Positioned.fill(
                  child: url == null
                      ? const _Message(
                          'Enter the camera account (Edit camera) to see '
                          'the picture.',
                        )
                      : CameraStream(key: ValueKey(url), url: url),
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: _Chip(icon: Icons.videocam, text: cam.name),
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (cam.isTapo && url != null)
                        TextButton(
                          onPressed: () => viewer.hd = !viewer.hd,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          child: Text(viewer.hd ? 'HD' : 'SD'),
                        ),
                      IconButton(
                        tooltip: 'Turn off camera',
                        color: Colors.white,
                        onPressed: viewer.stop,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Plays an RTSP stream (no sound: the camera is heard through a call).
/// Tries again by itself while the camera can't be reached.
class CameraStream extends StatefulWidget {
  const CameraStream({super.key, required this.url});

  final String url;

  /// Tests: shows this instead of a real player.
  @visibleForTesting
  static Widget Function(String url)? debugPlayer;

  @override
  State<CameraStream> createState() => _CameraStreamState();
}

class _CameraStreamState extends State<CameraStream> {
  VideoPlayerController? _player;
  String? _problem;
  bool _ready = false;
  Timer? _retry;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (CameraStream.debugPlayer == null) _open();
  }

  Future<void> _open() async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _player = c;
    c.addListener(() => _onChange(c));
    try {
      await c.initialize().timeout(const Duration(seconds: 15));
      if (_disposed || _player != c) return;
      await c.setVolume(0);
      await c.play();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      _failed(c, e);
    }
  }

  void _onChange(VideoPlayerController c) {
    if (_disposed || _player != c) return;
    final v = c.value;
    if (v.hasError) {
      _failed(c, v.errorDescription ?? 'stream error');
    } else if (v.isCompleted && _ready) {
      _failed(c, 'the stream ended');
    }
  }

  void _failed(VideoPlayerController c, Object error) {
    if (_disposed || _player != c) return;
    _player = null;
    unawaited(c.dispose());
    setState(() {
      _ready = false;
      _problem = _describe(error);
    });
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () {
      if (!_disposed) _open();
    });
  }

  static String _describe(Object e) {
    final s = e is TimeoutException ? 'the camera did not answer' : '$e';
    // Never show the login that's part of the address.
    return s.replaceAll(RegExp(r'rtsp://[^\s@/]*@'), 'rtsp://');
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final debug = CameraStream.debugPlayer;
    if (debug != null) return debug(widget.url);
    final c = _player;
    if (_ready && c != null && c.value.isInitialized) {
      final ratio = c.value.aspectRatio;
      return Center(
        child: AspectRatio(
          aspectRatio: ratio > 0 ? ratio : 16 / 9,
          child: VideoPlayer(c),
        ),
      );
    }
    return _Message(
      _problem == null
          ? 'Connecting to the camera…'
          : 'No picture: $_problem\nTrying again…',
      busy: _problem == null,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.busy = false});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            const CircularProgressIndicator(color: Colors.white70),
            const SizedBox(height: 12),
          ],
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white)),
        ],
      ),
    ),
  );
}
