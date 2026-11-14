# rapp 平台架构规格：relay · service · hub · GUI · worker CLI

日期：2026-11-11。状态：用户已认可第 1–3 段，并要求"开始实现"。第 4 段起由我按已定原则补齐，标为【默认】的条目是我做的选择。

工程原则：沿用 `~/git/note.md/AGENTS.md`，即 KISS、YAGNI、DRY、先规划、验证后再提交、多用子代理。

## 0. 用户已定的决策

| # | 决策 | 来源 |
|---|---|---|
| D1 | 每台机器装同一个安装包。界面上看到的是客户端管理器 `rapp`（GUI），它也能启动、停止、重启本机服务 | 用户原话 |
| D2 | 组件划分照 RustDesk：service、host 会话进程、cm 小窗、GUI、hbbs/hbbr | 用户原话 |
| D3 | 公网可用，自建 relay，部署在用户自己的 VPS 上 | 问答 |
| D4 | 有局域网就先走局域网直连，其次打洞，最后走中继 | 用户原话 |
| D5 | 认证用 RustDesk 那种 ID + 密码 | 问答 |
| D6 | GUI 用 Flutter | 问答 |
| D7 | B 端中枢在 GUI 里。关掉 GUI，已开的远端窗口会断 | 问答 |
| D8 | **性能优先于安全**。唯一的门禁是 `rapp-relay` 暴露的端口和它做的验证，其余连接一律从简 | 用户原话 |
| D9 | 保持极简 | 用户原话 |
| D10 | worker CLI 保留下来，一个进程只跑一个窗口；host 启动时用 `--app` 绑定 app；控制面走 stdin/stdout JSON 行 | 上一轮 |

接受下来的代价（D8）：拿到 VPS 的人能冒充任何设备，也能看到中继流量。

## 1. 组件

```
            rapp-relay (VPS, Rust)  UDP 22026  ← 唯一门禁
              ▲                    ▲
B: rapp (Flutter GUI) ── stdio ── rapp-hub (Rust)      A: rapp-service (Rust)  UDP 22028
                                      │  QUIC ═══════════════▶ │
                                      ▼                         ▼
                                rapp-client × N          rapp-host × N   rapp --cm
                               （连 127.0.0.1 隧道口）    （只听 127.0.0.1）
```

| 组件 | 位置 | 说明 |
|---|---|---|
| `rapp-relay` | `rust/relay` | 设备登记、核对 ID 和密码、失败限速、发令牌、帮双方打洞、中继转发 |
| `rapp-service` | `rust/service` | A 端，常驻后台。登记、认证接入、列出 app、拉起和回收 `rapp-host`、路由、本机 IPC，并按需拉起 `rapp --cm` |
| `rapp-hub` | `rust/hub` | B 端中枢，是 GUI 的子进程【默认：子进程，不用 FFI】。负责已存主机、选路、隧道，并拉起 `rapp-client` |
| `rapp-net` | `rust/net` | 前三者共用的库：配置目录、JSON 行读写、QUIC 端点、消息类型 |
| `rapp`（GUI） | `gui/` | Flutter 桌面程序。主界面就是客户端管理器；带 `--cm` 参数启动时是连接管理小窗 |
| `rapp-host` / `rapp-client` | `Sources/`（Swift） | 现有程序，按第 5 节补上 CLI。Windows 和 Linux 上的 Rust worker 以后按同一份 CLI 契约实现 |

依赖：`tokio`、`quinn 0.11`、`rustls`（自签证书，不做校验）、`rcgen`、`serde`/`serde_json`、`sha2`、`rand`、`anyhow`。不引日志框架，用 `eprintln!` 输出。

## 2. 连接与门禁

