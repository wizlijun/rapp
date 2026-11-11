# rapp 主界面 S1（外壳与设计语言）+ 启动全屏 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用新的主界面替换 GUI 现在的"本机 / 主机 / 会话"三块：常驻顶栏、左侧浮层面板（会话、设备、添加设备）、四套主题和七种状态灯、舞台占位加「切到窗口」；启动时默认进入沉浸式全屏。

**Architecture:** 纯 Flutter 改动为主，组件只读 `RappTokens`（ThemeExtension）。状态集中在一个 `MainState`（ChangeNotifier，包着现有 `HubClient`）。远程窗口仍是独立的 `rapp-client` 窗口；「切到窗口」靠 hub 新增的 `focus` 命令写一行 `{"cmd":"focus"}` 到 client 的 stdin，client 把自己提到最前。

**Tech Stack:** Flutter 3（macOS/Linux/Windows 桌面）、window_manager 0.5、Rust（rapp-hub, tokio）、Swift（rapp-client, AppKit）。

**Spec:** `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md`（§3.1、§3.2、§3.7、§5、§7 S1、§9）和 `docs/superpowers/specs/2026-11-12-rapp-design-language.md`（全文）。

## S1 范围裁定（规格没写死、我定的）

| # | 裁定 | 理由 | 错了的代价 |
|---|---|---|---|
| R1 | 启动默认全屏；面板底部有「启动时全屏」开关（存盘）；顶栏最右一个全屏切换按钮；macOS ⌃⌘F、其他系统 F11 切换 | 用户要"启动时允许全屏沉浸式" | 改一个默认值 |
| R2 | 面板只做「会话」「设备」两个标签；会话分组只有「设备」「App」；没有「常用」组、「设为常用」 | 项目、常用归 S5，资源归 S6 | 无，按计划后加 |
| R3 | 顶栏不放全景（S4）、窗口标签（S2）、需要你（S3）、流量标签（S2/S3） | 都依赖后面子项目的数据 | 无 |
| R4 | 会话灯在 S1 只有两种：`open` 请求未回来是连接中，回来后是活动；`closed` 后条目消失 | 现有 hub 不报状态（S3 才有） | 无 |
| R5 | 设备在线与否靠探测：打开设备标签时对每台远程设备调一次 `apps(id)`；进行中=连接中灯，成功=活动灯「在线」，失败=离线灯「离线」加错误文字 | hub 没有在线状态接口 | 每次开设备标签多几次请求 |
| R6 | hub 新增 `focus` 命令（唯一的协议改动） | 「切到窗口」要把另一个进程的窗口提前，只有 hub 握着 client 的 stdin；规格 §7 说 S1"只用现有 hub 接口"，这是为占位按钮能用而做的最小例外 | hub 协议多一条命令 |
| R7 | 舞台占位上除「切到窗口」外还有「结束会话」（点两次确认） | 现在的会话列表有关闭按钮，S1 换掉它后不能丢功能；串流菜单要到 S2 | 无 |
| R8 | 不打包字体：`--font` 写 `Inter`，回落 PingFang SC、Hiragino Sans GB、Noto Sans SC、Microsoft YaHei；`--mono` 写 `JetBrains Mono`，回落 SF Mono、Menlo、Consolas、monospace | 避免带 2 MB 字体资源；装了就用 | 没装 Inter 的机器上字形是系统默认 |
| R9 | 面板宽度 = min(规格宽度, 窗口宽度) | 窗口最小 360 宽，720 的面板放不下 | 无 |
| R10 | 总览数字里的总流量在 S1 显示 `—` | 没有流量数据（S3） | 无 |
| R11 | 偏好存 `<configDir>/gui.json`（`{"theme":"matrix","start_fullscreen":true}`） | 不为两个值加 shared_preferences 依赖 | 无 |

## Global Constraints

- 组件只引用 `RappTokens`，不写死颜色（设计语言 §4）。四套主题取值照抄设计语言 §4 的表；AVATAR 的 `--panel` 是白色 3.5%→1% 竖向渐变，`--raise` 是浅蓝（`#96E1FF`）14%→7% 竖向渐变。
- 主题枚举名与片名一致：`avatar`、`ironMan`、`matrix`、`westworld`；下拉顺序 AVATAR、IRON MAN、MATRIX、WESTWORLD；默认 MATRIX。不用原型里的 graphite/holo/phosphor/bone。
- 状态灯形状、颜色、动静、行底纹照抄设计语言 §2 的表；基准 10px。
- 所有可点控件高度 ≥ 48px；顶栏 56px；会话条 60px；设备面板 app 行 68px；浮层内边距 10–12px，控件间距 6–8px；圆角用 `--r`。
- 动效：旋转 1.4 秒一圈；闪烁 1 秒一次亮暗各半；按下 0.08 秒缩到 0.97。`MediaQuery.disableAnimationsOf(context)` 为真时全部关闭。
- 状态词只用设计语言 §9 的词表；"断开"和"结束"不混用（S1 只有"结束会话"）。
- 浮层只盖不挤：面板打开、关闭都不改变舞台大小（规格 §5.1）。选了就收（§5.3）。不可撤销操作点两次，3 秒复原（§5.4）。不依赖悬停和右键（§5.5）。
- 每盏灯旁边有文字，或控件带说明状态的 `Semantics` label；只有图标的按钮有 tooltip；装饰性灯对读屏隐藏（`ExcludeSemantics`）。
- 测试只用临时目录和 `FakeTransport`；不碰端口 47800、21116–21119，不碰 `~/Library/Logs/rapp`，不替换 `/Applications/rapp.app`，不重启正在跑的 rapp-service。
- 命令：Rust `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`（不跑 `cargo fmt --all`）；Flutter `cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`；Swift `./scripts/check.sh`，看 `.build-logs/check.log` 末行 `EXIT=0`。

