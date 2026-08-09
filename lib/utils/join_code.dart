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

/// A parsed address of a browser-hosted (web) session: the LAN relay's
/// address plus the session code it rendezvouses on.
class WebSessionAddress {
  const WebSessionAddress({
    required this.relayHost,
    required this.relayPort,
    required this.code,
  });

  final String relayHost;
  final int relayPort;
  final String code;

  @override
  bool operator ==(Object other) =>
      other is WebSessionAddress &&
      other.relayHost == relayHost &&
      other.relayPort == relayPort &&
      other.code == code;

  @override
  int get hashCode => Object.hash(relayHost, relayPort, code);

  @override
  String toString() => '$relayHost:$relayPort/$code';
}

/// Parses the join code of a web-hosted session into a [WebSessionAddress],
/// or returns `null` if it isn't one. A web code has a session token after a
/// `/` in the authority — e.g. `192.168.1.10:8080/AMP-4821`,
/// `http://192.168.1.10:8080/AMP-4821`, or `ws://.../AMP-4821`.
///
/// Plain `host:port` codes (native sessions) are NOT matched; callers should
/// try this first and fall back to [parseJoinCode].
WebSessionAddress? parseWebSessionCode(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;

  final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
  if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;

  // The session token is the first non-empty path segment.
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  final code = segments.first.trim();
  if (code.isEmpty) return null;

  final port = uri.port;
  if (port < 1 || port > 65535) return null;
  return WebSessionAddress(
    relayHost: uri.host,
    relayPort: port,
    code: code,
  );
}
