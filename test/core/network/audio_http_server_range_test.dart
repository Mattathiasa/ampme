import 'package:ampme/core/network/audio_http_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseRangeHeader', () {
    const totalLength = 1000;

    test('returns null when no header is present (caller should serve full content)', () {
      expect(parseRangeHeader(null, totalLength), isNull);
    });

    test('parses a fully specified range "bytes=0-499"', () {
      final range = parseRangeHeader('bytes=0-499', totalLength);

      expect(range, isNotNull);
      expect(range!.start, 0);
      expect(range.end, 499);
      expect(range.length, 500);
    });

    test('parses an open-ended range "bytes=500-"', () {
      final range = parseRangeHeader('bytes=500-', totalLength);

      expect(range, isNotNull);
      expect(range!.start, 500);
      expect(range.end, 999);
      expect(range.length, 500);
    });

    test('parses a suffix range "bytes=-500" as the last 500 bytes', () {
      final range = parseRangeHeader('bytes=-500', totalLength);

      expect(range, isNotNull);
      expect(range!.start, 500);
      expect(range.end, 999);
    });

    test('clamps a suffix range longer than the content to the whole file', () {
      final range = parseRangeHeader('bytes=-5000', totalLength);

      expect(range, isNotNull);
      expect(range!.start, 0);
      expect(range.end, 999);
    });

    test('clamps an end beyond the content length to the last byte', () {
      final range = parseRangeHeader('bytes=900-5000', totalLength);

      expect(range, isNotNull);
      expect(range!.start, 900);
      expect(range.end, 999);
    });

    test('throws RangeNotSatisfiableException for a start at/beyond the content length', () {
      expect(
        () => parseRangeHeader('bytes=1000-1005', totalLength),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });

    test('throws RangeNotSatisfiableException when start > end', () {
      expect(
        () => parseRangeHeader('bytes=500-100', totalLength),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });

    test('throws RangeNotSatisfiableException for a unit other than bytes', () {
      expect(
        () => parseRangeHeader('items=0-1', totalLength),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });

    test('throws RangeNotSatisfiableException for a multi-range request', () {
      expect(
        () => parseRangeHeader('bytes=0-99,200-299', totalLength),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });

    test('throws RangeNotSatisfiableException for non-numeric bounds', () {
      expect(
        () => parseRangeHeader('bytes=abc-def', totalLength),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });

    test('throws RangeNotSatisfiableException for a header missing a dash', () {
      expect(
        () => parseRangeHeader('bytes=500', totalLength),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });

    test('throws RangeNotSatisfiableException for an empty suffix ("bytes=-")', () {
      expect(
        () => parseRangeHeader('bytes=-', totalLength),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });

    test('throws RangeNotSatisfiableException when totalLength is zero', () {
      expect(
        () => parseRangeHeader('bytes=0-10', 0),
        throwsA(isA<RangeNotSatisfiableException>()),
      );
    });
  });
}
