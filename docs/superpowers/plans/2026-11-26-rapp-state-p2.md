# rapp-state P2（app 接入）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 网里有状态服务时，每台 rApp（Mac、Linux、iPad、Duo）的状态队列和“需要你”都从它来，先后到处一样，在一台上看过的会话在别台上不再是新的；连不上或关掉时一切照今天。

**Architecture:**
- `rapp-state` 加两个接口：`PUT /v1/seen` 记“看过”，`GET /v1/watch` 是 SSE 长连接，有变化就推一条。
- 接入点分平台找：
  - 桌面：本机 `rapp-service` 的 IPC `state` 回复多一个 `url`，它沿用 P1 的 sink 选择，远端的映射成 `localhost:<号>`。
  - iOS：内嵌 hub 的 `ports` 事件每项带 `kind`。
- GUI 新增 `lib/state/`，分三块：
  - `StateLink`：HTTP + SSE 客户端。
  - `StateConfig`：读写 `local/state.json`。
  - `StateSync`：找地址、连、重试、收推送、攒“看过”。
- `MainState` 拿 `StateSync` 改队列和“需要你”。

**Tech Stack:**
- Rust：hyper 1.x（已有），自己写一个基于 `mpsc` 的流式 body，不加新依赖。
- Dart：`dart:io` `HttpClient`，不加 pub 依赖。
- 测试：Rust 起真服务；Dart 用 `HttpServer.bind(loopback, 0)` 做假服务，`FakeTransport` 和注入的时钟。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-state-design.md`。重点看 §8.3 接口、§9 app 一侧、§15 P2、§16 GUI 测试、§17 第 3–5 条（2026-11-26 已定，含两条补问）。

## Global Constraints

- **分支与合并**
  - 在 worktree `.worktrees/rapp-state-p2`、分支 `feat/rapp-state-p2` 上做。
  - 完成后照 `CLAUDE.md` 合并到本机 `main`，提交信息 `merge: rapp-state 第 2 步：app 接入（feat/rapp-state-p2）`。
  - 不改版本号、不打 tag、不 push、不发版。`Cargo.lock`、`pubspec.yaml` 不变；跑完 flutter 测试后还原 `gui/pubspec.lock`。
- **不加依赖**：Rust 和 Dart 都不加新依赖；`rapp-state` 仍不依赖任何 `rapp-*` crate。
- **`PUT /v1/seen`**
  - 正文只认 `{"fp":"…","session":"…"}` 或 `{"eid":"…"}`，可选 `"handled":true`。
  - 回复：成功 204；对象不存在 404 `{"error":"unknown session"}` 或 `{"error":"unknown eid"}`；其他 400 `{"error":"bad request"}`。
  - 时间用服务自己的钟（Unix 秒）。
- **`GET /v1/watch`**
  - 回复头 `content-type: text/event-stream`。
  - 一开始先发 `data: {"what":"hello"}\n\n`，之后每 **15** 秒发一行 `: ping\n\n`。
  - 每条变化是 `data: <一行 JSON>\n\n`，`what` ∈ `session`、`queue`、`need`、`seen`。
  - 跟不上（broadcast 溢出，容量 **256**）就断开，客户端重连后重取全貌。
- **变化的形状**
  - `{"what":"session","fp","session","row":{…}|null}`：`null` 表示没了。
  - `{"what":"queue","row":{…}}`：和 `/v1/queue` 的一行相同。
  - `{"what":"need","needs":[…]}`：整份，和 `/v1/state` 的 `needs` 相同。
  - `{"what":"seen","fp","session","at"}` 或 `{"what":"seen","eid","at","handled"?}`。
- **GUI 客户端**
  - 超时：连接 **5** 秒；`watch` **45** 秒没收到任何东西（含 ping）就算断了。
  - 重试间隔 2、4、8、16、32、**60** 秒封顶。
  - 一页队列取 **50** 条；服务来的队列行内存里最多 **200** 条（按 `eid` 去重）；没发出去的“看过”最多攒 **200** 条（丢最旧）。
- **`local/state.json`**
  - 三种写法：`{"mode":"auto"}`、`{"mode":"off"}`、`{"mode":"manual","url":"http://…"}`。
  - 缺文件、坏文件、不认识的 `mode` 都按 `auto` 处理。
  - 写入用 `writePrivate`（0600）。
- **面向用户的文字**（逐字照抄）
  - 设置块标题 `状态服务`；三个选项 `自动`、`关`、`手填地址`。
  - 状态行：`已连上`、`连不上`、`没找到状态服务`、`已关`。
  - 手填地址不对时提示 `地址要以 http:// 或 https:// 开头`。
  - 队列里的中断行 `状态服务连不上，先用本机的`。
  - 灰掉的行写 `设备离线` 或 `已断开`。
  - 缺口行 `<设备名> 有一段状态没收到`。
- **反目标**
  - 模式 `关`，或者 `自动` 没找到服务时：不开任何连接，队列和“需要你”与今天逐项相同（`MainState` 不传 `StateSync` 时也一样）。
  - 事件文字（`msg`、`title`、`name`）不进 GUI 日志和服务日志。
- **门禁**
  - Rust（在 `rust/` 下）：`cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`。cargo 在 `$HOME/.cargo/bin`。
  - Dart（在 `gui/` 下）：`~/development/flutter/bin/flutter analyze`、`flutter test`。
  - 碰到 `gui/ios/` 或 hub-ffi 时，照 `scripts/build-ios.sh` 编一次 iOS（不装机）。
- **语言**：面向用户的文字用中文；代码、注释、日志事件名用英文。

## Review Focus

1. **iOS 进后台再回来**：后台时 watch 关掉。回前台要重取 `/v1/state` 和一页队列，再开 watch，队列里不能出现重复行。测试在 Task 7。
2. **服务重启（epoch 变、watch 断开）期间到的行**：重连后重取一页，`eid` 去重。之后 watch 推来的、已经在页里的行不重复出现。测试在 Task 5。
3. **同一台设备 Mac 上本机算了、服务也有**：“需要你”里只出现一项，用服务的 `since` 排序。测试在 Task 8。
4. **手填一个不是状态服务的地址**（例如 rapp-llm 的 8101）：`/v1/health` 不对，算“连不上”。不开 watch，队列只记一行中断。测试在 Task 5。
5. **没有 `id` 的设备**（纯服务器没 relay）、或这台 app 的设备表里没有的设备：它的“需要你”不加进来。它的队列行照常显示，但点不了（`goes` 为假）。测试在 Task 8。

