import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ampme/core/audio/live_wav_server.dart';
import 'package:ampme/core/audio/pcm_ring.dart';
import 'package:ampme/core/network/live_frames.dart';
import 'package:flutter_test/flutter_test.dart';

Int16List _ramp(int frames, int start, {int channels = 2}) =>
    Int16List.fromList([for (var i = 0; i < frames * channels; i++) (start * channels + i) % 30000]);

void main() {
  group('PcmRing', () {
    test('stores frames by index, silences gaps and evicted audio', () {
      final ring = PcmRing(channels: 2, sampleRate: 10, capacitySeconds: 1); // 10 frames
      ring.write(0, _ramp(4, 0));
      ring.write(6, _ramp(2, 6)); // gap at frames 4..5
      expect(ring.endFrame, 8);
      final out = Int16List(8 * 2);
      ring.read(0, out);
      expect(out.sublist(0, 8), _ramp(4, 0));
      expect(out.sublist(8, 12), [0, 0, 0, 0], reason: 'gap is silence');
      expect(out.sublist(12, 16), _ramp(2, 6));

      ring.write(8, _ramp(10, 8)); // pushes frames < 8 out
      expect(ring.startFrame, 8);
      final old = Int16List(2);
      ring.read(0, old);
      expect(old, [0, 0]);
    });

    test('waitFor completes when the frame arrives', () async {
      final ring = PcmRing(channels: 1, sampleRate: 100);
      var done = false;
      ring.waitFor(5).then((_) => done = true).ignore();
      ring.write(0, Int16List(5));
      await pumpEventQueue();
      expect(done, isFalse);
      ring.write(5, Int16List(1));
      await pumpEventQueue();
      expect(done, isTrue);
    });
  });

  test('LiveFrames round-trip, including frame indexes past 32 bits', () {
    final pcm = Int16List.fromList([1, -2, 32767, -32768]);
    final msg = LiveFrames.encode(epoch: 7, sampleRate: 48000, frame: 0x123456789, pcm: pcm);
    final d = LiveFrames.decode(msg)!;
    expect(d.epoch, 7);
    expect(d.sampleRate, 48000);
    expect(d.frame, 0x123456789);
    expect(d.pcm, pcm);
    expect(LiveFrames.decode(Uint8List(5)), isNull);
    expect(
      LiveFrames.interleave([Float32List.fromList([0, 1]), Float32List.fromList([-1, 0.5])]),
      [0, -32767, 32767, 16384],
    );
  });

  test('LiveWavServer serves the ring as a seekable endless WAV', () async {
    final ring = PcmRing(channels: 2, sampleRate: 48000);
    final server = LiveWavServer(ring);
    final uri = await server.start();
    ring.write(0, _ramp(1000, 0));
    // Frames past the live edge keep arriving while the player reads.
    final feeder = Timer.periodic(const Duration(milliseconds: 20), (t) {
      ring.write(ring.endFrame, _ramp(500, ring.endFrame));
    });
    // A real separate client (the phone's player is another process too).
    Future<ProcessResult> curl(List<String> args) =>
        Process.run('curl', ['-s', '--noproxy', '*', '--max-time', '2', ...args, '$uri'],
            stdoutEncoding: null);
    try {
      final seek = await curl(['-D', '-', '-H', 'Range: bytes=${44 + 400}-']);
      final out = seek.stdout as List<int>;
      final text = String.fromCharCodes(out.take(400));
      expect(text, contains('206'));
      expect(text.toLowerCase(), contains('content-range: bytes 444-'));
      final bodyAt = String.fromCharCodes(out).indexOf('\r\n\r\n') + 4;
      final body = Uint8List.fromList(out.sublist(bodyAt, bodyAt + 3000 * 4));
      expect(Int16List.sublistView(body), _ramp(3000, 100));

      final head = (await curl([])).stdout as List<int>;
      expect(String.fromCharCodes(head.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(head.sublist(36, 40)), 'data');
    } finally {
      feeder.cancel();
      ring.close();
      await server.close();
    }
  }, skip: Process.runSync('which', ['curl']).exitCode != 0 ? 'needs curl' : null);
}
