/// Pure timing helpers for the web host's synchronized playback (kept free
/// of browser APIs so they can be unit-tested).
library;

/// Shortest gap between deciding to start and the scheduled start instant.
const int minStartLeadMs = 500;

/// Extra margin on top of the slowest listener's round trip, so the play
/// command reaches every device before the instant it names.
const int startLeadMarginMs = 300;

/// How far ahead the scheduled start is set, given each listener's measured
/// round-trip time: the `play` message must arrive before the start instant,
/// otherwise that device has to catch up with a seek.
int startLeadMs(Iterable<int> roundTripsMs) {
  var worst = 0;
  for (final rtt in roundTripsMs) {
    if (rtt > worst) worst = rtt;
  }
  final lead = worst + startLeadMarginMs;
  return lead < minStartLeadMs ? minStartLeadMs : (lead > 3000 ? 3000 : lead);
}

/// How far a listener's playhead is from the host's timeline (ms; positive
/// means the listener is ahead).
///
/// [listenerPositionMs] was measured when the listener sent its report,
/// roughly half a round trip before [receivedAtMs] on the host clock.
/// [hostPositionAt] gives the host timeline position at a host wall time.
int listenerDriftMs({
  required int listenerPositionMs,
  required int roundTripMs,
  required int receivedAtMs,
  required int Function(int hostWallMs) hostPositionAt,
}) {
  final sentAt = receivedAtMs - roundTripMs ~/ 2;
  return listenerPositionMs - hostPositionAt(sentAt);
}

/// MIME type for a picked audio file, by extension (null if unknown — the
/// players sniff the content anyway).
String? audioMimeFor(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (fileName.substring(dot + 1).toLowerCase()) {
    'mp3' => 'audio/mpeg',
    'm4a' || 'mp4' || 'aac' => 'audio/mp4',
    'wav' => 'audio/wav',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'flac' => 'audio/flac',
    'webm' => 'audio/webm',
    _ => null,
  };
}