---

## File Structure

```
services/state/
  src/store.rs        Row.seen、Queued.seen/handled；mark_seen；changes 缓冲
  src/http.rs         PUT /v1/seen；GET /v1/watch（SSE）；broadcast；SseBody
  api/http.md         两个新接口和 watch 的推送格式
  tests/http.rs       seen、watch 的真 HTTP 测试
rust/
  service/src/companion.rs   IPC state 回复加 url
  hub/src/ports.rs           ports 事件每项带 kind
gui/lib/
  state/state_link.dart      新：health/state/queue/seen + watch（SSE 解析）
  state/state_config.dart    新：local/state.json
  state/state_sync.dart      新：找地址、连、重试、推送、看过缓冲、status
  hub_client.dart            ports 事件 → portMaps
  service_client.dart        ServiceMonitor.stateUrl()
  ui/main_state.dart         queueRows、needs 合并、offlineWord、看过、前后台
  ui/hint_history.dart       用 queueRows；新行加粗、灰行
  ui/needs_you.dart          灰行不可点
  pages/state_section.dart   新：设置里“状态服务”一块
  pages/global_sections.dart 放进 StateSection
  main.dart, main_ios.dart   建 StateSync，传给 MainState 和设置页
gui/test/
  state/state_link_test.dart, state/state_config_test.dart, state/state_sync_test.dart
  ui/main_state_test.dart（加组）, ui/needs_you_test.dart, ui/hint_history_test.dart（有就加，没有就新建）
  pages/state_section_test.dart
docs/superpowers/specs/2026-11-25-rapp-status-queue-design.md、2026-11-13-rapp-config-reference.md、
  2026-11-20-rapp-app-port-maps-design.md、tasks/todo.md
```

---

### Task 1: `rapp-state` 记“看过”（`PUT /v1/seen`）

**Files:**
- Modify: `services/state/src/store.rs`, `services/state/src/http.rs`, `services/state/api/http.md`
- Test: `services/state/src/store.rs`（tests 模块）、`services/state/tests/http.rs`

**Interfaces:**
- Produces:
  - `Row` 加 `#[serde(default)] seen: Option<u64>`。`put_row` 换掉一行时保留旧的 `seen`；`gone` 删掉会话时跟着删。
  - `Queued` 加 `#[serde(default)] seen: Option<u64>` 和 `#[serde(default)] handled: bool`。`trim`、`expire` 照旧整行删。
  - `pub enum Look<'a> { Session { fp: &'a str, session: &'a str }, Eid(&'a str) }`
  - `pub fn mark_seen(&mut self, look: Look, handled: bool, now: u64) -> Result<(), &'static str>`：错误值就是 `"unknown session"` 或 `"unknown eid"`。
  - 输出：`state()` 里每个会话行有 `seen` 时带上 `"seen": <秒>`。`queue()` 的行有 `seen` 时带 `"seen"`，`handled` 为真时带 `"handled": true`。
  - `handled` 在 P2 只是存起来；P4 有 `ask` 以后再拿它算“需要你”。

- [ ] **Step 1: 写失败的测试**（store）

```rust
#[test]
fn seen_sticks_to_the_session_and_survives_a_new_state() {
    let mut s = st();
    // 用 samples/term-events.ndjson 的第一条（fp "fpA"，session 取那一行的值）
    feed(&mut s, include_str!("../api/samples/term-events.ndjson"), 1);
    let (fp, sid) = first_session(&s);               // 帮手：state() 里第一个会话的 (fp, session)
    s.mark_seen(Look::Session { fp: &fp, session: &sid }, false, 500).unwrap();
    assert_eq!(session_row(&s, &fp, &sid)["seen"], 500);
    feed_one(&mut s, &fp, &sid, "working", 600);   // 帮手：同一会话一条新的 state
    assert_eq!(session_row(&s, &fp, &sid)["seen"], 500);
    assert_eq!(s.mark_seen(Look::Session { fp: "nope", session: &sid }, false, 1), Err("unknown session"));
}

#[test]
fn seen_and_handled_mark_a_queue_row() {
    let mut s = st();
    feed(&mut s, include_str!("../api/samples/term-events.ndjson"), 2);
    let eid = s.queue(None, 1).unwrap()["events"][0]["eid"].as_str().unwrap().to_string();
    s.mark_seen(Look::Eid(&eid), true, 700).unwrap();
    let row = &s.queue(None, 1).unwrap()["events"][0];
    assert_eq!((row["seen"].as_u64(), row["handled"].as_bool()), (Some(700), Some(true)));
    assert_eq!(s.mark_seen(Look::Eid("x:y:1"), false, 1), Err("unknown eid"));
}
```

`tests/http.rs` 加一个帮手 `async fn put(addr, path, body: &str) -> (u16, Option<Value>)`。测试：

```rust
#[tokio::test]
async fn seen_answers_204_404_400() {
    let addr = start(Config::default()).await;
    post_sample(addr).await;   // 已有的帮手：POST samples/term-events.ndjson
    let (fp, sid) = first_session_over_http(addr).await;
    assert_eq!(put(addr, "/v1/seen", &json!({"fp": fp, "session": sid}).to_string()).await.0, 204);
    assert!(get(addr, "/v1/state").await.1["devices"][0]["sessions"].as_array().unwrap().iter().any(|r| r["seen"].is_u64()));
    assert_eq!(put(addr, "/v1/seen", r#"{"fp":"zz","session":"zz"}"#).await, (404, Some(json!({"error":"unknown session"}))));
    assert_eq!(put(addr, "/v1/seen", r#"{"eid":"a:b:9"}"#).await, (404, Some(json!({"error":"unknown eid"}))));
    assert_eq!(put(addr, "/v1/seen", r#"{"what":1}"#).await, (400, Some(json!({"error":"bad request"}))));
    assert_eq!(get(addr, "/v1/seen").await.0, 405);
}
```

