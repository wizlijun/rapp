# 桌面远程控制 — 交接文档

> 接手人：先读这份，再读计划 `docs/superpowers/plans/2026-11-14-rapp-desktop-sessions.md`
> 和设计 `docs/superpowers/specs/2026-11-14-rapp-desktop-sessions-design.md`。
> 本文记录「做到哪了、剩什么、Task 6 怎么做」，省得重新推导。

分支：`feat/desktop`（未推送）。每个 Task 单独提交，别 push。

---

## 1. 做完的（Task 1–5，已提交）

| commit | 内容 |
|--------|------|
| `3eca43e` | core：protocol v10、`screenLocked`/`unlock`、`desktopTarget`/`orderedDisplays`/`desktopTitle` |
| `aab0afb` | host：desktop 会话、锁屏检测、解锁打字（`UnlockTyper`） |
| `97648bb` | rust client-core / service：protocol v10、`screen_locked`/`unlock` 透传与落日志 |
| `a4430d3` | RappSession + macOS runner：`screen_locked` 事件、`unlock`/`set_banner` 命令、`DetachedWindow` 横幅 |
| `aa990ca` | GUI：设备列表里「桌面」入口、`screen_locked` 透传、删掉「用屏幕共享打开」按钮 |

这五步 = 端到端的管道已通：
- host 能起 `desktop:`（主屏）和 `desktop:<CGDirectDisplayID>`（其他屏）会话，发 `screenLocked(bool)`，收 `unlock(password)` 并打字解锁；密码 host 端不记不传。
- service / hub 把 `unlock` 作为一条访问记录事件落日志（只记 `{app, sid}`，不含密码）。
- GUI 的会话层（RappSession、Linux port、Dart `SessionPort`）已能收 `screen_locked`、发 `unlock`/`set_banner`。
- 设备列表里 `desktop:` 作为一个可收藏的 app 显示为「桌面」；`apps` 回包带 `displays` 数组。

**本地冒烟验证过**：`rapp-host serve --app desktop:` + 本地 client，ready 标题「… · 屏幕 1」、1 个窗口、stats 正常；`list-apps --json` 带 `displays`。真机锁屏解锁还没测（Task 8）。

---

## 2. 剩下的（Task 6–8，未做）

- **Task 6**：GUI 把 desktop 会话摆到舞台 + 其他屏开子窗口 + 锁屏横幅。详见下面第 4 节。
- **Task 7**：系统密码对话框、记住密码、自动输入（`UnlockStore` = `local/unlock.json` 0600）。见计划原文。
- **Task 8**：README、全量构建、真机锁屏测试（**需要用户配合锁 A**）。见计划原文。

---

## 3. 重要背景：这个功能的边界（接手人必读）

这是「机器主人自己授权、方便自己远程解锁」的无人值守远程能力（对标 RustDesk 的记住密码 / 开机自动输入），不是偷偷监控别人。保持这几条，别越界：

1. **解锁动作要留痕**：host 已经发 `unlock` 事件、service 已落访问记录。别去掉。
2. **密码只存在 B 的 `local/`**（0600），host 端不记、不传、日志里不出现。计划里是
   `base64(XOR(固定key))` 混淆——**这不是真加密**。接手做 Task 7 时，先问用户：
   要不要用 macOS Keychain 存，替掉 XOR 混淆（更稳妥）。XOR 只是最低档，用户之前的
   产品取向是「性能优先、relay 是唯一的门、其余从简」（见 memory `security-posture-relay-gate`），
   所以这是个 trade-off，让用户拍板，别自己默默决定。
3. **不要再自作主张去掉「正在被控制」的提示**——之前那个「被控端不弹提示」的决定是我（助手）
   没问就定的，不合适。目前被控端的问责靠访问记录。如果产品要面向「管别人的机器」，
   提示/知情这条应当回到台面上和用户确认，而不是默认隐藏。

---

## 4. Task 6 详细设计（已推导好，照着做）

**文件**：`gui/lib/ui/main_state.dart`、`gui/lib/ui/stage.dart`；
测试 `gui/test/ui/main_state_test.dart`、`gui/test/ui/stage_test.dart`。

`main_state.dart` 有 1955 行、状态互相咬得很紧，**务必 TDD、小步跑 `flutter test`**。
测试脚手架看 `test/ui/main_state_test.dart` 的 `group('embedded sessions')` 里的 `env(...)` helper：
它用 `FakeTransport`（`open` 自动回 `opened`，`sid = app.length`）和 `FakeSessionPort`
（`emit(SessionEvent)` 放事件、`calls` 记命令）。desktop 主屏 sid = `'desktop:'.length` = 8。

