// Device names and removal: a listener sets its own name through the join
// screen, the host sees it, removes the device, and the device stays out.
const {
  chromium, BASE, SONG, log, enableSemantics, semanticsText, waitForText,
} = require('./common');

const NAME = 'Kitchen speaker';

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
  log('code', code);
  const [chooser] = await Promise.all([
    host.waitForEvent('filechooser'),
    host.getByRole('button', { name: /Choose a song/ }).click(),
  ]);
  await chooser.setFiles(SONG);
  await host.getByRole('button', { name: 'Play' }).waitFor({ timeout: 20000 });

  // The listener names itself on the join screen, then joins by code.
  await l1.goto(BASE);
  await enableSemantics(l1);
  await l1.getByRole('button', { name: 'Join a Session' }).click();
  await waitForText(l1, /Joining as Listener-/, 20000);
  await l1.getByRole('button', { name: 'Change' }).click();
  await l1.waitForTimeout(500);
  await l1.getByRole('textbox').last().fill(NAME);
  await l1.getByRole('button', { name: 'Save' }).click();
  await waitForText(l1, new RegExp(`Joining as ${NAME}`), 10000);
  log('listener named itself');
  await l1.getByRole('textbox').first().fill(code);
  await l1.getByRole('button', { name: 'Join', exact: true }).click();

  await waitForText(host, new RegExp(NAME), 30000);
  await waitForText(host, /Ready/, 30000);
  log('host lists the device as', NAME);

  // The host removes it from the tile's menu.
  await host.getByRole('button', { name: `Options for ${NAME}` }).click({ force: true });
  await host.waitForTimeout(400);
  await host.getByRole('menuitem', { name: 'Remove from session' }).click({ force: true });
  await waitForText(l1, /The host removed this device/, 20000);
  log('listener sees: removed');
  if (new RegExp(NAME).test(await semanticsText(host))) throw new Error('host still lists the removed device');

  // And it stays out: nothing re-joins while the listener would be re-announcing.
  await host.waitForTimeout(9000);
  const hostText = await semanticsText(host);
  if (new RegExp(NAME).test(hostText)) throw new Error('the removed device came back');
  if (!/The host removed this device/.test(await semanticsText(l1))) throw new Error('listener left the removed screen');
  log('PASS: named, removed, and kept out');
  await browser.close();
})().catch((e) => { console.error('FAIL', e.stack || e.message); process.exit(1); });