## Review Focus

1. **hub 中途退出**（`hub.alive` 变 false）：舞台显示"rapp-hub 已退出 — 重启 rapp 以恢复"，打开、切到、结束按钮全部禁用，点了不抛异常。测试放 Task 5、Task 7。
2. **当前会话被关**（收到 `closed`，可能是 A 端结束）：当前项移到同组下一个会话，没有了就回到空舞台提示；提示行写"已结束 <app>"。测试放 Task 5。
3. **同一（设备, app）快速点两次「打开」**：只发一次 `open`；第二次在 pending 期间被忽略，`opened` 之后再点是「切到」。测试放 Task 5。
4. **删除一台还开着会话、或正被选中的设备**：设备标签切到「本机」，那台设备的会话照旧在会话列表里（hub 不关它们），直到 `closed`。测试放 Task 8。
5. **gui.json 坏了或写不进去**：读坏文件用默认值；写失败在提示行写"偏好没有保存：<原因>"，界面照常切换。测试放 Task 1、Task 7。

---

### Task 1: 主题 token、四套主题、偏好存盘

**Files:**
- Create: `gui/lib/ui/tokens.dart`、`gui/lib/ui/prefs.dart`
- Test: `gui/test/ui/tokens_test.dart`、`gui/test/ui/prefs_test.dart`

**Interfaces:**
- Produces:
  - `enum RappTheme { avatar, ironMan, matrix, westworld }`；`const themeOrder = [avatar, ironMan, matrix, westworld]`；`String themeLabel(RappTheme)` → `'AVATAR' | 'IRON MAN' | 'MATRIX' | 'WESTWORLD'`。
  - `class RappTokens extends ThemeExtension<RappTokens>`：`Color bg, line, text, muted, on, accent, accentInk, tint; List<Color> panel, raise`（1 个色=实色，2 个=自上而下渐变）；`double r`；`List<BoxShadow> glow`；`List<Shadow> textGlow`（MATRIX、IRON MAN 有，其余空）；`String font; List<String> fontFallback; String mono; List<String> monoFallback`；`bool monoBody`（仅 MATRIX 真）；`double labelSpacing`（小标题字距 em：IRON MAN、WESTWORLD 0.12，其余 0.06）；`static RappTokens of(BuildContext)`；`BoxDecoration panelBox({Color? border})`、`BoxDecoration raiseBox({Color? border})`。
  - `RappTokens tokensFor(RappTheme)`；`ThemeData themeDataFor(RappTheme)`（深色 Material3，`colorScheme` 由 token 映射：surface=bg、primary=text、onPrimary=bg、error=accent、outline=line、onSurfaceVariant=muted；正文 15px 行高 1.4；`extensions: [tokens]`；所有按钮主题 `minimumSize` 高 48）。
  - `class UiPrefs { RappTheme theme; bool startFullscreen; }`，默认 `matrix`、`true`；`static UiPrefs load(String dir)`；`void save(String dir)`（同步写 `<dir>/gui.json`，失败抛 `FileSystemException`）。JSON 键：`theme`（枚举名）、`start_fullscreen`。

- [ ] **Step 1: 写失败的测试**

```dart
test('MATRIX token values match the design language table', () {
  final t = tokensFor(RappTheme.matrix);
  expect(t.bg, const Color(0xFF020A04));
  expect(t.panel, [const Color(0xFF041208)]);
  expect(t.line, const Color(0xFF176A33));
  expect(t.text, const Color(0xFF7DFF9E));
  expect(t.accent, const Color(0xFFF2FFF5));
  expect(t.accentInk, const Color(0xFF02240C));
  expect(t.tint, const Color.fromRGBO(125, 255, 158, .17));
  expect(t.r, 0);
  expect(t.monoBody, isTrue);
});
test('AVATAR panel and raise are vertical two-stop gradients', () {
  final t = tokensFor(RappTheme.avatar);
  expect(t.panel, [const Color.fromRGBO(255, 255, 255, .035), const Color.fromRGBO(255, 255, 255, .01)]);
  expect(t.raise.length, 2);
  expect(t.r, 4);
});
test('every theme has an opaque bg and one accent', () {
  for (final th in RappTheme.values) {
    expect(tokensFor(th).bg.a, 1.0, reason: '$th');
  }
});
test('dropdown order and labels', () {
  expect(themeOrder.map(themeLabel), ['AVATAR', 'IRON MAN', 'MATRIX', 'WESTWORLD']);
});
test('themeDataFor carries the tokens and 48px buttons', () {
  final d = themeDataFor(RappTheme.westworld);
  expect(d.extension<RappTokens>()!.accent, const Color(0xFFFF3B30));
  expect(d.filledButtonTheme.style!.minimumSize!.resolve({})!.height, 48);
});
```
另把 IRON MAN、WESTWORLD 的 `bg`、`text`、`accent`、`r` 各断言一遍（值照设计语言 §4 表）。

