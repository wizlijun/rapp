# Dock 右键菜单 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS Dock 右键 rapp 列出所有会话（点了切过去，分离的只提它的窗口）和空闲「常用」（点了在那台主机打开）；托盘同步加「常用」；Dock 退出 / Cmd+Q 有远程窗口时先问。

**Architecture:** 菜单内容由 `gui/lib/tray_menu.dart` 的纯函数生成，托盘和 Dock 共用。Dart 在状态变化时把 Dock 版推给原生 `rapp/dock` channel 缓存，`applicationDockMenu` 从缓存同步建 `NSMenu`，点击把 key 回传 Dart，走和托盘同一个点击路由。退出由 `applicationShouldTerminate` 拦下交给 Dart 确认，确认后原生再 `NSApp.terminate`。

**Tech Stack:** Flutter/Dart（`tray_manager` 0.5 的 `MenuItem`），Swift（FlutterMacOS、AppKit）。

**Spec:** `docs/superpowers/specs/2026-11-18-rapp-dock-menu-design.md`

## Global Constraints

- 工作区 `/Users/bruce/git/rapp-dock`，分支 `feat/dock-menu`。**不要提交到 main**。
- flutter 不在 PATH：`export PATH=$HOME/development/flutter/bin:$PATH`；`flutter test` 会改 `gui/pubspec.lock`，每次跑完 `git checkout -- gui/pubspec.lock`。
- 文案逐字：`常用`、`（离线）`、`（已断开）`、`没有打开的会话`、`显示 rapp`、`退出`；退出确认沿用现有 `退出 rapp？` / `还有 N 个远程窗口，退出后都会断开。` / `退出`。
- 只在 macOS 主进程做 Dock 和退出拦截；`--cm`（`SingleInstance.isConnectionManager`）一律不注册、不拦。
- 关机/重启/注销引起的退出不拦。
- 退出确认后必须仍经过 `NSApp.terminate`，让 `SessionPlugin` 的 `willTerminate` → `releaseKeys` 照常发按键释放。

## Review Focus

1. 确认框还开着时又按 Cmd+Q（或 Dock 退出）→ 只有一个确认框，不叠第二个。（Task 5 的 `_quit` 重入保护）
2. 有远程窗口时关机/注销 → 不弹框、不阻止关机。（Task 4：有 quit reason 就 `.terminateNow`）
3. Dart 还没起来（启动早期）或 Dart 侧坏了时按 Cmd+Q → 直接退出，不会卡死退不掉。（Task 4：`dartReady` 之前 `.terminateNow`）
4. 正在连接（`sid == null`）或已断开的分离会话被点 → 走主窗口切过去，不调 `raise_detached`。（Task 2 测试）
5. 菜单建好后会话/常用已经没了再点 → 什么都不做，不切到一个不存在的 key。（Task 5 点击路由先查存在）

---

### Task 1: 菜单模型加「常用」和 Dock 版

**Files:**
- Modify: `gui/lib/tray_menu.dart`
- Test: `gui/test/tray_menu_test.dart`

**Interfaces:**
- Consumes: `AppRef`（`gui/lib/ui/workspace_store.dart`），`SessionEntry` / `groupSessions`（现有）。
- Produces:
  - `class MenuFavorite { const MenuFavorite(this.app, {required this.host, required this.offline}); final AppRef app; final String host; final bool offline; }`
  - `List<MenuFavorite> menuFavorites(List<AppRef> idle, {required String Function(String id) hostName, required bool Function(String id) offline})`
  - `List<MenuItem> trayItems(List<SessionEntry> sessions, {List<MenuFavorite> favorites = const []})`（签名扩展，老调用不变）
  - `List<MenuItem> dockItems(List<SessionEntry> sessions, {List<MenuFavorite> favorites = const []})`
  - `const favKeyPrefix = 'fav:';` 和 `String? favKeyOf(String? itemKey)`（返回 `AppRef.key`，与 `sessionKeyOf` 对称）

- [ ] **Step 1: 写失败测试**（加到 `tray_menu_test.dart`，用现有 `e()` 帮手，另加 `MenuFavorite f(String id, String host, String bundle, {bool offline = false}) => MenuFavorite(AppRef(id, bundle, bundle), host: host, offline: offline);`）

