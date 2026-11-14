import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { selectDownloads, detectOS, fetchReleases } from './releases.mjs';

const fixture = JSON.parse(await readFile(new URL('./releases.json', import.meta.url)));

test('finds the latest package independently for every platform', () => {
  const result = selectDownloads(fixture);
  assert.equal(result.macos.version, 'v0.6.0');
  assert.equal(result.linux.version, 'v0.5.2');
  assert.match(result.macos.browser_download_url, /v0\.6\.0\/rapp-0\.6\.0\.pkg$/);
  assert.match(result.linux.name, /\.pkg\.tar\.zst$/);
  assert.equal(result.windows, null);
});

test('ignores prereleases and drafts, and sorts stable releases by publication', () => {
  const future = { ...fixture[0], tag_name: 'v99.0.0', published_at: '2099-01-01', prerelease: true };
  const draft = { ...future, prerelease: false, draft: true };
  assert.equal(selectDownloads([...fixture].reverse().concat(future, draft)).macos.version, 'v0.6.0');
});

test('uses the real asset URL and refuses a foreign download origin', () => {
  const release = structuredClone(fixture[0]);
  release.assets.forEach(a => a.browser_download_url = 'https://example.org/installer.pkg');
  assert.equal(selectDownloads([release]).macos, null);
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
      headers: count === 1 ? { link: '<https://api.github.com/repos/wizlijun/rapp/releases?per_page=100&page=2>; rel="next"' } : {},
    });
  });
  assert.equal(count, 2);
  assert.equal(selectDownloads(result).linux.version, 'v0.5.2');
});

test('API failure is surfaced for the UI to retain its verified snapshot', async () => {
  await assert.rejects(fetchReleases(async () => new Response('', { status: 403 })), /GitHub 403/);
});
