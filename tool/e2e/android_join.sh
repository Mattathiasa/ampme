#!/usr/bin/env bash
# Drives the Ampme Android app on a running emulator/device (via adb):
# installs the APK, joins the browser-hosted session whose code is in
# CODE_FILE, waits for the song to arrive and play, and checks that it plays
# through Android's *media* audio path (not the voice-call path).
#
# Usage: android_join.sh APK CODE_FILE [OUT_DIR]
set -euo pipefail

APK=$1
CODE_FILE=$2
OUT=${3:-e2e-out}
PKG=com.ampme.app
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

ui() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
  adb shell cat /sdcard/ui.xml 2>/dev/null || true
}

# Waits for a node matching $1 (see android_ui.py) and prints its center.
wait_for() {
  local pattern=$1 timeout=${2:-60}
  for ((i = 0; i < timeout; i += 2)); do
    if xy=$(ui | python3 "$HERE/android_ui.py" "$pattern"); then
      echo "$xy"
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for: $pattern" >&2
  ui > "$OUT/ui-timeout.xml"
  adb exec-out screencap -p > "$OUT/timeout.png" || true
  adb logcat -d > "$OUT/logcat.txt" || true
  # Also print what we saw: artifacts aren't always reachable.
  {
    echo "--- uiautomator dump says:"
    adb shell uiautomator dump /sdcard/ui.xml 2>&1 || true
    echo "--- focused window:"
    adb shell dumpsys window 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" || true
    echo "--- screen text/descriptions:"
    grep -oE 'content-desc="[^"]+"|text="[^"]+"|class="[^"]+EditText"' "$OUT/ui-timeout.xml" | head -n 40 || true
    echo "--- flutter / app logcat (tail):"
    grep -iE "flutter|AndroidRuntime|$PKG" "$OUT/logcat.txt" | tail -n 40 || true
  } >&2
  return 1
}

tap() { adb shell input tap $1; }

CODE=$(tr -d '[:space:]' < "$CODE_FILE")
echo "Joining session $CODE"

adb install -r -g "$APK"
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null

tap "$(wait_for '^Join a Session$' 120)"
tap "$(wait_for 'class:android.widget.EditText' 60)"
adb shell input text "$CODE"
adb shell input keyevent KEYCODE_BACK # close the keyboard
tap "$(wait_for '^Join$' 30)"
wait_for "${TRACK_NAME:-clip\\.webm}" 90 >/dev/null
echo "Joined: the app shows the host's song"
wait_for 'In sync' 120 >/dev/null
echo "Clock synced with the host"

PKG_LINE=$(adb shell pm list packages -U "$PKG" | tr -d '\r')
UID_=$(sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p' <<<"$PKG_LINE" | sed -n 1p)
echo "--- $PKG uid: ${UID_:-<unknown>}"

# The clock syncs as soon as the app joins, but the host only starts playing
# once the whole file has reached this device — over the emulator's NAT that
# can take a while. Wait (bounded) until the app actually has a started
# player, then let it play a little before checking how it plays.
for ((i = 0; i < 180; i += 3)); do
  NOW=$(adb shell dumpsys audio | tr -d '\r')
  STARTED_NOW=$(grep -E "AudioPlaybackConfiguration.*u/pid:${UID_:-none}/.*state:started" <<<"$NOW" || true)
  if [ -n "$STARTED_NOW" ]; then
    echo "Playback started after ~${i}s: $STARTED_NOW"
    break
  fi
  sleep 3
done
sleep 10
# A drift-correction seek briefly flushes the player; look for a started
# media player over a short window rather than a single snapshot.
for ((i = 0; i < 20; i += 2)); do
  adb shell dumpsys audio > "$OUT/dumpsys-audio.txt"
  if grep -qE "u/pid:${UID_:-none}/.*state:started.*USAGE_MEDIA|u/pid:${UID_:-none}/.*state:started.*usage=USAGE_MEDIA" <(tr -d '\r' < "$OUT/dumpsys-audio.txt"); then
    break
  fi
  sleep 2
done
adb exec-out screencap -p > "$OUT/android-joined.png"
ui > "$OUT/android-joined.xml"
adb logcat -d > "$OUT/logcat.txt"

# Everything below avoids `cmd | grep -q` / `grep -m1` pipelines: those exit
# early, the producer gets SIGPIPE, and with `pipefail` the pipeline "fails"
# (silently aborting the script under `set -e`). Capture, then match.
LOGCAT=$(cat "$OUT/logcat.txt")
CRASH=$(grep -E "FATAL EXCEPTION|AndroidRuntime: Process: $PKG" <<<"$LOGCAT" || true)
if [ -n "$CRASH" ]; then
  echo "FAIL: the app crashed:" >&2
  echo "$CRASH" >&2
  exit 1
fi
echo "--- app errors in logcat (flutter / WebRTC), if any:"
grep -iE "flutter.*(error|exception)|webrtc.*(error|fail)" <<<"$LOGCAT" | tail -n 20 || true

AUDIO=$(tr -d '\r' < "$OUT/dumpsys-audio.txt")
PLAYERS=$(grep -E "AudioPlaybackConfiguration.*u/pid:${UID_:-none}/" <<<"$AUDIO" || true)
echo "--- audio players for $PKG:"
if [ -n "$PLAYERS" ]; then
  echo "$PLAYERS"
else
  echo "<none> — all players on the device:"
  grep -E "AudioPlaybackConfiguration" <<<"$AUDIO" | head -n 40 || true
fi

STARTED=$(grep -E "state:started" <<<"$PLAYERS" || true)
if ! grep -q "usage=USAGE_MEDIA" <<<"$STARTED"; then
  echo "--- app screen text:"
  grep -oE 'content-desc="[^"]+"|text="[^"]+"' "$OUT/android-joined.xml" | grep -v '=""' || true
  echo "--- player-related logcat:"
  grep -iE "ExoPlayer|AudioTrack|just_audio|MediaCodec.*(error|fail)|ampme" <<<"$LOGCAT" | grep -viE "verbose" | tail -n 60 || true
  echo "FAIL: no started USAGE_MEDIA player — the song isn't playing as media" >&2
  exit 1
fi
if grep -q "USAGE_VOICE_COMMUNICATION" <<<"$STARTED"; then
  echo "FAIL: audio is playing on the voice-call path" >&2
  exit 1
fi
echo "PASS: the APK joined the web-hosted session and is playing media audio"
