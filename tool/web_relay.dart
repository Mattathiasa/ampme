// ignore_for_file: avoid_print

import 'package:ampme/core/network/network_utils.dart';

// Web Relay — the *no-internet* rendezvous point for browser-hosted Ampme
// sessions. By default the web app signals through Supabase Realtime (see
// lib/core/network/signaling/), which works from any page; this relay is the
// fully-local alternative ("Advanced: use a LAN relay" on the host screen).
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
//   listener-> relay {"type":"stats","to":"host","latencyMs":n}   (playout latency, ~1/s)
//   host    -> relay {"type":"end"}
//   relay   -> client{"type":"welcome","code":"...","relayIp":"...","relayPort":n,"sessionName":"..."}
//   relay   -> host  {"type":"listener-joined","id":"...","deviceName":"..."}
//   relay   -> host  {"type":"listener-left","id":"..."}
//   relay   -> client{"type":"no-host"}
//   relay   -> client{"type":"end"}            (session ended / host gone)
//   relay   -> client{"type":"error","message":"..."}
//
// No encryption, LAN-only by design — the same trust model as the rest of
// Ampme: bind it to a machine all participants can reach on the LAN. What it
// does guard: a code can only be re-claimed by the host that holds its
// token, only the host can end a session, a client can only reach its own
// session, and the relay stamps `from` itself (a listener can't pose as
// another). Browser pages from other origins can't open the socket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One static directory served at a URL prefix ('' for root, '/web' for the
/// web app beneath the landing page). Longest prefix wins on a request.
class _StaticRoot {
  const _StaticRoot({required this.prefix, required this.dir});

  final String prefix;
  final String dir;
}

Future<void> main(List<String> args) async {
  // Whatever slips through must not take every session down with it.
  await runZonedGuarded(() => _run(args), (error, stack) {
    print('Relay error (continuing): $error');
  });
}

Future<void> _run(List<String> args) async {
  var port = 8080;
  String? serveDir;
  String? docsDir;
  String? webDir;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[i + 1]) ?? port;
    } else if (args[i] == '--serve' && i + 1 < args.length) {
      serveDir = args[i + 1];
    } else if (args[i] == '--docs' && i + 1 < args.length) {
      docsDir = args[i + 1];
    } else if (args[i] == '--web' && i + 1 < args.length) {
      webDir = args[i + 1];
    } else if (args[i] == '--help' || args[i] == '-h') {
      _printUsage();
      return;
    }
  }

  // Default layout: the landing page (docs/) at the root and the web app
  // (build/web) beneath /web — one URL serves the whole experience over
  // plain HTTP, which is what browsers need to reach LAN devices. `--serve`
  // overrides the root for the old single-root behavior.
  webDir ??= (Directory('build/web').existsSync() ? 'build/web' : null);
  docsDir ??= (Directory('docs').existsSync() ? 'docs' : null);
  final roots = <_StaticRoot>[];
  if (serveDir != null) {
    roots.add(_StaticRoot(prefix: '', dir: serveDir));
  } else if (docsDir != null) {
    roots.add(_StaticRoot(prefix: '', dir: docsDir));
    if (webDir != null) roots.add(_StaticRoot(prefix: '/web', dir: webDir));
  } else if (webDir != null) {
    roots.add(_StaticRoot(prefix: '', dir: webDir));
  }

  final relay = SignalingRelay();
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  server.listen((request) async {
    try {
      await _handleRequest(request, relay, roots);
    } catch (_) {
      // A client that vanished mid-response, a bad upgrade: that request
      // dies, the relay does not.
      try {
        await request.response.close();
      } catch (_) {}
    }
  });

  // Reuse the app's adapter-selection logic (physical adapters first, RFC
  // 1918 preferred, virtual adapters skipped) so the printed URLs are
  // actually reachable by LAN peers.
  final ip = await getLocalWifiIp();
  final hostDisplay = ip ?? 'this machine\'s LAN IP';
  final hasApp = roots.any((r) => r.prefix == '' && r.dir.endsWith('web')) ||
      roots.any((r) => r.prefix == '/web');
  print('''
Ampme web relay running.
  Relay (signaling): ws://$hostDisplay:$port/ws
  Landing page:      http://$hostDisplay:$port/
  Web app:           http://$hostDisplay:$port/web/  ${!hasApp ? '(no web build found — run flutter build web once)' : ''}

To use it (no internet needed):
  1. Open http://$hostDisplay:$port/web/ in a browser on this network.
  2. Host a Session -> "Advanced: use a LAN relay" -> enter $hostDisplay:$port
     -> Start on LAN relay. Listeners join with the code it shows
     (e.g. $hostDisplay:$port/AMP-XXXXXX) or by scanning its QR code.

Note: the web app must be opened over plain HTTP (not HTTPS) to reach LAN
hosts — browsers block "mixed content" otherwise (this is also why the
GitHub Pages copy is a preview only).
''');
  print('Press Ctrl+C to stop.');
}

