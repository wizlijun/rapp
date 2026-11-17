#!/bin/bash
# Build everything (optimized, the way it is run) and run the unit tests.
# The full output goes to .build-logs/check.log; the last line is EXIT=<status>.
cd "$(dirname "$0")/.." || exit 1
export PATH="$HOME/.cargo/bin:$PATH"
mkdir -p .build-logs
ios_tests() {
    set -o pipefail
    xcodebuild -scheme RappCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test 2>&1 | tail -15
}
{
    swift build -c release 2>&1 && swift test 2>&1 \
        && (cd rust && cargo build --release -p rapp-hub-ffi --target aarch64-apple-ios-sim 2>&1) \
        && (ios_tests)
    echo "EXIT=$?"
} | tee .build-logs/check.log
