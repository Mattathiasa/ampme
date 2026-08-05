import 'dart:io';

/// Best-effort local IPv4 address for this device's WiFi/LAN interface,
/// used both to bind the UDP broadcaster and to put into the session
/// beacon so listeners know where to reach the host's HTTP/WebSocket
/// server. Returns null if no suitable interface is found (e.g. no active
/// network).
///
/// Implemented via `dart:io`'s `NetworkInterface.list()` rather than a
/// dedicated plugin, since this app only needs the IPv4 address (not the
/// SSID), and that keeps the dependency footprint smaller.
Future<String?> getLocalWifiIp() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );

  for (final interface in interfaces) {
    if (!_looksLikeWifiOrLan(interface.name)) continue;
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address.address;
    }
  }

  // Fall back to any non-loopback IPv4 address if no interface matched
  // the expected naming pattern (naming varies across OEMs/emulators).
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address.address;
    }
  }

  return null;
}

bool _looksLikeWifiOrLan(String interfaceName) {
  final name = interfaceName.toLowerCase();
  return name.contains('wlan') || name.contains('wifi') || name.contains('en0');
}
