# 安卓平板 P1b：安卓工程 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 安卓平板上装得上的 rApp 调试包，能接入、在全景里看到设备，进桌面会话、单应用会话和文本终端，触摸、外接键盘、鼠标、文字剪贴板、前后台、返回键、常亮、全屏和折叠都和 iPad 一样，并在模拟器 34、36 上验收；最后给用户一份在荣耀平板上做的实机清单。

**Architecture:** 一个 `.so`（`rust/android-ffi`，库名 `rapp_android`）里放进程内 hub（`rapp-hub-ffi` 的四个函数）和会话库（`rapp_client_core::session` 的五个函数）。Dart 侧 hub 走现有的 `FfiHubTransport`（加一个库名参数），会话走 P1a 的 `WorkerSessionPort`，通路换成 `FfiSessionLinks`、宿主换成 `AndroidSessionHost`。外壳照 iPad：`main_ios.dart` 的共用部分抽进 `main_mobile.dart`，`rapp/android` 通道和 `rapp/ios` 对齐成一个 `MobileChannel` 接口；排版不为安卓写，写死 iOS 的判断按 §6.5 逐处改成能力位或 `touchPlatform`。

**Tech Stack:** Rust（`cargo ndk`、NDK 28.2.13676358）、Flutter/Dart（`dart:ffi`、`NativeCallable`、`fake_async`）、Kotlin（Flutter 的 Android 模板）、Gradle（openjdk@21）。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`（§6.2–§6.6、§7–§10、§12、§14.2 第 2–4 条和验收、§14.6）；`docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md`；前置计划 `docs/superpowers/plans/2026-11-27-rapp-android-p1a-shared-refactor.md`。

**前置条件：** `feat/android-p1` 从 `refactor/session-port`（`cab34ce3`）开，P1a 还没合进 main（等 Linux 回归）。P1b 可以做完、验收，但 P1a 合进 main 之前不合并（Task 11）。

## Global Constraints

- 分支 `feat/android-p1`，worktree `.worktrees/android-p1`，从 `cab34ce3` 开（已建好）。
- 每个 shell 先带这三行（工具里每次调用的 shell 是新的，每条命令前都要有）：
  ```bash
  export ANDROID_HOME=$HOME/Library/Android/sdk
  export PATH=$HOME/.cargo/bin:$PATH
  adb=$ANDROID_HOME/platform-tools/adb
  ```
  adb 一律是 `$ANDROID_HOME/platform-tools/adb`（命令里写 `"$adb"`），不用 PATH 上 Homebrew 的那个：两个版本的 adb 会互相杀掉对方的服务。`cargo` 靠第二行找到（`cargo ndk` 也要它找 `cargo-ndk`）；`flutter` 照旧写全路径 `~/development/flutter/bin/flutter`。
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
  cd rust && ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358 cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi
  ```
  产物拷到 `gui/android/app/src/main/jniLibs/arm64-v8a/`（不进 git）。
- 模拟器：AVD `rapp-p0-34`、`rapp-p0-36`。用 Bash 工具的 `run_in_background` 起（不用 `&`）：`"$ANDROID_HOME/emulator/emulator" -avd rapp-p0-34 -no-snapshot -no-boot-anim`。冷启动要等开完机再装：`"$adb" wait-for-device shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done'`。装包、启动：`"$adb" install -r gui/build/app/outputs/flutter-apk/app-debug.apk; "$adb" shell am start -n com.rapphub.rapp/.MainActivity`。
- Mac 门禁（合并前跑全；动了 `rust/hub-ffi` 再加最后一条；`cargo` 要上面的 `PATH` 那行）：
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

1. **会话库里 Rust 出了 panic**：App 不闪退；那个会话恰好结束一次，显示断开；`send` 返回 -3。hub 的 panic 同样不越过 C 边界。→ Task 3 的 `a_panicking_session_ends_with_kind_2_once`、`send_that_panics_answers_minus_3`；Task 2 的 `start_that_panics_answers_minus_4`、`send_that_panics_answers_minus_4`。
2. **画面来得比 Dart 画得快**：一次只有一帧在路上，内存不涨。→ Task 3 的 `gate_holds_the_next_packet_until_ack`（不睡、不靠计时：等 `Gate::wait_until_blocked`）和 Task 5 的 `'ack reaches the library once per call'`。
3. **open 还没返回，第一个包已经到了；或者开到一半就关**：包不丢；结束恰好一次；`NativeCallable` 只在 kind 2 之后关（open 返回 0 时当场关）。→ Task 5 的 `'a packet before open returns is kept'`、`'close before the first send ends at once with -1 and closes packets'`、`'kill that never sees kind 2 keeps the callable open'`、`'kind 2 after the kill timeout still releases the callable once'`。
4. **返回键**：每按一次恰好关一层（菜单、面板、日志、输入块、全屏），会话里回全景，全景里退到后台，不弹「再按一次退出」。弹出的菜单是 Navigator 的路由，返回键先把它弹掉，轮不到 `PopScope`，所以 `backStep` 里没有菜单这一层。→ Task 10 的 `backStep` 表格测试和 `'back on the overview moves the app to the back'`。
5. **分屏、小窗把窗口缩到短边 < 600，再拉宽**：按窗口尺寸排版，退出全屏，拉宽后回到全屏，不重建、不崩。→ Task 10 的 `'MobileFullscreen leaves and comes back with the window'` 和 Task 11 的旋转、分屏两项。

---

### Task 1: iPad 和 Linux 的差别表（规格附录）

动手前先列（§6.3、§15.2 第 17 条）。只写文档，不改代码。

**Files:**
- Modify: `docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`（末尾加「附录 A：iPad 和 Linux 端口的差别」）

**Interfaces:**
- Consumes: `gui/lib/embed/session_port.dart` 的 `ChannelSessionPort`（iPad 的端口）和 P1a 的 `WorkerSessionPort`、`LinuxSessionHost`
- Produces: 附录 A 的表；Task 8、Task 9 的 `AndroidSessionHost` 按它取值

- [ ] **Step 1: 分支已建好，带上 main 的文档提交**

worktree `.worktrees/android-p1`、分支 `feat/android-p1` 已经在 `cab34ce3`。不 rebase、不重建，只把 main 合进来（带上 main 比它多的文档提交，比如 83ede3fe、3d199bec）。两条命令分开跑，不用管道接（管道会盖住合并失败）：

```bash
git -C /Users/bruce/git/rapp/.worktrees/android-p1 merge main
git -C /Users/bruce/git/rapp/.worktrees/android-p1 status --short | /usr/bin/grep '^UU'
```

第二条什么也不打印才往下走；打印了就是有冲突，停下来解决。

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

表下面再写一段「`gui/lib/` 里新加的 `Platform.isAndroid`」：只有一处，`main.dart` 里 `if (Platform.isIOS) return mainIos();` 下面的 `if (Platform.isAndroid) return mainAndroid();`（Task 9）。它是按平台分入口的那一行，是规格 §2.3「不加 `Platform.isAndroid`」唯一的例外；其他安卓的差别走能力位（Task 8）或由 `main_android.dart` 设进去（全局 `mobileChannel = channel`、参数 `prepareDataDir(..., chmod: false)`）。

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
- Produces: `rapp_hub_start` 和 `rapp_hub_send` 出 panic 时返回 `-4`；`rapp_hub_stop`、`rapp_hub_free_line` 出 panic 时什么也不做。正常返回值（0、-1、-2、-3）不变。iOS 的 Dart 把非 0 都当失败；-4 的文字在 Task 4 改成「hub 内部出错」。

- [ ] **Step 1: 写失败的测试**（`hub-ffi` 的 `mod tests`；已有的 `FORCE_PANIC` 是 hub 任务里的 panic，这里要的是函数体本身的 panic）

`lib.rs` 里（测试模块外）加：

```rust
/// Tests: the next C entry point that checks it panics in its own body (one-shot).
#[cfg(test)]
static PANIC_IN_CALL: AtomicBool = AtomicBool::new(false);
```

`rapp_hub_start`、`rapp_hub_send` 的函数体开头（拿 `HUB` 锁之前）检查它：`#[cfg(test)] if PANIC_IN_CALL.swap(false, Ordering::SeqCst) { panic!("forced panic in the call") }`。`swap` 是一次性的：panic 之后标志已经清掉，后面的调用照常走。

测试（`TEST_LOCK`、`start`、`send` 是测试模块里现成的，`start(home)` 内部按 `(home, log_dir, name, on_line)` 调 `rapp_hub_start`）：

