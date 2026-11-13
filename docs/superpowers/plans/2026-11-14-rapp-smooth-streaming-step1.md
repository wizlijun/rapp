# rapp 流畅串流·第一步（工具 + 规则一、二）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先做出 §4.1 的三样测量工具并留下基线，再实现规则一（发送端不排队）和规则二（弱网保底），让 B 在 200 kbps / 往返 300 ms / 丢包 5% / 每分钟断 10 秒的链路上仍能读和写。

**Architecture:** 测量：`rust/testkit` 里加一个带种子的 UDP 弱网代理（库 + `rapp-weaknet`），A 上加一个测试窗口 app（`rapp-testpage`），两个 Python 脚本用 `rapp-session` 扮 B、经 hub 的嵌入端口读解码后的画面。功能：协议升到 v7（帧确认、弱网通知、手动选档标记）；`RappCore` 里新增三个可单测的纯逻辑件（`SendPacer` 在途上限、`WeakTier` 降档状态机、`PacedSender` 把编码器、切片和二者接起来），`rapp-host` 的 `Server` 只做接线；四个客户端都回确认；界面显示"弱网"、记住手动选档、断网自动重连；最后按实测决定保活/卡死检测和拥塞控制。

**Tech Stack:** Swift 5.9 / macOS 14（XCTest，AppKit），Rust 2021（tokio，quinn 0.11.12 / quinn-proto 0.11.19，rand 0.9），Flutter/Dart（fakeAsync 测试），Python 3（标准库）。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-smooth-streaming-design.md`（第 2 稿，修订 1–2）。下文的"§"都指它。

**这份计划的范围：** §4.1 的三样工具、§3 规则一和规则二、§4 表里第一步的验收，以及 §4.2/§4.3 两个脚本在现在版本上的基线和第一步之后的复测。**不在这里的**：规则三、四（运动层、60 fps、码率），§4.2 的 S1/S2 的达标（要第二步），Sunshine 对照，实地验证（坐地铁，用户自己做）。

## Global Constraints

- 在单独的 git worktree 里、分支 `feat/smooth-step1` 上做（执行时用 superpowers:using-git-worktrees）。用户同时在改主目录：不碰主目录里未提交的 `README.md`、`gui/pubspec.lock`、`docs/archives/`、未跟踪的 spec 文件。README 只在任务 18 改，改的是 worktree 里的那份。
- 提交信息沿用仓库写法：`feat(host): …`、`feat(core): …`、`feat(gui): …`、`feat(testkit): …`、`test: …`、`docs: …`。每次提交按文件名 `git add`；不用 `git add -u/-A/.`，不用 `git stash/checkout/restore/reset`。
- 不跑 `cargo fmt`；新建的 Rust 文件只用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。Dart 改动后 `cd gui && dart format <改过的文件>`。
- 测试只用临时目录和 `127.0.0.1:0`；不用 22020–22029、47800；只停自己启动的进程，按 PID，不用 killall/pkill。
- 每个任务结束时，它碰到的那一侧全过：Swift `swift build && swift test`；Rust `cd rust && cargo test --workspace` 且 `cargo clippy --workspace -- -D warnings`；界面 `cd gui && flutter analyze && flutter test`。
- 规格定死的数（原样）：在途上限 `1 + 帧率 × 基准往返`（向上取整）；基准往返 = 近 10 秒最小的往返；比基准多 100 ms 以上算排队，上限降为 1；切片阈值 32 KB（32768 字节），按瓦片行从上到下；排队持续 3 秒进弱网档，连续 30 秒不排队退出；弱网档 = 双色·灰度（`duogray`）+ 省流 1x，不开运动层；新会话头一片只发 8 KB（8192 字节），它的确认超过 1 秒就直接从弱网档开始；手动选过档的会话不再自动改；自动重连间隔 1 秒起翻倍、15 秒封顶，直到连上或点「停止」；用户断开、A 端关了 app、被接管不自动重连；v6 客户端保持现在的行为。
- 本计划补的默认值（规格没给，§8 留给计划的）：
  - 帧确认是消息类型 27，B → A，载荷 `u16 处理毫秒`（封顶 65535）。往返 = 确认到达 − 发出时刻 − 处理毫秒。画面延迟 = 确认到达 − 采集时刻。
  - 基准往返的 10 秒窗里一个样本都没有时（断网刚恢复），用历史上最近 8 个样本的最小值；一个样本都没有过时上限为 1。
  - 在途上限另封顶 `max(2, 帧率)`（一秒的帧）。
  - "排队"= `max(最近一次往返, 最老未确认帧已等的时间) > 基准 + 100 ms`。第二项让断网期间（收不到确认）也算排队。
  - 退出弱网档只在收到确认时判断：这次确认不排队，且上一次排队已过去 ≥ 30 秒。画面静止、没有确认时不退出，免得空闲时来回切。
  - 弱网档的密度 = `min(B 要的密度, 1.0)`；帧率不变。
  - **第三条新消息**：类型 28 `weak(u8)`，A → B，只发给 v7，变了才发。规格说"只新增两条消息"（帧确认 + 第二步的运动帧）；流量标签要显示"弱网"，B 没别的办法知道。交付时向用户说明这条偏离。
  - setStream（11）末尾可选一个字节 `pinned`（1 = 用户在串流菜单里手动选的）。旧客户端不带，A 当 0。
- 帧号图案（测试片、阅读页共用，§8）：窗口内容区 (12 pt, 12 pt) 起一行 18 个 24 pt 的方格；第 0 格黑、第 1 格白（同步），第 2–17 格是 16 位数的第 15…0 位，黑 = 1。读的时候取每格中心 8×8 像素的平均亮度，< 128 为黑。
- 时间戳：测试 app 和脚本在同一台 Mac 上，统一用 `CLOCK_UPTIME_RAW` 的纳秒（Swift `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`，Python `time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)`）。

## Review Focus

规格没有明说、最可能伤到用户的五种情况，按可能性排。每条都在负责的任务里有测试：

1. **断网恢复后的第一个确认**：断网前发出的帧在恢复后才确认，往返是 10 秒。它不能变成"基准往返"，否则上限变成几百帧，规则一形同虚设。（任务 9）
2. **弱网档里画面静止**：没有帧就没有确认。空闲 30 秒不能当成"30 秒不排队"退回高彩；下一屏又贵又要再等 3 秒才降回来，地铁上会来回抖。（任务 9）
3. **切片排着队时档位变了**（弱网进出、用户换档）：没发完的片可以扔，但扔了之后下一帧必须是整帧，否则 B 上留下半屏旧瓦片。（任务 10）
4. **弱网档期间用户手动选档**：立刻退出弱网、用用户选的档、本会话不再自动改；自动重连回来的新会话也记得"选过"。（任务 11、14）
5. **自动重连在等的时候用户点了「断开」「结束会话」，或会话被接管**：定时器要撤掉，不能过一会儿又自己连上；连不上（对方离线、超时）时继续按退避试，不弹提示刷屏。（任务 15）

---

## 文件结构

| 文件 | 做什么 | 任务 |
|---|---|---|
| `rust/testkit/src/lib.rs`、`src/weaknet/{mod,profile,link,proxy}.rs`、`src/bin/rapp-weaknet.rs` | 弱网模型（纯）、UDP 代理、命令行 | 1、2 |
| `rust/testkit/profiles/{lan,s0,n1,n2,n3,n4}.json` | 六份链路配置 | 1 |
| `Sources/RappCore/FrameMark.swift` | 帧号图案（画和读的唯一定义） | 3 |
| `Sources/rapp-testpage/main.swift`、`scripts/testpage-app.sh` | 测试片、阅读页、编辑页 | 3 |
| `scripts/lib/rig.py`、`scripts/lib/frame_mark.py`、`scripts/lib/bside.py` | 起 relay/service/hub、驱动 `rapp-session`、读帧号 | 4 |
| `scripts/measure-weak.py`、`scripts/measure-video.py` | 两个测试，各出一张表 | 4、5 |
| `docs/superpowers/measurements/2026-11-14-*.md` | 基线和复测的原始表 | 5、16、17、18 |
| `Sources/RappCore/Protocol.swift` | v7 | 6 |
| `rust/client-core/src/protocol.rs` | v7（Rust 侧） | 7 |
| `Sources/RappCore/TileCodec.swift` | `encodeSlices` | 8 |
| `Sources/RappCore/SendPacer.swift`、`WeakTier.swift`、`PacedSender.swift` | 规则一、二的纯逻辑 | 9、10 |
| `Sources/rapp-host/Server.swift`、`Sources/RappCore/WorkerCLI.swift` | 接线、弱网覆盖、统计 | 11 |
| `Sources/RappSession/{EmbeddedSession,Channel}.swift`、`gui/macos/Runner/SessionPlugin.swift`、`Sources/rapp-client/main.swift` | macOS B | 12 |
| `rust/client-core/src/bin/rapp-session.rs`、`rust/client-gtk/src/ui.rs` | Linux B | 13 |
| `gui/lib/embed/*`、`gui/lib/ui/main_state.dart`、`lifecycle.dart`、`disconnected_stage.dart` | 弱网标签、手动选档、自动重连 | 14、15 |
| `rust/net/src/quic.rs`、`rust/wire/src/tls.rs`、`rust/hub/src/*` | 保活/卡死检测、拥塞控制 | 16、17 |

---

## 第一部分：工具和基线

### Task 1: 弱网模型（纯逻辑）和六份配置

**Files:**
- Create: `rust/testkit/src/lib.rs`、`rust/testkit/src/weaknet/mod.rs`、`profile.rs`、`link.rs`
- Create: `rust/testkit/profiles/lan.json`、`s0.json`、`n1.json`、`n2.json`、`n3.json`、`n4.json`
- Modify: `rust/testkit/Cargo.toml`（加 `[lib]`；依赖 `rand`（workspace）、`serde`、`serde_json`、`anyhow`）

**Interfaces:**
- Produces:
  - `pub struct Profile { seed: u64, rate_kbps: (u32, u32), rate_every_s: f64, delay_ms: (u32, u32), jitter_ms: u32, loss: f64, bursts_per_min: f64, burst_ms: u32, outages: Vec<Outage>, rebind_every_s: Option<f64>, queue_ms: u32 }`，`pub struct Outage { every_s: f64, for_s: f64, offset_s: f64 }`；`Profile::load(path: &Path) -> anyhow::Result<Profile>`，`Profile::named(name: &str) -> anyhow::Result<Profile>`（读 `profiles/<name>.json`，路径用 `env!("CARGO_MANIFEST_DIR")`）。所有字段 serde 默认值即"不加这项"。
  - `pub struct Link`（单方向）：`Link::new(p: &Profile, dir_seed: u64) -> Link`；`fn admit(&mut self, now: Duration, len: usize) -> Option<Duration>`（相对开始的时刻；返回送达时刻，`None` = 丢）；`fn down(&self, now: Duration) -> bool`（是否在断开时段）；`fn rebind_epoch(&self, now: Duration) -> u64`（第几次换端口，0 起）。

配置里的数（照 §4.3 的表；s0 是第一步验收的链路）：

| 名 | rate_kbps | rate_every_s | delay_ms（单程） | jitter_ms | loss | bursts | outages | rebind |
|---|---|---|---|---|---|---|---|---|
| lan | (1000000,1000000) | — | (1,1) | 0 | 0 | — | — | — |
| s0 | (200,200) | — | (150,150) | 0 | 0.05 | — | 每 60 s 断 10 s，offset 30 | — |
| n1 | (50,2000) | 5 | (100,400) | 50 | 0.10 | 每分钟 6 次 × 200 ms | 每 60 s 断 15 s，offset 20；每 300 s 断 45 s，offset 150 | — |
| n2 | (50,50) | — | (300,300) | 0 | 0.02 | — | — | — |
| n3 | (2000,2000) | — | (75,75) | 0 | 0.30 | — | — | — |
| n4 | (1000,1000) | — | (50,50) | 0 | 0.01 | — | — | 120 |

全部 `queue_ms: 1000`（瓶颈队列超过 1 秒的包尾丢，像手机基站的缓冲）。n1 的速率在区间里按对数均匀随机，每 5 秒换一次；往返在区间里按同样办法每 5 秒换一次。

- [ ] **Step 1: 写失败的测试**（`link.rs` 里 `#[cfg(test)]`）

```rust
#[test] fn same_seed_same_fate() { /* 两个同 seed 的 Link 对同一串 (now,len) 给出完全相同的结果 */ }
#[test] fn rate_limit_spaces_packets() {
    // s0 无丢包版（loss=0, 无断开）：连续 25 个 1000 字节包在 t=0 进入
    // 第 k 个的送达时刻 ≈ 150ms + k*40ms（200 kbps = 25 B/ms），误差 ≤ 1ms
}
#[test] fn queue_tail_drop() { /* 一次塞 60 KB：送达时刻超过 now+queue_ms+delay 的包返回 None */ }
#[test] fn loss_rate_close_to_profile() { /* n3：10000 个小包、包间隔 10ms，丢的比例在 0.27..0.33 */ }
#[test] fn bursts_drop_everything_inside() { /* n1 去掉随机丢包：每个成串丢包时段内的包全丢，时段外不丢（关断开） */ }
#[test] fn outage_schedule() { /* s0：down(30.0s)=true，down(39.9s)=true，down(40.0s)=false，down(90.5s)=true；断开时 admit 返回 None */ }
#[test] fn jitter_never_reorders() { /* n1：任意相邻两个 admit 的送达时刻不递减 */ }
#[test] fn rebind_epoch_counts() { /* n4：rebind_epoch(119s)=0，(120s)=1，(250s)=2 */ }
#[test] fn all_profiles_load() { /* 六个名字都能 Profile::named */ }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-testkit --lib weaknet`
Expected: 编译失败（`Link`、`Profile` 未定义）。

