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

## Changing the key / 换 key

For the person who runs the relay, and for an agent doing it for them: run the commands as they are, on the
VPS, and check that the output matches. Never paste a key into a chat, a ticket or a log; below it is written
`rapp…`.
写给管理中继的人，也写给替他操作的 agent：命令在 VPS 上照抄执行，再核对输出是否和这里写的一样。key 不要贴到聊天、
工单或日志里；下文一律写成 `rapp…`。

Before you start: the relay must run an image newer than 0.6.0. With 0.6.0, `rotate-key` changes the key but
devices stay connected. Check with
开始之前：中继要运行比 0.6.0 新的镜像。0.6.0 的 `rotate-key` 只换 key，设备照样连着。检查：

    docker exec rapp-relay rapp-relay --help | grep -A1 rotate-key

Expected: two lines, the first ending in `every device is disconnected`, the second `and must enter the new
key`. If not, upgrade the image first (see "Install in one line" or "Start with compose").
预期：两行，第一行以 `every device is disconnected` 结尾，第二行是 `and must enter the new key`。不是的话，先升级镜像
（见上面的 "Install in one line" 或 "Start with compose"）。

1. **When / 什么时候换.** Change the key when you think it has leaked, or when a device is lost.
   怀疑 key 泄露了，或者丢了设备，就换。

2. **A lost device: revoke it first / 丢了设备：先吊销.** Find its ID in the list (the device's ID is also shown
   under 本机 in rapp on that device), then revoke it:
   在列表里找到它的 ID（rapp 的 本机 一节里也显示这台设备的 ID），然后吊销：

       docker exec rapp-relay rapp-relay devices
       docker exec rapp-relay rapp-relay revoke <ID>

   Expected: `已吊销 <fingerprint>`, and in `devices` that device's last column reads `revoked`. Skip this step
   when no device is lost.
   预期：打出 `已吊销 <指纹>`；`devices` 里这台设备的最后一栏是 `revoked`。没有丢设备就跳过这一步。

3. **Change the key / 换 key.**

       docker exec rapp-relay rapp-relay rotate-key

   Expected: one line, the new key: `rapp` followed by 52 letters and digits (56 characters), like `rapp…`. It is
   shown only this once, so save it now (a password manager). Every device is disconnected at once.
   预期：打出一行，就是新 key：`rapp` 后面跟 52 个字母和数字，共 56 个字符，形如 `rapp…`。新 key 只显示这一次，
   立刻保存好（比如存进密码管理器）。所有设备马上和中继断开。

4. **On every device / 在每台设备上.** In rapp: the side panel, 设备 → 本机. The 状态 row reads
   `⚠ 安全变更：中继换了 key`. Click `输入新 key`, paste the new key, click `保存`. Expected: the row reads `连接中`,
   then `已连接`; the device keeps its ID. On the controlling side, a window that went through the relay closes;
   until the new key is entered on that device too, opening it again fails with
   `中继换了 key，请到 本机 → 输入新 key`. After that, open it again.
   在 rapp 里：侧栏 设备 → 本机。状态一行显示 `⚠ 安全变更：中继换了 key`。点 `输入新 key`，粘贴新 key，
   点 `保存`。预期：先显示 `连接中`，再显示 `已连接`；设备的 ID 不变。操作的一侧，经中继打开的窗口会关掉；
   那台设备也输入新 key 之前，再打开会提示 `中继换了 key，请到 本机 → 输入新 key`。输入以后，重新打开窗口就行。

   If it reads `出错：新 key 不对`, the key was mistyped: click `输入新 key` again and paste the key exactly. Each
   wrong key counts as an attack: after `lock_after` (5) wrong tries from one address the relay locks that
   address, for 1 s at first and doubling with every further wrong try, up to `lock_max_secs` (300 s); the right
   key gets in once the lock ends.
   如果显示 `出错：新 key 不对`，就是 key 输错了：再点 `输入新 key`，原样粘贴。每一次错的 key 都当攻击处理：同一个地址
   错满 `lock_after`（5）次，relay 就锁住这个地址，先锁 1 秒，以后每错一次加倍，最长 `lock_max_secs`（300 秒）；锁过了，
   对的 key 就能进来。

5. **Who is left / 还有谁没换.**

       docker exec rapp-relay rapp-relay devices

   Expected: a tab-separated header `ID 指纹 入网时间 最近在线 状态`, then one line per device. A device whose
   last column still reads `stale` has not entered the new key yet; once it has, the column is empty and
   `最近在线` reads `online`.
   预期：先是用 tab 分隔的表头 `ID 指纹 入网时间 最近在线 状态`，然后每台设备一行。最后一栏还是 `stale` 的，就是还没
   输入新 key 的设备；输入以后，这一栏变空，`最近在线` 显示 `online`。

6. **Do not edit `/data` / 不要直接改 `/data`.** The key is kept there only as a hash; editing the files does not
   give you a key that works. Use `rotate-key`.
   key 在那里只以哈希的形式存放，改了文件也得不到能用的 key。要换就用 `rotate-key`。

Notes / 说明:

- **Old app versions / 老版本的 app.** A device still on rapp 0.6.0 does not understand "key changed": it keeps
  retrying with the old key, every try is a wrong key, and its address gets locked again and again (up to 300 s
  each time), which also holds back the other devices behind that address. Upgrade those devices.
  还是 rapp 0.6.0 的设备不认识"换了 key"：它会一直拿旧 key 重试，每一次都算错的 key，它的地址会被一次次锁住（每次最长
  300 秒），同一地址后面的其他设备也会被挡住。把这些设备升级。
- **Offline devices / 换 key 时离线的设备.** A machine that was off during `rotate-key` tries the old key when it
  comes back, then shows `⚠ 安全变更：中继换了 key` like the others. Its service and its hub share one identity and
  one public address, so one such machine may spend one wrong try from the service and one or more from the hub.
  About 3 such machines behind one public address may lock it; the lock clears within 300 s.
  换 key 时关着的机器，上线时会拿旧 key 试，然后和其他设备一样显示 `⚠ 安全变更：中继换了 key`。同一台机器上的 service 和
  hub 用同一个身份、同一个公网地址，所以一台这样的机器可能 service 错一次、hub 再错一次或几次。同一个公网地址后面有
  3 台左右这样的机器，这个地址就可能被锁住；300 秒内会解开。
- **Closed enrollment / 入网已关闭.** Closed enrollment (`rapp-relay enroll closed`) does not stop a device that
  was enrolled before from entering the new key; it only keeps out devices the relay has never seen.
  入网关闭（`rapp-relay enroll closed`）不挡以前入过网的设备输入新 key，只挡中继从没见过的设备。
- **Direct connections / 直连.** Devices that reach each other directly on the LAN are not affected; only the
  connection to the relay is.
  设备之间在局域网里直连不受影响，受影响的只是到中继的连接。

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
| `rotate-key` | replace the key and show the new one once; every device is disconnected and must enter the new key (see [Changing the key](#changing-the-key--换-key)) |
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