```rust
#[test]
fn start_that_panics_answers_minus_4() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let home = tempfile::tempdir().unwrap();
    PANIC_IN_CALL.store(true, Ordering::SeqCst);
    assert_eq!(start(home.path()), -4);
    assert!(HUB.lock().unwrap_or_else(|e| e.into_inner()).is_none(), "nothing started");
    assert_eq!(start(home.path()), 0, "the flag is one-shot: the next start works");
    rapp_hub_stop();
}

#[test]
fn send_that_panics_answers_minus_4() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    PANIC_IN_CALL.store(true, Ordering::SeqCst);
    // No hub is running: the panic comes before the HUB lock, so it is -4, not -1.
    assert_eq!(send(r#"{"cmd":"hosts"}"#), -4);
    assert_eq!(send(r#"{"cmd":"hosts"}"#), -1, "then the usual answer");
}
```

- [ ] **Step 2: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-hub-ffi`
Expected: 编译失败（`PANIC_IN_CALL` 没定义）。只定义标志、还没包 `catch_unwind` 时，测试进程因 panic 越过 `extern "C"` 而中止。

- [ ] **Step 3: 实现**

四个函数体包进 `catch_unwind(AssertUnwindSafe(..)).unwrap_or(fallback)`（和 `android-ffi` 的 `guard` 同一个写法）；`PANIC_IN_CALL` 的检查放在包起来的那段里面、`HUB` 锁之前。`rapp_hub.h` 两处返回值说明加「-4 内部出错（panic），没有启动 / 没有发出」。`quic.rs:268` 的「Only the iOS hub uses them」改成「Only the in-process hub (iOS, Android) uses them」。

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
- Cargo：包名 `rapp-android-ffi`，`[lib] name = "rapp_android"`，`crate-type = ["cdylib"]`；依赖只有 `rapp-hub-ffi`、`rapp-client-core`、`libc`，dev 依赖 `flate2`，都写在 `[target.'cfg(not(windows))'.dependencies]` / `[target.'cfg(not(windows))'.dev-dependencies]` 下：Windows 门禁编 workspace 时这个 crate 什么也不带进来
- 追踪：P1 不调 `trace_to`（§6.6 追踪不开），`AndroidSessionHost.traceDir` 为 null。`trace_to` 是进程里先调先得的 `OnceLock`，P2 要开时由入口第一个调

- [ ] **Step 1: 取探查版做起点**

```bash
git show cfd7997e:rust/android-ffi/Cargo.toml > rust/android-ffi/Cargo.toml
git show cfd7997e:rust/android-ffi/src/lib.rs > rust/android-ffi/src/lib.rs
```

删掉：`rapp_p0_resolve`、`anyhow_text`（只有它用）和测试 `p0_resolve_gives_getaddrinfo_v6_then_the_dual_address`（连同它的 `resolve`）；Cargo.toml 里的 `serde_json`、`rapp-net`、`tokio` 和「Probe」注释，剩下的依赖挪到 `[target.'cfg(not(windows))'.…]` 下（见 Interfaces）。整个文件内容放进文件头的 `#![cfg(not(windows))]`（和依赖的 cfg 一起，Windows 上这个 crate 是空的）。保留：`Gate`、`Body`、`GateWriter`、`Lines`、`Session`、`guard`，测试里的 `GOT`、`record`、`got`、`wait_count`、`packet`、`tiny_frame`、`ready`、`fake_a`、`open`、`story`、`has`、`wait_end`，和四条测试（`gate_holds_the_next_packet_until_ack`、`close_releases_a_writer_stuck_on_the_gate` 按 Step 2 改，`session_over_loopback_ends_with_kind_2_exactly_once`、`close_on_an_unacked_frame_still_ends_with_kind_2_once` 原样，只在开头加 `TEST_LOCK`）。不另写 sink 或启动参数的工具函数。

- [ ] **Step 2: 写失败的测试**

测试要的钩子（`#[cfg(test)]`，写在库代码里，Step 4 实现；测试模块外）：

```rust
/// Tests: the next `rapp_session_open` starts a session thread that panics before `serve` (one-shot).
#[cfg(test)]
static PANIC_IN_SESSION: AtomicBool = AtomicBool::new(false);
/// Tests: the next `rapp_session_send` panics in its own body (one-shot).
#[cfg(test)]
static PANIC_IN_CALL: AtomicBool = AtomicBool::new(false);

// Gate gets one field, `#[cfg(test)] waiting: AtomicUsize` (writers stuck on Shut), and
impl Gate {
    /// Tests: true once a writer waits on the shut gate, within `limit`. No sleeping: it waits on `wake`.
    #[cfg(test)]
    fn wait_until_blocked(&self, limit: Duration) -> bool {
        let s = lock(&self.state);
        let (_s, r) = self
            .wake
            .wait_timeout_while(s, limit, |_| self.waiting.load(Ordering::SeqCst) == 0)
            .unwrap_or_else(|e| e.into_inner());
        !r.timed_out()
    }
}
```

`pass` 里，拿着 `state` 锁、发现是 `Shut` 时：`#[cfg(test)]` 先 `waiting += 1` 再 `wake.notify_all()`，`while` 等完之后 `waiting -= 1`。加减都在 `state` 锁里做，`wait_until_blocked` 也在这把锁里看，不会漏掉唤醒；写者被这次 `notify_all` 吵醒也没关系，`while` 会让它接着等。

测试模块开头加锁（和 hub-ffi 一样）：所有调 `rapp_session_open` 或 `rapp_session_send` 的测试第一行都拿它，两个全局标志才不会落到别的测试的会话上。

```rust
/// Serialises the tests that open sessions or send: PANIC_IN_SESSION and PANIC_IN_CALL are process-wide.
static TEST_LOCK: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}
```

`session_over_loopback_ends_with_kind_2_exactly_once`、`close_on_an_unacked_frame_still_ends_with_kind_2_once` 第一行加 `let _g = serial();`。探查版的两条闸门测试改成不睡（ID 各用自己的，不和会话的号撞）：

```rust
#[test]
fn gate_holds_the_next_packet_until_ack() {
    const ID: u64 = 1_000_001;
    let gate = Arc::new(Gate::new());
    let mut w = GateWriter::new(ID, record, gate.clone());
    let a = br#"{"event":"a"}"#;
    let f = [7u8; 24 + 4];
    let b = br#"{"event":"b"}"#;
    let all = [packet(0, a), packet(1, &f), packet(0, b)].concat();
    // Odd write sizes: the writer frames packets itself.
    let t = std::thread::spawn(move || -> std::io::Result<()> {
        for chunk in all.chunks(5) {
            w.write_all(chunk)?;
        }
        Ok(())
    });
    assert!(gate.wait_until_blocked(Duration::from_secs(5)), "b waits on the shut gate");
    assert_eq!(got(ID), vec![(0, [&[0u8][..], a].concat()), (1, [&[1u8][..], &f].concat())]);
    gate.open();
    assert!(wait_count(ID, 3, Duration::from_secs(5)), "b after the ack");
    assert_eq!(got(ID)[2], (0, [&[0u8][..], b].concat()));
    t.join().unwrap().unwrap();
}

#[test]
fn close_releases_a_writer_stuck_on_the_gate() {
    const ID: u64 = 1_000_002;
    let gate = Arc::new(Gate::new());
    let mut w = GateWriter::new(ID, record, gate.clone());
    let (done, result) = mpsc::channel();
    std::thread::spawn(move || {
        let r = w.write_all(&packet(1, &[9u8; 28])).and_then(|()| w.write_all(&packet(0, b"{}")));
        done.send(r).unwrap();
    });
    assert!(gate.wait_until_blocked(Duration::from_secs(5)), "the event waits on the gate");
    assert_eq!(got(ID).len(), 1, "the frame went");
    assert!(result.try_recv().is_err(), "the writer is still stuck");
    gate.close();
    let r = result.recv_timeout(Duration::from_secs(5)).expect("released");
    assert_eq!(r.unwrap_err().kind(), std::io::ErrorKind::BrokenPipe);
    assert_eq!(got(ID).len(), 1, "nothing after the frame");
}
```

新的四条：

