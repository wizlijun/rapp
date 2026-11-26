# rapp-state P3（桌面和代报）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 网里有状态服务时：
- 换一台设备能看到“别处开着”哪些会话，点一下在这台打开。
- 别的 app 开着的 GUI 客户端（Claude 桌面端等）在等确认，这台的“需要你”里也有它，标“推断”。
- 在任何一台 app 的设备页上能把另一台设备的状态服务打开或关上。

**Architecture:**
- **`rapp-state`**
  - 加“桌面”：`PUT /v1/desk/<app 指纹>`，整份替换；`/v1/state` 带 `desks`，`/v1/watch` 推 `desk`，30 天没更新就清掉。
  - 会话行和 `needs` 带上 `src`。
  - 代报的 `gone` 只删它自己报的那一行。
- **代报**：app 自己是一个发送者（`via` = app 的指纹，每次启动一个 `epoch`）。
  - 只报“现在”，不攒历史：连上后先按被控设备逐台发 `snap`，再随变化发 `state`/`gone`。
  - 发送失败就在 5 秒后整份重报。
- **远程开启**：设备间新请求 `SetService{name,on}`，`on` 缺省时只问状态。
  - 桌面走本机 `rapp-service` 的 IPC `state` 加 `to`。
  - iOS 走内嵌 hub 的新命令 `set_service`。
  - 设备页上一行“状态服务”开关；对方回 `unknown op`（或 IPC 转成的 `old version`）就不显示。
- **app 的身份**：hub 的 `hosts` 事件带上 hub 自己的指纹和名字（`me`、`name`），每台主机带 `fp`（hub 早就有，只是 Dart 没读）。

**Tech Stack:**
- Rust：hyper 1.x（已有）、tokio、serde_json，不加依赖。
- Dart：`dart:io` `HttpClient`，不加 pub 依赖。
- 测试：Rust 起真服务和 testkit；Dart 用 `HttpServer.bind(loopback, 0)` 做假服务、`FakeStateSync`、注入的时钟。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-state-design.md`。重点看：
- §6 信封（`src`、`via`）；
- §8.2 桌面、§8.3 `PUT /v1/desk`；
- §9.2 第 4、5 条；§10 远程；§15 P3 验收；
- §17 第 5、6 条（2026-11-26 已定：别处开着只列出不自动开；远程开启用 `SetService`）。

## Global Constraints

- **分支与合并**
  - 在 worktree `.worktrees/rapp-state-p3`、分支 `feat/rapp-state-p3` 上做。
  - 完成后照 `CLAUDE.md` 合并到本机 `main`，提交信息 `merge: rapp-state 第 3 步：桌面和代报（feat/rapp-state-p3）`。
  - 不改版本号、不打 tag、不 push、不发版。`Cargo.lock`、`pubspec.yaml` 不变；跑完 flutter 测试后还原 `gui/pubspec.lock`。
- **不加依赖**：Rust 和 Dart 都不加新依赖；`rapp-state` 仍不依赖任何 `rapp-*` crate。
- **`PUT /v1/desk/<fp>`**
  - `<fp>` 是 app 的指纹：非空、不含 `/`、最长 **128** 字符，否则 400。
  - 正文 `{"device":"<app 所在设备名>"?, "sessions":[{"fp"?,"id"?,"app","name"?}, …]}`。每项 `app` 是非空字符串，`fp` 和 `id` 至少有一个且是字符串，`name` 有就是字符串（超过 **500** 字符截断）；每项只留这四个字段。最多 **200** 项。
  - 成功 204；`sessions` 是空数组表示这台 app 什么都没开，桌面删掉；正文不对回 400 `{"error":"bad request"}`。
  - 时间用服务自己的钟（Unix 秒），存成桌面的 `at`。
- **`desks` 的形状**
  - `/v1/state` 加 `"desks":[{"fp","device"?,"at","sessions":[…]}]`，按 `fp` 排。
  - watch 推 `{"what":"desk","fp","desk":{…}|null}`：`null` 表示删了。内容没变（只是 `at` 更新）不推。
  - 30 天（`DEVICE_DAYS`）没更新的桌面在 `expire` 里清掉，推 `null`。
- **代报事件**（app 发，`POST /v1/events`）
  - 信封：`"v":1,"fp":<被控设备指纹>,"id":<被控设备 9 位 ID>,"epoch":<这次启动的随机串>,"n":<从 1 递增>,"at":<秒>,"src":"app","via":<app 指纹>`。**不带 `device`**：设备名由设备自己报，不让 app 起的名字盖掉它。
  - `state`：`session` = app 标识（包名，即会话 key 的后半段），`name` = 这台 app 上显示的名字，`state`，`blocked` 时带 `kind`，有就带 `app`（规则包 id）。
  - `gone`：`session`。会话真的关掉（记录删掉）、规则换了（推断清空）、或报过的状态不再成立（确定的 `blocked` 变成不确定）时发；连接断开**不发**（§8.2：合上 Mac 以后它多半还在等）。
  - `snap`：每台被控设备一条，`sessions` 每项是 `state` 那几个字段加 `since`。
  - 不确定的 `blocked`（`RemoteSession.inferredNeed` 为假）不报；报的是 `inferredPs`，没有推断时视同 `gone`。
- **app 一侧的常数**
  - 桌面上传防抖 **1** 秒；发送失败后 **5** 秒整份重报（`snap` + 桌面）。
  - 待发的代报事件最多 **200** 条，满了丢最旧并安排整份重报。
  - 服务回 404（旧服务没有 `/v1/desk`）：这次连接里不再传桌面，下次连上再试。
- **`SetService`**
  - 线上：`{"op":"set_service","name":"state","on":true|false}`；`on` 缺省是只问状态。
  - 谁能发：和 `Op::Share` 同一条规则，即 `forward::admit(&Caller{fp, server:false}, true)`：密码连接回 `not supported`。
  - 回复：成功时就是 `companion::set` / `companion::status` 的回复；名字不认识回 `unknown service`。
  - 日志：`service_set` 或 `service_refused`，带 `name`、`on` 和 `By::Remote(peer)`。
- **面向用户的文字**（逐字照抄）
  - 会话面板的组名 `别处开着`；卡片上写 `在 <设备名> 上开着`，几台用 `、` 连起来。
  - 服务来的 GUI 客户端“需要你”：`<名字> @ <设备名>：<等你的说法>（推断）`。`<等你的说法>` 用 `termAskWord`。
  - 设备页开关的标签 `状态服务`。
    - 开着且在跑：`运行中，端口 <port>`；开着但有 `error`：显示 `error` 原文；开着还没跑起来：`启动中`。
    - 网里已有一个在别的设备上：`已经有一个在 <设备名> 上`。是这台 app 自己所在的设备时，`<设备名>` 写 `本机`。
    - 切换失败：`没开成：<原因>` / `没关成：<原因>`。原因用 `shareErrorText` 能认出的就用它，否则原文。
- **反目标**
  - 没有状态服务、或 `StateSync` 不在（`MainState` 不传）时：不发任何代报和桌面，面板没有“别处开着”，“需要你”和队列与今天逐项相同。
  - 事件和桌面里的文字（`name`、`msg`）不进 GUI 日志和服务日志：服务日志只记条数和 `fp`。
- **门禁**
  - Rust（在 `rust/` 下）：`cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`。cargo 在 `$HOME/.cargo/bin`。testkit 的 linux_detach 测试要先 `cargo build --release --bin rapp-session`。
  - Dart（在 `gui/` 下）：`~/development/flutter/bin/flutter analyze`、`flutter test`。
  - 碰到 hub 或 hub-ffi 时，照 `scripts/build-ios.sh sim` 编一次 iOS（不装机）。
- **语言**：面向用户的文字用中文；代码、注释、日志事件名用英文。

## Review Focus

1. **两台 app 开着同一个 GUI 会话**：Mac 和 iPad 都开着 Mac 上的 Claude，iPad 关掉它发 `gone`，Mac 那边还在等。服务不能把这一行删掉：代报的 `gone` 只删 `by` 是它自己的行。测试在 Task 1。
2. **app 崩了或被杀，没来得及发 `gone`**：下次启动连上后，对 `/v1/state` 里 `by` 是自己、`src` 是 `app` 的每台设备都发一条 `snap`，这次没在报的就发空的，把上次留下的清掉。测试在 Task 5。
3. **被控设备的指纹还不知道**（hub 的主机表里 `fp` 为空，例如只用密码加过、还没走过 `rapp/2`）：不报，也不出错；桌面那一项只带 `id`。测试在 Task 6。
4. **桌面里有这台 app 设备表里没有的设备，或那台设备离线**：不进“别处开着”（点了也开不了）。会话这台已经开着的，也不进。测试在 Task 7。
5. **P2 的旧服务**（没有 `/v1/desk`，回 404）：代报照发，桌面这次连接里不再重试；不弹错，状态仍是“已连上”。测试在 Task 5。
   - **改了（最终评审）**：P2 的服务（0.15.48–0.15.51）代报也不发。它的 store 把 `src` 当信封丢掉，代报的行进了 `needs` 就成了终端的“在等你”，没有“推断”标记。看 `/v1/state` 有没有 `desks` 认出它：没有就整次连接什么都不发（代报、空 snap、桌面），每次接上重新看。桌面 PUT 回任何 4xx 也按 404 处理，这次连接里不再发。

---

## File Structure

```
services/state/
  src/store.rs        Desk、desks、put_desk、state() 带 desks、expire 清桌面；行和 needs 带 src；代报 gone 只删自己的
  src/http.rs         PUT /v1/desk/<fp>（前缀路由）
  api/http.md, api/events.md   新接口、desk 推送、src、代报的 gone
  tests/http.rs       desk 的真 HTTP 测试
