// A song's own title, artist and cover: the host reads them from the file,
// every device shows them, and the browser's Media Session carries them.
const path = require('path');
const { chromium, BASE, log, enableSemantics, semanticsText, waitForText } = require('./common');

const SONG = path.join(__dirname, '..', '..', '..', 'test', 'fixtures', 'tags', 'tagged.mp3');

(async () => {
  const browser = await chromium.launch({
    args: ['--autoplay-policy=no-user-gesture-required', '--disable-features=WebRtcHideLocalIpsWithMdns'],
  });
  const hostCtx = await browser.newContext({ viewport: { width: 420, height: 1800 }, locale: 'en-US' });
  await hostCtx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(BASE).origin });
  const host = await hostCtx.newPage();
  const l1 = await (await browser.newContext({ viewport: { width: 420, height: 1800 }, locale: 'en-US' })).newPage();
  for (const [name, p] of Object.entries({ host, l1 })) {
    p.on('pageerror', (e) => console.log(name, 'PAGEERROR', (e.stack || e.message).slice(0, 700)));
  }

  await host.goto(BASE);
  await enableSemantics(host);
  await host.getByRole('button', { name: 'Host a Session' }).click();
  await host.waitForTimeout(800);
  await host.getByRole('button', { name: 'Start Session' }).click();
  await waitForText(host, /Copy code/, 20000);
  await host.getByRole('button', { name: 'Copy code' }).click();
  await host.waitForTimeout(300);
  const code = (await host.evaluate(() => navigator.clipboard.readText())).trim();
  const [chooser] = await Promise.all([
    host.waitForEvent('filechooser'),
    host.getByRole('button', { name: /Choose a song/ }).click(),
  ]);
  await chooser.setFiles(SONG);
  await host.getByRole('button', { name: 'Play' }).waitFor({ timeout: 20000 });

  await l1.goto(`${BASE}?join=${encodeURIComponent(code)}`);
  await enableSemantics(l1);
  await waitForText(host, /Ready/, 30000);

  const media = (page) => page.evaluate(() => {
    const m = navigator.mediaSession.metadata;
    if (!m) return null;
    const a = m.artwork[0];
    return { title: m.title, artist: m.artist, artworkType: a && a.type, artworkBytes: a ? Math.round(a.src.length * 0.75) : 0 };
  });

  for (const [name, page] of [['host', host], ['listener', l1]]) {
    await waitForText(page, /Blinding Lights/, 20000);
    const text = await semanticsText(page);
    if (!/The Weeknd/.test(text)) throw new Error(`${name} does not show the artist: ${text.slice(0, 300)}`);
    if (/tagged/.test(text)) throw new Error(`${name} shows the file name instead of the title`);
    const m = await media(page);
    log(name, JSON.stringify(m));
    if (!m || m.title !== 'Blinding Lights' || m.artist !== 'The Weeknd') throw new Error(`${name}: wrong media session ${JSON.stringify(m)}`);
    if (m.artworkType !== 'image/jpeg' || m.artworkBytes < 100 || m.artworkBytes > 60 * 1024) throw new Error(`${name}: bad cover ${JSON.stringify(m)}`);
  }
  log('PASS: title, artist and cover on both devices');
  await browser.close();
})().catch((e) => { console.error('FAIL', e.stack || e.message); process.exit(1); });
