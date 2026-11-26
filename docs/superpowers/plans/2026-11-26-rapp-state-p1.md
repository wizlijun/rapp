# rapp-state P1（服务和发件箱）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 网里有一台设备 `rapp state on` 以后，每台设备的 `rapp-service` 把本机终端会话的状态变化单向送进那台的 `rapp-state`，`curl localhost:<号>/v1/queue` 能看到；网里没有状态服务时一切和今天一样。

**Architecture:** 新的独立程序 `rapp-state`（`services/state/`，hyper 1.x，只听回环）收事件、存盘、给查询。`rapp-service` 里加四块：`Share.kind`（分享带上“这是状态服务”的标记）、`sink`（知道状态服务在哪，并用新请求 `StateSink` 告诉别的设备）、`outbox`（看本机终端的 `watch`，比前后两份表出事件，缓存、补发、重试，经 `Op::Forward` 发过去）、`companion`（附带服务管理器：起停 `rapp-state`、分享它的端口）。命令行加 `rapp state [on|off]`。

**Tech Stack:** Rust 2021、tokio、hyper 1.x + hyper-util + http-body-util（新依赖）、serde_json；测试用 tokio `test-util` 假时钟和 `rust/testkit` 的多设备夹具。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-state-design.md`（第 2 稿；§7.2 发现办法、§7.4 补发顺序、端口 8102 已按 2026-11-26 的决定改过）。

## Global Constraints

- 在 worktree `.worktrees/rapp-state-p1`、分支 `feat/rapp-state-p1` 上做；完成后照 `CLAUDE.md` 合并到本机 `main`（`merge: rapp-state 第 1 步：服务和发件箱（feat/rapp-state-p1）`）。不改版本号、不打 tag、不 push、不发版。`Cargo.lock` 只允许因为新加依赖而变。
- 依赖方向：`rapp-state` 只依赖 tokio、hyper、hyper-util、http-body-util、serde、serde_json、anyhow，**不依赖任何 `rapp-*` crate**。本体 crate（service、hub、hub-ffi、cli、net、conn、ports、term…）**不依赖 `rapp-state`**；唯一例外是测试用的 `rapp-testkit`（不进安装包）。
- `rapp-state` 只监听 `127.0.0.1`，默认端口 **8102**，不做认证。
- 上限：一次 POST 最多 **50** 条、正文最多 256 KiB；`msg`、`text` 截到 **500** 个字符；发件箱缓存 **200** 条；队列 **1000** 条且不超过 **7** 天；设备 **30** 天没消息清掉；队列一页最多 **200** 条。
- 存盘：`<数据目录>/state.json`，文件 0600、目录 0700；`memory` 模式不建目录、不写任何文件。
- 事件里的文字（`msg`、`text`、`title`、`name`、会话 id）不进任何日志：`rapp-service` 和 `rapp-state` 都只记条数、设备 ID、状态码。
- 网里没有状态服务时：发件箱不开 `watch`、不开连接、缓存为空；`sink` 不发 `StateSink`；没有新增的定时器在跑网络请求。
- 设备间协议只加可选字段和一个新请求；可选字段 `None` 时不写出（`skip_serializing_if`），旧设备对新请求回 `unknown op`，按“告诉过了”处理。
- 门禁：`cargo test --workspace --no-fail-fast`（在 `rust/` 下）、`cargo clippy --workspace --all-targets -- -D warnings`。协议字段的改动必须跑整个 workspace（testkit 里有断言整行 JSON 的测试）。
- 面向用户的文字（命令行输出、错误）用中文；代码、注释、日志事件名用英文。

## Review Focus

1. **8102 被别的程序占着**：`rapp state on` 不能分享一个没人听的端口；`rapp state` 要说“没起来”和原因，管理器按退避重试。测试在 Task 10。
2. **状态服务那台长时间离线、或者从 `hosts.json` 里删了**：发件箱的内存不超过 200 条，重试间隔封顶 60 秒；删了的那台被忘掉、发件箱停下并清空。测试在 Task 6、Task 9。
3. **终端会话关着（`term.json` 的 `allow:false`）、之后又打开**：关着时不启动终端工作进程；打开后 60 秒内发件箱接上。测试在 Task 9。
4. **对面回 4xx**（进阶用户自己写的实现不认某条）：这一批丢掉并计数，不会无限重试卡住后面的事件。测试在 Task 8。
5. **网里有两台都开了状态服务**：所有设备选同一台（ID 最小），`rapp state` 两台都列出。测试在 Task 6。

---

## File Structure

```
services/
  README.md                         这一类是什么、进来的三个条件（规格 §12）
  state/
    Cargo.toml                      package rapp-state，lib rapp_state + bin rapp-state
    README.md                       单独跑、参数、接口一览（指向 api/）
    api/
      events.md                     事件格式（规格 §6 + 本计划的补充）
      http.md                       接口定义（P1 的四个）
      samples/term-lists.ndjson     发件箱的输入：一串带 at 的终端会话表
      samples/term-events.ndjson    发件箱的输出 = rapp-state 的输入（两边共用）
      samples/mixed.ndjson          重复、第二个发送者、代报、新 epoch、gap
    src/
      main.rs                       调 rapp_state::cli
      lib.rs                        Config、parse_args、cli、run、serve
      event.rs                      一行 → Event（校验信封、截断文字）
      store.rs                      纯内存模型：apply / state / queue / expire / 存取
      disk.rs                       state.json 的读写（0600、原子替换、坏文件改名）
      http.rs                       hyper 路由
    tests/http.rs                   起真服务、真 HTTP
rust/
  Cargo.toml                        members 加 "../services/state"；workspace 依赖加 hyper 三件
  net/src/msg.rs                    Op::StateSink
  service/src/shares.rs             Share.kind、Shares::set_kind
  service/src/forward.rs            listed() 带 kind
  service/src/share_cmds.rs         row() 带 kind；远程 shares 回复交给 sink::saw
  service/src/numbers.rs            启动时问到的分享表交给 sink::saw
  service/src/ipc.rs                reached() 交给 sink::saw；IPC 命令 state
  service/src/peer.rs               Op::StateSink → sink::serve
  service/src/sink.rs               新：状态服务在哪、学到/忘掉、告诉别人
  service/src/outbox/mod.rs         新：发件箱任务、统计
  service/src/outbox/diff.rs        新：前后两份会话表 → 事件
  service/src/outbox/cache.rs       新：信封、编号、200 条缓存、gap
  service/src/outbox/send.rs        新：HTTP 客户端、健康检查、退避
  service/src/companion.rs          新：附带服务管理器、services.json
  service/src/term.rs               watch_local：发件箱自己的 watch
  service/src/state.rs              State 加 sinks、outbox、companions
  service/src/lib.rs                启动 sink / outbox / companion 三个任务
  service/Cargo.toml                加 hyper 三件
  cli/src/args.rs, main.rs, say.rs  rapp state [on|off]
  testkit/Cargo.toml                依赖 rapp-state（只为 test-rapp-state）
  testkit/src/bin/test-rapp-state.rs 新：包一层 rapp_state::cli
  testkit/src/bin/fake-rapp-term.rs fake_rows 支持带 ps 的对象
  testkit/tests/common/mod.rs       bins() 加 rapp-state
  testkit/tests/state_sink.rs       新：三台设备的发现和传开
  testkit/tests/state_p1.rs         新：P1 验收
