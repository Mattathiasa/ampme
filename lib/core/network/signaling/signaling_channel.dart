/// Transport-agnostic signaling for browser-hosted (WebRTC) sessions.
///
/// A web-hosted session needs a rendezvous point to exchange the WebRTC
/// handshake (offer/answer/ICE) between the host page and its listeners. Two
/// transports implement it:
///
/// - [CloudSignalingChannel] — Supabase Realtime broadcast over `wss://`.
///   Works from any origin (including HTTPS pages and `flutter run`), so it is
///   the default.
/// - [RelaySignalingChannel] — the LAN relay (`tool/web_relay.dart`) over
///   plain `ws://`, for fully offline / no-cloud setups.
///
/// Both surface the same message shapes the LAN relay always used, so the
/// host and listener controllers don't care which one they're talking to:
///
///   to host:     welcome, listener-joined{id,deviceName}, listener-left{id},
///                answer{from,sdp}, ice{from,candidate,...}
///   to listener: welcome{sessionName}, offer{sdp}, ice{...}, no-host, end,
///                error{message}
///
/// [connect] resolves once `welcome` arrives and throws if the session can't
/// be reached ([SignalingException]).
abstract class SignalingChannel {
  /// Incoming signaling messages (relay protocol shape).
  Stream<Map<String, dynamic>> get messages;

  /// Fires once if the transport drops after [connect] succeeded.
  Stream<void> get disconnected;

  /// Opens the transport and registers this peer. Resolves with the
  /// `welcome` message.
  Future<Map<String, dynamic>> connect();

  /// Sends a signaling message. Messages carry `to` (`'host'` or a listener
  /// id) and, for listeners, `from`.
  void send(Map<String, dynamic> message);

  /// Closes the transport. Safe to call more than once.
  Future<void> close();
}

/// Role a peer plays in a signaling session.
enum SignalingRole { host, listener }

/// Raised when a session can't be reached or was rejected.
class SignalingException implements Exception {
  const SignalingException(this.message);

  final String message;

  @override
  String toString() => message;
}
