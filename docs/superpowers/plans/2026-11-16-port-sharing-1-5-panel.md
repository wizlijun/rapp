# 端口分享 第 1.5 步：设备面板和远程设置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设备面板里选中一台设备（或"本机"），看到它分享的端口和 `http://<ID>.rapp:<端口>` 地址；输入端口号就替它分享，点一下"只给谁"就改范围，按两次就取消分享；结果写在那台设备自己的 `local/shares.json` 里，重启后还在。

**Architecture:** 目标设备这一侧：`rapp-service` 多三个设备请求 `shares`、`share`、`unshare`，过授权检查点前三步（`admit`），和本机 IPC 的 `share`、`unshare` 走同一段新代码 `sharing.rs`，日志里写"谁设的"。发起这一侧：本机 IPC 的 `shares`、`share`、`unshare` 多一个可选参数 `to`，带了就经第 1 步的 `pipe::ask`（`Outbound`：局域网 → relay）去问目标设备，并把指纹换成显示名。界面：新文件 `shares_section.dart`，"本机"和远程设备共用，经 `ServiceMonitor` 上一条专用的 IPC 连接调用。

**Tech Stack:** Rust（`rust/` 工作区：tokio、serde_json，不加依赖）；Flutter（`gui/`，不加依赖）。

**Spec:** `docs/superpowers/specs/2026-11-15-rapp-port-sharing-panel-design.md` 第 2 稿（下称"规格"）。背景：主规格 `2026-11-15-rapp-port-sharing-design.md` §5.1、§6、§14；第 1 步上半的计划 `2026-11-15-port-sharing-1a-base.md`（代码的起点）。

## Global Constraints

- 代码的起点是分支 `feat/port-share-base`。Task 1 第 0 步开新分支 `feat/port-share-panel`，先并入 `origin/main`（0.10.4 的界面改动）和本地 `main`（这几份文档）。
- Rust 在 `rust/` 下跑：单个 crate `cargo test -p <crate>`，整体 `cargo test --workspace`；每个任务结束时 `cargo build --workspace` 没有警告。找不到 `cargo` 时先 `export PATH=$HOME/.cargo/bin:$PATH`。
- Flutter 在 `gui/` 下跑：`~/development/flutter/bin/flutter test`、`~/development/flutter/bin/flutter analyze`（没有新的问题）。跑完测试如果 `gui/pubspec.lock` 变了，`git checkout gui/pubspec.lock` 还原，不提交它。
- **不动 `rust/relay`，不动 `rust/hub`。** hub 不参与（规格 §4）。
- 三个设备请求只过检查点前三步：`Peer.fp` 是 `None` → `not supported`；服务器设备 → `host only`（这一轮恒为通过）；托管策略 → `policy`（这一轮恒为通过）。用 `forward.rs` 里已有的 `admit`，不另写。
- 回给对方的错误文本，逐字：`not supported`、`host only`、`policy`、`bad port`、`bad allow`、`limit`。
- "只给谁"在线上一律是 64 位十六进制的完整指纹（`Fp` 的 `Display`/`FromStr`）。目标设备不要求认识它。
- 远程设置不动 `raw`、`open_web`（规格 §1）。
- 不轮询：只在选中设备时、每次设置成功后、按"刷新"时问一次（规格 §6.5）。
- 发起设置的设备上不存任何东西；离线就不显示上次的表。
- 日志里永远不出现 key、口令、流里的内容。
- 面向用户的文字一律中文，逐字照这里写：
  - 段落标题 `端口`，按钮 `刷新`、`打开`、`复制`、`取消分享`、`分享`、`保存`、`取消`
  - 输入框占位 `端口号`、`备注，可不填`
  - `所有设备`、`只给 <名字>、<名字>`、`只给 <名字>（不含本机）`、`本机`
  - `正在读取…`、`没有分享端口`、`离线，读不到它的端口`、`对方的 rapp 还不支持分享端口`、`对方的策略不允许远程设置`、`最多分享 64 个端口`、`端口号是 1 到 65535 的数字`、`本机的 rapp 服务没有在运行`
  - `这台电脑还没有启用 .rapp 域名，地址现在只能复制。`
  - 小窗口：标题 `谁能用这个端口`，选项 `所有设备`、`只给勾选的设备`，候选只有本机时 `别的设备连过这台以后才能选`
  - 敏感端口提醒：目标设备回的 `warn` 原文（`分享这个端口，等于把这台机器能到的网络也交出去`）
  - 其他错误：`出错了：<原文>`

### 计划定的（规格 §9 留给实现计划的）

