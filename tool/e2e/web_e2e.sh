#!/usr/bin/env bash
# Browser end-to-end tests of the web app: a host page and listener pages in
# headless Chromium (Playwright), a local stand-in for Supabase Realtime and
# the LAN relay serving the build. Checks sync, resume after a host reload,
# and starting on a song that is still arriving.
#
# Needs: flutter, dart, ffmpeg, node and Playwright (NODE_PATH or
# `npm install --no-save playwright@1.56.1` plus `npx playwright install chromium`).
#
# Usage: tool/e2e/web_e2e.sh [--no-build] [scripts...]
#   scripts: sync resume progressive remove tags (default: all)
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
E2E=$ROOT/tool/e2e
WORK=${E2E_WORK:-$ROOT/build/e2e-work}
BUILD_DIR=$ROOT/build/web-e2e
mkdir -p "$WORK/fixtures" "$WORK/out"
export FIXTURES=$WORK/fixtures OUT=$WORK/out
export NODE_PATH=${NODE_PATH:-/opt/node-tools/node_modules}
export BASE=${BASE:-http://127.0.0.1:8080/web/}

BUILD=1
if [ "${1:-}" = "--no-build" ]; then BUILD=0; shift; fi
SCRIPTS=${*:-sync resume progressive remove tags}

if [ "$BUILD" = 1 ]; then
  # Cloud signaling goes to the local stand-in.
  flutter build web --release --no-web-resources-cdn \
    --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
    --dart-define=AMPME_SYNC_LOG=true
  # (`--output` leaves out the plain files — manifest, service worker,
  # asset manifests — when the folder exists, so copy the default build.)
  mkdir -p "$BUILD_DIR"
  cp -a build/web/. "$BUILD_DIR"/
fi

# Fixtures: a click train (easy to measure), a long tone, and a long
# video (its sound is what listeners get).
F=$FIXTURES
[ -f "$F/clicks.wav" ] || ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "aevalsrc='0.8*sin(2*PI*1000*t)*lt(mod(t\,0.5)\,0.01)':s=48000:c=mono:d=60" "$F/clicks.wav"
[ -f "$F/tone240.wav" ] || python3 "$E2E/make_tone.py" "$F/tone240.wav" 240 440
[ -f "$F/long.webm" ] || AUDIO_ONLY=1 bash "$E2E/make_video.sh" "$F/long.webm" 600

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
dart run "$E2E/fake_realtime.dart" >"$WORK/realtime.log" 2>&1 & PIDS+=($!)
dart run tool/web_relay.dart --port 8080 --docs docs --web "$BUILD_DIR" >"$WORK/relay.log" 2>&1 & PIDS+=($!)
up() { # up URL: any HTTP answer (even 404) means it is listening
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$1" || true)" != 000 ] && return 0
    sleep 1
  done
  echo "not up: $1" >&2; tail -5 "$WORK/relay.log" "$WORK/realtime.log" >&2; return 1
}
up http://127.0.0.1:54321/ && up "$BASE"

FAILED=0
run() { echo "=== $*"; if ! "$@"; then echo "FAILED: $*" >&2; FAILED=1; fi; }
for s in $SCRIPTS; do
  case "$s" in
    sync) run node "$E2E/web/sync_diag.js" ;;
    resume) run node "$E2E/web/resume_e2e.js" ;;
    progressive)
      # The video's sound (MP4, index first) and a WAV both stream; joining
      # first or mid-song.
      run env MODE=fresh SONG=long.webm node "$E2E/web/progressive_e2e.js"
      run env MODE=late SONG=long.webm node "$E2E/web/progressive_e2e.js"
      run env MODE=fresh SONG=tone240.wav node "$E2E/web/progressive_e2e.js"
      run env MODE=late SONG=tone240.wav node "$E2E/web/progressive_e2e.js"
      ;;
    remove) run node "$E2E/web/remove_e2e.js" ;;
    tags) run node "$E2E/web/tags_e2e.js" ;;
    *) echo "unknown script: $s" >&2; exit 2 ;;
  esac
done
[ "$FAILED" = 0 ] && echo "ALL WEB E2E PASSED" || { echo "SOME WEB E2E FAILED" >&2; exit 1; }
