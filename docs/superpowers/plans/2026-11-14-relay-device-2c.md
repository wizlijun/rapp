# 设备收尾（2c）实现计划：吊销名单、换 key 传下去、"接受新设备"、访问记录、redirect

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 relay 上吊销的设备，其他设备都不再认；在一台设备上填了新 key，它认识的设备自动换上并往下传；每台设备能关上"接受新设备"；被控端的访问记录能看到认识、取消认识、开关、key 更换这些事；设备跟得上 relay 的 `redirect`。

**Architecture:** 规则放在 `rapp-conn`（吊销名单文件、hello 里的新字段、"谁的 key 更新"），被控的一侧（rapp-service）负责写 `revoked.json` 和 `service.json`，操作的一侧（rapp-hub）只读这两个文件，要换 key 时通过本机 IPC 让 service 存。key 搭在每次握手的 hello 和回复上传，不新开请求。

**Tech Stack:** Rust（quinn 0.11、tokio、serde_json）；Flutter GUI。

**Spec:** `docs/superpowers/specs/2026-11-14-relay-device-2c-design.md`（下称"2c 规格"）。上级：`docs/superpowers/specs/2026-11-13-rapp-relay-design.md`（"relay 规格"）§7.3、§7.4、§8、§11.2。

**前一份：** 2b 已合进本地 main（`cb75793`，未推送）。打洞不在本计划里（用户定：放到以后）。

## Global Constraints

- 基于 main（`cb75793` 或之后），在新分支 `feat/relay-2c`（worktree）上做。
- 新文件 `<home>/revoked.json`：`{"fps":["<64 位小写 hex>", …]}`，权限 0600（`rapp_net::config::write_private`）。只加不减。service 写，hub 只读。
- `service.json` 新字段：`key_gen`（u64，不写为 0，为 0 时不写出）；`accept_new`（bool，不写为开，开时不写出）。
- "谁的 key 更新"：`(key_gen, key 文本)` 按字典序比较，大的新。只换成 relay 那一半和本机现有 key 相同的 key（都没有也算相同）；本机没有 key 时不换。
- 在设置里填了不同的 key：`key_gen = max(旧 key_gen + 1, 当前 Unix 秒)`。从别人那里换上：用对方的 `key_gen`。
- hello（B→A）新字段：`"id"`（B 本机 ID，自报）；对指纹对得上的主机加 `"key"`、`"key_gen"`。回复（A→B）在 A 更新时加 `"key"`、`"key_gen"`。老版本忽略这些字段。
- 拒绝原因的固定文本：`revoked`、`not accepting new devices`、`not trusted`（照旧）、`too many redirects`。
- 新 IPC 命令：`set_accept_new {"on": bool}` → `{"ok":true}`；`adopt_key {"key","key_gen","from"}` → `{"ok":true,"adopted":bool}`，key 不对回 `bad key`。`status` 多 `"accept_new": bool`。
- 新日志事件（rapp-service 的 `service.log`）：`unpaired {fp, name, reason:"revoked"}`；`accept_new {on}`；`key_changed {by:"settings"|"peer", from?}`；`peer_key_changed {id, old, new}`。`trust` 的 `result: "refused"` 行带 `reason`，按来源地址每 60 秒最多一行，被压下的条数在下一行的 `count` 里。
- 访问记录（`history`）新收：`trust`（`paired`、`refused`）、`unpaired`、`accept_new`、`key_changed`、`peer_key_changed`、`relay` 且 `error == "relay identity mismatch"`。`trust` 的 `known` 不收。
- key 文本和 `trust()` 的值不得出现在日志、事件、错误文本、`history` 里（`show_key` 除外）。`key_changed` 只记发生了。
- 从别人那里换上 key 不得重连 relay、不得断开任何会话。
- 用户同时在改仓库：不碰 `README.md`、`docs/archives/`、`tasks/` 和 main 工作区里用户改着的文档。按文件名 `git add`，不用 `git add -u/-A/.`、`git stash/checkout/restore/reset`。不跑 `cargo fmt`；只对改过的文件跑 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。
- `flutter test` 会改 `gui/pubspec.lock`：不要提交（`git show HEAD:gui/pubspec.lock > gui/pubspec.lock` 还原）。Flutter 在 `~/development/flutter/bin/flutter`，cargo 在 `~/.cargo/bin`。
- 测试不用端口 21116–21119、22026–22029（用户机器上的 rapp 在用）。
- 每个 Rust 任务结束：`cd rust && cargo test --workspace` 全过，`cargo clippy --workspace --all-targets -- -D warnings` 无警告。GUI 任务结束：`flutter test` 全过、`flutter analyze` 无问题。
- 不发版，不改版本号。提交信息 `feat(conn): …`、`feat(service): …`、`feat(hub): …`、`feat(gui): …`、`test(testkit): …`，结尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. 一台被吊销的设备手里还有旧 key、证明完全对得上：A 和 B 两个方向都必须拒绝它，也不能把新 key 发给它、不能接受它推来的 key。（任务 1、2、3）
2. 两台设备先后换了 key、或者一台时钟快了一天：最后所有设备落在同一把 key 上，不来回翻；同一把 key 互相握手不产生 `key_changed`。（任务 1、3、6）
3. B 经中继开着会话时，B 从别人那里换上新 key：会话不断，hub 不重连 relay。（任务 3）
4. "接受新设备"关着时，已认识的设备照常连、照常传 key；新设备证明对上也被拒，A 的访问记录里有一条带原因的拒绝。（任务 2）
5. `revoked.json` 坏了或读不出来：不当成"没有吊销"静默继续——记一条警告，并且已经在内存里的名单照旧生效；下一次 relay 推名单时整个重写。（任务 1、2）

