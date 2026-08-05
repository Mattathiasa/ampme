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
  instant — instead of just reacting to "play now" and drifting.

Browse `lib/core/network/` for the sync protocol implementation.

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
hotspot). This is a from-scratch v1: audio source is local files only, and
there's no cloud fallback if devices are on different networks — see the
`AudioEngine` abstraction in `lib/core/audio/` if you want to add a streaming
source later.

## Running tests

```
flutter analyze
flutter test -j 1   # this sandbox's default test concurrency intermittently
                     # drops test files; -j 1 runs them reliably
```
