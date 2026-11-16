import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads exact byte counts and lines from a socket.
class ByteReader {
  ByteReader(Socket socket) {
    _sub = socket.listen(
      (d) {
        _chunks.add(d);
        _available += d.length;
        _wake();
      },
      onError: (Object e) {
        _error ??= e;
        _done = true;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<Uint8List> _chunks = [];
  int _offset = 0; // Into the first chunk.
  int _available = 0;
  bool _done = false;
  Object? _error;
  Completer<void>? _waiter;

  /// Total bytes received so far.
  int received = 0;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  Future<void> _need(int n) async {
    while (_available < n) {
      if (_done) {
        throw _error ?? const SocketException('Connection closed');
      }
      await (_waiter ??= Completer<void>()).future;
    }
  }

  Future<Uint8List> read(int n) async {
    await _need(n);
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final take = (c.length - _offset).clamp(0, n - filled);
      out.setRange(filled, filled + take, c, _offset);
      filled += take;
      _offset += take;
      if (_offset == c.length) {
        _chunks.removeAt(0);
        _offset = 0;
      }
    }
    _available -= n;
    received += n;
    return out;
  }

  Future<int> readByte() async => (await read(1))[0];

  /// Looks at the next byte without consuming it.
  Future<int> peekByte() async {
    await _need(1);
    return _chunks.first[_offset];
  }

  /// Reads up to and including "\n"; returns the line without "\r\n".
  Future<String> readLine({int max = 16384}) async {
    final b = BytesBuilder();
    while (true) {
      final c = await readByte();
      if (c == 0x0A) break;
      b.addByte(c);
      if (b.length > max) throw const FormatException('Line too long');
    }
    final bytes = b.takeBytes();
    final end = bytes.isNotEmpty && bytes.last == 0x0D
        ? bytes.length - 1
        : bytes.length;
    return latin1.decode(bytes.sublist(0, end));
  }

  /// Reads header lines until the empty line; names are lower-cased.
  Future<Map<String, String>> readHeaders() async {
    final h = <String, String>{};
    while (true) {
      final line = await readLine();
      if (line.isEmpty) return h;
      final i = line.indexOf(':');
      if (i > 0) {
        h[line.substring(0, i).trim().toLowerCase()] = line
            .substring(i + 1)
            .trim();
      }
    }
  }

  Future<void> cancel() => _sub.cancel();
}

/// The text between [start] and [end] in [s], or ''.
String between(String s, String start, String end) {
  final i = s.indexOf(start);
  if (i < 0) return '';
  final j = s.indexOf(end, i + start.length);
  return j < 0 ? '' : s.substring(i + start.length, j);
}
