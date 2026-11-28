#!/bin/bash
# Build the iOS app. Usage: [RAPP_SPEECH=apple|wx] build-ios.sh [sim|device|ipa] [--install <udid>]
#   RAPP_SPEECH picks the speech engine built in (wx offline ASR design §5.3): apple (default, the system's)
#   or wx (WeChat IME's offline model; its model files are copied to the phone separately, never bundled).
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
speech=${RAPP_SPEECH:-apple}
case $speech in
apple | wx) ;;
*)
  echo "RAPP_SPEECH is apple or wx, not '$speech'" >&2
  exit 2
  ;;
esac
# Flutter hands FLUTTER_XCODE_<name> to xcodebuild as the build setting <name> (gui/Speech.xcconfig).
export FLUTTER_XCODE_RAPP_SPEECH=$speech

# wx: the speech engine rides inside the hub's library (its speech-wx feature; iOS links one Rust static
# library), built with dotprod so the model's int8 kernels inline `sdot` (design §7.4: A13 / iPhone 11 or later).
hub_args=()
if [ "$speech" = wx ]; then
  hub_args=(--features speech-wx)
  export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-Ctarget-feature=+dotprod"
  export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS="-Ctarget-feature=+dotprod"
fi
hub() { (cd "$repo/rust" && cargo build --release -p rapp-hub-ffi --target "$1" ${hub_args[@]+"${hub_args[@]}"}); }

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
