# Ampme

Play a song on one phone and every other phone connected to the same session
plays it back in sync — no cables, no cloud, just the local WiFi network.

**Look & feel:** volt lime (`#D4FF3A`) on ink (`#0B0B0F`) with a matching
light mode. Fonts are bundled, not fetched, so the app looks right on a LAN with
no internet. The visualizer follows the real audio on a browser host; on phones
(whose player exposes no samples) it runs a synthetic beat while playing. It is
throttled to ~30 fps, repaints only itself, and stops when playback stops or the
system asks for reduced motion.

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
  playing, the host re-broadcasts its *measured* playhead once a second.
  A listener more than ~30 ms off plays up to 3 % fast or slow (pitch
  preserved) until it's back; only jumps over ~120 ms are seeked, since
  seeks land imprecisely on many phones. Listeners stamp their status
  reports with when they were measured (host clock), so the drift the host
  shows is what the listener really has, not network delay.
  Clock sync runs continuously (a sample every 2s, plus a burst before every
  scheduled start) so time conversions stay fresh.
- **Ready-ack starts**: before a play/seek, the host asks every listener to
  pre-buffer at the target position (`prepare`), waits for them to confirm
  (`ready`), and only then picks the wall-clock start instant. No device has
  to buffer *after* the scheduled time — the classic cause of "one device
  starts a second late". If a listener never acks, the host proceeds anyway
  and that device falls back to a catch-up seek.

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
  theme/        # "Electric Club" design tokens (AmpTokens) + Material themes
  ui/           # component kit: AmpButton, GlassCard, EqVisualizer, SyncRing,
                # JoinCodeDisplay, SourceTile, DeviceTile, AmpPageRoute…
assets/fonts/   # Space Grotesk, Inter, JetBrains Mono (bundled, OFL)
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

The web build **hosts** sessions and **joins** them, from any copy of the app
— `flutter run -d chrome`, the GitHub Pages copy
(`https://mattathiasa.github.io/ampme/web/`), or a LAN server.

**Hosting from a browser**: a browser can't run the audio/control server a
native host runs (no inbound TCP), so it uses **WebRTC data channels**
instead: it sends the picked song to every listener, then drives playback
with the same sync protocol phone-hosted sessions use — clock sync,
pre-buffering, a start at one scheduled instant, and a position reference
every second for drift correction. Every device (the browser itself, Android
apps, other browsers) plays its own copy in step. The WebRTC handshake goes
through **Supabase Realtime** broadcast
(cloud signaling, `lib/core/network/signaling/`): open the app, **Host a
Session → Start Session**, pick a song, and share the `AMP-XXXXXX` code, the
join link, or the QR code (any phone camera opens the link and joins).
Only the handshake touches the cloud — the song and the sync messages flow
device-to-device.

**Videos**: pick a video (MP4, MOV, WebM, MKV) instead of a song and the
browser host shows the picture while every joined device — the host's own
speakers included — plays its sound in sync, so the phones become extra
speakers for the movie. The picture follows the sound (small drift is
absorbed by a ±5 % playback-rate nudge, larger drift by a seek). Phones get
the **sound only**: the host extracts it and encodes it as Opus (≈1 MB per
minute, WebCodecs in Chrome/Edge/Firefox; a WAV fallback elsewhere), so a
big video doesn't have to travel to every phone and phones never decode a
picture nobody sees. Android writes it to disk, so long films don't sit in
memory. Picks over 1 GB are refused (the browser holds the file). Which formats work
depends on the host browser: Chrome/Edge play MP4 (H.264/AAC), WebM and most
MKVs. When the browser can't decode a video's **sound** (Dolby AC-3/E-AC-3,
DTS — common in MKV movies), the host loads ffmpeg.wasm on first need
(~32 MB from jsdelivr, cached afterwards; see `web/ffmpeg/`) and converts the
first sound track. A picture the browser can't decode (e.g. HEVC) leaves the
session audio-only, with a note. The **full-screen** button (or a double-click)
on the picture puts the synced video in browser full screen; the Android host
opens an immersive landscape view.

The **Android app** can host a video too: it shows the picture and copies the
video's sound track into an audio-only file (no re-encoding — AAC goes to
.m4a, Opus/Vorbis to .webm), which is what the other devices receive. Videos
with another sound codec are sent whole.