```rust
#[test]
fn a_panicking_session_ends_with_kind_2_once() {
    let _g = serial();
    PANIC_IN_SESSION.store(true, Ordering::SeqCst);
    // Port 1: nothing listens there, but the thread panics before it would connect.
    let id = open(1);
    assert_ne!(id, 0);
    assert!(wait_end(id, Duration::from_secs(5)), "kind 2 after the panic");
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(got(id), vec![(2, Vec::new())], "no event before it: serve never ran");
    assert_eq!(rapp_session_send(id, c"{}".as_ptr()), -1, "gone from the table");
}

#[test]
fn send_that_panics_answers_minus_3() {
    let _g = serial();
    PANIC_IN_CALL.store(true, Ordering::SeqCst);
    // No such session either: the panic comes before the table lookup, so it is -3, not -1.
    assert_eq!(rapp_session_send(999_999, c"{}".as_ptr()), -3);
    assert_eq!(rapp_session_send(999_999, c"{}".as_ptr()), -1, "the flag is one-shot");
}

#[test]
fn send_to_no_session_answers_minus_1() {
    let _g = serial();
    assert_eq!(rapp_session_send(999_999, c"{}".as_ptr()), -1);
    // -2 (not UTF-8) needs a live session: it is in close_on_an_unacked_frame_still_ends_with_kind_2_once.
}

/// 这条钉住 P1a 终审第 11 条：关输入（丢掉 `Lines` 的发送端）就是 EOF，`serve` 的读线程随之 `shutdown`，
/// 空闲的会话（A 不说话、没有帧在路上）也在 2 s 内结束。
#[test]
fn close_on_an_idle_session_ends_with_kind_2_within_2_s() {
    let _g = serial();
    let (port, a) = fake_a();
    let id = open(port);
    assert_ne!(id, 0);
    let mut a = a.recv_timeout(Duration::from_secs(10)).expect("connected");
    let mut z = flate2::Compress::new(flate2::Compression::fast(), true);
    a.write_all(&ready()).unwrap();
    a.write_all(&tiny_frame(&mut z, true, 1)).unwrap();
    let end = Instant::now() + Duration::from_secs(10);
    while story(id).len() < 2 && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(story(id).len(), 2, "ready and the frame");
    rapp_session_ack(id);
    // A stays connected and silent: only closing the input can end this session.
    let started = Instant::now();
    rapp_session_close(id);
    assert!(started.elapsed() < Duration::from_millis(2500), "close waits at most 2 s");
    assert!(wait_end(id, Duration::from_millis(2500)), "kind 2 within 2.5 s of the close");
    std::thread::sleep(Duration::from_millis(300));
    let all = got(id);
    assert_eq!(all.iter().filter(|g| g.0 == 2).count(), 1);
    assert_eq!(all.last().unwrap().0, 2, "kind 2 is the last callback");
    drop(a);
}
```

（`got`、`wait_end`、`open`、`story` 都是探查版现成的；`open(port)` 发的启动参数是 `{"cmd":"start","sid":"s1","port":…,"token":"t",…}`。）

- [ ] **Step 3: 跑，看它失败**

Run: `cd rust && cargo test -p rapp-android-ffi`
Expected: 测试编不过（`PANIC_IN_SESSION`、`PANIC_IN_CALL`、`Gate::wait_until_blocked` 没定义）

- [ ] **Step 4: 实现**

- 两个标志都是一次性的、同步读：`rapp_session_open` 在起线程之前 `let boom = PANIC_IN_SESSION.swap(false, Ordering::SeqCst);`（`#[cfg(test)]`；非测试时 `let boom = false;`），把 `boom` 移进线程，线程里 `catch_unwind` 包着的那段开头 `if boom { panic!("forced panic before serve") }`，再 `session::serve(lines, writer)`。`rapp_session_send` 的 `guard` 里第一件事 `#[cfg(test)] if PANIC_IN_CALL.swap(false, Ordering::SeqCst) { panic!("forced panic in the call") }`，在查表之前。
- `rapp_session_send` 的 `guard` 兜底值从 -1 改成 -3。
- `Gate` 加 `#[cfg(test)] waiting` 字段（`Gate::new` 里同样 `#[cfg(test)]` 初始化）、`pass` 里的加减和 `wait_until_blocked`，照 Step 2。
- 会话线程：panic 之后先 `gate.end()`，再从表里删，再调 sink 的 kind 2；写线程在 `end()` 之后不再调 sink（探查版已是这个顺序，测试把它钉住）。
- 文件头和 `rapp_session_open`、`rapp_session_close` 的文档写明两点：sink 可能在 `rapp_session_open` 返回之前就被调（调用方不能靠返回的 id 分发）；`close` 最多等 2 s，kind 2 可能在它返回之后才来。

- [ ] **Step 5: 跑，看它通过**

Run: `cd rust && cargo test -p rapp-android-ffi && cargo clippy --workspace --all-targets -- -D warnings`
Expected: PASS

- [ ] **Step 6: 交叉编译，查导出表和对齐**

```bash
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$HOME/.cargo/bin:$PATH
cd rust && ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358 cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi
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
  - `@visibleForTesting String hubStartError(int rc)`、`@visibleForTesting String hubSendError(int rc)`：把 `start`、`send` 里现成的两个 `switch` 抽成纯函数，`HubException` 的文字从这里来。新加一种：-4 → `'hub 内部出错（-4）'`（Task 2 的 panic）。其余照旧：start 的 -1 `'hub 已经在运行'`、-2 `'hub 的参数不对'`、其他 `'hub 起不来（$rc）'`；send 的 -1、-3 `'hub 已退出'`、其他 `'hub 不收这一行（$rc）'`

- [ ] **Step 1: 写失败的测试**

```dart
test('start names a missing library in its error', () {
  expect(() => FfiHubTransport.start(home: '/x', logDir: '/x', name: 'n', library: 'librapp_nope.so'),
      throwsA(predicate((e) => '$e'.contains('librapp_nope.so'))));
});

test('-4 from start or send reads as an internal error', () {
  expect(hubStartError(-4), 'hub 内部出错（-4）');
  expect(hubSendError(-4), 'hub 内部出错（-4）');
  expect(hubStartError(-1), 'hub 已经在运行');
  expect(hubSendError(-1), 'hub 已退出');
  expect(hubSendError(-9), 'hub 不收这一行（-9）');
});
```

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/hub_ffi_test.dart`
Expected: FAIL（没有 `library` 参数，没有 `hubStartError`、`hubSendError`）

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
/// 库交来的一个包：kind 0 事件、1 帧（[packet] 是整个管道格式的包，首字节就是 kind，已经是 Dart 自己的内存），
/// kind 2 结束（[packet] 为 null）。
typedef SessionSink = void Function(int kind, Uint8List? packet);

/// C 函数的 Dart 一层；测试换成假的。
abstract class SessionNative {
  /// 返回 0：失败（之后不会调 [sink]）。[sink] 可能在 open 返回之前就被调。
  int open(String start, SessionSink sink);
  int send(int id, String line); // 0、-1、-2、-3，同 rapp_session_send
  void ack(int id);
  /// 在 Isolate.run 里调 rapp_session_close（会阻塞最多 2 s）。同一个 id 第二次是空操作。
  Future<void> close(int id);
  /// 关掉为 [sink] 建的 NativeCallable。每次 [open] 恰好配一次，由 link 调（见下）。
  void release(SessionSink sink);
}

class FfiSessionLinks implements SessionLinks {
  FfiSessionLinks(String library, {SessionNative? native});
}

