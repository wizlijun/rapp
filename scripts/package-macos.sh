#!/bin/bash
# Build dist/rapp-<version>.pkg and dist/rapp.dmg (GUI + service + hub + Swift
# host/client in one app)
# and dist/rapp-relay-x86_64-linux (static, for the VPS) plus its systemd unit.
# Needs: Xcode, cargo ($HOME/.cargo/bin), flutter ($HOME/development/flutter/bin).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH"
DIST=$ROOT/dist
rm -rf "$DIST" && mkdir -p "$DIST"

echo "== swift (rapp-host, rapp-client)"
swift build -c release

echo "== rust (rapp-service, rapp-hub, rapp-relay)"
(cd rust && cargo build --release -p rapp-service -p rapp-hub -p rapp-relay)

echo "== flutter (rapp.app)"
# Universal builds fail in lipo with this Xcode; the GUI ships arm64 only.
(cd gui && FLUTTER_XCODE_ARCHS=arm64 flutter build macos --release)

echo "== bundle"
APP=$DIST/stage/rapp.app
mkdir -p "$DIST/stage"
cp -R gui/build/macos/Build/Products/Release/rapp.app "$APP"
cp rust/target/release/rapp-service rust/target/release/rapp-hub "$APP/Contents/MacOS/"
cp .build/release/rapp-host .build/release/rapp-client "$APP/Contents/MacOS/"
# Ad-hoc signing: helpers first, then the app (keeping its entitlements).
for b in rapp-service rapp-hub rapp-host rapp-client; do
    codesign --force --sign - "$APP/Contents/MacOS/$b"
done
codesign --force --sign - --preserve-metadata=entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "== pkg (installs to /Applications, starts the LaunchAgent, opens the GUI)"
VERSION=$(sed -n 's/^version: \([0-9.]*\).*/\1/p' gui/pubspec.yaml)
# Not relocatable: otherwise Installer "upgrades" any other rapp.app it finds
# (e.g. gui/build/...) instead of writing /Applications/rapp.app.
# pkgbuild on macOS 27 prints "write: Permission denied" x4 on stderr; harmless.
pkgbuild --analyze --root "$DIST/stage" "$DIST/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$DIST/component.plist"
pkgbuild --root "$DIST/stage" --component-plist "$DIST/component.plist" \
    --install-location /Applications --scripts scripts/pkg \
    --identifier com.rapp.pkg --version "$VERSION" "$DIST/component.pkg" >/dev/null
productbuild --quiet --package "$DIST/component.pkg" "$DIST/rapp-$VERSION.pkg"
rm "$DIST/component.plist" "$DIST/component.pkg"

ln -s /Applications "$DIST/stage/Applications"
hdiutil create -quiet -volname rapp -srcfolder "$DIST/stage" -ov -format UDZO "$DIST/rapp.dmg"
rm -rf "$DIST/stage"

echo "== relay for Linux (static musl)"
# No cross gcc needed: ring's C is built freestanding with Apple clang,
# archived with rustup's llvm-ar and linked by rust-lld against Rust's musl.
rustup target add x86_64-unknown-linux-musl >/dev/null
rustup component add llvm-tools >/dev/null
LLVM_AR=$(ls "$(rustc --print sysroot)"/lib/rustlib/*/bin/llvm-ar | head -1)
(cd rust && CC_x86_64_unknown_linux_musl=clang \
    CFLAGS_x86_64_unknown_linux_musl="-ffreestanding --target=x86_64-unknown-linux-gnu -DRING_CORE_NOSTDLIBINC=1" \
    AR_x86_64_unknown_linux_musl="$LLVM_AR" \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
    cargo build --release -p rapp-relay --target x86_64-unknown-linux-musl)
cp rust/target/x86_64-unknown-linux-musl/release/rapp-relay "$DIST/rapp-relay-x86_64-linux"
cp scripts/rapp-relay.service "$DIST/"

echo "== done"
ls -lh "$DIST"
