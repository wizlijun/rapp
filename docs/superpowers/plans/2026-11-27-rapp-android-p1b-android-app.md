# 安卓平板 P1b：安卓工程 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 安卓平板上装得上的 rApp 调试包，能接入、在全景里看到设备，进桌面会话、单应用会话和文本终端，触摸、外接键盘、鼠标、文字剪贴板、前后台、返回键、常亮、全屏和折叠都和 iPad 一样，并在模拟器 34、36 上验收；最后给用户一份在荣耀平板上做的实机清单。

**Architecture:** 一个 `.so`（`rust/android-ffi`，库名 `rapp_android`）里放进程内 hub（`rapp-hub-ffi` 的四个函数）和会话库（`rapp_client_core::session` 的五个函数）。Dart 侧 hub 走现有的 `FfiHubTransport`（加一个库名参数），会话走 P1a 的 `WorkerSessionPort`，通路换成 `FfiSessionLinks`、宿主换成 `AndroidSessionHost`。外壳照 iPad：`main_ios.dart` 的共用部分抽进 `main_mobile.dart`，`rapp/android` 通道和 `rapp/ios` 对齐成一个 `MobileChannel` 接口；排版不为安卓写，写死 iOS 的判断按 §6.5 逐处改成能力位或 `touchPlatform`。

**Tech Stack:** Rust（`cargo ndk`、NDK 28.2.13676358）、Flutter/Dart（`dart:ffi`、`NativeCallable`、`fake_async`）、Kotlin（Flutter 的 Android 模板）、Gradle（openjdk@21）。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`（§6.2–§6.6、§7–§10、§12、§14.2 第 2–4 条和验收、§14.6）；`docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md`；前置计划 `docs/superpowers/plans/2026-11-27-rapp-android-p1a-shared-refactor.md`。

**前置条件：** P1a 的两个分支（`fix/hub-long-reply`、`refactor/session-port`）都已合进本机 main。`refactor/session-port` 因为等 Linux 回归没合的话，这份计划不开工。

## Global Constraints

- 分支 `feat/android-p1`，worktree `.worktrees/android-p1`，从合了 P1a 的本机 main 开。
- 范围：§14.2 第 2–4 条。**不做**：语音（§11）、更新/发版/签名（§13）、P2 的图片剪贴板、传文件（选、收、发布到下载、打开、分享）、解锁口令进 Keystore、日志导出、端口共享检查、内存警告事件。`rapp/android` 只实现 Task 7 列的方法。
- 清单权限只有 `INTERNET`、`ACCESS_NETWORK_STATE`。`RECORD_AUDIO`、`REQUEST_INSTALL_PACKAGES` 和识别服务的 `<queries>` 跟着 P2、P3 加。不要存储、通知权限，不要前台服务。
- `minSdk 34`，`compileSdk`、`targetSdk` 36。应用 ID `com.rapphub.rapp`。只出 `arm64-v8a`。
- `android:allowBackup="false"`，`dataExtractionRules` 排除全部数据；网络安全配置只对 `localhost`、`127.0.0.1` 放行明文。
- Gradle 每条命令都单独带 `JAVA_HOME`：
  ```bash
  JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ~/development/flutter/bin/flutter build apk --debug --target-platform android-arm64
  ```
- `.so` 的构建：
  ```bash
  cd rust && ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358 ~/.cargo/bin/cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi
  ```
  产物拷到 `gui/android/app/src/main/jniLibs/arm64-v8a/`（不进 git）。
- 模拟器：AVD `rapp-p0-34`、`rapp-p0-36`。启动用 `$ANDROID_HOME/emulator/emulator -avd rapp-p0-34 -no-snapshot -no-boot-anim`。adb 在 `~/Library/Android/sdk/platform-tools/adb`。装包、启动：`adb install -r gui/build/app/outputs/flutter-apk/app-debug.apk; adb shell am start -n com.rapphub.rapp/.MainActivity`。
- Mac 门禁（合并前跑全；动了 `rust/hub-ffi` 再加最后一条）：
  ```bash
  swift build -c release && swift test
  cd rust && cargo test --workspace --no-fail-fast
  cd rust && cargo clippy --workspace --all-targets -- -D warnings
  cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test
  git checkout gui/pubspec.lock
  cd rust && cargo build --release -p rapp-hub-ffi --target aarch64-apple-ios-sim
  ```
  已知的本机失败：`linux_detach_test` 两条、`service_client_test` 的「ServiceMonitor share…」。
- relay 地址和密钥不打印、不进日志、不提交。要用时从 `~/rapp/local/service.json` 读进变量，命令里只出现 `jq` 表达式，不 `echo`、不 `cat` 到终端；带它们的截图不存进仓库。
- 连 Mac 用单应用会话（比如「文本编辑」）。只有某一步确实要桌面会话才开：它会把用户自己的会话顶掉，Mac 在最后一个计数会话结束 10 s 后自动锁屏。
- 探查分支 `probe/android-p0`（`cfd7997e`）只用 `git show cfd7997e:<path>` 或 `git checkout cfd7997e -- <path>` 取。这些不带过来：`keeps_link`、`P0_SLOW_MS`、`p0 fps` / `p0 traffic` 日志、`rapp_p0_resolve`（和它为此公开的 `rapp_net::quic::getaddrinfo_v6`）、`LinuxSessionPort.ffi` / `slow`、`SessionWorker.ffi` / `_FfiSessionWorker`、`ackedPackets`、`main_p0_shell.dart`、`p0/` 页面、`p0SlowFromProperty`、`_traffic`、`rapp/p0speech` 通道、探查版 `MainActivity.kt`。
- 不改版本号（`gui/pubspec.yaml` 的 `version`、`rust/Cargo.toml` 的 workspace version）；新 crate 进 workspace 带来的 `Cargo.lock` 新条目照常提交。不打 tag，不 `git push`，不动 `website/releases.json`，不改 `CLAUDE.md`（发版步骤 §13.5 是 P3 的事）。
- 搜代码用 `/usr/bin/grep`。不读不搜 `docs/archives/`。
- 表现以 iPad 为准、做法沿用 Linux（规格 §15.2 第 17 条）。对不齐的地方停下来问用户（AskUserQuestion，一次问一件），不绕过。
- 安卓上 `stderr` 到不了 logcat：入口的日志用 `debugPrint`。

## Review Focus

1. **会话库里 Rust 出了 panic**：App 不闪退；那个会话恰好结束一次，显示断开；`send` 返回 -3。hub 的 panic 同样不越过 C 边界。→ Task 3 的 `a_panicking_session_ends_with_kind_2_once`、`send_after_a_panic_answers_minus_3`；Task 2 的 `start_that_panics_answers_minus_4`。
2. **画面来得比 Dart 画得快**：一次只有一帧在路上，内存不涨。→ Task 3 的 `gate_holds_the_next_packet_until_ack`（不靠计时）和 Task 5 的 `'ack reaches the library once per call'`。
3. **open 还没返回，第一个包已经到了；或者开到一半就关**：包不丢；结束恰好一次；`NativeCallable` 只在 kind 2 之后关。→ Task 5 的 `'a packet before open returns is kept'`、`'close before the first send ends at once with -1'`、`'kill that never sees kind 2 keeps the callable open'`。
4. **返回键**：每按一次恰好关一层（菜单、面板、日志、输入块、全屏），会话里回全景，全景里退到后台，不弹「再按一次退出」。→ Task 10 的 `backStep` 表格测试和 `'back on the overview moves the app to the back'`。
5. **分屏、小窗把窗口缩到短边 < 600，再拉宽**：按窗口尺寸排版，退出全屏，拉宽后回到全屏，不重建、不崩。→ Task 10 的 `'MobileFullscreen leaves and comes back with the window'` 和 Task 11 的旋转、分屏两项。

---

### Task 1: iPad 和 Linux 的差别表（规格附录）

动手前先列（§6.3、§15.2 第 17 条）。只写文档，不改代码。

**Files:**
- Modify: `docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`（末尾加「附录 A：iPad 和 Linux 端口的差别」）

**Interfaces:**
- Consumes: `gui/lib/embed/session_port.dart` 的 `ChannelSessionPort`（iPad 的端口）和 P1a 的 `WorkerSessionPort`、`LinuxSessionHost`
- Produces: 附录 A 的表；Task 8、Task 9 的 `AndroidSessionHost` 按它取值

- [ ] **Step 1: 建分支**

```bash
cd /Users/bruce/git/rapp && git worktree add .worktrees/android-p1 -b feat/android-p1 main
```

- [ ] **Step 2: 逐行对照，写表**

表的列：`行为 | iPad（ChannelSessionPort） | Linux（WorkerSessionPort） | 安卓取哪边 | 落在哪`。至少有这些行，每行写 `文件:行`：
- 写作条是原生的还是 Flutter 的（`supportsInlineNativeComposer`：Linux true，iPad false）
- 写作条的「粘贴」「附件」两个按钮走哪里（Linux 是 `composer_paste`、`composer_attach` 调宿主）
- 分离窗口（`supportsDetach`）
- 文字剪贴板的两个方向，什么时候读（§8.5：只在用户粘贴时读）
- 传文件的按钮和收到文件后的那一行（P1 安卓没有传文件：按钮在不在）
- 断开时的 `reason` 文字和「重连 / 结束会话」框
- `dropTextures`、内存警告
- 捏合缩放、双指滚动、悬停、右键、光标形状
- 键码（`hidMacKeyCode`）、Ctrl 当 ⌘、按着 Meta 的键不发
- 双击间隔（`init()` 的返回值）
- `sessionActive`、屏幕常亮
- 帧节流（iPad 由原生端控，Linux 靠管道背压，安卓靠 ack）

- [ ] **Step 3: 对不齐的行停下来**

「安卓取哪边」填不出、或者两边都不对的行，用 AskUserQuestion 问用户（一次一件，标「第 N/M 件」），答案写进表。没有这种行就写一句「全部对齐」。

- [ ] **Step 4: 提交**

```bash
git add docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md
git commit -m "docs(android): 附录 A：iPad 和 Linux 端口的差别"
```

### Task 2: `hub-ffi` 的 panic 不越过 C 边界

**Files:**
- Modify: `rust/hub-ffi/src/lib.rs`（四个 `extern "C"` 函数）
- Modify: `rust/hub-ffi/include/rapp_hub.h`（返回值说明）
- Modify: `rust/net/src/quic.rs:268`（注释）

**Interfaces:**
- Consumes: 无
- Produces: `rapp_hub_start` 和 `rapp_hub_send` 出 panic 时返回 `-4`；`rapp_hub_stop`、`rapp_hub_free_line` 出 panic 时什么也不做。正常返回值（0、-1、-2、-3）不变。iOS 不用改 Dart（`hub_ffi.dart` 把非 0 都当失败）。

- [ ] **Step 1: 写失败的测试**（`hub-ffi` 的 `mod tests`；已有的 `FORCE_PANIC` 是 hub 任务里的 panic，这里要的是函数体本身的 panic，加一个 `#[cfg(test)] static PANIC_IN_CALL: AtomicBool`）

