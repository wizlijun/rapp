# rapp 可观测性设计：统一日志、访问记录

日期：2026-11-11。依据：用户问"刚才哪些设备访问了我的 rapp host"时，发现哪里都没有记录；用户说"你应该有这种机制"，又要求"请统一设计一下，写成可观测性的 spec"。
平台规格见 `2026-11-11-rapp-platform-design.md`，本文只写改动。标为【默认】的条目是我做的选择，可以改。

## 0 原则

- 要能回答三个问题：
  1. **谁、什么时候、从哪条路、开了哪个 app、开了多久、怎么结束的**，包括被拒绝的尝试；
  2. **出问题时为什么**，比如 relay 连不上、点击被丢弃、缺权限、选路失败；
  3. **对方往我这台电脑放了什么**，比如上传的文件、粘贴的内容，只记类型和大小，不记内容。
- 沿用平台规格的"不引日志框架"。Rust 用 `rapp-net` 里一个约 150 行的小模块，Swift 不改日志方式。
- 日志只是信息，不加验证、确认或告警（D8，门禁仍然只有 relay）。
- 不写高频日志。每秒一条的东西（stats）不进日志，会话结束时记一行汇总；连续重复的行合并成一行计数。
- **绝不记**：密码、令牌、secret、relay key、入网口令、任何私钥，剪贴板和粘贴的内容，键入的文字。
- 兼容：协议只加可选字段，旧版收到会忽略。

## 1 现状（2026-11-11 盘点）

- 所有组件都只往 stderr 打零散的英文文本，没有一个写文件。
- launchd 的 plist 里没有 `StandardErrorPath`，由 GUI（`gui/lib/service_control.dart:59-91`）和 `scripts/pkg/postinstall` 写出，所以 service 的输出全部丢掉。
- rapp-relay 走 systemd，stderr 进 journal，但里面只有出错的那一行。登记、密码错误、限速锁定、中继会话这些结果，只用 JSON 回给了对方，自己不记。
- rapp-service 读 worker 的 stdout 时，`listening` 之后的事件全部丢掉；worker 的 stderr 继承下来，最后也一起丢了。
- rapp-hub 只读 rapp-client 的 `exit` 事件，client 的 stderr 继承到 GUI。
- rapp-host 在 `--json` 模式下每秒往 stderr 写一条 `[stats]`（`Server.swift:610`）。

## 2 统一格式

每行一个 JSON 对象，UTF-8 编码，以 `\n` 结尾。之所以用 JSON：Rust、Swift、Dart 都已经带了 JSON 库，GUI 解析起来最省事，`tail -f service.log | jq` 也能直接看。

```json
{"ts":"2026-11-11T14:04:05.123Z","lvl":"info","ev":"session_end","sid":3,"peer":"192.168.1.20:53001","name":"MacBook-M4","path":"lan","app":"Safari","secs":312,"up":18234,"down":90233411,"reason":"closed"}
```

| 字段 | 说明 |
|---|---|
| `ts` | UTC 时间，RFC 3339，精确到毫秒，以 `Z` 结尾。【默认：用 UTC。Rust 标准库拿不到本地时区，GUI 显示时再换成本地时间】 |
| `lvl` | `info`、`warn`、`error` 三级，不设 debug，也不用 `RUST_LOG`（YAGNI） |
| `ev` | 事件名，小写加下划线，取值见 §4。随手写的诊断文字一律是 `ev:"log"` 加 `msg` |
| `src` | 只出现在转写的行上：`host`（rapp-host）、`client`（rapp-client） |
| `repeat` | 只出现在 `ev:"repeat"` 上，表示上一行又连续出现了 N 次 |
| 其余 | 事件自带的字段 |

**重复合并**：写入时，如果这一行除了 `ts` 以外和上一行完全一样，就不写，只给计数加一。等下一条不同的行来、到了 60 秒，或者进程退出时，先补写一行 `{"ev":"repeat","repeat":N}`。以 Dock 那次的 bug 为例，原来会刷出 1000 行 `click dropped`，合并后只剩两行。

## 3 写到哪里

| 组件 | 去处 | 轮转 |
|---|---|---|
| rapp-service（A） | 日志目录下的 `service.log` | 超过 5 MB 就把旧文件改名为 `service.log.1`，只留这一份旧的 |
| rapp-hub（B） | 日志目录下的 `hub.log` | 同上 |
| rapp-relay（VPS） | stderr，由 journal 收集：`journalctl -u rapp-relay` | 交给 journald |
| rapp-host / rapp-client | 不自己写：stderr 文本由父进程（service 或 hub）逐行转写，stdout 的 JSON 事件挑一部分转写（§4） | — |
| GUI | 不写；hub 的 stderr 改成丢弃，因为 hub 已经写了文件 | — |

