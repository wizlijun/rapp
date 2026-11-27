# 安卓平板 P1a：共用重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把会话循环从 `rapp-session` 可执行文件挪进 `rapp-client-core` 的库模块，把 `LinuxSessionPort` 拆成和平台无关的 `WorkerSessionPort` + `SessionLink` + `SessionHost`，Linux 上的行为一个字节都不变；顺带先修掉 hub 读到超过 64 KiB 的回复就丢整条连接的毛病。

**Architecture:** Rust 侧 `client-core/src/session/` 收下 `bin/rapp-session.rs` 的全部逻辑，可执行文件只剩把标准输入输出接上去的 `main`。Dart 侧端口只认两个小接口：`SessionLinks`（开一条会话通路，Linux 是子进程；规格只要「一个造 SessionLink 的函数」，这里做成类，理由见 Self-review 的偏离表）和 `SessionHost`（落盘目录、剪贴板、选文件、分离窗口通道、追踪目录、两个能力位），`LinuxSessionHost` 装下现在散在端口里的 Linux 专属代码。P1b 的安卓只需再写一个 `FfiSessionLinks` 和 `AndroidSessionHost`。

**Tech Stack:** Rust（tokio、anyhow）、Flutter/Dart、`flutter_test`。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`（§6.2、§6.3、§14.2 第 1 条、§14.3）；P0 结果 `docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md`（第 4 节「会话自己断的原因」、补丁表 `link.rs` 那行）。

**拆法（和规格不同的一处，理由）：** 规格 §6.3 说这一步「单独一个分支、单独合并、纯重构」。64 KiB 那个毛病（`tasks/todo.md`「安卓平板」第一条，「P1 接会话之前要修好」）是共用 hub 的行为修复，不是重构，塞进重构分支就不「纯」了，而且它在桌面上同样会丢连接，没理由等 Linux 实机回归。所以本计划是**两个分支、两次合并**：Task 1–2 在 `fix/hub-long-reply`，只要 Mac 门禁全过就合（发版 session 会照常发出去）；Task 3–8 在 `refactor/session-port`，按 §6.3 的条件合（Mac 门禁 + Linux 实机回归）。两个分支互不依赖，可以并行，但 `refactor/session-port` 合并前要先 `git merge main`。

## Global Constraints

- Linux 上 `rapp-session` 的行为、输出格式一个字节都不变，现有测试照跑（§6.2）。
- `refactor/session-port` 是纯重构：不带任何安卓代码（§6.3）。不新增 `Platform.isAndroid`、不加 `android-ffi`、不加 `gui/android/`。
- **唯一允许的新行为是 Task 7 的 `dropTextures`**：规格 §6.3 把它列进了这个分支。它的调用方只有 iOS 的 `memoryWarning`（`gui/lib/ui/main_state.dart:3436-3444`，只对不在台上、已断开的会话调），所以 Linux 上的行为照样不变。Task 6 的 ack 在子进程通路上是空操作，也不改 Linux 行为。
- `refactor/session-port` 合并条件：Mac 门禁全过；Linux 上实机走一遍会话（接入、打字、拖动、复制粘贴、传文件、分离窗口）。**Linux 实机验不了就不合并**，写进 `tasks/todo.md` 等另一台机器验（§6.3）。
- Mac 门禁（每个分支合并前在分支上跑全）：
  ```bash
  swift build -c release && swift test
  cd rust && cargo test --workspace --no-fail-fast
  cd rust && cargo clippy --workspace --all-targets -- -D warnings
  cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test
  git checkout gui/pubspec.lock   # 跑完测试还原
  ```
  Flutter 在 `~/development/flutter/bin`，不在 PATH 上。
- 已知的本机失败，不算这次弄坏的（`tasks/todo.md`「安卓平板」第二条）：`gui/test/embed/linux_detach_test.dart` 的两条（要先 `cd rust && cargo build --release -p rapp-client-core --bin rapp-session`），`gui/test/service_client_test.dart` 的「ServiceMonitor share…」时好时坏。门禁里出现这几条之外的失败就停。
- relay 地址和密钥不打印、不进日志、不提交。
- 实机回归连 Mac 时用单应用会话；桌面会话会把用户自己的会话顶掉，Mac 在最后一个计数会话结束 10 s 后自动锁屏。只有某一步确实要桌面会话才开。
- 合并照 `CLAUDE.md`：在分支上 `git merge main` 解决冲突，再在本机 main 上 `git merge --no-ff <branch>`，提交信息 `merge: <中文说明>（<branch>）`。不改版本号（`gui/pubspec.yaml`、`rust/Cargo.toml`、`Cargo.lock`），不打 tag，不 `git push`，不动 `website/releases.json`。
  - **推送的唯一例外（用户 2026-11-27 定）**：为了 Linux 实机回归，允许 `git push origin refactor/session-port`。只推这一个分支；不推 main、不推别的分支、不打 tag。合并进本机 main 之后删掉远端分支：`git push origin --delete refactor/session-port`。`fix/hub-long-reply` 不推。
- 搜代码用 `/usr/bin/grep`（这台机器的 `grep` 是 ugrep，`-q -v` 的退出码不一样）。
- 不读不搜 `docs/archives/`。
- 探查分支 `probe/android-p0`（`cfd7997e`）上的这些东西不带过来：`keeps_link`（按错误文字判断）、`P0_SLOW_MS`、`p0 fps` / `p0 traffic` 日志、`rapp_p0_resolve`、`LinuxSessionPort.ffi` 和它的 `slow`、`main_p0_shell.dart`、`p0/` 页面、`p0SlowFromProperty`、`_traffic`。看探查代码只用 `git show cfd7997e:<path>`。
- 和 `origin/fix/windows-gate`（`05e54ae7`，没合）会撞：它改了 `linux_session_port_test.dart`（加了 skip「C 段做完时打开」）、`session_worker_test.dart`、`linux_detach_test.dart`、`rust/hub/src/link.rs`（`RELAY_WAIT`）、`tasks/todo.md`。它先进 main 的话，合并时留下它的 skip 和 `RELAY_WAIT`，把它对 `linux_session_port_test.dart` 的改动搬到改名后的 `worker_session_port_test.dart`；它对 `session_worker_test.dart` 的改动原样留着（本计划不碰那个文件）。

## Review Focus

1. **Mac 服务跑了一小时以上，余力的第一行带满 720 个点**：余力照常到，连接和上面的会话都不断。→ Task 2 的 `history_of_720_widest_points_stays_under_half_the_history_line`（余量）和 `watch_load_reply_reads_past_64k`（真走 hub）。
2. **别的回复也超长（比如将来某个列表）**：那一个请求失败，同一条连接不跟着丢，下一个请求还走这条连接，不重连。→ Task 2 的 `a_too_long_reply_keeps_the_cached_link`。
3. **会话通路中途死掉（子进程崩了、管道断了）**：端口恰好发一次 `disconnected`，不挂住、不重复。→ Task 6 的 `'a worker that dies mid-session gives one disconnected'`。
4. **帧被丢掉**：每个从通路来的帧包恰好 ack 一次，丢掉的也算；P1b 的进程内通路少 ack 一次会话就永远结束不了，多 ack 会放进第二帧。丢帧的地方有四处，都要 ack：读循环里 `if (closed || disconnected) break` 读到却不用的那一包、信箱里被新帧顶掉的那一包、`_stopTransport` 清掉的待画帧、`frame()` 解码失败的那一帧。→ Task 6 的 `'every frame packet is acked once, dropped ones too'`。
5. **内存紧张时放掉了画面，会话再回到台上**：画面马上回来（用最后一帧重画），不是黑的；重画不 ack。→ Task 7 的 `'dropTextures forgets pictures and restoreStage brings them back'`。

---

## 分支一：`fix/hub-long-reply`

### Task 1: 读行带上限参数，超长报专门的错

**Files:**
- Modify: `rust/net/src/line.rs`（`read_line`、`read_json` 和它们的测试）

**Interfaces:**
- Consumes: 无
- Produces:
  - `pub const HISTORY_LINE: usize = 256 * 1024;`（带满 720 个点的余力首行用；实测 75,125 字节，每点 99–103 字节，留到 2 倍以上的余量）
  - `#[derive(Debug)] pub struct LineTooLong(pub usize);`，实现 `Display`（`line longer than {n} bytes`）和 `std::error::Error`；`n` 是这次的上限
  - `pub async fn read_line_max<R: AsyncRead + Unpin>(r: &mut R, max: usize) -> Result<Option<String>>`：超长时返回 `anyhow::Error::new(LineTooLong(max))`
  - `pub async fn read_json_max<R: AsyncRead + Unpin>(r: &mut R, max: usize) -> Result<Value>`
  - `read_line` / `read_json` 不改签名，转调 `*_max(r, MAX_LINE)`

- [x] **Step 1: 建分支**（已建好：分支 `fix/hub-long-reply`，worktree `.worktrees/hub-long-reply`，建于 `5ff4c980`。不要再 `git worktree add`。开工前确认它没落后 main）

```bash
cd /Users/bruce/git/rapp/.worktrees/hub-long-reply && git merge-base --is-ancestor main HEAD || git merge main
```

- [ ] **Step 2: 写失败的测试**（`line.rs` 的 `mod tests`）