（405 走 `route` 已有的“方法不对”分支，回复体照现有写法。若现有分支回的不是 405，以现有的为准并改这一行断言。）

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-state`
Expected: 编译失败（没有 `mark_seen` / `Look`）

- [ ] **Step 3: 实现**
  - store：实现 `mark_seen`。
  - http：`route` 加 `"/v1/seen" => &Method::PUT`。正文用现有的 `Limited`（`MAX_BODY`）读，解析成 `Value`：有 `eid` 字符串走 `Look::Eid`；有 `fp` 和 `session` 字符串走 `Look::Session`；别的回 400。
  - 成功后 `mark(&dirty)` 存盘，日志 `seen {by:"session"|"eid"}`，不带 id。
  - `api/http.md` 加 `PUT /v1/seen` 一节，写请求、回复和 `state`/`queue` 里新出现的 `seen`、`handled` 字段。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-state && cargo clippy -p rapp-state --all-targets -- -D warnings`
Expected: PASS，无警告

- [ ] **Step 5: 提交**

```bash
git add services/state && git commit -m "feat(state): PUT /v1/seen marks a session or a queue row seen"
```

### Task 2: `rapp-state` 推变化（`GET /v1/watch`，SSE）

**Files:**
- Modify: `services/state/src/store.rs`, `services/state/src/http.rs`, `services/state/api/http.md`
- Test: `services/state/src/store.rs`、`services/state/tests/http.rs`

**Interfaces:**
- Consumes: Task 1 的 `mark_seen`
- Produces:
  - store 加 `#[serde(skip)] changes: Vec<Value>` 和 `pub fn take_changes(&mut self) -> Vec<Value>`（取出并清空）。
  - 谁往里放：
    - `apply` 每改一个会话放一条 `session`（`gone` 放 `row: null`；`snap` 对替换掉的每个会话放 `null`，对新放进去的每个放它的行）。
    - 每进一行队列放一条 `queue`。
    - `needs` 前后不同时放一条 `need`：`apply` 前后各算一次 `state()["needs"]` 来比。
    - `mark_seen` 放一条 `seen`。
    - `expire` 删掉设备或会话时，对每个删掉的会话放 `session`/`null`，`needs` 变了也放 `need`。
  - 形状照 Global Constraints “变化的形状”。
  - http：
    - 服务里有一个 `tokio::sync::broadcast::Sender<String>`（容量 256）。`post_events`、`PUT /v1/seen`、清理任务在改完 store、放开锁以后，把 `take_changes()` 的每条序列化后 `send`。
    - 回复体类型从 `Full<Bytes>` 换成 `http_body_util::combinators::BoxBody<Bytes, Infallible>`，普通 JSON 回复用 `Full::new(..).boxed()`。
  - `struct SseBody(tokio::sync::mpsc::Receiver<Bytes>)` 实现 `hyper::body::Body`：`poll_frame` 用 `poll_recv`，收到就给 `Frame::data`，通道关了返回 `None`。
  - 每个 watch 连接一个任务，干这几件事：
    1. 先发 hello。
    2. 之后 `select!` 三件事：broadcast 来一条就转一条；每 15 秒发一次 ping；mpsc 发不出去（客户端走了）就结束。
    3. `RecvError::Lagged` 时也结束。
  - 日志：开时记 `watch_open {watching:n}`，结束时记 `watch_closed {watching:n, lagged:bool}`。

- [ ] **Step 1: 写失败的测试**（store）

```rust
#[test]
fn changes_name_what_moved() {
    let mut s = st();
    feed(&mut s, include_str!("../api/samples/term-events.ndjson"), 1);
    let ch = s.take_changes();
    let whats: Vec<&str> = ch.iter().map(|c| c["what"].as_str().unwrap()).collect();
    assert!(whats.contains(&"session") && whats.contains(&"queue"));
    assert!(s.take_changes().is_empty());
    // 一条 blocked 进来 → 有 need，且 needs 等于 state()["needs"]
    feed_one(&mut s, "fpA", "t9", "blocked", 900);
    let need = s.take_changes().into_iter().find(|c| c["what"] == "need").unwrap();
    assert_eq!(need["needs"], s.state()["needs"]);
    // gone → session/null
    feed_gone(&mut s, "fpA", "t9", 901);
    assert!(s.take_changes().iter().any(|c| c["what"] == "session" && c["session"] == "t9" && c["row"].is_null()));
}
```

`tests/http.rs` 加一个帮手 `async fn watch(addr) -> tokio::sync::mpsc::Receiver<Value>`：发 `GET /v1/watch` 请求，读回复头，然后逐行读，把 `data: ` 行解析后送进通道，跳过 `:` 开头的行。回复是 chunked，帮手要拆 chunk，或者先读到 `\r\n\r\n` 再按行找 `data: `。

```rust
#[tokio::test]
async fn watch_says_hello_then_pushes_changes() {
    let addr = start(Config::default()).await;
    let mut w = watch(addr).await;
    assert_eq!(recv(&mut w).await["what"], "hello");          // recv：2 秒超时
    post_sample(addr).await;
    let mut whats = vec![];
    while let Ok(Some(v)) = tokio::time::timeout(Duration::from_millis(500), w.recv()).await { whats.push(v["what"].as_str().unwrap().to_string()); }
    assert!(whats.iter().any(|w| w == "queue") && whats.iter().any(|w| w == "session"));
    let (fp, sid) = first_session_over_http(addr).await;
    put(addr, "/v1/seen", &json!({"fp": fp, "session": sid}).to_string()).await;
    let seen = recv(&mut w).await;
    assert_eq!((seen["what"].as_str(), seen["session"].as_str()), (Some("seen"), Some(sid.as_str())));
}

#[tokio::test]
async fn a_closed_watch_is_let_go() {
    // 开 3 个 watch 再全部 drop，等 200ms；服务日志（serve_with_log 注入的 Log）里最后一条 watch_closed 的 watching 为 0
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-state`
Expected: 编译失败（没有 `take_changes`）

