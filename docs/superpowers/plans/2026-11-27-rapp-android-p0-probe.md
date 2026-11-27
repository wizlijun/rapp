# rApp 安卓平板 P0 探查 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在模拟器上把安卓平板版规格里没验证过的八件事各量一遍，写成一页结果，让 P1 的计划从事实出发。

**Architecture:** 一次性的分支 `probe/android-p0`，直接在真的 `gui/` 上打补丁：加安卓工程、一个探查用的入口、把 `LinuxSessionPort` 的子进程换成进程内的会话库。Rust 侧把会话循环粗略挪进库，新建 `rapp-android-ffi` 出 `.so`。探查代码不合并；合并的只有结果页和对规格的修改。

**Tech Stack:** Flutter 3.44.1（`~/development/flutter/bin/flutter`）、Rust stable + `aarch64-linux-android` + `cargo-ndk`、NDK 28.2.13676358、Kotlin（Flutter 模板自带的版本）、Android 模拟器（arm64，API 34 和 36）。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`。§14.1 是这八项的出处；§6.1、§6.2、§8.3、§11、§13.2 是被验证的内容。动手前把这几节读完。

## Global Constraints

- **探查代码不进 `main`。** 分支 `probe/android-p0`，worktree `.worktrees/android-p0`，不推送。每个任务结束提交一次，信息 `probe(android): <做了什么>`，结尾带 `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`。
- **交付物是结果页**：`docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md`，在分支 `docs/android-p0-findings`（worktree `.worktrees/android-p0-docs`）上写，按 `CLAUDE.md` 合并进本机 `main`。没看过探查代码的人要能只凭这一页写出 P1 的代码，所以每项都写：跑了什么命令、在哪个镜像上、量到什么、过没过、管用的做法（调用、参数、版本）。
- 不改版本号（`gui/pubspec.yaml` 的 `version`、`rust/Cargo.toml` 的 workspace version）、不打 tag、不推送。探查分支上 `Cargo.lock` 因为加 crate 而变是允许的，它不合并。
- 版本：`minSdk = 34`，`compileSdk`、`targetSdk` 用 Flutter 的默认（36），只出 `arm64-v8a`，`applicationId = com.rapphub.rapp`。
- **用户的 relay 地址和密钥**：只从这台 Mac 自己的 `service.json` 读，用 `jq` 直接写到 scratchpad 里的文件再推进模拟器，不打印到终端、不写进结果页、不进任何提交。Task 8 删掉 scratchpad 里那一份并卸载模拟器上的 App。
- 探查端在 relay 上会多出一台设备。名字固定成 `rApp P0 探查`，交稿时告诉用户。
- **2、3、4 项（Task 2、3、4）任何一项过不了：停，用对话框报告用户，不往下做，也不自己换方案**（规格 §14.1）。其余项过不了：记下来，按规格里写好的退路改规格。
- 这台 Mac 上：`grep` 是 ugrep，用 `/usr/bin/grep`；带 `*` 的参数要加引号（zsh）；在 `rust/` 里递归搜索要排除 `target`；`cargo`、`rustup` 在 `~/.cargo/bin`，不在 `PATH`；本机只有 JDK 27。不读 `docs/archives/`。
- 不改 Flutter 的全局配置（不用 `flutter config --jdk-dir`）。需要别的 JDK 时只在命令前设 `JAVA_HOME`。
- 一次只开一个模拟器。证据用 `adb exec-out screencap -p` 截图，放 scratchpad，不进仓库；结果页里用文字写看到了什么。
- 每个用到的版本写进结果页：NDK、build-tools、AGP、Gradle、Kotlin、JDK、模拟器、两个系统镜像的修订号、Rust、`cargo-ndk`。

## Review Focus

探查最怕的是「假的过关」。每行写了由哪个任务挡住。

1. `.so` 编得出来、`hosts` 也有回应，但真连 relay 时才出错（证书、数据目录、地址解析）→ Task 3 的过关线是全景里看到这台 Mac 在线，不是「有回应」。
2. 以为测了双栈，其实模拟器里根本没有可用的 IPv6 → Task 3 先记 `ip -o addr` 和 `ip -6 route`，没有就写「模拟器上测不了，留给实机」，不算过。
3. 内存「不涨」是因为 A 的画面没在动 → Task 4 量内存时 A 上必须有持续变化的画面，日志里每秒到达的帧数大于交给 Dart 的帧数（说明真的在丢帧合并）。
4. `adb` 注入的按键不等于实体键盘 → Task 5 的表每行标「注入」，实体键盘那一遍留在规格 §14.6 的实机清单里，不删。
5. 语音的几个「能不能用」接口答了是，但真说话不出字 → Task 6 要有识别出的中文文字才算过；麦克风用不了就记「没测」。
6. 自己装自己之所以成功，是因为 `adb` 装的包带了特权或权限已经给过 → Task 7 从干净安装开始，先确认 `canInstall` 是否，走一遍设置页。

---

## 顺序

Task 1 → 2 → 3 → 4 依次做，后一个靠前一个。Task 5、6、7 互不相干，在 Task 3 之后任意顺序。Task 8 最后。

---

### Task 1: 工具、结果页、空壳能启动（第 1 项）

**Files:**
- Create: `docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md`（在 `docs/android-p0-findings` 分支）
- Create: `gui/android/`（`flutter create` 生成）、`gui/lib/main_p0_shell.dart`
- Modify: `gui/android/app/build.gradle.kts`、`gui/.gitignore`

**Interfaces:**
- Produces: 两个模拟器 `rapp-p0-34`（AOSP 14，不带 Google）、`rapp-p0-36`（Android 16，带 Google API）；环境变量约定 `ANDROID_HOME=~/Library/Android/sdk`、`ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358`；能出调试 APK 的 `gui/android/`。

- [ ] **Step 1: 建两个 worktree**

```bash
cd /Users/bruce/git/rapp
git worktree add .worktrees/android-p0 -b probe/android-p0 main
git worktree add .worktrees/android-p0-docs -b docs/android-p0-findings main
```

- [ ] **Step 2: 建结果页骨架并提交**（在 `.worktrees/android-p0-docs`）

```markdown
# rApp 安卓平板 P0 探查结果

规格：`2026-11-27-rapp-android-tablet-design.md` §14.1。计划：`../plans/2026-11-27-rapp-android-p0-probe.md`。做完一项填一项。

## 工具和镜像

| 东西 | 版本 |
|---|---|

## 总表

| # | 看什么 | 结论（过 / 没过 / 部分 / 没测） | 规格要不要改 | 日期 |
|---|---|---|---|---|

## 1 工具和空壳
## 2 `.so`
## 3 进程内 hub 和网络
## 4 进程内会话
## 5 键盘和触控板
## 6 语音
## 7 自己装自己
## 8 数字
## 探查里打的补丁（P1 的输入）

| 文件和位置 | 改了什么 | 为什么 | P1 里它属于哪个接口 |
|---|---|---|---|

## 规格要改的地方
```

- [ ] **Step 3: 装工具**

```bash
export ANDROID_HOME=~/Library/Android/sdk
SDKM=$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager
yes | $SDKM --licenses
$SDKM "platforms;android-36" "ndk;28.2.13676358" "emulator" \
  "system-images;android-34;default;arm64-v8a" "system-images;android-36;google_apis;arm64-v8a"
~/.cargo/bin/rustup target add aarch64-linux-android
~/.cargo/bin/cargo install cargo-ndk --locked
```

`sdkmanager` 或后面的 Gradle 不认 JDK 27 时：`brew install openjdk@21`，之后所有安卓命令前加 `JAVA_HOME=$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home`。哪一步需要、报的什么错，写进结果页。build-tools 不手动装，让 AGP 自己下它要的那一版。

- [ ] **Step 4: 建两个模拟器**

```bash
AVDM=$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager
$AVDM create avd -n rapp-p0-34 -k "system-images;android-34;default;arm64-v8a" -d pixel_tablet
$AVDM create avd -n rapp-p0-36 -k "system-images;android-36;google_apis;arm64-v8a" -d pixel_tablet
```

在两个 `~/.android/avd/<名字>.avd/config.ini` 里设 `hw.keyboard=yes`、`hw.ramSize=4096`。启动（后台跑）：`$ANDROID_HOME/emulator/emulator -avd rapp-p0-34 -no-snapshot -no-boot-anim`，等 `adb shell getprop sys.boot_completed` 是 `1`。
验证：`adb shell wm size` 是 `2560x1600`（横竖都算）；`adb shell getprop ro.build.version.sdk` 分别是 `34`、`36`。`pixel_tablet` 不存在时，从 `avdmanager list device` 里挑一个平板，再把 `hw.lcd.width/height` 改成 2560/1600，写进结果页。

- [ ] **Step 5: 生成安卓工程**（在 `.worktrees/android-p0`）

```bash
~/development/flutter/bin/flutter create --platforms=android --org com.rapphub --project-name rapp gui
git status --short
```

预期：新增的只有 `gui/android/`，`gui/.metadata` 可能有改动。别的文件被改了就 `git checkout -- <文件>` 还原。
在 `gui/android/app/build.gradle.kts` 的 `defaultConfig` 里设 `minSdk = 34` 和 `ndk { abiFilters += "arm64-v8a" }`。`gui/.gitignore` 加一行 `android/app/src/main/jniLibs/`。

- [ ] **Step 6: 写空壳入口 `gui/lib/main_p0_shell.dart`**

一个只显示 `rApp P0 shell` 和 `Platform.operatingSystemVersion` 的 `MaterialApp`，不引用仓库里别的文件。

- [ ] **Step 7: 在两个模拟器上各装一次、启动、截图**

```bash
cd gui && ~/development/flutter/bin/flutter build apk --debug -t lib/main_p0_shell.dart --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.rapphub.rapp/.MainActivity
adb exec-out screencap -p > <scratchpad>/p0-shell-34.png
```

过关：两张截图上都有 `rApp P0 shell`；`adb logcat -d -s flutter AndroidRuntime` 里没有崩溃。之后 `git checkout -- pubspec.lock`（如果它变了）。

- [ ] **Step 8: 填结果页的「工具和镜像」和第 1 节，两边各提交一次**

---

### Task 2: 会话进库、`rapp-android-ffi`、出 `.so`（第 2 项，过不了就停）

**Files:**
- Move: `rust/client-core/src/bin/rapp-session.rs` 里除 `main` 以外的全部 → `rust/client-core/src/session/mod.rs`；`bin/session_output/mod.rs` → `src/session/output.rs`；`bin/session_trace/mod.rs` → `src/session/trace.rs`
- Modify: `rust/client-core/src/lib.rs`（加 `pub mod session;`）、`rust/client-core/src/bin/rapp-session.rs`（只剩 `main`）、`rust/Cargo.toml`（只在 `members` 里加 `"android-ffi"`）
- Create: `rust/android-ffi/Cargo.toml`、`rust/android-ffi/src/lib.rs`

**Interfaces:**
- Produces（`rapp_client_core::session`）：
  - `pub struct Output`，`pub fn Output::spawn(writer: impl Write + Send + 'static) -> (Output, JoinHandle<io::Result<()>>)`（现有的，只是变公开）
  - `pub fn run(input: impl BufRead + Send + 'static, out: &Output) -> Result<()>`（现有的 `run`，标准输入换成参数）
  - `pub fn serve(input: impl BufRead + Send + 'static, writer: impl Write + Send + 'static)`：现在 `main` 做的那几步（起 `Output`、`run`、发 `disconnected` 事件、`finish`、等写线程）。`main` 变成 `session::serve(BufReader::new(stdin()), stdout())`。
- Produces（`librapp_android.so` 导出的九个 C 函数）：
  - hub 的四个：`rapp_hub_start`、`rapp_hub_send`、`rapp_hub_free_line`、`rapp_hub_stop`（签名见 `rust/hub-ffi/src/lib.rs`）
  - `rapp_session_open(start: *const c_char, sink: Sink) -> u64`，`0` 是失败
  - `rapp_session_send(id: u64, line: *const c_char) -> i32`，`0` 成功，`-1` 没有这个会话，`-2` 参数不是 UTF-8
  - `rapp_session_ack(id: u64)`
  - `rapp_session_close(id: u64)`
  - `rapp_session_free(ptr: *mut c_void)`
  - `type Sink = extern "C" fn(id: u64, kind: u8, ptr: *mut u8, len: usize)`
- `Sink` 收到的东西：`kind` 0 和 1 时，`ptr` 指向的内容和管道里的一个包一模一样（第一个字节是 0 或 1，后面是事件的 JSON 或「24 字节帧头 + BGRA」），用 `libc::malloc` 分配，`len` 是整包长度，收的一方用 `rapp_session_free(ptr)`（就是 `libc::free`）归还。`kind` 2 时 `ptr` 是空、`len` 是 0，它是这个会话号的最后一次回调，恰好一次，`rapp_session_close` 之后也照发。
- 为什么 `free` 只收一个参数：Dart 的 `Pointer.asTypedList(len, finalizer:)` 只会拿指针一个参数去调收尾函数。动手前对一下 Dart SDK 里 `asTypedList` 的文档注释；和这里说的不一样就停下来改这一段。

- [ ] **Step 1: 挪代码**

用 `git mv` 挪三个文件，改 `mod`、`use` 路径和可见性，其余一个字不动。`session_trace` 读环境变量的那一行留在原处（P1 再处理）。

- [ ] **Step 2: 现有测试原样通过**

Run: `cd rust && ~/.cargo/bin/cargo test -p rapp-client-core`
Expected: 全过，测试条数和挪之前一样（先在 `main` 上跑一次记下条数）。

- [ ] **Step 3: 写 `rapp-android-ffi` 的三个失败测试**（`rust/android-ffi/src/lib.rs` 的 `tests` 模块）

带闸的写入端单独可测：`struct Gate`（开、关、作废三个状态，`Mutex` 加 `Condvar`）和 `struct GateWriter { id: u64, sink: Sink, gate: Arc<Gate>, .. }: Write`。`GateWriter` 自己解析「4 字节小端长度 + 包体」，不依赖 `Output` 每次 `write` 多长；一个包收齐后：等闸开 → 交给 `sink` → 这个包的第一个字节是 1 就关闸。

```rust
// 测试用的 sink 把 (id, kind, 内容) 记进一个全局 Vec，并立刻 rapp_session_free。
fn packet(kind: u8, body: &[u8]) -> Vec<u8>; // 4 字节长度 + kind + body

#[test]
fn gate_holds_the_next_packet_until_ack() {
    // 依次写入：事件 a、帧 f（24+4 字节）、事件 b。写入在另一个线程。
    // 200 ms 后 sink 收到的恰好是 [(0, a), (1, f)]。
    // gate.open()（rapp_session_ack 做的事）之后 1 s 内收到 (0, b)。
}

#[test]
fn close_releases_a_writer_stuck_on_the_gate() {
    // 写入帧 f，再写事件 b（卡在闸上）。gate.close() 后 1 s 内，卡住的 write 返回 Err(BrokenPipe)。
}

#[test]
fn session_over_loopback_ends_with_kind_2_exactly_once() {
    // 在 127.0.0.1 上起一个假的 A（把 rapp-session.rs 的 tests 模块里的 ready()、tiny_frame() 抄一份；挪完后它们在 session/mod.rs）。
    // rapp_session_open(启动行, sink)。启动行就是 LinuxSessionPort 发给子进程的第一行，
    // 字段见 session::run 开头。假的 A 先读掉会话发来的开头，再发 Ready 和一个 8×8 的完整帧。
    // sink 依次收到：kind 0 含 "event":"ready"；kind 1，len == 1 + 24 + 8*8*4。
    // rapp_session_ack(id)；假的 A 断开。
    // 之后收到 kind 0 含 "event":"disconnected"，最后是 kind 2（ptr 空，len 0），总共一次。
    // rapp_session_send(id, ..) 此后返回 -1。
}
```

- [ ] **Step 4: 跑，确认失败**

Run: `cd rust && ~/.cargo/bin/cargo test -p rapp-android-ffi`
Expected: 编译失败或三个测试失败。

- [ ] **Step 5: 实现**

`Cargo.toml`：包名 `rapp-android-ffi`，`[lib] name = "rapp_android"`，`crate-type = ["cdylib"]`，依赖用路径写：`rapp-hub-ffi = { path = "../hub-ffi" }`、`rapp-client-core = { path = "../client-core" }`，加 `libc = "0.2"`（`Cargo.lock` 里已有的那一版）和 `serde_json.workspace = true`。
`lib.rs`：`pub use rapp_hub_ffi::{rapp_hub_start, rapp_hub_send, rapp_hub_free_line, rapp_hub_stop};`；会话表 `static SESSIONS: Mutex<HashMap<u64, Session>>`，号从 1 起；`open` 建一对通道当 `input`（启动行是第一行，`send` 往里写后面的行），起一个线程跑 `session::serve(input, GateWriter)`，线程结束时把会话从表里拿掉并发 `kind` 2；`close` 作废闸、关掉输入、最多等 2 秒。每个 `extern "C"` 函数和这个线程的入口包 `catch_unwind`（规格 §6.2 规矩 2）。

- [ ] **Step 6: 测试通过，clippy 记一笔**

Run: `cd rust && ~/.cargo/bin/cargo test -p rapp-android-ffi -p rapp-client-core && ~/.cargo/bin/cargo clippy -p rapp-android-ffi -- -D warnings`
Expected: 测试全过。clippy 的结果只记录。

- [ ] **Step 7: 编安卓的 `.so`**

```bash
cd rust && ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358 \
  ~/.cargo/bin/cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi
```

Expected: `rust/target/aarch64-linux-android/release/librapp_android.so` 出来。（最低版本的参数名以 `cargo ndk --help` 为准，实际用的命令写进结果页。）哪个依赖编不过（`ring`、`quinn`、`rcgen`、`alacritty_terminal`、`portable-pty`、`if-addrs`），记下 crate、版本、报错，试一次最小的修法（换 feature、加 `cfg`）；修不动就是第 2 项没过，停。

- [ ] **Step 8: 看导出表和对齐**

```bash
BIN=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin
$BIN/llvm-nm -D --defined-only target/aarch64-linux-android/release/librapp_android.so | /usr/bin/grep ' T rapp_'
$BIN/llvm-readelf -lW target/aarch64-linux-android/release/librapp_android.so | /usr/bin/grep LOAD
ls -l target/aarch64-linux-android/release/librapp_android.so
```

过关：第一条恰好列出 Interfaces 里的九个名字；每个 `LOAD` 段的 `Align` 是 `0x4000`。
hub 的四个不在表里时：在 `lib.rs` 加一个 `#[used] static` 数组引用这四个函数再编。还不在就停下来报告。**不要**在这个 crate 里写四个同名的转调函数，名字会和 `rapp-hub-ffi` 里的撞。

- [ ] **Step 9: 查按 Linux 写的分支**

```bash
~/.cargo/bin/cargo tree -p rapp-android-ffi --target aarch64-linux-android -e normal --prefix none | /usr/bin/grep '^rapp-' | sort -u
/usr/bin/grep -rn --include='*.rs' --exclude-dir=target 'target_os = "linux"' hub net conn ports term client-core wire hub-ffi
```

第二条的每个命中在结果页里列一行：文件、它做什么、安卓要不要（要的话 P1 怎么改）。只列第一条输出里出现的 crate。

- [ ] **Step 10: 填结果页第 2 节（含 `.so` 大小），提交**

---

### Task 3: 进程内 hub、连上 relay、IPv4 和双栈（第 3 项，过不了就停）

**Files:**
- Modify: `gui/lib/hub_ffi.dart`、`gui/lib/main.dart`、`gui/android/app/src/main/AndroidManifest.xml`、`gui/android/app/src/main/kotlin/com/rapphub/rapp/MainActivity.kt`、`rust/android-ffi/src/lib.rs`、`rust/net/src/quic.rs`（只为让 `getaddrinfo_v6` 能被探查函数调到）
- Create: `gui/lib/main_android.dart`、`gui/lib/p0/p0_pages.dart`、`scripts/p0-android-so.sh`

**Interfaces:**
- Consumes: Task 2 的 `.so` 和九个函数。
- Produces:
  - `FfiHubTransport.start({required String home, required String logDir, required String name, String? library})`：`library` 是空就用 `DynamicLibrary.process()`，否则 `DynamicLibrary.open(library)`；`_stopOffThread(String? library)` 同样处理（传字符串，是因为 `DynamicLibrary` 过不了 `Isolate.run`）。安卓传 `'librapp_android.so'`。
  - Kotlin 通道 `rapp/android`：`paths` → `{"files": filesDir 的路径, "cache": cacheDir 的路径}`；`deviceName` → 固定返回 `"rApp P0 探查"`。
  - `Future<void> mainAndroid()`（`gui/lib/main_android.dart`）；`main.dart` 里在 iOS 那一行旁边加 `if (Platform.isAndroid) return mainAndroid();`。数据根是 `<files>/rapp`。
  - `--dart-define=P0_PAGE=<名字>`：不是空就不进主界面，显示 `p0_pages.dart` 里对应的探查页（`resolve`、`keys`、`speech`、`install`）。
  - 探查用的导出函数 `rapp_p0_resolve(host: *const c_char, port: *const c_char) -> *mut c_char`：返回 `rapp_net` 的 `getaddrinfo_v6(host, port)` 的结果的文字（没有就是 `none`），用 `rapp_hub_free_line` 归还。这个函数现在在 `quic.rs` 的私有模块 `sys` 里（非苹果的那一个），探查分支上把它开成公开的，`rapp-android-ffi` 加 `rapp-net = { path = "../net" }`。
  - `scripts/p0-android-so.sh`：跑 Task 2 Step 7 的命令，把 `.so` 拷到 `gui/android/app/src/main/jniLibs/arm64-v8a/`。

- [ ] **Step 1: 改 `hub_ffi.dart`，iOS 的测试不坏**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ 2>&1 | tail -3`（改之前先跑一次记下通过条数）
Expected: 通过条数不变。之后 `git checkout -- pubspec.lock`。

- [ ] **Step 2: 写 Kotlin 通道、清单、`main_android.dart`**

清单加 `<uses-permission android:name="android.permission.INTERNET"/>`、`ACCESS_NETWORK_STATE`，`android:allowBackup="false"`。
`main_android.dart` 照 `main_ios.dart` 抄，去掉：内置输入法（`RappRime`、`RimeGlue`、`RimeLocalIme`）、`_waitForNetwork`、`BackgroundWatch`、`FoldFullscreen`。`ensureDeviceId(root, name: name, os: 'android')`。会话端口这一步先传 `null`（Task 4 接上）。跑起来后哪里因为没有 iOS 通道而抛错，就地用最小的办法绕开，每处在结果页「探查里打的补丁」表里记一行。

- [ ] **Step 3: 装上，hub 起得来**

```bash
scripts/p0-android-so.sh && cd gui && ~/development/flutter/bin/flutter build apk --debug --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk && adb shell am start -n com.rapphub.rapp/.MainActivity
adb shell run-as com.rapphub.rapp cat files/rapp/logs/hub.log | tail -20
```

过关：界面出来的是接入引导（还没有 relay；能走到这一页说明 hub 回了 `access` 和 `hosts`），`hub.log` 里没有 error 级别的行，`adb logcat -d -s flutter` 里没有 `hub 起不来`。

- [ ] **Step 4: 放进 relay 和密钥**

这台 Mac 的数据根用 `gui/lib/paths.dart` 的 `defaultDataRoot` 对 macOS 的规则找（有 `RAPP_HOME` 或指针文件就跟着走），文件是 `<数据根>/local/service.json`。

```bash
jq '{relay, key}' "<数据根>/local/service.json" > <scratchpad>/p0-service.json   # 不要 cat 它
adb shell run-as com.rapphub.rapp mkdir -p files/rapp/local
adb shell run-as com.rapphub.rapp sh -c 'cat > files/rapp/local/service.json' < <scratchpad>/p0-service.json
adb shell am force-stop com.rapphub.rapp && adb shell am start -n com.rapphub.rapp/.MainActivity
```

过关：截图上全景里有这台 Mac，状态是在线。`hub.log` 里有连上 relay 的记录、没有 error。
hub 不认这个文件时：看 `rust/hub/src/access.rs` 的 `read` 要什么（字段、权限），照它补；不要改成在界面上手输，也不要把内容打出来看。

- [ ] **Step 5: 地址解析，两种网络状态各一遍**

先记状态：`adb shell ip -o addr`、`adb shell ip -6 route`。
- 状态「默认」：模拟器开机后的样子。
- 状态「只有 IPv4」：`adb root && adb shell sysctl -w net.ipv6.conf.all.disable_ipv6=1`（重启模拟器就恢复）。

每种状态下，用 `--dart-define=P0_PAGE=resolve` 的包对这四个主机调 `rapp_p0_resolve(主机, "443")` 并显示结果：relay 的主机（界面上显示成 `relay`，不显示真值）、`1.1.1.1`、`localhost`、`dns.google`。再换回普通包冷启动一次，看全景里这台 Mac 是不是在线。

过关：两种状态下 relay 都解析出能用的地址（真的 IPv6，或 `::ffff:a.b.c.d`），并且都连得上。
- 「只有 IPv4」下解析出 `none` 或连不上：在探查分支上给安卓加一支（按 IPv4 解析，自己拼成 `::ffff:` 地址），再测；结果页写清楚哪种写法管用。加了还不通，第 3 项没过，停。
- 「默认」状态下模拟器没有可用的 IPv6（没有全局地址或没有默认路由）：双栈这一半记「模拟器上测不了，留给实机」，加进规格 §14.6 的清单。

- [ ] **Step 6: 在另一个镜像上重复 Step 3–5，填结果页第 3 节，提交**

---

### Task 4: 进程内会话、节流、数字（第 4、8 项，第 4 项过不了就停）

**Files:**
- Modify: `gui/lib/embed/session_worker.dart`、`gui/lib/embed/linux_session_port.dart`、`gui/lib/main_android.dart`
- Create: `gui/lib/embed/session_ffi.dart`、`gui/test/session_ffi_test.dart`

**Interfaces:**
- Consumes: Task 2 的五个会话函数和 `Sink` 的约定；Task 3 的 `mainAndroid`。
- Produces:
  - `gui/lib/embed/session_ffi.dart`：`class SessionFfi`（五个函数的绑定，构造时收库名），和纯 Dart 的 `Stream<Uint8List> ackedPackets(Stream<Uint8List> source, void Function() ack, {Duration slow = Duration.zero})`：把包原样交给下游；下游来要下一个包时，如果上一个包的第一个字节是 1，先等 `slow`，再调一次 `ack`。
  - `factory SessionWorker.ffi(String library, {Duration slow})`（在 `session_worker.dart`）：第一次 `send(line)` 调 `rapp_session_open(line, sink)`，之后的调 `rapp_session_send`；`packets` 是 `ackedPackets(...)`，每个包用 `ptr.asTypedList(len, finalizer: rapp_session_free 的地址)` 包出来，不拷贝；`closeInput()` 和 `kill()` 在 `Isolate.run` 里调 `rapp_session_close`；`exitCode`、`inputDone` 在收到 `kind` 2 时完成，同时关掉 `NativeCallable`；`pid` 是会话号。
  - `LinuxSessionPort.ffi(String library, {required String Function() downloads})`：不检查可执行文件，用 `SessionWorker.ffi` 起会话。
  - `--dart-define=P0_SLOW_MS=<毫秒>` 传给 `slow`。延时放在 ack 之前，是因为现有的读循环拿到帧就交给 `queueFrame`、不等解码，和子进程那条路的 `credit` 是同一个时机；要量的是 ack 来得慢时 Rust 那边会不会堆。每秒用 `debugPrint` 打一行 `p0 fps=<这一秒交给端口的帧数>`。

- [ ] **Step 1: 写 `ackedPackets` 的失败测试**（`gui/test/session_ffi_test.dart`）

```dart
test('acks once per frame, only when the consumer asks for the next packet', () async {
  // source 依次给出：[0, ...]、[1, ...]、[0, ...]、[1, ...]。
  // 下游拿到第 2 个包（帧）时 acks == 0；拿到第 3 个包时 acks == 1；流结束时 acks == 2。
});
test('a paused consumer gets no ack', () async {
  // 下游拿到第一个帧后暂停订阅 100 ms：这期间 acks == 0。
});
```

- [ ] **Step 2: 跑，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/session_ffi_test.dart`
Expected: FAIL（`ackedPackets` 不存在）。

- [ ] **Step 3: 实现 `session_ffi.dart` 和 `SessionWorker.ffi`，测试通过**

Run: 同上。Expected: PASS。

- [ ] **Step 4: 让 `LinuxSessionPort` 在安卓上起来**

`main_android.dart` 里 `port = LinuxSessionPort.ffi('librapp_android.so', downloads: () => '<数据根>/files/transfers')`。跑起来后因为没有 `rapp/linux` 通道、没有 `xdg-open`、读环境变量而出错的地方，就地绕开，每处记进「探查里打的补丁」表，最后一列写它在规格 §6.3 里属于 `SessionLink`、`SessionHost` 还是别处。这张表是 P1 重构的清单，要全。

- [ ] **Step 5: 画面、点、打字**

被控端用这台 Mac（用户另指了别的设备就用那台）。模拟器窗口本身也在这台 Mac 的屏幕上，桌面会话里会看到一层套一层的画面，正常。动别人正在用的桌面之前只做这两件事：
1. 开这台 Mac 的桌面会话，截图：画面出来，和 Mac 屏幕一致，颜色没有红蓝对调。
2. 在 Mac 上开一个 TextEdit 的空白文稿，用单应用会话接入 TextEdit。`adb shell input tap <x> <y>` 点文稿区域，`adb shell input text 'p0probe'`。截图：文稿里出现 `p0probe`。做完在 Mac 上不保存关掉那个文稿。

过关：两张截图都符合。两个镜像各做一遍。

- [ ] **Step 6: 故意让 Dart 慢，量内存**

A 上放一个一直在动的画面（终端里 `while true; do date; sleep 0.03; done` 就够）。装 `--dart-define=P0_SLOW_MS=200` 的包，开桌面会话，等 30 秒，然后每 10 秒记一次，共 18 次：

```bash
adb shell dumpsys meminfo com.rapphub.rapp | /usr/bin/grep -E 'TOTAL( PSS)?:?'
adb logcat -d -s flutter | /usr/bin/grep 'p0 fps=' | tail -3
```

同时看会话的 `traffic` 事件里每秒的 `frames`（A 发来的帧数）。
过关：`p0 fps` 在 5 上下（每帧 200 ms）而 `frames` 明显更大；后 6 次的平均 PSS 减前 6 次的平均 PSS 小于 40 MB（一张 2560×1600 的画布是 16 MB，容许两张多）。涨过这个数：第 4 项没过，停。
再装不带 `P0_SLOW_MS` 的包同样量一遍，当对照。

- [ ] **Step 7: 数字（第 8 项）**

- APK 大小：`flutter build apk --release --target-platform android-arm64` 后 `ls -l build/app/outputs/flutter-apk/app-release.apk`；里面 `librapp_android.so`、`libflutter.so`、`libapp.so` 各多大（`unzip -lv`）。
- 内存：开着一个 2560×1600 的桌面会话、画面静止时的 `TOTAL PSS`，以及没开会话时的。
- 帧率：发布包、A 上放视频时的 `p0 fps`，量 30 秒取平均。注明「模拟器，只作参考」。

- [ ] **Step 8: 填结果页第 4、8 节和补丁表，提交**

---

### Task 5: 键盘和触控板（第 5 项）

**Files:**
- Modify: `gui/lib/p0/p0_pages.dart`

**Interfaces:**
- Produces: 探查页 `keys`：上半屏是一个能聚焦的空白区，下半屏是一个文本框；用 `HardwareKeyboard.instance.addHandler` 把每个 `KeyEvent` 记成一行（按下还是抬起、`physicalKey`、`logicalKey`、当时 Ctrl、Meta、Alt、Shift 是否按着），用 `Listener` 把 `PointerSignalEvent`、`PointerPanZoomStart/Update/End` 记成一行（类型、`kind`、位移或缩放）。每行同时 `debugPrint('p0 key …')` 或 `'p0 ptr …'`。

- [ ] **Step 1: 写探查页，装 `--dart-define=P0_PAGE=keys` 的包**

- [ ] **Step 2: 注入按键，填表**

```bash
adb shell input keycombination 113 31     # CTRL_LEFT + C
adb logcat -d -s flutter | /usr/bin/grep 'p0 key' | tail -4
```

键码：C 31、V 50、X 52、Z 54、A 29、T 48、W 51、TAB 61、SPACE 62、ENTER 66；CTRL_LEFT 113、META_LEFT 117。
要注入的：Ctrl 加上面十个键；Meta 加 C、TAB、ENTER，以及单按 Meta。
每个组合在四种情形下各做一次：两个镜像 ×（焦点在空白区、焦点在文本框且软键盘开着）。
表的列：组合、镜像、焦点在哪、App 收到了什么（`logicalKey` 和修饰键状态）、系统有没有做别的事（看截图）、来源（都填「注入」）。

过关：Ctrl+C 和 Ctrl+V 在焦点在空白区时到得了 App，并且 `isControlPressed` 是真。到不了就停下来报告（规格 §14.1）。
Meta 的几行只记录：按规格 U8 它们本来就不发给 A，要确认的是它们要么到不了 App，要么到的时候 `isMetaPressed` 是真（`_remoteKey` 靠这个丢掉它们）。

- [ ] **Step 3: 滚轮和触控板**

- 鼠标滚轮：先看 `adb shell input` 的帮助里 `scroll` 的写法（两个镜像可能不同），注入一次竖向滚动，记 Flutter 收到的事件类型和 `kind`。
- 触控板双指滚动、捏合：用 `adb shell uinput` 注册一个虚拟触控板再发手势，最多花一小时。做成了，记 Flutter 收到的是 `PointerPanZoom*` 还是 `PointerScrollEvent`；做不成，这两行写「模拟器上测不了，留给实机」，并确认规格 §14.6 的清单里有这一条（没有就加）。

- [ ] **Step 4: 填结果页第 5 节，提交**

---

### Task 6: 语音（第 6 项）

**Files:**
- Modify: `gui/android/app/src/main/kotlin/com/rapphub/rapp/MainActivity.kt`、`gui/android/app/src/main/AndroidManifest.xml`、`gui/lib/p0/p0_pages.dart`

**Interfaces:**
- Produces: Kotlin 通道 `rapp/p0speech`：
  - `probe` → `{"available": isRecognitionAvailable, "onDevice": isOnDeviceRecognitionAvailable, "service": 默认识别服务的包名}`
  - `support {"onDevice": bool}` → 对 `zh-CN` 调 `checkRecognitionSupport`，返回 `{"installed": [...], "pending": [...], "supported": [...], "online": [...]}`，或 `{"error": 错误码}`
  - `start {"onDevice": bool, "segmented": bool, "hotwords": [..]}`、`stop`
  - 事件：`partial`、`segment`、`final`、`rms`、`error`（带错误码）、`end`
  清单加 `RECORD_AUDIO` 和查询识别服务用的 `<queries>`。探查页 `speech`：显示 `probe` 和两次 `support` 的原样回答，一个「按住说话」按钮，下面滚动显示事件。

- [ ] **Step 1: 写通道和探查页，装 `--dart-define=P0_PAGE=speech` 的包**

- [ ] **Step 2: 两个镜像上各记一遍「能不能用」**

截图记下 `probe` 和 `support`（`onDevice` 真、假各一次）的回答。按规格 §11 的四条规则手算结论。
过关：不带 Google 的镜像（`rapp-p0-34`）算出来是「不能用」；带 Google 的（`rapp-p0-36`）算出来是什么就记什么。两边的回答和规则对不上（比如识别器明明能用却不让查），写进「规格要改的地方」。

- [ ] **Step 3: 真的说一句（只在算出「能用」的镜像上）**

`adb emu avd hostmicon` 打开主机麦克风；按住按钮用 `adb shell input swipe <x> <y> <x> <y> 8000`（原地按 8 秒，后台跑），同时在 Mac 上 `say -v Tingting "今天下午三点开会"`。
macOS 这时如果弹出「允许模拟器使用麦克风」，那是用户的事：用对话框请用户点一下。用户不在或不同意，这一步记「没测」，留给实机。
能录的话做三遍：普通一段；`segmented: true` 说两句、中间停 3 秒；带 `hotwords: ["rApp"]` 说「打开 rApp」。记每遍的事件顺序和最后的文字。
过关：普通一段出了中文字。分段和热词只记录：分段不支持时会收到什么（错误码还是静静地只出一段），决定规格 §11「识别中」第一条走哪一支。

- [ ] **Step 4: 填结果页第 6 节，提交**

---

### Task 7: 自己装自己（第 7 项）

**Files:**
- Modify: `gui/android/app/src/main/kotlin/com/rapphub/rapp/MainActivity.kt`、`gui/android/app/src/main/AndroidManifest.xml`、`gui/lib/p0/p0_pages.dart`
- Create: `gui/android/app/src/main/res/xml/network_security_config.xml`

**Interfaces:**
- Produces: `rapp/android` 通道加 `canInstall` → `packageManager.canRequestPackageInstalls()`；`openInstallSettings` → `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`（带本包的 `package:` 地址）；`installApk {"path": ...}` → 用 `PackageInstaller` 会话写入并提交，系统要确认时把那个确认界面拉起来，结果（成功、失败码、用户取消）经事件 `install` 发回。清单加 `REQUEST_INSTALL_PACKAGES`；网络安全配置只放行 `localhost` 和 `127.0.0.1` 的明文。
  探查页 `install`：显示本包的 `versionCode` 和 `canInstall`；按钮「下载并安装」从 `http://127.0.0.1:8765/app.apk` 下到 `<cache>/update/rapp.apk`，对 SHA-256（期望值从 `http://127.0.0.1:8765/app.sha256` 读），对上才调 `installApk`；按钮「去设置」。

- [ ] **Step 1: 写通道和探查页；出两个包**

```bash
cd gui && F=~/development/flutter/bin/flutter
$F build apk --debug --target-platform android-arm64 --dart-define=P0_PAGE=install --build-number 9001 && cp build/app/outputs/flutter-apk/app-debug.apk <scratchpad>/p0-old.apk
$F build apk --debug --target-platform android-arm64 --dart-define=P0_PAGE=install --build-number 9002 && cp build/app/outputs/flutter-apk/app-debug.apk <scratchpad>/serve/app.apk
shasum -a 256 <scratchpad>/serve/app.apk | cut -d' ' -f1 > <scratchpad>/serve/app.sha256
```

在 `<scratchpad>/serve` 里后台跑 `python3 -m http.server 8765 --bind 127.0.0.1`，再 `adb reverse tcp:8765 tcp:8765`。

- [ ] **Step 2: 从干净安装走一遍**

```bash
adb uninstall com.rapphub.rapp; adb install <scratchpad>/p0-old.apk
adb shell am start -n com.rapphub.rapp/.MainActivity
```

依次确认并截图：页面上 `versionCode` 9001、`canInstall` 是否 →「去设置」打开的是 rApp 那一页的「允许安装未知应用」，打开开关、返回，`canInstall` 变成是 →「下载并安装」→ 系统弹确认 → 点确认（按钮位置用 `adb shell uiautomator dump` 找）。

```bash
adb shell dumpsys package com.rapphub.rapp | /usr/bin/grep versionCode
adb shell pidof com.rapphub.rapp
```

过关：`versionCode` 变成 9002。
另外记下来（不作过关线）：装完后 App 是自己重新起来了，还是被杀掉、等用户点系统提示上的「打开」或桌面图标；数据目录里的文件还在不在（装之前用 `run-as` 放一个标记文件）。规格 §13.2 第 4 步写的是「装完 App 被系统重启」，和看到的不一样就改规格的说法。

- [ ] **Step 3: 哈希不对的那一遍**

把 `app.sha256` 改成 64 个 `0`，回到 9001 的包再点「下载并安装」。
过关：页面报校验失败，系统的确认界面没有出现，`<cache>/update/rapp.apk` 被删掉了，`versionCode` 还是 9001。

- [ ] **Step 4: 在另一个镜像上重复 Step 2，填结果页第 7 节，提交**

---

### Task 8: 写完结果、改规格、收尾

**Files:**
- Modify: `docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md`、`docs/superpowers/specs/2026-11-27-rapp-android-tablet-design.md`、`tasks/todo.md`（都在 `.worktrees/android-p0-docs`）

- [ ] **Step 1: 填完总表和「规格要改的地方」**

总表八行都有结论。每个「部分」「没过」「没测」后面写清楚：走的是规格里哪条退路，或者留给实机的哪一条。

- [ ] **Step 2: 改规格**

按「规格要改的地方」逐条改 `2026-11-27-rapp-android-tablet-design.md`，被改的段落末尾注 `（P0 结果 §n）`。§4.5「这台 Mac 上的工具」改成装完之后的样子。§14.6 的实机清单加上所有「留给实机」的项。规格的状态行改成 `P0 已完成（日期），待写 P1 计划`。
改到用户定过的事（§0 的 U1–U8）或者改变用户看得见的表现的，不直接改：列出来，交稿时用对话框一条一条问。

- [ ] **Step 3: `tasks/todo.md` 加一节「安卓平板」**

写：P0 结果页在哪；留给实机的各项；探查分支 `probe/android-p0` 还留着、P1 计划写完后可以删。

- [ ] **Step 4: 收尾**

```bash
rm -rf <scratchpad>/p0-service.json <scratchpad>/serve <scratchpad>/p0-old.apk
adb uninstall com.rapphub.rapp        # 两个模拟器都做，身份密钥和 relay 密钥随之删除
adb reverse --remove-all
```

停掉模拟器和 HTTP 服务。两个模拟器和装的工具留着给 P1 用，占了多少磁盘写进结果页。

- [ ] **Step 5: 合并文档，报告用户**

```bash
cd /Users/bruce/git/rapp/.worktrees/android-p0-docs && git merge main
cd /Users/bruce/git/rapp && git merge --no-ff docs/android-p0-findings -m "merge: 安卓平板 P0 探查结果（docs/android-p0-findings）"
```

不推送。用对话框告诉用户：八项各是什么结论；规格改了哪几处；relay 上多出来的那台 `rApp P0 探查` 可以删；要用户定的事（如果有）。然后才写 P1 的计划。