```rust
#[tokio::test]
async fn read_line_max_takes_a_line_exactly_at_the_limit() {
    let mut b = vec![b'x'; 100]; b.push(b'\n');
    assert_eq!(read_line_max(&mut b.as_slice(), 100).await.unwrap().unwrap().len(), 100);
}

#[tokio::test]
async fn read_line_max_reports_line_too_long_with_its_limit() {
    let mut b = vec![b'x'; 101]; b.push(b'\n');
    let e = read_line_max(&mut b.as_slice(), 100).await.unwrap_err();
    assert_eq!(e.downcast_ref::<LineTooLong>().map(|t| t.0), Some(100));
}

#[tokio::test]
async fn read_line_still_stops_at_64k() {
    let mut b = vec![b'x'; MAX_LINE + 1]; b.push(b'\n');
    let e = read_line(&mut b.as_slice()).await.unwrap_err();
    assert_eq!(e.downcast_ref::<LineTooLong>().map(|t| t.0), Some(MAX_LINE));
}
```

- [ ] **Step 3: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-net line::tests`
Expected: 编译失败，`read_line_max`、`LineTooLong` 没定义

- [ ] **Step 4: 按上面的 Produces 实现**

`read_line` 原来 `bail!("line longer than 64 KiB")` 的地方换成 `LineTooLong(max)`。改文件头注释：64 KiB 是默认上限，个别已知很长的回复由调用方给更大的上限。

- [ ] **Step 5: 跑，看它通过**

Run: `cd rust && cargo test -p rapp-net`
Expected: PASS（含原有的 `reads_lines_without_overreading`）

- [ ] **Step 6: 提交**

```bash
git add rust/net/src/line.rs
git commit -m "fix(net): read_line_max with a typed LineTooLong error; HISTORY_LINE for long replies"
```

### Task 2: hub 给余力的回复放宽上限，超长不丢连接

**Files:**
- Modify: `rust/hub/src/link.rs`（第 17 行的 `use`、`:143-151` `exchange`、`:679-696` `relay_hello`、`:872-919` `request` 两处出错分支、`mod tests` 的 `use` 和两条新测试）
- Modify: `rust/service/src/load/rules.rs`（`mod tests`，只加一条测试）
- Modify: `rust/testkit/tests/hub_load.rs`（`old_service` 改成转调 `service_with_load`，加 `wide_load` 和一条测试）
- Create: `rust/testkit/tests/long_reply.rs`（relay 上的假 A 和一条测试）
- Modify: `tasks/todo.md`（Step 6，单独提交）

不改 `rust/testkit/tests/common/mod.rs`：起服务、起 hub、起 relay 的工具都已经有了（`RelayRig::start`、`relay_conn`、`hub_relay`、`Hub::start`、`wait_path`、`take_paths`、`ipc_once`）。relay 上的假 A 照抄 `rust/testkit/tests/forward.rs:1593-1628` 的 `fake_on_relay` / `FakeA`（`FakeA` 只要三个字段；它的 `asked_mux` 只认 `mux`，这里换成下面的 `asked`）（它在 `forward.rs` 里是私有的，挪进 `common` 要动 `forward.rs`，不值得）。

**Interfaces:**
- Consumes: Task 1 的 `read_json_max`、`LineTooLong`、`HISTORY_LINE`；现有的 `MAX_LINE`
- Produces（都在 `link.rs`，私有）:
  - `fn reply_limit(op: &Op) -> usize`：`Op::WatchLoad` 和 `Op::Load { history: true, .. }` 给 `HISTORY_LINE`，其余 `MAX_LINE`
  - `fn link_kept(e: &anyhow::Error) -> bool`：`e.downcast_ref::<LineTooLong>().is_some()`。按类型认，不按错误文字（探查的 `keeps_link` 按文字，不能带过来）

- [ ] **Step 1: 写失败的测试**

**(a) `link.rs` 的 `mod tests`。** 现有的 `use` 是：

```rust
use super::{cacheable, finish, dial_order, is_refusal, must_forget, probe_asks_relay, repeatable, reply_wait, unreached};
use super::{OPEN_TERM_WAIT, REPLY_WAIT};
use rapp_net::msg::Op;
```

在它下面加两行（`anyhow!` 从 `super` 的 `use anyhow::{anyhow, …}` 来，不用另写）：

```rust
use super::{link_kept, reply_limit};
use rapp_net::line::{LineTooLong, HISTORY_LINE, MAX_LINE};
```

两条测试：

```rust
#[test]
fn reply_limit_widens_only_the_load_history() {
    assert_eq!(reply_limit(&Op::WatchLoad), HISTORY_LINE);
    assert_eq!(reply_limit(&Op::Load { history: true, top: false }), HISTORY_LINE);
    assert_eq!(reply_limit(&Op::Load { history: false, top: false }), MAX_LINE);
    assert_eq!(reply_limit(&Op::Ping), MAX_LINE);
}

#[test]
fn link_kept_only_for_a_too_long_line() {
    assert!(link_kept(&anyhow::Error::new(LineTooLong(MAX_LINE))));
    assert!(!link_kept(&anyhow::anyhow!("line longer than 65536 bytes"))); // 文字一样也不算
    assert!(!link_kept(&anyhow::anyhow!("stream closed")));
}
```

**(b) `rules.rs` 的 `mod tests`**（已有 `use super::*;`，`Sample`、`Cpu`、`Mem`、`Heat`、`HeatLevel` 都在范围里；`disk(total, avail)` 是这个模块现成的小工具）。这一条守的是**余量**，修之前就会通过，通过就留着：

```rust
#[test]
fn history_of_720_widest_points_stays_under_half_the_history_line() {
    // point() 只写 at、cpu、gpu、mem 的比例、heat 档位、最紧那块盘的比例（见 History::point）。
    // 每一项都取最长的写法：10 位的 at；0.1 这种 f32 转成 f64 后有 17 位小数；比例除不尽；heat 最高档。
    let mut h = History::new();
    for i in 0..KEEP {
        h.push(Sample {
            at: 4_000_000_000 + i as u64,
            cpu: Some(Cpu { pct: 0.1, cores: 8, load1: None }),
            gpu: Some(0.1),
            mem: Some(Mem { total: 9_876_543_211, avail: 1_234_567_891, swap_used: None, pressure: None }),
            heat: Some(Heat { level: HeatLevel::Critical, celsius: None }),
            disks: vec![disk(9_876_543_211, 1_234_567_891)],
            ..Default::default()
        });
    }
    let line = serde_json::to_vec(&h.history_json()).unwrap().len();
    // 约 95,000 字节：超过 64 KiB（这正是要修的情形），不到 HISTORY_LINE 的一半
    assert!(rapp_net::line::MAX_LINE < line && line < rapp_net::line::HISTORY_LINE / 2, "{line}");
}
```

**(c) `testkit/tests/hub_load.rs`。** 顶上加：

```rust
use rapp_net::line::MAX_LINE;
use rapp_service::load::{Cpu, Heat, HeatLevel, Mem, Sample, Sampler, KEEP};
```

把 `old_service()` 的身体挪进一个带参数的函数，`old_service` 转调它（`Opts` 里其余字段一个不改）：

```rust
/// A service like `old_service`, with `load` as given.
async fn service_with_load(load: Option<rapp_service::LoadOpts>) -> TestService {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    let svc = rapp_service::Service::start(rapp_service::Opts {
        home: home.path().to_path_buf(),
        bin_dir: Some(bins.path().to_path_buf()),
        gui: None,
        lock_grace: Duration::from_secs(1),
        worker_idle: Duration::from_secs(60),
        log_dir: home.path().join("logs"),
        runner: Arc::new(FakeRunner::new()),
        update: None,
        data: None,
        advertise_lan: None,
        forward_sum_every: Duration::from_secs(600),
        forward_priority: rapp_conn::relay::FORWARD_PRIORITY,
        channels: true,
        pacing: true,
        map_ports: TEST_PORTS,
        own_ports: true,
        load,
    })
    .await
    .unwrap();
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    TestService { svc, home, bins, id }
}

/// A service whose load sampling is off, as an older device.
async fn old_service() -> TestService {
    service_with_load(None).await
}

/// A sampler whose every point is as long as `point()` can write it, every 5 ms, so the
/// history is full (KEEP points) within seconds. The service fills `disks` itself.
fn wide_load() -> rapp_service::LoadOpts {
    struct Wide;
    impl Sampler for Wide {
        fn sample(&mut self) -> Sample {
            let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
            Sample {
                at,
                cpu: Some(Cpu { pct: 0.1, cores: 8, load1: None }),
                gpu: Some(0.1),
                mem: Some(Mem { total: 9_876_543_211, avail: 1_234_567_891, swap_used: None, pressure: None }),
                heat: Some(Heat { level: HeatLevel::Critical, celsius: None }),
                ..Default::default()
            }
        }
    }
    rapp_service::LoadOpts {
        every: Duration::from_millis(5),
        sampler: Arc::new(|| Box::new(Wide)),
        disk_wait: Duration::from_secs(2),
    }
}
```

测试：

```rust
#[tokio::test]
async fn watch_load_reply_reads_past_64k() {
    let a = service_with_load(Some(wide_load())).await;
    // 等服务攒满 KEEP 个点，并确认这一行真的超过 64 KiB
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    let r = loop {
        let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"load","history":true})).await;
        if r["history"].as_array().map_or(0, |h| h.len()) == KEEP {
            break r;
        }
        assert!(tokio::time::Instant::now() < deadline, "history never filled: {}", r["history"].as_array().map_or(0, |h| h.len()));
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert!(serde_json::to_vec(&r["history"]).unwrap().len() > MAX_LINE);
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    let first = pushed_load(&mut hub).await;
    assert_eq!(first["history"].as_array().map(|h| h.len()), Some(KEEP), "{first}");
    let next = pushed_load(&mut hub).await;
    assert!(next["point"].is_object(), "{next}");
    hub.finish().await;
}
```

**(d) 新文件 `rust/testkit/tests/long_reply.rs`。** 假 A 挂在 relay 上（hub 走 relay 时每个请求开一条新的转发流，假 A 数得到流的条数，这样「重连了没有」能直接数出来；QUIC 直连上 `request()` 走的是同一段分支，测 relay 这一路就够了）：

```rust
//! rapp-hub: a reply longer than the line limit fails that one request and keeps the cached link.

