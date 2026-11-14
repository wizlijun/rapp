import { mkdir, rm, copyFile, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const destination = new URL('./dist/', import.meta.url);
await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
const files = ['index.html', 'style.css', 'app.js', 'releases.mjs', 'releases.json', 'install-relay.sh', '_headers'];
for (const file of files) {
  await copyFile(new URL(file, import.meta.url), new URL(file, destination));
}
const fingerprint = content => createHash('sha256').update(content).digest('hex').slice(0, 12);
const moduleVersion = fingerprint(await readFile(new URL('releases.mjs', destination)));
const appPath = new URL('app.js', destination);
const app = (await readFile(appPath, 'utf8')).replace("'./releases.mjs'", `'./releases.mjs?v=${moduleVersion}'`);
await writeFile(appPath, app);
const cssVersion = fingerprint(await readFile(new URL('style.css', destination)));
const appVersion = fingerprint(app);
const indexPath = new URL('index.html', destination);
const html = (await readFile(indexPath, 'utf8'))
  .replace('href="./style.css"', `href="./style.css?v=${cssVersion}"`)
  .replace('src="./app.js"', `src="./app.js?v=${appVersion}"`);
await writeFile(indexPath, html);
console.log(`Prepared ${files.length} public website files in website/dist/`);