rust/
  net/src/msg.rs              Op::SetService
  service/src/companion.rs    serve（设备间）、ipc 支持 to
  service/src/peer.rs         分派 SetService
  hub/src/lib.rs              set_service 命令；hosts 事件带 me、name
  hub/src/services.rs         新：set_service 的实现（照 labels.rs）
  testkit/tests/set_service.rs  新：远程开关、密码连接被拒、IPC to
gui/lib/
  state/state_link.dart       postEvents、putDesk
  state/state_out.dart        新：StateOut（代报 + 桌面上传）
  state/state_sync.dart       desks、desk 推送、接上 StateOut
  state/service_switch.dart   新：ServiceSwitchApi
  hub_client.dart             HubHost.fp、meFp/meName、stateService、stateHost
  service_client.dart         ServiceMonitor 实现 ServiceSwitchApi
  ui/main_state.dart          代报、服务来的推断行、桌面清单、elsewhereEntries
  ui/session_model.dart       SessionEntry.openOn
  ui/session_block.dart       显示 openOn
  ui/sessions_tab.dart        “别处开着”一组
  ui/state_service_row.dart   新：设备页的“状态服务”一行
  ui/devices_tab.dart, ui/main_window.dart, main.dart, main_ios.dart   接线
gui/test/
  state/state_link_test.dart, state/state_out_test.dart（新）, state/state_sync_test.dart, fakes.dart
  hub_client_test.dart, service_client_test.dart
  ui/main_state_test.dart（加组）, ui/sessions_tab_test.dart（有就加，没有就新建）, ui/state_service_row_test.dart（新）
docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md、2026-11-13-rapp-config-reference.md（只在写到 IPC `state` 时改）、tasks/todo.md
```

---

### Task 1: `rapp-state` 记桌面，行带 `src`，代报的 `gone` 只删自己的

**Files:**
- Modify: `services/state/src/store.rs`, `services/state/src/http.rs`, `services/state/src/disk.rs`（只改测试）, `services/state/api/http.md`, `services/state/api/events.md`
- Test: `services/state/src/store.rs`（tests）、`services/state/src/disk.rs`（tests）、`services/state/tests/http.rs`

**Interfaces:**
- Produces:
  - `#[derive(Serialize, Deserialize, Clone)] pub struct Desk { device: Option<String>, at: u64, sessions: Vec<Value> }`。
  - `Store` 加 `#[serde(default)] desks: BTreeMap<String, Desk>`：旧的 `state.json` 没有这个字段，必须照样读得进来。
  - `pub fn put_desk(&mut self, fp: &str, body: &Value, now: u64) -> Result<(), &'static str>`：错误值 `"bad request"`。
  - `state()` 多一个 `"desks"` 数组；变化推 `{"what":"desk","fp","desk"}`。
  - 会话行（`row_data`）存进事件信封里的 `src`（有才存）；`needs()` 的每项也带 `src`。
  - `Kind::Gone` 在事件带 `via` 时只删 `by == ev.sender` 的行；不带 `via` 的照旧删掉不管谁报的。

- [ ] **Step 1: 写失败的测试**（store）

