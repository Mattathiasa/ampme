import 'dart:typed_data';

/// Muxes raw Opus packets into an Ogg Opus file (RFC 7845), the format the
/// web host uses to send a video's sound to listeners: small (≈1 MB per
/// minute at 128 kbps), seekable, and played by ExoPlayer and browsers.
class OggOpusWriter {
  OggOpusWriter({
    required this.channels,
    this.preSkip = 312,
    this.inputSampleRate = 48000,
    this.serial = 0x414d504d, // "AMPM"
    this.packetsPerPage = 50, // 1 s of 20 ms frames
  })  : assert(channels == 1 || channels == 2),
        assert(packetsPerPage > 0 && packetsPerPage <= 255);

  final int channels;

  /// Samples (at 48 kHz) the decoder must drop from the start: the encoder's
  /// look-ahead.
  final int preSkip;
  final int inputSampleRate;
  final int serial;
  final int packetsPerPage;

  final BytesBuilder _out = BytesBuilder(copy: false);
  final List<Uint8List> _pending = [];
  int _sequence = 0;
  int _granule = 0;
  bool _headersWritten = false;

  /// Adds one encoded Opus packet carrying [samples48k] samples per channel.
  void addPacket(Uint8List packet, int samples48k) {
    _writeHeaders();
    _pending.add(packet);
    _granule += samples48k;
    if (_pending.length >= packetsPerPage) _flushPage(last: false);
  }

  /// Finishes the stream and returns the whole file. [totalSamples48k] (the
  /// real length of the input) trims the encoder's padding at the end.
  Uint8List finish({int? totalSamples48k}) {
    _writeHeaders();
    if (totalSamples48k != null && totalSamples48k < _granule) {
      _granule = totalSamples48k; // the last page's granule = preSkip + this
    }
    _flushPage(last: true);
    return _out.takeBytes();
  }

  void _writeHeaders() {
    if (_headersWritten) return;
    _headersWritten = true;
    final head = ByteData(19)
      ..setUint8(8, 1) // version
      ..setUint8(9, channels)
      ..setUint16(10, preSkip, Endian.little)
      ..setUint32(12, inputSampleRate, Endian.little)
      ..setInt16(16, 0, Endian.little) // output gain
      ..setUint8(18, 0); // mapping family 0 (mono/stereo)
    final headBytes = head.buffer.asUint8List()..setAll(0, 'OpusHead'.codeUnits);
    _writePage([headBytes], granule: 0, flags: 0x02);

    const vendor = 'Ampme';
    final tags = ByteData(8 + 4 + vendor.length + 4);
    final tagBytes = tags.buffer.asUint8List()..setAll(0, 'OpusTags'.codeUnits);
    tags.setUint32(8, vendor.length, Endian.little);
    tagBytes.setAll(12, vendor.codeUnits);
    tags.setUint32(12 + vendor.length, 0, Endian.little); // no comments
    _writePage([tagBytes], granule: 0, flags: 0);
  }

  void _flushPage({required bool last}) {
    if (_pending.isEmpty && !last) return;
    _writePage(List.of(_pending), granule: preSkip + _granule, flags: last ? 0x04 : 0);
    _pending.clear();
  }

  void _writePage(List<Uint8List> packets, {required int granule, required int flags}) {
    final lacing = <int>[];
    for (final p in packets) {
      var n = p.length;
      while (n >= 255) {
        lacing.add(255);
        n -= 255;
      }
      lacing.add(n);
    }
    if (lacing.length > 255) {
      throw StateError('Ogg page would need ${lacing.length} segments');
    }
    final bodyLength = packets.fold<int>(0, (a, p) => a + p.length);
    final page = Uint8List(27 + lacing.length + bodyLength);
    final view = ByteData.sublistView(page);
    page.setAll(0, 'OggS'.codeUnits);
    view
      ..setUint8(4, 0)
      ..setUint8(5, flags)
      // Two 32-bit halves: dart2js (the web build) has no 64-bit accessors.
      ..setUint32(6, granule & 0xffffffff, Endian.little)
      ..setUint32(10, granule ~/ 0x100000000, Endian.little)
      ..setUint32(14, serial, Endian.little)
      ..setUint32(18, _sequence++, Endian.little)
      ..setUint32(22, 0, Endian.little)
      ..setUint8(26, lacing.length);
    page.setAll(27, lacing);
    var offset = 27 + lacing.length;
    for (final p in packets) {
      page.setAll(offset, p);
      offset += p.length;
    }
    view.setUint32(22, oggCrc(page), Endian.little);
    _out.add(page);
  }
}

final List<int> _crcTable = List<int>.generate(256, (i) {
  var r = i << 24;
  for (var j = 0; j < 8; j++) {
    r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04c11db7) : (r << 1);
    r &= 0xffffffff;
  }
  return r;
});

/// Ogg's page checksum: CRC-32, polynomial 0x04c11db7, no reflection, zero
/// initial value, computed with the checksum field set to zero.
int oggCrc(Uint8List bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc = ((crc << 8) & 0xffffffff) ^ _crcTable[((crc >> 24) & 0xff) ^ b];
  }
  return crc;
}
