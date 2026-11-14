# 2c 实现计划：换 key 后所有设备失效，客户端提示重新输入 key

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 relay 上 `rotate-key` 以后，每台设备立刻和中继断开，GUI 明确提示"安全变更：中继换了 key"，并让用户输入新 key；再补一份给人和 agent 看的换 key 操作文档。

**Architecture:** relay 给设备记录加 `stale`，换 key 时标记全部并以关闭码 4 断开；`stale` 的设备只能用新口令重新入网（保留 ID），旧口令得到 `key changed`。设备的两侧（service、hub）把关闭码 4 和 `key changed` 当成一种专门的错误，GUI 据此显示提示和"输入新 key"按钮。

**Tech Stack:** Rust（quinn 0.11、tokio、serde_json）；Flutter GUI。

**Spec:** `docs/superpowers/specs/2026-11-14-relay-device-2c-design.md`（下称"2c 规格"）。

## Global Constraints

- 基于 main（`f03af66` 或之后），在新分支 `feat/relay-2c`（worktree）上做。
- 关闭码 `4`，关闭原因 `key changed`；请求的错误文本 `key changed`。新 key 也不对时，service 报 `bad key`。不是 `stale` 的设备口令不对：回 `bad key`，关闭码 `5`，关闭原因 `bad key`。客户端（service、hub）收到关闭码 4/5 或 `key changed`/`bad key` 就停止，不再拨号，直到 key 变了。
- 设备记录 `stale: bool`：`#[serde(default, skip_serializing_if = "is_false")]`，老的 `devices.json` 照样能读。
- 任何口令不对的入网（含 `stale` 设备）都调用 `enroll_backoff.fail`（当攻击处理，用户 2026-11-14 改定）；`enroll_per_ip_per_min` 限速照旧。
- GUI 文案（照抄）：状态行 `安全变更：中继换了 key`（警示色）；说明 `这台设备已经和中继断开。请向管理中继的人要新 key，再输入。`；按钮 `输入新 key`（`Key('enter-new-key')`）；对话框标题 `输入新 key`；新 key 也不对时状态 `出错：新 key 不对`；`disconnectWord('key changed')` → `中继换了 key，请到 本机 → 输入新 key`。
- key 文本和 `trust()` 的值不得出现在日志、状态、错误文本里（`show_key` 除外）。service 只在内存里记 key 的哈希。
- 用户同时在改仓库：不碰仓库根目录的 `README.md`、`docs/archives/`、`tasks/` 和 main 工作区里用户改着的文档（`docker/relay/README.md` 要改，它不在此列）。按文件名 `git add`，不用 `git add -u/-A/.`、`git stash/checkout/restore/reset`。不跑 `cargo fmt`；只对改过的文件跑 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。
- `flutter test` 会改 `gui/pubspec.lock`：不要提交（`git show HEAD:gui/pubspec.lock > gui/pubspec.lock` 还原）。Flutter 在 `~/development/flutter/bin/flutter`，cargo 在 `~/.cargo/bin`。
- 测试不用端口 21116–21119、22026–22029。
- 每个 Rust 任务结束：`cd rust && cargo test --workspace` 全过，`cargo clippy --workspace --all-targets -- -D warnings` 无警告。GUI 任务结束：`flutter test` 全过、`flutter analyze` 无问题。
- 不发版，不改版本号。提交信息结尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. 换 key 后，新客户端收到关闭码 4 就停：service 和 hub 都不再用旧 key 拨号（在线探测也不拨），所以同一个出口 IP 后面的新设备不会因为旧 key 重试把这个 IP 锁住或耗尽限速。（任务 1、2）
2. 换 key 时 relay 正在转发的中继会话：连接都被断开，设备不再自动重连；输入新 key 后恢复，ID 不变。（任务 1、2）
3. relay 在标记完 `stale`、断开连接之前重启（或写文件失败）：重启后不能出现"口令换了、设备却没被标记"的状态——先写 `devices.json`，再换口令哈希；任何一步失败，`rotate-key` 都报错，并且不显示新 key。（任务 1）
4. 用户输入的新 key 带了空格或换行：照现有 `set_relay` 的处理去掉首尾空白，不能因此报"新 key 不对"。（任务 3）
5. 设备没设中继（只用局域网）：GUI 不出现提示和按钮。（任务 3）

---

### Task 1: relay：`stale`、关闭码 4、`key changed`

