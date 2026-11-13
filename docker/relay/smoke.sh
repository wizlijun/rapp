#!/usr/bin/env bash
# Smoke check of the relay image: docker/relay/smoke.sh <image>
# Runs the compose file with a temporary override (bridge network, a free host port above 30000,
# a 2 s health check) and prints PASS/FAIL per item. Exit 1 when any item failed.
# It removes only containers rapp-relay-smoke and rapp-relay-smoke-probe and volume rapp-relay-smoke-data.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

[ $# -eq 1 ] || { echo "usage: $0 <image>" >&2; exit 2; }
IMG=$1
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
C=rapp-relay-smoke
PROBE_C=rapp-relay-smoke-probe
VOL=rapp-relay-smoke-data
WORK=$(mktemp -d)
PROBE_PID=
FAILED=0

PORT=$(python3 -c 'import random,socket
for _ in range(200):
    p = random.randint(30001, 39999)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", p)); print(p); break
    except OSError:
        pass
    finally:
        s.close()')
[ -n "$PORT" ] || { echo "no free port" >&2; exit 2; }

cat > "$WORK/override.yml" <<EOF
services:
  rapp-relay:
    image: $IMG
    container_name: $C
    network_mode: bridge
    environment:
      RAPP_RELAY_LISTEN: "0.0.0.0:$PORT"
    ports: ["127.0.0.1:$PORT:$PORT/udp"]
    healthcheck:
      test: ["CMD", "rapp-relay", "check"]
      interval: 2s
      timeout: 5s
      retries: 1
volumes:
  rapp-relay-data:
    name: $VOL
EOF
# compose merges "network_mode" and "ports" from both files; host mode is replaced by bridge.
COMPOSE=(docker compose -p rapp-relay-smoke -f "$HERE/docker-compose.yml" -f "$WORK/override.yml")

cleanup() {
  [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null
  docker rm -f "$PROBE_C" >/dev/null 2>&1
  docker rm -f "$C" >/dev/null 2>&1
  docker volume rm "$VOL" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; FAILED=1; }
health() { docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null; }
wait_health() { # <status> <seconds>
  local i
  for ((i = 0; i < $2 * 2; i++)); do
    [ "$(health)" = "$1" ] && return 0
    sleep 0.5
  done
  return 1
}

# Start clean: a leftover from an earlier run is ours (fixed names).
docker rm -f "$C" >/dev/null 2>&1
docker volume rm "$VOL" >/dev/null 2>&1

"${COMPOSE[@]}" up -d >/dev/null 2>"$WORK/up.err" || { cat "$WORK/up.err" >&2; echo "FAIL 1 up: compose up failed"; exit 1; }

# 1. healthy within 30 s
if wait_health healthy 30; then pass "1 healthy within 30s"; else fail "1 healthy" "status $(health)"; fi

# 2. runs as 10001 on a read-only root
uid=$(docker exec "$C" id -u 2>&1)
if [ "$uid" = 10001 ] && ! docker exec "$C" touch /x >/dev/null 2>&1; then
  pass "2 uid 10001, root filesystem read-only"
else
  fail "2 identity" "uid=$uid, or touch /x succeeded"
fi

# 3. key: 56 characters starting with rapp, once, then refused with exit 1
KEY=$(docker exec "$C" rapp-relay key 2>/dev/null)
docker exec "$C" rapp-relay key >/dev/null 2>&1
second=$?
if [ "${#KEY}" = 56 ] && [ "${KEY#rapp}" != "$KEY" ] && [ "$second" = 1 ]; then
  pass "3 key is rapp + 52 chars, second call exits 1"
else
  fail "3 key" "length ${#KEY}, second exit $second"
fi

# 4. a device enrolls and waits. On Linux the probe runs on the host and dials the published port.
# Docker on a Mac runs in a VM that does not forward UDP to the Mac, so there the probe is built and run
# in a container that shares the relay's network namespace (it dials 127.0.0.1 there).
if [ "$(uname)" = Linux ]; then
  (cd "$ROOT/rust" && cargo build -q -p rapp-relay2 --example probe) || fail "4 enroll" "probe did not build"
  "$ROOT/rust/target/debug/examples/probe" "127.0.0.1:$PORT" "$KEY" --wait >"$WORK/probe.out" 2>&1 &
else
  docker rm -f "$PROBE_C" >/dev/null 2>&1
  docker run --rm --name "$PROBE_C" --network "container:$C" -v "$ROOT/rust:/src/rust:ro" \
    -e CARGO_TARGET_DIR=/tmp/probe-target -w /src/rust rust:1.99.1-alpine3.23 sh -c \
    "apk add -q --no-cache musl-dev && cargo run -q --locked -p rapp-relay2 --example probe -- 127.0.0.1:$PORT $KEY --wait" \
    >"$WORK/probe.out" 2>&1 &
fi
PROBE_PID=$!
ok4=0
for ((i = 0; i < 600; i++)); do
  grep -q '^enrolled' "$WORK/probe.out" && { ok4=1; break; }
  sleep 0.5
done
if [ $ok4 = 1 ]; then pass "4 probe enrolled ($(grep -m1 "^enrolled" "$WORK/probe.out"))"; else fail "4 enroll" "$(cat "$WORK/probe.out")"; fi

# 5. SIGSTOP from outside makes it unhealthy within 15 s; SIGCONT brings it back
docker kill --signal=SIGSTOP "$C" >/dev/null
if wait_health unhealthy 15; then
  docker kill --signal=SIGCONT "$C" >/dev/null
  if wait_health healthy 15; then pass "5 SIGSTOP -> unhealthy, SIGCONT -> healthy"; else fail "5 recover" "status $(health)"; fi
else
  docker kill --signal=SIGCONT "$C" >/dev/null
  fail "5 unhealthy" "status $(health)"
fi

# 6. stop: the waiting probe sees going_away; the last audit record is relay_stop
docker stop "$C" >/dev/null
for ((i = 0; i < 20; i++)); do kill -0 "$PROBE_PID" 2>/dev/null || break; sleep 0.5; done
PROBE_PID=
last=$(docker run --rm -v "$VOL:/data" "$IMG" audit | tail -1)
if grep -q going_away "$WORK/probe.out" && echo "$last" | grep -q '"ev":"relay_stop"'; then
  pass "6 probe saw going_away, last audit record is relay_stop"
else
  fail "6 stop" "probe: $(cat "$WORK/probe.out" | tr '\n' ' ') / last audit: $last"
fi

# 7. down and up again without deleting the volume: the earlier audit records are still there
"${COMPOSE[@]}" down >/dev/null 2>&1
"${COMPOSE[@]}" up -d >/dev/null 2>&1
wait_health healthy 30 >/dev/null
old=$(docker exec "$C" rapp-relay audit --event enroll 2>/dev/null | wc -l | tr -d ' ')
old_stop=$(docker exec "$C" rapp-relay audit --event relay_stop 2>/dev/null | wc -l | tr -d ' ')
if [ "$old" -ge 1 ] && [ "$old_stop" -ge 1 ]; then
  pass "7 audit records survive down/up ($old enroll, $old_stop relay_stop)"
else
  fail "7 persistence" "enroll=$old relay_stop=$old_stop"
fi

# 8. size, uncompressed and gzipped (limit: 10 MB compressed)
raw=$(docker image inspect -f '{{.Size}}' "$IMG")
gz=$(docker save "$IMG" | gzip -c | wc -c | tr -d ' ')
if [ "$gz" -le 10000000 ]; then
  pass "8 image $raw bytes, $gz bytes gzipped (<= 10 MB)"
else
  fail "8 size" "image $raw bytes, $gz bytes gzipped, over 10 MB"
fi

[ $FAILED = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAILED
