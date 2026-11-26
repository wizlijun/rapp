# 总览本机列折叠 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 没有本机服务（`Overview.monitor == null`，即 iPad/Duo）时，总览「本机」列默认折成窄竖条，点开展开、可折回。

**Architecture:** `gui/lib/ui/overview.dart` 里新增一个有状态的 `_LocalFold`，它包住本机列：折叠时画竖条，展开时画现有的 `_Column`，并给 `_Column` 一个 `onFold` 回调，用来在列头放折回按钮。展开状态存在 `_LocalFold` 的 State 里。`Overview` 是 ListenableBuilder 重建，而 State 靠 Wrap 里的位置和 key 保留，所以本次运行中展开状态不会丢。

**Tech Stack:** Flutter / Dart，flutter_test。

**Spec:** `docs/superpowers/specs/2026-11-26-overview-fold-local-design.md`

## Global Constraints

- 只在 `monitor == null && col.id == null` 时折叠；有 monitor 时（桌面，或测试里 iOS 带 monitor 的情况）本机列和现在完全一样。
- 远程设备列不变。
- 不存盘、不加设置项、不进 `MainState`。
- 折叠条宽 56px；key：外层 `column-local`（保持不变，排序/换行测试靠它），折叠条 `column-local-folded`，折回按钮 `column-local-fold`；折叠条里的系统图标仍用 key `os-mark-local`。
- 语义：折叠条 `button: true, label: '展开 本机'`；折回按钮 `label: '折叠 本机'`。
- 用户可见文字中文。

## Review Focus

1. 窄窗口（600 宽、换行）下折叠条仍在 `column-local` 的位置、不溢出 —— 现有 600-wide 测试覆盖，跑一遍即可。
2. 状态在 `state.notifyListeners()` 重建后保持展开 —— Task 1 测试 `stays open across rebuilds`。
3. 系统图标在折叠条上仍是同一个 `OsMark`（`os-mark-local` 依然能找到，值正确）—— 现有 `each column shows its system mark` 测试覆盖。
4. 名字很长（未来可能不是「本机」）时竖条不溢出 —— `maxLines: 1` + ellipsis，宽度锁 56；测试里断言无 exception。
5. 有 monitor 时完全不出现折叠条 —— Task 1 测试 `a local service keeps the column open`。

---

### Task 1: 本机列折叠

**Files:**
- Modify: `gui/lib/ui/overview.dart`（`Overview.build` 的 Wrap children；`_Column` 加 `onFold`；新增 `_LocalFold`、`_FoldedColumn`）
- Test: `gui/test/ui/overview_test.dart`（新增 group `local column fold`；修 `version-local` 那条）

**Interfaces:**
- `_Column({required MainState state, required DeviceColumn col, ServiceMonitor? monitor, VoidCallback? onFold})` —— `onFold != null` 时列头名字那一行右侧放一个 `IconButton`/InkWell（`Icons.chevron_left`，size 18，key `column-local-fold`），点了调 `onFold`。
- `_LocalFold({required MainState state, required DeviceColumn col})` —— StatefulWidget，`bool _open = false`；外层 `KeyedSubtree(key: Key('column-local'))` 或让子 widget 带这个 key，二者只能有一个带 `column-local`。
- `_FoldedColumn({required DeviceColumn col, required VoidCallback onOpen})` —— `SizedBox(width: 56)`，`t.panelBox(border: t.line)`，竖排 `OsMark(col.os, key: Key('os-mark-local'))`、`StatusLamp(col.lamp)`、名字 Text（单行省略、`bodySmall`），上下 padding 10，元素间距 6；整条 InkWell。

- [ ] **Step 1: 写失败的测试**（在 `overview_test.dart` 里，用文件现有的 `boot` / `show` / `inside`）

```dart
group('local column fold', () {
  testWidgets('no local service: the 本机 column starts folded, 56 wide', (tester) async {
    hubVersion = '0.14.7';
    await boot(tester);
    await show(tester);
    expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('column-local'))).width, 56);
    expect(inside('column-local', find.text('本机')), findsOneWidget);
    expect(find.byKey(const Key('os-mark-local')), findsOneWidget);
    expect(find.text('没有打开的 app'), findsNothing);
    expect(find.byKey(const Key('version-local')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap opens it; the fold button closes it again', (tester) async {
    hubVersion = '0.14.7';
    await boot(tester);
    await show(tester);
    await tester.tap(find.byKey(const Key('column-local-folded')));
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('column-local'))).width, 220);
    expect(find.byKey(const Key('version-local')), findsOneWidget);
    await tester.tap(find.byKey(const Key('column-local-fold')));
    await tester.pump();
    expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
  });

  testWidgets('stays open across rebuilds', (tester) async {
    await boot(tester);
    await show(tester);
    await tester.tap(find.byKey(const Key('column-local-folded')));
    await tester.pump();
    s.notifyListeners();
    await tester.pump();
    expect(find.byKey(const Key('column-local-folded')), findsNothing);
    expect(find.byKey(const Key('column-local-fold')), findsOneWidget);
  });

  testWidgets('a local service keeps the column open, with no fold button', (tester) async {
    await boot(tester);
    s.toggleOverview();
    final m = ServiceMonitor(readToken: () async => null);
    addTearDown(m.dispose);
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s, monitor: m))));
    await tester.pump();
    expect(find.byKey(const Key('column-local-folded')), findsNothing);
    expect(find.byKey(const Key('column-local-fold')), findsNothing);
    expect(tester.getSize(find.byKey(const Key('column-local'))).width, 220);
  });
});
```

（如果 `s.notifyListeners()` 不可从测试调用，改用一次会触发重建的现有状态变化，如 `port.emit(...)`。）

- [ ] **Step 2: 跑测试，确认失败**

Run: `~/development/flutter/bin/flutter test test/ui/overview_test.dart --plain-name 'local column fold'`
Expected: 4 条里前 3 条 FAIL（找不到 `column-local-folded`），第 4 条可能已通过前半。

- [ ] **Step 3: 实现** `_LocalFold` / `_FoldedColumn` / `_Column.onFold`，`Overview.build` 里本机列在 `monitor == null` 时换成 `_LocalFold(state: state, col: c)`。

- [ ] **Step 4: 修现有测试** `each column shows its version at the bottom…`：`show` 之后先 `tap(column-local-folded)` 再断言 `version-local`。

- [ ] **Step 5: 跑全部受影响测试**

Run: `~/development/flutter/bin/flutter test test/ui/` 和 `~/development/flutter/bin/flutter analyze`
Expected: 全绿、analyze 无 issue。之后 `git checkout pubspec.lock`（如有改动）。

- [ ] **Step 6: Commit**

```bash
git add gui/lib/ui/overview.dart gui/test/ui/overview_test.dart
git commit -m "feat(overview): fold the 本机 column when there is no local service"
```