mod common;
use common::*;

use quinn::Endpoint;
use rapp_conn::relay::RelayConn;
use rapp_conn::Pipe;
use rapp_net::line::read_json;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// A device on `rig` with an ID and identity of its own, trusting the relay's key: lookups are
/// answered, and each relayed stream is handed to `serve` with its number (from 0) on a task of
/// its own. Its ID, the streams so far, and what keeps it on the relay. (Copied from forward.rs.)
async fn fake_on_relay<F, Fut>(rig: &RelayRig, serve: F) -> (String, Arc<AtomicUsize>, (Endpoint, RelayConn))
where
    F: Fn(usize, Pipe, FakeA) -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    let id = "876543219".to_string();
    let me = Arc::new(rapp_wire::Identity::generate().unwrap());
    let (ep, conn) = relay_conn(rig, &me, &rig.key).await;
    conn.register(&id, &[]).await.unwrap();
    let streams = Arc::new(AtomicUsize::new(0));
    let (pushes, n, key) = (conn.clone(), streams.clone(), Arc::new(rapp_wire::Key { relay: rig.key.relay, root: rig.key.root }));
    let fake = FakeA { id: id.clone(), me, key };
    tokio::spawn(async move {
        loop {
            match pushes.next_push().await {
                Ok(rapp_conn::relay::Pushed::Incoming { mut reply, .. }) => {
                    let _ = reply.write_all(b"{\"ok\":true}\n").await;
                    let _ = reply.flush().await;
                }
                Ok(rapp_conn::relay::Pushed::Relayed { stream, .. }) => {
                    tokio::spawn(serve(n.fetch_add(1, Ordering::SeqCst), stream, fake.clone()));
                }
                Ok(rapp_conn::relay::Pushed::Closed { .. }) | Err(_) => return,
                Ok(_) => {}
            }
        }
    });
    (id, streams, (ep, conn))
}

#[derive(Clone)]
struct FakeA {
    id: String,
    me: Arc<rapp_wire::Identity>,
    key: Arc<rapp_wire::Key>,
}

impl FakeA {
    /// TLS and the hello on a relayed stream, as A answers them, and the request read.
    async fn asked(&self, stream: Pipe) -> (Pipe, Value) {
        let (mut pipe, facts) = rapp_conn::e2e_accept(stream, &self.me).await.unwrap();
        let home = tempfile::tempdir().unwrap();
        let hello = rapp_conn::Me { id: &self.id, name: "fake-a", key: Some(&self.key) };
        rapp_conn::hello_server(&mut pipe, &facts, &hello, &rapp_conn::Paired::empty(home.path())).await.unwrap();
        let op = read_json(&mut pipe).await.unwrap();
        (pipe, op)
    }
}

/// Sends `cmd` and returns the event that answers its `req` (path events are kept aside by `Hub`).
async fn answer(hub: &mut Hub, cmd: Value) -> Value {
    hub.send(cmd.clone()).await;
    loop {
        let r = hub.next().await;
        if r["req"] == cmd["req"] {
            return r;
        }
    }
}

