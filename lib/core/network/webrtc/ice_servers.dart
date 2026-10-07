/// ICE servers for every Ampme WebRTC peer connection (web host and
/// listeners alike).
///
/// STUN is always on: Chrome hides LAN addresses behind mDNS `.local`
/// candidates, which a native peer can't always resolve, so a server-
/// reflexive candidate is what lets two devices on the same WiFi (or on
/// different networks behind friendly NATs) find each other. Peers behind
/// strict/symmetric NATs on different networks additionally need TURN —
/// supply one at build time:
///
/// ```sh
/// --dart-define=TURN_URL=turn:turn.example.com:3478
/// --dart-define=TURN_USERNAME=... --dart-define=TURN_CREDENTIAL=...
/// ```
const _turnUrl = String.fromEnvironment('TURN_URL');
const _turnUsername = String.fromEnvironment('TURN_USERNAME');
const _turnCredential = String.fromEnvironment('TURN_CREDENTIAL');

const List<String> defaultStunUrls = [
  'stun:stun.l.google.com:19302',
  'stun:stun1.l.google.com:19302',
];

/// The `iceServers` list in the plain-map form both `flutter_webrtc` and the
/// browser's `RTCConfiguration` accept.
List<Map<String, dynamic>> iceServers() => [
  {'urls': defaultStunUrls},
  if (_turnUrl.isNotEmpty)
    {
      'urls': [_turnUrl],
      'username': _turnUsername,
      'credential': _turnCredential,
    },
];
