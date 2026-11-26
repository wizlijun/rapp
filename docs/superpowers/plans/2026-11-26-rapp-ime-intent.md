# 输入法跟着意图走 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 写作版里打字 = 本机中文，画面上直接打字 = 远端英文，串流的终端默认不因字母弹写作版。

**Architecture:** 远端那一半在会话层做：Swift `EmbeddedSession`（macOS + iOS 共用）和 Linux 客户端 `linux_session_port.dart` 在发出按下的键之前看 A 报告的输入源，不是英文就先发 `select_input("")`；Dart 用新的通道方法 `auto_english` 控制暂停。本机那一半由 Dart 的 `ImeIntent` 管：它只看 `composer.editorFocused` 的边沿，通过 `LocalIme` 端口切本机输入法（macOS 原生 TIS、iOS Rime `ascii_mode`、Linux fcitx5/ibus）。Linux 被控端的 `select` 改成等切换完成。

**Tech Stack:** Flutter/Dart（gui/），Swift（Sources/RappSession、gui/macos/Runner、rapp_rime 包），Rust（rust/host-linux）。

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-ime-intent-design.md`（用户 2026-11-26 批准）

## Global Constraints

- 协议号不变，线上不加新消息。`auto_english` 只是 Dart ↔ 原生 / Linux port 的本地通道方法。
- 不改版本号（`gui/pubspec.yaml` version、`rust/Cargo.toml` workspace version、`Cargo.lock`），不打 tag，不 push。
- 远端自动切英文只在这几种情况都满足时触发：是**按下**的键；不是单独的修饰键（mac 虚拟键码 54–63）；修饰位里没有 Command（`1 << 20`）；A 报告过输入源且 `ascii == false`；本会话没暂停。发一次 `select_input("")` 后先把本地状态记成英文。A 是英文时不发任何额外消息。
- 本机切换只在边沿：进入写作版一次，离开一次，rApp 回前台且光标在写作版里一次。之后不抢用户的手动切换。
- 本机切换失败不提示用户，只用 `debugPrint('ime: …')` 写一行。`ImeIntent` 绝不往外抛异常；每次本机调用最多等 300 ms。
- 用户看得到的文字逐字照抄：设置开关「打开写作版时切到中文，回到画面时切回英文」（默认开）；串流菜单说明「直接打字不会自动切英文，打开写作版后恢复」。
- 「英文」= 系统的 ASCII 键盘布局（macOS `TISCopyCurrentASCIICapableKeyboardLayoutInputSource`），不强制 ABC。是否 ASCII 的判定和被控端一致：输入源类型是 `kTISTypeKeyboardLayout`（`Sources/rapp-host/InputSourceWatcher.swift:29`）。
- Linux 被控端：切换完成或最多等 300 ms，再等 50 ms，然后才处理这个客户端的下一条输入。队列满时最多排队等 300 ms，不再直接报 "input source helper busy"。
- Flutter 是 `~/development/flutter/bin/flutter`，不在 PATH 上。跑完测试 `git checkout gui/pubspec.lock`。`test/embed/linux_detach_test.dart` 里那 2 个失败是已知的老问题。
- Swift 测试：在仓库根目录跑 `swift test`。Rust：`rust/host-linux` 的 Linux 专属模块在这台 Mac 上不编译，能在 Mac 上测的逻辑放进不带 cfg 的模块（照 `pause`、`pacing` 的先例）。

## Review Focus

1. **焦点在两个写作版之间换手**（两个会话之间，或冻结舞台重连时 `keepFocus` 把焦点交给新会话）：最后本机是中文，中间不来回切。`ImeIntent` 把同一轮里的变化合并成一次（Task 5 测试 `swap between two editors switches once`）。
2. **写作版带着焦点被销毁**（`ComposerModel.detach` 把 `editorFocused` 设成 false，但不会触发 onFocus(false)）：本机照样切回英文（Task 5 测试 `detach while focused leaves`）。
3. **本机调用卡住或没有插件**（Linux 没装 fcitx/ibus、旧原生构建、Process 卡住）：按字母开写作版时被截下的字母最多晚 300 ms 重放，不丢，不抛异常（Task 5 测试 `hung toChinese still settles`）。
4. **按住不放 / 自动重复**：远端切英文只发一次；松开不触发；线上 `select_input` 排在这个键前面（Task 2 和 Task 3 测试 `repeat sends one select`）。
5. **「切回」之后**：在 A 上直接打字不再被切英文；打开写作版后恢复；重连后的新会话一开始就不暂停（Task 3 测试 `pause until editor focus`）。

---

### Task 1: Linux 被控端同步切换输入源

**Files:**
- Create: `rust/host-linux/src/select_wait.rs`（不带 cfg，Mac 上也能跑测试）
- Modify: `rust/host-linux/src/lib.rs`（照 `pause` 的写法加 `mod select_wait;`，带 `#[cfg_attr(not(target_os = "linux"), allow(dead_code))]`）
- Modify: `rust/host-linux/src/input_source.rs:87-136`
- Test: `rust/host-linux/src/select_wait.rs` 里的 `#[cfg(test)] mod tests`