scripts/package-macos.sh, lib/sign-check.sh, test-package.sh, build-linux.sh, package-linux.sh
docs/superpowers/specs/2026-11-13-rapp-config-reference.md, 2026-11-15-rapp-port-sharing-design.md, tasks/todo.md
```

---

### Task 1: `services/` 目录和 `rapp-state` 骨架（health）

**Files:**
- Modify: `rust/Cargo.toml`（`members` 加 `"../services/state"`；`[workspace.dependencies]` 加 `hyper = { version = "1", features = ["http1", "server", "client"] }`、`hyper-util = { version = "0.1", features = ["tokio"] }`、`http-body-util = "0.1"`）
- Create: `services/README.md`、`services/state/{Cargo.toml,README.md}`、`services/state/src/{main.rs,lib.rs,http.rs}`、`services/state/api/http.md`
- Test: `services/state/src/lib.rs`（参数）、`services/state/tests/http.rs`

**Interfaces:**
- Produces:
  - `pub struct Config { pub port: u16, pub data: Option<PathBuf>, pub keep_days: u64, pub keep_events: usize }`，`Default` = `8102, None, 7, 1000`。`data: None` 就是只放内存。
  - `pub fn parse_args(args: &[String]) -> Result<Config, String>`：`--port N`、`--data DIR`、`--keep-days N`（≥1）、`--keep-events N`（≥1）；不认识的、缺值的回中文错误。
  - `pub async fn serve(cfg: Config, listener: tokio::net::TcpListener) -> anyhow::Result<()>`（测试绑端口 0 后传进来）
  - `pub async fn run(cfg: Config) -> anyhow::Result<()>`：绑 `127.0.0.1:cfg.port` 再 `serve`
  - `pub async fn cli(args: Vec<String>) -> i32`：解析、`run`，错误打到 stderr 返回 2（参数错）或 1（起不来）。绑不上端口时打一行 `{"event":"bind_failed","port":p,"error":"AddrInUse"}`（`error` 是 `io::ErrorKind` 的名字），Task 10 靠它认出“端口被占用”。`main.rs` 只有 `std::process::exit(rapp_state::cli(args).await)`。
  - 日志：一行一个 JSON 写 stderr，`{"at":<unix>,"event":"<名字>",…}`。P1 的事件名：`listening {port}`、`events {from,accepted,dup}`、`rejected {status,count}`、`saved {bytes}`、`load_failed {}`。

- [ ] **Step 1: worktree 已由主控建好（`.worktrees/rapp-state-p1`，分支 `feat/rapp-state-p1`），直接在里面做**

- [ ] **Step 2: 写失败的测试**

`lib.rs` 里：
```rust
#[test]
fn args() {
    let a = |s: &str| parse_args(&s.split_whitespace().map(String::from).collect::<Vec<_>>());
    assert_eq!(a("").unwrap(), Config::default());
    assert_eq!(a("").unwrap().port, 8102);
    let c = a("--port 9000 --data /tmp/x --keep-days 3 --keep-events 10").unwrap();
    assert_eq!((c.port, c.data.as_deref(), c.keep_days, c.keep_events), (9000, Some(Path::new("/tmp/x")), 3, 10));
    assert_eq!(a("--port").unwrap_err(), "--port 后面要写端口");
    assert_eq!(a("--keep-days 0").unwrap_err(), "--keep-days 要写正整数");
    assert_eq!(a("--frob").unwrap_err(), "不认识的参数：--frob");
}
```
`tests/http.rs`：一个帮手 `async fn start(cfg: Config) -> SocketAddr`（绑 `127.0.0.1:0`，`tokio::spawn(serve(cfg, l))`），再用 `tokio::net::TcpStream` 手写 HTTP/1.1 请求（帮手 `async fn get(addr, path) -> (u16, Value)`，`Connection: close`，读完整个回应）：
```rust
#[tokio::test]
async fn health_says_who_it_is() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/health").await, (200, json!({"name":"rapp-state","v":1})));
    assert_eq!(get(addr, "/nope").await, (404, json!({"error":"not found"})));
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd .worktrees/rapp-state-p1/rust && cargo test -p rapp-state`
Expected: 编译失败（crate 不存在）

- [ ] **Step 4: 实现**

`services/state/Cargo.toml`：`package.workspace` 不用写，`version.workspace = true` 等照 `rust/service/Cargo.toml`；`[lib] name = "rapp_state"`；`[[bin]] name = "rapp-state"`。`http.rs`：`hyper::server::conn::http1::Builder::new().serve_connection(TokioIo::new(stream), service_fn(...))`，每个连接一个 task；回应都是 `application/json`。

`services/README.md` 写规格 §12 的三个条件（本体不依赖它；它不引用本体 crate，只经端口分享和 `api/` 打交道；两边用 `api/` 的同一批样例测试），外加一句“`llm/` 位置先留着”。`services/state/README.md`：怎么单独跑（`cargo run -p rapp-state -- --data ./data`）、参数、指向 `api/`。`api/http.md` 先写 `/v1/health`，后面的任务往里补。

- [ ] **Step 5: 跑测试确认通过，并核对依赖方向**

Run: `cargo test -p rapp-state && cargo tree -p rapp-state -e normal | /usr/bin/grep -c "rapp-"`
Expected: 测试 PASS；grep 计数为 `1`（只有 `rapp-state` 自己那一行）

- [ ] **Step 6: Commit**

```bash
git add services rust/Cargo.toml rust/Cargo.lock
git commit -m "feat(state): rapp-state skeleton with /v1/health"
```

---

### Task 2: 事件和存储模型（纯逻辑）

**Files:**
- Create: `services/state/src/event.rs`、`services/state/src/store.rs`、`services/state/api/events.md`、`services/state/api/samples/term-events.ndjson`、`services/state/api/samples/mixed.ndjson`
- Test: 两个文件各自的 `#[cfg(test)]`

**Interfaces:**
- Produces:
  - `pub struct Event { pub sender: String, pub epoch: String, pub n: u64, pub at: u64, pub t: Kind, pub body: serde_json::Map<String, Value> }`，`pub enum Kind { State, Gone, Snap, Emit }`；`pub fn parse_line(line: &str) -> Result<Event, String>`；`impl Event { pub fn eid(&self) -> String /* "<sender>:<epoch>:<n>" */ }`
  - `pub struct Store`（`Serialize + Deserialize`，存盘就是它）；`Store::new(keep_days: u64, keep_events: usize) -> Store`；`pub fn apply(&mut self, ev: Event, now: u64) -> bool`（false = 重复）；`pub fn state(&self) -> Value`；`pub fn queue(&self, before: Option<&str>, limit: usize) -> Result<Value, String>`；`pub fn expire(&mut self, now: u64)`；`pub fn set_limits(&mut self, keep_days: u64, keep_events: usize)`
  - `pub const TEXT_CHARS: usize = 500; pub const DEVICE_DAYS: u64 = 30; pub const PAGE_MAX: usize = 200;`

规则（写进 `api/events.md`，测试照它断言）：

- 信封必填：`v`（=1）、`fp`、`epoch`、`n`（≥1）、`at`、`t`；可选 `id`、`device`、`src`、`via`。发送者 = `via`，没有就是 `fp`。不认识的字段原样留着，不认识的 `t` 是错。`state`、`gone` 必须有 `session`。
- `msg`、`text` 超过 500 个字符截断（按 `char` 数，不加省略号）。
- 去重：每个发送者记最近 4 个 `epoch` 各自见过的最大 `n`；`n` 不大于它的丢掉。
- 当前状态按 **被报的设备**（`fp`）分组：`devices[fp] = {fp, id, device, last: at, sessions: {session → 行}}`。`state` 替换那一行（行 = 事件的 `body` 去掉信封，加 `at`、`by: 发送者`）；`gone` 删掉；`snap` 删掉这个设备里 **`by` 等于这个发送者** 的所有行，再放进 `sessions` 数组的每一项（`at` 用 snap 的 `at`，`by` 用发送者）。别的发送者报的行不动。
- 队列：`state`、`gone`、`emit` 进队列；`snap` 只有带 `gap:true` 时进一行 `{"t":"gap","fp","id","device","at","eid"}`。每行 = 原事件（去掉 `v`）加 `eid`。排序键 `(at, 到达序号)`，新的在前。超过 `keep_events` 丢最旧；`at` 早于 `now - keep_days*86400` 的在 `expire` 时丢。
- `needs`：所有 `state == "blocked"` 的行，`{fp, id, device, session, kind, app, msg, since}`，`since` 是这一行进入 blocked 且 `seq` 不变以来的最早 `at`（同一 `seq` 再报一次不改 `since`；行里带 `since` 字段时用它）。按 `since` 从早到晚。
- `state()` 的形状：`{"devices":[{fp,id,device,last,sessions:[行…按 session 排]}…按 fp 排], "needs":[…], "queued": <队列条数>}`。
- `queue(before, limit)`：`limit` 缺省 50、封顶 200；`before` 是一行的 `eid`，只回比它旧的；不认识的 `eid` 回 `Err("bad cursor")`。形状 `{"events":[…], "more": bool}`。
- 设备 30 天（`last` 早于 `now - 30*86400`）没消息，`expire` 时整台清掉（它的队列行留着按队列规则走）。

