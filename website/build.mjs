import { mkdir, rm, copyFile } from 'node:fs/promises';

const destination = new URL('./dist/', import.meta.url);
await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
const files = ['index.html', 'style.css', 'app.js', 'releases.mjs', 'releases.json', 'install-relay.sh', '_headers'];
for (const file of files) {
  await copyFile(new URL(file, import.meta.url), new URL(file, destination));
}
console.log(`Prepared ${files.length} public website files in website/dist/`);