- [ ] **Step 3: 实现 `Profile`、`Link`**

`Link` 是一个令牌桶式的串行瓶颈：维护 `busy_until`（瓶颈出口空闲的时刻），包的出队时刻 = `max(now, busy_until) + len*8/rate`；出队时刻 − now > queue_ms 尾丢；送达 = 出队 + 单程延迟 + 抖动，再取 `max(上一个送达时刻, 它)` 保证不乱序。随机数 `rand::rngs::StdRng::seed_from_u64(seed ^ dir_seed)`；速率和延迟的变化表、成串丢包的时段都从 seed 推出来，和调用顺序无关（按 `now / period` 的序号派生子 seed），这样两个方向、重跑都一致。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-testkit --lib weaknet`
Expected: 9 passed.

- [ ] **Step 5: 提交**

```bash
git add rust/testkit/Cargo.toml rust/Cargo.lock rust/testkit/src/lib.rs rust/testkit/src/weaknet rust/testkit/profiles
git commit -m "feat(testkit): seeded weak-link model and six profiles"
```

### Task 2: UDP 代理和 `rapp-weaknet`

**Files:**
- Create: `rust/testkit/src/weaknet/proxy.rs`、`rust/testkit/src/bin/rapp-weaknet.rs`
- Create: `rust/testkit/tests/weaknet.rs`
- Modify: `rust/testkit/Cargo.toml`（`[[bin]] rapp-weaknet`；`[dependencies]` 加 tokio（workspace，`net`、`time`、`macros`、`rt-multi-thread`）。代理本身不用 quinn）

**Interfaces:**
- Consumes: Task 1 的 `Profile`、`Link`。
- Produces:
  - `pub async fn run(listen: SocketAddr, upstream: SocketAddr, p: Profile, stats: Arc<ProxyStats>) -> anyhow::Result<()>`。客户端的每个来源地址一条"会话"；上行、下行各一个 `Link`（`dir_seed` 0 / 1），时间零点 = 代理启动。
  - `pub struct ProxyStats { up_pkts, up_dropped, down_pkts, down_dropped: AtomicU64 }`。
  - `rapp-weaknet --listen 127.0.0.1:0 --to HOST:PORT --profile NAME|PATH [--seed N]`：启动后在 stdout 打一行 `{"event":"listening","port":P}`，之后每秒一行 `{"event":"stats",...,"down":bool}`。
- 换端口：`rebind_epoch` 变了时，会话换一个新绑定的上游 socket（对端看到新的来源端口，模拟 NAT 换映射）；旧 socket 收到的回包丢掉。

- [ ] **Step 1: 写失败的集成测试**（`tests/weaknet.rs`）

```rust
#[tokio::test] async fn forwards_both_ways_on_lan() { /* UDP echo 服务 + 代理(lan)：100 个包全回来，顺序不变 */ }
#[tokio::test] async fn outage_blocks_then_resumes() {
    // 自定义 profile：每 2s 断 1s，offset 0.5：t∈[0.5,1.5) 发的包都不回；之后的回来
}
#[tokio::test] async fn rebind_changes_source_port() { /* rebind_every_s=0.5：echo 服务看到的来源端口在 1.2 秒内至少变 2 次 */ }
#[tokio::test] async fn quic_survives_rebind() {
    // rapp_net::quic 的客户端/服务端经代理(n4 但 rebind_every_s=1)建连，3 秒里每 100ms 开一个 bi 流往返 1 KB，全部成功
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-testkit --test weaknet`
Expected: 编译失败（`proxy::run` 未定义）。

- [ ] **Step 3: 实现 `proxy::run` 和命令行**

按送达时刻用 `tokio::time::sleep_until` 发出（每个方向一个按时间排序的队列 + 一个发送任务）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-testkit --test weaknet`
Expected: 4 passed。再手动：`cargo run -p rapp-testkit --bin rapp-weaknet -- --listen 127.0.0.1:0 --to 127.0.0.1:9 --profile s0` 打出 `listening` 和每秒的 `stats`。

