# rapp iPad P0 探查 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal：** 回答 spec §15 P0 的 6 个问题，给出过关结论（走路线 A 还是回头看路线 B），结论写进 `docs/superpowers/measurements/2026-11-17-rapp-ipad-p0.md`。

**Architecture：** 探查代码全部放在 `probe/ipad-p0` 分支，不合入 main（spec：P0 只出结论，不留产品代码）。Rust 侧加一个 `rust/hub-ffi` 静态库，让 hub 在进程内跑；Swift 包加 iOS 平台，用条件编译让 `RappCore`、`RappSession` 在 iOS 上编过；`probes/ios/` 是一个只有 iOS 目标的 Flutter 探查 App，用 `dart:ffi` 起 hub，经 hub 打开一个嵌入会话，用一个精简的 Swift 插件把 `EmbeddedSession` 的画面注册成 Flutter 纹理，并把 CPU、内存、电量、窗口大小、生命周期写进 `Documents/probe.jsonl`。文档（spec、本计划、结论）放在 `docs/ipad-duo` 分支，交 rapp-49 合入。

**Tech Stack：** Rust 1.99（`aarch64-apple-ios`、`aarch64-apple-ios-sim` 已装）、Xcode 27.2、Flutter 3.44.1（`~/development/flutter/bin`）、Swift 6 / SwiftPM。

**Spec：** `docs/superpowers/specs/2026-11-17-rapp-ipad-duo-design.md`（§3、§5、§6.1、§6.3、§9、§10、§15 P0）

## Global Constraints

- 不改 main，不改桌面行为：macOS 上 `swift test`、`cargo test -p rapp-hub` 在探查分支上照样通过（spec §2"桌面三个平台的行为因为这次改动而变化"不能出现）。
- 不改线路协议、relay、A 端（spec §2）。
- hub 的代码不改，`hub-ffi` 只是外壳（spec §6.1"hub 本身的代码不改"）。探查中发现不得不改的，写进结论，不在 P0 里改。
- key、relay 地址只经 `--dart-define-from-file` 从 scratchpad 里的文件进探查包，不进任何提交（spec §2"key 出现在……"不能出现）。
- iOS 最低版本 17.0；包标识探查用 `com.rapphub.rapp.probe`（正式的 `com.rapphub.rapp` 留给 P1）。
- 手上的真机是 iPhone 12 mini（没有 iPad、没有 Duo）。spec 写"真机 iPad"的项目用这台 iPhone 量，结论里写明机型；Duo、iPad 的窗口大小用 Xcode 27.2 模拟器量。
- 结论文档用中文，写法同 `docs/superpowers/measurements/` 里已有的几份：命令、机型、提交号、表格、未通过的项照实写。

## Review Focus

1. **hub 在 iOS 上调 `std::process::Command`**（`rapp_net::config::hostname()`、`datadir` 的 git）：不能崩，只能退回默认值。Task 1 的测试在 iOS 模拟器上跑一次 `rapp_hub_start` 并检查 `hub.log` 里没有 panic。
2. **回调线程**：`on_line` 在 hub 的线程上被调用，Dart 侧必须用 `NativeCallable.listener`，否则崩在非 Dart 线程。Task 3 的冒烟测试发 20 条命令、收齐 20 个回答。
3. **`rapp_hub_stop` 后再 `rapp_hub_start`**（App 回前台时可能这样做）：第二次启动要么成功，要么返回明确的错误码，不能挂死。Task 1 测。
4. **进后台时正在流的会话**：回前台后探查 App 不能往已断开的会话里发东西（spec §2"不能出现"）。Task 5 记录回来时 hub 报的事件，探查 App 只在收到新的 `opened` 后才 `start`。
5. **"本地网络"弹框没人点**：真机上没人点"允许"时，hub 要能走中继连上。Task 6 记录弹框出现的时机和最后走的路径。

---

## 文件结构（都在 `probe/ipad-p0` 分支上，除非另注）

| 文件 | 职责 |
|---|---|
| `rust/hub-ffi/Cargo.toml`、`src/lib.rs`、`include/rapp_hub.h` | 三个 C 函数，内存管道接 `rapp_hub::run` |
| `rust/Cargo.toml` | workspace 成员加 `hub-ffi` |
| `Package.swift` | `platforms` 加 `.iOS(.v17)`；三个可执行目标照旧（iOS 上不编，靠 scheme 区分） |
| `Sources/RappCore/Windows.swift`、`DataPaths.swift` | `#if os(macOS)` 包住 macOS 专有的接口 |
| `Sources/RappSession/*.swift`（AppKit 那 6 个 + 用到它们的） | `#if canImport(AppKit)`；`LocalPasteboard` 加 UIKit 版 |
| `probes/ios/`（Flutter App，`flutter create --platforms=ios`） | 探查 App |
| `probes/ios/lib/ffi_hub.dart` | `FfiHubTransport implements HubTransport` |
| `probes/ios/lib/probe_log.dart` | 写 `Documents/probe.jsonl` |
| `probes/ios/lib/main.dart` | 自动跑一遍探查流程，屏幕上显示纹理和状态 |
| `probes/ios/ios/Runner/ProbePlugin.swift` | `rapp/probe` 通道：开会话、注册纹理、报 CPU/内存/电量 |
| `probes/ios/ios/Flutter/Probe.xcconfig` | 按 SDK 选 Rust 静态库路径、`-force_load` |
| `probes/ios/run.sh` | 编 Rust、编 Flutter、装到模拟器或真机、取回 `probe.jsonl` |
| `docs/superpowers/measurements/2026-11-17-rapp-ipad-p0.md`（`docs/ipad-duo` 分支） | 结论 |

---

### Task 1: `hub-ffi` 静态库

**Files：**
- Create: `rust/hub-ffi/Cargo.toml`、`rust/hub-ffi/src/lib.rs`、`rust/hub-ffi/include/rapp_hub.h`
- Modify: `rust/Cargo.toml`（members 加 `hub-ffi`）
- Test: `rust/hub-ffi/src/lib.rs` 里的 `#[cfg(test)] mod tests`

**Interfaces：**
- Produces（C ABI，名字照 spec §6.1）：
  ```c
  int32_t rapp_hub_start(const char *home, const char *log_dir, void (*on_line)(const char *line)); // 0 成功；-1 已在运行；-2 参数不是 UTF-8；-3 起运行时失败
  int32_t rapp_hub_send(const char *line);   // 0 成功；-1 没在运行
  void    rapp_hub_stop(void);               // 关输入、等 hub 结束（最多 5 秒）后返回；没在运行时什么也不做
  ```
- crate 名 `rapp-hub-ffi`，lib 名 `rapp_hub_ffi`，`crate-type = ["staticlib", "rlib"]`。
- `Opts`：`home` = 参数 `home`；`bin_dir: None`；`log: Log::file(log_dir, "hub.log")`；`presence_every: Some(30 s)`；`upgrade: UpgradeTimes::default()`。

- [ ] **Step 1：写失败的测试**

```rust
#[test]
fn hosts_round_trip_then_restart() {
    let home = tempfile::tempdir().unwrap();
    // 测试用一个全局 Mutex<Vec<String>> 收 on_line 的行
    assert_eq!(start(home.path()), 0);
    assert_eq!(start(home.path()), -1);                    // 已在运行
    assert_eq!(send(r#"{"cmd":"hosts"}"#), 0);
    assert!(wait_for(|l| l.contains(r#""event":"hosts""#), 5s));
    rapp_hub_stop();
    assert_eq!(send(r#"{"cmd":"hosts"}"#), -1);            // 已停
    assert_eq!(start(home.path()), 0);                     // 停了能再起
    assert_eq!(send(r#"{"cmd":"hosts"}"#), 0);
    assert!(wait_for(|l| l.contains(r#""event":"hosts""#), 5s));
    rapp_hub_stop();
}
```

`start`、`send`、`wait_for` 是测试里的小帮手（转 `CString`、轮询收到的行）。只写这一个测试：全局状态让多个测试并行跑会互相干扰。

- [ ] **Step 2：跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-hub-ffi`
Expected: 编不过（函数还没有）。

- [ ] **Step 3：实现**

全局 `Mutex<Option<Running>>`；`Running` 持有 tokio 多线程运行时、输入管道的写端（`tokio::io::duplex` 的一端，或 `mpsc` 接一个 `StreamReader`）和 hub 任务的 `JoinHandle`。输出端由一个任务按行读出，转 `CString` 调 `on_line`。`stop` 丢掉写端（等于关 stdin），在运行时上 `block_on` 等 `JoinHandle`（超时 5 秒），然后 `shutdown_timeout`。头文件 `include/rapp_hub.h` 手写，和上面三行一致。

- [ ] **Step 4：跑测试，确认通过；桌面 hub 测试照常**

Run: `cd rust && cargo test -p rapp-hub-ffi && cargo test -p rapp-hub`
Expected: 全部 PASS。

- [ ] **Step 5：编两个 iOS 目标**

Run: `cd rust && cargo build --release -p rapp-hub-ffi --target aarch64-apple-ios && cargo build --release -p rapp-hub-ffi --target aarch64-apple-ios-sim && ls -la target/aarch64-apple-ios*/release/librapp_hub_ffi.a`
Expected: 两个 `.a` 都在。记下大小（进结论 Q1）。编不过时：记下报错的 crate，按 spec §6.1 的退路（`rapp-term` 分 feature）处理，并写进结论。

- [ ] **Step 6：提交**

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/hub-ffi
git commit -m "probe(ios): hub-ffi, the hub in-process behind three C functions"
```

---

### Task 2: Swift 包在 iOS 上编过

**Files：**
- Modify: `Package.swift`、`Sources/RappCore/Windows.swift`、`Sources/RappCore/DataPaths.swift`、`Sources/RappSession/{Detach,RemoteView,PopupPanel,KeyRouting,Sender,LocalPasteboard}.swift`，以及编译器报出来的引用它们的地方
- Test: 已有的 `RappCoreTests`、`RappSessionTests`

**Interfaces：**
- Produces：iOS 上可用的 `EmbeddedSession(address:choice:backingScale:link:pasteboard:queue:downloads:)`、`WindowSurfaces.latest(_:)`、`Connection(address:queue:)`、`LocalPasteboard()`（UIKit 版：`write(text:)`、`string`，其余方法在 iOS 上返回空或什么也不做）。签名和 macOS 一致。

规则：只加 `#if os(macOS)` / `#if canImport(AppKit)` / `#if canImport(UIKit)`，macOS 上编出来的代码一个字节都不变。AppKit 的 `Detach`、`RemoteView`、`PopupPanel`、`KeyRouting` 整个文件包起来；`Sender` 只用了 `UTType`，把 `import AppKit` 换成 `#if canImport(AppKit) import AppKit #endif`；`Windows.swift` 里的 `CGWindowLevel…` 和 `DataPaths.swift` 里的 `homeDirectoryForCurrentUser` 用 `#if os(macOS)` 包住，iOS 分支用 `FileManager.default.homeDirectoryForCurrentUser` 的等价物 `NSHomeDirectory()`。

- [ ] **Step 1：确认现在在 iOS 上编不过**

Run: `xcodebuild -scheme RappSession -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratchpad>/dd build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD FAILED`，报 `CGWindowLevelKey`、`homeDirectoryForCurrentUser`、`AppKit`。

- [ ] **Step 2：改 `Package.swift` 和条件编译，直到 iOS 模拟器、iOS 真机两个目标都编过**

Run: 上面的命令，再把 destination 换成 `generic/platform=iOS` 跑一次。
Expected: 两次都是 `BUILD SUCCEEDED`。

- [ ] **Step 3：RappCore 测试在 iOS 模拟器上跑**

