/// G.711 (A-law, µ-law) and the 8 kHz ⇄ 16 kHz conversions needed to talk
/// with IP cameras, which use telephone audio.
library;

import 'dart:typed_data';

final Int16List _alawToPcm = () {
  final t = Int16List(256);
  for (var i = 0; i < 256; i++) {
    final a = i ^ 0x55;
    var v = (a & 0x0F) << 4;
    final seg = (a & 0x70) >> 4;
    switch (seg) {
      case 0:
        v += 8;
      case 1:
        v += 0x108;
      default:
        v = (v + 0x108) << (seg - 1);
    }
    t[i] = (a & 0x80) != 0 ? v : -v;
  }
  return t;
}();

final Int16List _ulawToPcm = () {
  final t = Int16List(256);
  for (var i = 0; i < 256; i++) {
    final u = ~i & 0xFF;
    var v = ((u & 0x0F) << 3) + 0x84;
    v <<= (u & 0x70) >> 4;
    t[i] = (u & 0x80) != 0 ? 0x84 - v : v - 0x84;
  }
  return t;
}();

Int16List alawDecode(Uint8List data) {
  final out = Int16List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = _alawToPcm[data[i]];
  }
  return out;
}

Int16List ulawDecode(Uint8List data) {
  final out = Int16List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = _ulawToPcm[data[i]];
  }
  return out;
}

const List<int> _segEnd = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF];

Uint8List alawEncode(Int16List pcm) {
  final out = Uint8List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    var v = pcm[i] >> 3; // 13 bit
    int mask;
    if (v >= 0) {
      mask = 0xD5;
    } else {
      mask = 0x55;
      v = -v - 1;
    }
    var seg = 0;
    while (seg < 8 && v > _segEnd[seg]) {
      seg++;
    }
    int a;
    if (seg >= 8) {
      a = 0x7F;
    } else {
      a = seg << 4;
      a |= seg < 2 ? (v >> 1) & 0x0F : (v >> seg) & 0x0F;
    }
    out[i] = a ^ mask;
  }
  return out;
}

/// Doubles the sample rate (8 → 16 kHz), interpolating between samples.
/// Keeps the last sample between calls so chunks join smoothly.
class Upsampler2 {
  int _last = 0;

  Int16List process(Int16List input) {
    final out = Int16List(input.length * 2);
    var prev = _last;
    for (var i = 0; i < input.length; i++) {
      final s = input[i];
      out[i * 2] = (prev + s) >> 1;
      out[i * 2 + 1] = s;
      prev = s;
    }
    _last = prev;
    return out;
  }
}

/// Halves the sample rate (16 → 8 kHz) by averaging pairs.
Int16List downsample2(Int16List input) {
  final out = Int16List(input.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = (input[i * 2] + input[i * 2 + 1]) >> 1;
  }
  return out;
}