---

### Task 1: conn：吊销名单、hello 的新字段、"谁的 key 更新"

**Files:**
- Create: `rust/conn/src/revoked.rs`
- Modify: `rust/conn/src/paired.rs`（`id` 字段、`remove`、`find_by_id`）
- Modify: `rust/conn/src/hello.rs`（新字段和拒绝规则）
- Modify: `rust/conn/src/lib.rs`（导出）
- Test: 各文件里的单元测试；`rust/conn/tests/trust.rs` 加用例

**Interfaces:**
- Produces:
  - `pub struct Revoked`；`Revoked::load(home: &Path) -> Result<Revoked>`（文件不在 = 空；解析不了 = Err）、`Revoked::empty(home: &Path) -> Revoked`、`fn contains(&self, fp: &Fp) -> bool`、`fn merge(&self, fps: &[Fp]) -> Result<Vec<Fp>>`（并进内存和文件，返回原来没有的那些；写文件失败时内存照样更新、返回 Err）。
  - `Paired`：`Entry` 多 `#[serde(default, skip_serializing_if = "Option::is_none")] id: Option<String>`；`fn add(&self, fp: &Fp, name: &str, id: Option<&str>) -> Result<()>`（改签名，调用处都改）；`fn remove(&self, fp: &Fp) -> Result<Option<String>>`（返回去掉的那项的名字，不在返回 `None` 且不写文件）；`fn other_with_id(&self, id: &str, fp: &Fp) -> Option<Fp>`（同 ID、不同指纹的一项）。
  - `pub fn newer(theirs: (&Key, u64), mine: Option<(&Key, u64)>) -> bool`：`mine` 为 `None` 返回 false；relay 那一半不同返回 false；否则 `(gen, 文本)` 比较。放在 `hello.rs`。
  - `Me` 多 `key_gen: u64`。`send_hello(s, f, me, share_key: bool)`：`share_key` 时（并且有 key）带 `key`、`key_gen`；总是带 `id`。
  - `Accepted` 多 `offered: Option<(Key, u64)>`：回复里带了能解析的 key 时填（不在这里判断新旧）。`read_welcome(s, f, key, want_id, known, revoked: &Revoked)`：`f.peer` 在名单里 → `bail!("revoked")`（在其他检查之前）。
  - `hello_server(s, f, me, paired, revoked: &Revoked, accept_new: bool)`：顺序是 吊销 → 已认识 → 证明。吊销回 `revoked`；不认识且 `!accept_new` 回 `not accepting new devices`（证明对不对都一样）；否则照旧。新认识时把 hello 的 `id` 存进 `paired`。B 带来的 key 能解析就放进 `Greeted.offered: Option<(Key, u64)>`，`Greeted.id: Option<String>`。回复里：`me.key` 和 B 带来的 `key_gen`/key 比较，`newer((me.key, me.key_gen), Some(B 的))` 为真时带上 `key`、`key_gen`；B 没带 key 时用 `key_gen` 字段比（只比 gen），B 什么都没带就不发。
  - 拒绝时回给对方的错误文本就是原因本身（`revoked`、`not accepting new devices`、`not trusted`），返回的 `Err` 文本也一样。