1. **参数名是 `to`**，和 `pipe` 命令同名，值是 9 位 ID 或 `<ID>.rapp`（`pipe::target_id` 认的写法）。`to` 是本机自己的 ID 时当作不带 `to`。
2. **共用的代码**：新文件 `rust/service/src/sharing.rs` 只管"改这台设备自己的分享表"，本机 IPC 和远程请求都调它。本机 IPC 的三个命令从 `ipc.rs` 挪到新文件 `rust/service/src/share_cmds.rs`，它决定改本机还是经 `pipe` 去问别的设备。`ipc.rs` 只剩分派。
3. **`allow` 的写法**：本机 IPC 上，每一项要么是完整指纹（不要求认识），要么照旧按名字或指纹前几位在 `paired.json` 里找（给命令行用）。远程请求上只认完整指纹，别的一律 `bad allow`。
4. **设备请求的 `ports`、`port`、`allow` 用 `serde_json::Value` 装**，在 `sharing.rs` 里校验。这样端口写错回 `bad port`，不会因为整条解析失败落进 `unknown op`，被面板当成"旧版本"。
5. **旧版本**：目标设备回 `unknown op` 或 `bad request` 时，发起这一侧的 IPC 回 `old version`。
6. **"谁设的"**：`share`、`unshare` 两种日志行加 `by`。本机设的写 `"by":"local"`；远程设的写 `"by":"<指纹前 8 位>"`，再加 `peer.fields` 给的 `peer`、`path`、`name`。远程请求被检查点拒绝时记 `share_refused {op, reason, peer, path, name?}`（警告级）。远程的 `shares`（只读）成功时不记。
7. **界面的 IPC 连接**：IPC 一条连接上的命令是一条接一条处理的，远程请求最多要等 6 秒（沿用 `HOSTS_WAIT`）。`ServiceMonitor` 为这三个命令另开一条连接，不和 `status` 刷新挤在一起。
8. **"打开"可用的条件**：服务状态里有 `"rapp_names": true`（这一轮没有，第 4 步加），这个分享给本机（`mine`），而且不是 22 端口（`web`）。
9. **Windows 上的 `openUrl`**：加一个分支 `Process.start('cmd', ['/c', 'start', '', url])`。
10. **显示名在服务里算**（规格 §5 的取法），界面只显示。名字一律过 `clean_name`：别的设备给的名字不可信。

## Review Focus

规格没有写、但最可能让用户碰上的五种情况。每条的测试已经加进对应的任务。

1. **远程请求慢的时候本机面板别的地方跟着卡。** 对方离线时一次 `shares` 要等满 6 秒；如果和 `status` 走同一条 IPC 连接，这 6 秒里本机状态也不刷新。→ Task 5 的 `remote share calls use their own connection`。
2. **切换设备时，上一台的回复晚到。** 先选 A（离线，6 秒后才回），马上换成 B，A 的"离线"不能盖在 B 的表上。→ Task 6 的 `a late reply for the previous device is dropped`。
3. **端口号的各种写法。** 空、`0`、`65536`、`80a`、前后带空格、全角数字 `８０００`、`-1`。前后空格去掉后照常接受，其余在本地就提示 `端口号是 1 到 65535 的数字`，不发请求。→ Task 6 的 `port input`。
4. **别的设备给的名字。** 目标设备 `paired.json` 里的名字带控制字符、双向控制符、超长，或者是空的。→ Task 3 的 `names_from_the_other_device_are_cleaned`。
5. **`to` 写的是本机自己的 ID。** 当作本机，直接改本机的表，不经 relay 绕一圈。→ Task 3 的 `to_this_device_is_local`。

---

## File Structure

| 文件 | 负责什么 |
|---|---|
| `rust/net/src/msg.rs`（改） | `Op::Shares`、`Op::Share`、`Op::Unshare` |
| `rust/conn/src/paired.rs`（改） | `Paired::list` |
| `rust/service/src/sharing.rs`（新） | 改这台设备的分享表（校验、写入、切断、"谁设的"日志）；受理三个设备请求 |
| `rust/service/src/share_cmds.rs`（新） | 本机 IPC 的 `shares`、`share`、`unshare`：本机的，或带 `to` 经 `pipe` 问别的设备；显示名 |
| `rust/service/src/ipc.rs`（改） | 三个命令改成调 `share_cmds` |
| `rust/service/src/forward.rs`（改） | `admit` 改成 `pub(crate)` |
| `rust/service/src/pipe.rs`（改） | `ask` 带回对方指纹；`PipeErr::Old`；`pipe::set` |
| `rust/service/src/peer.rs`（改） | `serve_request` 多三个分支 |
| `rust/cli/src/say.rs`（改） | `allow` 变成对象数组后照旧打名字 |
| `rust/testkit/tests/common/sharing.rs`（新） | 从 `forward.rs` 挪出来的辅助函数 |
| `rust/testkit/tests/share_set.rs`（新） | 远程设置的测试，含三台设备和重启 |
| `gui/lib/shares.dart`（新） | 分享表的数据类型、`SharesApi`、错误换成中文 |
| `gui/lib/service_client.dart`（改） | 三个命令；`ServiceMonitor implements SharesApi`；`ServiceStatus.rappNames` |
| `gui/lib/ui/shares_section.dart`（新） | "端口"这一段 |
| `gui/lib/ui/allow_dialog.dart`（新） | "谁能用这个端口"小窗口 |
| `gui/lib/ui/devices_tab.dart`、`gui/lib/ui/main_window.dart`（改） | 插入这一段 |
| `gui/lib/term/term_stage.dart`（改） | `openUrl` 的 Windows 分支 |

---

### Task 1: 三个设备请求的消息，和改分享表的共用代码

**Files:**
- Modify: `rust/net/src/msg.rs`
- Create: `rust/service/src/sharing.rs`；Modify: `rust/service/src/lib.rs`（`mod sharing;`）
- Modify: `rust/service/src/ipc.rs`（`share`、`unshare`、`allowed` 挪走）
- Create: `rust/service/src/share_cmds.rs`
- Test: `rust/net/src/msg.rs`、`rust/testkit/tests/forward.rs`（接着加）

