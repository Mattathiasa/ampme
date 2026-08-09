// ignore_for_file: avoid_print

import 'package:ampme/core/network/network_utils.dart';

// Web Relay — the LAN rendezvous point that lets a browser-hosted Ampme
// session signal (and be reached by) native listeners.
//
// Browsers can only make *outbound* connections, so a web host can't run the
// audio/control server a native host does. This tiny program fixes that:
// the web host page and every native listener both connect to this relay
// (outbound, so browsers are fine), and the relay routes the WebRTC
// handshake (offers/answers/ICE) between them. The audio itself then flows
// host -> listener directly over WebRTC, not through the relay, keeping
// latency low.
//
// It doubles as the web app's static server: point it at `build/web` and the
// whole flow is "run one command, open the URL it prints".
//
// Usage:
//   dart run tool/web_relay.dart [--port 8080] [--serve build/web]
//
// Protocol (JSON over the WebSocket at /ws):
//   client -> relay  {"type":"host","code":"AMP-XXXX","sessionName":"..."}
//   client -> relay  {"type":"listener","code":"AMP-XXXX","id":"...","deviceName":"..."}
//   host    -> relay {"type":"offer","to":"<listenerId>","sdp":"..."}
//   listener-> relay {"type":"answer","to":"host","sdp":"..."}
//   either  -> relay {"type":"ice","to":"...","candidate":"...","sdpMid":"...","sdpMLineIndex":n}
//   host    -> relay {"type":"end"}
//   relay   -> client{"type":"welcome","code":"...","relayIp":"...","relayPort":n,"sessionName":"..."}
//   relay   -> host  {"type":"listener-joined","id":"...","deviceName":"..."}
//   relay   -> host  {"type":"listener-left","id":"..."}
//   relay   -> client{"type":"no-host"}
//   relay   -> client{"type":"end"}            (session ended / host gone)
//   relay   -> client{"type":"error","message":"..."}
//
// No authentication, no encryption, LAN-only by design — the same trust
// model as the rest of Ampme. Bind it to a machine all participants can
// reach on the LAN.

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  var port = 8080;
  String? serveDir;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[i + 1]) ?? port;
    } else if (args[i] == '--serve' && i + 1 < args.length) {
      serveDir = args[i + 1];
    } else if (args[i] == '--help' || args[i] == '-h') {
      _printUsage();
      return;
    }
  }
  // Convenience default: serve the Flutter web build if it exists.
  serveDir ??= (Directory('build/web').existsSync() ? 'build/web' : null);

  final relay = SignalingRelay();
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  server.listen((request) => _handleRequest(request, relay, serveDir));

  // Reuse the app's adapter-selection logic (physical adapters first, RFC
  // 1918 preferred, virtual adapters skipped) so the printed URLs are
  // actually reachable by LAN peers.
  final ip = await getLocalWifiIp();
  final hostDisplay = ip ?? 'this machine\'s LAN IP';
  print('''
Ampme web relay running.
  Relay (signaling): ws://$hostDisplay:$port/ws
  Web app:           http://$hostDisplay:$port/${serveDir == null ? '(no --serve dir given — app not served)' : ''}
${serveDir == null ? '' : '  (serving web build from: $serveDir)'}

To use it:
  1. Build the web app once:  flutter build web
  2. Open http://$hostDisplay:$port on the hosting machine's browser.
  3. That page hosts the session; native Ampme apps join it by entering the
     code it shows (relay address + code, e.g. $hostDisplay:$port/AMP-XXXX).

Note: the web app must be opened over plain HTTP (not HTTPS) to reach LAN
hosts — browsers block "mixed content" otherwise.
''');
  print('Press Ctrl+C to stop.');
}

void _printUsage() {
  print('''
Usage: dart run tool/web_relay.dart [options]
  --port <n>       Port to listen on (default 8080).
  --serve <dir>    Directory of the web build to serve (default build/web if
                   it exists). Omit to run signaling-only.
  --help           Show this help.
''');
}

Future<void> _handleRequest(
  HttpRequest request,
  SignalingRelay relay,
  String? serveDir,
) async {
  if (WebSocketTransformer.isUpgradeRequest(request) &&
      request.uri.path == '/ws') {
    final socket = await WebSocketTransformer.upgrade(request);
    relay.handleClient(socket);
    return;
  }
  if (serveDir == null) {
    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.text
      ..write(
        'Ampme web relay is running (signaling only). '
        'Serve the web app with --serve build/web.\n',
      );
    await request.response.close();
    return;
  }
  await _serveStatic(request, serveDir);
}

Future<void> _serveStatic(HttpRequest request, String root) async {
  final response = request.response;
  final relative = request.uri.path == '/' ? 'index.html' : request.uri.path;
  // Resolve and guard against path traversal.
  final file = File('${root.replaceAll('\\', '/')}/$relative');
  final rootAbs = Directory(root).absolute.path.replaceAll('\\', '/');
  final fileAbs = file.absolute.path.replaceAll('\\', '/');
  if (!fileAbs.startsWith('$rootAbs/') && fileAbs != '$rootAbs/index.html') {
    response.statusCode = HttpStatus.forbidden;
    await response.close();
    return;
  }
  if (!await file.exists()) {
    response.statusCode = HttpStatus.notFound;
    await response.close();
    return;
  }
  response.headers.contentType = ContentType(
    'application',
    _extensionToMime(file.path),
  );
  await response.addStream(file.openRead());
  await response.close();
}

