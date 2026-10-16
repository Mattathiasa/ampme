// Minimal local stand-in for Supabase Realtime (protocol vsn 2.0.0, JSON
// array frames) — just enough for broadcast channels: phx_join, heartbeat,
// broadcast fan-out (self:false), phx_leave. Used only for E2E testing in a
// sandbox that can't reach *.supabase.co.
import 'dart:convert';
import 'dart:io';

final members = <String, Map<WebSocket, String?>>{}; // topic -> socket -> joinRef

// DROP_FIRST=answer: lose the first signaling message whose type is that
// (simulates a message lost in the cloud).
final dropFirst = Platform.environment['DROP_FIRST'];
var dropped = false;

void main(List<String> args) async {
  final port = args.isEmpty ? 54321 : int.parse(args.first);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('fake realtime on ws://127.0.0.1:$port/realtime/v1/websocket');
  await for (final req in server) {
    if (req.uri.path == '/realtime/v1/websocket' &&
        WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      stdout.writeln('client connected ${req.uri.query.isNotEmpty ? "(params ok)" : ""}');
      ws.listen((data) => handle(ws, data), onDone: () => drop(ws));
    } else {
      req.response.statusCode = 404;
      await req.response.close();
    }
  }
}

void send(WebSocket ws, List<Object?> frame) => ws.add(jsonEncode(frame));

void handle(WebSocket ws, dynamic data) {
  if (data is! String) return;
  final f = jsonDecode(data) as List;
  final joinRef = f[0] as String?;
  final ref = f[1] as String?;
  final topic = f[2] as String;
  final event = f[3] as String;
  final payload = f[4];
  switch (event) {
    case 'heartbeat':
      send(ws, [null, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}]);
    case 'phx_join':
      (members[topic] ??= {})[ws] = joinRef;
      stdout.writeln('join $topic (${members[topic]!.length} members)');
      send(ws, [joinRef, ref, topic, 'phx_reply', {
        'status': 'ok',
        'response': {'postgres_changes': []},
      }]);
    case 'phx_leave':
      members[topic]?.remove(ws);
      send(ws, [joinRef, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}]);
    case 'broadcast':
      final inner = (payload as Map)['payload'];
      final kind = inner is Map ? inner['type'] : '?';
      stdout.writeln('broadcast $topic $kind -> ${(members[topic]?.length ?? 1) - 1}');
      if (dropFirst != null && !dropped && jsonEncode(inner).contains('"type":"$dropFirst"')) {
        dropped = true;
        stdout.writeln('DROPPED first $dropFirst');
        send(ws, [joinRef, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}]);
        return;
      }
      for (final other in (members[topic] ?? {}).keys) {
        if (other == ws) continue;
        send(other, [null, null, topic, 'broadcast', payload]);
      }
      send(ws, [joinRef, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}]);
    default:
      if (ref != null) {
        send(ws, [joinRef, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}]);
      }
  }
}

void drop(WebSocket ws) {
  for (final m in members.values) {
    m.remove(ws);
  }
}