`term-events.ndjson`（Task 7 的发件箱要逐行产出这 5 行，按 JSON 值比较，所以按这里写死）：一个发送者 `fp` = `"aa"*32`（64 个 a）、`id` `"111111111"`、`device` `"mac"`、`epoch` `"e1"`、`src` `"term"`、`at` 从 1764130000 起：
1. `n:1 t:snap sessions:[{"session":"term:pty:a","name":"a","state":"idle","seq":0,"since":1764129000}]`
2. `n:2 t:state session term:pty:a name a state working seq 1 since 1764130010`（`at` 1764130010）
3. `n:3 t:state … state blocked kind permission app claude-code msg "approve Bash: touch /tmp/x" seq 2 since 1764130020`
4. `n:4 t:state … state done seq 3 since 1764130030`
5. `n:5 t:gone session term:pty:a`（`at` 1764130040）

`mixed.ndjson`：第 2 行原样重复一次；第二个发送者 `fp` `"bb"*32` 报自己的会话 `term:pty:b`（blocked）；第三个 `fp` `"cc"*32` 带 `via` = `"bb"*32` 替 `aa` 报 `app:claude` 的一行；`aa` 换 `epoch` `"e2"`、`n:1` 的 `snap`（带 `gap:true`，`sessions` 里只有 `term:pty:c`）。

- [ ] **Step 1: 写失败的测试**（`store.rs` 里；样例用 `include_str!("../api/samples/…")`）

```rust
#[test] fn samples_give_the_state_and_queue_in_events_md()  // 喂 term-events：devices[aa].sessions 为空（gone 了）；queue 4 行（3 state + 1 gone），第一行是 gone；needs 为空
#[test] fn blocked_is_a_need_until_it_changes()             // 只喂 term-events 前 3 行：needs == [{fp aa, session term:pty:a, kind permission, since 1764130020, …}]
#[test] fn a_duplicate_is_ignored()                         // apply 同一事件两次：第二次返回 false，queue 不变
#[test] fn a_snap_replaces_only_its_senders_rows()           // 喂 mixed：aa 下只剩 term:pty:c（aa 自己的）和 cc 代报的那一行；queue 里有一行 t:gap，eid "aa…:e2:1"
#[test] fn text_is_cut_at_500_chars()                       // msg 600 个“字” → 行和队列里都是 500 个
#[test] fn the_queue_keeps_its_limits()                     // keep_events 3：喂 5 条，只剩最新 3 条；expire(now+8 天) 后为空
#[test] fn a_silent_device_goes_after_30_days()
#[test] fn pages_go_back_by_cursor()                        // 5 行，limit 2：[5,4] more:true → before=4 的 eid → [3,2] → [1] more:false；before "x:y:9" → Err("bad cursor")
#[test] fn same_second_keeps_arrival_order()
```
`event.rs` 里：
```rust
#[test] fn a_line_needs_its_envelope()   // 缺 fp / epoch / n / t 各回 Err；v:2 回 Err；t:"what" 回 Err；state 缺 session 回 Err；未知字段保留在 body
#[test] fn the_sender_is_via_when_given()
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-state`
Expected: FAIL（`parse_line`、`Store` 未定义）

- [ ] **Step 3: 实现 `event.rs`、`store.rs`，写 `api/events.md` 和两个样例文件**

队列用 `Vec`，按排序键插入（1000 条以内，线性插入够用）；到达序号是 `Store` 里递增的 `u64`，跟着存盘。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test -p rapp-state`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add services/state
git commit -m "feat(state): event parsing and the store (current state, queue, needs)"
```

---

### Task 3: `POST /v1/events`、`GET /v1/state`、`GET /v1/queue`

**Files:**
- Modify: `services/state/src/http.rs`、`services/state/src/lib.rs`（`serve` 里持有 `Arc<Mutex<Store>>`）、`services/state/api/http.md`
- Test: `services/state/tests/http.rs`

**Interfaces:**
- Consumes: Task 2 的 `parse_line`、`Store::{apply,state,queue,expire}`
- Produces（接口定义写进 `api/http.md`）：
  - `POST /v1/events`：正文是 NDJSON，空行忽略。超过 50 条或 256 KiB → 413 `{"error":"too many events"}`；任何一行解析失败 → 400 `{"error":"line <k>: <原因>"}`，**整批都不收**；否则全部 `apply`，回 204。日志 `events {from: 发送者前 8 位, accepted, dup}`（每个请求一行）；400/413 记 `rejected {status, count}`。
  - `GET /v1/state` → 200 `Store::state()`。
  - `GET /v1/queue?before=<eid>&limit=<n>` → 200 `Store::queue()`；`bad cursor` → 400；`limit` 不是数 → 400 `{"error":"bad limit"}`。
  - 方法不对 → 405 `{"error":"method not allowed"}`。
  - 每次 `apply` 之前和每 10 分钟调一次 `expire(now)`。

- [ ] **Step 1: 写失败的测试**（加帮手 `async fn post(addr, path, body: &str) -> (u16, Value)`，204 时 `Value::Null`）

```rust
#[tokio::test] async fn posted_samples_show_in_state_and_queue()   // POST term-events.ndjson → 204；/v1/state 的 queued == 4；/v1/queue 第一行 t == "gone"
#[tokio::test] async fn a_bad_line_takes_nothing()                  // 第 2 行坏 → 400，error 以 "line 2:" 开头；/v1/state 的 queued == 0
#[tokio::test] async fn fifty_one_events_are_too_many()             // 413
#[tokio::test] async fn a_resent_batch_is_taken_once()              // 同一批 POST 两次都 204；queued 不变
#[tokio::test] async fn the_log_has_counts_not_text()               // 用 serve 的日志钩子（见 Step 3）收集日志，POST 含 msg "SECRET-TEXT" 的一批：日志里没有 "SECRET-TEXT"、没有 "term:pty:"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-state --test http`
Expected: FAIL（404）

- [ ] **Step 3: 实现**

日志钩子：`lib.rs` 里 `pub struct Log(Arc<dyn Fn(&Value) + Send + Sync>)`，`Log::stderr()`；`serve_with_log(cfg, listener, log: Log)` 给测试用，`serve` 用 `Log::stderr()` 调它。读正文用 `http_body_util::Limited::new(body, 256 * 1024)`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test -p rapp-state`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add services/state
git commit -m "feat(state): POST /v1/events, GET /v1/state and /v1/queue"
```

---

### Task 4: 存盘和只放内存

**Files:**
- Create: `services/state/src/disk.rs`
- Modify: `services/state/src/lib.rs`
- Test: `services/state/src/disk.rs`、`services/state/tests/http.rs`

**Interfaces:**
- Consumes: `Store`（serde）
- Produces:
  - `pub fn load(dir: &Path) -> (Option<Store>, Option<String>)`：没有文件 → `(None, None)`；读不了或解析不了 → 把它改名成 `state.json.bad`（覆盖旧的 `.bad`），回 `(None, Some(原因))`，日志 `load_failed`（原因只写 io/serde 的错误种类，不写内容）。
  - `pub fn save(dir: &Path, store: &Store) -> std::io::Result<u64>`：建目录（0700），写 `state.json.tmp`（0600）再 `rename` 成 `state.json`，回字节数。
  - `serve` 在 `cfg.data` 有值时：启动先 `load`，读到的用 `set_limits` 换成这次的上限再 `expire`；之后有改动时最多每秒存一次（一个后台 task，`Notify` + 1 秒间隔），退出前不强求存。`cfg.data` 为 `None` 时这一块完全不跑。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn saved_and_loaded_are_the_same()                 // save 后 load == 原样（比较 state() 和 queue()）
