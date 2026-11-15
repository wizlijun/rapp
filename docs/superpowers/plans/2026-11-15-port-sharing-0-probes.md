# 端口分享 第 0 步：先验证 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在真机上试出 `.rapp` 域名在 macOS 和 Linux 桌面上到底能不能按规格 §9.2 的办法生效，把结果写进测量文档，并据此改定规格 §9.2 和 §16。

**Architecture:** 不写产品代码。每个试验是 `scripts/probes/port-sharing/` 下的一个脚本：自己搭环境、逐项检查、打印 `PASS`/`FAIL` 行、退出前把系统还原。一个只用标准库的 Python 小解析器冒充将来 `rapp-service` 里的那个。

**Tech Stack:** bash、Python 3（只用标准库）、系统自带的 `dscacheutil`、`curl`、`resolvectl`。

**Spec:** `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（下称"规格"）§9、§15 第 0 步、§16 第 1 到 5 条。

## Global Constraints

- **这些脚本要管理员权限，会改系统文件。** 每个脚本开头打印它要改什么，等用户回车才继续；用 `trap` 保证退出时还原（包括被 Ctrl-C 打断）。执行计划的 agent 不替用户输管理员密码：把命令交给用户在自己的终端里跑，拿回输出。
- 试验用的名字固定是 `gpu1.rapp`，回环地址固定是 `127.77.0.5`，解析器固定听 `127.0.0.1:22053`（UDP）。
- 每个检查打印一行，格式 `PASS <检查名>` 或 `FAIL <检查名>: <看到了什么>`。脚本最后一行是 `DONE pass=<n> fail=<n>`。有 `FAIL` 时退出码仍然是 0：`FAIL` 是试验的结果，不是脚本出错。
- 结果写进 `docs/superpowers/measurements/2026-11-15-port-sharing-probes.md`：每台机器一节，开头是系统版本（`sw_vers` 或 `/etc/os-release` 加 `uname -r`），然后原样贴脚本输出。
- 不装任何软件包。机器上没有某个程序（比如 `node`）时，那一项打印 `SKIP <检查名>: 没有 <程序>`。
- 这一步不改规格以外的任何产品文件。

## Review Focus

规格没有写、但试验时最容易漏掉、漏了以后会在用户机器上出事的五种情况。每一条的检查都已经放进对应的任务里。

1. **解析器没在跑的时候**（rapp 没启动、刚开机）：系统查 `gpu1.rapp` 应该很快失败，不能卡住别的域名解析。→ Task 2、Task 4 的"解析器停掉"一组。
2. **IPv6 查询**：程序同时查 A 和 AAAA，解析器不回 AAAA 时有的程序会等到超时。→ Task 1 的解析器对 AAAA 立刻回空；Task 2、Task 4 量 `getaddrinfo` 的耗时。
3. **不走系统解析的程序**：开着加密 DNS 的浏览器、自带解析器的运行时。→ Task 5。
4. **脚本中途被打断**：`/etc/resolver/rapp`、回环地址、`hosts` 里的那一行留在系统里。→ 每个脚本的 `trap`；Task 2、3、4 各有一步"跑到一半 Ctrl-C，检查系统已还原"。
5. **同一台机器上已经有别的东西占着 `127.77.0.5` 或 22053**。→ 每个脚本开头先查，占着就打印原因并退出，什么都不改。

---

### Task 1: 试验用的小解析器

**Files:**
- Create: `scripts/probes/port-sharing/dns_stub.py`
- Create: `scripts/probes/port-sharing/README.md`

**Interfaces:**
- Produces: `python3 dns_stub.py [--port 22053] [--addr 127.77.0.5]`。前台运行，听 `127.0.0.1:<port>` 的 UDP。对 `*.rapp` 的 A 查询回 `<addr>`（TTL 5）；对 `*.rapp` 的 AAAA 查询回"没有记录"（NOERROR、0 条答案）；其他名字回 NXDOMAIN。每收到一个查询在标准错误打印一行 `Q <类型> <名字>`。Task 2、3、4 用这几行判断查询有没有到它这里。

- [ ] **Step 1: 写 `dns_stub.py`**

这段解析和拼包的代码不由接口决定，照这个写：

```python
#!/usr/bin/env python3
"""Answers *.rapp on UDP for the port-sharing probes. Standard library only."""
import argparse, socket, struct, sys

