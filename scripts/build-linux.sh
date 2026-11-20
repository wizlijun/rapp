#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Arch/Omarchy: rust, gtk4, clang, cmake, ninja, pkgconf,
# gtk3, at-spi2-core, libxkbcommon, libayatana-appindicator, and Flutter >= 3.50.0.
flutter_bin="${FLUTTER:-flutter}"
if ! command -v "$flutter_bin" >/dev/null && [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
  flutter_bin="$HOME/development/flutter/bin/flutter"
fi
# Older Linux engines clear the GL context before GTK finishes the frame.
# 3.50 includes flutter/flutter#192137; do not silently ship the crash-prone
# engine again when building from a different machine or an older default SDK.
flutter_info=$("$flutter_bin" --version --machine)
printf '%s' "$flutter_info" | python3 -c '
import json,re,sys
v=json.load(sys.stdin).get("frameworkVersion", "")
m=re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v)
if not m or tuple(map(int,m.groups())) < (3,50,0):
    sys.exit(f"Linux builds require stable Flutter >= 3.50.0 (found {v}); set FLUTTER to the matching SDK executable.")
'
# Cargo resolves custom/shared target directories, including relative paths.
# Copy from that same directory so cached builds cannot bundle stale workers.
target_dir=$(cargo metadata --manifest-path rust/Cargo.toml --locked --no-deps --format-version 1 |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
# Use the portable x86-64 CPU backend, never the build machine's instruction set.
export GGML_NATIVE=OFF GGML_AVX=OFF GGML_AVX2=OFF GGML_FMA=OFF GGML_F16C=OFF
cargo build --manifest-path rust/Cargo.toml --release --locked -p rapp-client-core -p rapp-client-gtk -p rapp-hub -p rapp-service -p rapp-term -p rapp-cli -p rapp-host-linux -p rapp-speech-linux
version=$(python3 -c 'import tomllib; print(tomllib.load(open("rust/Cargo.toml", "rb"))["workspace"]["package"]["version"])')
(cd gui && "$flutter_bin" build linux --release --dart-define="RAPP_VERSION=$version")
bundle=gui/build/linux/x64/release/bundle
# Flutter writes the GUI as rapp on every build; expose one stable CLI/GUI entry.
mv -f "$bundle/rapp" "$bundle/rapp-gui"
install -m755 scripts/linux/rapp "$bundle/rapp"
# Replace workers atomically: an app/session may still be running this bundle.
for binary in rapp-client rapp-session rapp-host rapp-hub rapp-service rapp-term rapp-cli rapp-speech; do
  staged=$(mktemp "$bundle/.$binary.XXXXXX")
  install -m755 "$target_dir/release/$binary" "$staged"
  mv -f "$staged" "$bundle/$binary"
done
printf '%s\n' "$flutter_info" > "$bundle/FLUTTER-INFO.json"
printf 'Built %s/%s/rapp and rapp-client\n' "$PWD" "$bundle"
