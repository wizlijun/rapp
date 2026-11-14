#!/bin/sh
# rapp E2E relay for Linux with Docker. No package manager or firewall changes.
# Usage: curl -fsSL https://rapphub.com/install-relay.sh | sh
set -eu

IMAGE=ghcr.io/wizlijun/rapp-relay:0.6.0
NAME=rapp-relay
VOLUME=rapp-relay-data
fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || fail 'Run this installer on a Linux server.'
case $(uname -m) in
  x86_64|aarch64|arm64) ;;
  *) fail 'Supported server architectures: x86_64 and arm64.' ;;
esac
command -v docker >/dev/null 2>&1 || fail 'Install Docker from https://docs.docker.com/engine/install/ and run this command again.'
docker info >/dev/null 2>&1 || fail 'Docker is not running or this user cannot access it. Start Docker or rerun the installer as a user with Docker access.'

if docker container inspect "$NAME" >/dev/null 2>&1; then
  fail 'rapp-relay already exists. Nothing changed. Manage it with Docker; your key and enrolled devices remain in rapp-relay-data.'
fi

printf 'Installing %s\n' "$IMAGE"
docker pull "$IMAGE" || fail 'Cannot download the relay image. Check GHCR package visibility or sign in to GHCR with an account that has pull access.'
docker run -d --name "$NAME" --network host --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --user 10001:10001 --log-driver json-file --log-opt max-size=10m --log-opt max-file=5 \
  -v "$VOLUME:/data" "$IMAGE" >/dev/null

attempt=0
until docker exec "$NAME" rapp-relay check >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 15 ] || fail 'Relay did not become ready. Inspect it with: docker logs rapp-relay. Existing data has been preserved.'
  sleep 1
done

printf '\nRelay ready. Allow inbound UDP 22026 in your server and cloud firewall.\n'
printf 'Enter this server address and the following key in rapp on each device.\n'
printf 'Save the key now: it is only printed once.\n\n'
if ! docker exec "$NAME" rapp-relay key; then
  fail 'Could not issue a key. If this is an existing data volume, retrieve the original key from an enrolled device. This installer never rotates your key.'
fi
printf '\nUse rapp 0.6+ on both devices for end-to-end encryption.\n'
printf 'The relay forwards ciphertext; it cannot read session content.\n'
