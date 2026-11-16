#!/usr/bin/env bash
# Headless CandidateLease tests on a private bus; never contact desktop Fcitx.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(cd -- "$source_dir/../../.." && pwd)
headers=${FLUTTER_ENGINE_HEADERS:-$repo_root/gui/linux/flutter/ephemeral}
if [[ ! -f "$headers/flutter_linux/flutter_linux.h" ]]; then
  flutter_bin=${FLUTTER:-$(command -v flutter || true)}
  if [[ -n "$flutter_bin" ]]; then
    flutter_root=$(dirname -- "$(dirname -- "$(readlink -f -- "$flutter_bin")")")
    headers="$flutter_root/bin/cache/artifacts/engine/linux-x64"
  fi
fi
[[ -f "$headers/flutter_linux/flutter_linux.h" ]] || {
  echo 'Set FLUTTER_ENGINE_HEADERS to the directory containing flutter_linux/.' >&2
  exit 1
}
test_dir=$(mktemp -d -t rapp-candidates-bridge.XXXXXX)
printf 'Private candidate bridge test artifacts: %s\n' "$test_dir"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -g \
  -I"$source_dir" -I"$headers" \
  "$source_dir/rapp_candidates.cc" "$source_dir/tests/candidates_bridge_test.cc" \
  -o "$test_dir/candidates_bridge_test" $(pkg-config --cflags --libs gtk+-3.0)
dbus-run-session -- env -u DISPLAY -u WAYLAND_DISPLAY \
  RAPP_CANDIDATES_ISOLATED_TEST=1 "$test_dir/candidates_bridge_test"
