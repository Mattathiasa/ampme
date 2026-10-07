#!/usr/bin/env bash
# Drives the Ampme Android app on a running emulator/device (via adb):
# installs the APK, joins the browser-hosted session whose code is in
# CODE_FILE, and checks that the WebRTC stream is playing through Android's
# *media* audio path (not the voice-call path).
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
wait_for 'Live stream' 90 >/dev/null
echo "Joined: the app shows the live stream"

# Let audio flow, then check how Android is playing it.
sleep 12
adb exec-out screencap -p > "$OUT/android-joined.png"
ui > "$OUT/android-joined.xml"
adb logcat -d > "$OUT/logcat.txt"
adb shell dumpsys audio > "$OUT/dumpsys-audio.txt"

if grep -E "FATAL EXCEPTION|AndroidRuntime: Process: $PKG" "$OUT/logcat.txt"; then
  echo "FAIL: the app crashed" >&2
  exit 1
fi

UID_=$(adb shell dumpsys package "$PKG" | grep -m1 -o 'userId=[0-9]*' | cut -d= -f2)
PLAYERS=$(grep -E "AudioPlaybackConfiguration.*u/pid:$UID_/" "$OUT/dumpsys-audio.txt" || true)
echo "Audio players for $PKG (uid $UID_):"
echo "${PLAYERS:-<none>}"

if ! echo "$PLAYERS" | grep -E "state:started" | grep -q "usage=USAGE_MEDIA"; then
  echo "FAIL: no started USAGE_MEDIA player — WebRTC audio isn't playing as media" >&2
  exit 1
fi
if echo "$PLAYERS" | grep -E "state:started" | grep -q "USAGE_VOICE_COMMUNICATION"; then
  echo "FAIL: audio is playing on the voice-call path" >&2
  exit 1
fi
echo "PASS: the APK joined the web-hosted session and is playing media audio"
