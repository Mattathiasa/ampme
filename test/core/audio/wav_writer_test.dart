import 'dart:typed_data';

import 'package:ampme/core/audio/wav_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('writes an interleaved 16-bit PCM WAV', () {
    final wav = wavFromPcm([
      Float32List.fromList([0, 1, -1]),
      Float32List.fromList([0.5, 2, -2]), // clipped
    ], 22050);
    final v = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(v.getUint16(22, Endian.little), 2);
    expect(v.getUint32(24, Endian.little), 22050);
    expect(v.getUint32(40, Endian.little), 12);
    expect(wav.length, 44 + 12);
    final samples = [for (var i = 0; i < 6; i++) v.getInt16(44 + i * 2, Endian.little)];
    expect(samples, [0, 16384, 32767, 32767, -32767, -32767]);
  });
}
