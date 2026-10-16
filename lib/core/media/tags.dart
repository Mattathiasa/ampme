import 'dart:convert';
import 'dart:typed_data';

/// What a song file says about itself: its title and artist, and the cover
/// picture when it carries one.
class TrackTags {
  const TrackTags({this.title, this.artist, this.artwork});

  final String? title;
  final String? artist;

  /// The embedded cover as stored (JPEG or PNG bytes), not yet resized.
  final Uint8List? artwork;

  bool get isEmpty => title == null && artist == null && artwork == null;

  @override
  String toString() =>
      'TrackTags(title: $title, artist: $artist, artwork: ${artwork?.length ?? 0} bytes)';
}

/// Reads the tags of an MP3 (ID3v2), MP4/M4A (iTunes metadata) or FLAC file
/// from [bytes] — the start of the file is enough for MP3 and FLAC; MP4 needs
/// the part that holds its `moov` box. Never throws: a file that is
/// something else, or damaged, simply has no tags.
TrackTags readTags(Uint8List bytes) {
  try {
    if (bytes.length >= 10 && _ascii(bytes, 0, 3) == 'ID3') return _readId3(bytes);
    if (bytes.length >= 4 && _ascii(bytes, 0, 4) == 'fLaC') return _readFlac(bytes);
    if (bytes.length >= 12 && _ascii(bytes, 4, 4) == 'ftyp') return _readMp4(bytes);
  } catch (_) {
    // Damaged or truncated metadata: treat as untagged.
  }
  return const TrackTags();
}

/// Pictures larger than this are ignored; a cover is a thumbnail here.
const int _maxPictureBytes = 8 * 1024 * 1024;

String _ascii(Uint8List b, int offset, int length) =>
    String.fromCharCodes(b.sublist(offset, offset + length));

int _be32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _le32(Uint8List b, int o) => (b[o + 3] << 24) | (b[o + 2] << 16) | (b[o + 1] << 8) | b[o];

String? _clean(String? s) {
  if (s == null) return null;
  final t = s.replaceAll('\u0000', ' ').trim();
  return t.isEmpty ? null : t;
}

// ---- ID3v2 (MP3) ----

TrackTags _readId3(Uint8List b) {
  final major = b[3];
  if (major < 2 || major > 4) return const TrackTags();
  final flags = b[5];
  final tagSize = _syncsafe(b, 6);
  final end = 10 + tagSize > b.length ? b.length : 10 + tagSize;
  var pos = 10;
  if (flags & 0x40 != 0 && major >= 3 && pos + 4 <= end) {
    // Extended header: v2.4 stores its size syncsafe (and counts itself),
    // v2.3 stores it plain (and does not count the size field).
    pos += major == 4 ? _syncsafe(b, pos) : _be32(b, pos) + 4;
  }

  String? title, artist;
  Uint8List? picture;
  var pictureType = -1;
  final idLength = major == 2 ? 3 : 4;
  final headerLength = major == 2 ? 6 : 10;
  while (pos + headerLength <= end) {
    if (b[pos] == 0) break; // padding
    final id = _ascii(b, pos, idLength);
    final size = switch (major) {
      2 => (b[pos + 3] << 16) | (b[pos + 4] << 8) | b[pos + 5],
      3 => _be32(b, pos + 4),
      _ => _syncsafe(b, pos + 4),
    };
    final body = pos + headerLength;
    if (size < 0 || body + size > end) break;
    final frame = Uint8List.sublistView(b, body, body + size);
    switch (id) {
      case 'TIT2' || 'TT2':
        title ??= _clean(_id3Text(frame));
      case 'TPE1' || 'TP1':
        artist ??= _clean(_id3Text(frame));
      case 'APIC' || 'PIC':
        final apic = _id3Picture(frame, short: id == 'PIC');
        // Prefer the front cover (type 3) over other pictures.
        if (apic != null && apic.bytes.length <= _maxPictureBytes) {
          final rank = apic.type == 3 ? 3 : (picture == null ? 0 : -2);
          if (picture == null || rank > pictureType) {
            picture = apic.bytes;
            pictureType = rank;
          }
        }
    }
    pos = body + size;
  }
  return TrackTags(title: title, artist: artist, artwork: picture);
}