### 2.1 共用约定
- 控制消息一律用 JSON：一行一条，UTF-8，以 `\n` 结尾，每行最长 64 KiB。超长就关闭这条流。
- 每个请求独占一条 QUIC 双向流：请求一行，应答一行。`open` 例外，应答之后这条流直接传原始 v3 字节。
- 应答格式：`{"ok":true,...}` 或 `{"ok":false,"error":"<英文短句>"}`。
- QUIC 用自签证书，客户端不校验证书，SNI 固定为 `rapp`。ALPN 有两个：`rapp-relay/1` 用于连 relay，`rapp/1` 用于设备之间。
- 保活 10 秒，空闲 30 秒超时。
- 密码哈希 = `hex(SHA-256(salt ‖ password))`，salt 是 16 个随机字节。比对用常量时间比较。
- ID 是 9 位十进制数字，首位不为 0，由 relay 分配。

### 2.2 relay（`rapp-relay --key <relay key> [--listen 0.0.0.0:22026] [--db relay.json]`）
- 只开一个端口 `22026/udp`。TCP 备用中继先不做（YAGNI）。
- `relay.json` 保存每个设备的 `{id: {secret_hash, pw_salt, pw_hash, name}}`。内容一变就整个文件重写。

**A 端：登记**。A 和 relay 保持一条长连接，在上面开一条流：
```
→ {"op":"register","key":K,"id":"123456789"|null,"secret":"<64hex>","name":"bruce-mac","pw_salt":"<32hex>","pw_hash":"<64hex>","lan":["192.168.1.5:22028"]}
← {"ok":true,"id":"123456789"}  |  {"ok":false,"error":"bad relay key"|"id taken"}
```
- service 首次启动时自己随机生成 9 位 ID（不管有没有 relay），登记时带上它；relay 接受一个格式合法、还没人用过的 ID。`id` 为 null 时仍由 relay 分配（兼容旧配置）。
- `id` 已存在、但 `secret` 的哈希对不上：返回 `id taken`。
- 同一个 ID 再次登记：替换掉旧连接，同时更新密码哈希、局域网地址和名字。改了密码就靠这样重新登记。
- relay 把这条连接的对端地址记作 A 的公网地址。

**B 端：发起连接**（B 只在需要时连 relay）：
```
→ {"op":"connect","key":K,"id":"123456789","password":"..."}
← {"ok":true,"token":"<32hex>","name":"...","lan":[...],"public":"1.2.3.4:22028"}
   | {"ok":false,"error":"bad relay key"|"unknown id"|"offline"|"bad password"|"locked, retry in 12s"}
```
- 核对通过后，relay 在 A 的长连接上开一条流：`→ {"op":"incoming","token":T,"peer":"<B 公网地址>"}`，A 回 `← {"ok":true}`。relay 最多等 2 秒；等不到就回 B `offline`。
- A 收到 `incoming` 时，从自己的端点向 `peer` 发起一次 QUIC 连接，并且不等它完成。这一步只是为了在 A 的 NAT 上打开映射。
- 令牌 T 在 A 端和 relay 都保存 24 小时。A 重启后令牌全部作废，B 拿着旧令牌会收到 `bad token`，这时用已存的密码重新 `connect`。

**失败限速**：按 ID 和来源 IP 分别计数。连续失败 5 次以后，第 n 次失败要等 `min(2^(n-5), 300)` 秒才能再试。成功一次就清零。计数只放在内存里。

**中继**。B 开一条流：
```
→ {"op":"relay","key":K,"token":T}
```
relay 在 A 的长连接上开一条流，发 `{"op":"relayed","token":T}`，然后把两条流双向原样对接，不再回任何 JSON。对接之后，B 写的第一行就是发给 A 的请求（见 2.3）。令牌不存在时，relay 回 B `{"ok":false,"error":"bad token"}`。

### 2.3 设备之间（A 端监听 `22028/udp`，和它连 relay 用的是同一个端点）
- **直连**：新建的 QUIC 连接上，第一条流必须是认证请求，二选一：
  - `{"op":"auth","token":T}`，用 relay 发的令牌；
  - `{"op":"auth","password":"..."}`，仅当连接来自私有网段时才接受。这是 relay 不可用时的退路，由 A 用本机存的密码核对。成功时回 `{"ok":true,"id","name"}`，B 据此确认连上的确实是它要的那台主机。

  认证失败就回一行错误并关闭连接。认证通过后，这条连接上的后续流都直接是请求。