**Share a browser tab (YouTube, Spotify Web, …)**: on a computer running
Chrome or Edge, **Share a browser tab** and pick the **tab** (with "Share tab
audio" on) — windows and whole screens carry no sound, so the picker opens on
tabs and hides screens; if nothing comes through the host says why. Live audio can't be copied ahead of time, so every device — the
host included — plays it **1 s behind the tab**, all at the same instant:
the host stamps the captured audio with its clock, streams it (16-bit PCM,
~190 KB/s per listener — fine on WiFi, heavy for many listeners over the
internet) over a third data channel, and each device schedules it on the
shared timeline. Android plays it through a loopback "endless WAV" its
regular player streams; browsers schedule it with WebAudio. The shared tab
is muted locally, and its picture runs that 1 s ahead of the sound.

```sh
flutter run -d chrome     # works out of the box; no relay needed
```

**Joining from a browser**: enter an `AMP-XXXXXX` code or open a join link
(`…/web/?join=AMP-XXXXXX`). Android/Windows apps join the same codes. A
browser can also join a *phone-hosted* session (`192.168.1.5:54213`), but only
when the web app itself is served over plain HTTP on the LAN: browsers block
HTTPS pages from reaching `http://`/`ws://` LAN devices (mixed content), and
the app says so instead of failing silently.

**Cloud signaling config**: the Supabase project URL and publishable anon key
are compiled in (`lib/core/network/signaling/signaling_config.dart`); point at
another project with `--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`.
Only Realtime *broadcast* is used — no tables, no auth. ICE uses Google's
public STUN servers; for devices behind strict NATs on *different* networks,
add a TURN server with `--dart-define=TURN_URL=… TURN_USERNAME=… TURN_CREDENTIAL=…`.

**No-internet option (LAN relay)**: `tool/web_relay.dart` is a tiny local
signaling server that also serves the landing page and the web app over
plain HTTP:

```sh
flutter build web --release --no-web-resources-cdn   # bundle CanvasKit: works offline
dart run tool/web_relay.dart      # or: --port 8080 --docs docs --web build/web
```

Open the printed `http://<lan-ip>:8080/web/`, **Host a Session → Advanced:
use a LAN relay**, enter the relay address and **Start on LAN relay**.
Listeners join with `<relay-ip>:8080/AMP-XXXXXX` or the QR code.

**GitHub Pages**: the web build is committed under `docs/web/`. Rebuild with
`flutter build web --release --no-web-resources-cdn` and copy `build/web/`
over it (`--no-web-resources-cdn` serves CanvasKit from the build instead of
Google's CDN, so the LAN-relay copy also loads with no internet).

Web-hosting notes:

- The song is copied to each device before it can play (a few seconds for a
  typical MP3; the host shows each device's progress, then **Ready** and
  **In sync (±N ms)** while playing). Late joiners get the song and jump in
  at the right spot.
- Listeners need v1.2.0 or newer (older apps expected a live audio stream;
  the host flags them with "Needs the latest Ampme app").
- Each device's speaker/Bluetooth latency isn't visible to the app; if the
  host computer still sounds ahead of (or behind) the phones, nudge **This
  speaker** on the host screen. A single phone that sounds behind (Bluetooth
  speakers especially) has its own **Sync nudge** on its now-playing card
  (−300…+500 ms, saved on that device), or **Calibrate with mic**: the host
  and the phone each play a short chirp in different pitch bands, the phone
  records both and sets the nudge from the gap (median of 3 runs; needs a
  web host — the Android host doesn't play the chirp yet).
- Browsers may block audio until the listener taps the page (autoplay
  policy); the join screen then shows **Tap to start audio**.
- Keep the hosting tab open and visible — browsers throttle background tabs
  (timers/audio), which would let listeners drift.


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

CI (`.github/workflows/android.yml`) runs analyze + tests, builds the APKs,
and runs an end-to-end check on an Android emulator: a session hosted from
the web app (headless Chrome, real Supabase signaling) is joined from the
APK, and the stream must play through Android's media audio path. The
pieces live in `tool/e2e/` and also run locally against any device on
`adb` (`web_host.js` + `android_join.sh`).

```
flutter analyze
flutter test -j 1   # this sandbox's default test concurrency intermittently
                     # drops test files; -j 1 runs them reliably
```