`prefs_test.dart`：`defaults when file missing`（matrix、true）；`round-trips theme and start_fullscreen`；`corrupt json gives defaults`（写 `{nope`）；`unknown theme name gives matrix`；`save into a missing dir creates it`；`save into a read-only dir throws FileSystemException`（`chmod 500` 临时目录）。

- [ ] **Step 2: 跑测试确认失败** — `cd gui && flutter test test/ui/` → 编译失败（文件不存在）。
- [ ] **Step 3: 实现 `tokens.dart`、`prefs.dart`**。`load` 吞掉所有解析错误返回默认值。
- [ ] **Step 4: 跑测试确认通过** — 同上命令 → 全部 PASS。
- [ ] **Step 5: Commit** `feat(gui): design tokens, four themes, gui.json prefs`

---

### Task 2: 状态灯、按钮、两次确认

**Files:**
- Create: `gui/lib/ui/lamp.dart`、`gui/lib/ui/controls.dart`
- Test: `gui/test/ui/lamp_test.dart`、`gui/test/ui/controls_test.dart`

**Interfaces:**
- Consumes: `RappTokens.of`（Task 1）。
- Produces:
  - `enum Lamp { active, idle, connecting, disconnected, waiting, offline, notOpened }`；`String lampWord(Lamp)` → 活动、空闲、连接中、已断开、等你、离线、未打开。
  - `enum LampShape { disc, ring, triangle, diamond, square }`；`enum LampStroke { none, solid, dashed, dotted }`；`({LampShape shape, LampStroke stroke, bool glow, bool spins, bool blinks}) lampSpec(Lamp)`。
  - `class StatusLamp extends StatelessWidget { StatusLamp(Lamp kind, {double size = 10}) }`：CustomPainter 画形状，颜色按设计语言 §2；连接中用 `RotationTransition` 1.4s、等你用 1s 亮暗各半的 `FadeTransition`（亮暗各 0.5s，非渐变）；`MediaQuery.disableAnimationsOf` 为真时不建动画控制器。整体包 `ExcludeSemantics`。
  - `Decoration? rowBackdrop(Lamp, RappTokens)`：已断开→135° 斜条纹 8px `--tint`；等你→整行 `--tint`；离线→8px 点阵 `--line`；其余 null。`Color rowBorder(Lamp, RappTokens, {bool selected})`：已断开、等你 `--accent`；选中 `--text`；否则 `--line`。
  - `class RappButton`：`RappButton.primary / .secondary / .accent({required String label, VoidCallback? onPressed, Key? key, String? semanticLabel})`；高 ≥ 48；按下缩 0.97、0.08s（减少动态效果时不缩）。
  - `class ConfirmButton extends StatefulWidget { label, confirmLabel = '再点一次确认', onConfirmed, Duration reset = const Duration(seconds: 3) }`：平时 `--muted` 字弱按钮；第一次点变强调按钮写 confirmLabel；3 秒不点复原；第二次点才调 `onConfirmed`。

- [ ] **Step 1: 写失败的测试**

```dart
test('seven lamps are pairwise distinct by shape+stroke alone', () {
  final specs = Lamp.values.map((l) { final s = lampSpec(l); return (s.shape, s.stroke); }).toSet();
  expect(specs.length, 7);
});
test('only waiting blinks, only connecting spins', () {
  expect(Lamp.values.where((l) => lampSpec(l).blinks), [Lamp.waiting]);
  expect(Lamp.values.where((l) => lampSpec(l).spins), [Lamp.connecting]);
});
test('words come from the vocabulary', () {
  expect(Lamp.values.map(lampWord), ['活动', '空闲', '连接中', '已断开', '等你', '离线', '未打开']);
});
testWidgets('reduced motion builds no animation', (t) async {
  await t.pumpWidget(wrap(const StatusLamp(Lamp.connecting), disableAnimations: true));
  expect(find.byType(RotationTransition), findsNothing);
});
testWidgets('connecting spins when motion allowed', (t) async {
  await t.pumpWidget(wrap(const StatusLamp(Lamp.connecting)));
  expect(find.byType(RotationTransition), findsOneWidget);
});
```
（`wrap` 是测试里的辅助：`MaterialApp(theme: themeDataFor(RappTheme.matrix))` 外加 `MediaQuery(data: MediaQueryData(disableAnimations: ...))`。放 `gui/test/ui/helpers.dart`，后面的任务复用。）