def name_at(buf, off):
    labels = []
    while True:
        n = buf[off]
        if n == 0:
            return ".".join(labels).lower(), off + 1
        labels.append(buf[off + 1:off + 1 + n].decode("ascii", "replace"))
        off += 1 + n

def answer(q, addr):
    qid, flags, qd = struct.unpack("!HHH", q[:6])
    name, off = name_at(q, 12)
    qtype, qclass = struct.unpack("!HH", q[off:off + 4])
    question = q[12:off + 4]
    print("Q", {1: "A", 28: "AAAA"}.get(qtype, qtype), name, file=sys.stderr, flush=True)
    ours = name == "rapp" or name.endswith(".rapp")
    rcode = 0 if ours else 3
    rr = b""
    if ours and qtype == 1:
        rr = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 5, 4) + socket.inet_aton(addr)
    head = struct.pack("!HHHHHH", qid, 0x8400 | (flags & 0x0100) | rcode, 1, 1 if rr else 0, 0, 0)
    return head + question + rr

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=22053)
    p.add_argument("--addr", default="127.77.0.5")
    a = p.parse_args()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", a.port))
    while True:
        q, peer = s.recvfrom(1500)
        try:
            s.sendto(answer(q, a.addr), peer)
        except Exception as e:  # a malformed query must not stop the stub
            print("ERR", e, file=sys.stderr, flush=True)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: 验证它自己是对的**

Run（两个终端，或后台起）：

```bash
python3 scripts/probes/port-sharing/dns_stub.py &
python3 - <<'EOF'
import socket, struct
def ask(name, qtype):
    q = struct.pack("!HHHHHH", 7, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(l)]) + l.encode() for l in name.split(".")) + b"\0" + struct.pack("!HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
    s.sendto(q, ("127.0.0.1", 22053)); r = s.recv(1500)
    return r[3] & 15, struct.unpack("!H", r[6:8])[0], r[-4:]
assert ask("gpu1.rapp", 1) == (0, 1, socket.inet_aton("127.77.0.5"))
assert ask("a.b.gpu1.rapp", 1)[:2] == (0, 1)
assert ask("gpu1.rapp", 28)[:2] == (0, 0)
assert ask("example.com", 1)[:2] == (3, 0)
print("stub ok")
EOF
kill %1
```

Expected: `stub ok`。

- [ ] **Step 3: 写 `README.md`**：三句话。这些脚本是规格第 0 步的试验；会改系统文件、要管理员密码、退出时还原；结果贴到测量文档。

- [ ] **Step 4: Commit**

```bash
git add scripts/probes/port-sharing/
git commit -m "probe: a stub resolver for the .rapp name experiments"
```

---

### Task 2: macOS，`/etc/resolver` 的办法

**Files:**
- Create: `scripts/probes/port-sharing/macos-resolver.sh`

**Interfaces:**
- Consumes: Task 1 的 `dns_stub.py` 和它的 `Q` 行。
- Produces: 一份输出。Task 6 根据其中 `resolver-*` 各行决定规格 §9.2 的 macOS 做法。

- [ ] **Step 1: 写脚本**

顺序和检查名（每项一行 `PASS`/`FAIL`/`SKIP`）：

1. 开头：打印 `sw_vers`；查 `/etc/resolver/rapp` 已存在、`127.77.0.5` 已在 `lo0` 上、22053 被占：任何一项成立就说明原因并退出。
2. 搭环境（`sudo`）：`ifconfig lo0 alias 127.77.0.5`；写 `/etc/resolver/rapp`，内容两行 `nameserver 127.0.0.1`、`port 22053`；后台起 `dns_stub.py`，标准错误接到一个临时文件；在 `127.77.0.5:8000` 起 `python3 -m http.server --bind 127.77.0.5 8000`。
3. `trap`（EXIT、INT、TERM）：杀掉两个后台进程；`sudo rm /etc/resolver/rapp`；`sudo ifconfig lo0 -alias 127.77.0.5`；`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`。
4. 等 2 秒让系统读到新文件，然后检查：

