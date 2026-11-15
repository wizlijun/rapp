# rapp 桌面会话 Implementation Plan

> **当前进度（2026-11-14）**：Task 1–7 已完成；Task 8 的文档和自动验证已完成，真机锁屏待用户配合。用户已选择 macOS Keychain，替代原定 XOR 文件；其他平台只手动输入。详见交接文档。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** A third session kind "桌面": B sees and drives a whole screen of A (one session per screen), sees when A is locked, and can type A's system password to unlock it.

**Architecture:** `rapp-host serve --app desktop:[<CGDirectDisplayID>]` captures a whole display with a fixed one-window table and reuses the app session's codec, pacing, yield and input path. Protocol goes to v10 with `screenLocked` (31) and `unlock` (32). The GUI treats each screen as its own `SessionRecord`; the main screen (`desktop:`) is the visible one, the other screens (`desktop:<id>`) are hidden from the list and detached into native windows on macOS.

**Tech Stack:** Swift (RappCore, rapp-host, RappSession, macOS runner), Rust (client-core, rapp-session, client-gtk, rapp-service), Flutter/Dart GUI.

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-desktop-sessions-design.md`

**Base:** branch `feat/desktop` from tag `v0.8.0` (protocol v9, exact match). This work is protocol **v10**.

## Global Constraints

- Protocol v10, exact match on both sides (`protocolVersion = 10` in Swift, `VERSION: u8 = 10` in Rust). New types: 31 `screenLocked(Bool)` host → client, payload `u8` 0/1; 32 `unlock(password: String)` client → host, payload `string` (u16 length + UTF-8), at most 1024 bytes.
- Ids: `desktop:` is the app-list / favorite entry and the **main screen** session; `desktop:<CGDirectDisplayID>` (decimal) is any other screen's session. Never put `desktop:<id>` into favorites.
- Copy (verbatim): app name `桌面`; lock banner `A 已锁屏，鼠标和键盘操作不会生效。请先解锁。`; button `输入系统密码`; dialog checkboxes `记住密码`, `连上时自动输入`; wrong password hint `密码可能不对`; new screen hint `A 多了一块屏`; access log `输入了系统密码`.
- The host never stores or logs the password. B stores it only in the local macOS Keychain (non-synchronizing); other platforms do not remember passwords. Nothing is written to `local/` or `shared/`.
- All user-facing text in Chinese.
- Flutter is `~/development/flutter/bin/flutter`; revert `gui/pubspec.lock` after tests.

## Deviations from the spec (my calls, all to keep rapp-service/hub nearly untouched)

1. The main screen's session id is `desktop:` itself (spec: `desktop:<id>` for every screen). Favorites, reconnect and the record key then need nothing new, and CGDirectDisplayID changing across reboots does not matter for the main screen.
2. The display list travels inside the `apps` array as the `desktop:` entry's `displays` field (spec: a top-level `displays`). rapp-service and rapp-hub pass `apps` through untouched, so they need no change for it.
3. No `--display` / `--no-clipboard` flags: the host reads the display from `--app desktop:[id]` and turns the clipboard on only when that display is the main one.
4. `unlock` while A is not locked: the host drops it, logs it and re-sends `screenLocked(false)`; it does not send `error` (that ends the session on every client). The GUI says `A 没有锁屏，没有输入密码`.
5. Child windows show the lock banner as a native label without a button; its text points to the main window's button.

## Review Focus

1. A locked while B is typing in an **app** session: B must see the lock hint (31 is sent to app sessions too), not silent dead input.
2. Stale ⌃⌘ flags after unlock: mouse and keys after the password must work — every posted event carries explicit flags.
3. `unlock` arriving when A is not locked: nothing is typed anywhere (test in Task 2).
4. A screen unplugged while its child window is open: the session ends, the window closes, no "ended" hint spam (Task 6).
5. Ending the main `desktop:` session ends every `desktop:<id>` session of that device; closing a child window ends only its own (Task 6).

---

### Task 1: RappCore — protocol v10, desktop ids, display list

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`, `Sources/RappCore/WorkerCLI.swift`
- Create: `Sources/RappCore/Desktop.swift`
- Test: `Tests/RappCoreTests/ProtocolTests.swift`, `Tests/RappCoreTests/DesktopTests.swift`

