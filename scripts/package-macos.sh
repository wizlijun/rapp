#!/bin/bash
# Build dist/rapp-<version>.pkg and dist/rapp.dmg (GUI + service + hub + Swift
# host/client in one app)
# and dist/rapp-relay-x86_64-linux (static, for the VPS) plus its systemd unit.
# Needs: Xcode, cargo ($HOME/.cargo/bin), flutter ($HOME/development/flutter/bin).
#
# Signing identity order (scripts/lib/sign-check.sh): RAPP_SIGN_APP (a SHA-1;
# set but empty = force ad-hoc) > "Developer ID Application" (hardened runtime,
# timestamp) > "Apple Development" > ad-hoc. "Apple Distribution" is never used.
# With a "Developer ID Installer" identity the pkg is signed too, and if the
# notarytool profile exists (xcrun notarytool store-credentials rapp-notary ...)
# the pkg is notarized and stapled. Override with RAPP_SIGN_PKG / RAPP_NOTARY_PROFILE.
# Sub-programs get fixed identifiers (com.rapp.service/hub/host/client) so the
# designated requirement stays stable. An ad-hoc result (cdhash requirement)
# fails the build unless RAPP_ALLOW_ADHOC=1 (local builds only).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH"
DIST=$ROOT/dist
source "$ROOT/scripts/lib/sign-check.sh"
source "$ROOT/scripts/lib/release.sh"
# By SHA-1: names can repeat (an expired and a renewed cert), hashes cannot.
identity() { security find-identity -v -p basic | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"$1:.*/\1/p" | head -1; }
read -r KIND SIGN_ID < <(pick_identity "$(security find-identity -v -p basic)" "${RAPP_SIGN_APP+set}" "${RAPP_SIGN_APP-}")
SIGN_PKG=${RAPP_SIGN_PKG-$(identity "Developer ID Installer")}
NOTARY=${RAPP_NOTARY_PROFILE:-rapp-notary}
echo "== signing: app $KIND; pkg ${SIGN_PKG:-unsigned}"
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
# Inside out: frameworks, helpers (with fixed identifiers), then the app (keeping its entitlements).
SIGN=(codesign --force $(runtime_flags "$KIND") --sign "$SIGN_ID")
if [ "$KIND" != adhoc ]; then
    "${SIGN[@]}" "$APP"/Contents/Frameworks/*.framework
fi
# Identifiers: -i com.rapp.service / com.rapp.hub / com.rapp.host / com.rapp.client (EXPECTED_IDS).
for pair in $EXPECTED_IDS; do
    "${SIGN[@]}" -i "${pair#*:}" "$APP/Contents/MacOS/${pair%%:*}"
done
"${SIGN[@]}" --preserve-metadata=entitlements "$APP"
codesign --verify --deep --strict "$APP"
for pair in $EXPECTED_IDS; do
    got=$(identifier_of "$(codesign -d -v "$APP/Contents/MacOS/${pair%%:*}" 2>&1)")
    if [ "$got" != "${pair#*:}" ]; then
        echo "identifier of ${pair%%:*} is '$got', expected ${pair#*:}" >&2
        exit 1
    fi
done
DR=$(codesign -d -r- "$APP" 2>&1)
echo "$DR"
if is_cdhash_dr "$DR" && [ "${RAPP_ALLOW_ADHOC-}" != 1 ]; then
    echo "release build is ad-hoc (cdhash DR); set RAPP_ALLOW_ADHOC=1 for local builds" >&2
    exit 1
fi

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
if [ -n "$SIGN_PKG" ] && [ "$KIND" = devid ] && xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
    echo "== notarize (profile $NOTARY)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY" --wait
    xcrun stapler staple "$PKG"
elif [ -n "$SIGN_PKG" ]; then
    echo "!! pkg signed but not notarized (no Developer ID app signature or no notarytool profile \"$NOTARY\")"
fi

echo "== release outputs (zip, latest.json)"
ZIP=$DIST/rapp-$VERSION-macos-arm64.zip
ditto -c -k --keepParent "$APP" "$ZIP"
RELEASE_BASE=${RAPP_RELEASE_BASE:-https://github.com/wizlijun/rapp-releases/releases/download/v$VERSION}
write_manifest "$DIST/latest.json" "$VERSION" "$RELEASE_BASE/rapp-$VERSION-macos-arm64.zip" \
    "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" "$(stat -f %z "$ZIP")" "${RAPP_RELEASE_NOTES-}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
plutil -convert xml1 -o /dev/null "$DIST/latest.json"
echo "publish: gh release create v$VERSION --repo wizlijun/rapp-releases \"$ZIP\" \"$DIST/latest.json\" \"$PKG\" --title v$VERSION"

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