**Interfaces:**
- Produces（crate 内部）：
  - `pub(crate) fn send_queued<T>(tx: &mpsc::SyncSender<T>, value: T, max: Duration) -> anyhow::Result<()>`：队列满时每 10 ms 重试一次 `try_send`，到 `max` 还满就返回 `Err("input source helper busy")`；接收端断开立刻返回 Err。
  - `pub(crate) fn wait_done(done: &mpsc::Receiver<()>, max: Duration, settle: Duration)`：最多等 `max` 收到完成信号（断开也算完成），然后 `sleep(settle)`。
- `InputSources::select(&self, id: String) -> Result<()>` 签名不变，`server.rs:714` 不用改。

- [ ] **Step 1: 写失败的测试**（在 `select_wait.rs`）

```rust
#[test]
fn waits_for_the_switch_then_settles() {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || { std::thread::sleep(Duration::from_millis(100)); let _ = tx.send(()); });
    let t = Instant::now();
    wait_done(&rx, Duration::from_millis(300), Duration::from_millis(50));
    let e = t.elapsed();
    assert!(e >= Duration::from_millis(150) && e < Duration::from_millis(300), "{e:?}");
}
#[test]
fn a_hung_switch_costs_at_most_max_plus_settle() {
    let (_tx, rx) = mpsc::channel::<()>();
    let t = Instant::now();
    wait_done(&rx, Duration::from_millis(300), Duration::from_millis(50));
    let e = t.elapsed();
    assert!(e >= Duration::from_millis(350) && e < Duration::from_millis(500), "{e:?}");
}
#[test]
fn a_full_queue_waits_instead_of_failing() {
    let (tx, rx) = mpsc::sync_channel::<u8>(1);
    tx.try_send(0).unwrap();
    std::thread::spawn(move || { std::thread::sleep(Duration::from_millis(50)); let _ = rx.recv(); std::thread::sleep(Duration::from_secs(1)); });
    assert!(send_queued(&tx, 1, Duration::from_millis(300)).is_ok());
}
#[test]
fn a_queue_full_past_max_is_busy() {
    let (tx, _rx) = mpsc::sync_channel::<u8>(1);
    tx.try_send(0).unwrap();
    let err = send_queued(&tx, 1, Duration::from_millis(30)).unwrap_err();
    assert!(err.to_string().contains("busy"));
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd rust && cargo test -p rapp-host-linux select_wait`
Expected: 编译失败，`wait_done` / `send_queued` 没定义

- [ ] **Step 3: 实现 `select_wait.rs`，再改 `input_source.rs`**

