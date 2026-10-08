import 'clock_sync.dart';
import 'models/control_message.dart';

/// Reconnection lifecycle reported to the session controller while the link
/// tries to recover from a transient drop (WiFi blip, host briefly
/// backgrounded) before giving up and reporting the host as gone.
enum ReconnectionStatus { attempting, succeeded, failed }

/// Listener-side control connection to a host: carries the sync protocol
/// ([ControlMessage]s) and runs the NTP-style clock sync in the background.
///
/// [ControlClient] implements it over a WebSocket (phone-hosted sessions);
/// [PipeControlLink] over a WebRTC data channel (browser-hosted sessions).
/// [ListenerSessionController] only depends on this surface, so both kinds
/// of session get the same scheduled start and drift correction.
abstract class ControlLink {
  /// Every message except the clock-sync replies, which the link consumes.
  Stream<ControlMessage> get messages;

  /// Fires once the host is really gone (not just briefly unreachable).
  Stream<void> get disconnected;

  /// Emits while a transient drop is being recovered.
  Stream<ReconnectionStatus> get reconnectionStatus;

  ClockSyncEstimate? get clockEstimate;

  /// Number of clock-sync samples collected so far.
  int get syncSampleCount;

  /// Whether the newest clock-sync sample is younger than [within].
  bool isSyncFresh({Duration within = const Duration(milliseconds: 600)});

  /// Restarts the fast clock-sync burst right away (before a scheduled start).
  void syncNow();

  void send(ControlMessage message);

  Future<void> dispose();
}
