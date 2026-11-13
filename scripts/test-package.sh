#!/bin/bash
# Tests for scripts/lib/sign-check.sh and the packaging scripts. Feeds recorded
# `security find-identity` / `codesign -d` text to the pure functions; never runs
# security, codesign or package-macos.sh. Last line: ALL OK.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/sign-check.sh
source scripts/lib/release.sh

check() {
    local name=$1
    shift
    if ! "$@"; then
        echo "FAIL: $name" >&2
        exit 1
    fi
}
eq() { [ "$1" = "$2" ]; }
not() { ! "$@"; }

DEVID_SHA=1111111111111111111111111111111111111111
DEV_SHA=2222222222222222222222222222222222222222
DIST_SHA=3333333333333333333333333333333333333333
IDS_DEVID="  1) $DEVID_SHA \"Developer ID Application: X (T5G56DH47L)\""
IDS_DEV="  2) $DEV_SHA \"Apple Development: bruce lee (M753G3H4R8)\""
IDS_DIST="  3) $DIST_SHA \"Apple Distribution: Wuhan Fulin Technology Co., Ltd. (T5G56DH47L)\""
IDS_BOTH=$IDS_DEV$'\n'$IDS_DEVID$'\n'"     2 valid identities found"
IDS_DEV_ONLY=$IDS_DEV$'\n'"     1 valid identities found"
IDS_DIST_ONLY=$IDS_DIST$'\n'"     1 valid identities found"
IDS_ALL=$IDS_DIST$'\n'$IDS_DEV$'\n'$IDS_DEVID

check "pick prefers developer id" eq "$(pick_identity "$IDS_BOTH")" "devid $DEVID_SHA"
check "pick prefers developer id over distribution" eq "$(pick_identity "$IDS_ALL")" "devid $DEVID_SHA"
check "pick falls back to apple development" eq "$(pick_identity "$IDS_DEV_ONLY")" "dev $DEV_SHA"
check "pick with nothing is adhoc" eq "$(pick_identity "")" "adhoc -"
check "apple distribution alone is adhoc" eq "$(pick_identity "$IDS_DIST_ONLY")" "adhoc -"
check "apple distribution is skipped for apple development" eq "$(pick_identity "$IDS_DIST"$'\n'"$IDS_DEV")" "dev $DEV_SHA"
check "explicit empty RAPP_SIGN_APP forces adhoc" eq "$(pick_identity "$IDS_BOTH" set "")" "adhoc -"
check "explicit sha of a developer id is devid" eq "$(pick_identity "$IDS_BOTH" set "$DEVID_SHA")" "devid $DEVID_SHA"
check "explicit sha of apple development is custom" eq "$(pick_identity "$IDS_BOTH" set "$DEV_SHA")" "custom $DEV_SHA"
check "unset flag ignores the value" eq "$(pick_identity "$IDS_BOTH" unset "$DEV_SHA")" "devid $DEVID_SHA"

check "runtime for devid" grep -q -- '--options runtime' <(runtime_flags devid)
check "timestamp for devid" grep -q -- '--timestamp' <(runtime_flags devid)
for k in dev custom adhoc; do
    check "no runtime for $k" eq "$(runtime_flags "$k")" ""
done

DR_CDHASH='# designated => cdhash H"dee3c9aa11bb22cc33dd44ee55ff66778899aabb"'
DR_STABLE='designated => identifier "com.rapp.rapp" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: bruce lee (M753G3H4R8)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */'
check "cdhash dr detected" is_cdhash_dr "$DR_CDHASH"
check "stable dr is not cdhash" not is_cdhash_dr "$DR_STABLE"

CS_OUT=$'Executable=/x/rapp.app/Contents/MacOS/rapp-host\nIdentifier=com.rapp.host\nFormat=Mach-O thin (arm64)'
check "identifier parsed" eq "$(identifier_of "$CS_OUT")" "com.rapp.host"
check "expected ids" eq "$EXPECTED_IDS" "rapp-service:com.rapp.service rapp-hub:com.rapp.hub rapp-host:com.rapp.host rapp-client:com.rapp.client"

CH=$(grep -n 'chown -R "$USER_NAME":staff "$APP"' scripts/pkg/postinstall | head -1 | cut -d: -f1 || true)
BS=$(grep -n 'launchctl bootstrap' scripts/pkg/postinstall | head -1 | cut -d: -f1 || true)
check "postinstall chowns before bootstrap" test -n "$CH" -a -n "$BS" -a "${CH:-999}" -lt "${BS:-0}"

check "package script has the adhoc gate" grep -q 'RAPP_ALLOW_ADHOC' scripts/package-macos.sh
check "package script sets identifiers" grep -q -- '-i com.rapp.service' scripts/package-macos.sh
# The literal above can match a comment; also require the executable signing loop.
signs_with_ids() {
    local code
    code=$(grep -v '^[[:space:]]*#' "$1")
    printf '%s\n' "$code" | grep -q 'for pair in \$EXPECTED_IDS' &&
        printf '%s\n' "$code" | grep -q -- '"\${SIGN\[@\]}" -i "\${pair#\*:}"'
}
check "signing loop passes -i from EXPECTED_IDS" signs_with_ids scripts/package-macos.sh
check "postinstall waits for the old agent to leave" grep -q 'while launchctl print "gui/$USER_ID/$LABEL"' scripts/pkg/postinstall
check "postinstall retries bootstrap" grep -q 'for _ in 1 2 3 4 5; do launchctl bootstrap' scripts/pkg/postinstall
check "scripts parse" bash -c 'bash -n scripts/package-macos.sh && bash -n scripts/pkg/postinstall && bash -n scripts/lib/sign-check.sh'

check "release scripts parse" bash -c 'bash -n scripts/lib/release.sh'
check "default release base" grep -q 'wizlijun/rapp/releases/download/v\$VERSION' scripts/package-macos.sh
zip_after_verify() {
    local z v
    z=$(grep -n 'ditto -c -k --keepParent' scripts/package-macos.sh | head -1 | cut -d: -f1)
    v=$(grep -n 'codesign --verify --deep --strict' scripts/package-macos.sh | head -1 | cut -d: -f1)
    [ -n "$z" ] && [ -n "$v" ] && [ "$z" -gt "$v" ]
}
check "zip after verify" zip_after_verify

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
manifest_ok() {
    local notes=$'一句"话"\n第二行\t\\ end' f=$T/l.json
    write_manifest "$f" 0.5.0 https://x/r.zip "$(printf 'a%.0s' $(seq 64))" 123 "$notes" 2026-11-20T08:00:00Z
    plutil -convert xml1 -o /dev/null "$f" &&
        [ "$(plutil -extract version raw -o - "$f")" = 0.5.0 ] &&
        [ "$(plutil -extract assets.macos-arm64.size raw -o - "$f")" = 123 ] &&
        [ "$(plutil -extract notes raw -o - "$f")" = "$notes" ]
}
check "manifest is valid json with escaped notes" manifest_ok
check "control chars are escaped" eq "$(json_escape $'a\001b')" 'a\u0001b'

echo "ALL OK"