- **中继**：每条经 relay 转来的流，开头都是 `{"op":"relayed","token":T}`，A 核对令牌，之后的内容和直连一样。
- **`id@ip` 地址**：没有 relay 时，主机用 `id@ip`（端口不是 22028 时写成 `id@ip:port`）标识自己，本机每个可用 IPv4 一个（不含回环、链路本地和 198.18.0.0/15——Clash/Surge 一类 TUN 代理的假 IP）。B 拿它加主机时直接连这个地址做密码认证，不经过 relay。
- 请求有两种：
  - `{"op":"list_apps"}` → `{"ok":true,"apps":[{"app":"com.apple.Safari","name":"Safari"}]}`，回完关流。
  - `{"op":"open","app":"com.apple.Safari"}` → `{"ok":true,"token":"<worker token>"}`，之后这条流双向传原始 v3 字节，直到有一方关闭。
  - 终端会话（细则见终端会话规格）：
    - `{"op":"list_terms"}` → `{"ok":true,"terms":[TermRow…],"hosts":[{"host":null},{"host":"gpu1","target":"me@gpu1","tmux":"…"?,"error":"…"?}]}`，回完关流。`TermRow` = `{"id","host","name","command","panes","attached","activity","dead","unread"}`；`hosts` 第一项永远是本机（`host` 为 null），之后按 `term.json` 的顺序。
    - `{"op":"watch_terms"}` → 先回一行和 `list_terms` 一样的回复，之后每次列表变了再发一行；列表每 2 秒问一次，只在变了时发；对方关流才停。
    - `{"op":"new_term","host":null|"gpu1","name":"x"?,"command":["claude"],"cols":120,"rows":40}` → `{"ok":true,"id":"term:tmux:x"}`。`host` 是 `term.json` 里的目标名，没有或为 null 是本机。
    - `{"op":"add_term_target","name":"gpu1","target":"me@gpu1","tmux":"/opt/homebrew/bin/tmux"?}` → `{"ok":true,"targets":[{"name","target","tmux"?}…]}`（加完以后的全部目标）。名字已有回 `name is taken`，已满 32 个回 `too many targets`。
    - `{"op":"remove_term_target","name":"gpu1"}` → `{"ok":true,"targets":[…]}`；没有这个名字回 `unknown target`。
    - 不限制谁能加、删目标。「允许终端会话」关着时，上面五个请求和 `open term:…` 一律回 `{"ok":false,"error":"terminal sessions are off"}`；`term.json` 坏了回 `term.json is invalid`。
  - `open` 的 `app` 以 `term:` 开头时，A 走 `rapp-term`（不是 `rapp-host`）：回 `{"ok":true,"token":"<rapp-term 的口令>"}`，之后这条流双向传的是终端规格 §7 的 JSON 行，第一行是 worker 口令（B 写）。

### 2.4 选路（hub）
1. 依次连 A 的局域网地址，每个最多等 500 ms。localhost 测试时局域网地址包含 `127.0.0.1:22028`。
2. 再连 `public`，最多等 2 s，相当于打洞。
3. 都不通就走 relay：此后每个请求都是一条新的 `relay` 流。

每台主机的 QUIC 连接建立一次后复用，GUI 上会显示当前走的是 `lan`、`direct` 还是 `relay`。调试时可以用环境变量 `RAPP_FORCE_PATH=relay|direct|lan` 强制只走某一条路。relay 连不上，或者 relay 回 `unknown id` / `offline` 时（例如只按 `id@ip` 加的主机），直接用已存的局域网地址加密码认证（2.3 那条退路）。`bad password` 和 `locked` 不触发退路。