**Interfaces:**
- Produces:
  - `Op::Shares`；`Op::Share { #[serde(default)] ports: Value, #[serde(default, skip_serializing_if = "Option::is_none")] note: Option<String>, #[serde(default, skip_serializing_if = "Value::is_null")] allow: Value }`；`Op::Unshare { #[serde(default)] port: Value }`
  - `sharing::By<'a>`：`Local` | `Remote(&'a Peer)`；`fn fields(&self, more: Value) -> Value` 给日志行加 `by`（和远程时的 `peer`、`path`、`name`）
  - `sharing::Allow`：`Names`（本机 IPC：完整指纹或名字）| `Fps`（远程：只认完整指纹）
  - `sharing::share(state: &State, req: &Value, allow: Allow, by: &By) -> Result<Vec<Shared>, String>`：`req` 里读 `ports`、`note`、`allow`，`By::Local` 时还读 `raw`；`Err` 是要回的错误文本
  - `sharing::unshare(state: &State, port: &Value, by: &By) -> Result<bool, String>`
  - `share_cmds::{shares, share, unshare}`：这一个任务里还只有本机的写法，签名同 `ipc.rs` 原来的三个函数；Task 3 给它们加 `to`

- [ ] **Step 0: 开分支，并入两条 main**

```bash
cd /Users/bruce/git/rapp
git worktree add .claude/worktrees/port-share-panel -b feat/port-share-panel feat/port-share-base
cd .claude/worktrees/port-share-panel
git merge origin/main     # 0.10.4 的界面改动
git merge main            # 端口分享的规格、评审、这份计划
```

有冲突时停下来报告，不要自己挑一边。合完跑 `cargo test --workspace` 和 `flutter test`，都过了再往下。

- [ ] **Step 1: 写测试**

`msg.rs` 的 `share_requests` 里加：

```rust
assert_eq!(serde_json::to_value(Op::Shares).unwrap(), json!({"op":"shares"}));
assert_eq!(
    serde_json::from_value::<Op>(json!({"op":"share","ports":[8000],"note":"jupyter"})).unwrap(),
    Op::Share { ports: json!([8000]), note: Some("jupyter".into()), allow: Value::Null }
);
// A bad port still parses: sharing.rs answers "bad port", not peer.rs "unknown op".
assert!(serde_json::from_value::<Op>(json!({"op":"share","ports":[70000]})).is_ok());
assert!(serde_json::from_value::<Op>(json!({"op":"unshare","port":"x"})).is_ok());
assert_eq!(serde_json::to_value(Op::Share { ports: json!([22]), note: None, allow: Value::Null }).unwrap(),
           json!({"op":"share","ports":[22]}));
```

`forward.rs`（IPC 那一组）里加：

```rust
#[tokio::test]
async fn a_local_share_and_unshare_are_logged_as_local() {
    // ipc share 8000 → log line "share" has by == "local"; ipc unshare 8000 → "unshare" has by == "local"
}

#[tokio::test]
async fn ipc_allow_takes_a_full_fingerprint_it_does_not_know() {
    // allow: [64 hex of a fresh identity] → ok; shares.json has that fp in allow
    // allow: ["abababab"] (8 hex, unknown) → "unknown device: abababab" (unchanged)
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-net share_requests; cargo test -p rapp-testkit --test forward local_share`
Expected: 编译失败（`Op::Shares` 不存在）或断言失败（日志里没有 `by`）。

- [ ] **Step 3: 实现**

- `msg.rs` 加三个变体，字段如 Interfaces。
- `sharing.rs`：`share` 的校验、`Patch`、`share_all`、日志、`allow_changed` 时 `forwards.cut` 照搬 `ipc.rs` 现在的 `share`；日志行 `share {port, allow: <个数>}` 经 `by.fields` 加上 `by`。`allow` 的解析：`Allow::Fps` 时每一项必须 `parse::<Fp>()` 成功，否则 `bad allow`；`Allow::Names` 时先试 `parse::<Fp>()`，不行再走原来的 `paired.find`。`By::Remote` 时 `Patch.raw` 恒为 `None`。`unshare` 同理，`was` 为真才记日志、总是 `cut`（照搬）。
- `share_cmds.rs`：`ipc.rs` 原来的 `shares`、`share`、`unshare`、`allow_names`、`share_url`、`port_of` 挪过来；`share`、`unshare` 改成调 `sharing::share(state, cmd, Allow::Names, &By::Local)` 再组回原来的回复。
- `ipc.rs` 的分派改调 `share_cmds::*`。

- [ ] **Step 4: 跑**

Run: `cargo test -p rapp-net && cargo test -p rapp-service && cargo test -p rapp-testkit --test forward && cargo test -p rapp-cli`
Expected: 全部 PASS（1a 的测试一条不改就过）。

- [ ] **Step 5: Commit**

```bash
git add rust/net/src/msg.rs rust/service/src/{sharing,share_cmds,ipc,lib}.rs rust/testkit/tests/forward.rs
git commit -m "feat(service): one code path for changing the share table, logged with who set it"
```

---

### Task 2: 目标设备受理 `shares`、`share`、`unshare`