**Files:**
- Modify: `rust/relay/src/store.rs`（`Device.stale`、`mark_all_stale`、`enroll` 去掉 `stale`）
- Modify: `rust/relay/src/admin.rs`（`set_join` 在 `rotate` 时调用标记和断开）
- Modify: `rust/relay/src/server.rs`（`CLOSE_KEY_CHANGED = 4`；`stale` 当作没入网；`try_enroll` 的 `key changed`）
- Modify: `rust/relay/src/main.rs`（`devices` 的最后一栏）
- Test: `store.rs`、`admin.rs` 的单元测试；`rust/relay/tests/` 里现有的集成测试文件加用例

**Interfaces:**
- Produces:
  - `Registry::mark_all_stale(&self) -> Result<usize>`：把没吊销、没 `stale` 的设备标上，先写盘，返回标了几台。
  - `Registry::enroll`：对 `stale` 的设备去掉 `stale`，返回"有变化"，`id` 不动。
  - `Control::key_changed(&self)`（`admin` 用）：以 `CLOSE_KEY_CHANGED`、`b"key changed"` 关闭所有已入网的连接，并把它们移出在线表。
  - `set_join(.., rotate: true)` 的顺序：`mark_all_stale` → `set_join_hash` → `key_changed()` → 审计 `rotate_key {hash, stale: n}`。前两步任何一步失败都返回错误（`rotate-key` 不显示 key）。
  - 连接建立时：`enrolled = known 存在 && !revoked && !stale`。
  - `try_enroll`：口令不对、并且 `registry.get(fp)` 是 `stale` 的 → `Err("key changed")`，不调用 `enroll_backoff.fail`。

- [ ] **Step 1: 写失败的测试**
  - `store.rs`：`mark_all_stale_skips_revoked_and_persists`；`enroll_clears_stale_and_keeps_the_id`；`old_devices_json_without_stale_loads`。
  - 集成测试（进程内 relay，两台设备）：
    - `rotate_key_closes_every_device_with_code_4`：两台都注册以后 `rotate-key`，两边的 `next_push` 都得到 `Pushed::Closed { code: 4, .. }`。
    - `a_stale_device_with_the_old_key_gets_key_changed_and_is_never_locked`：同一个来源用旧 key 连 10 次，每次都是 `key changed`，没有一次是 `locked`；接着同一个来源的另一台设备用新 key 入网成功。
    - `the_new_key_brings_the_old_id_back`：用新 key 重连、`register` 原来的 ID，结果是 `Same`/ok；另一台能 `connect` 到它。
    - `a_stale_device_is_offline_to_others`。
    - `rotate_key_fails_without_showing_a_key_when_devices_json_cannot_be_written`（数据目录里的 `devices.json` 设成只读）。
- [ ] **Step 2:** `cargo test -p rapp-relay`，确认这些测试失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `cargo test --workspace` 全过，clippy 无警告。
- [ ] **Step 5: 提交** `feat(relay): rotate-key drops every device until it enters the new key`

### Task 2: 设备两侧：`key changed`

**Files:**
- Modify: `rust/conn/src/relay.rs`（让 `key changed` 能被认出来）
- Modify: `rust/service/src/relay_link.rs`（`End::KeyChanged`、不重试、`bad key` 的判断）
- Modify: `rust/hub/src/link.rs`（关闭码 4 / `key changed` 原样报出）
- Test: `rust/testkit/tests/` 里 relay 相关的测试文件加用例

**Interfaces:**
- Consumes: 任务 1 的关闭码 4 和 `key changed`。
- Produces:
  - `rapp_conn::relay::KEY_CHANGED: &str = "key changed"`；`pub fn is_key_changed(e: &anyhow::Error) -> bool`（错误文本里含 `key changed`）。`Pushed::Closed { code: 4, reason }` 原样传出。
  - service：`End::KeyChanged`。`session` 里 `Closed{code:4}`、以及 `dial`/`register` 的错误 `is_key_changed` 都返回它。处理和 `End::Revoked` 一样：设状态、等 `settings.changed()`、不退避重试。状态错误：本进程第一次遇到时记下当前 key 的 `join_hash`，报 `key changed`；之后用一把哈希不同的 key 又遇到，就报 `bad key`。记一条日志 `relay_key_changed {}`。
  - hub：经中继的 `connect_to`/`relay_to`/探测在这条 relay 连接以关闭码 4 结束后失败时，错误是 `key changed`（不是 `connection closed`）。不加重试的特殊逻辑：hub 的 relay 缓存按 key 文本判断，用户输入新 key 后自然重连。