- [ ] **Step 5: 提交**

```bash
git add rust/testkit/Cargo.toml rust/Cargo.lock rust/testkit/src/weaknet/proxy.rs rust/testkit/src/weaknet/mod.rs rust/testkit/src/bin/rapp-weaknet.rs rust/testkit/tests/weaknet.rs
git commit -m "feat(testkit): rapp-weaknet UDP proxy with outages and rebinding"
```

### Task 3: 测试 app（测试片、阅读页、编辑页）

**Files:**
- Create: `Sources/RappCore/FrameMark.swift`、`Tests/RappCoreTests/FrameMarkTests.swift`
- Create: `Sources/rapp-testpage/main.swift`、`scripts/testpage-app.sh`
- Modify: `Package.swift`（`.executableTarget(name: "rapp-testpage", dependencies: ["RappCore"])`，加 `.executable` 产品）

**Interfaces:**
- Produces:
  - `public enum FrameMark { static let cellCount = 18; static let cellPoints: CGFloat = 24; static let origin = CGPoint(x: 12, y: 12); static func cells(_ n: UInt16) -> [Bool] /* true = 黑 */; static func read(luma: (Int) -> UInt8) -> UInt16? /* 传入"第 i 格中心平均亮度" */ }`。
  - `scripts/testpage-app.sh` 生成 `.build/RappTestPage.app`，bundle id `dev.rapp.testpage`，名字 `RappTestPage`；`open -n .build/RappTestPage.app --args <模式>` 启动。
  - 模式：
    - `--clip [--marks PATH]`：1280×720 pt 窗口，60 Hz（`CADisplayLink` 或 `NSView.displayLink`）重画：帧号 = 计数 mod 65536；一条 4 pt 宽的竖线每帧右移 4 pt，到边回头；`--marks` 时每画一帧追加 10 字节 `u16 帧号 LE + u64 uptime_raw 纳秒 LE`。
    - `--reading`：同尺寸窗口，长文字（生成 400 行"第 N 行 ……"中文，14 pt），帧号区显示当前页号；PageDown（keyCode 121）翻一页，页号 +1。
    - `--editor PATH`：一个 `NSTextView`，每次文字变化原子写到 PATH（先写临时文件再改名）。
  - 窗口用 `.titled`，内容区坐标即上面的 origin（左上原点，`isFlipped = true`）。

- [ ] **Step 1: 写失败的测试**（`FrameMarkTests`）

```swift
func testSyncCellsAndBitOrder() {
    let c = FrameMark.cells(0b1000_0000_0000_0001)
    XCTAssertEqual(c.count, 18); XCTAssertTrue(c[0]); XCTAssertFalse(c[1])
    XCTAssertTrue(c[2]); XCTAssertTrue(c[17]); XCTAssertFalse(c[3])
}
func testRoundTripAllEdges() { for n: UInt16 in [0, 1, 255, 256, 65535, 12345] {
    let c = FrameMark.cells(n); XCTAssertEqual(FrameMark.read { c[$0] ? 20 : 235 }, n) } }
func testReadRejectsWithoutSync() { XCTAssertNil(FrameMark.read { _ in 20 }) }   // 全黑：同步格不对
func testThresholdIs128() { /* 亮度 127 当黑，128 当白 */ }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter FrameMarkTests`
Expected: 编译失败（`FrameMark` 未定义）。

- [ ] **Step 3: 实现 `FrameMark` 和 `rapp-testpage`，写 `scripts/testpage-app.sh`**

脚本：`swift build -c release --product rapp-testpage`，拼 `Contents/MacOS/RappTestPage` + 最小 `Info.plist`（`CFBundleIdentifier dev.rapp.testpage`、`NSHighResolutionCapable`），ad-hoc 签名 `codesign -s -`。

- [ ] **Step 4: 跑测试并手动看一眼**

Run: `swift test --filter FrameMarkTests` → 4 passed。`scripts/testpage-app.sh && open -n .build/RappTestPage.app --args --clip --marks /tmp/x.marks`：看到 18 格在跳、竖线在走；5 秒后 `/tmp/x.marks` 的大小 ≈ 5×60×10 字节（± 10%）。用完按 PID 停掉。

- [ ] **Step 5: 提交**

```bash
git add Package.swift Sources/RappCore/FrameMark.swift Tests/RappCoreTests/FrameMarkTests.swift Sources/rapp-testpage/main.swift scripts/testpage-app.sh
git commit -m "feat(testpage): clip, reading and editor test windows with a frame mark"
```

### Task 4: 测量的台子和弱网测试脚本

**Files:**
- Create: `scripts/lib/rig.py`、`scripts/lib/frame_mark.py`、`scripts/lib/bside.py`、`scripts/measure-weak.py`
- Modify: `scripts/e2e-local.py`（改成从 `scripts/lib/rig.py` 导入 `Hub`、`ipc`、`wait_for`、`free_udp_port`，行为不变）

**Interfaces:**
- Consumes: Task 2 的 `rapp-weaknet`（stdout 的 `listening`）；Task 3 的 `RappTestPage.app` 和帧号图案。
- Produces:
  - `rig.py`：`Rig(path: "direct"|"relay", profile: str, seed: int)`：起 relay（`relay` 路径才起）、A 的 service（`service.json` 同 e2e-local）、B 的 hub；`direct` 时代理接在 hub 和 A 的 service 端口之间，hub `add_host id@127.0.0.1:<代理端口>`（不配 relay）；`relay` 时代理接在 hub 和 relay 之间（B 的 `service.json` 里 relay 写代理地址）。`Rig.open(app) -> (sid, port, token)` 发 hub `open` 带 `embed:true`（重连时 `reconnect:true`）。`Rig.close()` 按 PID 停自己起的进程。
  - `frame_mark.py`：`read_mark(rgba: bytes, width: int, x0: int, y0: int, cell_px: int) -> int | None`，和 `FrameMark.read` 同一规则；文件末尾 `if __name__ == "__main__"` 跑自测（合成 RGBA 缓冲，0/1/65535/12345 往返，无同步返回 None）。
  - `bside.py`：`BSide(port, token, mode, fps, density)` 起 `rapp-session`，喂它第一行 JSON（和 `test-linux-session-latency.py` 一样），后台线程读 stdout 的包：事件 JSON 进队列；帧（24 字节头：`u32 w, u32 h, 4×f32 region` + `w*h*4` RGBA）只解出帧号（用最近一次 `windows` 事件里测试窗口的 `x,y` 和 `w / region.w` 算像素位置）。`frames: list[(uptime_ns, mark)]`、`send(cmd: dict)`、`wait_event(name, timeout)`。
  - `measure-weak.py --profile s0|n1|n2|n3|n4|lan --path direct|relay --minutes M --seed N --out FILE.md`：按 §4.3 出一张表（行：打开到第一屏可读、翻页中位数、200 字逐字相同（丢几个 / 重复几个）、网络回来到恢复、画面延迟随时间（每 5 分钟一格的中位数）、崩溃/要人点）。`--profile s0` 时另出第一步验收的四行（新一屏 ≤ 2 s、延迟不增长、恢复 ≤ 5 s、文字不丢）。