**Interfaces — Produces:**
- `Message.screenLocked(Bool)` (31), `Message.unlock(password: String)` (32); parser rejects flag > 1 and strings > 1024 bytes.
- `public enum DesktopTarget: Equatable { case main; case display(UInt32) }`, `public func desktopTarget(_ app: String) -> DesktopTarget?` (`desktop:` → `.main`, `desktop:123` → `.display(123)`, anything else / bad number → nil); `public func isDesktopApp(_ app: String) -> Bool`.
- `public struct DesktopDisplay: Equatable { id: UInt32; name: String; main: Bool; width: Int; height: Int; frame: CGRect }` and `public func orderedDisplays(_ d: [DesktopDisplay]) -> [DesktopDisplay]` (main first, then by `frame.minX`, then `minY`). Screen number N = index + 1.
- `public func desktopTitle(computer: String, number: Int) -> String` → `"<computer> · 屏幕 N"` (just `"屏幕 N"` for an empty name).
- `public func desktopTable(width: Double, height: Double, title: String) -> [WindowInfo]`: one item, id 1, parent 0, `.normal`, not resizable, focused, rect 0,0,w,h, titleBar 0.
- `appsJSON(_:screenRecording:accessibility:displays:)`: with a non-empty `displays` the `apps` array starts with `{"app":"desktop:","name":"桌面","displays":[{"id","name","main","width","height"}]}`.