**Files:**
- Modify: `rust/service/src/sharing.rs`、`rust/service/src/peer.rs`、`rust/service/src/forward.rs`（`admit` → `pub(crate)`）
- Modify: `rust/conn/src/paired.rs`
- Create: `rust/testkit/tests/common/sharing.rs`（从 `forward.rs` 挪 `echo`、`share_file`、`start_sharing`、`sharing`、`sharing_ports`、`Visitor`、`visitor`、`ask`、`forward`、`read_all`，改成 `pub`）；Modify: `rust/testkit/tests/common/mod.rs`（`pub mod sharing;`）、`rust/testkit/tests/forward.rs`（改用它们）
- Test: `rust/testkit/tests/share_set.rs`（新）、`rust/conn/src/paired.rs`

**Interfaces:**
- Consumes: Task 1 的 `sharing::{share, unshare, By, Allow}`、`Op::{Shares, Share, Unshare}`。
- Produces:
  - `Paired::list(&self) -> Vec<(Fp, String)>`：文件里的顺序
  - `sharing::serve(state: &Arc<State>, s: Pipe, op: Op, peer: Peer) -> Result<()>`：回一行 JSON 后关流
  - `sharing::table(state: &Arc<State>) -> Vec<(Share, bool)>`：整张表和每个端口现在有没有服务在听；探测从 `share_cmds::shares` 挪过来（`LISTENING_WAIT`，同时探），本机 IPC 的 `shares` 也改用它
  - 三个请求的回复（规格 §5，逐字段）：
    - `shares` → `{"ok":true,"shares":[{"port","note","allow":[{"fp","name"}],"listening"}],"known":[{"fp","name"}]}`；`name` 是目标设备 `paired.json` 里的名字过 `clean_name`，没有就是 `""`；`listening` 来自 `sharing::table`
    - `share` → `{"ok":true,"shared":[{"port"},{"port","warn"}]}`，`warn` 只在敏感端口上有
    - `unshare` → `{"ok":true,"was":<bool>}`
  - 测试辅助：`common::sharing::*`，签名不变

- [ ] **Step 1: 写测试**

`paired.rs`：`list_is_in_file_order`。

`share_set.rs`（一台目标 A，用 `start_sharing`；访问者 `visitor()` 经 `ask` 直接发设备请求）：

```rust
#[tokio::test]
async fn shares_is_the_whole_table_and_known_is_paired_json() {   // 规格 §8 第 5 条
    // A shares P with allow = [x] (not B), and Q for everyone; B has connected once (so it is in paired.json)
    // B asks shares → both P and Q, P's allow == [{"fp": x, "name": ""}]
    // known contains {"fp": B's fp, "name": <B's hello name>}
    // B asks list_shares → only Q
}

#[tokio::test]
async fn a_remote_share_is_saved_and_says_who() {                  // 第 1 条前半，第 9 条
    // B: share ports [P] note "jupyter" → {"ok":true,"shared":[{"port":P}]}
    // A's shares.json has P, note "jupyter"; log "share" has by == B's fp short, and name
    // B: share [22] → shared[0].warn == "分享这个端口，等于把这台机器能到的网络也交出去"
}

#[tokio::test]
async fn sharing_again_without_allow_keeps_it() {                  // 第 6 条
    // A shares P allow [x]; B: share [P] note "n" (no allow) → shares.json P allow still [x], note "n"
    // B: share [P] allow [] → allow empty
}

#[tokio::test]
async fn a_remote_share_leaves_raw_alone() {
    // shares.json: P with raw true; B: share [P] note "n" → raw still true
    // B: share with "raw": false in the request → raw still true (the field is ignored)
}

#[tokio::test]
async fn a_remote_unshare_cuts_the_forward() {                     // 第 3 条
    // C forwards P (echo, open); B: unshare P → {"was":true}; C's pipe ends within 2 s
    // C: forward P again → "not shared"; log "unshare" has by == B's fp short
}

#[tokio::test]
async fn narrowing_allow_cuts_the_one_left_out() {                 // 第 4 条
    // C forwards P; B: share [P] allow [B's fp] → C's pipe ends; C: forward P → "not allowed"
}

#[tokio::test]
async fn the_password_connection_cannot_set() {                    // 第 7 条
    // old password auth connection: shares, share, unshare → each "not supported"; shares.json unchanged
    // log has share_refused {op, reason: "not supported"}
}

#[tokio::test]
async fn the_65th_port_is_limit_and_nothing_changes() {            // 第 8 条
    // shares.json with 64 ports; B: share [P65] → "limit"; file bytes unchanged
    // B: share [P1, P65] → "limit"; P1's note unchanged (all or none)
}

#[tokio::test]
async fn bad_values() {
    // ports [0] / [70000] / ["x"] / [] / missing → "bad port"
    // unshare port 0 / missing → "bad port"
    // allow ["mini"] / ["abababab"] / [7] / "x" → "bad allow"
    // allow [64 hex nobody knows] → ok
    // after each error the same A answers {"op":"ping"} on a new stream
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-testkit --test share_set`
Expected: FAIL，回复是 `unknown op`。

- [ ] **Step 3: 实现**

