# rapphub.com

Published on Cloudflare Workers Static Assets: https://rapphub.com/ and https://www.rapphub.com/.
Worker: `rapphub-site`. Current production version: `d21c8546-8663-4c36-9908-ae7d90de8ffe` (2026-11-24).

Both production domains were verified against the built release snapshot after deployment: macOS 0.14.12 and Linux 0.14.13. All eight release-selection tests and the JavaScript syntax check passed before deployment.

Buildless HTML, CSS and JavaScript. Preview from the repository root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

Open http://127.0.0.1:4173/. English is the default; `?lang=ja` and `?lang=zh` link directly to the other languages. The theme selector offers MATRIX (default), WESTWORLD, and AVATAR from the existing app palettes.

Downloads are resolved independently per platform from the public GitHub releases API, including pagination. Drafts and prereleases are excluded. Exact asset URLs are used, rather than `/releases/latest/download`, because macOS and Linux packages can belong to different releases. `releases.json` is a verified fallback snapshot refreshed for 0.15.29; refresh it before publication. If GitHub cannot be reached, the version label says the list is saved. There is currently no Windows package. The Linux package is specifically for Omarchy / Arch x86_64, not all Linux distributions.

The Linux relay installer requires a running Docker installation and supports x86_64 / arm64. It pins the published `ghcr.io/wizlijun/rapp-relay:0.6.0` image, preserves the data volume, bounds readiness polling, and refuses to replace an existing container or rotate its key. It does not change the firewall or install Docker. Open UDP 22026 on the server and its cloud firewall. Keep the printed enrollment key; it is only shown once.

E2E copy refers to the new relay path with rapp 0.6+ on both devices. The published Linux app is now 0.15.28 and supports that path, plus desktop hosting on Omarchy/Hyprland, compatible wlroots compositors and X11. Linux 0.14.13 also adds local hold-to-talk; first use downloads a verified ~142 MB speech model, and audio is not saved or uploaded. Linux 0.15.9 adds isolated application hosting on Hyprland/X11, window controls across displays, host clipboard/file transfers, view crops, AT-SPI menus/focus hints, input-source switching and adaptive network saving. Native support and locker restrictions are documented in the repository README and release notes. Linux 0.15.13 aligns protocol v15 with macOS 0.15.12, adds native main/detached window pause and resume notifications, and excludes paused time from ACK deadlines and network-saving decisions. Linux 0.15.15 aligns the five-minute voice recording limit and fixes the native adapter ending final recognition at the old 80-second deadline. Linux 0.15.18 adds learned speech hotwords, the desktop key bar and phrase strip, fixes physical-key modifier latching, and adopts the rApp name and icon from macOS 0.15.17. Linux 0.15.22 aligns the floating input dock, in-panel quick-area toggle and local voice correction with macOS 0.15.21, adds Chinese-first language selection and speech timing, and includes the current desktop icon. Linux 0.15.24 brings the shared 0.15.23 quick-toggle fixes to Linux, with coverage for caret/selection/IME preservation, zoom, narrow menus, accessibility and reduced motion. Linux 0.15.26 aligns the macOS 0.15.25 regrouped key bar and trailing `⋯ ⌄` fold key, wraps `KeyBar` in `TextFieldTapRegion` so Linux mouse clicks preserve caret/selection/IME composition, and adds verified Omarchy Quickshell lock-screen password entry. Linux 0.15.28 aligns the macOS 0.15.27 overview Open App dropdown menu on remote device columns with Linux desktop hover, narrow-window and host-capability coverage. macOS is on 0.15.29 (terminal rows show the status Claude Code and Codex report over OSC 7501, and a terminal waiting for confirmation shows up in 需要你; 0.15.27: an 打开应用 dropdown on each overview device column that opens any running app in two clicks; 0.15.25: regrouped key bar with `⌫`, sticky `⌃`, `⋯ ⌄` and `⌃L`, plus keeping previous `.app` backups unlaunchable; 0.15.23: quick-toggle fixes for large text, landscape, narrow menus and mouse focus; 0.15.21: the quick-area toggle moves into the writing box, local voice correction and Chinese-first recognition; 0.15.20: the key bar and the writing panel float together as one input block, so the remote picture is never pushed up; 0.15.19: a separate glass-pad icon for the desktop while iOS keeps the full-bleed one; 0.15.17: a new app icon; 0.15.16: voice input remembers corrections and tidies for people or for prompts, the iOS key bar and phrase strip on the desktop, and the app is now named rApp; 0.15.14 let hold-to-talk voice input last up to 5 minutes; 0.15.12 brought protocol v15: sessions nobody can see stop sending pictures and keep only the activity lamp, plus the iOS phrases row; 0.15.11 made the iOS icon fill the whole tile; 0.15.10 brought the iOS input key that opens and closes the panel, plus a terminal key bar; 0.15.8 brought the new B-Aqua icon; voice tidy starts while speaking, words stream in, hotwords and a think switch; 0.15.7 made voice tidy rewrite in place with the original kept for comparing, and a failure quietly sends the original; 0.15.6 made the iOS app open the localhost:28000+ share ports itself; 0.15.5 tidied long voice text with the virtual-network LLM before sending; 0.15.3 made input history one row per entry with a ⋮ menu; 0.15.1 made writing-panel ↑/↓ keep what is being written); Linux-only releases must use `--latest=false` because the macOS updater reads `/releases/latest/download/latest.json`. The download page shows the legacy warning only when it selects an old Linux build such as 0.5.2. See the v0.6.0 release notes and `rust/conn/src/e2e.rs`.

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
