# 会话标注 第一期 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 被控端服务里存一张会话标注表（标题 + 备注），任何客户端和被控端本机都能看、能改、能一键还原；有标注的会话在每台客户端上常驻一张卡，终端没了能「启动」。

**Architecture:** 服务新模块 `labels.rs` 持有表并原子写 `labels.json`，三个加法 Op（`watch_labels` 长连接整表推送、`set_label`、`reset_label`）和三条 IPC 命令；hub 每台在线 host 一个 labels watch（复用 terms.rs 的 watch 状态机），发 `labels` 事件；GUI 把标注填进 `SessionEntry`，卡片、菜单、对话框都在 `session_block.dart` 里只写一份。

**Tech Stack:** Rust（tokio、serde_json）、Flutter/Dart。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-session-labels-design.md`（§7 优先于正文）。

## Global Constraints

- 标题：去首尾空白、无控制字符、≤64 字符（`rapp_term::id::clean_name` 同一规则，但允许空串）。备注：换行折成空格后去首尾空白、无控制字符、≤200 字符。两者都空 = 还原。
- 最多 500 条，超了 `set_label` 新键回 `err("标注已满 500 条")`。
- 文件 `state.home/labels.json` = `{"version":1,"rev":N,"labels":{app:{title,note,at}}}`；读不了 → 空表 + 一条日志，首次写前挪成 `labels.json.bad`。
- `log_fields` 对三个 Op 只记 op 名，不记 app、标题、备注。
- 协议是加法：旧端回 `unknown op` → hub 发 `{"event":"labels","id","unsupported":true}`，不再问。
- `OpenTerm` 加可选 `label_from`（`skip_serializing_if = None`），服务在同一把锁里把标注从旧 id 搬到新 id。
- GUI 文案：「改标题和备注…」「还原」「留空用默认：<默认标题>」「已还原，标题回到 <默认标题>」「设备离线，连上后再改」「已停止」「启动」「打开」「原来的目录没有记下，已在家目录新开」。
- 卡片只有一份实现（`session_block.dart`）；带备注的卡 72 高，否则 56。
- 功能分支不改版本号、不 push、不发版；flutter 跑完还原 `gui/pubspec.lock`。

## Review Focus

1. 同一 app 两个客户端并发改：后写覆盖，两边最终同一 rev 同一内容 → testkit 两客户端测试覆盖。
2. 乱序推送（hub 重连时旧 rev 晚到）：GUI 丢掉 rev 更小的表 → `hub_client` 测试 `older rev is dropped`。
3. 设备从在线变离线：常驻的「打开/已停止」卡收起，已打开的会话保留最后的标注 → `_mapEntries` 测试。
4. 旧被控端（不认 Op）：菜单不出现，没有报错提示 → hub `labels_unsupported_event` 单测 + GUI 菜单隐藏测试。
5. 标题含换行/超长/全空白：服务拒绝或折叠，GUI 对话框显示红字不关 → 服务单测 + 对话框测试。

---

### Task 1: 协议 Op

**Files:** Modify `rust/net/src/msg.rs`（Op 枚举 + tests）

**Produces:** `Op::WatchLabels`、`Op::SetLabel { app: String, title: String, note: String }`、`Op::ResetLabel { app: String }`；`Op::OpenTerm` 加 `label_from: Option<String>`（serde default + skip none）。JSON：`{"op":"watch_labels"}`、`{"op":"set_label","app","title","note"}`、`{"op":"reset_label","app"}`。

- [ ] 测试 `label_ops_have_their_json_shape`：三个 Op 的 to_value 等于上面的 JSON；`OpenTerm{label_from:None}` 序列化不带 `label_from`，带值时带。
- [ ] 加枚举分支，修好所有 `Op::OpenTerm { .. }` 构造点（`cargo build --workspace` 无错）。
- [ ] `cargo test -p rapp-net msg` 通过，提交。

### Task 2: 服务标注表 + Op + IPC

**Files:** Create `rust/service/src/labels.rs`；Modify `service/src/lib.rs`（mod）、`state.rs`（字段 `labels: crate::labels::Labels`，在建 State 处 `Labels::load(&home)`，有 why 就记日志 `labels_unreadable`）、`peer.rs`（分发）、`ipc.rs`（命令）、`term.rs`（OpenTerm 的 label_from）。

**Produces:**
- `pub struct Label { pub title: String, pub note: String, pub at: u64 }`（Serialize/Deserialize/Clone/PartialEq）
- `Labels::load(home: &Path) -> (Labels, Option<String>)`
- `Labels::table(&self) -> Value` = `{"rev":N,"labels":{...}}`
- `Labels::set(&self, app: &str, title: &str, note: &str) -> Result<u64, String>`（返回新 rev；两者清洗后都空 = reset）
- `Labels::reset(&self, app: &str) -> Result<u64, String>`（没有也 Ok，rev 不变）
- `Labels::rename(&self, from: &str, to: &str) -> Result<u64, String>`（没有 from 的条目就 Ok 不变）
- `Labels::subscribe(&self) -> tokio::sync::watch::Receiver<u64>`
- `pub async fn request(state, s, peer, op) -> Result<()>`：WatchLabels 先发 `{ok:true,rev,labels}`，之后每次 rev 变发整表，B 关流就结束（照 `term::follow` 的 select）；Set/Reset 回 `{ok,rev}` 或 `err(原因)`；每次改动后 `state.notify()`。
- IPC：`labels` → `{ok,rev,labels}`；`set_label {app,title,note}`；`reset_label {app}`。

- [ ] 单测：`missing_file_is_empty`、`set_saves_and_load_reads_back`、`both_empty_is_reset`、`rev_goes_up_by_one_per_change`、`reset_of_nothing_keeps_rev`、`title_rule`（65 字、控制字符拒绝，`"后".repeat(64)` 收）、`note_newlines_fold_to_spaces`、`note_over_200_refused`、`five_hundred_and_first_refused_but_edit_of_existing_ok`、`unreadable_file_moves_to_bad_on_first_write`、`rename_moves_the_label`、`log_fields_carry_only_the_op`。
- [ ] 实现，`cargo test -p rapp-service labels` 通过。
- [ ] `term.rs`：`OpenTerm { label_from: Some(old) }` 成功拿到新 id 后 `state.labels.rename(old, new)` 然后 `state.notify()`；`log_fields` 不变。
- [ ] 提交。

### Task 3: hub labels watch + 命令

**Files:** Create `rust/hub/src/labels.rs`；Modify `hub/src/terms.rs`（把 watch 状态机的 ensure/stop/retain 做成 `Watches` 方法，terms 自己改用它们）、`lib.rs`（字段 `labels: terms::Watches`，命令路由 `"set_label" | "reset_label"`）、`presence.rs` 和 `watch.rs`（terms 调用旁边并列 labels）。

**Produces:**
- 事件 `{"event":"labels","id","rev","labels"}`、`{"event":"labels","id","unsupported":true}`、`{"event":"labels","id","error"}`（重试中）。
- GUI 命令 `set_label {id,app,title,note}` → `{"event":"label_set","id","app","rev"}`；`reset_label {id,app}` → `label_reset`。
- `labels::ensure_watch(hub,&host)`、`labels::stop_watch(hub,id)`、`labels::stop_gone(hub,&hosts)`。

- [ ] 单测 `labels_event_shapes`（成功、unsupported）。
- [ ] 实现；`after_end` 复用（`unknown op` → Unsupported）；off 不会出现，当 Retry。
- [ ] `cargo test -p rapp-hub` 通过，提交。

### Task 4: testkit 端到端

**Files:** Create `rust/testkit/tests/hub_labels.rs`（照 `hub_terms.rs` 起 service + 两个 hub）。

- [ ] 测试 `two_clients_see_one_label`：hub1 `set_label` → hub2 几秒内收到 `labels` 事件带该标题；`reset_label` 后两边表里没有这条。
- [ ] 测试 `open_term_label_from_moves_it`（若 hub_terms 测试能开终端则加；不能则在 service 单测覆盖 rename 即可）。
- [ ] `cargo test --workspace --no-fail-fast` 通过（linux_detach_test 在新 worktree 里缺 rapp-session 是已知的），提交。

### Task 5: GUI 数据层

**Files:** Modify `gui/lib/hub_client.dart`、`gui/lib/service_client.dart`、`gui/lib/ui/session_model.dart`、`gui/lib/ui/main_state.dart`；Create `gui/lib/ui/labels.dart`。

**Produces:**
- `labels.dart`：`class SessionLabel {title, note}`、`class LabelTable {rev, Map<String,SessionLabel> labels; fromJson}`、`String? cleanLabelTitle(String)`、`String cleanLabelNote(String)`（与服务同规则，给对话框做即时校验）。
- `HubClient.labels: Map<String, LabelTable>`、`HubClient.labelsUnsupported: Set<String>`；`setLabel(id, app, title, note)`、`resetLabel(id, app)`（`_request` 等 `label_set`/`label_reset`）；`labels` 事件 rev 小于手上的丢掉。
- `ServiceConnection.labels()/setLabel/resetLabel`，`ServiceMonitor` 在 changed 后重取，`ServiceMonitor.labels: LabelTable?`。
- `SessionEntry.label: SessionLabel?`；`SessionEntry.defaultTitle`（原来的标题）；`title` 有非空标注标题时用它。
- `MainState.labelFor(String? device, String app) -> SessionLabel?`（device null = 本机，读 monitor）、`titleOf(String? device, String app, String fallback) -> String`、`labelsReady(String? device) -> bool`、`setLabel/resetLabel(device, app, …)`；`labelOf(AppRef)` 先走 `titleOf`；`open_apps_menu` 显示 `titleOf` 并把 App 名放小字。

- [ ] 测试：`older rev is dropped`、`unsupported is remembered`、`entry title prefers label`、`labelOf prefers label`。
- [ ] 实现，`flutter test` 相关文件通过，提交。

### Task 6: 常驻卡片（打开 / 已停止 / 启动）

**Files:** Modify `gui/lib/ui/session_model.dart`（`SessionEntry` 加 `standby: Standby?`，`enum Standby { open, stopped }`）、`main_state.dart` `_mapEntries`、`overview_model.dart`。

- 对每台**在线且 labels 已到**的设备，表里每个 app：已有 entry → 不加；终端在 `termLists[id]` 里或不是终端 → `Standby.open`；终端不在 → `Standby.stopped`。lamp 为 `Lamp.notOpened`，key 仍是 `device/app`。
- 分组内排在末尾（`_byDeviceThenApp` 之后把 standby 的挪到组尾）。
- 点卡：open → `openOrSwitch(id, app, title)`；stopped → `MainState.startStopped(id, app)` = `hub.openTerm(id, app:…, labelFrom: app)` 然后照 `openText` 切过去，并 hint「原来的目录没有记下，已在家目录新开」。
- standby 卡不参与计数、`currentKey`、⌘数字切换、步进（`stepKey` 的 within 只含 open 的）。

- [ ] 测试：`labelled terminal gone shows stopped card at group end`、`live labelled app not open shows 打开`、`offline device hides standby cards`、`reset removes the card`、`start sends label_from`。
- [ ] 实现、通过、提交。

### Task 7: 卡片上的标注：菜单、对话框、备注行、本机列

**Files:** Modify `gui/lib/ui/session_block.dart`、`gui/lib/ui/inbound.dart`、`gui/lib/ui/overview.dart`；Test `gui/test/ui/session_labels_test.dart`。

- `SessionBlock` 加备注行（有 note 时高 72，`Tooltip` 全文）、standby 右侧动作文字（「打开」/「启动」）、终端有自定义标题时第二行开头用程序名（`entry.fg ?? termKindWord`）。
- 菜单（右键 `onSecondaryTapUp`、长按）：`showLabelMenu(context, state, device, app, defaultTitle, label)` 一处实现，`SessionBlock` 和被接入卡共用；不支持或没到时不出现；离线时两项灰掉并在菜单里写「设备离线，连上后再改」。
- 对话框 `LabelDialog`：标题、备注两行、灰字「留空用默认：…」；保存失败红字不关。
- 被接入卡改为 `SessionBlock` 的共用外框/文字部件（抽成 `SessionCardBody` 或给 `SessionBlock` 加 `trailing`/`onTap: null` 参数），右侧「断开」；标题用 `titleOf(null, app, inboundTitle(app))`，备注同样显示。
- 本机列被接入卡下面列出本机有标注、没人接入的 app，同一张卡，只有菜单。

- [ ] 测试：`menu shows edit and reset`、`reset hint names default`、`dialog error keeps it open`、`note line makes card 72`、`menu hidden when unsupported`、`inbound card shows label and kicks`、`local labelled not-accessed list`、`custom title second line starts with program`。
- [ ] 实现、通过、提交。

### Task 8: 收尾

- [ ] `tasks/todo.md` 加：第二期（钉住、快照恢复，规则见 spec §7.2）+ 实机检查 1–8。
- [ ] 门禁：`cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`、`flutter analyze`、`flutter test`；还原 pubspec.lock。
- [ ] `git merge main` → main 上 `git merge --no-ff feat/session-labels -m "merge: 会话标注（feat/session-labels）"`。不 push。
