# 连接方式（2b）实现计划：ID 折叠、自动切局域网、强制走中继、看得到路径

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 设了 relay 时本机 ID 先给纯数字、`ID@IP` 折叠；B 经中继（或直连）连着的主机，局域网一通就自动切过去、开着的会话逐个重开到局域网上；每台主机可以强制走中继；设备行、会话列表、流菜单上的路径随切换马上更新。

**Architecture:** hub 管选路：`hosts.json` 每台主机多一个 `route`；hub 每缓存一条到主机的连接就发一条 `path` 事件；新模块 `upgrade.rs` 按时间表对不在局域网上的主机试局域网，通了就把这条试通的连接直接换进缓存（不握第二次手）。会话重开由 GUI 做：收到 `path` 事件后，把这台主机上路径不同的会话一个一个用"重连打开"重开（旧画面留到新会话有画面再换），失败的留在原路，并告诉 hub `route_failed`（5 分钟内不再试）。hub 只把连接移出缓存、不关它：开着的会话的流还挂在上面，最后一条流结束时 quinn 自己关连接。

**Tech Stack:** Rust（quinn 0.11、tokio、if-addrs）；Flutter GUI。

**Spec:** `docs/superpowers/specs/2026-11-14-relay-connect-ux-design.md`（下称"UX 规格"）。背景：`docs/superpowers/specs/2026-11-13-rapp-relay-design.md`（"relay 规格"）。

**前一份：** 2a 已合进 main 并发了 0.6.0（`9123a0a`）。2c（吊销、换 key、审计）另写。

## Global Constraints

- 基于 main（`9123a0a` 或之后）。在新分支 `feat/relay-2b`（worktree）上做。
- 路径的词：`lan`、`direct`、`relay`。GUI 标签 `局域网`、`直连`、`中继`；强制走中继、路径是 `relay` 时写 `中继（强制）`。
- `hosts.json` 主机项新字段 `"route": "relay"`；不写就是自动。只认 `"relay"`。读的时候缺省为自动；写的时候自动就不写这个字段。
- 自动切局域网的时间表（UX 规格 §3）：连接刚缓存在中继或直连上 → **2 秒**后试；之后每 **30 秒**；B 本机地址变了 → 马上试；上一次切换失败（`route_failed`）→ **5 分钟**内不试。
- "局域网连通" = 在私有地址（`rapp_net::addr::is_private`）上 `rapp/2` 握手成功，回复的 `id` 是这台主机，并且指纹等于 `hosts.json` 里存的 `fp`（`read_welcome` 已经检查这两样）。没存 `fp` 的主机不试。
- 只往局域网切。强制走中继的主机不试。
- 强制走中继时连不上 relay：报错，**不**退回局域网。错误文本以 `relay unreachable: ` 开头（GUI 已映射为 `中继连不上`），或者是 relay 原样转来的词（`offline`、`unknown id`、…）；没设 relay 是 `relay not set: add the host as id@ip`。
- B 的 `hub.log` 在自动切换成功时记一行 `msg`：`<id>: path <旧路径>→lan`（例如 `100000001: path relay→lan`）。
- hub 新事件和命令（stdout/stdin JSON 行，`req` 照旧回显）：
  - 事件 `{"event":"path","id":"<id>","path":"lan"|"direct"|"relay"}`：每次缓存一条到这台主机的连接时发（新建的、自动切换换进来的都算）。不去重。
  - 命令 `{"cmd":"set_route","id":"<id>","route":"relay"|"auto"}`，回复 `hosts` 事件；别的 `route` 值回 `bad route`，主机不存在回 `unknown host`。
  - 命令 `{"cmd":"route_failed","id":"<id>"}`，无回复。
  - `hosts` 事件的主机项在强制时带 `"route":"relay"`。
  - `presence` 事件离线时多带 `"error":"<原因>"`（在线时不带）。