`controls_test.dart`：`ConfirmButton single tap does not fire`；`second tap within 3s fires once`（用 `tester.pump(Duration(seconds: 2))` 后再点）；`resets after 3s`（点一次、`pump(3s)`、再点一次 → 仍未触发，且文字回到 label）；`RappButton is at least 48 tall`（`tester.getSize(find.byType(RappButton)).height >= 48`）。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/lamp_test.dart test/ui/controls_test.dart` → 编译失败。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** → PASS。
- [ ] **Step 5: Commit** `feat(gui): status lamps, buttons, two-tap confirm`

---

### Task 3: hub `focus` 命令 + client 提到最前

**Files:**
- Modify: `rust/hub/src/session.rs`（会话表从 `Option<ChildStdin>` 改成写入通道）、`rust/hub/src/lib.rs:141-195`（dispatch 加 `focus`）、`rust/hub/src/lib.rs` 里 `sessions` 字段类型
- Modify: `rust/testkit/src/bin/fake-rapp-client.rs:71-78`（收到含 `"focus"` 的行时在自身目录写 `client.focus`，内容追加一行 `focus`）
- Modify: `Sources/rapp-client/main.swift:243-250`、`Sources/rapp-client/WindowCoordinator.swift`（加 `func raiseAll()`）
- Modify: `docs/superpowers/specs/2026-11-11-rapp-platform-design.md` hub 命令表加一行 `focus`
- Test: `rust/testkit/tests/hub.rs`

**Interfaces:**
- Produces（hub stdin 协议）：`{"cmd":"focus","sid":<u64>}` → 成功时不回事件（同 `close`）；sid 不存在或已在关闭 → `{"event":"error","error":"unknown sid"}`（带 `req` 则回带）。hub 给该 client 的 stdin 写一行 `{"cmd":"focus"}\n`。
- Produces（client stdin）：`--json` 模式下 `focus` → 主线程 `NSApp.activate()` 后 `coordinator.raiseAll()`（每个 RemoteWindow `orderFront`，`lastFocused` 那个 `makeKeyAndOrderFront`）。

实现要点：`sessions: Mutex<HashMap<u64, Option<tokio::sync::mpsc::UnboundedSender<String>>>>`。`open` 里起一个写任务独占 `ChildStdin`：`while let Some(l) = rx.recv().await { if stdin.write_all(l.as_bytes()).await.is_err() { break } }`，任务结束即 drop stdin。`close` = `take()` 发送端（写任务收完排队的行后结束 → client 读到 EOF，行为与现在相同）。`close_all` 同理。`focus` 对 `Some(tx)` 发送；`None` 或缺失 → `bail!("unknown sid")`。

- [ ] **Step 1: 写失败的测试**（`hub.rs`）

```rust
#[tokio::test]
async fn focus_reaches_the_client_and_unknown_sid_errors() {
    // 与 add_host_hosts_apps_open_close_remove 相同的搭建（relay + service + hub_with_host）
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o"})).await;
    let sid = r["sid"].clone();
    hub.send(json!({"cmd":"focus","sid":sid})).await;
    // fake client 在 bins 目录写 client.focus
    wait_for_file(&a.bins.path().join("client.focus")).await;
    assert_eq!(std::fs::read_to_string(a.bins.path().join("client.focus")).unwrap(), "focus\n");
    let e = hub.call(json!({"cmd":"focus","sid":999,"req":"f"})).await;
    assert_eq!(e, json!({"event":"error","error":"unknown sid","req":"f"}));
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"echo ok"}));
}
```
`wait_for_file`：每 20 ms 查一次，最多 3 秒，超时 panic。若 `common` 里已有同类辅助就用它。另跑现有 `open_and_close` 系列和 `stdin_eof_closes_open_sessions`，它们验证通道改造后 close / EOF 行为不变。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-testkit --test hub focus_` → FAIL（`unknown cmd`）。
- [ ] **Step 3: 实现 hub 通道改造和 `focus`；fake client 写文件**。
- [ ] **Step 4: 跑测试确认通过** — `cargo test --workspace` 全绿；`cargo clippy --workspace --all-targets` 无警告。
- [ ] **Step 5: Swift client 处理 `focus`**；`./scripts/check.sh` → `.build-logs/check.log` 末行 `EXIT=0`。
- [ ] **Step 6: 文档** — 平台规格 hub 命令表加 `focus`（一行：作用、无回复、错误 `unknown sid`）。
- [ ] **Step 7: Commit** `feat(hub,client): focus command raises a session's windows`

---

### Task 4: `HubClient.focus` 与会话模型

**Files:**
- Modify: `gui/lib/hub_client.dart`（加 `void focus(Object sid)`；`HubSession` 不改）
- Create: `gui/lib/ui/session_model.dart`
- Test: `gui/test/hub_client_test.dart`（加一条）、`gui/test/ui/session_model_test.dart`

**Interfaces:**
- Produces:
  - `void HubClient.focus(Object sid)` → 发 `{"cmd":"focus","sid":sid}`，不等回复（同 `close`）。
  - `class SessionEntry { final Object? sid; final String id; final String app; final String appName; final String device; final String path; final Lamp lamp; }`（`sid == null` 表示 open 还在路上，lamp=connecting）。`String get key => '$id/$app'`。
  - `enum Grouping { device, app }`；`String groupingLabel(Grouping)` → 设备、App。
  - `class SessionGroup { final String title; final List<SessionEntry> entries; }`
  - `List<SessionGroup> groupSessions(List<SessionEntry> all, Grouping g)`：按设备分组时组名=设备名、组按设备名排序；按 App 分组时组名=appName、组按 appName 排序；组内按 `device` 再 `appName` 排序（稳定）。
  - `const pathLabels = {'lan': '局域网', 'direct': '直连', 'relay': '中继'}` 从 `pages/sessions_section.dart` 搬到这里；`sessions_section.dart` 改为 import 它（该文件 Task 9 才删）。
  - `String? stepKey(List<SessionGroup> groups, String? current, int delta)`：把各组的 entries 依次拼成一个序列，返回 current 前后 delta 位（循环）的 `key`；current 为 null 或不在序列里时返回第一个；序列空返回 null。

- [ ] **Step 1: 写失败的测试**

