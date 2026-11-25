# 总览「正在被接入」 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 本机列显示接入本机的会话（虚线卡片 + 断开）；macOS 主窗口在运行时自动拉起的 `rapp --cm` 不显示。

**Architecture:** 服务 `status` 的每个会话多带 `name`、`side`；GUI 的 `ServiceSession` 读它们；`Overview` 多收一个可选的 `ServiceMonitor`，本机列在任务卡片后画「正在被接入 · N」一组；`--cm` 进程启动时试主锁，被占就退出。

**Tech Stack:** Rust（rapp-service, testkit），Flutter/Dart，Swift（macOS runner）。

**Spec:** `docs/superpowers/specs/2026-11-25-rapp-overview-inbound-sessions-design.md`

## Global Constraints

- 组标题：`正在被接入 · N`；断开按钮文字 `断开`；失败提示 `断开失败：<e>`；传文件后缀 `· 传文件`。
- 显示名顺序：`hub.hosts` 中同 id 的名字 → 自称 `name` → `peer`。
- 时长：`<60 s` → `N 秒`，`<60 min` → `N 分钟`，否则 `N 小时`（向下取整；`since` 为 Unix 秒，缺失或在未来时显示 `0 秒`）。
- 卡片高 56（`_blockHeight`），不可选中，不进会话计数 / 状态队列。
- 不改网络协议；改服务 status 后跑 `cargo test --workspace --no-fail-fast`。
- 终端标题：`termTitle(termDisplayName(p.name, p.host))`（`gui/lib/term/term_id.dart`）；非终端用原 `app`。

## Review Focus

- 服务没在运行（`monitor.status == null`）或没传 monitor（iOS、测试）：整组不出现，不报错 → Task 3 测试 `no monitor or no status: no inbound group`。
- 断开失败（kick 抛错）：出提示，卡片仍在 → Task 3 测试 `a failed kick shows 断开失败`。
- 对方 id 不在设备列表、也没自称名：显示设备 ID → Task 3 测试 `display name falls back to the peer id`。
- 很长的 app 名 / 设备名：一行省略，「断开」不被挤掉 → Task 3 测试 `long names ellipsize and keep 断开 on screen`。
- 点卡片空白处：不选中、不切舞台（`state.currentKey` 不变）→ Task 3 测试 `tapping an inbound card selects nothing`。

---

### Task 1: 服务 status 带 `name`、`side`

**Files:**
- Modify: `rust/service/src/state.rs:241-245`（`status()` 的 sessions map）
- Test: `rust/testkit/tests/service.rs:131-139`

- [ ] **Step 1:** 在 testkit 现有断言 `sessions[0]["app"] == "com.example.echo"` 旁加：`assert_eq!(sessions[0]["side"], false);`，以及 `name` 与该测试里 B 发送的自称名一致（B 没发就断言 `sessions[0].get("name").is_none() || sessions[0]["name"].is_null()`）。
- [ ] **Step 2:** `cargo test -p rapp-testkit --test service` → 新断言 FAIL。
- [ ] **Step 3:** sessions 的 `json!` 加 `"name": s.peer.name, "side": s.side`。
- [ ] **Step 4:** `cargo test --workspace --no-fail-fast` → 全过（已知负载 flake `a_dead_socket_is_removed_and_skipped` 单跑确认）。
- [ ] **Step 5:** commit `feat(service): status sessions carry the peer's own name and side`。

### Task 2: `ServiceSession` 读 `name`、`side`；显示文字函数

**Files:**
- Modify: `gui/lib/service_client.dart:23-30, 122-125`
- Create: `gui/lib/ui/inbound.dart`
- Test: `gui/test/service_client_test.dart`, `gui/test/ui/inbound_test.dart`

**Interfaces:**
- Produces: `ServiceSession(sid, peer, app, path, since, {String? name, bool side = false})`（位置参数不变，命名参数新增）。
- Produces (`inbound.dart`): `String inboundTitle(String app)`；`String inboundWho(ServiceSession s, List<HostInfo> hosts)`（hosts 的类型跟 `state.hub?.hosts` 一致）；`String inboundAge(Object? since, DateTime now)`；`String inboundSubtitle(ServiceSession s, List<…> hosts, DateTime now)` = `'$who · $age'` + 传文件时 `' · 传文件'`。

