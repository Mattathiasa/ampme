import 'dart:typed_data';

import 'package:ampme/core/audio/ogg_opus_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal Ogg page reader for checking what the writer produced.
List<({int flags, int granule, int seq, List<Uint8List> packets})> _pages(Uint8List file) {
  final out = <({int flags, int granule, int seq, List<Uint8List> packets})>[];
  var o = 0;
  while (o < file.length) {
    final v = ByteData.sublistView(file, o);
    expect(String.fromCharCodes(file.sublist(o, o + 4)), 'OggS');
    final segs = file[o + 26];
    final lacing = file.sublist(o + 27, o + 27 + segs);
    final len = lacing.fold<int>(0, (a, b) => a + b);
    final page = Uint8List.fromList(file.sublist(o, o + 27 + segs + len));
    final crc = ByteData.sublistView(page).getUint32(22, Endian.little);
    ByteData.sublistView(page).setUint32(22, 0, Endian.little);
    expect(oggCrc(page), crc, reason: 'page CRC');
    final packets = <Uint8List>[];
    var p = o + 27 + segs;
    final cur = BytesBuilder();
    for (final l in lacing) {
      cur.add(file.sublist(p, p + l));
      p += l;
      if (l < 255) packets.add(cur.takeBytes());
    }
    out.add((
      flags: file[o + 5],
      granule: v.getUint64(6, Endian.little),
      seq: v.getUint32(18, Endian.little),
      packets: packets,
    ));
    o = p;
  }
  return out;
}

void main() {
  test('CRC matches the Ogg reference value', () {
    // CRC-32/OGG check value for "123456789".
    expect(oggCrc(Uint8List.fromList('123456789'.codeUnits)), 0x89a1897f);
  });

  test('headers, pages, granules and end trimming', () {
    final w = OggOpusWriter(channels: 2, preSkip: 312, packetsPerPage: 3);
    for (var i = 0; i < 7; i++) {
      // Includes a packet that needs 255-lacing.
      w.addPacket(Uint8List(i == 2 ? 600 : 100 + i), 960);
    }
    final file = w.finish(totalSamples48k: 7 * 960 - 500);
    final pages = _pages(file);

    expect(String.fromCharCodes(pages[0].packets.single.sublist(0, 8)), 'OpusHead');
    expect(pages[0].packets.single[9], 2);
    expect(ByteData.sublistView(pages[0].packets.single).getUint16(10, Endian.little), 312);
    expect(pages[0].flags, 0x02);
    expect(String.fromCharCodes(pages[1].packets.single.sublist(0, 8)), 'OpusTags');

    final audio = pages.skip(2).toList();
    expect(audio.map((p) => p.packets.length), [3, 3, 1]);
    expect(audio[0].packets[2].length, 600, reason: 'lacing round-trips');
    expect(audio.map((p) => p.granule), [312 + 3 * 960, 312 + 6 * 960, 312 + 7 * 960 - 500]);
    expect(audio.last.flags, 0x04);
    expect(pages.map((p) => p.seq), List.generate(pages.length, (i) => i));
  });
}
