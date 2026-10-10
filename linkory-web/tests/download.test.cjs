// Run: node tests/download.test.cjs (Node built-ins only).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const script = fs.readFileSync(path.join(__dirname, '../script.js'), 'utf8');
async function run(fetch) {
  const label = {};
  const cards = ['windows', 'macos', 'linux', 'android'].map(platform => ({
    dataset: { platform }, link: { href: 'https://github.com/yuhuotech/linkory/releases' },
    querySelector() { return this.link; },
  }));
  const document = {
    getElementById: id => id === 'release-label' ? label : {},
    querySelectorAll: selector => selector === '[data-platform]' ? cards : [],
  };
  await vm.runInNewContext(script, { document, fetch, URL, AbortController, setTimeout, clearTimeout });
  return { label, cards };
}
(async () => {
  const assets = ['windows-x64-setup.exe', 'macos.dmg', 'linux-amd64.deb', 'android.apk'].map(suffix => ({
    name: `Linkory-1.2.3-${suffix}`,
    browser_download_url: `https://github.com/yuhuotech/linkory/releases/download/v1.2.3/Linkory-1.2.3-${suffix}`,
  }));
  const response = release => async () => ({ ok: true, json: async () => release });
  const release = { tag_name: 'v1.2.3', assets };
  const success = await run(response(release));
  assert.equal(success.label.textContent, '最新正式版 v1.2.3');
  success.cards.forEach(card => assert.match(card.link.href, /releases\/download\/v1\.2\.3/));
  for (const fetch of [async () => { throw new Error('offline'); }, async () => ({ ok: false }),
    response({ ...release, prerelease: true }), response({ ...release, assets: null })]) {
    const fallback = await run(fetch);
    fallback.cards.forEach(card => assert.equal(card.link.href, 'https://github.com/yuhuotech/linkory/releases'));
    assert.match(fallback.label.textContent, /GitHub Releases/);
  }
  const unsafe = await run(response({ ...release, assets: assets.map(asset => ({ ...asset,
    browser_download_url: 'https://untrusted.example/installer.exe' })) }));
  unsafe.cards.forEach(card => assert.equal(card.link.href, 'https://github.com/yuhuotech/linkory/releases'));
  console.log('PASS: latest assets, network/API failure, prerelease rejection and untrusted URL rejection');
})().catch(error => { console.error(error); process.exitCode = 1; });
