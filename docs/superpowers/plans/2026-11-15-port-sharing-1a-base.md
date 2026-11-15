# 端口分享 第 1 步（上）：底座 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一台设备用 `rapp-cli share 8000` 把本机端口注册成分享，另一台持同一把 key 的设备用 `rapp-cli pipe <ID> 8000` 接到它上面，走局域网或者经 relay；没分享的、不给它的、旧密码连接上的请求都被拒，并留下访问记录。

**Architecture:** 分享方：`rapp-service` 里多一张分享表（`local/shares.json`）、两个设备请求（`list_shares`、`forward`）和一个授权检查点。访问方：`rapp-conn` 里新加一个小的向外拨号器 `Outbound`（局域网直连 → 经 relay），`rapp-service` 的本机 IPC 多一个 `pipe` 命令，把那条 IPC 连接直接变成字节流。命令行是一个新的小程序 `rapp-cli`，只和本机 IPC 说话。relay 一行不改。

**Tech Stack:** Rust（`rust/` 工作区）：tokio、quinn、rustls、serde_json，全是工作区已有的依赖，不加新的。

**Spec:** `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（下称"规格"）§5、§6、§9.4、§14.1、§14.3、§15 第 1 步、§19。

## Global Constraints

- 在 `rust/` 下跑。单个 crate：`cargo test -p <crate>`；整体：`cargo test --workspace`。每个任务结束时 `cargo build --workspace` 没有警告。
- **不动 `rust/hub/src/link.rs`，不动 `rust/relay`。** 见下面"计划定的"第 1 条。
- 只接到分享方自己的 `127.0.0.1:<端口>`，连不上再试 `[::1]:<端口>`。任何别的地址都不连（规格 §1）。
- 默认什么都不分享。一台设备最多分享 64 个端口。每台来访设备同时转发的连接最多 256 条。
- `list_shares`、`forward` 只在按 key 互信的连接上受理：`Peer.fp` 是 `Some` 的连接（`serve_device` 和 `serve_relayed` 设了它）。旧的密码认证连接（`serve_conn` 走 `auth` 的那条路，`Peer.fp` 是 `None`）上回 `not supported`。
- 回给对方的错误文本，逐字：`not supported`、`host only`、`policy`、`not shared`、`not allowed`、`refused`、`limit`。
- `local/shares.json` 用 `rapp_net::config::write_json` 写（它已经是 0600、先写临时文件再改名）。
- 日志里永远不出现：key、任何口令、流里的内容。端口号和字节数可以记。
- 面向用户的文字一律中文，逐字照这里写：
  - `已分享：http://<名字>.rapp:<端口>`
  - `分享这个端口，等于把这台机器能到的网络也交出去`
  - `<名字> 没有分享 <端口>。在 <名字> 上运行 rapp share <端口>`
  - `<名字> 的 <端口> 没有分享给这台设备`
  - `<名字> 不在线`
  - `<名字> 的 <端口> 上没有服务在听`
- 这一步里"名字"只有 9 位数字的 ID。短名和机器名是第 2 步。

### 计划定的（规格留给实现的，以及和规格不同的）

1. **不把 hub 的拨号代码挪出来共用，新写一个小的。** 规格 §5 说"向外拨号的代码……要挪成 service 和 hub 共用"。读了代码：`rust/hub/src/link.rs` 的拨号和主机列表、在线探测、升级调度、网络状态缠在一起（它直接用 `self.hosts`、`self.schedule`、`self.probe_halt`、`self.relay_seen`、`self.relay_lan`），而且现在有几个分支同时在改 hub。所以这一步在 `rapp-conn` 里用已有的零件（`RelayConn`、`e2e_connect`、`send_hello`、`read_welcome`）新写 `Outbound`，只有"局域网 → relay"两档，不带探测和调度。让 hub 也改用它，是以后单独的一次重构。
2. **规格第 1 步拆成上、下两份计划。** 这一份（上）里，经 relay 的每条转发连接各自是一条 relay 流、各握一次手：能用，但慢。规格 §5.2 的复用通道和 §5.3 的会话优先放到下一份计划（下）。这一份的最后一个任务量出"各握一次手"的实际耗时，作为下一份的基线。
3. 命令行是新 crate `rust/cli`，程序名 `rapp-cli`。用户面对的名字是 `rapp`；怎么让 `rapp share` 落到它上面（无界面机器上直接改名安装，桌面上由界面程序转交），归第 3、4 步的打包。
4. "只给谁"在这一步只能写**这台设备已经认识的设备**：按 `paired.json` 里对方自报的名字，或者指纹的前几位（至少 8 个十六进制字符）来找。对方连上来时不带 ID（hub 发的 hello 里 `id` 是空的），所以分享方只能凭指纹认人。
5. 访问记录写进现有的 `service.log`，事件名 `forward`、`forward_sum`、`forward_refused`、`share`、`unshare`。规格 §14.3 的"同时写到系统日志或指定的目录"和托管策略文件一起，归第 4 步。
6. 检查点的第 2 步（角色）和第 3 步（策略）在这一步里恒为通过：角色要到第 3 步才有，策略要到第 4 步才有。函数的参数里现在就留着它们，顺序和规格 §5.1 一致。
7. 敏感端口清单：22、23、3389、5900、5901、2375、2376、1080、3128、8118、3306、5432、6379、27017、9200、1433、1521。
8. `shares.json` 读不懂时：服务照常启动，分享表当作空的，`service.log` 里记一行 `shares_unreadable`（警告级），文件原样留着不覆盖。
9. `rapp-cli hosts` 在这一步列的是 `local/hosts.json` 里的主机（界面里加过的那些）。无界面的机器上没有这个文件，列表是空的。

## Review Focus

规格没有写、但最可能让用户碰上的五种情况。每条的测试已经加进对应的任务。

1. **半关闭经 relay 还在不在。** `ssh`、`curl` 上传这类用法是"一头写完了，另一头还在回"。局域网直连是 QUIC 流，没问题；经 relay 是 relay 对接的两条流里面再套一层 TLS，写完的那一头能不能把"写完了"传到对面，没有人测过。→ Task 8 的 `half_close_survives_the_relay`。
2. **本机的服务一接上就关，或者根本不读。** 转发不能挂住，也不能把内存撑大。→ Task 4 的 `local_service_that_closes_at_once`、`a_reader_that_stalls_does_not_grow_memory`。
3. **用户手改坏了 `shares.json`。** → Task 2 的 `an_unreadable_file_is_an_empty_table`。
4. **名字的各种写法。** `123456789.rapp`、`123456789.RAPP`、`a.b.123456789.rapp`、末尾带点 `123456789.rapp.`、不带后缀。→ Task 6 的 `target_spellings`。
5. **分享一个已经分享了的端口、端口 0、大于 65535 的数、不是数字。** → Task 2 的 `add_replaces_the_same_port`，Task 7 的 `bad_ports_are_refused_before_anything_is_saved`。

---

## File Structure

| 文件 | 负责什么 |
|---|---|
| `rust/net/src/msg.rs`（改） | `Op::ListShares`、`Op::Forward` |
| `rust/service/src/shares.rs`（新） | 分享表：读、写、增、删、"这台设备看得到哪些"、敏感端口 |
| `rust/service/src/forward.rs`（新） | 授权检查点；受理 `list_shares`、`forward`；对接字节；并发上限；取消分享时切断 |
| `rust/service/src/forward_log.rs`（新） | 访问记录：逐条、合并、被拒的限速 |
| `rust/conn/src/paired.rs`（改） | `Paired::find` |
| `rust/conn/src/dial.rs`（新） | `Outbound`：向另一台设备发一个请求，局域网直连或经 relay |
| `rust/service/src/pipe.rs`（新） | 访问方：名字的写法、向对方发 `forward` 和 `list_shares` |
| `rust/service/src/ipc.rs`（改） | 命令 `shares`、`share`、`unshare`、`hosts`、`pipe` |
| `rust/service/src/peer.rs`（改） | `serve_request` 多两个分支 |
| `rust/service/src/state.rs`、`lib.rs`、`config.rs`（改） | `State` 多三个字段；`Opts.forward_sum_every`；`Config.forward_log` |
| `rust/cli/`（新 crate） | `rapp-cli` |
| `rust/testkit/tests/forward.rs`（新） | 两台服务加一个 relay 的端到端测试 |
| `rust/testkit/src/bin/measure_forward.rs`（新） | 量经 relay 新开连接的耗时 |