```rust
#[test]
fn start_that_panics_answers_minus_4() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = CString::new("/tmp/rapp-hub-ffi-panic").unwrap();
    PANIC_IN_CALL.store(true, Ordering::SeqCst);
    let r = rapp_hub_start(dir.as_ptr(), dir.as_ptr(), CString::new("n").unwrap().as_ptr(), collect);
    PANIC_IN_CALL.store(false, Ordering::SeqCst);
    assert_eq!(r, -4);
    assert!(HUB.lock().unwrap_or_else(|e| e.into_inner()).is_none());
}

#[test]
fn send_that_panics_answers_minus_4() { /* 同上，对 rapp_hub_send；没起 hub 时也先走到 panic 点 */ }
```

`TEST_LOCK`、`collect` 是测试模块里现成的；`rapp_hub_start` 的参数顺序以 `lib.rs` 为准。

- [ ] **Step 2: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-hub-ffi`
Expected: FAIL（`PANIC_IN_CALL` 没定义；定义后测试进程因 panic 越过 `extern "C"` 而中止）

- [ ] **Step 3: 实现**

四个函数体包进 `catch_unwind(AssertUnwindSafe(..)).unwrap_or(fallback)`（和 `android-ffi` 的 `guard` 同一个写法）；`PANIC_IN_CALL` 在各函数体开头检查。`rapp_hub.h` 两处返回值说明加「-4 内部出错（panic），没有启动 / 没有发出」。`quic.rs:268` 的「Only the iOS hub uses them」改成「Only the in-process hub (iOS, Android) uses them」。

- [ ] **Step 4: 跑，看它通过，iOS 模拟器的库编得过**

Run: `cd rust && cargo test -p rapp-hub-ffi && cargo clippy -p rapp-hub-ffi --all-targets -- -D warnings && cargo build --release -p rapp-hub-ffi --target aarch64-apple-ios-sim`
Expected: PASS，编译成功

- [ ] **Step 5: 提交**

```bash
git add rust/hub-ffi rust/net/src/quic.rs
git commit -m "fix(hub-ffi): a panic in a C entry point returns -4 instead of aborting"
```

### Task 3: `rust/android-ffi`（hub + 会话的 `.so`）

**Files:**
- Create: `rust/android-ffi/Cargo.toml`、`rust/android-ffi/src/lib.rs`
- Modify: `rust/Cargo.toml`（workspace `members` 加 `android-ffi`）、`rust/Cargo.lock`

**Interfaces:**
- Consumes: `rapp_client_core::session::serve`（P1a Task 3）；`rapp_hub_ffi` 的四个函数（Task 2）
- Produces（C ABI，导出表里恰好这 9 个 `rapp_*`）:
  - `pub use rapp_hub_ffi::{rapp_hub_start, rapp_hub_send, rapp_hub_stop, rapp_hub_free_line};`
  - `pub type Sink = extern "C" fn(id: u64, kind: u8, ptr: *mut u8, len: usize);`：kind 0 事件、1 帧（`ptr`/`len` 是一整个管道格式的包，`libc::malloc` 来的，用 `rapp_session_free` 还）；kind 2 是结束（null、0），每个会话恰好一次且是最后一次
  - `rapp_session_open(start: *const c_char, sink: Sink) -> u64`：0 失败（之后不调 sink）
  - `rapp_session_send(id: u64, line: *const c_char) -> i32`：0 发出；-1 没这个会话（或正在结束）；-2 null 或不是 UTF-8；-3 内部出错（panic）
  - `rapp_session_ack(id: u64)`、`rapp_session_close(id: u64)`、`unsafe rapp_session_free(ptr: *mut c_void)`
- Cargo：包名 `rapp-android-ffi`，`[lib] name = "rapp_android"`，`crate-type = ["cdylib"]`；依赖只有 `rapp-hub-ffi`、`rapp-client-core`、`libc`；dev 依赖 `flate2`

- [ ] **Step 1: 取探查版做起点**

```bash
git show cfd7997e:rust/android-ffi/Cargo.toml > rust/android-ffi/Cargo.toml
git show cfd7997e:rust/android-ffi/src/lib.rs > rust/android-ffi/src/lib.rs
```

删掉：`rapp_p0_resolve`、`anyhow_text`（只有它用的话）和测试 `p0_resolve_gives_getaddrinfo_v6_then_the_dual_address`；Cargo.toml 里的 `serde_json`、`rapp-net`、`tokio` 和「Probe」注释。整个文件内容放进 `#[cfg(not(windows))]`（Windows 门禁照样编 workspace，安卓的库在那里不需要内容）。保留：`Gate`、`Body`、`GateWriter`、`Lines`、`Session`、`guard` 和四条测试（`gate_holds_the_next_packet_until_ack`、`close_releases_a_writer_stuck_on_the_gate`、`session_over_loopback_ends_with_kind_2_exactly_once`、`close_on_an_unacked_frame_still_ends_with_kind_2_once`）。

- [ ] **Step 2: 写失败的测试**