#[test] fn files_are_private()                             // 目录 mode & 0o777 == 0o700，文件 == 0o600
#[test] fn a_broken_file_is_moved_aside()                  // 写 "{not json" → load 回 (None, Some(_))；state.json.bad 存在，state.json 不在
#[tokio::test] async fn a_restart_keeps_the_queue()        // tests/http.rs：data = tempdir，POST term-events，等 1.5 秒，停掉（abort）再起一个同目录的 → queued == 4
#[tokio::test] async fn memory_mode_writes_nothing()       // 单独放在 tests/memory.rs（独立进程，才能安全地 set_current_dir）：cwd 和 HOME 设成 tempdir，data = None，POST 后 1.5 秒 tempdir 仍为空
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-state`
Expected: FAIL

- [ ] **Step 3: 实现 `disk.rs` 并接进 `serve`**

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test -p rapp-state`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add services/state
git commit -m "feat(state): keep the store on disk (0600) or in memory only"
```

---

### Task 5: `Share.kind`

**Files:**
- Modify: `rust/service/src/shares.rs:84`（`Share` 加字段）、`rust/service/src/forward.rs:156`（`listed`）、`rust/service/src/share_cmds.rs:77`（`row` 带 `kind`）、`rust/service/src/sharing.rs`（`Op::Shares` 的回复若不是直接序列化 `Share`，同样带上）
- Test: `rust/service/src/shares.rs`、`rust/service/src/forward.rs`、`rust/testkit/tests/`（在现有的分享测试文件里加一个，或新开 `share_kind.rs`）

**Interfaces:**
- Produces:
  - `Share.kind: Option<String>`，`#[serde(default, skip_serializing_if = "Option::is_none")]`；`Share::new` 给 `None`。
  - `Shares::set_kind(&self, port: u16, kind: Option<&str>) -> anyhow::Result<bool>`：改了回 true 并存盘；没有这个分享回 false。
  - `share_all`（重新分享同一端口）保留原来的 `kind`。
  - 只有 `kind` 有值时，`list_shares`、`Op::Shares`、IPC `shares`、IPC `hosts` 的每一项才多一个 `"kind"`。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn kind_is_kept_and_written_only_when_set()   // shares.rs：add 一个、set_kind(p, Some("state")) → 重新 load 后 kind == Some("state")；另一个分享的 JSON 里没有 "kind" 键；share_all 同一端口后 kind 还在
#[test] fn listed_says_the_kind()                     // forward.rs：listed(&share) == {"port":8102,"proto":"http","local":28001,"kind":"state"}；没 kind 的和今天的输出完全一样
#[tokio::test] async fn another_device_sees_the_kind() // testkit：B 的 shares.json 预先写一项 {"port":P,"local":N,"kind":"state"}，A 的 IPC hosts 里 B 的那一项 kind == "state"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd rust && cargo test -p rapp-service kind && cargo test -p rapp-testkit another_device_sees_the_kind`
Expected: FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑整个 workspace**

Run: `cargo test --workspace --no-fail-fast`
Expected: PASS（原有断言整行 JSON 的测试不受影响，因为没 kind 时不写出）

- [ ] **Step 5: Commit**

```bash
git add rust
git commit -m "feat(service): optional Share.kind, told in list_shares, shares and hosts"
```

---

### Task 6: `sink`——状态服务在哪，告诉别人

**Files:**
- Create: `rust/service/src/sink.rs`
- Modify: `rust/net/src/msg.rs`（`Op::StateSink`）、`rust/service/src/peer.rs:229` 附近（分派）、`rust/service/src/state.rs`（`pub sinks: crate::sink::Sinks`）、`rust/service/src/lib.rs`（`Service::start` 里 load 并 `sink::spawn`）、`rust/service/src/ipc.rs:254`（`reached` 开头调 `sink::saw`）、`rust/service/src/numbers.rs`（`on_start` 拿到每台的分享表时调 `sink::saw`）、`rust/service/src/share_cmds.rs:129`（远程 `Op::Shares` 回复调 `sink::saw`）
- Test: `rust/service/src/sink.rs`、`rust/net/src/msg.rs`、`rust/testkit/tests/state_sink.rs`

**Interfaces:**
- Consumes: Task 5 的 `kind`；`pipe::{set, known_ids, known_hosts}`（`set` 发请求、`Old` 表示旧设备）
- Produces:
  - `Op::StateSink { id: String, port: u16, on: bool }` → 线上 `{"op":"state_sink","id":"123456789","port":8102,"on":true}`
  - `pub enum Dest { Local(u16), Remote { id: String, port: u16 } }`（`Clone, PartialEq, Debug`）
  - `pub struct Sinks`：`load(home: &Path) -> (Sinks, Option<String>)`（读 `<home>/state-sinks.json`，`[{"id","port"}]`，坏文件当空并回警告）；`set_local(&self, port: Option<u16>) -> bool`；`learn(&self, id: &str, port: u16) -> bool`；`forget(&self, id: &str) -> bool`（两者改了才存盘、才 bump）；`remote(&self) -> Vec<(String, u16)>`；`dest(&self, own_id: Option<&str>) -> Option<Dest>`；`subscribe(&self) -> tokio::sync::watch::Receiver<u64>`（“告诉过谁什么”只存在 `spawn` 的循环里，不放进 `Sinks`）
  - `pub fn saw(state: &Arc<State>, id: &str, items: &[Value])`：分享表里有 `kind == "state"` 的项 → `learn(id, 它的 port)`；没有、而 `id` 是已知的状态服务 → `forget(id)`。
  - `pub async fn serve(state: &Arc<State>, s: Pipe, op: Op, peer: Peer) -> anyhow::Result<()>`：`id` 不是 9 位数字或 `port == 0` 回 `bad request`；`on` → `learn`，否则 → `forget`；回 `{"ok":true}`。
  - `pub fn spawn(state: Arc<State>) -> JoinHandle<()>`：告诉别人的循环。
  - IPC `{"cmd":"state"}` 先回 `{"ok":true,"sinks":[{"id","port","local":bool,"chosen":bool}…]}`；Task 9 加 `outbox`，Task 10 加本机服务那几项，字段名不再变。
  - `pub const TELL_EVERY: Duration = Duration::from_secs(300);`
  - 日志：`state_sink {id, port, on, from: "local"|"shares"|"notice"}`（学到、忘掉各一行）、`state_sink_told {sent, failed}`（每一轮一行，没发就不记）。

规则：

- `dest`：候选 = 本机（`set_local` 给的端口，ID 用 `own_id`）加 `remote()`；按 ID 字符串排序取最小；`own_id` 为 `None` 时本机排第一。没有候选回 `None`。
- `saw` 只在 `id` 是 9 位数字时起作用；`id` 是本机自己时不动 `remote`（本机由 companion 管）。
- `hosts.json` 存在时，`dest` 之前先把不在 `known_ids` 里的远程项 `forget` 掉（在 `spawn` 循环的每一轮做）。
- 告诉别人：每台目标设备记“告诉过的那份内容”（`HashMap<目标 id, Vec<(id, port, on)>>`，内存里）。一轮 = 对 `known_hosts` 里每台（只去掉本机）：要说的 = 每个现有的状态服务（**不含在这台目标自己身上的那个**）`on:true`，加上本轮之前对它说过、现在没了的 `on:false`；和记下的一样就跳过。状态服务所在的设备也要被告诉“别处的状态服务”，否则两台都开时它们互相不知道。发 `pipe::set(state, id, &Op::StateSink{…})`：`Ok` 或 `Err(PipeErr::Old)` → 记成告诉过；别的错 → 不记，下一轮再试。
- 一轮什么时候跑：`Sinks` 变了（`subscribe`）立刻跑一轮；另外 **只在** 有状态服务、或者还有没说完的 `on:false` 时，每 `TELL_EVERY` 跑一轮。都没有时循环只等 `subscribe`，不读文件、不发请求。
- 收到的 `StateSink` 不回传给发来的那台：把发来的那台（按 `peer.fp` 在 `known_hosts` 里找到的 `id`）记成“已经知道这份”。

- [ ] **Step 1: 写失败的测试**