- 判定规则（脚本里写死，表头写明）：
  - **可读** = 帧号等于期望页号，且之后 1 秒没有新帧；时刻取最后一帧的到达。
  - **翻页** = 发 PageDown 到"可读"；断开时段（代理 stats 的 `down`）里开始的翻页不计。
  - **恢复** = 网络回来（代理 stats 的 `down` 变 false）后每 0.5 秒发一次 PageDown，直到某次翻页在 3 秒内可读；恢复时间 = 那一次发出的时刻 − 网络回来的时刻。
  - **自动重连**：`rapp-session` 报 `disconnected`，且原因不是用户断开/接管/关 app，就按 1、2、4、8、15、15… 秒重开（和任务 15 的界面策略相同）。
  - **写字**：编辑页模式下，200 字分 10 段、每段 20 字用 `paste` 发，等 `paste_result`；断线时没确认的段重连后重发。结束时读 PATH，和原文比，分别数缺的字和多的字。
  - **画面延迟**（基线没有 v7 统计时）：测试片 `--marks` 文件里帧号的画出时刻，到 B 收到这个帧号的时刻。

- [ ] **Step 1: 帧号读取的自测先失败**

Run: `python3 scripts/lib/frame_mark.py`
Expected: 失败（文件不存在）。

- [ ] **Step 2: 写 `frame_mark.py`，自测通过**

Run: `python3 scripts/lib/frame_mark.py` → `frame_mark self-test ok`。

- [ ] **Step 3: 写 `rig.py`、`bside.py`、`measure-weak.py`；改 `e2e-local.py` 的导入**

- [ ] **Step 4: 冒烟**

Run: `python3 scripts/e2e-local.py`（行为和改前一样，三条路径都 OK）；`python3 scripts/measure-weak.py --profile lan --path direct --minutes 1 --out /tmp/w.md`
Expected: 表里每格都有数字，没有异常退出；进程都被停掉（`ps` 里没有残留的 rapp-weaknet、rapp-session、RappTestPage）。

- [ ] **Step 5: 提交**

```bash
git add scripts/lib/rig.py scripts/lib/frame_mark.py scripts/lib/bside.py scripts/measure-weak.py scripts/e2e-local.py
git commit -m "test: weak-network measurement rig and script"
```

### Task 5: 视频测试脚本和两份基线

**Files:**
- Create: `scripts/measure-video.py`
- Create: `docs/superpowers/measurements/2026-11-14-baseline.md`

**Interfaces:**
- Consumes: Task 4 的 `Rig`、`BSide`、`read_mark`；Task 3 的 `--clip --marks`。
- Produces: `measure-video.py --profile lan --mode color16 --density original --fps 30 --minutes 5 --out FILE.md`。表的行照 §4.2：每秒到达的不同帧（中位数 / 最低）、相邻两帧间隔 p99、最长卡顿、画面延迟中位数 / p95、码率（rapp-session 的 `traffic` 事件）、A 端编码耗时（基线写"无"；任务 11 之后从 A 的 `[stats]` 行读）。`--fps` 现在只接受 30 及以下（60 是第二步）。

- [ ] **Step 1: 写 `measure-video.py`**

- [ ] **Step 2: 冒烟**

Run: `python3 scripts/measure-video.py --profile lan --mode color16 --density original --fps 30 --minutes 1 --out /tmp/v.md`
Expected: 每秒不同帧数接近 30（测试片 60 Hz、采集 30 fps）。

- [ ] **Step 3: 在现在的版本上跑基线**（先 `swift build -c release`、`cd rust && cargo build --release`）

Run（每条一个表，全部写进 `docs/superpowers/measurements/2026-11-14-baseline.md`，表前写提交号、机器、日期）：
- `measure-video.py --profile lan --mode color16 --density original --fps 30 --minutes 5`
- `measure-weak.py --profile lan --path direct --minutes 5`
- `measure-weak.py --profile s0 --path direct --minutes 10`
- `measure-weak.py --profile s0 --path relay --minutes 10`
- `measure-weak.py --profile n1|n2|n3|n4 --path direct --minutes 10`（每份一条）
Expected: 脚本都正常结束；s0 的第一步验收行预计不过（§4 说现在的版本应该不通过）。不过的格照实记，不改脚本去凑。

- [ ] **Step 4: 提交**

```bash
git add scripts/measure-video.py docs/superpowers/measurements/2026-11-14-baseline.md
git commit -m "test: video measurement script and baselines on the current version"
```

---

## 第二部分：规则一、二

### Task 6: 协议 v7（Swift）

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`
- Modify: `Sources/RappSession/Channel.swift:126`、`Sources/RappSession/EmbeddedSession.swift:284`、`Sources/rapp-host/Server.swift:406`（只改 `setStream` 的模式匹配，加 `pinned`；行为不变）
- Test: `Tests/RappCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces:
  - `protocolVersion: UInt8 = 7`；`oldestClientVersion` 不变（5）。
  - `public func clientSendsFrameAcks(_ v: UInt8) -> Bool { v >= 7 }`。
  - `case setStream(mode: Mode, fps: UInt8, density: Float, pinned: Bool)`（11）：编码总是带末尾的 `pinned` 字节；解码时末尾有一个字节就读，没有就是 `false`。
  - `case frameAck(processingMs: UInt16)`（27，client → host）。
  - `case weak(Bool)`（28，host → client）。
  - 两个新类型进 `knownTypes`。

- [ ] **Step 1: 写失败的测试**

```swift
func testFrameAckAndWeakRoundTrip() { roundTrip(.frameAck(processingMs: 0)); roundTrip(.frameAck(processingMs: 65535)); roundTrip(.weak(true)); roundTrip(.weak(false)) }
func testSetStreamPinnedRoundTrip() { roundTrip(.setStream(mode: .duogray, fps: 1, density: 2, pinned: true)) }
func testV6SetStreamWithoutPinnedDecodesUnpinned() {
    // 手拼 v6 的 11 号消息（mode、fps、density，没有末尾字节）→ .setStream(..., pinned: false)
}
func testSetStreamWithTwoTrailingBytesIsRejected() { /* 末尾多两个字节 → 抛 "unexpected bytes after message" */ }
func testHostAcceptsHelloV5ToV7() { /* hello v5、v6、v7 都能解；v8 抛 ProtocolVersionMismatch */ }
func testAckCapability() { XCTAssertFalse(clientSendsFrameAcks(6)); XCTAssertTrue(clientSendsFrameAcks(7)) }
```

（现有的 `setStream` 用例加上 `pinned: false`。`roundTrip` 用文件里已有的辅助函数。）

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter ProtocolTests`
Expected: 编译失败。

- [ ] **Step 3: 实现**；三个调用处加 `pinned`：`Channel` 解析 `set_stream` 的可选 `"pinned"`（缺省 false）；`EmbeddedSession` 先原样传 `false`（任务 12 接上）；`Server` 先忽略（任务 11 接上）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift build && swift test`
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappCore/Protocol.swift Tests/RappCoreTests/ProtocolTests.swift Sources/RappSession/Channel.swift Sources/RappSession/EmbeddedSession.swift Sources/rapp-host/Server.swift
git commit -m "feat(core): protocol v7 — frame ack, weak notice, pinned stream choice"
```

### Task 7: 协议 v7（Rust 客户端核心）

**Files:**
- Modify: `rust/client-core/src/protocol.rs`

**Interfaces:**
- Produces:
  - `pub const VERSION: u8 = 7`；`Address::parse` 接受协议 4–7。
  - `pub fn frame_ack(processing_ms: u16) -> Vec<u8>`（类型 27）。
  - `pub fn stream(mode: u8, fps: u8, density: f32, pinned: Option<bool>) -> Vec<u8>`：`Some` 时末尾加一字节，`None` 时和现在一样（给 v6 用）。调用方按协商出的版本 ≥ 7 传 `Some`。
  - `Incoming::Weak(bool)`（类型 28）。

- [ ] **Step 1: 写失败的测试**（文件里已有的 `#[cfg(test)]` 模块）

```rust
#[test] fn frame_ack_bytes() { assert_eq!(frame_ack(300), packet(27, 300u16.to_le_bytes().to_vec())); }
#[test] fn stream_pinned_only_when_asked() { /* stream(3,1,1.,None) 与现在逐字节相同；Some(true) 多一个 1 */ }
#[test] fn decodes_weak() { /* 类型 28、载荷 [1] → Incoming::Weak(true) */ }
#[test] fn parses_protocol_7() { /* Address::parse 的协议字段 7 通过，8 报错 */ }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-client-core protocol`
Expected: 编译失败。

- [ ] **Step 3: 实现**；`stream()` 的现有调用处先传 `None`（任务 13 接上）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test --workspace && cargo clippy --workspace -- -D warnings`
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add rust/client-core/src/protocol.rs rust/client-core/src/bin/rapp-session.rs rust/client-gtk/src/ui.rs
git commit -m "feat(client-core): protocol v7 messages"
```

