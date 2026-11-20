#!/bin/bash
# Drives the installed app on a simulator with real HID key events (simkey) and saves a screenshot after each
# step under out/<label>/. Test tool only: simkey and hwkb use CoreSimulator/SimulatorKit private API.
#
# usage: sim.sh <sim udid> prep
#        sim.sh <sim udid> <label> [scenario...]     scenarios: builtin repeat compose (default: all three, in order)
#
# prep: makes the system's 简体拼音 the simulator's first input source (so a system candidate bar would show if the
# system input method ever got the keys), reboots the simulator, turns 「实体键盘用内置输入法」 on in the app's
# prefs file and launches the app. The script cannot tap, so then, by hand: set up access, open a session, open the
# writing panel (caret in it, empty), and run the scenarios. If the prefs file is somewhere else (the device has an
# id), turn the switch on in 设置 by hand once; it stays on.
#
# builtin  panel open: n i h a o → composition underlined, 「你好」 in the candidate row; 1 → 你好 committed.
# repeat   panel open: hold ⌫ 1.5 s → several characters gone; hold a → several a in the composition.
# compose  Esc closes the panel, n i on the session screen → the panel opens with ni in Rime's composition (not
#          English "ni" committed); Space 1 → 你1 in that order.
# No screenshot may show the system's candidate bar.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
U=${1:?usage: sim.sh <udid> prep | <udid> <label> [scenario...]}
B=com.rapphub.rapp
for t in simkey hwkb; do
  [ -x "$t" ] && [ "$t" -nt "$t.m" ] || clang -fobjc-arc -framework Foundation -o "$t" "$t.m" || exit 1
done

if [ "${2:-}" = prep ]; then
  xcrun simctl boot "$U" 2>/dev/null
  xcrun simctl spawn "$U" defaults write -g AppleKeyboards -array \
    "zh_Hans-Pinyin@sw=Pinyin-Simplified;hw=US" "en_US@sw=QWERTY;hw=Automatic"
  xcrun simctl shutdown "$U"; xcrun simctl boot "$U"; xcrun simctl bootstatus "$U" >/dev/null; sleep 10
  xcrun simctl terminate "$U" $B 2>/dev/null
  data=$(xcrun simctl get_app_container "$U" $B data) || exit 1
  prefs="$data/Library/Application Support/rapp/local/gui.json"
  mkdir -p "$(dirname "$prefs")"
  python3 -I - "$prefs" <<'EOF'
import json, sys
p = sys.argv[1]
try:
    j = json.load(open(p))
except Exception:
    j = {}
j["rime_enabled"] = True
json.dump(j, open(p, "w"))
print("rime_enabled on in", p)
EOF
  ./hwkb "$U" on >/dev/null
  xcrun simctl launch "$U" $B >/dev/null
  echo "now open a session and its writing panel by hand, then: sim.sh $U <label> builtin repeat compose"
  exit 0
fi

L=${2:?label}; shift 2
OUT=$here/out/$L; mkdir -p "$OUT"
SC=${*:-builtin repeat compose}
# The simulator drops the hardware keyboard after some events: re-assert it every 0.3 s.
(while :; do ./hwkb "$U" on >/dev/null 2>&1; sleep 0.3; done) & LOOP=$!
trap 'kill $LOOP 2>/dev/null' EXIT
sleep 1

step() { local n=$1; shift; [ $# -gt 0 ] && ./simkey "$U" "$@"; sleep 0.8; xcrun simctl io "$U" screenshot "$OUT/$n.png" >/dev/null 2>&1; echo "$n"; }

for s in $SC; do case $s in
builtin)
  step a00-start
  step a01-nihao n i h a o
  step a02-select1 1
  ;;
repeat)
  step e01-type c e s h i SPACE
  step e02-hold-bs HOLD:BS:1500
  step e03-hold-letter HOLD:a:1500
  step e04-esc ESC
  ;;
compose)
  # Esc with nothing composing closes the panel (the text stays); the session's picture has the keys again.
  step c01-panel-closed ESC
  step c02-compose-ni n i
  step c03-space-1 SPACE 1
  ;;
*) echo "unknown scenario $s" >&2 ;;
esac; done