## 3. `rapp-service`（A 端）
- 配置目录：macOS 是 `~/Library/Application Support/rapp/`，Linux 是 `$XDG_CONFIG_HOME/rapp/`（默认 `~/.config/rapp/`），Windows 是 `%APPDATA%\rapp\`。环境变量 `RAPP_HOME` 可以覆盖，测试时用来隔离。
- `service.json`（权限 0600）：`{"relay":"vps:22026","key":K,"id":null|"…","secret":"…","name":"<主机名>","password":"…"}`。
  - 首次启动时生成 9 位 ID 和 secret，再生成一个 8 位的随机字母数字密码。
  - 密码明文保存（D8），这样 GUI 能把它显示出来。
- 启动时：
  1. 执行 `rapp-host check --json`，结果放进 status。
  2. 绑定 `0.0.0.0:22028/udp`。
  3. 配了 relay 就去登记，断线后按 1 s、2 s……最长 60 s 退避重连。
  4. 启动本机 IPC。
- worker 的查找顺序：环境变量 `RAPP_BIN_DIR` → 和服务自身同一目录 → `PATH`。
- **worker 生命周期**：每个 app 一个 `rapp-host`。
  - `open` 时如果这个 app 还没有 worker，就执行 `rapp-host serve --app X --bind 127.0.0.1 --port 0 --token-env RAPP_TOKEN --json`，token 随机生成，再从 `listening` 事件里读端口。
  - 每个 `open` 请求都新建一条到该端口的 TCP 连接，和 QUIC 流双向对接。
  - 同一个 app 已经有会话时，由 worker 自己回 `busy`。
  - worker 闲置 60 秒（没有会话）后，服务关掉它的 stdin。
  - worker 退出就把它从表里删掉，不自动重启。
- `list_apps` 转调 `rapp-host list-apps --json`。
- **本机 IPC**【默认：TCP，取代 Unix socket 和命名管道】：监听 `127.0.0.1:22029`，令牌放在 `ipc.token` 文件里（权限 0600）。每条连接的第一行是 `{"token":"…"}`，之后：
  - `{"cmd":"status"}` → `{"ok":true,"id","name","password","relay":"connected|connecting|off","relay_error"?,"lan_ids":["id@ip",…],"permissions":{"screen_recording":b,"accessibility":b},"sessions":[{"sid","peer","app","path","since"}]}`
  - `{"cmd":"set_password","password":"…"}` → `{"ok":true}`。服务改写配置，然后重新登记。
  - `{"cmd":"set_relay","relay":"…","key":"…"}` → `{"ok":true}`。服务改写配置，然后重连 relay。
  - `{"cmd":"kick","sid":n}` → `{"ok":true}`
  - `{"cmd":"subscribe"}` → 先回 `{"ok":true}`，之后每当有会话开始、结束，或者 relay 状态变化，就推一行 `{"event":"changed"}`。客户端收到后再发一次 `status`。
- 有会话开始而 `rapp --cm` 不在运行时，服务就拉起它。找 GUI 的规则是 `RAPP_GUI` 环境变量 → 和服务同目录的 `rapp`。找不到就跳过，不报错。

## 4. `rapp-hub` 与 GUI（B 端）【默认】
- `hosts.json`（权限 0600）：`[{"id","name","password","lan":[...]}]`。密码明文保存（D8）。
- hub 从 stdin 读 JSON 行命令，往 stdout 写 JSON 行。每条命令可以带一个 `req` 字段，hub 原样回在应答里：
  - `{"cmd":"hosts"}` → `{"event":"hosts","hosts":[{"id","name"}]}`
  - `{"cmd":"add_host","id","password"}` → 先试连一次，`connect` 成功才保存 → `{"event":"host_added","id","name"}`
    - `id` 也可以写成 `id@ip[:port]`：直接连该地址做密码认证，对端报的 ID 必须和 `id` 一致，成功后保存，`lan` 就是这个地址。全程不需要 relay。
  - `{"cmd":"remove_host","id"}` → `{"event":"hosts",...}`
  - `{"cmd":"apps","id"}` → `{"event":"apps","id","path","apps":[...]}`
  - `{"cmd":"open","id","app"}`：
    1. 开 `open` 流，拿到 worker token；
    2. 在 `127.0.0.1:0` 上监听；
    3. 执行 `rapp-client "rapp://127.0.0.1:<port>/?mode=color16" --token-env RAPP_TOKEN --json`；
    4. 接受一个连接后和流对接。

    成功回 `{"event":"opened","sid","id","app","path"}`；会话结束时回 `{"event":"closed","sid","reason"}`。
    - 带 `"embed":true`（嵌入舞台，S2）：不找、不拉起 `rapp-client`；`opened` 多 `port`、`token`（token 不进日志）。GUI 连上 `127.0.0.1:<port>`，首行发 token，之后和流对接；后续连接是侧连接。`closed` 的 `reason`：`"quit"`（hub 收到 `close` 或 stdin 关闭）、`"connection closed"`（本机 TCP 断开）、`"GUI did not connect"`（10 秒内没连上）。
  - `{"cmd":"close","sid"}`：关掉 client 的 stdin。
  - `{"cmd":"focus","sid"}`：让该会话的 rapp-client 把窗口提到最前（hub 给它的 stdin 写 `{"cmd":"focus"}`）。无回复；sid 不存在或已在关闭回 `unknown sid`。
  - `{"cmd":"note","sid","what":"detach"|"attach","windows":k}`：GUI 把嵌入会话的窗口分离出去或放回，hub 记一行事件 `detach`/`attach`（`{sid, windows}`）。无回复；sid 不存在回 `unknown sid`，`what` 不对或缺 `windows` 回 `bad note`。
  - 任何一条命令出错都回 `{"event":"error","req"?, "error":"…"}`。
  - stdin 关闭时，hub 关掉所有 client 后退出。
- GUI 是单窗口，加一个托盘或菜单栏图标。点关闭按钮只隐藏窗口；点"退出"时，如果还有会话，先确认。窗口分三块：
  1. **本机**：ID（relay 未连上时改显示 status 里的 `lan_ids`，每行一个 `id@ip`）、密码（可以改）、relay 地址和 key（可以改）、服务状态，以及启动、停止、重启三个按钮。
  2. **主机**：主机列表、添加主机（ID 或 `ID@IP`，加密码）、删除主机；点开一台主机后列出它的 app，点 app 就打开窗口，另有一个输入框可以按 bundle id 启动别的 app。
  3. **会话**：每个会话显示主机、app、路径，带一个关闭按钮。
- `rapp --cm`：小窗口，列出本机 service 当前的会话，每个会话带一个断开按钮。会话全部结束 5 秒后自动退出。
- 服务控制（GUI 用 Dart 直接调系统命令）：
  - macOS：LaunchAgent `com.rapp.service`，plist 是 `~/Library/LaunchAgents/com.rapp.service.plist`，首次运行时由 GUI 写入。
    - 启动：`launchctl bootstrap gui/$UID <plist>`
    - 停止：`launchctl bootout gui/$UID/com.rapp.service`
    - 重启：`launchctl kickstart -k gui/$UID/com.rapp.service`
  - Linux：systemd 用户单元 `rapp-service.service`，用 `systemctl --user start|stop|restart`。
  - Windows：开机启动写在注册表 `HKCU\…\Run`。GUI 直接拉起服务进程，停止用 `taskkill`。

## 5. worker CLI 契约（Swift 版先实现）
通用约定：
- 加 `--json` 时，stdout 只输出 JSON 行事件，人看的日志全部改到 stderr。最后一行固定是 `{"event":"exit","code":N,"reason":"…"}`。
- 加 `--json` 时，stdin 读 JSON 行命令；stdin 关闭（EOF）就正常退出，退出码 0。
- 退出码：0 正常、1 运行时错误、2 参数错误、3 缺权限、5 协议版本不符。

**`rapp-host`**
- `rapp-host serve --app <appID> (--token <t> | --token-env <VAR>) [--port 47800] [--bind 0.0.0.0] [--json]`
  - 事件：
    - `{"event":"listening","port":N}`
    - `{"event":"session","state":"started","client":"ip:port","mode":"color16","fps":15}`
    - `{"event":"session","state":"ended","reason":"…"}`
    - `{"event":"rejected","reason":"busy"|"bad token"|"…"}`
    - `{"event":"stats","kbps":12.3,"fps":15,"width":800,"height":600}`
  - stdin 命令：`{"cmd":"kick"}` 结束当前会话，`{"cmd":"quit"}` 退出。
  - Hello 的 appID 为空时，表示用绑定的那个 app；不为空且和绑定的不同时，回 Error `this host shares <appID>`。
- 旧写法 `rapp-host --token X [--port N]` 保持原样：不绑定 app，按每次 Hello 里的 appID 来。
- `rapp-host list-apps [--json]`：列出当前有可见窗口的普通 app，判定条件是窗口层级为 0、尺寸至少 50×50。输出 `{"apps":[{"app":"<bundleID>","name":"<名称>"}]}`，按名称排序。不带 `--json` 时每行输出 `bundleID<TAB>名称`。
- `rapp-host check [--json]`：输出 `{"screen_recording":b,"accessibility":b}`，不弹授权提示。权限都有就退出 0，缺任何一项就退出 3。
- `rapp-host version [--json]`：输出 `{"version":"0.2.0","protocol":3}`。

**`rapp-client`**
- `rapp-client [connect] "<地址>" [--token-env <VAR>] [--json]`
  - 地址可以不带 app（`rapp://h:p/?mode=…`），这时 Hello 的 appID 为空。
  - 地址里没有 token 时，从 `--token-env` 指定的环境变量读。两处都没有就算参数错误，退出 2。
  - 事件：`{"event":"ready","width":W,"height":H,"title":"…"}`，以及最后的 `exit`。
  - stdin 命令：`{"cmd":"quit"}`；stdin 关闭等同于 quit。
  - 用户关窗或按 ⌘Q：退出码 0。
