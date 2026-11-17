# rapp

**More agents. One Pad.**

Your agents work across machines. Keep your attention in one place.
rapp brings remote Mac apps into one workspace, so you can read, reply, and direct your agents from the computer in front of you.

Recommended: an Omarchy tablet.

[Website & downloads](https://rapphub.com) · [Releases](https://github.com/wizlijun/rapp/releases) · [简体中文](README.zh-CN.md)

## Install

| Platform | Installation |
| --- | --- |
| macOS 14+ · Apple silicon | Download and open the `.pkg`. Supports hosting and controlling apps. |
| Omarchy / Arch · x86_64 | Install the matching `.pkg.tar.zst` with `sudo pacman -U ./rapp-omarchy-*.pkg.tar.zst`. Controls Mac apps and desktops; also serves text terminals and shared ports. |

Install rapp on your Mac host and controlling computer. On the host, allow Screen Recording and Accessibility, and keep it awake. When the last remote app closes, the host locks itself; the next time you open an app, the controlling computer asks for the host's system password (or types the remembered one). Turn this off under This Mac (本机). The login window after a restart and sleep are still not supported. Add the host in rapp, then open an app.

Type Chinese and other IME text on the controlling computer: the writing panel composes it locally and sends it whole, while the host stays in English. For the smoothest input, use the [Fcitx5](https://github.com/fcitx/fcitx5) input method; on macOS its candidates appear right under the writing panel, in the panel's own font. See [writing panel design](docs/writing-panel.md) (Chinese).

For macOS on Apple silicon, download the companion [Fcitx5 for Sumi 0.5.0.15 installer (.pkg)](https://github.com/wizlijun/rapp/releases/download/v0.10.7/Fcitx5-for-Sumi-0.5.0.15-arm64.pkg).

For access across networks, see [self-hosted relay setup](docker/relay/README.md). E2E relay connections require rapp 0.6+ on both ends; Linux v0.5.2 uses the legacy connection path. Downloads are selected separately for each platform.

Linux v0.5.2 cannot connect to macOS hosts running 0.8+. Linux and macOS now share the workspace release version and app protocol 13; update both ends together. Build and package this source if the release page does not yet offer the matching Linux assets. Older explicit `protocol=4/5/6` addresses are rejected.

Linux supports embedded sessions, detach/reattach into native windows, and the standalone GTK client. The main window retains the last picture and draft while reconnecting. The standalone client, like its Mac counterpart, exits on an ordinary disconnect and offers an explicit take-back after takeover. Text, images and file transfers use the same current protocol as the picture connection.

Linux can host full desktops for other clients speaking the same protocol, over the existing LAN/direct/relay connections. Omarchy/Hyprland, Wayland compositors exposing wlr screencopy and virtual keyboard/pointer protocols, and X11 are supported. Desktop hosting includes per-monitor capture, mouse, keyboard and text insertion (`xdotool` is required for X11 text). GNOME/KDE Wayland portals, individual application hosting, host clipboard/file transfers and automatic password entry are not implemented; unlock locally if the compositor blocks capture while locked. The Linux package and `scripts/build-linux.sh` now include `rapp-host`; restart the service after upgrading an existing installation. Use `rapp-host check --json` to inspect desktop availability. Text-terminal windows require an installed supported terminal, a graphical login and a systemd user manager; they run separately from the rapp service so restarting it does not end the terminal. `rapp` with no arguments opens the GUI; `rapp hosts`, `rapp share`, `rapp unshare` and `rapp pipe` run the CLI. Linux updates are installed through the package manager, or by replacing the portable bundle.

For direct connections, allow inbound **UDP 22028** (or the service's configured UDP port) from the intended peers. Do not open an entire `2202x` range: TCP 22029 is localhost-only IPC; TCP 28000–28999 are localhost-only port mappings carried over the existing rapp connection. Neither needs a LAN firewall exception. UDP 22026 belongs to a separately deployed relay, not a normal rapp device. The Linux Local page shows the actual UDP listener, offers a read-only check of recent UFW block logs, and provides a command restricted to one peer IP. A timeout or an empty log alone does not establish whether a firewall blocked the connection.

Upgrades preserve the data directory and saved hosts. The legacy relay configuration from 0.5.x is retired by the mainline migration; enter a current relay key to use the new relay. This is separate from preserving local data.

## Build

Requires Rust/Cargo and Flutter with Dart 3.12.1+.

```sh
git clone https://github.com/wizlijun/rapp.git
cd rapp
```

**macOS:** Apple silicon, macOS 14+, and Xcode.

```sh
RAPP_ALLOW_ADHOC=1 ./scripts/package-macos.sh
```

Packages are written to `dist/`. Ad-hoc signing is allowed for local builds; see the [script](scripts/package-macos.sh) for signing and notarization options.

**Omarchy / Arch:** x86_64, Python 3.11+, GTK4 ≥ 4.12, GTK3, clang, cmake, ninja, pkgconf, and libayatana-appindicator.

```sh
./scripts/build-linux.sh
./gui/build/linux/x64/release/bundle/rapp
```

To create Linux packages, run `./scripts/package-linux.sh` from a clean checkout; it also requires makepkg, fakeroot, and zstd. Outputs go to `dist/`. For a package-only revision, use `PKGREL=2 ./scripts/package-linux.sh`; revised artifacts go to `dist/pkgrel-2/`, retaining the earlier artifacts. `DIST_DIR` can override the output directory.

Implementation scope and verification status: [Linux 0.13.7 alignment](docs/superpowers/plans/2026-11-17-linux-0137-parity.md).

## License

[GNU GPL v3](LICENSE).

## Acknowledgments

Thanks to the open-source projects that informed or support rapp:

- [RustDesk](https://github.com/rustdesk/rustdesk) — device connection and self-hosted relay design references.
- [Sunshine](https://github.com/SunshineStream/Sunshine) — a reference for streaming research.
- [hurryvc](https://github.com/swigger/hurryvc) — the design reference for text terminals on macOS and Windows (pseudo-terminal plus screen-state sync).
- [Fcitx5](https://github.com/fcitx/fcitx5) — the input method behind rapp's smooth writing-panel input.
- [Flutter](https://github.com/flutter/flutter) and [GTK](https://www.gtk.org/) — user interfaces.
- [Tokio](https://github.com/tokio-rs/tokio), [Quinn](https://github.com/quinn-rs/quinn), and [rustls](https://github.com/rustls/rustls) — networking foundations.
