#!/usr/bin/env bash
# Builds the relay image: scripts/build-relay-image.sh <version> [--multi] [--push]
#   (default)  this machine's architecture, loaded into the local Docker
#   --multi    linux/amd64 + linux/arm64 with buildx (the foreign one runs under QEMU: slow, expected);
#              without --push the result goes to an OCI archive in a temp dir
#   --push     push to ghcr.io (implies --multi); log in first yourself
set -euo pipefail

usage() { echo "usage: $0 <version> [--multi] [--push]" >&2; exit 2; }
[ $# -ge 1 ] || usage
VERSION=$1
shift
MULTI=0
PUSH=0
for a in "$@"; do
  case $a in
    --multi) MULTI=1 ;;
    --push) PUSH=1; MULTI=1 ;;
    *) usage ;;
  esac
done

REPO=ghcr.io/wizlijun/rapp-relay
MINOR=${VERSION%.*}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Stop on known vulnerabilities in the dependencies.
(cd rust && cargo audit)

if [ "$MULTI" = 0 ]; then
  docker build -f docker/relay/Dockerfile -t "$REPO:$VERSION" -t "$REPO:$MINOR" .
  docker image ls "$REPO"
  exit 0
fi

docker buildx version >/dev/null 2>&1 || { echo "error: docker buildx is not installed (brew install docker-buildx)" >&2; exit 1; }
if [ "$PUSH" = 1 ]; then
  OUT=(--push)
else
  OUT_FILE=$(mktemp -d)/rapp-relay-$VERSION.oci.tar
  OUT=(--output "type=oci,dest=$OUT_FILE")
  echo "OCI archive: $OUT_FILE"
fi
docker buildx build --platform linux/amd64,linux/arm64 -f docker/relay/Dockerfile \
  -t "$REPO:$VERSION" -t "$REPO:$MINOR" "${OUT[@]}" .
