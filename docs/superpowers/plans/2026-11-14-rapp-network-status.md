# 网络状态、断网自动重连、自动省流量 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 会话在时断时续的网上自己回来；顶栏显示本机到中继的四档网络标记；A 按排队情况一级一级省流量，不超过用户选的档位。

**Architecture:** hub 把现有的中继连接缓存改成常驻：启动就拨、断了重拨、平时只读 QUIC 统计，出事才每 2 秒发一个 `ping` 请求量往返；按 10 秒窗口分四档，推 `net` 事件。界面按 `net` 和 `presence` 驱动重试。会话层加 v9 的 ping/pong 量整条路，A 的 `WeakTier` 改成 0/1/2 三级的梯子。

**Tech Stack:** Rust（quinn 0.11、tokio）、Swift（RappCore、rapp-host、RappSession）、Flutter（gui）。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-network-status-design.md`（修订 2 记了本计划定下的实现选择）

## Global Constraints

- 中继 0.7.0 不改、不重新部署。快测请求 `{"op":"ping"}`：0.7.0 回 `bad request`，不审计、不限流、不计入 `connect_backoff`；任何一行回复都算"通"。
- 四档：强 = 往返中位数 < 100 ms 且丢包 < 2%；一般 = < 300 ms 且 < 5%；弱 = 连着但不够一般；断开 = 快测连续 3 次没回应，或连接断了且重拨没拨通。往下掉马上生效，往上升要新档连续 10 秒；离开"断开"马上生效（修订 2）。
- 快测 2 秒一次；退出快测要连续 30 秒强或一般。收包计数 12 秒不变就进快测。
- hub 重拨中继：1、2、4、8 秒，最长 10 秒；地址变了马上拨；key 被拒不重拨。
- A 的 `relay_link`：退避最长 10 秒；地址变了马上重拨。
- 等对方上线的问询：5 秒；1 分钟后 15 秒；5 分钟后 30 秒；回 `limit` 停 60 秒；全局标记是断开时不问。
- 会话 ping：平时 10 秒一次，疑似不通时 2 秒一次；疑似不通 = 有输入发出后 5 秒什么都没收到，或连续 2 个 ping 没回。
- 恢复时走中继的会话错开 200 ms 重连。
- 省流梯子：级 1 = fps ≤ 5；级 2 = 双色·灰度、密度 ≤ 1.0、fps ≤ 5。降一级要排队 3 秒，升一级要 30 秒不排队且有确认；头一片确认 > 1 秒直接到最高一级；某级和上一级效果相同就跳过。
- 协议 v9：31 `ping(u32)` B→A，32 `pong(u32)` A→B，33 `saving(u8 级)` A→B。v9 的 A 服务 v5–v9 的 B；v9 的 B 要 v9 的 A（"update both sides"，和 v7、v8 一样，修订 2）。
- v9 的 `SetStream`：数值总是上限，`pinned` 字节 = "自动省流量关了"。v8 及以下的 B：梯子只有级 2 且不压帧率，`pinned` = 手动选过（现在的规则）。
- 设置：`gui.json` 的 `auto_save_traffic`，读不到当 `true`；设置面板文字 `网络差时自动省流量`。
- 所有界面文字中文，照规格原文。提交带 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。不提交用户已改的三份规格和未跟踪的文件。

## Review Focus

1. 笔记本睡眠/换 wifi 后 hub 的常驻连接是旧的：地址变化必须马上重拨，标记不能卡在旧档（Task 3 测地址变化触发重拨）。
2. 中继的 key 被拒时常驻连接不能狂拨：`relay()` 返回 Err 时监视器不拨（Task 3 测 refused 不重拨）。
3. 断开期间用户手点「重连」：失败后进入自动等待，不弹出无限错误（Task 1 测 failedOpen 的网络原因自动等）。
4. 恢复瞬间多个会话同时拨：错开 200 ms，并且只有走中继的会话被拦（Task 7 测）。
5. 用户手动选"最清晰"且开关开着：网好时始终最清晰；选更低档时当前级不高于新上限（Task 6 测）。

---

### Task 1: 界面重试规则修正

**Files:**
- Modify: `gui/lib/ui/lifecycle.dart`（`stopsAutoReconnect`、`autoReconnects`）
- Modify: `gui/lib/ui/main_state.dart`（`_planRetry`）
- Test: `gui/test/ui/lifecycle_test.dart`、`gui/test/ui/` 里现有的重试测试

**Interfaces:** Produces `autoReconnects(String word)` 对 `网络断了`、`连接超时`、`中继连不上`、`对方离线` 返回 true；`stopsAutoReconnect` 比 `远端关闭了 app`。

- [ ] 写测试：`autoReconnects('中继连不上')`、`autoReconnects('对方离线')` 为 true；`stopsAutoReconnect` 对 `远端关闭了 app` 为 true；首次打开失败、原因是网络类时 `_planRetry` 排一次重试，原因是密码类时不排。
- [ ] 跑测试看到失败；实现；跑 `flutter test` 全绿；还原 `gui/pubspec.lock`；提交。

### Task 2: 网络档位分类器和中继连接的测量接口

**Files:**
- Create: `rust/conn/src/netq.rs`（`Level`、`Meter`、`Stall`）
- Modify: `rust/conn/src/relay.rs`（`probe`、`stats`、`ensure_enrolled`）、`rust/conn/src/lib.rs`

**Interfaces — Produces:**
- `enum Level { Strong, Ok, Weak, Down }`，`Level::as_str() -> &'static str`（`strong|ok|weak|down`）。
- `Meter::new()`；`Meter::sample(now: Instant, rtt: Duration, lost: u64, sent: u64)`；`Meter::miss(now) -> bool`（第 3 次连着没回返回 true）；`Meter::down(now)`；`Meter::level() -> Option<Level>`；`Meter::rtt_ms() -> Option<u32>`；`Meter::loss() -> f64`。
- `Stall::new()`；`Stall::observe(now, rx_datagrams: u64) -> bool`（12 秒不变为 true）。
- `RelayConn::probe(&self, wait: Duration) -> Result<Duration>`：开双向流写 `{"op":"ping"}\n`，读到一行就算通。
- `RelayConn::stats(&self) -> LinkStats { rtt: Duration, rx_datagrams: u64, lost: u64, sent: u64 }`。
- `RelayConn::ensure_enrolled(&self, key: &Key) -> Result<()>`。

