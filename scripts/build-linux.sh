#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Arch/Omarchy: rust, gtk4, clang, cmake, ninja, pkgconf,
# gtk3, libayatana-appindicator, and Flutter with Dart >= 3.12.1.
flutter_bin="${FLUTTER:-flutter}"
if ! command -v "$flutter_bin" >/dev/null && [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
  flutter_bin="$HOME/development/flutter/bin/flutter"
fi
cargo build --manifest-path rust/Cargo.toml --release --locked -p rapp-client-core -p rapp-client-gtk -p rapp-hub -p rapp-service -p rapp-term
version=$(python3 -c 'import tomllib; print(tomllib.load(open("rust/Cargo.toml", "rb"))["workspace"]["package"]["version"])')
(cd gui && "$flutter_bin" build linux --release --dart-define="RAPP_VERSION=$version")
bundle=gui/build/linux/x64/release/bundle
# Replace workers atomically: an app/session may still be running this bundle.
for binary in rapp-client rapp-session rapp-hub rapp-service rapp-term; do
  staged=$(mktemp "$bundle/.$binary.XXXXXX")
  install -m755 "rust/target/release/$binary" "$staged"
  mv -f "$staged" "$bundle/$binary"
done
printf 'Built %s/%s/rapp and rapp-client\n' "$PWD" "$bundle"