已经加好的、可以直接用的零件（在 `session_model.dart` / `hub_client.dart`）：
- `isDesktopApp(app)`（`desktop:` 开头）、`isDesktopScreen(app)`（`desktop:<id>`，长度>8）。
- `RemoteDisplay{ id, name, main, width, height }`；`HubApp.displays`（只有 `desktop:` 非空，按主屏在前、其余左到右排序）。
- `RemoteSession.screenLocked`（`bool?`，host 没说时为 null）。
- `SessionPort.unlock(sid, pw)` / `setBanner(sid, text)`；`ScreenLockedEvent(sid, locked)`。

### 4.1 其他屏开子窗口

- 用户点「桌面」→ 已有 `_openEmbedded(id, 'desktop:', '桌面')` 开主屏记录（主屏留在主窗口）。
- 主屏记录 **live 之后** 调 `_ensureDesktopScreens(id)`：
  1. `await hub.apps(id)`，把 `desktop:` 那个 `HubApp.displays` 存进
     `Map<String, List<RemoteDisplay>> _desktopDisplays[id]`。
  2. 对每个 `!main` 且还没开记录的屏，`_openEmbedded(id, 'desktop:${d.id}', '桌面 · 屏幕 ${N}', select: false, quiet: true)`。
     `N` = 该屏在有序 displays 里的 1-based 下标（主屏=屏幕1，所以其他屏是 2、3…）。
- **「再点一次桌面」补开漏掉的屏**：`_openEmbedded` 对 `desktop:` 主屏时，若记录已 live，
  也调一次 `_ensureDesktopScreens(id)`（幂等，已开的 `continue`）。
- **自动 detach**：在 `_onPortEvent` 的 `WindowsEvent` 分支，若 `isDesktopScreen(r.app)` 且
  `port?.supportsDetach == true` 且该 key 没自动 detach 过（用一个 `Set<String> _autoDetached`），
  就 `port!.detach(sid)` 并记下。Linux（无 detach）不自动开，只从切换条开（见 4.5）。

### 4.2 隐藏屏不进列表、不出提示

- `_mapEntries()` 的 embeds 分支过滤掉 `isDesktopScreen`：
  `[for (final r in _records.values) if (!isDesktopScreen(r.app)) _entryOf(r)]`。
- 所有会发 hint 的地方，隐藏屏要静音。至少这几处加 `&& !isDesktopScreen(r.app)`：
  - `_onPortEvent` 的 `ClosedEvent` 分支（`endedHint`）。
  - `_finishEnding(r)`（`已结束 …`）。
  - 隐藏屏断线不该自动重连刷屏——`_disconnect` 对隐藏屏可直接 `_endRecord` 收掉，别进 `_planRetry`。

### 4.3 「桌面」入口名字带屏数

- `_entryOf(r)`：当 `r.app == 'desktop:'`，`appName` 覆写为：
  `n = _records.values.where((x) => x.id == r.id && isDesktopApp(x.app)).length`；
  `n > 1 ? '桌面（$n 块屏）' : '桌面'`。

### 4.4 结束会话级联

- `_endEmbedded(key)`：若 `r.app == 'desktop:'`，先把该设备所有 `isDesktopScreen` 记录
  `_endEmbedded(x.key, quiet: true)`，再结束主屏（主屏带「正在结束/已结束」hint）。
- 子窗口关闭：macOS `DetachedWindow.windowShouldClose` 已经 `session.close(reason:"quit")`，
  到 Dart 是那条 sid 的 `ClosedEvent` → 命中隐藏屏记录 → `_endRecord` 且**不发 hint**（4.2 已保证）。
  天然「只结束它自己、不打扰别的」。

### 4.5 30s 轮询 displays 变化 + Linux 切换条

- 有 live 的 `desktop:` 记录时，起一个 `Timer.periodic(30s)`（没有时取消；`dispose` 里也取消）。
  每次对每个有 desktop 的设备 `hub.apps(id)`，和 `_desktopDisplays[id]` 比：
  - **多了屏**：hint 一次 `A 多了一块屏，再点一次「桌面」打开它`（用 `Set _hintedScreens[id]` 去重，
    **不自动开**）。
  - **少了屏**：对应 `desktop:<id>` 记录若开着，`_endEmbedded(key, quiet: true)`。
  - 更新 `_desktopDisplays[id]`。
