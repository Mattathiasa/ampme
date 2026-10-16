/// Removes what identifies a session or a network from text that leaves the
/// device (crash reports, copied diagnostics): session codes and IPv4
/// addresses. Names people typed are not touched.
String scrubSensitive(String text) => text
    .replaceAll(_sessionCode, 'AMP-******')
    .replaceAll(_ipv4, 'x.x.x.x');

final RegExp _sessionCode = RegExp(r'\bAMP-[A-Z0-9]{4,10}\b', caseSensitive: false);
final RegExp _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