int _syncsafe(Uint8List b, int o) =>
    ((b[o] & 0x7f) << 21) | ((b[o + 1] & 0x7f) << 14) | ((b[o + 2] & 0x7f) << 7) | (b[o + 3] & 0x7f);

String? _id3Text(Uint8List frame) {
  if (frame.isEmpty) return null;
  // Several values are separated by NUL; the first is the one shown.
  final text = _decodeText(frame[0], Uint8List.sublistView(frame, 1));
  final nul = text.indexOf('\u0000');
  return nul < 0 ? text : text.substring(0, nul);
}

String _decodeText(int encoding, Uint8List data) {
  switch (encoding) {
    case 1: // UTF-16 with a byte order mark
      if (data.length >= 2 && data[0] == 0xff && data[1] == 0xfe) return _utf16(data, 2, Endian.little);
      if (data.length >= 2 && data[0] == 0xfe && data[1] == 0xff) return _utf16(data, 2, Endian.big);
      return _utf16(data, 0, Endian.little);
    case 2: // UTF-16, big endian, no mark
      return _utf16(data, 0, Endian.big);
    case 3:
      return utf8.decode(data, allowMalformed: true);
    default:
      return latin1.decode(data);
  }
}

String _utf16(Uint8List data, int start, Endian endian) {
  final units = <int>[];
  final view = ByteData.sublistView(data);
  for (var i = start; i + 1 < data.length; i += 2) {
    units.add(view.getUint16(i, endian));
  }
  return String.fromCharCodes(units);
}

({Uint8List bytes, int type})? _id3Picture(Uint8List f, {required bool short}) {
  if (f.length < 4) return null;
  final encoding = f[0];
  var p = 1;
  if (short) {
    p += 3; // "JPG" / "PNG" instead of a MIME type
  } else {
    while (p < f.length && f[p] != 0) {
      p++;
    }
    p++; // the terminator
  }
  if (p >= f.length) return null;
  final type = f[p++];
  // The description ends with a NUL (two for UTF-16).
  final wide = encoding == 1 || encoding == 2;
  if (wide) {
    while (p + 1 < f.length && !(f[p] == 0 && f[p + 1] == 0)) {
      p += 2;
    }
    p += 2;
  } else {
    while (p < f.length && f[p] != 0) {
      p++;
    }
    p++;
  }
  if (p >= f.length) return null;
  return (bytes: Uint8List.fromList(f.sublist(p)), type: type);
}

// ---- FLAC ----

TrackTags _readFlac(Uint8List b) {
  var pos = 4;
  String? title, artist;
  Uint8List? picture;
  var pictureType = -1;
  while (pos + 4 <= b.length) {
    final header = b[pos];
    final last = header & 0x80 != 0;
    final type = header & 0x7f;
    final length = (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];
    final body = pos + 4;
    if (body + length > b.length) break;
    if (type == 4) {
      final comments = _vorbisComments(Uint8List.sublistView(b, body, body + length));
      title ??= _clean(comments['TITLE']);
      artist ??= _clean(comments['ARTIST']);
    } else if (type == 6) {
      final pic = _flacPicture(Uint8List.sublistView(b, body, body + length));
      if (pic != null && pic.bytes.length <= _maxPictureBytes) {
        final rank = pic.type == 3 ? 3 : (picture == null ? 0 : -2);
        if (picture == null || rank > pictureType) {
          picture = pic.bytes;
          pictureType = rank;
        }
      }
    }
    pos = body + length;
    if (last) break;
  }
  return TrackTags(title: title, artist: artist, artwork: picture);
}