```dart
test('favourites follow the sessions under 常用, grouped by host name, favourite order kept', () {
  final items = trayItems([e('1', 'air', 'Notes')],
      favorites: [f('2', 'mini', 'Xcode'), f('1', 'air', 'Mail'), f('2', 'mini', 'Pages')]);
  final labels = [for (final i in items) if (i.type != 'separator') i.label];
  expect(labels, ['显示 rapp', 'air', '    Notes', '常用', 'air', '    Mail', 'mini', '    Xcode', '    Pages', '退出']);
  expect(items.firstWhere((i) => i.label == '常用').disabled, isTrue);
  expect(items.firstWhere((i) => i.label == '    Xcode').key, '${favKeyPrefix}2/Xcode');
  expect(items.firstWhere((i) => i.label == '    Xcode').disabled, isFalse);
});

test('an offline host says so and its favourites are greyed', () {
  final items = trayItems(const [], favorites: [f('2', 'mini', 'Xcode', offline: true)]);
  expect(items.firstWhere((i) => i.label == 'mini（离线）').disabled, isTrue);
  expect(items.firstWhere((i) => i.label == '    Xcode').disabled, isTrue);
});

test('no idle favourites: no 常用 section and no extra separator', () {
  final items = trayItems([e('1', 'air', 'Notes')]);
  expect(items.any((i) => i.label == '常用'), isFalse);
  expect(items.where((i) => i.type == 'separator').length, 2);
});

test('the dock menu is the tray menu without 显示 rapp, 退出 and their separators', () {
  final items = dockItems([e('1', 'air', 'Notes')], favorites: [f('2', 'mini', 'Xcode')]);
  final shape = [for (final i in items) i.type == 'separator' ? '—' : i.label];
  expect(shape, ['air', '    Notes', '—', '常用', 'mini', '    Xcode']);
  expect(dockItems(const []).map((i) => i.label), ['没有打开的会话']);
});

test('favKeyOf reads back the favourite key, null for others', () {
  expect(favKeyOf('${favKeyPrefix}2/Xcode'), '2/Xcode');
  expect(favKeyOf('${sessionKeyPrefix}2/Xcode'), isNull);
  expect(favKeyOf(null), isNull);
});

test('menuFavorites names each host and marks offline ones', () {
  final m = menuFavorites([const AppRef('2', 'Xcode', 'Xcode')],
      hostName: (id) => 'mini-$id', offline: (id) => id == '2');
  expect(m.single.host, 'mini-2');
  expect(m.single.offline, isTrue);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && flutter test test/tray_menu_test.dart`
Expected: 编译失败（`MenuFavorite` / `dockItems` / `favKeyOf` 未定义）。

- [ ] **Step 3: 实现**

在 `tray_menu.dart` 加上 Interfaces 里的类型和函数；文件头注释改成「Tray and Dock menus: …」。`trayItems` = `显示 rapp`、分隔线、`_body(...)`、分隔线、`退出`；`dockItems` = `_body(...)`。`_body` 是现有会话段，后面接常用段：常用段非空时先放分隔线和置灰的 `常用`，再按 `host` 字符串排序分组（同 host 名的按设备 id 分开，各自一组），组标题置灰，离线时加 `（离线）`，组内保持传入顺序，项 label 为 `'    ${app.name}'`，离线时 `disabled: true`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd gui && flutter test test/tray_menu_test.dart && git checkout -- pubspec.lock`
Expected: 全部 PASS（含原有 4 个）。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/tray_menu.dart gui/test/tray_menu_test.dart
git commit -m "feat(menu): idle favourites in the tray model, and a Dock variant"
```

### Task 2: `MainState.raiseIfDetached`

**Files:**
- Modify: `gui/lib/ui/main_state.dart`（放在 `focusCurrent()` 旁边，约 2584 行）
- Test: `gui/test/ui/main_state_test.dart`（放在 `'switching to an open embedded session does not focus through the hub'` 旁，复用同一个 `env`）

**Interfaces:**
- Produces: `bool raiseIfDetached(String key)`：`key` 对应的会话有 `sid`、`remote[sid]` 存在且 `detached`、不是终端（`isTermApp`）、灯不是 `Lamp.disconnected` 时，`portOf(sid)!.raiseDetached(sid)` 并返回 true；否则什么都不发、返回 false。不改 `currentKey`、不 `notifyListeners`。

- [ ] **Step 1: 写失败测试**

```dart
test('raiseIfDetached raises a live detached session and leaves the current one alone', () {
  env((a, t, port, st, hints) {
    port.emit(const DetachedEvent(1, true));
    a.flushMicrotasks();
    final before = st.currentKey;
    expect(st.raiseIfDetached('111/a'), isTrue);
    lastCall(port, 'raise_detached', {'sid': 1});
    expect(st.currentKey, before);
  });
});

test('raiseIfDetached is false for an attached, disconnected or unknown session', () {
  env((a, t, port, st, hints) {
    final calls = port.calls.length;
    expect(st.raiseIfDetached('111/a'), isFalse); // attached
    expect(st.raiseIfDetached('999/x'), isFalse); // unknown
    port.emit(const DetachedEvent(1, true));
    port.emit(const DisconnectedEvent(1, 'connection closed'));
    a.flushMicrotasks();
    expect(st.raiseIfDetached('111/a'), isFalse); // disconnected
    expect(port.calls.skip(calls).where((c) => c.$1 == 'raise_detached'), isEmpty);
  });
});
```

