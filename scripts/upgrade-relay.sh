#!/bin/bash
# Upgrade rapp-relay on the VPS: scripts/upgrade-relay.sh <url of the binary>
# CURL, SYSTEMCTL and RELAY_BIN can be overridden (tests use fakes).
set -euo pipefail
CURL=${CURL:-curl}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
RELAY_BIN=${RELAY_BIN:-/usr/local/bin/rapp-relay}
[ $# -eq 1 ] || { echo "usage: $0 <url>" >&2; exit 1; }

# Same directory as the target so the final mv is an atomic rename.
tmp=$(mktemp "$(dirname "$RELAY_BIN")/.rapp-relay.XXXXXX")
trap 'rm -f "$tmp"' EXIT
$CURL -fL -o "$tmp" "$1" || { echo "download failed" >&2; exit 1; }
chmod +x "$tmp"
ver=$("$tmp" --version 2>/dev/null || true)
case "$ver" in
"rapp-relay "*) ;;
*) echo "downloaded file is not rapp-relay; keeping the old one" >&2; exit 1 ;;
esac
mv "$tmp" "$RELAY_BIN"
echo "installed $ver"
$SYSTEMCTL restart rapp-relay
state=$($SYSTEMCTL is-active rapp-relay || true)
[ "$state" = active ] || { echo "rapp-relay is $state after restart" >&2; exit 1; }
echo "rapp-relay is active"