`InputSources.commands` 改成 `mpsc::SyncSender<(String, mpsc::Sender<()>)>`（容量还是 8）。后台线程做完 `select(&id).and_then(|_| current())` 并发出事件后，用 `done.send(())` 回信。`select()` 变成：建一对 `mpsc::channel()`，`send_queued(&self.commands, (id, done_tx), 300ms)?`，然后 `wait_done(&done_rx, 300ms, 50ms)`，返回 `Ok(())`。切换本身的错误照旧走 `events` 报出去。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd rust && cargo test -p rapp-host-linux select_wait && cargo clippy -p rapp-host-linux -- -D warnings`
Expected: 4 个测试 PASS，clippy 干净

- [ ] **Step 5: Linux 编译检查**

Run: `rustup target list --installed`。装了 Linux target 就跑 `cd rust && cargo clippy -p rapp-host-linux --target <那个 target> -- -D warnings`。没装的话，在报告里写明「input_source.rs 没在 Linux 上编译过」，Task 6 会在 `tasks/todo.md` 里留给 Linux 机器去核对。

- [ ] **Step 6: Commit**

```bash
git add rust/host-linux/src/select_wait.rs rust/host-linux/src/lib.rs rust/host-linux/src/input_source.rs
git commit -m "fix(host-linux): select_input waits for the switch (≤300 ms + 50 ms) and queues instead of failing busy"
```

---

### Task 2: Swift 会话层自动切远端英文，加暂停

**Files:**
- Modify: `Sources/RappSession/EmbeddedSession.swift`（`send` 在第 103 行；收到的 `.inputSource` 在第 309 行左右）
- Modify: `Sources/RappSession/Channel.swift`（`known` 方法集合在第 106 行左右；解析分支在 `case "select_input"` 旁边；`ChannelCommand` 枚举）
- Modify: `gui/macos/Runner/SessionPlugin.swift:265`（macOS 和 iOS 共用这一份文件）
- Test: `Tests/RappSessionTests/EmbeddedSessionTests.swift`、`Tests/RappSessionTests/ChannelTests.swift`

**Interfaces:**
- Produces:
  - `EmbeddedSession.setAutoEnglish(_ on: Bool)`（public，在会话队列上执行；默认 on）
  - `ChannelCommand.autoEnglish(sid: Int64, on: Bool)`，方法名 `"auto_english"`，参数 `{sid, on}`
  - `SessionPlugin`：`case let .autoEnglish(sid, on): live[sid]?.session.setAutoEnglish(on)`

- [ ] **Step 1: 写失败的测试**（用 `FakeLink` 看发出去的消息顺序）

`EmbeddedSessionTests`：
- `testKeyDownSwitchesRemoteToEnglishFirst`：先喂 `.inputSource(id: "pinyin", name: "拼音", ascii: false)`，再 `send(.key(keyCode: 0, modifiers: 0, down: true))` → link 收到 `[.selectInput(id: ""), .key(0, 0, true)]`。
- `testRepeatSendsOneSelect`：同上，接着连发两个按下的键 → 一共只有一个 `.selectInput`。
- `testAsciiHostGetsNoSelect`：报告 `ascii: true` → 只发键。
- `testNoReportNoSelect`：从没报告过 → 只发键。
- `testKeyUpModifierOnlyAndCommandSkip`：报告非英文后，`down: false`、keyCode 56（Shift）、`modifiers: 1 << 20` 都不触发 select。
- `testPausedSkipsAndResumes`：`setAutoEnglish(false)` → 不发 select；`setAutoEnglish(true)` → 下一个键先 select。
- `testFreshReportReArms`：发过 select 之后又收到 `ascii: false` → 下一个键再发一次 select。

`ChannelTests`：`testParsesAutoEnglish`：`auto_english {sid: 7, on: false}` → `.autoEnglish(sid: 7, on: false)`。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter 'EmbeddedSessionTests|ChannelTests'`
Expected: 编译失败，`setAutoEnglish` / `.autoEnglish` 没定义

- [ ] **Step 3: 实现**

