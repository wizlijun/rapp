#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Arch/Omarchy: rust, gtk4, clang, cmake, ninja, pkgconf,
# gtk3, libayatana-appindicator, and Flutter with Dart >= 3.12.1.
flutter_bin="${FLUTTER:-flutter}"
if ! command -v "$flutter_bin" >/dev/null && [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
  flutter_bin="$HOME/development/flutter/bin/flutter"
fi
cargo build --manifest-path rust/Cargo.toml --release --locked -p rapp-client-core -p rapp-client-gtk -p rapp-hub -p rapp-service -p rapp-relay
(cd gui && "$flutter_bin" build linux --release)
bundle=gui/build/linux/x64/release/bundle
cp rust/target/release/{rapp-client,rapp-session,rapp-hub,rapp-service} "$bundle/"
printf 'Built %s/%s/rapp and rapp-client\n' "$PWD" "$bundle"