Run: `xcodebuild test -scheme RappCore -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -derivedDataPath <scratchpad>/dd 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`。scheme 名不对时用 `rapp-Package` 加 `-only-testing:RappCoreTests`。不能在 iOS 上跑的测试（用了 AppKit 或 macOS 路径的）用 `#if os(macOS)` 跳过，跳过了哪几个写进结论。

- [ ] **Step 4：macOS 上照常**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: 全部通过，和 main 上的测试数一致。

- [ ] **Step 5：提交**

```bash
git add Package.swift Sources
git commit -m "probe(ios): RappCore and RappSession build for iOS"
```

---

### Task 3: 探查 App：hub 进程内（回答 Q2）

**Files：**
- Create: `probes/ios/`（`flutter create --platforms=ios --org com.rapphub.rapp --project-name rapp_probe probes/ios`，包标识改成 `com.rapphub.rapp.probe`），`lib/ffi_hub.dart`、`lib/probe_log.dart`、`lib/main.dart`、`ios/Flutter/Probe.xcconfig`、`run.sh`
- Modify: `probes/ios/pubspec.yaml`（依赖 `rapp: {path: ../../gui}`）、`ios/Flutter/{Debug,Release}.xcconfig`（`#include "Probe.xcconfig"`）、`ios/Runner/Info.plist`（`NSLocalNetworkUsageDescription`："连接同一网络里你自己的电脑"）
- Test: `probes/ios/test/ffi_hub_test.dart`（不要 FFI 的部分）

**Interfaces：**
- Consumes：Task 1 的三个 C 函数；`package:rapp/hub_client.dart` 的 `HubTransport`、`HubClient`、`HubSession`、`AppList`。
- Produces：
  - `class FfiHubTransport implements HubTransport { static FfiHubTransport start({required String home, required String logDir}); }`，用 `DynamicLibrary.process()` 查符号，`NativeCallable<Void Function(Pointer<Utf8>)>.listener` 收行。`send` 去掉末尾的 `\n` 再交给 `rapp_hub_send`（hub 那边按行读，管道里补回 `\n`——由 Task 1 的 `send` 负责补）。`close()` 调 `rapp_hub_stop` 并关掉 `NativeCallable`。
  - `class ProbeLog { static Future<ProbeLog> open(); void write(String kind, Map<String, Object?> data); }`：每行 `{"t": <自启动起的毫秒>, "wall": <ISO 时间>, "kind": ..., ...data}`，写到 `<Documents>/probe.jsonl`，同时 `print`。
- 数据根：`<HOME>/Library/Application Support/rapp`，hub 的 `home` 用它下面的 `local/`（和桌面 `config::local(root)` 一致），日志目录 `<root>/logs`。启动时如果 `local/service.json` 不存在，就用 `String.fromEnvironment('RAPP_RELAY')`、`String.fromEnvironment('RAPP_KEY')` 写一个 `{"relay":..,"key":..}`（权限 600）。
- Probe.xcconfig：
  ```
  RAPP_RUST_TARGET = $(SRCROOT)/../../../rust/target
  RAPP_HUB_LIB[sdk=iphoneos*] = $(RAPP_RUST_TARGET)/aarch64-apple-ios/release/librapp_hub_ffi.a
  RAPP_HUB_LIB[sdk=iphonesimulator*] = $(RAPP_RUST_TARGET)/aarch64-apple-ios-sim/release/librapp_hub_ffi.a
  OTHER_LDFLAGS = $(inherited) -force_load $(RAPP_HUB_LIB) -lc++ -framework Security -framework SystemConfiguration
  ```
  （缺哪个系统库照链接报错补。）

- [ ] **Step 1：写失败的测试**——`FfiHubTransport` 里拆出一个纯函数 `String toHubLine(String line)`（去掉末尾 `\n`，中间的换行原样留着让 hub 报错）：

```dart
test('toHubLine drops one trailing newline only', () {
  expect(toHubLine('{"cmd":"hosts"}\n'), '{"cmd":"hosts"}');
  expect(toHubLine('{"cmd":"hosts"}'), '{"cmd":"hosts"}');
  expect(toHubLine('a\n\n'), 'a\n');
});
```

