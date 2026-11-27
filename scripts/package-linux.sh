#!/usr/bin/env bash
# Build an Omarchy/Arch x86_64 package and a portable bundle for the same release.
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root=$PWD
package_revision=${PKGREL-1}
[[ $package_revision =~ ^[1-9][0-9]*$ ]] || { echo 'PKGREL must be a positive integer.' >&2; exit 1; }
# Keep release asset names compatible with LinuxUpdate. Revised portable archives
# have the same name, so put revisions in separate directories rather than overwrite.
default_dist="$repo_root/dist"
if [[ $package_revision != 1 ]]; then
  default_dist="$default_dist/pkgrel-$package_revision"
fi
dist_dir=${DIST_DIR:-$default_dist}
[[ $(uname -m) == x86_64 ]] || { echo 'This package targets x86_64.' >&2; exit 1; }
for tool in python3 makepkg fakeroot zstd tar; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
[[ -z $(git status --porcelain) ]] || { echo 'Commit source changes before packaging.' >&2; exit 1; }
version=$(python3 - <<'PY'
import tomllib
from pathlib import Path
print(tomllib.loads(Path('rust/Cargo.toml').read_text())['workspace']['package']['version'])
PY
)
name="rapp-$version-omarchy-x86_64"
package="rapp-omarchy-$version-$package_revision-x86_64.pkg.tar.zst"
checksums="$name-SHA256SUMS"
mkdir -p "$dist_dir"
dist_dir=$(cd "$dist_dir" && pwd -P)
for artifact in "$name.tar.gz" "$package" "$checksums"; do
  [[ ! -e "$dist_dir/$artifact" && ! -L "$dist_dir/$artifact" ]] || { echo "Already exists: $dist_dir/$artifact" >&2; exit 1; }