- Linux（`!port.supportsDetach`）：
  - `List<RemoteDisplay> desktopScreens(String device)` → `_desktopDisplays[device] ?? []`。
  - `void openScreen(String device, String displayId)` → 切到那条 `desktop:<id>` 记录（当 current）。
  - `stage.dart` 在 `!port.supportsDetach` 且当前是 desktop 记录、displays > 1 时，
    画一排「屏幕 1 / 屏幕 2…」按钮，点了调 `openScreen`。

### 4.6 锁屏横幅

- 建议加一个可单测的 getter，别只写在 widget 里：
  ```dart
  class LockBanner { const LockBanner(this.text, this.action); final String text, action; }
  LockBanner? get lockBanner {
    final r = currentRecord; final sid = r?.sid;
    final rs = sid == null ? null : remote[sid];
    if (rs?.screenLocked != true) return null;
    return isDesktopApp(r!.app)
      ? const LockBanner('远程电脑已锁屏；输入系统密码解锁', '输入系统密码')
      : const LockBanner('A 已锁屏，操作不会生效。', '打开桌面');
  }
  ```
- `stage.dart`：`lockBanner != null` 时在画面上方叠一条黄条 + 按钮。
  - app 会话按钮「打开桌面」→ `openOrSwitch(r.id, 'desktop:', '桌面')`（**Task 6 就能做完、要测**）。
  - desktop 会话按钮「输入系统密码」→ 调 `requestUnlock()`——**这个方法体留给 Task 7**
    （Task 7 做对话框）。Task 6 先把按钮和 getter 做好、测 text/action 和「打开桌面」行为即可。
- **锁屏状态变了要推给隐藏屏**：主屏 `ScreenLockedEvent` 到达、`screenLocked` 变化时，
  对该设备每个 `isDesktopScreen` 的 live 记录 `port.setBanner(sid, locked ? 横幅文案 : '')`，
  让子窗口也显示横幅（macOS `DetachedWindow` 的 banner 已就绪）。

### 4.7 Task 6 要测的点（计划 Step 1）

secondary 屏被开且 detach；隐藏屏不进 entries；入口名字带屏数；结束主屏级联结束其他屏；
关某个子窗口只结束它、无 hint；少屏→静默结束；多屏→hint 一次；横幅文案 desktop vs app。

---

## 5. 构建 / 测试命令（含坑）

```bash
# 全在 worktree 根跑：/Users/bruce/git/rapp/.claude/worktrees/desktop
export PATH="$HOME/.cargo/bin:$PATH"          # cargo 不在 PATH
FLUTTER=~/development/flutter/bin/flutter       # flutter 不在 PATH

swift test                                      # core / host / session
cargo test                                      # client-core / service（rust/ 下）
(cd gui && $FLUTTER test)                        # GUI
(cd gui && $FLUTTER build macos --debug)         # 编译 runner
(cd gui && $FLUTTER analyze)
```

坑：
- `flutter build/test` 会改 `gui/pubspec.lock`，**提交前 `git checkout gui/pubspec.lock` 还原**
  （memory `flutter-path`）。
- 整个 rust 仓库本来就不是 rustfmt-clean，别顺手全量 reformat 无关文件。
- 提交 trailer 以当前 system reminder 为准（目前是 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`，
  会话里换过几次；接手人以自己环境里的 reminder 为准）。

---

## 6. Task 7 / Task 8 原文

见计划 `docs/superpowers/plans/2026-11-14-rapp-desktop-sessions.md` 的 `### Task 7` / `### Task 8`。
要点：
- Task 7：`UnlockStore(localDir)` = `local/unlock.json` 0600，`read/save/forget`；
  `MainState.unlock(device, pw, {remember, auto})` 经 `desktop:` 的 live sid 发、不落日志、
  5s 后还锁着就 hint `密码可能不对`、没锁就 hint `A 没有锁屏，没有输入密码`；
  自动输入只在某个 sid 的**第一次** `ScreenLockedEvent(true)` 触发一次。
  **动手前先问用户 Keychain vs XOR（见第 3 节第 2 条）。**
- Task 8：改 README（锁屏那行 + 会话种类加「桌面」）；全量 `swift/cargo/flutter test` + `flutter build macos`；
  **要用户配合**在真机 A 上锁屏实测（画面/横幅/打字/解锁后输入），结果记回 spec，
  若锁屏画面是黑的就调横幅文案。

---

*接手人：有疑问优先问用户，别替用户做 trade-off（尤其密码存储、知情提示这两处）。*
