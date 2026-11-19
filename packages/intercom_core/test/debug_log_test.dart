import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(DebugLog.instance.clear);

  test('lines have a time and a tag, and logins are hidden', () {
    debugLog('video', 'opening rtsp://me:p%40ss@192.168.1.5:554/stream2');
    final e = DebugLog.instance.entries.last;
    expect(e.tag, 'video');
    expect(e.text, 'opening rtsp://***@192.168.1.5:554/stream2');
    expect(e.toString(), matches(r'^\d\d:\d\d:\d\d\.\d\d\d \[video\] '));
  });

  test('keeps only the newest lines', () {
    for (var i = 0; i < DebugLog.capacity + 10; i++) {
      debugLog('t', 'line $i');
    }
    expect(DebugLog.instance.length, DebugLog.capacity);
    expect(DebugLog.instance.entries.first.text, 'line 10');
    expect(
      DebugLog.instance.dump(header: ['Gundil Intercom']),
      startsWith('Gundil Intercom\n\n'),
    );
  });

  test('listeners hear about new lines', () {
    var n = 0;
    void l() => n++;
    DebugLog.instance.addListener(l);
    debugLog('t', 'a');
    DebugLog.instance.removeListener(l);
    debugLog('t', 'b');
    expect(n, 1);
  });

  test('the engine log goes to the debug log', () {
    IntercomCore.log('hello');
    expect(DebugLog.instance.entries.last.toString(), contains('[app] hello'));
  });
}