```rust
#[test]
fn a_panicking_session_ends_with_kind_2_once() {
    // PANIC_IN_SESSION：会话线程进 serve 之前 panic
    let ends = record_sink();                    // 测试 sink：按 id 记下每个 kind
    PANIC_IN_SESSION.store(true, SeqCst);
    let id = rapp_session_open(c(START).as_ptr(), ends.sink);
    PANIC_IN_SESSION.store(false, SeqCst);
    ends.wait_end(id, Duration::from_secs(2));
    assert_eq!(ends.kinds(id), vec![2]);
}

#[test]
fn send_after_a_panic_answers_minus_3() { /* PANIC_IN_CALL 设上后调 rapp_session_send，返回 -3 */ }

#[test]
fn send_answers_minus_1_and_minus_2() {
    assert_eq!(rapp_session_send(999_999, c("{}").as_ptr()), -1);
    // 开一个会话后，发一段不是 UTF-8 的字节
    assert_eq!(rapp_session_send(id, b"\xff\xfe\0".as_ptr().cast()), -2);
}

#[test]
fn gate_holds_the_next_packet_until_ack() { /* 探查版原样：不睡、不靠计时，用 Condvar 的状态判断 */ }
```

`record_sink`、`START` 写在测试里；`START` 是一行会让会话立刻因连不上而结束的启动参数（探查版 `fake_a()` 那套可复用）。

- [ ] **Step 3: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-android-ffi`
Expected: 新的三条 FAIL（`PANIC_IN_SESSION`、`PANIC_IN_CALL` 没定义；`send` 出 panic 时探查版返回 -1）

- [ ] **Step 4: 实现**

- `rapp_session_send` 的 `guard` 兜底值从 -1 改成 -3。
- 会话线程：panic 之后先 `gate.end()`，再从表里删，再调 sink 的 kind 2；写线程在 `end()` 之后不再调 sink（探查版已是这个顺序，测试把它钉住）。
- 文件头和 `rapp_session_open`、`rapp_session_close` 的文档写明两点：sink 可能在 `rapp_session_open` 返回之前就被调（调用方不能靠返回的 id 分发）；`close` 最多等 2 s，kind 2 可能在它返回之后才来。

- [ ] **Step 5: 跑，看它通过**

Run: `cd rust && cargo test -p rapp-android-ffi && cargo clippy --workspace --all-targets -- -D warnings`
Expected: PASS

- [ ] **Step 6: 交叉编译，查导出表和对齐**

```bash
cd rust && ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358 ~/.cargo/bin/cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi
nm=$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm
re=$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf
so=target/aarch64-linux-android/release/librapp_android.so
"$nm" -D --defined-only "$so" | /usr/bin/grep -c ' T rapp_'
"$re" -lW "$so" | /usr/bin/grep LOAD
```

Expected: 计数 `9`；每个 `LOAD` 的对齐列是 `0x4000`。

- [ ] **Step 7: 提交**

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/android-ffi
git commit -m "feat(android-ffi): one .so with the in-process hub and the session library"
```

### Task 4: `FfiHubTransport` 能从指定的库里找函数

**Files:**
- Modify: `gui/lib/hub_ffi.dart`
- Test: `gui/test/hub_ffi_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `static FfiHubTransport start({required String home, required String logDir, required String name, String? library})`：`library` 为 null 时是 App 本身（iOS 静态链接，和现在一样），否则 `DynamicLibrary.open(library)`
  - 私有 `DynamicLibrary _open(String? library)`、`Future<void> _stopOffThread(String? library)`：停 hub 在 `Isolate.run` 里按库名重新打开（`DynamicLibrary` 不能传给别的 isolate）

- [ ] **Step 1: 写失败的测试**

```dart
test('start names a missing library in its error', () {
  expect(() => FfiHubTransport.start(home: '/x', logDir: '/x', name: 'n', library: 'librapp_nope.so'),
      throwsA(predicate((e) => '$e'.contains('librapp_nope.so'))));
});
```

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/hub_ffi_test.dart`
Expected: FAIL（没有 `library` 参数）

- [ ] **Step 3: 按 Produces 实现**（探查版 `git show cfd7997e:gui/lib/hub_ffi.dart` 的 `_open`、`_stopOffThread` 可以照搬）

打不开库时抛的 `HubException` 文字里带库名。

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2
Expected: PASS（原有的 iOS 测试照过）

- [ ] **Step 5: 提交**

```bash
git add gui/lib/hub_ffi.dart gui/test/hub_ffi_test.dart
git commit -m "feat(gui): FfiHubTransport takes the shared library to load"
```

### Task 5: `FfiSessionLinks`（进程内会话的通路）

**Files:**
- Create: `gui/lib/embed/session_ffi.dart`
- Test: `gui/test/embed/session_ffi_test.dart`

**Interfaces:**
- Consumes: P1a Task 4 的 `SessionLink`、`SessionLinks`；Task 3 的 C 函数
- Produces:

```dart
/// C 函数的 Dart 一层；测试换成假的。sink 收 (kind, 一整个包或 null)。
abstract class SessionNative {
  int open(String start, void Function(int kind, Uint8List? packet) sink); // 0：失败
  int send(int id, String line);
  void ack(int id);
  Future<void> close(int id);               // 在 Isolate.run 里调 rapp_session_close（会阻塞最多 2 s）
}

class FfiSessionLinks implements SessionLinks {
  FfiSessionLinks(String library, {SessionNative? native});
}

class FfiSessionLink implements SessionLink {
  FfiSessionLink(SessionNative native);
}
```

- `FfiSessionLinks.check()`：打不开库就抛 `StateError('session library not found: $library')`；`open()` 返回一个还没开的 `FfiSessionLink`。
- **第一次 `send(line)` 才开会话**：那一行就是启动参数，传给 `native.open`；之后的 `send` 走 `native.send`。`open` 返回 0：包流关、`exitCode` 完成为 -1。
- 每条 link 一个 `NativeCallable<SinkC>.listener`（真实现里），不靠 id 分发；包到了先拷进 `Uint8List` 再 `rapp_session_free`。
- kind 2：关包流，`exitCode` 完成为 0，`inputDone` 完成，然后才 `NativeCallable.close()`。
- `ack()`：已开就 `native.ack(id)`，否则不做。
- `close()`：没开过就当场结束（`exitCode` -1）；开过就 `native.close(id)`，结束仍等 kind 2。
- `kill()`：同 `close()`，不等。kind 2 一直不来，`NativeCallable` 也不关（关了库里再调会崩），只让 `exitCode` 在 3 s 后完成为 -1。
- `id`：开之前 0，之后是库给的号。

- [ ] **Step 1: 写失败的测试**（全部用 `FakeNative`，`fake_async` 控时间）

```dart
test('the first send opens with that line, later ones go to send', () { ... expect(native.opened, ['{"start":1}']); expect(native.sent, [(7, '{"cmd":"x"}')]); });
test('a packet before open returns is kept', () { /* FakeNative.open 在返回前就调 sink(0, ...) */ expect(packets, hasLength(1)); });
test('kind 2 ends the link once and only then closes the callable', () { ... expect(await link.exitCode, 0); expect(native.callableClosed, 1); });
test('ack reaches the library once per call', () { link.ack(); link.ack(); expect(native.acks, [7, 7]); });
test('ack before open does nothing', () { expect(native.acks, isEmpty); });
test('close before the first send ends at once with -1', () { ... expect(await link.exitCode, -1); expect(native.opened, isEmpty); });
test('open that fails ends with -1', () { /* FakeNative.open 返回 0 */ });
test('kill that never sees kind 2 keeps the callable open', () {
  fakeAsync((t) { link.kill(); t.elapse(const Duration(seconds: 3)); expect(code, -1); expect(native.callableClosed, 0); });
});
test('check names a missing library', () async {
  await expectLater(FfiSessionLinks('librapp_nope.so').check(), throwsA(isA<StateError>()));
});
```

`callableClosed` 由 `FakeNative` 记（真实现里关 `NativeCallable` 的那一步要经过 `SessionNative` 的一个回调或 `FfiSessionLink` 的一个 `@visibleForTesting` 计数，实施者选一种）。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/embed/session_ffi_test.dart`
Expected: FAIL（文件不存在）

- [ ] **Step 3: 按 Produces 实现**

真的 `SessionNative`（私有 `_LibSessionNative`）的 typedef 照探查版 `session_ffi.dart:50-56`；`close` 照探查版 `closeOffThread` 按库名在 `Isolate.run` 里调。探查版里的 `slow`、`ackedPackets` 不要。

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/session_ffi.dart gui/test/embed/session_ffi_test.dart
git commit -m "feat(gui): FfiSessionLinks runs sessions in the app's own library"
```

