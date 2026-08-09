# Ampme

Play a song on one phone and every other phone connected to the same session
plays it back in sync — no cables, no cloud, just the local WiFi network.

## How it works

- **Host a session**: pick a local audio file. The app runs a small HTTP
  server (serving the audio with range-request support so listeners can
  buffer/seek) and broadcasts a discovery beacon over UDP so nearby devices
  can find the session.
- **Join a session**: nearby sessions show up automatically. Joining opens a
  WebSocket control connection to the host and runs an NTP-style clock-sync
  exchange to estimate the offset between the two devices' clocks.
- **Staying in sync**: when the host plays, pauses, or seeks, it broadcasts a
  command carrying the exact host wall-clock time playback should start at.
  Each listener converts that to its own local time using the estimated
  clock offset, pre-buffers, and fires playback from a precise timer at that
  instant — instead of just reacting to "play now" and drifting. While
  playing, the host re-broadcasts its *measured* playhead once a second and
  listeners apply tiny (~30ms) corrections, so drift never grows audible.
  Clock sync runs continuously (a sample every 2s, plus a burst before every
  scheduled start) so time conversions stay fresh.

Browse `lib/core/network/` for the sync protocol implementation.

## Live audio sources

Besides picked files, the host can broadcast **live** audio that listeners
play as a real-time stream (no seeking, no position sync):

- **Amplify the room** — the host's microphone (works on every platform).
- **Broadcast device audio** — whatever the device itself is playing, from
  *any* app, with no file selected. Android 10+ only, via MediaProjection:
  the system shows a consent dialog per session and a notification while
  capturing. Apps that opt out of playback capture (`allowAudioPlaybackCapture="false"`,
  e.g. Spotify) and DRM-protected content are silently excluded.


## Project layout

```
lib/
  core/
    audio/      # AudioEngine abstraction + just_audio implementation
    network/    # discovery, control protocol, clock sync, HTTP audio server
    permissions/
    session/    # HostSessionController / ListenerSessionController
  features/
    home/, host/, join/   # screens + view models
test/
  core/network/  # unit tests for clock sync math, message (de)serialization,
                 # and HTTP range parsing — the parts with no UI to click
```

## Getting started

```
flutter pub get
flutter run            # requires an Android device/emulator on the same WiFi
```

Host and listener devices must be on the same WiFi network (or one device's
hotspot). This is a from-scratch v1: audio sources are local files, the
microphone, and (on Android 10+) captured device audio; there's no cloud
fallback if devices are on different networks — see the `AudioEngine`
abstraction in `lib/core/audio/` if you want to add a streaming source later.

### Windows desktop

Ampme runs on Windows too — a PC can be the host, another Windows PC (or any
phone on the same network) can join, with the same sync guarantees.

Prerequisites:

- Visual Studio 2022 with the **Desktop development with C++** workload
  (and the Windows 10/11 SDK).
- First launch on a host/listener PC: Windows Firewall prompts to allow
  inbound connections — accept it, or listeners can't reach the host's
  audio/control server.

Run or build it like any desktop Flutter app:

```sh
flutter run -d windows
flutter build windows --release
```

Windows-specific notes:

- Playback uses `just_audio_windows` (WinRT MediaPlayer); there's no
  background/notification service on desktop, which is fine — the window
  staying open is what keeps playback alive.
- No camera, so the join screen hides QR scanning on desktop; join by code
  or by tapping a discovered session.
- Desktop has no runtime permission prompts: the file picker and the
  microphone recorder surface their own errors (the mic needs to be enabled
  in Windows privacy settings for "amplify the room").
- The host advertises the best private-LAN address it finds (`getLocalWifiIp`
  in `lib/core/network/network_utils.dart` skips virtual adapters like
  Hyper-V/VPN NICs); if the join code ever points at the wrong adapter, join
  manually by code.

### Web (browser)

The web build can **join** any session (with the same tight sync as native
listeners) and can **host** its own sessions.