`msg.rs`：
```rust
#[test] fn state_sink_wire() // to_value(Op::StateSink{id:"123456789".into(),port:8102,on:true}) == {"op":"state_sink","id":"123456789","port":8102,"on":true}，反向也成立
```
`sink.rs`（用 tempdir 当 home）：
```rust
#[test] fn the_smallest_id_wins()                 // learn("222222222",1)、learn("111111111",2)、set_local(Some(3)) 且 own_id "333333333" → Remote{id:"111111111",port:2}；own_id None → Local(3)
#[test] fn learned_sinks_survive_a_restart()       // learn 后重新 load → remote() 一样；forget 后文件里为空数组
#[test] fn a_share_list_without_the_kind_forgets() // saw(id, [{"port":8102,"kind":"state"}]) → learn；saw(id, [{"port":8102}]) → forget
#[test] fn what_to_tell_each_host()                // 纯函数 tell_plan(hosts, sinks, told) 的几种情形：新设备要说 on；说过一样的不说；状态服务没了要说 off；不跟一台设备说它自己身上的状态服务，但要跟它说别处的
```
`testkit/tests/state_sink.rs`（照 `tests/maps.rs` 的 `start_on` / `knows` 起三台：A 有 `hosts.json` 认识 B、C；B 和 C 没有 `hosts.json`）：
```rust
#[tokio::test] async fn a_sink_seen_in_shares_spreads()   // B 的 shares.json 预先有 kind:"state" 的一项；A 跑 IPC hosts → 10 秒内 C 的 IPC state 的 sinks 里有 B
#[tokio::test] async fn an_unshared_sink_is_forgotten_everywhere() // 接上一个：B 的 IPC unshare 那个端口，A 再跑 IPC hosts → A、C 都忘掉 B
#[tokio::test] async fn two_sinks_pick_the_same_one()     // B、C 都有 kind:"state"；A hosts 一次后：A 的 IPC state 的 sinks 两项、chosen 是 ID 较小的那台；B 的 sinks 有 C，C 的 sinks 有 B
                                                           // （本机的状态服务要到 Task 10 才有，“三台选同一个”在 Task 10 的 two_companions_pick_the_same_one 断言）
#[tokio::test] async fn no_sink_no_notice()               // 都没有 kind；A hosts 后 3 秒：B、C 的日志里没有 state_sink，A 的日志里没有 state_sink_told
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-net state_sink && cargo test -p rapp-service sink && cargo test -p rapp-testkit --test state_sink`
Expected: FAIL

- [ ] **Step 3: 实现**

`tell_plan(hosts: &[String], sinks: &[(String, u16)], told: &HashMap<String, Vec<(String, u16, bool)>>) -> Vec<(String, Vec<(String, u16, bool)>)>` 做成纯函数，循环只负责发和记。

- [ ] **Step 4: 跑整个 workspace**

Run: `cargo test --workspace --no-fail-fast`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rust
git commit -m "feat(service): find the state service and tell the known devices (state_sink)"
```

---

### Task 7: 发件箱的纯逻辑——会话表比较、信封、缓存

**Files:**
- Create: `rust/service/src/outbox/mod.rs`（这一步只有 `mod diff; mod cache;` 和公开类型）、`rust/service/src/outbox/diff.rs`、`rust/service/src/outbox/cache.rs`、`services/state/api/samples/term-lists.ndjson`
- Modify: `rust/service/src/lib.rs`（`mod outbox;`）
- Test: `diff.rs`、`cache.rs` 的 `#[cfg(test)]`

**Interfaces:**
- Produces:
  - `pub struct Me { pub fp: String, pub id: Option<String>, pub device: String, pub epoch: String }`；`pub fn new_epoch() -> String`（6 个随机十六进制字符，用 `rand`）
  - `pub struct Diff`：`Diff::default()`；`pub fn feed(&mut self, list: &Value, at: u64) -> Vec<Value>`：`list` 是终端工作进程的 `{"terms":[…],"hosts":[…]}`；第一次只记下、回空；之后回事件正文（没有信封，`t` + 字段）。`pub fn snap(&self) -> Vec<Value>`：当前每个会话一项。`pub fn ready(&self) -> bool`（喂过第一份）。
  - `pub const CACHE_MAX: usize = 200;`
  - `pub struct Cache`：`Cache::new(me: Me)`；`pub fn push(&mut self, body: Value, at: u64)`（编号、套信封、满了丢最旧并记 gap）；`pub fn head(&self, max: usize) -> Vec<Value>`；`pub fn ack(&mut self, through: u64)`（去掉 `n <= through` 的）；`pub fn snap(&mut self, sessions: Vec<Value>, at: u64) -> Value`（取下一个 `n`，`gap` 为真时带 `gap:true`；不进缓存）；`pub fn snap_taken(&mut self)`（清 gap）；`pub fn len(&self) -> usize`；`pub fn dropped(&self) -> u64`
  - 信封字段顺序和内容：`v:1, fp, id（有才写）, device, epoch, n, at, src:"term"`，然后正文字段。

比较规则（和 `gui/lib/ui/main_state.dart:637` 的 `_trackPrograms` 一致）：

- 只看 `dead == false` 且有 `ps` 的行。会话的“键” = `(ps.state, ps.state == "blocked" ? ps.seq : 0)`。
- 新出现的、键变了的 → `state` 事件：`session`（行的 `id`）、`name`、`title`、`fg`、`host`（后三个有才写）、`state`、`kind`、`app`、`msg`（有才写，`msg` 截到 500 字符）、`seq`、`since`（`ps.since`）。
- 只是 `progress`、`msg` 变而键没变 → 不发，但 `snap()` 里用最新的值。
- 上一份有、这一份没有（或变成 dead、或 `ps` 没了）→ `gone {session}`。
- `snap()` 每项 = `state` 事件去掉 `t`。

- [ ] **Step 1: 写 `term-lists.ndjson`，再写失败的测试**

`term-lists.ndjson` 每行 `{"at":…, "list":{"terms":[…],"hosts":[]}}`，五行分别让 `term:pty:a` 处于 idle（`since` 1764129000）、working、blocked（seq 2，msg 同 Task 2）、done、消失；外加第 3、4 行之间插一行只改 `progress` 的。

```rust
#[test] fn lists_become_the_sample_events() {
    // Me{fp: "a"*64, id: Some("111111111"), device: "mac", epoch: "e1"}；
    // 第一份 feed 后 cache.snap(diff.snap(), at) 是 n:1；其余每份 feed 的事件逐条 push；
    // [snap] + cache.head(50) 逐行 == term-events.ndjson 的 5 行（serde_json::Value 比较）
}
#[test] fn progress_alone_says_nothing()
#[test] fn a_new_question_while_blocked_is_news()   // blocked seq 2 → blocked seq 3：一条 state
#[test] fn dead_or_statusless_rows_are_gone()
#[test] fn the_cache_keeps_200_and_marks_the_gap() // push 250 条：len 200，head(1)[0]["n"] == 51，dropped 50；snap 带 gap:true；snap_taken 后再 snap 不带
#[test] fn ack_drops_what_was_taken()
#[test] fn the_first_list_is_no_change()
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-service outbox`
Expected: FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test -p rapp-service outbox && cargo test -p rapp-state`
Expected: PASS（两边读的是同一份 `term-events.ndjson`）

- [ ] **Step 5: Commit**

```bash
git add rust services/state/api/samples
git commit -m "feat(service): outbox diff, envelope and 200-event cache"
```

---

### Task 8: 发件箱的发送——HTTP、健康检查、补发顺序、退避

**Files:**
- Create: `rust/service/src/outbox/send.rs`、`rust/service/src/outbox/pump.rs`
- Modify: `rust/service/Cargo.toml`（加 `hyper`、`hyper-util`、`http-body-util`）
- Test: `send.rs`、`pump.rs` 的 `#[cfg(test)]`（测试里用 hyper 起一个假的状态服务，记下收到的每个请求）

**Interfaces:**
- Consumes: Task 7 的 `Diff`、`Cache`、`Me`
- Produces:
  - `pub enum DialErr { Gone, Down(&'static str) }`（`Gone` = 对面说没有这个分享，要 `forget`；`Down` 带种类：`offline`、`refused`、`io`…，只用于日志）
  - `pub trait Dial: Send + Sync { fn dial(&self) -> impl Future<Output = Result<rapp_conn::Pipe, DialErr>> + Send; }`
  - `pub struct Conn`；`pub async fn connect(io: rapp_conn::Pipe) -> Result<Conn, &'static str>`：HTTP/1.1 握手，`GET /v1/health`，回应必须是 200 且 `name == "rapp-state"`，否则 `Err("not rapp-state")`
  - `impl Conn { pub async fn post(&mut self, lines: &[Value]) -> Result<Posted, &'static str> }`；`pub enum Posted { Taken, Refused(u16) }`（2xx → `Taken`；4xx → `Refused`；5xx 和网络错误 → `Err`）
  - `pub fn backoff(fails: u32) -> Duration`：2、4、8、16、32、60、60… 秒
  - `pub struct Stats { pub active: bool, pub cached: usize, pub sent: u64, pub dropped: u64, pub refused: u64, pub last_ok: Option<u64>, pub up: bool }`（`Default, Clone, Serialize`）
  - `pub async fn pump<D: Dial>(me: Me, lists: tokio::sync::mpsc::Receiver<(Value, u64)>, dial: D, log: &rapp_net::log::Log, stats: &std::sync::Mutex<Stats>) -> PumpEnd`；`pub enum PumpEnd { Gone, ListsClosed }`。`lists` 的每项是 `(会话表, at)`。