### Task 6: `gui/android/` 外壳和 `scripts/build-android.sh debug`

**Files:**
- Create: `gui/android/`（模板文件，见 Step 1）
- Create: `gui/android/app/src/main/res/xml/network_security_config.xml`、`gui/android/app/src/main/res/xml/data_extraction_rules.xml`
- Create: `gui/android/app/src/main/kotlin/com/rapphub/rapp/MainActivity.kt`（这一步只有空的 `FlutterActivity`，通道在 Task 7）
- Create: `scripts/build-android.sh`
- Modify: `gui/.metadata`（android 那一项）、`gui/.gitignore`（`android/app/src/main/jniLibs/`）

**Interfaces:**
- Consumes: Task 3 的 `.so`
- Produces:
  - 能编出的调试包 `gui/build/app/outputs/flutter-apk/app-debug.apk`，`.so` 在包里的 `lib/arm64-v8a/librapp_android.so`
  - `scripts/build-android.sh debug`：编 `.so`、拷进 `jniLibs`、查导出表 9 个和 `LOAD` 对齐 `0x4000`（不对就退出非 0）、带 `JAVA_HOME` 编调试包、还原 `gui/pubspec.lock`、打印 APK 路径。`release` 参数打印「release 包在 P3」后退出 1。

- [ ] **Step 1: 取模板**

```bash
git checkout cfd7997e -- gui/android/.gitignore gui/android/build.gradle.kts gui/android/settings.gradle.kts \
  gui/android/gradle.properties gui/android/gradle/wrapper/gradle-wrapper.properties \
  gui/android/app/build.gradle.kts gui/android/app/src/debug gui/android/app/src/profile \
  gui/android/app/src/main/res gui/android/app/src/main/AndroidManifest.xml
```

（探查版的这些是 `flutter create --platforms=android` 生成后只改了清单和网络配置；拿不到时就在临时目录 `flutter create --platforms=android --org com.rapphub --project-name rapp` 再拷过来。）`MainActivity.kt` 不取探查版，新写一个只继承 `FlutterActivity` 的。`gui/.metadata`、`gui/.gitignore` 只并进探查版多的那几行。`flutter create` 若生成了 `test/widget_test.dart`，删掉。

- [ ] **Step 2: 按 Global Constraints 改清单和 Gradle**

清单：两个权限；`<application android:allowBackup="false" android:dataExtractionRules="@xml/data_extraction_rules" android:networkSecurityConfig="@xml/network_security_config">`；Activity `android:resizeableActivity="true"`、不锁方向、`configChanges` 用模板的整套。`data_extraction_rules.xml` 的 `cloud-backup` 和 `device-transfer` 都 `<exclude domain="root" path="."/>`（以及 `file`、`database`、`sharedpref`、`external` 各一条）。网络配置只给 `localhost`、`127.0.0.1` 放行明文。`app/build.gradle.kts`：`minSdk = 34`，`compileSdk`、`targetSdk` 用 Flutter 默认（36），`ndk { abiFilters += "arm64-v8a" }`，`versionName`/`versionCode` 从 pubspec 来（模板默认）。

- [ ] **Step 3: 写 `scripts/build-android.sh`**

照 `git show cfd7997e:scripts/p0-android-so.sh` 的变量写法，加上 Produces 里的查表、编包、还原。`set -euo pipefail`，路径都从 `$(dirname "$0")/..` 算。

- [ ] **Step 4: 编出来，装到模拟器上能起**

```bash
bash -n scripts/build-android.sh && scripts/build-android.sh debug
$ANDROID_HOME/emulator/emulator -avd rapp-p0-34 -no-snapshot -no-boot-anim &   # 后台起
~/Library/Android/sdk/platform-tools/adb wait-for-device
~/Library/Android/sdk/platform-tools/adb install -r gui/build/app/outputs/flutter-apk/app-debug.apk
~/Library/Android/sdk/platform-tools/adb shell am start -n com.rapphub.rapp/.MainActivity
unzip -l gui/build/app/outputs/flutter-apk/app-debug.apk | /usr/bin/grep librapp_android.so
```

Expected: 脚本最后一行是 APK 路径；App 起来（这时 `main.dart` 还没有安卓入口，走桌面那支会报错或空白，这一步只看进程活着：`adb shell pidof com.rapphub.rapp` 有输出）；包里有 `lib/arm64-v8a/librapp_android.so`。`adb shell dumpsys package com.rapphub.rapp | /usr/bin/grep -E 'minSdk|targetSdk|ALLOW_BACKUP'` 是 34、36，flags 里没有 `ALLOW_BACKUP`。

- [ ] **Step 5: 门禁里的 Flutter 部分没被新目录弄坏，提交**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && git checkout pubspec.lock`
Expected: 没有新问题

```bash
git add gui/android gui/.metadata gui/.gitignore scripts/build-android.sh
git commit -m "feat(android): Flutter Android shell (minSdk 34, no backup, loopback-only cleartext) and build-android.sh debug"
```

### Task 7: `MobileChannel`，`IosChannel` 和 `AndroidChannel` 都实现它

**Files:**
- Create: `gui/lib/mobile_channel.dart`（接口、`MobileNet`、`MobilePaths`、全局 `mobileChannel`）
- Create: `gui/lib/android_channel.dart`
- Modify: `gui/lib/ios_channel.dart`（`implements MobileChannel`；`IosNet` 改名 `MobileNet` 挪走；`IosPaths implements MobilePaths`；加空的 `moveToBack`）
- Modify: `gui/lib/ui/background.dart`（`BackgroundWatch({required MainState state, required MobileChannel channel, ...})`）
- Modify: `gui/lib/ui/fullscreen.dart`（`IosFullscreen` 改名 `MobileFullscreen([MobileChannel? channel])`，默认 `mobileChannel`）
- Modify: `gui/lib/pages/ios_local_section.dart:74`、`gui/lib/main_ios.dart`（跟着改名）
- Modify: `gui/android/app/src/main/kotlin/com/rapphub/rapp/MainActivity.kt`
- Test: `gui/test/android_channel_test.dart`；改 `gui/test/ui/background_test.dart`、`gui/test/ui/ios_channel_test.dart`、`gui/test/ui/fold_fullscreen_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:

```dart
abstract class MobilePaths { String get dataRoot; }
class MobileNet { const MobileNet({required this.ok, this.status = 0, this.error = ''}); bool get blocked; } // 原 IosNet，blocked 规则不变
abstract class MobileChannel {
  Future<MobilePaths> paths();
  Future<String> deviceName();
  Future<String> version();
  Future<MobileNet> net();
  Future<void> openSettings();
  Future<void> keepAwake(bool on);
  Future<void> sessionActive(bool on);
  Future<void> fullscreen(bool on);
  Future<void> beginBackground();
  Future<void> endBackground();
  Future<void> openUrl(String url);
  Future<void> moveToBack();            // 安卓：moveTaskToBack；iOS：不做
  Stream<String> get events;            // 'pathChanged'（安卓 P1 只有它）、'memoryWarning'
}
class AndroidPaths implements MobilePaths { const AndroidPaths(this.files, this.cache); final String files, cache; String get dataRoot => '$files/rapp'; }
class AndroidChannel implements MobileChannel { AndroidChannel([MethodChannel? channel]); } // 'rapp/android'
final MobileChannel mobileChannel = Platform.isAndroid ? AndroidChannel() : iosChannel;
```

`IosChannel` 的 `idiom`、`share` 留在它自己身上，不进接口。`AndroidChannel.net()` 不调原生，直接 `const MobileNet(ok: true)`；`sessionActive`、`beginBackground`、`endBackground` 不调原生，直接完成（§9.1）。

Kotlin 那边（`MainActivity.configureFlutterEngine` 里开 `rapp/android`），P1 只实现：

