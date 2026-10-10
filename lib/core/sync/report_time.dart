/// When a listener's status report was measured, on the host clock.
///
/// Newer listeners stamp it themselves ([sentAtHostMs], converted with their
/// clock offset — the same offset their own sync loop uses, so host and
/// listener then measure the same drift). Older ones don't, and an
/// implausible stamp (over 5 s off) is ignored: the report is then assumed
/// to be half a round trip old.
int reportTimeMs(int roundTripMs, int receivedAtMs, int? sentAtHostMs) {
  if (sentAtHostMs != null && (receivedAtMs - sentAtHostMs).abs() <= 5000) {
    return sentAtHostMs;
  }
  return receivedAtMs - roundTripMs ~/ 2;
}
