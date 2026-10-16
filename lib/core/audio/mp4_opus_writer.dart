import 'dart:typed_data';

/// Packs raw Opus packets into an MP4 (ISO BMFF, "Opus in ISO Base Media
/// File Format"), the format the web host sends a video's sound in.
///
/// The index (`moov`) is written *before* the audio (`mdat`), so a player
/// can seek straight to any moment from the first bytes — which is what
/// lets listeners start on a song that's still arriving. Ogg can't: its
/// players probe across the whole file to seek. Same size as Ogg (Opus at
/// 128 kbps ≈ 1 MB/min); played by Chrome, Firefox, Edge and ExoPlayer.
class Mp4OpusWriter {
  Mp4OpusWriter({required this.channels, this.preSkip = 312, this.inputSampleRate = 48000})
      : assert(channels == 1 || channels == 2);

  final int channels;

  /// Samples (at 48 kHz) the decoder drops from the start: the encoder's
  /// look-ahead. Signalled in `dOps` and by the edit list.
  final int preSkip;
  final int inputSampleRate;

  static const int _timescale = 48000;
  static const int _samplesPerChunk = 50; // about 1 s of 20 ms packets

  final List<Uint8List> _packets = [];
  final List<int> _durations = [];

  /// Adds one encoded Opus packet carrying [samples48k] samples per channel.
  void addPacket(Uint8List packet, int samples48k) {
    _packets.add(packet);
    _durations.add(samples48k);
  }

  /// Returns the whole file. [totalSamples48k] (the real length of the
  /// input) trims the encoder's padding at the end.
  Uint8List finish({int? totalSamples48k}) {
    final mediaDuration = _durations.fold<int>(0, (a, d) => a + d);
    var playDuration = mediaDuration - preSkip;
    if (totalSamples48k != null && totalSamples48k < playDuration) playDuration = totalSamples48k;
    if (playDuration < 0) playDuration = 0;

    final ftyp = _box('ftyp', [
      ..._ascii('isom'),
      ..._u32(0x200),
      ..._ascii('isom'),
      ..._ascii('iso2'),
      ..._ascii('mp41'),
    ]);
    // The chunk offsets depend on the index's own size: build it once with
    // placeholder offsets to measure, then for real.
    final chunkCount = (_packets.length + _samplesPerChunk - 1) ~/ _samplesPerChunk;
    var moov = _moov(mediaDuration, playDuration, List.filled(chunkCount, 0));
    final mdatStart = ftyp.length + moov.length + 8;
    final offsets = <int>[];
    var at = mdatStart;
    for (var i = 0; i < _packets.length; i++) {
      if (i % _samplesPerChunk == 0) offsets.add(at);
      at += _packets[i].length;
    }
    moov = _moov(mediaDuration, playDuration, offsets);

    final mdatLength = at - mdatStart;
    final out = BytesBuilder(copy: false)
      ..add(ftyp)
      ..add(moov)
      ..add(_u32(8 + mdatLength))
      ..add(_ascii('mdat'));
    for (final p in _packets) {
      out.add(p);
    }
    return out.takeBytes();
  }