**日志目录**：
- macOS 是 `~/Library/Logs/rapp/`，Console.app 能直接打开。
- Linux 是 `$XDG_STATE_HOME/rapp/`，默认 `~/.local/state/rapp/`。
- Windows 是 `%LOCALAPPDATA%\rapp\logs\`。
- 覆盖顺序：`RAPP_LOG_DIR` 优先；其次，如果设了 `RAPP_HOME`，就用 `$RAPP_HOME/logs`，这样测试会自动隔离，不会写到真目录。
- 目录权限 0700，文件 0600。

**launchd 兜底**：plist 加上 `StandardOutPath` 和 `StandardErrorPath`，都指向 `~/Library/Logs/rapp/launchd.log`，用来收 panic 和日志模块起来之前的输出。不和 `service.log` 共用一个文件，因为轮转改名之后，launchd 手里还拿着旧文件。service 启动时如果发现 `launchd.log` 超过 5 MB，就把它清空。要改的地方有两处：GUI 的 plist 写入（`service_control.dart`）和 `scripts/pkg/postinstall`。

**性能**：
- 写日志时文件一直开着，用 append 方式写，每行一次 `write`，不 fsync。
- 写入集中在一个 `Mutex` 里，平均每次会话只有几行，不会成为瓶颈。
- 写失败（比如磁盘满）就静默丢弃，不影响连接。

## 4 事件清单

### 4.1 rapp-service（A 端，`service.log`）

| ev | lvl | 字段 | 时机 |
|---|---|---|---|
| `service_start` | info | `version, id, port, ipc_port` | 启动 |
| `relay` | info/warn | `state`（connected、connecting、off），`error?` | 状态变化时；值不变不重复记 |
| `permissions` | info/warn | `screen_recording, accessibility` | 值变化时 |
| `auth_fail` | warn | `peer, name?, path, reason` | 直连认证失败，reason 取 `bad password`、`bad token`、`password auth only from private networks`、`timeout`、`auth required` |
| `request` | info | `peer, name?, path, op, app?, result` | 每个 `list_apps` 和 `open` 请求，result 取 `ok` 或错误文字（如 `busy`、`missing permission: …`） |
| `session_start` | info | `sid, peer, name?, path, app` | 对接开始 |
| `session_end` | info | `sid, peer, name?, path, app, secs, up, down, reason` | 对接结束。`up`、`down` 是对接的字节数（B→A、A→B）；reason 取 `closed`、`kicked`，或者错误文字 |
| `transfer` | info | `sid, dir`（`a_to_b`、`b_to_a`），`kind`（text、image、files、data），`bytes`，`name?` | 一次剪贴板或文件传输完成。由 host 的 stdout 事件转写（§4.3）。文件只记名字，不记内容 |
| `kick` | info | `sid` | GUI 或 cm 发了断开 |
| `worker_exit` | info/warn | `app, code, reason` | rapp-host 退出 |
| `log` | 任意 | `msg, src?, app?` | 原来的 `eprintln!`，以及 worker 的 stderr 行（加上 `src:"host"` 和 `app`） |

`peer` 是对方的地址。走 relay 时，就是 relay 报来的 B 的公网地址。

**`name`**（新增，可选）：B 自报的设备名，取 hub 所在机器的主机名。
- 直连时放在 `Op::Auth` 里；走 relay 时放在 `Op::Connect` 里，由 relay 通过 `Op::Incoming` 转给 A。
- 它没有经过验证，只用来帮助识别，日志和 GUI 都标成"自称"（D8）。

### 4.2 rapp-relay（VPS，journal）

| ev | lvl | 字段 |
|---|---|---|
| `relay_start` | info | `listen, devices`（库里登记了几台） |
| `register` | info/warn | `id, ip, result`（`ok`、`new`、`id taken`、`bad key`、`replaced`） |
| `connect` | info/warn | `from`（B 的 ip:port）、`name?`、`to`（A 的 id）、`result`（`ok`、`unknown id`、`bad password`、`locked`、`offline`、`bad token`） |
| `lockout` | warn | `key`（`id:…` 或 `ip:…`）、`secs` |
| `relayed` | info | `to, from, secs, up, down`：一条中继流结束时记 |
| `log` | 任意 | `msg`：原来的 `eprintln!` |

### 4.3 rapp-host / rapp-client 的改动（Swift）

- `--json` 模式下不再往 stderr 写 `[stats]` 文本。`stats` 事件照常发，但父进程不会把它写进日志。
- host 新增一个 stdout 事件：`{"event":"transfer","dir":"a_to_b|b_to_a","kind":…,"bytes":n,"name"?:…}`，在一次 side 传输或 paste 完成时发。
- service 在 `listening` 之后继续读 stdout，把 `transfer` 和 `rejected` 转写进日志，带上当前会话的 `sid`；其余事件仍然丢弃。
- rapp-client 不改。

### 4.4 rapp-hub（B 端，`hub.log`）

| ev | lvl | 字段 |
|---|---|---|
| `hub_start` | info | `version, relay?` |
| `route` | info/warn | `id, path`（`lan`、`direct`、`relay`），`result`；每次选路尝试记一行，失败的写原因 |
| `opened` | info | `sid, id, host_name?, app, path` |
| `closed` | info | `sid, id, app, secs, reason` |
| `log` | 任意 | `msg, src?, sid?`：原来的 `eprintln!`，以及 rapp-client 的 stderr 行（加上 `src:"client"` 和 `sid`） |

### 4.2.1 新 relay（`rapp-relay2`，Docker）

规格：《rapp relay 设计》§11。新 relay 有两种日志，用处不同：

- **运行日志**：写标准错误，由 Docker 收集，格式同本文 §2。给排查问题的人看，设备用指纹的前 8 位（`fp`）标识。

  | ev | lvl | 字段 / 时机 |
  |---|---|---|
  | `relay_start` | info | 启动，带版本和生效的配置（审计日志的镜像，见下） |
  | `listening` | info | `addr, fp`：实际监听的地址和 relay 的指纹 |
  | `stats` | info | 每 5 分钟一行：`online`（在线设备数）、`relayed_streams`（正在中继的流数）、`relayed_bytes`、`handshake_failures`、`limited`、`audit_failures` |
  | `handshake_failed` | info | `from, error`：握手被拒（比如没出示证书） |
  | `revoked_refused` | info | `fp, from`：已吊销的设备被拒绝 |
  | `enroll_failed`、`register_failed` | error | `fp, error`：入网或登记在服务端出错 |
  | `registry_flush_failed` | error | 登记簿写盘失败 |
  | `audit_write_failed` | error | 审计写不进去（比如磁盘满）；`audit.required` 为 `false` 时继续服务 |
  | `admin_failed` | error | 管理命令失败 |
  | `conn_open`、`conn_closed`、`push_failed` | debug | 只在 `log` 设成 `debug` 时记 |

  审计事件也会带标记镜像一份到运行日志（标准错误），所以 `relay_start` 在两处各出现一次。
- **审计日志**：`/data/audit/YYYY-MM-DD.jsonl`，一天一个，默认留 180 天、总量不超过 256 MB。记每一次和准入、身份、连接有关的动作，成功和失败都记，带完整指纹。**事件表在规格 §11.1，这里不抄。**
- **指标**（可选，默认关）：`metrics` 配了本机地址才提供 Prometheus 格式的数字：`rapp_relay_online_devices`、`rapp_relay_relayed_streams`、`rapp_relay_relayed_bytes_total`、`rapp_relay_handshake_failures_total`、`rapp_relay_limited_total`、`rapp_relay_audit_failures_total`。
- **绝不记**：key、入网口令、任何私钥、流里的任何内容（和本文 §0 一致；审计日志只记 `key`、`rotate_key` 这类命令发生了，不记 key 本身）。
- 在线探测不逐条记：经中继的探测流（5 秒以内、8 KiB 以内）按"发起方和目标"每小时合并成一行；真正的会话每条都记 `relayed`。

旧 relay（上面 §4.2）在迁移结束后删除，这一小节随之成为 relay 的唯一说明。

## 5 共用模块 `rapp_net::log`

```rust
#[derive(Clone)] pub struct Log;      // Arc<Mutex<…>>；各组件通过自己的 Opts.log 拿到，不用全局单例
impl Log {
    pub fn none() -> Log;             // 测试默认：什么都不写
    pub fn stderr() -> Log;           // relay 用（journald 收集）
    pub fn file(dir: &Path, name: &str) -> Log;   // service、hub 用；首次写时才创建目录和文件
    pub fn event(&self, lvl: Lvl, ev: &str, fields: serde_json::Value);  // fields 必须是 object
    pub fn msg(&self, lvl: Lvl, text: impl Display);                     // 等于 event(lvl, "log", {"msg":…})
    pub fn flush(&self);              // 补写挂起的 repeat 计数；Writer 被 drop 时也会补写
}
pub fn log_dir() -> PathBuf;          // 按 §3 的规则
pub fn read_recent(dir: &Path, name: &str, keep: impl Fn(&Value) -> bool, limit: usize) -> Vec<Value>;
pub fn pipe_lines(log: Log, r: impl AsyncRead, fields: Value) -> JoinHandle<()>;  // 子进程 stderr 转写