- [ ] **Step 1: 写失败的测试**
  - `revoked.rs`：`merge_is_additive_and_persists`（先并 [a,b] 返回 [a,b]，再并 [b,c] 返回 [c]；重新 `load` 后 a、b、c 都在；文件权限 0600）；`unparsable_file_is_an_error`。
  - `paired.rs`：`remove_returns_the_name_and_rewrites`、`other_with_id_finds_a_different_fp`、`old_file_without_id_still_loads`。
  - `hello.rs`：`newer_compares_gen_then_text`（gen 大的新；gen 相等文本大的新；同一把 key 不新）、`newer_refuses_another_relay`（`Key::new_for_relay(&fp1)` 对 `Key::new_for_relay(&fp2)` 返回 false；两个 `new_local()` 可以比）、`newer_needs_a_key_of_my_own`。
  - `conn/tests/trust.rs`（用文件里现有的握手搭法）：
    - `a_revoked_device_is_refused_with_a_good_proof`：B 有同一把 key，A 的名单里有 B 的指纹 → B 读到错误 `revoked`，A 的 `paired.json` 不变。
    - `a_revoked_host_is_refused_by_b`：B 的名单里有 A 的指纹 → `read_welcome` 返回 `revoked`。
    - `accept_new_off_refuses_strangers_but_not_known_devices`。
    - `key_travels_both_ways`：B 的 `(key2, gen 5)`、`share_key` → A（`gen 3`）的 `Greeted.offered` 是 key2；反过来 A 新时回复带 key，`Accepted.offered` 是它；同一把 key 时都不带。
    - `hello_carries_the_id_into_paired`。

- [ ] **Step 2:** `cd rust && cargo test -p rapp-conn` —— 新测试编译失败或失败。

- [ ] **Step 3: 实现** 上面的接口。`Revoked` 内部用 `Mutex<BTreeSet<Fp>>`，写文件按排序后的列表。

- [ ] **Step 4:** `cargo test --workspace` 全过（改了签名的调用处：`rust/service/src/peer.rs`、`rust/service/src/relay_link.rs`、`rust/hub/src/link.rs`——这一步只让它们编译过：service 传 `&Revoked::empty(..)` 之外的真实值留给任务 2，hub 留给任务 3；可以先在 `State`/`Hub` 里放一个从 `home` 加载的 `Revoked`，`accept_new` 先传 `true`，`share_key` 先传 `false`）。clippy 无警告。

- [ ] **Step 5: 提交** `feat(conn): revocation list, key offers in the hello, accept-new refusal`

### Task 2: service：吊销推送、"接受新设备"、key_gen、换 key、访问记录、限速