#[tokio::test]
async fn a_too_long_reply_keeps_the_cached_link() {
    let rig = RelayRig::start().await;
    // 每个请求一行 {"ok":true,"events":[]}；logs 请求带 q=long 时多一个 70 KiB 的字段
    let (id, streams, _on_relay) = fake_on_relay(&rig, |_, stream, fake| async move {
        let (mut pipe, op) = fake.asked(stream).await;
        let mut r = json!({"ok": true, "events": []});
        if op["q"] == "long" {
            r["pad"] = json!("x".repeat(70 * 1024));
        }
        let _ = rapp_net::line::write_json(&mut pipe, &r).await;
        let mut rest = Vec::new();
        let _ = pipe.read_to_end(&mut rest).await;
    })
    .await;
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let mut hub = Hub::start(home.path(), bins.path());
    assert_eq!(answer(&mut hub, json!({"cmd":"add_host","id":id,"req":1})).await["event"], "host_added");
    assert_eq!(answer(&mut hub, json!({"cmd":"logs","id":id,"req":2})).await["event"], "logs");
    hub.wait_path(&id, "relay").await;
    let before = streams.load(Ordering::SeqCst);
    let r = answer(&mut hub, json!({"cmd":"logs","id":id,"q":"long","req":3})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert!(r["error"].as_str().unwrap_or_default().contains("line longer than 65536 bytes"), "{r}");
    let r = answer(&mut hub, json!({"cmd":"logs","id":id,"req":4})).await;
    assert_eq!(r["event"], "logs", "{r}");
    // 两个请求两条流：没有因为长回复而忘掉连接再重连
    assert_eq!(streams.load(Ordering::SeqCst), before + 2);
    assert!(!hub.take_paths().iter().any(|p| p["id"] == id), "the link was dropped and re-made");
    hub.finish().await;
}
```

- [ ] **Step 2: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-hub link::tests && cargo test -p rapp-service load::rules && cargo test -p rapp-testkit --test hub_load --test long_reply`
Expected:
- `link::tests` 编译失败，`reply_limit`、`link_kept` 没定义（先停在这里的话后面两条命令不跑；可以先只加 `link.rs` 的两个空壳函数让它编过，再看下面两条）
- `history_of_720_widest_points_stays_under_half_the_history_line` 直接 PASS（守余量，留着）
- `watch_load_reply_reads_past_64k` FAIL：`pushed_load` 等不到带 720 个点的 `load`（`next_where` 撞上 `error` 事件，或超时 `no pushed load event in time`；hub 丢了连接、重连后再读又超长，所以一直等不到）
- `a_too_long_reply_keeps_the_cached_link` FAIL：`Logs` 可以重发（`repeatable`），所以长回复之后 hub 忘掉连接、重连、再发一次，流的条数大于 `before + 2`

- [ ] **Step 3: 实现**

- 第 17 行：`use rapp_net::line::{read_json, write_json};` 改成 `use rapp_net::line::{read_json, read_json_max, write_json, LineTooLong, HISTORY_LINE, MAX_LINE};`（`read_json` 还有别处在用，留着）。
- `reply_limit`、`link_kept` 写在 `reply_wait`（`:127`）旁边，按 Produces。
- `exchange`：`read_json(&mut s)` 换成 `read_json_max(&mut s, lines.last().map_or(MAX_LINE, |op| reply_limit(op)))`。
- `relay_hello`：`wait` 块里 `read_welcome` 之后的 `let r = read_json(&mut pipe).await?;` 换成 `let r = read_json_max(&mut pipe, reply_limit(op)).await?;`；`read_welcome` 不动。
- `hello`（直连握手，回的是 `ping`）不动。
- `request()` 缓存连接那支：在现有的第一个出错分支 `Err(e) if host.forced_relay() && is_relay_unreachable(&e)` **之前**加
  ```rust
  // A reply too long is that one reply's fault; the link is fine, so keep it and do not retry.
  Err(e) if link_kept(&e) => return Err(e),
  ```
- `request()` 新连接那支：`match send_on { … Err(e) => { self.forget_if_dead(&host.id, &link, op); Err(e) } }` 改成先判：
  ```rust
  Err(e) => {
      if !link_kept(&e) {
          self.forget_if_dead(&host.id, &link, op);
      }
      Err(e)
  }
  ```

- [ ] **Step 4: 跑，看它通过**

Run: `cd rust && cargo test -p rapp-hub && cargo test -p rapp-service && cargo test -p rapp-testkit --test hub_load --test long_reply`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add rust/hub/src/link.rs rust/service/src/load/rules.rs rust/testkit/tests/hub_load.rs rust/testkit/tests/long_reply.rs
git commit -m "fix(hub): load history replies read up to 256 KiB; a too-long reply no longer drops the link"
```

- [ ] **Step 6: 门禁、待办、合并**

1. 跑 Global Constraints 里的整套 Mac 门禁（这一支没动 `hub-ffi`，不用编 iOS 模拟器的库）。
2. 在分支上把 `tasks/todo.md`「## 安卓平板」下第一条（「**hub 读到超过 64 KiB 的回复行就丢整条连接。**…」）的 `- [ ]` 改成 `- [x]`，后面写一句「`fix/hub-long-reply` 修了：余力回复放宽到 256 KiB，超长只让那一个请求失败、不丢连接」。`git add tasks/todo.md && git commit -m "docs(todo): 64 KiB 回复行已修"`。
3. `git merge main`，在本机 main 上 `git merge --no-ff fix/hub-long-reply -m "merge: hub 读长回复不再丢连接（fix/hub-long-reply）"`。不推。

---

## 分支二：`refactor/session-port`

### Task 3: 会话循环进库（`rapp_client_core::session`）

**Files:**
- Create: `rust/client-core/src/session/mod.rs`（`bin/rapp-session.rs` 里除 `main` 以外的全部，连同那 10 条测试和测试里的 `Sink`）
- Move: `rust/client-core/src/bin/session_output/mod.rs` → `rust/client-core/src/session/output.rs`（`git mv`，它自己的 1 条测试跟着走）
- Move: `rust/client-core/src/bin/session_trace/mod.rs` → `rust/client-core/src/session/trace.rs`（`git mv`）
- Modify: `rust/client-core/src/lib.rs`（加 `pub mod session;`）
- Modify: `rust/client-core/src/bin/rapp-session.rs`（只剩文件头注释和 `main`）

不改 `Cargo.toml`：新测试不用 `tempfile`。

**Interfaces:**
- Consumes: 无
- Produces:
  - `pub fn run(mut input: impl BufRead + Send + 'static, out: &Output) -> Result<()>`：第一行是启动参数（仍按 `take(1024 * 1024)` 读），之后一行一条命令（仍按 `take(2 * 1024 * 1024)`，在原来那个读线程里读）
  - `pub fn serve(input: impl BufRead + Send + 'static, writer: impl Write + Send + 'static)`：就是现在 `main` 的身体——`Output::spawn(writer)`、`run`、发 `disconnected` 事件（`reason` 是 `closed` 或 `{e:#}`）、`finish`、`join` 写线程
  - `pub use output::Output;`（`spawn`、`event`、`frame`、`finish` 不改）
  - `pub use trace::trace_to;`，`pub fn trace_to(dir: PathBuf) -> &'static Path`：设追踪目录，第一次设的算数，返回生效的那个。库里不再读环境变量
  - 可执行文件：
    ```rust
    use rapp_client_core::session;

    fn main() {
        // Before the first record: the trace file is opened once, on the first record.
        if let Some(dir) = std::env::var_os("RAPP_STREAM_TRACE_DIR") {
            session::trace_to(dir.into());
        }
        session::serve(std::io::BufReader::new(std::io::stdin()), std::io::stdout());
    }
    ```
    - 不滤空串：现在设成空串时文件落在当前目录，照旧。
    - 用 `BufReader::new(stdin())` 而不是 `stdin().lock()`：`StdinLock` 不是 `Send`，送不进读线程。

- [ ] **Step 1: 建分支，记下基线**

```bash
cd /Users/bruce/git/rapp && git worktree add .worktrees/session-port -b refactor/session-port main
cd .worktrees/session-port/rust && cargo test -p rapp-client-core 2>&1 | /usr/bin/grep -E '^test result|Running'
```

Expected: 记下每个测试目标的通过数。bin 目标 `rapp-session` 是 11（文件里 10 条 + `session_output` 1 条）；lib 和其余目标以本次实测为准（P0 那次量到的「lib 18」对不上源码里的 `#[test]` 个数，不用管它，只拿这次的数对比）。

- [ ] **Step 2: 写失败的测试**

先建空模块 `session/mod.rs`（`lib.rs` 加 `pub mod session;`），只放测试：

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::Path;
    use std::sync::{Arc, Mutex};

    // Step 4 搬代码时，bin 测试里现成的同名 Sink 搬过来，删掉这一份
    #[derive(Clone, Default)]
    struct Sink(Arc<Mutex<Vec<u8>>>);
    impl Write for Sink {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Splits the pipe format (u32 LE length, then that many bytes: kind byte + body).
    fn packets(b: &[u8]) -> Vec<Vec<u8>> {
        let mut v = Vec::new();
        let mut i = 0;
        while i + 4 <= b.len() {
            let n = u32::from_le_bytes(b[i..i + 4].try_into().unwrap()) as usize;
            v.push(b[i + 4..i + 4 + n].to_vec());
            i += 4 + n;
        }
        v
    }

    #[test]
    fn serve_over_memory_ends_with_one_disconnected() {
        // 输入只有一行坏的启动参数；输出写进内存
        let sink = Sink::default();
        serve(&b"not json\n"[..], sink.clone());
        let all = packets(&sink.0.lock().unwrap());
        let events: Vec<_> = all.iter().filter(|p| p[0] == 0).collect();
        assert_eq!(events.len(), 1, "{all:?}");
        assert!(std::str::from_utf8(&events[0][1..]).unwrap().contains("\"event\":\"disconnected\""));
    }

    #[test]
    fn trace_to_keeps_the_first_dir() {
        // 不存在的目录：同一个测试进程里别的测试调 record 时打不开文件，什么都不写
        let a = trace_to("/nonexistent/rapp-trace-a".into());
        let b = trace_to("/nonexistent/rapp-trace-b".into());
        assert_eq!(a, Path::new("/nonexistent/rapp-trace-a"));
        assert_eq!(b, a);
    }
}
```

`&b"…"[..]` 是 `&'static [u8]`，本身就是 `BufRead + Send + 'static`。`trace_to` 的返回值就是读取口，不另加 `#[cfg(test)]` 的入口。

- [ ] **Step 3: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-client-core --lib session::`
Expected: 编译失败，`serve`、`trace_to` 没定义

- [ ] **Step 4: 搬代码**

1. `git mv rust/client-core/src/bin/session_output/mod.rs rust/client-core/src/session/output.rs`，`git mv rust/client-core/src/bin/session_trace/mod.rs rust/client-core/src/session/trace.rs`。
2. `session/mod.rs` 顶上：`mod output; mod trace; pub use output::Output; pub use trace::trace_to;`。把 `rapp-session.rs` 的 `event`、`menus`、`number`、`float`、`command`、`run`、`is_input`、`Probe`、`read_loop` 和整个 `#[cfg(test)] mod tests`（10 条测试 + `Sink`）搬进来；Step 2 写的测试并进同一个 `mod tests`，删掉重复的 `Sink`。
3. 要改的只有这些，别的一字不改：
   - `use rapp_client_core::{codec::Decoder, probe::PathProbe, protocol::{self as p, Incoming, Menu}}` → `use crate::{codec::Decoder, probe::PathProbe, protocol::{self as p, Incoming, Menu}}`；`output.rs` 里的 `use rapp_client_core::codec::{DecodedCanvas, Decoder};` → `use crate::codec::{DecodedCanvas, Decoder};`
   - `session_trace::record`（原 `rapp-session.rs:204/329/331/346`）→ `trace::record`；`crate::session_trace::record`（原 `session_output/mod.rs:117/121/126`）→ `super::trace::record`
   - `output.rs`：`pub(super) struct Output` → `pub struct Output`；`trace.rs` 的 `pub(super) fn record` 不动（`session` 和它下面都看得见）
   - `run`：签名改成 Produces 那样；删掉开头的 `let stdin = std::io::stdin(); let mut input = stdin.lock();`；删掉 `drop(input);`；读线程里删掉 `let mut input = std::io::stdin().lock();`，线程是 `move` 闭包，直接用移进去的 `input`（这样第一行读进 `BufReader` 缓冲里的后续字节不会丢）
   - 新写 `serve`，身体是原 `main` 的四行（`Output::spawn(writer)` 那个返回的线程句柄改名 `thread`，免得和参数 `writer` 撞名）
   - `trace.rs`：
     ```rust
     static DIR: OnceLock<PathBuf> = OnceLock::new();

     /// Sets the trace dir; the first call wins and its dir is returned. Call it before the
     /// first `record`: the file is opened once, on the first `record`, and stays as it is.
     pub fn trace_to(dir: PathBuf) -> &'static Path {
         DIR.get_or_init(|| dir)
     }
     ```
     `record` 里 `let dir = std::env::var_os("RAPP_STREAM_TRACE_DIR")?; let path = std::path::PathBuf::from(dir).join(…)` 换成 `let path = DIR.get()?.join(format!("worker-{}.log", std::process::id()));`，`use` 里加 `path::{Path, PathBuf}`
4. `rapp-session.rs` 删掉 `mod session_output; mod session_trace;`、所有 `use` 和搬走的代码，只留文件头注释和 Produces 里的 `main`。

- [ ] **Step 5: 跑，看它通过，和基线对数**

Run: `cd rust && cargo test -p rapp-client-core 2>&1 | /usr/bin/grep -E '^test result|Running' && cargo clippy -p rapp-client-core --all-targets -- -D warnings`
Expected: lib 目标 = 基线 lib + 13（搬来 10 + 1，新加 2）；bin 目标 `rapp-session` 是 0 条；其余目标和基线一样，`host_wire` 照样起真的 `rapp-session` 并通过；clippy 干净。

- [ ] **Step 6: 提交**

```bash
git add -A rust/client-core
git commit -m "refactor(client-core): the session loop is a library module; rapp-session only wires stdin/stdout"
```

### Task 4: `SessionLink` / `SessionLinks` 和子进程那一半

**Files:**
- Create: `gui/lib/embed/session_link.dart`
- Test: `gui/test/embed/session_link_test.dart`

**Interfaces:**
- Consumes: `gui/lib/embed/session_worker.dart` 的 `SessionWorker`（`start`、`fromProcess`、`pid`、`packets`、`send`、`closeInput`、`kill`、`exitCode`、`inputDone`，不改）
- Produces:

```dart
/// 一条会话通路：一个 rapp-session 子进程（Linux、Windows），或进程内的会话库（安卓，P1b）。
abstract class SessionLink {
  int get id;                         // 追踪日志里的编号（子进程是 pid）
  Stream<Uint8List> get packets;      // 管道格式的包：首字节 0 是事件 JSON，1 是「24 字节帧头 + BGRA」
  void send(String line);             // 一行 JSON 命令，不带换行
  void ack();                         // 一帧用完了（做成图片或决定丢掉）；子进程那边是空操作
  Future<void> close();               // 不再发命令（关输入）
  void kill();                        // 立刻结束
  Future<int> get exitCode;
  Future<void> get inputDone;         // 输入那头断了时带错误完成
}

abstract class SessionLinks {
  Future<void> check();               // 端口 init 时调；不可用就抛
  Future<SessionLink> open();
}

class ProcessSessionLink implements SessionLink { ProcessSessionLink(SessionWorker worker); }
class ProcessSessionLinks implements SessionLinks { ProcessSessionLinks(String executable); }
```

`ProcessSessionLinks.check()` 文件不在时抛 `StateError('rapp-session not found: $executable')`（现在 `init` 里的原话）；`open()` 是 `ProcessSessionLink(await SessionWorker.start(executable))`。`ProcessSessionLink`：`id` 是 `pid`，`packets`/`send`/`exitCode`/`inputDone` 直接转给 worker，`ack()` 什么都不做（管道自己有背压），`close()` 是 `closeInput()`，`kill()` 是 `kill(ProcessSignal.sigkill)`。

- [ ] **Step 1: 写失败的测试**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_link.dart';
import 'package:rapp/embed/session_worker.dart';

void main() {
  test('ProcessSessionLinks.check names a missing executable', () async {
    await expectLater(ProcessSessionLinks('/nope/rapp-session').check(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('rapp-session not found'))));
  });

  test('ProcessSessionLink passes packets, lines and close through', () async {
    // 子进程读一行命令，回一个管道格式的包：长度 3（u32 LE），种类 0，内容就是那一行；再等输入关掉
    final proc = await Process.start('sh', ['-c', r'''read line; printf '\003\000\000\000\000'; printf '%s' "$line"; cat >/dev/null''']);
    final link = ProcessSessionLink(SessionWorker.fromProcess(proc));
    final first = link.packets.first;
    link.send('{}');
    expect(await first, [0, 0x7b, 0x7d]);
    link.ack(); // 子进程那边是空操作：不抛、不往输入里写东西
    await link.close();
    expect(await link.exitCode, 0);
    expect(link.id, proc.pid);
  }, skip: Platform.isWindows ? '要 sh' : null);

  test('a worker that exits early gives no packets and its exit code', () async {
    final link = ProcessSessionLink(SessionWorker.fromProcess(await Process.start('sh', ['-c', 'exit 3'])));
    expect(await link.packets.toList(), isEmpty);
    expect(await link.exitCode, 3);
    link.kill(); // 已经结束，再杀不抛
  }, skip: Platform.isWindows ? '要 sh' : null);
}
```

端口层面「中途死掉只发一次 `disconnected`」在 Task 6 测（这里只测通路本身）。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/session_link_test.dart`
Expected: FAIL，编译不过：`session_link.dart` 不存在

- [ ] **Step 3: 按 Produces 实现**

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2
Expected: 3 条 PASS

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/session_link.dart gui/test/embed/session_link_test.dart
git commit -m "refactor(gui): SessionLink/SessionLinks with the child-process implementation"
```

### Task 5: `SessionCopy` 和 `SessionHost` / `LinuxSessionHost`

**Files:**
- Move: `gui/lib/embed/linux_clipboard.dart` → `gui/lib/embed/session_copy.dart`（`git mv`；`LinuxDesktop` 挪走后只剩 `SessionCopy` 和存取函数）
- Create: `gui/lib/embed/session_host.dart`（抽象 `SessionHost`）
- Create: `gui/lib/embed/linux_session_host.dart`（`LinuxSessionHost`，收下原 `LinuxDesktop`、端口里的 `downloads`、`reveal`、`_native`）
- Modify: `gui/lib/embed/linux_session_port.dart`（这一步还叫这个名字）、`gui/test/embed/linux_transfer_test.dart`（`LinuxCopy` 等改名）
- Modify（只在用到旧名字时）: `gui/test/embed/linux_session_port_test.dart`——Step 3 的 grep 有它才改
- Test: `gui/test/embed/linux_session_host_test.dart`

`linux_transfer.dart` 不动：它不引用 `LinuxCopy`、`LinuxDesktop` 和 `linux_clipboard.dart`。

**Interfaces:**
- Consumes: 无
- Produces:
  - `class SessionCopy`（原 `LinuxCopy`，字段、`toMap`、`fromMap` 不变）；`Future<String> saveSessionCopy(SessionCopy copy, String textDir, String fileDir, String stem)`、`Future<SessionCopy?> loadSessionCopy(String path)`（原 `saveLinuxCopy` / `loadLinuxCopy`，参数不变）
  - ```dart
    abstract class SessionHost {
      /// 端口 init 时调一次。分离窗口那一组的原生端从这里接上，它的来电交给 [onDetachCall]。
      /// 能力位（[supportsDetach]）在这之后才定。
      Future<void> init(Future<Object?> Function(MethodCall call) onDetachCall);
      String downloads();                        // 传文件落盘目录
      Future<bool> reveal(String path);          // 去看收到的文件
      Future<SessionCopy?> readClipboard();
      Future<bool> writeClipboard(SessionCopy copy);
      Future<List<String>> chooseFiles();
      String? get traceDir;                      // null：不追踪
      MethodChannel? get detachChannel;          // 分离窗口那一组；null：没有
      bool get supportsInlineNativeComposer;
      bool get supportsDetach;
    }
    ```
    **能力位只有一个出处**：`supportsDetach`、`supportsInlineNativeComposer` 只在 host 上算；端口的这两个 getter 改成转调 `host`，端口里不再留 `_native`。
  - `class LinuxSessionHost implements SessionHost { LinuxSessionHost({MethodChannel channel = const MethodChannel('rapp/linux'), Map<String, String>? env}); }`（`env` 缺省是 `Platform.environment`）：
    - `init(onDetachCall)`：现在端口 `init` 里那段原样搬来——`try { _native = await channel.invokeMethod<bool>('init') ?? false; channel.setMethodCallHandler(onDetachCall); } on MissingPluginException { _native = false; }`
    - `supportsDetach => _native`；`supportsInlineNativeComposer => true`（端口现在给的值）
    - `downloads()`：`env['RAPP_DOWNLOADS'] ?? '${dataRoot(env, Platform.operatingSystem)}/files/transfers'`（现在端口构造里的那段，操作系统名照旧取 `Platform.operatingSystem`，不写死 `'linux'`）
    - `reveal(path)`：现在端口 `:482-494` 的那段（文件在才 `xdg-open` 它所在的目录，退出码 0 算成；`ProcessException` 返回 false）。端口那边只留 `if (path is! String) return false; return host.reveal(path);`
    - `readClipboard` / `writeClipboard` / `chooseFiles`：原 `LinuxDesktop` 的三个方法原样（`LinuxCopy` 改名 `SessionCopy`）
    - `traceDir`：`env['RAPP_STREAM_TRACE_DIR']`，空串算 null（和现在 `_traceStream` 的 `isNotEmpty` 判断一致）
    - `detachChannel => channel`
  - 文件名 `linux_transfer.dart`、`linux_text_upload.dart` 不改（它们走的是 A 的传文件协议，和平台无关，改名只会让这次的差异变大；类名 `LinuxTransfers` 也不改）

- [ ] **Step 1: 写失败的测试**（`gui/test/embed/linux_session_host_test.dart`）

```dart
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_session_host.dart';
import 'package:rapp/paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LinuxSessionHost reads downloads and the trace dir from the environment', () {
    final h = LinuxSessionHost(env: {'RAPP_DOWNLOADS': '/d', 'RAPP_STREAM_TRACE_DIR': '/t'});
    expect(h.downloads(), '/d');
    expect(h.traceDir, '/t');
    final bare = LinuxSessionHost(env: {'RAPP_STREAM_TRACE_DIR': '', 'HOME': '/h'});
    expect(bare.traceDir, isNull);
    expect(bare.downloads(), '${dataRoot({'HOME': '/h'}, Platform.operatingSystem)}/files/transfers');
  });

  test('LinuxSessionHost falls back to Flutter text when the native clipboard is missing', () async {
    // rapp/linux 没有处理器 → MissingPluginException → 读 Flutter Clipboard 的文字
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData' ? {'text': 'hi'} : null);
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final copy = await LinuxSessionHost().readClipboard();
    expect(copy?.kind, 'text');
    expect(copy?.text, 'hi');
  });

  test('LinuxSessionHost without the native side has no detach', () async {
    final h = LinuxSessionHost();
    await h.init((_) async => null);
    expect(h.supportsDetach, isFalse);
    expect(h.supportsInlineNativeComposer, isTrue);
  });
}
```

存取的来回不另写测试：`linux_transfer_test.dart:197` 的 `'pinned images, arbitrary data and files survive reload independently of the source'` 已经测了 save/load 来回，改名后照跑。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/linux_session_host_test.dart`
Expected: FAIL，编译不过：`linux_session_host.dart` 不存在

