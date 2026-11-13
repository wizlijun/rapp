#!/bin/bash
# Build .build/RappTestPage.app (bundle id dev.rapp.testpage) for the measurement scripts.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product rapp-testpage
BIN="$(swift build -c release --show-bin-path)/rapp-testpage"
APP=.build/RappTestPage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/RappTestPage"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.rapp.testpage</string>
<key>CFBundleName</key><string>RappTestPage</string>
<key>CFBundleExecutable</key><string>RappTestPage</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$APP"
echo "$APP"