```dart
test('focus sends the sid', () {
  hub.focus(3);
  expect(t.sent.last, {'cmd': 'focus', 'sid': 3});
});
test('groups by device, sorted, entries stable', () {
  final g = groupSessions([e('mini', 'Safari'), e('air', 'Notes'), e('mini', 'Mail')], Grouping.device);
  expect(g.map((x) => x.title), ['air', 'mini']);
  expect(g[1].entries.map((x) => x.appName), ['Mail', 'Safari']);
});
test('groups by app', () {
  final g = groupSessions([e('mini', 'Safari'), e('air', 'Safari')], Grouping.app);
  expect(g.single.title, 'Safari');
  expect(g.single.entries.map((x) => x.device), ['air', 'mini']);
});
test('stepKey cycles across groups both ways', () {
  final g = groupSessions([e('a', 'X'), e('b', 'Y'), e('b', 'Z')], Grouping.device);
  expect(stepKey(g, 'a/X', 1), 'b/Y');
  expect(stepKey(g, 'b/Z', 1), 'a/X');
  expect(stepKey(g, 'a/X', -1), 'b/Z');
  expect(stepKey(g, null, 1), 'a/X');
  expect(stepKey(const [], null, 1), isNull);
});
```
（`e(device, appName)` 是测试里造 `SessionEntry` 的辅助，`id == device`、`app == 'bundle.$appName'`。）

- [ ] **Step 2: 跑测试确认失败** → 编译失败。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: Commit** `feat(gui): HubClient.focus, session grouping and prev/next`

---

### Task 5: `MainState`（界面状态的唯一来源）