- [ ] **Step 3: 实现**

1. `git mv gui/lib/embed/linux_clipboard.dart gui/lib/embed/session_copy.dart`，改类名和函数名；`LinuxDesktop` 整个类剪进 `linux_session_host.dart`（变成 `LinuxSessionHost` 的三个方法）。
2. `/usr/bin/grep -rn 'LinuxCopy\|LinuxDesktop\|saveLinuxCopy\|loadLinuxCopy\|linux_clipboard' gui/lib gui/test` 逐处换掉（应当只剩端口、`linux_transfer_test.dart`）。
3. 端口（仍叫 `LinuxSessionPort`）：
   - 构造改成 `LinuxSessionPort(this.executable, {Future<void> Function()? framePresented, SessionHost? host})`，`host = host ?? LinuxSessionHost()`；去掉 `desktop:`、`downloads:` 和这两个字段
   - `init`：文件检查照旧，然后 `await host.init(_nativeEvent);` 代替原来的 `try { _native = …; desktop.channel.setMethodCallHandler(_nativeEvent); } on MissingPluginException { … }`；删掉 `_native` 字段
   - `supportsDetach => host.supportsDetach`、`supportsInlineNativeComposer => host.supportsInlineNativeComposer`；原来读 `_native` 的两处（`:141` 的 `if (_native && s?.detached == true)`、`:603` 的 `if (!_native || s.detached) return null;`）改读 `host.supportsDetach`
   - `_Session` 构造的最后两个参数 `downloads, desktop` 换成一个 `host`；`transfers` 用 `downloads: host.downloads`；字段 `final LinuxDesktop desktop` 换成 `final SessionHost host`
   - 端口和 `_Session` 里所有 `desktop.channel.invokeMethod(...)` 改成 `host.detachChannel?.invokeMethod(...)`（`_nativeCall`、`detach`、`attach`、`windows`、`frame`、`close` 里那几处；它们都只在 `detached` 或 `supportsDetach` 为真时走到，Linux 上 `detachChannel` 不会是 null）；`desktop.readClipboard` / `writeClipboard` / `chooseFiles` 改成 `host.…`
   - 顶上的 `_traceStream` 常量删掉，`_streamTrace` 改成 `void _streamTrace(SessionHost host, int worker, String stage, String detail)`，开头 `if (host.traceDir == null) return;`；四个调用点（`queueFrame` 一处、`drainFrames` 三处）把 `host` 传进去
   - `reveal` 那一支按 Produces 改成转调 `host.reveal`