---

### Task 1: 两个设备请求

**Files:**
- Modify: `rust/net/src/msg.rs`

**Interfaces:**
- Produces: `Op::ListShares`（线上是 `{"op":"list_shares"}`）；`Op::Forward { port: u16 }`（线上是 `{"op":"forward","port":8000}`）。

- [ ] **Step 1: 写失败的测试**（加在 `msg.rs` 的 `tests` 里）

```rust
#[test]
fn share_requests() {
    assert_eq!(serde_json::to_value(Op::ListShares).unwrap(), json!({"op":"list_shares"}));
    assert_eq!(serde_json::to_value(Op::Forward { port: 8000 }).unwrap(), json!({"op":"forward","port":8000}));
    assert_eq!(serde_json::from_value::<Op>(json!({"op":"forward","port":22})).unwrap(), Op::Forward { port: 22 });
    assert!(serde_json::from_value::<Op>(json!({"op":"forward","port":70000})).is_err());
    assert!(serde_json::from_value::<Op>(json!({"op":"forward"})).is_err());
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-net share_requests`
Expected: 编译失败，`no variant named ListShares`。

- [ ] **Step 3: 在 `Op` 里加两个变体**，各带一行说明。`rust/service/src/peer.rs` 的 `serve_request` 是对 `Op` 的 `match`，这时会编译不过：给它加一个临时分支，两个新变体都回 `err("not supported")`（Task 4 换掉）。

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-net share_requests && cargo build --workspace`
Expected: PASS；整个工作区编译通过。

- [ ] **Step 5: Commit**

```bash
git add rust/net/src/msg.rs rust/service/src/peer.rs
git commit -m "feat(net): list_shares and forward requests"
```

---

### Task 2: 分享表

**Files:**
- Create: `rust/service/src/shares.rs`
- Modify: `rust/service/src/lib.rs`（`mod shares;`）

**Interfaces:**
- Produces:

```rust
pub const MAX_SHARES: usize = 64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Share {
    pub port: u16,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub note: String,
    /// Empty: every trusted device. Otherwise only these.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allow: Vec<Fp>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub raw: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub open_web: bool,
}

pub struct Shares { /* path + Mutex<Vec<Share>> */ }

impl Shares {
    /// `home` is the device's `local/`. A missing file is an empty table; an unreadable one
    /// too, with `Err` carrying why in the second field so the caller can log it.
    pub fn load(home: &Path) -> (Shares, Option<String>);
    pub fn list(&self) -> Vec<Share>;                       // sorted by port
    pub fn get(&self, port: u16) -> Option<Share>;
    /// Adds, or replaces the share of the same port. Err("limit") at MAX_SHARES; Err("bad port") for 0.
    pub fn add(&self, share: Share) -> Result<()>;
    /// True when there was one.
    pub fn remove(&self, port: u16) -> Result<bool>;
    /// The shares `fp` may use: `allow` empty or containing it.
    pub fn visible_to(&self, fp: &Fp) -> Vec<Share>;
}

pub fn sensitive(port: u16) -> bool;
```

`raw` 和 `open_web` 这一步只存不用（第 5 步用）。

- [ ] **Step 1: 写失败的测试**（`shares.rs` 里的 `tests`）

```rust
fn fp(b: u8) -> Fp { Fp([b; 32]) }
fn share(port: u16) -> Share { Share { port, note: String::new(), allow: vec![], raw: false, open_web: false } }

#[test]
fn a_missing_file_is_an_empty_table() {
    let d = tempfile::tempdir().unwrap();
    let (s, why) = Shares::load(d.path());
    assert!(s.list().is_empty() && why.is_none());
}

#[test]
fn add_saves_and_load_reads_it_back() {
    let d = tempfile::tempdir().unwrap();
    let (s, _) = Shares::load(d.path());
    s.add(Share { note: "模型".into(), allow: vec![fp(1)], ..share(11434) }).unwrap();
    s.add(share(22)).unwrap();
    let (again, why) = Shares::load(d.path());
    assert!(why.is_none());
    assert_eq!(again.list().iter().map(|s| s.port).collect::<Vec<_>>(), [22, 11434]);
    assert_eq!(again.get(11434).unwrap().note, "模型");
    let mode = std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(d.path().join("shares.json")).unwrap().permissions());
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn add_replaces_the_same_port() {
    let d = tempfile::tempdir().unwrap();
    let (s, _) = Shares::load(d.path());
    s.add(share(8000)).unwrap();
    s.add(Share { note: "x".into(), ..share(8000) }).unwrap();
    assert_eq!(s.list().len(), 1);
    assert_eq!(s.get(8000).unwrap().note, "x");
}

#[test]
fn port_zero_and_the_65th_share_are_refused() {
    let d = tempfile::tempdir().unwrap();
    let (s, _) = Shares::load(d.path());
    assert_eq!(s.add(share(0)).unwrap_err().to_string(), "bad port");
    for p in 1..=64 { s.add(share(p)).unwrap(); }
    assert_eq!(s.add(share(65)).unwrap_err().to_string(), "limit");
    s.add(share(64)).unwrap(); // replacing one that exists is not a 65th
}

#[test]
fn remove_says_whether_there_was_one() {
    let d = tempfile::tempdir().unwrap();
    let (s, _) = Shares::load(d.path());
    s.add(share(8000)).unwrap();
    assert!(s.remove(8000).unwrap());
    assert!(!s.remove(8000).unwrap());
    assert!(Shares::load(d.path()).0.list().is_empty());
}

#[test]
fn visible_to_honours_allow() {
    let d = tempfile::tempdir().unwrap();
    let (s, _) = Shares::load(d.path());
    s.add(share(1)).unwrap();
    s.add(Share { allow: vec![fp(1)], ..share(2) }).unwrap();
    assert_eq!(s.visible_to(&fp(1)).len(), 2);
    assert_eq!(s.visible_to(&fp(9)).iter().map(|s| s.port).collect::<Vec<_>>(), [1]);
}

#[test]
fn an_unreadable_file_is_an_empty_table() {
    let d = tempfile::tempdir().unwrap();
    std::fs::write(d.path().join("shares.json"), b"{not json").unwrap();
    let (s, why) = Shares::load(d.path());
    assert!(s.list().is_empty());
    assert!(why.is_some());
    assert_eq!(std::fs::read(d.path().join("shares.json")).unwrap(), b"{not json"); // left as it was
}