```rust
#[test]
fn a_desk_is_replaced_whole_and_an_empty_one_is_removed() {
    let mut s = st();
    s.put_desk("appA", &json!({"device":"iPad","sessions":[{"id":"111111111","app":"com.x","name":"X","junk":1}]}), 100).unwrap();
    let d = &s.state()["desks"][0];
    assert_eq!((d["fp"].as_str(), d["device"].as_str(), d["at"].as_u64()), (Some("appA"), Some("iPad"), Some(100)));
    assert_eq!(d["sessions"], json!([{"id":"111111111","app":"com.x","name":"X"}]));
    assert_eq!(s.take_changes().last().unwrap()["what"], "desk");
    s.put_desk("appA", &json!({"device":"iPad","sessions":[{"id":"111111111","app":"com.x","name":"X"}]}), 200).unwrap();
    assert!(s.take_changes().is_empty(), "same content: no push");
    assert_eq!(s.state()["desks"][0]["at"], 200, "at still moves");
    s.put_desk("appA", &json!({"sessions":[]}), 300).unwrap();
    assert_eq!(s.state()["desks"], json!([]));
    assert_eq!(s.take_changes().last().unwrap()["desk"], Value::Null);
}

#[test]
fn a_bad_desk_is_refused() {
    let mut s = st();
    for b in [json!({}), json!({"sessions":[{"app":"x"}]}), json!({"sessions":[{"id":"1"}]}), json!({"sessions":[{"id":1,"app":"x"}]}),
              json!({"device":3,"sessions":[]})] {
        assert_eq!(s.put_desk("a", &b, 1), Err("bad request"), "{b}");
    }
    let many: Vec<Value> = (0..201).map(|i| json!({"id":"1","app":format!("a{i}")})).collect();
    assert_eq!(s.put_desk("a", &json!({"sessions": many}), 1), Err("bad request"));
}

#[test]
fn an_old_desk_expires() {
    let mut s = st();
    s.put_desk("a", &json!({"sessions":[{"id":"1","app":"x"}]}), 1_000).unwrap();
    s.take_changes();
    s.expire(1_000 + 31 * 86_400);
    assert_eq!(s.state()["desks"], json!([]));
    assert!(s.take_changes().iter().any(|c| c["what"] == "desk" && c["desk"].is_null()));
}

#[test]
fn rows_and_needs_carry_src() {
    let mut s = st();
    feed_line(&mut s, json!({"v":1,"fp":"devA","id":"111111111","epoch":"e1","n":1,"at":10,"src":"app","via":"appA",
                             "t":"state","session":"com.x","name":"X","state":"blocked","kind":"permission"}));
    assert_eq!(session_row(&s, "devA", "com.x")["src"], "app");
    assert_eq!(s.state()["needs"][0]["src"], "app");
    assert!(s.state()["devices"][0].get("device").is_none(), "a proxy event names no device");
}

#[test]
fn a_proxy_gone_removes_only_its_own_row() {
    let mut s = st();
    let ev = |via: &str, n: u64, t: &str| json!({"v":1,"fp":"devA","epoch":"e","n":n,"at":10,"src":"app","via":via,
                                                 "t":t,"session":"com.x","name":"X","state":"blocked","kind":"permission"});
    feed_line(&mut s, ev("appMac", 1, "state"));
    feed_line(&mut s, ev("appPad", 1, "gone"));
    assert_eq!(session_row(&s, "devA", "com.x")["by"], "appMac", "iPad's gone leaves the Mac's report");
    feed_line(&mut s, ev("appMac", 2, "gone"));
    assert!(s.state()["devices"][0]["sessions"].as_array().unwrap().is_empty());
}
```

`feed_line(&mut Store, Value)`：新帮手，把一行 JSON 交给 `parse_line` 再 `apply`（已有的 `feed`、`feed_one`、`feed_gone` 不带 `src`/`via`）。`disk.rs` 的 `saved_and_loaded_are_the_same` 里先 `put_desk` 一份，断言读回来后 `state()["desks"]` 相同；再加一条 `an_old_file_without_desks_loads`：读入一份去掉 `desks` 字段的 JSON，`desks` 为空，不进 `.bad`。

`tests/http.rs`：

```rust
#[tokio::test]
async fn desk_answers_204_and_400_and_shows_in_state_and_watch() {
    let addr = start(Config::default()).await;
    let mut rx = watch(addr).await;
    assert_eq!(recv(&mut rx).await["what"], "hello");
    let body = json!({"device":"iPad","sessions":[{"fp":"devA","id":"111111111","app":"term:pty:1","name":"rapp"}]}).to_string();
    assert_eq!(put(addr, "/v1/desk/appA", &body).await.0, 204);
    assert_eq!(recv(&mut rx).await["what"], "desk");
    assert_eq!(get(addr, "/v1/state").await.1["desks"][0]["fp"], "appA");
    assert_eq!(put(addr, "/v1/desk/appA", "{}").await, (400, Some(json!({"error":"bad request"}))));
    assert_eq!(put(addr, "/v1/desk/", &body).await.0, 400);
    assert_eq!(put(addr, &format!("/v1/desk/{}", "f".repeat(129)), &body).await.0, 400);
    assert_eq!(get(addr, "/v1/desk/appA").await.0, 405);
}
```

再加一条到 `the_log_has_counts_not_text`（或新写一条）：PUT 一份 `name` 是 `"SECRET-NAME"` 的桌面，日志文件里找不到这个字符串。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-state`
Expected: 编译失败（没有 `put_desk`）

- [ ] **Step 3: 实现**
  - store：实现 `put_desk`。“内容没变”指 `device` 和 `sessions` 都和存的相同；正文没给 `device` 时算 `None`。
  - `expire`：桌面的清理放在函数里“设备都新鲜就提前返回”的那一句**前面**。
  - `row_data` 多一个参数，传入事件信封的 `src`：`Kind::State` 传 `ev.body["src"]`，`Kind::Snap` 也传信封的。`needs()` 的复制字段表里加 `"src"`。
  - `Kind::Gone`：`ev.body` 里有 `via` 时，只在行的 `by` 等于 `ev.sender` 时删。
  - http：在 `route` 的精确匹配之前加一段 `strip_prefix("/v1/desk/")`。只认 `PUT`，别的方法回 405，形状照现有的。正文用 `Limited`（`MAX_BODY`）读。成功以后依次 `publish`、`mark(&dirty)`，日志 `desk {fp, sessions: <条数>}`。
  - `api/http.md` 加 `PUT /v1/desk/<fp>` 一节，写清 `desks` 和 `desk` 推送；`api/events.md` 写清 `src` 会留在会话行和 `needs` 里，以及代报的 `gone` 只删自己报的。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-state && cargo clippy -p rapp-state --all-targets -- -D warnings`
Expected: PASS，无警告

- [ ] **Step 5: 提交**

```bash
git add services/state && git commit -m "feat(state): desks (PUT /v1/desk), src on rows, a proxy gone removes only its own row"
```

