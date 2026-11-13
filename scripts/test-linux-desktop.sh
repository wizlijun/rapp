#!/usr/bin/env bash
# GTK3 runner smoke test; use a graphical session or a GTK Broadway display.
set -euo pipefail
cd "$(dirname "$0")/.."
ephemeral="$PWD/gui/linux/flutter/ephemeral"
binary=$(mktemp /tmp/rapp-desktop-test.XXXXXX)
trap 'rm -f "$binary"' EXIT
clang++ -std=c++17 -Wall -Wextra -Wno-unused-parameter gui/linux/tests/windows_smoke.cc \
  -I"$ephemeral" $(pkg-config --cflags --libs gtk+-3.0) \
  -L"$ephemeral" -lflutter_linux_gtk -Wl,-rpath,"$ephemeral" -o "$binary"
G_DEBUG=fatal-criticals "$binary"
