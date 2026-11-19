/// The app's debug log: what the app does with cameras, calls and the
/// network, kept in memory (the last [DebugLog.capacity] lines) so it can
/// be shown, copied or saved from the app.
library;

import 'dart:collection';

class LogEntry {
  LogEntry(this.time, this.tag, this.text);
  final DateTime time;

  /// What it's about: 'tapo', 'rtsp', 'camera', 'video', 'player', ...
  final String tag;
  final String text;

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 14:03:07.123
  String get clock =>
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}.'
      '${time.millisecond.toString().padLeft(3, '0')}';

  @override
  String toString() => '$clock [$tag] $text';
}

class DebugLog {
  DebugLog._();

  static final DebugLog instance = DebugLog._();

  /// Lines kept; older ones are dropped.
  static const int capacity = 5000;

  final ListQueue<LogEntry> _entries = ListQueue();
  final List<void Function()> _listeners = [];

  /// Also prints every line (the Flutter app routes this to debugPrint).
  void Function(String line)? printer = print;

  /// More detail: every part a Tapo sends, and the video player's own
  /// debug messages. Off by default (it's a lot).
  bool detailed = false;

  List<LogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;

  /// Lines added since the app started (including dropped ones).
  int added = 0;

  void add(String tag, String text) {
    final e = LogEntry(DateTime.now(), tag, redact(text));
    _entries.addLast(e);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    added++;
    printer?.call(e.toString());
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void clear() {
    _entries.clear();
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  /// The whole log as text, oldest first, after [header] lines.
  String dump({List<String> header = const []}) {
    final b = StringBuffer();
    for (final h in header) {
      b.writeln(h);
    }
    if (header.isNotEmpty) b.writeln();
    for (final e in _entries) {
      b.writeln(e);
    }
    return b.toString();
  }

  static final RegExp _login = RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/@]+@');

  /// Removes logins written into addresses (rtsp://user:pass@host).
  static String redact(String s) =>
      s.replaceAllMapped(_login, (m) => '${m[1]}***@');
}

/// Adds a line to the debug log.
void debugLog(String tag, String text) => DebugLog.instance.add(tag, text);

/// Bytes as "12.3 kB".
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} kB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Milliseconds since [watch] started, as "1234 ms".
String msSince(Stopwatch watch) => '${watch.elapsedMilliseconds} ms';