- [ ] **Step 4: 跑，看它通过**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test test/embed/`
Expected: analyze 无问题；`linux_session_host_test.dart` 3 条 PASS；`test/embed/` 除已知的 `linux_detach_test` 两条外 PASS

- [ ] **Step 5: 提交**

```bash
git add -A gui/lib/embed gui/test/embed
git commit -m "refactor(gui): SessionHost; LinuxSessionHost takes the Linux clipboard, files, reveal, trace and detach channel"
```

### Task 6: `WorkerSessionPort`、`FrameSink`、`hidMacKeyCode`、ack，桌面入口接上

**Files:**
- Move: `gui/lib/embed/linux_session_port.dart` → `gui/lib/embed/worker_session_port.dart`（`git mv`）
- Move: `gui/test/embed/linux_session_port_test.dart` → `gui/test/embed/worker_session_port_test.dart`（`git mv`）
- Create: `gui/lib/embed/frame_sink.dart`
- Create: `gui/test/embed/fake_session_link.dart`（`FakeLink`、`OneLink`、`FailingLinks`、`FakeHost`；P1b 的测试也用）
- Modify: `gui/lib/main.dart`（第 12 行的 import、第 101-102 行）
- Modify: `gui/test/embed/linux_key_bar_test.dart`（import、构造、`seedSessionForTest`）
- Modify: `gui/test/embed/linux_detach_test.dart`（import、`'linux_session_port_test.dart' as wire` 的路径、构造、`seedSessionForTest`）

`session_worker_test.dart` 不动：它不用端口，也没有要改的名字。

**Interfaces:**
- Consumes: Task 4 的 `SessionLinks`、`SessionLink`、`ProcessSessionLinks`、`ProcessSessionLink`；Task 5 的 `SessionHost`、`LinuxSessionHost`、`SessionCopy`
- Produces:
  - `class WorkerSessionPort extends SessionPort with WidgetsBindingObserver { WorkerSessionPort(SessionLinks links, SessionHost host, {Future<void> Function()? framePresented, FrameSink sink = const ImageFrameSink()}); }`
  - `init()` 开头 `await links.check();`（代替 `File(executable).exists()` 那行），然后 `await host.init(_nativeEvent);`
  - 开会话 `await links.open()`，代替 `SessionWorker.start(executable)`。`_Session` 持有 `final SessionLink link`：原来的 `process.pid` → `link.id`，`process.packets` → `link.packets`，`process.send` → `link.send`，`closeInput()` → `close()`，`kill(ProcessSignal.sigkill)` → `kill()`，`exitCode`、`inputDone` 同名。`inputDone.catchError → disconnect('session worker stopped')` 和 `_stopTransport` 里 2 s 的强杀计时照旧。取消的启动（`_cancelledStarts`）照旧 `link.packets.drain`、`link.close()`、`link.kill()`，不 ack（P1b 的 `close` 自己放开闸门）
  - `@visibleForTesting void seedSessionForTest(Object sid, SessionLink link, {bool reading = false})`：原来收 `Process`。`reading: true` 时和 `start` 一样挂上 `inputDone` 和读循环——把 `start` 里 `_sessions[sid] = s;` 之后挂 `inputDone.catchError` 和 `s.read().whenComplete(...)` 的两段抽成私有的 `void _watch(Object sid, _Session s)`，`start` 和 seed 共用，测试走的就是真路径。默认 `false`：现有测试自己读子进程的输出，照旧不挂
  - **ack（规格 §6.2 第 1 条：做成图片或决定丢掉之后 ack，不等上屏）**：每个从通路读到的帧包（kind 1）恰好 ack 一次；事件包、`restoreStage` 的重画不 ack。`_Session` 加一个 `bool _pendingAck = false;`（信箱里那帧是从通路来的、还没 ack），四处：
    1. `queueFrame(Uint8List bytes, {bool restore = false, bool fromLink = false})`：开头 `if (_pendingAck) link.ack(); _pendingAck = fromLink;`，再放进信箱（被顶掉的那帧在这里 ack）
    2. `drainFrames`：取出一帧时 `final ack = _pendingAck; _pendingAck = false;`，`await frame(bytes, restore: restore)` 包进 `try { … } finally { if (ack) link.ack(); }`，在等 `framePresented` 之前（`frame()` 画好、决定不画、或抛错都算用完）
    3. `_stopTransport`：`_pendingFrame = null;` 那里先 `if (_pendingAck) link.ack(); _pendingAck = false;`
    4. 读循环：`if (closed || disconnected) break;` 改成 `if (closed || disconnected) { if (packet[0] == 1) link.ack(); break; }`；帧走 `queueFrame(Uint8List.sublistView(packet, 1), fromLink: true)`
    P1b 的 FFI 要容得下 `close` 之后再来的 `ack`（`_stopTransport` 先关输入、再 ack 不了的情况不会有，但顺序别依赖它）。
  - ```dart
    /// 一帧画面怎么上屏。现在只有「整帧做成 ui.Image」一种（ImageFrameSink），丙落地时加第二种。
    abstract class FrameSink {
      Future<ui.Image> decode(Uint8List bgra, int width, int height);
      void retire(ui.Image? image);                                    // 下一帧画完后再释放
    }
    class ImageFrameSink implements FrameSink { const ImageFrameSink(); }
    ```
    `decode` 收下现在 `frame()` 里 `ImmutableBuffer.fromUint8List` → `ImageDescriptor.raw(bgra8888)` → `instantiateCodec` → `getNextFrame` 那一段（`codec` 用完就 `dispose`，和现在一样）；`frame()` 里拿到图之后的 `if (closed || detached || (disconnected && !restore)) return;` 和裁剪照旧留在端口。`retire` 是现在顶层的 `_retire`（`addPostFrameCallback` 里 `dispose` + `scheduleFrame`），四个调用点改成 `sink.retire(...)`。`_Session` 的字段叫 `sink`（`frame()` 里已有一个局部变量叫 `frames`）
  - `int? hidMacKeyCode(PhysicalKeyboardKey key)`（原 `linuxMacKeyCode`，映射不变：Ctrl 仍映成 Mac 的 Command 55）
  - `main.dart`：`import 'embed/worker_session_port.dart';`，并加 `import 'embed/session_link.dart';`、`import 'embed/linux_session_host.dart';`；第 101-102 行 `Platform.isLinux ? WorkerSessionPort(ProcessSessionLinks('$bin/rapp-session'), LinuxSessionHost()) : ChannelSessionPort()`

- [ ] **Step 1: 只改名，不改行为**

```bash
git mv gui/lib/embed/linux_session_port.dart gui/lib/embed/worker_session_port.dart
git mv gui/test/embed/linux_session_port_test.dart gui/test/embed/worker_session_port_test.dart
```

`/usr/bin/grep -rn 'LinuxSessionPort\|linux_session_port\|linuxMacKeyCode' gui/lib gui/test` 逐处换成 `WorkerSessionPort`、`worker_session_port`、`hidMacKeyCode`（含 `main.dart:12`、`linux_detach_test.dart` 的 `as wire` 那行、`worker_session_port_test.dart` 里的 `'physical keyboard mapping includes Command, arrows and punctuation'`——它测的就是 `hidMacKeyCode`，不另写新测试）。构造参数这一步还不动。

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test test/embed/`
Expected: analyze 无问题；除已知的两条外 PASS