`EmbeddedSession` 加两个状态：`remoteAscii: Bool?`（收到 `.inputSource` 时写入，和 `onEvent` 在同一个队列上）和 `autoEnglish = true`。在 `send` 的 `run` 闭包里、`link.send(m)` 之前：如果 `m` 是 `.key(code, mods, true)`，`remoteAscii == false`，`autoEnglish` 为真，`!(54...63).contains(code)`，`mods & (1 << 20) == 0`，就先 `link.send(.selectInput(id: ""))`，再把 `remoteAscii` 设成 `true`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RappSession Tests/RappSessionTests gui/macos/Runner/SessionPlugin.swift
git commit -m "feat(session): a key-down switches A to English first unless paused (auto_english)"
```

---

### Task 3: Dart 暂停开关、串流菜单说明、Linux 客户端自动切英文

**Files:**
- Modify: `gui/lib/embed/session_port.dart`（`selectInput` 旁边，第 674 行）
- Modify: `gui/lib/embed/remote_session.dart`（构造参数在第 39 行左右；`selectInput` 在第 195 行）
- Modify: `gui/lib/embed/stream_menu.dart:574-578`
- Modify: `gui/lib/ui/main_state.dart`（`onSelectInput` 的接线在第 2477 行；`composerFocusChanged` 在第 788 行）
- Modify: `gui/lib/embed/linux_session_port.dart`（`_remoteKey` 在第 377 行发键；`'key'`/`'key_event'` 分支在第 664 行；命令 switch；`class _Session` 在第 808 行；事件循环在第 1271 行左右看到 `InputSourceEvent`）
- Test: `gui/test/embed/remote_session_test.dart`、`gui/test/embed/stream_menu_test.dart`、Linux port 现有的测试文件（`git grep -l LinuxSessionPort gui/test` 找到它）、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 2 的通道方法 `auto_english {sid, on}`
- Produces:
  - `SessionPort.autoEnglish(Object sid, bool on)` → `_send('auto_english', {'sid': sid, 'on': on})`
  - `RemoteSession.autoEnglish`（bool，默认 true）、`RemoteSession.setAutoEnglish(bool on)`（值没变时什么都不做；变了就调构造参数 `onAutoEnglish` 并 notify）
  - `MainState.composerFocusChanged` 在 `focused == true` 时调 `session.setAutoEnglish(true)`

- [ ] **Step 1: 写失败的测试**

- remote_session：`setAutoEnglish(false)` 调一次 `onAutoEnglish(false)`；再调一次同样的值不会再调。
- stream_menu：点「切回 拼音」→ `autoEnglish == false`，并且照旧发 `selectInput(back.id)`；暂停时「远端输入法」组里有一行不可点的「直接打字不会自动切英文，打开写作版后恢复」；没暂停时没有这一行。
- main_state：`pause until editor focus` —— 先 `setAutoEnglish(false)`，再 `composerFocusChanged(s, true)` → 假 port 收到 `autoEnglish(sid, true)`。
- Linux port（经过假的 worker 连接，看 `s.send` 发出去的顺序）：
  - 收到非英文 `input_source` 后，第一个按下的字母键先发 `{'cmd':'select_input','id':''}` 再发 key；
  - `repeat sends one select`：重复的按下事件只发一次 select；
  - A 是英文时不发 select；单独的 Shift、Ctrl 组合（远端 Command，`1 << 20`）、松开都不发；
  - 走 `'key'` 命令的按键区键（`down` 没给或者为 true）同样先发 select；
  - `auto_english {on:false}` 之后不发，`{on:true}` 之后恢复。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/remote_session_test.dart test/embed/stream_menu_test.dart test/ui/main_state_test.dart <linux port 的测试文件>`
Expected: FAIL（方法和文字都还没有）

- [ ] **Step 3: 实现**