| 检查名 | 怎么查 | PASS 的条件 |
|---|---|---|
| `resolver-scutil` | `scutil --dns` | 输出里有 `domain   : rapp` 和 `port     : 22053` |
| `resolver-dscacheutil` | `dscacheutil -q host -a name gpu1.rapp` | 输出含 `127.77.0.5` |
| `resolver-getaddrinfo` | `python3 -c 'import socket,time;t=time.time();print(socket.getaddrinfo("gpu1.rapp",8000,proto=socket.IPPROTO_TCP)[0][4][0], round(time.time()-t,2))'` | 第一栏是 `127.77.0.5`，第二栏小于 1.0 |
| `resolver-curl` | `curl -s -o /dev/null -w '%{http_code} %{time_namelookup}' http://gpu1.rapp:8000/` | 状态码 200，解析耗时小于 1.0 |
| `resolver-node` | `node -e 'require("dns").lookup("gpu1.rapp",(e,a)=>console.log(e?e.code:a))'` | `127.77.0.5`；没有 `node` 就 `SKIP` |
| `resolver-subdomain` | 同 `resolver-getaddrinfo`，名字换成 `a.b.gpu1.rapp` | `127.77.0.5` |
| `resolver-stub-saw-query` | 临时文件里有 `Q A gpu1.rapp` | 有 |
| `resolver-other-names` | `python3 -c 'import socket;print(socket.getaddrinfo("apple.com",443)[0][4][0])'` | 能解析（别的域名没受影响） |
| `resolver-stub-down-fast` | 杀掉 `dns_stub.py`，再跑一次 `resolver-getaddrinfo` 的命令，量耗时 | 5 秒内失败；并且随后 `apple.com` 仍能解析 |

5. 最后打印 `DONE pass=<n> fail=<n>`。

- [ ] **Step 2: 请用户在 macOS 上跑**

Run: `bash scripts/probes/port-sharing/macos-resolver.sh 2>&1 | tee /tmp/macos-resolver.out`
Expected: 最后一行 `DONE pass=… fail=…`。每一项是 `PASS` 还是 `FAIL` 都是有效结果。

- [ ] **Step 3: 中断后的还原**

请用户再跑一次，看到第一行 `PASS` 时按 Ctrl-C，然后：

Run: `ls /etc/resolver/rapp; ifconfig lo0 | grep 127.77.0.5; pgrep -f dns_stub.py`
Expected: 三条命令都没有输出（文件不在、地址不在、进程不在）。

- [ ] **Step 4: Commit**

```bash
git add scripts/probes/port-sharing/macos-resolver.sh
git commit -m "probe: /etc/resolver for .rapp on macOS"
```

---

### Task 3: macOS，`hosts` 的后备办法，和低端口监听

**Files:**
- Create: `scripts/probes/port-sharing/macos-hosts-ports.sh`

**Interfaces:**
- Produces: `hosts-*` 和 `bind-*` 各行。Task 6 用 `hosts-*` 判断后备办法成不成立，用 `bind-*` 判断规格 §9.1"在 22 上监听"在 macOS 上要不要额外授权。

- [ ] **Step 1: 写脚本**

1. 开头同 Task 2（查 `/etc/hosts` 里已有 `gpu1.rapp`、地址已在 `lo0` 上：成立就退出）。
2. 搭环境（`sudo`）：`ifconfig lo0 alias 127.77.0.5`；在 `/etc/hosts` 末尾加一行 `127.77.0.5 gpu1.rapp # rapp-probe`；在 `127.77.0.5:8000` 起 `http.server`。
3. `trap`：杀后台进程；用 `sudo sed -i '' '/# rapp-probe$/d' /etc/hosts` 删掉那一行；去掉地址；刷新缓存（同 Task 2）。
4. 检查：