`pump` 的行为：

- 一边收 `lists` 喂 `Diff`，事件 `push` 进 `Cache`；一边送。
- 送：收到第一份表以前不 `dial`；之后没连接就 `dial` + `connect`；成功后先把缓存按 `n` 一批最多 50 条发完（每批 `Taken` 就 `ack`），然后发一条 `snap`（`Diff` 还没 `ready` 时等第一份表再发），`Taken` 后 `snap_taken`；之后缓存一有东西就发。
- `Refused(status)`：这一批 `ack` 掉，`refused += 条数`，日志 `outbox_refused {status, count}`；连接留着继续。
- `Err` / `dial` 的 `Down`：丢掉连接，`fails += 1`，等 `backoff(fails)`，期间照常收 `lists`；重新连上后照上面“先补发、再 snap”。连上并送成功一次就把 `fails` 归零。
- `dial` 回 `Gone` → 回 `PumpEnd::Gone`。`lists` 关了 → 回 `ListsClosed`。
- 同一时刻只有一个请求在路上。
- 日志（`rapp_net::log::Log`）：`outbox_up {resent}`（连上并补完时，`resent` 是补发的条数）、`outbox_down {cached, why}`（`why` 是 `&'static str` 的种类）、`outbox_dropped {count}`（缓存满丢的，每次掉线恢复时汇总一行）。不写任何事件内容。
- 每次变化后更新 `stats`。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn backoff_doubles_to_a_minute()        // [2,4,8,16,32,60,60]
#[tokio::test] async fn health_must_say_rapp_state()      // 假服务回 {"name":"other"} → connect 回 Err("not rapp-state")
#[tokio::test] async fn events_go_in_order_then_snap()    // 假服务记录；dial 先回 Down，喂 term-lists 前 4 份（idle、working、blocked、只改 progress）后才让它成功：
                                                           // 收到 n:1 working、n:2 blocked，然后 n:3 的 snap（会话 blocked，progress 是最新的）；喂第一份之前不 dial
#[tokio::test(start_paused = true)] async fn a_failed_service_is_tried_again_later() // dial 前 3 次回 Down("offline")：第 1..3 次 dial 的（假）时刻相差 2s、4s；第 4 次成功后补发
#[tokio::test] async fn three_changes_while_down_arrive_after() // 断开期间喂 3 份有变化的表，恢复后假服务收到这 3 条 + snap
#[tokio::test] async fn three_hundred_changes_leave_a_gap()     // 断开期间 300 条变化：恢复后收到 200 条（最旧的是第 101 条变化）+ 带 gap:true 的 snap；stats.dropped == 100；日志有一行 outbox_dropped {count:100}
#[tokio::test] async fn a_refused_batch_is_dropped_not_retried() // 假服务第一批回 400、之后 204：第一批不再出现，后面的照常到；stats.refused == 那批条数
#[tokio::test] async fn not_shared_ends_the_pump()               // dial 回 Gone → PumpEnd::Gone
#[tokio::test] async fn the_log_has_no_event_text()              // msg "SECRET-TEXT"，跑完 three_changes 的流程：日志文件里没有 "SECRET-TEXT"、"term:pty:"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-service outbox`
Expected: FAIL

- [ ] **Step 3: 实现**

`Conn` 内部是 `hyper::client::conn::http1::SendRequest<Full<Bytes>>`，握手后把 connection future `tokio::spawn` 出去；请求头 `Host: rapp-state`、`Content-Type: application/x-ndjson`。假时钟测试里 `Dial` 是一个记录 `tokio::time::Instant::now()` 的假实现，成功时回 `tokio::io::duplex` 的一端、另一端接测试里的 hyper 假服务。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test -p rapp-service outbox`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rust
git commit -m "feat(service): outbox sending: health check, resend then snap, backoff"
```

---

### Task 9: 发件箱接进 `rapp-service`

**Files:**
- Modify: `rust/service/src/outbox/mod.rs`（任务、`status`）、`rust/service/src/term.rs`（`watch_local`、`set_term` 后 `poke`）、`rust/service/src/state.rs`（`pub outbox: crate::outbox::Outbox`）、`rust/service/src/lib.rs`（`outbox::spawn`）、`rust/service/src/ipc.rs`（IPC `state` 的回复加 `"outbox": outbox::status(state)`）、`rust/testkit/src/bin/fake-rapp-term.rs`（`fake_rows` 的项可以是对象；每次开始一个 `watch` 往 `term.log` 写一行 `watch open`）
- Test: `rust/service/src/outbox/mod.rs`、`rust/testkit/tests/state_p1.rs`（先放两个反目标测试）

**Interfaces:**
- Consumes: Task 6 的 `Sinks::{dest,subscribe}`、`sink::forget`；Task 8 的 `pump`、`Stats`、`Dial`；`pipe::open`；`term::config`
- Produces:
  - `term.rs`：`pub(crate) struct LocalWatch<'a>`、`pub(crate) async fn watch_local(state: &Arc<State>) -> anyhow::Result<LocalWatch<'_>>`（`start_counted` + `first(port, token, {"op":"watch"})`，持有 `Counted` 直到丢掉），`impl LocalWatch<'_> { pub async fn next(&mut self) -> anyhow::Result<Option<Value>> }`；第一份表也从 `next` 出来。工作进程回 `{"error":…}` 时 `next` 回 `Err`。
  - `outbox/mod.rs`：`pub struct Outbox { stats: Mutex<Stats> }`、`Outbox::new()`；`pub fn spawn(state: Arc<State>) -> JoinHandle<()>`；`pub fn status(state: &State) -> Value`（`Stats` 加 `"dest"`：`{"local":port}` 或 `{"id","port"}` 或 `null`）
  - `pub const SOURCE_RETRY: Duration = Duration::from_secs(60);`
  - fake-rapp-term：`fake_rows` 的一项可以是 `{"key":"a","ps":{…},"title":"…","fg":"claude"}`，生成的行带上这些字段；字符串项照旧。

`spawn` 的行为：

- 等 `sinks.subscribe()`；`dest(own_id)` 为 `None` 时什么都不做（`stats` 清成默认，`active:false`）。
- 有了 `dest`：开一个 `mpsc::channel(64)`；开 `pump`（`Me` 的 `fp` 取 `state.identity.fp`、`id`/`device` 取 `cfg.id`/`cfg.name`、`epoch` 每次 `rapp-service` 启动生成一次）；开“来源”任务：`term::config(state)` 显示终端会话关着就每 `SOURCE_RETRY` 再看一次（只读文件，不起工作进程）；开着就 `watch_local`，每份表 `send((list, now))`；`watch` 断了 2 秒后重开（`Diff` 留着，所以重开后的第一份只出真变化）。
- `Dial` 的实现：`Dest::Local(port)` → `TcpStream::connect(("127.0.0.1", port))`；`Dest::Remote{id,port}` → `pipe::open(state, &id, port)`，`Refused("not shared" | "not allowed")` → `DialErr::Gone`，`Offline` → `Down("offline")`，别的 → `Down("refused")`/`Down("io")`。
- `dest` 变了或变成 `None`：abort 来源和 `pump`，丢掉 `Cache`（`stats.cached` 归零），按新的 `dest` 重来。`PumpEnd::Gone` → `sinks.forget(id)`（它会触发 `subscribe`）。

- [ ] **Step 1: 写失败的测试**

