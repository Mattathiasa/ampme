import 'dart:math' as math;
import 'dart:typed_data';

/// Encodes float PCM ([channels] of equal length, -1..1) as a 16-bit WAV
/// file. Fallback for sending a video's sound when the browser can't encode
/// Opus (larger, ~10 MB per minute, but every player handles it).
Uint8List wavFromPcm(List<Float32List> channels, int sampleRate) {
  final n = channels.isEmpty ? 0 : channels.first.length;
  final ch = channels.length;
  final dataBytes = n * ch * 2;
  final out = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  out
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, ch, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * ch * 2, Endian.little)
    ..setUint16(32, ch * 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);
  var o = 44;
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < ch; c++) {
      final v = math.max(-1.0, math.min(1.0, channels[c][i]));
      out.setInt16(o, (v * 32767).round(), Endian.little);
      o += 2;
    }
  }
  return out.buffer.asUint8List();
}
