import '../models/session_beacon.dart';

/// A session heard on the network, with the last time its beacon arrived so
/// the scanner can expire hosts that go silent. Lives in its own web-safe
/// file (no `dart:io`) so both the native scanner and the web no-op stub can
/// share the type.
class DiscoveredSession {
  DiscoveredSession({required this.beacon, required this.lastSeenAt});

  final SessionBeacon beacon;
  final DateTime lastSeenAt;
}