class FfiSessionLink implements SessionLink {
  FfiSessionLink(SessionNative native);
}
```

- `FfiSessionLinks.check()`：打不开库就抛 `StateError('session library not found: $library')`；`open()` 返回一个还没开的 `FfiSessionLink`。
- **第一次 `send(line)` 才开会话**：那一行就是启动参数，传给 `native.open`；之后的 `send` 走 `native.send`。link 里存一个 `late final SessionSink _sink = _onPacket;`，open 和 release 用的是同一个对象。
- `open` 返回 0：当场 `native.release(_sink)`，包流关、`inputDone` 完成、`exitCode` 完成为 -1。
- `send` 的返回值：0 照常；-1 什么也不做（会话正在结束，kind 2 在路上）；-2、-3 让 `inputDone` 带 `StateError('session send failed: $rc')` 完成（端口因此显示「session worker stopped」），会话本身照旧等 kind 2。
- 真的 `SessionNative`（`_LibSessionNative`）每次 open 建一个 `NativeCallable<SinkC>.listener`，不靠 id 分发。监听函数里：kind 0、1 先 `Uint8List.fromList(ptr.asTypedList(len))` 拷一份，**马上** `rapp_session_free(ptr)`，和 ack 无关（端口在 ack 之后还留着最后一帧，`lastNativeFrame`，内存必须是 Dart 的），再交给 sink；kind 2 交 null。`release(sink)` 找到那个 `NativeCallable` 并 `close()`。
- kind 2：取消 kill 的计时器；包流关，`exitCode` 完成为 0，`inputDone` 完成；然后 `native.release(_sink)`。
- 每次 `open` 恰好一次 `release`：open 返回 0 时当场，否则在 kind 2 之后。kind 2 一直不来就永远不 release（关了 `NativeCallable` 库里再调会崩）。
- `exitCode`、`inputDone` 和关包流，每处都先查 `isCompleted` / `isClosed`：先到的那个说了算，后到的什么也不改。
- `ack()`：已开（id 非 0）就 `native.ack(id)`，kind 2 之后也照调（库里查不到就是空操作，SessionLink 约定「close 之后的 ack 无害」）；没开过不做。
- `close()`：没开过就当场结束：包流关、`inputDone` 完成、`exitCode` -1，不碰 native；之后的 `send` 什么也不做。开过就 `await native.close(id)`，结束仍等 kind 2。
- `kill()`：没开过同 `close()`。开过就 `unawaited(native.close(id))`，再起一个 3 s 的计时器：到时候 kind 2 还没来，`exitCode` -1、`inputDone` 完成、包流关（不 release）。之后再来的 kind 2 只 release 一次，`exitCode` 不变。
- 端口先 `close()`、2 s 后再 `kill()`：`native.close` 会调两次，第二次在库里是空操作（表里已删）。
- `id`：开之前 0，之后是库给的号。

- [ ] **Step 1: 写失败的测试**（全部用 `FakeNative`，`fake_async` 控时间）

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_ffi.dart';

class FakeNative implements SessionNative {
  final opened = <String>[];
  final sent = <(int, String)>[];
  final acks = <int>[];
  final closed = <int>[];
  var released = 0;
  var openResult = 7;
  var sendResult = 0;
  /// Packets delivered from inside open, before it returns.
  List<(int, Uint8List?)> early = const [];
  SessionSink? sink;

  @override
  int open(String start, SessionSink sink) {
    opened.add(start);
    this.sink = sink;
    for (final (k, p) in early) {
      sink(k, p);
    }
    return openResult;
  }

  @override
  int send(int id, String line) {
    sent.add((id, line));
    return sendResult;
  }

  @override
  void ack(int id) => acks.add(id);

  @override
  Future<void> close(int id) async => closed.add(id);

  @override
  void release(SessionSink sink) {
    expect(sink, same(this.sink), reason: 'the sink given to open');
    released++;
  }
}

Uint8List event(String json) => Uint8List.fromList([0, ...json.codeUnits]);

void main() {
  late FakeNative native;
  late FfiSessionLink link;
  setUp(() {
    native = FakeNative();
    link = FfiSessionLink(native);
  });

  test('the first send opens with that line, later ones go to send', () {
    expect(link.id, 0);
    link.send('{"start":1}');
    link.send('{"cmd":"x"}');
    expect(native.opened, ['{"start":1}']);
    expect(native.sent, [(7, '{"cmd":"x"}')]);
    expect(link.id, 7);
  });

  test('a packet before open returns is kept', () async {
    native.early = [(0, event('{"event":"ready"}'))];
    final got = <Uint8List>[];
    link.packets.listen(got.add);
    link.send('{"start":1}');
    await pumpEventQueue();
    expect(got.single, event('{"event":"ready"}'));
  });

  test('kind 2 ends the link once and only then releases the callable', () async {
    link.send('{"start":1}');
    native.sink!(0, event('{}'));
    expect(native.released, 0);
    native.sink!(2, null);
    expect(await link.exitCode, 0);
    await link.inputDone;
    expect(await link.packets.toList(), hasLength(1));
    expect(native.released, 1);
  });

  test('ack reaches the library once per call', () {
    link.send('{"start":1}');
    link.ack();
    link.ack();
    expect(native.acks, [7, 7]);
  });

  test('ack before open does nothing', () {
    link.ack();
    expect(native.acks, isEmpty);
  });

  test('ack after kind 2 still goes to the library and is harmless', () async {
    link.send('{"start":1}');
    native.sink!(2, null);
    expect(await link.exitCode, 0);
    link.ack();
    expect(native.acks, [7]);
    expect(native.released, 1);
  });

  test('close before the first send ends at once with -1 and closes packets', () async {
    final drained = link.packets.drain<void>();
    await link.close();
    await drained;
    expect(await link.exitCode, -1);
    await link.inputDone;
    link.kill();
    link.send('{"start":1}');
    expect(native.opened, isEmpty);
    expect(native.closed, isEmpty);
    expect(native.released, 0);
  });

  test('open that fails ends with -1 and releases the callable at once', () async {
    native.openResult = 0;
    final drained = link.packets.drain<void>();
    link.send('{"start":1}');
    await drained;
    expect(await link.exitCode, -1);
    await link.inputDone;
    expect(native.released, 1);
  });

  test('send that answers -3 ends input with an error', () async {
    link.send('{"start":1}');
    native.sendResult = -3;
    link.send('{"cmd":"x"}');
    await expectLater(link.inputDone, throwsA(isA<StateError>()));
  });

  test('send that answers -1 does nothing', () async {
    link.send('{"start":1}');
    native.sendResult = -1;
    link.send('{"cmd":"x"}');
    var done = false;
    unawaited(link.inputDone.then((_) => done = true, onError: (_) => done = true));
    await pumpEventQueue();
    expect(done, isFalse, reason: 'kind 2 is what ends it');
  });

  test('kill that never sees kind 2 keeps the callable open', () {
    fakeAsync((t) {
      int? code;
      link.send('{"start":1}');
      link.exitCode.then((c) => code = c);
      link.kill();
      t.elapse(const Duration(milliseconds: 2900));
      expect(code, isNull);
      t.elapse(const Duration(milliseconds: 100));
      expect(code, -1);
      expect(native.closed, [7]);
      expect(native.released, 0);
    });
  });

  test('kind 2 after the kill timeout still releases the callable once', () {
    fakeAsync((t) {
      int? code;
      link.send('{"start":1}');
      link.exitCode.then((c) => code = c);
      link.kill();
      t.elapse(const Duration(seconds: 3));
      native.sink!(2, null);
      t.flushMicrotasks();
      expect(code, -1, reason: 'the first answer stays');
      expect(native.released, 1);
    });
  });

  test('close then kill closes in the library twice; kind 2 still ends it with 0', () {
    fakeAsync((t) {
      int? code;
      link.send('{"start":1}');
      link.exitCode.then((c) => code = c);
      link.close();
      t.elapse(const Duration(seconds: 2));
      link.kill();
      t.flushMicrotasks();
      expect(native.closed, [7, 7]);
      native.sink!(2, null);
      t.elapse(const Duration(seconds: 5));
      expect(code, 0, reason: 'kind 2 came before the kill timeout');
      expect(native.released, 1);
    });
  });

  test('check names a missing library', () async {
    await expectLater(
      FfiSessionLinks('librapp_nope.so').check(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('librapp_nope.so'))),
    );
  });
}
```

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

清单：两个权限（`INTERNET`、`ACCESS_NETWORK_STATE`）；删掉探查版的 `RECORD_AUDIO`、`REQUEST_INSTALL_PACKAGES` 和 `android.speech.RecognitionService` 那条 `<queries>`（`PROCESS_TEXT` 那条留着）；`android:label="rApp"`；`<application android:allowBackup="false" android:dataExtractionRules="@xml/data_extraction_rules" android:networkSecurityConfig="@xml/network_security_config">`；Activity `android:resizeableActivity="true"`、不锁方向、`configChanges` 用模板的整套。`data_extraction_rules.xml` 的 `cloud-backup` 和 `device-transfer` 都 `<exclude domain="root" path="."/>`（以及 `file`、`database`、`sharedpref`、`external` 各一条）。网络配置只给 `localhost`、`127.0.0.1` 放行明文。`app/build.gradle.kts`：`minSdk = 34`，`compileSdk`、`targetSdk` 用 Flutter 默认（36），`ndk { abiFilters += "arm64-v8a" }`，`versionName`/`versionCode` 从 pubspec 来（模板默认）。

- [ ] **Step 3: 写 `scripts/build-android.sh`**

照 `git show cfd7997e:scripts/p0-android-so.sh` 的变量写法，加上 Produces 里的查表、编包、还原。`set -euo pipefail`，路径都从 `$(dirname "$0")/..` 算。

- [ ] **Step 4: 编出来，装到模拟器上能起**

先编（每条命令前都带 Global Constraints 的三行）：

```bash
bash -n scripts/build-android.sh && scripts/build-android.sh debug
```

再用 Bash 工具的 `run_in_background` 起模拟器（不要写 `&`）：

```bash
export ANDROID_HOME=$HOME/Library/Android/sdk
"$ANDROID_HOME/emulator/emulator" -avd rapp-p0-34 -no-snapshot -no-boot-anim
```

等它开完机（`wait-for-device` 在冷启动时会比包管理服务先返回，直接装会报「Can't find service: package」），再装、起、查：

```bash
export ANDROID_HOME=$HOME/Library/Android/sdk
adb=$ANDROID_HOME/platform-tools/adb
"$adb" wait-for-device shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done'
"$adb" install -r gui/build/app/outputs/flutter-apk/app-debug.apk
"$adb" shell am start -n com.rapphub.rapp/.MainActivity
unzip -l gui/build/app/outputs/flutter-apk/app-debug.apk | /usr/bin/grep librapp_android.so
"$adb" shell pidof com.rapphub.rapp
"$adb" shell dumpsys package com.rapphub.rapp | /usr/bin/grep -E 'minSdk|targetSdk|ALLOW_BACKUP'
```