（`lastCall` 在该组里定义于这两个测试之后，实现时把新测试放在 `lastCall` 定义之后，或内联同样的断言。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && flutter test test/ui/main_state_test.dart --plain-name raiseIfDetached`
Expected: 编译失败（`raiseIfDetached` 未定义）。

- [ ] **Step 3: 实现** Interfaces 里的方法，按 `_entries` 里 `e.key == key` 找会话。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd gui && flutter test test/ui/main_state_test.dart && git checkout -- pubspec.lock`
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/ui/main_state.dart gui/test/ui/main_state_test.dart
git commit -m "feat(state): raiseIfDetached for menus that switch to a session"
```

### Task 3: Dart 侧 `DockChannel`

**Files:**
- Create: `gui/lib/dock_channel.dart`
- Test: `gui/test/dock_channel_test.dart`

**Interfaces:**
- Consumes: `MenuItem`（`tray_manager`）。
- Produces:
  - `List<Map<String, Object?>> dockPayload(List<MenuItem> items)`：分隔线 → `{'separator': true}`；其余 → `{'key': item.key, 'label': item.label, 'disabled': item.disabled}`（`key` 可为 null）。
  - `class DockChannel { DockChannel({required void Function(String key) onClick, required Future<void> Function() onQuitRequested, MethodChannel channel = const MethodChannel('rapp/dock')}); Future<void> setMenu(List<MenuItem> items); Future<void> confirmQuit(); }`
  - 原生→Dart 方法：`click`（参数 String key）、`quitRequested`（无参）。Dart→原生方法：`setMenu`（参数 `dockPayload(...)`）、`confirmQuit`（无参）。
  - 构造时 `setMethodCallHandler`；未知方法抛 `MissingPluginException`。

- [ ] **Step 1: 写失败测试**（`TestWidgetsFlutterBinding.ensureInitialized()`，用 `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler` 记录 Dart→原生调用，用 `handlePlatformMessage` + `StandardMethodCodec().encodeMethodCall` 模拟原生→Dart）

```dart
test('dockPayload: separators and items with key, label, disabled', () {
  final p = dockPayload([MenuItem(label: '常用', disabled: true), MenuItem.separator(), MenuItem(key: 'fav:2/X', label: '    X')]);
  expect(p, [
    {'key': null, 'label': '常用', 'disabled': true},
    {'separator': true},
    {'key': 'fav:2/X', 'label': '    X', 'disabled': false},
  ]);
});

test('setMenu sends the payload; confirmQuit asks the native side to quit', () async { /* calls == [('setMenu', payload), ('confirmQuit', null)] */ });

test('a native click reaches onClick with its key', () async { /* simulate 'click' with 'session:1/a' → clicked == ['session:1/a'] */ });

