#!/bin/bash
# Release manifest helpers (sourced by package-macos.sh and test-package.sh).

# Escape a string for use inside a JSON string literal.
json_escape() {
    local s=$1 out="" c i n=${#1} code
    for ((i = 0; i < n; i++)); do
        c=${s:i:1}
        case "$c" in
        '\') out+='\\' ;;
        '"') out+='\"' ;;
        $'\n') out+='\n' ;;
        $'\t') out+='\t' ;;
        $'\r') out+='\r' ;;
        *)
            # Bytes >= 0x80 (UTF-8) print as negative or large values: pass them through.
            code=$(printf '%d' "'$c" 2>/dev/null || echo 255)
            if [ "$code" -ge 0 ] && [ "$code" -lt 32 ]; then
                out+=$(printf '\\u%04x' "$code")
            else
                out+=$c
            fi
            ;;
        esac
    done
    printf '%s' "$out"
}

# write_manifest <out> <version> <url> <sha256> <size> <notes> <published_at>
write_manifest() {
    local out=$1 version=$2 url=$3 sha=$4 size=$5 notes=$6 at=$7
    cat >"$out" <<JSON
{
  "version": "$(json_escape "$version")",
  "published_at": "$(json_escape "$at")",
  "notes": "$(json_escape "$notes")",
  "assets": {
    "macos-arm64": {
      "url": "$(json_escape "$url")",
      "sha256": "$(json_escape "$sha")",
      "size": $size
    }
  }
}
JSON
}