Expected: 脚本最后一行是 APK 路径；App 起来（这时 `main.dart` 还没有安卓入口，走桌面那支会报错或空白，这一步只看进程活着：`pidof` 有输出）；包里有 `lib/arm64-v8a/librapp_android.so`；`dumpsys` 那条是 34、36，flags 里没有 `ALLOW_BACKUP`。

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
- Test: `gui/test/android_channel_test.dart`；改 `gui/test/ui/background_test.dart`、`gui/test/ios_channel_test.dart`、`gui/test/ui/fold_fullscreen_test.dart`

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
/// 共用代码用的那一个。默认是 iOS 的；main_android.dart 第一件事把它换成 AndroidChannel（Task 9）。
MobileChannel mobileChannel = iosChannel;
```

`mobile_channel.dart` 里不出现 `Platform.isAndroid`（规格 §2.3）：哪个平台用哪个通道由入口决定。

`IosChannel` 的 `idiom`、`share` 留在它自己身上，不进接口。`AndroidChannel.net()` 不调原生，直接 `const MobileNet(ok: true)`；`sessionActive`、`beginBackground`、`endBackground` 不调原生，直接完成（§9.1）。

Kotlin 那边（`MainActivity.configureFlutterEngine` 里开 `rapp/android`），P1 只实现：

| 方法 | 做法 |
|---|---|
| `paths` | `{"files": filesDir.absolutePath, "cache": cacheDir.absolutePath}` |
| `deviceName` | `Settings.Global.DEVICE_NAME`，空就 `Build.MODEL` |
| `version` | `packageManager.getPackageInfo(packageName, 0).versionName`：一个 `x.y.z` 字符串，不带构建号，和 iOS 的 `CFBundleShortVersionString` 同一个样子（规格 §6.4 已按此改） |
| `openSettings` | `ACTION_APPLICATION_DETAILS_SETTINGS`，`package:` 本包 |
| `keepAwake` | 主线程上加、去 `FLAG_KEEP_SCREEN_ON`（参数 `on`） |
| `fullscreen` | `WindowInsetsControllerCompat`：`on` 时 `hide(systemBars())` + `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`，否则 `show(systemBars())` |
| `openUrl` | `ACTION_VIEW`；没有能打开的 App 就 `result.error("no_app", …)` |
| `moveToBack` | `moveTaskToBack(true)` |
| 事件 `pathChanged` | `registerDefaultNetworkCallback` 的 `onAvailable`、`onLost` 里在主线程 `invokeMethod("pathChanged", null)`；`onDestroy` 注销 |

其他方法 `result.notImplemented()`。

- [ ] **Step 1: 写失败的测试**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/android_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android');
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<(String, Object?)> calls;
  late AndroidChannel ch;
  setUp(() {
    calls = [];
    m.setMockMethodCallHandler(channel, (c) async {
      calls.add((c.method, c.arguments));
      return c.method == 'paths' ? {'files': '/data/f', 'cache': '/data/c'} : null;
    });
    ch = AndroidChannel(channel);
  });
  tearDown(() => m.setMockMethodCallHandler(channel, null));

  test('paths gives the data root under filesDir', () async {
    expect((await ch.paths()).dataRoot, '/data/f/rapp');
  });

  test('net is always ok and never asks the platform', () async {
    expect((await ch.net()).ok, isTrue);
    expect(calls, isEmpty);
  });

  test('keepAwake, fullscreen, openUrl and moveToBack go over the channel', () async {
    await ch.keepAwake(true);
    await ch.fullscreen(false);
    await ch.openUrl('https://a');
    await ch.moveToBack();
    expect(calls, [
      ('keepAwake', {'on': true}),
      ('fullscreen', {'on': false}),
      ('openUrl', {'url': 'https://a'}),
      ('moveToBack', null),
    ]);
  });

  test('sessionActive and the background calls stay on the Dart side', () async {
    await ch.sessionActive(true);
    await ch.beginBackground();
    await ch.endBackground();
    expect(calls, isEmpty);
  });

  test('pathChanged from the platform arrives on events', () async {
    final first = ch.events.first;
    await m.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('pathChanged')),
      (_) {},
    );
    expect(await first, 'pathChanged');
  });
}
```

`background_test.dart`、`fold_fullscreen_test.dart` 里构造 `BackgroundWatch(ios: …)`、`IosFullscreen(…)` 的地方换成新名字，并各加一条用 `AndroidChannel` 的：`'BackgroundWatch keeps the screen awake over rapp/android'`（会话上台后 `keepAwake {on: true}` 发到 `rapp/android`）。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/android_channel_test.dart test/ui/background_test.dart test/ios_channel_test.dart test/ui/fold_fullscreen_test.dart`
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
- Test: `gui/test/platform_caps_test.dart`、`gui/test/data_dir_test.dart`，以及下表「测试」一列点名的现有测试文件

**Interfaces:**
- Consumes: Task 7 的 `mobileChannel`
- Produces:
  - `enum SecretStore { none, memory, keychain }`；`PlatformCaps` 加 `final SecretStore secretStore`（默认 `none`）、`final bool systemLinks`（链接走 `mobileChannel.openUrl`；默认 false）、`final bool opensFolders`（有地方打开一个文件夹；默认 true）
  - `forOs`：`'ios'` 加 `secretStore: keychain, systemLinks: true`；`'android' => PlatformCaps(hubInProcess: true, secretStore: SecretStore.memory, systemLinks: true, opensFolders: false)`；`'linux'` 单列一支（桌面那一整套 + `secretStore: memory`）；`'macos'` 和兜底那支 `secretStore: keychain`（兜底原来也是 macOS 用）；`'windows'` 不变（`none`）
  - `pinchZoom`、`hardwareKeyboard()` 改认 `touchPlatform(defaultTargetPlatform)`（`ui/tokens.dart:312`，已经含安卓）
  - `bool prepareDataDir(String root, String? legacy, {bool chmod = true})`：每次调用都把库内私有的 `_noChmod` 设成 `!chmod`；`_chmod` 开头 `if (_noChmod) return;`，所以之后的 `writePrivate`、`copyLocalIfMissing` 也跟着不 `chmod`。安卓的入口传 `chmod: false`（Task 9；沙盒管权限，安卓上也不该起 `chmod` 进程）；iOS 和桌面不传，行为不变（iOS 照旧由 `_chmod` 里现成的 `Platform.isIOS` 跳过）

`onlineUpdate` 在安卓上 P1 先不开（规格 §6.5 已按此改；用户已同意 P1 不带解锁口令落盘、发文件和 App 内更新，分别在 P2、P2、P3 补，2026-11-27）：它的两处用法读的是 `ServiceMonitor`，安卓走不到；P3 做更新界面时再开。`systemOpen` 留 false（规格原话）。

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
| `embed/key_bar.dart:428` | iOS、mac 的键面字体（`CupertinoSystemText`） | 保持（安卓走下一行已有的那支 Roboto，§10 系统字体） | — |
| `term/term_stage.dart:51` | `systemOpen` 时走 `iosChannel.openUrl` | 改 `caps.systemLinks` → `mobileChannel.openUrl`；其余分支不变 | `term_stage` 新测试：android 的 caps 下链接发到 `rapp/android` 的 `openUrl` |
| `pages/local_section.dart:43` | 同上（安装页） | 同上 | — |
| `pages/data_section.dart:54` | 打开文件夹 | `!caps.opensFolders` 时不显示那个按钮 | — |
| `pages/app_profile_page.dart:445` | iOS 才有「常用语条」开关 | 改 `touchPlatform` | — |
| `pages/app_profile_page.dart:455` | 内置输入法开关 | 保持 | — |
| `pages/ios_local_section.dart:74` | `iosChannel.version` | Task 7 已改 `mobileChannel.version` | — |
| `main.dart:42` | iOS 入口 | Task 9 加 `if (Platform.isAndroid) return mainAndroid();`，附录 A 记为唯一新加的 `Platform.isAndroid` | — |
| `data_dir.dart:205` | Windows、iOS 不 `chmod` | 不加 `Platform.isAndroid`（规格 §2.3）：`prepareDataDir(..., chmod: false)` 由安卓入口传（见 Produces） | `data_dir_test`：`chmod: false` 时 `local` 不是 700，之后默认调用又是 700 |

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

// lastHardwareKey 是全局的：先清掉，再用「现在」比，前面的测试收到过键也不影响。
// variant 负责设、还原目标平台，expect 失败也不会漏到后面的测试。
testWidgets('android counts as touch for pinch and the hardware keyboard', (t) async {
  lastHardwareKey = null;
  expect(pinchZoom, isTrue);
  expect(hardwareKeyboard(now: DateTime.now()), isFalse, reason: 'no key seen');
}, variant: TargetPlatformVariant.only(TargetPlatform.android));
```

`data_dir_test.dart`（用文件里现成的 `tmp`、`mode`）：

```dart
test('chmod: false leaves local alone; the next default call chmods again', () {
  final b = '${tmp.path}/b';
  prepareDataDir(b, null, chmod: false);
  expect(Directory('$b/local').existsSync(), isTrue);
  expect(mode('$b/local'), isNot('700'));
  final a = '${tmp.path}/a';
  prepareDataDir(a, null);
  expect(mode('$a/local'), '700', reason: 'each call sets the flag again');
});
```

