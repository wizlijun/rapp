# 端口分享 第 1 步（下）：经 relay 的复用通道和会话优先 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 访问方经 relay 到同一台分享方的转发连接，不再每条各握一次手：一对设备之间只建一条长开的加密通道，后来的每条转发连接在里面复用，额外耗时不超过一个两台设备经 relay 的往返（规格 §5.2）；分享方的 relay 连接上，转发排在会话后面，并量出大流量转发对会话延迟的实际影响（规格 §5.3）。

**Architecture:** `rapp-conn` 里新写一个小的流复用层 `mux`（帧格式、按流的窗口、轮转调度、心跳），跑在已有的端到端 TLS 管道里面。访问方的 `Outbound` 按对方 ID 持有一条通道（同一时刻只建一次），经 relay 的请求改成在通道里开子流；对方是旧版本时退回 1a 的每条一流。分享方的 `serve_relayed` 先读第一个请求：是 `mux` 就把这条 relay 流当通道，子流逐条交给现有的 `serve_request`。优先级用 quinn 的流优先级：转发通道和旧式的转发流降到 `-1`，会话保持 `0`。relay 一行不改。

**Tech Stack:** Rust（`rust/` 工作区）：tokio、quinn 0.11（`SendStream::set_priority`）、tokio-rustls、serde_json，全是工作区已有的依赖。`rapp-conn` 的 dev-dependencies 给 tokio 加 `test-util`（暂停时钟测心跳和空闲关闭）。

