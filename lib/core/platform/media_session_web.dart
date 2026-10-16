import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../network/models/track_info.dart';

String? _shownTrackId;

void showNowPlaying(TrackInfo? track, {String? appName}) {
  try {
    final session = web.window.navigator.mediaSession;
    if (track == null || track.isLive || track.isLiveCapture) {
      _shownTrackId = null;
      session.metadata = null;
      return;
    }
    if (_shownTrackId == track.trackId) return;
    _shownTrackId = track.trackId;
    final cover = track.artwork;
    // A JPEG starts /9j/ in base64; anything else is sent as PNG.
    final type = cover != null && cover.startsWith('/9j/') ? 'image/jpeg' : 'image/png';
    session.metadata = web.MediaMetadata(
      web.MediaMetadataInit(
        title: track.displayTitle,
        artist: track.artist ?? '',
        album: appName ?? 'Ampme',
        artwork: [
          if (cover != null)
            web.MediaImage(src: 'data:$type;base64,$cover', sizes: '200x200', type: type),
        ].toJS,
      ),
    );
  } catch (_) {
    // A browser without the Media Session API.
  }
}
