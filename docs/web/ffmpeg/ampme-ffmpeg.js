// Ampme's bridge to ffmpeg.wasm, loaded on demand (see README.md here).
// window.ampmeExtractAudio(bytes, fileName, coreBase, onProgress, onStatus)
//   -> Promise<Uint8Array>: the file's first audio track as stereo Ogg Vorbis
//   (or 16-bit WAV). Not Opus: libopus in @ffmpeg/core 0.12.10 crashes with
//   "memory access out of bounds"; the app re-encodes to Opus for the phones
//   itself (WebCodecs) anyway.
(function () {
  const here = new URL('.', document.currentScript.src).href;
  let ready = null;

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error('Could not load ' + src));
      document.head.appendChild(s);
    });
  }

  // @ffmpeg/util's toBlobURL, inlined (its UMD build references `exports`
  // and breaks in browsers): the core is fetched cross-origin, then handed
  // to the same-origin worker as a blob: URL.
  async function toBlobURL(url, type) {
    const res = await fetch(url);
    if (!res.ok) throw new Error('Could not download ' + url + ' (' + res.status + ')');
    return URL.createObjectURL(new Blob([await res.arrayBuffer()], { type }));
  }

  function ffmpeg(coreBase, onStatus) {
    if (!ready) {
      ready = (async () => {
        await loadScript(here + 'ffmpeg.js');
        onStatus && onStatus('download');
        const ff = new self.FFmpegWASM.FFmpeg();
        await ff.load({
          coreURL: await toBlobURL(coreBase + 'ffmpeg-core.js', 'text/javascript'),
          wasmURL: await toBlobURL(coreBase + 'ffmpeg-core.wasm', 'application/wasm'),
        });
        return ff;
      })();
      ready.catch(() => { ready = null; }); // let a later attempt retry
    }
    return ready;
  }

  // A failed exec can leave the wasm instance broken: drop it so the next
  // attempt loads a fresh one.
  function discard(ff) {
    try { ff.terminate(); } catch (_) {}
    ready = null;
  }

  async function convert(ff, input, args, out, onProg, onLog) {
    ff.on('log', onLog);
    ff.on('progress', onProg);
    try {
      const code = await ff.exec(['-i', input, '-vn', '-map', '0:a:0', '-ac', '2', ...args, out]);
      if (code !== 0) return null;
      const data = await ff.readFile(out);
      await ff.deleteFile(out).catch(() => {});
      return data;
    } finally {
      ff.off('log', onLog);
      ff.off('progress', onProg);
    }
  }

  window.ampmeExtractAudio = async function (bytes, fileName, coreBase, onProgress, onStatus) {
    const ext = (fileName.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '');
    const input = 'in.' + (ext || 'bin');
    const logs = [];
    const onLog = ({ message }) => { logs.push(message); if (logs.length > 30) logs.shift(); };
    const onProg = ({ progress }) => onProgress && onProgress(Math.max(0, Math.min(1, progress || 0)));
    const attempts = [[['-c:a', 'libvorbis', '-q:a', '6'], 'out.ogg'], [['-c:a', 'pcm_s16le'], 'out.wav']];
    let lastError = null;
    for (const [args, out] of attempts) {
      const ff = await ffmpeg(coreBase, onStatus);
      onStatus && onStatus('convert');
      try {
        await ff.writeFile(input, bytes.slice()); // writeFile transfers (detaches) its buffer
        const data = await convert(ff, input, args, out, onProg, onLog);
        await ff.deleteFile(input).catch(() => {});
        if (data) return data;
      } catch (e) {
        lastError = e;
        discard(ff);
      }
    }
    const hint = logs.filter((l) => /Stream #|Error|Invalid|not found|Unsupported/i.test(l)).slice(-3);
    throw new Error('ffmpeg could not convert it (' +
      (hint.join(' / ') || (lastError && (lastError.message || String(lastError))) || 'unknown error') + ')');
  };
})();