- [ ] **Step 3: 实现**（照 Interfaces）。`api/http.md` 加 `GET /v1/watch` 一节：hello、ping 间隔、四种 `what` 的样例各一行，以及“断开后请重取 `/v1/state` 和 `/v1/queue`”。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-state && cargo clippy -p rapp-state --all-targets -- -D warnings`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add services/state && git commit -m "feat(state): GET /v1/watch pushes session, queue, need and seen changes"
```

### Task 3: 接入地址——本机服务给 `url`，iOS hub 的 `ports` 带 `kind`

**Files:**
- Modify: `rust/service/src/companion.rs`, `rust/hub/src/ports.rs`, `docs/superpowers/specs/2026-11-20-rapp-app-port-maps-design.md`（`ports` 事件那一段加 `kind`）
- Test: 同文件的 tests 模块

**Interfaces:**
- Produces:
  - `companion.rs`：`pub(crate) fn sink_url(chosen: Option<&Dest>, local_of: impl Fn(&str, u16) -> Option<u16>) -> Option<String>`，按 `chosen` 分三种：
    - `Dest::Local(p)` → `http://127.0.0.1:<p>`
    - `Dest::Remote{id,port}` → `local_of(id,port)` 有值就是 `http://localhost:<n>`，没有就是 `None`
    - `None` → `None`
  - `status()` 先取 chosen 的 sink：远端的先调 `crate::maps::ensure_all(state, id, &[(port, None)])` 确保映射，再用 `state.maps.list()` 找 `m.id==id && m.port==port` 的 `m.local`，算出 `url`。回复里加 `"url": <字符串或 null>`。
  - `hub/src/ports.rs`：
    - `HubPorts` 加 `kinds: Mutex<HashMap<(String, u16), String>>`。`ask_all` 收到一台的分享表时，用表里各项的 `port` 和 `kind` 重写这台的那几项（没 `kind` 的不记）。
    - `pub(crate) fn told(maps: &[Map], kinds: &HashMap<(String, u16), String>) -> Vec<Value>`：每项 `{"id","port","local"}`，有 kind 时加 `"kind"`。
    - `told` 字段改成 `Mutex<Option<Vec<Value>>>`，用 `told(...)` 的结果比较是否要再发，所以只是 kind 变了也会发。
- 决定：P2 不让 `list_apps` 带出状态服务（规格 §7.2 留的问题）。理由：
  - iPad 的 hub 每 60 秒问各设备的分享表，自己就能看到纯服务器上的状态服务。
  - 桌面只要有一台设备看过一次那台的分享表，就会经 `StateSink` 传开。
  - 代价：网里只有桌面设备、又没人看过纯服务器的分享表时，桌面的“自动”找不到。这一条留在 `tasks/todo.md`。

- [ ] **Step 1: 写失败的测试**

```rust
// companion.rs
#[test]
fn sink_url_points_at_the_local_port_or_the_map() {
    assert_eq!(sink_url(Some(&Dest::Local(8102)), |_, _| None).as_deref(), Some("http://127.0.0.1:8102"));
    let r = Dest::Remote { id: "222".into(), port: 8102 };
    assert_eq!(sink_url(Some(&r), |id, p| (id == "222" && p == 8102).then_some(28003)).as_deref(), Some("http://localhost:28003"));
    assert_eq!(sink_url(Some(&r), |_, _| None), None);
    assert_eq!(sink_url(None, |_, _| Some(1)), None);
}
// ports.rs
#[test]
fn told_maps_carry_kind_when_known() {
    let maps = vec![Map { id: "222".into(), port: 8102, local: 28003, wanted: None }, Map { id: "222".into(), port: 3000, local: 28000, wanted: None }];
    let kinds = HashMap::from([(("222".to_string(), 8102), "state".to_string())]);
    assert_eq!(told(&maps, &kinds), vec![
        json!({"id":"222","port":8102,"local":28003,"kind":"state"}),
        json!({"id":"222","port":3000,"local":28000}),
    ]);
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-service sink_url && cargo test -p rapp-hub told_maps`
Expected: 编译失败

- [ ] **Step 3: 实现**（照 Interfaces）。若 `Dest` 不是 `pub(crate)` 可见，就在 `sink.rs` 里放宽可见性，不复制类型。

- [ ] **Step 4: 跑门禁**

Run: `cd rust && cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings`
Expected: PASS（testkit 里断言整行 IPC `state` 回复的测试如果因为多了 `url` 失败，就改那条断言加上 `url`）

- [ ] **Step 5: 提交**

```bash
git add rust docs && git commit -m "feat(service,hub): state service address for apps (IPC url, ports kind)"
```

### Task 4: Dart 客户端 `StateLink`

**Files:**
- Create: `gui/lib/state/state_link.dart`
- Test: `gui/test/state/state_link_test.dart`

**Interfaces:**
- Produces:
  - `class StateLink { StateLink(this.base, {Duration connect = const Duration(seconds: 5), Duration idle = const Duration(seconds: 45)}); final Uri base; }`
  - `Future<bool> health()`：`GET /v1/health` 回 200，且正文 `name == 'rapp-state'`，才为真；其他情况（含异常）都是假，从不抛。
  - `Future<Map<String, Object?>> state()`
  - `Future<Map<String, Object?>> queue({String? before, int limit = 50})`
  - `Future<void> seen({String? fp, String? session, String? eid, bool handled = false})`：非 2xx 时抛 `StateLinkError(status)`。
  - `Stream<Map<String, Object?>> watch()`
    - 解析 SSE：`data:` 行累积，遇到空行发出一条；`:` 开头的行只用来重置空闲计时，不发出。
    - `idle` 时间内什么都没收到，流以 `StateLinkError(0)` 结束；服务关连接时流正常结束。
    - 取消订阅时 `close(force: true)`。
  - `void close()`：关掉所有进行中的请求。
  - `class StateLinkError implements Exception { final int status; }`：网络错误、超时、坏 JSON 时 `status = 0`。
  - 普通请求（`health`、`state`、`queue`、`seen`）整体限时 `connect + idle`（默认 50 秒），连接本身限时 `connect`（5 秒）。