| 检查名 | 怎么查 | PASS 的条件 |
|---|---|---|
| `hosts-getaddrinfo` | 同 Task 2 的 `resolver-getaddrinfo` | `127.77.0.5`，小于 1.0 秒 |
| `hosts-curl` | 同 Task 2 的 `resolver-curl` | 200 |
| `hosts-node` | 同 Task 2 | `127.77.0.5` 或 `SKIP` |
| `bind-high-unpriv` | 不用 `sudo`：`python3 -c 'import socket;s=socket.socket();s.bind(("127.77.0.5",18000));print("ok")'` | `ok` |
| `bind-22-unpriv` | 同上，端口 22 | `ok`（`FAIL` 时把错误原样打出来） |
| `bind-80-unpriv` | 同上，端口 80 | `ok` |
| `bind-wildcard-conflict` | 先在 `0.0.0.0:18001` 上起一个监听（设 `SO_REUSEADDR`），再不设任何选项去绑 `127.77.0.5:18001` | 打印实际结果：绑得上是 `PASS bind-wildcard-conflict: no conflict`，绑不上是 `FAIL bind-wildcard-conflict: <错误>`。两种都是有效结果 |

- [ ] **Step 2: 请用户在 macOS 上跑**

Run: `bash scripts/probes/port-sharing/macos-hosts-ports.sh 2>&1 | tee /tmp/macos-hosts-ports.out`
Expected: 最后一行 `DONE pass=… fail=…`。

- [ ] **Step 3: 中断后的还原**

跑到一半 Ctrl-C，然后：

Run: `grep rapp-probe /etc/hosts; ifconfig lo0 | grep 127.77.0.5`
Expected: 没有输出。

- [ ] **Step 4: Commit**

```bash
git add scripts/probes/port-sharing/macos-hosts-ports.sh
git commit -m "probe: hosts fallback and low ports on macOS"
```

---

### Task 4: Linux 桌面

**Files:**
- Create: `scripts/probes/port-sharing/linux.sh`

**Interfaces:**
- Produces: `resolved-*`、`hosts-*`、`bind-*` 各行。Task 6 用它们定规格 §9.2 的 Linux 做法。

- [ ] **Step 1: 写脚本**

1. 开头：打印 `/etc/os-release` 的 `PRETTY_NAME`、`uname -r`、`systemctl is-active systemd-resolved`、`readlink -f /etc/resolv.conf`。查占用（22053、`/etc/systemd/resolved.conf.d/rapp-probe.conf`、`/etc/hosts` 里的 `gpu1.rapp`）：成立就退出。
2. 起 `dns_stub.py` 和 `python3 -m http.server --bind 127.77.0.5 8000`（Linux 上整个 127 段都在本机，不用加地址）。
3. **第一组，systemd-resolved 的办法**（`systemd-resolved` 没在跑就整组 `SKIP`）。`sudo` 写 `/etc/systemd/resolved.conf.d/rapp-probe.conf`：

```ini
[Resolve]
DNS=127.0.0.1:22053
Domains=~rapp
```

然后 `sudo systemctl restart systemd-resolved`，等 2 秒。

| 检查名 | 怎么查 | PASS 的条件 |
|---|---|---|
| `resolved-getaddrinfo` | 同 Task 2 的 `resolver-getaddrinfo` | `127.77.0.5`，小于 1.0 秒 |
| `resolved-curl` | 同 Task 2 的 `resolver-curl` | 200 |
| `resolved-node` | 同 Task 2 | `127.77.0.5` 或 `SKIP` |
| `resolved-other-names` | 解析 `archlinux.org` | 能解析 |
| `resolved-no-leak` | 解析 `archlinux.org` 之后看 `dns_stub.py` 的输出 | 里面**没有** `archlinux.org`（别的域名没有被送到我们的解析器） |
| `resolved-stub-down-fast` | 杀掉 `dns_stub.py`，量 `gpu1.rapp` 的解析耗时，再解析 `archlinux.org` | 5 秒内失败；`archlinux.org` 仍能解析 |