- `rapp-client version [--json]`。

**`rapp-term`**（tmux 终端会话；一台设备一个 `serve`，由 service 拉起）
- `rapp-term serve --token-env <VAR> --config <term.json 路径> [--bind 127.0.0.1] [--port 0] [--json]`
  - `--bind` 没写时 `127.0.0.1`，`--port` 没写时 0（系统挑一个）。`--token-env` 指的变量没设或为空，算参数错误，退出 2。service 拉起它的命令行固定为 `rapp-term serve --bind 127.0.0.1 --port 0 --token-env RAPP_TOKEN --config <state.home>/term.json --json`。
  - 事件：
    - `{"event":"listening","port":N}`
    - `{"event":"ended","sid":N,"term":"term:tmux:work","inputs":N}`：一个带 `sid` 的 view 结束了，`inputs` 是这次输入的次数。
    - 最后一行 `{"event":"exit","code":N,"reason":"…"}`（`--json`）；stdin 关闭正常退出，退出码 0。
  - 每次用时现读 `--config`；`allow` 为 false 时不接请求。
  - **worker 的连接**：service 连这个端口，先写一行请求，再写一行口令（worker 的 `RAPP_TOKEN`），都以 `\n` 结尾。worker 读这两行合计最多等 30 秒，一行（含换行符）不超过 65536 字节。

    | 请求行 | 谁写口令行 | worker 回 |
    |---|---|---|
    | `{"op":"list"}` | service | 一行 `TermList`，然后关 |
    | `{"op":"watch"}` | service | 马上一行 `TermList`，之后每次变了再一行；对方关了才停 |
    | `{"op":"new","host":null\|"gpu1","name":"x"?,"command":["claude"],"cols":120,"rows":40}` | service | `{"ok":true,"id":"term:tmux:x"}` 或 `{"error":"…"}`，然后关 |
    | `{"op":"view","term":"term:tmux:work","sid":7}` | 主控台（经 hub、service 原样转过来的第一行） | 终端规格 §7 的线协议（`Hello` 起头）；开泵前的错误是一条 `{"t":"error","error":"…"}` |

    `TermList` = `{"terms":[TermRow…],"hosts":[{"host":null},{"host":"gpu1","target":"me@gpu1","tmux":"…"?,"error":"…"?}]}`。口令不对回 `{"error":"bad token"}` 后关；请求行不是这几种回 `{"error":"bad request"}`；`term.json` 读不出回 `{"error":"term.json is invalid"}`；`allow` 为 false 回 `{"error":"terminal sessions are off"}`。
