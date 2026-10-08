import 'dart:async';

import 'package:realtime_client/realtime_client.dart';

import 'signaling_channel.dart';
import 'signaling_config.dart';

/// A pub/sub room the cloud signaling runs over: every message sent is
/// delivered to every *other* member of the same topic. Abstracted so tests
/// can swap in an in-memory hub for the real Supabase connection.
abstract class BroadcastTransport {
  /// Joins [topic]. Resolves once subscribed; throws [SignalingException] if
  /// the service can't be reached.
  Future<void> join(String topic, void Function(Map<String, dynamic>) onMessage);

  /// Publishes [message] to the other members of the joined topic.
  void broadcast(Map<String, dynamic> message);

  /// Fires if the subscription is lost for good after [join] succeeded.
  Stream<void> get dropped;

  Future<void> leave();
}

/// [BroadcastTransport] over Supabase Realtime broadcast (`wss://`).
class RealtimeBroadcastTransport implements BroadcastTransport {
  RealtimeBroadcastTransport({String? endpoint, String? apiKey})
    : _endpoint = endpoint ?? SignalingConfig.realtimeEndpoint,
      _apiKey = apiKey ?? SignalingConfig.supabaseAnonKey;

  static const _event = 'signal';

  final String _endpoint;
  final String _apiKey;
  final _dropped = StreamController<void>.broadcast();
  RealtimeClient? _client;
  RealtimeChannel? _channel;

  @override
  Stream<void> get dropped => _dropped.stream;

  @override
  Future<void> join(
    String topic,
    void Function(Map<String, dynamic>) onMessage,
  ) async {
    final client = RealtimeClient(_endpoint, params: {'apikey': _apiKey});
    _client = client;
    final channel = client.channel(topic);
    _channel = channel;
    channel.onBroadcast(
      event: _event,
      callback: (raw) {
        // Wire shape is {type: broadcast, event: signal, payload: {...}}.
        final inner = raw['payload'];
        if (inner is Map) onMessage(Map<String, dynamic>.from(inner));
      },
    );
    final subscribed = Completer<void>();
    channel.subscribe((status, error) {
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          if (!subscribed.isCompleted) subscribed.complete();
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.timedOut:
          // Before the first join this is fatal; afterwards the client
          // retries the join on its own.
          if (!subscribed.isCompleted) {
            subscribed.completeError(
              SignalingException(
                'Could not reach the Ampme signaling service'
                '${error == null ? '' : ' ($error)'}. Check your internet '
                'connection.',
              ),
            );
          }
        case RealtimeSubscribeStatus.closed:
          if (subscribed.isCompleted && !_dropped.isClosed) _dropped.add(null);
      }
    });
    try {
      await subscribed.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      await leave();
      throw const SignalingException(
        'Timed out reaching the Ampme signaling service. Check your internet '
        'connection.',
      );
    } catch (_) {
      await leave();
      rethrow;
    }
  }

  @override
  void broadcast(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    // Nest the message under `payload` so the wire format matches every
    // other Supabase client: {type, event, payload}.
    unawaited(
      channel
          .sendBroadcastMessage(event: _event, payload: {'payload': message})
          .catchError((_) => ChannelResponse.error),
    );
  }

  @override
  Future<void> leave() async {
    final client = _client;
    _client = null;
    _channel = null;
    if (client == null) return;
    try {
      await client.removeAllChannels();
      await client.disconnect();
    } catch (_) {
      // Best-effort teardown.
    }
    if (!_dropped.isClosed) await _dropped.close();
  }
}

/// [SignalingChannel] over a cloud pub/sub room (Supabase Realtime by
/// default), so a browser-hosted session is reachable from anywhere — HTTPS
/// pages included — without a LAN relay. Only the WebRTC handshake travels
/// through the cloud; the audio itself flows peer-to-peer.
///
/// All peers of a session share the room `ampme:<code>`. Room messages carry
/// `from`/`to` and each side filters for itself:
///
/// - listener → room `hello{deviceName}` (repeated until answered)
/// - host → listener `host-here{sessionName}` (host also emits
///   `listener-joined` locally, which starts the offer)
/// - offer / answer / ice as in the relay protocol (`ice` is batched on the
///   wire as `ice-batch` to stay well under broadcast rate limits)
/// - listener → host `stats{latencyMs}` every second (playout latency, used by
///   the host to delay its own speaker into sync)
/// - listener → host `bye` on leave; host → room `end` when the session ends
class CloudSignalingChannel implements SignalingChannel {
  CloudSignalingChannel({
    required this.code,
    required this.role,
    required this.selfId,
    this.deviceName = '',
    this.sessionName = '',
    BroadcastTransport? transport,
    this.helloInterval = const Duration(milliseconds: 1500),
    this.findHostTimeout = const Duration(seconds: 8),
    this.iceBatchWindow = const Duration(milliseconds: 80),
  }) : _transport = transport ?? RealtimeBroadcastTransport();

  final String code;
  final SignalingRole role;
  final String selfId;
  final String deviceName;
  final String sessionName;
  final Duration helloInterval;
  final Duration findHostTimeout;
  final Duration iceBatchWindow;
  final BroadcastTransport _transport;