**Files:**
- Modify: `rust/service/src/config.rs`（`key_gen`、`accept_new`）
- Modify: `rust/service/src/state.rs`（`revoked`、`adopt_key`、`status`）
- Modify: `rust/service/src/relay_link.rs`（`Revoked` 推送）
- Modify: `rust/service/src/peer.rs`（`greet` 用名单、开关、换 key；`trust` 拒绝限速）
- Modify: `rust/service/src/ipc.rs`（`set_accept_new`、`adopt_key`、`set_relay` 记 `key_gen`、`in_history`）
- Modify: `rust/wire/src/tls.rs`（`device_server_config` 单向流 0）
- Test: `rust/testkit/tests/service.rs` 加用例；`config.rs`、`ipc.rs` 单元测试

**Interfaces:**
- Consumes: 任务 1 的 `Revoked`、`Paired::remove/other_with_id`、`newer`、`Greeted.offered/id`、`hello_server` 新签名。
- Produces:
  - `Config.key_gen: u64`（`#[serde(default, skip_serializing_if = "is_zero")]`）、`Config.accept_new: Option<bool>` 和 `fn accept_new(&self) -> bool`（默认 true）。
  - `State.revoked: Revoked`（启动时 `Revoked::load`，失败记一条 `Warn` 用 `empty`）。
  - `State::adopt_key(&self, key: &Key, gen: u64, from: &str) -> bool`：`newer` 为真才存 `key`、`key_gen`，记 `key_changed {by:"peer", from}`，`notify()`；**不** bump `relay_settings`。
  - `State::revoke(&self, fps: &[Fp])`：`revoked.merge`，对每个新加进来的、在 `paired` 里的指纹 `paired.remove`，记 `unpaired {fp, name, reason:"revoked"}`；写失败记 `Warn`。`relay_link` 收到 `Pushed::Revoked` 调它（原来的 `relay_revoked` 计数行去掉）。
  - `set_relay`：key 文本变了时 `key_gen = max(key_gen + 1, now)`，记 `key_changed {by:"settings"}`；没变不动。清掉 key 时 `key_gen` 不动。
  - `greet`：传 `&state.revoked`、`cfg.accept_new()`、`me.key_gen`；`Greeted.offered` 有值时调 `adopt_key(.., from = 对方名字或指纹前 8 位)`；新认识、`Greeted.id` 有值、`paired.other_with_id` 找到旧指纹时记 `peer_key_changed {id, old, new}`。
  - 拒绝限速：`State.refusals: Mutex<HashMap<IpAddr, (Instant, u32)>>`；同一 IP 60 秒内第二次起只计数；过了 60 秒的下一次拒绝写一行并带 `count`（被压下的条数，0 不写）。`serve_device` 和 `relay_link::serve_relayed` 的拒绝都走它（`serve_relayed` 的来源是 relay 报的 `peer` 地址）。表项超过 1024 时清掉过期的。
  - IPC：`set_accept_new {on}`：存、记 `accept_new {on}`、`notify()`；值没变不记。`adopt_key {key, key_gen, from}`：key 解析不了回 `bad key`，否则 `{"ok":true,"adopted": adopt_key(..)}`。`status` 加 `accept_new`。
  - `in_history` 按 Global Constraints 收新事件。
  - `device_server_config` 加 `.max_concurrent_uni_streams(0u32.into())`（只改服务端；连 relay 的客户端连接要收 relay 的单向推送，不能动）。