String _extensionToMime(String path) {
  final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'html':
      return 'html';
    case 'js':
      return 'javascript';
    case 'css':
      return 'css';
    case 'json':
      return 'json';
    case 'png':
      return 'png';
    case 'jpg':
    case 'jpeg':
      return 'jpeg';
    case 'svg':
      return 'svg+xml';
    case 'wasm':
      return 'wasm';
    case 'otf':
      return 'font-otf';
    case 'ttf':
      return 'font-ttf';
    case 'woff':
      return 'font-woff';
    case 'woff2':
      return 'font-woff2';
    default:
      return 'octet-stream';
  }
}

/// Routes signaling messages between one host and its listeners.
///
/// No idle sweep: once the WebRTC handshake completes, the audio flows
/// host->listener directly and the relay sockets go quiet for the whole
/// session — reaping "idle" sockets would kill live sessions. Stale listeners
/// are instead self-cleaned by the host, which watches each peer's WebRTC
/// connection state.
class SignalingRelay {
  final _sessions = <String, _Session>{};

  void handleClient(WebSocket socket) {
    socket.listen(
      (data) => _handleMessage(socket, data),
      onDone: () => _handleClosed(socket),
      onError: (_) => _handleClosed(socket),
      cancelOnError: false,
    );
  }

  void _handleMessage(WebSocket socket, dynamic data) {
    if (data is! String) return;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return; // drop malformed frames
    }

    switch (message['type']) {
      case 'host':
        _registerHost(socket, message);
      case 'listener':
        _registerListener(socket, message);
      case 'offer':
      case 'answer':
      case 'ice':
        _route(socket, message);
      case 'end':
        _endSession(socket);
      default:
        break;
    }
  }

  void _registerHost(WebSocket socket, Map<String, dynamic> message) {
    final code = message['code'] as String?;
    if (code == null || code.isEmpty) {
      _send(socket, {'type': 'error', 'message': 'Missing session code.'});
      return;
    }
    // A new host for a code supersedes any previous one (page reload, retry).
    _teardown(_sessions.remove(code));
    final session = _Session()
      ..host = socket
      ..sessionName = message['sessionName'] ?? '';
    _sessions[code] = session;
    _send(socket, {
      'type': 'welcome',
      'code': code,
      'sessionName': session.sessionName,
      // The page already knows its own host address; keep the fields for
      // future use / diagnostics.
      'relayIp': '',
      'relayPort': 0,
    });
  }

  void _registerListener(WebSocket socket, Map<String, dynamic> message) {
    final code = message['code'] as String?;
    final id = message['id'] as String?;
    final session = code == null ? null : _sessions[code];
    if (session == null || session.host == null || id == null || id.isEmpty) {
      _send(socket, {'type': 'no-host'});
      return;
    }
    if (session.listeners.containsKey(id)) {
      // Duplicate registration (reconnect) — swap the socket.
      final old = session.listeners[id];
      if (old != null && old != socket) old.close();
    }
    session.listeners[id] = socket;
    _send(socket, {
      'type': 'welcome',
      'code': code,
      'sessionName': session.sessionName,
    });
    _send(session.host!, {
      'type': 'listener-joined',
      'id': id,
      'deviceName': message['deviceName'] ?? 'Unknown device',
    });
  }

  void _route(WebSocket socket, Map<String, dynamic> message) {
    final code = message['code'] as String?;
    final session = code == null ? null : _sessions[code];
    final to = message['to'] as String?;
    if (session == null || to == null) return;
    if (to == 'host') {
      session.host?.add(jsonEncode(message));
    } else {
      session.listeners[to]?.add(jsonEncode(message));
    }
  }

  void _endSession(WebSocket socket) {
    final code = _codeFor(socket);
    final session = code == null ? null : _sessions.remove(code);
    if (session == null) return;
    for (final listener in session.listeners.values) {
      _send(listener, {'type': 'end'});
    }
    if (session.host != null && session.host != socket) {
      _send(session.host!, {'type': 'end'});
    }
    _closeQuietly(session.host);
    for (final listener in session.listeners.values) {
      _closeQuietly(listener);
    }
  }

  void _handleClosed(WebSocket socket) {
    final code = _codeFor(socket);
    if (code == null) return;
    final session = _sessions[code];
    if (session == null) return;
    if (session.host == socket) {
      // The host went away — tell listeners first (while their sockets are
      // still open), then tear everything down.
      _sessions.remove(code);
      for (final listener in session.listeners.values) {
        _send(listener, {'type': 'end'});
      }
      for (final listener in session.listeners.values) {
        _closeQuietly(listener);
      }
    } else {
      final gone = session.listeners.entries
          .where((entry) => entry.value == socket)
          .map((entry) => entry.key)
          .toList();
      for (final id in gone) {
        session.listeners.remove(id);
        session.host?.add(
          jsonEncode({'type': 'listener-left', 'id': id}),
        );
      }
    }
  }

  String? _codeFor(WebSocket socket) {
    for (final entry in _sessions.entries) {
      final session = entry.value;
      if (session.host == socket || session.listeners.values.contains(socket)) {
        return entry.key;
      }
    }
    return null;
  }

  void _teardown(_Session? session) {
    if (session == null) return;
    _closeQuietly(session.host);
    for (final listener in session.listeners.values) {
      _closeQuietly(listener);
    }
  }

  void _closeQuietly(WebSocket? socket) {
    try {
      socket?.close();
    } catch (_) {
      // Already closed.
    }
  }

  void _send(WebSocket socket, Map<String, dynamic> message) {
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      // Socket died mid-write; the onDone handler will clean up.
    }
  }
}

class _Session {
  WebSocket? host;
  final listeners = <String, WebSocket>{};
  String sessionName = '';
}
