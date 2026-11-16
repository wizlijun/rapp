# 端口分享：转发自动让路（§5.3 补做）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 分享方的 relay 连接上有会话时，经 relay 的转发按 relay 连接往返时间自动让路，把路上的排队压到会话感觉不到的程度（规格 §5.3）；没有会话时转发全速。

**Architecture:** `rapp-service` 新增 `pace` 模块，分两层。纯逻辑的控制器 `Control` 吃 `(now, rtt, 实测发送速率)`，算出放行速率。`Pacer` 放在 `State` 上，持有会话计数、字节计数和当前速率，并提供两样东西：一个 `wrap(pipe)`，把管道的写方向包成令牌桶；一个 `tick(now, rtt)`。`relay_link::session` 在推送循环里每 100 ms 调一次 `tick`，用的是 `conn.stats().rtt`。`serve_relayed` 做两件事：在 `Open`/`OpenTerm` 请求服务期间持有一个会话计数守卫；在通道（`mux`）和旧式单条 `forward` 的管道外面套上 `wrap`。relay、hub、conn 一行不改。

**Tech Stack:** Rust（`rust/` 工作区）：tokio，以及工作区已有的依赖。`rapp-service` 的 dev-dependencies 给 tokio 加 `test-util`，用暂停时钟测令牌桶。

**Spec:** `docs/superpowers/specs/2026-11-16-port-sharing-forward-pacing-design.md`，下称"设计"，已获批。上游：`docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md` §5.3，下称"规格"。测量：`docs/superpowers/measurements/2026-11-16-port-sharing-mux.md`。

## Global Constraints

- 基于本地 main（写计划时是 `4ba6ae9`，里面包括 1b 的 `c2a3389`）。在 `rust/` 下跑。
  - 单个 crate：`cargo test -p <crate>`；整体：`cargo test --workspace`。
  - 每个任务结束时，`cargo build --workspace` 没有警告。
- **不动 `rust/relay`、`rust/hub`、`rust/conn`。** 不加新依赖，不加 `service.json` 配置项。
- 用户定的有三条：
  - 限速，不换拥塞控制；
  - 上限自动探，不用配置；
  - **只在分享方的 relay 连接上有会话时生效**，没有会话时转发全速。
- 只管分享方往 relay 写转发数据的方向。局域网直连、访问方一侧都不管。
- 判定规则沿用 1b：在 `wan` 配置下，让路打开的那一组，会话往返 p50 增加 ≤ 20 ms，且 p95 增加 ≤ 40 ms。
- 日志里永远不出现 key、口令或流里的内容。

### 计划定的（设计留给实现的，以及和设计不同的）

1. **数字。**
   - `TICK` = 100 ms。
   - `TARGET` = 10 ms：排队量 = 当前往返 − 基线。
   - 超过 `TARGET` 时速率减半，每个当前往返最多减一次。
   - 不超过时，每过一个当前往返乘 1.05。上限是"最近 1 s 实测发送速率 × 1.25"，但不低于 `FLOOR`。
   - `FLOOR` = 256 kbit/s。
   - 令牌桶深度 `max(16 KiB, 速率 × 5 ms)`。
2. **基线（和设计不同）。** 设计写的是"最近 60 s 内的最小值"。但没有会话时转发全速，Cubic 会一直把瓶颈队列填着；转发跑了一分钟以上时，60 s 里根本看不到真实的往返，基线就会偏高，让路也就失效。所以改成下面这样：
   - 基线取这条 relay 连接**建立以来**的最小往返。连接刚建好、还没有转发的时候，看到的就是真实往返。
   - 再加一条纠偏：已经压在 `FLOOR` 上、排队量还连续 10 s 超过 `TARGET`，说明排队不是转发造成的（路由变了，或者会话自己占满了带宽）。这时把基线重设为最近 10 s 的最小往返。
   - 新的 relay 连接从头开始。
3. **开始和撤闸。**
   - 有会话、但还没有速率时，下一个 `tick` 定初始速率：最近 1 s 实测发送速率，但不低于 `FLOOR`。
   - 写的时候只要会话计数是 0 就直接放行，所以撤闸是立即的。下一个 `tick` 看到计数是 0，清掉速率和控制器状态（基线保留）。
4. **会话。** 经 relay 进来、请求是 `Open` 或 `OpenTerm` 的流，在 `serve_value` 期间持有 `Pacer::session()` 返回的守卫。局域网和直连路径进来的不算。
5. **套闸的位置。** 套在 e2e TLS 的明文管道上，也就是 `serve_relayed` 里拿到的 `pipe`：
   - `Op::Mux` 交给 `channel::serve` 之前套上，一条通道里的所有子流、`PONG` 都过闸；
   - `Op::Forward` 交给 `serve_value` 之前套上。
   - 计数也在这里：所有过这道闸的写都算进"实测发送速率"。
6. **开关。** `rapp_service::Opts` 加 `pacing: bool`：正式程序里是 `true`；测试的默认也是 `true`，测量的对照组设成 `false`。`false` 时 `wrap` 原样返回管道，`tick` 什么都不做。
7. **日志。** 每次开始让路和撤闸各写一行 `pace` 事件（info）：
   - 开始：`{"on": true, "kbps": <初始速率>, "base_ms": <基线>}`；
   - 撤闸：`{"on": false, "kbps": <撤闸前的速率>, "secs": <这次让路持续了多久>}`。
   - 速率调整不写日志。
8. **一轮调参。** 第一遍测量如果不达标，允许改一次 `TARGET`、乘数和减半规则，然后重跑三遍。两次的数字都写进测量文档。还不达标就如实记下，交给用户。判定规则不改。

## Review Focus

1. **没有会话时转发不受影响。** 会话计数是 0 时，`wrap` 过的写和不套一样快，不会因为令牌桶残留状态而卡住。Task 2 有测试。
2. **会话结束后立即全速。** 守卫 drop 以后，正在睡着等令牌的写要能马上醒来，不能睡到桶满。Task 2 有测试：撤闸会唤醒正在等的写。
3. **令牌桶不把转发压到零。** 往返时间持续很高（会话自己占满了上行）时，速率停在 `FLOOR`，并且 10 s 后基线纠偏。Task 1 有测试。
4. **relay 断了重连。** 新连接用新的基线；旧连接上留下的速率不能拿来压新连接。Task 3 有测试：连接重建时调用 `reset`。
5. **会话守卫泄漏。** `Open` 请求在半路出错（口令错、应用不存在）时，守卫必须还回去，否则转发永远处在让路状态。守卫要是 RAII 的，Task 3 有测试。

---

### Task 1: 控制器 `Control`

**Files:**
- Create: `rust/service/src/pace.rs`，这个任务只写 `Control`
- Modify: `rust/service/src/lib.rs`，加上 `mod pace;`

**Interfaces:**
- Produces（`pace.rs`，crate 内可见）：
  - 常量：`TICK: Duration`、`TARGET: Duration`、`FLOOR_BPS: u64 = 256_000`（单位 bit/s）
  - `struct Control`
  - `Control::new() -> Control`
  - `Control::step(&mut self, now: Instant, rtt: Duration, sent_bps: u64, pacing: bool) -> Option<u64>`
    - `pacing == false`：只更新基线，清掉速率，返回 `None`。
    - `pacing == true`：返回这一步之后的放行速率（bit/s）。
  - `Control::base(&self) -> Option<Duration>`

- [ ] **Step 1: 写失败的测试**，放在 `pace.rs` 的 `#[cfg(test)] mod tests` 里，用手造的 `Instant` 序列，不睡觉。
  - `starts_at_the_sent_rate_with_a_floor`
    - 往返 30 ms、`sent_bps` 10_000_000、`pacing` true：第一步返回 `Some(10_000_000)`。
    - 新的 `Control`，`sent_bps` 0：返回 `Some(FLOOR_BPS)`。
  - `halves_when_the_queue_passes_the_target_once_per_rtt`
    - 先用往返 30 ms 定好基线，速率 10 Mbit/s。
    - 往返 60 ms 时：下一步返回 5_000_000；同一个往返内（再过 10 ms）的下一步仍是 5_000_000；过了 60 ms 以后的那一步返回 2_500_000。
  - `grows_five_percent_per_rtt_up_to_a_cap`
    - 基线 30 ms，往返一直 32 ms，速率 4 Mbit/s，`sent_bps` 4_000_000。
    - 每过 30 ms 一步，速率依次是 4_200_000、4_410_000……
    - `sent_bps` 一直是 4_000_000 时，速率不超过 5_000_000（= 4_000_000 × 1.25）。
  - `never_below_the_floor`：往返一直比基线高 100 ms，走 200 步，每步结果都 ≥ `FLOOR_BPS`。
  - `rebases_after_ten_seconds_stuck_at_the_floor`
    - 基线 30 ms。
    - 往返变成 80 ms 并保持；速率掉到 `FLOOR_BPS` 之后再过 10 s，`base()` 变成 `Some(80 ms)`。
    - 下一步开始增长，不再减半。
  - `base_is_the_minimum_since_new`
    - 往返依次是 40、30、35 ms：`base()` 是 `Some(30 ms)`。
    - `pacing` false 的步也更新基线。
  - `not_pacing_clears_the_rate`
    - `pacing` true 走几步后，`pacing` false 那一步返回 `None`。
    - 再 `pacing` true 时，从当时的 `sent_bps` 重新开始。

- [ ] **Step 2: 跑测试，确认失败**
  Run: `cargo test -p rapp-service pace::`
  Expected: 编译失败，提示 `Control` 未定义。

- [ ] **Step 3: 实现 `Control`**，规则照"计划定的"第 1–3 条。
  - "一个当前往返"用传进来的 `rtt`。
  - 增长按"距离上次增长或减半已经过了 ≥ rtt"判断，减半同理。
  - 纠偏要记两样：从什么时候起一直压在 `FLOOR` 上并且超过目标；最近 10 s 的最小往返。数据结构由实现者定。

- [ ] **Step 4: 跑测试，确认通过**
  Run: `cargo test -p rapp-service pace::`
  Expected: 7 个测试都 PASS。

- [ ] **Step 5: Commit**
  ```bash
  git add rust/service/src/pace.rs rust/service/src/lib.rs
  git commit -m "feat(pace): a delay-based rate controller for forwards (spec §5.3)"
  ```

### Task 2: `Pacer`：会话计数、令牌桶、`tick`

**Files:**
- Modify: `rust/service/src/pace.rs`
- Modify: `rust/service/Cargo.toml`：dev-dependencies 加 `tokio = { workspace = true, features = ["test-util"] }`，如果工作区的 tokio 已经开了这个特性就不用加。

**Interfaces:**
- Consumes：Task 1 的 `Control`。
- Produces（crate 内可见）：
  - `struct Pacer`
  - `Pacer::new(enabled: bool) -> Arc<Pacer>`
  - `Pacer::session(self: &Arc<Self>) -> SessionGuard`：`SessionGuard` 在 drop 时把会话计数减一。
  - `Pacer::wrap(self: &Arc<Self>, pipe: rapp_conn::Pipe) -> rapp_conn::Pipe`
  - `Pacer::tick(&self, now: Instant, rtt: Duration) -> Option<PaceEvent>`
  - `enum PaceEvent { On { kbps: u64, base_ms: u64 }, Off { kbps: u64, secs: u64 } }`
  - `Pacer::reset(&self)`：新 relay 连接调用，清掉 `Control`（包括基线）和速率。
  - `Pacer::rate_bps(&self) -> Option<u64>`：测试用，也给 `tick` 的日志用。

