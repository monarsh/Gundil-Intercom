import 'package:flutter/foundation.dart';

/// Which camera's picture is on (the camera on/off button), if any. Works
/// with or without a call; only for cameras, never for intercom peers.
class CameraViewer extends ChangeNotifier {
  String? _showing;
  bool _hd = false;

  /// Peer id of the camera being watched.
  String? get showing => _showing;
  bool get on => _showing != null;

  /// Tapo: the full-resolution stream instead of the small one.
  bool get hd => _hd;

  bool isShowing(String id) => _showing == id;

  void show(String id) {
    if (_showing == id) return;
    _showing = id;
    notifyListeners();
  }

  void stop() {
    if (_showing == null) return;
    _showing = null;
    notifyListeners();
  }

  void toggle(String id) => isShowing(id) ? stop() : show(id);

  set hd(bool v) {
    if (_hd == v) return;
    _hd = v;
    notifyListeners();
  }
}