- `Paired::list`。
- `sharing::serve`：先 `admit(&Caller { fp: peer.fp.as_ref(), server: false }, true)`；`Err(d)` 时记 `share_refused` 并回 `d.as_str()`。通过后：`Op::Shares` 组表；`Op::Share` 把 `ports`、`note`、`allow` 拼成一个 `Value` 交给 `share(state, &req, Allow::Fps, &By::Remote(&peer))`；`Op::Unshare` 调 `unshare`。
- `peer.rs` 的 `serve_request` 加 `Ok(op @ (Op::Shares | Op::Share { .. } | Op::Unshare { .. })) => crate::sharing::serve(state, s, op, peer).await`。
- 测试辅助挪进 `common/sharing.rs`，`forward.rs` 里删掉原来的那些定义。

- [ ] **Step 4: 跑**

Run: `cargo test -p rapp-conn && cargo test -p rapp-testkit --test share_set --test forward`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add rust/conn/src/paired.rs rust/service/src rust/testkit/tests
git commit -m "feat(service): other devices can list, share and unshare this device's ports"
```

---

### Task 3: 本机 IPC 的三个命令带 `to`

**Files:**
- Modify: `rust/service/src/pipe.rs`、`rust/service/src/share_cmds.rs`、`rust/cli/src/say.rs`
- Test: `rust/service/src/share_cmds.rs`、`rust/service/src/pipe.rs`、`rust/testkit/tests/share_set.rs`

**Interfaces:**
- Consumes: Task 2 的三个设备请求和回复；`pipe::{target_id, known_hosts}`；`Outbound` 的 `Sent.fp`。
- Produces（界面靠这些，Task 5 照着解析）：
  - `PipeErr::Old`，`as_str` 是 `old version`
  - `pipe::set(state: &State, name: &str, op: &Op) -> Result<(Value, Fp), PipeErr>`：对方的回复和对方的指纹；对方回 `unknown op`、`bad request` 时 `Err(PipeErr::Old)`，回别的错误时 `Err(PipeErr::Refused(原文))`
  - `share_cmds::shown(fp: &Fp, me: &Fp, target: Option<(&Fp, &str)>, given: &str) -> String`：是 `me` → `本机`；是目标设备 → 它的名字；`clean_name(given)` 非空 → 它；否则 `fp.short()`
  - IPC `{"cmd":"shares","to"?}` →
    `{"ok":true,"id":"<目标 ID>","me":"<本机指纹>","shares":[{"port","note","allow":[{"fp","name"}],"url","addr","web","listening","mine"}],"known":[{"fp","name"}]}`
    - `url` 恒为 `http://<id>.rapp:<port>`（命令行用）；`addr` 是面板显示的：22 是 `ssh <id>.rapp`，其余同 `url`；`web` 是 `port != 22`
    - `mine`：`allow` 是空的，或者含 `me`
    - `known`：第一项恒为 `{"fp": me, "name": "本机"}`，后面是目标设备的 `known`（不带 `to` 时是本机的 `paired.json`），去掉 `me`
    - 不带 `to` 时另外照旧有 `relay`
    - 目标设备的名字：本机 `hosts.json` 里它那一项的 `name`，空的就用 ID
  - IPC `{"cmd":"share","to","ports","note"?,"allow"?}` → `{"ok":true,"shared":[{"port","warn"?}]}`；不带 `to` 时回复照旧
  - IPC `{"cmd":"unshare","to","port"}` → `{"ok":true,"was"}`
  - 带 `to` 时的错误：`offline`（含 6 秒没回，沿用 `HOSTS_WAIT`）、`old version`、`no key`、`unknown name`，以及目标设备的原文
  - 命令行（`say.rs`）读 `allow[].name`，打出来的字一个不变

- [ ] **Step 1: 写测试**

`pipe.rs`：

```rust
#[test]
fn an_old_device_is_old() {
    // reply_err(&json!({"ok":false,"error":"unknown op"})) == PipeErr::Old; same for "bad request"
    // "policy" → Refused("policy")
}
```

`share_cmds.rs`：

```rust
#[test]
fn names_from_the_other_device_are_cleaned() {
    // shown(x, me, Some((t, "gpu1")), "\u{202e}mini\n") == "mini"
    // given "" or only control chars → x.short(); given 200 chars → NAME_MAX chars
    // shown(me, me, ..) == "本机"; shown(t, me, Some((t, "gpu1")), "whatever") == "gpu1"
}
```

`share_set.rs`（两台服务 A、B，B 的 `hosts.json` 写 A 的局域网地址，照 1a 的 `hosts_lists_what_each_device_offers_this_one`）：

```rust
#[tokio::test]
async fn b_lists_and_sets_a_through_its_own_ipc() {
    // B ipc share to A ports [P] note "n" → ok; A's shares.json has P
    // B ipc shares to A → id == A.id, me == B's fp, shares[0] has url, addr == url, web true, mine true
    // known[0] == {"fp": B's fp, "name": "本机"}
    // B ipc share to A ports [22] → shared[0].warn set; shares → the 22 row: addr == "ssh <A.id>.rapp", web false
    // B ipc share to A ports [P] allow [x] → shares: P mine false, allow == [{"fp": x, "name": x.short()}]
    // B ipc unshare to A port P → {"was":true}
}

#[tokio::test]
async fn to_this_device_is_local() {
    // A ipc share to A.id ports [P] → the reply has "url" (the local shape); no "share" line has a by other than "local"
}

#[tokio::test]
async fn an_offline_device_is_offline_within_the_wait() {
    // B ipc shares to a made-up id → "offline" in under 7 s
}

#[tokio::test]
async fn the_cli_still_prints_the_same() {
    // rapp-cli shares on A with one share allowed to a known device → the same lines as before Task 1
}
```

