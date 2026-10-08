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

/// How the host's `<video>` should follow the audio timeline, given how far
/// the picture is from the sound ([driftMs], positive = picture ahead).
/// Small drift is absorbed by a slightly different playback rate (invisible);
/// large drift by a seek.
({bool seek, double rate}) videoCorrection(int driftMs) {
  final abs = driftMs.abs();
  if (abs > 150) return (seek: true, rate: 1.0);
  if (abs <= 20) return (seek: false, rate: 1.0);
  // Close the gap over roughly two seconds, at most ±5 %.
  final rate = (1 - driftMs / 2000).clamp(0.95, 1.05);
  return (seek: false, rate: rate);
}

const _videoExtensions = {'mp4', 'm4v', 'mov', 'webm', 'mkv'};

/// File extensions the host's picker accepts.
const pickableExtensions = [
  'mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus', 'flac',
  ..._videoExtensions,
];

/// Whether [fileName] is a video (shown on the host, heard on every device).
bool isVideoFile(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot >= 0 && _videoExtensions.contains(fileName.substring(dot + 1).toLowerCase());
}

/// MIME type for a picked audio or video file, by extension (null if unknown — the
/// players sniff the content anyway).
String? audioMimeFor(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (fileName.substring(dot + 1).toLowerCase()) {
    'mp3' => 'audio/mpeg',
    'm4a' || 'aac' => 'audio/mp4',
    'mp4' => 'video/mp4',
    'wav' => 'audio/wav',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'flac' => 'audio/flac',
    'webm' => 'video/webm',
    'm4v' || 'mov' => 'video/mp4',
    'mkv' => 'video/x-matroska',
    _ => null,
  };
}