### Task 2: 设备间请求 `SetService`，本机 IPC `state` 加 `to`

**Files:**
- Modify: `rust/net/src/msg.rs`, `rust/service/src/peer.rs`, `rust/service/src/companion.rs`
- Create: `rust/testkit/tests/set_service.rs`
- Test: `rust/net/src/msg.rs`（tests）、`rust/testkit/tests/set_service.rs`

**Interfaces:**
- Consumes: `companion::set(state, name, on) -> Value` 和 `companion::status(state, name) -> Value`（已有）；`forward::admit`、`Caller`（已有）；`share_cmds::target`、`share_cmds::ask_there`（已有，要用就改成 `pub(crate)`）。
- Produces:
  - `Op::SetService { name: String, #[serde(default, skip_serializing_if = "Option::is_none")] on: Option<bool> }`，线上 `{"op":"set_service",…}`。
  - `pub async fn serve(state: &Arc<State>, s: Pipe, op: Op, peer: Peer) -> Result<()>`（`companion.rs`）：回一行，然后 `shutdown`。
  - IPC：`{"cmd":"state","to"?:<设备 ID 或名字>,"name"?:"state","on"?:bool}`。`to` 指向别的设备时发 `SetService`，把对方的回复原样交回；`to` 是本机或缺省时走现在的本机逻辑。错误照 `ask_there`：`offline`、`old version`（对方回 `unknown op`）等。

- [ ] **Step 1: 写失败的测试**

`msg.rs`（照 `state_sink_wire` 写）：

```rust
#[test]
fn set_service_wire() {
    let on: Op = serde_json::from_str(r#"{"op":"set_service","name":"state","on":true}"#).unwrap();
    assert_eq!(on, Op::SetService { name: "state".into(), on: Some(true) });
    let ask: Op = serde_json::from_str(r#"{"op":"set_service","name":"state"}"#).unwrap();
    assert_eq!(serde_json::to_value(&ask).unwrap(), json!({"op":"set_service","name":"state"}));
}
```

`testkit/tests/set_service.rs`：帮手照 `share_set.rs` 的 `say`、`a_and_b_key`、`b_ipc`；服务的起法照 `state_p1.rs` 的 `services(..)`，要让 `rapp-state` 程序能被找到。

```rust
#[tokio::test]
async fn b_turns_a_state_service_on_and_off() {
    // A、B 两个真 rapp-service，共用 key；B 经自己的 IPC 发 {"cmd":"state","to":<A 的 id>,"on":true}
    let r = b_ipc(&b, json!({"cmd":"state","to": a_id, "on": true})).await;
    assert_eq!((r["ok"].as_bool(), r["on"].as_bool()), (Some(true), Some(true)));
    wait_state(&a_home, true).await;                 // A 的 services.json 里 state 开着，分享表里有 kind:"state"
    let ask = b_ipc(&b, json!({"cmd":"state","to": a_id})).await;   // 不带 on：只问
    assert_eq!(ask["on"], true);
    let r = b_ipc(&b, json!({"cmd":"state","to": a_id, "on": false})).await;
    assert_eq!(r["on"], false);
}

#[tokio::test]
async fn a_password_connection_cannot_set_a_service() {
    // 照 share_set.rs::the_password_connection_cannot_set：密码连接发 {"op":"set_service","name":"state","on":true}
    assert_eq!(r["error"], "not supported");
    // A 的 services.json 里没有 state
}

#[tokio::test]
async fn an_unknown_service_is_named() {
    let r = say(&a, &key, &b, json!({"op":"set_service","name":"nope","on":true})).await;
    assert_eq!(r["error"], "unknown service");
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-net set_service && cargo test -p rapp-testkit --test set_service`
Expected: 编译失败（没有 `Op::SetService`）

- [ ] **Step 3: 实现**
  - `msg.rs`：加变体，文档注释写清“旧设备回 `unknown op`”。
  - `peer.rs`：在 `serve_value` 的 `match` 里，紧挨 `StateSink` 那一行加 `Ok(op @ Op::SetService { .. }) => crate::companion::serve(state, s, op, peer).await`。
  - `companion::serve`：
    - 先 `admit`，被拒就回 `err(<deny 的文字>)`，日志 `service_refused`。
    - 过了就看 `on`：`None` 调 `status`，`Some(b)` 调 `set`，日志 `service_set`。字段见 Global Constraints。
  - `companion::ipc`：先用 `share_cmds::target` 解析 `to`；指向别的设备就 `ask_there(.., &Op::SetService{..})`，回复原样返回，错误照 `ask_there` 的值。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-net && cargo test -p rapp-service && cargo test -p rapp-testkit --test set_service --test state_p1 --test share_set && cargo clippy --workspace --all-targets -- -D warnings`
Expected: PASS，无警告

- [ ] **Step 5: 提交**

```bash
git add rust && git commit -m "feat(service): SetService turns another device's state service on or off"
```

### Task 3: hub 的 `set_service` 命令，`hosts` 事件带 app 自己的指纹

**Files:**
- Create: `rust/hub/src/services.rs`
- Modify: `rust/hub/src/lib.rs`
- Test: `rust/hub/src/services.rs`（tests），或 `rust/testkit/tests/set_service.rs`（见 Step 1）

**Interfaces:**
- Consumes: `Op::SetService`（Task 2）；`hub.host(id)`、`hub.request(&host, &op)`（照 `labels::command`）。
- Produces:
  - 命令 `{"cmd":"set_service","id":<设备 ID>,"name"?:"state","on"?:bool}`，回 `{"event":"service","id","reply":<设备的回复>}`。设备回 `ok:false` 时，命令报错，错误文字里带上设备原来的 `error`（`unknown op` 要原样出现，Dart 靠它认旧设备）。
  - `hosts` 事件多两个字段：`"me":<hub 身份的指纹>`（`identity.fp.to_string()`，从 `at_home()` 取），`"name":<hub.name>`。每台主机的 `fp` 已经在 `summary()` 里了，不动。
  - **改了（最终评审）**：hub 连上一台主机、存下它新的（或第一次的）指纹时（`link.rs` 的 `remember_fp`），主动发一条不带 `req` 的 `hosts` 事件，app 的 `HubHost.fp` 不用等下次列主机就更新。

- [ ] **Step 1: 写失败的测试**
  - `hosts_event_names_this_app`：起一个 hub（照 hub 现有测试的起法），`hosts` 事件的 `me` 是 64 位十六进制，`name` 非空。
  - `set_service_says_the_reply`：对一台会回 `{"ok":true,"on":true}` 的假设备（照 labels 测试的假设备），事件是 `{"event":"service","id":…,"reply":{"ok":true,"on":true}}`。
  - `set_service_on_an_old_device_says_unknown_op`：假设备回 `{"ok":false,"error":"unknown op"}`，命令的错误文字包含 `unknown op`。

  hub 里如果没有能挂假设备的测试帮手，改用 `rust/testkit/tests/` 下真 `rapp-service` 加真 hub 的写法，在 `set_service.rs` 里加这三条。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-hub`（或 `-p rapp-testkit --test set_service`）
