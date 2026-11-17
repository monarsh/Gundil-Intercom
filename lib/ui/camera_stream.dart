import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../src/camera_viewer.dart';
import '../src/intercom_service.dart';

/// The picture of the camera [viewer] shows, with its name, zoom (buttons,
/// pinch and drag), a close button, and for a Tapo an SD/HD switch and pan &
/// tilt arrows.
class CameraStage extends StatefulWidget {
  const CameraStage({super.key, required this.service, required this.viewer});

  final IntercomService service;
  final CameraViewer viewer;

  /// Tests: called instead of moving a real camera.
  @visibleForTesting
  static Future<void> Function(SavedCamera camera, int x, int y)? debugPanTilt;

  @override
  State<CameraStage> createState() => _CameraStageState();
}

class _CameraStageState extends State<CameraStage> {
  static const double _maxZoom = 8;

  final TransformationController _zoom = TransformationController();
  String? _shownId;
  Size _size = Size.zero;

  bool _panTiltOpen = false;
  OnvifPtz? _ptz;
  String? _ptzFor;
  String? _ptzProblem;
  bool _moving = false;
  Timer? _hold;

  CameraViewer get viewer => widget.viewer;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hold?.cancel();
    _ptz?.close();
    _zoom.dispose();
    super.dispose();
  }

  /// Another camera (or none): start unzoomed, arrows closed.
  void _cameraChanged(String? id) {
    if (id == _shownId) return;
    _shownId = id;
    // Runs during build: reset quietly (no rebuild request).
    _zoom.removeListener(_rebuild);
    _zoom.value = Matrix4.identity();
    _zoom.addListener(_rebuild);
    _panTiltOpen = false;
    _ptzProblem = null;
    _hold?.cancel();
  }

  double get _scale => _zoom.value.getMaxScaleOnAxis();

  /// Zooms by [factor] around the middle of the picture.
  void _zoomBy(double factor) {
    final m = _zoom.value;
    final s = m.getMaxScaleOnAxis();
    final target = (s * factor).clamp(1.0, _maxZoom);
    if (target <= 1.001) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final k = target / s;
    final cx = _size.width / 2, cy = _size.height / 2;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(cx, cy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1)
      ..multiply(m);
  }

  // ------------------------------------------------------------ pan & tilt

  Future<void> _step(SavedCamera cam, int x, int y) async {
    if (_moving) return;
    _moving = true;
    try {
      final debug = CameraStage.debugPanTilt;
      if (debug != null) {
        await debug(cam, x, y);
      } else {
        if (_ptzFor != cam.peerId) {
          _ptz?.close();
          _ptz = OnvifPtz(
            host: cam.host,
            username: cam.rtspUser,
            password: cam.rtspPassword,
          );
          _ptzFor = cam.peerId;
        }
        await _ptz!.move(x, y);
      }
      if (_ptzProblem != null && mounted) setState(() => _ptzProblem = null);
    } catch (e) {
      _hold?.cancel();
      if (mounted) setState(() => _ptzProblem = '$e');
    } finally {
      _moving = false;
    }
  }

  /// One step on press, then more while the arrow is held.
  void _press(SavedCamera cam, int x, int y) {
    _hold?.cancel();
    _step(cam, x, y);
    _hold = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _step(cam, x, y),
    );
  }

  void _release() => _hold?.cancel();

  Widget _arrow(SavedCamera cam, IconData icon, String tip, int x, int y) =>
      Tooltip(
        message: tip,
        child: Listener(
          onPointerDown: (_) => _press(cam, x, y),
          onPointerUp: (_) => _release(),
          onPointerCancel: (_) => _release(),
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, color: Colors.white, size: 30),
            ),
          ),
        ),
      );

  Widget _pad(SavedCamera cam) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _arrow(cam, Icons.keyboard_arrow_up, 'Tilt up', 0, 1),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _arrow(cam, Icons.keyboard_arrow_left, 'Pan left', -1, 0),
          const SizedBox(width: 44, height: 44),
          _arrow(cam, Icons.keyboard_arrow_right, 'Pan right', 1, 0),
        ],
      ),
      _arrow(cam, Icons.keyboard_arrow_down, 'Tilt down', 0, -1),
    ],
  );

  Widget _toolButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    color: selected ? Colors.amberAccent : Colors.white,
    disabledColor: Colors.white38,
    icon: Icon(icon),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewer,
      builder: (context, _) {
        final id = viewer.showing;
        final cam = id == null ? null : widget.service.camera(id);
        _cameraChanged(cam?.peerId);
        if (cam == null) return const SizedBox.shrink();
        final url = cam.videoUrl(hd: viewer.hd);
        final scale = _scale;
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
                      : LayoutBuilder(
                          builder: (context, box) {
                            _size = box.biggest;
                            return InteractiveViewer(
                              transformationController: _zoom,
                              minScale: 1,
                              maxScale: _maxZoom,
                              child: SizedBox.fromSize(
                                size: box.biggest,
                                child: CameraStream(
                                  key: ValueKey(url),
                                  url: url,
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Positioned(
                  left: 8,
                  right: 4,
                  top: 4,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _Chip(
                            icon: Icons.videocam,
                            text: scale > 1.05
                                ? '${cam.name} · ${scale.toStringAsFixed(1)}×'
                                : cam.name,
                          ),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (url != null) ...[
                            _toolButton(
                              tooltip: 'Zoom out',
                              icon: Icons.zoom_out,
                              onPressed: scale > 1.001
                                  ? () => _zoomBy(1 / 1.5)
                                  : null,
                            ),
                            _toolButton(
                              tooltip: 'Zoom in',
                              icon: Icons.zoom_in,
                              onPressed: scale < _maxZoom - 0.001
                                  ? () => _zoomBy(1.5)
                                  : null,
                            ),
                          ],
                          if (cam.canPanTilt)
                            _toolButton(
                              tooltip: 'Pan & tilt',
                              icon: Icons.open_with,
                              selected: _panTiltOpen,
                              onPressed: () => setState(() {
                                _panTiltOpen = !_panTiltOpen;
                                _ptzProblem = null;
                              }),
                            ),
                          if (cam.isTapo && url != null)
                            TextButton(
                              onPressed: () => viewer.hd = !viewer.hd,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                              child: Text(viewer.hd ? 'HD' : 'SD'),
                            ),
                          _toolButton(
                            tooltip: 'Turn off camera',
                            icon: Icons.close,
                            onPressed: viewer.stop,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_panTiltOpen && cam.canPanTilt)
                  Positioned(right: 12, bottom: 12, child: _pad(cam)),
                if (_panTiltOpen && _ptzProblem != null)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    right: 170,
                    child: _Chip(
                      icon: Icons.error_outline,
                      text: 'Pan & tilt: $_ptzProblem',
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
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}
