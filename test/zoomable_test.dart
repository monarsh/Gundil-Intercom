import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/ui/zoomable.dart';

void main() {
  testWidgets('zoom buttons, double-tap and pinch; at most 3×', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: ZoomableView(child: ColoredBox(color: Colors.blue)),
          ),
        ),
      ),
    );
    final viewer = find.byType(InteractiveViewer);
    double scale() => tester
        .widget<InteractiveViewer>(viewer)
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    IconButton button(String tip) => tester.widget<IconButton>(
      find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton)),
    );

    expect(button('Zoom out').onPressed, isNull);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
    }
    expect(scale(), closeTo(3, 0.001));
    expect(find.text('3.0×'), findsOneWidget);
    expect(button('Zoom in').onPressed, isNull);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pump();
    }
    expect(scale(), 1);
    expect(find.textContaining('×'), findsNothing);

    Future<void> doubleTap(Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));
    }

    final c = tester.getCenter(viewer);
    await doubleTap(c + const Offset(-80, 40));
    expect(scale(), closeTo(2, 0.001));
    await doubleTap(c);
    expect(scale(), 1);

    final f1 = await tester.startGesture(c - const Offset(30, 0));
    final f2 = await tester.startGesture(c + const Offset(30, 0));
    for (var i = 1; i <= 8; i++) {
      await f1.moveTo(c - Offset(30.0 + i * 10, 0));
      await f2.moveTo(c + Offset(30.0 + i * 10, 0));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump(const Duration(seconds: 1));
    expect(scale(), greaterThan(1.5));
    expect(scale(), lessThanOrEqualTo(3));
  });
}