```bash
git add -A gui/lib gui/test
git commit -m "refactor(gui): rename LinuxSessionPort to WorkerSessionPort, linuxMacKeyCode to hidMacKeyCode"
```

- [ ] **Step 2: 写失败的测试，现有调用改成新构造**

**(a) `gui/test/embed/fake_session_link.dart`：**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:rapp/embed/session_copy.dart';
import 'package:rapp/embed/session_host.dart';
import 'package:rapp/embed/session_link.dart';

/// A link whose packets the test pushes; counts acks and kills, keeps the lines sent.
class FakeLink implements SessionLink {
  final _packets = StreamController<Uint8List>();
  final _exit = Completer<int>();
  final _input = Completer<void>();
  final sent = <String>[];
  int acks = 0;
  int kills = 0;

  void push(List<int> packet) => _packets.add(Uint8List.fromList(packet));

  /// The input side breaks, as when the worker dies.
  void failInput() {
    if (!_input.isCompleted) _input.completeError(StateError('input closed'));
  }

  @override
  int get id => 7;
  @override
  Stream<Uint8List> get packets => _packets.stream;
  @override
  void send(String line) => sent.add(line);
  @override
  void ack() => acks++;
  @override
  Future<void> close() async {
    // The packet stream stays open, so a test can still push a frame after the port stopped.
    if (!_exit.isCompleted) _exit.complete(0);
  }
  @override
  void kill() {
    kills++;
    if (!_exit.isCompleted) _exit.complete(-9);
  }
  @override
  Future<int> get exitCode => _exit.future;
  @override
  Future<void> get inputDone => _input.future;
}

/// Opens [link] every time.
class OneLink implements SessionLinks {
  OneLink(this.link);
  final SessionLink link;
  @override
  Future<void> check() async {}
  @override
  Future<SessionLink> open() async => link;
}

/// [check] throws [error].
class FailingLinks implements SessionLinks {
  FailingLinks(this.error);
  final Object error;
  @override
  Future<void> check() async => throw error;
  @override
  Future<SessionLink> open() async => throw error;
}

/// No clipboard, no files, no detach, no trace.
class FakeHost implements SessionHost {
  @override
  Future<void> init(Future<Object?> Function(MethodCall call) onDetachCall) async {}
  @override
  String downloads() => '/nonexistent/downloads';
  @override
  Future<bool> reveal(String path) async => false;
  @override
  Future<SessionCopy?> readClipboard() async => null;
  @override
  Future<bool> writeClipboard(SessionCopy copy) async => false;
  @override
  Future<List<String>> chooseFiles() async => const [];
  @override
  String? get traceDir => null;
  @override
  MethodChannel? get detachChannel => null;
  @override
  bool get supportsInlineNativeComposer => true;
  @override
  bool get supportsDetach => false;
}
```

**(b) `worker_session_port_test.dart`**：import 里加 `package:rapp/embed/linux_session_host.dart`、`package:rapp/embed/session_link.dart`、`package:rapp/embed/session_worker.dart`、`'fake_session_link.dart'`。现有调用照下面换（`linux_key_bar_test.dart`、`linux_detach_test.dart` 同样换，它们也加这几个 import）：

| 原来 | 换成 |
|---|---|
| `LinuxSessionPort('unused', framePresented: …)`（Step 1 后叫 `WorkerSessionPort('unused', …)`） | `WorkerSessionPort(ProcessSessionLinks('unused'), LinuxSessionHost(), framePresented: …)` |
| `WorkerSessionPort('/nonexistent-worker', …)`、`('/bin/cat', …)`、`(worker, …)` | 同上，`ProcessSessionLinks('/nonexistent-worker')` 等 |
| `port.seedSessionForTest(3, proc)` | `port.seedSessionForTest(3, ProcessSessionLink(SessionWorker.fromProcess(proc)))` |

新测试的小工具（用文件里现有的 `u32`、`f32`）：

```dart
/// A pipe frame packet: 2×2 canvas covering (0,0)–(2,2), white BGRA.
List<int> frame2x2() => [1, ...u32(2), ...u32(2), ...f32(0), ...f32(0), ...f32(2), ...f32(2), ...List.filled(16, 255)];

/// A pipe event packet: one 2×2 window at the origin, no title bar.
List<int> windowsEvent() => [0, ...utf8.encode(jsonEncode({
  'event': 'windows',
  'windows': [
    {'id': 1, 'parent': 0, 'kind': 'normal', 'title': 't', 'x': 0, 'y': 0, 'w': 2, 'h': 2,
     'titleBar': 0, 'resizable': true, 'focused': true, 'texture': null, 'visible': [0, 0, 1, 1]},
  ],
}))];

Future<void> until(bool Function() ok) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
```

三条新测试：

```dart
test('every frame packet is acked once, dropped ones too', () async {
  final link = FakeLink();
  final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
  final events = <SessionEvent>[];
  final sub = port.events.listen(events.add);
  port.seedSessionForTest(3, link, reading: true);
  // 事件不 ack；三帧连着来，信箱顶掉的那帧也 ack
  link.push(windowsEvent());
  link.push(frame2x2());
  link.push(frame2x2());
  link.push(frame2x2());
  await until(() => link.acks == 3);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  expect(link.acks, 3);
  // 解码失败的那帧：ack，然后会话断开
  link.push([1, 1, 2, 3]);
  await until(() => events.any((e) => e is DisconnectedEvent));
  expect((events.whereType<DisconnectedEvent>().single).reason, contains('画面解码失败'));
  expect(link.acks, 4);
  // 断开之后读到的帧：读循环丢掉它，也 ack
  link.push(frame2x2());
  await until(() => link.acks == 5);
  port.dispose();
  await sub.cancel();
});

test('a worker that dies mid-session gives one disconnected', () async {
  final link = ProcessSessionLink(SessionWorker.fromProcess(await Process.start('sh', ['-c', 'exit 3'])));
  final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
  final events = <SessionEvent>[];
  final sub = port.events.listen(events.add);
  port.seedSessionForTest(3, link, reading: true);
  // 读循环到头和输入断开两条路都会喊断开，只能出一次
  await Future<void>.delayed(const Duration(milliseconds: 300));
  expect(events.whereType<DisconnectedEvent>().length, 1);
  port.dispose();
  await sub.cancel();
}, skip: Platform.isWindows ? '要 sh' : null);

test('init asks the links and the host first', () async {
  final links = FailingLinks(StateError('rapp-session not found: x'));
  await expectLater(WorkerSessionPort(links, FakeHost()).init(), throwsStateError);
});
```

- [ ] **Step 3: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/worker_session_port_test.dart`
Expected: FAIL，编译不过：`WorkerSessionPort` 还收 `String`、`seedSessionForTest` 还收 `Process`、没有 `reading:`。（ack 的计数这一步看不到；实现后它若不是 3/4/5，就是 Produces 里四处 ack 有漏有多。）

- [ ] **Step 4: 实现 Produces 里剩下的**

按 Produces 逐条改：构造和 `init`；`_Session` 改持 `SessionLink`；抽 `_watch`；四处 ack；`FrameSink` 抽进 `frame_sink.dart`；`main.dart` 那两行。