- [ ] **Step 2：跑测试，确认失败**

Run: `cd probes/ios && ~/development/flutter/bin/flutter test test/ffi_hub_test.dart`
Expected: FAIL（`toHubLine` 没定义）。

- [ ] **Step 3：实现 `ffi_hub.dart`、`probe_log.dart` 和 `main.dart` 的第一段流程**

`main.dart` 启动后自动跑，每一步写一行日志：`hub_start` → `HubClient.hosts()`（记下从启动到回答的毫秒）→ 连发 20 次 `hosts`，记下收齐用了多久（Review Focus 2）→ 屏幕上列出设备。

- [ ] **Step 4：测试通过**

Run: `cd probes/ios && ~/development/flutter/bin/flutter test`
Expected: PASS。

- [ ] **Step 5：在 iOS 模拟器上跑通 Q2**

`run.sh sim`：编两个 Rust 目标 → `flutter build ios --simulator --debug --dart-define-from-file=<scratchpad>/probe-defines.json` → `xcrun simctl install`、`launch --console-pty` → 30 秒后用 `xcrun simctl get_app_container ... data` 取回 `Documents/probe.jsonl`。
Expected: 日志里有 `hosts` 回答，设备表里有这台 Mac（`Bruces-MacBook-Pro`），20 次请求收齐；`hub.log` 里没有 `panic`（Review Focus 1）。

- [ ] **Step 6：提交**（不提交 `probe-defines.json`；在 `probes/ios/.gitignore` 里加 `*.defines.json`）

```bash
git add probes/ios
git commit -m "probe(ios): Flutter probe app runs the hub in-process over dart:ffi"
```

---

### Task 4: 一路纹理（回答 Q3 的"能不能"）

**Files：**
- Create: `probes/ios/ios/Runner/ProbePlugin.swift`
- Modify: `probes/ios/ios/Runner/AppDelegate.swift` 或 `SceneDelegate.swift`（注册插件）、`Runner.xcodeproj/project.pbxproj`（加本地 Swift 包：仓库根，产品 `RappSession`）、`probes/ios/lib/main.dart`

**Interfaces：**
- Consumes：Task 2 的 `EmbeddedSession`、`WindowSurfaces`、`Connection`、`RemoteAddress(host:port:bundleID:token:mode:fps:)`、`DensityChoice`、`SessionEvent`；Task 3 的 `HubClient.apps(id)`、`HubClient.open(id, app, embed: true)`。
- Produces：`rapp/probe` 通道
  - Dart → Swift：`start {port, token, mode, fps, density}` → `true`；`stats` → `{cpu: Double(%，进程全部线程合计), mem_mb: Double(phys_footprint), battery: Double(0–1，-1 不可用), state: "charging"|"unplugged"|...}`；`close`。
  - Swift → Dart：`texture {window: Int, id: Int, w: Int, h: Int}`（新窗口注册了纹理）、`event {kind: String}`（`SessionEvent` 的名字，`closed` 时带 `reason`）、`frames {n: Int, bytes: Int}`（每秒一次）。
  - 纹理类就是 macOS `SurfaceTexture` 的同一写法（`copyPixelBuffer` 返回 `surfaces.latest(window)`），用 `import Flutter`。
  - CPU 用 `task_threads` + `thread_basic_info` 合计 `cpu_usage`；内存用 `task_vm_info.phys_footprint`；电量开 `UIDevice.isBatteryMonitoringEnabled`。启动后 `UIApplication.shared.isIdleTimerDisabled = true`。

- [ ] **Step 1：A 端准备**（这台 Mac 就是 A，`rapp-service` 已在跑）

Run: `bash scripts/testpage-app.sh && open -n .build/RappTestPage.app --args --clip`
Expected: 屏幕上出现 1280×720 的测试页，在播动画。

- [ ] **Step 2：实现 `ProbePlugin.swift` 和 `main.dart` 的第二段流程**

