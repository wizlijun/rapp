export const REPOSITORY = 'wizlijun/rapp';
const rules = {
  macos: { preferred: /^rapp-\d[^/]*\.pkg$/i, alternate: /^rapp-.*macos-arm64\.zip$/i },
  linux: { preferred: /^rapp-omarchy-.*-x86_64\.pkg\.tar\.zst$/i, alternate: /^rapp-.*omarchy-x86_64\.tar\.gz$/i },
  windows: { preferred: /^rapp-.*(?:windows|win32|win64).*(?:\.exe|\.msi)$/i },
};

export function selectDownloads(releases) {
  const stable = releases.filter(r => !r.draft && !r.prerelease)
    .sort((a, b) => Date.parse(b.published_at) - Date.parse(a.published_at));
  return Object.fromEntries(Object.entries(rules).map(([os, rule]) => {
    for (const release of stable) {
      const assets = release.assets ?? [];
      const asset = assets.find(a => rule.preferred.test(a.name)) ?? assets.find(a => rule.alternate?.test(a.name));
      if (!asset) continue;
      // Only direct assets from this repository; never construct a /latest/download URL.
      const prefix = `https://github.com/${REPOSITORY}/releases/download/`;
      if (!asset.browser_download_url?.startsWith(prefix)) continue;
      return [os, { ...asset, version: release.tag_name, release: release.html_url }];
    }
    return [os, null];
  }));
}

export function detectOS(ua, platform = '') {
  const text = `${ua} ${platform}`;
  if (/Android|iPhone|iPad|iPod/i.test(text)) return null;
  if (/Mac/i.test(text)) return 'macos';
  if (/Windows|Win32/i.test(text)) return 'windows';
  if (/Linux/i.test(text) && !/aarch64|armv|arm64/i.test(text)) return 'linux';
  return null;
}

export async function fetchReleases(fetcher = fetch) {
  let url = `https://api.github.com/repos/${REPOSITORY}/releases?per_page=100`;
  const releases = [];
  for (let page = 0; url && page < 10; page++) {
    const response = await fetcher(url, { headers: { Accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error(`GitHub ${response.status}`);
    const batch = await response.json();
    if (!Array.isArray(batch)) throw new Error('Invalid releases');
    releases.push(...batch);
    const next = response.headers.get('link')?.match(/<([^>]+)>; rel="next"/)?.[1];
    url = next?.startsWith(`https://api.github.com/repos/${REPOSITORY}/releases?`) ? next : null;
  }
  if (url) throw new Error('Release pagination incomplete');
  return releases;
}