- [ ] **Step 1: 写失败的测试**（假服务：`HttpServer.bind(InternetAddress.loopbackIPv4, 0)`，按路径回写）

```dart
test('health is true only for rapp-state', () async { /* 回 {"name":"rapp-state","v":1} → true；{"name":"x"} → false；关掉的端口 → false */ });
test('state and queue pass before and limit', () async { /* 断言收到的 query 是 before=a%3Ab%3A1&limit=50 */ });
test('seen sends the body and throws on 404', () async { /* 正文 {"fp":"f","session":"s"}；404 → StateLinkError(404) */ });
test('watch yields data lines and skips pings', () async {
  // 服务写 ': ping\n\n' 'data: {"what":"hello"}\n\n' 'data: {"what":"queue","row":{"eid":"a:b:1"}}\n\n' 再 close
  expect(await link.watch().toList(), [{'what': 'hello'}, {'what': 'queue', 'row': {'eid': 'a:b:1'}}]);
});
test('a silent watch ends with an error after idle', () async { /* idle: 200ms；服务只发 hello 不再写 → emitsError(isA<StateLinkError>()) */ });
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/state/state_link_test.dart`
Expected: FAIL（文件不存在）

- [ ] **Step 3: 实现**。照 `lib/llm_api.dart` 的 `HttpClient` 写法：`connectionTimeout`、`.timeout`、`finally close`。`watch` 用 `res.transform(utf8.decoder).transform(const LineSplitter())`。

- [ ] **Step 4: 跑测试，确认通过**

Run: 同 Step 2
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add gui/lib/state gui/test/state && git commit -m "feat(gui): StateLink, the rapp-state HTTP and SSE client"
```

### Task 5: `StateConfig` 和 `StateSync`

**Files:**
- Create: `gui/lib/state/state_config.dart`, `gui/lib/state/state_sync.dart`
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（加 `local/state.json`）
- Test: `gui/test/state/state_config_test.dart`, `gui/test/state/state_sync_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `StateLink`
- Produces:
  - `enum StateMode { auto, off, manual }`
  - `class StateConfig`
    - 构造：`const StateConfig(this.mode, {this.url = ''})`
    - `static StateConfig load(String localDir)`：读 `local/state.json`，照 Global Constraints 的兜底。
    - `void save(String localDir)`：用 `writePrivate`。
    - `static String? checkUrl(String s)`：合法回 `null`，否则回 `地址要以 http:// 或 https:// 开头`。
  - `enum StateStatus { off, none, connecting, connected, unreachable }`
  - `class StateSync extends ChangeNotifier`
    - 构造：`StateSync({required String localDir, required Future<String?> Function() find, StateLink Function(Uri)? link, DateTime Function()? clock})`
    - `find` 是平台给的“自动”找法，返回 URL 或 `null`。
    - `link` 是测试注入点。
  - 字段和 getter：
    - `StateConfig config`
    - `StateStatus status`
    - `Uri? url`
    - `List<Map<String, Object?>> rows`：服务来的队列行，新的在前，按 `eid` 去重，最多 200 条。
    - `List<Map<String, Object?>> needs`
    - `Map<String, Object?>? session(String fp, String id)`：`/v1/state` 里那个会话的行，含 `seen`。
    - `String? fpOf(String deviceId)`：从 `devices[].id` 对到 `fp`。
    - `String? idOf(String fp)`
    - `int outage`：每进入一次 `unreachable` 加 1，`MainState` 用它“一次中断只记一行”。
  - 方法：
    - `Future<void> setConfig(StateConfig c)`：存盘，然后重连。
    - `void start()`
    - `Future<void> refresh()`：前台回来时调。
    - `void pause()`：后台时调，关 watch，status 不变。
    - `void markSeen(String deviceId, String session)`：按（设备 id, 会话）攒着（最多 200 条，丢最旧；同一会话只留一条），连上以后按顺序补发，发的时候才对 `fp`；那时还对不上（全貌里没有这台设备，也不在重取）就丢掉。（终审 M1/M3 改过：原来记下时就对 `fp`，连上前记的全丢。）
    - `bool fresh(Map<String, Object?> row)`：行的 `session` 在 `session(fp, …)` 里有，并且行的 `at` 大于那一行的 `seen ?? 0`。
    - `void dispose()`
  - 连接步骤（`_connect`）：
    1. `off` 时 status 为 `off`，结束。
    2. `manual` 用 `config.url`；`auto` 调 `find()`，得到 `null` 时 status 为 `none`，并在 60 秒后再找一次。
    3. status 设为 `connecting`。
    4. `health()` 为假就进 `unreachable`，按 2…60 秒退避后回到第 1 步。
    5. 开 `watch()`。收到 hello 后取 `state()` 和 `queue(limit: 50)`，这期间的推送先攒着。队列整页替换掉 `rows` 里比这页最旧一条更新的部分，再按 `eid` 去重。（终审 I2 改过：原来是先取再开 watch，中间的变化会丢。）
    6. 全貌放好后按顺序补上攒着的推送，status 设为 `connected`，补发攒着的“看过”。
    7. 推送的处理：
       - `session`：更新那个会话的行。
       - `queue`：去重后插到 `rows` 最前。
       - `need`：整份替换 `needs`。
       - `seen`：更新那个会话行的 `seen`。
       - 每条处理完 `notifyListeners`。
    8. watch 出错或结束就进 `unreachable`，退避后重连（重连从第 1 步开始）。
  - `StateSync` 不打印事件文字，只用 `debugPrint` 记状态切换（`state_sync: connected` 这类）。

- [ ] **Step 1: 写失败的测试**

