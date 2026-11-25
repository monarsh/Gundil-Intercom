/// IMA ADPCM: 16-bit PCM in 4 bits per sample (a quarter of the data),
/// for calls over the internet. Each packet carries its own starting state,
/// so a lost packet doesn't spoil the next ones.
library;

import 'dart:typed_data';

const List<int> _steps = [
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  16,
  17,
  19,
  21,
  23,
  25,
  28,
  31,
  34,
  37,
  41,
  45,
  50,
  55,
  60,
  66,
  73,
  80,
  88,
  97,
  107,
  118,
  130,
  143,
  157,
  173,
  190,
  209,
  230,
  253,
  279,
  307,
  337,
  371,
  408,
  449,
  494,
  544,
  598,
  658,
  724,
  796,
  876,
  963,
  1060,
  1166,
  1282,
  1411,
  1552,
  1707,
  1878,
  2066,
  2272,
  2499,
  2749,
  3024,
  3327,
  3660,
  4026,
  4428,
  4871,
  5358,
  5894,
  6484,
  7132,
  7845,
  8630,
  9493,
  10442,
  11487,
  12635,
  13899,
  15289,
  16818,
  18500,
  20350,
  22385,
  24623,
  27086,
  29794,
  32767,
];
const List<int> _indexStep = [-1, -1, -1, -1, 2, 4, 6, 8];

class AdpcmEncoder {
  int _predicted = 0, _index = 0;

  /// `[predicted:int16 LE][index:1][count:uint16 LE][nibbles…]`.
  Uint8List encode(Int16List pcm) {
    final out = Uint8List(5 + (pcm.length + 1) ~/ 2);
    final h = ByteData.sublistView(out);
    h.setInt16(0, _predicted, Endian.little);
    out[2] = _index;
    h.setUint16(3, pcm.length, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      final step = _steps[_index];
      var diff = pcm[i] - _predicted;
      var code = 0;
      if (diff < 0) {
        code = 8;
        diff = -diff;
      }
      var delta = step >> 3;
      if (diff >= step) {
        code |= 4;
        diff -= step;
        delta += step;
      }
      if (diff >= step >> 1) {
        code |= 2;
        diff -= step >> 1;
        delta += step >> 1;
      }
      if (diff >= step >> 2) {
        code |= 1;
        delta += step >> 2;
      }
      _predicted += (code & 8) != 0 ? -delta : delta;
      if (_predicted > 32767) _predicted = 32767;
      if (_predicted < -32768) _predicted = -32768;
      _index += _indexStep[code & 7];
      if (_index < 0) _index = 0;
      if (_index > 88) _index = 88;
      if (i.isEven) {
        out[5 + i ~/ 2] = code;
      } else {
        out[5 + i ~/ 2] |= code << 4;
      }
    }
    return out;
  }
}

/// Decodes one packet (stateless: the state travels in the packet).
Int16List adpcmDecode(Uint8List data) {
  if (data.length < 5) return Int16List(0);
  final h = ByteData.sublistView(data);
  var predicted = h.getInt16(0, Endian.little);
  var index = data[2].clamp(0, 88);
  final count = h.getUint16(3, Endian.little);
  final n = count < (data.length - 5) * 2 ? count : (data.length - 5) * 2;
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    final b = data[5 + i ~/ 2];
    final code = i.isEven ? b & 0x0F : b >> 4;
    final step = _steps[index];
    var delta = step >> 3;
    if ((code & 4) != 0) delta += step;
    if ((code & 2) != 0) delta += step >> 1;
    if ((code & 1) != 0) delta += step >> 2;
    predicted += (code & 8) != 0 ? -delta : delta;
    if (predicted > 32767) predicted = 32767;
    if (predicted < -32768) predicted = -32768;
    index += _indexStep[code & 7];
    if (index < 0) index = 0;
    if (index > 88) index = 88;
    out[i] = predicted;
  }
  return out;
}
