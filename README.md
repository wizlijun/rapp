# rApp

**More agents. One Pad.**

Your agents work across machines. Keep your attention in one place.
rApp brings remote Mac apps into one workspace, so you can read, reply, and direct your agents from the computer in front of you.

Recommended: an Omarchy tablet.

[Website & downloads](https://rapphub.com) · [Releases](https://github.com/wizlijun/rapp/releases) · [简体中文](README.zh-CN.md)

## Install

| Platform | Installation |
| --- | --- |
| macOS 14+ · Apple silicon | Download and open the `.pkg`. Supports hosting and controlling apps. |
| Omarchy / Arch · x86_64 | Install the matching `.pkg.tar.zst` with `sudo pacman -U ./rapp-omarchy-*.pkg.tar.zst`. Controls Mac apps and desktops; also serves text terminals and shared ports. |
| iPhone Duo · iOS / iPadOS | Works on iPhone Duo. The iOS and iPadOS app is coming soon. |

Install rApp on your Mac host and controlling computer. On the host, allow Screen Recording and Accessibility, and keep it awake. When the last remote app closes, the host locks itself; the next time you open an app, the controlling computer asks for the host's system password (or types the remembered one). Turn this off under This Mac (本机). The login window after a restart and sleep are still not supported. Add the host in rApp, then open an app.

Type Chinese and other IME text on the controlling computer: the writing panel composes it locally and sends it whole, while the host stays in English. For the smoothest input, use the [Fcitx5](https://github.com/fcitx/fcitx5) input method; on macOS its candidates appear right under the writing panel, in the panel's own font. See [writing panel design](docs/writing-panel.md) (Chinese).

For macOS on Apple silicon, download the companion [Fcitx5 for Sumi 0.5.0.15 installer (.pkg)](https://github.com/wizlijun/rapp/releases/download/v0.10.7/Fcitx5-for-Sumi-0.5.0.15-arm64.pkg).

For access across networks, see [self-hosted relay setup](docker/relay/README.md). E2E relay connections require rApp 0.6+ on both ends; Linux v0.5.2 uses the legacy connection path. Downloads are selected separately for each platform.

Linux v0.5.2 cannot connect to macOS hosts running 0.8+. Linux and macOS now share the workspace release version and app protocol 14; update both ends together. Build and package this source if the release page does not yet offer the matching Linux assets. Older explicit `protocol=4/5/6` addresses are rejected.

Linux supports embedded sessions, detach/reattach into native windows, and the standalone GTK client. The main window retains the last picture and draft while reconnecting. The standalone client, like its Mac counterpart, exits on an ordinary disconnect and offers an explicit take-back after takeover. Text, images and file transfers use the same current protocol as the picture connection.

Linux can host full desktops over the existing LAN/direct/relay connections on Omarchy/Hyprland, compatible wlroots compositors and X11. Hyprland toplevel export/mapping and X11 Composite also support isolated application sharing across monitors, including window focus/move/resize/close and cover protection. Host features include clipboard observation, text/image/file/typed-data paste and transfer with resume, cropped views, adaptive network saving, input-source selection, AT-SPI menus and focus/password-field hints. These interfaces are exercised on isolated Xvfb, labwc and nested Hyprland desktops. X11 text insertion requires `xdotool`; use `rapp-host check --json` to inspect availability and restart the service after upgrading.

Native support depends on the compositor and application: Hyprland's toplevel export clips popups to the parent surface; X11 can include separate popup surfaces. Menus/focus hints require AT-SPI metadata. Password entry requires confirmed Hyprland lock notifications and a same-session hyprlock/swaylock; other lockers require local unlock. GNOME/KDE Wayland portal hosting remains unavailable. Text-terminal windows require a supported terminal, a graphical login and a systemd user manager, and survive service restarts. `rapp` opens the GUI; `rapp hosts`, `rapp share`, `rapp unshare` and `rapp pipe` run the CLI. Linux updates use the package manager or replacement portable bundle.

For direct connections, allow inbound **UDP 22028** (or the service's configured UDP port) from the intended peers. Do not open an entire `2202x` range: TCP 22029 is localhost-only IPC; TCP 28000–28999 are localhost-only port mappings carried over the existing rApp connection. Neither needs a LAN firewall exception. UDP 22026 belongs to a separately deployed relay, not a normal rApp device. The Linux Local page shows the actual UDP listener, offers a read-only check of recent UFW block logs, and provides a command restricted to one peer IP. A timeout or an empty log alone does not establish whether a firewall blocked the connection.

Program status: in a text terminal started with `rapp-term run`, CLIs that report their state over OSC 7501 show it in the session list (working, waiting for approval, asking, error), and sessions waiting for you appear in 需要你. rApp only reads the reports and answers the CLI's probe; it never types into the CLI. This needs Claude Code ≥ 2.1.295, Codex ≥ 0.163.0 or agy ≥ 1.4.0 on the host. Set `"programStatus": false` in `local/term.json` to turn it off for new sessions.

Multiple text terminals: press ⌘T (Ctrl+Shift+T on non-macOS) in a text terminal to open a new one in the same directory and shell; on the host Mac it is a new Terminal tab titled `<dir> · <prog>`. ⌘W or 结束终端 in the session menu ends the terminal (with a confirm if a program is running) and its tab closes by itself; 关闭 only stops viewing and leaves the terminal running on the host.

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

**Omarchy / Arch:** x86_64 with SSE4.2, Python 3.11+, GTK4 ≥ 4.12, GTK3, at-spi2-core, libxkbcommon, clang, cmake, ninja, pkgconf, libayatana-appindicator, libpulse, and stable Flutter ≥ 3.50.0. Set `FLUTTER=/path/to/flutter/bin/flutter` to select an isolated SDK. Older Linux engines have a GTK/OpenGL crash path fixed upstream in Flutter #192137. Packages record the selected SDK in `FLUTTER-INFO.json` and its engine digest in `BUILD-INFO.json`.

```sh
./scripts/build-linux.sh
./gui/build/linux/x64/release/bundle/rapp
```

To create Linux packages, run `./scripts/package-linux.sh` from a clean checkout; it also requires makepkg, fakeroot, and zstd. Outputs go to `dist/`. For a package-only revision, use `PKGREL=2 ./scripts/package-linux.sh`; revised artifacts go to `dist/pkgrel-2/`, retaining the earlier artifacts. `DIST_DIR` can override the output directory.

Linux 0.14.13 adds local hold-to-talk on app and terminal stages: hold Right Alt or the voice button, release to send, Esc to cancel, Tab to edit. First use downloads a verified ~142 MB model; audio is never saved or uploaded. Recognition follows the system language and needs PulseAudio or PipeWire PulseAudio. See [Linux voice behavior and verification limits](docs/superpowers/specs/2026-11-18-rapp-linux-voice-design.md).

The 0.15.2 source also includes host-grouped tray sessions and favorites, screen selection in the window menu, and input history that preserves unfinished drafts and works with recording disabled. On Linux, Ctrl+V, Shift+Insert and the input panel's context-menu Paste all use the application clipboard pipeline for text and attachment blocks. Detached windows leave history and send keys to the input method while it is composing. See [macOS 0.15.1 parity and Linux validation](docs/superpowers/plans/2026-11-20-linux-0151-parity.md).

Linux 0.15.4 includes the macOS 0.15.3 single-row input history, with actions in the ⋮ / right-click menu, full-text hover previews and compact scope buttons. The time column also shrinks in narrow panels so multiline drafts retain their line count, unsent badge and menu without overflowing. See [0.15.3 parity and Linux 0.15.4 release validation](docs/superpowers/plans/2026-11-20-linux-0154-parity.md).

## License

[GNU GPL v3](LICENSE).

## Acknowledgments

Thanks to the open-source projects that informed or support rApp:

- [RustDesk](https://github.com/rustdesk/rustdesk) — device connection and self-hosted relay design references.
- [Sunshine](https://github.com/SunshineStream/Sunshine) — a reference for streaming research.
- [hurryvc](https://github.com/swigger/hurryvc) — the design reference for text terminals on macOS and Windows (pseudo-terminal plus screen-state sync).
- [gascity](https://github.com/gastownhall/gascity) — the OSC 7501 probe answer and stream scanner in `rapp-term` are ported from its program-status relay, along with its recorded test captures (MIT, Copyright (c) 2026 Gas City Contributors).
- [zellij](https://github.com/zellij-org/zellij) — the program-status report parser, limits and record table in `rapp-term` are ported from its OSC 7501 implementation (MIT, Copyright (c) 2020 Zellij contributors).
- [Fcitx5](https://github.com/fcitx/fcitx5) — the input method behind rApp's smooth writing-panel input.
- [Flutter](https://github.com/flutter/flutter) and [GTK](https://www.gtk.org/) — user interfaces.
- [Tokio](https://github.com/tokio-rs/tokio), [Quinn](https://github.com/quinn-rs/quinn), and [rustls](https://github.com/rustls/rustls) — networking foundations.