- [ ] **Step 1: 写失败的测试**（`rust/testkit/tests/service.rs`，用现有的进程内 relay 和 `hello_and_send`/`dial2` 搭法）
  - `a_revoked_push_unpairs_and_refuses`：B 先连上被认识；relay 上 `revoke` B → A 的 `paired.json` 没有 B，`revoked.json` 有，日志有 `unpaired`；B 再连被拒，原因 `revoked`；`history` 里有 `unpaired` 和这条拒绝。
  - `accept_new_off_keeps_known_devices`：`set_accept_new false` 后，认识的 B 照常 `ping`；同 key 的新 B2 被拒，原因 `not accepting new devices`；`status.accept_new == false`；`history` 有 `accept_new`。
  - `a_newer_key_in_the_hello_is_adopted_without_a_relay_restart`：B 的 hello 带 `(key2, gen 大)`、A 认识 B → `service.json` 的 key 变成 key2、`key_gen` 是 B 的；`relay` 状态一直是 `connected`、relay 那边 A 没有重连；日志 `key_changed` 不含 key 文本（在整份 `service.log` 里搜 key2 的文本，搜不到）。
  - `the reply carries A's newer key`、`same key, no key_changed`。
  - `set_relay_bumps_key_gen_only_when_the_key_changes`（单元测试或 IPC 测试）。
  - `refusals_are_rate_limited_per_source`：同一来源 5 次失败 → 只有 1 行 `trust refused`；把限速窗口做成可注入（`State` 上一个 `Duration` 字段，测试设成 200 ms）后再失败一次 → 第 2 行带 `count: 4`。
  - `adopt_key` IPC：旧 gen 回 `adopted:false`；坏 key 回 `bad key`。
  - `device_server_config` 的单元测试：服务端不收单向流（仿 `server_allows_no_uni_streams`）。

- [ ] **Step 2:** 跑这些测试，确认失败。
- [ ] **Step 3: 实现**上面的接口。
- [ ] **Step 4:** `cargo test --workspace` 全过，clippy 无警告。
- [ ] **Step 5: 提交** `feat(service): act on revocation, accept-new switch, take newer keys, history events`

### Task 3: hub：把 key 发给认得的主机、换 key 交给 service、拒绝被吊销的主机

**Files:**
- Modify: `rust/hub/src/link.rs`（`send_hello` 的 `share_key`、`read_welcome` 的名单、`offered`、relay 缓存）
- Create: `rust/hub/src/adopt.rs`（通过 IPC 交给 service）
- Modify: `rust/hub/src/lib.rs`（模块）
- Test: `rust/testkit/tests/hub.rs`、`rust/hub/src/adopt.rs` 单元测试

**Interfaces:**
- Consumes: 任务 1 的 `send_hello(.., share_key)`、`read_welcome(.., revoked)`、`Accepted.offered`；任务 2 的 IPC `adopt_key`、`service.json` 的 `key_gen`。
- Produces:
  - `rapp_conn::settings::Settings` 多 `key_gen: u64`（从 `service.json` 读，缺省 0）。
  - hub 每次握手前 `Revoked::load(home)`（读不出来记一条 `Warn`、当空——hub 只读，service 是写的一方，review focus 5 由 service 保证）。
  - `share_key = host.fp == Some(facts.peer)`：只对存过指纹并且这次对得上的主机发 key。`add_host`（还没存指纹）不发。
  - `adopt::offer(home: &Path, key: &Key, gen: u64, from: &str)`：`Accepted.offered` 有值、并且 `newer(offered, 本机 settings)` 为真时调用；读 `<home>/ipc.token` 和 `service.json` 的 `ipc_port`（缺省 22029），连 `127.0.0.1`，发 token 行和 `adopt_key`，等一行回复，整个 2 秒超时；失败只记 `Debug`。在后台任务里跑，不挡握手。
  - relay 缓存（`RelayCache`）改为按 `addr`、`key.relay`（relay 那一半）和本机指纹判断能不能复用；key 文本变了但这三样没变 → 复用连接（`join` 只在第一次入网时用，已入网的连接不需要）。
  - 主机出示的指纹在名单里：`read_welcome` 返回 `revoked`，这台主机的 `presence` 错误和 `add_host`/`open` 的错误都是 `revoked`。