  static const hostId = 'host';

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _disconnected = StreamController<void>.broadcast();
  final _knownListeners = <String>{};
  final _pendingIce = <String, List<Map<String, dynamic>>>{};
  final _iceTimers = <String, Timer>{};
  Completer<Map<String, dynamic>>? _hostFound;
  StreamSubscription<void>? _droppedSub;
  bool _closed = false;

  String get _myAddress => role == SignalingRole.host ? hostId : selfId;

  String get topic => 'ampme:${code.toUpperCase()}';

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Stream<void> get disconnected => _disconnected.stream;

  @override
  Future<Map<String, dynamic>> connect() async {
    await _transport.join(topic, _handleRoomMessage);
    _droppedSub = _transport.dropped.listen((_) {
      if (!_closed && !_disconnected.isClosed) _disconnected.add(null);
    });

    if (role == SignalingRole.host) {
      return {'type': 'welcome', 'code': code, 'sessionName': sessionName};
    }

    // Listener: announce ourselves until the host answers (the first hello
    // can race the subscription becoming live on the server).
    final found = Completer<Map<String, dynamic>>();
    _hostFound = found;
    void hello() => _transport.broadcast({
      'type': 'hello',
      'from': selfId,
      'to': hostId,
      'deviceName': deviceName,
    });
    hello();
    final helloTimer = Timer.periodic(helloInterval, (_) => hello());
    try {
      return await found.future.timeout(findHostTimeout);
    } on TimeoutException {
      await close();
      throw const SignalingException(
        'Session not found. Check the code, and make sure the host still has '
        'the session open.',
      );
    } finally {
      helloTimer.cancel();
    }
  }

  void _handleRoomMessage(Map<String, dynamic> message) {
    if (_closed) return;
    final to = message['to'];
    final type = message['type'];
    // Room-wide messages have no `to`; everything else must be for us.
    if (to != null && to != _myAddress) return;

    if (role == SignalingRole.host) {
      final from = message['from'] as String?;
      if (from == null || from == hostId) return;
      switch (type) {
        case 'hello':
          _transport.broadcast({
            'type': 'host-here',
            'from': hostId,
            'to': from,
            'code': code,
            'sessionName': sessionName,
          });
          if (_knownListeners.add(from)) {
            _emit({
              'type': 'listener-joined',
              'id': from,
              'deviceName': message['deviceName'] ?? 'Unknown device',
            });
          }
        case 'bye':
          if (_knownListeners.remove(from)) {
            _emit({'type': 'listener-left', 'id': from});
          }
        case 'answer':
        case 'stats':
          _emit(message);
        case 'ice-batch':
          _unbatchIce(message);
      }
      return;
    }

    // Listener.
    if (message['from'] != hostId) return;
    switch (type) {
      case 'host-here':
        final found = _hostFound;
        if (found != null && !found.isCompleted) {
          found.complete({
            'type': 'welcome',
            'code': code,
            'sessionName': message['sessionName'] ?? 'Web session',
          });
        }
      case 'offer':
        _emit(message);
      case 'ice-batch':
        _unbatchIce(message);
      case 'end':
        _emit({'type': 'end'});
    }
  }

  void _unbatchIce(Map<String, dynamic> message) {
    final candidates = message['candidates'];
    if (candidates is! List) return;
    for (final candidate in candidates) {
      if (candidate is! Map) continue;
      _emit({
        ...Map<String, dynamic>.from(candidate),
        'type': 'ice',
        'from': message['from'],
      });
    }
  }

  void _emit(Map<String, dynamic> message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  @override
  void send(Map<String, dynamic> message) {
    if (_closed) return;
    final type = message['type'];
    final to = message['to'] as String? ?? (type == 'end' ? null : hostId);
    if (type == 'ice') {
      _queueIce(to ?? hostId, message);
      return;
    }
    _transport.broadcast({
      ...message,
      'from': _myAddress,
      'to': ?to,
    });
    // Candidates gathered while the SDP was being produced go out right
    // behind it instead of waiting for the batch window.
    if (to != null) _flushIce(to);
  }

  void _queueIce(String to, Map<String, dynamic> message) {
    (_pendingIce[to] ??= []).add({
      'candidate': message['candidate'],
      'sdpMid': message['sdpMid'],
      'sdpMLineIndex': message['sdpMLineIndex'],
    });
    _iceTimers[to] ??= Timer(iceBatchWindow, () => _flushIce(to));
  }

  void _flushIce(String to) {
    _iceTimers.remove(to)?.cancel();
    final batch = _pendingIce.remove(to);
    if (batch == null || batch.isEmpty || _closed) return;
    _transport.broadcast({
      'type': 'ice-batch',
      'from': _myAddress,
      'to': to,
      'candidates': batch,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    for (final to in _pendingIce.keys.toList()) {
      _flushIce(to);
    }
    if (role == SignalingRole.listener) {
      _transport.broadcast({'type': 'bye', 'from': selfId, 'to': hostId});
    }
    _closed = true;
    for (final timer in _iceTimers.values) {
      timer.cancel();
    }
    _iceTimers.clear();
    await _droppedSub?.cancel();
    // Give the farewell a moment to leave the socket before tearing down.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _transport.leave();
    await _messages.close();
    await _disconnected.close();
  }
}
