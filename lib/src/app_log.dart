import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'intercom_service.dart';

/// Sends everything to the debug log ([DebugLog]): the engine's own lines,
/// and the video player's messages (fvp and its mdk player use
/// package:logging). Call once, before the first picture is opened.
void setUpAppLog() {
  // Release builds: only in the app (printing every line costs time).
  DebugLog.instance.printer = kDebugMode ? debugPrint : null;
  Logger.root.level = Level.INFO;
  _records ??= Logger.root.onRecord.listen((r) {
    final tag = r.loggerName == 'mdk' ? 'player' : r.loggerName;
    final level = r.level >= Level.SEVERE
        ? 'error: '
        : r.level >= Level.WARNING
        ? 'warning: '
        : '';
    debugLog(tag.isEmpty ? 'log' : tag, '$level${r.message}');
  });
}

StreamSubscription<LogRecord>? _records;

/// More detail: every part a Tapo sends, the online checks, and the video
/// player's debug messages.
bool get detailedLog => DebugLog.instance.detailed;

set detailedLog(bool on) {
  DebugLog.instance.detailed = on;
  Logger.root.level = on ? Level.ALL : Level.INFO;
  debugLog('app', 'detailed log ${on ? 'on' : 'off'}');
}