- `_Session` 加 `bool? remoteAscii` 和 `bool autoEnglish = true`。事件循环看到 `InputSourceEvent` 时写 `remoteAscii`。
- 加一个辅助方法 `void _englishFirst(_Session s, int code, int mods)`，规则照 Global Constraints。在第 377 行（`down` 为真时）和 `'key'`/`'key_event'` 分支（`args['down'] != false` 时）发键之前调用它。
- 命令 switch 加 `case 'auto_english': s.autoEnglish = args['on'] as bool;`。
- main_state 把 `onAutoEnglish: (on) { if (_liveSid(s.sid)) portOf(s.sid)!.autoEnglish(s.sid, on); }` 接到 RemoteSession 上，写法和 `onSelectInput` 一样。
- 菜单「切回」的 onTap：先 `_s.setAutoEnglish(false)`，再 `_s.selectInput(back.id)`。

- [ ] **Step 4: 跑测试确认通过，再跑 analyze**

Run: 同 Step 2，然后 `~/development/flutter/bin/flutter analyze`，最后 `git checkout pubspec.lock`
Expected: PASS；No issues found

- [ ] **Step 5: Commit**

```bash
git add gui/lib/embed gui/lib/ui/main_state.dart gui/test
git commit -m "feat(gui): 切回 pauses auto-English until the writing panel opens; Linux client switches A to English before keys"
```

---

### Task 4: 本机切换的原生能力（macOS TIS、iOS Rime）

**Files:**
- Modify: `gui/macos/Runner/SecureInputPlugin.swift`：在同一个文件里加 `final class LocalImePlugin`，由 `SecureInputPlugin.register` 一起注册。这样不用改 Xcode 工程。
- Modify: `gui/macos/Runner/SessionPlugin.swift`：`.composeReplay` 分支（第 370 行）和 iOS 的重放路径（第 766 行附近）改成在下一轮 runloop 执行（`DispatchQueue.main.async`），已经是异步的就不动。
- Modify: `gui/packages/rapp_rime/ios/rapp_rime/Sources/rapp_rime/RimeEngine.swift:170`、`RappRimePlugin.swift`（方法 switch）
- Modify: `gui/packages/rapp_rime/lib/src/rapp_rime.dart`（`RimeLink` 接口和 `RappRime`）
- Test: `gui/packages/rapp_rime/test/`（Dart 通道测试）

**Interfaces:**
- Produces:
  - 通道 `rapp/local-ime`（macOS）：
    - `toChinese {preferred: String?}` → `String?`，返回实际选中的 id，选不到返回 null。
    - `toEnglish` → null：选中 ASCII 键盘布局；本来就是 ASCII 就不动。
    - `current` → `{id: String, ascii: bool}`。
    - `SecureInputPlugin` 处于 engaged 状态时三个方法都什么也不做（`current` 返回 null）。
  - `RimeLink.setAscii(bool on)` → `_invoke<void>('ascii', {'on': on})`；原生 `RimeEngine.setAscii(_:)` 走 `api.set_option!(session, "ascii_mode", on ? 1 : 0)`，`ready` 为假时什么也不做。