#[test]
fn sensitive_ports() {
    for p in [22, 23, 3389, 5900, 5901, 2375, 2376, 1080, 3128, 8118, 3306, 5432, 6379, 27017, 9200, 1433, 1521] {
        assert!(sensitive(p), "{p}");
    }
    assert!(!sensitive(8000) && !sensitive(11434));
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-service shares::`
Expected: 编译失败，`cannot find type Shares`。

- [ ] **Step 3: 实现 `shares.rs`**。文件格式是一个 JSON 数组。`add`、`remove` 在锁里改完就整份写回。

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-service shares::`
Expected: 8 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add rust/service/src/shares.rs rust/service/src/lib.rs
git commit -m "feat(service): the table of shared ports"
```

---

### Task 3: 访问记录

**Files:**
- Create: `rust/service/src/forward_log.rs`
- Modify: `rust/service/src/lib.rs`（`mod forward_log;`；`Opts` 加 `pub forward_sum_every: Duration`）、`rust/service/src/main.rs`（填 `forward_log::SUM_EVERY`）、`rust/service/src/config.rs`（`Config` 加 `forward_log`）、`rust/testkit/tests/common/mod.rs`（构造 `Opts` 的地方填 `Duration::from_secs(600)`）

**Interfaces:**
- Consumes: `rapp_net::log::Log`（`event(lvl, ev, fields)`）、`crate::state::Peer`（`fields(more)`）。
- Produces:

```rust
pub const SUM_EVERY: Duration = Duration::from_secs(600);
pub const REFUSED_EVERY: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode { Summary, Each }
impl Mode { pub fn parse(s: Option<&str>) -> Mode }   // Some("each") → Each; anything else → Summary

pub struct ForwardLog { /* Log + Mutex<state> */ }

impl ForwardLog {
    pub fn new(log: Log) -> ForwardLog;
    /// One forwarded connection ended.
    pub fn done(&self, mode: Mode, peer: &Peer, port: u16, secs: f64, bytes_in: u64, bytes_out: u64);
    /// A request was refused. At most one line per (peer fp or addr, port, reason) per REFUSED_EVERY.
    pub fn refused(&self, peer: &Peer, port: Option<u16>, reason: &str);
    /// Writes one `forward_sum` line per (peer, port) that had connections since the last flush.
    pub fn flush(&self);
}
```

`Config.forward_log: Option<String>`（`service.json` 的 `forward_log`，`#[serde(default, skip_serializing_if = "Option::is_none")]`）。

事件和字段（都经 `peer.fields(…)`，所以自带对方的地址、名字、路径）：

| 事件 | 级别 | 什么时候 | 多带的字段 |
|---|---|---|---|
| `forward` | info | `Each`：每条连接结束。`Summary`：这个 (来访设备, 端口) 自上次 `flush` 以来的第一条连接结束 | `fp`、`port`、`secs`、`bytes_in`、`bytes_out` |
| `forward_sum` | info | `flush` 时，每个有过连接的 (来访设备, 端口) 一行 | `fp`、`port`、`conns`、`bytes_in`、`bytes_out` |
| `forward_refused` | warn | 见 `refused` | `fp`（有的话）、`port`（有的话）、`reason` |

`bytes_in` 是来访设备发来的，`bytes_out` 是发给它的。

- [ ] **Step 1: 写失败的测试**（`forward_log.rs` 的 `tests`；`Log::file(dir, "t.log")` 写文件，`rapp_net::log::read_recent(dir, "t.log", |_| true, 100)` 读回）

```rust
fn peer(b: u8) -> Peer { Peer { addr: "1.2.3.4:5".into(), name: Some("mini".into()), path: "lan", fp: Some(Fp([b; 32])) } }
fn lines(dir: &Path, ev: &str) -> Vec<Value> { /* flush the Log, read_recent, keep v["ev"] == ev */ }

#[test]
fn each_writes_one_line_per_connection() {
    // two done() calls in Mode::Each → 2 `forward` lines; the first has port 8000, bytes_in 10, bytes_out 20
    // and "fp" equal to the peer's fingerprint as a string; no `forward_sum` after flush()
}

#[test]
fn summary_writes_the_first_at_once_and_the_rest_on_flush() {
    // three done() calls for (peer 1, 8000) and one for (peer 2, 8000) in Mode::Summary
    // → exactly 2 `forward` lines (one per peer) before flush()
    // → after flush(): 2 `forward_sum` lines; peer 1's has conns 3 and the three byte counts added up
    // → a second flush() with nothing new writes nothing
    // → the next done() for (peer 1, 8000) writes a `forward` line again
}

#[test]
fn refusals_are_rate_limited_per_peer_port_and_reason() {
    // refused(peer 1, Some(9), "not shared") ×5 → 1 line
    // refused(peer 1, Some(9), "not allowed") → a 2nd line; refused(peer 2, Some(9), "not shared") → a 3rd
    // a peer with fp None is keyed by its addr
}

#[test]
fn nothing_secret_is_logged() {
    // every line written above, as text, contains neither "key" nor "password" as a field name
}

#[test]
fn mode_parse() {
    assert_eq!(Mode::parse(Some("each")), Mode::Each);
    assert_eq!(Mode::parse(Some("summary")), Mode::Summary);
    assert_eq!(Mode::parse(Some("?")), Mode::Summary);
    assert_eq!(Mode::parse(None), Mode::Summary);
}
```

把注释里的断言写成代码。限速那一条用可注入的"现在"（`refused_at(&self, now: Instant, …)`，`refused` 调它），测试里不睡。

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-service forward_log::`
Expected: 编译失败。

- [ ] **Step 3: 实现**。`Service::start` 里起一个任务，每 `opts.forward_sum_every` 调一次 `flush`；`Service::stop` 时再调一次。

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-service forward_log:: && cargo build --workspace`
Expected: 5 个测试 PASS；工作区编译通过（`Opts` 的所有构造处都填了新字段）。

- [ ] **Step 5: Commit**

```bash
git add rust/service/src rust/testkit/tests/common/mod.rs
git commit -m "feat(service): the access record of forwarded connections"
```

---

### Task 4: 授权检查点和 `forward`、`list_shares` 的受理

**Files:**
- Create: `rust/service/src/forward.rs`
- Modify: `rust/service/src/state.rs`（`State` 加 `pub shares: Shares`、`pub forwards: Forwards`、`pub forward_log: ForwardLog`）、`rust/service/src/lib.rs`（`mod forward;`，`Service::start` 里构造它们；`Shares::load` 给了原因时记 `shares_unreadable`）、`rust/service/src/peer.rs`（`serve_request` 的两个分支）
- Test: `rust/service/src/forward.rs` 里的单元测试；`rust/testkit/tests/forward.rs`（新，Task 8 接着往里加）

**Interfaces:**
- Consumes: Task 1 的 `Op`；Task 2 的 `Shares`、`Share`；Task 3 的 `ForwardLog`、`Mode`。
- Produces:

```rust
pub const MAX_PER_PEER: usize = 256;
pub const LOCAL_CONNECT_WAIT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Deny { NotSupported, HostOnly, Policy, NotShared, NotAllowed }
impl Deny { pub fn as_str(self) -> &'static str }   // the exact texts in Global Constraints

pub struct Caller<'a> {
    /// Some on a key-trusted connection.
    pub fp: Option<&'a Fp>,
    /// The caller is a server device (always false until step 3).
    pub server: bool,
}

/// The one place that decides. The order is spec §5.1's.
pub fn authorize(caller: &Caller<'_>, policy_allows: bool, share: Option<&Share>) -> Result<(), Deny>;

/// Live forwards: the count per visiting device, and the way to cut a port's connections.
pub struct Forwards { /* Mutex<HashMap<Fp, usize>> + broadcast::Sender<u16> */ }
impl Forwards {
    pub fn new() -> Forwards;
    /// None at MAX_PER_PEER. The guard gives the slot back when dropped.
    pub fn enter(&self, fp: &Fp) -> Option<ForwardGuard>;
    /// Ends every forward of `port` that is running now.
    pub fn cut(&self, port: u16);
    pub fn cuts(&self) -> broadcast::Receiver<u16>;
}

pub async fn serve_list(state: &Arc<State>, s: Pipe, peer: Peer) -> Result<()>;
pub async fn serve_forward(state: &Arc<State>, s: Pipe, port: u16, peer: Peer) -> Result<()>;
```

`serve_list` 的回复：`{"ok":true,"shares":[{"port":8000,"note":"…"}]}`，只含 `visible_to(这台设备)` 的，只有 `port` 和 `note` 两个字段（`note` 空时不带）。被拒时回 `{"ok":false,"error":"<Deny 的文本>"}`。规格 §5.1 回复里的 `short`、`machine` 是第 2 步的。

`serve_forward` 的顺序：`authorize` → `Forwards::enter`（没有就回 `limit`）→ 连本机（`127.0.0.1:port`，失败再 `[::1]:port`，每个最多等 `LOCAL_CONNECT_WAIT`；都失败回 `refused`）→ 回 `{"ok":true}` → 用 `tokio::io::copy_bidirectional` 对接，同时等 `cuts()` 里出现这个端口 → 结束后 `forward_log.done(…)`。每一种拒绝都调 `forward_log.refused(…)`。`Mode` 取自 `state.cfg` 的 `forward_log`。

- [ ] **Step 1: 写检查点的失败测试**（`forward.rs` 的 `tests`）

```rust
fn share(allow: Vec<Fp>) -> Share { Share { port: 8000, note: String::new(), allow, raw: false, open_web: false } }
const A: Fp = Fp([1; 32]);
const B: Fp = Fp([2; 32]);

#[test]
fn the_five_steps_in_order() {
    let ok = Caller { fp: Some(&A), server: false };
    let open = share(vec![]);
    assert_eq!(authorize(&ok, true, Some(&open)), Ok(()));
    // 1: not a key-trusted connection — wins over everything after it
    assert_eq!(authorize(&Caller { fp: None, server: true }, false, None), Err(Deny::NotSupported));
    // 2: a server device
    assert_eq!(authorize(&Caller { fp: Some(&A), server: true }, false, None), Err(Deny::HostOnly));
    // 3: policy
    assert_eq!(authorize(&ok, false, None), Err(Deny::Policy));
    // 4: not shared
    assert_eq!(authorize(&ok, true, None), Err(Deny::NotShared));
    // 5: shared, but not with this device
    assert_eq!(authorize(&ok, true, Some(&share(vec![B]))), Err(Deny::NotAllowed));
    assert_eq!(authorize(&ok, true, Some(&share(vec![B, A]))), Ok(()));
}

#[test]
fn deny_texts() {
    use Deny::*;
    assert_eq!([NotSupported, HostOnly, Policy, NotShared, NotAllowed].map(Deny::as_str),
               ["not supported", "host only", "policy", "not shared", "not allowed"]);
}

#[test]
fn the_257th_forward_of_one_device_is_refused_and_slots_come_back() {
    let f = Forwards::new();
    let held: Vec<_> = (0..256).map(|_| f.enter(&A).unwrap()).collect();
    assert!(f.enter(&A).is_none());
    assert!(f.enter(&B).is_some()); // another device has its own count
    drop(held);
    assert!(f.enter(&A).is_some());
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-service forward::`
Expected: 编译失败。

- [ ] **Step 3: 实现 `Deny`、`Caller`、`authorize`、`Forwards`**

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-service forward::`
Expected: 3 个测试 PASS。

- [ ] **Step 5: 写受理这一层的失败测试**（新文件 `rust/testkit/tests/forward.rs`，`mod common; use common::*;`）

一个辅助函数 `echo() -> (u16, JoinHandle)`：在 `127.0.0.1:0` 上起一个回声服务（读到什么写回什么，对方写完时自己也写完），返回端口。另一个 `share_file(home: &Path, shares: Value)`：直接写 `home/shares.json`（在服务启动前）。连接和发请求用 `common` 里的 `dial2`、`req2`、`hello_and_send`（它们走 `rapp/2`、按 key 互信）；旧的密码连接用 `direct`。写法照 `rust/testkit/tests/service.rs` 里已有的 `rapp/2` 用例。

```rust
#[tokio::test]
async fn forward_reaches_the_shared_port_and_echoes() {
    // share the echo port; over rapp/2 send {"op":"forward","port":<echo>}; the reply is {"ok":true};
    // write b"hello", read back b"hello"
}

#[tokio::test]
async fn a_port_that_is_not_shared_is_refused() {
    // nothing shared; forward → {"ok":false,"error":"not shared"}
    // service.log has a `forward_refused` line with reason "not shared" and that port
}

#[tokio::test]
async fn a_share_for_someone_else_is_not_allowed_and_not_listed() {
    // shares.json: [{"port":<echo>,"allow":["<64 hex of some other fp>"]}, {"port":9}]
    // forward <echo> → "not allowed";  list_shares → shares == [{"port":9}]
}

#[tokio::test]
async fn nothing_listening_is_refused() {
    // share a port nothing listens on (bind 127.0.0.1:0, take the port, drop the listener)
    // forward → {"ok":false,"error":"refused"}
}

#[tokio::test]
async fn a_password_connection_cannot_forward_or_list() {
    // the legacy path (`direct(...)` with the service's password): forward and list_shares both
    // answer {"ok":false,"error":"not supported"}, even for a shared port
}

#[tokio::test]
async fn the_local_fallback_is_ipv6_loopback() {
    // an echo bound to [::1]:0 only; share its port; forward works. Skip (return) when binding [::1] fails.
}

#[tokio::test]
async fn half_close_is_kept() {
    // forward to the echo; write 1 MiB, shut down the write side, then read to the end: exactly 1 MiB comes back
}

#[tokio::test]
async fn local_service_that_closes_at_once() {
    // a listener that accepts and drops; forward answers ok, then the stream ends (read returns 0) within 2 s
}

#[tokio::test]
async fn a_reader_that_stalls_does_not_grow_memory() {
    // a local service that writes 64 MiB as fast as it can; the visitor reads nothing for 2 s, then reads it all:
    // exactly 64 MiB arrive. (Completion is the assertion: unbounded buffering would be the bug, and
    // copy_bidirectional does not buffer beyond its fixed buffers.)
}

#[tokio::test]
async fn a_finished_forward_is_recorded() {
    // after the echo test's stream is closed: service.log gets a `forward` line with that port,
    // bytes_in 5, bytes_out 5 (use `wait_log`)
}

#[tokio::test]
async fn an_unreadable_shares_file_starts_empty_and_says_so() {
    // shares.json = "{not json" before start; the service starts; forward → "not shared";
    // service.log has `shares_unreadable`
}
```

- [ ] **Step 6: 跑，确认失败**

Run: `cargo test -p rapp-testkit --test forward`
Expected: 除了 `a_password_connection_cannot_forward_or_list` 以外都 FAIL（Task 1 的临时分支回的是 `not supported`）。

- [ ] **Step 7: 实现 `serve_list`、`serve_forward`，接进 `peer.rs`**

`serve_request` 里把 Task 1 的临时分支换成：`Ok(Op::ListShares) => crate::forward::serve_list(state, s, peer).await`，`Ok(Op::Forward { port }) => crate::forward::serve_forward(state, s, port, peer).await`。`Caller.fp` 取 `peer.fp.as_ref()`；`server` 填 `false`；`policy_allows` 填 `true`。

- [ ] **Step 8: 跑，确认通过**

Run: `cargo test -p rapp-testkit --test forward && cargo test -p rapp-service`
Expected: 全部 PASS。

- [ ] **Step 9: Commit**

```bash
git add rust/service/src rust/testkit/tests/forward.rs
git commit -m "feat(service): forward and list_shares behind one authorization point"
```

---

### Task 5: 向另一台设备发请求（`Outbound`）

**Files:**
- Create: `rust/conn/src/dial.rs`
- Modify: `rust/conn/src/lib.rs`（`pub mod dial;`）
- Test: `rust/testkit/tests/forward.rs`（接着加）

**Interfaces:**
- Consumes: `rapp_conn::relay::{RelayConn, Found}`（`RelayConn::dial(ep, addr, key, id)`、`connect_to(id)`、`relay_to(id)`、`is_closed()`）、`e2e_connect`、`quic_facts`、`send_hello`、`read_welcome`、`Me`、`Accepted`、`rapp_wire::{Identity, Key, Fp}`、`rapp_net::msg::Op`、`rapp_net::line::{read_json, write_json}`。照 `rust/hub/src/link.rs` 里 `Dialer::dial`、`Dialer::hello`、`Hub::relay_hello` 的写法（只读，不改它）。
- Produces:

```rust
pub const DIRECT_WAIT: Duration = Duration::from_secs(1);
pub const REPLY_WAIT: Duration = Duration::from_secs(20);

/// Where to find the other device and how to trust it.
pub struct Target<'a> {
    pub id: &'a str,
    /// LAN addresses already known (`hosts.json`); may be empty.
    pub lan: &'a [String],
    /// The fingerprint already known; None: the key vouches.
    pub known: Option<Fp>,
}

