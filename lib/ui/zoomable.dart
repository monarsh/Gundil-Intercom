import 'package:flutter/material.dart';

/// Digital zoom for a picture: pinch, double-tap (2× on that spot / back
/// out), drag while zoomed in, and small zoom in / out buttons with the
/// zoom level.
class ZoomableView extends StatefulWidget {
  const ZoomableView({
    super.key,
    required this.child,
    this.maxScale = 3,
    this.buttons = true,
  });

  final Widget child;
  final double maxScale;

  /// Show the zoom in / zoom out buttons (top right).
  final bool buttons;

  @override
  State<ZoomableView> createState() => _ZoomableViewState();
}

class _ZoomableViewState extends State<ZoomableView> {
  final TransformationController _zoom = TransformationController();
  Size _size = Size.zero;
  Offset? _doubleTapAt;

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
    _zoom.dispose();
    super.dispose();
  }

  double get _scale => _zoom.value.getMaxScaleOnAxis();

  void _zoomBy(double factor, {Offset? around}) {
    final m = _zoom.value;
    final s = m.getMaxScaleOnAxis();
    final target = (s * factor).clamp(1.0, widget.maxScale);
    if (target <= 1.001) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final k = target / s;
    final cx = around?.dx ?? _size.width / 2;
    final cy = around?.dy ?? _size.height / 2;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(cx, cy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1)
      ..multiply(m);
  }

  void _doubleTap() {
    if (_scale > 1.05) {
      _zoom.value = Matrix4.identity();
    } else {
      _zoomBy(2, around: _doubleTapAt);
    }
  }

  Widget _button(String tip, IconData icon, VoidCallback? onPressed) =>
      IconButton(
        tooltip: tip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        color: Colors.white,
        disabledColor: Colors.white38,
        style: IconButton.styleFrom(backgroundColor: Colors.black45),
        icon: Icon(icon, size: 20),
      );

  @override
  Widget build(BuildContext context) {
    final scale = _scale;
    return LayoutBuilder(
      builder: (context, box) {
        _size = box.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: _doubleTap,
              child: InteractiveViewer(
                transformationController: _zoom,
                minScale: 1,
                maxScale: widget.maxScale,
                child: SizedBox.fromSize(
                  size: box.biggest,
                  child: widget.child,
                ),
              ),
            ),
            if (widget.buttons)
              Positioned(
                right: 4,
                top: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (scale > 1.05)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          '${scale.toStringAsFixed(1)}×',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [Shadow(blurRadius: 3)],
                          ),
                        ),
                      ),
                    _button(
                      'Zoom out',
                      Icons.zoom_out,
                      scale > 1.001 ? () => _zoomBy(1 / 1.5) : null,
                    ),
                    const SizedBox(width: 2),
                    _button(
                      'Zoom in',
                      Icons.zoom_in,
                      scale < widget.maxScale - 0.001
                          ? () => _zoomBy(1.5)
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