**Joining from a browser** works like any other listener: enter the host's
code (`192.168.1.5:54213`) and the browser streams + syncs exactly like the
native apps. The one constraint is **mixed content**: the web app must be
served over plain HTTP (not HTTPS) to reach `http://192.168.x.x` LAN hosts
(browsers block HTTPS → HTTP). The relay below serves the app over HTTP, so
this is automatic.

**Hosting from a browser** is different under the hood, because a browser
can't run the audio/control server a native host runs (no inbound TCP).
Instead the browser plays the picked file with WebAudio and streams it to
every joined listener over **WebRTC** (~30-80ms latency on a LAN), using a
tiny **relay** on the LAN just for the connection handshake. The relay also
serves the web app, so the whole flow is one command:

```sh
flutter build web                 # once, after code changes
dart run tool/web_relay.dart      # serves the app + runs signaling
# or: dart run tool/web_relay.dart --port 8080 --serve build/web
```

Then open the printed `http://<lan-ip>:8080` on the hosting machine and
click **Host a Session**. Listeners join by entering the code shown
(`<relay-ip>:8080/AMP-XXXX` — relay address + session token) in the native
app's join-by-code field.

Web-hosting notes:

- Sessions are **live**: listeners can't seek, and there's no position
  sync/clock-sync (the audio arrives in real time over WebRTC). The host's
  own playback is delayed ~60ms to roughly match what listeners hear.
- The web host can also be joined by other browsers (WebRTC works
  browser-to-browser too).
- Keep the hosting tab open and visible — browsers throttle background tabs
  (timers/audio), which would let listeners drift.
- `dart run tool/web_relay.dart --port 8080` alone runs signaling-only if
  you're serving the web build some other way.


## Production setup

### Crash reporting (Sentry)

```sh
flutter run --dart-define=SENTRY_DSN=https://<key>@o<org>.ingest.sentry.io/<project>
flutter build apk --release --dart-define=SENTRY_DSN=https://<key>@o<org>.ingest.sentry.io/<project>
```

Without `SENTRY_DSN` the app runs exactly as before — errors are still logged
locally, they're just not sent anywhere. Optionally set
`SENTRY_ENVIRONMENT` too.

### Signing a release build

Export these before building (the keystore itself never lives in the repo):

```sh
export KEYSTORE_PATH=/path/to/upload-keystore.jks
export KEYSTORE_PASSWORD=...
export KEY_ALIAS=...
export KEY_PASSWORD=...
flutter build apk --release
```

If the variables are missing, release builds fall back to the debug keystore
so `flutter run --release` still works locally — but Play Store uploads will
be rejected until the real keystore is configured. Release builds run R8
minification with rules in `android/app/proguard-rules.pro`.

### App icon & splash screen

The artwork is generated programmatically so it stays in sync with the brand
palette. To regenerate:

```sh
dart run tool/generate_app_icon.dart   # renders assets/icon + assets/splash
dart run flutter_launcher_icons        # writes Android mipmaps
dart run flutter_native_splash:create  # writes the native splash
```

### Network security

`android/app/src/main/res/xml/network_security_config.xml` centralizes the
cleartext policy. Android's network security config **cannot express IP
ranges** (no CIDR), so the "cleartext to private LAN IPs only" policy is
enforced in code instead — every URL the app opens is validated against the
RFC 1918 ranges (`isPrivateNetworkHost` in `lib/core/network/network_utils.dart`),
and join codes pointing at non-private hosts are rejected.

### Other production behaviours

- **Auto-reconnect**: a transient WiFi blip reconnects the control channel
  with exponential backoff (1s/2s/4s) instead of immediately showing
  "host left"; the join screen shows a reconnecting banner meanwhile.
- **Audio focus**: a phone call or another media app pauses playback (host
  tells listeners too) and a temporary interruption resumes it in sync.
- **Permissions**: permanently denied camera/mic/audio permissions explain
  why they're needed and offer "Open Settings".

## Running tests

```
flutter analyze
flutter test -j 1   # this sandbox's default test concurrency intermittently
                     # drops test files; -j 1 runs them reliably
```