`state_config_test.dart`：缺文件得 `auto`；`{"mode":"manual","url":"http://x:1"}` 往返不变；坏 JSON 得 `auto`；`{"mode":"weird"}` 得 `auto`；`checkUrl('ftp://x')` 回提示语；`checkUrl('http://localhost:8102')` 回 `null`；存的文件权限是 0600（照现有 `writePrivate` 的测试写法）。

`state_sync_test.dart` 用一个假的 `StateLink` 子类，各方法由测试控制，watch 用 `StreamController`；时钟注入：

```dart
test('off and none open no link', () async { /* off: 没调用过 link 工厂；auto + find→null: status none，link 工厂未调用 */ });
test('connect fetches state and a queue page, then watches', () async {
  // health→true, state→{devices:[{fp:'F',id:'111',sessions:[{session:'t1',seen:100}]}],needs:[]}, queue→{events:[{eid:'F:e:2',at:200,session:'t1',fp:'F'},{eid:'F:e:1',at:50,session:'t1',fp:'F'}]}
  // watch 推 hello → status connected；fpOf('111')=='F'；fresh(eid 2 的行)==true，fresh(eid 1)==false
});
test('a pushed queue row already in the page is not added twice', () async { /* push {what:queue,row:{eid:'F:e:2',…}} → rows.length 仍为 2 */ });
test('a wrong health is unreachable and retries with backoff', () async {
  // fakeAsync：health→false；status unreachable，outage==1；2s 后第二次 health；再 4s 第三次；一直失败时 outage 仍为 1
});
test('seen while unreachable is kept and sent on reconnect, at most 200', () async {
  // 断开时 markSeen 201 次 → 连上后 seen 调用 200 次，第一次是第 2 条
});
test('refresh refetches and a watch error goes unreachable then reconnects', () async { /* … */ });
test('setConfig saves and reconnects to the manual url', () async { /* link 工厂收到的 Uri == 手填的 */ });
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/state/`
Expected: FAIL

- [ ] **Step 3: 实现**（照 Interfaces）。配置规范总览加 `local/state.json` 一节：路径、三种写法、兜底、谁读谁写。

- [ ] **Step 4: 跑测试，确认通过**

Run: 同 Step 2
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add gui/lib/state gui/test/state docs && git commit -m "feat(gui): StateSync finds, connects to and follows rapp-state"
```

### Task 6: 状态队列从服务来

**Files:**
- Modify: `gui/lib/ui/main_state.dart`, `gui/lib/ui/hint_history.dart`, `docs/superpowers/specs/2026-11-25-rapp-status-queue-design.md`（§2 加一句“连着状态服务时程序状态行从服务来”）
- Test: `gui/test/ui/main_state_test.dart`（新组 `state service queue`）、`gui/test/ui/hint_history_test.dart`

**Interfaces:**
- Consumes: Task 5 的 `StateSync`（`status`、`rows`、`fresh`、`session`、`idOf`、`outage`、`markSeen`）
- Produces:
  - `MainState` 构造参数加 `StateSync? stateSync`。构造里 `addListener(_onStateSync)`，`dispose` 里移除。
  - `HintRecord` 加 `final bool term`（`_trackPrograms` 写真）和 `final String? eid`（服务行）。
  - `bool get _fromService => stateSync?.status == StateStatus.connected`
  - `_trackPrograms`：照旧更新 `_psSeen`，但 `_fromService` 时不调 `_queue`。
  - `List<HintRecord> get queueRows`：
    - 不是 `_fromService` 时，就是 `hintHistory`。
    - 是的时候：`hintHistory.where((r) => !r.term)` 加上 `stateSync.rows.map(_serviceRow).whereType<HintRecord>()`，按 `at` 新的在前排，取前 `hintHistoryMax` 条。
  - `HintRecord? _serviceRow(Map row)`，按行的 `t` 分：
    - `state`：建一个 `TermPs(row.state, kind:, app:, msg:, seq:)`。`title = termDisplayName(row.title ?? row.name, row.host)`。设备 id 用 `row.id ?? stateSync.idOf(row.fp)`，名字用 `deviceName(id)`，没 id 时用 `row.device`。
      - 文字 `'$title @ $名字：${programWord(ps)}'`，`lamp: programLamp(ps)`。
      - 只有 id 在 `hub.hosts` 里时才带 `device`、`app: row.session`，这样 `goes` 为真。
      - `at = DateTime.fromMillisecondsSinceEpoch(row.at * 1000)`，`eid: row.eid`。
    - `gap`：文字 `'<名字> 有一段状态没收到'`，没有灯。
    - `gone` 和其他：返回 `null`。
  - `String? offlineWord(String device, String termId)`：
    - 设备在 `_offlineSince` 里，或 `probes[device]?.lamp == Lamp.offline`，返回 `'设备离线'`。
    - 这台 app 有那个终端的会话记录，而且它的 `phase == Phase.disconnected`，返回 `'已断开'`。
    - 其他返回 `null`。
  - `bool queuedFresh(HintRecord r)`：`r.eid` 不为空时，看 `stateSync.fresh` 对它那一行的结果；否则为假。
  - `goToQueued`：`offlineWord(...) != null` 时什么也不做。
  - 中断行：`_onStateSync` 里，`status == unreachable` 且 `outage` 比上次记下的大，就 `_queue(HintRecord('状态服务连不上，先用本机的', _now()))`，并记下这个 `outage`。
  - `hint_history.dart`：
    - 用 `state.queueRows`。
    - `queuedFresh` 的行，文字用 `FontWeight.w600`，语义标签末尾加 `，新`。
    - `offlineWord` 不为空的行：文字颜色 `t.muted`，末尾加 `' · <词>'`，不包 `InkWell`（不可点）。

- [ ] **Step 1: 写失败的测试**（`main_state_test.dart` 照现有 setup；`StateSync` 用一个测试用子类或假对象，能直接设 `status`、`rows`，再 `notifyListeners()`）

```dart
test('connected: program rows come only from the service', () async {
  // hub.termLists['111'] 给一台 blocked 终端，先 _onHub 一次做基线，再换成 working → 本来会进一行
  // sync.status = connected，rows = [{t:'state',eid:'F:e:1',fp:'F',id:'111',session:'t1',name:'rapp',state:'working',at:100}]
  // 断言：queueRows 里程序行恰好 1 条，eid == 'F:e:1'，没有 term==true 的行；文字以 'rapp @ mini：' 开头
});
test('own hint lines stay and sort in with service rows', () async { /* s.say('a') 后 queueRows 含 'a' 和服务行，按 at 排 */ });
test('unreachable: back to local rows and one outage line', () async {
  // status: connected → unreachable(outage 1) → unreachable 再 notify 一次 → 'connecting' → unreachable(outage 2)
  // hintHistory 里 '状态服务连不上，先用本机的' 恰好 2 条；queueRows == hintHistory
});
test('a row from an offline device is grey and does not go', () async {
  // _setOnline('111', true) 后 false；offlineWord('111','t1') == '设备离线'；goToQueued 不调 openOrSwitch
});
test('gap rows read 有一段状态没收到 and gone rows are not shown', () async { /* … */ });
test('without a StateSync nothing changes', () async { /* 现有 hintHistory 测试的场景，queueRows == hintHistory */ });
```

`hint_history_test.dart`（widget）：新行字重是 w600，语义标签以 `，新` 结尾；灰行文字以 ` · 设备离线` 结尾，没有 `Key('queue-0')` 可点。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/main_state_test.dart test/ui/hint_history_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**（照 Interfaces），再改状态队列设计 §2 那一句。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
Expected: 全部 PASS，analyze 无问题

- [ ] **Step 5: 提交**

```bash
git add gui docs && git commit -m "feat(gui): status queue rows come from rapp-state when connected"
```

### Task 7: 看过、前后台

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/main_state_test.dart`（同一组）