**Files:**
- Create: `gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: `HubClient`（`hosts`、`sessions`、`alive`、`lastError`、`apps`、`open`、`close`、`focus`、`removeHost`、`refreshHosts`）、`SessionEntry`/`groupSessions`/`stepKey`（Task 4）、`Lamp`（Task 2）、`UiPrefs`（Task 1）。
- Produces `class MainState extends ChangeNotifier`：
  - 构造：`MainState({required HubClient? hub, String? hubError, required String configDir, required UiPrefs prefs})`；监听 hub。
  - 面板：`PanelTab? panel`（`enum PanelTab { sessions, devices }`，null=收起）；`void togglePanel([PanelTab tab = PanelTab.sessions])`（同标签再点=收起）；`void closePanel()`。
  - 会话：`Grouping grouping`；`List<SessionGroup> get groups`；`String? currentKey`；`SessionEntry? get current`；`void select(String key)`（设 current 并 `closePanel()`）；`void step(int delta)`。
  - 打开：`Future<void> openOrSwitch(String id, String app, String appName)`：已有该 key 的会话且 sid 非空 → `hub.focus(sid)`、设 current、提示"已切到 <appName>"；pending 中 → 忽略；否则加 pending 条目（连接中）、设 current、`closePanel()`、`await hub.open`；成功提示"已打开 <appName> @ <device>"；失败去掉 pending、提示错误文字（权限缺失时用 `remoteHint`，同现在的 HostsSection）。
  - `void focusCurrent()`、`void endCurrent()`（`hub.close(sid)`；提示"正在结束 <appName>"）。
  - `closed` 事件让条目消失时：若它是 current，current 移到 `stepKey(groups, 旧 key, 1)` 计算出的下一个（在移除前算），没有则 null；提示"已结束 <appName>"。
  - 设备：`Map<String, DeviceProbe> probes`（`class DeviceProbe { Lamp lamp; String word; AppList? apps; String? error; }`）；`Future<void> probe(String id)`；`void probeAll()`；`String? deviceTab`（null=本机）；`void selectDevice(String? id)`；`Future<void> removeDevice(String id)`（成功后若 `deviceTab == id` 则回到本机）。
  - 名字：`String deviceName(String id)`（hosts 里的 name，空则 id）；app 名取自 probe 过的 `AppList`，没有则 bundle id。
  - 提示：`String hint`（初始 `''`；hub 的 `lastError` 变化时也写进来）。
  - hub 状态：`bool get hubUsable => hub != null && hub!.alive`；`String? get hubProblem`（hub 为 null → `hubError ?? 'rapp-hub 不可用'`；`!alive` → `'rapp-hub 已退出 — 重启 rapp 以恢复'`）。`hubUsable` 为假时 `openOrSwitch`、`focusCurrent`、`endCurrent`、`probe`、`removeDevice` 直接返回。
  - 偏好：`UiPrefs prefs`；`void setTheme(RappTheme)`、`void setStartFullscreen(bool)` → 改内存、`prefs.save(configDir)`；保存抛异常时提示"偏好没有保存：<原因>"，内存里的值照样生效。
  - 总览：`int get onlineDevices`（probe 为活动的远程设备数）；`int get sessionCount`。

- [ ] **Step 1: 写失败的测试**（用 `FakeTransport` + `HubClient`，`onSend` 里按需 `emit`）

- `openOrSwitch sends one open while pending`：连点两次，`sent.where(cmd=='open').length == 1`；pending 条目 lamp 为 connecting。
- `opened turns the entry active and sets the hint`：emit `opened` 后 lamp=active，hint `已打开 Safari @ mini`。
- `opening an open session focuses instead`：已 opened 后再 `openOrSwitch` → 最后一条发送是 `{'cmd':'focus','sid':1}`，hint `已切到 Safari`。
- `open failure drops the pending entry and shows the error`：emit `{"event":"error","error":"offline","req":...}` → 条目没了、hint 含 `offline`。
- `closing the current session moves to the next one`：两个会话，current=第一个，emit `closed` sid=第一个 → current 是第二个，hint `已结束 <app>`；再关第二个 → current 为 null。
- `select closes the panel`。
- `hub death disables actions`：`t.die()` 后 `hubUsable` 为假、`hubProblem` 为 `rapp-hub 已退出 — 重启 rapp 以恢复`，`openOrSwitch` 不发任何命令、不抛异常。
- `probe marks online/offline`：apps 成功 → `probes[id].lamp == Lamp.active`、word `在线`；失败 → `Lamp.offline`、`离线`、error 非空。
- `removing the selected device returns to 本机 and keeps its sessions`：`deviceTab == id`，remove 成功后 `deviceTab == null`，该设备的会话条目仍在。
- `setTheme survives an unwritable config dir`：configDir 是 `chmod 500` 的临时目录 → `prefs.theme` 已变、hint 以 `偏好没有保存：` 开头。

- [ ] **Step 2: 跑测试确认失败** → 编译失败。
- [ ] **Step 3: 实现 `main_state.dart`**。pending 条目存在 `Map<String, SessionEntry>`，`opened` 或请求失败时移除；hub 会话通过 `hub.sessions` 每次 `notifyListeners` 时重新映射成 `SessionEntry`。
- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: Commit** `feat(gui): MainState — sessions, devices, hints, prefs`

---

### Task 6: 顶栏与舞台

**Files:**
- Create: `gui/lib/ui/top_bar.dart`、`gui/lib/ui/stage.dart`、`gui/lib/ui/backdrop.dart`
- Test: `gui/test/ui/top_bar_test.dart`、`gui/test/ui/stage_test.dart`

**Interfaces:**
- Consumes: `MainState`（Task 5）、`StatusLamp`/`RappButton`/`ConfirmButton`（Task 2）、`RappTokens`。
- Produces:
  - `class TopBar extends StatelessWidget { TopBar({required MainState state, required bool fullscreen, required VoidCallback onToggleFullscreen}) }`，高 56。从左到右：面板按钮（`Key('panel-button')`，tooltip「面板」）、‹（`Key('prev')`，tooltip「上一个」）、当前会话（灯 + app 名 600 字重；第二行设备 · 路径词；没有当前会话时写「没有选中的会话」）、›（`Key('next')`，tooltip「下一个」）、提示（`Expanded`，一行，`TextOverflow.ellipsis`，`--muted`）、全屏按钮（`Key('fullscreen-button')`，tooltip「进入全屏」或「退出全屏」）。会话少于 2 个时 ‹ › 禁用。
  - `class Stage extends StatelessWidget { Stage({required MainState state}) }`，`Key('stage')`。四种内容：
    - `hubProblem` 非空：居中写 hubProblem。
    - 没有当前会话：居中「打开左侧面板，选一个会话或到设备里打开 app」加一个「打开面板」次级按钮。
    - 当前会话连接中：居中旋转的连接中灯和「正在连接」。
    - 当前会话活动：1px 虚线 `--line` 边框的占位，居中 app 名、一行「<appName> 在单独的窗口里 · <设备> · <路径词>」，下面「切到窗口」主按钮（`Key('focus-button')`）和「结束会话」`ConfirmButton`（`Key('end-button')`）。
  - `class Backdrop extends StatelessWidget { Backdrop({required RappTheme theme, required Widget child}) }`：MATRIX 叠 1px 扫描线（每 3px 一条 `--line` 8% 不透明）和四角暗角；IRON MAN 叠 32px 淡网格（`--line` 18%）；AVATAR 底层三团失焦光斑（`--on` 10%，`ImageFiltered` 模糊 60）加淡竖线；WESTWORLD 无。全部 `IgnorePointer` 包住，不拦点击。
  - 路径词用 `session_model.dart` 的 `pathLabels`（Task 4）。

- [ ] **Step 1: 写失败的测试**
  - `top bar shows current session name, device and path`。
  - `prev/next disabled with fewer than two sessions`；`next moves current`（两个会话，点 `Key('next')` 后 `state.currentKey` 变）。
  - `long hint is one line with ellipsis`（Text 的 `maxLines == 1`、`overflow == TextOverflow.ellipsis`）。
  - `stage placeholder focus button sends focus`；`end button needs two taps`（点一次 sent 里没有 close；再点一次有 `{'cmd':'close','sid':1}`）。
  - `stage shows connecting while open is pending`（找到 `StatusLamp` kind=connecting 和文字「正在连接」）。
  - `stage shows hub problem after hub dies`，且找不到 `Key('focus-button')`。
- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: Commit** `feat(gui): top bar, stage placeholder, theme backdrops`

---

### Task 7: 左侧面板外框与会话标签

**Files:**
- Create: `gui/lib/ui/side_panel.dart`、`gui/lib/ui/sessions_tab.dart`
- Test: `gui/test/ui/side_panel_test.dart`

**Interfaces:**
- Consumes: `MainState`、`groupSessions`、`StatusLamp`、`rowBackdrop`/`rowBorder`、`RappButton`、`themeOrder`/`themeLabel`。
- Produces:
  - `class SidePanel extends StatelessWidget { SidePanel({required MainState state, required Widget devicesTab}) }`：宽度 会话 330、设备 720，取 `min(规格宽度, MediaQuery 宽度)`；`--bg` 实底、`--text` 右边框、深色投影。顶部：两个标签按钮（`Key('tab-sessions')` 会话、`Key('tab-devices')` 设备，选中样式见设计语言 §8）和收起按钮（`Key('panel-close')`，tooltip「收起面板」）。中间是当前标签内容（设备标签由调用方传入，Task 8 实现，避免这里依赖 LocalSection 的一大串参数）。底部固定：主题下拉（`Key('theme-dropdown')`，按 `themeOrder`）、启动时全屏开关（`Key('start-fullscreen')`，带文字「启动时全屏」）、七盏灯的图例（灯 + `lampWord`）、总览数字（「在线设备 N」「会话 N」「总流量 —」，30px 等宽 600 字重，为 0 时 `--muted`）。
  - `class SessionsTab extends StatelessWidget { SessionsTab({required MainState state}) }`：顶部分组切换（设备 / App，标签样式）；每组一个小标题（11px、`--muted`、字距 `labelSpacing`），每个会话一条 60px 高的行（`Key('session-<key>')`）：灯 + `lampWord` 的 Semantics、app 名、第二行（按设备分组时写路径词；按 App 分组时写设备名 · 路径词）；选中行边框 `--text` 加 1px 内描边。点一行 = `state.select(key)`。没有会话时写「没有打开的会话。到「设备」里打开一个 app。」。

- [ ] **Step 1: 写失败的测试**
  - `tapping a session selects it and closes the panel`。
  - `grouping switch regroups`（切到 App 后组标题变成 app 名）。
  - `theme dropdown lists the four films in order`；`picking IRON MAN changes prefs.theme`。
  - `start fullscreen switch saves`（关掉后 `UiPrefs.load(dir).startFullscreen == false`）。
  - `legend shows all seven words`。
  - `panel is clamped to the window width`（`tester.view.physicalSize = Size(400, 800)`、`devicePixelRatio = 1`，设备标签下面板宽 ≤ 400）。
  - `session row is 60 tall`。
- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: Commit** `feat(gui): side panel shell, sessions tab, theme picker, legend`

---

### Task 8: 设备标签（本机、远程设备 app、添加设备）

**Files:**
- Create: `gui/lib/ui/devices_tab.dart`、`gui/lib/ui/add_device_form.dart`
- 参考：`gui/lib/pages/hosts_section.dart`（添加表单和 app 列表的现有行为从这里搬；文件本身在 Task 9 随 `home_page.dart` 一起删，避免中间提交编译不过）；`gui/test/hosts_section_test.dart` 里仍适用的用例改写到 `gui/test/ui/devices_tab_test.dart`
- Test: `gui/test/ui/devices_tab_test.dart`

**Interfaces:**
- Consumes: `MainState`（`deviceTab`、`selectDevice`、`probe`、`probes`、`openOrSwitch`、`removeDevice`、`deviceName`、`hubUsable`）、`LocalSection`、`AccessLogSection`（原样复用，参数同 `home_page.dart` 现在的传法）、`missingPermissions`/`remoteHint`、`ConfirmButton`。
- Produces:
  - `class DevicesTab extends StatefulWidget { DevicesTab({required MainState state, required Widget local}) }`：`local` 是调用方拼好的「本机」内容（`LocalSection` + `AccessLogSection`，Task 9 传入）。顶部一排设备标签：「本机」（`Key('device-local')`）在最前，然后每台远程设备（`Key('device-<id>')`，灯 = probe 的 lamp、文字 = 名字，没探测过时触发 `probe`）。initState 调 `state.probeAll()`。
  - 远程设备内容：头部一行 名字、ID（等宽）、probe 词（在线/离线/连接中）、路径词、「删除设备」`ConfirmButton`（`Key('remove-device')`）；离线时显示错误文字；缺权限时显示 `remoteHint`（同现在）；然后每个 app 一行 68px（`Key('app-<bundle>')`）：灯（有会话=该会话的灯，否则未打开）、app 名、bundle id（等宽 12px、`--muted`）、右侧按钮——没有会话「打开」、连接中禁用的「打开」、活动「切到」（`Key('open-<bundle>')`）。没有 app 时写「对方没有可共享的窗口」。末尾保留现在的「Bundle ID」输入框加「打开」。
  - 页面底部：`AddDeviceForm`。
  - `class AddDeviceForm extends StatefulWidget { AddDeviceForm({required HubClient hub, required ValueChanged<String> onAdded}) }`：ID 或 ID@IP 输入框（`Key('add-id')`，标签「ID 或 ID@IP（不经 relay）」）、密码（`Key('add-password')`，遮蔽）、「添加设备」主按钮（`Key('add-button')`）；错误在下方一行；成功后清空并回调 `onAdded(id)`（DevicesTab 用它切到新设备并 probe）。

- [ ] **Step 1: 写失败的测试**
  - `adds a device and switches to it`（emit `host_added` → `state.deviceTab == id`，发出了一条 `apps`）。
  - `add error is shown inline and nothing switches`。
  - `app rows show 打开 / 切到 by session state`。
  - `tapping 打开 opens and closes the panel`（`state.panel == null`，sent 有 `open`）。
  - `remove device needs two taps; selected device falls back to 本机 and its sessions stay`。
  - `offline device shows 离线 and the error`。
  - `missing permissions on a remote host show the remote hint`（apps 回复带 `permissions: {screen_recording: false}`）。
  - `app row is 68 tall`。
- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过**；`flutter analyze` 无问题。
- [ ] **Step 5: Commit** `feat(gui): devices tab — 本机, remote apps, add device`

---

### Task 9: 主窗口组装、启动全屏、替换 HomePage

**Files:**
- Create: `gui/lib/ui/main_window.dart`、`gui/lib/ui/fullscreen.dart`
- Modify: `gui/lib/main.dart`（`HomePage` 换成 `MainWindow`；`_App` 的 theme 由 `MainState.prefs.theme` 决定；读 `UiPrefs.load(cfg)`；窗口显示后按 `startFullscreen` 进全屏）
- Delete: `gui/lib/home_page.dart`、`gui/lib/pages/sessions_section.dart`、`gui/lib/pages/hosts_section.dart`、`gui/test/hosts_section_test.dart`（`_openFolder` 搬到 `main_window.dart`）
- Test: `gui/test/ui/main_window_test.dart`

**Interfaces:**
- Consumes: Task 1–8 的全部产出；`ServiceMonitor`、`ServiceController`、`AccessLogSection`、`LocalSection`、`openFolderCommand`。
- Produces:
  - `abstract class FullscreenControl { Future<bool> isFullScreen(); Future<void> setFullScreen(bool on); }`；`class WindowManagerFullscreen implements FullscreenControl`（调 `windowManager`）；测试用假的。
  - `class MainWindow extends StatefulWidget { MainWindow({required MainState state, required ServiceMonitor monitor, required ServiceController? control, required String configDir, required FullscreenControl fullscreen}) }`：`Backdrop` 里 `Column[TopBar, Expanded(Stack[Stage, 面板遮罩, SidePanel])]`。面板打开时舞台上盖一层半透明 `--bg` 遮罩（点遮罩=收起）；舞台始终占满 `Expanded`，面板是 `Positioned` 在 `Stack` 里——这样面板开合不改舞台大小。
  - 快捷键（`Shortcuts` + `Actions`，焦点在窗口内时生效）：macOS ⌃⌘F、其他系统 F11 → 切换全屏；Esc → 面板开着就收起，否则全屏中就退出全屏；⌘[ / ⌘]（其他系统 Ctrl）→ 上一个 / 下一个会话。
  - `main.dart`：`MaterialApp` 包在 `ListenableBuilder(listenable: state)` 里，`theme: themeDataFor(state.prefs.theme)`，`themeMode: ThemeMode.dark`；`_showWindow(Size(1194, 834), 'rapp')`（规格基准尺寸），显示后 `if (prefs.startFullscreen) await WindowManagerFullscreen().setFullScreen(true)`。退出确认对话框、托盘保持不变。`--cm` 分支不动。

- [ ] **Step 1: 写失败的测试**
  - `opening and closing the panel never changes the stage size`（对会话、设备两个标签各开一次：`tester.getSize(find.byKey(Key('stage')))` 前后相等）。
  - `every tappable control is at least 48 tall`：开着设备标签和会话标签各扫一遍，`find.byWidgetPredicate((w) => w is ButtonStyleButton || w is IconButton || w is InkWell || w is DropdownButton || w is Switch)`，每个 `getSize(...).height >= 48`（`Switch` 用它外面那一行的高度——测试里找 `Key('start-fullscreen')` 的行）。
  - `window mode has no permanent element besides the top bar`：面板收起时，`Stage` 之外只有 `TopBar`（找不到 `SidePanel`）。
  - `fullscreen button toggles the fake`；`Esc closes the panel first, then leaves fullscreen`。
  - `tapping the scrim closes the panel`。
- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现 `main_window.dart`、`fullscreen.dart`；改 `main.dart`；删旧文件**。
- [ ] **Step 4: 全部 Flutter 测试和静态检查** — `flutter analyze` → `No issues found!`；`flutter test` → 全部 PASS。
- [ ] **Step 5: Commit** `feat(gui): main window shell replaces HomePage; fullscreen at launch`

---

### Task 10: 实机检查、打包、记录

**Files:**
- Modify: `tasks/todo.md`（加 S1 一节，逐项打勾写验证方式）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` 顶部状态行后加一句"S1 已实现（计划 `docs/superpowers/plans/2026-11-12-rapp-main-window-s1.md`）"

