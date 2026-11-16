/// The little of MPEG-TS that Tapo cameras need: pulling the audio out of
/// the camera's stream, and wrapping our audio for its speaker.
///
/// The Tapo protocol was worked out by the go2rtc project
/// (https://github.com/AlexxIT/go2rtc, MIT licence), used here as reference.
library;

import 'dart:typed_data';

const int tsPacketSize = 188;
const int _sync = 0x47;

/// Tapo's private stream types.
const int streamTypePcmaTapo = 0x90; // G.711 A-law, 8 kHz
const int streamTypePcmuTapo = 0x91; // G.711 µ-law, 16 kHz (newer firmware)

/// One audio chunk from the camera.
class TsAudio {
  TsAudio(this.streamType, this.payload);
  final int streamType;
  final Uint8List payload;
}

/// Extracts the Tapo audio stream from MPEG-TS data fed in any chunking.
class TsAudioDemuxer {
  final BytesBuilder _pending = BytesBuilder(copy: false);
  int? _pmtPid;
  final Map<int, int> _audioPids = {}; // pid → stream type
  final Map<int, BytesBuilder> _pes = {};

  /// Feeds [data]; returns the audio chunks completed by it.
  List<TsAudio> add(Uint8List data) {
    final out = <TsAudio>[];
    _pending.add(data);
    var buf = _pending.takeBytes();
    var i = 0;
    while (buf.length - i >= tsPacketSize) {
      if (buf[i] != _sync) {
        i++; // Resync.
        continue;
      }
      _packet(Uint8List.sublistView(buf, i, i + tsPacketSize), out);
      i += tsPacketSize;
    }
    if (i < buf.length) _pending.add(Uint8List.sublistView(buf, i));
    return out;
  }

  void _packet(Uint8List p, List<TsAudio> out) {
    final pusi = (p[1] & 0x40) != 0;
    final pid = ((p[1] & 0x1F) << 8) | p[2];
    final hasAdaptation = (p[3] & 0x20) != 0;
    final hasPayload = (p[3] & 0x10) != 0;
    if (!hasPayload) return;
    var off = 4;
    if (hasAdaptation) off += 1 + p[4];
    if (off >= tsPacketSize) return;
    final payload = Uint8List.sublistView(p, off);

    if (pid == 0) {
      if (pusi) _pat(payload);
    } else if (pid == _pmtPid) {
      if (pusi) _pmt(payload);
    } else if (_audioPids.containsKey(pid)) {
      if (pusi) {
        _flush(pid, out);
        _pes[pid] = BytesBuilder(copy: true)..add(payload);
      } else {
        _pes[pid]?.add(payload);
      }
      _flushIfComplete(pid, out);
    }
  }

  void _pat(Uint8List s) {
    final b = _section(s);
    if (b == null || b.length < 12) return;
    // After the 8 byte section header: program number, PMT pid.
    _pmtPid = ((b[10] & 0x1F) << 8) | b[11];
  }

  void _pmt(Uint8List s) {
    final b = _section(s);
    if (b == null || b.length < 12) return;
    final sectionLength = ((b[1] & 0x0F) << 8) | b[2];
    final end = (3 + sectionLength - 4).clamp(0, b.length);
    final infoLength = ((b[10] & 0x0F) << 8) | b[11];
    var i = 12 + infoLength;
    while (i + 5 <= end) {
      final type = b[i];
      final pid = ((b[i + 1] & 0x1F) << 8) | b[i + 2];
      final esLength = ((b[i + 3] & 0x0F) << 8) | b[i + 4];
      if (type == streamTypePcmaTapo || type == streamTypePcmuTapo) {
        _audioPids[pid] = type;
      }
      i += 5 + esLength;
    }
  }

  /// The table section after the pointer field.
  static Uint8List? _section(Uint8List payload) {
    if (payload.isEmpty) return null;
    final start = 1 + payload[0];
    return start < payload.length
        ? Uint8List.sublistView(payload, start)
        : null;
  }

  void _flushIfComplete(int pid, List<TsAudio> out) {
    final b = _pes[pid];
    if (b == null || b.length < 6) return;
    final bytes = b.toBytes();
    final length = (bytes[4] << 8) | bytes[5];
    if (length != 0 && bytes.length >= 6 + length) _flush(pid, out);
  }

