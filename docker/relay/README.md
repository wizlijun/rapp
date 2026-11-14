# rapp relay (Docker)

One Alpine image holding one program, `/usr/local/bin/rapp-relay` (the `rapp-relay` crate). Runs as uid
10001, read-only root, all capabilities dropped. Spec: `docs/superpowers/specs/2026-11-13-rapp-relay-design.md` §12.

## Install in one line

On a Linux host with Docker, this starts the relay and prints its key once it is up:

    docker run -d --name rapp-relay --network host --restart unless-stopped --read-only --cap-drop ALL --security-opt no-new-privileges --log-opt max-size=10m --log-opt max-file=5 -v rapp-relay-data:/data ghcr.io/wizlijun/rapp-relay:0.6.0 && until docker exec rapp-relay rapp-relay check >/dev/null 2>&1; do sleep 1; done && docker exec rapp-relay rapp-relay key

Then open `22026/udp` in the firewall and enter the key on every device. The key is shown only once, so save it.
Your data lives in the `rapp-relay-data` volume. To upgrade, change the tag and run the line again after
`docker rm -f rapp-relay`. The data stays in the volume, and the last `key` step fails because the key has
already been made, which is expected.

## Start with compose

On a Linux host (host networking is needed so the relay sees real source addresses):

    cd docker/relay
    docker compose up -d

Open `22026/udp` in the host firewall. The data volume `rapp-relay-data` is mounted at `/data`.
Show the key once, then enter it on every device:

    docker exec rapp-relay rapp-relay key

A second call fails: the key is shown only once (`rotate-key` makes a new one).
Upgrade: edit the tag in `docker-compose.yml`, then `docker compose pull && docker compose up -d`.

## Back up

Back up `/data`. The files that matter most are `relay.key` (the relay's identity: lose it and every device
has to be re-keyed) and `devices.json` (the enrolled devices). `audit/` is the audit log.

    docker run --rm -v rapp-relay-data:/data -v "$PWD":/backup alpine tar czf /backup/rapp-relay-data.tgz -C /data .

## A host directory instead of a named volume

The relay runs as 10001, so the directory must belong to it:

    sudo mkdir -p /srv/rapp-relay && sudo chown 10001:10001 /srv/rapp-relay && sudo chmod 700 /srv/rapp-relay

then use `- /srv/rapp-relay:/data` in `volumes:`.

## Sending the audit elsewhere

The audit is also written, marked, to stderr, so Docker's log driver can ship it. For example with syslog
(in `docker-compose.yml`, replacing `logging:`):

    logging:
      driver: syslog
      options:
        syslog-address: "udp://logs.example.com:514"
        tag: rapp-relay

## Commands

Run as `docker exec rapp-relay rapp-relay <command>`. `--data <dir>` defaults to `/data`.

| Command | What it does |
|---|---|
| (none) | run the relay |
| `key` | make the key and show it once |
| `rotate-key` | replace the key and show the new one once |
| `devices` | list the enrolled devices |
| `revoke <ID or fingerprint>` | revoke a device (8+ hex digits of the fingerprint work) |
| `unbind <ID>` | free an ID |
| `enroll open\|closed` | let new devices enroll, or not |
| `audit [--since <N>d\|<N>h] [--id <ID>] [--event <name>]` | print audit records |
| `check` | health check: exit 0 when the relay answers (the image's HEALTHCHECK) |
| `--version` | print the version |

## Checks and build

- `docker/relay/smoke.sh <image>` runs the image on this machine (bridge network, a free port above 30000) and
  prints PASS/FAIL for eight items. On a Mac, Docker
  runs in a VM that does not forward UDP to the host, so the probe is built and run in a container that shares the
  relay container's network. It removes only container `rapp-relay-smoke` and volume `rapp-relay-smoke-data`.
- `scripts/build-relay-image.sh <version> [--multi] [--push]` runs `cargo audit`, then builds. `--multi` builds
  linux/amd64 and linux/arm64 with buildx; the foreign architecture runs under QEMU and is slow.
- `cargo run -p rapp-relay --example probe -- <host:port> <key> [--wait]` enrolls a throwaway device and prints
  `enrolled from <address the relay saw>`.

## Image size

Measured on linux/arm64 with `scripts/build-relay-image.sh 0.0.0-dev` (Alpine 3.23.8, Rust 1.99.1,
`--profile relay`): the image is 5,756,325 bytes by `docker image inspect` (the `docker image ls` DISK USAGE
column, 17.9 MB, counts the unpacked layers) and 5,742,894 bytes (5.5 MiB) after `docker save | gzip`. That is
inside the 10 MB target. The Alpine base is 4,201,091 bytes of it; the statically linked relay binary is the rest (about 1.5 MB).