- [ ] **Step 2: 跑，确认失败**

Run: `cargo test -p rapp-service share_cmds pipe && cargo test -p rapp-testkit --test share_set b_lists`
Expected: FAIL。

- [ ] **Step 3: 实现**

- `pipe::ask` 多带回 `sent.fp`；`open`、`shares_of` 不变。
- `share_cmds` 的三个函数开头：`to` 不在、或 `target_id(to)` 等于本机 ID → 本机的写法；否则用 `tokio::time::timeout(HOSTS_WAIT, pipe::set(..))` 发 `Op::Shares`、`Op::Share`、`Op::Unshare`，再按上面的字段组回复。
- `say.rs` 的 `names()` 读对象的 `name`。

- [ ] **Step 4: 跑**

Run: `cargo test --workspace`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add rust/service/src rust/cli/src rust/testkit/tests
git commit -m "feat(service): shares, share and unshare take a device to ask"
```

---

### Task 4: 端到端：三台设备，经局域网和经 relay，重启后还在

**Files:**
- Test: `rust/testkit/tests/share_set.rs`（接着加）

**Interfaces:**
- Consumes: Task 1 到 3 的全部；`RelayRig`、`a_on_relay`（1a 的 `forward.rs` 里有，需要的话一起挪进 `common/sharing.rs`）。
- 三台：A 是目标，B 在自己的 IPC 上设置 A，C 是转发的访问者（`visitor()` 或第三台服务）。

- [ ] **Step 1: 写测试**

```rust
#[tokio::test]
async fn set_from_b_forward_from_c() {                             // 规格 §8 第 1 条
    // B ipc share to A ports [P] (echo) → C forward P → b"hello" echoes
}

#[tokio::test]
async fn set_through_the_relay() {
    // A and B on the rig with advertise_lan Some(vec![]); B has no hosts.json entry with lan
    // B ipc shares to A → ok; B ipc share to A [P] → ok; rig.streams() grew
}

#[tokio::test]
async fn a_restart_keeps_what_was_set_remotely() {                 // 第 2 条
    // B ipc share to A [P] note "n"; A.svc.stop(); start_service(A.home, A.bins) again
    // (A's LAN port changes: rewrite B's hosts.json with the new address)
    // B ipc shares to A → P with note "n"; C forward P → echoes
}

#[tokio::test]
async fn remote_unshare_and_narrowing_cut_c() {                    // 第 3、4 条经 IPC
    // C forwarding P; B ipc share to A [P] allow [B's fp] → C's pipe ends
    // C forwarding Q; B ipc unshare to A Q → C's pipe ends
}
```

- [ ] **Step 2: 跑**

Run: `cargo test -p rapp-testkit --test share_set`
Expected: 全部 PASS。不过的，改 Task 1 到 3 的代码，不改测试。

- [ ] **Step 3: Commit**

```bash
git add rust/testkit/tests
git commit -m "test: remote share setting end to end, with a restart of the target"
```

---

### Task 5: 界面的服务调用

**Files:**
- Create: `gui/lib/shares.dart`
- Modify: `gui/lib/service_client.dart`、`gui/lib/term/term_stage.dart`（`openUrl` 的 Windows 分支）
- Test: `gui/test/shares_test.dart`（新）、`gui/test/service_client_test.dart`

**Interfaces:**
- Consumes: Task 3 的 IPC 命令和字段。
- Produces（`gui/lib/shares.dart`）：
  - `class Device { final String fp; final String name; }`
  - `class ShareRow { final int port; final String note; final List<Device> allow; final String addr; final bool web; final bool listening; final bool mine; }`
  - `class ShareTable { final String id; final String me; final List<ShareRow> rows; final List<Device> known; static ShareTable fromJson(Map<String, dynamic>) }`
  - `class Shared { final int port; final String? warn; }`
  - `abstract class SharesApi { bool get rappNames; Future<ShareTable> shares({String? to}); Future<List<Shared>> share({String? to, required List<int> ports, String? note, List<String>? allow}); Future<bool> unshare({String? to, required int port}); }`
  - `String shareErrorText(Object e)`：`ServiceException` 的原文 → 规格 §6.4 的字：`offline`、`no key`、`unknown name` → `离线，读不到它的端口`；`old version` → `对方的 rapp 还不支持分享端口`；`policy` → `对方的策略不允许远程设置`；`limit` → `最多分享 64 个端口`；`bad port` → `端口号是 1 到 65535 的数字`；`service not running`、`service connection closed` → `本机的 rapp 服务没有在运行`；其余 `出错了：<原文>`
  - `bool shareErrorHidesInput(Object e)`：离线、旧版本、`policy`、服务没在运行这四种为真（规格 §6.4："没有输入框"）
  - `int? parsePort(String s)`：去掉前后空格后是 1 到 65535 的 ASCII 十进制数才返回
  - `ServiceStatus.rappNames`：`json['rapp_names'] == true`
  - `ServiceMonitor implements SharesApi`：三个命令走一条专用连接（第一次用时 `ServiceConnection.connect`，断了下次再连），不走 `_cmd`，也不调 `refresh()`

- [ ] **Step 1: 写测试**

`shares_test.dart`：

```dart
test('a table from the service', () {
  // fromJson of the Task 3 shape with one web row and one 22 row → fields as given; known[0].name == '本机'
});
test('error words', () {
  // each service text above → its 中文; 'whatever' → '出错了：whatever'
  // shareErrorHidesInput true for offline/old version/policy/service not running, false for limit/bad port
});
test('port input', () {
  // '8000' and ' 8000 ' → 8000; '', '0', '65536', '80a', '８０００', '-1', '8000.0' → null
});
```

`service_client_test.dart`（用文件里已有的假服务端）：

```dart
test('remote share calls use their own connection', () async {
  // the fake holds the reply to {"cmd":"shares","to":"123456789"} for 1 s
  // while it waits, monitor.refresh() completes (status comes back on the other connection)
});
test('share sends to, ports, note and allow; leaves out what is null', () async {
  // share(to: '123456789', ports: [8000]) → the fake got {"cmd":"share","to":"123456789","ports":[8000]} exactly
});
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/shares_test.dart test/service_client_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现** `shares.dart` 和 `ServiceMonitor` 的三个方法；`openUrl` 加 Windows 分支（计划定的第 9 条）。