- [ ] **Step 1: 写失败的测试**（rapp_rime 的 Dart 测试，模拟通道）：`setAscii(false)` 在 iOS 平台下发 `ascii {on: false}`；在其他平台什么也不发。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui/packages/rapp_rime && ~/development/flutter/bin/flutter test`
Expected: FAIL，`setAscii` 没定义

- [ ] **Step 3: 实现**

- Rime：照上面的接口实现。
- `LocalImePlugin.toChinese`：
  1. 如果给了 `preferred`，用 `TISCreateInputSourceList([kTISPropertyInputSourceID: preferred], false)` 找它，并且要求它已启用、可选（`kTISPropertyInputSourceIsSelectCapable`）。
  2. 找不到的话，在已启用、可选的输入源里取第一个满足这两条的：类型不是 `kTISTypeKeyboardLayout`；`kTISPropertyInputSourceLanguages` 里有以 `zh` 开头的语言。
  3. 当前输入源已经是选中的那个就不调 `TISSelectInputSource`。
- `current`：id 取 `kTISPropertyInputSourceID`；ascii = 类型是 `kTISTypeKeyboardLayout`。读属性的写法照 `SecureInputPlugin.sourceID(_:)`。

- [ ] **Step 4: 跑测试，并编译两个平台**

Run: `cd gui/packages/rapp_rime && ~/development/flutter/bin/flutter test`，然后 `cd gui && ~/development/flutter/bin/flutter build macos --debug`，再跑 `scripts/build-ios.sh sim`（缺 Rime 资源时先跑 `gui/packages/rapp_rime/scripts/fetch.sh`），最后 `git checkout gui/pubspec.lock`
Expected: 测试 PASS；两个平台都编译成功

- [ ] **Step 5: Commit**

```bash
git add gui/macos/Runner gui/packages/rapp_rime
git commit -m "feat(native): local input source switching (macOS TIS, iOS Rime ascii_mode); compose replay on the next runloop"
```

---

### Task 5: ImeIntent：写作版 = 本机中文

**Files:**
- Create: `gui/lib/embed/local_ime.dart`：`LocalIme` 接口，以及 `ChannelLocalIme`、`LinuxLocalIme`、`RimeLocalIme`、`NoLocalIme` 四个实现。
- Create: `gui/lib/ui/ime_intent.dart`：`ImeIntent` 类。
- Modify: `gui/lib/ui/main_state.dart`
  - `composerFocusChanged`（第 788 行）。
  - 构造函数加可选的 `LocalIme? localIme`。
  - 加 `AppLifecycleListener(onResume: imeIntent.appResumed)`，并在 dispose 时释放它。
  - 加 `Future<void> get imeSettled`。
  - 加 `setImeIntent(bool)`，写法照 `setRimeEnabled`（第 3925 行）。
- Modify: `gui/lib/embed/composer_model.dart:437-441`：`detach` 时如果 `editorFocused` 原来为真，就调新加的 `void Function()? onBlur`。
- Modify: `gui/lib/embed/composer_panel.dart:205-224`：两条重放路径都先 `await widget.state.imeSettled`，再 `composeReplay`。
- Modify: `gui/lib/ui/prefs.dart`：`imeIntent`（json 键 `ime_intent`，默认 true）和 `chineseIme`（json 键 `chinese_ime`，String?，可空）。写法照 `rime_enabled`（第 40、105、159、194、246 行）。
- Modify: `gui/lib/ui/side_panel.dart`：在「记下写作面板发出去的话」那个开关后面加 `toggle(const Key('ime-intent-switch'), '打开写作版时切到中文，回到画面时切回英文', state.prefs.imeIntent, state.setImeIntent)`，各平台都显示。
- Modify: `gui/lib/ui/secure_text_field.dart`：`SecureInput` 记住 begin/end 的层数，加 `static bool get active`。
- Modify: iOS 入口（`gui/lib/main_ios.dart` 里构造 MainState 的地方）：传 `RimeLocalIme(rime)`。
- Test: `gui/test/ui/ime_intent_test.dart`（新建）、`gui/test/embed/local_ime_test.dart`（新建）、`gui/test/ui/prefs_test.dart`、`gui/test/ui/side_panel_test.dart`

**Interfaces:**
- Consumes: Task 4 的通道 `rapp/local-ime`，以及 `RimeLink.setAscii`
- Produces:

```dart
abstract interface class LocalIme {
  Future<String?> toChinese(String? preferredId); // 实际选中的 id；null = 没切
  Future<void> toEnglish();
  Future<({String id, bool ascii})?> current();
}
LocalIme localImeForPlatform();  // macOS → ChannelLocalIme，Linux → LinuxLocalIme，其余 → NoLocalIme（iOS 由 main_ios 传 RimeLocalIme）