**Interfaces:**
- Consumes: Task 5 的 `markSeen`、`refresh`、`pause`；Task 6 的 `_fromService`
- Produces:
  - 当前会话变成一个文字终端时，调 `stateSync?.markSeen(device, termId)`。这包括 `select`、`openOrSwitch`、`_focusNewTerm`、`focusCurrent` 走到的地方。实现方式：在 `currentKey` 变化的那个地方集中判断一次，并且主窗口要看得见，不要在每个入口各写一遍。
  - 服务推来一行，它的 `session` 正是当前会话、主窗口看得见时，再 `markSeen` 一次，这样正在看的会话不显示成新行。
  - `enterBackground` 调 `stateSync?.pause()`；`enterForeground` 调 `stateSync?.refresh()`。

- [ ] **Step 1: 写失败的测试**

```dart
test('opening a terminal marks it seen with the service', () async { /* openOrSwitch('111','t1','rapp') → sync.seenCalls == [('111','t1')] */ });
test('a pushed row for the shown terminal is marked seen again', () async { /* … */ });
test('background pauses and foreground refreshes the state service', () async { /* enterBackground → pauseCalls 1；enterForeground → refreshCalls 1 */ });
test('a GUI app session is never sent as seen', () async { /* 非终端会话被选中 → seenCalls 为空 */ });
```

- [ ] **Step 2: 跑测试，确认失败** — Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/main_state_test.dart` / Expected: FAIL
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试，确认通过** — Run: `cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze` / Expected: PASS
- [ ] **Step 5: 提交** — `git commit -am "feat(gui): tell rapp-state what was seen; pause it in the background"`

### Task 8: “需要你”合并服务的

**Files:**
- Modify: `gui/lib/ui/main_state.dart`, `gui/lib/ui/needs_you.dart`
- Test: `gui/test/ui/main_state_test.dart`（新组 `state service needs`）、`gui/test/ui/needs_you_test.dart`

**Interfaces:**
- Consumes: Task 5 的 `needs`、`session`、`idOf`；Task 6 的 `offlineWord`
- Produces:
  - `NeedItem` 加 `final int at`（Unix 秒，排序用）和 `final String? greyWord`。
  - `needs` 的排序改成 `at` 降序，同秒再按 `seq` 降序。
  - 每一项的 `at` 来自 `_needAt: Map<String,int>`：同 `_termNeedSeq` 的 key，用 `putIfAbsent(key, () => _now().millisecondsSinceEpoch ~/ 1000)` 填，用同样的办法修剪。
  - 会话断开、设备离线这两种也要有 key，分别是 `'sess\n${r.key}'` 和 `'dev\n$id'`。
  - 本机现算的终端项：服务的 `needs` 里有同一个 `(id, session)` 时，`at` 用服务的 `since`。
  - 先定“本机现算的设备”：`L = hub.termLists 的键 − _offlineSince 的键`。服务的每一项 `n` 照下面处理：
    1. `id = n.id ?? stateSync.idOf(n.fp)`。`id` 为空，或者不在 `hub.hosts` 里，就跳过。
    2. `id` 在 `L` 里也跳过，本机算的更新。
    3. 其余的加一项 `NeedKind.terminal`：
       - 文字 `'$title @ ${deviceName(id)}：${termAskWord(ps)}'`。
       - `title` 用 `stateSync.session(n.fp, n.session)` 那一行的 `title ?? name` 和 `host`。
       - `ps` 用 `n.kind`、`n.app`、`n.msg` 建。
       - `at = n.since`；`greyWord = offlineWord(id, n.session)`。
  - 只在 `_fromService` 时合并；不是的时候 `needs` 和今天逐项相同，只多了 `at` 字段。
  - `goToNeed`：`greyWord != null` 时什么也不做。
  - `needs_you.dart`：`greyWord` 不为空的行用 `t.muted`，末尾加 `' · $greyWord'`，不可点。顶部计数仍是 `needs.length`，灰行算在里面（§17 第 4 条补问）。

- [ ] **Step 1: 写失败的测试**

```dart
test('an offline device: its blocked terminal comes from the service, grey, counted', () async {
  // 111 上线后掉线；sync connected；sync.needs=[{fp:'F',id:'111',session:'t1',kind:'permission',app:'claude-code',msg:'approve',since:100}]
  // sync.session('F','t1') = {session:'t1',name:'rapp'}
  // needs 恰好含一项 terminal，greyWord == '设备离线'，文字以 'rapp @ mini：' 开头；needCount 计入它；goToNeed 不打开
});
test('a device this app computes is not doubled and takes the service since', () async {
  // termLists['111'] 有 blocked t1 和 t2；sync.needs 只含 (111,t1) since=50；_now 固定在 1000 秒
  // needs 里 t1 只有一项，at == 50；t2 的 at == 1000 → t2 排在 t1 前面
});
test('a need from a device not in the host list is skipped', () async { /* id '999' → 不出现 */ });
test('a need with no id resolves its fp through the state devices', () async { /* id 缺，idOf('F')=='222' → 出现，可点（greyWord null） */ });
test('not connected: needs are what they were', () async { /* 现有 needs 场景，结果与改前一致 */ });
```

`needs_you_test.dart`：灰行文字以 ` · 设备离线` 结尾，点它不调用 `goToNeed` 的打开路径；计数显示含灰行。

- [ ] **Step 2: 跑测试，确认失败** — Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/main_state_test.dart test/ui/needs_you_test.dart` / Expected: FAIL
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试，确认通过** — Run: `cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze` / Expected: PASS
- [ ] **Step 5: 提交** — `git commit -am "feat(gui): 需要你 merges rapp-state's needs, grey for offline, ordered by first seen"`