Expected: FAIL（`unknown cmd`，`me` 为空）

- [ ] **Step 3: 实现**：`services.rs` 照 `labels.rs` 的 `command` 写。`dispatch` 加一支 `Some("set_service") => services::command(..)`。`hosts_event` 加 `me`、`name`。

- [ ] **Step 4: 跑测试，确认通过；编 iOS**

Run: `cd rust && cargo test -p rapp-hub -p rapp-hub-ffi && cargo clippy --workspace --all-targets -- -D warnings && cd .. && scripts/build-ios.sh sim`
Expected: PASS，无警告，iOS 编过

- [ ] **Step 5: 提交**

```bash
git add rust && git commit -m "feat(hub): set_service command; hosts event names this app (me, name)"
```

### Task 4: Dart 的传输：`StateLink` 发事件和桌面，hub 和服务的开关接口

**Files:**
- Modify: `gui/lib/state/state_link.dart`, `gui/lib/hub_client.dart`, `gui/lib/service_client.dart`
- Create: `gui/lib/state/service_switch.dart`
- Test: `gui/test/state/state_link_test.dart`, `gui/test/hub_client_test.dart`, `gui/test/service_client_test.dart`

**Interfaces:**
- Consumes: Task 1 的接口形状；Task 2 的 IPC `state` + `to`；Task 3 的 `set_service` 和 `hosts.me`。
- Produces:
  - `StateLink.postEvents(List<Map<String, Object?>> events) -> Future<void>`：`POST /v1/events`，一行一个 JSON，`content-type: application/x-ndjson`。2xx 算成功，别的抛 `StateLinkError(status)`。
  - `StateLink.putDesk(String fp, Map<String, Object?> body) -> Future<void>`：`PUT /v1/desk/<Uri.encodeComponent(fp)>`，错误同上（404 要能从 `StateLinkError.status` 看出来）。
  - `HubHost` 加 `final String? fp`，从 `hosts` 每项读。
  - `HubClient` 加 `String? meFp`、`String? meName`，从 `hosts` 事件的 `me`、`name` 读。
  - `abstract interface class ServiceSwitchApi`（`service_switch.dart`）：
    - `Future<Map<String, Object?>> stateService({String? to, bool? on})`：返回设备的回复（`on`、`running`、`port`、`error`…），失败抛异常，异常文字是原因。
    - `Future<String?> stateHost()`：网里现在用的状态服务在哪台设备（9 位 ID）；本机就是本机的 ID；没有就 null。
  - `ServiceMonitor implements ServiceSwitchApi`：
    - `stateService` 发 `{'cmd':'state','to':?to,'on':?on}`，走 `_remoteRequest`（单独的连接，因为远程最长要等 `HOSTS_WAIT`）。
    - `stateHost` 读本机 `state` 回复的 `outbox.dest`：`id` 就是它；有 `local` 时用本机的设备 ID（`ServiceStatus` 里的）。
  - `HubClient implements ServiceSwitchApi`：
    - `stateService` 发 `{'cmd':'set_service','id':to!,'name':'state','on':?on}`，等 `service` 事件，返回它的 `reply`。`to` 为 null 时抛 `ArgumentError`：iOS 上没有本机服务。
    - `stateHost` 返回 `portMaps` 里 `kind == 'state'` 中 ID 最小的那项的 `id`，和 `stateUrlFromPorts` 同一个选法。抽一个 `stateMapOf(List<PortMap>)`，两个函数共用。

- [ ] **Step 1: 写失败的测试**
  - `state_link_test.dart`
    - `postEvents sends ndjson`：假服务收到的正文 `split('\n')` 是两行 JSON，方法 `POST`，路径 `/v1/events`。
    - `putDesk encodes the fp and throws 404 as status 404`：路径 `/v1/desk/a%2Fb`；假服务回 404 时 `StateLinkError.status == 404`。
  - `hub_client_test.dart`
    - `hosts carry fp and the app's own me`：喂一条 `{"event":"hosts","hosts":[{"id":"1","name":"m","fp":"ab"}],"me":"cd","name":"iPad"}`，`hosts.first.fp == 'ab'`、`meFp == 'cd'`、`meName == 'iPad'`。
    - `stateService sends set_service and returns the reply`。
    - `an old device's unknown op reaches the caller`：照 `:155` 的写法，异常文字包含 `unknown op`。
  - `service_client_test.dart`
    - `stateService asks state with to`：请求是 `{'cmd':'state','to':'111111111','on':true}`。
    - `stateHost reads outbox.dest`：`{"dest":{"id":"222222222","port":8102}}` 得 `'222222222'`；`{"dest":{"local":8102}}` 得本机 ID；`null` 得 null。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/state/state_link_test.dart test/hub_client_test.dart test/service_client_test.dart`
Expected: 编译失败

- [ ] **Step 3: 实现**（照上面的签名）

- [ ] **Step 4: 跑测试，确认通过**

Run: 同 Step 2，再跑 `~/development/flutter/bin/flutter analyze`
Expected: PASS，`No issues found!`

- [ ] **Step 5: 提交**（还原 `gui/pubspec.lock`）

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui && git commit -m "feat(gui): StateLink posts events and desks; hub and service speak SetService"
```

### Task 5: `StateOut`：代报和桌面上传，接进 `StateSync`

**Files:**
- Create: `gui/lib/state/state_out.dart`
- Modify: `gui/lib/state/state_sync.dart`, `gui/test/fakes.dart`
- Test: `gui/test/state/state_out_test.dart`, `gui/test/state/state_sync_test.dart`