`testkit/tests/state_p1.rs`：
```rust
#[tokio::test] async fn without_a_state_service_nothing_changes()
// 两台 A、B 互相认识、都没有状态服务；B 的 term.json 有 fake_rows 带 ps 并改几次：
// A、B 的 IPC state 里 outbox == {"active":false,"cached":0,…,"dest":null}；
// B 的 term.log 里没有 "watch open"；
// A、B 的服务日志里没有 outbox_ 和 state_sink 开头的事件
#[tokio::test] async fn terminals_off_starts_no_worker()
// B 的 term.json allow:false；B 的 state-sinks.json 预先写 A 的一个状态服务；3 秒内 B 的 term.log 没有任何行（工作进程没起）；
// IPC set_term 打开终端会话后 2 秒内 term.log 有 "watch open"（靠 Step 3 的 poke，不等 SOURCE_RETRY）
```
`outbox/mod.rs` 单元测试：
```rust
#[tokio::test] async fn a_gone_dest_clears_the_cache() // 用 Task 8 的假 Dial：Gone 后 stats.cached == 0 且 sinks.forget 被调
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-testkit --test state_p1 && cargo test -p rapp-service outbox`
Expected: FAIL

- [ ] **Step 3: 实现**

`term::set`（IPC `set_term`）成功后 `state.outbox.poke()`（一个 `Notify`），来源任务在等 `SOURCE_RETRY` 时也等这个 `Notify`，这样打开终端会话不用等 60 秒。

- [ ] **Step 4: 跑整个 workspace**

Run: `cargo test --workspace --no-fail-fast`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rust
git commit -m "feat(service): run the outbox while a state service is known"
```

---

### Task 10: 附带服务管理器和 IPC `state`

**Files:**
- Create: `rust/service/src/companion.rs`、`rust/testkit/src/bin/test-rapp-state.rs`
- Modify: `rust/service/src/state.rs`（`pub companions: crate::companion::Companions`）、`rust/service/src/lib.rs`（`companion::spawn`；`stop()` 时子进程跟着停）、`rust/service/src/ipc.rs`（`"state"` 放进 async 分派）、`rust/testkit/Cargo.toml`（依赖 `rapp-state = { path = "../../services/state" }`，加 `[[bin]] test-rapp-state`）、`rust/testkit/tests/common/mod.rs:32`（`bins()` 加 `("rapp-state", env!("CARGO_BIN_EXE_test-rapp-state"))`）
- Test: `companion.rs`、`rust/testkit/tests/state_p1.rs`

**Interfaces:**
- Consumes: Task 5 的 `Shares::set_kind`、`sharing::share`；Task 6 的 `Sinks::set_local`；Task 9 的 `outbox::status`；`rapp_net::bins::find`
- Produces:
  - `pub struct Companion { pub name: &'static str, pub program: &'static str, pub port: u16, pub kind: &'static str, pub note: &'static str }`；`pub const TABLE: &[Companion] = &[Companion { name: "state", program: "rapp-state", port: 8102, kind: "state", note: "状态服务" }];`
  - `local/services.json`：`{"state":{"on":true,"port":8102,"store":"disk","keep_days":7,"keep_events":1000}}`；除 `on` 外都可缺（用默认）；`#[derive(Serialize, Deserialize, Default)] pub struct ServiceCfg { pub on: bool, pub port: Option<u16>, pub store: Option<String>, pub keep_days: Option<u64>, pub keep_events: Option<usize> }`；文件没有 = 全关；坏文件 = 全关并在日志里记 `services_json_invalid`，`set` 时覆盖它。未知字段保留（读成 `Map` 再改 `on`）。
  - `pub fn args(c: &ServiceCfg, home: &Path) -> Vec<String>`：`--port <p>`、`store` 不是 `"memory"` 时 `--data <home>/state`、`--keep-days`、`--keep-events`
  - `pub struct Companions`；`pub fn spawn(state: Arc<State>) -> JoinHandle<()>`：启动时把 `on` 的那些起起来
  - `pub async fn set(state: &Arc<State>, name: &str, on: bool) -> Value`、`pub async fn status(state: &Arc<State>, name: &str) -> Value`
  - IPC：`{"cmd":"state"}` → `status`；`{"cmd":"state","on":true|false}` → `set`。回复：`{"ok":true,"on","port","share":<分享号>|null,"running":bool,"error":<原因>|null,"stored":{"devices","sessions","queued","last":{"device","at"}|null}|null,"sinks":[{"id","port","local":bool,"chosen":bool}…],"outbox":<outbox::status>}`；`name` 不认识回 `err("unknown service")`。
  - 日志：`companion_start {name, port, pid}`、`companion_exit {name, code}`、`companion_ready {name}`、`companion_failed {name, why}`。子进程的 stderr 追加写到 `<log_dir>/rapp-state.log`，stdout 丢掉。

管理器的行为：

- 开（`set(on:true)` 或启动时文件里是开的）：写文件（`set` 时）→ 起子进程（`kill_on_drop`）→ 每 200 ms 用 `GET /v1/health` 探一次，最多 5 秒。成功：`sharing::share(state, &json!({"ports":[port],"note":"状态服务","proto":"http"}), Allow::Names, &By::Local)`（已有这个分享就不重复，`note` 以用户改过的为准）→ `set_kind(port, Some("state"))` → `sinks.set_local(Some(port))` → 日志 `companion_ready`。失败（程序找不到、端口被占导致子进程退出、5 秒没就绪）：`running:false`，`error` 写中文原因（`找不到 rapp-state`、`端口 8102 被占用`、`没有起来`），**不分享**，按 `outbox::send::backoff` 退避重试。
- 子进程中途退出：`sinks.set_local(None)`，退避后重起；跑满 60 秒算稳定，退避归零。分享保留（端口短暂没人听，访问的一方会重试）。
- 关（`set(on:false)`）：写文件 → 停子进程 → `sinks.set_local(None)` → 取消分享（`sharing::unshare`，只在这个分享的 `kind` 是 `"state"` 时）。
- `stored`：服务在跑时 `GET /v1/state` 数出来（3 秒超时，失败给 `null`）。
- 端口被占的判断：子进程 1 秒内退出且 stderr 最后一行含 `Address already in use`/`AddrInUse` → `端口 <p> 被占用`。（`rapp-state` 绑不上端口时打印 `{"event":"bind_failed","port":p,"error":"AddrInUse"}`，Task 1 的 `cli` 要这样报。）

- [ ] **Step 1: 写失败的测试**

`companion.rs`：
```rust
#[test] fn args_follow_the_file()     // 缺省 → ["--port","8102","--data","<home>/state","--keep-days","7","--keep-events","1000"]；store memory → 没有 --data
#[test] fn turning_on_keeps_other_fields() // 文件里有 {"state":{"on":false,"x":1},"llm":{…}} → set on 后 x 和 llm 都还在
```
`testkit/tests/state_p1.rs`（测试先找一个空闲端口写进 `services.json` 的 `port`，不用 8102）：
```rust
#[tokio::test] async fn state_on_runs_and_shares_it()
// IPC {"cmd":"state","on":true} → 5 秒内 running:true；share 是一个分享号；本机 IPC shares 里那一项 kind == "state"；
// curl 等价（TcpStream 手写 GET）127.0.0.1:<port>/v1/health 回 rapp-state；outbox.dest == {"local":port}
#[tokio::test] async fn state_off_stops_and_unshares()
#[tokio::test] async fn a_taken_port_is_said_and_not_shared()
// 先自己占住端口 → on 后 running:false，error == "端口 <p> 被占用"；shares 里没有这个端口；释放端口后再发一次 IPC state on → 5 秒内 running:true 且分享出现
// （`set(on:true)` 在已经开着、但没跑起来时立即重试，不等退避）
#[tokio::test] async fn a_crashed_service_comes_back() // 找到子进程 pid（日志 companion_start 后用 /v1/health 确认），kill -9 → 10 秒内 running:true 又成立
#[tokio::test] async fn state_on_tells_the_known_devices() // A 认识 B（hosts.json）；A 上 state on → 10 秒内 B 的 IPC state 的 sinks 里有 A
#[tokio::test] async fn two_companions_pick_the_same_one() // A 认识 B、C；B、C 都 state on（不同的空闲端口），A 跑一次 IPC hosts → 15 秒内 A、B、C 的 outbox.dest 都指向 ID 较小的那台
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-service companion && cargo test -p rapp-testkit --test state_p1`
Expected: FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑整个 workspace，并核对依赖方向**

Run: `cargo test --workspace --no-fail-fast && cargo tree -p rapp-service -e normal | /usr/bin/grep -c rapp-state`
Expected: PASS；计数 `0`