| 方法 | 做法 |
|---|---|
| `paths` | `{"files": filesDir.absolutePath, "cache": cacheDir.absolutePath}` |
| `deviceName` | `Settings.Global.DEVICE_NAME`，空就 `Build.MODEL` |
| `version` | `PackageInfo.versionName` |
| `openSettings` | `ACTION_APPLICATION_DETAILS_SETTINGS`，`package:` 本包 |
| `keepAwake` | 主线程上加、去 `FLAG_KEEP_SCREEN_ON`（参数 `on`） |
| `fullscreen` | `WindowInsetsControllerCompat`：`on` 时 `hide(systemBars())` + `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`，否则 `show(systemBars())` |
| `openUrl` | `ACTION_VIEW`；没有能打开的 App 就 `result.error("no_app", …)` |
| `moveToBack` | `moveTaskToBack(true)` |
| 事件 `pathChanged` | `registerDefaultNetworkCallback` 的 `onAvailable`、`onLost` 里在主线程 `invokeMethod("pathChanged", null)`；`onDestroy` 注销 |

其他方法 `result.notImplemented()`。

- [ ] **Step 1: 写失败的测试**

```dart
// android_channel_test.dart（用 TestDefaultBinaryMessenger 给 'rapp/android' 装假处理器）
test('paths gives the data root under filesDir', () async { expect((await ch.paths()).dataRoot, '/data/f/rapp'); });
test('net is always ok and never asks the platform', () async { expect((await ch.net()).ok, isTrue); expect(calls, isEmpty); });
test('keepAwake, fullscreen, openUrl and moveToBack go over the channel', () async {
  await ch.keepAwake(true); await ch.fullscreen(false); await ch.openUrl('https://a'); await ch.moveToBack();
  expect(calls, [('keepAwake', {'on': true}), ('fullscreen', {'on': false}), ('openUrl', {'url': 'https://a'}), ('moveToBack', null)]);
});
test('sessionActive and the background calls stay on the Dart side', () async { ...; expect(calls, isEmpty); });
test('pathChanged from the platform arrives on events', () async { ... expect(await ch.events.first, 'pathChanged'); });
```

`background_test.dart`、`fold_fullscreen_test.dart` 里构造 `BackgroundWatch(ios: …)`、`IosFullscreen(…)` 的地方换成新名字，并各加一条用 `AndroidChannel` 的：`'BackgroundWatch keeps the screen awake over rapp/android'`（会话上台后 `keepAwake {on: true}` 发到 `rapp/android`）。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/android_channel_test.dart test/ui/background_test.dart test/ui/ios_channel_test.dart test/ui/fold_fullscreen_test.dart`
Expected: FAIL（`AndroidChannel`、`MobileChannel` 不存在）

- [ ] **Step 3: 按 Produces 实现 Dart 部分和 Kotlin 部分**

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2，再 `~/development/flutter/bin/flutter analyze`
Expected: PASS，analyze 干净

- [ ] **Step 5: 提交**

```bash
git add gui/lib gui/test gui/android/app/src/main/kotlin
git commit -m "feat(gui): MobileChannel shared by rapp/ios and the new rapp/android"
```

### Task 8: 能力表和 §6.5 的逐处结论

**Files:**
- Modify: `gui/lib/platform_caps.dart`、`gui/lib/ui/unlock.dart`、`gui/lib/ui/main_state.dart`、`gui/lib/ui/main_window.dart`、`gui/lib/ui/open_apps_menu.dart`、`gui/lib/ui/log_screen.dart`、`gui/lib/ui/resources_tab.dart`、`gui/lib/embed/composer_panel.dart`、`gui/lib/embed/voice_tidy_card.dart`、`gui/lib/embed/input_dock.dart`、`gui/lib/term/term_stage.dart`、`gui/lib/data_dir.dart`、`gui/lib/pages/app_profile_page.dart`、`gui/lib/pages/local_section.dart`、`gui/lib/pages/data_section.dart`
- Test: `gui/test/ui/platform_caps_test.dart`，以及下表「测试」一列点名的现有测试文件

**Interfaces:**
- Consumes: Task 7 的 `mobileChannel`
- Produces:
  - `enum SecretStore { none, memory, keychain }`；`PlatformCaps` 加 `final SecretStore secretStore`（默认 `none`）、`final bool systemLinks`（链接走 `mobileChannel.openUrl`；默认 false）、`final bool opensFolders`（有地方打开一个文件夹；默认 true）
  - `forOs`：`'ios'` 加 `secretStore: keychain, systemLinks: true`；`'android' => PlatformCaps(hubInProcess: true, secretStore: SecretStore.memory, systemLinks: true, opensFolders: false)`；`'linux'` 单列一支（桌面那一整套 + `secretStore: memory`）；`'macos'` 和兜底那支 `secretStore: keychain`（兜底原来也是 macOS 用）；`'windows'` 不变（`none`）
  - `pinchZoom`、`hardwareKeyboard()` 改认 `touchPlatform(defaultTargetPlatform)`（`ui/tokens.dart:312`，已经含安卓）

`onlineUpdate` 在安卓上 P1 先不开（规格 §6.5 写的是 true）：它的两处用法读的是 `ServiceMonitor`，安卓走不到；P3 做更新界面时再开。`systemOpen` 留 false（规格原话）。

逐处结论（行号是本计划写时的，动手前重新 `/usr/bin/grep -rn 'isIOS\|TargetPlatform.iOS\|iosChannel' gui/lib`）：

| 位置 | 现在 | 结论 | 测试 |
|---|---|---|---|
| `ui/unlock.dart:22` | mac、iOS、Linux 才 `supported` | `supported ??= caps.secretStore != none`，`memory ??= caps.secretStore == memory`（安卓 P1 只记在内存里，P2 换 Keystore） | `unlock_test`：android 的 caps 下 `supported` 且 `memory` |
| `ui/main_state.dart:217` | iOS、mac 有语音 | 保持；安卓落到 null（语音不在 P1） | — |
| `ui/main_state.dart:969, 978` | iOS 没有本机余力 | 改 `!caps.hasService` | `main_state` 现有余力测试在 android 的 caps 下 `localLoadId == null` |
| `ui/main_state.dart:4827` | iOS 默认不自动收起快捷区 | 改 `!touchPlatform(...)` | 现有 `quickAutoHide` 测试加 android |
| `ui/tokens.dart:312` | `touchPlatform` 已含安卓 | 保持 | — |
| `ui/main_window.dart:43` | 没有文件管理器就弹分享 | `caps.opensFolders` 为 false 时，各处 `openFolder:` 传 null，收它的组件见 null 就不显示那个按钮（参数本来不可空的改成可空） | `app_profiles_section` 的现有测试：android 的 caps 下没有打开文件夹的按钮 |
| `ui/main_window.dart:142` | `caps.hubInProcess` 时显示接入引导 | 保持（安卓同 iPad） | — |
| `ui/open_apps_menu.dart:26` | iOS 行高 44 | 改 `touchPlatform` | — |
| `ui/side_panel.dart:268` | 内置输入法开关 | 保持（安卓没有 Rime） | — |
| `ui/log_screen.dart:143` | iOS：不显示来源、行高 48 | 来源那条改 `!caps.hasService`，行高改 `touchPlatform(Theme.of(context).platform)` | — |
| `ui/resources_tab.dart:67` | iOS 能从资源加常用语 | 改 `touchPlatform`（同 iPad） | — |
| `service_client.dart:414, 449` | iOS 不开余力、终端流 | 保持（安卓不造 `ServiceMonitor`，走不到） | — |
| `embed/flutter_editor.dart:19` | iOS 用内置 Rime | 保持 | — |
| `embed/composer_panel.dart:139` | iOS 键条锁住修饰键后的字母发给 A | 改 `touchPlatform` | — |
| `embed/composer_panel.dart:548` | iOS 的输入块叠法（`_iosStack`） | 改 `touchPlatform` | `composer_panel` 现有 iOS 叠法测试加一遍 android |
| `embed/composer_panel.dart:755` | iOS 的 AI 整理卡片位置 | 改 `touchPlatform` | — |
| `embed/composer_panel.dart:870` | iOS 的按住说话 | 保持（语音在 P2 决定） | — |
| `embed/voice_tidy_card.dart:542` | iOS 最小行高 44 | 改 `touchPlatform` | — |
| `embed/input_dock.dart:205` | iOS 的输入块默认位置、下拉收起 | 改 `touchPlatform` | `input_dock` 现有测试加 android |
| `embed/voice_button.dart:61, 566` | iOS 的震动、去设置 | 保持（语音） | — |
| `term/term_stage.dart:49` | `systemOpen` 时走 `iosChannel.openUrl` | 改 `caps.systemLinks` → `mobileChannel.openUrl`；其余分支不变 | `term_stage` 新测试：android 的 caps 下链接发到 `rapp/android` 的 `openUrl` |
| `pages/local_section.dart:43` | 同上（安装页） | 同上 | — |
| `pages/data_section.dart:54` | 打开文件夹 | `!caps.opensFolders` 时不显示那个按钮 | — |
| `pages/app_profile_page.dart:445` | iOS 才有「常用语条」开关 | 改 `touchPlatform` | — |
| `pages/app_profile_page.dart:455` | 内置输入法开关 | 保持 | — |
| `pages/ios_local_section.dart:74` | `iosChannel.version` | Task 7 已改 `mobileChannel.version` | — |
| `main.dart:40` | iOS 入口 | Task 9 加安卓一行 | — |
| `data_dir.dart:205` | Windows、iOS 不 `chmod` | 加 `Platform.isAndroid`（沙盒管权限） | — |

- [ ] **Step 1: 写失败的测试**

```dart
test('android caps', () {
  final c = PlatformCaps.forOs('android');
  expect([c.hubInProcess, c.hasService, c.canDetach, c.systemOpen, c.systemLinks, c.opensFolders, c.onlineUpdate],
      [true, false, false, false, true, false, false]);
  expect(c.secretStore, SecretStore.memory);
  expect(PlatformCaps.forOs('linux').secretStore, SecretStore.memory);
  expect(PlatformCaps.forOs('macos').secretStore, SecretStore.keychain);
  expect(PlatformCaps.forOs('windows').secretStore, SecretStore.none);
});