- [ ] **Step 1: 写失败的测试**（`rust/testkit/tests/hub.rs`，进程内 relay + 真 service + hub）
  - `a_host_with_a_newer_key_hands_it_to_b`：A 的 `key_gen` 比 B 大 → B 探测一次之后 B 的 `service.json` key 等于 A 的；B 的 `service.log` 有 `key_changed {by:"peer"}`。
  - `b_hands_its_newer_key_to_a_known_host`：反方向。
  - `a_stranger_host_gets_no_key`：B 用 `id@ip` 加一台没存指纹的主机 → hello 里没有 `key`（用一个记录 hello 的假 A 检查）。
  - `a_key_change_keeps_relayed_sessions`：B 经中继开着一个会话（`fake-rapp-host`），B 的 key 被换（`adopt_key`）→ 会话的流继续通（再收发一行），relay 上 B 的连接数不变。
  - `a_revoked_host_is_refused`：B 的 `revoked.json` 里有 A → `presence` 离线、`error: "revoked"`。
  - `adopt.rs`：service 不在时 2 秒内返回、不 panic。

- [ ] **Step 2:** 确认失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `cargo test --workspace` 全过，clippy 无警告。
- [ ] **Step 5: 提交** `feat(hub): pass keys to known hosts, hand adopted keys to the service, refuse revoked hosts`

### Task 4: 跟着 relay 的 `redirect` 走

**Files:**
- Modify: `rust/conn/src/relay.rs`（`Redirected` 错误）
- Modify: `rust/service/src/relay_link.rs`（`register` 被 redirect）
- Modify: `rust/hub/src/link.rs`（第一次 `connect` 被 redirect）
- Test: `rust/conn/tests/relay.rs`（假 relay）、`rust/testkit/tests/hub.rs`

**Interfaces:**
- Produces:
  - `#[derive(Debug)] pub struct Redirected { pub to: String }`（`impl Display`：`redirect to <to>`；`impl std::error::Error`）。`RelayConn` 的请求收到 `{"ok":false,"error":"redirect","relay":"…"}` 时返回 `anyhow::Error::new(Redirected { to })`；`relay` 字段缺失或不像 `主机:端口` 时当普通错误 `redirect`。
  - service：`register` 返回 `Redirected` → 关掉这条连接，`RelayConn::dial(.., &to, ..)` 再 `register` 一次；第二次还是 `Redirected` → `End::Failed { err: "too many redirects" }`。跳过去的地址不存。
  - hub：`relay()` 之后的第一次 `connect_to` 返回 `Redirected` → 用 `to` 重新 dial，换进缓存（缓存的 `addr` 仍记设置里的地址，避免每次重来），再 `connect_to` 一次；第二次 → 错误 `too many redirects`。
  - 两边都用同一个 `key`，所以照旧核对 relay 的身份（`Expect::Pin`）。

- [ ] **Step 1: 写失败的测试**
  - `conn/tests/relay.rs`：`a_redirect_reply_is_typed`（假 relay 对 `register` 回 redirect → `downcast_ref::<Redirected>()` 拿到地址）。
  - `testkit`：两个进程内 relay，用同一份数据目录复制出来的身份（同一个指纹、同一把 key）；第一个对一切请求回 redirect 到第二个（给 `rapp_relay::server` 加一个只在测试里用的开关，或者在 testkit 里写一个只会回 redirect 的假 relay，用同一个身份）→ A 注册到第二个上，B 经第二个连上 A。再让第二个也回 redirect → 状态里的错误是 `too many redirects`。
  - 指向身份不同的 relay → 错误 `relay identity mismatch`。

- [ ] **Step 2:** 确认失败。
- [ ] **Step 3: 实现。** 假 relay 优先放在 testkit 里，不改 relay 服务端的正式代码。
- [ ] **Step 4:** `cargo test --workspace` 全过，clippy 无警告。
- [ ] **Step 5: 提交** `feat(conn): follow one relay redirect`

### Task 5: GUI："接受新设备"开关、新的访问记录、新的错误词

**Files:**
- Modify: `gui/lib/service_client.dart`（或现有放 `ServiceStatus`/IPC 的文件：`acceptNew`、`setAcceptNew`）
- Modify: `gui/lib/pages/local_section.dart`（开关一行）
- Modify: `gui/lib/access_log.dart`（新事件）
- Modify: `disconnectWord` 所在文件（新错误词）
- Test: 对应的 `gui/test/…_test.dart`

