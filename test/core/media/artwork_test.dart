import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ampme/core/media/artwork.dart';
import 'package:ampme/core/network/models/track_info.dart';
import 'package:ampme/features/host/widgets/transport_controls.dart';
import 'package:ampme/core/network/models/playback_state.dart';
import 'package:ampme/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cover = File('test/fixtures/tags/cover.jpg').readAsBytesSync();

  test('a cover is shrunk to a small picture that fits in a message', () async {
    final base64 = await shrinkArtwork(cover);
    expect(base64, isNotNull);
    final bytes = base64Decode(base64!);
    expect(bytes.length, lessThanOrEqualTo(maxArtworkBytes));
    // PNG (phones) or JPEG (browsers): either way a real picture.
    final isPng = bytes[0] == 0x89 && bytes[1] == 0x50;
    final isJpeg = bytes[0] == 0xff && bytes[1] == 0xd8;
    expect(isPng || isJpeg, isTrue);
  });

  test('something that is not a picture gives none', () async {
    expect(await shrinkArtwork(Uint8List.fromList(List.filled(64, 1))), isNull);
  });

  group('TrackInfo', () {
    test('tags travel with the track and older hosts\' tracks still read', () {
      const track = TrackInfo(
        trackId: 't',
        fileName: 'a.mp3',
        streamUrl: '',
        durationMs: 1,
        title: 'Blinding Lights',
        artist: 'The Weeknd',
        artwork: 'QUJD',
      );
      final back = TrackInfo.fromJson(track.toJson());
      expect(back.title, 'Blinding Lights');
      expect(back.artist, 'The Weeknd');
      expect(back.artwork, 'QUJD');

      final old = TrackInfo.fromJson({
        'trackId': 't',
        'fileName': 'a.mp3',
        'streamUrl': '',
        'durationMs': 1,
      });
      expect(old.title, isNull);
      expect(old.toJson().containsKey('artwork'), isFalse);
    });

    test('the title falls back to the file name without its extension', () {
      TrackInfo named(String n, {String? title}) =>
          TrackInfo(trackId: 't', fileName: n, streamUrl: '', durationMs: 1, title: title);
      expect(named('Song.mp3').displayTitle, 'Song');
      expect(named('Mr. Brightside.flac').displayTitle, 'Mr. Brightside');
      expect(named('Mr. Brightside').displayTitle, 'Mr. Brightside');
      expect(named('noextension').displayTitle, 'noextension');
      expect(named('Song.mp3', title: 'Real title').displayTitle, 'Real title');
    });
  });

  testWidgets('the now-playing panel shows the title, the artist and the cover', (tester) async {
    final art = await tester.runAsync(() => shrinkArtwork(cover));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: TransportControls(
            title: 'Blinding Lights',
            artist: 'The Weeknd',
            artwork: art,
            playbackState: PlaybackState.paused,
            position: Duration.zero,
            duration: const Duration(minutes: 3),
          ),
        ),
      ),
    );
    expect(find.text('Blinding Lights'), findsOneWidget);
    expect(find.text('The Weeknd'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });
}
