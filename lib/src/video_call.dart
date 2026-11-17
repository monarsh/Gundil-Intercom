import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'intercom_service.dart';

/// Which way a camera points.
enum CameraFacing { front, back, external }

/// One camera the device has (e.g. "Front camera", "Logitech C920").
class CameraInfo {
  const CameraInfo({
    required this.id,
    required this.name,
    required this.facing,
  });

  final String id;
  final String name;
  final CameraFacing facing;

  static CameraInfo? fromMap(Object? m) {
    if (m is! Map) return null;
    final id = m['id'], name = m['name'];
    if (id is! String) return null;
    return CameraInfo(
      id: id,
      name: name is String && name.isNotEmpty ? name : id,
      facing: switch (m['facing']) {
        'front' => CameraFacing.front,
        'back' => CameraFacing.back,
        _ => CameraFacing.external,
      },
    );
  }
}

/// The local camera during a call. It is never turned on automatically:
/// the user presses the camera button. Pictures go to the peers through
/// [IntercomService.sendVideoFrame] and are shown as a self-view.
///
/// Capture is native: CameraX on Android (`CameraCapture.kt`), Media
/// Foundation on Windows (`windows/runner/camera_capture.cpp`), V4L2 on Linux
/// (`linux/runner/camera_capture.cc`). All deliver JPEG pictures on the
/// `p2p_intercom/camera/frames` event channel.
class VideoCall extends ChangeNotifier {
  VideoCall(this.service, {bool hd = false, this.onHdChanged}) : _hd = hd {
    service.addListener(_onService);
  }

  final IntercomService service;

  /// Called when the SD/HD choice changes (to remember it).
  final void Function(bool hd)? onHdChanged;

  /// Shows a camera error that happened on its own (camera unplugged,
  /// taken by another app, ...).
  void Function(String message)? onError;

  static const MethodChannel _method = MethodChannel('p2p_intercom/camera');
  static const EventChannel _frames = EventChannel(
    'p2p_intercom/camera/frames',
  );

  /// Sending video is available on these platforms (others still show the
  /// video peers send).
  static bool get supported =>
      debugSupported ??
      (Platform.isAndroid || Platform.isWindows || Platform.isLinux);

  /// Tests: pretend the platform has (or lacks) camera support.
  @visibleForTesting
  static bool? debugSupported;

  /// Picture size and rate asked from the camera. 640x480 JPEGs are about
  /// 25–50 KB, so 15 fps is well within any Wi-Fi.
  static const int width = 640;
  static const int height = 480;
  static const int fps = 15;
  static const int quality = 70;

  /// HD: 1280x720 at a little lower JPEG quality, about 80–150 KB a
  /// picture. Fine on Wi-Fi; on a slow line pictures are skipped (never the
  /// audio).
  static const int hdWidth = 1280;
  static const int hdHeight = 720;
  static const int hdQuality = 60;

  bool _hd;

  /// Send HD (1280x720) instead of SD (640x480).
  bool get hd => _hd;

  Map<String, Object> _startArgs(String id) => {
    'id': id,
    'width': _hd ? hdWidth : width,
    'height': _hd ? hdHeight : height,
    'fps': fps,
    'quality': _hd ? hdQuality : quality,
  };