**Interfaces:**
- Consumes: 任务 2 的 `status.accept_new`、IPC `set_accept_new`、新日志事件。
- Produces:
  - `ServiceStatus.acceptNew`（`status` 里没有这个字段时为 true）；`setAcceptNew(bool)`。
  - 本机一节：`hasKey` 时在 key 那一行下面显示 `接受新设备` 和一个 `Switch`（`Key('accept-new')`）；切换时调 `setAcceptNew`，失败照现有的方式提示 `失败：…` 并把开关放回去。下面一行小字：开着时 `有 key 的设备都能连进来`，关着时 `只认已经认识的设备`。
  - `historyRow` 的结果一栏（照 2c 规格 §6 的表）：
    - `trust` + `paired` → `认识了这台设备`；`trust` + `refused` → `拒绝认识：<原因词>`（警示）。原因词：`revoked` → `已吊销`，`not accepting new devices` → `不接受新设备`，`not trusted` → `key 不对`，`timeout` → `超时`，其他原样。带 `count` 时后面加 `（另有 N 次）`。
    - `unpaired` → `已吊销，不再认识`（警示）；`who` 用 `name`，没有就用 `fp` 前 8 位。
    - `accept_new` → `开始接受新设备` / `不再接受新设备`；`who` 和路径空着。
    - `key_changed` → `key 已更换（本机设置）` / `key 已更换（来自 <from>）`。
    - `peer_key_changed` → `对方的密钥变了`（警示）；`who` 是 `id`。
    - `relay` + `relay identity mismatch` → `中继身份对不上`（警示）。
  - `disconnectWord`：`revoked` → `已吊销`；`not accepting new devices` → `对方不接受新设备`；`too many redirects` → `中继转向太多次`。

- [ ] **Step 1: 写失败的测试**：每种新事件一条 `historyRow` 测试（含 `count`、警示色）；开关显示条件（没 key 不显示）、点了调 `setAcceptNew`、失败时开关回原位；三个 `disconnectWord`。
- [ ] **Step 2:** `flutter test` 确认失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `flutter test` 全过，`flutter analyze` 无问题；还原 `pubspec.lock`。
- [ ] **Step 5: 提交** `feat(gui): accept-new switch, revocation and key events in 访问记录`

### Task 6: 端到端检查（本机，三台"设备"）

在本机用三个数据目录（A、B、C）、一个进程内或本地 Docker 的 relay，端口用 24026/24028/24029 一类（不碰 22026–22029）。被控的一侧用 `fake-rapp-host`。每一步记下命令和看到的结果，写进报告。

- [ ] **Step 1: 换 key 传下去**：三台都入网、B 连过 A、C 连过 B 的被控端（C→B 是主机）。`rapp-relay rotate-key`，把新 key 只填到 A。等 ≤ 70 秒：B、C 的 `service.json` key 都变成新的（C 是经 B 传到的），三份 `service.log` 各有一条 `key_changed`，日志里搜不到 key 文本。期间 B 经中继开着的会话没断。
- [ ] **Step 2: 吊销**：在 relay 上 `revoke` C。A、B 的 `paired.json` 没有 C，`revoked.json` 有；C 去连 A 被拒（`revoked`），A 的访问记录有 `unpaired` 和拒绝；C 自己的状态是"出错：已吊销"。
- [ ] **Step 3: 时钟快了的设备**：把 B 的 `key_gen` 手改成比现在大一天的值，在 A 上再填一把新 key → 结果按 `(key_gen, 文本)` 定下来，所有设备落在同一把上，之后 3 分钟内没有新的 `key_changed`（不来回翻）。
- [ ] **Step 4: 接受新设备**：A 关上开关；一台新的 D（同 key、没连过 A）连 A 被拒（`not accepting new devices`）；B 照常连。再打开，D 能连上，访问记录有"认识了这台设备"。
- [ ] **Step 5: 汇总**：`cargo test --workspace`、`flutter test`、`flutter analyze` 全过。
