#!/bin/bash
# Build the iOS app. Usage: build-ios.sh [sim|device|ipa] [--install <udid>]
#   sim     arm64 simulator app            -> gui/build/ios/iphonesimulator/Runner.app
#   device  development-signed ipa         -> gui/build/ios/ipa/ (with --install: installed and launched on <udid>)
#   ipa     app-store ipa for TestFlight   -> gui/build/ios/ipa/
# Needs no key and passes no --dart-define: the key and relay address are typed into the app at run time.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-sim}
shift || true
udid=
if [ "${1:-}" = "--install" ]; then
  udid=${2:?usage: build-ios.sh [sim|device|ipa] [--install <udid>]}
fi
flutter=${FLUTTER:-$HOME/development/flutter/bin/flutter}
bundle=com.rapphub.rapp
export PATH=$HOME/.cargo/bin:$PATH

hub() { (cd "$repo/rust" && cargo build --release -p rapp-hub-ffi --target "$1"); }

case $mode in
sim)
  hub aarch64-apple-ios-sim
  "$repo/gui/packages/rapp_rime/scripts/fetch.sh"
  (cd "$repo/gui" && "$flutter" build ios --simulator)
  if [ -n "$udid" ]; then
    xcrun simctl install "$udid" "$repo/gui/build/ios/iphonesimulator/Runner.app"
    xcrun simctl launch "$udid" $bundle
  fi
  ;;
device|ipa)
  hub aarch64-apple-ios
  "$repo/gui/packages/rapp_rime/scripts/fetch.sh"
  method=development
  [ "$mode" = ipa ] && method=app-store
  (cd "$repo/gui" && "$flutter" build ipa --export-method $method)
  if [ "$mode" = device ] && [ -n "$udid" ]; then
    ipa=$(ls "$repo"/gui/build/ios/ipa/*.ipa | head -1)
    xcrun devicectl device install app --device "$udid" "$ipa"
    xcrun devicectl device process launch --device "$udid" --terminate-existing $bundle
  fi
  ;;
*)
  echo "usage: build-ios.sh [sim|device|ipa] [--install <udid>]" >&2
  exit 2
  ;;
esac