class ImeIntent {
  ImeIntent(this.ime, {required bool Function() enabled, required bool Function() secure,
      required String? Function() lastId, required void Function(String id) saveId,
      Duration callTimeout = const Duration(milliseconds: 300)});
  void focus(Object sid, bool on);  // 某个会话的写作版拿到 / 失去光标
  void appResumed();
  Future<void> get settled;         // 排着的和正在进行的切换都结束（每次调用最多 callTimeout）
}
```

`ImeIntent` 的行为：
- 记一组「写作版有光标」的 sid。每次变化都排一个 `Timer(Duration.zero)` 去结算；同一轮里的变化只结算一次。
- 结算时，只有「组非空」和上次结算的结果不一样才动作：
  - 组从空变成非空：`toChinese(lastId())`。
  - 组从非空变成空：先 `current()`，不是 ASCII 就 `saveId(id)`；然后 `toEnglish()`。
  - `enabled()` 为假或者 `secure()` 为真时只记下结果，不调本机。
- `appResumed`：组非空、开关开着、没在密码框里，就再 `toChinese` 一次。
- 所有调用排成一条串行链，每次都 `.timeout(callTimeout)`，任何错误都 catch 掉，只写 `debugPrint('ime: …')`。

`LinuxLocalIme(run)`：`run` 是可注入的 `Future<ProcessResult> Function(String exe, List<String> args)`。
- 判断 fcitx5：`fcitx5-remote` 退出码为 0，输出 `1` 或 `2`。
  - `current` 返回 `{id: 'fcitx5', ascii: 输出 != '2'}`。
  - `toChinese` 跑 `fcitx5-remote -o`，返回 `'fcitx5'`。
  - `toEnglish` 跑 `fcitx5-remote -c`。
- 不是 fcitx5，就看 `ibus engine` 是否退出码为 0：
  - `current` 返回 `{id: 'ibus:<engine>', ascii: engine 以 'xkb:' 开头}`。
  - `toChinese(preferred)`：`preferred` 以 `ibus:` 开头才跑 `ibus engine <去掉前缀>`，否则返回 null，什么也不跑。
  - `toEnglish` 跑 `ibus engine xkb:us::eng`。
- 两个都没有，或者 `ProcessException`：返回 null / 什么也不做。

`RimeLocalIme`：
- `toChinese` 调 `setAscii(false)`，返回 `'rime'`。
- `toEnglish` 什么也不做。
- `current` 返回 null。

- [ ] **Step 1: 写失败的测试**（`ime_intent_test.dart`，用记录调用的假 `LocalIme`，加 `fakeAsync`）

- `enter switches to Chinese with the saved id`：`lastId` 是 `'im.rime'`，`focus(1, true)` → `toChinese('im.rime')`。
- `leave saves a non-ASCII source then goes English`：`current` 返回 `('sogou', ascii: false)`，`focus(1, false)` → 先 `saveId('sogou')`，再 `toEnglish()`；`current` 是 ASCII 时不调 `saveId`。
- `only edges`：`focus(1, true)` 调两次 → 只有一次 `toChinese`。
- `swap between two editors switches once`：同一轮里 `focus(1, false)` 加 `focus(2, true)` → 本机一次都不调；只有 `focus(2, true)` → 一次 `toChinese`。
- `switch off does nothing`、`password field does nothing`。
- `app resumed with caret inside switches again`；光标不在写作版里时 resumed 什么也不做。
- `hung toChinese still settles`：`toChinese` 永远不返回 → `settled` 在 300 ms 内完成；没有未捕获的异常。
- `detach while focused leaves`：放在 composer_model 测试里，`detach` 一个有焦点的编辑区 → `onBlur` 被调一次。

`local_ime_test.dart`：照上面 `LinuxLocalIme` 的规则，用假的 `run` 测 fcitx5、ibus、两个都没有、`ProcessException` 这几种情况。

prefs：`ime_intent` / `chinese_ime` 能存能读回来，缺省时 `imeIntent` 为 true。side_panel：有 `ime-intent-switch`，点一下就把 `prefs.imeIntent` 翻过来。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/ime_intent_test.dart test/embed/local_ime_test.dart test/ui/prefs_test.dart test/ui/side_panel_test.dart test/embed/composer_model_test.dart`
Expected: FAIL（文件和方法都还没有）

- [ ] **Step 3: 实现，并接进 main_state**