### Task 8: 瓦片帧切片

**Files:**
- Modify: `Sources/RappCore/TileCodec.swift`（`FrameEncoder`，`encode` 在 95 行附近）
- Test: `Tests/RappCoreTests/TileCodecTests.swift`

**Interfaces:**
- Produces: `public func encodeSlices(samples: [UInt8], width: Int, height: Int, limit: Int, firstLimit: Int? = nil) -> [FramePayload]`（`FrameEncoder` 的方法）。`encode(...)` 不变，内部可改为调它。
- 规则：
  - 变了的瓦片按瓦片行从上到下分组；每组的估计大小 = 原始字节 × `ratio`（上一帧的压缩后 / 压缩前，初始 1.0，夹在 [0.05, 1]），组累计超过 `limit` 就收口（第一组用 `firstLimit ?? limit`）。阈值是软的：一组至少一行。
  - 每组依次用同一个 deflate 流压缩（整帧时只在第一组前 `reset`），各成一个 `FramePayload`；只有整帧的第一片 `isFull`。
  - 帧比阈值小时返回一个，和 `encode` 的结果逐字节相同。

- [ ] **Step 1: 写失败的测试**

```swift
func testSmallFrameIsOneSliceSameAsEncode() { /* 同一序列喂两个编码器：encode 与 encodeSlices(limit: 32768) 的 data 逐字节相同 */ }
func testLargeFrameSlicesTopToBottomAndDecodesIdentically() {
    // 1920×1080 随机噪声整帧，limit 32768：片数 ≥ 2；按顺序喂 FrameDecoder 后像素等于整帧解码；
    // 每片的瓦片行号都大于上一片；只有第一片 isFull
}
func testFirstLimitCapsFirstSlice() { /* firstLimit 8192：第一片压缩后 ≤ 8192 + 一行的上限（一行是软下限） */ }
func testDeltaSlicesCarryOnlyChangedTiles() { /* 两帧只改第 3 行和第 40 行的瓦片：limit 很小时两片，各含一行 */ }
func testForceFullAfterDroppedSlicesRestoresPicture() {
    // 第 1 帧切成 3 片只喂解码器第 1 片；encoder.forceFull = true；第 2 帧的片全喂：解码结果等于第 2 帧原图
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter TileCodecTests`
Expected: 编译失败（`encodeSlices` 未定义）。

- [ ] **Step 3: 实现 `encodeSlices`**

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter TileCodecTests`
Expected: 全过（含原有用例）。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappCore/TileCodec.swift Tests/RappCoreTests/TileCodecTests.swift
git commit -m "feat(core): slice large tile frames by tile rows"
```

### Task 9: 在途上限和弱网档的状态机

**Files:**
- Create: `Sources/RappCore/SendPacer.swift`、`Sources/RappCore/WeakTier.swift`
- Test: `Tests/RappCoreTests/SendPacerTests.swift`、`Tests/RappCoreTests/WeakTierTests.swift`

**Interfaces:**
- Produces（时间都用 `TimeInterval`，秒，由调用方传入，没有内部时钟）:
  - `public struct SendPacer`：`init(fps: Int)`；`var fps: Int`；`mutating func sent(at: TimeInterval, captured: TimeInterval)`；`mutating func acked(at: TimeInterval, processingMs: UInt16) -> (rtt: TimeInterval, latency: TimeInterval)?`（没有在途帧时 nil，忽略多余的确认）；`var inFlight: Int { get }`；`func cap(now: TimeInterval) -> Int`；`func queueing(now: TimeInterval) -> Bool`；`func baseRtt(now: TimeInterval) -> TimeInterval?`；`var lastRtt: TimeInterval? { get }`；`mutating func reset()`（会话换编码器时不用；只给断开用）。
  - `public struct WeakTier`：`init()`；`private(set) var weak: Bool`；`var pinned: Bool`（设为 true 时 `weak` 立刻变 false）；`mutating func observe(now: TimeInterval, queueing: Bool, onAck: Bool) -> Bool?`（状态变了返回新值，否则 nil）；`mutating func probe(firstAckDelay: TimeInterval) -> Bool?`（> 1 秒且没 pinned → 进弱网）。
- 数值见 Global Constraints（10 秒窗、8 个历史样本、100 ms、`max(2, fps)` 封顶、3 秒、30 秒、1 秒）。

- [ ] **Step 1: 写失败的测试**

`SendPacerTests`：

```swift
func testCapIsOneBeforeAnySample() { XCTAssertEqual(SendPacer(fps: 30).cap(now: 0), 1) }
func testLanCapIsTwo() { /* fps 30，往返 2ms 的样本若干：cap == 2 */ }
func testCapAt80msAnd30fpsIsFour() { /* 1 + ceil(30 × 0.08) = 4 */ }
func testCapClampedToOneSecondOfFrames() { /* fps 5，基准 3 秒：cap == 5 */ }
func testProcessingTimeIsSubtracted() { /* 发出 0，确认 0.25，处理 50ms → rtt 0.2 */ }
func testLatencyIsAckMinusCapture() { /* 采集 0、发出 0.1、确认 0.4 → latency 0.4 */ }
func testQueueingWhenRttRisesOver100ms() { /* 基准 0.3，最近一次 0.45 → queueing，cap 1；回落到 0.35 → 不排队，cap 恢复 */ }
func testQueueingWhileOldestUnackedWaitsTooLong() { /* 基准 0.3，有一帧 0.0 发出未确认，now 0.5 → queueing */ }
func testBaseWindowIs10Seconds() { /* t=0 样本 0.1，t=5 起都是 0.3：t=9 基准 0.1，t=11 基准 0.3 */ }
func testPostOutageAckDoesNotBecomeBase() {
    // Review Focus 1：t=0..20 每 0.1 秒一个 0.3 的往返；t=20 发一帧，t=31 才确认（往返 11 秒），窗口里只有它
    // baseRtt(now: 31) == 0.3（最近 8 个样本的最小），cap(now: 31) == 1 + ceil(30×0.3) = 10
}
func testExtraAckIgnored() { /* 没有在途帧时 acked 返回 nil，inFlight 仍为 0 */ }
```

`WeakTierTests`：

```swift
func testEntersAfterThreeSecondsOfQueueing() { /* 0、1、2 秒 queueing → nil；3.0 秒 → true */ }
func testShortQueueingDoesNotEnter() { /* 排队 2.9 秒后一次不排队，再排队 2.9 秒 → 一直 nil */ }
func testLeavesOnAckAfter30sWithoutQueueing() { /* 进入后最后一次排队在 t=10；t=39.9 的不排队确认 → nil；t=40 → false */ }
func testIdleDoesNotLeave() {
    // Review Focus 2：进入后 t=10 最后一次排队，之后 60 秒只有 onAck:false 的 observe → 一直 weak
}
func testPinnedNeverEntersAndLeavesAtOnce() { /* weak 时 pinned = true → weak false；之后排队 10 秒仍 false；probe(2.0) → nil */ }
func testProbe() { XCTAssertEqual(WeakTier().probe(firstAckDelay: 1.01) , true); var t = WeakTier(); XCTAssertNil(t.probe(firstAckDelay: 0.9)) }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter 'SendPacerTests|WeakTierTests'`
Expected: 编译失败。

- [ ] **Step 3: 实现两个结构体**

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter 'SendPacerTests|WeakTierTests'`
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappCore/SendPacer.swift Sources/RappCore/WeakTier.swift Tests/RappCoreTests/SendPacerTests.swift Tests/RappCoreTests/WeakTierTests.swift
git commit -m "feat(core): in-flight cap and weak-tier state machine"
```

### Task 10: `PacedSender`

**Files:**
- Create: `Sources/RappCore/PacedSender.swift`
- Test: `Tests/RappCoreTests/PacedSenderTests.swift`

**Interfaces:**
- Consumes: Task 8 `encodeSlices`；Task 9 `SendPacer`、`WeakTier`。
- Produces:

```swift
public final class PacedSender {
    public struct Stats { public var rttMs: Int?; public var baseRttMs: Int?; public var latencyMs: Int?; public var inFlight: Int; public var cap: Int; public var weak: Bool }
    /// acks: false = v6 客户端，走现在的办法（transmit 的完成回调放下一帧，不切片）
    public init(mode: Mode, fps: Int, acks: Bool, now: @escaping () -> TimeInterval,
                transmit: @escaping (_ region: CanvasRect, _ payload: FramePayload, _ done: @escaping () -> Void) -> Void)
    public var onWeakChange: ((Bool) -> Void)?
    public func offer(samples: [UInt8], width: Int, height: Int, region: CanvasRect, captured: TimeInterval)
    public func ack(processingMs: UInt16)
    public func setMode(_ mode: Mode)          // 新编码器；扔掉排队的片；下一帧整帧
    public func setFps(_ fps: Int)
    public func setPinned(_ pinned: Bool)
    public func tick()                          // 每秒一次：弱网判断（断网时靠它）
    public func takeStats() -> Stats            // 取完清零"这一秒"的延迟
    public var weak: Bool { get }
}
```

- 行为：
  - `offer` 只记住最新的一份（新的替换旧的）；有名额（`inFlight < cap` 且片队列空）就立刻编码、切片（`limit` 32768；本会话第一帧 `firstLimit` 8192），片进队列，按名额逐片 `transmit`；每次 `transmit` 记 `pacer.sent`。
  - `ack` → `pacer.acked`；第一次确认交给 `tier.probe`；每次确认 `tier.observe(onAck: true)`；之后继续发队列里的片，片发完了再编码最新的一份。
  - `weak` 变了调 `onWeakChange`（由 `Server` 去换档并通知 B）。
  - `acks == false`：`transmit` 的 `done` 回调放行下一帧，`ack` 被忽略，从不切片、从不进弱网——即现在 `Server.encodeAndSend` 的行为原样搬进来。

- [ ] **Step 1: 写失败的测试**（假时钟 `var t = 0.0`，`transmit` 记下每次调用，`done` 由测试决定何时调）

```swift
func testOnlyCapFramesInFlightAndNewestWins() {
    // acks true，fps 30，无样本 → cap 1：offer A → 发；offer B、C → 不发；ack → 编码并发的是 C（B 被替换）
}
func testLargeFrameGoesOutAsSlicesOnePerSlot() { /* 噪声整帧：先发一片（≤ 8192 + 一行）；每 ack 一次再发一片；片发完前 offer 的新帧不编码 */ }
func testModeChangeDropsQueuedSlicesAndSendsFull() {
    // Review Focus 3：整帧切成多片只发了 1 片；setMode(.duogray)；ack；下一份 transmit 的是 isFull 的新模式帧；
    // 把全部 transmit 的片按序喂 FrameDecoder：最后的像素等于最后一帧
}
func testProbeEntersWeakWhenFirstAckSlow() { /* 第一片发出后 t += 1.2；ack → onWeakChange(true) */ }
func testOutageEntersWeakViaTick() { /* 有样本 0.3 后，发一帧不确认，t 每次 +1 调 tick：第 4 秒前后 onWeakChange(true) */ }
func testV6PathUsesCompletionNotAcks() { /* acks false：offer A → 发；offer B → 不发；调 A 的 done → 发 B；ack 无作用；大帧不切片 */ }
func testStatsReportRttLatencyAndCap() { /* 一次往返 0.2、采集到确认 0.35 → takeStats 的 rttMs 200、latencyMs 350、cap、inFlight */ }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter PacedSenderTests`
Expected: 编译失败。

- [ ] **Step 3: 实现 `PacedSender`**（`Server` 的单个队列上调用，不做线程同步，类注释写明）

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test --filter PacedSenderTests`
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappCore/PacedSender.swift Tests/RappCoreTests/PacedSenderTests.swift
git commit -m "feat(core): PacedSender — in-flight cap, slicing, weak tier"
```

### Task 11: 接进 `rapp-host`

**Files:**
- Modify: `Sources/rapp-host/Server.swift`（会话状态 253–309 行，`handle` 374，`frameArrived` 635，`quantizeAndSubmit` 646，`submit` 668，`encodeAndSend` 679，`tick` 699，`setStream` 721）
- Modify: `Sources/RappCore/WorkerCLI.swift:198`（`stats` 事件加字段）
- Test: `Tests/RappCoreTests/WorkerCLITests.swift`；`scripts/multi-client-loopback.py`（不改，用来验 v6）

**Interfaces:**
- Consumes: Task 6 的消息；Task 10 的 `PacedSender`。
- Produces:
  - 每个会话一个 `PacedSender`（`acks: clientSendsFrameAcks(helloVersion)`），替换掉 `encoder`、`sendInFlight`、`pending`；`transmit` = 现在的 `send` 带 `.contentProcessed` 完成。采集时刻用 `frameArrived` 收到画面的时刻。
  - `.frameAck(ms)` → `paced.ack(ms)`。
  - `setStream(mode, fps, density, pinned)`：记下 B 要的 `(mode, fps, density)`；`pinned` 为 true 时 `paced.setPinned(true)`（会立刻退出弱网，见下）。弱网中只更新记下的值，不改实际档位。
  - `onWeakChange(true)`：实际档位换成 `duogray`、密度 `min(要的, 1.0)`，帧率不变（走现有的 mode/density 变更路径）；给 v7 的 B 发 `.weak(true)`。`false`：换回记下的档位，发 `.weak(false)`。
  - `tick` 里调 `paced.tick()`，`[stats]` 行改成 `[stats] %.1f kbps %d fps %dx%d rtt %d base %d latency %d inflight %d/%d%@`（没有的数写 `-`，弱网时末尾加 ` weak`）；`WorkerCLI.Event.stats` 加 `rttMs: Int?, baseRttMs: Int?, latencyMs: Int?, weak: Bool`，JSON 里没有的值省略。

- [ ] **Step 1: 写失败的测试**（`WorkerCLITests`）

```swift
func testStatsJsonCarriesPacingFields() { /* .stats(kbps:..., rttMs: 120, baseRttMs: 80, latencyMs: 300, weak: true) 的 JSON 有 rttMs/baseRttMs/latencyMs/weak；rttMs nil 时没有这个键 */ }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter WorkerCLITests`
Expected: 编译失败。

- [ ] **Step 3: 改 `WorkerCLI` 和 `Server`**

- [ ] **Step 4: 验证**

Run: `swift build && swift test`（全过）；`swift build -c release && python3 scripts/multi-client-loopback.py`（它说 v6：全部步骤 OK，证明 v6 照旧）。
再手动：`measure-weak.py --profile lan --minutes 1` 跑一遍，A 的 service 日志里能看到新的 `[stats]` 字段（那时 B 还是 v6，`rtt` 为 `-`）。

- [ ] **Step 5: 提交**

```bash
git add Sources/rapp-host/Server.swift Sources/RappCore/WorkerCLI.swift Tests/RappCoreTests/WorkerCLITests.swift
git commit -m "feat(host): pace frames by acks, slice, auto weak tier, pacing stats"
```

### Task 12: macOS 的 B 回确认、收弱网通知、带手动选档

**Files:**
- Modify: `Sources/RappSession/EmbeddedSession.swift`（`setStream` 95 行、发送 284 行、`.frame` 的处理）
- Modify: `Sources/RappSession/Channel.swift:125`（`set_stream` 的 `pinned`；新事件 `weak`）
- Modify: `gui/macos/Runner/SessionPlugin.swift:136`
- Modify: `Sources/rapp-client/main.swift`（`.frame` 在 184 行附近）
- Test: `Tests/RappSessionTests/EmbeddedSessionTests.swift`、`Tests/RappSessionTests/ChannelTests.swift`

**Interfaces:**
- Consumes: Task 6。
- Produces:
  - `EmbeddedSession`：每解完并画完一帧，`link.send(.frameAck(processingMs:))`（从收到这条消息到画完的毫秒数）。解码失败不回（会话照现在的办法结束）。
  - `EmbeddedSession.setStream(mode:fps:choice:pinned:)`，`pinned` 原样放进 `.setStream`；去重时把 `pinned` 也算进去。
  - 收到 `.weak(b)` → 发给 Flutter 的事件 `{"event":"weak","sid":…,"on":b}`（和现有事件同一个通道、同一种写法）。
  - `rapp-client`：同样每帧回 `.frameAck`；`.weak` 忽略。
  - Flutter 的 `set_stream` 调用多一个可选参数 `pinned`（缺省 false）。

- [ ] **Step 1: 写失败的测试**