**Interfaces:**
- Consumes: `StateLink.postEvents`、`StateLink.putDesk`（Task 4）。
- Produces（`state_out.dart`）:
  - `typedef AppReport = ({String state, String? kind, String? app, String name});`
  - `class StateOut`，构造 `StateOut({DateTime Function()? clock, String Function()? epoch, Duration deskDelay = const Duration(seconds: 1), Duration retry = const Duration(seconds: 5)})`。
  - `void setMe(String? fp, String? device)`：`fp` 从 null 变成有、或者变了，在已接上时整份重报。
  - `void report({required String fp, String? id, required String session, required AppReport? now})`：`now == null` 表示 `gone`。和上次报的相同就不发。
  - `void setDesk(List<Map<String, Object?>> sessions)`：防抖 `deskDelay` 后 `putDesk(me, {'device': meName, 'sessions': sessions})`。
  - `void attach(StateLink link, Map<String, Object?> snapshot)`：在 `StateSync` 放好全貌后调。
    - 先发 `snap`：每台“这次在报的被控设备”一条，再给 `snapshot['devices']` 里有 `by == me && src == 'app'` 行、但这次没在报的设备各发一条空的。
    - 然后发桌面（有的话），之后才发实时的。
  - `void detach()`：不再发，待发的清空；下次 `attach` 整份重报。
  - 事件形状见 Global Constraints。同一时刻只有一个请求在路上；失败了清空待发，`retry` 后整份重报（仍接着时）。`putDesk` 回 404 时，这次接上期间不再传桌面。
  - `epoch` 默认是 12 位随机十六进制串，每个 `StateOut` 一个；`n` 从 1 递增，整份重报不重置。
- Produces（`state_sync.dart`）:
  - `final StateOut out`：`StateSync` 自己建，可以注入，用来测试。
  - `List<Map<String, Object?>> get desks`：来自 `/v1/state` 的 `desks` 和 `desk` 推送（推 `null` 就删掉）；`_drop()` 时清空。
  - 全貌放好以后（包括重取）调 `out.attach(link, state)`；状态离开 `connected` 时调 `out.detach()`。
  - `FakeStateSync`：可以设 `desks`；`out` 换成一个 `FakeStateOut`，记下 `reports`（`(fp, id, session, AppReport?)` 列表）和 `desksSet`（每次 `setDesk` 的参数）。另外补上 `fpOf` 的覆盖（用 `ids` 反查）。

- [ ] **Step 1: 写失败的测试**（`state_out_test.dart`，假服务用 `HttpServer.bind(loopback, 0)`，记下收到的每个请求）

```dart
test('attach sends a snap per reported device, an empty one for a stale device, then the desk', () async {
  final out = StateOut(clock: () => DateTime.fromMillisecondsSinceEpoch(10000), epoch: () => 'e1');
  out.setMe('appA', 'iPad');
  out.report(fp: 'devA', id: '111111111', session: 'com.x',
      now: (state: 'blocked', kind: 'permission', app: 'claude', name: 'Claude'));
  out.setDesk([{'id': '111111111', 'fp': 'devA', 'app': 'com.x', 'name': 'Claude'}]);
  out.attach(link, {'devices': [
    {'fp': 'devB', 'sessions': [{'session': 'com.y', 'by': 'appA', 'src': 'app'}]},
    {'fp': 'devC', 'sessions': [{'session': 'term:pty:1', 'by': 'devC', 'src': 'term'}]},
  ]});
  await server.settle();
  final events = server.events;   // 按收到的顺序展开的事件
  expect(events.map((e) => (e['t'], e['fp'])), [('snap', 'devA'), ('snap', 'devB')]);
  expect(events[0], containsPair('via', 'appA'));
  expect(events[0], containsPair('src', 'app'));
  expect(events[0].containsKey('device'), isFalse);
  expect((events[0]['sessions'] as List).single, allOf(containsPair('session', 'com.x'), containsPair('state', 'blocked'),
      containsPair('kind', 'permission'), containsPair('name', 'Claude'), contains('since')));
  expect(events[1]['sessions'], isEmpty);
  expect(events.map((e) => e['n']), [1, 2]);
  expect(server.desks.single, ('appA', {'device': 'iPad', 'sessions': [{'id': '111111111', 'fp': 'devA', 'app': 'com.x', 'name': 'Claude'}]}));
});
```

其余几条测试：
- `a change sends state, the same again sends nothing, null sends gone`。
- `nothing is sent before attach or without me`：`setMe(null, …)` 时 `report` 和 `setDesk` 都不发请求。
- `a failed post re-sends the whole picture after retry`：假服务第一次回 500，第二次起回 204；`retry: Duration(milliseconds: 50)`；之后收到的又是 `snap` 开头，`n` 接着往上数。
- `a 404 desk is not retried while attached`：假服务对 `/v1/desk/…` 回 404；再 `setDesk` 两次也没有新的 PUT；`detach` 再 `attach` 后会再试一次。
- `more than 200 pending drops the oldest and re-sends whole`：先让一个请求挂住，再 `report` 201 次不同会话；放开后收到的第一条是 `snap`。

`state_sync_test.dart`：
- `desks come from the state and from desk pushes`：`/v1/state` 带一份 `desks`，再推 `{"what":"desk","fp":"appB","desk":{…}}`，再推 `{"what":"desk","fp":"appA","desk":null}`，`desks` 跟着变。
- `the snapshot attaches out, a drop detaches it`：注入的假 `StateOut` 记下 `attach`/`detach` 的次数。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/state/`
Expected: 编译失败

- [ ] **Step 3: 实现**（照上面的接口）

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/state/ && ~/development/flutter/bin/flutter analyze`
Expected: PASS，`No issues found!`

- [ ] **Step 5: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui && git commit -m "feat(gui): StateOut reports inferred app states and the desk to the state service"
```

### Task 6: `MainState` 代报 GUI 客户端状态，服务来的标“推断”

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/main_state_test.dart`（新开一个 `group('rapp-state P3 proxy reports', …)`；文件太大就新建 `gui/test/ui/state_p3_test.dart`）

**Interfaces:**
- Consumes:
  - `stateSync.out.report(...)`、`stateSync.out.setMe(...)`（Task 5）；`HubHost.fp`、`hub.meFp`、`hub.meName`（Task 4）。
  - 已有的：`RemoteSession.inferredPs`、`RemoteSession.inferredNeed`、`AppState.pack`、`_trackAppState`、`_endRecord`、`_resendRules`、`_serviceRow`、`_serviceNeeds`、`queueRows`、`goToNeed`。