- [x] Step 1: tests — round trip of 31 (true/false) and 32 (`"pässwörd"`); 31 with byte 2 throws; 32 with 1025 bytes throws; `protocolVersion == 10`; `desktopTarget` cases (`"desktop:"`, `"desktop:69733382"`, `"desktop:x"` → nil, `"com.apple.Safari"` → nil); `orderedDisplays` puts main first then left-to-right; `desktopTable(…)` values; `appsJSON` with/without displays.
- [x] Step 2: `swift test --filter 'ProtocolTests|DesktopTests|WorkerCLITests'` fails.
- [x] Step 3: implement; bump `protocolVersion` to 10 and fix every exhaustive switch the compiler names (rapp-host Server's "unexpected message" list gets `.screenLocked`; rapp-client ignores `.screenLocked`).
- [x] Step 4: `swift build && swift test` passes.
- [x] Step 5: commit `feat(core): protocol v10 screenLocked/unlock, desktop ids`.

### Task 2: rapp-host — input fix, desktop serve, lock watch, unlock

**Files:**
- Modify: `Sources/rapp-host/InputInjector.swift`, `Paster.swift`, `ClipboardWatcher.swift`, `WindowCapture.swift`, `Server.swift`, `main.swift`
- Create: `Sources/rapp-host/UnlockTyper.swift`
- Modify: `Sources/RappCore/WorkerCLI.swift` (worker event `unlock`), test in `WorkerCLITests`

**Interfaces:**
- Consumes Task 1.
- `InputInjector(app: NSRunningApplication?, display:, log:)` — `app == nil` is desktop mode: no activate, no covered check. Source `CGEventSource(stateID: .combinedSessionState)`; every mouse/scroll event gets `flags = []`, key events get the message's modifiers, text events `[]`.
- `Paster(app: NSRunningApplication?, …)` — nil pastes into whatever is frontmost (no activate, no frontmost wait). `ClipboardWatcher(pid: pid_t?, …)` — nil counts every copy.
- `WindowCapture.findDisplay(_ target: DesktopTarget) async throws -> (SCDisplay, DesktopDisplay, number: Int)`; `WindowCapture(display: SCDisplay, region:, fps:, density:, onFrame:, onStopped:)` with `SCContentFilter(display:excludingWindows: [])`.
- `UnlockTyper.type(_ password: String, display: CGRect)` (blocking, call off the session queue): move to display centre, left click, sleep 1.0 s, unicode chunks (flags `[]`), Return (key 36). Never logs the password.
- Worker event `{"event":"unlock"}` (`WorkerEvent.unlock`).
- Session: `desktop` branch in the hello path — no tracker/menus; `resize/move/close/focus/menuPick` ignored; clipboard only for the main display; table from `desktopTable` with `desktopTitle(computer: Host.current().localizedName ?? "", number:)`. All sessions: `screenLocked` sent at ready and whenever `screenLocked()` changes (checked in the 1 s tick). `.unlock(pw)`: passes the input gate; if not locked → log `unlock dropped: A is not locked`, send `.screenLocked(false)`; else type on a utility queue and emit `.unlock`.
- `list-apps --json` adds displays (via `NSScreen.screens` / `CGDisplayBounds`, name = `NSScreen.localizedName`).

- [x] Step 1: tests in RappCore — `WorkerEvent.unlock` encodes as `{"event":"unlock"}`; `parseHostArguments(["serve","--app","desktop:", …])` keeps the app string. (The host's AppKit/CGEvent code has no unit-test seam; it is covered by the smoke step and Task 8.)
- [x] Step 2: implement; `swift build` clean.
- [x] Step 3: manual smoke on this Mac: `rapp-host list-apps --json` shows the desktop entry; `swift test` passes.
- [x] Step 4: commit `feat(host): desktop sessions, lock state, unlock typing`.

### Task 3: Rust — client-core v10, rapp-session, client-gtk, service log

**Files:** `rust/client-core/src/protocol.rs`, `rust/client-core/src/bin/rapp-session.rs`, `rust/client-core/tests/client.rs`, `rust/client-gtk/src/ui.rs`, `rust/service/src/workers.rs`, `rust/service/src/ipc.rs`

**Interfaces:**
- `VERSION = 10`; `Incoming::ScreenLocked(bool)`; `pub fn unlock(password: &str) -> Vec<u8>` (type 32).
- rapp-session: command `{"cmd":"unlock","password":s}` (≤1024 bytes else error); event `{"event":"screen_locked","locked":b}`.
- client-gtk: shows the lock banner text in its info label while locked.
- service: worker event `unlock` → access-log line `unlock {app, sid}` (no other fields); `ipc.rs` history filter includes `unlock`.

- [x] Step 1: tests — 31 parse strict (2 → error), `unlock("ab") == [32,4,0,0,0,2,0,b'a',b'b']`; rapp-session command parse incl. too long; service transcribe test if one exists for `transfer`.
- [x] Step 2: `cargo test -p rapp-client-core -p rapp-service` (names per Cargo.toml) passes; `cargo build` for client-gtk where available (skip on macOS if it does not build there; say so).
- [x] Step 3: commit `feat(rust): protocol v10 screen_locked/unlock`.

### Task 4: Swift client side — RappSession and macOS runner

**Files:** `Sources/RappSession/Channel.swift`, `SessionEvent.swift`, `EmbeddedSession.swift`; `gui/macos/Runner/SessionPlugin.swift`, `gui/macos/Runner/DetachedWindow.swift`; tests `Tests/RappSessionTests/ChannelTests.swift`, `EmbeddedSessionTests.swift`

**Interfaces:**
- Channel command `unlock {sid, password}` → `.unlock(sid:password:)` (password ≤ 1024 bytes); `set_banner {sid, text}` → `.setBanner(sid:text:)` (`""` clears).
- `SessionEvent.screenLocked(Bool)` → payload `screen_locked {locked}`.
- SessionPlugin: `unlock` sends `.unlock(password:)`; `set_banner` sets `DetachedSession.banner`.
- `DetachedSession.banner: String?` — a label strip over the top of every window of that session.

- [x] Step 1: tests — channel parse of both commands (missing/oversize fields rejected), event payload for `screenLocked(true)`, EmbeddedSession forwards host 31.
- [x] Step 2: `swift test` passes; `flutter build macos --debug` compiles the runner.
- [x] Step 3: commit `feat(session): screen_locked event, unlock and set_banner commands`.

### Task 5: GUI plumbing — apps, events, screen-share removal, access log

**Files:** `gui/lib/hub_client.dart`, `gui/lib/embed/session_port.dart`, `gui/lib/embed/linux_session_port.dart`, `gui/lib/embed/remote_session.dart`, `gui/lib/ui/devices_tab.dart`, `gui/lib/ui/main_window.dart`, `gui/lib/access_log.dart`; tests alongside.

**Interfaces:**
- `class RemoteDisplay { String id; String name; bool main; int width; int height; }`; `HubApp.displays` (empty unless `desktop:`).
- `ScreenLockedEvent(sid, locked)`; `SessionPort.unlock(sid, password)`, `SessionPort.setBanner(sid, text)` (Linux port: `unlock` forwarded to rapp-session, `setBanner` no-op).
- `RemoteSession.screenLocked` (`bool?`, null until told).
- `bool isDesktopApp(String app)`, `bool isDesktopScreen(String app)` (`desktop:<id>`) in `session_model.dart`.
- Device row: the screen-share button and `screenShare` callback are gone; the `desktop:` app shows as `桌面` with the favourite star like any app.
- Access log: app `desktop:` → `桌面`, `desktop:<id>` → `桌面（其他屏）`; ev `unlock` → `输入了系统密码`.

- [x] Step 1: tests — hub apps parse with displays; port event parse; access log rows; devices tab has no `screen-share` key and shows `桌面`.
- [x] Step 2: `flutter test` passes.
- [x] Step 3: commit `feat(gui): desktop app entry, screen_locked plumbing; drop screen sharing button`.

### Task 6: GUI — desktop sessions on the stage and in child windows

**Files:** `gui/lib/ui/main_state.dart`, `gui/lib/ui/stage.dart`; test `gui/test/ui/main_state_test.dart`, `stage_test.dart`

**Interfaces:**
- Opening `desktop:` opens the main record; once live, `_openScreens(id)` opens a hidden record per other display (`select: false, quiet: true`), app name `桌面 · 屏幕 N`; on its first `WindowsEvent` with `port.supportsDetach` it is detached. Without detach (Linux) they are opened only from the switcher.
- Hidden records (`isDesktopScreen`) never appear in `entries` and never trigger ended hints; the `desktop:` entry's name is `桌面` or `桌面（N 块屏）`.
- `endSession('<id>/desktop:')` ends all `desktop:*` records of that device.
- While a `desktop:` record is live: every 30 s `hub.apps(id)`; a new display → hint `A 多了一块屏，再点一次「桌面」打开它` (once per display); a vanished one → its record ends quietly. Opening `desktop:` again opens any missing screen.
- `MainState.desktopScreens(String device) -> List<RemoteDisplay>`, `openScreen(String device, String displayId)` for the Linux switcher; stage shows `屏幕 1 / 屏幕 2…` buttons when `!port.supportsDetach` and the current record is a desktop one with >1 displays.
- Lock banner: current record's `screenLocked == true` → stage banner; desktop: banner text + `输入系统密码`; app session: `A 已锁屏，操作不会生效。` + `打开桌面`. Every hidden screen record gets `port.setBanner(sid, …)` on lock change.

- [x] Step 1: tests (fake hub/port from `gui/test/fakes.dart`) — secondary screen opened and detached; hidden from entries; entry name with count; ending main ends secondaries; window close of a secondary ends only it with no hint; display vanishes → ended; new display → hint once; banner text for desktop vs app.
- [x] Step 2: `flutter test` passes.
- [x] Step 3: commit `feat(gui): desktop sessions, child windows, lock banner`.

### Task 7: GUI — system password dialog, remember, auto-input

**Files:** Create `gui/lib/ui/unlock.dart` (store + dialog), `Sources/RappSession/UnlockStore.swift`, `gui/macos/Runner/UnlockPlugin.swift`; modify `main_state.dart`, `stage.dart` and runner registration; tests `gui/test/ui/unlock_test.dart`, `gui/test/ui/desktop_test.dart`, `Tests/RappSessionTests/UnlockStoreTests.swift`.

**Interfaces:**
- `UnlockStore` provides async `read/save/forget` via the `rapp/unlock` platform channel. macOS stores the password and `auto` together in a local Keychain item, keyed by device ID (`com.rapp.rapp.system-password`, `kSecAttrSynchronizable = false`). Other platforms expose manual input only. This replaces the original XOR/file design by the user’s explicit choice on 2026-11-14.
- `MainState.unlock(String device, String password, {required bool remember, required bool auto})`: sends only via that device’s `desktop:` record’s live sid, logs nothing, schedules a 5 s check → still locked → hint `密码可能不对`. Not locked when asked → hint `A 没有锁屏，没有输入密码`.
- Auto-input: only when the first `ScreenLockedEvent` of a fresh main desktop connection is `true`, with a stored password and `auto`. An initial `false` consumes this opportunity too. A later lock never auto-unlocks. Pending Keychain reads are bound to the same connection and lock generation; disconnect/end/unlock cancels them.

- [x] Step 1: tests — native Keychain queries, bridge round trip and unsupported platforms; auto-input only on the first locked state, async cancellation, 5 s wrong-password hint; dialog input, choices, forget and cancellation. Synthetic local Keychain save/read/update/forget smoke also passed.
- [x] Step 2: `flutter test` passes.
- [x] Step 3: commit `feat(gui): system password dialog with remember and auto input`.

### Task 8: README, full build, real-machine test

- [x] README: the "A 不能锁屏" line becomes `锁屏后可以在「桌面」里输入系统密码解锁；睡眠、关机、开机后的登录窗口仍然不行。` and the session kinds list gains 桌面.
- [x] `swift test`, `cargo test`, `flutter test` all pass; `flutter build macos` builds.
- [ ] Real A/B lock test (user explicitly deferred on 2026-11-14; code/build complete): run the lock test on a real A (spec §6 step 1): lock A, open 桌面, check picture, banner, password typing, input after unlock. Record the result in the spec; adjust banner copy if the locked picture is black.
- [x] Commit `docs: desktop sessions in README`.


### Follow-up fixes and validation notes

- `b05f017`: host rechecks lock state before waking, before each password chunk, and before Return. Four pure sequence tests cover unlock during the wait and during typing.
- Desktop stream choices/pinning now propagate to sibling screens and newly opened screens; secondary display IDs cannot be favorited.
- GUI desktop coverage is in `gui/test/ui/desktop_test.dart` (state + widget tests), alongside the existing `main_state_test.dart` and `stage_test.dart` regression suites.
- Run Rust tests with `TERM=xterm-256color`; with `TERM=dumb`, four existing tmux real-client tests cannot attach. The 37-test live suite and then the full workspace pass with the correct terminal setting.
- No branch push or installation was performed. Linux-native GTK rendering and real A/B lock-screen behavior are not validated on this Mac.