- key 和 `trust()` 的值不得出现在日志、事件、错误文本里（2a 的规矩照旧）。
- 用户同时在改仓库：不碰 `README.md`、`docs/archives/`、`tasks/` 和 main 工作区里用户改着的文档。按文件名 `git add`，不用 `git add -u/-A/.`、`git stash/checkout/restore/reset`。不跑 `cargo fmt`；只对改过的文件跑 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。
- `flutter test` 会改 `gui/pubspec.lock`：不要提交它（用 `git show HEAD:gui/pubspec.lock > gui/pubspec.lock` 还原）。Flutter 在 `~/development/flutter/bin/flutter`，cargo 在 `~/.cargo/bin`。
- 每个 Rust 任务结束：`cd rust && cargo test --workspace` 全过，`cargo clippy --workspace --all-targets -- -D warnings` 无警告。GUI 任务结束：`cd gui && flutter test` 全过、`flutter analyze` 无问题。
- 不发版，不改版本号。提交信息 `feat(hub): …`、`feat(gui): …`、`test(testkit): …`，结尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. 切换进行中用户关掉或结束了一个会话、或者那个会话自己断了：不留下两个会话、不把已结束的记录复活、不报错。（任务 5）
2. 会话正在从中继挪到局域网时，又来一条 `path` 事件（例如用户马上按了"强制走中继"）：同一台主机同一时间只跑一轮挪动，后一轮按最新的路径来，每个会话最多被重开一次。（任务 5）
3. 主机在切换途中被删除，或者 `set_home` 换了数据目录：升级循环不把旧主机的连接放回缓存，不对新目录里同 ID 的主机用旧连接。（任务 2）
4. 自动切换把直连（`direct`）连接换成局域网时，挂在旧连接上的会话照常活着，直到 GUI 把它重开（缓存换掉不等于关连接）。（任务 1、2）
5. 老的密码主机（没有 `fp`、没有 key）：从不被升级循环拨，强制按钮对它不显示（B 没设 relay）；有密码、没 `fp` 的主机设了强制也能存，`establish` 走中继。（任务 1、2、4）

---

### Task 1: hub：`route` 设置、强制走中继、`path` 事件

**Files:**
- Modify: `rust/hub/src/hosts.rs`（`route` 字段、`summary`、`set_route`）
- Modify: `rust/hub/src/link.rs`（`cache_link`、`uncache`、强制时的 `establish`/`request`/`probe`）
- Modify: `rust/hub/src/lib.rs`（`set_route` 命令）
- Modify: `rust/hub/src/presence.rs`（离线带 `error`）
- Test: `rust/hub/src/hosts.rs`、`rust/testkit/tests/route.rs`（新）

**Interfaces:**
- Produces:
  - `Host.route: Option<String>`（`#[serde(default, skip_serializing_if = "Option::is_none")]`）；`impl Host { pub fn forced_relay(&self) -> bool }`（`route.as_deref() == Some("relay")`）。所有现有 `Host { .. }` 字面量补 `route: None`。
  - `Hosts::set_route(&self, id: &str, route: Option<String>) -> Result<bool>`：主机在且值变了才写文件，返回是否变了；主机不在返回 `Ok(false)`。
  - `Hub::cache_link(&self, id: &str, link: Link)`（`async`）：放进 `links`（主机已不在 `hosts` 里就不放、不发），然后发 `path` 事件。`request` 里现在 `links.insert` 那一处改用它。
  - `Hub::uncache(&self, id: &str)`：从 `links` 移出，**不**关连接。
  - `set_route` 命令：存设置；`relay` → `uncache`，再后台（`tokio::spawn`，非 quiet）对这台主机 `request(&host, &Op::Ping)` 一次，让中继连接建好、`path` 事件发出去（失败只记 `warn`）；`auto` → 交给任务 2 的 `upgrade_now(id)`（本任务里先留一个空的 `pub(crate) fn upgrade_now(&self, _id: &str) {}`，任务 2 填）。都记一行 `msg`：`<id>: route relay` 或 `<id>: route auto`。