- [ ] **Step 4: 跑**

Run: `~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
Expected: 全部 PASS，analyze 没有新问题。`git checkout pubspec.lock`（如果变了）。

- [ ] **Step 5: Commit**

```bash
git add gui/lib/shares.dart gui/lib/service_client.dart gui/lib/term/term_stage.dart gui/test
git commit -m "feat(gui): service calls for listing and setting a device's shares"
```

---

### Task 6: 面板里的"端口"这一段

**Files:**
- Create: `gui/lib/ui/shares_section.dart`
- Modify: `gui/lib/ui/devices_tab.dart`（`DevicesTab` 多一个参数 `shares`；`_remote` 在 `_termGroup` 后面插入）、`gui/lib/ui/main_window.dart`（`_local()` 里 `LocalSection` 后面插入；给 `DevicesTab` 传 `shares: widget.monitor`）
- Test: `gui/test/ui/shares_section_test.dart`（新）

**Interfaces:**
- Consumes: Task 5 的 `SharesApi`、`ShareTable`、`shareErrorText`、`shareErrorHidesInput`、`parsePort`；`openUrl`；`StatusLamp`、`RappButton`、`ConfirmButton`、`InlineEdit`。
- Produces:
  - `class SharesSection extends StatefulWidget { const SharesSection({super.key, required this.api, this.to}); final SharesApi api; final String? to; }`：`to` 为 null 是本机。插入处用 `key: ValueKey('shares-${to ?? 'local'}')`。
  - 一个钩子留给 Task 7：点"所有设备 / 只给 …"时调 `Future<List<String>?> Function(BuildContext, ShareRow, List<Device> known)`，这一任务里先给一个返回 null 的默认值。
  - 测试用的 Key：`shares-refresh`、`share-port`、`share-note`、`share-add`、`share-row-<port>`、`share-open-<port>`、`share-copy-<port>`、`share-unshare-<port>`、`share-allow-<port>`、`share-warn-<port>`、`share-names-off`

- [ ] **Step 1: 写测试**（用一个假的 `SharesApi`，回复可以控制先后和失败）

```dart
testWidgets('rows', (t) async {
  // two rows: 8000 'jupyter' listening, allow [] ; 22 not listening, allow [本机, mini]
  // '端口' title; ● on 8000, ○ on 22; 'http://123456789.rapp:8000' and 'ssh 123456789.rapp'
  // '所有设备' and '只给 本机、mini'; share-open-22 absent; share-copy-22 present
});
testWidgets('open is grey without .rapp names, with the line under the section', ...);
  // rappNames false → share-open-8000 disabled; '这台电脑还没有启用 .rapp 域名，地址现在只能复制。' shown
  // rappNames true, mine true → enabled and calls openUrl (injectable)
testWidgets('a share that leaves this device out', ...);
  // mine false, allow [mini] → '只给 mini（不含本机）', open disabled even with rappNames true
testWidgets('the states', ...);
  // pending → '正在读取…'; empty table → '没有分享端口' + share-port; offline → '离线，读不到它的端口', no share-port;
  // old version → '对方的 rapp 还不支持分享端口'; policy → '对方的策略不允许远程设置'; service not running → '本机的 rapp 服务没有在运行'
testWidgets('share a port', ...);
  // type ' 8000 ' + note 'jupyter', tap share-add → api got share(to, [8000], note 'jupyter', allow null); then one shares() call
  // share-add is disabled while the call runs (a second tap sends nothing)
  // '0' → '端口号是 1 到 65535 的数字', no call; 'limit' reply → '最多分享 64 个端口', the input keeps its text
testWidgets('a sensitive port shows the warning under its row', ...);
  // share 22 → reply warn → share-warn-22 shows the warn text; no dialog
testWidgets('unshare takes two taps', ...);
  // one tap → no call, '再点一次确认'; second → unshare(to, 22) then shares()
testWidgets('the note is edited in place', ...);
  // InlineEdit commit 'x' → share(to, [8000], note 'x', allow null)