- Produces:
  - `void _reportAppState(SessionRecord r)`：在 `_trackAppState` 被调的地方紧接着调。
    - 算出 `AppReport?`：`inferredPs` 为 null，或 `blocked` 但 `inferredNeed` 为假，都算 null。`app` 用 `appState.pack`，`name` 用 `r.appName`。
    - 交给 `out.report(fp: <hub 主机的 fp>, id: r.id, session: r.app, now: …)`。主机 `fp` 为 null 时什么都不做。
  - 会话记录被删掉（`_endRecord`），或 `_resendRules` 清掉推断时，报 `now: null`。`linkDown` 不报。终端和 `desktop:` 不报。
  - `hub` 的 `hosts` 事件到了就 `out.setMe(hub.meFp, hub.meName)`。
  - `_serviceRow`：`row['src'] == 'app'` 的 `state` 行。
    - 标题用 `row['name']`，没有就用 `session`。
    - 生成的 `HintRecord` 带 `inferred: true`；`device`/`app` 的给法和终端行相同，好让它点得开。
  - `queueRows`：连着服务时，本机的 `inferred` 行也不要了，它们由服务那边回来，免得出现两次。
  - `_serviceNeeds`：`src == 'app'` 的项。
    - 只在这台 app 自己有一条 live 记录 `'$id/$session'` 时跳过；不受“这台自己读这台设备的终端”影响。
    - 生成 `NeedItem(NeedKind.app, '$id/$session', '<名字> @ <设备名>：<termAskWord>（推断）', …, device: id, title: <名字>, at: since, greyWord: deviceOffline(id) ? '设备离线' : null)`。
  - `goToNeed` 的 `NeedKind.app`：记录存在就照旧 `select`；不存在且 `n.device != null` 时 `openOrSwitch(n.device!, <key 的 app 部分>, n.title!)`。

- [ ] **Step 1: 写失败的测试**
  - `a sure block is reported, then gone when the session ends`：用现有的假 hub，主机带 `fp: 'devA'`，`meFp: 'appA'`；给一条 live 的 GUI 会话喂一个 `sure`、`blocked` 的 `AppStateEvent`。
    - `fake.out.reports.last` 是 `('devA', id, app, (state: 'blocked', kind: …, app: <pack>, name: <appName>))`。
    - `endSession` 后最后一条的 `now` 是 null。
  - `an unsure block and a link drop are not reported`：不确定的 `blocked` 不出新报告；`linkDown` 之后也不出。
  - `no fp, no report`：主机 `fp` 为 null 时 `reports` 为空，也没有异常。
  - `a service app need is marked inferred and opens on tap`：`FakeStateSync` 设成 `connected`，`needs` 里放一项 `{'fp':'devA','id':<id>,'session':'com.x','src':'app','state':'blocked','kind':'permission','since':5}`，`sessions` 里放这一行（`name: 'Claude'`）。
    - `needs` 里有 `NeedKind.app`，文字以 `（推断）` 结尾。
    - `goToNeed` 调了 `openOrSwitch(<id>, 'com.x', 'Claude')`；用现有的打开记录手段断言，比如 `fake hub` 收到的 open。
  - `a service app need is skipped when this app has it live`：同一项，这台有 live 记录，只出现一项（本机算的那项）。
  - `service app rows queue as inferred and local inferred rows step aside`：
    - `rows` 里一条 `src: 'app'` 的 `state` 行，`queueRows` 里那一行 `inferred == true`。
    - 本机 `_trackAppState` 记的推断行不在 `queueRows` 里；断开服务（`status = unreachable`）后又出现。
  - 反目标：`stateSync` 为 null 时上面的 GUI 会话照旧，不抛异常；`needs` 和 `queueRows` 与改动前相同（现有测试全过即是）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/main_state_test.dart`（或新文件）
Expected: FAIL

- [ ] **Step 3: 实现**（照上面的接口）

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/ && ~/development/flutter/bin/flutter analyze`
Expected: PASS，`No issues found!`

- [ ] **Step 5: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui && git commit -m "feat(gui): report inferred app states to the state service; show others' as 推断"
```

### Task 7: 桌面清单上传，会话面板加“别处开着”

**Files:**
- Modify: `gui/lib/ui/main_state.dart`, `gui/lib/ui/session_model.dart`, `gui/lib/ui/session_block.dart`, `gui/lib/ui/sessions_tab.dart`
- Test: `gui/test/ui/main_state_test.dart`（或 Task 6 的新文件）、`gui/test/ui/sessions_tab_test.dart`（有就加，没有就新建；写法照 `session_labels_test.dart:291`）

**Interfaces:**
- Consumes: `stateSync.out.setDesk`、`stateSync.desks`（Task 5）；`hub.meFp`、`HubHost.fp`（Task 4）；已有的 `_records`、`_mapEntries`、`listed`、`openStandby`、`deviceOffline`、`termDisplayName`。
- Produces:
  - `List<Map<String, Object?>> get deskSessions`：这台 app 现在开着的会话。
    - 每条 `_records` 一项（任何阶段，包括已断开），`termsEntry` 不算。
    - 每项 `{'id': r.id, 'fp'?: <主机 fp>, 'app': r.app, 'name': r.appName}`，按 `key` 排。
  - 每次 `_entries = _mapEntries()` 赋值以后，`deskSessions` 和上次传的不同就 `stateSync?.out.setDesk(deskSessions)`。启动时也传一次，空的也传。
  - `SessionEntry` 加 `final String? openOn`，默认 null。
  - `List<SessionEntry> get elsewhereEntries`：
    - 来源是 `stateSync.desks` 里 `fp != hub.meFp` 的每份桌面的每项。
    - 设备 ID 用项里的 `id`；没有就用 `stateSync.idOf(fp)`。
    - 跳过这些：ID 不在 `hub.hosts` 里的、`deviceOffline(id)` 的、`'$id/$app'` 已在 `listed` 里的。终端在 `hub.termLists[id]` 里标 `dead`，或列表已到却找不到的，也跳过。
    - 同一个 key 只出一张，`openOn` 是 `在 <各桌面的 device，没有就用 fp 的前 8 位> 上开着`，多个用 `、` 连。
    - 卡片是 `lamp: Lamp.notOpened`、`standby: Standby.open`。终端的名字用 `termLists` 里那一行算（`termDisplayName`），没有就用桌面给的 `name`。
    - 按桌面的 `at` 新的在前。
    - 只在 `_fromService` 时有，否则是空列表。
  - `SessionsTab`：在各组之后、`常用` 之前，`elsewhereEntries` 非空时加一组。组名用 `SessionGroupTitle('别处开着')`，卡片照 standby 卡的写法，`keyPrefix: 'elsewhere'`。点卡片走 `openStandby`，即 `openOrSwitch`，不自动打开任何东西。
  - `SessionBlock`：`entry.openOn != null` 时，把它显示在设备名那一行的位置。

- [ ] **Step 1: 写失败的测试**
  - `the desk follows opens and closes`：
    - 打开一条会话后，`fake.out.desksSet.last` 是 `[{'id': id, 'fp': 'devA', 'app': app, 'name': name}]`。
    - `endSession` 后是 `[]`。
    - 连着再开一条又关一条时，相同的清单不重复传。
  - `elsewhere lists other desks' sessions not open here`：`FakeStateSync.desks` 有三份。
    - `appA` 是自己的：不出现。
    - `appB`（device `Mac`）有 `{'id': h1, 'app': 'com.x', 'name': 'X'}` 和 `{'id': '999999999', 'app': 'com.y'}`，后者是不认识的设备：只出现 X。
    - `appC`（device `iPad`）也有 X：X 的 `openOn` 是 `在 Mac、iPad 上开着`，卡片的 `lamp` 是 `Lamp.notOpened`。
  - `elsewhere skips what is open here and offline devices`。
  - `elsewhere is empty without the service`：`status = unreachable` 时为空。
  - 面板（widget test）：
    - 有一项时出现文字 `别处开着` 和 `在 Mac 上开着`。
    - 点卡片后，假 hub 收到打开 `com.x` 的请求（照 `session_labels_test.dart` 断言打开的写法）。
    - 渲染期间没有任何会话被自动打开。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/`
Expected: FAIL

- [ ] **Step 3: 实现**（照上面的接口）

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
Expected: 全部 PASS，`No issues found!`

- [ ] **Step 5: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui && git commit -m "feat(gui): upload this app's open sessions; 别处开着 in the session panel"
```