// rapp_net::quic
pub struct Meter;                     // get() -> (a_to_b, b_to_a)；splice 被取消或出错后仍可读
pub async fn splice_metered(a, b, meter: &Meter) -> io::Result<()>;
```

- 用实例而不是全局：集成测试把 relay、service、hub 放在同一个进程里跑，全局单例会把三者的日志混在一起。
- `Op::Open` 多一个可选的 `side: bool`（默认 false，false 时不上线）：hub 给文件传输的侧连接打上它，service 记 `request` 时带上，「访问记录」不显示这些行。
- `Op::Auth`、`Op::Connect`、`Op::Incoming` 多一个可选的 `name`（自称），旧版本不发也能解析。

- 时间格式化自己写，用 days-from-civil 算法，大约 20 行，不引入 chrono。
- 轮转判断：每次写之前，用一个已知字节计数和 5 MB 比较。
- 子进程 stderr 的转写：`spawn` 时设 `Stdio::piped()`，起一个任务逐行读，每行调用 `msg(Info, …)` 并带上 `src`、`app` 或 `sid`。一行超过 4 KiB 就截断。

## 6 访问记录（GUI）

- 新的 IPC 命令 `{"cmd":"history","limit":n}`（n 最大 500）。回复 `{"ok":true,"events":[…]}`，按时间从新到旧，只包含这几类事件：`session_start`、`session_end`、`auth_fail`，以及 `result` 不是 `ok` 的 `request`。数据来自 `service.log` 和 `service.log.1`，所以 service 重启后也还在。
- 本机页加一块「访问记录」，默认显示最近 50 条，每行写：
  - 本地时间；
  - 对方：自称名字加地址，比如 `MacBook-M4（自称）· 192.168.1.20`；
  - 路径：局域网、直连或中继；
  - app、时长、结果；被拒绝的行用警告色。
- 再加一个按钮「打开日志文件夹」。macOS 上执行 `open <日志目录>`，Linux 用 `xdg-open`，Windows 用 `explorer`。
- `status` 的回复里加 `log_dir`。
- cm 小窗不改，它显示的是正在进行的会话。

## 7 测试

- **`rapp_net::log` 单元测试**：
  - 行格式和 `ts` 格式，包括闰年、毫秒为 0 的情况；
  - 写满 5 MB 后发生轮转，旧文件被覆盖，只留一份；
  - 重复合并：N 行一样的，合成 1 行加一行 `repeat:N-1`，进程退出时也会补写；
  - `read_recent` 能跨两个文件，按从新到旧排列，并且跳过坏行；
  - 设了 `RAPP_HOME`、没设 `RAPP_LOG_DIR` 时，目录是 `$RAPP_HOME/logs`。
- **service 集成测试**（用现有的 fake host）：
  - 密码错误时写一行 `auth_fail`；
  - 一次 open 依次写出 `request`、`session_start`、`session_end`，其中 `up` 和 `down` 大于 0，kick 后 reason 是 `kicked`；
  - `history` 能返回这些行；
  - fake host 写进 stderr 的一行，会以 `src:"host"` 的形式出现；
  - **全量检查**：测试结束后，日志里搜不到测试用的密码、令牌和 relay key。
- **relay 集成测试**：bad password 和 locked 时各有一行 `connect`，中继流结束时有一行 `relayed`；同样做密钥全量检查。
- **hub 测试**：`opened` 和 `closed` 被写进 `hub.log`。
- **Swift**：`transfer` 事件的 JSON 格式（RappCore）。
- **GUI**：history 每一行的格式化（纯函数），包括"自称"和本地时间。
- 所有测试只用临时目录和临时端口，不碰 `~/Library/Logs/rapp`，也不碰 47800 和 21116–21119 这几个端口。

## 8 不做的事

- 指标服务或 Prometheus 端点、远程上传日志、tracing 框架、debug 级别、`RUST_LOG`。
- 失败尝试的通知或告警、自动拉黑（D8：门禁只有 relay）。
- 记录任何内容，包括剪贴板、粘贴、键入的文字。
- 给 Windows 和 Omarchy 主机写代码：它们还没有升到 v5。等它们实现 v5 时，按同一份 worker 契约做，也就是 stderr 写文本、stdout 写 JSON 事件，加上 `transfer` 事件；service 那边是共用的，不用另做。

## 9 未验证的假设

- ~~`splice` 改成返回字节数~~：不可行——kick 会取消 splice 的 future，出错时 `copy_bidirectional` 也不给计数。已改为包装流计数的 `Meter`（见 §5）。
- launchd 对 `StandardErrorPath` 用的是 append 方式打开，所以 service 清空 `launchd.log` 之后，后面的写入还能接上。
- `~/Library/Logs/rapp/` 由 service 自己创建，不需要额外授权。