- [ ] **Step 1: 写失败的测试**，用 `#[tokio::test(start_paused = true)]`，内层管道用 `tokio::io::duplex(1 << 20)`，另一头起一个任务一直读。
  - `no_session_writes_at_once`
    - `enabled` true、没有会话：写 4 MiB，虚拟时间过去 < 1 ms。
    - 让路过之后再撤闸（守卫 drop），同样立即写完。
  - `a_session_paces_to_the_rate`
    - 持有守卫，`tick` 定出速率 8_000_000 bit/s：先写 8 MiB 让 `sent_bps` 被量出来，或者直接用 crate 内的测试入口设速率，由实现者定。
    - 接着写 1_000_000 字节：虚拟耗时在 0.95–1.05 s 之间。
  - `dropping_the_last_guard_wakes_a_waiting_write`
    - 速率 `FLOOR_BPS`，开始写 1 MiB。
    - 虚拟时间 100 ms 后 drop 守卫，写要在之后 10 ms 内完成。
  - `disabled_wraps_nothing`：`enabled` false 时，有会话也立即写完；`tick` 返回 `None`，`rate_bps()` 是 `None`。
  - `tick_reports_on_and_off_once`
    - 有会话时第一次 `tick` 返回 `Some(PaceEvent::On{..})`，之后的 `tick` 返回 `None`。
    - drop 守卫后的下一次 `tick` 返回 `Some(PaceEvent::Off{..})`，再下一次返回 `None`。
  - `reset_forgets_the_base`：`reset` 之后 `rate_bps()` 是 `None`，基线重新学。

- [ ] **Step 2: 跑测试，确认失败**
  Run: `cargo test -p rapp-service pace::`
  Expected: 编译失败。

- [ ] **Step 3: 实现**
  - 会话计数和字节计数用原子变量。
  - 速率和 `Control` 放在 std `Mutex` 里，锁只在 `tick` 里和写路径算令牌时短暂持有。
  - 写路径：
    - 计数是 0，或者还没有速率，就直接写；
    - 否则从桶里取令牌，最多写取到的字节数；
    - 不够一个最小块（1 KiB）就存一个 `tokio::time::Sleep`，睡到够为止。
    - 睡的时候还要能被撤闸唤醒：守卫 drop 到 0 时 `Notify::notify_waiters()`，写路径同时等 sleep 和 notify。
  - `poll_flush`、`poll_shutdown` 和读方向原样转发。
  - 实测发送速率：`tick` 用最近 10 个 tick（1 s）的字节增量算。

- [ ] **Step 4: 跑测试，确认通过**
  Run: `cargo test -p rapp-service pace::`
  Expected: 全部 PASS。`cargo build --workspace` 没有警告。

- [ ] **Step 5: Commit**
  ```bash
  git add rust/service/src/pace.rs rust/service/Cargo.toml
  git commit -m "feat(pace): Pacer — session count, token bucket on forward writes, tick"
  ```

### Task 3: 接进服务

**Files:**
- Modify: `rust/service/src/lib.rs`：给 `Opts` 加 `pacing: bool` 和文档注释，构造 `State` 时把它传进去
- Modify: `rust/service/src/state.rs`：加 `pub pacer: Arc<pace::Pacer>`
- Modify: `rust/service/src/main.rs`：`pacing: true`
- Modify: `rust/service/src/relay_link.rs`：
  - `session()` 在 register 成功后先 `state.pacer.reset()`；
  - 推送循环加一个 `TICK` 间隔的 select 分支，调用 `state.pacer.tick(Instant::now(), conn.stats().rtt)`，返回事件时写 `pace` 日志；
  - `serve_relayed` 按"计划定的"第 4、5 条加守卫和 `wrap`。
- Modify: 所有构造 `rapp_service::Opts` 的测试：`testkit/tests/common/mod.rs` 的三处、`testkit/tests/hub.rs:677`、`testkit/tests/service.rs:773`，都加 `pacing: true`
- Test: `rust/testkit/tests/forward.rs`，在里面加测试

**Interfaces:**
- Consumes：Task 2 的 `Pacer`、`PaceEvent`。
- Produces：`Opts::pacing: bool`；日志事件 `pace`，字段照"计划定的"第 7 条。

- [ ] **Step 1: 写失败的测试**，放在 `forward.rs`，沿用这个文件里现成的 relay 装置。
  - `a_session_turns_pacing_on_and_off`
    - A 分享一个端口，B 经 relay 打开一条转发并保持。
    - 另一个访问方身份经 relay 对 A 开 `{"op":"open","app":"com.example.echo"}`，做法照 `session_priority.rs` 的 `one()`，完成到 `ok\n`。
    - 5 s 内 A 的日志出现一行 `pace`，`on` 为 true。
    - 关掉会话流后 5 s 内出现一行 `pace`，`on` 为 false，`secs` ≥ 0。
  - `a_failed_open_does_not_leave_pacing_on`
    - 经 relay 对 A 开一个不存在的应用，比如 `com.example.nope`，等它的错误回复。
    - 之后 1 s 内 A 的日志没有 `on` 为 true 的 `pace`；如果有，后面必须跟着 `on` 为 false 的。
  - `pacing_off_logs_nothing`：`pacing` 为 false 的 A，做第一条测试里的同一套操作，A 的日志里没有 `pace`。
  - 断线重连会调用 `reset`：这一条由 Task 2 的 `reset_forgets_the_base` 和这里的代码审查覆盖，不另写集成测试。

