Vendored [ffmpeg.wasm](https://github.com/ffmpegwasm/ffmpeg.wasm) wrapper
(MIT): `ffmpeg.js` + its worker chunk `814.ffmpeg.js` from `@ffmpeg/ffmpeg@0.12.15`
(UMD build). `@ffmpeg/util` isn't used: its UMD build is broken in browsers,
and `ampme-ffmpeg.js` inlines the one helper it needs. They live here, served
from the same origin as the app, because browsers only start a Worker from
the page's own origin.

The converter itself (`@ffmpeg/core@0.12.10`, ~32 MB, GPL-2.0-or-later) is not
in this repository: `ampme-ffmpeg.js` fetches it from jsdelivr the first time a
video's sound can't be decoded by the browser (Dolby/DTS MKVs, mostly), and the
browser caches it.