- [ ] 单元测试：30 ms 样本 → 强；200 ms → 一般；600 ms → 弱；3 次 miss → 断开；从一般升到强要 10 秒；从断开回来马上是测到的档；丢包 = Δlost/Δsent，Δsent < 10 时当 0；`Stall` 12 秒不变才报。
- [ ] testkit 里对真中继测 `probe` 有回复、10 分钟内跑 300 次不触发 `limit`（缩成 50 次的快速版）。
- [ ] 实现、`cargo test -p rapp-conn`、提交。

### Task 3: hub 网络监视器

**Files:**
- Create: `rust/hub/src/netmon.rs`
- Modify: `rust/hub/src/lib.rs`（字段 `net`、启动、`dispatch` 的 `net`/`net_suspect`）、`rust/hub/src/link.rs`（请求超时调用 `hub.net_suspect()`）
- Test: `rust/testkit/tests/hub.rs` 或新的 `rust/testkit/tests/netmon.rs`

**Interfaces:**
- Consumes: Task 2 的 `Meter`、`Stall`、`RelayConn::probe/stats/ensure_enrolled`；`Hub::relay()`、`upgrade::local_addrs()`。
- Produces: 事件 `{"event":"net","level":"strong|ok|weak|down","rtt_ms":n?,"loss":f}`；没设中继且发过时推 `{"event":"net","level":"none"}`；命令 `{"cmd":"net"}`（推当前值）、`{"cmd":"net_suspect"}`；`Hub::net_level() -> Option<Level>`；`Hub::net_suspect()`。

- [ ] testkit 测：设了中继的 hub 启动后推 `net` 且档位是强；把中继停掉，快测后推 `down`；中继回来，5 秒内离开 `down`；没设中继不推；key 被拒不反复拨。
- [ ] 实现：1 秒一拍；平时读 `stats()` 喂 `Meter`；快测每 2 秒 `probe(2s)`；3 次 miss 关连接（让 `relay()` 重拨）；重拨退避 1→10 秒；地址变化马上拨；档位变或 2 秒一次推；`cargo test`；提交。

### Task 4: 等对方上线

**Files:**
- Create: `rust/hub/src/watch.rs`
- Modify: `rust/hub/src/lib.rs`（命令 `watch`）、`rust/hub/src/presence.rs`（跳过在等的主机）

**Interfaces:** 命令 `{"cmd":"watch","id":s,"on":bool}`；问到在线马上推 `presence{id,online:true}`。