`hosts` 之后：`apps(<那台 Mac 的 id>)` → `open(id, 'dev.rapp.testpage', embed: true)` → `rapp/probe.start`（`mode` 用 `color16`、`fps` 30、`density` `original`，和 `2026-11-14-baseline.md` 同一档）→ 收到 `texture` 后屏幕上铺一个 `Texture(textureId:)`，按 `w`×`h` 等比缩放。每秒调一次 `stats`，连同 `frames` 写日志 `stats`。

- [ ] **Step 3：模拟器上出画面**

Run: `probes/ios/run.sh sim 60`（跑 60 秒取回日志），再 `xcrun simctl io booted screenshot <scratchpad>/p0-sim-texture.png`
Expected: 截图里是测试页的画面；日志里 `frames.n` 每秒大于 0。

- [ ] **Step 4：提交**

```bash
git add probes/ios
git commit -m "probe(ios): one embedded session drawn as a Flutter texture"
```

---

### Task 5: 窗口大小、开合、前后台（回答 Q4、Q5）

**Files：**
- Modify: `probes/ios/lib/main.dart`（加日志：`MediaQuery` 的 `size`、`padding`、`viewPadding`、`displayFeatures` 每次变化写一行 `window`；`AppLifecycleListener` 的每个状态写一行 `life`；一个 1 秒的 `Timer` 写 `tick`；后台恢复流程）

**Interfaces：**
- Consumes：Task 4 的通道和日志。
- 恢复流程（spec §9.1–9.2 的最小版）：`hidden`/`paused` 时 `HubClient.close(sid)` 并停 `stats`；`resumed` 时发 `{"cmd":"net_suspect"}`，再 `open(..., reconnect: true)` → `start`，记下 `resumed` 到第一个 `frames.n > 0` 的毫秒（`resume_to_frame`）。在新的 `opened` 到达之前不对旧 sid 发任何东西（Review Focus 4）。

- [ ] **Step 1：iPad 模拟器**

在 `iPad Pro 11-inch (M5)` 上跑，用 `osascript` 让 Simulator 执行"Device → Rotate Left"一次、再转回来。
Expected: 日志里有横竖两个 `window` 尺寸和安全区。

- [ ] **Step 2：Duo 模拟器**

在 `iPhone Duo` 上跑，用 Simulator 菜单（`osascript` 点菜单；菜单项名照 Xcode 27.2 实际的写）依次：内屏竖、内屏横、合上（外屏竖）、外屏横、再展开。
Expected: 每个状态一行 `window`；开合过程中的 `window` 序列（中间有几次变化、间隔多少毫秒）原样记下；`life` 在开合过程中是否离开 `resumed`；`displayFeatures` 是否为空（核对 F9）。菜单里没有开合命令时写明"模拟器不能开合"，Q4 的开合序列留给真机，记进 `tasks/todo.md`。

- [ ] **Step 3：前后台（模拟器）**

App 在流画面时，`xcrun simctl launch booted com.apple.Preferences` 切走，等 10 秒、30 秒、120 秒三轮，每轮再 `simctl launch` 探查 App 回来。
Expected: `tick` 的断档就是被挂起的时长（模拟器可能不挂起，照实写）；回来后 hub 报的事件和 `resume_to_frame`。

- [ ] **Step 4：提交**

```bash
git add probes/ios
git commit -m "probe(ios): log window sizes, lifecycle and resume time"
```

---

### Task 6: 真机 iPhone 12 mini 实测（回答 Q3 的数、Q5、Q6），和 macOS 对比

**Files：**
- Modify: `probes/ios/run.sh`（加 `device` 子命令：`flutter build ios --release`、`xcrun devicectl device install app`、`devicectl device process launch`、`devicectl device copy from --domain-type appDataContainer` 取回 `probe.jsonl`）
- Create: `probes/ios/mac-baseline.sh`（macOS 对比：起 `rapp-hub`，用 JSON 行打开同一个测试页的非嵌入会话，hub 拉起 `rapp-client`，每秒用 `ps -o %cpu=,rss= -p <rapp-client>` 采样 5 分钟）