加上表里「测试」一列的那几条。

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/platform_caps_test.dart test/data_dir_test.dart`
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
- Create: `gui/lib/ui/debug_panel.dart`（`KeyLog`、`DebugPanel`、`CountingFrameSink`）
- Modify: `gui/lib/main_ios.dart`（只留 iOS 的差别）、`gui/lib/main.dart:42`、`gui/lib/ui/log_screen.dart`（可选参数 `Widget? top`）、`gui/lib/ui/main_window.dart`（`MainWindow({Widget? debugPanel})`，传给日志页）。不改 `gui/lib/embed/worker_session_port.dart`（P1a 等 Linux 回归的那一片）
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
      bool chmodData = true,                                // 安卓传 false，交给 prepareDataDir(chmod:)
    })
    ```
    身体就是现在 `mainIos()` 去掉三处 iOS 专属（`idiom`、`RimeLocalIme`、`RimeGlue`）后的样子，`iosChannel` 换成 `channel`，`IosFullscreen()` 换成 `MobileFullscreen(channel)`，`_IosApp` 改名 `_MobileApp`，`_waitForNetwork` 收 `channel`；`prepareDataDir(root, null)` 改成 `prepareDataDir(root, null, chmod: chmodData)`；`debugPanel` 造好后交给 `MainWindow(debugPanel:)`。
  - `main_ios.dart`：`mainIos()` 取 `idiom` 后调 `mainMobile(channel: iosChannel, os: 'ios', log: stderr 那个, hub: …FfiHubTransport.start(home:, logDir:, name:), port: …ChannelSessionPort, localIme: RimeLocalIme(RappRime.instance), localOs: () => localDeviceOs(iosIdiom: idiom), rime: RimeGlue.new)`
  - `main_android.dart`：`Future<void> mainAndroid()`，开头：
    ```dart
    final channel = AndroidChannel();
    mobileChannel = channel;            // 共用代码从这以后用 rapp/android（Task 7）
    final frames = CountingFrameSink();
    final keyLog = KeyLog()..install();
    ```
    然后 `mainMobile(channel: channel, os: 'android', ...)`：`log` 是 `debugPrint('rapp: $s')`；`hub` 是 `FfiHubTransport.start(..., library: 'librapp_android.so')`；`port` 是
    ```dart
    (data, root) async {
      final p = WorkerSessionPort(FfiSessionLinks('librapp_android.so'), AndroidSessionHost(root), sink: frames);
      return (p, Duration(milliseconds: await p.init()));
    }
    ```
    `localIme: NoLocalIme()`；`localOs: () => localDeviceOs(os: 'android', shortestSide: <窗口短边，逻辑点>)`（`device_os.dart:37` 已有这两个参数）；`debugPanel: (s) => DebugPanel(keys: keyLog, frames: () => frames.count)`；`onBack: channel.moveToBack`；`chmodData: false`
  - `main.dart:42`（`if (Platform.isIOS) return mainIos();`）下面加 `if (Platform.isAndroid) return mainAndroid();`。这是附录 A 记下的唯一新加的 `Platform.isAndroid`
  - `class AndroidSessionHost implements SessionHost { AndroidSessionHost(String root); }`：
    - `init(onDetachCall)` 什么也不做（没有分离窗口）
    - `downloads()` 是 `'$root/files/transfers'`
    - `readClipboard()` 只读 Flutter `Clipboard` 的文字：`Clipboard.getData(Clipboard.kTextPlain)?.text`，有就 `SessionCopy('text', text: t, uti: 'public.utf8-plain-text')`，没有返回 null
    - `writeClipboard(copy)`：`kind == 'text'` 且 `text` 非空时 `Clipboard.setData(ClipboardData(text: copy.text!))` 返回 true；其他返回 false
    - 这两步照抄 `LinuxSessionHost` 的文字退路（同一个 `uti`），不抽共用函数：抽出来就要改 `linux_session_host.dart`，那是 P1a 等 Linux 回归的一片
    - `reveal` 返回 false、`chooseFiles` 返回空（传文件是 P2）；`traceDir` null；`detachChannel` null；`supportsDetach` false；`supportsInlineNativeComposer` 按 Task 1 附录 A 取（预期 false，同 iPad）
  - `class CountingFrameSink implements FrameSink { CountingFrameSink([FrameSink inner = const ImageFrameSink()]); int get count; }`：`decode` 先 `count++` 再交给 `inner`，`retire` 直接交给 `inner`。端口每做一张图调一次 `decode`，所以 `count` 就是做成图片的帧累计数，只增不减
  - ```dart
    class KeyLog extends ChangeNotifier {
      KeyLog({int keep = 30});
      void install();                    // HardwareKeyboard.instance.addHandler，只看不拦（返回 false）
      void uninstall();                  // removeHandler；测试里 addTearDown(log.uninstall)
      List<String> get lines;            // 新的在前
    }
    ```
    每行格式（定死，实机清单照它读）：`'${kind} ${logicalKey.keyLabel.isEmpty ? logicalKey.debugName : logicalKey.keyLabel} ctrl=${c} meta=${m} alt=${a} shift=${s}'`，`kind` 是 `down`/`up`/`repeat`，四个修饰键取事件那一刻的 `HardwareKeyboard.instance.isControlPressed` 等，写 `1`/`0`。
  - `class DebugPanel extends StatefulWidget { const DebugPanel({super.key, required KeyLog keys, required int Function() frames}); }`：标题「调试」；第一行「画面 N 帧/秒」，一开始是 0；`initState` 记下 `frames()` 当基数，起 `Timer.periodic(1 s)`，每次取 `frames()` 和上次的差、`setState`；同时监听 `keys`（`addListener`）。`dispose` 取消计时器、去掉监听。下面是 `KeyLog.lines`，等宽字。放在日志页最上面（`MainWindow` 把 `debugPanel` 交给 `LogScreen(top:)`）。

- [ ] **Step 1: 写失败的测试**

`gui/test/ui/debug_panel_test.dart`：

```dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/frame_sink.dart';
import 'package:rapp/ui/debug_panel.dart';

class _Inner implements FrameSink {
  final decoded = <(int, int)>[];
  final retired = <ui.Image?>[];
  @override
  Future<ui.Image> decode(Uint8List bgra, int width, int height) {
    decoded.add((width, height));
    return Completer<ui.Image>().future; // never needed here
  }

  @override
  void retire(ui.Image? image) => retired.add(image);
}

void main() {
  testWidgets('the key log shows Ctrl held with C', (t) async {
    final log = KeyLog()..install();
    addTearDown(log.uninstall);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: DebugPanel(keys: log, frames: () => 0))));
    await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await simulateKeyDownEvent(LogicalKeyboardKey.keyC);
    await t.pump();
    expect(find.text('down C ctrl=1 meta=0 alt=0 shift=0'), findsOneWidget);
    // Let go, so no key stays pressed for the next test.
    await simulateKeyUpEvent(LogicalKeyboardKey.keyC);
    await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
  });

  testWidgets('frames per second comes from the counter', (t) async {
    var n = 0;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: DebugPanel(keys: KeyLog(), frames: () => n))));
    expect(find.text('画面 0 帧/秒'), findsOneWidget);
    n += 24;
    await t.pump(const Duration(seconds: 1));
    expect(find.text('画面 24 帧/秒'), findsOneWidget);
    n += 10;
    await t.pump(const Duration(seconds: 1));
    expect(find.text('画面 10 帧/秒'), findsOneWidget, reason: 'the difference, not the total');
  });

  test('CountingFrameSink counts each decode and hands it on', () {
    final inner = _Inner();
    final s = CountingFrameSink(inner);
    expect(s.count, 0);
    unawaited(s.decode(Uint8List(4), 1, 1));
    unawaited(s.decode(Uint8List(8), 2, 1));
    s.retire(null);
    expect(s.count, 2);
    expect(inner.decoded, [(1, 1), (2, 1)]);
    expect(inner.retired, [null]);
  });
}
```

`gui/test/embed/android_session_host_test.dart`（剪贴板的假处理器照 `linux_session_host_test.dart`）：

```dart
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/android_session_host.dart';
import 'package:rapp/embed/session_copy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AndroidSessionHost keeps text on the Flutter clipboard and has no files yet', () async {
    String? board;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          board = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return board == null ? null : {'text': board};
      }
      return null;
    });
    addTearDown(() => m.setMockMethodCallHandler(SystemChannels.platform, null));

    final h = AndroidSessionHost('/r');
    await h.init((_) async => null);
    expect(h.downloads(), '/r/files/transfers');
    expect(await h.readClipboard(), isNull, reason: 'nothing on the clipboard yet');
    expect(await h.writeClipboard(const SessionCopy('text', text: 'hi')), isTrue);
    final copy = await h.readClipboard();
    expect([copy?.kind, copy?.text, copy?.uti], ['text', 'hi', 'public.utf8-plain-text']);
    expect(await h.writeClipboard(SessionCopy('image', bytes: Uint8List(1), uti: 'public.png')), isFalse);
    expect(board, 'hi', reason: 'the image did not replace the text');
    expect(await h.reveal('/r/files/transfers/a.txt'), isFalse);
    expect(await h.chooseFiles(), isEmpty);
    expect([h.traceDir, h.detachChannel, h.supportsDetach, h.supportsInlineNativeComposer], [null, null, false, false]);
  });
}
```