- [ ] **Step 1: 写失败的测试**（进程内 relay + 真 service + hub）
  - `service_stops_and_says_key_changed_after_rotate`：`rotate-key` 后 `status` 在 2 秒内变成 `relay: "error"`、`relay_error: "key changed"`；之后 5 秒 relay 上没有这台设备新的连接；`service.log` 里搜不到新旧 key 的文本。
  - `a_new_key_reconnects_with_the_same_id`：IPC `set_relay`（地址不变、新 key）后 `status` 变成 `connected`；另一台经中继能连上它。
  - `a_wrong_new_key_says_bad_key`：`set_relay` 填第三把 key → `relay_error: "bad key"`。
  - `hub_reports_key_changed`：`rotate-key` 后 hub 对经中继的主机 `open` → 错误含 `key changed`。
- [ ] **Step 2:** 确认这些测试失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `cargo test --workspace` 全过，clippy 无警告。
- [ ] **Step 5: 提交** `feat(service,hub): stop and say "key changed" when the relay changes its key`

### Task 3: GUI：提示和"输入新 key"

**Files:**
- Modify: `gui/lib/pages/local_section.dart`（`_relayState`、`_stateRow`、新对话框）
- Modify: `gui/lib/ui/lifecycle.dart`（`disconnectWord`）
- Test: `gui/test/` 里本机一节和 `lifecycle` 的测试文件

**Interfaces:**
- Consumes: 任务 2 的 `status.relay_error == "key changed"` / `"bad key"`；现有的 `set_relay`（`m.setRelay`，地址、key）。
- Produces:
  - `relayError == 'key changed'` 时，状态行显示 `安全变更：中继换了 key`（警示色）、下面的说明和 `输入新 key` 按钮。`relayError == 'bad key'` 且这次的 key 是从"输入新 key"保存的（`_State` 里一个布尔值）时显示 `出错：新 key 不对`，按钮保留；其他情况照现在的 `_relayState`。`relayError == 'bad key'` 时（service 已停止重试）也显示 `输入新 key` 按钮。
  - `_enterNewKey(ServiceStatus st)`：对话框只有一个 key 输入框（`autofocus`、`obscureText`），保存时用 `st.relayAddr` 和去掉首尾空白的 key 调用 `setRelay`，失败照现有的方式提示 `失败：…`。
  - `disconnectWord`：`key changed` 的判断放在 `bad key` **之前**。

- [ ] **Step 1: 写失败的测试**：`key changed` 时出现三段文字和按钮；按钮打开对话框，保存时以原地址和去掉空白的新 key 调用 `setRelay`；之后状态是 `bad key` → `出错：新 key 不对`；没设中继时不出现提示和按钮；`disconnectWord('key changed')` 和 `disconnectWord('relay: key changed')` 的文字。
- [ ] **Step 2:** `flutter test`，确认这些测试失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `flutter test` 全过，`flutter analyze` 无问题；还原 `pubspec.lock`。
- [ ] **Step 5: 提交** `feat(gui): tell the user the relay key changed and ask for the new one`

### Task 4: 操作文档和端到端检查

**Files:**
- Modify: `docker/relay/README.md`（新的一节 `Changing the key / 换 key`，内容照 2c 规格 §5，中英都写）
- Modify: `rust/relay/src/main.rs` 的 `USAGE`（只在 `rotate-key` 的说明里加一句"所有设备会断开，需要重新输入 key"）

- [ ] **Step 1: 写文档。** 每条命令可以直接复制执行；每一步写清楚预期的输出（`rotate-key` 打出一行 `rapp…`；`devices` 的最后一栏 `stale`）。
- [ ] **Step 2: 本机端到端**：一个本地 relay（不用 22026–22029，例如 24026）、两个数据目录（A 被控、B 操作）、`fake-rapp-host`。B 经中继打开 A 的窗口 → `rotate-key` → A、B 的 GUI（或 `status`）都显示"中继换了 key"、会话断开、relay 上没有重连 → `devices` 两台都是 `stale` → A 输入新 key → A 回到 `connected`、`devices` 里 A 的 `stale` 没了、ID 不变 → B 输入新 key 后能重新打开 A 的窗口 → 再填一把错的 key，看到 `出错：新 key 不对`。每一步记下命令和结果，写进报告。
- [ ] **Step 3: 汇总**：`cargo test --workspace`、`flutter test`、`flutter analyze` 全过。
- [ ] **Step 4: 提交** `docs(relay): how to change the key`