test('a native quitRequested runs onQuitRequested', () async { /* simulate 'quitRequested' → asked == 1 */ });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && flutter test test/dock_channel_test.dart`
Expected: 编译失败（文件不存在）。

- [ ] **Step 3: 实现** `gui/lib/dock_channel.dart`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd gui && flutter test test/dock_channel_test.dart && git checkout -- pubspec.lock`
Expected: 4 个 PASS。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/dock_channel.dart gui/test/dock_channel_test.dart
git commit -m "feat(dock): Dart side of the rapp/dock channel"
```

### Task 4: 原生 Dock 菜单、退出拦截、分离窗口

**Files:**
- Create: `gui/macos/Runner/DockMenu.swift`
- Modify: `gui/macos/Runner.xcodeproj/project.pbxproj`（照 `ComposerPlugin.swift` 的四处条目加 `DockMenu.swift`：PBXBuildFile、PBXFileReference、Runner 组、Sources 阶段；新 id 用同样风格的不重复 24 位十六进制）
- Modify: `gui/macos/Runner/MainFlutterWindow.swift`（`awakeFromNib` 里，非 `--cm` 时 `DockMenu.register(messenger:)`）
- Modify: `gui/macos/Runner/AppDelegate.swift`
- Modify: `gui/macos/Runner/DetachedWindow.swift`

**Interfaces:**
- Consumes: Task 3 的 channel 协议（名字 `rapp/dock`，方法 `setMenu` / `confirmQuit` / `click` / `quitRequested`，payload 形状）。
- Produces（Swift）：
  - `final class DockMenu: NSObject`，`static private(set) var shared: DockMenu?`，`static func register(messenger: FlutterBinaryMessenger)`。
  - `var dartReady: Bool`（第一次收到 `setMenu` 置 true）。
  - `func menu() -> NSMenu?`：从缓存 payload 建菜单，`autoenablesItems = false`；分隔线 `.separator()`；有 key 的项 target=self、action=`clicked(_:)`、`representedObject = key`；`disabled` → `isEnabled = false`。缓存为空返回 nil。
  - `@objc func clicked(_ item: NSMenuItem)` → `invokeMethod("click", arguments: key)`。
  - `var quitConfirmed = false`；`func requestQuit()` → `invokeMethod("quitRequested", arguments: nil)`。收到 `confirmQuit` → `quitConfirmed = true; NSApp.terminate(nil)`。

- [ ] **Step 1: 写 `DockMenu.swift` 和注册**

- [ ] **Step 2: `AppDelegate`**
  - `override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockMenu.shared?.menu() }`
  - `override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply`：
    1. `--cm`、`DockMenu.shared == nil`、`!dartReady`、`quitConfirmed` → `.terminateNow`
    2. 当前 Apple Event（`NSAppleEventManager.shared().currentAppleEvent`）带 `kAEQuitReason` 属性（关机/重启/注销都会带；Dock「退出」和 Cmd+Q 不带）→ `.terminateNow`
    3. 否则 `DockMenu.shared!.requestQuit()`，返回 `.terminateCancel`

- [ ] **Step 3: `DetachedWindow.swift`**
  - `DetachedWindow` 初始化处 `isExcludedFromWindowsMenu = true`。
  - `DetachedSession.raise()` 末尾加 `NSApp.activate(ignoringOtherApps: true)`（从 Dock/托盘点分离会话时 rapp 不在前台）。

- [ ] **Step 4: 编译验证**

Run: `cd gui && flutter build macos --debug 2>&1 | tail -5 && git checkout -- pubspec.lock`
Expected: `✓ Built build/macos/Build/Products/Debug/rapp.app`，没有 Swift 报错。

- [ ] **Step 5: 提交**

```bash
git add gui/macos
git commit -m "feat(dock): native Dock menu, quit gate, detached windows off the window list"
```

### Task 5: 接进 `_Shell`，实机检查清单

**Files:**
- Modify: `gui/lib/main.dart`（`_Shell`）
- Modify: `tasks/todo.md`

**Interfaces:**
- Consumes: Task 1 的 `trayItems` / `dockItems` / `menuFavorites` / `favKeyOf` / `sessionKeyOf`；Task 2 的 `state.raiseIfDetached`；Task 3 的 `DockChannel` / `confirmQuit`；现有 `state.idleFavorites`、`state.favorites`、`state.deviceName`、`state.deviceOffline`、`state.entries`、`state.select`、`state.openOrSwitch`。

- [ ] **Step 1: 菜单更新** `_updateMenu` 用 `favorites: menuFavorites(state.idleFavorites, hostName: state.deviceName, offline: state.deviceOffline)` 同时生成托盘和（macOS 上）Dock 两份；去重形状加上 `disabled`；托盘和 Dock 各自去重，Dock 用 `dock.setMenu(...)`。`DockChannel` 只在 `Platform.isMacOS` 时创建，在 `setupTray` 里且不受托盘失败影响（托盘的 try/catch 不能吞掉 Dock 的初始化）。

- [ ] **Step 2: 共用点击路由** `void _menuClick(String? key)`，托盘 `onTrayMenuItemClick` 和 Dock `onClick` 都走它：
  - `show` → `_show()`；`quit` → `_quit()`
  - session key：`state.entries` 里没有就不做；`state.raiseIfDetached(k)` 为 true 就结束；否则 `_show(); state.select(k);`
  - fav key：在 `state.favorites` 里按 `key` 找，找不到就不做；找到 `_show(); state.openOrSwitch(f.device, f.bundle, f.name);`

- [ ] **Step 3: 退出请求** Dock `onQuitRequested`：`if (await _confirm()) await dock.confirmQuit();`，其中确认文案与托盘 `_quit` 相同。给 `_quit` 和这条路径共用一个 `_quitAsking` 标志：确认框已经开着时再次请求直接忽略（Review Focus 1）。托盘「退出」路径保持 `_quitNow()`（`exit(0)`）不变。

- [ ] **Step 4: 全量验证**

Run: `cd gui && flutter analyze lib test && flutter test && flutter build macos --debug 2>&1 | tail -3; git checkout -- pubspec.lock`
Expected: analyze `No issues found!`；测试全部 PASS；构建 `✓ Built`。

- [ ] **Step 5: 实机检查清单** 在 `tasks/todo.md` 加一节 `## Dock 右键菜单（feat/dock-menu）实机检查`，逐条照 spec「留给实现」最后一条列出（共 9 条，每条 `- [ ]`），再加一条：确认框开着时再按 Cmd+Q 只有一个框。

- [ ] **Step 6: 提交**

```bash
git add gui/lib/main.dart tasks/todo.md
git commit -m "feat(dock): wire the Dock menu and quit confirmation into the shell"
```
