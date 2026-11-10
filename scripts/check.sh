#!/bin/bash
# Build everything (optimized, the way it is run) and run the unit tests.
# The full output goes to .build-logs/check.log; the last line is EXIT=<status>.
cd "$(dirname "$0")/.." || exit 1
mkdir -p .build-logs
{
    swift build -c release 2>&1 && swift test 2>&1
    echo "EXIT=$?"
} | tee .build-logs/check.log
