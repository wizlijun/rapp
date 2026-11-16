import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { selectDownloads, detectOS, fetchReleases, REPOSITORY } from './releases.mjs';

// The selection rules are tested against a frozen fixture, not against releases.json: that snapshot is
// refreshed at every release, and tests pinned to whatever it held that day fail on the next one.
const url = (tag, name) => `https://github.com/${REPOSITORY}/releases/download/${tag}/${name}`;
const release = (tag, at, names) => ({
  assets: names.map(name => ({ browser_download_url: url(tag, name), name, size: 1024 })),
  draft: false,
  html_url: `https://github.com/${REPOSITORY}/releases/tag/${tag}`,
  prerelease: false,
  published_at: at,
  tag_name: tag,
});
// macOS ships in the newest release; the Linux package only in an older one, which is the whole
// reason each platform is resolved on its own.
const fixture = [
  release('v2.0.0', '2026-03-02T00:00:00Z', ['rapp-2.0.0.pkg', 'rapp-2.0.0-macos-arm64.zip', 'latest.json']),
  release('v1.0.0', '2026-01-01T00:00:00Z', ['rapp-omarchy-1.0.0-1-x86_64.pkg.tar.zst']),
];

test('finds the latest package independently for every platform', () => {
  const result = selectDownloads(fixture);
  assert.equal(result.macos.version, 'v2.0.0');
  assert.equal(result.linux.version, 'v1.0.0');
  assert.match(result.macos.browser_download_url, /v2\.0\.0\/rapp-2\.0\.0\.pkg$/);
  assert.match(result.linux.name, /\.pkg\.tar\.zst$/);
  assert.equal(result.windows, null);
});

test('prefers the pkg but falls back to the zip', () => {
  const zipOnly = [release('v2.0.0', '2026-03-02T00:00:00Z', ['rapp-2.0.0-macos-arm64.zip'])];
  assert.equal(selectDownloads(zipOnly).macos.name, 'rapp-2.0.0-macos-arm64.zip');
});

test('ignores prereleases and drafts, and sorts stable releases by publication', () => {
  const future = { ...fixture[0], tag_name: 'v99.0.0', published_at: '2099-01-01', prerelease: true };
  const draft = { ...future, prerelease: false, draft: true };
  assert.equal(selectDownloads([...fixture].reverse().concat(future, draft)).macos.version, 'v2.0.0');
});

test('uses the real asset URL and refuses a foreign download origin', () => {
  const foreign = structuredClone(fixture[0]);
  foreign.assets.forEach(a => (a.browser_download_url = 'https://example.org/installer.pkg'));
  assert.equal(selectDownloads([foreign]).macos, null);
});

test('desktop OS selection excludes phones, tablets and unsupported Linux ARM', () => {
  assert.equal(detectOS('Mozilla Macintosh Intel Mac OS X'), 'macos');
  assert.equal(detectOS('X11; Linux x86_64'), 'linux');
  assert.equal(detectOS('Windows NT 10.0; Win64; x64'), 'windows');
  for (const ua of ['Linux aarch64', 'Linux armv7l', 'Android Linux', 'iPad', 'iPhone']) assert.equal(detectOS(ua), null);
});

test('follows GitHub pagination so packages in older releases are found', async () => {
  let count = 0;
  const result = await fetchReleases(async () => {
    count++;
    return new Response(JSON.stringify(count === 1 ? [fixture[0]] : fixture.slice(1)), {
      headers: count === 1 ? { link: `<https://api.github.com/repos/${REPOSITORY}/releases?per_page=100&page=2>; rel="next"` } : {},
    });
  });
  assert.equal(count, 2);
  assert.equal(selectDownloads(result).linux.version, 'v1.0.0');
});

test('API failure is surfaced for the UI to retain its verified snapshot', async () => {
  await assert.rejects(fetchReleases(async () => new Response('', { status: 403 })), /GitHub 403/);
});

// The snapshot is what the page falls back to when GitHub cannot be reached, so it has to stay usable
// in its own right, whatever release it was taken at.
test('the shipped snapshot is well formed and offers a macOS download', async () => {
  const snapshot = JSON.parse(await readFile(new URL('./releases.json', import.meta.url)));
  assert.ok(Array.isArray(snapshot) && snapshot.length > 0);
  for (const r of snapshot) {
    assert.equal(typeof r.tag_name, 'string');
    assert.equal(typeof r.published_at, 'string');
    assert.ok(!Number.isNaN(Date.parse(r.published_at)), `${r.tag_name} has a readable date`);
    assert.equal(typeof r.draft, 'boolean');
    assert.equal(typeof r.prerelease, 'boolean');
    assert.ok(Array.isArray(r.assets));
    for (const a of r.assets) {
      assert.equal(typeof a.name, 'string');
      assert.equal(typeof a.size, 'number');
      assert.ok(a.browser_download_url.startsWith(`https://github.com/${REPOSITORY}/releases/download/`), a.browser_download_url);
    }
  }
  const macos = selectDownloads(snapshot).macos;
  assert.ok(macos, 'the snapshot resolves a macOS download');
  assert.match(macos.name, /\.pkg$|-macos-arm64\.zip$/);
});
