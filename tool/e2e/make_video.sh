#!/usr/bin/env bash
# Writes a seekable test video: a moving test pattern with a 1 kHz click
# every 0.5 s (sharp onsets make sync easy to measure). OUT.webm gives
# VP9/Opus (what Playwright's open-source Chromium can decode), OUT.mp4
# gives H.264/AAC (real Chrome, Edge, Safari).
#
# Usage: make_video.sh OUT.(webm|mp4) [SECONDS]
set -euo pipefail
OUT=$1
SECONDS_=${2:-90}
case "$OUT" in
  *.webm) CODECS=(-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 300k -c:a libopus -b:a 128k) ;;
  *) CODECS=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart) ;;
esac
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=${SECONDS_}" \
  -f lavfi -i "aevalsrc='0.8*sin(2*PI*1000*t)*lt(mod(t\,0.5)\,0.01)':s=44100:c=stereo:d=${SECONDS_}" \
  "${CODECS[@]}" -shortest "$OUT"