testWidgets('android counts as touch for pinch and the hardware keyboard', (t) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  expect(pinchZoom, isTrue);
  expect(hardwareKeyboard(now: DateTime(2026)), isFalse);       // 没收到过键
  debugDefaultTargetPlatformOverride = null;
});
```

加上表里「测试」一列的那几条。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/platform_caps_test.dart`
Expected: FAIL（`secretStore` 等不存在）

- [ ] **Step 3: 按 Produces 和表实现**

- [ ] **Step 4: 跑全部 Flutter 测试**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test; git checkout pubspec.lock`
Expected: 除已知的三条外 PASS（这一步改了共用代码，iOS、桌面的现有测试必须照过）

- [ ] **Step 5: 提交**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): Android caps; iOS-only checks become capabilities or touchPlatform (spec §6.5)"
```

### Task 9: `main_mobile.dart`、`main_android.dart` 和「调试」区（按键、帧率）

**Files:**
- Create: `gui/lib/main_mobile.dart`（`main_ios.dart` 里两边一样的部分）
- Create: `gui/lib/main_android.dart`
- Create: `gui/lib/embed/android_session_host.dart`
- Create: `gui/lib/ui/debug_panel.dart`（`KeyLog`、`DebugPanel`）
- Modify: `gui/lib/main_ios.dart`（只留 iOS 的差别）、`gui/lib/main.dart:40`、`gui/lib/ui/log_screen.dart`（可选参数 `Widget? top`）、`gui/lib/ui/main_window.dart`（`debugPanel` 传给日志页）、`gui/lib/embed/worker_session_port.dart`（`framesShown`）
- Test: `gui/test/ui/debug_panel_test.dart`、`gui/test/embed/android_session_host_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `FfiHubTransport.start(library:)`；Task 5 的 `FfiSessionLinks`；Task 7 的 `MobileChannel`、`BackgroundWatch(channel:)`、`MobileFullscreen`；Task 8 的 caps；P1a 的 `WorkerSessionPort`、`SessionHost`、`SessionCopy`
- Produces:
  - ```dart
    Future<void> mainMobile({
      required MobileChannel channel,
      required String os,                                   // 'ios' | 'android'：给 ensureDeviceId
      required void Function(String) log,
      required HubTransport Function(DataDir data, String root, String name) hub,
      required Future<(SessionPort, Duration)> Function(DataDir data, String root) port, // 端口和双击间隔
      required LocalIme localIme,
      required DeviceOs Function() localOs,
      RimeGlue Function(MainState state)? rime,             // 只有 iOS 给
      Widget Function(MainState state)? debugPanel,         // 只有安卓给
      Future<void> Function()? onBack,                      // Task 10 用；只有安卓给
    })
    ```
    身体就是现在 `mainIos()` 去掉三处 iOS 专属（`idiom`、`RimeLocalIme`、`RimeGlue`）后的样子，`iosChannel` 换成 `channel`，`IosFullscreen()` 换成 `MobileFullscreen(channel)`，`_IosApp` 改名 `_MobileApp`，`_waitForNetwork` 收 `channel`。
  - `main_ios.dart`：`mainIos()` 取 `idiom` 后调 `mainMobile(channel: iosChannel, os: 'ios', log: stderr 那个, hub: …FfiHubTransport.start(home:, logDir:, name:), port: …ChannelSessionPort, localIme: RimeLocalIme(RappRime.instance), localOs: () => localDeviceOs(iosIdiom: idiom), rime: RimeGlue.new)`
  - `main_android.dart`：`Future<void> mainAndroid()`：`log` 是 `debugPrint('rapp: $s')`；`hub` 是 `FfiHubTransport.start(..., library: 'librapp_android.so')`；`port` 是 `WorkerSessionPort(FfiSessionLinks('librapp_android.so'), AndroidSessionHost(root))`，`init()` 的返回值当双击间隔；`localIme: NoLocalIme()`；`localOs: () => localDeviceOs(os: 'android', shortestSide: <窗口短边，逻辑点>)`（`device_os.dart:37` 已有这两个参数）；`debugPanel` 给；`onBack: androidChannel.moveToBack`
  - `main.dart:40` 下面加 `if (Platform.isAndroid) return mainAndroid();`
  - `class AndroidSessionHost implements SessionHost { AndroidSessionHost(String root); }`：`downloads()` 是 `'$root/files/transfers'`；`readClipboard()` 只读 Flutter `Clipboard` 的文字（`SessionCopy('text', …)`，没有文字返回 null）；`writeClipboard` 只写文字（不是文字返回 false）；`reveal` 返回 false、`chooseFiles` 返回空（传文件是 P2）；`traceDir` null；`detachChannel` null；`supportsDetach` false；`supportsInlineNativeComposer` 按 Task 1 附录 A 取（预期 false，同 iPad）
  - `WorkerSessionPort`：`int get framesShown`（做成图片的帧累计数，只增不减）
  - ```dart
    class KeyLog extends ChangeNotifier {
      KeyLog({int keep = 30});
      void install();                    // HardwareKeyboard.instance.addHandler，只看不拦（返回 false）
      List<String> get lines;            // 新的在前
    }
    ```
    每行格式（定死，实机清单照它读）：`'${kind} ${logicalKey.keyLabel.isEmpty ? logicalKey.debugName : logicalKey.keyLabel} ctrl=${c} meta=${m} alt=${a} shift=${s}'`，`kind` 是 `down`/`up`/`repeat`，四个修饰键取事件那一刻的 `HardwareKeyboard.instance.isControlPressed` 等，写 `1`/`0`。
  - `class DebugPanel extends StatelessWidget { const DebugPanel({required KeyLog keys, required int Function() frames}); }`：标题「调试」；第一行「画面 N 帧/秒」（每秒取一次 `frames()` 的差）；下面是 `KeyLog.lines`，等宽字。放在日志页最上面（`LogScreen(top:)`）。

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('the key log shows Ctrl held with C', (t) async {
  final log = KeyLog()..install();
  await t.pumpWidget(MaterialApp(home: DebugPanel(keys: log, frames: () => 0)));
  await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await simulateKeyDownEvent(LogicalKeyboardKey.keyC);
  await t.pump();
  expect(find.text('down C ctrl=1 meta=0 alt=0 shift=0'), findsOneWidget);
});

testWidgets('frames per second comes from the counter', (t) async { /* frames 每秒 +24，pump 1 s 后有「画面 24 帧/秒」 */ });

test('AndroidSessionHost keeps text on the Flutter clipboard and has no files yet', () async {
  final h = AndroidSessionHost('/r');
  expect(h.downloads(), '/r/files/transfers');
  expect(await h.writeClipboard(SessionCopy('text', text: 'hi')), isTrue);
  expect((await h.readClipboard())?.text, 'hi');
  expect(await h.writeClipboard(SessionCopy('image', path: '/x.png')), isFalse);
  expect(await h.chooseFiles(), isEmpty);
  expect([h.traceDir, h.detachChannel, h.supportsDetach], [null, null, false]);
});
```

