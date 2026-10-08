import 'dart:typed_data';

/// Wire format of live-capture audio on the `ampme-live` data channel:
///
///   u32 epoch | u32 sample rate | u32 frame (low) | u32 frame (high) |
///   int16 PCM, stereo interleaved
///
/// all little-endian. [epoch] identifies one sharing session (a new "Share a
/// tab" starts a new epoch), so stale frames from a previous one are ignored.
abstract final class LiveFrames {
  static const int headerBytes = 16;

  /// Live audio is always sent as stereo.
  static const int channels = 2;

  static Uint8List encode({
    required int epoch,
    required int sampleRate,
    required int frame,
    required Int16List pcm,
  }) {
    final out = Uint8List(headerBytes + pcm.lengthInBytes);
    ByteData.sublistView(out)
      ..setUint32(0, epoch, Endian.little)
      ..setUint32(4, sampleRate, Endian.little)
      ..setUint32(8, frame & 0xffffffff, Endian.little)
      ..setUint32(12, frame ~/ 0x100000000, Endian.little);
    final body = ByteData.sublistView(out, headerBytes);
    for (var i = 0; i < pcm.length; i++) {
      body.setInt16(i * 2, pcm[i], Endian.little);
    }
    return out;
  }

  static ({int epoch, int sampleRate, int frame, Int16List pcm})? decode(Uint8List message) {
    if (message.length < headerBytes || (message.length - headerBytes).isOdd) return null;
    final v = ByteData.sublistView(message);
    final samples = (message.length - headerBytes) ~/ 2;
    final pcm = Int16List(samples);
    for (var i = 0; i < samples; i++) {
      pcm[i] = v.getInt16(headerBytes + i * 2, Endian.little);
    }
    return (
      epoch: v.getUint32(0, Endian.little),
      sampleRate: v.getUint32(4, Endian.little),
      frame: v.getUint32(8, Endian.little) + v.getUint32(12, Endian.little) * 0x100000000,
      pcm: pcm,
    );
  }

  /// Float samples (-1..1) of each channel → interleaved 16-bit PCM.
  static Int16List interleave(List<Float32List> channels) {
    final n = channels.first.length;
    final ch = channels.length;
    final out = Int16List(n * ch);
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < ch; c++) {
        final v = channels[c][i];
        out[i * ch + c] = (v >= 1 ? 32767 : v <= -1 ? -32767 : (v * 32767).round());
      }
    }
    return out;
  }
}