```swift
// EmbeddedSessionTests（FakeLink 的 make(link){events} 模式）
func testAcksEveryDecodedFrame() { /* feed 三个 .frame → link.sent 里依次有三个 .frameAck */ }
func testBadFrameIsNotAcked() { /* feed 坏帧 → 没有 .frameAck，会话照旧结束 */ }
func testWeakNoticeBecomesEvent() { /* feed .weak(true) → events 里有 weak on:true */ }
func testPinnedReachesTheWire() { /* setStream(..., pinned: true) → link.sent 最后一条是 .setStream(..., pinned: true) */ }
// ChannelTests
func testSetStreamPinnedParsed() { /* {"cmd":"set_stream",...,"pinned":true} → pinned true；缺省 false */ }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter 'EmbeddedSessionTests|ChannelTests'`
Expected: 编译失败或断言失败。

- [ ] **Step 3: 实现**（含 `SessionPlugin.swift` 把 `pinned` 传下去、`rapp-client` 回确认）

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift build && swift test`；`swift build -c release && python3 scripts/e2e-local.py`（rapp-client 走 v7，三条路径都 OK）。
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappSession/EmbeddedSession.swift Sources/RappSession/Channel.swift gui/macos/Runner/SessionPlugin.swift Sources/rapp-client/main.swift Tests/RappSessionTests/EmbeddedSessionTests.swift Tests/RappSessionTests/ChannelTests.swift
git commit -m "feat(session): ack frames, weak notice, pinned stream choice on macOS"
```

### Task 13: Linux 的 B 回确认、收弱网通知、带手动选档

**Files:**
- Modify: `rust/client-core/src/bin/rapp-session.rs`
- Modify: `rust/client-gtk/src/ui.rs`（hello 126 行，解帧 159 行）

**Interfaces:**
- Consumes: Task 7。
- Produces:
  - `rapp-session`：写 socket 的一端改成 `Arc<Mutex<TcpStream>>`（stdin 线程和读循环共用）；`decode_into` 成功后写 `frame_ack(ms)`（从读完这条消息到 `out.frame` 返回的毫秒数）。版本 < 7 时不回。
  - `set_stream` 命令接受可选 `"pinned"`，版本 ≥ 7 时传 `Some(pinned)`。
  - `Incoming::Weak(b)` → stdout 事件 `{"event":"weak","on":b}`。
  - `client-gtk`：每解完一帧经现有的发送通道发 `frame_ack`；`Weak` 忽略。

- [ ] **Step 1: 写失败的测试**（`rapp-session.rs` 的 `tests` 模块）

```rust
#[test] fn set_stream_pinned() { /* command(&json!({"cmd":"set_stream","mode":"duogray","fps":1,"density":1.,"pinned":true}), 7) == p::stream(3,1,1.,Some(true)) */ }
#[test] fn set_stream_v6_has_no_pinned_byte() { /* 同一命令、版本 6 → p::stream(3,1,1.,None) */ }
#[test] fn acks_each_frame_over_loopback() {
    // 起一个 TcpListener 扮 A：回 Ready，再发两个小 .frame；读到两个 27 号包；然后发 28 号 [1]，stdout 事件里有 weak on:true
}
```

（`command` 需要知道版本：签名改成 `command(v: &Value, version: u8)`。）

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-client-core --bin rapp-session`
Expected: 编译失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test --workspace && cargo clippy --workspace -- -D warnings`；`cargo build --release -p rapp-client-core && python3 scripts/test-linux-session-latency.py`（仍通过）。
Expected: 全过。`client-gtk/src/ui.rs` 只在 Linux 上编译（gtk4 是 `cfg(target_os = "linux")` 的依赖），Mac 上的 `cargo test` 碰不到它：这一处的改动交付时标明"待 Omarchy 上 `cargo build -p rapp-client-gtk` 和手动连一次验证"。

- [ ] **Step 5: 提交**

```bash
git add rust/client-core/src/bin/rapp-session.rs rust/client-gtk/src/ui.rs
git commit -m "feat(client-core): ack frames, weak notice, pinned stream choice on Linux"
```

### Task 14: 界面：弱网标签、手动选档

**Files:**
- Modify: `gui/lib/embed/session_port.dart`（`parseSessionEvent` 加 `weak`；`setStream` 加 `pinned`）、`gui/lib/embed/linux_session_port.dart:279`、`gui/lib/embed/remote_session.dart`、`gui/lib/embed/stream_menu.dart:198`、`gui/lib/embed/traffic_label.dart`
- Modify: `gui/lib/ui/main_state.dart`（`_applyFps` ~350、`_sentFps`）、`gui/lib/ui/lifecycle.dart`（`SessionRecord.pinned`）
- Test: `gui/test/embed/traffic_label_test.dart`、`gui/test/embed/remote_session_test.dart`、`gui/test/embed/session_port_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 12/13 的 `weak` 事件和 `pinned` 参数。
- Produces:
  - `RemoteSession.weak`（bool，事件驱动，`notifyListeners`）；`RemoteSession.setChoice(StreamChoice c, {bool manual = false})`：`manual` 时 `streamPinned = true`。串流菜单里用户点选调 `manual: true`；app 配置、启动时套用的不算。
  - `SessionRecord.pinned`：会话的 `streamPinned` 变 true 时记上，重连时带回新的 `RemoteSession`。
  - `SessionPort.setStream(sid, mode, fps, density, {bool pinned = false})`；`_sentFps` 的去重元组加上 `pinned`。
  - `TrafficLabel(..., weak: bool)`：`weak` 时速率文字后面加" · 弱网"，语义标签变成 '流量 $rate，弱网，打开串流菜单'。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('traffic label shows 弱网', (t) async { /* weak:true → find.textContaining('弱网') 一个；semantics 含 '弱网' */ });
test('weak event sets RemoteSession.weak', () { /* apply(parseSessionEvent({"event":"weak","sid":1,"on":true})) → weak true；on:false → false */ });
test('manual pick pins and reaches the port', () { /* env 里打开会话，菜单选一档 → port 收到 set_stream pinned:true；profile 套用的 → pinned:false */ });
test('pin survives reconnect', () { /* 手动选档 → 断网 → reconnect → 新会话的第一次 set_stream 带 pinned:true（Review Focus 4） */ });
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && flutter test test/embed test/ui/main_state_test.dart`
Expected: 失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && flutter analyze && flutter test`
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/session_port.dart gui/lib/embed/linux_session_port.dart gui/lib/embed/remote_session.dart gui/lib/embed/stream_menu.dart gui/lib/embed/traffic_label.dart gui/lib/ui/main_state.dart gui/lib/ui/lifecycle.dart gui/test
git commit -m "feat(gui): 弱网 on the traffic label, remember a manual stream pick"
```

### Task 15: 界面：断网自动重连

**Files:**
- Modify: `gui/lib/ui/main_state.dart`（`_disconnect` 724、`_connect` 808、`reconnect` 876、`disconnectCurrent`、`_endEmbedded`）、`gui/lib/ui/lifecycle.dart`（`SessionRecord.retry`）、`gui/lib/ui/disconnected_stage.dart`
- Test: `gui/test/ui/main_state_test.dart`（现有重连测试在 1197–1310 行附近，照它们的 `env(...)` 写）、`gui/test/ui/stage_test.dart`（断开舞台的按钮）

**Interfaces:**
- Produces:
  - `bool autoReconnects(String? raw)`（`lifecycle.dart`）：`disconnectWord(raw)` 是 '网络断了' 或 '连接超时' → true。任务 16 若加了 `connection stalled`，也在 `disconnectWord` 里归到 '网络断了'。
  - `SessionRecord.retry`：`null` 或 `(int attempt, DateTime at)`。`MainState` 里每个记录一个 `Timer`。
  - 规则：
    - 会话因 `autoReconnects` 的原因断开 → `attempt = 0`，1 秒后 `reconnect(key)`。
    - 自动重连的那次 `_connect` 失败：原因是 '你断开了'、接管、'A 端关闭了 app'、'密码不对'、或含 `bad token` → 停止自动重连，照现在显示；其他（对方离线、超时、网络断了……）→ `attempt += 1`，延迟 `min(2^attempt, 15)` 秒再试。自动重连失败不设 `hint`。
    - 连上（`_connect` 走到最后）→ `retry = null`。
    - 用户点「断开」「结束会话」、记录被移除、被接管、hub 不可用 → 撤掉定时器，`retry = null`。
    - 断开的界面在 `retry != null` 时显示「正在重连…」和按钮「停止」（替代「重连」）；点「停止」→ 撤掉定时器，`retry = null`，回到现在的「重连」「结束会话」。画面照现在的办法停在最后一帧。

- [ ] **Step 1: 写失败的测试**（fakeAsync）

