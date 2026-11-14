# rapphub.com

Published on Cloudflare Workers Static Assets: https://rapphub.com/ and https://www.rapphub.com/.
Worker: `rapphub-site`. Initial production version: `fe3f4930-7b19-4652-b13d-d04ac7da8a3b` (2026-11-14).

Buildless HTML, CSS and JavaScript. Preview from the repository root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

Open http://127.0.0.1:4173/. English is the default; `?lang=ja` and `?lang=zh` link directly to the other languages. The theme selector offers MATRIX (default), WESTWORLD, and AVATAR from the existing app palettes.

Downloads are resolved independently per platform from the public GitHub releases API, including pagination. Drafts and prereleases are excluded. Exact asset URLs are used, rather than `/releases/latest/download`, because macOS and Linux packages can belong to different releases. `releases.json` is a verified fallback snapshot from 2026-11-14; refresh it before publication. If GitHub cannot be reached, the version label says the list is saved. There is currently no Windows package. The Linux package is specifically for Omarchy / Arch x86_64, not all Linux distributions.

The Linux relay installer requires a running Docker installation and supports x86_64 / arm64. It pins the published `ghcr.io/wizlijun/rapp-relay:0.6.0` image, preserves the data volume, bounds readiness polling, and refuses to replace an existing container or rotate its key. It does not change the firewall or install Docker. Open UDP 22026 on the server and its cloud firewall. Keep the printed enrollment key; it is only shown once.

E2E copy refers to the new relay path with rapp 0.6+ on both devices. The currently published Linux app is 0.5.2 and uses the old connection path; this limitation is shown beside the downloads. See the v0.6.0 release notes and `rust/conn/src/e2e.rs`.

The install script is served at https://rapphub.com/install-relay.sh. The build copies only the seven public website files to `dist/`; documentation, tests, and deployment configuration are excluded.

Relay availability: anonymous access to the GHCR relay image returned HTTP 401 during verification on 2026-11-14. The website and script are public, but pulling the relay image still requires resolving package visibility or using an account with pull access. No registry visibility was changed. Installer behavior was checked with a mocked Docker CLI (fresh installation, existing container, unsupported OS, readiness timeout, and existing enrollment key); no relay was installed on this computer.

Deploy updates from the repository root after refreshing `releases.json`:

```sh
node website/build.mjs
npx --yes wrangler@4.135.0 deploy --config website/wrangler.jsonc
```

Checks:

```sh
node --test website/releases.test.mjs
node --check website/app.js
shellcheck website/install-relay.sh
```
