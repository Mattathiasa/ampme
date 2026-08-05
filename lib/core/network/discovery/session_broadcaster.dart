import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/session_beacon.dart';

/// Well-known UDP port both host and listeners agree on at compile time
/// for session discovery beacons.
const int discoveryPort = 45454;

const Duration _beaconInterval = Duration(seconds: 1);

/// Host-side: periodically broadcasts a [SessionBeacon] over UDP so
/// listener devices on the same local network can discover this session.
class SessionBroadcaster {
  RawDatagramSocket? _socket;
  Timer? _timer;

  Future<void> start(SessionBeacon Function() beaconBuilder) async {
    await stop();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    _socket = socket;
    _timer = Timer.periodic(_beaconInterval, (_) => _sendBeacon(beaconBuilder()));
    _sendBeacon(beaconBuilder());
  }

  void _sendBeacon(SessionBeacon beacon) {
    final socket = _socket;
    if (socket == null) return;
    final data = utf8.encode(beacon.toJsonString());
    socket.send(data, InternetAddress('255.255.255.255'), discoveryPort);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}