testWidgets('refresh asks again; nothing is asked on a timer', ...);
  // pump 60 s → still one shares() call; tap shares-refresh → two
testWidgets('a late reply for the previous device is dropped', ...);
  // section for A (reply held), rebuilt for B (reply at once), then A's offline arrives → B's rows still shown
```

- [ ] **Step 2: 跑，确认失败**

Run: `~/development/flutter/bin/flutter test test/ui/shares_section_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**

视觉照 `rapp-design-language` 和 `_TermRow`：标题和"终端"一组一样（`fontWeight: w600`，上 8 下 6）；一行里依次是灯、端口（等宽）、备注、地址（等宽、可选中）、范围、按钮。灯：`listening` 用 `Lamp.active`，否则 `Lamp.idle`。设置成功后重新问一次；失败时表不动，错误字显示在输入框下面。回复晚到的判断：每次发请求记一个序号，回来时不是最新的就丢掉；`didUpdateWidget` 里 `to` 变了也算新的一轮。

- [ ] **Step 4: 跑**

Run: `~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
Expected: 全部 PASS（`devices_tab_test`、`main_window_test` 照旧过，需要时给它们传一个假的 `SharesApi`）。

- [ ] **Step 5: Commit**

```bash
git add gui/lib/ui gui/test/ui
git commit -m "feat(gui): a Ports section on each device and on this one"
```

---

### Task 7: "谁能用这个端口"小窗口

**Files:**
- Create: `gui/lib/ui/allow_dialog.dart`
- Modify: `gui/lib/ui/shares_section.dart`（钩子的默认值换成它）
- Test: `gui/test/ui/allow_dialog_test.dart`（新）

**Interfaces:**
- Consumes: Task 5 的 `Device`、`ShareRow`；Task 6 的钩子。
- Produces: `Future<List<String>?> showAllowDialog(BuildContext context, {required List<Device> candidates, required List<Device> current})`：取消 → `null`；`所有设备` → `[]`；否则勾着的指纹，顺序是候选的顺序，后面接不在候选里的。

- [ ] **Step 1: 写测试**

```dart
testWidgets('everyone', ...);
  // current [] → '所有设备' selected; tap 保存 → []
testWidgets('pick devices', ...);
  // candidates [本机, mini, gpu1]; choose '只给勾选的设备', tick 本机 and gpu1 → [me, gpu1's fp]
  // nothing ticked → 保存 disabled
testWidgets('one already allowed but not a candidate stays ticked', ...);
  // current [x (name 'abababab')] not in candidates → a ticked row 'abababab'; 保存 without touching → [x]
testWidgets('only this device to pick', ...);
  // candidates [本机] → '别的设备连过这台以后才能选' shown
testWidgets('cancel', ...);  // → null, the section sends nothing
testWidgets('saving from the section sends the fingerprints', ...);
  // in SharesSection: tap share-allow-8000, pick mini, 保存 → api.share(to, [8000], allow [mini's fp], note null)
```

- [ ] **Step 2: 跑，确认失败**

Run: `~/development/flutter/bin/flutter test test/ui/allow_dialog_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**：两个单选项，下面是候选的勾选列表（选"所有设备"时勾选列表不可用），按钮 `取消`、`保存`；样子照面板里已有的对话框。

- [ ] **Step 4: 跑**

Run: `~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
Expected: 全部 PASS。`git checkout pubspec.lock`（如果变了）。

- [ ] **Step 5: Commit**

```bash
git add gui/lib/ui gui/test/ui
git commit -m "feat(gui): choose who may use a shared port"
```

---

### Task 8: 文档和真机检查单

**Files:**
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（§2.11 写明 `shares.json` 也可能是别的设备写进来的）
- Modify: `docs/superpowers/specs/2026-11-11-rapp-observability-design.md`（`share`、`unshare` 的 `by`；新事件 `share_refused`）
- Modify: `docs/superpowers/specs/2026-11-11-rapp-platform-design.md`（设备请求 `shares`、`share`、`unshare`；IPC 三个命令的 `to` 和新字段；`rapp_names` 留给第 4 步）
- Modify: `docs/superpowers/specs/2026-11-15-rapp-port-sharing-panel-design.md`（状态行：已实现，分支名）
- Modify: 本计划（勾选）

- [ ] **Step 1: 照代码写**：字段名、错误文本、事件名以代码为准；和规格不一样的地方在规格里标"（实现注，日期）"，不改规格原文。
- [ ] **Step 2: 写真机检查单**，追加到本计划末尾，给用户在两台真机上做：
  1. Mac 上选中另一台在线的设备 → 看到它的表；分享一个端口 → 那台的 `~/.rapp/local/shares.json` 里有它。
  2. 分享 22 → 行下面出现提醒。
  3. "只给谁"改成只给本机 → 第三台 `rapp-cli pipe` 被拒 `not allowed`。
  4. 取消分享按两次 → 第三台正在用的 `pipe` 断开。
  5. 重启那台的服务 → 面板按"刷新"，表还在。
  6. 断开那台的网络 → 刷新后 6 秒内显示"离线，读不到它的端口"，本机那一段照常可用。
- [ ] **Step 3: Commit**

```bash
git add docs
git commit -m "docs: remote share setting in the config, observability and platform specs"
```