/// The settings a request goes out with, read fresh by the caller each time.
pub struct Via<'a> {
    /// The relay's address; None: LAN only.
    pub relay: Option<&'a str>,
    pub key: &'a Key,
}

pub struct Sent {
    pub pipe: Pipe,
    /// The other device's reply line (ok or not).
    pub reply: Value,
    /// "lan", "direct" or "relay".
    pub path: &'static str,
    pub fp: Fp,
}

/// Unreachable in every way that was tried; `to_string()` is "offline" or "unknown id".
#[derive(Debug)] pub struct NotReached(pub &'static str);

pub struct Outbound { /* ep, identity, name, Mutex<links by id>, tokio Mutex<relay conn + (addr,key text) it was dialed for> */ }

impl Outbound {
    pub fn new(ep: quinn::Endpoint, identity: Arc<Identity>, name: String) -> Outbound;
    /// Sends `op` on a new stream to the device and returns it with the reply.
    pub async fn request(&self, via: &Via<'_>, to: &Target<'_>, op: &Op) -> Result<Sent>;
    /// Closes every connection it holds.
    pub fn close(&self);
}
```

`request` 的顺序：

1. 这个 ID 有留着的直连（`quinn::Connection`）：在上面开一条新流，写 `op`，读回复。失败就丢掉这条连接，往下走。
2. `to.lan` 里的地址，最多前 3 个，一个一个试，每个最多等 `DIRECT_WAIT`：`rapp/2` 连上、hello 和 `ping` 一起发（同 `Dialer::hello`）、通过后把连接按 ID 留着，再走第 1 步的"开新流发 `op`"。
3. `via.relay` 是 `None`：`Err(NotReached("offline"))`。
4. 有 relay：取留着的 `RelayConn`（没有、已关闭、或者地址和 key 变了就重新 `RelayConn::dial`）。`connect_to(id)`：回 `unknown id` 就是 `NotReached("unknown id")`，回 `offline` 就是 `NotReached("offline")`；成功得到 `Found`，把其中 `to.lan` 里没试过的地址照第 2 步再试（同样最多 3 个）。
5. 都不通：`relay_to(id)` → `e2e_connect` → `send_hello` 和 `op` 一起发 → `read_welcome` → 读回复。`path` 是 `"relay"`。经 relay 的连接不留着（每条转发各一条流，见"计划定的"第 2 条）。

relay 拒绝 key（`rapp_conn::relay::refused_key` 给出 `key changed` 或 `bad key`）时原样把错误传上去。`path` 的 `"lan"`/`"direct"` 照 hub 的 `direct_path` 的规则分（私有地址是 `lan`）。

- [ ] **Step 1: 写失败的测试**（加在 `rust/testkit/tests/forward.rs`）

辅助：`RelayRig::start()` 起一个 relay；两台服务 A、B 各自的 `service.json` 里填 `rig.addr` 和 `rig.key`（照 `rust/testkit/tests/key_change.rs` 开头搭两台设备的写法）；`outbound(home: &Path) -> Outbound` 用 B 的设备密钥（`Identity::load_or_create(home, "device")`）和 `b_endpoint()` 构造。

```rust
#[tokio::test]
async fn outbound_reaches_a_device_on_the_lan_address() {
    // Target { id: A's id, lan: &[a_addr(&a).to_string()], known: None }, Via { relay: None, key }
    // request(Op::Ping) → reply["ok"] == true, path == "lan", fp == A's fingerprint
}