void _printUsage() {
  print('''
Usage: dart run tool/web_relay.dart [options]
  --port <n>       Port to listen on (default 8080).
  --serve <dir>    Serve this single directory at the root (overrides the
                   docs+web layout below).
  --docs <dir>     Directory of the landing page to serve at the root
                   (default docs/ if it exists).
  --web <dir>      Directory of the Flutter web build to serve at /web/
                   (default build/web if it exists).
  --help           Show this help.
''');
}

Future<void> _handleRequest(
  HttpRequest request,
  SignalingRelay relay,
  List<_StaticRoot> roots,
) async {
  if (WebSocketTransformer.isUpgradeRequest(request) &&
      request.uri.path == '/ws') {
    if (!isAllowedOrigin(request.headers.value('origin'), request.headers.host)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    relay.handleClient(socket);
    return;
  }
  if (roots.isEmpty) {
    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.text
      ..write(
        'Ampme web relay is running (signaling only). '
        'Serve the app with --web build/web (and the landing page with '
        '--docs docs).\n',
      );
    await request.response.close();
    return;
  }
  await _serveStatic(request, roots);
}

Future<void> _serveStatic(HttpRequest request, List<_StaticRoot> roots) async {
  final response = request.response;
  final path = request.uri.path;

  // Longest prefix wins, so /web/... resolves into the web build while
  // everything else falls through to the root (landing page).
  _StaticRoot? best;
  for (final root in roots) {
    if (root.prefix == '') {
      best ??= root;
      continue;
    }
    if (path == root.prefix || path.startsWith('${root.prefix}/')) {
      if (best == null || root.prefix.length > best.prefix.length) best = root;
    }
  }
  if (best == null) {
    response.statusCode = HttpStatus.notFound;
    await response.close();
    return;
  }

  if (path.split('/').contains('..')) {
    response.statusCode = HttpStatus.forbidden;
    await response.close();
    return;
  }
  var relative = best.prefix.isEmpty
      ? (path == '/' ? 'index.html' : path)
      : (path == best.prefix
            ? 'index.html'
            : path.substring(best.prefix.length + 1));
  // Trailing-slash directory requests (e.g. `/web/`) resolve to the index.
  if (relative.isEmpty || relative == '/') relative = 'index.html';
  // Resolve and guard against path traversal.
  final file = File('${best.dir.replaceAll('\\', '/')}/$relative');
  final rootAbs = Directory(best.dir).absolute.path.replaceAll('\\', '/');
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
  response.headers.contentType = contentTypeFor(file.path);
  if (isNoCachePath(file.path)) {
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  }
  await response.addStream(file.openRead());
  await response.close();
}

/// The `Content-Type` to serve [path] with. Browsers act on these: an HTML
/// page served as anything but `text/html` is downloaded instead of shown,
/// stylesheets must be `text/css`, and `application/wasm` is required for
/// streaming WebAssembly compilation (CanvasKit).
ContentType contentTypeFor(String path) {
  final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'html':
    case 'htm':
      return ContentType.html;
    case 'js':
    case 'mjs':
      return ContentType('text', 'javascript', charset: 'utf-8');
    case 'css':
      return ContentType('text', 'css', charset: 'utf-8');
    case 'json':
      return ContentType.json;
    case 'txt':
      return ContentType.text;
    case 'png':
      return ContentType('image', 'png');
    case 'jpg':
    case 'jpeg':
      return ContentType('image', 'jpeg');
    case 'gif':
      return ContentType('image', 'gif');
    case 'ico':
      return ContentType('image', 'x-icon');
    case 'svg':
      return ContentType('image', 'svg+xml');
    case 'wasm':
      return ContentType('application', 'wasm');
    case 'otf':
      return ContentType('font', 'otf');
    case 'ttf':
      return ContentType('font', 'ttf');
    case 'woff':
      return ContentType('font', 'woff');
    case 'woff2':
      return ContentType('font', 'woff2');
    case 'apk':
      return ContentType('application', 'vnd.android.package-archive');
    default:
      return ContentType.binary;
  }
}

/// Whether [path] must be revalidated on every load: the entry points that
/// reference the (content-versioned) rest of a Flutter web build. Without
/// this a rebuilt app can keep loading a stale bootstrap from cache.
bool isNoCachePath(String path) {
  final name = path.split('/').last;
  return name.endsWith('.html') ||
      name == 'flutter_bootstrap.js' ||
      name == 'flutter_service_worker.js' ||
      name == 'sw.js' ||
      name == 'version.json' ||
      name == 'manifest.json';
}