```dart
// lifecycle_test.dart
test('autoReconnects', () { /* 'connection closed'、'send failed: x'、'timed out' → true；'user'、'host says: app quit'、'host says: taken over'、'bad password' → false */ });
// main_state_test.dart / stage_test.dart
test('network drop reconnects after 1s', ...);               // 断开原因 'connection closed' → elapse 999ms 没有 open；1s 后 hub.open(reconnect:true)
test('backoff 1,2,4,8,15,15', ...);                          // 每次 open 都失败（'offline'）：open 的时刻间隔依次 1、2、4、8、15、15 秒
test('no hint on failed auto attempts', ...);                // 失败几次后 st.hint 仍为 null
test('success resets backoff', ...);                         // 连上后再断网：又从 1 秒开始
test('user disconnect, A quit, takeover do not retry', ...); // 原因 'user'、'host says: app quit'、'host says: taken over by X'：elapse 60s 没有 open
test('bad password stops retrying', ...);
test('stop cancels', ...);                                   // 「停止」后 elapse 60s 没有 open；舞台上出现「重连」
test('end session while waiting cancels', ...);              // Review Focus 5：等待中「结束会话」→ 记录没了，elapse 60s 没有 open
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && flutter test test/ui/main_state_test.dart test/ui/stage_test.dart test/ui/lifecycle_test.dart`
Expected: 新用例失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && flutter analyze && flutter test`
Expected: 全过。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/ui/main_state.dart gui/lib/ui/lifecycle.dart gui/lib/ui/disconnected_stage.dart gui/test/ui
git commit -m "feat(gui): reconnect by itself after a network drop"
```

---

## 第三部分：传输层的实测决定和验收

### Task 16: 断网恢复的关口（保活、卡死检测）

**为什么要有这一关：** quinn 的探测退避是 `2^min(pto_count,16)` 倍，只有收到确认才清零。断 10 秒后，下一次探测可能要在恢复后再等好几秒（推算约 8.6 秒，没实测）。验收要求恢复 ≤ 5 秒。

**Files:**
- Modify（视实测）: `rust/net/src/quic.rs:97`、`rust/wire/src/tls.rs:93`、`rust/hub/src/link.rs`（或 hub 里持有对 A / 对 relay 连接的那一处）、`gui/lib/ui/lifecycle.dart`
- Create: `docs/superpowers/measurements/2026-11-14-recovery.md`

**Interfaces:**
- Consumes: Task 4 的 `measure-weak.py`（`--profile s0` 的"恢复"行）；Task 15 的自动重连。
- Produces（若做 M3）: hub 每秒看一次 `conn.stats().udp_rx.datagrams`；连续 4 秒不变（保活 1 秒时，通的链路每秒都有包）→ `conn.close(0u32.into(), b"connection stalled")`，挂在它上面的会话以 `connection stalled` 结束；`disconnectWord` 把它归到 '网络断了'。

- [ ] **Step 1: 量现状**：s0 和一份"每 60 秒断 15 秒"的变体（命令行 `--outage 60:15:30` 覆盖），direct 和 relay 两条路径各 10 分钟，记每次恢复的秒数。
- [ ] **Step 2: M1**：两个 `transport()` 的保活从 10 秒改成 1 秒，重跑 Step 1。恢复都 ≤ 5 秒 → 跳到 Step 4。
- [ ] **Step 3: M3**：照 Interfaces 加卡死检测，先写测试：`rust/testkit/tests/hub.rs` 里经 `rapp-weaknet`（自定义 profile：t=2 s 起一直断）连 hub 和假 A，断后 6 秒内 hub 发出 `closed` 且原因 `connection stalled`；界面加 `disconnectWord('connection stalled') == '网络断了'` 的测试。重跑 Step 1。
- [ ] **Step 4: 记录**：每一步的恢复秒数（每次、中位数、最长）写进 `2026-11-14-recovery.md`，写明最后用了哪几步。
- [ ] **Step 5: 验证并提交**

Run: `cd rust && cargo test --workspace && cargo clippy --workspace -- -D warnings`；`cd gui && flutter test`。

```bash
git add rust/net/src/quic.rs rust/wire/src/tls.rs rust/hub/src docs/superpowers/measurements/2026-11-14-recovery.md gui/lib/ui/lifecycle.dart gui/test rust/testkit/tests/hub.rs
git commit -m "feat(net): recover within 5s after an outage"
```

（没改到的文件不加。）

### Task 17: 拥塞控制的对比和切换

**Files:**
- Create: `rust/testkit/tests/cc_compare.rs`、`docs/superpowers/measurements/2026-11-14-cc.md`
- Modify（若换）: `rust/net/src/quic.rs:97`、`rust/wire/src/tls.rs:93`

**Interfaces:**
- Consumes: Task 2 的 `proxy::run`、`Profile::named`。
- Produces: `#[ignore]` 测试 `cc_table`：对 `cubic`（quinn 默认）、`newreno`、`bbr`（`quinn::congestion::{CubicConfig,NewRenoConfig,BbrConfig}` 经 `TransportConfig::congestion_controller_factory`），在 s0、n2、n3 上（各去掉断开，固定 seed）各跑 20 秒：一条流尽量灌数据（量收到的字节 = 有效吞吐），同时每 200 ms 开一条 bi 流往返 1 KB（量 p50/p95）。打印一张表。
- 判定（写死在表头）：BBR 在 n3 的吞吐 ≥ 默认的 1.2 倍，在 s0、n2 ≥ 1.0 倍，且三份上 p95 都不比默认差 20% 以上 → 两个 `transport()` 都换成 BBR（relay2 和 hub/service 一起换，规格 §3 规则二第 3 条）；否则不换，记下数字。

- [ ] **Step 1: 写 `cc_compare.rs` 并跑**

Run: `cd rust && cargo test -p rapp-testkit --release --test cc_compare -- --ignored --nocapture`
Expected: 打出 3×3 的表。把表和判定写进 `2026-11-14-cc.md`。

- [ ] **Step 2: 按判定改（或不改）两个 `transport()`**；改了的话在 `rust/net` 和 `rust/wire` 各加一个单测：`transport()` 建的连接两端能互通（用现有的测试端点辅助）。

- [ ] **Step 3: 验证**

Run: `cd rust && cargo test --workspace && cargo clippy --workspace -- -D warnings`
Expected: 全过。

- [ ] **Step 4: 提交**

```bash
git add rust/testkit/tests/cc_compare.rs docs/superpowers/measurements/2026-11-14-cc.md rust/net/src/quic.rs rust/wire/src/tls.rs
git commit -m "test(testkit): congestion-control comparison on the weak link"
```

### Task 18: 第一步验收、README"实测"

**Files:**
- Create: `docs/superpowers/measurements/2026-11-14-step1.md`
- Modify: `README.md`（"实测"一节，协议版本写 v7）、`tasks/todo.md`（§9 要求的两项指向规格）

- [ ] **Step 1: 全量构建**：`scripts/check.sh`（末行 `EXIT=0`）；`cd rust && cargo build --release`；`cd gui && flutter test`。
- [ ] **Step 2: 复跑任务 5 Step 3 的全部命令**，表写进 `2026-11-14-step1.md`，每行旁边放基线的数。
- [ ] **Step 3: 对照第一步的验收**（§4 的表）：s0 上新一屏 ≤ 2 秒；画面延迟不随时间增长（10 分钟里每 5 分钟一格的中位数，后一格不比前一格多 20% 以上）；网络回来 ≤ 5 秒恢复、不用人点；文字缺 0 个；lan 上码率和每秒帧数不低于基线的 95%。每条写"过 / 不过"和数字。**不过的不改阈值、不改脚本**：回到对应的任务找原因（superpowers:systematic-debugging），修完重跑；仍不过的照实写进文档，交付时告诉用户。
- [ ] **Step 4: 30 分钟稳定**：`measure-weak.py --profile n1 --minutes 30`，记 A 和 B 进程的内存（开始、结束），确认没有崩溃、没有要人点的状态。
- [ ] **Step 5: 改 README 和 todo**：README"实测"加两张表（第一步验收、§4.3 四份网络），注明是同一台 Mac 上的回环加假链路、不是实地；协议版本改为 v7。`tasks/todo.md` 的"硬件编码""按区域选编码"指向规格。
- [ ] **Step 6: 提交**

```bash
git add docs/superpowers/measurements/2026-11-14-step1.md README.md tasks/todo.md
git commit -m "docs: smooth streaming step 1 measurements"
```
