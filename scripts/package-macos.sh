#!/bin/bash
# Build dist/rapp-<version>.pkg and dist/rapp.dmg (GUI + service + hub + Swift
# host/client in one app)
# and dist/rapp-relay-x86_64-linux (static, for the VPS) plus its systemd unit.
# Needs: Xcode, cargo ($HOME/.cargo/bin), flutter ($HOME/development/flutter/bin).
#
# Signing: with a "Developer ID Application" identity in the keychain the app is
# signed with it (hardened runtime, timestamp), with a "Developer ID Installer"
# identity the pkg is signed too, and if the notarytool profile exists
# (xcrun notarytool store-credentials rapp-notary ...) the pkg is notarized and
# stapled. Override with RAPP_SIGN_APP / RAPP_SIGN_PKG / RAPP_NOTARY_PROFILE.
# Without them everything is ad-hoc signed, as before.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH"
DIST=$ROOT/dist
# By SHA-1: names can repeat (an expired and a renewed cert), hashes cannot.
identity() { security find-identity -v -p basic | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"$1:.*/\1/p" | head -1; }
SIGN_APP=${RAPP_SIGN_APP-$(identity "Developer ID Application")}
SIGN_PKG=${RAPP_SIGN_PKG-$(identity "Developer ID Installer")}
NOTARY=${RAPP_NOTARY_PROFILE:-rapp-notary}
echo "== signing: app ${SIGN_APP:-ad-hoc}; pkg ${SIGN_PKG:-unsigned}"
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
# Inside out: frameworks, helpers, then the app (keeping its entitlements).
if [ -n "$SIGN_APP" ]; then
    SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_APP")
    "${SIGN[@]}" "$APP"/Contents/Frameworks/*.framework
else
    SIGN=(codesign --force --sign -)
fi
for b in rapp-service rapp-hub rapp-host rapp-client; do
    "${SIGN[@]}" "$APP/Contents/MacOS/$b"
done
"${SIGN[@]}" --preserve-metadata=entitlements "$APP"
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
PKG=$DIST/rapp-$VERSION.pkg
productbuild --quiet ${SIGN_PKG:+--sign "$SIGN_PKG" --timestamp} --package "$DIST/component.pkg" "$PKG"
rm "$DIST/component.plist" "$DIST/component.pkg"
if [ -n "$SIGN_PKG" ] && [ -n "$SIGN_APP" ] && xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
    echo "== notarize (profile $NOTARY)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY" --wait
    xcrun stapler staple "$PKG"
elif [ -n "$SIGN_PKG" ]; then
    echo "!! pkg signed but not notarized (no Developer ID app signature or no notarytool profile \"$NOTARY\")"
fi

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
