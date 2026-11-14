#!/usr/bin/env bash
# Build an Omarchy/Arch x86_64 package and a portable bundle for the same release.
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root=$PWD
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
./scripts/build-linux.sh
mkdir -p dist
# Flutter may migrate files for a different SDK. Do not mislabel such a build.
[[ -z $(git status --porcelain) ]] || { echo 'Build modified source files; review and commit before packaging.' >&2; exit 1; }
work=$(mktemp -d "$repo_root/dist/.linux-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
name="rapp-$version-omarchy-x86_64"
stage="$work/$name"
mkdir -p "$stage"
cp -a gui/build/linux/x64/release/bundle/. "$stage/"
cp gui/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png "$stage/rapp.png"
cp scripts/linux/rapp.desktop "$stage/rapp.desktop"
python3 - "$stage" <<'PY'
import json, platform, subprocess, sys
from pathlib import Path
stage=Path(sys.argv[1])
commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
info={'source_commit':commit,'source_url':f'https://github.com/wizlijun/rapp/tree/{commit}',
      'platform':'Omarchy / Arch Linux x86_64','architecture':platform.machine(),
      'rust':subprocess.check_output(['rustc','--version'],text=True).strip(),
      'runtime_packages':subprocess.check_output(['pacman','-Q','glibc','gtk3','gtk4','libayatana-appindicator'],text=True).splitlines()}
(stage/'BUILD-INFO.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
(stage/'README-LINUX.txt').write_text('''rapp for Omarchy / Arch Linux x86_64

Recommended installation: download the matching .pkg.tar.zst release asset, then:
  sudo pacman -U ./rapp-omarchy-*.pkg.tar.zst
Open rapp from the application launcher or run `rapp`.
Remove the installed package with `sudo pacman -R rapp-omarchy`.

Portable bundle:
  sudo pacman -S --needed gtk3 gtk4 libayatana-appindicator
  ./rapp
Keep the entire directory together (lib/, data/, and the worker executables).
Requires glibc >= 2.39, GTK4 >= 4.12, and a graphical Wayland or X11 session.
This build targets current Omarchy/Arch; it is not a generic all-distributions binary.

Remote applications render inside the app. The standalone `./rapp-client` is
also available. Linux hosting, embedded detach/attach, and image/file attachments
are not implemented. Local configuration and saved hosts are not included.
The package does not automatically start a background service at installation.
See BUILD-INFO.json for the exact source revision and build environment.
''')
PY
archive="$repo_root/dist/$name.tar.gz"
[[ ! -e "$archive" ]] || { echo "Already exists: $archive" >&2; exit 1; }
tar -C "$work" -czf "$archive" "$name"
cp "$archive" "$work/"
cat > "$work/PKGBUILD" <<PKG
pkgname=rapp-omarchy
pkgver=$version
pkgrel=1
pkgdesc='Remote Mac apps embedded in a Linux desktop client (Omarchy/Arch)'
arch=('x86_64')
url='https://github.com/wizlijun/rapp'
depends=('glibc>=2.39' 'gcc-libs' 'gtk3' 'gtk4>=4.12' 'libayatana-appindicator')
provides=('rapp=$version')
conflicts=('rapp')
options=('!strip' '!debug')
source=('$name.tar.gz')
sha256sums=('$(sha256sum "$archive" | cut -d' ' -f1)')
package() {
  install -d "\$pkgdir/opt/rapp" "\$pkgdir/usr/bin"
  cp -a "\$srcdir/$name/." "\$pkgdir/opt/rapp/"
  for binary in rapp rapp-client rapp-hub rapp-service rapp-term; do
    ln -s "/opt/rapp/\$binary" "\$pkgdir/usr/bin/\$binary"
  done
  install -Dm644 "\$srcdir/$name/rapp.desktop" "\$pkgdir/usr/share/applications/rapp.desktop"
  install -Dm644 "\$srcdir/$name/rapp.png" "\$pkgdir/usr/share/icons/hicolor/256x256/apps/rapp.png"
}
PKG
(cd "$work" && PKGDEST="$repo_root/dist" makepkg --noconfirm)
(cd dist && sha256sum "$name.tar.gz" "rapp-omarchy-$version-1-x86_64.pkg.tar.zst" > "$name-SHA256SUMS")
printf 'Release artifacts are in %s/dist\n' "$repo_root"