`SessionCopy` 的构造参数名以 P1a 搬过来的为准（原 `LinuxCopy`）。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/debug_panel_test.dart test/embed/android_session_host_test.dart`
Expected: FAIL（文件不存在）

- [ ] **Step 3: 实现**

先抽 `main_mobile.dart` 并改 `main_ios.dart`（iOS 行为不变），再写 `main_android.dart`、`AndroidSessionHost`、`KeyLog`、`DebugPanel`。

- [ ] **Step 4: 跑，看它通过；iOS 入口没坏**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test; git checkout pubspec.lock`
Expected: 除已知三条外 PASS

再在模拟器 34 上走一遍：`scripts/build-android.sh debug`，装包、启动，App 停在接入引导（「输入 relay 和密钥」那一页），`adb logcat -d | /usr/bin/grep 'rapp:'` 里没有「hub 起不来」「embedded sessions unavailable」。

- [ ] **Step 5: 提交**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): Android entry over main_mobile; text clipboard host; 调试 panel with key log and frame rate"
```

### Task 10: 返回键、前后台、常亮、全屏和折叠、四边避让

**Files:**
- Create: `gui/lib/ui/back_step.dart`
- Modify: `gui/lib/ui/main_window.dart`（`MainWindow` 加 `Future<void> Function()? onBack`；有它时外面包 `PopScope`）、`gui/lib/ui/main_state.dart`（`composerOpen`、`closeComposer()`）、`gui/lib/main_mobile.dart`（把 `onBack` 交给 `MainWindow`）
- Test: `gui/test/ui/back_step_test.dart`、`gui/test/ui/fold_fullscreen_test.dart`

**Interfaces:**
- Consumes: Task 7 的 `MobileChannel.moveToBack`、`MobileFullscreen`；Task 9 的 `mainMobile(onBack:)`；`MainState` 现有的 `corner`、`panel`、`logs`、`overview`、`closeCorner()`、`closePanel()`、`closeLogs()`、`toggleOverview()`、`current`
- Produces:
  - `enum BackStep { closeCorner, closePanel, closeLogs, closeComposer, leaveFullscreen, toOverview, toSystem }`
  - `BackStep backStep({required bool corner, required bool panel, required bool logs, required bool composer, required bool fullscreen, required bool overview})`：按这个顺序取第一个成立的：`corner` → `panel` → `logs` → `composer` → `fullscreen` → `!overview`（`toOverview`）→ `toSystem`
  - `MainState.composerOpen`（台上会话的输入块开着）、`MainState.closeComposer()`（收起它；已收起不做事）
  - `MainWindow`：`onBack != null` 时 `PopScope(canPop: false, onPopInvokedWithResult: …)`，按 `backStep` 做对应的事；`toSystem` 调 `onBack`。`onBack` 为 null（桌面、iOS）时不包 `PopScope`，行为不变。`_esc` 不改（Esc 在全景里回会话，返回键在全景里退后台，两者不同是有意的）。

前后台、常亮、全屏和折叠不写新代码：`BackgroundWatch`、`MobileFullscreen`、`FoldFullscreen` 在 Task 7、9 已接到 `rapp/android`。这一任务给它们补安卓的测试，并在模拟器上看四个边。

- [ ] **Step 1: 写失败的测试**

```dart
test('backStep closes one layer at a time, then the overview, then the system', () {
  BackStep s({bool c = false, bool p = false, bool l = false, bool k = false, bool f = false, bool o = false}) =>
      backStep(corner: c, panel: p, logs: l, composer: k, fullscreen: f, overview: o);
  expect(s(c: true, p: true, k: true, f: true), BackStep.closeCorner);
  expect(s(p: true, k: true), BackStep.closePanel);
  expect(s(l: true, k: true), BackStep.closeLogs);
  expect(s(k: true, f: true), BackStep.closeComposer);
  expect(s(f: true), BackStep.leaveFullscreen);
  expect(s(), BackStep.toOverview);
  expect(s(o: true), BackStep.toSystem);
  expect(s(o: true, f: true), BackStep.leaveFullscreen);
});

testWidgets('back on the overview moves the app to the back', (t) async {
  var back = 0;
  // MainWindow(state: overview 为 true 的 MainState, onBack: () async => back++, fullscreen: NoFullscreen())
  await t.binding.handlePopRoute();
  expect(back, 1);
});

testWidgets('without onBack there is no PopScope', (t) async { expect(find.byType(PopScope), findsNothing); });

test('MobileFullscreen leaves and comes back with the window', () async {
  // FoldFullscreen(MobileFullscreen(AndroidChannel(假通道)))：want 为 true，2560×1600 → 全屏；
  // 窗口变成 500×1600（分屏）→ 发 fullscreen {on:false}；再变回 2560×1600 → 发 {on:true}
});
```

`MainWindow` 测试里造 `MainState` 用现有 `main_window` 测试的那套工具。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/back_step_test.dart test/ui/fold_fullscreen_test.dart`
Expected: FAIL（`backStep` 不存在；`onBack` 不存在）

- [ ] **Step 3: 按 Produces 实现**

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2，再跑全部 Flutter 测试和 `flutter analyze`，`git checkout gui/pubspec.lock`
Expected: 除已知三条外 PASS

- [ ] **Step 5: 模拟器上看四个边**

36 的 AVD 上用带刘海的配置（`adb shell cmd overlay enable com.android.internal.display.cutout.emulation.tall`，看完 `disable`），竖屏、横屏各截一张：顶栏不被状态栏和刘海压住，画面区不被手势条压住；全屏时系统栏藏起来，边缘滑一下暂时显出来。截图只放 scratchpad。