- `composerFocusChanged` 调 `imeIntent.focus(session.sid, focused)`。
- 新建 RemoteSession 的地方（第 2454 行）设 `rs.composer.onBlur = () => imeIntent.focus(rs.sid, false)`。
- `saveId` 写 `prefs.chineseIme` 并保存。
- `enabled` 读 `prefs.imeIntent`；`secure` 读 `SecureInput.active`。
- MainState 的测试构造都传 `NoLocalIme` 或假实现，不让测试碰真通道。

- [ ] **Step 4: 跑测试确认通过，再跑全量和 analyze**

Run: 同 Step 2，然后 `~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`，最后 `git checkout pubspec.lock`
Expected: 新测试 PASS；全量只剩已知的 2 个 linux_detach_test 失败；analyze 干净

- [ ] **Step 5: Commit**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): writing panel switches the local IME to Chinese, back to English on the picture"
```

---

### Task 6: 终端默认不因字母开写作版；文档和实机检查

**Files:**
- Modify: `gui/assets/app_profiles.json:4-7`：终端、iTerm2、Ghostty、Warp 四项加 `"typeToCompose": false`。
- Test: `gui/test/embed/builtin_profiles_test.dart`
- Modify: `docs/superpowers/specs/2026-11-15-rapp-type-to-compose-design.md` §2.1：加一行注，说明从 2026-11-26 起由 `app_profiles.json` 落实，见 ime-intent 规格 §3.3。
- Modify: `docs/superpowers/specs/2026-11-14-rapp-terminal-gui-design.md` 的 K5，以及 `docs/superpowers/specs/2026-11-14-rapp-terminal-gui-review.md` 的 R9：注明被 `2026-11-26-rapp-ime-intent-design.md` §3.4 取代（R9 作废，K5 维持现状、不提示）。
- Modify: `tasks/todo.md`：加一节「输入法跟着意图走（feat/ime-intent，2026-11-26）实机检查」。

**Interfaces:** 无

- [ ] **Step 1: 写失败的测试**：`builtin_profiles_test.dart` 断言四个终端的 `typeToCompose == false`，其他内置 app 不变。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/builtin_profiles_test.dart`
Expected: FAIL

- [ ] **Step 3: 改 JSON；查历史**

Run: `git log -S typeToCompose --oneline -- gui/lib/embed/app_profile.dart gui/lib/ui/prefs.dart`。看有没有哪个旧版本把整份配置（包括默认值）写进过用户文件。
- 有：在报告里写清楚是哪个提交、哪些版本，并在 todo 里加一条「老用户的终端配置可能存了 `typeToCompose: true`」。
- 没有：在报告里写「历史里只存改过的字段」。

- [ ] **Step 4: 写文档和 todo**

todo 里逐条写这些检查：
1. 本机停在 ABC 时开写作版，直接打出中文。
2. 按字母开写作版，第一个字母进拼音（`nihao` → 你好）。
3. 鼠须管、搜狗下同上；切不过去时第一个字母照现状上屏，不丢字。
4. 回到画面后本机是英文；在写作版里自己按 ⌃空格 切成英文后不会被切回中文。
5. A 在拼音时直接打 `ls`，得到 `ls`；打 `y` 回答 Claude Code，不弹写作版。
6. 点「切回 拼音」后在 A 上直接打中文；打开写作版后恢复自动切英文。
7. Linux 被控端：开头几个字不丢（并在 Linux 机器上编译、跑 clippy `host-linux`）。
8. iOS「内」模式下开写作版回到「中」。
9. Linux 客户端（fcitx5 / ibus）进出写作版能切换。
10. 设置开关关掉后回到老行为。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/builtin_profiles_test.dart`，然后 `git checkout pubspec.lock`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add gui/assets/app_profiles.json gui/test/embed/builtin_profiles_test.dart docs/superpowers/specs tasks/todo.md
git commit -m "feat(gui): streamed terminals default to no type-to-compose; spec notes and real-machine checks"
```
