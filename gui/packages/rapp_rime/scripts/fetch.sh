#!/bin/bash
# Fetch librime (static xcframeworks), the OpenCC tables and the 雾凇 (rime-ice) shared data for the plugin.
# Everything lands in git-ignored directories; every download is checked against a pinned sha256.
# Idempotent: when the expanded tree matches the recorded stamp it exits at once.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
v=$here/vendor
ios=$here/ios/rapp_rime
fw=$ios/Frameworks
inc=$ios/Sources/CRime/include
data=$ios/Sources/rapp_rime/RimeData

KIT_URL=https://github.com/thomfang/LibrimeKit-iOS/releases/download/v0.2.2/Frameworks.tgz
KIT_SHA=43a0921538827fedb2679e5d26bb389dec3759d44ccdcfd439e8ec21a7f93223
# Only its share/opencc tables are used. A tagged release (librime 1.16.1, the version LibrimeKit-iOS v0.2.2
# bundles), never the rolling `latest` nightly, whose asset names change when it moves.
DEPS_URL=https://github.com/rime/librime/releases/download/1.16.1/rime-deps-de4700e-macOS-universal.tar.bz2
DEPS_SHA=087e753056f092f644cc4a470f64ecf2cd9de18e684b220e0588f86f6b91dfcc
ICE_COMMIT=927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6
ICE_URL=https://codeload.github.com/iDvel/rime-ice/tar.gz/$ICE_COMMIT
ICE_SHA=3c78386c45eba9bada065300e3e2ffcbc267d50e839892a34fa3116eae9e1817
# Bump when the way the data is assembled changes (not the sources); Task 3 uses it in distribution_version.
DATA_REV=1

stamp="$KIT_SHA $DEPS_SHA $ICE_SHA $DATA_REV"
if [ -f "$v/stamp" ] && [ "$(cat "$v/stamp")" = "$stamp" ] && [ -f "$fw/librime.xcframework/Info.plist" ] \
  && [ -f "$inc/rime_api.h" ] && [ -f "$data/rapp_rime_data_version" ]; then
  exit 0
fi

mkdir -p "$v/dl"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fetch() { # file url sha
  local f=$v/dl/$1
  if [ ! -s "$f" ]; then
    if ! curl -fsSL -m 900 -o "$f.part" "$2"; then
      rm -f "$f.part"
      echo "下载 $1 失败（没联网，或者 GitHub 连不上）：$2" >&2
      echo "联网后重跑：gui/packages/rapp_rime/scripts/fetch.sh（或者直接重跑 scripts/build-ios.sh）" >&2
      exit 1
    fi
    mv "$f.part" "$f"
  fi
  if [ "$(sha "$f")" != "$3" ]; then
    echo "sha256 mismatch for $1 (want $3); delete vendor/dl/$1 and rerun fetch.sh" >&2
    exit 1
  fi
}
fetch librimekit.tgz "$KIT_URL" "$KIT_SHA"
deps=$(basename "$DEPS_URL") # named after the asset, so a cache of an older one is not mistaken for it
fetch "$deps" "$DEPS_URL" "$DEPS_SHA"
fetch rime-ice.tgz "$ICE_URL" "$ICE_SHA"

rm -rf "$v/src" "$fw" "$data" "$v/stamp"
mkdir -p "$v/src/ice" "$v/src/deps" "$fw" "$inc" "$data"
tar xzf "$v/dl/librimekit.tgz" -C "$fw"
tar xzf "$v/dl/rime-ice.tgz" -C "$v/src/ice" --strip-components 1
tar xjf "$v/dl/$deps" -C "$v/src/deps" share/opencc

for h in rime_api.h rime_api_deprecated.h rime_api_stdbool.h rime_levers_api.h; do
  cp "$fw/librime.xcframework/ios-arm64/Headers/$h" "$inc/"
done

# 雾凇: shared data only (no squirrel.yaml / weasel.yaml).
ice=$v/src/ice
for f in "$ice"/*.yaml "$ice"/*.txt "$ice"/LICENSE; do
  [ -e "$f" ] || continue
  case $(basename "$f") in squirrel.yaml | weasel.yaml) continue ;; esac
  cp "$f" "$data/"
done
for d in cn_dicts en_dicts lua; do cp -R "$ice/$d" "$data/$d"; done

# The iOS build's OpenCC is older than rime-ice's .json files (no "normalization", no TSCharactersExt), so write
# plain two-table configs, then lay rime-ice's own opencc/ over them.
mkdir -p "$data/opencc"
cp "$v/src/deps/share/opencc"/{TSPhrases,TSCharacters,STPhrases,STCharacters}.ocd2 "$data/opencc/"
cat >"$data/opencc/t2s.json" <<'JSON'
{"name": "t2s", "segmentation": {"type": "mmseg", "dict": {"type": "ocd2", "file": "TSPhrases.ocd2"}},
 "conversion_chain": [{"dict": {"type": "group", "dicts": [
   {"type": "ocd2", "file": "TSPhrases.ocd2"}, {"type": "ocd2", "file": "TSCharacters.ocd2"}]}}]}
JSON
cat >"$data/opencc/s2t.json" <<'JSON'
{"name": "s2t", "segmentation": {"type": "mmseg", "dict": {"type": "ocd2", "file": "STPhrases.ocd2"}},
 "conversion_chain": [{"dict": {"type": "group", "dicts": [
   {"type": "ocd2", "file": "STPhrases.ocd2"}, {"type": "ocd2", "file": "STCharacters.ocd2"}]}}]}
JSON
cp -R "$ice/opencc/." "$data/opencc/"

cat >"$data/default.custom.yaml" <<'YAML'
patch:
  schema_list:
    - schema: rime_ice
  menu/page_size: 9
YAML
echo "${ICE_COMMIT:0:7}-$DATA_REV" >"$data/rapp_rime_data_version"

rm -rf "$v/src"
echo "$stamp" >"$v/stamp"
du -sh "$fw" "$data"