（`supportsInlineNativeComposer` 的 `false` 以附录 A 为准；附录 A 定了 true 就改这一处。）

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/debug_panel_test.dart test/embed/android_session_host_test.dart`
Expected: FAIL（文件不存在）

- [ ] **Step 3: 实现**

先抽 `main_mobile.dart` 并改 `main_ios.dart`（iOS 行为不变），再写 `main_android.dart`、`AndroidSessionHost`、`KeyLog`、`DebugPanel`。

- [ ] **Step 4: 跑，看它通过；iOS 入口没坏**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test; git checkout pubspec.lock`
Expected: 除已知三条外 PASS

再在模拟器 34 上走一遍：`scripts/build-android.sh debug`，装包、启动，App 停在接入引导（「输入 relay 和密钥」那一页），`"$adb" logcat -d | /usr/bin/grep 'rapp:'`（`adb` 变量见文件头的环境那段）里没有「hub 起不来」「embedded sessions unavailable」。

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
  - `BackStep backStep({required bool corner, required bool panel, required bool logs, required bool composer, required bool fullscreen, required bool overview})`：按这个顺序取第一个成立的：`corner` → `panel` → `logs` → `composer` → `fullscreen` → `!overview`（`toOverview`）→ `toSystem`。`MainState.corner`、`panel` 是可空的（`Corner?`、`PanelTab?`），传 `corner: s.corner != null`、`panel: s.panel != null`
  - 弹出菜单（`showMenu`、下拉）是 Navigator 的路由，返回键先把它们弹掉，轮不到 `PopScope`，所以 `backStep` 里没有「关菜单」这一步；Task 11 第 14 项的「开菜单 → 返回」靠的就是这个
  - `MainState.composerOpen`（台上会话的输入块开着）、`MainState.closeComposer()`（收起它；已收起不做事）
  - `MainWindow`：`onBack != null` 时 `PopScope(canPop: false, onPopInvokedWithResult: …)`，按 `backStep` 做对应的事；`toSystem` 调 `onBack`。`onBack` 为 null（桌面、iOS）时不包 `PopScope`，行为不变。`PopScope` 要在 `ModalRoute` 底下才收得到返回键（`MaterialApp(home: …)` 里就是）。`_esc` 不改（Esc 在全景里回会话，返回键在全景里退后台，两者不同是有意的）。

前后台、常亮、全屏和折叠不写新代码：`BackgroundWatch`、`MobileFullscreen`、`FoldFullscreen` 在 Task 7、9 已接到 `rapp/android`。这一任务给它们补安卓的测试，并在模拟器上看四个边。

- [ ] **Step 1: 写失败的测试**

`gui/test/ui/back_step_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/back_step.dart';
import 'package:rapp/ui/fullscreen.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
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

// The same MainState as main_window_test.dart, on the overview.
MainState overviewState() {
  final tmp = Directory.systemTemp.createTempSync('back_step_test');
  final s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs())..overview = true;
  addTearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });
  return s;
}

testWidgets('back on the overview moves the app to the back', (t) async {
  var back = 0;
  // wrap() is MaterialApp(home: …), so MainWindow sits under a ModalRoute and PopScope gets the back key.
  await t.pumpWidget(wrap(
    MainWindow(
      state: overviewState(),
      monitor: null,
      control: null,
      fullscreen: const NoFullscreen(),
      onBack: () async => back++,
    ),
    disableAnimations: true,
  ));
  await t.pump();
  await t.binding.handlePopRoute();
  await t.pump();
  expect(back, 1);
});

testWidgets('without onBack there is no PopScope', (t) async {
  await t.pumpWidget(wrap(
    MainWindow(state: overviewState(), monitor: null, control: null, fullscreen: const NoFullscreen()),
    disableAnimations: true,
  ));
  await t.pump();
  expect(find.byWidgetPredicate((w) => w is PopScope), findsNothing);
});
}
```

`gui/test/ui/fold_fullscreen_test.dart` 里加一条（文件现有的 `_Fake` 测试不动；新加的 import 是 `package:flutter/services.dart`、`package:rapp/android_channel.dart`）：

```dart
test('MobileFullscreen leaves and comes back with the window', () async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rapp/android');
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <(String, Object?)>[];
  m.setMockMethodCallHandler(channel, (c) async {
    calls.add((c.method, c.arguments));
    return null;
  });
  addTearDown(() => m.setMockMethodCallHandler(channel, null));

  final fs = FoldFullscreen(MobileFullscreen(AndroidChannel(channel)));
  await fs.start(want: true, size: const Size(2560, 1600));
  expect(calls, [('fullscreen', {'on': true})]);
  await fs.windowSize(const Size(500, 1600)); // split screen: short side under 600
  expect(calls.last, ('fullscreen', {'on': false}));
  await fs.windowSize(const Size(2560, 1600));
  expect(calls.last, ('fullscreen', {'on': true}));
  expect(calls, hasLength(3));
});
```

（`TestWidgetsFlutterBinding.ensureInitialized()` 放进这个文件的 `main()` 开头也行。）

- [ ] **Step 2: 跑，看它失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/back_step_test.dart test/ui/fold_fullscreen_test.dart`
Expected: FAIL（`backStep` 不存在；`onBack` 不存在）

- [ ] **Step 3: 按 Produces 实现**

- [ ] **Step 4: 跑，看它通过**

Run: 同 Step 2，再跑全部 Flutter 测试和 `flutter analyze`，`git checkout gui/pubspec.lock`
Expected: 除已知三条外 PASS

- [ ] **Step 5: 模拟器上看四个边**

36 的 AVD 上用带刘海的配置（`"$adb" shell cmd overlay enable com.android.internal.display.cutout.emulation.tall`，看完 `disable`；`adb` 变量见文件头的环境那段），竖屏、横屏各截一张：顶栏不被状态栏和刘海压住，画面区不被手势条压住；全屏时系统栏藏起来，边缘滑一下暂时显出来。截图只放 scratchpad。

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
- Produces: 验收记录；P1a（`cab34ce3`）已在 main 里时，本机 main 上的合并 `merge: 安卓平板 P1：能连、能看、能操作（feat/android-p1）`；不在时只有待办里的一行，不合并（Step 2）

每台模拟器从卸载开始（`"$adb" uninstall com.rapphub.rapp`；`adb` 变量见文件头的环境那段，下表里的 `"$adb"` 都是它，有两台模拟器同时开时加 `-s emulator-5554` 这样的序号），`scripts/build-android.sh debug` 的同一个包。证据（截图、命令输出）只放 scratchpad；有 relay、密钥的东西不留。relay 和密钥只走管道，不进命令行参数、不进输出（第 2 项）。

- [ ] **Step 1: 逐项走（34 和 36 各一遍）**

| # | 做法 | 过的标准 |
|---|---|---|
| 1 | 装上、启动 | 停在接入引导 |
| 2 | 填 relay 和密钥：不用 `input text`（值会进 adb 的参数，设备上的 shell 还会再拆一遍、报错时把片段打出来）。走 P0 结果 §3 的 `run-as` 合并 `service.json`，值只走管道，输出全丢掉；第 1 项启动过一次、`service.json` 已经有了再做。命令见表下 | 最后一条命令打印 `true`；重新启动 App，引导过去，回到全景 |
| 3 | 设备页按 ID 添加这台 Mac（ID 用 `jq -r .id ~/rapp/local/service.json`） | 全景里看到 Mac，在线 |
| 4 | 进单应用会话（「文本编辑」），点、拖窗口、选字 | 画面对，跟手 |
| 5 | 写作条里打一段中英文，回车 | 34、36 上回车是发送还是换行都记下来；文字到 Mac 上一个不少（`osascript` 读回来对照） |
| 6 | 外接键盘（`uinput` 虚拟键盘，P0 结果 §5 的做法）：Ctrl+C、Ctrl+V、Ctrl+Enter；看日志页「调试」区 | 「调试」里 `ctrl=1`；Ctrl 当 ⌘ 到 Mac；Ctrl+Enter 开写作版 |
| 7 | 鼠标：悬停、右键、滚轮 | 和 Linux 版一样 |
| 8 | 文字剪贴板：Mac 复制 → 安卓粘贴进写作条；安卓复制 → 会话里 Ctrl+V | 两边都到 |
| 9 | 只开一次桌面会话（规格 §14.2 写的是桌面会话；单应用会话已经覆盖点和打字，这一项只看画面能出来、能点一下，然后立刻结束；用户已同意这样做，2026-11-27） | 画面出来；结束后 Mac 没有被锁 |
| 10 | 开文本终端，打 `ls`，Ctrl+C | 有输出；终端里 Ctrl 是 Ctrl |
| 11 | 切到后台：`"$adb" shell input keyevent HOME`，等 2 s，`"$adb" shell run-as com.rapphub.rapp cat /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6`，只看本 App 的 uid（`"$adb" shell dumpsys package com.rapphub.rapp \| /usr/bin/grep userId`） | 本 uid 一行都没有 |
| 12 | 切回来 | 自动重连，会话恢复，画面是活的 |
| 13 | 旋转（`"$adb" shell settings put system user_rotation 1` 等）、分屏（最近任务里拉进分屏） | 不重建（`pidof` 不变）、不崩；窄到短边 < 600 时退出全屏，拉宽回来 |
| 14 | 返回键：开菜单 → 返回；开面板 → 返回；开输入块 → 返回；全屏 → 返回；会话里 → 返回；全景里 → 返回 | 每次恰好关一层；最后一次 App 退到后台，没有确认框 |
| 15 | 屏幕常亮：会话在台上时 `"$adb" shell dumpsys power \| /usr/bin/grep -i wake` | 有 rApp 的 `FLAG_KEEP_SCREEN_ON`；回全景后没有 |
| 16 | P0 见过的毛病：让会话断开（Mac 上退出那个 app），在断开框里点「结束会话」 | 会话结束。不结束的话：先查是不是共用代码的问题（在 macOS 或 Linux 上同样做一遍），按 systematic-debugging 找原因，修在本分支并加一条测试；修不了就写进 `tasks/todo.md` 并告诉用户 |
| 17 | 系统返回手势和画面区边缘拖动的冲突（§8.1） | 记下来，不修 |

第 2 项的命令（照抄，不加 `echo`、不加 `-x`；`$f` 只是路径，没有秘密）：

```bash
f=/data/user/0/com.rapphub.rapp/files/rapp/local/service.json
"$adb" shell am force-stop com.rapphub.rapp
{ "$adb" exec-out run-as com.rapphub.rapp cat "$f"; jq '{relay, key}' ~/rapp/local/service.json; } \
  | jq -s '.[0] * .[1]' \
  | "$adb" shell "run-as com.rapphub.rapp sh -c 'cat > $f'" >/dev/null 2>&1
