import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';

import '../../core/network/signaling/cloud_signaling_channel.dart';
import '../../core/network/signaling/relay_signaling_channel.dart';
import '../../core/network/signaling/signaling_channel.dart';
import '../../core/observability/reporting.dart';
import '../../core/platform/session_keep_alive.dart';
import '../../utils/join_code.dart';
import 'session_resume_store.dart';
import 'sync_math.dart';
import 'web_host_controller.dart';

/// UI-facing wrapper around [WebHostController] for the web host screen:
/// session start (cloud or LAN relay), file picking (bytes on web), and
/// error surfacing.
class WebHostViewModel extends ChangeNotifier {
  WebHostViewModel() : hostController = WebHostController() {
    hostController.addListener(notifyListeners);
  }

  final WebHostController hostController;

  bool isStarting = false;
  bool isPickingFile = false;

  bool get isRunning => hostController.isRunning;

  /// Starts a session signaled through the cloud (Supabase Realtime): works
  /// from any page, and listeners join with just the `AMP-` code or link.
  Future<void> startCloudSession(String sessionName) {
    final code = generateCloudSessionCode();
    final name = _nameOrDefault(sessionName);
    return _start(
      signaling: CloudSignalingChannel(
        code: code,
        role: SignalingRole.host,
        selfId: CloudSignalingChannel.hostId,
        sessionName: name,
      ),
      name: name,
      code: code,
      joinCode: code,
      joinLink: buildJoinLink(Uri.base, code),
      resumable: true,
    );
  }

  /// A session this page was hosting before a reload (or crash), if recent.
  ResumeInfo? resumable = SessionResumeStore.load();

  /// Picks the saved session back up: same code (listeners are waiting and
  /// reconnect by themselves), same song, same point in it.
  Future<void> resume() async {
    final info = resumable;
    if (info == null) return;
    resumable = null;
    hostController.unlockAudio();
    isStarting = true;
    notifyListeners();
    final bytes = info.trackId == null ? null : await SessionResumeStore.loadTrackBytes();
    if (bytes != null) {
      // Before announcing: listeners' welcome then carries the song.
      await hostController.loadTrack(bytes, info.fileName ?? 'Song', trackId: info.trackId);
    }
    await _start(
      signaling: CloudSignalingChannel(
        code: info.code,
        role: SignalingRole.host,
        selfId: CloudSignalingChannel.hostId,
        sessionName: info.name,
      ),
      name: info.name,
      code: info.code,
      joinCode: info.joinCode,
      joinLink: info.joinLink,
      resumable: true,
    );
    if (bytes != null && hostController.isRunning) {
      await hostController.resumePlayback(
        positionMs: info.positionMs,
        wallMs: info.wallMs,
        playing: info.playing,
      );
    }
  }

  /// Forgets the saved session (listeners still waiting give up on their own).
  void discardResume() {
    SessionResumeStore.clear();
    resumable = null;
    notifyListeners();
  }

  /// Starts a session signaled through a LAN relay at [relayAddress]
  /// (`ip:port`, as printed by `dart run tool/web_relay.dart`). No internet
  /// needed, but the page must be served over plain HTTP.
  Future<void> startRelaySession(String sessionName, String relayAddress) {
    final address = parseJoinCode(relayAddress);
    if (address == null) {
      hostController.errorMessage =
          'Enter the relay address as ip:port (e.g. 192.168.1.10:8080).';
      notifyListeners();
      return Future.value();
    }
    final code = generateCloudSessionCode();
    final name = _nameOrDefault(sessionName);
    final joinCode = '${address.host}:${address.port}/$code';
    return _start(
      signaling: RelaySignalingChannel(
        relayHost: address.host,
        relayPort: address.port,
        code: code,
        role: SignalingRole.host,
        selfId: 'host',
        sessionName: name,
      ),
      name: name,
      code: code,
      joinCode: joinCode,
      // The relay serves the web app at /web/, so the link opens the LAN
      // copy (plain HTTP — required to reach the relay) and joins.
      joinLink: Uri(
        scheme: 'http',
        host: address.host,
        port: address.port,
        path: '/web/',
        queryParameters: {'join': joinCode},
      ).toString(),
    );
  }

  Future<void> _start({
    required SignalingChannel signaling,
    required String name,
    required String code,
    required String joinCode,
    String? joinLink,
    bool resumable = false,
  }) async {
    isStarting = true;
    this.resumable = null; // a new session replaces the saved one
    hostController.errorMessage = null;
    notifyListeners();
    try {
      await hostController.start(
        signaling: signaling,
        name: name,
        code: code,
        joinCode: joinCode,
        joinLink: joinLink,
        resumable: resumable,
      );
      // A sleeping screen throttles this tab, which would let listeners
      // drift: keep it on while hosting.
      await SessionKeepAlive.start(title: name, text: 'Hosting');
    } on SignalingException catch (e) {
      hostController.errorMessage = 'Couldn’t start the session: ${e.message}';
    } catch (e, st) {
      hostController.errorMessage = 'Couldn’t start the session: $e';
      reportError(e, st, context: 'webHost.startSession');
    } finally {
      isStarting = false;
      notifyListeners();
    }
  }

  static const int _maxFileBytes = 1024 * 1024 * 1024;

  String _nameOrDefault(String name) =>
      name.trim().isEmpty ? 'Ampme session' : name.trim();

  Future<void> pickAndLoadTrack() async {
    isPickingFile = true;
    notifyListeners();
    try {
      // withData: the browser has no file paths, only bytes — and
      // file_picker 11 defaults to not reading them, which made picking a
      // song silently do nothing.
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: pickableExtensions,
        withData: true,
      );
      final picked = result?.files.single;
      if (picked == null) return; // cancelled
      final bytes = picked.bytes;
      if (bytes == null) {
        hostController.errorMessage = 'Could not read that file.';
        return;
      }
      // The browser keeps the file in memory, and every listener downloads
      // all of it before playing.
      if (bytes.length > _maxFileBytes) {
        hostController.errorMessage =
            'That file is ${bytes.length ~/ (1024 * 1024)} MB. Pick one under '
            '${_maxFileBytes ~/ (1024 * 1024)} MB — every device has to download '
            'all of it before playing.';
        return;
      }
      await hostController.loadTrack(bytes, picked.name);
    } catch (e, st) {
      hostController.errorMessage = 'Failed to load track: $e';
      reportError(e, st, context: 'webHost.pickTrack');
    } finally {
      isPickingFile = false;
      notifyListeners();
    }
  }

  Future<void> play() => hostController.play();
  Future<void> pause() => hostController.pause();
  Future<void> seek(Duration position) => hostController.seek(position);
  Future<void> setVolume(double volume) => hostController.setVolume(volume);
  Future<void> setSpeakerOffset(int ms) => hostController.setSpeakerOffset(ms);
  Future<void> end() async {
    await SessionKeepAlive.stop();
    await hostController.end();
  }
  Future<void> startTabShare() => hostController.startTabShare();
  void stopTabShare() => hostController.stopTabShare();

  @override
  void dispose() {
    SessionKeepAlive.stop();
    hostController.removeListener(notifyListeners);
    hostController.dispose();
    super.dispose();
  }
}
