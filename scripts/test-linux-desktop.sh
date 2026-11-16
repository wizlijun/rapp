#!/usr/bin/env bash
# GTK3 runner smoke test on a private, headless Broadway display.
set -euo pipefail
cd "$(dirname "$0")/.."
ephemeral="$PWD/gui/linux/flutter/ephemeral"
work=$(mktemp -d /tmp/rapp-desktop-test.XXXXXX)
desktop_pid=
mkdir -m 700 "$work/runtime"
cleanup() {
  if [[ -n "$desktop_pid" ]]; then
    kill "$desktop_pid" 2>/dev/null || true
    wait "$desktop_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
clang++ -std=c++17 -Wall -Wextra -Wno-unused-parameter gui/linux/tests/windows_smoke.cc \
  gui/linux/runner/rapp_candidates.cc gui/linux/runner/rapp_candidates_gtk.cc \
  -I"$ephemeral" $(pkg-config --cflags --libs gtk+-3.0) \
  -L"$ephemeral" -lflutter_linux_gtk -Wl,-rpath,"$ephemeral" -o "$work/test"
display=:$((100 + $$ % 50000))
env XDG_RUNTIME_DIR="$work/runtime" broadwayd --unixsocket="$work/http.sock" "$display" > "$work/broadway.log" 2>&1 &
desktop_pid=$!
for ((i=0; i<50; i++)); do
  [[ -S "$work/http.sock" ]] && break
  if ! kill -0 "$desktop_pid" 2>/dev/null; then
    cat "$work/broadway.log" >&2
    exit 1
  fi
  sleep 0.02
done
dbus-run-session -- env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=broadway BROADWAY_DISPLAY="$display" \
  XDG_RUNTIME_DIR="$work/runtime" NO_AT_BRIDGE=1 GIO_USE_VFS=local \
  G_DEBUG=fatal-criticals "$work/test"
