/// A parsed host address a listener can connect to.
class HostAddress {
  const HostAddress({required this.host, required this.port});

  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is HostAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => '$host:$port';
}

/// Parses the join code a host displays into a [HostAddress], or returns
/// `null` if it can't be understood. Accepts, trimmed and case-insensitively
/// for the scheme:
///
/// - `host:port`                      e.g. `192.168.1.5:54213`
/// - `ampme://join?host=..&port=..`   the app's deep-link form
/// - `http://host:port` / `ws://host:port` (any scheme with an authority)
///
/// The port must be present and in 1..65535; the host must be non-empty.
HostAddress? parseJoinCode(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;

  // URI forms: anything with a "scheme://". Covers ampme://, http://, ws://.
  if (raw.contains('://')) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;

    // ampme://join?host=..&port=.. — data lives in query params.
    final qpHost = uri.queryParameters['host'];
    final qpPort = uri.queryParameters['port'];
    if (qpHost != null && qpHost.isNotEmpty && qpPort != null) {
      return _build(qpHost, qpPort);
    }

    // http://host:port / ws://host:port — data lives in the authority.
    if (uri.host.isNotEmpty && uri.hasPort) {
      return _build(uri.host, uri.port.toString());
    }
    return null;
  }

  // Bare `host:port`. rsplit on the last ':' so IPv6-ish inputs don't break
  // the common IPv4/host case.
  final lastColon = raw.lastIndexOf(':');
  if (lastColon <= 0 || lastColon == raw.length - 1) return null;
  return _build(raw.substring(0, lastColon), raw.substring(lastColon + 1));
}

HostAddress? _build(String host, String portStr) {
  final trimmedHost = host.trim();
  final port = int.tryParse(portStr.trim());
  if (trimmedHost.isEmpty || port == null || port < 1 || port > 65535) {
    return null;
  }
  return HostAddress(host: trimmedHost, port: port);
}