"$adb" exec-out run-as com.rapphub.rapp cat "$f" | jq 'has("relay") and has("key")'
```

最后一条只打印 `true`/`false`，不打印值。打印 `false` 或 `jq` 报错：看 P0 结果 §3 里 `service.json` 的实际路径和字段名，改上面的 `f` 或字段名再来，不要把文件内容打出来看。

- [ ] **Step 2: 门禁、待办、合并**

1. 先查 P1a 合了没有：`git -C /Users/bruce/git/rapp merge-base --is-ancestor cab34ce3 main && echo in-main || echo not-in-main`。
2. `git merge main`；跑 Global Constraints 里的整套 Mac 门禁（含 iOS 模拟器那条）。
3. `tasks/todo.md`「安卓平板」：第一段按第 1 步的结果写，只写真的事：
   - `in-main`：「P1 已合（日期），模拟器 34、36 验收结果：…」
   - `not-in-main`：「P1 验收过，未合（等 P1a）。P1b 验收过，等 P1a 合并后再合（feat/android-p1 @ <`git rev-parse --short HEAD` 的值>）。模拟器 34、36 验收结果：…」

   第 5、16、17 项的结果各一行；Task 12 的实机清单写进「未经实机验证」。提交 `docs(todo): 安卓 P1 模拟器验收`。
4. 只有第 1 步是 `in-main` 才合：本机 main 上 `git merge --no-ff feat/android-p1 -m "merge: 安卓平板 P1：能连、能看、能操作（feat/android-p1）"`。不推、不打 tag。发版 session 会看到共用代码的改动，照常发 macOS 版，这不用管。
5. `not-in-main`：不合并（合了就会把还没过 Linux 回归的 P1a 一起带进 main，发版 session 会把它发出去）。分支留着，告诉用户「P1b 验收过，等 P1a 合并后再合」和分支的提交号。P1a 合进 main 以后，从第 1 步重来。

任何一项不过：不合并，停下来告诉用户哪一项、证据在 scratchpad 哪里。

### Task 12: 实机清单（等用户）

用户在荣耀平板（HONOR ROD2-W09，Android 16，MagicOS 10，配蓝牙 MISTEL 键盘和鼠标）上用 P1 第一个包做。编号同规格 §14.6；第 5、7、10、13 条（语音、更新）P1 包里没有对应的东西，留到 P2、P3 的包。

**Files:**
- Modify: `tasks/todo.md`（「未经实机验证」：补 1、2、3、4、6；8、9、11、12、14、15 保留；10、13 后面加「P1 包里没有，等 P3 / P2」）

**Interfaces:**
- Consumes: Task 11 验收过的调试包（合没合进 main 都一样）
- Produces: 给用户的清单（下面原样发）

- [ ] **Step 1: 装包**

平板用 USB 连上 Mac 时，序号只放进变量，不打印：

```bash
s=$("$adb" devices | awk 'NR>1 && $2=="device" && $1 !~ /^emulator-/ {print $1}')
[ -n "$s" ] && echo tablet-found || echo no-tablet
"$adb" -s "$s" install -r gui/build/app/outputs/flutter-apk/app-debug.apk
```

命令里只写 `-s "$s"`；不 `echo "$s"`，序号不写进待办、提交和 scratchpad，也不跑会把它打出来的 `"$adb" devices`（要看就用上面第二行）。荣耀会弹「USB 安装」确认，用户点。`no-tablet` 就记进 `tasks/todo.md`，等能连再装。装包之前用 AskUserQuestion 告诉用户要装、要他点确认。

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

（这一步在 `feat/android-p1` 上提交，跟着 Task 11 的合并进 main；Task 11 已经合过了，就在本机 main 上单独提交这一个文档改动；P1a 还没合、Task 11 没合并时，留在分支上，等那次合并一起进。）

## 待用户定的（不在本计划里做，列着以免漏掉）

- 建议 1：荣耀的三层安装确认，界面上怎么提示（P3）。
- 建议 2：语音按下去 3 s 没有回调就当失败（P2）。
- 建议 3：「装完会回到桌面」的提示（P3）。

## Self-review（写完后自查，已就地改过）

- 规格覆盖：§14.2 第 2 条 → Task 3（crate）、6（工程、`build-android.sh debug`）、7（`AndroidChannel` 基本方法）、8（能力表和 §6.5 清单）、9（`main_android.dart`）；第 3 条 → 接入引导和 iPad 精简「本机」页靠 `caps.hubInProcess`、`!caps.hasService` 直接走 iPad 那支（Task 8 表里 `main_window.dart:142`、Task 7 的 `ios_local_section`），验收在 Task 11 第 1–3 项；第 4 条 → Task 9–10 和 Task 11 的 4–15 项。§6.4 清单设置 → Task 6；§6.6 落脚处、追踪不开 → Task 9 的 `AndroidSessionHost`；§7 返回键 → Task 10；§8.3 键码规矩沿用 P1a 的 `hidMacKeyCode`，验收 Task 11 第 6 项；§9 → Task 7、10、11；§12 的不进备份、只放行回环 → Task 6。§14.3 已在 P1a。§14.6 → Task 12。
- 不在 P1 的（语音、更新、P2 各项、内存警告事件）没有任务，Global Constraints 里写了。
- 类型一致：`MobileChannel`、`MobileNet`、`MobilePaths`、`AndroidChannel([MethodChannel?])`、可赋值的全局 `mobileChannel`（只由入口赋值）、`MobileFullscreen`、`BackgroundWatch(channel:)`、`hubStartError`/`hubSendError`、`FfiSessionLinks(library)`、`SessionNative`（含 `release(SessionSink)`）、`SessionSink`、`AndroidSessionHost(root)`、`KeyLog`（`install`/`uninstall`）、`DebugPanel(keys:, frames:)`、`CountingFrameSink`（`WorkerSessionPort(..., sink:)` 收它，端口本身不改）、`prepareDataDir(root, legacy, chmod:)`、`mainMobile(onBack:, chmodData:)`、`MainWindow(debugPanel:, onBack:)`、`backStep`、`BackStep` 在各任务里写法一致。
- 共用代码里唯一新加的 `Platform.isAndroid` 是 `main.dart` 那一行（附录 A）；其余差别都由入口传参数或给全局赋值。
- P1a 那一片（`worker_session_port.dart`、`linux_session_host.dart`）不改：帧数从 `sink:` 接，剪贴板文字退路照抄。
- 秘密：relay、密钥只走管道（Task 11 第 2 项）；平板序号只在变量里（Task 12）。计划里不写任何地址、密钥、序号。
- 比例：代码块是接口、测试和命令；函数体留给实施者，只有 `KeyLog` 的行格式写死（实机清单按它读）。