**Interfaces：**
- Consumes：Task 3–5 的全部日志项。签名用钥匙串里的 `Apple Development` 身份（团队 ID 照 `security find-identity` 和证书里的 OU 填进 `DEVELOPMENT_TEAM`）。

- [ ] **Step 1：装到真机、流 20 分钟**

`probes/ios/run.sh device 1200`：手机要解锁并保持亮屏（App 里已关自动锁屏）。设备锁着导致启动失败时，停在这一步，在最后的汇报里请用户解锁后再跑这一步。
Expected: 取回的 `probe.jsonl` 有约 1200 行 `stats`。

- [ ] **Step 2：真机前后台**

流画面时用 `devicectl device process launch --device <id> com.apple.Preferences` 切走，10 秒、30 秒、120 秒各一轮，再启动探查 App 回来。
Expected: `tick` 断档 = 挂起时长；hub 回来时看到的是连接超时还是立刻报错（看 `event`、`hub.log`）；`resume_to_frame`。

- [ ] **Step 3：Q6 的三件事**

- "本地网络"弹框：截一张真机屏（`devicectl` 不能截屏时，看日志里 hub 报的路径事件推断）；记下第一次出现的时机（第一次 `hosts`、还是第一次连 A）、没人点时最后走的路径（`path` 事件）。
- 只往外拨要不要先登记：Task 3 的 `hosts` 里能看到 A、Task 4 能打开会话，就是"不用"；再读 `rust/conn/src/relay.rs` 的拨号路径，写下依据（函数名和行号）。A 的访问记录和 `PeerNames` 里这台手机显示成什么名字（`rapp_net::config::hostname()` 在 iOS 上拉起 `hostname` 子进程会失败，预计退回 `rapp`）。
- hub 有没有用组播或广播：`rg -n "multicast|broadcast|join_multicast|set_broadcast" rust/hub rust/conn rust/net rust/wire` 的结果。

- [ ] **Step 4：macOS 对比**

Run: `bash probes/ios/mac-baseline.sh 300`（测试页同样 `--clip`、`color16`、30 fps、`original`）。
Expected: `rapp-client` 的 CPU 中位数、内存。和真机的 CPU 中位数对比，按 spec P0 过关条件"不比 macOS 上同一档高出一倍以上"判定。M5 和 A14 不是同档芯片，结论里写明这一点和判定依据。

- [ ] **Step 5：提交**

```bash
git add probes/ios
git commit -m "probe(ios): device run, resume rounds and the macOS baseline script"
```

---

### Task 7: 结论文档和收尾（`docs/ipad-duo` 分支）

**Files：**
- Create: `docs/superpowers/measurements/2026-11-17-rapp-ipad-p0.md`
- Modify: `docs/superpowers/specs/2026-11-17-rapp-ipad-duo-design.md`（只改和实测不符的事实：§4 的 `Platform.is…` 个数、§6.3"RappCore 不改代码"、§14.1 的 Xcode/Flutter 版本，以及 P0 推翻的任何一条）、`tasks/todo.md`（真机 iPad、Duo 上要补量的项）

- [ ] **Step 1：写结论文档**

结构：机型和提交号 → Q1–Q6 各一节（结论一句、证据表、命令）→ 过关判定（1–3 是否走通、CPU 倍数）→ P1 要带上的发现（比如 `hostname()`、跳过的测试、链接要的系统库）→ 没量到的和原因。数字照实写，未通过的写未通过。

- [ ] **Step 2：改 spec、加待办，检查格式**

Run: `git diff --stat`
Expected: 只动了上面三个文件。

- [ ] **Step 3：提交并交给 rapp-49**

```bash
git add docs tasks
git commit -m "docs: iPad/Duo spec, P0 probe plan and its measurements"
```

用 `ListAgents` 找到 rapp-49，`SendMessage` 告诉它：`docs/ipad-duo` 要合入（只有文档）；`probe/ipad-p0` 是探查分支，不合入，留给 P1 取用；主工作目录里那份未跟踪的 spec 和分支里的是同一份，合并前要先删掉它。
