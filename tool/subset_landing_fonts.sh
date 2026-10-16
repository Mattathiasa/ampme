#!/usr/bin/env bash
# Builds the small WOFF2 fonts the landing page (docs/index.html) and the
# privacy page serve themselves, from the fonts the app already bundles
# (assets/fonts, SIL Open Font License 1.1). Self-hosting keeps the page from
# asking Google's servers for anything. Needs: pip install fonttools brotli
set -euo pipefail
cd "$(dirname "$0")/.."
UNICODES="U+0020-007E,U+00A0-00FF,U+2013,U+2014,U+2018,U+2019,U+201C,U+201D,U+2022,U+2026,U+2190-2199,U+2212,U+221E,U+00B1"
for f in SpaceGrotesk-Medium SpaceGrotesk-Bold Inter-Regular Inter-Medium Inter-SemiBold Inter-Bold JetBrainsMono-Medium JetBrainsMono-Bold; do
  pyftsubset "assets/fonts/$f.ttf" --unicodes="$UNICODES" --flavor=woff2 \
    --layout-features='kern,liga,tnum,calt' --output-file="docs/fonts/$f.woff2"
done
ls -l docs/fonts