done
./scripts/build-linux.sh
# Flutter may migrate files for a different SDK. Do not mislabel such a build.
[[ -z $(git status --porcelain) ]] || { echo 'Build modified source files; review and commit before packaging.' >&2; exit 1; }
work=$(mktemp -d "$dist_dir/.linux-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage"
cp -a gui/build/linux/x64/release/bundle/. "$stage/"
cp gui/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png "$stage/rapp.png"
cp scripts/linux/rapp.desktop "$stage/rapp.desktop"
cp LICENSE "$stage/LICENSE"
cp -a rust/speech-linux/licenses "$stage/speech-licenses"
cp -a rust/host-linux/licenses "$stage/host-licenses"
python3 - "$stage" <<'PY'
import hashlib, json, platform, subprocess, sys
from pathlib import Path
stage=Path(sys.argv[1])
commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
info={'source_commit':commit,'source_url':f'https://github.com/wizlijun/rapp/tree/{commit}',
      'platform':'Omarchy / Arch Linux x86_64','architecture':platform.machine(),
      'flutter':json.loads((stage/'FLUTTER-INFO.json').read_text()),
      'flutter_engine_sha256':hashlib.sha256((stage/'lib/libflutter_linux_gtk.so').read_bytes()).hexdigest(),
      'rust':subprocess.check_output(['rustc','--version'],text=True).strip(),
      'runtime_packages':subprocess.check_output(['pacman','-Q','glibc','gtk3','gtk4','at-spi2-core','libxkbcommon','libayatana-appindicator'],text=True).splitlines()}
(stage/'BUILD-INFO.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
(stage/'README-LINUX.txt').write_text('''rApp for Omarchy / Arch Linux x86_64 (SSE4.2 CPU required for local speech)

Recommended installation: download the matching .pkg.tar.zst release asset, then:
  sudo pacman -U ./rapp-omarchy-*.pkg.tar.zst
Open rApp from the application launcher or run `rapp`.
Remove the installed package with `sudo pacman -R rapp-omarchy`.

Portable bundle:
  sudo pacman -S --needed gtk3 gtk4 at-spi2-core libxkbcommon libayatana-appindicator xdg-utils libpulse
  ./rapp
Keep the entire directory together (lib/, data/, and the worker executables).
Requires glibc >= 2.39, GTK4 >= 4.12, and a graphical Wayland or X11 session.
This build targets current Omarchy/Arch; it is not a generic all-distributions binary.

Hold the voice button or Right Alt to dictate. First use downloads a verified
142 MB Whisper base model to ~/.cache/rapp/speech (or XDG_CACHE_HOME).
Recordings can last up to five minutes. After release, capture stops immediately;
local recognition can take up to five minutes to finish on slower CPUs.
Recognition runs locally; Chinese is preferred when present in the system
language list (including LANGUAGE), otherwise the first language is used.
Audio stays in memory and is never saved or uploaded. Requires a PulseAudio-compatible server and libpulse.
Esc cancels; Tab edits before sending. Change the shortcut in the sidebar.
AI correction learning and prompt/chat modes use the shared LLM endpoint.
Gateway hotwords provide spelling context to local recognition on each recording.
Cached correction rules fix recognized words locally before sending or editing.
The input dock, corner quick-area toggle (staying beside 收起/输入 and 语音
whether the writing panel is open or closed), regrouped key bar (first row `Tab ⇧Tab Esc ⌃C
⌫ ⏎ ↑ ⋯`; second row `⌘C ⌘V ⌘T ⌘ ⌃ PgUp PgDn ← ↓ →` with inverted-T arrows
aligning `↓` under `↑` and `→` under `⋯`, terminal `PgUp`/`PgDn` history paging
or alt-screen keys, terminal `⌘T`, sticky `⌘` + letter rApp shortcuts, and
automatic `⌃`/`⌘` release when `⋯` folds), tool-aware phrase-strip
commands (新对话 / 换模型 / 压缩 / 恢复 / 用量 / 搜历史 Ctrl-R for Claude Code,
Codex, Gemini CLI, agy and opencode, hidden on plain shells and excluded from
input history), overview Open App
dropdown menu, overview Local column inbound sessions, OSC 7501 program
status, GUI app state rules client support, top-bar status queue, Needs You
direct jump, OSC 0/1/2 terminal titles (with · 2 numbering on clashes),
multi-terminal Ctrl+Shift+T / Ctrl+Shift+W / End Terminal / clean exit /
host `<dir> · <prog>` window titles, foreground-program terminal titles with
CLI subtitle, single-flight New Terminal, unified SessionBlock / FavoriteBlock
cards across the overview, top-bar session list and side-panel Sessions tab,
host-persisted session labels (custom title and note on session cards, standby
and stopped-terminal cards with one-tap restart carrying the label, and Local
column label management), overview device OS marks using official brand shapes
(detecting Omarchy via `/usr/share/omarchy/shell` vs Linux), favorite
Terminal restore/creation, text terminal restore (pre-boot 常用 · 终端 恢复,
Devices-tab saved-terminal recovery, zsh/bash/fish OSC 7502 shell hooks with
venv/conda reactivation and non-executing command prefill, secret-line filtering,
and 新建 / Ctrl+Shift+T starting in the current or last terminal's directory),
device headroom/load bars with 1-hour detail sparklines and Needs You resource
warnings, companion state service (`rapp-center`), event outbox and cross-device
StateSync / StateOut status queue, Needs You `推断` inferred waits, `别处开着`
open-elsewhere session cards (`/v1/watch`, `/v1/seen`, `/v1/desk/<fp>`, 状态服务
settings, and per-device `SetService` switches), intent-following
IME switching (local `fcitx5-remote` / `ibus` Chinese in the writing panel and
English on the stage, remote auto-English before stage keys, streamed terminal
`typeToCompose: false` default, and folded 本机 column when no local service is
present), remote macOS Terminal consent prompts with screen preservation,
`Ctrl+Shift+V` Linux terminal paste with Wayland selection roundtrip, and the
enlarged 3-line non-blocking `WaitCard` stage overlay (for slow `Ctrl+Shift+T`,
新建, 恢复, standby 启动 and device-tab shell opens, with queued counts and
automatic switch to a remote Mac's desktop on consent) share the macOS 0.15.59
layout and rules.

Remote applications render inside the app. The standalone `./rapp-client` is
also available with native per-app windows. Embedded sessions can detach and
reattach without reconnecting. This release uses protocol v16 (compatible with
macOS 0.15.35–0.15.59); update both peers when coming from protocol v15. Incoming GUI
state rules are forwarded by the Linux client to compatible hosts (such as
macOS 0.15.35+) and safely ignored by the Linux desktop/app host. Off-stage and
hidden/minimized embedded or detached sessions pause pictures but keep activity
signals, then resume from the existing canvas. Minimization requires compositor
support; Wayland does not provide general window-occlusion detection.
Text, images, files and typed clipboard data can
be pasted, transferred, cancelled and pinned; files stream to disk with resume.
Folders cannot be attached. This machine can host desktops on Omarchy/Hyprland,
compatible wlroots compositors, and X11. Hyprland (toplevel export/mapping) and
X11 (Composite) also share isolated applications across monitors, with window
focus, move, resize, close and cover protection. Other applications are excluded
from app captures even when they cover the target. Host clipboard observation,
typed paste, file upload/download, resume, view crops, adaptive network saving,
input source selection and AT-SPI menus/focus/password-field hints are supported.
X11 text insertion requires xdotool. Native features depend on the compositor
and applications exposing their corresponding protocols/accessibility metadata.
Hyprland toplevel export clips popups to their parent surface; X11 includes
separate popup surfaces. GNOME/KDE Wayland portal hosting is not implemented.
Verified Hyprland lock notifications allow password entry to a same-session
hyprlock/swaylock or verified Omarchy Quickshell lock screen. Other lock screens
require local unlock; a logind hint alone never authorizes automatic password
typing. Actual account unlock is not part of the isolated regression suite.
Writing panels optionally render inline candidates with Fcitx5's sumicandidates
addon (org.fcitx.Fcitx.SumiCandidates1). Without that separately installed addon,
the system candidate window remains available. Rapp does not install or restart
the input method. Composition and commits remain owned by the local input method.
Linux can share ports and text terminals. New terminal windows require a graphical
session, a supported terminal app, and a working systemd user manager.
They run in separate transient user services and survive a rapp-service restart.
Run `rapp share`, `rapp unshare`, `rapp hosts`, `rapp pipe`, `rapp term restore`
(`--list` / `--forget` / `<number|name>...`), `rapp center` (`on` / `off`),
`rapp load` (`pick` / `--top` / `--json`), or `rapp update`
(`status` / `check` / `rollback`, with `--json`) for CLI access; on Linux
online self-replacement is disabled (`not_launchd`, exit 7) and directs to the
release packages, while `rapp update status` reports the installed version.
No arguments opens the GUI; `./rapp-gui` opens it explicitly.
For direct LAN access, allow the service's UDP listener (default 22028) from the
intended peers. TCP 22029 (IPC) and TCP 28000-28999 (share numbers and visitor mappings) bind only to
localhost and do not need inbound LAN rules. UDP 22026 is for a separate relay.
Use Local / 本机 for the actual port and read-only UFW diagnostics; an empty log
does not prove that the network or firewall allows the connection.
Local configuration and saved hosts are not included.
The package does not automatically start a background service at installation.
In rApp, open Local / 本机 and click Start / 启动 to install and enable the user
systemd service. The service records text changes with git (install git to use it).
Start/restart also refreshes the executable path after moving a portable bundle.
Stop stops the current process; to turn off login startup, run:
  systemctl --user disable --now rapp-service.service

Data is in ~/rapp, or RAPP_HOME / the data-root pointer in $XDG_CONFIG_HOME/rapp
(~/.config/rapp by default). Upgrading copies old configuration without deleting
it, including saved hosts and projects from client-only installations.
Pinned text survives restart in clipboard/; binary pins are in files/.
Downloads use files/transfers/ (override with RAPP_DOWNLOADS). Credentials stay in local/ and are
excluded from git. The Data directory / 数据目录 section can change the location.
Linux logs are in $XDG_STATE_HOME/rapp (~/.local/state/rapp by default).
See BUILD-INFO.json for the exact source revision and build environment.
''')
PY
archive="$dist_dir/$name.tar.gz"
tar -C "$work" -czf "$archive" "$name"
cp "$archive" "$work/"
cat > "$work/PKGBUILD" <<PKG
pkgname=rapp-omarchy
pkgver=$version
pkgrel=$package_revision
pkgdesc='Remote apps, text terminals and port sharing (Omarchy/Arch)'
arch=('x86_64')
license=('GPL-3.0-only')
url='https://github.com/wizlijun/rapp'
depends=('glibc>=2.39' 'gcc-libs' 'gtk3' 'gtk4>=4.12' 'at-spi2-core' 'libxkbcommon' 'libayatana-appindicator' 'xdg-utils' 'systemd' 'libpulse')
optdepends=('git: data directory version history and remote synchronization' 'xdotool: text insertion into an X11 host desktop')
provides=('rapp=$version')
conflicts=('rapp')
options=('!strip' '!debug')
source=('$name.tar.gz')
sha256sums=('$(sha256sum "$archive" | cut -d' ' -f1)')
package() {
  install -d "\$pkgdir/opt/rapp" "\$pkgdir/usr/bin"
  cp -a "\$srcdir/$name/." "\$pkgdir/opt/rapp/"
  for binary in rapp rapp-client rapp-host rapp-hub rapp-service rapp-term rapp-center rapp-cli; do
    ln -s "/opt/rapp/\$binary" "\$pkgdir/usr/bin/\$binary"
  done
  install -Dm644 "\$srcdir/$name/LICENSE" "\$pkgdir/usr/share/licenses/rapp-omarchy/LICENSE"
  install -Dm644 "\$srcdir/$name/rapp.desktop" "\$pkgdir/usr/share/applications/rapp.desktop"
  install -Dm644 "\$srcdir/$name/rapp.png" "\$pkgdir/usr/share/icons/hicolor/256x256/apps/rapp.png"
}
PKG
(cd "$work" && PKGDEST="$dist_dir" makepkg --noconfirm)
(cd "$dist_dir" && sha256sum "$name.tar.gz" "$package" > "$checksums")
printf 'Release artifacts are in %s\n' "$dist_dir"