- [ ] **Step 1: 全量验证** — Rust `cargo test --workspace`、`cargo clippy --workspace --all-targets`；Swift `./scripts/check.sh` 末行 `EXIT=0`；Flutter `flutter analyze`、`flutter test`。
- [ ] **Step 2: 实机检查（只用自己起的进程，按 PID 收尾）**：`RAPP_HOME` 指向 scratchpad 里的新目录，`RAPP_BIN_DIR` 指向本次构建的二进制；`flutter run -d macos` 或打包后的 app 用 `open -n` 起。检查：启动即全屏；顶栏是唯一常驻元素；四套主题都能切、重启后保持；⌃⌘F、Esc 行为；设备标签里「本机」显示正常；添加 `id@127.0.0.1` 指向自己起的测试 host（临时端口、令牌 `runtest123`，目标 app 是 `pgrep` 确认没在跑后自己 `open -g` 起的 Calculator）；「打开」后会话出现、舞台占位出现；「切到窗口」把 rapp-client 窗口提到最前；「结束会话」点两次才结束。截图只截 rapp 自己的窗口。结束后按 PID 关掉自己起的 host、client、Calculator、GUI。
- [ ] **Step 3: 打包** — `scripts/package-macos.sh`；不替换 `/Applications/rapp.app`，不重启已装的 rapp-service。
- [ ] **Step 4: Commit** `docs: S1 done — todo, spec status`
