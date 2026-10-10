'use strict';
// Progressive enhancement: every download works via Releases without JavaScript/API.
const themes = document.querySelectorAll('[data-theme]');
const preview = document.getElementById('desktop-preview');
themes.forEach(button => button.addEventListener('click', () => {
  const dark = button.dataset.theme === 'dark';
  preview.src = dark ? 'assets/chat-dark.png' : 'assets/chat-light.png';
  preview.alt = `连信桌面客户端${dark ? '深色' : '浅色'}主题：设备会话、消息和文件传输`;
  themes.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
}));

const patterns = {
  windows: /-windows-x64-setup\.exe$/,
  macos: /-macos\.dmg$/,
  linux: /-linux-amd64\.deb$/,
  android: /-android\.apk$/,
};
async function loadRelease() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 6000);
  try {
    const response = await fetch('https://api.github.com/repos/yuhuotech/linkory/releases/latest', {
      signal: controller.signal, headers: { Accept: 'application/vnd.github+json' },
    });
    if (!response.ok) throw new Error('Release unavailable');
    const release = await response.json();
    if (release.draft || release.prerelease || !Array.isArray(release.assets) ||
        !/^v?\d+\.\d+\.\d+$/.test(release.tag_name)) throw new Error('Invalid release');
    document.getElementById('release-label').textContent = `最新正式版 ${release.tag_name}`;
    document.querySelectorAll('[data-platform]').forEach(card => {
      const asset = release.assets.find(item => typeof item.name === 'string' &&
        item.name.startsWith(`Linkory-${release.tag_name.replace(/^v/, '')}-`) &&
        patterns[card.dataset.platform].test(item.name));
      if (!asset) return;
      const url = new URL(asset.browser_download_url);
      if (url.protocol !== 'https:' || url.hostname !== 'github.com' ||
          !url.pathname.startsWith('/yuhuotech/linkory/releases/download/')) return;
      card.querySelector('.download-link').href = url.href;
    });
  } catch {
    document.getElementById('release-label').textContent = '选择平台，前往 GitHub Releases 下载';
  } finally { clearTimeout(timeout); }
}
loadRelease();
