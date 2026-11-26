# 等候卡片 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 慢操作（首先是 ⌘T 新建文本终端）一开始就在舞台上浮出一张等候卡片，直到出结果。

**Architecture:** `Waits` 是一个 ChangeNotifier（新文件 `gui/lib/ui/waits.dart`），记录正在等的事和最近一次的结果。MainState 持有它，慢操作通过 `waits.run(...)` 包起来。主窗口舞台 Stack 的最上层放一个 `WaitCard`（新文件 `gui/lib/ui/wait_card.dart`），它只监听 `waits`。

**Tech Stack:** Flutter/Dart，flutter_test。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-wait-card-design.md`

## Global Constraints

- 卡片在等待开始 300 ms 后才出现；300 ms 内成功的操作不显示卡片。
- 失败的结果停留 4 秒；需要授权的结果停留 8 秒。哪怕失败发生在 300 ms 内，结果也要显示。
- 卡片不接收点击（IgnorePointer），不挡键盘，没有取消按钮。
- 文案：
  - ⌘T、新建、启动：`正在新建终端…`
  - 恢复：`正在恢复终端…`
  - 设备页开 shell：`正在打开终端…`
  - 同类排队：`还有 N 个排队`
  - 不同类：`另有 N 件在等`
  - 秒数：`N 秒`
- 顶栏 hint 和 hintHistory 的写法保持不变，卡片只是额外加的。
- 不改 hub、协议和超时时间。
- 一张卡片只有一处实现，不复制。
- flutter 在 `~/development/flutter/bin`，不在 PATH 里；跑完测试后要还原 `gui/pubspec.lock`。

## Review Focus

- 连按 3 次 ⌘T：一按下就计入排队，卡片显示「还有 2 个排队」。每做完一个，数字减一。→ Task 2 的 `wait_card_counts_queued_presses`
- ⌘T 碰到被控 Mac 正在问授权：卡片显示授权那句话，并切到那台设备的桌面（以前 ⌘T 不切桌面）。→ Task 2 的 `new_term_from_consent_shows_desktop`
- 第一件失败后第二件还在等：结果文字和「还有 N 个排队」一起显示，不能互相覆盖。→ Task 1 的 `outcome_and_waiting_together`
- MainState dispose 后计时器还在跑：不能报错，也不能调已经 dispose 的 notifyListeners。→ Task 1 的 `dispose_cancels_timers`
- 卡片文字很长（授权那句约 50 字）：最多两行，宽度上限 420，超出用省略号，不能撑出舞台。→ Task 3 的 `long_outcome_wraps_within_card`

---

### Task 1: `Waits` 模型

**Files:**
- Create: `gui/lib/ui/waits.dart`
- Test: `gui/test/ui/waits_test.dart`

**Interfaces:**
- Produces:
  - `class WaitItem { final String what; final String? detail; final DateTime started; }`
  - `class WaitOutcome { final String text; final bool asks; }`
  - `class Waits extends ChangeNotifier`，构造为 `Waits({Duration showAfter = const Duration(milliseconds: 300), Duration failFor = const Duration(seconds: 4), Duration askFor = const Duration(seconds: 8), DateTime Function()? now})`
  - `Future<T> run<T>(String what, Future<T> Function() f, {String? detail, String Function(Object e)? words, bool Function(Object e)? asks})`：调用时就登记，结束时移除。抛错时把 `outcome` 设为 `WaitOutcome(words?.call(e) ?? '$e', asks?.call(e) ?? false)`，停留 askFor 或 failFor，然后照原样 rethrow。成功时不设 outcome。
  - `List<WaitItem> get shown`：已等够 showAfter 的那些，按开始时间从早到晚排。
  - `WaitOutcome? get outcome`
  - `String? get moreLine`：`shown` 的第一件之外，其他项的说明。其余项都和第一件 `what` 相同时，返回 `还有 N 个排队`；否则返回 `另有 N 件在等`。N 是除第一件外的全部登记项（包括还没到 300 ms 的）。没有其他项时返回 null。如果 `shown` 为空但有 outcome，就以全部登记项为准。
  - `dispose()`：取消全部计时器。
- 用 Timer 在 showAfter 到点、outcome 到期时调用 notifyListeners。秒数的刷新归卡片管，这里不负责。

- [ ] **Step 1: 写失败的测试**（用 `fakeAsync` 跑，`now` 注入 fake clock）
  - `hidden_before_300ms`：run 一个 100 ms 后完成的 future。50 ms 时 `shown` 为空；完成后 `shown` 仍为空，`outcome` 为 null，并且从头到尾 `shown` 都没有非空过（监听 notify 时记录下来）。
  - `shown_after_300ms`：run 一个永远不完成的 future。300 ms 时 `shown.single.what == '正在新建终端…'`。
  - `failure_outcome_stays_4s`：run 一个 50 ms 后抛 `StateError('x')` 的 future，`words: (e) => 'w'`。run 应该照原样抛出这个 StateError。抛出后 `outcome!.text == 'w'`、`asks == false`；3.9 s 时还在；4.1 s 时变为 null。
  - `ask_outcome_stays_8s`：`asks: (_) => true`，7.9 s 时还在，8.1 s 时变为 null。
  - `outcome_and_waiting_together`：两个 `正在新建终端…`。第一个在 500 ms 时失败，第二个一直挂着。600 ms 时 `outcome` 非空，`shown.single` 是第二个，`moreLine` 为 null。再加一个 `正在恢复终端…`，等到 1 s，`moreLine == '另有 1 件在等'`。
  - `queued_line`：一次登记三个同样 `what` 的，300 ms 后 `moreLine == '还有 2 个排队'`。
  - `dispose_cancels_timers`：run 一个会失败的，在 outcome 停留期间 dispose，接着 elapse 10 s，不应抛错。
- [ ] **Step 2: 运行测试，确认失败**
  - 命令：`cd gui && ~/development/flutter/bin/flutter test test/ui/waits_test.dart`
  - 预期：编译失败，因为 `Waits` 还没定义。
- [ ] **Step 3: 实现 `gui/lib/ui/waits.dart`**，满足上面的 Interfaces。
- [ ] **Step 4: 运行测试，确认通过**
  - 命令同 Step 2。预期：全部通过。
- [ ] **Step 5: 提交**
  - `git add gui/lib/ui/waits.dart gui/test/ui/waits_test.dart && git commit -m "feat(gui): Waits model for the wait card"`

### Task 2: 接入 MainState 和设备页

**Files:**
- Modify: `gui/lib/ui/main_state.dart`。改动点：
  - 字段：加 `waits`，在 `dispose` 里一起释放。
  - `newTermFrom`（约 3624 行）
  - `_openTerms` 的 NewText 分支（约 3520 行）
  - `restoreSaved`（约 3420 行）
  - `openStandby`（约 1787 行）
- Modify: `gui/lib/ui/devices_tab.dart:530`
- Test: `gui/test/term/term_main_test.dart`，复用里面的 `hubAnswers` / `listOf` / `openTerm`。

**Interfaces:**
- Consumes：Task 1 的 `Waits.run` / `shown` / `moreLine` / `outcome`。
- Produces：
  - `final Waits waits = Waits();`，公开字段，Task 3 的卡片读它。
  - `@visibleForTesting static bool consentError(Object e) => e is HubException && isConsentAsk(e.message);`
  - 每处接入都传 `words: newTermWords, asks: consentError`。`detail` 一律是 `deviceName(id)`；⌘T 用 `'${deviceName(id)} · 在「$shown」旁边'`，其中 `$shown` 来自 `termRowOf('$device/$term')`，取不到 row 时只写设备名。目录不在终端列表里，所以不显示目录；这是对 spec「设备·目录」的落地，算我的决定。
- `newTermFrom`：`waits.run` 要包住整个排队链上的那一节，也就是在按下时调用，而不是轮到时才调用，这样排队数一按就有。写法：`newTermFrom` 同步调用 `waits.run(..., () => _newTerms = _newTerms.then(...))`；或者先把链上的 future 存下来，再交给 run 包。`newTermTimeout` 的超时仍然只算轮到之后的等待。catch 里在设 hint 之后补一句 `_showConsentPrompt(device, e)`。
- 原有的 try/catch 和 hint 文案不动。`waits.run` 放在 try 里面，它 rethrow 的错误由原来的 catch 处理。

- [ ] **Step 1: 写失败的测试**（加在 term_main_test 里 `new_term_from_queues` 旁边）
  - `wait_card_counts_queued_presses`：
    - 用 3 个 gate；在 `runAsync` 里连发 3 次 `newTermFrom` 并 flush，然后 `tester.pump(400ms)`。
    - 预期：`s.waits.shown.first.what == '正在新建终端…'`，`s.waits.moreLine == '还有 2 个排队'`。
    - 放行第一个 gate 后：`moreLine == '还有 1 个排队'`。
    - 三个都放行后：`s.waits.shown` 为空，`s.waits.outcome` 为 null。
  - `new_term_from_consent_shows_desktop`：
    - 给 `hubAnswers` 加一个可选参数 `openError`：open_term 回 `{'event':'error','req':..,'error': openError}`。
    - 用一个支持图形应用的远端设备（参照 overview_test 里现有的授权切桌面用例的设备设置；那个设备不能是 `localLoadId`）。
    - 错误文字取 `'macOS is asking whether rApp may control Terminal'`。
    - 预期：`s.waits.outcome!.asks == true`；outcome 文字和 `s.hint` 都以 `被控 Mac 上弹出了授权框` 开头；`t.sent` 里有一条打开 `desktop:` 的请求，或者 `s.currentKey` 以 `/desktop:` 结尾，按现有 consent 测试的断言方式写。
  - `new_terms_from_overview_shows_wait`：总览「新建」（`newTermFromRestore('111')`，gate 挂住），pump 400 ms 后，`s.waits.shown.single.what == '正在新建终端…'`。
- [ ] **Step 2: 运行测试，确认失败**
  - 命令：`cd gui && ~/development/flutter/bin/flutter test test/term/term_main_test.dart --plain-name "wait_card"`，以及上面另外两个用例名。
  - 预期：FAIL，原因是 `waits` 未定义。
- [ ] **Step 3: 在 MainState 和 devices_tab 里接入**，按上面的 Interfaces 改。设备页那处是 `state.waits.run('正在打开终端…', () => state.openText(...), detail: state.deviceName(id), words: MainState.newTermWords, asks: MainState.consentError)`。
- [ ] **Step 4: 跑测试，确认通过，再跑全量 GUI 测试防止回归**
  - 命令：`cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
  - 预期：全部通过，analyze 无 issue。然后 `git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交**
  - `git commit -am "feat(gui): slow terminal opens report to the wait card; ⌘T shows the consent desktop"`

### Task 3: `WaitCard` 组件并挂进主窗口

**Files:**
- Create: `gui/lib/ui/wait_card.dart`
- Modify: `gui/lib/ui/main_window.dart`：在舞台 `Stack(children: [...])`（约 350 行）的末尾加一层。
- Test: `gui/test/ui/wait_card_test.dart`

**Interfaces:**
- Consumes：`Waits`（Task 1）、`state.waits`（Task 2）。
- Produces：`class WaitCard extends StatefulWidget { const WaitCard({super.key, required this.waits}); final Waits waits; }`
- 显示规则：
  - 没有 `shown` 也没有 `outcome` 时返回 `SizedBox.shrink()`。
  - 有内容时，最外层是 `IgnorePointer`，再用 `Align(alignment: Alignment(0, -0.5))` 放置，也就是舞台高度约 1/4 处。
  - 卡片 `ConstrainedBox(maxWidth: 420)`，底用 `t.float` 渐变，边框 `t.line`，圆角 `t.r * 2`，内边距 12。用 `float` 而不是透明玻璃，是因为它盖在远端画面上；这是对 spec「半透明玻璃底」的修正，算我的决定。
- 内容（从上到下）：
  - 有 outcome 时显示结果文字：asks 用 `t.warn` 色，失败用 `t.text` 色，maxLines 2，超出用省略号。
  - 有 `shown` 时显示一行：16px 的 `CircularProgressIndicator(strokeWidth: 2, color: t.on)` + `what` + 右侧 `N 秒`（`t.muted` 色）。
  - `detail` 和 `moreLine`：各占一行小字，`t.muted` 色，maxLines 1。
- 秒数：`shown` 非空时，State 里开一个 `Timer.periodic(1s, setState)`；空了就取消。dispose 时也取消。秒数按 `(now - shown.first.started).inSeconds` 计算。
- 卡片的 Key：`const Key('wait-card')`。

- [ ] **Step 1: 写失败的测试**
  - `wait_card_hidden_then_shown`：pump 一个包着 `WaitCard(waits: w)` 的 MaterialApp（参照 `test/ui/helpers.dart` 的 `wrap`），`w.run` 一个挂住的 future。pump 100 ms 时找不到 `Key('wait-card')`；pump 400 ms 后找到，并且有 `find.text('正在新建终端…')`。pump 2 s 后，find 中含有 `秒` 的文字是 `2 秒`。
  - `wait_card_lets_taps_through`：卡片底下放一个全屏 GestureDetector，点卡片中心，GestureDetector 的 onTap 被调用。
  - `long_outcome_wraps_within_card`：失败文字是 `newTermWords` 的授权那句。卡片宽度 ≤ 420，Text 的 `maxLines == 2`，没有 overflow 异常（`tester.takeException()` 为 null）。
  - `main_window_has_wait_card`：在 term_main_test 现有的 window 里找到 `find.byType(WaitCard)`。
- [ ] **Step 2: 运行测试，确认失败**
  - 命令：`cd gui && ~/development/flutter/bin/flutter test test/ui/wait_card_test.dart`
  - 预期：编译失败。
- [ ] **Step 3: 实现 `wait_card.dart`，并在 main_window 舞台 Stack 的末尾加 `Positioned.fill(child: WaitCard(waits: state.waits))`。**
- [ ] **Step 4: 跑全量**
  - 命令：`cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`
  - 预期：全部通过。然后 `git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交，并在 `tasks/todo.md` 加「等候卡片」实机检查**
  - 检查项：
    1. 被控 Mac 上按 ⌘T，0.3 秒内出卡片，秒数在走；
    2. 连按 3 次 ⌘T，显示「还有 2 个排队」，并逐个递减；
    3. 用 `tccutil reset AppleEvents` 重置授权后按 ⌘T，卡片显示授权提示，并切到被控 Mac 桌面；
    4. 总览「新建」「恢复」和设备页开 shell 都出卡片；
    5. 卡片出现期间照常能打字、点击；
    6. 浅色、深色主题下都看得清。
  - `git add -A gui docs/superpowers tasks/todo.md && git commit -m "feat(gui): WaitCard floats over the stage while a slow open waits"`