- [ ] **Step 1:** 测试：status JSON 带 `"name":"iPad","side":true` 解析出 `name == 'iPad'`、`side == true`；缺字段时 `null` / `false`。`inbound_test.dart`：`inboundTitle('term:pty:zsh') == 'CLI · zsh'`、`inboundTitle('com.apple.Safari') == 'com.apple.Safari'`；`inboundAge` 12 s → `12 秒`、200 s → `3 分钟`、7300 s → `2 小时`、null / 未来 → `0 秒`；`inboundWho` 三级回退各一例；subtitle 传文件带 `· 传文件`。
- [ ] **Step 2:** `flutter test test/service_client_test.dart test/ui/inbound_test.dart` → FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 同命令 → PASS。
- [ ] **Step 5:** commit `feat(gui): ServiceSession reads name/side; inbound labels`。

### Task 3: 总览本机列「正在被接入」

**Files:**
- Modify: `gui/lib/ui/overview.dart`（`Overview` 加 `final ServiceMonitor? monitor;`，`ListenableBuilder` 合并它；`_Column` 本机列（`id == null`）在任务卡片之后画组）
- Modify: `gui/lib/ui/inbound.dart`（`InboundCard` widget，key `inbound-<sid>`，断开 key `inbound-kick-<sid>`，组标题 key `inbound-title`）
- Modify: `gui/lib/ui/main_window.dart:355`（`Overview(state: state, monitor: widget.monitor)`）
- Test: `gui/test/ui/overview_test.dart`

**Interfaces:**
- Consumes: Task 2 的函数和 `ServiceSession`；`ServiceMonitor.kick(Object sid)`、`ServiceMonitor.status`。

- [ ] **Step 1:** 测试里定义 `class _Mon extends ServiceMonitor`（`super(readToken: () async => null)`，覆写 `kick` 记录 sid、可设置抛错），`show()` 允许传 monitor。测试：
  - `inbound sessions show under 正在被接入 in the 本机 column`：两条会话 → `inside('column-local', find.text('正在被接入 · 2'))`，`inbound-1`、`inbound-2` 存在，标题和副标题文字对。
  - `tapping 断开 kicks that session` → `_Mon.kicked == [1]`。
  - Review Focus 五条（名字见上）。
  - `the inbound card has a dashed frame and no InkWell`：`find.descendant(of: inbound-1, matching: find.byType(InkWell))` 只有断开按钮自身的（或为零，视 RappButton 实现）；卡片 Semantics 不是 button。
  - 会话计数不变：`count-active` 等数字与没有 monitor 时相同。
- [ ] **Step 2:** `flutter test test/ui/overview_test.dart` → FAIL。
- [ ] **Step 3:** 实现：虚线边框用 `CustomPainter`（圆角 `t.r`，颜色 `t.muted`）；左侧图标 `Icons.login`；第一行标题 + `RappButton.quiet(label: '断开')`；第二行副标题（小字 muted）；时间用 `state` 的 clock（与 MainState 一致，测试可控）。kick 抛错 → `ScaffoldMessenger.maybeOf(context)?.showSnackBar(...)`。
- [ ] **Step 4:** `flutter test` 全部 + `flutter analyze` → 全过、无告警。
- [ ] **Step 5:** commit `feat(gui): overview 本机 column lists inbound sessions with 断开`。

### Task 4: macOS `--cm` 主窗口在运行时不显示；实机检查

**Files:**
- Modify: `gui/macos/Runner/AppDelegate.swift`（`SingleInstance` 加 `static func mainIsRunning() -> Bool`：打开锁文件，`flock(LOCK_EX|LOCK_NB)` 失败＝被占＝true；成功则立刻 `LOCK_UN` 并关闭，返回 false）
- Modify: `gui/macos/Runner/MainFlutterWindow.swift:10`（`isConnectionManager && mainIsRunning()` → `exit(0)`，在创建 Flutter 之前）
- Modify: `tasks/todo.md`（新增「总览·正在被接入」实机检查 1–6）

- [ ] **Step 1:** `flutter build macos --debug`（或现有 macOS 构建配方）编译通过。
- [ ] **Step 2:** 手动冒烟：主 rApp 开着时运行构建出的 `rapp.app/Contents/MacOS/rapp --cm` → 进程立刻退出、无窗口；主 rApp 不在时 → 小窗口出现。
- [ ] **Step 3:** todo 写实机检查：①另一台设备接入应用，本机列出现卡片；②接入终端，标题 `CLI · …`；③断开有效；④主窗口开着不弹小窗口；⑤主窗口退出后接入会弹；⑥Linux 总览同样显示。
- [ ] **Step 4:** commit `feat(macos): --cm stays hidden while the main window runs; todo checks`。