  Uint8List _moov(int mediaDuration, int playDuration, List<int> chunkOffsets) {
    final matrix = [
      ..._u32(0x00010000), ..._u32(0), ..._u32(0), //
      ..._u32(0), ..._u32(0x00010000), ..._u32(0), //
      ..._u32(0), ..._u32(0), ..._u32(0x40000000),
    ];
    final mvhd = _fullBox('mvhd', 0, 0, [
      ..._u32(0), ..._u32(0), // creation, modification
      ..._u32(_timescale),
      ..._u32(playDuration),
      ..._u32(0x00010000), // rate 1.0
      ..._u16(0x0100), // volume 1.0
      ...List.filled(10, 0),
      ...matrix,
      ...List.filled(24, 0), // pre_defined
      ..._u32(2), // next track id
    ]);
    final tkhd = _fullBox('tkhd', 0, 3, [
      ..._u32(0), ..._u32(0),
      ..._u32(1), // track id
      ..._u32(0),
      ..._u32(playDuration),
      ...List.filled(8, 0),
      ..._u16(0), ..._u16(0), // layer, alternate group
      ..._u16(0x0100), // volume
      ..._u16(0),
      ...matrix,
      ..._u32(0), ..._u32(0), // width, height
    ]);
    // Play from the end of the pre-skip, for the real length.
    final edts = _box('edts', _fullBox('elst', 0, 0, [
      ..._u32(1),
      ..._u32(playDuration),
      ..._u32(preSkip),
      ..._u32(0x00010000),
    ]));
    final mdhd = _fullBox('mdhd', 0, 0, [
      ..._u32(0), ..._u32(0),
      ..._u32(_timescale),
      ..._u32(mediaDuration),
      ..._u16(0x55c4), // language "und"
      ..._u16(0),
    ]);
    final hdlr = _fullBox('hdlr', 0, 0, [
      ..._u32(0),
      ..._ascii('soun'),
      ...List.filled(12, 0),
      ..._ascii('SoundHandler'), 0,
    ]);
    final dOps = _box('dOps', [
      0, // version
      channels,
      ..._u16(preSkip),
      ..._u32(inputSampleRate),
      ..._u16(0), // output gain
      0, // channel mapping family 0 (mono/stereo)
    ]);
    final opus = _box('Opus', [
      ...List.filled(6, 0),
      ..._u16(1), // data reference index
      ...List.filled(8, 0),
      ..._u16(channels),
      ..._u16(16), // sample size
      ..._u16(0), ..._u16(0),
      ..._u32(_timescale << 16),
      ...dOps,
    ]);
    final stsd = _fullBox('stsd', 0, 0, [..._u32(1), ...opus]);

    // Sample durations, run-length coded.
    final stts = <int>[];
    var runs = 0;
    for (var i = 0; i < _durations.length;) {
      var j = i;
      while (j < _durations.length && _durations[j] == _durations[i]) {
        j++;
      }
      stts
        ..addAll(_u32(j - i))
        ..addAll(_u32(_durations[i]));
      runs++;
      i = j;
    }
    final lastChunk = _packets.length % _samplesPerChunk;
    final fullChunks = _packets.length ~/ _samplesPerChunk;
    final stsc = [
      if (fullChunks > 0) ...[..._u32(1), ..._u32(_samplesPerChunk), ..._u32(1)],
      if (lastChunk > 0) ...[..._u32(fullChunks + 1), ..._u32(lastChunk), ..._u32(1)],
    ];
    final stbl = _box('stbl', [
      ...stsd,
      ..._fullBox('stts', 0, 0, [..._u32(runs), ...stts]),
      ..._fullBox('stsc', 0, 0, [..._u32(stsc.length ~/ 12), ...stsc]),
      ..._fullBox('stsz', 0, 0, [
        ..._u32(0),
        ..._u32(_packets.length),
        for (final p in _packets) ..._u32(p.length),
      ]),
      ..._fullBox('stco', 0, 0, [
        ..._u32(chunkOffsets.length),
        for (final o in chunkOffsets) ..._u32(o),
      ]),
    ]);
    final dinf = _box('dinf', _fullBox('dref', 0, 0, [..._u32(1), ..._fullBox('url ', 0, 1, [])]));
    final minf = _box('minf', [..._fullBox('smhd', 0, 0, [0, 0, 0, 0]), ...dinf, ...stbl]);
    final mdia = _box('mdia', [...mdhd, ...hdlr, ...minf]);
    final trak = _box('trak', [...tkhd, ...edts, ...mdia]);
    return _box('moov', [...mvhd, ...trak]);
  }

  static Uint8List _box(String type, List<int> payload) {
    final b = Uint8List(8 + payload.length);
    ByteData.sublistView(b).setUint32(0, b.length);
    b.setAll(4, type.codeUnits);
    b.setAll(8, payload);
    return b;
  }

  static Uint8List _fullBox(String type, int version, int flags, List<int> payload) =>
      _box(type, [version, (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff, ...payload]);

  static List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
  static List<int> _u16(int v) => [(v >> 8) & 0xff, v & 0xff];
  static List<int> _ascii(String s) => s.codeUnits;
}