/// Whether a WebSocket upgrade from a page with [origin] may use the relay.
/// Native apps send no Origin. A browser page may if it was served by this
/// relay (same host), or runs on this machine (a dev server); a page from
/// anywhere else could otherwise open sessions on the LAN's behalf.
bool isAllowedOrigin(String? origin, String? requestHost) {
  if (origin == null || origin.isEmpty) return true;
  final host = Uri.tryParse(origin)?.host;
  if (host == null || host.isEmpty) return false;
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]') {
    return true;
  }
  return host == requestHost;
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
  final _random = Random.secure();

  static const maxSessions = 200;
  static const maxListenersPerSession = 100;
  static const maxFrameChars = 64 * 1024;

  void handleClient(WebSocket socket) {
    socket.listen(
      (data) {
        try {
          _handleMessage(socket, data);
        } catch (_) {
          // A frame of the wrong shape is dropped; it can't end the relay.
        }
      },
      onDone: () => _handleClosed(socket),
      onError: (_) => _handleClosed(socket),
      cancelOnError: false,
    );
  }

  /// [value] as a string of 1..[max] characters, else null.
  static String? _text(Object? value, {int max = 100}) =>
      value is String && value.isNotEmpty && value.length <= max ? value : null;

  void _handleMessage(WebSocket socket, dynamic data) {
    if (data is! String || data.length > maxFrameChars) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return; // drop malformed frames
    }
    if (decoded is! Map<String, dynamic>) return;
    final message = decoded;

    switch (message['type']) {
      case 'host':
        _registerHost(socket, message);
      case 'listener':
        _registerListener(socket, message);
      case 'offer':
      case 'answer':
      case 'ice':
      case 'stats':
        _route(socket, message);
      case 'end':
        _endSession(socket);
      default:
        break;
    }
  }

  void _registerHost(WebSocket socket, Map<String, dynamic> message) {
    final code = _text(message['code'], max: 64);
    if (code == null) {
      _send(socket, {'type': 'error', 'message': 'Missing session code.'});
      return;
    }
    final existing = _sessions[code];
    if (existing != null) {
      // Only the host that made the session may take it over again (a
      // retry, a reconnect); anyone else asking for a live code is refused.
      if (message['hostToken'] != existing.hostToken) {
        _send(socket, {'type': 'error', 'message': 'That session code is already in use.'});
        return;
      }
    } else if (_sessions.length >= maxSessions) {
      _send(socket, {'type': 'error', 'message': 'The relay is full.'});
      return;
    }
    final token = existing?.hostToken ?? _newToken();
    _teardown(_sessions.remove(code));
    final name = message['sessionName'];
    final session = _Session(hostToken: token)
      ..host = socket
      ..sessionName = name is String && name.length <= 100 ? name : '';
    _sessions[code] = session;
    _send(socket, {
      'type': 'welcome',
      'code': code,
      'sessionName': session.sessionName,
      'hostToken': token,
      // The page already knows its own host address; keep the fields for
      // future use / diagnostics.
      'relayIp': '',
      'relayPort': 0,
    });
  }

  String _newToken() => List.generate(24, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  void _registerListener(WebSocket socket, Map<String, dynamic> message) {
    final code = _text(message['code'], max: 64);
    final id = _text(message['id']);
    final session = code == null ? null : _sessions[code];
    if (session == null || session.host == null || id == null) {
      _send(socket, {'type': 'no-host'});
      return;
    }
    if (session.listeners.length >= maxListenersPerSession &&
        !session.listeners.containsKey(id)) {
      _send(socket, {'type': 'error', 'message': 'This session is full.'});
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
    final name = message['deviceName'];
    _send(session.host!, {
      'type': 'listener-joined',
      'id': id,
      'deviceName': name is String && name.isNotEmpty && name.length <= 100 ? name : 'Unknown device',
    });
  }

  /// Forwards a handshake message to its recipient inside the sender's own
  /// session, stamped with who really sent it.
  void _route(WebSocket socket, Map<String, dynamic> message) {
    final code = _codeFor(socket);
    final session = code == null ? null : _sessions[code];
    final to = _text(message['to']);
    if (session == null || to == null) return;
    final fromHost = session.host == socket;
    String? senderId;
    if (!fromHost) {
      for (final entry in session.listeners.entries) {
        if (entry.value == socket) senderId = entry.key;
      }
      if (senderId == null) return;
    }
    // Offers come from the host, answers and stats from listeners.
    final type = message['type'];
    if ((type == 'offer' && !fromHost) || ((type == 'answer' || type == 'stats') && fromHost)) {
      return;
    }
    final stamped = jsonEncode({...message, 'from': fromHost ? 'host' : senderId});
    if (to == 'host') {
      if (!fromHost) session.host?.add(stamped);
    } else {
      session.listeners[to]?.add(stamped);
    }
  }

  void _endSession(WebSocket socket) {
    final code = _codeFor(socket);
    final session = code == null ? null : _sessions[code];
    if (session == null || session.host != socket) return; // only the host ends it
    _sessions.remove(code);
    for (final listener in session.listeners.values) {
      _send(listener, {'type': 'end'});
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
  _Session({required this.hostToken});

  /// Proves a later `host` message comes from the host that created the
  /// session; handed out only in that host's welcome.
  final String hostToken;
  WebSocket? host;
  final listeners = <String, WebSocket>{};
  String sessionName = '';
}