Map<String, String> _vorbisComments(Uint8List d) {
  final out = <String, String>{};
  var p = 0;
  if (d.length < 4) return out;
  p += 4 + _le32(d, 0); // vendor
  if (p + 4 > d.length) return out;
  final count = _le32(d, p);
  p += 4;
  for (var i = 0; i < count && p + 4 <= d.length; i++) {
    final len = _le32(d, p);
    p += 4;
    if (len < 0 || p + len > d.length) break;
    final entry = utf8.decode(Uint8List.sublistView(d, p, p + len), allowMalformed: true);
    p += len;
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    out.putIfAbsent(entry.substring(0, eq).toUpperCase(), () => entry.substring(eq + 1));
  }
  return out;
}

({Uint8List bytes, int type})? _flacPicture(Uint8List d) {
  if (d.length < 32) return null;
  final type = _be32(d, 0);
  var p = 4;
  final mimeLength = _be32(d, p);
  p += 4 + mimeLength;
  if (p + 4 > d.length) return null;
  final descriptionLength = _be32(d, p);
  p += 4 + descriptionLength;
  p += 16; // width, height, depth, colours
  if (p + 4 > d.length) return null;
  final dataLength = _be32(d, p);
  p += 4;
  if (dataLength <= 0 || p + dataLength > d.length) return null;
  return (bytes: Uint8List.fromList(d.sublist(p, p + dataLength)), type: type);
}

// ---- MP4 / M4A ----

TrackTags _readMp4(Uint8List b) {
  final moov = _findBox(b, 0, b.length, 'moov');
  if (moov == null) return const TrackTags();
  final udta = _findBox(b, moov.start, moov.end, 'udta');
  if (udta == null) return const TrackTags();
  final meta = _findBox(b, udta.start, udta.end, 'meta');
  if (meta == null) return const TrackTags();
  // `meta` is a "full box": four bytes of version and flags come first.
  final ilst = _findBox(b, meta.start + 4, meta.end, 'ilst');
  if (ilst == null) return const TrackTags();

  String? title, artist;
  Uint8List? picture;
  var pos = ilst.start;
  while (pos + 8 <= ilst.end) {
    final size = _be32(b, pos);
    if (size < 8 || pos + size > ilst.end) break;
    final name = String.fromCharCodes(b.sublist(pos + 4, pos + 8));
    final data = _findBox(b, pos + 8, pos + size, 'data');
    if (data != null && data.end - data.start > 8) {
      // 4 bytes of type, 4 of locale, then the value.
      final value = Uint8List.sublistView(b, data.start + 8, data.end);
      switch (name) {
        case '©nam':
          title ??= _clean(utf8.decode(value, allowMalformed: true));
        case '©ART':
          artist ??= _clean(utf8.decode(value, allowMalformed: true));
        case 'covr':
          if (picture == null && value.length <= _maxPictureBytes) {
            picture = Uint8List.fromList(value);
          }
      }
    }
    pos += size;
  }
  return TrackTags(title: title, artist: artist, artwork: picture);
}

/// The first box called [name] among the boxes between [start] and [end];
/// [start] of the result is where its content begins.
({int start, int end})? _findBox(Uint8List b, int start, int end, String name) {
  var pos = start;
  while (pos + 8 <= end) {
    var size = _be32(b, pos);
    var header = 8;
    if (size == 1) {
      // 64-bit size
      if (pos + 16 > end) return null;
      size = (_be32(b, pos + 8) << 32) | _be32(b, pos + 12);
      header = 16;
    } else if (size == 0) {
      size = end - pos; // runs to the end
    }
    if (size < header) return null;
    final boxEnd = pos + size > end ? end : pos + size;
    if (String.fromCharCodes(b.sublist(pos + 4, pos + 8)) == name) {
      return (start: pos + header, end: boxEnd);
    }
    pos += size;
  }
  return null;
}