- [ ] **Step 5: 跑，看它通过**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test test/embed/ && /usr/bin/grep -rn 'LinuxSessionPort\|linuxMacKeyCode\|LinuxCopy\|LinuxDesktop\|SessionWorker.start' gui/lib gui/test | /usr/bin/grep -v 'session_link.dart\|session_worker'`
Expected: analyze 无问题；除已知的两条外 PASS（含三条新的）；grep 没有输出（`SessionWorker.start` 只剩 `session_link.dart` 里那一处）

- [ ] **Step 6: 提交**

```bash
git add -A gui/lib gui/test
git commit -m "refactor(gui): WorkerSessionPort over SessionLinks + SessionHost; FrameSink; frames acked once"
```

### Task 7: `dropTextures` 在共用端口里实现

**Files:**
- Modify: `gui/lib/embed/worker_session_port.dart`（覆盖 `dropTextures`，加两个测试入口）
- Test: `gui/test/embed/worker_session_port_test.dart`

**Interfaces:**
- Consumes: `SessionPort.dropTextures(Object sid)`（`gui/lib/embed/session_port.dart:610`，默认转成 `drop_textures` 方法调用；调用方 `gui/lib/ui/main_state.dart:3442` 的 `memoryWarning`，只对不在台上、已断开的会话调）；Task 6 的 `FrameSink.retire`、`FakeLink`
- Produces:
  - `@override void dropTextures(Object sid) => _sessions[sid]?.dropPictures();`
  - `_Session.dropPictures()`：`for (final p in _pictures.values) { sink.retire(p.image); }`、`_pictures.clear();`、`publish();`（和 `close` 里放图那几行同一个写法，再发一次窗口表，窗口都不带图）。`lastNativeFrame` 留着——它是 `restoreStage` 重画的来源，只占一份 BGRA
  - `@visibleForTesting List<RemoteWindow> picturesForTest(Object sid) => _sessions[sid]?._pictures.values.toList() ?? const [];`
  - `@visibleForTesting void restoreStageForTest(Object sid) => _sessions[sid]?.restoreStage();`

- [ ] **Step 1: 写失败的测试，加两个测试入口**

先在端口里加上 Produces 的两个 `ForTest` 入口（它们只读状态、只转调现有的 `restoreStage`，不改行为），让测试失败在该失败的地方：

```dart
test('dropTextures forgets pictures and restoreStage brings them back', () async {
  final link = FakeLink();
  final port = WorkerSessionPort(OneLink(link), FakeHost(), framePresented: () async {});
  final events = <SessionEvent>[];
  final sub = port.events.listen(events.add);
  port.seedSessionForTest(3, link, reading: true);
  link.push(windowsEvent());
  link.push(frame2x2());
  await until(() => events.any((e) => e is WindowsEvent && e.windows.any((w) => w.image != null)));
  // 会话断开、不在台上：memoryWarning 调 dropTextures 的情形
  link.failInput();
  await until(() => events.any((e) => e is DisconnectedEvent));
  port.dropTextures(3);
  expect(port.picturesForTest(3), isEmpty);
  port.restoreStageForTest(3); // 等于会话回到台上
  await until(() => port.picturesForTest(3).isNotEmpty);
  expect(link.acks, 1); // 只有那一帧；重画不是新帧，不 ack
  port.dispose();
  await sub.cancel();
});
```

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/worker_session_port_test.dart --name dropTextures`
Expected: FAIL 在 `expect(port.picturesForTest(3), isEmpty)`：默认的 `dropTextures` 只发一个 `drop_textures` 调用，`_pictures` 还在

- [ ] **Step 3: 按 Produces 实现**

- [ ] **Step 4: 跑，看它通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/worker_session_port_test.dart`
Expected: PASS（整个文件，含 Task 6 的三条）

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/worker_session_port.dart gui/test/embed/worker_session_port_test.dart
git commit -m "feat(gui): WorkerSessionPort.dropTextures lets go of an off-stage session's pictures"
```

### Task 8: 门禁、Linux 实机回归、合并

**Files:**
- Modify: `tasks/todo.md`（验过：「## Windows 版 A 段（地基）…」一节末尾一行；验不了：「## 安卓平板」一节一行）

**Interfaces:**
- Consumes: Task 3–7 的全部
- Produces: 本机 main 上的 `merge: 会话端口拆成共用的 WorkerSessionPort（refactor/session-port）`；`tasks/todo.md` Windows A 段写明接口在哪个提交

- [ ] **Step 1: 合进最新的 main，跑整套 Mac 门禁**

```bash
cd /Users/bruce/git/rapp/.worktrees/session-port && git merge main
```

然后跑 Global Constraints 里的整套命令（这一支没动 `hub-ffi`）。`origin/fix/windows-gate` 已进 main 的话按 Global Constraints 最后一条处理冲突。
Expected: 除已知的三条外全过。

- [ ] **Step 2: Linux 实机回归**

Linux 机器要拿到这个分支：按 Global Constraints 里推送的唯一例外，`git push origin refactor/session-port`（只推这个分支，不推 main、不打 tag）。Linux 机器上的 session 拉下来验：

```bash
git fetch origin && git checkout refactor/session-port
scripts/build-linux.sh            # 要 Flutter ≥ 3.50.0
cd gui && flutter test test/embed/   # Linux 上那些 skip 掉的真 worker 测试这里才跑
```

然后开打出来的包，对 Mac 开一个单应用会话（比如「文本编辑」），逐项走：

| 项 | 做法 | 过的标准 |
|---|---|---|
| 接入 | 全景里点 Mac，开单应用会话 | 画面出来，窗口表对 |
| 打字 | 外接键盘打一段中英文；Ctrl+C / Ctrl+V | Mac 上一个字不少；Ctrl 当 ⌘ |
| 拖动 | 拖窗口、选一段文字 | 跟手，画面不花 |
| 复制粘贴 | Mac 复制一段字到 Linux，Linux 复制一段字到 Mac | 两边都到 |
| 传文件 | Linux 发一个文件给 Mac；Mac 发一个给 Linux，点「在文件夹中显示」 | 都到，落在 `files/transfers`，文件管理器打开 |
| 分离窗口 | 把会话分离出去再收回 | 和改之前一样 |

- [ ] **Step 3a（Linux 验过）: 写待办、合并、删远端分支**

在分支上往 `tasks/todo.md` 的「## Windows 版 A 段（地基）（计划 `docs/superpowers/plans/2026-11-26-rapp-windows-a-foundation.md`，分支 `feat/windows-foundation`）」一节最后一条后面加一行：「- [ ] 会话端口的小接口（`SessionLinks` / `SessionLink` / `SessionHost`，`gui/lib/embed/session_link.dart`、`session_host.dart`）已在 `<Task 6 Step 6 的提交号>`，`ProcessSessionLink` 就是 Windows 那一半；Windows 接着加 `WindowsSessionHost`，不要另做一个（规格 §14.3）」。`git add tasks/todo.md && git commit -m "docs(todo): 会话端口接口的位置"`。然后：

```bash
cd /Users/bruce/git/rapp/.worktrees/session-port && git merge main
cd /Users/bruce/git/rapp && git merge --no-ff refactor/session-port -m "merge: 会话端口拆成共用的 WorkerSessionPort（refactor/session-port）"
git push origin --delete refactor/session-port
```

- [ ] **Step 3b（Linux 验不了）: 不合并**

分支留着（远端分支也留着，Linux 机器要用）。在本机 main 上往 `tasks/todo.md`「## 安卓平板」一节加一行：「- [ ] `refactor/session-port`（`<分支头提交号>`）Mac 门禁已过，等 Linux 实机回归（接入、打字、拖动、复制粘贴、传文件、分离窗口）后合并；合并后删远端分支；P1b 在这之前不能合」，`git add tasks/todo.md && git commit -m "docs(todo): 共用重构等 Linux 回归"`。告诉用户在等什么。

## Self-review（写完后自查，已就地改过）

- 规格覆盖：§6.2 的 `run`、`Output`、追踪参数、可执行文件只剩 `main` → Task 3；`rapp-android-ffi` 归 P1b。§6.2 第 1 条 ack 的时机 → Task 6。§6.3 的改名、`SessionLink`（`send`/包流/`ack`/`close`）、`SessionHost`（落盘、`reveal`、剪贴板、追踪、分离窗口一组、两个 `supports*`）、`dropTextures`、`FrameSink`、键码改名、`main.dart` 那一行、单独分支和合并条件 → Task 4–8。差别表是「P1 动手前」给安卓用的，放在 P1b Task 1。§14.3 的 Windows 待办 → Task 8。todo 里 64 KiB 那条 → Task 1–2。
- 和规格不一样的地方，每条的理由：

| 规格 | 本计划 | 理由 |
|---|---|---|
| §6.3：一个分支，纯重构 | 两个分支（`fix/hub-long-reply` + `refactor/session-port`） | 64 KiB 是行为修复，桌面上也丢连接，不该等 Linux 回归；见开头「拆法」 |
| §6.3：`WorkerSessionPort` 收「一个造 SessionLink 的函数」 | `SessionLinks` 类，`check()` + `open()` | 现在 `init` 要先报「rapp-session not found」，安卓要先报库打不开；一个函数只能在开会话时才失败 |
| §6.3：`SessionLink` 有 `messages` | 叫 `packets` | 内容是管道格式的包，和 `SessionWorker.packets` 同名（§15.3 名字留给实施者） |
| §6.3：`SessionLink` 只有 `send`、`messages`、`ack`、`close` | 多 `id`、`kill`、`exitCode`、`inputDone` | 现有 `_Session` 用到：追踪日志的编号（pid）、断开后 2 s 强杀、取消的启动要杀掉、输入断了要报断开。去掉就改了 Linux 行为 |
| §6.3：`SessionHost` 列了落盘、`reveal`、剪贴板、追踪、分离窗口、两个能力位 | 多 `init(onDetachCall)`、`chooseFiles`、`downloads()` 是函数 | `supportsDetach` 在 Linux 上要等原生端 `init` 回话才知道，所以 host 要有 `init`；「添加文件」现在走原生选文件；落盘目录照现在端口的写法每次现算 |
| §6.3：纯重构 | Task 7 `dropTextures` 是新行为 | 规格自己把它列进这个分支；调用方只在 iOS，Linux 不变（Global Constraints 写明） |

- 类型一致：`seedSessionForTest(Object, SessionLink, {reading})`、`WorkerSessionPort(SessionLinks, SessionHost, {framePresented, sink})`、`SessionHost.init(onDetachCall)`、`SessionCopy`、`hidMacKeyCode`、`FakeLink`/`OneLink`/`FailingLinks`/`FakeHost` 在 Task 5–7 里写法相同。P1b 计划的 `AndroidSessionHost` 要按这里的 `SessionHost` 实现 `init(onDetachCall)`（什么都不接，空操作）。
- 测试都写全了：每条新测试给了完整代码和断言，Step 3 的「失败」都写了是哪一种失败。函数体除了 Task 2、Task 3、Task 6 的 ack 这几处写明的改法，其余留给实施者照 Produces 写。