### Task 9: 设置里“状态服务”一块，接上两个平台

**Files:**
- Create: `gui/lib/pages/state_section.dart`
- Modify: `gui/lib/pages/global_sections.dart`、iOS 的设置页（`main_window.dart:263` 用的 `ios_local_section.dart` 附近，放在同一个设置列表里）、`gui/lib/hub_client.dart`、`gui/lib/service_client.dart`、`gui/lib/main.dart`、`gui/lib/main_ios.dart`、`tasks/todo.md`
- Test: `gui/test/pages/state_section_test.dart`、`gui/test/hub_client_test.dart`（有就加）、`gui/test/service_client_test.dart`

**Interfaces:**
- Consumes: Task 5 的 `StateSync`、`StateConfig`；Task 3 的 IPC `url` 和 `ports.kind`
- Produces:
  - `HubClient.portMaps: List<({String id, int port, int local, String? kind})>`，由 `case 'ports':` 整份替换。
  - `String? stateUrlFromPorts(List<…> maps)`：取 `kind == 'state'` 的项，有多个时选 `id` 最小的（按字符串比，9 位定长），返回 `http://localhost:<local>`；一个都没有返回 `null`。
  - `ServiceMonitor.stateUrl() → Future<String?>`：发 IPC `{'cmd':'state'}`，取回复的 `url`，出错时返回 `null`。
  - `main.dart`（桌面）：`StateSync(localDir: data.localDir, find: monitor.stateUrl)`。
  - `main_ios.dart`：`find: () async => stateUrlFromPorts(hub.portMaps)`。
  - 两边都 `start()`，传给 `MainState(stateSync:)` 和设置页。
  - `class StateSection extends StatelessWidget { const StateSection({super.key, required this.sync}); }`
    - 外面是 `SectionCard(title: '状态服务')`，里面三个单选：`自动`、`关`、`手填地址`。
    - 选 `手填地址` 时出一个输入框，提交时过 `checkUrl`，不对就在框下显示提示语，对了 `setConfig`。
    - 状态行按 `sync.status` 显示：`connected` 为 `已连上 <url>`，`unreachable` 为 `连不上`，`none` 为 `没找到状态服务`，`off` 为 `已关`，`connecting` 为 `连接中…`。
  - `tasks/todo.md` 的 rapp-state 一节：
    - P2 标成已做，写上实机检查 1–6：
      1. Mac 和 iPad 的队列逐行相同。
      2. “需要你”的先后相同。
      3. Mac 上看过，iPad 上不再是新的。
      4. Mac 的 rApp 退出后终端完成一轮，iPad 看到。
      5. 关掉状态服务，两边各用各的队列，只记一行中断。
      6. iPad 进后台再回来，没有重复行，重连所需时间记下来（规格 §18 第 3 条）。
    - “纯服务器上的状态服务要等人看过分享表”那条留着，写明 P2 决定不借 `list_apps`、iPad 能自己看到。

- [ ] **Step 1: 写失败的测试**

```dart
// state_section_test.dart
testWidgets('the three choices save to local/state.json', (t) async { /* 点 关 → StateConfig.load(dir).mode == off；点 手填地址、输入 ftp://x、提交 → 显示 '地址要以 http:// 或 https:// 开头'；输入 http://h:8102 → 存下 */ });
testWidgets('the status line follows the sync', (t) async { /* status unreachable → find.text('连不上')；none → '没找到状态服务' */ });
// hub_client_test.dart
test('ports event keeps kind and picks the smallest id', () {
  // emit {'event':'ports','maps':[{'id':'333','port':8102,'local':28005,'kind':'state'},{'id':'222','port':8102,'local':28003,'kind':'state'},{'id':'222','port':3000,'local':28000}]}
  expect(stateUrlFromPorts(hub.portMaps), 'http://localhost:28003');
});
// service_client_test.dart
test('stateUrl reads url from the state reply', () async { /* 假 IPC 回 {"ok":true,"url":"http://localhost:28003"} → 该值；回 error → null */ });
```

- [ ] **Step 2: 跑测试，确认失败** — Run: `cd gui && ~/development/flutter/bin/flutter test test/pages/state_section_test.dart test/hub_client_test.dart test/service_client_test.dart` / Expected: FAIL
- [ ] **Step 3: 实现**，再改 `tasks/todo.md`。
- [ ] **Step 4: 跑全部门禁**

Run:
```bash
cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test && git checkout pubspec.lock
cd ../rust && cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings
```
Expected: 全部 PASS。iOS 编一次（`scripts/build-ios.sh` 的模拟器或 device 构建，不装机），确认 `main_ios.dart` 能编。

- [ ] **Step 5: 提交**

```bash
git add gui tasks && git commit -m "feat(gui): 状态服务 settings and wiring on desktop and iOS"
```
