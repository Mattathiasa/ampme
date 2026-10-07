import 'dart:math';

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

/// Characters used in cloud session codes: uppercase letters and digits
/// without the easily-confused ones (0/O, 1/I/L).
const _cloudCodeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// Length of the random part of a cloud session code. Cloud sessions share a
/// single global namespace, so this is longer than the 4-character LAN relay
/// codes: 31^6 ≈ 887M combinations.
const cloudCodeLength = 6;

final _cloudCodePattern = RegExp(r'^AMP-[A-Z0-9]{6}$');

/// Generates a fresh cloud session code, e.g. `AMP-7KQ4ZD`.
String generateCloudSessionCode([Random? random]) {
  final rng = random ?? Random.secure();
  final suffix = List.generate(
    cloudCodeLength,
    (_) => _cloudCodeAlphabet[rng.nextInt(_cloudCodeAlphabet.length)],
  ).join();
  return 'AMP-$suffix';
}

/// Parses a cloud (internet-signaled) session code, or returns `null` if
/// [input] isn't one. Accepts, case-insensitively:
///
/// - the bare code: `AMP-7KQ4ZD` (also without the dash: `AMP7KQ4ZD`)
/// - a join link: `https://…/web/?join=AMP-7KQ4ZD`
///
/// Returns the normalized (uppercase, dashed) code.
String? parseCloudSessionCode(String input) {
  var raw = input.trim();
  if (raw.isEmpty) return null;

  if (raw.contains('://') || raw.contains('?')) {
    final uri = Uri.tryParse(raw);
    final join = uri?.queryParameters['join'];
    if (join == null || join.isEmpty) return null;
    raw = join.trim();
  }

  var code = raw.toUpperCase();
  if (code.startsWith('AMP') && !code.startsWith('AMP-')) {
    code = 'AMP-${code.substring(3)}';
  }
  return _cloudCodePattern.hasMatch(code) ? code : null;
}

/// Public copy of the web app, used for join links when the host page itself
/// isn't reachable by other devices (e.g. `flutter run` on localhost).
/// Override with `--dart-define=PUBLIC_WEB_APP_URL=https://…/`.
const publicWebAppUrl = String.fromEnvironment(
  'PUBLIC_WEB_APP_URL',
  defaultValue: 'https://mattathiasa.github.io/ampme/web/',
);

/// Builds the shareable link that opens the web app and joins [code].
///
/// [pageUrl] is the hosting page's own URL. A page on a loopback address
/// (`flutter run`, a local server) can't be opened by other devices, so the
/// link points at [publicWebAppUrl] instead — cloud codes work from any copy
/// of the app.
String buildJoinLink(Uri pageUrl, String code) {
  final host = pageUrl.host.toLowerCase();
  final isLoopback =
      host == 'localhost' || host == '127.0.0.1' || host == '::1' || host.isEmpty;
  final base = isLoopback || !pageUrl.hasScheme || !pageUrl.scheme.startsWith('http')
      ? Uri.parse(publicWebAppUrl)
      : pageUrl;
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: base.path.isEmpty ? '/' : base.path,
    queryParameters: {'join': code},
  ).toString();
}