  void _flush(int pid, List<TsAudio> out) {
    final b = _pes.remove(pid);
    if (b == null) return;
    final bytes = b.takeBytes();
    // 00 00 01, stream id, length (2), flags (2), header length, header…
    if (bytes.length < 9 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 1) {
      return;
    }
    final length = (bytes[4] << 8) | bytes[5];
    final start = 9 + bytes[8];
    var end = length == 0 ? bytes.length : 6 + length;
    if (end > bytes.length) end = bytes.length;
    if (start >= end) return;
    out.add(
      TsAudio(_audioPids[pid]!, Uint8List.sublistView(bytes, start, end)),
    );
  }
}

/// Wraps A-law audio in MPEG-TS the way the camera's speaker expects it
/// (same layout as go2rtc's muxer).
class TsAudioMuxer {
  static const int _pmtPid = 0x1000;
  static const int _audioPid = 0x100;

  int _counter = 0;
  int _pts = 0;

  /// PAT and PMT: sent once before the audio.
  Uint8List header() {
    final out = BytesBuilder();
    out.add(
      _table(0, 0, [
        0x00, 0x01, // Program number
        0xE0 | (_pmtPid >> 8), _pmtPid & 0xFF,
      ]),
    );
    out.add(
      _table(_pmtPid, 2, [
        0xFF, 0xFF, // PCR pid: none
        0xF0, 0x00, // Program info length
        streamTypePcmaTapo,
        0xE0 | (_audioPid >> 8), _audioPid & 0xFF,
        0xF0, 0x00, // ES info length
      ]),
    );
    return out.takeBytes();
  }

  static Uint8List _table(int pid, int tableId, List<int> content) {
    final p = Uint8List(tsPacketSize);
    p[0] = _sync;
    p[1] = 0x40 | (pid >> 8); // Payload unit start
    p[2] = pid & 0xFF;
    p[3] = 0x10; // Payload only
    p[4] = 0; // Pointer field
    final sectionLength = 5 + content.length + 4;
    final section = <int>[
      tableId,
      0xB0 | (sectionLength >> 8), sectionLength & 0xFF,
      0x00, 0x01, // Table id extension
      0xC1, // Version 0, current
      0x00, 0x00, // Section number, last section number
      ...content,
    ];
    final crc = _crc32(section);
    section.addAll([
      crc >> 24,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ]);
    p.setRange(5, 5 + section.length, section);
    return p;
  }

  /// One chunk of A-law [audio] as TS packets. [samples] advances the
  /// timestamp (8 kHz clock, like the RTP timestamps go2rtc passes on).
  Uint8List audio(Uint8List audio) {
    final size = 3 + 5 + audio.length;
    final pes = Uint8List(14 + audio.length);
    pes[2] = 1; // Start code 00 00 01
    pes[3] = 0xC0; // Audio stream
    if (size <= 0xFFFF) {
      pes[4] = size >> 8;
      pes[5] = size & 0xFF;
    }
    pes[6] = 0x80;
    pes[7] = 0x80; // PTS only
    pes[8] = 5;
    final t = _pts;
    pes[9] = 0x20 | ((t >> 29) & 0x0E) | 1;
    pes[10] = (t >> 22) & 0xFF;
    pes[11] = ((t >> 14) & 0xFE) | 1;
    pes[12] = (t >> 7) & 0xFF;
    pes[13] = ((t << 1) & 0xFE) | 1;
    pes.setRange(14, pes.length, audio);
    _pts = (_pts + audio.length) & 0xFFFFFFFF;

    final out = BytesBuilder();
    var off = 0;
    var first = true;
    while (off < pes.length) {
      final p = Uint8List(tsPacketSize);
      p[0] = _sync;
      p[1] = (first ? 0x40 : 0) | (_audioPid >> 8);
      p[2] = _audioPid & 0xFF;
      final counter = _counter++ & 0x0F;
      final left = pes.length - off;
      if (left < tsPacketSize - 4) {
        // Pad with an adaptation field in front.
        p[3] = 0x30 | counter;
        final pad = tsPacketSize - 4 - 1 - left;
        p[4] = pad;
        p.setRange(5 + pad, tsPacketSize, pes, off);
        off += left;
      } else {
        p[3] = 0x10 | counter;
        p.setRange(4, tsPacketSize, pes, off);
        off += tsPacketSize - 4;
      }
      first = false;
      out.add(p);
    }
    return out.takeBytes();
  }

  /// CRC-32/MPEG-2.
  static int _crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b << 24;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x80000000) != 0
            ? ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            : (crc << 1) & 0xFFFFFFFF;
      }
    }
    return crc;
  }
}