- [ ] **Step 5: Commit**

```bash
git add rust
git commit -m "feat(service): companion services: start, share and stop rapp-state"
```

---

### Task 11: 命令行 `rapp state [on|off]`

**Files:**
- Modify: `rust/cli/src/args.rs`（`USAGE`、`Cmd::State`、`parse`）、`rust/cli/src/main.rs`、`rust/cli/src/say.rs`
- Test: `args.rs`、`say.rs` 的 `#[cfg(test)]`

**Interfaces:**
- Consumes: Task 10 的 IPC `state` 回复
- Produces: `Cmd::State { on: Option<bool> }`；`pub fn state(r: &Value) -> String`（`say.rs`）

`USAGE` 加两行：
```
rapp state                                      看状态服务
rapp state on|off                               在这台上开、关状态服务
```

`say::state` 的输出（每项一行，没有的那行不写）：
```
状态服务：开着，端口 8102，分享号 28003
  存着 3 台设备、5 个会话、120 条队列；最近一次收到 mac 的，2 分钟前
状态服务：开着，端口 8102，没有起来：端口 8102 被占用
状态服务：没开
网里的状态服务：123456789 的 8102（在用），本机的 8102
发件箱：在发，缓存 0 条，已发 42 条
发件箱：连不上，缓存 17 条
发件箱：没在发（网里没有状态服务）
```
`rapp state on` 成功后先打一行 `已打开状态服务`（失败时 `fail("没有成功：<error>")`，退出码 1），再打 `say::state`；`off` 打 `已关掉状态服务`。时间差用“刚才 / N 分钟前 / N 小时前 / N 天前”。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn state_commands() // "state" → State{on:None}；"state on" → Some(true)；"state off" → Some(false)；"state up" → Err("不认识的命令：state up")；"state on x" → Err("多写了：x")
#[test] fn state_says_what_runs() // 用上面几种 IPC 回复的 JSON 逐一断言整段输出
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p rapp-cli`
Expected: FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test -p rapp-cli`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rust/cli
git commit -m "feat(cli): rapp state [on|off]"
```

---

### Task 12: P1 验收测试（两台设备，真的 `rapp-state`）

**Files:**
- Modify: `rust/testkit/tests/state_p1.rs`
- Test: 同上

**Interfaces:**
- Consumes: 前面所有任务；`tests/maps.rs` 的两台设备写法；fake-rapp-term 的带 `ps` 的 `fake_rows`

- [ ] **Step 1: 写验收测试**（规格 §15 P1 那一行，逐条）

“停服务”不用 `state off`（关掉是有意移除，会发 `on:false`，B 会忘掉并清空发件箱，这是对的）。停、起的两个测试改用测试自己控制的 `rapp-state`：testkit 的测试直接调 `rapp_state::serve`（固定的空闲端口、tempdir 里存盘），A 的 `shares.json` 预先有这个端口、`kind:"state"` 的分享，B 的 `state-sinks.json` 预先指向 A 的这个端口；停 = abort 那个 task，起 = 同端口同目录再 `serve` 一次。确认 A 端口没人听时 `Op::Forward` 回的错误在 Task 9 的映射里是 `Down` 而不是 `Gone`。

```rust
#[tokio::test] async fn claude_working_blocked_done_reach_the_queue()
// A：state on（空闲端口）。B 认识 A；A 认识 B（hosts.json 两边都写），A 的 state on 告诉 B。
// B 的 term.json fake_rows 依次改成 term:pty:a 的 working → blocked(kind permission, seq 1) → done，每次之间等到 A 的 /v1/queue 多一行（10 秒超时）。
// 断言：/v1/queue 的前三行 state 依次是 done、blocked、working，fp 都是 B 的指纹；/v1/state 的 needs 在 blocked 时有一项、done 后为空。
#[tokio::test] async fn three_changes_while_stopped_arrive_later()
// 用上面的自控 rapp-state：先确认 working 到了；停掉它；B 改 3 次状态；再起；15 秒内 /v1/queue 多出这 3 行，顺序对；/v1/state 里 B 的 term:pty:a 是最后那个状态。
#[tokio::test] async fn three_hundred_changes_leave_a_gap_row()
// 停服务期间 B 改 300 次（写 term.json 之间等 120 ms，确保 fake 的 watch 都发出来）；恢复后 /v1/queue 里有一行 t == "gap"、fp == B；B 的 IPC state 里 outbox.dropped == 100。
#[tokio::test] async fn no_text_in_any_log()
// 以上流程里 msg 用 "SECRET-TEXT"、会话名用 "secret-name"：A、B 的 service 日志目录下所有文件、A 的 rapp-state.log 都不含这两个串。
```
（`without_a_state_service_nothing_changes` 在 Task 9 已经有了，它就是验收的第三句。）

- [ ] **Step 2: 跑测试**

Run: `cargo test -p rapp-testkit --test state_p1 -- --test-threads=2`
Expected: PASS。若失败，按 superpowers:systematic-debugging 找原因，修在对应任务的文件里，并补一条能单独复现它的单元测试。

- [ ] **Step 3: 跑整个门禁**

Run: `cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings`
Expected: 全部 PASS、clippy 无警告

- [ ] **Step 4: Commit**

```bash
git add rust/testkit
git commit -m "test: rapp-state P1 acceptance across two devices"
```

---

### Task 13: 进安装包、文档、待办

**Files:**
- Modify: `scripts/package-macos.sh:33-34`（`-p rapp-state`）、`:44`（拷 `rust/target/release/rapp-state`）；`scripts/lib/sign-check.sh:5` 和 `scripts/test-package.sh:56`（`EXPECTED_IDS` 加 `rapp-state:com.rapp.state`，两处一致）；`scripts/build-linux.sh:27`（`-p rapp-state`）和 `:35`（循环加 `rapp-state`）；`scripts/package-linux.sh:173`（循环加 `rapp-state`）
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（新增 `local/services.json`、`local/state-sinks.json`、`<数据目录>/state/state.json` 三节，写字段、默认值、谁写谁读；§7 命令行加 `rapp state`；§8 打包加 `rapp-state`）、`docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`（`Share.kind` 和 `StateSink` 各一段，指向 rapp-state 规格 §7.2）、`tasks/todo.md`（加 rapp-state 四步：P1 已做待实机验收、P2–P4 待写计划；P2 要先问规格 §17 第 3–5 条，P3 问第 6 条；“纯服务器上开的状态服务要等 GUI 设备看过一次分享表”记为 P2 要解决的）
- Test: `scripts/test-package.sh`

- [ ] **Step 1: 改脚本，跑脚本自测**

Run: `bash scripts/test-package.sh`
Expected: 全部 ok（`expected ids` 那一项按新列表通过）

- [ ] **Step 2: 本机打一次 release 构建确认能编、看大小**

Run: `cd rust && cargo build --release -p rapp-state && ls -l target/release/rapp-state`
Expected: 构建成功；把大小记进 `tasks/todo.md` 的 P1 条目（规格 §18 第 4 条“hyper 进来以后安装包大多少”）。

- [ ] **Step 3: 写文档和待办**

`tasks/todo.md` 的 P1 实机验收写成可勾的清单：①两台真机，一台 `rapp state on`，另一台跑 Claude Code，`curl localhost:<分享号>/v1/queue` 有 working、blocked、done；②停服务期间 3 次变化恢复后补到；③纯服务器上 `rapp state on`，在 Mac 上 `rapp hosts` 一次后，别的设备的 `rapp state` 都看到它；④没开状态服务的网里，`rapp state` 显示发件箱没在发。

- [ ] **Step 4: Commit**

```bash
git add scripts docs tasks
git commit -m "build+docs: ship rapp-state; config reference, port sharing and todo for P1"
```

- [ ] **Step 5: 合并（主控在整条分支审完后做，实现这个任务的人不做）**

```bash
git merge main            # 在分支上先合 main，解决冲突后重跑 cargo test --workspace --no-fail-fast
cd /Users/bruce/git/rapp && git merge --no-ff feat/rapp-state-p1 -m "merge: rapp-state 第 1 步：服务和发件箱（feat/rapp-state-p1）"
```
合并前确认主 checkout 当前在 `main`。合并后不 push、不发版（发版 session 会接手）。