做完这一组：删掉那个文件，重启 `systemd-resolved`，重新起 `dns_stub.py`。

4. **第二组，`hosts` 的办法**：`sudo` 在 `/etc/hosts` 末尾加 `127.77.0.5 gpu1.rapp # rapp-probe`。检查 `hosts-getaddrinfo`、`hosts-curl`、`hosts-node`，条件同 Task 3。做完删掉那一行（`sudo sed -i '/# rapp-probe$/d' /etc/hosts`）。

5. **第三组，监听**：

| 检查名 | 怎么查 | PASS 的条件 |
|---|---|---|
| `bind-high-unpriv` | 同 Task 3 | `ok` |
| `bind-22-unpriv` | 同 Task 3（机器上 sshd 占着 `0.0.0.0:22` 时，这一项同时测到了冲突；把错误原样打出来） | 打印实际结果 |
| `bind-unpriv-port-start` | `sysctl -n net.ipv4.ip_unprivileged_port_start` | 打印这个数 |
| `bind-setcap` | 把 `python3` 的真实文件复制到临时目录，`sudo setcap cap_net_bind_service+ep` 给这个副本，用它绑 `127.77.0.5:81` | `ok` |
| `bind-setcap-survives-replace` | 用 `cp` 把同一个文件再覆盖一次那个副本，`getcap` 看它 | 打印实际结果（预期能力没了：这说明自动升级替换程序以后要重新授权） |
| `bind-wildcard-conflict` | 同 Task 3，端口 18001 | 打印实际结果 |

6. `trap`：杀后台进程；删 `rapp-probe.conf` 并在它存在过时重启 `systemd-resolved`；删 `hosts` 里那一行；删临时目录。

- [ ] **Step 2: 请用户在 Linux 桌面（Omarchy）上跑**

Run: `bash scripts/probes/port-sharing/linux.sh 2>&1 | tee /tmp/linux.out`
Expected: 最后一行 `DONE pass=… fail=…`。

- [ ] **Step 3: 中断后的还原**

跑到第一组中间 Ctrl-C，然后：

Run: `ls /etc/systemd/resolved.conf.d/rapp-probe.conf; grep rapp-probe /etc/hosts; resolvectl query archlinux.org | head -1`
Expected: 前两条没有输出；第三条能解析。

- [ ] **Step 4: Commit**

```bash
git add scripts/probes/port-sharing/linux.sh
git commit -m "probe: .rapp names and low ports on Linux"
```

---

### Task 5: 浏览器（人工）

**Files:**
- Create: `scripts/probes/port-sharing/browsers.md`

**Interfaces:**
- Consumes: Task 2 或 Task 3 的环境（哪个办法在这台机器上解析成功，就用哪个脚本）。给两个脚本各加一个 `--hold` 参数：搭好环境、跑完检查以后不退出，等用户回车再还原。
- Produces: 一张填好的表，Task 6 贴进测量文档。

- [ ] **Step 1: 给 `macos-resolver.sh`、`macos-hosts-ports.sh`、`linux.sh` 加 `--hold`**

带 `--hold` 时，在打印 `DONE` 之前打印 `HOLD: 环境保持着，按回车还原`，然后 `read`。

- [ ] **Step 2: 写 `browsers.md`**

一张要人填的表。行是下面这些情况，列是 Safari、Chrome、Firefox（Linux 上没有 Safari）。每格填"打开了"、"打不开：<浏览器显示的话>"或"没有这个浏览器"。

| # | 情况 | 地址栏里输入 |
|---|---|---|
| 1 | 默认设置 | `http://gpu1.rapp:8000/` |
| 2 | 默认设置，不写协议 | `gpu1.rapp:8000` |
| 3 | 默认设置，不写协议、带斜杠 | `gpu1.rapp:8000/` |
| 4 | Chrome：设置 → 隐私和安全 → 使用安全 DNS，选一个具体的提供商 | `http://gpu1.rapp:8000/` |
| 5 | Firefox：设置 → 隐私与安全 → 基于 HTTPS 的 DNS，选"增强保护" | `http://gpu1.rapp:8000/` |
| 6 | Firefox：同上，选"最大保护" | `http://gpu1.rapp:8000/` |
| 7 | 浏览器开着"始终使用安全连接"（优先 https） | `http://gpu1.rapp:8000/` |