- `rapp-term list [--json] [--ssh <destination> --host <name>] [--tmux <path>]`：列出 tmux 会话。`--json` 输出 `{"sessions":[TermRow…]}`；不带时每行 `id<TAB>command<TAB>panes`。`--host` 只能和 `--ssh` 一起用，名字要是 term 标识能带的。
- `rapp-term watch <term id> [--ssh <destination>] [--tmux <path>] [--json]`：在终端里直接看一个会话，stdin/stdout 走终端规格 §7 的线协议。id 带主机名时必须给 `--ssh`；没有这个会话退出 1。
- `rapp-term run [--name <name>] [--size <cols>x<rows>] [--ssh <destination> --host <name>] [--tmux <path>] [--json] -- <command...>`：新开一个 tmux 会话跑 `<command>`，输出新会话的 id（`--json` 时 `{"id":"term:tmux:x"}`）。`--size` 没写时 80x24，`--name` 没写时取命令名；同名会话已存在退出 1。
- `rapp-term version [--json]`：输出 `{"version":"…","proto":N}`；不带 `--json` 时 `rapp-term <版本> (protocol N)`。
- 退出码：0 正常、1 运行时错误（tmux 不可用、会话不在或建不成）、2 参数错误。出错信息在 stderr 一行，不含命令、屏幕和输入内容。