- [ ] **Step 1: 写测试**
  - `hosts.rs`：
    - `route_reads_absent_as_auto_and_is_written_only_when_forced`：`{"id":"2","name":"b"}` 读出来 `route == None`；`set_route("1", Some("relay"))` 返回 `true`、再设一次返回 `false`、对不存在的 ID 返回 `false`；`summary()` 里这台带 `"route":"relay"`；`set_route("1", None)` 以后文件里没有 `route` 这个键。
    - `old_versions_ignore_route`：在测试里定义一个没有 `route` 字段的 `struct OldHost { id, name, #[serde(default)] password, #[serde(default)] lan }`（等于 0.6.0 的 `Host` 去掉 `fp`），`serde_json::from_str::<Vec<OldHost>>` 读带 `"route":"relay"` 和 `"fp"` 的文件不出错。
  - `testkit/tests/route.rs`（`mod common; use common::*;`，照 `hub.rs` 里 `hub_relay`、`a_on_relay`、`bare_id_prefers_lan` 的写法；用到的这几个 helper 从 `hub.rs` 挪进 `common/mod.rs`）：
    - `forced_relay_ignores_a_working_lan`：A 在 relay 上、局域网通（`a_on_relay(&rig, None)`）；加主机；`set_route relay` 的回复是 `hosts` 事件、这台带 `"route":"relay"`；接下来的事件里有 `{"event":"path","id":a.id,"path":"relay"}`；`apps` 的 `path` 是 `relay`；`rig.streams() > 0`；`saved_hosts` 里这台有 `"route":"relay"`。
    - `forcing_moves_new_requests_off_the_lan`：先 `apps` 走 `lan`（收到 `path lan` 事件），`open` 一个会话（`path lan`），`set_route relay` 以后 `path relay` 事件到来，再 `open` 的 `path` 是 `relay`；第一个会话还活着（`close` 它，收到 `closed` 且 reason 是 `echo ok`）。
    - `forced_relay_down_does_not_fall_back`：强制以后 `rig.stop().await`，`apps` 回 `error`，文本以 `relay unreachable: ` 开头（或者是 relay 停掉前缓存的连接断了以后重新建连接的错误——循环调 `apps` 直到拿到以 `relay unreachable: ` 开头的错，`WAIT` 内）；全程没有一次 `apps` 回 `path lan`。
    - `bad_route_is_refused`：`set_route` 带 `"route":"lan"` 回 `{"event":"error","error":"bad route"}`；对不存在的 ID 回 `unknown host`。
    - `presence_says_why_offline`：presence 跑着（`start_with_presence`，100 ms），强制以后停 relay：等到 `presence` 事件 `online:false`，带 `error` 且以 `relay unreachable: ` 开头。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-hub hosts && cargo test -p rapp-testkit --test route`：编译失败或断言失败。

- [ ] **Step 3: 实现**
  - `establish`：`host.forced_relay()` 时不跑局域网赛跑、不试密码：`self.relay()` 出错 → `relay unreachable: {e:#}`；`Ok(None)` → `relay not set: add the host as id@ip`；有 relay 就 `relay_connect`（不看 `asks_relay`，强制的主机就是在中继上的），成功 → `Link::Relay`，并照旧记 `route` 行。
  - `request`：缓存里的连接和强制设置不符（强制而缓存的不是 `relay`）→ `uncache` 后重新 `establish`。
  - presence：离线时事件加 `"error": format!("{e:#}")`；`hub.log` 的 `presence` 行不变。

- [ ] **Step 4: 跑测试确认通过** — `cd rust && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`。

- [ ] **Step 5: 提交** `feat(hub): per-host forced relay; path events on every new link`

---

### Task 2: hub：自动切到局域网

**Files:**
- Create: `rust/hub/src/upgrade.rs`（时间表和循环）
- Modify: `rust/hub/src/lib.rs`（`Opts.upgrade`、`Hub` 新字段、启动循环、`route_failed` 命令）
- Modify: `rust/hub/src/link.rs`（`relay_connect` 记下 A 报的局域网地址；`try_lan`）
- Modify: `rust/hub/src/main.rs`、`rust/testkit/tests/common/mod.rs`（`Opts` 加字段）
- Test: `rust/hub/src/upgrade.rs`、`rust/testkit/tests/route.rs`、`rust/testkit/tests/common/mod.rs`（`LanGate`）

**Interfaces:**
- Consumes: 任务 1 的 `cache_link`、`Host::forced_relay`、`upgrade_now` 的位置。
- Produces:
  - `pub struct UpgradeTimes { pub first: Duration, pub every: Duration, pub hold: Duration, pub tick: Duration }`，`Default` = 2 s / 30 s / 5 min / 1 s。`Opts.upgrade: UpgradeTimes`。
  - `pub(crate) struct Schedule`（纯数据，不碰网络，`Instant` 由调用方给）：
    - `linked(&mut self, id: &str, path: &str, now: Instant)`：`path != "lan"` → 到期 `now + first`；`lan` → 移出时间表。
    - `tried(&mut self, id: &str, now: Instant)`：没试通 → `now + every`。
    - `failed_move(&mut self, id: &str, now: Instant)`：`hold` 到 `now + hold`。
    - `now_for(&mut self, id: &str, now: Instant)`：马上到期，清掉 `hold`（`set_route auto` 用）。
    - `net_changed(&mut self, now: Instant)`：表里所有主机马上到期（`hold` 照旧算）。
    - `forget(&mut self, id: &str)`；`clear(&mut self)`（`set_home`）。
    - `due(&self, now: Instant) -> Vec<String>`：到期且不在 `hold` 里的。
  - `Hub` 新字段：`schedule: Mutex<upgrade::Schedule>`、`relay_lan: Mutex<HashMap<String, Vec<String>>>`（`relay_connect` 成功时存 `found.lan`）、`times: UpgradeTimes`。
  - `cache_link` 里调 `schedule.linked(id, link.path(), now)`；`forget`、`remove_host` 调 `schedule.forget`；`set_home` 调 `schedule.clear()` 并清 `relay_lan`。
  - `Hub::try_lan(&self, host: &Host) -> Result<Option<Link>>`：地址 = `host.lan` 加 `relay_lan[host.id]`（去重）→ `dial_order` → 只留私有地址；空 → `Ok(None)`；否则在 `QUIET` 里 `first_v2(host, &addrs, key)`，拿到路径是 `lan` 的连接就返回它。
  - `pub(crate) fn worth_trying(host: Option<&Host>, cached_path: Option<&str>) -> bool`（`upgrade.rs`，纯函数）：主机在、不强制、有 `fp`、缓存里有连接且路径不是 `lan` 才 `true`。
  - `pub(crate) async fn run(hub: Arc<Hub>)`（`upgrade.rs`）：每 `tick` 一次：比较 `local_ipv4s()`（排序后）和上一次的，不同 → `net_changed`；对 `due` 里每台主机：`worth_trying` 为 `false` → `forget` 掉不试；否则 `try_lan`：成功 → 再确认主机还在、`at_home` 没换（试之前记下 `home`，比较）、缓存里还是试之前那条（`path()` 不是 `lan`），才 `cache_link` 换进去并记 `<id>: path <旧>→lan`；没通或出错 → `tried`。一台一台来。
  - `upgrade_now(id)` → `schedule.now_for(id, now)`。命令 `route_failed {id}` → `schedule.failed_move(id, now)`。

- [ ] **Step 1: 写测试**
  - `upgrade.rs` 单元测试（`Instant` 自己造，不睡）：
    - `relay_link_is_tried_after_first_then_every`：`linked("a","relay",t0)` → `due(t0+1.9s)` 空，`due(t0+2s) == ["a"]`；`tried("a", t1)` → `t1+29.9s` 空、`t1+30s` 有。
    - `lan_link_leaves_the_schedule`：`linked("a","lan",t0)` → 永远不到期。
    - `failed_move_holds_five_minutes_even_on_net_change`：`failed_move("a",t0)`，`net_changed(t0+1s)` → `due(t0+1s)` 空；`due(t0+5min)` 有。
    - `net_change_makes_everyone_due`、`now_for_clears_the_hold`、`direct_counts_like_relay`。
    - `defaults_match_the_spec`：`UpgradeTimes::default()` 是 2 s、30 s、300 s、1 s。
    - `worth_trying_only_unforced_hosts_with_a_fingerprint_off_the_lan`：有 `fp`、缓存 `relay` → `true`；`direct` → `true`；`lan` → `false`；没缓存 → `false`；主机 `None`（已删）→ `false`；`route: Some("relay")` → `false`；`fp: None`、有 `password`（老的密码主机）→ `false`。
  - `common/mod.rs` 加 `LanGate`：在 `127.0.0.1:0` 上开一个 UDP 转发口，`open` 时把包转给目标（A 的 QUIC 地址），`close` 时丢掉；`pub async fn start(to: SocketAddr) -> LanGate`、`pub fn addr(&self) -> String`、`pub fn open(&self)`、`pub fn close(&self)`。加 `Hub::start_with_upgrade(home, bins, times)`。测试用的时间：`first 200 ms、every 300 ms、hold 2 s、tick 50 ms`。
  - `testkit/tests/route.rs`：
    - `relay_link_moves_to_lan_when_the_lan_opens`：门关着，A 在 relay 上、报的局域网地址是门（`a_on_relay(&rig, Some(vec![gate.addr()]))`）；加主机，`apps` 走 `relay`（收到 `path relay`）；`open` 一个会话（`relay`）；开门；`WAIT` 内收到 `{"event":"path","id":a.id,"path":"lan"}`；`hub.log` 里有 msg `<id>: path relay→lan`；之后 `open` 的 `path` 是 `lan`；第一个会话还活着（`close` 它，reason `echo ok`）。
    - `another_device_on_the_lan_address_is_not_taken`：门转给另一台 A（同一个 key 的第二个 service），等 1.5 s：没有 `path lan` 事件，`apps` 还是 `relay`。
    - `route_failed_holds_the_host`：在 relay 上，发 `route_failed`，开门；1.5 s 内没有 `path lan`；`hold` 过后（`WAIT` 内）收到 `path lan`。
    - `forced_host_is_never_tried_and_auto_tries_at_once`：门开着但先强制（`set_route relay`），1 s 内只有 `path relay`、没有 `path lan`；`set_route auto` 以后 1 s 内（不用等 `first`）收到 `path lan`。
    - `lan_from_the_start_never_touches_the_relay`：门开着，加主机、`apps`、`open` 全是 `lan`，`rig.streams() == 0`。
    - `a_removed_host_is_not_moved`：在 relay 上，`remove_host`，开门；1.5 s 内没有这台的 `path` 事件；再加回来（`add_host`），`apps` 走 `lan`（新连接照常先试局域网）。
    - `set_home_drops_pending_moves`：在 relay 上，`set_home` 换到另一个空目录，开门；1.5 s 内没有 `path` 事件。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-hub upgrade && cargo test -p rapp-testkit --test route`。

- [ ] **Step 3: 实现**（见上面 Interfaces；`main.rs` 用 `UpgradeTimes::default()`，`lib.rs` 的 `run` 里和 presence 一样 spawn、退出时 abort）。

- [ ] **Step 4: 跑测试确认通过** — `cd rust && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings`。

- [ ] **Step 5: 提交** `feat(hub): move relay and direct links to the LAN when it answers`（测试辅助另提交也行：`test(testkit): LanGate`）

---

### Task 3: GUI：本机 ID 先给纯数字，局域网地址折叠

**Files:**
- Modify: `gui/lib/pages/local_section.dart`（`_idRows` 那一段）
- Modify: `gui/lib/service_client.dart`（只在需要时：`shownIds` 不再给设了 relay 的情况用）
- Test: `gui/test/local_section_test.dart`、`gui/test/service_client_test.dart`

**Interfaces:**
- Consumes: `ServiceStatus.relaySet`、`ServiceStatus.id`、`ServiceStatus.lanIds`（`id@ip[:port]`）。
- Produces: 设了 relay 时：
  - 第一行 `ID  <纯数字>  [复制]`（key `copy-id-0`，复制纯数字）；
  - 有局域网地址时下一行是可点的 `▸ 局域网地址（N 个）`（key `lan-fold`），点开变 `▾ 局域网地址（N 个）`，下面每个 `ID@IP` 一行带复制（key `copy-lan-<i>`，提示 `复制 ID`）；
  - 展开状态放在 State 里，不存盘。
  - 没设 relay：照旧 `shownIds`，key `copy-id-<i>`。

- [ ] **Step 1: 写测试**（`local_section_test.dart`，用现有的 `FakeService`）
  - 把 `ids with relay: bare id first` 改成 `with a relay the bare ID comes first and LAN IDs fold`：`copy-id-0` 复制 `123456789`；`find.text('▸ 局域网地址（2 个）')` 有一个；`find.text('123456789@192.168.1.5')` 没有；点 `lan-fold` 以后显示 `▾ 局域网地址（2 个）`，两个地址都在，`copy-lan-1` 复制 `123456789@10.0.0.7`；离开页面再进来（重建 widget）又是折起来的。
  - `with a relay and no LAN address there is no fold row`：`lanIds` 空，`find.byKey(Key('lan-fold'))` 没有，`copy-id-0` 复制纯数字。
  - `every LAN ID has its own copy button`（没设 relay）照旧通过。

- [ ] **Step 2: 跑测试确认失败** — `cd gui && ~/development/flutter/bin/flutter test test/local_section_test.dart`。

- [ ] **Step 3: 实现** — 折叠行用现有 `_row` 的格式（标签列空），文字点击区用 `InkWell` 或 `TextButton`，样式和这一节其他行一致。

- [ ] **Step 4: 跑测试确认通过** — `cd gui && flutter test && flutter analyze`；还原 `pubspec.lock`。

- [ ] **Step 5: 提交** `feat(gui): with a relay, the bare ID first and LAN IDs folded`

---

### Task 4: GUI：路径标签随 hub 更新；强制走中继的按钮和菜单项

**Files:**
- Modify: `gui/lib/hub_client.dart`（`HubHost.route`、`path` 事件、`setRoute`、`routeFailed`、presence 的 `error`）
- Modify: `gui/lib/ui/session_model.dart`（`routeWord`）
- Modify: `gui/lib/ui/main_state.dart`（`relaySet`、`setRoute`、`pathOf`、presence 带错误）
- Modify: `gui/lib/ui/main_window.dart`（把 `monitor.status?.relaySet` 交给 `MainState`）
- Modify: `gui/lib/ui/devices_tab.dart`（路径词、按钮）
- Modify: `gui/lib/ui/sessions_tab.dart`、`gui/lib/ui/top_bar.dart`、`gui/lib/embed/stream_menu.dart`（标签、菜单项）
- Test: `gui/test/hub_client_test.dart`、`gui/test/ui/devices_tab_test.dart`、`gui/test/embed/stream_menu_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: 任务 1 的 `hosts` 事件 `route`、`path` 事件、`set_route` 命令、`presence.error`；任务 2 的 `route_failed`。
- Produces:
  - `HubHost.route`（`String?`）和 `bool get forcedRelay => route == 'relay'`。
  - `HubClient.hostPaths`（`Map<String, String>`，`path` 事件更新）；`List<({String id, String path})> takePaths()`，和 `takePresence` 一样每台主机只留最新一条、读了清空。
  - `HubClient.setRoute(String id, String route) → Future<void>`（发 `set_route`，等 `hosts` 回复）；`HubClient.routeFailed(String id)`（发 `route_failed`，不等）。
  - presence 队列项多一个 `String? error`；`MainState._onHub` 把它交给 `_setOnline(id, online, error: …)`。
  - `String routeWord(String? path, {bool forced = false})`（`session_model.dart`）：`forced && path == 'relay'` → `中继（强制）`，否则 `pathLabels[path] ?? ''`。
  - `MainState.relaySet`（`bool`）和 `void setRelaySet(bool v)`（变了才 notify）；`String? pathOf(String id)` = `hub.hostPaths[id] ?? probes[id]?.apps?.path`；`bool forcedRelay(String id)`；`Future<void> setRoute(String id, bool forced)`（失败把错放进 `hint`，用 `disconnectWord`）。
  - 设备行：路径词 `routeWord(state.pathOf(id), forced: state.forcedRelay(id))`；`relaySet` 时在"用屏幕共享打开"前加 `RappButton.secondary(key: Key('route-toggle'), label: forced ? '恢复自动' : '强制走中继')`，`hubUsable` 才可按。
  - 会话列表、流菜单第一行用 `routeWord(entry.path, forced: state.forcedRelay(entry.id))`。
  - `StreamMenuAnchor`/`StreamMenu` 新参数 `bool? forcedRelay`（`null` = 不显示这一项）、`VoidCallback? onToggleRoute`（`null` = 灰掉）。这一项放在路径那一行下面，`reconnecting` 时不显示；文字自动时 `改走中继`、强制时 `恢复自动选路`；点了先关菜单再回调。`top_bar.dart` 传 `forcedRelay: state.relaySet ? state.forcedRelay(cur.id) : null`、`onToggleRoute: state.hubUsable ? () => state.setRoute(cur.id, !forced) : null`。

- [ ] **Step 1: 写测试**
  - `hub_client_test.dart`：
    - `hosts carry route`：`hosts` 事件里 `{"id":"1","name":"a","route":"relay"}` → `hosts[0].forcedRelay`；没有 `route` 的为 `false`。
    - `path events update hostPaths and queue the latest per host`：发 `path relay` 再 `path lan`（同一台）→ `hostPaths['1'] == 'lan'`，`takePaths()` 只有一条 `lan`，再取为空。
    - `setRoute sends set_route and waits for hosts`：`sent.last` 是 `{"cmd":"set_route","id":"1","route":"relay","req":…}`；回 `hosts` 后 future 完成。
    - `presence carries the error when offline`。
  - `session_model`（放进 `test/ui/overview_model_test.dart` 或新文件 `test/ui/route_word_test.dart`）：`routeWord('relay', forced: true) == '中继（强制）'`，`routeWord('lan', forced: true) == '局域网'`，`routeWord(null) == ''`。
  - `devices_tab_test.dart`：
    - `route toggle shows only with a relay`：`relaySet: false` 没有 `route-toggle`；`true` 时有，文字 `强制走中继`；点了以后 `t.sent` 里有 `set_route … "route":"relay"`；回的 `hosts` 带 `route` 以后按钮文字变 `恢复自动`，再点发 `"route":"auto"`。
    - `device row path follows path events`：`apps` 回 `path lan`，行里是 `局域网`；fake hub 发 `{"event":"path","id":"111","path":"relay"}` 以后是 `中继`；主机强制时是 `中继（强制）`。
    - `offline from presence shows the relay error`：fake hub 发 `presence {id:'111', online:false, error:'relay unreachable: timed out'}` → 行里有 `离线` 和 `中继连不上`。
  - `stream_menu_test.dart`：`forcedRelay: false` 显示 `改走中继`，`true` 显示 `恢复自动选路`，`null` 没有这两项；`onToggleRoute: null` 时那一项灰掉；点了回调一次、菜单关上；`reconnecting` 时不显示。

- [ ] **Step 2: 跑测试确认失败** — `cd gui && flutter test test/hub_client_test.dart test/ui/devices_tab_test.dart test/embed/stream_menu_test.dart`。

- [ ] **Step 3: 实现**（见 Interfaces。`MainState._onHub` 先 `takePaths()` 取走——本任务只用来刷新界面，挪会话在任务 5）

- [ ] **Step 4: 跑测试确认通过** — `cd gui && flutter test && flutter analyze`；还原 `pubspec.lock`。

- [ ] **Step 5: 提交** `feat(gui): route labels follow the hub; force relay per device`

---

### Task 5: GUI：路径变了，把会话一个一个重开过去

**Files:**
- Modify: `gui/lib/ui/main_state.dart`（`reroute`、每台主机一轮的挪动）
- Test: `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: 任务 4 的 `takePaths()`、`hub.routeFailed(id)`；现有 `_connect(r, reconnect: true)`、`_swapIfReady`、`_disconnect`。
- Produces:
  - `Future<bool> reroute(String key)`：只对 `phase == Phase.live`、`lastSid == null`、嵌入式的记录做。和 `reconnect` 一样把旧 sid 放进 `lastSid`、用 `_connect(r, reconnect: true)` 开新的（旧画面留在台上，`_swapIfReady` 在新会话第一个有画面的窗口时换掉旧的）。`_connect` 加参数 `bool reroute = false`：reroute 时开失败或启动失败**不**走 `_disconnect`、不出提示，而是把 `sid` 还原成旧的、`lastSid = null`、`phase = Phase.live`，返回 `false`。换好了返回 `true`；15 秒内没换好算失败：关掉新 sid（`_quiet` + `hub.close`），还原旧的。重开期间记录的 `phase` 保持 `live`（输入照旧送到旧会话）。
  - 每台主机一轮：`_onHub` 从 `takePaths()` 拿到 `(id, path)` 后，对这台主机启动（或更新目标）一轮挪动：按记录的顺序，对每条 `r.id == id && r.path != path` 的记录 `await reroute(r.key)`；每个会话一轮里最多重开一次；一轮在跑时又来同一台主机的 `path`，只记下最新目标，这一轮结束后按它再跑一轮。某个会话失败：目标是 `lan` 时 `hub.routeFailed(id)`，这一轮停下（后面的会话留在原路）。
  - 挪动途中记录被结束（`ending`）、断开或被删：跳过它，不复活。

- [ ] **Step 1: 写测试**（`main_state_test.dart`，用现有的 `opened`、`opens()`、`FakeSessionPort` 写法）
  - `a path change reopens each live session once, one at a time`：同一台主机两个会话，`path` 都是 `relay`；fake hub 发 `path lan`；第一个会话收到一次 `open`（带 `reconnect: true`），在它的新会话出画面之前第二个还没有 `open`；第一个换好以后第二个才 `open`；最后 `opens()` 比开始多 2；两条记录 `path` 都是 `lan`；`hint` 里没有错误；旧 sid 都被 `port.close`。
  - `sessions already on the new path are left alone`：会话 `path lan`，收到 `path lan` → 没有新的 `open`。
  - `a failed reopen stays on its route and tells the hub`：新 `open` 回 `error` → 记录还是旧 sid、`phase live`、`path relay`、`hint` 为空；`t.sent` 里有 `{"cmd":"route_failed","id":…}`；同一轮里第二个会话没有被 `open`。
  - `a reopen that never shows a picture times out`（用 `fakeAsync` 或可注入的超时）：15 s 后新 sid 被关、旧的留着、发了 `route_failed`。
  - `a second path change during a move runs once more with the latest`：挪动中又来 `path relay` → 本轮结束后按 `relay` 再跑，每个会话总共最多两次 `open`。
  - `ending a session mid-move does not bring it back`：挪动中结束第二个会话 → 它没有被 `open`、不在列表里。
  - `forcing relay moves sessions to the relay`：会话 `path lan`，hub 发 `path relay` → 会话被重开，新的 `opened` 带 `path relay`；失败时**不**发 `route_failed`。

- [ ] **Step 2: 跑测试确认失败** — `cd gui && flutter test test/ui/main_state_test.dart`。

- [ ] **Step 3: 实现**（见 Interfaces；非嵌入式会话不挪，下次重连时自然走新路——记在代码注释里）

- [ ] **Step 4: 跑测试确认通过** — `cd gui && flutter test && flutter analyze`；还原 `pubspec.lock`。

- [ ] **Step 5: 提交** `feat(gui): sessions follow the host to its new route, one at a time`

---

### Task 6: 两台机器上的端到端检查

**Files:** 无（只跑、只记录）。

用编出来的真二进制（不是 testkit）在本机走一遍强制和恢复。不改 `scripts/e2e-local.py`。

- [ ] **Step 1:** `cd rust && cargo build --release -p rapp-relay -p rapp-service -p rapp-hub`。在 scratchpad 里建三个目录 `relay/`、`a/`、`b/`；照 `docker/relay/README.md` 起 relay（端口挑一个空的）；A、B 各用自己的 `RAPP_HOME` 和 `RAPP_LOG_DIR`（两个程序都不收参数；数据文件在 `rapp_net::config::local(<RAPP_HOME>)` 下，`service.json` 也放那里），两边的 `service.json` 填同一个接入点和 key；起 A 的 `rapp-service`，起 B 的 `rapp-hub`（stdin 用一个 FIFO 喂命令，stdout 存到文件）。
- [ ] **Step 2:** 依次发：`add_host {id:<A 的纯数字 ID>}`、`apps`（期望 `path` 是 `lan`、事件里有 `path lan`）；`set_route relay`（期望 `hosts` 里带 `"route":"relay"`、随后 `path relay`）；`apps`（`relay`）；`set_route auto`（期望 1 秒内 `path lan`）；`b/hosts.json` 里这台没有 `route` 键。
- [ ] **Step 3:** 停 relay，`set_route relay`，`apps`：期望错误以 `relay unreachable: ` 开头。
- [ ] **Step 4:** 把命令、期望和实际输出写进任务报告；所有进程停掉。任何一步和期望不符，当作缺陷修掉（回到对应任务）再走一遍。

---

## 对照规格

| UX 规格 | 任务 |
|---|---|
| §2 ID 显示 | 3 |
| §3 新连接先试局域网 | 已有（2a）；测试在 2 |
| §3 时间表、切换、逐个重开、失败留原路、日志 | 2（hub）、5（GUI） |
| §4 路径随切换更新、`中继（强制）` | 1（事件）、4（界面） |
| §5 强制走中继：存储、两处入口、马上生效、连不上不退回 | 1、4、5 |
| §8 试通的连接直接留用 | 2（`try_lan` 返回的连接就是缓存的那条） |
| §8 通知用哪种消息 | `path` 事件（1） |
| §8 测试里挡局域网 | `LanGate`（2） |
| §9 各条测试 | 1、2、3、4、5 |