- [ ] testkit 测：watch 一台离线主机，主机上线后 10 秒内收到 `presence online`；`limit` 不推错误。
- [ ] 实现节奏 5/15/30 秒、`limit` 停 60 秒、标记断开时不问；提交。

### Task 5: A 端到中继更快回来

**Files:** Modify `rust/service/src/relay_link.rs`

- [ ] 改测试 `backoff_doubles_up_to_ten_seconds` 期望 `[1,2,4,8,10,10]`。
- [ ] `BACKOFF_MAX` 10 秒；`session()` 里每 2 秒比本机地址，变了以 `End::Failed("address changed")` 结束并马上重拨（不退避）；同样用 `Stall` + `probe` 3 次没回就结束连接。
- [ ] `cargo test -p rapp-service`；提交。

### Task 6: 协议 v9 和省流梯子

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`（31/32/33、`protocolVersion = 9`、`clientUnderstandsSaving(v ≥ 9)`）、`Sources/RappCore/WeakTier.swift`（级）、`Sources/RappCore/PacedSender.swift`（`onLevelChange`、`level`、`setSteps`）
- Create: `Sources/RappCore/SaveLadder.swift`（`steps`、`stream`）
- Modify: `Sources/rapp-host/Server.swift`（ping→pong、`levelChanged`、setStream 按上限）
- Modify: `Sources/RappSession/EmbeddedSession.swift`、`Channel.swift`、`SessionEvent.swift`（ping 定时、`rtt`、`stalled`、`weak` 带 `level`）
- Modify: `rust/client-core/src/protocol.rs`（`VERSION = 9`、`ping`、`Incoming::Pong/Saving`、`Address::parse` 收 4–9）、`rust/client-core/src/bin/rapp-session.rs`（ping 定时、事件）
- Test: `Tests/RappCoreTests/WeakTierTests.swift`、`ProtocolTests.swift`、新 `SaveLadderTests.swift`；Rust 协议单元测试

**Interfaces — Produces:**
- `WeakTier.level: Int`、`weak`（level > 0）、`steps: [Int]`；`observe(...) -> Int?`、`probe(...) -> Int?`。
- `SaveLadder.stream(level:ceiling:legacy:) -> StreamSpec`；`SaveLadder.steps(ceiling:legacy:) -> [Int]`。`StreamSpec { mode, fps, density }`。
- 会话端口事件：`{"event":"rtt","ms":n}`、`{"event":"stalled","on":bool}`、`{"event":"weak","on":bool,"level":n}`。

- [ ] 测试：梯子 0→1（3 秒排队）→2（再 3 秒）→1（30 秒平稳）→0；头片慢直接 2；`pinned` 回 0；legacy 的 steps 是 `[2]` 且级 2 保持 fps；上限 fps ≤ 5 时跳过级 1；协议往返 31/32/33。
- [ ] 实现 Swift 和 Rust 两边；`swift test`、`cargo test`；提交。

### Task 7: 界面

**Files:**
- Create: `gui/lib/ui/net_marker.dart`（脉搏线）
- Modify: `gui/lib/hub_client.dart`（`net` 事件、`watch`、`netSuspect`）、`gui/lib/embed/session_port.dart`、`linux_session_port.dart`（`rtt`、`stalled`、`weak.level`）、`gui/lib/embed/remote_session.dart`、`traffic_label.dart`、`stream_menu.dart`、`gui/lib/ui/main_state.dart`、`disconnected_stage.dart`、`top_bar.dart`、`side_panel.dart`、`prefs.dart`
- Test: `gui/test/ui/net_marker_test.dart`、现有 main_state/stage 测试

**Interfaces:** Consumes Task 3/4/6 的事件和命令。`UiPrefs.autoSaveTraffic`（json `auto_save_traffic`，默认 true）。

- [ ] 测试：四档的形状和颜色、窄窗口只有线、没设中继没有标记；断开时走中继的会话不重试、恢复后错开 200 ms 重连；对方离线发 `watch on`，`presence online` 马上重连；断开画面三种文字；流量标签写 `省流·1`/`省流·2`/`本机网络弱`/`对方网络弱`；开关存进 `gui.json`，`setStream` 的 `pinned` = `!autoSaveTraffic`。
- [ ] 实现；`flutter test`；还原 `gui/pubspec.lock`；提交。

### Task 8: 文档

- [ ] 串流规格规则二第 1、2 条；S3 生命周期规格断开画面文字；配置参考 `gui.json` 的 `auto_save_traffic`；协议文档 v9。提交。