- [ ] **Step 2: 跑测试，确认失败**
  Run: `cargo test -p rapp-testkit --test forward pac`
  Expected: 编译失败（`Opts` 没有 `pacing`），或者断言失败（没有 `pace` 行）。

- [ ] **Step 3: 实现**，照上面的 Files 列表。守卫在 `serve_value` 返回之前一直活着，就放在 `serve_relayed` 的局部变量里。

- [ ] **Step 4: 跑测试，确认通过**
  Run: `cargo test -p rapp-testkit --test forward`，再跑 `cargo test --workspace`
  Expected: 全部 PASS。`cargo clippy --workspace --all-targets` 没有警告。

- [ ] **Step 5: Commit**
  ```bash
  git add -A rust
  git commit -m "feat(service): forwards give way on the relay connection while a session runs (spec §5.3)"
  ```

### Task 4: §5.3 重测和文档

**Files:**
- Modify: `rust/testkit/tests/session_priority.rs`
- Modify: `docs/superpowers/measurements/2026-11-16-port-sharing-mux.md`：加一节"## 自动让路（§5.3 补做）"
- Modify: `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`：§5.3 的实现注后面加一句，指向新的一节
- Modify: `docs/superpowers/specs/2026-11-16-port-sharing-forward-pacing-design.md`：基线一条改成"计划定的"第 2 条的说法，并注明改动原因

**Interfaces:**
- Consumes：Task 3 的 `Opts::pacing`。

- [ ] **Step 1: 改测试（跑之前）**
  - 文件头的 VERDICT RULE 改成：`wan`、`FORWARD_PRIORITY`、`pacing` true 那一组，p50 增加 ≤ 20 ms 且 p95 增加 ≤ 40 ms 算达标。不达标照"计划定的"第 8 条处理。
  - `pair` 和 `Row` 加一个参数 `pacing: bool`，`session_latency_under_a_big_forward` 跑四组：
    - `lan`/pacing true、`lan`/false、`wan`/true、`wan`/false；
    - 四组的优先级都是 `FORWARD_PRIORITY`；
    - 1b 已经证明优先级 0 和 -1 没有差别，所以去掉优先级 0 的组，把这一点写在注释里。
  - 新加 `#[ignore]` 测试 `forward_alone_keeps_its_speed`
    - `wan`、pacing true、不开会话，只做大转发：等 1 s，量 10 s 下载速率，打印出来。
    - 写进文件头的规则：≥ 18 Mbit/s 算达标，现在是约 19.5。
  - `small_forward_beside_a_bulk_one` 不改。

- [ ] **Step 2: 跑三遍，记数**
  Run: `cd rust && cargo test -p rapp-testkit --release --test session_priority -- --ignored --nocapture --test-threads 1`
  Expected: 打印出每组的表。第一遍 `wan`/true 不达标时，照"计划定的"第 8 条做一轮调参，然后再跑三遍。

- [ ] **Step 3: 写文档**
  - 测量文档新的一节：
    - 做法；
    - 三遍的表（有调参的话两轮都写）；
    - `forward_alone_keeps_its_speed` 的数字；
    - 结论（达标或不达标、原因）；
    - 已知限制：同一通道里转发之间仍然不让路；`lan` 上 CPU 那约 5 ms 仍在。
  - 规格 §5.3 的实现注加一句，指向这一节。
  - 设计文档改基线那一条。

- [ ] **Step 4: Commit**
  ```bash
  git add rust/testkit/tests/session_priority.rs docs/superpowers
  git commit -m "test(session_priority): pacing on/off groups and forward-alone speed; measurements"
  ```