- [ ] **Step 6: 提交**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): Android back key closes one layer at a time, then leaves to the system"
```

### Task 11: 模拟器验收（34、36）

**Files:**
- Modify: `tasks/todo.md`（「安卓平板」一节记结果）

**Interfaces:**
- Consumes: Task 1–10 的全部
- Produces: 验收记录；本机 main 上的合并 `merge: 安卓平板 P1：能连、能看、能操作（feat/android-p1）`

每台模拟器从卸载开始（`adb uninstall com.rapphub.rapp`），`scripts/build-android.sh debug` 的同一个包。证据（截图、命令输出）只放 scratchpad；有 relay、密钥的东西不留。

- [ ] **Step 1: 逐项走（34 和 36 各一遍）**

| # | 做法 | 过的标准 |
|---|---|---|
| 1 | 装上、启动 | 停在接入引导 |
| 2 | 输入 relay 和密钥：`adb shell input text "$(jq -r .relay ~/rapp/local/service.json)"`，密钥同样（命令不回显值；`input text` 打不出某些字符时改用 P0 结果 §3 那段 `run-as` 合并 `service.json` 的做法，并在记录里写明） | 引导过去，回到全景 |
| 3 | 设备页按 ID 添加这台 Mac（ID 用 `jq -r .id ~/rapp/local/service.json`） | 全景里看到 Mac，在线 |
| 4 | 进单应用会话（「文本编辑」），点、拖窗口、选字 | 画面对，跟手 |
| 5 | 写作条里打一段中英文，回车 | 34、36 上回车是发送还是换行都记下来；文字到 Mac 上一个不少（`osascript` 读回来对照） |
| 6 | 外接键盘（`uinput` 虚拟键盘，P0 结果 §5 的做法）：Ctrl+C、Ctrl+V、Ctrl+Enter；看日志页「调试」区 | 「调试」里 `ctrl=1`；Ctrl 当 ⌘ 到 Mac；Ctrl+Enter 开写作版 |
| 7 | 鼠标：悬停、右键、滚轮 | 和 Linux 版一样 |
| 8 | 文字剪贴板：Mac 复制 → 安卓粘贴进写作条；安卓复制 → 会话里 Ctrl+V | 两边都到 |
| 9 | 只在需要时开一次桌面会话（规格 §14.2 写的是桌面会话；单应用会话已经覆盖点和打字，这一项只看画面能出来、能点一下，然后立刻结束） | 画面出来；结束后 Mac 没有被锁 |
| 10 | 开文本终端，打 `ls`，Ctrl+C | 有输出；终端里 Ctrl 是 Ctrl |
| 11 | 切到后台：`adb shell input keyevent HOME`，等 2 s，`adb shell run-as com.rapphub.rapp cat /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6`，只看本 App 的 uid（`adb shell dumpsys package com.rapphub.rapp \| /usr/bin/grep userId`） | 本 uid 一行都没有 |
| 12 | 切回来 | 自动重连，会话恢复，画面是活的 |
| 13 | 旋转（`adb shell settings put system user_rotation 1` 等）、分屏（最近任务里拉进分屏） | 不重建（`pidof` 不变）、不崩；窄到短边 < 600 时退出全屏，拉宽回来 |
| 14 | 返回键：开菜单 → 返回；开面板 → 返回；开输入块 → 返回；全屏 → 返回；会话里 → 返回；全景里 → 返回 | 每次恰好关一层；最后一次 App 退到后台，没有确认框 |
| 15 | 屏幕常亮：会话在台上时 `adb shell dumpsys power \| /usr/bin/grep -i wake` | 有 rApp 的 `FLAG_KEEP_SCREEN_ON`；回全景后没有 |
| 16 | P0 见过的毛病：让会话断开（Mac 上退出那个 app），在断开框里点「结束会话」 | 会话结束。不结束的话：先查是不是共用代码的问题（在 macOS 或 Linux 上同样做一遍），按 systematic-debugging 找原因，修在本分支并加一条测试；修不了就写进 `tasks/todo.md` 并告诉用户 |
| 17 | 系统返回手势和画面区边缘拖动的冲突（§8.1） | 记下来，不修 |

- [ ] **Step 2: 门禁、待办、合并**

1. `git merge main`；跑 Global Constraints 里的整套 Mac 门禁（含 iOS 模拟器那条）。
2. `tasks/todo.md`「安卓平板」：第一段改成「P1 已合（日期），模拟器 34、36 验收结果：…」；第 5、16、17 项的结果各一行；Task 12 的实机清单写进「未经实机验证」。提交 `docs(todo): 安卓 P1 模拟器验收`。
3. 本机 main 上 `git merge --no-ff feat/android-p1 -m "merge: 安卓平板 P1：能连、能看、能操作（feat/android-p1）"`。不推、不打 tag。发版 session 会看到共用代码的改动，照常发 macOS 版，这不用管。

任何一项不过：不合并，停下来告诉用户哪一项、证据在 scratchpad 哪里。

### Task 12: 实机清单（等用户）

用户在荣耀平板（HONOR ROD2-W09，Android 16，MagicOS 10，配蓝牙 MISTEL 键盘和鼠标）上用 P1 第一个包做。编号同规格 §14.6；第 5、7、10、13 条（语音、更新）P1 包里没有对应的东西，留到 P2、P3 的包。

**Files:**
- Modify: `tasks/todo.md`（「未经实机验证」：补 1、2、3、4、6；8、9、11、12、14、15 保留；10、13 后面加「P1 包里没有，等 P3 / P2」）

**Interfaces:**
- Consumes: Task 11 合并后的调试包
- Produces: 给用户的清单（下面原样发）

- [ ] **Step 1: 装包**

平板用 USB 连上 Mac、`adb devices` 看得到时：`adb -s <平板> install -r gui/build/app/outputs/flutter-apk/app-debug.apk`（荣耀会弹「USB 安装」确认，用户点）。连不上就记进 `tasks/todo.md`，等能连再装。装包之前用 AskUserQuestion 告诉用户要装、要他点确认。

- [ ] **Step 2: 把这份清单发给用户（AskUserQuestion 之外的正文），做完的结果由用户回来说**

接入：打开 rApp → 输入 relay 和密钥 →「设备」里按 ID 添加你的 Mac。以下都开**单应用会话**（比如「文本编辑」）；第 1 条要看视频时再开桌面会话，看完就结束。

| # | 做什么 | 看什么 |
|---|---|---|
| 9（先做，一分钟） | 接上蓝牙键盘。打开「日志」，最上面是「调试」。按 Ctrl+C、Ctrl+V | 「调试」里出现 `down C ctrl=1` 和 `down V ctrl=1`。是 `ctrl=0` 或者没有这两行，先停下，把那几行发给我 |
| 1 | 原生分辨率下拖窗口、滚网页、放一段视频 | 「调试」里的「画面 N 帧/秒」拖动和滚动时不低于 30；点下去到画面动，和 iPad 比没有感觉得出的慢 |
| 12 | 同上，但把这台平板换到另一个网络（比如手机热点），让它只能走中转 | 帧数记下来 |
| 2 | 连着一个会话半小时 | 背面烫不烫，电量掉了多少 |
| 3 | 触摸：点、双击、长按、拖、双指滚、捏合；从屏幕左右边缘往里划 | 都和 iPad 一样；边缘划的时候是返回还是拖了画面，记下来 |
| 4、14 | 真键盘：在会话里按 Ctrl+C/V/X/Z/A/T/W/Tab/空格/Enter；在写作条里按 Ctrl+空格、单按字母、Ctrl+C/V | 「调试」里每个键有没有、`ctrl=` 是几；写作条里字有没有出来。没到的键列出来 |
| 11 | 用真键盘和软键盘各在写作条里打一段（中英文混着），发出去 | 到 Mac 上一个字不少 |
| 9（后半） | 有触控板的话（这台机器现在没有，可以跳过）：双指滚动、捏合 | 画面跟着滚、跟着缩放 |
| 6 | 前台开着会话放 10 分钟不碰（屏幕常亮会开着） | 会话没断、没卡住；MagicOS 有没有弹「耗电过高」之类 |
| 8 | 在有全局 IPv6 的网络、只有 IPv6 的网络（NAT64）下各连一次 | 都连得上 |
| 15 | 把 relay 写成域名再连一次（需要我先帮你在 App 里改的话告诉我） | 连得上 |

- [ ] **Step 3: 提交待办**

```bash
git add tasks/todo.md
git commit -m "docs(todo): 安卓 P1 实机清单"
```

（这一步在 Task 11 合并前做的话，跟着那次合并进 main；合并后再做，就在本机 main 上单独提交这一个文档改动。）

## 待用户定的（不在本计划里做，列着以免漏掉）

- 建议 1：荣耀的三层安装确认，界面上怎么提示（P3）。
- 建议 2：语音按下去 3 s 没有回调就当失败（P2）。
- 建议 3：「装完会回到桌面」的提示（P3）。

## Self-review（写完后自查，已就地改过）

- 规格覆盖：§14.2 第 2 条 → Task 3（crate）、6（工程、`build-android.sh debug`）、7（`AndroidChannel` 基本方法）、8（能力表和 §6.5 清单）、9（`main_android.dart`）；第 3 条 → 接入引导和 iPad 精简「本机」页靠 `caps.hubInProcess`、`!caps.hasService` 直接走 iPad 那支（Task 8 表里 `main_window.dart:142`、Task 7 的 `ios_local_section`），验收在 Task 11 第 1–3 项；第 4 条 → Task 9–10 和 Task 11 的 4–15 项。§6.4 清单设置 → Task 6；§6.6 落脚处、追踪不开 → Task 9 的 `AndroidSessionHost`；§7 返回键 → Task 10；§8.3 键码规矩沿用 P1a 的 `hidMacKeyCode`，验收 Task 11 第 6 项；§9 → Task 7、10、11；§12 的不进备份、只放行回环 → Task 6。§14.3 已在 P1a。§14.6 → Task 12。
- 不在 P1 的（语音、更新、P2 各项、内存警告事件）没有任务，Global Constraints 里写了。
- 类型一致：`MobileChannel`、`MobileNet`、`MobilePaths`、`AndroidChannel`、`MobileFullscreen`、`BackgroundWatch(channel:)`、`FfiSessionLinks(library)`、`SessionNative`、`AndroidSessionHost(root)`、`KeyLog`、`DebugPanel(keys:, frames:)`、`framesShown`、`backStep`、`BackStep`、`mainMobile(onBack:)` 在各任务里写法一致。
- 比例：代码块是接口、测试断言和命令；函数体留给实施者，只有 `KeyLog` 的行格式写死（实机清单按它读）。