#[tokio::test]
async fn outbound_goes_through_the_relay_when_there_is_no_address() {
    // A registered on the rig with advertise_lan Some(vec![]) so no LAN address is offered;
    // Target { lan: &[] }, Via { relay: Some(&rig.addr), key }
    // request(Op::Ping) → ok, path == "relay"; rig.streams() grew by one
}

#[tokio::test]
async fn a_second_request_reuses_the_direct_connection() {
    // two requests to the LAN address; A's service.log has exactly one `trust` line for B's fingerprint
}

#[tokio::test]
async fn an_id_the_relay_does_not_know_and_one_that_is_offline() {
    // Target { id: "999999999" } → error downcasts to NotReached("unknown id")
    // stop A; Target { id: A's id } → NotReached("offline")
}

#[tokio::test]
async fn a_device_with_another_key_is_not_trusted() {
    // B's Via carries a different Key (Key::new_local()); over the LAN address → an error, not a reply
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-testkit --test forward outbound`
Expected: 编译失败，`unresolved import rapp_conn::dial`。

- [ ] **Step 3: 实现 `dial.rs`**

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-testkit --test forward`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add rust/conn/src rust/testkit/tests/forward.rs
git commit -m "feat(conn): Outbound sends one request to a device, LAN first, then the relay"
```

---

### Task 6: 访问方：名字的写法，和向对方要端口

**Files:**
- Create: `rust/service/src/pipe.rs`
- Modify: `rust/service/src/lib.rs`（`mod pipe;`）、`rust/service/src/state.rs`（`State` 加 `pub outbound: rapp_conn::dial::Outbound`，`Service::start` 里用 `state.identity` 和一个新的客户端端点 `rapp_net::quic::client_endpoint(([0,0,0,0],0).into())` 构造；`Service::stop` 里 `close()`）

**Interfaces:**
- Consumes: Task 5 的 `Outbound`、`Target`、`Via`、`Sent`、`NotReached`；`Config` 的 `relay`、`key`；`local/hosts.json`（只读：数组，每项有 `id`、`name`、`lan`、可能有 `fp`）。
- Produces:

```rust
/// The device a name means, in this step: the 9-digit ID that is the last label before `.rapp`.
/// "123456789", "123456789.rapp", "123456789.RAPP", "a.b.123456789.rapp", "123456789.rapp." → Some("123456789").
/// Anything else → None.
pub fn target_id(name: &str) -> Option<String>;

#[derive(Debug, PartialEq)]
pub enum PipeErr {
    UnknownName,           // "unknown name"
    NoKey,                 // "no key"
    Offline,               // "offline"       (NotReached "offline" or "unknown id")
    Refused(String),       // the other device's error text: "not shared", "not allowed", "refused", "limit", …
    Other(String),
}
impl PipeErr { pub fn as_str(&self) -> &str }

/// Opens a forward to `port` of the device `name` means. The pipe carries the port's bytes.
pub async fn open(state: &State, name: &str, port: u16) -> Result<(Pipe, &'static str /* path */), PipeErr>;

/// The shares the device `name` means offers this one.
pub async fn shares_of(state: &State, name: &str) -> Result<Value /* the "shares" array */, PipeErr>;
```

`open` 和 `shares_of` 每次都从 `state.cfg` 现读 `relay` 和 `key`，从 `local/hosts.json` 找这个 ID 的 `lan` 和 `fp`（文件没有、读不懂、里面没有这个 ID：`lan` 空、`known` 是 `None`）。

- [ ] **Step 1: 写失败的测试**（`pipe.rs` 的 `tests`）

```rust
#[test]
fn target_spellings() {
    for ok in ["123456789", "123456789.rapp", "123456789.RAPP", "a.b.123456789.rapp", "123456789.rapp.", " 123456789.rapp "] {
        assert_eq!(target_id(ok).as_deref(), Some("123456789"), "{ok}");
    }
    for bad in ["", "rapp", ".rapp", "gpu1", "gpu1.rapp", "12345678.rapp", "1234567890.rapp", "123456789.com", "123456789.rapp.com"] {
        assert_eq!(target_id(bad), None, "{bad}");
    }
}

#[test]
fn error_texts() {
    assert_eq!(PipeErr::UnknownName.as_str(), "unknown name");
    assert_eq!(PipeErr::NoKey.as_str(), "no key");
    assert_eq!(PipeErr::Offline.as_str(), "offline");
    assert_eq!(PipeErr::Refused("not shared".into()).as_str(), "not shared");
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-service pipe::`
Expected: 编译失败。

- [ ] **Step 3: 实现 `pipe.rs`**

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-service pipe:: && cargo build --workspace`
Expected: 2 个测试 PASS；工作区编译通过。（`open`、`shares_of` 的行为在 Task 7、8 的端到端测试里验。）

- [ ] **Step 5: Commit**

```bash
git add rust/service/src
git commit -m "feat(service): names a forward can go to, and asking a device for a port"
```

---

### Task 7: 本机 IPC 的五个命令

**Files:**
- Modify: `rust/service/src/ipc.rs`、`rust/conn/src/paired.rs`
- Test: `rust/conn/src/paired.rs` 的单元测试；`rust/testkit/tests/forward.rs`（接着加）

**Interfaces:**
- Consumes: Task 2 的 `Shares`、`sensitive`；Task 4 的 `Forwards::cut`；Task 6 的 `open`、`shares_of`、`PipeErr`。
- Produces（IPC，一行 JSON 一个命令，沿用现有的令牌行）：

| 命令 | 请求 | 回复 |
|---|---|---|
| `shares` | `{"cmd":"shares"}` | `{"ok":true,"id":"123456789","relay":"online"…,"shares":[{"port":8000,"note":"…","allow":["mini"],"url":"http://123456789.rapp:8000","listening":true}]}`。`relay` 是 `state.status()` 里现有的那个值；`allow` 里是 `paired.json` 里的名字，没有名字的写指纹前 8 位；`listening` 是现在连不连得上 `127.0.0.1:端口`（等 200 毫秒） |
| `share` | `{"cmd":"share","ports":[8000,22],"note":"…","allow":["mini"],"raw":false}`（后三项可省） | `{"ok":true,"shared":[{"port":8000,"url":"http://123456789.rapp:8000"},{"port":22,"url":"…","warn":"分享这个端口，等于把这台机器能到的网络也交出去"}]}`；错误 `bad port`、`limit`、`unknown device: <写的那个>`、`ambiguous device: <写的那个>` |
| `unshare` | `{"cmd":"unshare","port":8000}` | `{"ok":true,"was":true}`；随后 `Forwards::cut(8000)` |
| `hosts` | `{"cmd":"hosts"}` | `{"ok":true,"hosts":[{"id":"…","name":"…","shares":[…]} 或 {"id":"…","name":"…","error":"offline"}]}`。`local/hosts.json` 里的每台，同时问，每台最多等 3 秒 |
| `pipe` | `{"cmd":"pipe","to":"123456789.rapp","port":22}` | 成功：一行 `{"ok":true,"path":"lan"}`，**此后这条 IPC 连接就是那个端口的字节流**，不再是 JSON 行。失败：一行 `{"ok":false,"error":"<PipeErr 的文本>"}`，连接照常继续 |

`share` 一次给几个端口时：全部合法才存，有一个不合法就一个都不存。写进 `service.log`：`share`（`port`、`allow` 的个数）、`unshare`（`port`）。

```rust
// rust/conn/src/paired.rs
impl Paired {
    /// The devices `who` can mean: an exact self-declared name, or a fingerprint that starts with
    /// `who` (at least 8 hex digits, case ignored). Each with its name.
    pub fn find(&self, who: &str) -> Vec<(Fp, String)>;
    /// The name stored for `fp`, if any.
    pub fn name_of(&self, fp: &Fp) -> Option<String>;
}
```

`pipe` 在 `ipc.rs` 里怎么接：`conn` 现在用 `BufReader::new(r).lines()`。收到 `pipe` 并且 `open` 成功时，先写回那一行 `ok`，再 `lines.into_inner()` 拿回 `BufReader`（它里面可能已经缓冲了对方紧跟着发来的字节，所以必须用它而不是底下的读端），和写端拼成一个双向流，同转发的那条 `Pipe` 做 `copy_bidirectional`，结束后这个 IPC 连接就结束。

- [ ] **Step 1: 写 `Paired::find` 的失败测试**（`paired.rs` 的 `tests`）

```rust
#[test]
fn find_by_name_or_fingerprint_prefix() {
    let d = tempfile::tempdir().unwrap();
    let p = Paired::empty(d.path());
    let (a, b) = (Fp([0xab; 32]), Fp([0xcd; 32]));
    p.add(&a, "mini").unwrap();
    p.add(&b, "mini").unwrap();            // two devices that call themselves the same
    p.add(&Fp([0xef; 32]), "书房").unwrap();
    assert_eq!(p.find("书房").len(), 1);
    assert_eq!(p.find("mini").len(), 2);
    assert_eq!(p.find("abababab"), vec![(a, "mini".to_string())]);
    assert_eq!(p.find("ABABABAB").len(), 1);
    assert!(p.find("ababab").is_empty());   // under 8 hex digits is not a prefix
    assert!(p.find("nobody").is_empty());
    assert_eq!(p.name_of(&a).as_deref(), Some("mini"));
}
```

- [ ] **Step 2: 跑，确认失败；实现；跑，确认通过**

Run: `cargo test -p rapp-conn find_by_name_or_fingerprint_prefix`
Expected: 先编译失败，实现后 PASS。

- [ ] **Step 3: 写 IPC 的失败测试**（加在 `rust/testkit/tests/forward.rs`；用 `Ipc::open`、`Ipc::call`）

```rust
#[tokio::test]
async fn share_then_shares_then_unshare() {
    // call share {ports:[P]} (P = an echo port) → ok, shared[0].url == format!("http://{id}.rapp:{P}"), no "warn"
    // call shares → shares[0] has port P, listening true, that url; "id" is the service's id
    // shares.json on disk has port P
    // call unshare {port:P} → was true; again → was false
    // service.log has `share` and `unshare` lines with port P
}

#[tokio::test]
async fn sharing_a_sensitive_port_warns_and_still_shares() {
    // share {ports:[22]} → ok; shared[0].warn == "分享这个端口，等于把这台机器能到的网络也交出去"
    // shares lists 22
}

#[tokio::test]
async fn bad_ports_are_refused_before_anything_is_saved() {
    // share {ports:[8000, 0]} → {"ok":false,"error":"bad port"}; shares is empty
    // share {ports:[8000, 70000]} and {ports:["x"]} and {ports:[]} → "bad port"; shares is empty
}

#[tokio::test]
async fn allow_names_a_known_device_or_is_refused() {
    // B has connected to A once (so A's paired.json has B under the name B said)
    // share {ports:[P], allow:["<that name>"]} → ok; shares[0].allow == ["<that name>"]
    // share {ports:[P], allow:["nobody"]} → {"ok":false,"error":"unknown device: nobody"}
}

#[tokio::test]
async fn unshare_cuts_what_is_running() {
    // a forward to the echo port is open and has echoed once; unshare {port:P};
    // the visitor's next read returns 0 (or an error) within 2 s
}
```

- [ ] **Step 4: 跑，确认失败**

Run: `cargo test -p rapp-testkit --test forward share`
Expected: FAIL，回的是空对象或 `unknown command`。

- [ ] **Step 5: 实现五个命令**

- [ ] **Step 6: 跑，确认通过**

Run: `cargo test -p rapp-testkit --test forward && cargo test -p rapp-conn`
Expected: 全部 PASS。

- [ ] **Step 7: Commit**

```bash
git add rust/service/src/ipc.rs rust/conn/src/paired.rs rust/testkit/tests/forward.rs
git commit -m "feat(service): share, unshare, shares, hosts and pipe over the local IPC"
```

---

### Task 8: 端到端：`pipe` 经局域网和经 relay

**Files:**
- Test: `rust/testkit/tests/forward.rs`（接着加）

**Interfaces:**
- Consumes: Task 4 到 7 的全部。两台服务 A（分享方）、B（访问方）加 `RelayRig`，搭法同 Task 5。B 的 `local/hosts.json` 里写不写 A 的局域网地址，决定走哪条路。
- 辅助：`pipe(ipc_port, token, to, port) -> (Value, TcpStream)`：连 B 的 IPC，发令牌行和 `pipe` 命令，读回第一行，把这条 TCP 连接交回来。

- [ ] **Step 1: 写测试**

```rust
#[tokio::test]
async fn pipe_over_the_lan() {
    // B's hosts.json has A with its LAN address; A shares the echo port
    // pipe(to: format!("{a_id}.rapp"), port) → first line {"ok":true,"path":"lan"}; b"hello" echoes
}

#[tokio::test]
async fn pipe_over_the_relay() {
    // A started with advertise_lan Some(vec![]); B has no hosts.json
    // pipe → {"ok":true,"path":"relay"}; b"hello" echoes; rig.streams() grew
}

#[tokio::test]
async fn half_close_survives_the_relay() {
    // over the relay: write 1 MiB, shut down the write side of the IPC connection,
    // read to the end → exactly 1 MiB
}

#[tokio::test]
async fn bytes_sent_right_behind_the_command_are_not_lost() {
    // write the token line, the pipe command and b"hello" in ONE write; the reply line comes,
    // then b"hello" echoes (the IPC reader's buffered bytes were carried over)
}

#[tokio::test]
async fn pipe_errors() {
    // to "gpu1.rapp" → {"ok":false,"error":"unknown name"}
    // to a 9-digit id the relay does not know → "offline"
    // A up, port not shared → "not shared";  shared with allow = someone else → "not allowed"
    // shared, nothing listening → "refused"
    // B's service.json without a key → "no key"
    // after each error the same IPC connection still answers {"cmd":"status"}
}

#[tokio::test]
async fn hosts_lists_what_each_device_offers_this_one() {
    // B's hosts.json: A (up, sharing P and Q, Q allowed only to someone else) and a made-up id
    // call hosts → A's entry has shares == [{"port":P}]; the other has error "offline"
}

#[tokio::test]
async fn the_relay_saw_nothing_it_could_read() {
    // after pipe_over_the_relay's exchange of a recognisable 32-byte marker:
    // no file under rig.data contains the marker, the port number as a JSON field, or "forward"
}
```

- [ ] **Step 2: 跑**

Run: `cargo test -p rapp-testkit --test forward`
Expected: 全部 PASS。有不过的，改的是 Task 4 到 7 的代码，不是测试。`half_close_survives_the_relay` 不过时先停下来报告：那说明 relay 对接流的方式不传"写完了"，要改的可能在 relay 里，而这份计划不许动 relay。

- [ ] **Step 3: Commit**

```bash
git add rust/testkit/tests/forward.rs
git commit -m "test: pipe end to end, over the LAN and over the relay"
```

---

### Task 9: 命令行 `rapp-cli`

**Files:**
- Create: `rust/cli/Cargo.toml`、`rust/cli/src/main.rs`、`rust/cli/src/args.rs`、`rust/cli/src/say.rs`
- Modify: `rust/Cargo.toml`（`members` 加 `"cli"`）
- Test: `rust/cli/src/args.rs`、`rust/cli/src/say.rs` 的单元测试；`rust/testkit/tests/forward.rs` 加一条起真程序的

**Interfaces:**
- Consumes: Task 7 的 IPC 命令。IPC 的端口：`<local>/service.json` 的 `ipc_port`，没有就是 22029；令牌：`<local>/ipc.token`；`<local>` 是 `rapp_net::config::local(&rapp_net::config::home())`。
- Produces: 程序 `rapp-cli`。依赖只有 `anyhow`、`tokio`、`serde_json`、`rapp-net`。

```rust
// args.rs
#[derive(Debug, PartialEq)]
pub enum Cmd {
    /// No ports: show the table.
    Share { ports: Vec<u16>, allow: Vec<String>, raw: bool, note: Option<String> },
    Unshare { port: u16 },
    Hosts,
    Pipe { to: String, port: u16 },
}
/// Err carries the line to print (in Chinese) before the usage.
pub fn parse(args: &[String]) -> Result<Cmd, String>;

// say.rs — what gets printed, as pure functions of the service's reply
pub fn shared(reply: &Value) -> String;                    // one "已分享：<url>" per port; a warn line right under its port
pub fn table(reply: &Value) -> String;                     // `rapp share` with no ports
pub fn hosts(reply: &Value) -> String;
pub fn pipe_error(to: &str, port: u16, error: &str) -> String;
```

用法（`rapp-cli` 不带参数、带 `-h`、或者解析失败时打印）：

```
rapp share [端口…] [--allow 设备,设备] [--raw] [--note 备注]
rapp unshare <端口>
rapp hosts
rapp pipe <名字> <端口>
```

`pipe_error` 的文字（`<名字>` 是用户写的那个，去掉 `.rapp`）：

| 服务回的 | 打印 |
|---|---|
| `not shared` | `<名字> 没有分享 <端口>。在 <名字> 上运行 rapp share <端口>` |
| `not allowed` | `<名字> 的 <端口> 没有分享给这台设备` |
| `offline` | `<名字> 不在线` |
| `refused` | `<名字> 的 <端口> 上没有服务在听` |
| `unknown name` | `不认识 <名字>。现在只能写 9 位的设备 ID` |
| `no key` | `这台设备还没有填 key` |
| 其他 | `接不上 <名字> 的 <端口>：<原文>` |

连不上本机服务时（IPC 连接失败、令牌文件没有）：打印 `本机的 rapp 服务没有在运行`，退出码 1。`pipe` 失败时提示写到标准错误，退出码 1；成功时标准输入接到连接、连接接到标准输出，任何一头结束就按半关闭传过去，都结束了退出 0。

`table` 的样子（列之间用空格对齐；没有分享时只有前两行加一行 `（没有分享）`）：

```
这台设备：123456789.rapp   中继：已连接
端口     状态          只给         地址
22       有服务在听    mini         http://123456789.rapp:22
8000     没有服务在听               http://123456789.rapp:8000
```

`中继：` 后面按 `relay` 的值：`online` → `已连接`，`connecting` → `连接中`，`error` → `出错`，其他（没有配）→ `没有配置`。先看一眼 `State::status` 里 `relay` 实际有哪些值，按实际的写全。

- [ ] **Step 1: 写 `args` 的失败测试**

```rust
fn p(s: &str) -> Result<Cmd, String> { parse(&s.split_whitespace().map(String::from).collect::<Vec<_>>()) }

#[test]
fn commands() {
    assert_eq!(p("share"), Ok(Cmd::Share { ports: vec![], allow: vec![], raw: false, note: None }));
    assert_eq!(p("share 8000 22"), Ok(Cmd::Share { ports: vec![8000, 22], allow: vec![], raw: false, note: None }));
    assert_eq!(p("share 8000 --allow mini,abababab --raw --note 模型"),
               Ok(Cmd::Share { ports: vec![8000], allow: vec!["mini".into(), "abababab".into()], raw: true, note: Some("模型".into()) }));
    assert_eq!(p("unshare 8000"), Ok(Cmd::Unshare { port: 8000 }));
    assert_eq!(p("hosts"), Ok(Cmd::Hosts));
    assert_eq!(p("pipe 123456789.rapp 22"), Ok(Cmd::Pipe { to: "123456789.rapp".into(), port: 22 }));
}

#[test]
fn bad_input_says_what_is_wrong() {
    assert_eq!(p("share 0").unwrap_err(), "端口要在 1 到 65535 之间：0");
    assert_eq!(p("share 70000").unwrap_err(), "端口要在 1 到 65535 之间：70000");
    assert_eq!(p("share abc").unwrap_err(), "端口要在 1 到 65535 之间：abc");
    assert_eq!(p("share --allow").unwrap_err(), "--allow 后面要写设备");
    assert_eq!(p("unshare").unwrap_err(), "要写端口");
    assert_eq!(p("pipe gpu1").unwrap_err(), "要写名字和端口");
    assert_eq!(p("frobnicate").unwrap_err(), "不认识的命令：frobnicate");
}
```

- [ ] **Step 2: 写 `say` 的失败测试**

```rust
#[test]
fn shared_prints_the_address_and_the_warning() {
    let r = json!({"ok":true,"shared":[
        {"port":8000,"url":"http://123456789.rapp:8000"},
        {"port":22,"url":"http://123456789.rapp:22","warn":"分享这个端口，等于把这台机器能到的网络也交出去"}]});
    assert_eq!(shared(&r), "已分享：http://123456789.rapp:8000\n已分享：http://123456789.rapp:22\n分享这个端口，等于把这台机器能到的网络也交出去\n");
}

#[test]
fn pipe_errors_say_the_next_step() {
    assert_eq!(pipe_error("123456789.rapp", 8000, "not shared"), "123456789 没有分享 8000。在 123456789 上运行 rapp share 8000");
    assert_eq!(pipe_error("123456789", 8000, "not allowed"), "123456789 的 8000 没有分享给这台设备");
    assert_eq!(pipe_error("123456789", 8000, "offline"), "123456789 不在线");
    assert_eq!(pipe_error("123456789", 8000, "refused"), "123456789 的 8000 上没有服务在听");
    assert_eq!(pipe_error("gpu1", 22, "unknown name"), "不认识 gpu1。现在只能写 9 位的设备 ID");
    assert_eq!(pipe_error("123456789", 22, "no key"), "这台设备还没有填 key");
    assert_eq!(pipe_error("123456789", 22, "boom"), "接不上 123456789 的 22：boom");
}

#[test]
fn table_with_and_without_shares() {
    let none = json!({"ok":true,"id":"123456789","relay":"online","shares":[]});
    assert_eq!(table(&none), "这台设备：123456789.rapp   中继：已连接\n（没有分享）\n");
    let some = json!({"ok":true,"id":"123456789","relay":"online","shares":[
        {"port":22,"allow":["mini"],"url":"http://123456789.rapp:22","listening":true},
        {"port":8000,"url":"http://123456789.rapp:8000","listening":false}]});
    let t = table(&some);
    assert!(t.lines().nth(1).unwrap().starts_with("端口"));
    assert!(t.contains("有服务在听") && t.contains("没有服务在听") && t.contains("mini"));
    assert_eq!(t.lines().count(), 4);
}

#[test]
fn hosts_lists_devices_and_what_is_wrong() {
    let r = json!({"ok":true,"hosts":[
        {"id":"123456789","name":"gpu1","shares":[{"port":8000},{"port":22}]},
        {"id":"987654321","name":"mini","error":"offline"},
        {"id":"111111111","name":"书房","shares":[]}]});
    let t = hosts(&r);
    assert!(t.contains("gpu1") && t.contains("123456789.rapp") && t.contains("8000  22"));
    assert!(t.lines().any(|l| l.contains("mini") && l.contains("不在线")));
    assert!(t.lines().any(|l| l.contains("书房") && l.contains("（没有分享）")));
}
```

- [ ] **Step 3: 跑，确认失败**

Run: `cargo test -p rapp-cli`
Expected: 编译失败（crate 还不存在时是 `package ID specification rapp-cli did not match`）。

- [ ] **Step 4: 建 crate，实现 `args.rs`、`say.rs`、`main.rs`**

- [ ] **Step 5: 跑，确认通过**

Run: `cargo test -p rapp-cli`
Expected: 6 个测试 PASS。

- [ ] **Step 6: 起真程序的一条测试**（加在 `rust/testkit/tests/forward.rs`）

```rust
#[tokio::test]
async fn the_cli_shares_and_pipes() {
    // build path: env!("CARGO_BIN_EXE_…") is not available across crates, so run
    // `cargo build -p rapp-cli` once in the test and use target/<profile>/rapp-cli
    // (the way `bins()` in tests/common finds the other programs).
    // With RAPP_HOME pointing at A's data root:  `rapp-cli share <P>` → stdout "已分享：http://<id>.rapp:<P>\n", exit 0
    // With RAPP_HOME pointing at B's:  `rapp-cli pipe <a_id> <P>` with stdin b"hello" then EOF → stdout b"hello", exit 0
    // `rapp-cli pipe <a_id> 9` → exit 1, stderr "<a_id> 没有分享 9。在 <a_id> 上运行 rapp share 9\n"
    // With RAPP_HOME at an empty directory: `rapp-cli share` → exit 1, stderr "本机的 rapp 服务没有在运行\n"
}
```

`RAPP_HOME` 指的是数据根还是 `local/`，以及测试里的服务把 `ipc.token` 写在哪，先看 `rust/testkit/tests/common/mod.rs` 的 `start_service` 和 `rapp_net::config::home`/`local`，照实际的对上；对不上时给 `rapp-cli` 加一个只给测试用的环境变量 `RAPP_LOCAL`（直接指到放 `ipc.token` 的目录），并在这条测试里用它。

- [ ] **Step 7: 跑，确认通过**

Run: `cargo test -p rapp-testkit --test forward the_cli`
Expected: PASS。

- [ ] **Step 8: Commit**

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/cli rust/testkit/tests/forward.rs
git commit -m "feat(cli): rapp-cli share, unshare, hosts and pipe"
```

---

### Task 10: 量基线，写文档

**Files:**
- Create: `rust/testkit/src/bin/measure_forward.rs`（并在 `rust/testkit/Cargo.toml` 加一个 `[[bin]]`）
- Create: `docs/superpowers/measurements/2026-11-15-port-sharing-forward-baseline.md`
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`、`docs/superpowers/specs/2026-11-11-rapp-observability-design.md`、`docs/superpowers/specs/2026-11-11-rapp-platform-design.md`、`docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`

**Interfaces:**
- Consumes: 一个真的 relay 地址和 key、两台跑着这一版服务的设备（一台分享了一个回声或 HTTP 端口）。
- Produces: `measure-forward --to <ID> --port <端口> [--n 50] [--parallel 6]`，在访问方那台机器上跑，经本机 IPC 的 `pipe`。打印四个数（毫秒，中位数和第 95 百分位）：

| 行 | 量什么 |
|---|---|
| `open_seq` | 一条一条地开 `n` 条转发，每条从发 `pipe` 命令到收到 `{"ok":true}` |
| `open_par` | 同时开 `parallel` 条，每条的同一段时间 |
| `first_byte` | 收到 `ok` 以后发 1 个字节到收回 1 个字节（对着回声端口） |
| `path` | 每条走的路（`lan`、`relay`）各多少条 |

- [ ] **Step 1: 写 `measure_forward.rs`**

- [ ] **Step 2: 本机自测**

用 `rust/testkit/tests/forward.rs` 的搭法在一条测试里起 relay 加两台服务，调 `measure_forward` 的核心函数（把它放在 `rust/testkit/src/lib.rs` 里，`bin` 只管解析参数），断言 `open_seq` 有 50 个样本、`path` 全是 `relay`。

Run: `cargo test -p rapp-testkit --test forward measure`
Expected: PASS。

- [ ] **Step 3: 请用户在真机上量一次**

分享方在 NAT 后面（不在同一个局域网），访问方经真的 relay。

Run: `cargo run -p rapp-testkit --bin measure-forward -- --to <分享方的 ID> --port <回声端口>`
Expected: 四行数字。同时用 `ping` 量访问方到 relay、分享方到 relay 的往返时间，一起记下来。

- [ ] **Step 4: 写测量文档**

机器、网络、两个往返时间、四行数字。最后一节"给下一份计划的"：规格 §5.2 的要求是"通道建好以后，每新开一条转发连接，额外的耗时不超过两台设备经 relay 的一个往返"；这里量到的 `open_seq` 中位数是它的几倍，就是下一份计划（复用通道）要消掉的量。

- [ ] **Step 5: 改相关文档**

| 文档 | 加什么 |
|---|---|
| 配置规范总览 | `local/shares.json`（格式照 Task 2）；`service.json` 的 `forward_log`（`summary` 默认、`each`） |
| 可观测性规格 | 事件表加 `forward`、`forward_sum`、`forward_refused`、`share`、`unshare`、`shares_unreadable`，字段照 Task 3、Task 7 |
| 平台规格 | 设备请求表加 `list_shares`、`forward`；IPC 命令表加 `shares`、`share`、`unshare`、`hosts`、`pipe` |
| 端口分享规格 | §5 末尾"要挪成 service 和 hub 共用"一句后面加：这一步没有挪，原因见本计划"计划定的"第 1 条；§15 第 1 步那一行注明拆成上、下两份计划，复用通道和会话优先在下；§6"只给谁"加一句：这一步只能写这台设备已经认识的设备 |

- [ ] **Step 6: 全量检查**

Run: `cd rust && cargo build --workspace 2>&1 | grep -c warning; cargo test --workspace`
Expected: 第一条打印 `0`；测试全部 PASS。

- [ ] **Step 7: Commit**

```bash
git add rust/testkit docs/superpowers
git commit -m "docs: forward baseline over the relay; config, events and requests of port sharing"
```
