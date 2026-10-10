// Browser side of the web <-> native interop test. The native side is linkory-app/test/e2e_web_interop_test.dart.
//   node interop.js <server-url> <shared-dir>      MODE=fs (default) | memory
// Flutter paints on a canvas, so text is read (and buttons are found) through its accessibility tree.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const puppeteer = require('puppeteer-core');

const [url, dir] = process.argv.slice(2);
const mode = process.env.MODE || 'fs';
const chrome = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sha = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

async function until(fn, what, seconds = 60) {
  const end = Date.now() + seconds * 1000;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error('timeout waiting for ' + what);
    await sleep(200);
  }
}

(async () => {
  await until(() => fs.existsSync(path.join(dir, 'native_ready')), 'native client', 120);
  const browser = await puppeteer.launch({ executablePath: chrome, headless: 'new', args: ['--no-sandbox'] });
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  await page.setViewport({ width: 1280, height: 800 });
  page.on('pageerror', (e) => console.log('pageerror:', e.message.slice(0, 300)));
  const downloads = path.join(dir, 'web_downloads');
  fs.mkdirSync(downloads, { recursive: true });
  const cdp = await browser.target().createCDPSession();
  await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads, eventsEnabled: true, browserContextId: ctx.id }).catch(() => {});
  await page.evaluateOnNewDocument((mode) => {
    if (mode === 'fs') {
      // Headless Chrome has no save dialog: stand in for the File System Access API and keep what is written.
      window.__saved = {};
      window.showSaveFilePicker = async (opts) => ({
        createWritable: async () => {
          const parts = [];
          return {
            write: async (d) => { parts.push(new Uint8Array(d)); },
            close: async () => { window.__saved[opts.suggestedName] = parts; },
            abort: async () => {},
          };
        },
      });
    } else {
      delete window.showSaveFilePicker; // Firefox / Safari: the in-memory path and a normal download
    }
  }, mode);

  await page.goto(url, { waitUntil: 'networkidle2', timeout: 60000 });
  await sleep(3000);

  // ---- sign in ----
  await page.mouse.click(485, 356); await sleep(800);
  await page.keyboard.type(process.env.E2E_USER); await page.keyboard.press('Tab');
  await page.keyboard.type('correct-horse-9'); await page.keyboard.press('Enter');
  await sleep(3500);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await sleep(1000);

  const texts = () => page.evaluate(() => [...document.querySelectorAll('flt-semantics')].map((e) => e.textContent || '').join('\n'));
  const clickLabel = async (label) => {
    const h = await page.evaluateHandle((label) => [...document.querySelectorAll('flt-semantics')].filter((e) => e.children.length === 0 || true).find((e) => (e.getAttribute('aria-label') || e.textContent || '').trim() === label), label);
    const el = h.asElement();
    if (!el) throw new Error('no button ' + label);
    await el.click();
  };
  const click = async (label) => { await until(async () => (await page.evaluate((l) => [...document.querySelectorAll('flt-semantics')].some((e) => (e.getAttribute('aria-label') || e.textContent || '').trim() === l), label)), 'button ' + label); await clickLabel(label); };

  // ---- open the conversation with the native device ----
  await until(async () => (await texts()).includes('在线'), 'native device online');
  await page.mouse.click(180, 80); await sleep(1500);

  // ---- text both ways ----
  await page.mouse.click(700, 720);
  await page.keyboard.type('hello native 你好'); await page.keyboard.press('Enter');
  await until(async () => (await texts()).includes('hi browser 你好'), 'reply from native');
  console.log('ok  text both ways');

  // ---- file browser -> native ----
  const src = path.join(dir, 'web_src.bin');
  fs.writeFileSync(src, crypto.randomBytes(Number(process.env.WEB_FILE_MB || 5) * 1024 * 1024 + 321));
  const [chooser] = await Promise.all([page.waitForFileChooser(), page.mouse.click(421, 655)]);
  await chooser.accept([src]);
  await until(async () => (await texts()).includes('web_src.bin'), 'transfer card');
  fs.writeFileSync(path.join(dir, 'web_sent'), '1');
  await until(async () => (await texts()).includes('已完成'), 'upload completed', 90);
  console.log('ok  file browser -> native');

  // ---- file native -> browser (accept) ----
  await click('接收');
  const want = sha(fs.readFileSync(path.join(dir, 'native_src.bin')));
  if (mode === 'fs') {
    const got = await until(() => page.evaluate(async () => {
      const parts = window.__saved['native_src.bin'];
      if (!parts) return null;
      const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
      let o = 0; for (const p of parts) { all.set(p, o); o += p.length; }
      return [...new Uint8Array(await crypto.subtle.digest('SHA-256', all))].map((b) => b.toString(16).padStart(2, '0')).join('');
    }), 'saved file', 90);
    if (got !== want) throw new Error('browser received different bytes');
  } else {
    const f = await until(() => fs.readdirSync(downloads).find((n) => n === 'native_src.bin'), 'downloaded file', 90);
    await sleep(500);
    if (sha(fs.readFileSync(path.join(downloads, f))) !== want) throw new Error('browser downloaded different bytes');
  }
  console.log(`ok  file native -> browser (${mode})`);

  // ---- a second offer is declined ----
  await click('拒绝');
  await until(() => fs.existsSync(path.join(dir, 'native_done')), 'native to finish', 90);
  console.log('ok  reject');
  await browser.close();
})().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