**Spec:** `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（下称"规格"）§5.2、§5.3、§15 第 1 步、§16 第 9 条、§19 性能。基线：`docs/superpowers/measurements/2026-11-15-port-sharing-forward-baseline.md`。

## Global Constraints

- 基于本地 main `8218773`。在 `rust/` 下跑。单个 crate：`cargo test -p <crate>`；整体：`cargo test --workspace`。每个任务结束时 `cargo build --workspace` 没有警告。
- **不动 `rust/relay`，不动 `rust/hub`。** 会话照旧走 hub 自己的连接。
- **不加新依赖**（不要 yamux、h2、tokio-util）。用户定的：复用层自己写（第 1/2 件"自己写"）。
- 用户定的（第 2/2 件"优先级加实测"）：这一份只做优先级和测量；**不做限速**。测量不达标时如实记下，限速作为下一件要用户定的事。
- 旧版本互通：新访问方对旧分享方、旧访问方对新分享方，转发都照常能用（旧分享方回 `unknown op` 或 `bad request`）。
- 同一对设备、同一个 relay、同一把 key 之间，同一时刻最多一条通道。并发开 50 条转发，只建一次通道，分享方只记一行 `trust`。
- 日志里永远不出现：key、任何口令、流里的内容。
- 规格 §5.2 原文："一对设备之间经 relay 只建一条长开的加密通道，转发的连接在它里面复用……每新开一条转发连接，额外的耗时不超过两台设备经 relay 的一个往返"。
- 规格 §5.3 原文要求：大流量转发不能明显拖慢远程会话的操作和画面延迟，用流畅串流规格 §4.1 的工具量。

### 计划定的（规格留给实现的，以及和规格不同的）

1. **帧格式。** 每帧 `type u8 | id u32 BE | len u16 BE | payload`，头 7 字节，`payload` 最长 `MAX_FRAME` = 16 KiB。类型：`OPEN`=1、`DATA`=2、`FIN`=3、`RST`=4、`CREDIT`=5（payload 是 u32 BE 增量）、`PING`=6、`PONG`=7（两者 id 为 0，payload 8 字节原样回）。只有访问方（客户端）开子流，id 取奇数、递增；分享方不开子流。
2. **窗口。** 每条子流每个方向 `WINDOW` = 1 MiB 起始额度（和 relay 现在每条流的 1 MiB 窗口一样，单条转发不会比 1a 慢）。收方的应用读走的字节累计到 `WINDOW/2` 时回一个 `CREDIT`。每条子流还没发出去的字节最多 64 KiB，满了 `poll_write` 就等。
3. **调度。** 控制帧（`OPEN`、`CREDIT`、`RST`、`PING`、`PONG`）先发；`DATA` 在有数据又有额度的子流之间轮转，每轮每条一帧。一条子流的帧总是 `OPEN`、`DATA`…、`FIN` 的顺序：`FIN` 是这条子流的标记，排在它的数据发完之后。写下层时成批写、队列空了才 `flush`。
4. **出错的处理。** 超额度的 `DATA`、不认识的类型、`len > MAX_FRAME`、分享方收到偶数 id 或重复 id 的 `OPEN`：整条通道关掉（原因 `protocol: <哪一种>`）。已经 `RST` 过的 id 再来的帧丢掉。两头都 `FIN` 之前丢掉子流，发 `RST`。一条通道最多 `MAX_STREAMS` = 1024 条同时开着的子流：客户端 `open()` 直接报错，分享方对超出的 `OPEN` 回 `RST`。
5. **心跳和空闲。** 两头每 `PING_EVERY` = 10 秒发一个 `PING`；`DEAD_AFTER` = 30 秒什么都没收到，关掉通道（原因 `dead`）。访问方没有子流开着满 `CHANNEL_IDLE` = 5 分钟，关掉通道（原因 `idle`）。
6. **第一条请求和建通道一起发。** 访问方：开 relay 流、TLS 握手（一个往返）、然后把 hello、`{"op":"mux"}`、第一条子流的 `OPEN` 和请求一口气写出去，再读 welcome、`mux` 的回复和子流的回复（又一个往返）。所以第一条转发和 1a 一样是两个往返，之后每条一个往返。为此 `Mux::client` 接受一个"读端就绪"的 future：写端立刻能用，读端等 welcome 和 `{"ok":true}` 读完才开始读帧；future 出错时整条通道带着它的文字关掉。
7. **旧分享方。** 通道的就绪 future 读到的回复是 `unknown op` 或 `bad request` 时，访问方记下"这台是旧的"`OLD_KEEP` = 10 分钟，这次和这段时间里的请求都走 1a 的每条一流（`relayed`）。子流自己的回复是 `{"error":"unknown op"}`（分享方不认识某个子流里的请求）不算，照常当作回复交回去。
8. **选路的顺序。** 已有的局域网 QUIC 连接 → 已有的通道 → 局域网 → relay（建通道）。通道开着的时候不再试局域网，直到它空闲关掉；接受的代价：两台机器后来到了同一个局域网，最多 5 分钟后才换到直连。
9. **通道失效。** relay 地址、key 换了，或者 `hosts.json` 里给对方记的指纹在通道建好之后改了，就关掉旧通道重建；对方的指纹和 `hosts.json` 里记的不一样、但 key 为它作了证的，照 1a 接受，通道照用。在已有通道上开子流失败（通道已经断了），丢掉它，重来一次（新建）；新建的也失败就报错。
10. **优先级。** `FORWARD_PRIORITY` = `-1`；会话不设，保持 quinn 的默认 `0`。quinn 的优先级是严格的：会话流有东西要发时，同一条 QUIC 连接上的转发一个字节都不发。分享方：通道，以及旧式的单条 `forward` 流，在读到请求之后降到 `-1`。访问方：建通道的 relay 流开的时候就设 `-1`（这台设备自己也在被别人远程时，它的 relay 连接上也有会话流）。局域网上转发和会话是两条不同的 QUIC 连接，优先级管不到；访问方这边，会话走 hub 自己的 relay 连接，也不在一起。**真正挤在一起的只有分享方的 relay 连接（画面和转发下载同向）**，测量就量这里。
11. **优先级管不到瓶颈上的排队。** quinn 的优先级只决定自己发送缓冲里谁先走；包一旦发出去，在路上的瓶颈队列里会话和转发一样排队，拥塞控制（quinn 默认 Cubic）会把这个队列填满。所以测量很可能不达标；不达标就记下数字，把"限速或换拥塞控制"作为下一件事交给用户定。
12. **开关。** `rapp_service::Opts` 加两个字段：`forward_priority: i32`（正式程序里是 `FORWARD_PRIORITY`）和 `channels: bool`（正式程序里是 `true`；`false` 时分享方把 `mux` 当成不认识的请求，像旧版本一样）。两个都只给测试和测量用，不进 `service.json`。
13. **日志。** 分享方每条通道两行：开的时候 `channel`（info，`peer, name?, path, fp`），关的时候 `channel_end`（info，`peer, name?, path, fp, streams, reason, secs`）。`streams` 是这条通道上一共开过的子流数。子流里的转发照旧各记 `forward_open`、`forward` 等。访问方不记。

## Review Focus

规格没有写、但最可能让用户碰上的五种情况。每条的测试已经加进对应的任务。

1. **网页一下子开几十条连接。** 浏览器打开一个页面同时开几十条，第一条还没建好通道时后面的就来了：只能建一条通道，不能撞上 relay 的 `max_relayed_per_device`（32）或 `connect_per_target_per_min`（60）。→ Task 5 的 `fifty_at_once_share_one_channel`（用默认限额的 relay）。
2. **一个大下载和一个小请求同时走一条通道；或者一头根本不读。** 小请求不能被大下载挤死，一条不读的子流不能卡住别的子流。→ Task 2 的 `a_big_flow_does_not_starve_a_small_one`、`a_stalled_reader_does_not_block_another`。
3. **分享方还是旧版本。** 转发照样能用，而且不是每条都先试一次通道。→ Task 5 的 `an_old_sharer_falls_back_once`。
4. **用着用着 relay 重启了，或者分享方掉线又回来。** 开着的转发断掉（和 1a 一样），下一条要自己重建通道，不能一直拿着死通道报错。→ Task 5 的 `a_dead_channel_is_rebuilt`。
5. **通道里的半关闭和取消分享。** `ssh`、`curl` 上传要"一头写完、另一头还在回"；取消分享要切断通道里的那条转发，同一通道里别的端口的转发不受影响。→ Task 5 的 `half_close_survives_the_channel`、`unshare_cuts_only_that_port`。

---

## File Structure

| 文件 | 负责什么 |
|---|---|
| `rust/net/src/msg.rs`（改） | `Op::Mux` |
| `rust/conn/src/hello.rs`（改） | `read_welcome` 接受任何 `AsyncRead`（通道的读端不是 `Pipe`） |
| `rust/conn/src/mux.rs`（新） | 复用层：帧、子流、窗口、调度、心跳、空闲关闭 |
| `rust/conn/src/relay.rs`（改） | `FORWARD_PRIORITY`、`Prio`、`relay_to_at`、`Pushed::Relayed.prio` |
| `rust/conn/src/dial.rs`（改） | `Outbound` 持有通道、同时只建一次、旧版本回退 |
| `rust/conn/Cargo.toml`（改） | dev-dependencies：tokio `test-util` |
| `rust/service/src/peer.rs`（改） | `serve_request` 拆出 `serve_value` |
| `rust/service/src/relay_link.rs`（改） | `serve_relayed` 先读请求：`mux` 走通道，`forward` 降优先级 |
| `rust/service/src/channel.rs`（新） | 分享方的一条通道：回 `ok`、收子流、记 `channel`/`channel_end` |
| `rust/service/src/lib.rs`、`state.rs`、`main.rs`（改） | `Opts.forward_priority`、`Opts.channels`，存进 `State` |
| `rust/testkit/tests/common/mod.rs`（改） | `relayed_request`（从 `tests/service.rs` 挪过来）、`service_on_relay_with`、`proxy` |
| `rust/testkit/tests/forward.rs`（改） | 通道的端到端测试、§5.2 验收 |
| `rust/testkit/tests/session_priority.rs`（新） | §5.3 的测量（`#[ignore]`，手动跑） |
| `docs/superpowers/measurements/2026-11-16-port-sharing-mux.md`（新） | 进程内和弱网的数字、§5.3 的结论、真机步骤 |
| `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（改） | §5.2、§5.3、§15 的实现注 |
| `docs/superpowers/specs/2026-11-11-rapp-observability-design.md`（改） | `channel`、`channel_end` 两行 |

---

### Task 1: `mux` 请求和通用的 `read_welcome`

**Files:**
- Modify: `rust/net/src/msg.rs`（`enum Op`，和文件末尾的测试）
- Modify: `rust/conn/src/hello.rs:43`（`read_welcome`）

**Interfaces:**
- Produces: `Op::Mux`，线上是 `{"op":"mux"}`。`read_welcome<R: AsyncRead + Unpin>(s: &mut R, f: &Facts, key: Option<&Key>, want_id: &str, known: Option<&Fp>) -> Result<Accepted>`（只改了第一个参数的类型，现有调用不用改）。

- [ ] **Step 1: 写失败的测试**（`msg.rs` 现有测试旁边）

```rust
#[test]
fn mux_op() {
    assert_eq!(serde_json::to_value(Op::Mux).unwrap(), json!({"op":"mux"}));
    assert_eq!(serde_json::from_value::<Op>(json!({"op":"mux"})).unwrap(), Op::Mux);
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-net mux_op`
Expected: 编译失败，`no variant named Mux`

- [ ] **Step 3: 在 `Op` 里加 `Mux`（单元变体，放在 `Forward` 后面）；`read_welcome` 的 `s` 改成泛型 `R: AsyncRead + Unpin`**

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-net && cargo test -p rapp-conn && cargo build --workspace`
Expected: 全部 PASS，没有警告

- [ ] **Step 5: 提交**

```bash
git add rust/net/src/msg.rs rust/conn/src/hello.rs
git commit -m "feat(net): mux op; read_welcome takes any reader"
```

---

### Task 2: 复用层 `mux`

**Files:**
- Create: `rust/conn/src/mux.rs`（测试在同一个文件的 `#[cfg(test)] mod tests`）
- Modify: `rust/conn/src/lib.rs`（`pub mod mux;`）
- Modify: `rust/conn/Cargo.toml`（`[dev-dependencies]` 加 `tokio = { workspace = true, features = ["test-util"] }`）

**Interfaces:**
- Produces（全在 `rapp_conn::mux`）：

```rust
pub const MAX_FRAME: usize = 16 * 1024;
pub const WINDOW: u32 = 1 << 20;
pub const MAX_STREAMS: usize = 1024;
pub const PING_EVERY: Duration = Duration::from_secs(10);
pub const DEAD_AFTER: Duration = Duration::from_secs(30);
pub const CHANNEL_IDLE: Duration = Duration::from_secs(300);

pub type Reader = Box<dyn AsyncRead + Unpin + Send>;
pub type Writer = Box<dyn AsyncWrite + Unpin + Send>;

#[derive(Clone)]
pub struct Mux { /* Arc 里的共享状态 */ }
impl Mux {
    /// 访问方。`w` 立刻能写；读端等 `ready` 给出才开始读帧。`ready` 出错时通道带着它的文字关掉。
    pub fn client<F>(ready: F, w: Writer) -> Mux
    where F: Future<Output = io::Result<Reader>> + Send + 'static;
    /// 分享方。只收子流，不开。
    pub fn server(r: Reader, w: Writer) -> (Mux, Incoming);
    /// 开一条子流，不等对方（OPEN 和之后写的数据一起排队）。通道关了或满了 MAX_STREAMS 时报错。
    pub fn open(&self) -> io::Result<MuxStream>;
    pub fn is_closed(&self) -> bool;
    pub fn close(&self);                 // 原因 "closed"
    pub fn reason(&self) -> Option<String>;
    pub fn live(&self) -> usize;         // 正开着的子流
    pub fn opened(&self) -> u64;         // 一共开过（或收到过）的子流
    pub async fn closed(&self);          // 通道关掉时返回
}
pub struct Incoming { /* .. */ }
impl Incoming { pub async fn next(&mut self) -> Option<MuxStream>; } // 通道关了返回 None

pub struct MuxStream { /* .. */ } // AsyncRead + AsyncWrite + Unpin + Send + 'static
```

- 子流的读写错误：收到 `RST` 是 `io::ErrorKind::ConnectionReset`；通道关了是 `io::ErrorKind::ConnectionAborted`，`to_string()` 就是通道的 `reason()`。`poll_shutdown` 发 `FIN`。
- 关通道的原因文字，逐字：`closed`、`idle`、`dead`、`eof`（下层读到头）、`protocol: credit`、`protocol: type`、`protocol: len`、`protocol: id`；下层 io 出错时是那个错误的文字；`ready` 出错时是它的文字。

帧格式、窗口、调度、出错、心跳、空闲：照"计划定的"第 1 到 5 条。实现的形状由实现者定，约束是：一个读任务、一个写任务，共享状态在一把 `std::sync::Mutex` 里，锁里不做 io；`MuxStream` 的 waker 存在共享状态里。

- [ ] **Step 1: 写失败的测试**

测试用 `tokio::io::duplex(64 * 1024)` 接两头，`tokio::io::split` 拆成 `Reader`/`Writer`。辅助函数（测试模块里）：`pair() -> (Mux, Mux, Incoming)`（客户端的 `ready` 是 `async { Ok(r) }`）；`raw_server() -> (Mux /*client*/, DuplexStream /*对面的原始字节*/)`；`raw_client() -> (DuplexStream, Mux /*server*/, Incoming)`；`frame(t: u8, id: u32, payload: &[u8]) -> Vec<u8>`。

```rust
#[tokio::test]
async fn bytes_both_ways_and_half_close() {
    let (c, _s, mut inc) = pair();
    let mut a = c.open().unwrap();
    a.write_all(b"ping").await.unwrap();
    a.shutdown().await.unwrap();
    let mut b = inc.next().await.unwrap();
    let mut got = Vec::new();
    b.read_to_end(&mut got).await.unwrap();
    assert_eq!(got, b"ping");
    // 对面写完之后，这一头还能回
    b.write_all(b"pong").await.unwrap();
    b.shutdown().await.unwrap();
    let mut back = Vec::new();
    a.read_to_end(&mut back).await.unwrap();
    assert_eq!(back, b"pong");
}

#[tokio::test]
async fn two_hundred_streams_at_once() {
    // 服务端把每条收到的原样写回；200 条并发，每条 64 KiB、内容各不相同（按序号填），
    // 每条读回来的和写的一样。
}

#[tokio::test]
async fn a_stalled_reader_does_not_block_another() {
    // 子流 A：客户端写 4 MiB，服务端拿着 A 不读。
    // 200 ms 后 A 的 write_all 还没完成（卡在 WINDOW 上）。
    // 子流 B：服务端回声，10 次 1 KiB 往返在 2 秒内完成。
}

#[tokio::test]
async fn a_big_flow_does_not_starve_a_small_one() {
    // 子流 A：服务端写 64 MiB，客户端一直读，读到的总数放在 AtomicU64 里。
    // 子流 B：10 次 1 KiB 回声往返。
    // B 做完的那一刻，A 读到的 < 64 MiB（A 还没完）。
}

#[tokio::test]
async fn dropping_before_fin_resets() {
    // 客户端开 a，写 "x"，drop。服务端读 b：先读到 "x"，再读得到 ConnectionReset。
}

#[tokio::test]
async fn protocol_violations_close_the_channel() {
    // 用 raw_client 逐个起新的，各发一种坏帧，服务端 Mux 在 1 秒内 is_closed()，reason 逐字：
    // frame(9, 1, b"")                                 → "protocol: type"
    // 头里 len = MAX_FRAME + 1                         → "protocol: len"
    // frame(1, 2, b"")（偶数 id）                       → "protocol: id"
    // frame(1, 1, b"") 两次                            → "protocol: id"
    // OPEN 1，然后 DATA 共 WINDOW + 1 字节、没有 CREDIT → "protocol: credit"
}

#[tokio::test]
async fn opens_past_the_cap() {
    // 客户端：开 MAX_STREAMS 条都成功，第 MAX_STREAMS + 1 条 open() 报错。
    // 分享方：raw_client 发 MAX_STREAMS + 1 个 OPEN（id 1, 3, 5, ...），收到对最后那个 id 的 RST 帧，
    // 服务端 Mux 没有关。
}

#[tokio::test(start_paused = true)]
async fn silence_closes_the_channel() {
    // raw_server：对面只读不写。等 DEAD_AFTER + 1 秒，客户端 is_closed()，reason() == Some("dead")。
}

#[tokio::test(start_paused = true)]
async fn pings_keep_a_quiet_channel_open() {
    // pair()，开一条子流不关，什么都不写，过 90 秒，两头都没关。
}

#[tokio::test(start_paused = true)]
async fn an_idle_client_closes() {
    // pair()，开一条子流再两头都 shutdown、读到头、drop；过 CHANNEL_IDLE + 1 秒，
    // 客户端 reason() == Some("idle")。另起一对，子流一直开着，过同样时间没关。
}

#[tokio::test]
async fn writes_go_out_before_ready() {
    // 客户端的 ready 等一个 oneshot。open() 写 "x"：服务端在 oneshot 发出之前就收到了 "x"。
}

#[tokio::test]
async fn a_ready_error_closes_with_its_text() {
    // ready 返回 Err(io::Error::other("unknown op"))。open() 成功；读这条子流得到错误，
    // 它的 to_string() == "unknown op"，kind 是 ConnectionAborted；reason() == Some("unknown op")。
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-conn mux::`
Expected: 编译失败，`could not find mux`

- [ ] **Step 3: 实现 `rust/conn/src/mux.rs`**

- [ ] **Step 4: 跑，确认通过，并重复跑几遍看稳不稳**

Run: `for i in 1 2 3 4 5; do cargo test -p rapp-conn mux:: -q || break; done`
Expected: 五遍都 PASS

- [ ] **Step 5: 提交**

```bash
git add rust/conn/src/mux.rs rust/conn/src/lib.rs rust/conn/Cargo.toml
git commit -m "feat(conn): a stream multiplexer for one channel per device pair"
```

---

### Task 3: relay 流的优先级

**Files:**
- Modify: `rust/conn/src/relay.rs`（`relay_to` :177、`Pushed` :88、`bi_push` :388）
- Modify: `rust/service/src/relay_link.rs:213`（解构 `Pushed::Relayed` 时写 `prio: _`，Task 4 再传给 `serve_relayed`）
- Test: `rust/conn/tests/relay.rs`

**Interfaces:**
- Produces（`rapp_conn::relay`）：

```rust
pub const FORWARD_PRIORITY: i32 = -1;

/// 一条被推过来的 relay 流的优先级把手。set 之后，下一次往这条流写的时候生效。
#[derive(Clone)]
pub struct Prio(/* Arc<AtomicI32> 要设的值, Arc<AtomicI32> 已经设上的值（未设为 i32::MIN） */);
impl Prio {
    /// 要设的值是 0，已设的是 i32::MIN（还没设过）。
    pub fn new() -> Prio;
    pub fn set(&self, p: i32);
    /// 已经真的设到 quinn 流上的值；还没生效时是 None。
    pub fn applied(&self) -> Option<i32>;
}

impl RelayConn {
    /// 同 relay_to，开流时先把 quinn 流的优先级设成 priority。
    pub async fn relay_to_at(&self, id: &str, priority: i32) -> Result<Pipe>;
}

pub enum Pushed {
    // ...
    Relayed { peer: String, stream: Pipe, prio: Prio },
    // ...
}
```

- `relay_to(id)` 变成 `relay_to_at(id, 0)`。`relay_to_at` 在 `open_bi` 之后调 `send.set_priority(priority)`（返回的错误忽略：流已经关了，下一次写自然会报错）。
- `bi_push` 给 `Relayed` 的流包一层私有的 `Prioritized<quinn::SendStream>`：每次 `poll_write`/`poll_flush`/`poll_shutdown` 之前，要设的值和已设的不同就调 `set_priority` 并记下。流的拼法变成 `BufReader::new(tokio::io::join(recv, Prioritized::new(send, prio.clone())))`（`Incoming` 的那条照旧用 `tls::bi`）。

- [ ] **Step 1: 写失败的测试**（`conn/tests/relay.rs`，照这个文件里现有的"B 经 relay 到 A"测试搭两头）

```rust
#[tokio::test]
async fn a_pushed_stream_takes_its_priority_on_the_next_write() {
    // B relay_to_at(A, FORWARD_PRIORITY) 并写一个字节；A 的 next_push() 是 Relayed { stream, prio, .. }。
    assert_eq!(prio.applied(), None);
    prio.set(FORWARD_PRIORITY);
    stream.write_all(b"x").await.unwrap();
    stream.flush().await.unwrap();
    assert_eq!(prio.applied(), Some(FORWARD_PRIORITY));
    // B 读到 "x"：包了一层以后字节照常过去。
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-conn --test relay a_pushed_stream_takes_its_priority`
Expected: 编译失败，`no function relay_to_at` / `Relayed` 没有 `prio`

- [ ] **Step 3: 实现上面的接口；`relay_link.rs` 跟着改到能编译**

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-conn && cargo test -p rapp-service && cargo build --workspace`
Expected: 全部 PASS，没有警告

- [ ] **Step 5: 提交**

```bash
git add rust/conn/src/relay.rs rust/conn/tests/relay.rs rust/service/src/relay_link.rs
git commit -m "feat(conn): priority handle on relayed streams"
```

---

### Task 4: 分享方：经 relay 来的通道

**Files:**
- Create: `rust/service/src/channel.rs`
- Modify: `rust/service/src/peer.rs:178`（`serve_request` 拆成读 + `serve_value`）
- Modify: `rust/service/src/relay_link.rs:297`（`serve_relayed`）
- Modify: `rust/service/src/lib.rs:43`（`Opts`）、`rust/service/src/state.rs`、`rust/service/src/main.rs:32`
- Modify（跟着 `Opts` 改）：`rust/testkit/tests/common/mod.rs:67,91,530`、`rust/testkit/tests/hub.rs:676`、`rust/testkit/tests/service.rs:772`
- Modify: `rust/testkit/tests/common/mod.rs`（把 `tests/service.rs:941` 的 `relayed` 挪过来，改名 `pub async fn relayed_request`，签名不变；`service.rs` 改用它）
- Modify: `docs/superpowers/specs/2026-11-11-rapp-observability-design.md`（`forward_refused` 那行后面加两行）
- Test: `rust/testkit/tests/forward.rs`

**Interfaces:**
- Consumes: `Op::Mux`（Task 1）；`Mux::server`、`Incoming::next`、`Mux::opened`、`Mux::reason`、`Mux::client`（Task 2，测试里用）；`Prio`、`FORWARD_PRIORITY`、`relay_to_at`（Task 3）。
- Produces:
  - `rapp_service::Opts { .., forward_priority: i32, channels: bool }`；`State` 上同名两个字段。`main.rs` 里是 `FORWARD_PRIORITY` 和 `true`；testkit 里所有现有的构造也是这两个值。
  - `peer::serve_value(state: &Arc<State>, s: Pipe, v: Value, peer: Peer) -> Result<()>`：现在 `serve_request` 里 `match` 的那一整段；`serve_request` 变成读一个 JSON 再调它。`serve_value` 里没有 `Op::Mux` 的分支，落到 `_ => unknown op`（直连上、子流里来的 `mux` 都这样）。
  - `channel::serve(state: Arc<State>, pipe: Pipe, prio: Prio, peer: Peer)`：`prio.set(state.forward_priority)`；回 `{"ok":true}`（用 `write_json`，不 `shutdown`）；`tokio::io::split` 后 `Mux::server`；记 `channel`；每条子流 `tokio::spawn(serve_request(&state, Box::new(s), peer.clone()))`，子流请求失败时照 `serve_relayed` 现在的样子记一行 `msg`；`Incoming` 结束后记 `channel_end`，`streams` 取 `opened()`，`reason` 取 `reason()`，`secs` 是整秒。
  - `serve_relayed(state, stream, from, prio: Prio)`：握手和 `greet` 不变；之后在 `HELLO_WAIT` 里读第一个 JSON：`Op::Mux` 且 `state.channels` → `channel::serve`；`Op::Forward { .. }` → `prio.set(state.forward_priority)` 再 `serve_value`；其余 → `serve_value`。
  - 测试辅助（`common/mod.rs`）：`pub async fn service_on_relay_with(addr: &str, key: &Key, lan: Option<Vec<String>>, tune: impl FnOnce(&mut Opts)) -> TestService`（`service_on_relay_lan` 改成调它、`tune` 什么都不做）。

- [ ] **Step 1: 写失败的测试**（`forward.rs`）。测试里自己当访问方：`relay_conn` 拿一个 B 身份的 relay 连接，用 `relayed_request` 发 `{"op":"mux"}`，再读回复。

```rust
/// 手搭的通道：relayed_request 发 mux，读到 {"ok":true}，split 之后 Mux::client(async { Ok(r) }, w)。
async fn raw_channel(rig: &RelayRig, a: &TestService) -> (Endpoint, RelayConn, Mux);

#[tokio::test]
async fn a_channel_carries_forwards_to_two_ports() {
    // A 分享两个回声端口。raw_channel 上开两条子流，各发 {"op":"forward","port":p}，
    // 各读到 {"ok":true}，各回声 "hi"。
    // A 的 service.log：恰好一行 channel，恰好一行 trust，两行 forward_open（端口各一）。
    // B 的 RelayConn 关掉之后，wait_log 等到 channel_end：streams == 2。
}

#[tokio::test]
async fn mux_is_unknown_elsewhere() {
    // 通道里的一条子流发 {"op":"mux"}：回 {"error":"unknown op"}，通道照常可用（再开一条 forward 成功）。
}

#[tokio::test]
async fn a_sharer_without_channels_says_unknown_op() {
    // A 用 service_on_relay_with(.., |o| o.channels = false)。relayed_request 发 mux，
    // 回复的 error == "unknown op"。A 的日志里没有 channel。
}

#[tokio::test]
async fn a_lone_forward_is_still_served() {
    // 1a 的旧式访问：relayed_request 直接发 forward，照常回 ok 并回声（旧访问方对新分享方）。
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-testkit --test forward -- channel mux_is lone_forward sharer_without`
Expected: `a_channel_carries_forwards_to_two_ports` 失败（回复是 `unknown op`），`a_sharer_without_channels_says_unknown_op` 编译失败（没有 `channels` 字段）

- [ ] **Step 3: 实现上面的接口，改所有 `Opts` 的构造；观测规格 §3 的表里 `forward_refused` 那行后面加两行**

```markdown
| `channel` | info | `peer, name?, path, fp` | （实现注，2026-11-16）一台设备经 relay 和本机建了一条转发通道（端口分享规格 §5.2）。一条通道里的转发各自照常记 `forward_open`、`forward`（`rust/service/src/channel.rs`） |
| `channel_end` | info | `peer, name?, path, fp, streams, reason, secs` | 这条通道关了。`streams` 是它上面一共开过的连接数；`reason` 取 `closed`、`idle`、`dead`、`eof`、`protocol: …` 或底下连接的错误 |
```

- [ ] **Step 4: 跑，确认通过**

Run: `cargo test -p rapp-service && cargo test -p rapp-testkit --test forward && cargo test -p rapp-testkit --test service && cargo build --workspace`
Expected: 全部 PASS，没有警告

- [ ] **Step 5: 提交**

```bash
git add rust/service rust/testkit/tests docs/superpowers/specs/2026-11-11-rapp-observability-design.md
git commit -m "feat(service): serve a forward channel from a relayed stream"
```

---

### Task 5: 访问方：一对设备一条通道

**Files:**
- Modify: `rust/conn/src/dial.rs`（`Outbound`、`request` :143、`through_relay` :269、`relayed` :332、`close` :181）
- Test: `rust/testkit/tests/forward.rs`

**Interfaces:**
- Consumes: `Mux::client`、`Mux::open`、`Mux::is_closed`、`Mux::reason`、`Mux::close`（Task 2）；`relay_to_at`、`FORWARD_PRIORITY`（Task 3）；`read_welcome` 泛型（Task 1）；分享方的通道（Task 4）。
- Produces: `Outbound::request` 的签名和 `Sent` 不变；经通道来的 `Sent` 是 `{ pipe: Box<MuxStream>, reply, path: "relay", fp }`。新常量 `OLD_KEEP: Duration = 600 s`。

`Outbound` 新加的状态：

```rust
struct Chan {
    mux: Mux,
    relay: String,
    key_text: String,
    /// 通道的 welcome 读完时填上（就绪 future 里）。
    fp: Arc<OnceLock<Fp>>,
    /// 建通道时 `hosts.json` 里记的指纹（`to.known`）。
    known: Option<Fp>,
}
// Outbound 里：
chans: Mutex<HashMap<String, Arc<Slot>>>, // 按设备 ID；Slot { chan: tokio::sync::Mutex<Option<Chan>>, failed }，内层锁保证同时只建一次
old: Mutex<HashMap<String, Instant>>,                                   // 按设备 ID，旧版本，OLD_KEEP 内有效
```

`request` 的新流程（"计划定的"第 7 到 9 条）：

1. `on_held` 命中就返回（不变）。
2. 没配 relay，或者这台在 `old` 里：走现在的路（局域网 → `through_relay` → `relayed`），结束。
3. 拿这台的通道槽，`lock().await`（别的请求在建时就在这里等）。槽里的通道还能用（没关、`relay`/`key_text` 一样、`to.known` 和建通道时的 `known` 一样；不拿 `fp` 和 `to.known` 比，key 作证的新指纹照 1a 接受）：克隆 `Mux`、放锁、在上面发请求。不能用：`close()` 它、清空。
4. 拿着锁：再试一次 `on_held`（等锁的时候前面的请求可能走局域网连上了），再走局域网和 `through_relay`；`through_relay` 最后一步从 `relayed` 换成 `open_channel`，建好的通道放进槽里，放锁，在上面发请求。
5. 在通道上发请求：`mux.open()`，写请求，`REPLY_WAIT` 内读一个 JSON 回复。失败时看 `mux.reason()`：是 `unknown op` 或 `bad request` → 记进 `old`、清空槽、这一条改走 `relayed`；通道是第 3 步拿的旧通道 → 清空槽、从第 3 步再来一次（只一次）；否则按 `relayed` 现在的规矩报错（读不到回复是 `no reply`；TLS 或 relay 的拒绝照 `not_reached(relay_failure(e))`）。从第 3 步再来的那一次只在拿到的旧通道已经关闭时才做：一个子流被 RST 或超时就丢掉还活着的通道，会把它上面别的子流一起切断。

```rust
/// 经 relay 建通道：relay_to_at(id, FORWARD_PRIORITY)，REPLY_WAIT 内 e2e_connect，
/// send_hello，write_json(Op::Mux)，然后 split 成读写两半，Mux::client(ready, w)。
/// ready：read_welcome(&mut r, &facts, Some(key), to.id, to.known.as_ref())，把 fp 填进 OnceLock，
/// 读一个 JSON，不是 {"ok":true} 就 Err(io::Error::other(<error 的文字>))；
/// 整个 ready 限在 REPLY_WAIT 内，超时是 Err(other("no reply"))。
async fn open_channel(&self, relay: &RelayConn, addr: &str, key: &Key, to: &Target<'_>) -> Result<Chan>;
```

- `close()` 也关掉所有通道。

- [ ] **Step 1: 写失败的测试**（`forward.rs`；`over_relay()` 是现成的 A 分享、B 访问、全走 relay）

```rust
#[tokio::test]
async fn forwards_share_one_channel() {
    // 依次 pipe 三次，每次回声 "hi" 成功。A 的日志：恰好一行 channel、恰好一行 trust。
}

#[tokio::test]
async fn fifty_at_once_share_one_channel() {
    // 用默认限额的 RelayRig::start()（不是 start_with_connect_limit）。50 条 pipe 同时开，
    // 全部回声成功；A 的日志恰好一行 channel；relay 的审计里没有 result == "limit" 的 relayed。
}

#[tokio::test]
async fn half_close_survives_the_channel() {
    // 照 1a 的 half_close_survives_the_relay，但先 pipe 一次让通道建好，再在第二条上做半关闭：
    // B 写完 shutdown，回声服务读到头再回，B 读到全部。
}

#[tokio::test]
async fn unshare_cuts_only_that_port() {
    // A 分享两个回声端口 p1、p2，B 在同一条通道上各开一条，都开着。
    // A 上 unshare p1：p1 那条在 WAIT 内读到头或出错；p2 那条还能回声；之后 pipe p2 还能开新的。
}

#[tokio::test]
async fn an_old_sharer_falls_back_once() {
    // A 用 service_on_relay_with(.., |o| o.channels = false)。B pipe 两次，都回声成功。
    // A 的日志：trust 恰好 3 行（一次通道的尝试 + 两条旧式），没有 channel。
}

#[tokio::test]
async fn a_dead_channel_is_rebuilt() {
    // over_relay，pipe 一次成功。rig.restart()，等 A、B 的 status relay == "connected"。
    // 再 pipe：成功。A 的日志：channel 两行，channel_end 至少一行。
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-testkit --test forward -- share_one_channel half_close_survives_the_channel unshare_cuts_only an_old_sharer a_dead_channel`
Expected: 通道相关的断言失败（A 的日志里没有 `channel`；trust 行数是 pipe 的次数）

- [ ] **Step 3: 实现上面的 `Outbound` 改动**

- [ ] **Step 4: 跑，确认通过；整个 forward 测试连跑三遍**

Run: `cargo test -p rapp-conn && for i in 1 2 3; do cargo test -p rapp-testkit --test forward -q || break; done && cargo build --workspace`
Expected: 全部 PASS，1a 的测试（局域网、经 relay、旧密码连接被拒等）不变，没有警告

- [ ] **Step 5: 提交**

```bash
git add rust/conn/src/dial.rs rust/testkit/tests/forward.rs
git commit -m "feat(conn): one channel per device pair over the relay, old sharers fall back"
```

---

### Task 6: §5.2 验收：延迟下的开连接耗时

**Files:**
- Modify: `rust/testkit/tests/common/mod.rs`（`proxy`，从 `tests/cc_compare.rs:57` 挪过来改成 `pub`；`cc_compare.rs` 改用它）
- Modify: `rust/testkit/tests/forward.rs`（新测试；`measure_the_forward_over_the_relay` 不动）
- Create: `docs/superpowers/measurements/2026-11-16-port-sharing-mux.md`
- Modify: `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（§5.2、§15 实现注）

**Interfaces:**
- Consumes: Task 5 的通道；`rapp_testkit::measure(&Plan { ipc_port, token, to, port, n, parallel }) -> Report { open_seq, open_par, first_byte, path }`（中位数等字段照 `testkit/src/lib.rs` 现有的）；`weaknet::Profile`。
- Produces: `pub async fn proxy(upstream: SocketAddr, p: Profile) -> SocketAddr`（`common/mod.rs`）。

- [ ] **Step 1: 写测试**

```rust
/// 访问方 B 到 relay 之间单向 25 ms（往返 50 ms），A 到 relay 不加。两台经 relay 的一个往返约 50 ms。
/// 1a 每条要两个往返（约 100 ms）；有了通道，建好之后每条一个。
#[tokio::test]
async fn opening_over_the_channel_costs_one_round_trip() {
    const RTT_MS: f64 = 50.0;
    // 跑两组，每组各起一套新的 RelayRig::start()、A、B：
    //   旧式：A 用 service_on_relay_with(.., |o| o.channels = false)（B 退回每条一流，就是 1a 的路）
    //   通道：A 用默认的 Opts
    // A 等 relay connected 后分享回声端口；B = service_on_relay_with(&proxy(rig.addr, p).to_string(), ..)，
    // 也等 relay connected。先 pipe 一次（建通道 / 记下旧版本），再 measure(n = 50, parallel = 6)。
    // 两组都把 open_seq/open_par/first_byte 的中位数和 p95 打出来（--nocapture 时记进测量文档）。
    // 断言：
    //   两组 report.path 的 relay 计数都 == 100（顺序和并发两轮各 50，measure 合在一起计）
    //   旧式组 open_seq 中位数 ≥ 1.7 × RTT_MS（延迟真的加上了，而且确实是两个往返）
    //   通道组 open_seq 中位数 ≤ 1.5 × RTT_MS，open_par 中位数 ≤ 1.5 × RTT_MS
    //   通道组 A 的日志恰好一行 channel
}
```

`p` 照 `rust/testkit/profiles/lan.json`（不限速、不丢包、不抖动）：读那个文件、`serde_json::from_str` 进 `Profile`，再改 `delay_ms: (25, 25)`、`seed: 1`，不要手抄字段。

- [ ] **Step 2: 跑**

Run: `cargo test -p rapp-testkit --test forward opening_over_the_channel -- --nocapture`
Expected: PASS；旧式组 `open_seq` 中位数约 100 ms，通道组约 50 ms

- [ ] **Step 3: 连跑三遍看稳不稳**

Run: `for i in 1 2 3; do cargo test -p rapp-testkit --test forward opening_over_the_channel -q || break; done`
Expected: 三遍都 PASS

- [ ] **Step 4: 写测量文档和规格实现注**

测量文档照基线文档的结构：`## 量什么`、`## 进程内（本机回环）`（重跑 `measure_the_forward_over_the_relay`，和基线的 2.41 ms / 11.16 ms 对比）、`## 加了延迟（每单向 25 ms）`（Step 2 的两组数：旧式对通道）、`## 会话优先（§5.3）`（Task 7 填）、`## 真机测量（待做）`（照基线文档的 `measure-forward` 步骤；倍数 = `open_seq` 中位数 ÷ 两台经 relay 的一个往返，要 ≤ 1）。

规格 §5.2 末尾加实现注（2026-11-16）：通道是 `rapp-conn` 里自己写的复用层（`rust/conn/src/mux.rs`），帧格式和窗口照本计划"计划定的"第 1、2 条；第一条连接和建通道一起发（两个往返），之后每条一个往返；旧分享方回 `unknown op` 时退回每条一流，记 10 分钟；通道开着时不再试局域网，空闲 5 分钟关。§15 第 1 步加一句：复用通道和会话优先已做（本计划），真机数字见测量文档。

- [ ] **Step 5: 提交**

```bash
git add rust/testkit/tests docs/superpowers/measurements/2026-11-16-port-sharing-mux.md docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md
git commit -m "test(forward): opening over the channel costs one round trip; measurements"
```

---

### Task 7: §5.3 测量：大转发时的会话延迟

**Files:**
- Create: `rust/testkit/tests/session_priority.rs`
- Modify: `docs/superpowers/measurements/2026-11-16-port-sharing-mux.md`（`## 会话优先（§5.3）`）
- Modify: `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（§5.3、§16 第 9 条实现注）

**Interfaces:**
- Consumes: `service_on_relay_with`、`relayed_request`、`relay_conn`（Task 4）；`proxy`（Task 6）；`Opts.forward_priority`（Task 4）；`FORWARD_PRIORITY`（Task 3）。

文件头照 `cc_compare.rs`：说明怎么跑，和**跑之前就定好的判定规则**：

```rust
//! 规格 §5.3：分享方的 relay 连接上同时有一条大转发和一个会话时，会话的往返变慢多少。
//! 手动跑：cargo test -p rapp-testkit --test session_priority -- --ignored --nocapture
//!
//! VERDICT RULE (fixed before running):
//!   在 "wan" 配置下，转发优先级为 FORWARD_PRIORITY 的那一组，和同组没有转发时相比，
//!   会话往返的 p50 增加 ≤ 20 ms，且 p95 增加 ≤ 40 ms，算达标。
//!   不达标：如实写进测量文档，限速（或换拥塞控制）作为下一件交给用户定。不改阈值。
```

- 两种网络：`lan`（不经代理）和 `wan`：A 的 relay 地址换成 `proxy(rig.addr, p)`，`p` 是 `lan.json` 读进来再改 `rate_kbps: (20_000, 20_000)`、`delay_ms: (15, 15)`、`queue_ms: 100`、`seed: 7`。
- 每种网络两组：A 用 `forward_priority = FORWARD_PRIORITY`，和 A 用 `forward_priority = 0`（关掉优先级）。每组各起一套新的 relay、A、B。
- 会话：用一个 B 身份的 `relay_conn`，`relayed_request` 发 `{"op":"open","app":"com.example.echo"}`，读回复拿到 `token`，写 `token` 一行，读到 `ok\n`，之后每 20 ms 写 16 字节、读回 16 字节，记每次往返。
- 大转发：A 上起一个 TCP 服务，接上就不停地写；A 分享它；B 服务 `pipe` 过去一直读。
- 每组：先只跑会话 10 秒（基线），再加上大转发跑 10 秒；两段各取 p50、p95，并记大转发那 10 秒的下载速率。
- 打出一张表：网络、优先级、基线 p50/p95、有转发 p50/p95、增加量、转发速率、判定。

- [ ] **Step 1: 写测试（`#[ignore]`），先确认它能编译、`lan` 那组能跑出数**

Run: `cargo test -p rapp-testkit --test session_priority -- --ignored --nocapture`
Expected: 打出完整的表（判定哪一种都行，这一步只看它能跑）

- [ ] **Step 2: 跑三遍，把三张表都抄进测量文档的 `## 会话优先（§5.3）`，写结论**

结论按判定规则写"达标"或"不达标"。不达标时写清楚：优先级开和关差多少（看出优先级管不管用），增加量大约是不是 `queue_ms` 那么多（看出是不是瓶颈队列的问题，"计划定的"第 11 条）。末尾一句：限速或换拥塞控制要用户定。

真机步骤也写进去：分享方在 relay 上分享一个大文件的 http 服务（如 `python3 -m http.server`）；访问方一边开着到分享方的远程会话看 `[stats]` 的画面延迟，一边 `curl -o /dev/null http://<ID>.rapp:<端口>/<大文件>`；记有无下载时的画面延迟中位数和 95 分位，对照流畅串流规格的目标（中位数/95 分位 ≤ 60/100 ms）。

- [ ] **Step 3: 规格实现注**

§5.3 末尾（2026-11-16）：优先级只在分享方的 relay 连接上起作用（"计划定的"第 10 条的那几句）；测量结果和结论见测量文档。§16 第 9 条后面注明：进程内弱网已量，真机待做。

- [ ] **Step 4: 整体跑一遍**

Run: `cargo test --workspace && cargo build --workspace`
Expected: 全部 PASS，没有警告（`session_priority` 是 `ignored`，不在里面跑）

- [ ] **Step 5: 提交**

```bash
git add rust/testkit/tests/session_priority.rs docs/superpowers/measurements/2026-11-16-port-sharing-mux.md docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md
git commit -m "test(forward): measure session latency under a big forward (spec 5.3)"
```
