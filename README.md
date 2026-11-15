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
| Omarchy / Arch · x86_64 | Download the `.pkg.tar.zst`, then run `sudo pacman -U ./rapp-omarchy-*.pkg.tar.zst`. Client only. |

Install rapp on your Mac host and controlling computer. On the host, allow Screen Recording and Accessibility, and keep it awake. When the last remote app closes, the host locks itself; the next time you open an app, the controlling computer asks for the host's system password (or types the remembered one). Turn this off under This Mac (本机). The login window after a restart and sleep are still not supported. Add the host in rapp, then open an app.

Type Chinese and other IME text on the controlling computer: the writing panel composes it locally and sends it whole, while the host stays in English. For the smoothest input, use the [Fcitx5](https://github.com/fcitx/fcitx5) input method; on macOS its candidates appear right under the writing panel, in the panel's own font. See [writing panel design](docs/writing-panel.md) (Chinese).

For macOS on Apple silicon, download the companion [Fcitx5 for Sumi 0.5.0.15 installer (.pkg)](https://github.com/wizlijun/rapp/releases/download/v0.10.7/Fcitx5-for-Sumi-0.5.0.15-arm64.pkg).

For access across networks, see [self-hosted relay setup](docker/relay/README.md). E2E relay connections require rapp 0.6+ on both ends; Linux v0.5.2 uses the legacy connection path. Downloads are selected separately for each platform.

Linux v0.5.2 cannot connect to macOS hosts running 0.8+. Build the Linux client from current source until a compatible package is available; update both ends together.

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

To create Linux packages, run `./scripts/package-linux.sh` from a clean checkout; it also requires makepkg, fakeroot, and zstd. Outputs go to `dist/`.

## License

[GNU GPL v3](LICENSE).

## Acknowledgments

Thanks to the open-source projects that informed or support rapp:

- [RustDesk](https://github.com/rustdesk/rustdesk) — device connection and self-hosted relay design references.
- [Sunshine](https://github.com/SunshineStream/Sunshine) — a reference for streaming research.
- [Fcitx5](https://github.com/fcitx/fcitx5) — the input method behind rapp's smooth writing-panel input.
- [Flutter](https://github.com/flutter/flutter) and [GTK](https://www.gtk.org/) — user interfaces.
- [Tokio](https://github.com/tokio-rs/tokio), [Quinn](https://github.com/quinn-rs/quinn), and [rustls](https://github.com/rustls/rustls) — networking foundations.