## 6. 打包（本轮只做 macOS）
`scripts/package-macos.sh` 依次做这几步：
1. 构建 Swift release 版；
2. 构建 `cargo build --release`，包括 service、hub、relay；
3. 构建 `flutter build macos --release`；
4. 把 `rapp-service`、`rapp-hub`、`rapp-host`、`rapp-client` 复制进 `rapp.app/Contents/MacOS/`；
5. 用 ad-hoc 签名；
6. 生成 `dist/rapp.dmg`。

`rapp-relay` 另外交叉编译成 `x86_64-unknown-linux-musl` 的静态二进制，脚本附一份 systemd 单元示例。（实现时改的：原定 `x86_64-unknown-linux-gnu`，但这台机器没有 Linux 的 gcc；musl 用 Apple clang 加 rust-lld 就能编，而且静态链接，不挑发行版的 glibc 版本。）Windows 和 Linux 的安装包、交叉编译，留到用户的实机上去做。

## 7. 验证
- **Rust 集成测试**：同一个进程里起 relay、service、hub，service 用一个假的 `rapp-host` 脚本，覆盖这些情况：
  - 登记；
  - 密码错误；
  - 限速；
  - 用令牌直连；
  - 用 `RAPP_FORCE_PATH=relay` 走中继；
  - `list_apps`；
  - `open` 之后字节能双向对接；
  - 令牌失效后重新认证。
- **Swift**：现有的 91 个测试继续通过，新加参数解析和 JSON 事件格式的测试。
- **本机端到端**：在 `127.0.0.1` 上起 relay，service 用一个隔离的 `RAPP_HOME`，hub 选路分别打通 `lan` 和 `relay`，再用一个没有 relay 的 hub 按 A 报的第一个 `id@ip` 加主机并打开，打开 Safari 能看到窗口。
- **GUI**：能构建出 macOS 版并启动，三块界面都能用；`--cm` 能断开会话。
- **未经实机验证**（要你在真实网络上验收）：跨 NAT 打洞、VPS 部署、Windows 和 Linux 上的服务。

## 8. 不做的事
一次性密码、mDNS、TCP 备用中继、多人同看一个 app、断线续连、worker 自动重启、手机端、证书校验和端到端密钥（D8）。
