import 'dart:io';

/// Whether [host] is a loopback address or an RFC 1918 private address
/// (`10.x`, `172.16-31.x`, `192.168.x`).
///
/// Ampme is a LAN-only app: the host's HTTP/WebSocket server lives on a
/// private IP, so every cleartext connection the app makes must target one of
/// these ranges. Android's network security config can't express IP ranges
/// (see `android/app/src/main/res/xml/network_security_config.xml`), so this
/// is the enforcement point: join codes, stream URLs and control hosts that
/// point anywhere else are rejected rather than opened.
bool isPrivateNetworkHost(String host) {
  final h = host.trim().toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;

  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((o) => o == null)) return false;
  final a = octets[0]!;
  final b = octets[1]!;
  if (a == 10) return true; // 10.0.0.0/8
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  return false;
}

/// Best-effort local IPv4 address for this device's WiFi/LAN interface,
/// used both to bind the UDP broadcaster and to put into the session
/// beacon so listeners know where to reach the host's HTTP/WebSocket
/// server. Returns null if no suitable interface is found (e.g. no active
/// network).
///
/// Implemented via `dart:io`'s `NetworkInterface.list()` rather than a
/// dedicated plugin, since this app only needs the IPv4 address (not the
/// SSID), and that keeps the dependency footprint smaller.
///
/// The ordering matters for desktop (Windows) hosts, where the first
/// non-loopback adapter is often a VPN or Hyper-V virtual NIC whose address
/// peers can't actually reach: physical WiFi/Ethernet adapters are preferred
/// first, then any RFC 1918 private address, and only as a last resort any
/// address at all.
Future<String?> getLocalWifiIp() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );

  // Preferred: physical WiFi/Ethernet adapters (Windows: "Wi-Fi", "Ethernet";
  // Android: "wlan0"; macOS: "en0"). Naming varies, so any name containing
  // a known LAN keyword wins. Virtual adapters are skipped even here — a
  // Hyper-V/Docker "vEthernet (Default Switch)" matches 'ethernet' but its
  // 172.x address is unreachable by LAN peers (see [_looksVirtual]).
  for (final interface in interfaces) {
    if (_looksVirtual(interface.name)) continue;
    if (!_looksLikeWifiOrLan(interface.name)) continue;
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address.address;
    }
  }

  // Fall back to any private (RFC 1918) address on a non-virtual adapter —
  // the join code must be reachable by LAN peers, so a public/VPN address
  // here is worse than a private one on a misnamed adapter.
  for (final interface in interfaces) {
    if (_looksVirtual(interface.name)) continue;
    for (final address in interface.addresses) {
      if (!address.isLoopback && isPrivateNetworkHost(address.address)) {
        return address.address;
      }
    }
  }

  // Last resort: any non-loopback IPv4 address at all (naming varies
  // across OEMs/emulators, and VPNs are still better than nothing).
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address.address;
    }
  }

  return null;
}

bool _looksLikeWifiOrLan(String interfaceName) {
  final name = interfaceName.toLowerCase();
  return name.contains('wlan') ||
      name.contains('wifi') ||
      name.contains('wi-fi') ||
      name.contains('ethernet') ||
      name.contains('en0');
}

/// Whether [interfaceName] is probably a virtual adapter (VPN, VM, Docker,
/// Hyper-V) whose address LAN peers can't reach. Only used to deprioritize
/// these in the private-address fallback; physical adapters win regardless.
bool _looksVirtual(String interfaceName) {
  final name = interfaceName.toLowerCase();
  return name.contains('virtual') ||
      name.contains('vmware') ||
      name.contains('hyper-v') ||
      name.contains('vethernet') ||
      name.contains('vbox') ||
      name.contains('docker') ||
      name.contains('tailscale') ||
      name.contains('zerotier') ||
      name.contains('tun') ||
      name.contains('tap');
}