  /// Switches between SD and HD; a running camera restarts at the new size
  /// without telling the peers it went off. Returns an error message, or
  /// null.
  Future<String?> setHd(bool value) async {
    if (value == _hd || _busy) return null;
    _hd = value;
    onHdChanged?.call(value);
    notifyListeners();
    final id = _cameraId;
    if (!_on || id == null) return null;
    _busy = true;
    notifyListeners();
    try {
      try {
        await _method.invokeMethod<void>('stop');
      } on PlatformException {
        // Already stopped.
      }
      await _method.invokeMethod<void>('start', _startArgs(id));
      return null;
    } on PlatformException catch (e) {
      _busy = false;
      await stop();
      return 'Camera unavailable: ${e.message ?? e.code}';
    } on MissingPluginException {
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  List<CameraInfo> _cameras = const [];
  String? _cameraId;
  bool _on = false;
  bool _busy = false;
  Uint8List? _preview;
  int _previewRotation = 0;
  bool _mirror = false;
  StreamSubscription<Object?>? _sub;

  /// The camera is on (we're sending video).
  bool get on => _on;

  /// Starting, stopping or switching is in progress.
  bool get busy => _busy;

  List<CameraInfo> get cameras => _cameras;

  CameraInfo? get camera =>
      _cameras.where((c) => c.id == _cameraId).firstOrNull;

  /// Latest own picture, for the self-view.
  Uint8List? get preview => _preview;
  int get previewRotation => _previewRotation;

  /// Show the self-view mirrored (front cameras, like a mirror).
  bool get mirror => _mirror;

  /// Whether there's another camera to switch to.
  bool get canSwitch => _cameras.length > 1;

  /// Bumped on every own picture, so only the self-view repaints.
  final ValueNotifier<int> previewTick = ValueNotifier(0);

  /// Turns the camera on or off.
  Future<String?> toggle() async {
    if (!_on) return start();
    await stop();
    return null;
  }

  /// Turns the camera on (asks for permission first on Android). Returns an
  /// error message, or null on success.
  Future<String?> start([String? cameraId]) async {
    if (!supported || _busy) return null;
    if (!service.inConversation) {
      return 'Connect first, then turn on the camera';
    }
    _busy = true;
    notifyListeners();
    try {
      final allowed = await _method.invokeMethod<bool>('requestPermission');
      if (allowed != true) return 'Camera permission denied';
      await _refreshCameras();
      if (_cameras.isEmpty) return 'No camera found';
      final id = cameraId ?? _pickDefault();
      if (!service.inConversation) return null; // Hung up meanwhile.
      await _sub?.cancel();
      _sub = _frames.receiveBroadcastStream().listen(
        _onFrame,
        onError: (Object e) {
          _fail(e is PlatformException ? (e.message ?? e.code) : '$e');
        },
      );
      await _method.invokeMethod<void>('start', _startArgs(id));
      _cameraId = id;
      _on = true;
      service.setCamera(true);
      return null;
    } on PlatformException catch (e) {
      await _release();
      return 'Camera unavailable: ${e.message ?? e.code}';
    } on MissingPluginException {
      await _release();
      return 'Camera not supported on this device';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Turns the camera off.
  Future<void> stop() async {
    if (!_on && _sub == null) return;
    _on = false;
    service.setCamera(false);
    await _release();
    notifyListeners();
  }

  /// Android: front ⇄ back. Windows: the next webcam.
  Future<String?> switchCamera() async {
    if (_cameras.length < 2) return null;
    final cur = camera;
    CameraInfo next;
    if (cur != null && cur.facing != CameraFacing.external) {
      final want = cur.facing == CameraFacing.front
          ? CameraFacing.back
          : CameraFacing.front;
      next = _cameras.firstWhere(
        (c) => c.facing == want,
        orElse: () => _cameras[(_cameras.indexOf(cur) + 1) % _cameras.length],
      );
    } else {
      final i = cur == null ? -1 : _cameras.indexOf(cur);
      next = _cameras[(i + 1) % _cameras.length];
    }
    return select(next.id);
  }

  /// Switches to camera [id] (turns the camera on if it was off).
  Future<String?> select(String id) async {
    if (_on && id == _cameraId) return null;
    if (_on) await stop();
    return start(id);
  }

  /// Reloads the camera list (e.g. a USB webcam was plugged in).
  Future<void> refreshCameras() async {
    if (!supported) return;
    try {
      await _refreshCameras();
    } on PlatformException {
      // Keep the old list.
    } on MissingPluginException {
      return;
    }
    notifyListeners();
  }

  Future<void> _refreshCameras() async {
    final list = await _method.invokeMethod<List<Object?>>('list') ?? const [];
    _cameras = list.map(CameraInfo.fromMap).whereType<CameraInfo>().toList();
  }

  String _pickDefault() {
    // Keep the last choice (e.g. the back camera) for the next call.
    final last = _cameraId;
    if (last != null && _cameras.any((c) => c.id == last)) return last;
    // A video call starts with the selfie camera on a phone.
    return _cameras
        .firstWhere(
          (c) => c.facing == CameraFacing.front,
          orElse: () => _cameras.first,
        )
        .id;
  }

  void _onFrame(Object? e) {
    if (!_on || e is! Map) return;
    final jpeg = e['jpeg'];
    if (jpeg is! Uint8List || jpeg.isEmpty) return;
    final rotation = (e['rotation'] as int? ?? 0) & 3;
    _preview = jpeg;
    _previewRotation = rotation;
    _mirror = e['mirror'] == true;
    previewTick.value++;
    service.sendVideoFrame(jpeg, rotation: rotation);
  }

  void _fail(String message) {
    debugPrint('Camera error: $message');
    onError?.call('Camera stopped: $message');
    stop();
  }

  Future<void> _release() async {
    await _sub?.cancel();
    _sub = null;
    _preview = null;
    try {
      await _method.invokeMethod<void>('stop');
    } on PlatformException {
      // Already stopped.
    } on MissingPluginException {
      // Test harness.
    }
  }

  /// The call ended (or the engine turned the camera off): release it.
  void _onService() {
    if (_on && !service.cameraOn) stop();
  }

  @override
  void dispose() {
    service.removeListener(_onService);
    _release();
    previewTick.dispose();
    super.dispose();
  }
}
