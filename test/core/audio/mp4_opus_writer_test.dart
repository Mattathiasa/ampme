import 'dart:io';
import 'dart:typed_data';

import 'package:ampme/core/audio/mp4_opus_writer.dart';
import 'package:ampme/core/network/growing_file.dart';
import 'package:flutter_test/flutter_test.dart';

/// Top-level and nested boxes by path, e.g. 'moov/trak/mdia/minf/stbl/stco'.
Map<String, (int, int)> _boxes(Uint8List b, [int start = 0, int? end, String prefix = '']) {
  const containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf'};
  final out = <String, (int, int)>{};
  final data = ByteData.sublistView(b);
  var at = start;
  end ??= b.length;
  while (at + 8 <= end) {
    final size = data.getUint32(at);
    final type = String.fromCharCodes(b.sublist(at + 4, at + 8));
    final path = '$prefix$type';
    out[path] = (at, size);
    if (containers.contains(type)) out.addAll(_boxes(b, at + 8, at + size, '$path/'));
    at += size;
  }
  return out;
}

void main() {
  test('index in front, offsets point at each chunk of packets', () {
    final w = Mp4OpusWriter(channels: 2, preSkip: 312);
    final packets = [
      for (var i = 0; i < 120; i++) Uint8List.fromList(List.filled(10 + i % 7, i & 0xff)),
    ];
    for (final p in packets) {
      w.addPacket(p, 960);
    }
    final file = w.finish(totalSamples48k: 120 * 960 - 500);
    final boxes = _boxes(file);
    expect(boxes.keys.take(3), ['ftyp', 'moov', 'moov/mvhd']);
    expect(boxes['moov']!.$1, lessThan(boxes['mdat']!.$1), reason: 'index first');
    expect(isProgressivelyPlayable('audio/mp4', file), isTrue);
    expect(seeksDirectly('audio/mp4'), isTrue);

    final data = ByteData.sublistView(file);
    // stco: 120 packets in chunks of 50 -> 3 chunks at packets 0, 50, 100.
    final (stco, _) = boxes['moov/trak/mdia/minf/stbl/stco']!;
    expect(data.getUint32(stco + 12), 3);
    var expected = boxes['mdat']!.$1 + 8;
    for (var c = 0; c < 3; c++) {
      expect(data.getUint32(stco + 16 + 4 * c), expected);
      expect(file[expected], packets[c * 50][0]);
      for (var i = c * 50; i < (c + 1) * 50 && i < packets.length; i++) {
        expected += packets[i].length;
      }
    }
    // stsz: every packet's size.
    final (stsz, _) = boxes['moov/trak/mdia/minf/stbl/stsz']!;
    expect(data.getUint32(stsz + 16), 120);
    expect(data.getUint32(stsz + 20 + 4 * 7), packets[7].length);
    // Durations: media = all samples; movie = trimmed real length.
    final (mdhd, _) = boxes['moov/trak/mdia/mdhd']!;
    expect(data.getUint32(mdhd + 24), 120 * 960);
    final (mvhd, _) = boxes['moov/mvhd']!;
    expect(data.getUint32(mvhd + 24), 120 * 960 - 500);
    // Pre-skip in the edit list.
    final (elst, _) = boxes['moov/trak/edts/elst']!;
    expect(data.getUint32(elst + 20), 312);
  });

  // The ground truth is a real decoder: remux ffmpeg's own Opus packets and
  // have ffmpeg read, decode and seek the result.
  final haveFfmpeg = Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  test('ffmpeg decodes and seeks the file', () {
    final dir = Directory.systemTemp.createTempSync('ampme_mp4_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ogg = '${dir.path}/src.ogg';
    final out = '${dir.path}/out.m4a';
    final made = Process.runSync('ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
      'sine=frequency=440:duration=5', '-ac', '2', '-c:a', 'libopus', '-b:a', '128k', ogg,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    // Opus packets out of the Ogg pages (the first two pages are headers).
    final b = File(ogg).readAsBytesSync();
    final packets = <Uint8List>[];
    var at = 0, page = 0;
    var cur = <int>[];
    while (at + 27 <= b.length) {
      final segs = b[at + 26];
      var p = at + 27 + segs;
      for (final l in b.sublist(at + 27, at + 27 + segs)) {
        cur.addAll(b.sublist(p, p + l));
        p += l;
        if (l < 255) {
          if (page >= 2) packets.add(Uint8List.fromList(cur));
          cur = [];
        }
      }
      at = p;
      page++;
    }
    expect(packets.length, greaterThan(200));

    final w = Mp4OpusWriter(channels: 2);
    for (final p in packets) {
      w.addPacket(p, 960);
    }
    File(out).writeAsBytesSync(w.finish(totalSamples48k: 5 * 48000));

    final probe = Process.runSync('ffprobe', [
      '-v', 'error', '-show_entries', 'stream=codec_name,channels:format=duration',
      '-of', 'default=nw=1', out,
    ]);
    expect(probe.stdout, contains('codec_name=opus'));
    expect(probe.stdout, contains('channels=2'));
    final duration = double.parse(RegExp(r'duration=([\d.]+)').firstMatch('${probe.stdout}')!.group(1)!);
    expect(duration, closeTo(5.0, 0.1));
    expect(Process.runSync('ffmpeg', ['-v', 'error', '-i', out, '-f', 'null', '-']).stderr, isEmpty);
    expect(
      Process.runSync('ffmpeg', ['-v', 'error', '-ss', '3', '-i', out, '-t', '1', '-f', 'null', '-']).stderr,
      isEmpty,
      reason: 'seeking straight to 3 s',
    );
  }, skip: haveFfmpeg ? false : 'ffmpeg not installed');
}