每种情况之间重启浏览器。第 4 到 7 种做完把设置改回去。

- [ ] **Step 3: 请用户照表做，把填好的表发回来**

- [ ] **Step 4: Commit**

```bash
git add scripts/probes/port-sharing/
git commit -m "probe: --hold, and the browser checklist"
```

---

### Task 6: 写结果，改定规格

**Files:**
- Create: `docs/superpowers/measurements/2026-11-15-port-sharing-probes.md`
- Modify: `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（§9.2 的表、§9.3、§16 第 1 到 5 条和第 7 条）

**Interfaces:**
- Consumes: Task 2 到 5 的输出。
- Produces: 定下来的规格 §9.2。第 4 步（桌面入口）的计划从它开始。

- [ ] **Step 1: 写测量文档**

每台机器一节：系统版本、三个脚本的输出原样贴上、浏览器的表。最前面一节"结论"，每条一句，照下面的规则得出：

| 看到的 | 结论 |
|---|---|
| macOS 上 `resolver-getaddrinfo`、`resolver-curl` 都 `PASS` | macOS 用 `/etc/resolver`（规格 §9.2 现在写的办法） |
| 上面任何一个 `FAIL`，而 `hosts-getaddrinfo`、`hosts-curl` 都 `PASS` | macOS 改用 `hosts`：`rapp-service` 不能自己写 `/etc/hosts`，所以需要一个只改 rapp 那一段的小助手。规格 §9.2 的 macOS 一行照此改，并在 §18 加一条"助手怎么做到不常驻" |
| 两种都 `FAIL` | macOS 上系统层的域名做不到。停下来告诉用户，不改规格 |
| Linux 上 `resolved-getaddrinfo`、`resolved-other-names`、`resolved-no-leak` 都 `PASS` | Linux 用 systemd-resolved 的配置片段 |
| 其中任何一个 `FAIL` 或整组 `SKIP`，而 `hosts-*` 都 `PASS` | Linux 用 `hosts`，同 macOS 的第二种 |
| `bind-22-unpriv` 在某个系统上 `FAIL` | 规格 §9.3"1024 以下的端口监听不了"那一行在这个系统上成立；安装时要授权。Linux 上若 `bind-setcap` `PASS` 而 `bind-setcap-survives-replace` 显示能力丢了，在 §18 加一条"自动升级以后重新授权" |
| `bind-wildcard-conflict` 报错 | 规格 §9.3"本机有服务占着同一个端口"那一行在这个系统上成立；没报错就把那一行里的"（Linux 上……尤其会）"照实际改 |
| 浏览器表里第 4、5、6 种有打不开的 | 在规格 §9.3 的表里加一行："浏览器开着加密 DNS：`.rapp` 打不开。在浏览器里关掉，或者用设备面板里的端口" |
| 浏览器表里第 2、3 种被当成搜索 | 在规格 §2"访问"下加一句：地址要带 `http://` |

- [ ] **Step 2: 照结论改规格**

只改上表点到的地方。§16 第 1 到 5 条和第 7 条每条末尾加"（已验证，见测量文档）"和一句结果。规格头部"状态"一行后面加一句"第 0 步的试验结果已并入 §9、§16（日期）"。

- [ ] **Step 3: 自查**

Run: `grep -n "未验证\|有风险" docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`
Expected: §9.2 的表里 macOS 和 Linux 两行不再出现"未验证"或"有风险"（Windows 那一行还在，这一步不管它）。

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/measurements/2026-11-15-port-sharing-probes.md docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md
git commit -m "docs: what the .rapp name probes found; spec §9.2 settled"
```