### Task 8: 设备页的“状态服务”开关，接线，文档和待办

**Files:**
- Create: `gui/lib/ui/state_service_row.dart`
- Modify: `gui/lib/ui/devices_tab.dart`, `gui/lib/ui/main_window.dart`, `gui/lib/main.dart`, `gui/lib/main_ios.dart`（只在需要传参时改）
- Modify (docs): `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md`，`docs/superpowers/specs/2026-11-26-rapp-state-design.md`（§15 P3 标“计划已写”），`tasks/todo.md`
- Test: `gui/test/ui/state_service_row_test.dart`, `gui/test/ui/devices_tab_test.dart`

**Interfaces:**
- Consumes: `ServiceSwitchApi`（Task 4）；`shareErrorText`（已有）。
- Produces:
  - `class StateServiceRow extends StatefulWidget`，构造 `StateServiceRow({Key? key, required ServiceSwitchApi api, String? to, required String Function(String id) nameOf, String? localId})`。
    - 一出来就 `api.stateService(to: to)` 问状态，同时 `api.stateHost()` 问网里的那一个在哪。
    - 问状态出错（任何原因：旧设备的 `unknown op` / `old version`、离线等）就整行不显示（`SizedBox.shrink()`）。
    - 正常时：一个开关 `状态服务`，值是回复的 `on`；下面一行状态文字，见 Global Constraints。
    - 网里那一个所在的设备不是 `to`（`to` 为 null 时与 `localId` 比）就显示 `已经有一个在 <nameOf(id)> 上`；那个 ID 等于 `localId` 时名字写 `本机`。
    - 拨开关时调 `api.stateService(to: to, on: v)`，期间开关禁用；失败显示 `没开成：…` / `没关成：…`，开关回到原来的值。
  - `DevicesTab` 加参数 `ServiceSwitchApi? serviceSwitch`：在 `_remote` 里 `SharesSection` 那一行之后放 `StateServiceRow(key: ValueKey('state-service-$id'), api: serviceSwitch!, to: id, nameOf: state.deviceName, localId: <本机设备 ID>)`。`serviceSwitch` 为 null 时不放。
  - `main_window.dart`：
    - 桌面传 `ServiceMonitor`，iOS 传 `HubClient`。iOS 上 `shares` 为 null，开关照样有。
    - 桌面本机那一段（`ValueKey('shares-local')` 旁边）也放一行，`to: null`。

- [ ] **Step 1: 写失败的测试**（`state_service_row_test.dart`，一个假的 `ServiceSwitchApi`）
  - `hidden when the device is too old`：`stateService` 抛 `Exception('unknown op')`，找不到 `状态服务`。`old version` 也一样。
  - `shows on and running with the port`：回复 `{'ok':true,'on':true,'running':true,'port':8102}`，有 `状态服务` 和 `运行中，端口 8102`，开关为开。
  - `turning on calls with on: true and shows the new state`。
  - `a failed turn shows the reason and flips back`：`stateService(on: true)` 抛 `Exception('policy')`，显示 `没开成：` 开头的文字，开关仍为关。
  - `names where the other one is`：`stateHost` 回 `'222222222'`，`to` 是 `'111111111'`，显示 `已经有一个在 <nameOf('222222222')> 上`；`stateHost` 回 `localId` 时显示 `已经有一个在 本机 上`；回 `to` 自己时不显示。
  - `devices_tab_test.dart`：传 `serviceSwitch` 时每台远程设备页有 `ValueKey('state-service-<id>')`；不传就没有。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/state_service_row_test.dart test/ui/devices_tab_test.dart`
Expected: 编译失败

- [ ] **Step 3: 实现**（照上面的接口），然后接线。

- [ ] **Step 4: 跑全部门禁**

Run:
```bash
cd rust && cargo build --release --bin rapp-session && cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings
cd ../gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test
cd .. && scripts/build-ios.sh sim
```
Expected: 全部通过。rapp-term 的 pty 测试在负载下偶发失败时单独重跑一次，并在报告里写明。

- [ ] **Step 5: 文档和待办**
  - 端口分享主规格：
    - `Share.kind` 若 P1 还没写进去，补上；
    - 加 `SetService{name,on}` 一节：谁能发、`on` 缺省只问、回复、旧设备 `unknown op`。
  - `tasks/todo.md` 的“rapp-state 状态服务”一节：
    - 把 P3 那一行（“计划还没写；写之前先问用户规格 §17 第 6 条”）改成已做；
    - 加“P3 实机检查”1–6：
      1. Mac 上开 3 个会话，iPad 的会话面板“别处开着”列出这 3 个，写“在 <Mac> 上开着”，点一个在 iPad 上打开；
      2. Mac 上 Claude 桌面端等确认，iPad 的“需要你”里有它，带“（推断）”，点了在 iPad 打开；
      3. Mac 和 iPad 都开着同一个 Claude，iPad 关掉后 iPad 的“需要你”里它还在（Mac 报的）；
      4. iPad 设备页把另一台设备的“状态服务”打开，那台 `rapp state` 显示开着，再关掉；
      5. 对一台 0.15.51 及更早的设备，开关不出现；
      6. 杀掉 Mac 上的 rApp 再打开，上次留下的推断行被清掉。
    - 加“P3 遗留”：
      - 退出 app 时不发空桌面，别处会留着“在 <它> 上开着”，直到它下次打开或 30 天；
      - 不确定的 `blocked` 不代报。

- [ ] **Step 6: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui docs tasks && git commit -m "feat(gui): 状态服务 switch on every device page; docs and checks for rapp-state P3"
```
