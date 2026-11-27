# rApp 安卓平板版设计

日期：2026-11-27
状态：用户已核对（2026-11-27），P0 计划已写，待执行
分支：`docs/android-tablet-design`
相关规格：iPad 和 Duo（`2026-11-17-rapp-ipad-duo-design.md`，下文叫「iPad 规格」）、Windows（`2026-11-26-rapp-windows-design.md`，下文叫「Windows 规格」）、iOS 内置输入法（`2026-11-20-rapp-ios-rime-ime-design.md`）

名词：**A** 是被控的电脑，**B** 是操作的那一端。安卓平板只做 B。

---

## 0. 已定的（来自用户，2026-11-27）

| # | 事 | 定的 |
|---|---|---|
| U1 | 做什么 | 安卓平板版，和 iPad、iPhone 一样只做 B；被控（服务端）能力先研究，做不了就不做 |
| U2 | 最低版本 | 安卓 **14**（API 34）。iOS、iPadOS 不动，仍是 17.0 |
| U3 | 目标设备 | 手上还没有设备，先按通用写：不依赖 Google 服务，实机验收等买了设备再做 |
| U4 | 后台 | 和 iPad 一样：进后台就冻结并断开，回前台自动重连；不做前台服务、不挂常驻通知 |
| U5 | 分发和更新 | APK 随每次发版放到 GitHub release 和网站；App 里「检查更新」下载 APK，交给系统安装 |
| U6 | 语音 | 用系统的识别器；设备上没有能识别中文的识别器，就不显示语音按钮 |
| U7 | 输入法 | 第一版用系统输入法，不内置 Rime；「直接打字=英文、写作版=中文」的自动切换安卓上没有 |
| U8 | 外接键盘的 ⌘ | 跟 Linux 版一样：Ctrl 当 ⌘，写作版用 Ctrl+Enter，Meta 键留给安卓系统 |

U2 的由来：用户问提到 14 能不能省兼容代码。实情是省的代码很少（Flutter 和 Rust 不管安卓版本，只有 Kotlin 壳里几处），省的主要是测试范围（只测 14–17）。代价见 §3.2。用户选了 14。

## 1. 为什么做

用户要在安卓平板上像在 iPad 上一样操作自己的电脑：看全景、进桌面和单应用会话、开终端、用输入块和语音打字。安卓平板便宜、型号多，是 iPad 之外最常见的大屏触摸设备。

## 2. 目标、不做、不能出现

### 2.1 目标

1. 安卓平板上装一个 APK，输入 relay 地址和密钥后，能看到自己的设备，接入桌面会话、单应用会话和文本终端。
2. 触摸、外接键盘、鼠标和触控板的操作方式和 iPad 版一致；同样大小的窗口，排版和 iPad 版一致。
3. 输入块、键条、常用语条、输入历史、AI 整理和 iPad 版一致；语音按 U6。
4. 进后台、回前台、断线重连的表现和 iPad 版一致（U4）。
5. 每次发版同时出 APK，App 内能更新（U5）。
6. 共用代码多、安卓专有代码少：画面解码和协议用现有的 Rust（`rapp-client-core`），不写第三份协议实现；hub 用现有的 `rapp-hub`，不改它的逻辑。

### 2.2 不做（第一版）

- 被控能力（别人接入这台平板）。原因见 §3.1。
- 后台保活、通知、锁屏小组件、桌面小组件。
- 内置输入法、输入法自动切换（U7）。
- 应用商店上架（Google Play 和国内各家商店）。
- 手机排版的验收。APK 不拦手机安装，手机上按 iPhone 的排版规则显示，但第一版不测、不保证。
- 多窗口（一台设备上开两个 rApp 窗口）、三星 DeX 和安卓 16 桌面窗口模式的验收。能缩放、能分屏，但只按「一个窗口」验收。
- 「分享到 rApp」（别的 App 把文件分享进来）。
- 32 位和 x86 设备。只出 `arm64-v8a`。
- 鸿蒙 5 及以后（装不了 APK）。

### 2.3 不能出现

- relay 地址、密钥或任何个人信息编进 APK。和 iOS 一样，全部在 App 里运行时输入。
- 为安卓另写一份协议编解码或另一套排版。
- 后台偷偷连着：进后台 2 秒后还有到 relay 或 A 的连接，算缺陷。
- 更新包不验哈希就交给系统安装。
- `gui/lib/` 里新增 `Platform.isAndroid` 这类判断（Windows 规格 §18.1 第 4 条）。平台差别进 `PlatformCaps`，或者放在入口文件 `main_android.dart` 和 `android_*.dart` 里。
- 改了共用代码让 Linux、macOS、iOS 的行为变了。

## 3. 平台事实

### 3.1 安卓为什么做不了被控

rApp 的被控要三样东西：不用人守着就能抓屏、能注入键鼠、锁屏后还能接入。安卓上：

- 抓屏只有 MediaProjection。每次开始都要用户在本机点同意，锁屏时系统会结束它 [S1][S2]。
- 注入输入只能靠无障碍服务，要用户手动到系统设置里打开，系统更新或省电策略会把它关掉。
- RustDesk 的安卓被控端是同一套办法，官方文档也只说是「部分无人值守」[S3][S4]。

所以安卓上做不出「放在那里随时能接入」的被控端。这和之前的决定一致（I3：移动端只做 B；端口共享 S7：移动端不对外共享端口）。

### 3.2 版本

| 版本 | 占比（2026-10）[S5] |
|---|---|
| 17 | 约 1% |
| 16 | 25.4% |
| 15 | 14.7% |
| 14 | 15.3% |
| 13 | 11.8% |
| 12 | 9.6% |

14 及以上合计约 56%。2024 年起上市的平板出厂就是 14 或更高，不少 2022–2023 年的平板也升到了 14。

装不上的：停在 12、13 的旧平板；华为鸿蒙 4.x 的平板（它的安卓兼容层一般认为是安卓 12 级别，这一条没有找到官方说明 [S6]）；鸿蒙 5 及以后本来就装不了 APK。

最低版本以后往下放容易（改一个数，再把下面几处补上退路），往上提会把已装的用户甩掉，所以先定高的。

定在 14 用得上的东西：

| 能力 | 从哪版起 | 用在哪 |
|---|---|---|
| 设备上的识别器（`createOnDeviceSpeechRecognizer`） | 12 | §11 |
| 问识别器支持哪些语言（`checkRecognitionSupport`） | 13 | §11，U6 的「能识别中文才显示」 |
| 分段连续识别、热词（`EXTRA_SEGMENTED_SESSION`、`EXTRA_BIASING_STRINGS`） | 13 | §11 |
| 触控板手势由系统分类（双指滑动、捏合） | 14 | §8.2，Flutter 用没用上要在 P0 看 |

### 3.3 其他会影响设计的事实

- **子进程会被杀**。安卓 12 起，App 派生的子进程全系统合计上限 32 个，占 CPU 多的会被系统杀掉。画面层不能照 Linux 那样每个会话一个子进程。这是 §5 选办法的决定性原因。
- **16 KB 页**。目标版本是安卓 15 及以上的 App，自带的原生库必须按 16 KB 对齐 [S7]。NDK r28 默认就是。
- **本地网络权限**。安卓 17 才开始强制，而且只管目标版本 37 及以上的 App；目标版本 36 的 App 有 `INTERNET` 就够 [S8][S9]。rApp 不做局域网发现（代码里没有组播和广播），只主动连 relay 和已知地址。
- **没有 Google 服务的设备很多**。国行平板没有 Google 的语音识别，也没有 Play。U3 要求不依赖它们。
- **第三方输入法能收到外接键盘的键**。这和 iOS 相反（iOS 内置 Rime 就是因为第三方输入法收不到），所以安卓不需要内置输入法。
- **解码是软件的**。`rapp-client-core` 的编解码是分块加 zlib，纯 Rust（`flate2` 用的是纯 Rust 后端），不用 MediaCodec。

## 4. 现状（代码里已经有的）

### 4.1 能直接用的

- **hub 进程内**：`rust/hub-ffi` 把 hub 做成库，iOS 用 `dart:ffi` 调（`gui/lib/hub_ffi.dart` 的 `FfiHubTransport`，四个函数 `rapp_hub_start`、`rapp_hub_send`、`rapp_hub_free_line`、`rapp_hub_stop`）。iOS 的选项是 `owns_access: true, embed_only: true, dual_stack: true, map_ports: Some((FIRST, COUNT))`。hub 不依赖系统证书库（没有 `rustls-native-certs` 这类包），安卓上不用做 JNI 初始化。
- **会话端口的抽象**：`gui/lib/embed/session_port.dart` 的 `SessionPort`，界面只认它。
- **触摸**：`gui/lib/embed/touch_gestures.dart`、`picture.dart`、`term/term_stage.dart` 都是 Dart，`touchPlatform()` 已经把安卓算进去。
- **外接键盘**：`LinuxSessionPort.handleKeyEvent`（里面的 `_remoteKey`）用 `PhysicalKeyboardKey.usbHidUsage` 换成 Mac 键码（`linuxMacKeyCode`）。它的规矩是 Linux 的：Ctrl 当 ⌘ 发给 A，按着 Meta 的键不发（留给本机系统），Ctrl+Enter 留给写作版。全在 Dart，不用写 Kotlin。U8 定了安卓照这个规矩。
- **文本终端**：`TermSessionPort` 纯 Dart。
- **设备类型**：`DeviceOs.androidTablet`、`androidPhone` 已有（短边 ≥ 600 算平板），全景里的系统标志已画。
- **更新清单**：`latest.json` 的格式是 `{version, published_at, notes, assets: {<平台>: {url, sha256, size}}}`，能加一个平台键。
- **iOS 入口** `gui/lib/main_ios.dart`（209 行）是安卓入口的模板。

### 4.2 画面层现在有两套

1. macOS、iOS：Swift 的 `SessionPlugin` + `RappSession` 出原生纹理，Dart 这边是 `ChannelSessionPort`。
2. Linux（Windows 计划同路）：每个会话一个 `rapp-session` 子进程。Dart 从它的标准输入发 JSON 命令，从标准输出收带长度前缀的事件（0 是 JSON，1 是一帧 BGRA，帧头 24 字节：宽、高、四个 f32 的画布矩形）。Dart 的 `LinuxSessionPort`（1621 行）把每帧做成 `ui.Image`，`picture.dart` 按窗口切着画。

`rapp-session` 的结构（`rust/client-core/src/bin/rapp-session.rs`）：

- `command(&Value) -> Result<Vec<u8>>`：JSON 命令换成协议包。
- `run(out: &Output)`：读第一行启动参数，连 `127.0.0.1:<port>`（hub 给的本机口），起两个线程（标准输入到套接字、每秒一次的探测和流量），然后进 `read_loop` 解码。
- `Output::spawn(impl Write + Send + 'static)`：输出线程，已经是对写入端泛化的，积压时只留最新一帧。

### 4.3 `LinuxSessionPort` 里绑死 Linux 的地方

| 位置 | 是什么 |
|---|---|
| `session_worker.dart`（247 行） | 起子进程、在 isolate 里读它的输出 |
| `linux_session_port.dart:484–495` | `reveal`：用 `xdg-open` 打开文件所在的文件夹 |
| `linux_session_port.dart:27, 46–47` | 环境变量 `RAPP_STREAM_TRACE_DIR`、`RAPP_DOWNLOADS`，`dataRoot(...)` |
| `linux_clipboard.dart`（187 行） | `rapp/linux` 通道读写剪贴板里的图片和文件 |
| `rapp/linux` 通道的其余方法、`supportsInlineNativeComposer => true` | 分离出去的原生 GTK 窗口用的（`init`、`focus`、`windows`、`menus`、`frame`、`clips`、`detach`、`attach`，以及把草稿交给原生输入框）。安卓没有分离窗口，全部用不上 |
| `linux_transfer.dart`（400 行） | 传文件，本身没有 Linux 专有调用，落盘目录由上面的环境变量给 |

Windows 规格 §10.2 计划把这些抽成一个小接口，归 Windows 的 C 段（控制端），还没做。

### 4.4 只有 iOS 有、安卓要对应的

| iOS 的 | 作用 | 安卓怎么办 |
|---|---|---|
| `rapp/ios` 通道（`IosPlugin.swift`） | 目录、设备名、版本、网络、常亮、全屏、分享、打开链接；事件：内存警告、网络变化 | Kotlin 写对应的通道，见 §6.4 |
| `BackgroundWatch`（`ui/background.dart`） | 进后台和回前台 | 复用，见 §9 |
| `FoldFullscreen`（`ui/fullscreen.dart`） | 折叠屏折起来时退出全屏 | 复用 |
| `rapp/unlock` 通道 | 存 A 的解锁口令 | Kotlin 用 Keystore，见 §6.4 |
| `rapp/speech` 通道 | 语音 | Kotlin 用系统识别器，见 §11 |
| `rapp_rime` 插件、`RimeLocalIme` | 内置输入法 | 不做，用 `NoLocalIme` |
| `PlatformCaps.forOs('ios')` | 能力表 | 加安卓一项，见 §6.5 |

`gui/lib` 里按 iOS 写死的判断有二十多处（清单见 §6.5），安卓现在会落进「桌面」那一支，是错的。

### 4.5 这台 Mac 上的工具

Flutter 3.44.1（`~/development/flutter/bin`，默认最低版本 24、编译和目标版本 36、NDK 28.2.13676358）。Android SDK 在 `~/Library/Android/sdk`，只有 `platforms/android-34` 和 `build-tools/35.0.0`，没有 NDK、没有模拟器和系统镜像。Rust 没装安卓目标，没有 `cargo-ndk`。`gui/android/` 不存在。有 `adb`，没有设备。

## 5. 办法

### 5.1 三条路

**甲：会话循环做成库，和 hub 放进同一个 `.so`，进程内跑（选这条）。**
把 `rapp-session.rs` 里的 `run`、`read_loop` 挪进 `rapp-client-core` 的库，输入输出泛化。Linux 的 `rapp-session` 可执行文件变薄，行为不变。安卓上由一个新 crate 把它和 hub 一起导出给 Dart。Dart 这边把 `LinuxSessionPort` 里绑 Linux 的部分抽成小接口，安卓和 Linux（以后还有 Windows）共用同一个会话端口。
- 得：协议、解码、手势、按键、传文件、剪贴板逻辑全部共用；安卓专有的只有一层薄的 FFI 和 Kotlin 壳。
- 失：每帧整张画布从 Rust 交给 Dart 再上传成纹理，高分屏平板上的帧率没有实测过。要先动共用的 Dart 代码，Linux 有回归风险。

**乙：把 `rapp-session` 打进 APK 当子进程跑。**
- 得：Dart 这边几乎不用改。
- 失：安卓 12 起子进程会被系统杀（§3.3），画面进程吃 CPU，正好是被杀的那一类。不选。

**丙：Rust 直接写进安卓的原生纹理（Flutter 的 `SurfaceProducer` + `ANativeWindow`）。**
- 得：少一次拷贝和一次上传，性能最好。
- 失：显示这一段是安卓专有的（JNI、Kotlin、像素格式转换），按窗口切画要另写。
- 处置：只作为**帧这一条路**的退路。甲里把「一帧怎么显示」收在一个接口后面，实机测出来不够快，再换成丙，命令、事件、手势都不动。

另外否掉的：用 Kotlin 重写协议和解码。那是第三份协议实现，每次协议升版要改三处。

### 5.2 分层

```
Flutter 界面（共用）
  ├─ SessionPort ── WorkerSessionPort（共用，现在的 LinuxSessionPort 改名）
  │                   ├─ SessionLink：发一行命令，收一条事件或一帧
  │                   │     ├─ ProcessSessionLink（Linux，以后 Windows）：子进程
  │                   │     └─ FfiSessionLink（安卓）：进程内
  │                   └─ SessionHost：落盘目录、打开文件、剪贴板、追踪目录
  │                         ├─ LinuxSessionHost
  │                         └─ AndroidSessionHost
  ├─ HubTransport ── FfiHubTransport（iOS、安卓共用，只差「库从哪里找」）
  └─ 平台通道 ── Kotlin 壳（rapp/android、rapp/unlock、rapp/speech）

librapp_android.so（Rust）
  ├─ rapp-hub-ffi 的四个函数
  └─ 会话的五个函数 → rapp-client-core::session
```

接口和类的名字是建议，最后以先落地的那一方为准（见 §14.3 和 Windows 的 C 段怎么对）。

## 6. 架构细节

### 6.1 hub

- hub 的代码不改。选项和 iOS 相同：`owns_access: true, embed_only: true, dual_stack: true, map_ports`。
- `FfiHubTransport` 现在用 `DynamicLibrary.process()`（iOS 是静态链接）。安卓要 `DynamicLibrary.open('librapp_android.so')`。做法：构造时传入库，iOS 传 `process()`，安卓传 `open(...)`；`_stopOffThread` 里那一处也要跟着改。这不是平台判断，是入口各自传参。
- **要在 P0 看的**：`rust/net/src/quic.rs` 的 `sys` 模块说「只有 iOS 的 hub 用」，非苹果系统走 `AI_V4MAPPED | AI_ADDRCONFIG`。安卓的 C 库对 `AI_V4MAPPED` 的支持不确定。P0 要在纯 IPv4、双栈两种网络下各连一次 relay。不行就给安卓单独一支。
- `cfg(target_os = "linux")` 在安卓上**不成立**（安卓是 `target_os = "android"`），`cfg(unix)` 成立。共用 crate 里按 Linux 写的分支不会编进安卓；P0 要确认没有哪段是安卓也需要的。

### 6.2 会话库（Rust）

`rapp-client-core` 加一个库模块 `session`，从 `bin/rapp-session.rs` 挪过来：

```rust
/// input：一行一条 JSON 命令，第一行是启动参数。out：事件和帧的去处。
pub fn run(input: impl BufRead + Send + 'static, out: &Output) -> Result<()>
```

- `command`、`read_loop`、`Probe`、`is_input` 跟着挪。`Output`（`bin/session_output/`）和 `session_trace` 一起进库。
- `bin/rapp-session.rs` 只剩 `main`：标准输入、标准输出接到 `session::run`。Linux 上的行为、输出格式一个字节都不变，现有测试照跑。
- `session_trace` 读环境变量的部分留在可执行文件那一侧，库里只收「追踪目录」这个参数。

新 crate `rust/android-ffi`（包名 `rapp-android-ffi`，库名 `rapp_android`，`crate-type = ["cdylib"]`），进 workspace：

```rust
pub use rapp_hub_ffi::{rapp_hub_start, rapp_hub_send, rapp_hub_free_line, rapp_hub_stop};

/// 开一个会话。start 是启动参数的 JSON（和 rapp-session 的第一行相同）。
/// 返回会话号，0 是失败。sink 在库自己的线程上被调用。
#[no_mangle] pub extern "C" fn rapp_session_open(start: *const c_char, sink: Sink) -> u64;
/// 发一条命令（一行 JSON）。0 成功，负数失败。
#[no_mangle] pub extern "C" fn rapp_session_send(id: u64, line: *const c_char) -> i32;
/// Dart 处理完一帧后调，库才交出下一帧。
#[no_mangle] pub extern "C" fn rapp_session_ack(id: u64);
/// 结束会话，等它的线程退出（最多 2 秒）。
#[no_mangle] pub extern "C" fn rapp_session_close(id: u64);
/// 归还 sink 收到的内存（libc 的 malloc 分配的）。只收指针一个参数：Dart 的收尾函数只带一个参数。
#[no_mangle] pub unsafe extern "C" fn rapp_session_free(ptr: *mut c_void);

/// kind：0 是事件，1 是帧，2 是会话结束（ptr 空、len 0，每个会话恰好一次，是最后一次回调）。
/// 0 和 1 时 ptr 指向的内容和管道里的一个包一模一样：第一个字节是 0 或 1，
/// 后面是事件的 JSON 或「24 字节帧头 + BGRA」。这样 Dart 的读循环两条路共用，帧不用拷贝。
type Sink = extern "C" fn(id: u64, kind: u8, ptr: *mut u8, len: usize);
```

要守的规矩：

1. **一次只有一帧在路上，顺序和管道一样**。子进程那条路靠管道写满来挡住发送方，进程内没有管道。`NativeCallable.listener` 是往 Dart 的消息队列里投，永远不会挡，不管的话 Dart 慢一点帧就会在内存里堆起来。做法是学管道：`Output` 不改，给它的写入端是一个带闸的东西，交出一帧后闸关上，下一条（不管是事件还是帧）等 `rapp_session_ack` 才交。`Output` 的队列照旧保序（描述一帧的窗口表事件永远排在那一帧前面），积压时照旧只留最新一帧，事件照旧受 `MAX_EVENTS = 32` 的上限。Dart 拿到一帧、做成图片或决定丢掉之后就 ack，不等画到屏幕上。`rapp_session_close` 要能把卡在闸上的写入端放开。
2. **恐慌不能穿过 FFI**。每个 `extern "C"` 函数和每个库线程的入口包一层 `catch_unwind`，出事就给 sink 发一条 `kind = 2`。
3. **内存归还**。sink 拿到的内存由 Dart 用完后经 `rapp_session_free` 归还（`asTypedList(len, finalizer: …)`）。Dart 一侧已经关掉的会话，后到的消息直接归还。
4. 会话线程连的还是 `127.0.0.1:<port>`，和子进程时一样，hub 不用知道有区别。
5. 这个 crate 在 Mac 上也能编、能测（对着本机回环起一个假的 A），进 `cargo test --workspace` 和 clippy。Windows 的门禁上它也要能编；编不过就用 `cfg` 把内容在 Windows 上置空，不要把它移出 workspace。

`pub use` 重新导出的 `#[no_mangle]` 函数会不会真的出现在 `.so` 的导出表里，P0 用 `llvm-nm -D` 看；没有就在这个 crate 里用一个 `#[used]` 的静态量引用这四个函数。不能写四个同名的转调函数，名字会和 `rapp-hub-ffi` 里的撞。

### 6.3 会话端口（Dart）

- `LinuxSessionPort` 改名 `WorkerSessionPort`（文件 `worker_session_port.dart`），构造时收两样：一个造 `SessionLink` 的函数，一个 `SessionHost`。
- `SessionLink`：`send(String line)`、`messages`（事件或帧）、`ack()`（Linux 那边是空操作）、`close()`。`ProcessSessionLink` 包现在的 `SessionWorker`；`FfiSessionLink` 包 §6.2 的函数。
- `SessionHost`：传文件落盘目录、`reveal`（去看收到的文件）、读写剪贴板（文字、图片、文件）、追踪目录、分离窗口那一组（§4.3 表最后一行）。`LinuxSessionHost` 装下 §4.3 表里的东西；`AndroidSessionHost` 见 §8.5、§8.6，分离窗口那一组全是空的，`supportsInlineNativeComposer` 和 `supportsDetach` 是否。
- **按哪个平台的表现验收**：用户看得见的表现以 iPad 为准（§2.1），端口内部的做法沿用 Linux 的。两个端口（`ChannelSessionPort` 加 Swift，和 `LinuxSessionPort`）表现不一样的地方，P1 动手前先列一张差别表（复制和钉住、剪贴板挑选、附件和粘贴、传文件、输入框），每行写安卓取哪边。能用少量代码对齐 iPad 的就对齐；对不齐或者代价大的，回来问用户，不自己定。按键例外，按 U8 跟 Linux。
- `dropTextures`（内存紧张时放掉不在台上的会话的画面）现在只有 Swift 那边实现了，`LinuxSessionPort` 没有。安卓要用（§9.3），在共用端口里补上：放掉那个会话缓存的 `ui.Image`。
- 帧的显示收在一个接口后面（建议叫 `FrameSink`）：现在唯一的实现是「整帧做成 `ui.Image`」。丙落地时加第二个实现。
- 按键：`handleKeyEvent` 原样用。`linuxMacKeyCode` 改个不带 Linux 的名字。
- `main.dart` 里选端口的那一行（`Platform.isLinux ? LinuxSessionPort(...) : ChannelSessionPort()`）在桌面入口，改成造 `WorkerSessionPort(ProcessSessionLink…, LinuxSessionHost())`。
- **这一步是纯重构**：单独一个分支、单独合并，不带任何安卓代码。合并条件：Mac 门禁全过；Linux 上实机走一遍会话（接入、打字、拖动、复制粘贴、传文件）。Linux 实机验不了就不合并，写进 `tasks/todo.md` 等另一台机器验。

### 6.4 Kotlin 壳

`gui/android/`（`flutter create --platforms=android` 生成后改）。应用 ID `com.rapphub.rapp`（和 iOS 一致）。一个 Activity，`resizeableActivity="true"`，方向不锁，`configChanges` 用 Flutter 模板的整套（旋转、分屏、折叠时不重建）。

通道 `rapp/android`，方法名和 `rapp/ios` 对齐，Dart 一侧抽一个两边都实现的接口（建议 `MobileChannel`，`IosChannel` 实现它，另加 `AndroidChannel`），`BackgroundWatch`、`FoldFullscreen` 改收这个接口：

| 方法 | 安卓怎么做 |
|---|---|
| `paths` | 数据根 `filesDir/rapp`，缓存 `cacheDir` |
| `deviceName` | `Settings.Global.DEVICE_NAME`，取不到用 `Build.MODEL` |
| `idiom` | 不用（Dart 按短边算） |
| `version` | `PackageInfo` 的 `versionName` 和 `longVersionCode` |
| `net` | 永远返回可用。iOS 那个是查「无线数据」被拒，安卓没有这回事 |
| `openSettings` | 打开本 App 的系统设置页 |
| `keepAwake` | `FLAG_KEEP_SCREEN_ON` 加上或去掉 |
| `sessionActive` | 空操作 |
| `fullscreen` | 沉浸模式：藏状态栏和导航栏，边缘滑一下暂时显出来 |
| `beginBackground`、`endBackground` | 空操作（见 §9.1） |
| `share` | `ACTION_SEND` + `FileProvider` |
| `openUrl` | `ACTION_VIEW` |
| `pickFiles`（新） | `ACTION_OPEN_DOCUMENT`，可多选；选中的文件拷到缓存目录，返回路径 |
| `publishDownload`（新） | 把一个文件经 MediaStore 放进系统「下载/rApp/」，返回能打开它的地址 |
| `openFile`（新） | 用系统里能开它的 App 打开（`ACTION_VIEW` + `FileProvider`） |
| `showDownloads`（新） | 打开系统的「下载」列表（`DownloadManager.ACTION_VIEW_DOWNLOADS`）；`reveal` 在安卓上就是它 |
| `clipboardRead`、`clipboardWrite`（新） | 剪贴板里的图片；文字走 Flutter 自带的 `Clipboard` |
| `installApk`（新） | 见 §13 |
| `canInstall`、`openInstallSettings`（新） | 查、去开「允许安装未知应用」 |
| 事件 `memoryWarning` | `onTrimMemory` 到 `RUNNING_CRITICAL` 及以上 |
| 事件 `pathChanged` | `ConnectivityManager.registerDefaultNetworkCallback` |

通道 `rapp/unlock`（方法 `save`、`forget` 等，和 iOS 的同名同参）：口令用 Android Keystore 里的一把 AES-GCM 密钥加密，密文放 `filesDir`。`UnlockStore` 里 `supported` 的判断（`unlock.dart:22`）改成从 `PlatformCaps` 取。

通道 `rapp/speech`：见 §11。

权限（清单里声明的全部）：`INTERNET`、`ACCESS_NETWORK_STATE`、`RECORD_AUDIO`（第一次按语音时才问）、`REQUEST_INSTALL_PACKAGES`。不要存储权限（MediaStore 写「下载」不需要），不要通知权限，不要前台服务。

其他清单设置：`android:allowBackup="false"`，并在 `dataExtractionRules` 里排除全部数据（身份密钥不能被云备份或换机克隆到另一台设备上）；网络安全配置只对 `localhost` 和 `127.0.0.1` 放行明文（AI 整理走本机的 `localhost:28001`）；`minSdk 34`、`compileSdk` 和 `targetSdk` 36（Flutter 默认）。**把目标版本升到 37 之前，先看本地网络权限**（§3.3）。

### 6.5 能力表和写死的判断

`PlatformCaps.forOs` 加：

```dart
'android' => const PlatformCaps(hubInProcess: true, systemOpen: true, onlineUpdate: true),
```

`onlineUpdate` 在安卓上的数据来源和界面位置都不同，见 §13.2。现在这个能力位的两处用法（`main_window.dart:411` 的红点、`pages/global_sections.dart:64` 的「版本与升级」行）读的都是 `ServiceMonitor` 的状态，安卓没有 service，`GlobalSections` 也不会出现（`main_window.dart:391`）。

`pinchZoom`、`hardwareKeyboard()` 现在只认 iOS，改成认「触摸平台」（`touchPlatform`）。

下面这些地方现在写的是 iOS，要逐个看：是「触摸设备都这样」就改成能力位或 `touchPlatform`，是「只有 iOS 这样」就保持。结论写进计划，每处一行：

`ui/unlock.dart:22`、`ui/main_state.dart:211, 951, 960, 4726`、`ui/tokens.dart:312`、`ui/main_window.dart:43, 142`、`ui/open_apps_menu.dart:26`、`ui/side_panel.dart:264`、`ui/log_screen.dart:143`、`ui/resources_tab.dart:67`、`service_client.dart:389`、`embed/flutter_editor.dart:19`、`embed/composer_panel.dart:140, 556, 763, 880`、`embed/voice_tidy_card.dart:542`、`embed/input_dock.dart:212`、`embed/voice_button.dart:61`、`term/term_stage.dart:49`、`main.dart:38`、`data_dir.dart:205`、`pages/app_profile_page.dart:445, 455`、`pages/local_section.dart:43`、`pages/data_section.dart:54`。

（行号是 2026-11-27 `5e39bb91` 上的，动手前重新搜一遍。）

需要新能力位就加，名字说的是能力不是平台，比如 `localIme`（有没有本机输入法切换）、`secretStore`（有没有地方存解锁口令）、`mobileShell`（走移动端外壳）。

入口：`main.dart:38` 现在是 `if (Platform.isIOS) return mainIos();`，加一行安卓的。`main_android.dart` 照 `main_ios.dart` 写：取目录和设备名、起进程内 hub、造 `WorkerSessionPort`、`localIme: NoLocalIme()`、语音按 §11 决定给不给。两个入口重复的部分抽到一个共用的 `main_mobile.dart`，各自只留差别。

`pubspec.yaml` 里的 `tray_manager`、`window_manager`、`rapp_rime` 都不支持安卓，Flutter 不会给安卓注册它们；Dart 代码里对它们的调用已经被能力位挡住（iOS 就是这样跑的）。P0 确认安卓能正常编过。

### 6.6 数据放在哪

| 东西 | 位置 | 说明 |
|---|---|---|
| 身份、设备表、设置、输入历史 | `filesDir/rapp/` | 卸载就没了；不进备份 |
| 日志 | `filesDir/rapp/logs/` | 日志页里能「分享」导出 |
| 传文件的落脚处 | `filesDir/rapp/files/transfers/` | 收完后发布到系统「下载/rApp/」，这里的删掉 |
| 更新包 | `cacheDir/update/` | 装完或下次启动时删 |
| 解锁口令 | Keystore 加密后放 `filesDir` | 卸载就没了 |
| 追踪 | 不开 | 调试时用 `adb shell run-as` 取 |

### 6.7 不带到安卓的

`rapp-service`、托盘、窗口管理、分离窗口、`rapp` 命令行、被控相关的全部页面（本机接入设置里只留 B 用得到的，和 iPad 的精简「本机」页相同）、Sumi 候选窗、内置 Rime、输入法自动切换的设置行。

## 7. 排版

不为安卓写排版。同样的窗口尺寸，走 iPad、iPhone 现有的规则：

- 短边 ≥ 600 是平板，否则按手机。
- 分屏、小窗把窗口缩窄后，按当时的窗口尺寸算，不按设备算（和 iPad 的侧拉一样）。
- 「本机」列折成 56 px 竖条的规则（`overview.dart`）照用。
- 折叠屏折起来（短边 < `foldedShortSide` 600）退出全屏，照用 `FoldFullscreen`。
- 控件高度 48（`controlHeightFor` 已经把安卓算成触摸平台）。
- 系统栏、刘海、手势条的避让用 Flutter 的 `MediaQuery`，iOS 上已有的安全区处理照用。目标版本 35 起系统强制全面屏显示，P1 要在有刘海的模拟器配置上看一遍四个边。

**返回键和返回手势**：关掉最上面的一层（菜单、面板、输入块、全屏）；没有可关的，就从会话回全景；已经在全景，交给系统（App 退到后台，按 §9 冻结）。不弹「再按一次退出」。

## 8. 输入

### 8.1 触摸

和 iPad 规格 §8 的 T1–T8 相同，代码共用。手写笔按手指算。

边缘：系统的返回手势占屏幕左右边缘。画面区里从边缘开始的拖动会被系统截走。第一版不申请手势排除区；全屏时系统手势要先滑一下才生效，实际冲突要在 P1 模拟器上看，记进验收。

### 8.2 鼠标和触控板

Flutter 在安卓上把鼠标当鼠标（悬停、右键、滚轮都有），走现有的桌面指针路径。触控板双指滚动、捏合在安卓 14 上由系统分类；Flutter 把它交成什么事件（滚轮还是 `PointerPanZoom`）要 P0 看，两种现有代码都有处理，看的是哪一种、方向和速度对不对。

### 8.3 外接键盘（U8）

- 规矩和 Linux 版一样，用现有的 `_remoteKey` 和 `linuxMacKeyCode`，不另写映射：
  - Ctrl 当 ⌘ 发给 A（Ctrl+C、Ctrl+V 就是复制、粘贴）。
  - 按着 Meta（Win、⌘、搜索键）的键不发给 A，留给安卓系统。这样系统抢 Meta 组合的问题不存在。
  - Ctrl+Enter 开写作版。
  - 要发真正的 ⌃（比如在 A 的终端里中断），用键条上的 ⌃。
- 文本终端（`TermSessionPort`）有自己的按键处理，不走这条路，Ctrl 在那里就是 Ctrl，不变。
- Mac 布局的蓝牙键盘接到安卓平板上，⌘ 键就是 Meta，按上面的规矩不发给 A。用这种键盘的人也用 Ctrl。第一版不做切换的设置。
- `hardwareKeyboard()` 的判断照 iOS 的逻辑（有键按着，或者刚收到过键）。
- 键条在安卓上和 iPad 一样显示；按过实体键后折成 ⊙ 的规矩照现有的。

### 8.4 软键盘、输入块、输入法

- 没有外接键盘时，打字走输入块（Flutter 编辑器 + 系统输入法），和 iPad 一样。不做「软键盘直接打给 A」。
- 有外接键盘时，直接打字是键码直达 A，不经过输入法；在输入块里打字经过系统输入法（中文照常能打）。
- 键条、常用语条、输入历史、AI 整理共用。
- `LocalIme` 用 `NoLocalIme`；和自动切换有关的设置行靠能力位藏掉。

### 8.5 剪贴板

- 文字：两个方向都通，用 Flutter 的 `Clipboard`。P1 做。
- 图片：两个方向都通，走 `rapp/android` 的 `clipboardRead`、`clipboardWrite`（`FileProvider` 地址）。P2 做。
- 文件：不走剪贴板，走传文件。
- 安卓 13 起，App 读剪贴板时系统可能弹一个「已粘贴」的小提示，这是系统行为，不处理。只在用户做粘贴动作时读，不在回前台时偷读。

### 8.6 文件和链接

- 发文件给 A：输入块的附件按钮 → `pickFiles`。
- 从 A 收文件：先落在 `filesDir` 的落脚处，收完经 `publishDownload` 放进系统「下载/rApp/」。那一行上有「打开」和「分享」；现有的「在文件夹中显示」（`reveal`）在安卓上打开系统的「下载」列表。
- A 那边点开的链接要在 B 打开：`openUrl`。

## 9. 前后台（和 iPad 一致）

### 9.1 进后台

`AppLifecycleListener` 的 `onHide` → `BackgroundWatch` → `state.enterBackground`，三步和 iPad 规格 §9.1 相同：冻结每个会话的画面、告诉 A 暂停、断开 relay 和直连。

安卓没有 iOS 那种「申请多跑几秒」的接口，也不需要：`onHide` 之后进程还会照常跑一小段时间。三步立刻做，不等。`beginBackground`、`endBackground` 是空操作。验收：进后台 2 秒后没有任何连接（§2.3）。

分屏时 rApp 只是失去焦点但还看得见，不算进后台，照常跑。

### 9.2 回前台

`onShow` → `state.enterForeground`：重连 relay，会话自己恢复，冻结的画面换成活的。和 iPad 相同。

进程在后台被系统杀掉后再打开，是冷启动：回到全景，上次的会话不自动恢复（和 iPad 相同）。

### 9.3 其他

- rApp 自己的自动锁、A 的锁屏解锁：逻辑共用，口令存放见 §6.4。
- 屏幕常亮：有活着的会话时常亮，规则同 iPad。
- 内存：收到 `memoryWarning` 时丢掉不在台上的会话的画面缓存，表现同 iPad；共用端口里这是新写的（§6.3）。每帧整画布的做法比 iOS 的纹理吃内存，P0 要记下一个 2560×1600 会话的内存占用。

## 10. 网络、终端、端口共享

- **网络**：relay 和直连都走 hub 里的 QUIC，不经系统的 HTTP 栈，不受系统代理设置影响（和 iOS 相同）。网络切换（Wi-Fi 换蜂窝）时 `pathChanged` 通知 hub 重绑，沿用 iOS 的处理（含 quinn 收包空转那次修的逻辑）。
- **终端**：文本终端纯 Dart，直接能用。等宽字体用主题里的 `mono` 和它的后备；安卓系统自带的等宽字体不含中文，中文落到系统的 Noto CJK，宽度对不对齐 P1 看，不齐就随包带一个字体（那时再定带哪个）。
- **端口共享**：和 iOS 相同，hub 在本机开 `localhost:28000+`，平板上的浏览器能访问 A 共享的端口。只在 rApp 在前台（或分屏可见）时有效。平板自己不对外共享。

## 11. 语音（U6）

`rapp/speech` 的 Kotlin 实现，方法和事件与 iOS 的一致（`start {hotwords}`、`stop`、`cancel`；`partial`、`final`、`level`、`timing`、`error`），另加一个 `available`。

**能不能用**（`available`，只在启动时问一次。`MainState.voice` 是构造时定死的，不为这个改成能中途换；用户后来装了识别器，重开 App 就有了）：

1. 有设备上的识别器（`isOnDeviceRecognitionAvailable`），并且 `checkRecognitionSupport` 说中文（`zh-CN`）已装好 → 能用，用它。
2. 否则有默认识别器（`isRecognitionAvailable`），并且 `checkRecognitionSupport` 说支持中文（在线或设备上都算）→ 能用，用它。
3. 否则 → 不能用。`main_android.dart` 给 `voice` 传 `null`，按钮不出现（`main_state.dart:210–214` 现成的逻辑）。
4. 识别器不让查（`ERROR_CANNOT_CHECK_SUPPORT`）→ 按不能用算。宁可少显示，不显示一个按了没反应的按钮。

**识别中**：

- 按住说话，最长 5 分钟（现有上限）。系统识别器遇到停顿会自己结束一段。先试分段连续识别（`EXTRA_SEGMENTED_SESSION`）；识别器不支持，就在一段结束、手还按着时立刻开下一段，文字接在后面。对 Dart 来说始终是一次录音。
- 热词经 `EXTRA_BIASING_STRINGS` 传；识别器不理也不报错。
- `level` 用 `onRmsChanged`。
- 有的识别器开始、结束时会响一声，关不掉，不处理。
- 麦克风权限第一次按时才问；拒了就提示去系统设置里开。

识别出的文字之后走现有的那一套（本地纠词、AI 整理、学习），不分平台。

实话：国行平板上多半走到第 3 条，按钮不出现，用户用自己输入法上的语音键。这是 U6 定的。

## 12. 安全

| 事 | 做法 |
|---|---|
| 身份密钥 | 在 `filesDir`，系统按 App 隔离；不进备份 |
| A 的解锁口令 | Keystore 密钥加密 |
| 更新包 | 清单里的大小和 SHA-256 都对上才交给系统；系统再验签名和已装的是否一致 |
| APK 签名 | 发版密钥不进仓库，见 §13.3 |
| 明文 | 只放行本机回环 |
| relay 是唯一关口 | 不变。安卓端不加额外的门 |
| 截屏 | 不拦（iOS 也不拦） |

## 13. 分发和更新（U5）

### 13.1 产物

每次发版多一个资源：`rapp-<版本>-android-arm64.apk`，和 macOS 的 zip、pkg 一起传到 GitHub release。`latest.json` 的 `assets` 里加一项 `"android-arm64": {url, sha256, size}`。`rust/update` 解析清单时不认识的平台键会被忽略（审阅时对过代码），旧的 macOS 客户端不受影响。

清单由谁写：`scripts/lib/release.sh` 的 `write_manifest` 现在只写死 `macos-arm64` 一项。改成能多带一项安卓的；`scripts/package-macos.sh` 加一个可选参数收 APK 的路径，有就把它的地址、哈希、大小写进去。所以发版时先出 APK，再打 macOS 包。

清单里没有安卓这一项的时候（比如哪次发版 APK 没出，或者最新的 release 是另一台机器发的 Linux 版），安卓端显示「已是最新」，不报错。这和 macOS 现在遇到同样情况时的表现一致，可以接受。

网站的下载页多一行安卓（`website/releases.json` 列的是 release 的资源，脚本要认这个文件名）。

版本名用 `pubspec.yaml` 的版本，`versionCode` 用它的构建号（`+N`，发版 session 每次加 1，正好单调）。

### 13.2 App 内更新

安卓没有 `rapp-service`，更新逻辑在 Dart（新文件，建议 `gui/lib/android_update.dart`，一个 `ChangeNotifier`），状态沿用 `UpdateInfo` 的那几个（`idle`、`checking`、`downloading`、`ready`、`installing`、`failed`、`up_to_date`）。

**界面在哪**：侧边面板「全局设置」里、iOS 放内置输入法设置的那个位置（`main_window.dart:391` 的 `settings:`），安卓放一节「版本与升级」。「本机」上的红点（`localBadge`）在有新版本时亮，数据来自这个新的更新器。

**每个状态显示什么**（文案照 `updateView` 现有的口气，按钮是新的一套，不复用 `UpdateAction` 里 macOS 专有的 `apply`、`reinstall`）：

| 状态 | 一行字 | 按钮 |
|---|---|---|
| 没查过、已是最新 | 当前 x | 检查更新 |
| 正在检查 | 当前 x · 正在检查 | 无 |
| 有新版本 | 当前 x · 有新版本 y（大小） | 更新 |
| 正在下载 | 正在下载 y · 百分比 | 取消 |
| 下好了，还没有安装权限 | 需要允许 rApp 安装应用 | 去设置 |
| 下好了 | y 已下载 | 安装 |
| 失败 | 原因（下载失败、校验不对、被系统拒绝） | 重试 |

macOS 那句「10 分钟后自动安装」之类的话安卓上不出现。

**流程**：

1. **查**：回前台时，距上次查过了 20 小时就查一次（和 macOS 的间隔一样）；设置里也能手动查。取 `latest.json`（地址同 macOS），读 `android-arm64` 那一项，和本机版本比。清单里没有这一项，就是「已是最新」。
2. **下**：用户点了「更新」才下，不自动下（平板可能在用流量）。下到 `cacheDir/update/`，显示进度，能取消。
3. **验**：大小和 SHA-256 对上才算好。对不上就删掉、报失败。
4. **装**：`installApk` 用 `PackageInstaller` 会话交给系统，系统弹确认，装完 App 被系统重启。能免确认的情形（上一版就是它自己装的）让系统自己决定，App 不依赖这一点。
5. **第一次**：系统要求用户先给 rApp「允许安装未知应用」。`canInstall` 是否，就先说明一句、带用户去那个设置页（`openInstallSettings`），回来接着装。
6. 更新不看有没有会话开着：是用户自己点的（和 macOS 手动更新的规矩一致）。

GitHub 在国内直连慢或不通，和 macOS 的更新是同一个已知限制，不在这里解决。

### 13.3 签名密钥

- 发版用一把固定的密钥签。密钥库文件和口令放在发版那台 Mac 上、仓库之外（建议 `~/.rapp/android-release.jks` 和 `~/.rapp/android-release.properties`，`build-android.sh` 从那里读）。
- **这把密钥丢了，之后的版本就装不上去了，所有用户只能卸载重装（数据全丢）。** 生成后必须由用户另存一份到别处。这件事在 P3 生成密钥时当面提醒用户。
- 调试包用 Flutter 默认的调试密钥，和发版包不能互相覆盖安装。

### 13.4 构建

`scripts/build-android.sh`，照 `scripts/build-ios.sh` 写：

```
build-android.sh [debug|release] [--install <序列号>]
  debug    调试签名的 APK
  release  发版签名的 APK -> dist/rapp-<版本>-android-arm64.apk，并打印 sha256 和大小
```

- Rust：`cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi`，产物拷到 `gui/android/app/src/main/jniLibs/arm64-v8a/`（这个目录不进仓库）。
- Flutter：`flutter build apk --release --target-platform android-arm64`。
- 脚本末尾检查 `.so` 是 16 KB 对齐的，不是就失败。
- 和 iOS 一样不带密钥、不传 `--dart-define`。

工具（P0 装，版本写进 P0 的结果里）：NDK 28.2.x、`platforms;android-36`、对应的 build-tools、模拟器和两个 arm64 系统镜像（一个不带 Google 的 AOSP 14，一个带 Google API 的 16）、Rust 目标 `aarch64-linux-android`、`cargo-ndk`。不装 Android Studio。

### 13.5 发版流程要加的（P3 落地时改 `CLAUDE.md`，现在不改）

发版 session：

- 第 3 步之后加：`scripts/build-android.sh release` 出 APK；它编不过就是门禁失败，停下来报告。
- 第 4 步上传的资源里加 APK，核对 digest 时一并核对；`latest.json` 带上 `android-arm64`。
- 只影响安卓的改动（`gui/android/`、`rust/android-ffi/`、`scripts/build-android.sh`）也照常发一个完整的补丁版本，macOS 包照打。理由：只有一份清单、一条流程；代价是 macOS 用户收到一次内容没变的更新。
- 只影响 Linux 或 Windows 的改动不发 macOS 版，也就不出 APK（现有规矩，不变）。

做功能的 session：改了 `gui/android/` 或 `rust/android-ffi/` 的分支，合并前本机跑一次 `scripts/build-android.sh debug`。

## 14. 分期和验收

没有实机（U3）。P0–P3 都在模拟器上做完并验收；实机那一段等用户买了设备。

### 14.1 P0 探查

一次性的分支 `probe/android-p0`，代码不合并，只把结果写成 `docs/superpowers/specs/2026-11-27-rapp-android-p0-findings.md` 并回来改这份规格。计划：`docs/superpowers/plans/2026-11-27-rapp-android-p0-probe.md`。

| # | 看什么 | 过关 |
|---|---|---|
| 1 | 工具装得上，`flutter create --platforms=android` 出来的空壳（最低版本 34）在两个模拟器上能启动 | 能启动 |
| 2 | `rapp-android-ffi` 能编成 `aarch64-linux-android` 的 `.so`（`ring`、`quinn`、`rcgen`、`alacritty_terminal`、`portable-pty`、`if-addrs` 都过），导出表里有 hub 的四个和会话的五个函数，16 KB 对齐 | 都有 |
| 3 | Dart 里起进程内 hub，发 `hosts` 有回应；填上用户的 relay 后看得到设备；纯 IPv4 和双栈各连一次 | 都通 |
| 4 | 进程内会话连上一台 Mac 的桌面会话，画面出来，能点、能打字；ack 这套节流下，故意让 Dart 慢（每帧睡 200 ms）内存不涨 | 画面对，内存平 |
| 5 | 外接键盘：Ctrl 组合（Ctrl+C、V、X、Z、A、T、W、Tab、空格、Enter）是不是都到得了 App，有没有被系统或输入法拿走的（14 和 16 各看一遍）；触控板双指滚动、捏合在 Flutter 里是什么事件 | 表列出来；Ctrl+C、V 到不了就停下来报告 |
| 6 | 语音：带 Google 的镜像上 `checkRecognitionSupport` 对 `zh-CN` 的回答，按住说话能出字，分段连续识别行不行；不带 Google 的镜像上判成不能用 | 两边都符合 §11 |
| 7 | 自己装自己：本机起个 HTTP 放一个高版本 APK，走完 §13.2 的 4、5 | 装上并重启 |
| 8 | 数字：APK 大小；一个 2560×1600 会话的内存；模拟器上的帧率（只作参考，不作结论） | 记下来 |

2、3、4 任何一项过不了，停下来报告用户，不往下做。

### 14.2 P1 能连、能看、能操作

1. **共用重构**（§6.2 的库模块、§6.3 的端口）：单独的分支，单独合并，条件见 §6.3。
2. 安卓工程、`rapp-android-ffi`、`main_android.dart`、`AndroidChannel` 的基本方法、能力表和 §6.5 的清单、`build-android.sh debug`。
3. 接入引导和精简的「本机」页（共用 iPad 的）。
4. 桌面会话、单应用会话、文本终端；触摸、外接键盘、鼠标；文字剪贴板；前后台；返回键；常亮；全屏和折叠。

验收（模拟器）：装上 → 输入 relay 和密钥 → 全景看到设备 → 进桌面会话点和打字 → 开终端 → 切到后台 2 秒后 `adb shell` 看没有连接 → 切回来自动恢复 → 旋转、分屏不重建不崩。Mac 门禁全过；Linux 实机回归过了。

### 14.3 和 Windows 的 C 段怎么对

Windows 的 C 段也要「会话端口的小接口」，在 Windows 机器上做，还没开始。规矩：

- 谁先动手谁做，做之前看一眼对方的分支和 `origin/main`；已经有了就直接用，不做第二个。
- 安卓这边先做的话，接口按 §6.3 写，`ProcessSessionLink` 本来就是给 Windows 用的那一半，Windows 那边接着加 `WindowsSessionHost`。
- 在 `tasks/todo.md` 的 Windows 一节留一行，说明这个接口已经在哪个提交里。

### 14.4 P2 补齐

图片剪贴板、传文件（选、收、发布到下载、打开、分享）、解锁口令、日志导出、端口共享检查、语音、内存警告。

验收：每项在模拟器上走一遍；语音在两个镜像上分别是「能用」和「按钮不出现」。

### 14.5 P3 发布

签名密钥（当面提醒用户另存）、`build-android.sh release`、App 内更新、`latest.json` 的安卓项、网站下载行、`CLAUDE.md` 的发版步骤（§13.5）、README 里安卓的安装说明（含「允许安装未知应用」那一步）。

验收：从上一个发版包更新到新包，数据还在；把清单里的哈希改错，App 报失败并且不调安装。

### 14.6 实机（用户有设备后）

写进 `tasks/todo.md` 的「未经实机验证」：

1. 帧率和手感：平板原生分辨率下拖窗口、滚网页、放视频。**标准：拖动和滚动时不低于 30 帧每秒，点下去到画面有反应的延迟和 iPad 上没有可察觉的差别。** 不达标就做丙（只换帧这一条路）。
2. 发热和耗电：连着一个会话半小时。
3. 触摸手势 T1–T8、边缘返回手势的冲突。
4. 外接键盘上系统拿走的键，和 P0 的表对一遍。
5. 语音按钮在这台设备上出不出现、识别准不准。
6. 厂商系统的省电策略会不会在前台就限制它。
7. 更新一遍。

## 15. 请你核对

### 15.1 你定的

§0 的 U1–U8。

### 15.2 我定的（哪条不对直接说）

1. **被控不做**：安卓上做不出不用人守着的被控端（§3.1）。
2. **画面层走甲**：会话循环做成库、进程内跑，和 Linux 共用 Dart 端口；丙只作帧路径的退路（§5）。
3. **先做一次共用代码的重构**，单独合并，Linux 实机回归过了才合（§6.3）。
4. **新 crate `rust/android-ffi`**，hub 和会话同一个 `.so`；不动 `hub-ffi` 的产物类型（§6.2）。
5. **应用 ID `com.rapphub.rapp`**，和 iOS 一致。
6. **只出 arm64**；手机能装但不验收（§2.2）。
7. **数据不进系统备份**：换机要重新接入（§6.4）。
8. **收到的文件放系统「下载/rApp/」**（§8.6）。
9. **返回键**：逐层关，全景再按就退到后台，不弹确认（§7）。
10. **更新只查不自动下**，用户点了才下、才装（§13.2）。
11. **只影响安卓的改动也发完整版本**，macOS 包照打（§13.5）。
12. **目标版本停在 36**，升 37 之前先处理本地网络权限（§6.4）。
13. **「⌘ 用哪个键」不做成设置**：只有 U8 这一种（§8.3）。
14. **等宽中文字体先用系统的**，不齐再带字体（§10）。
15. **不装 Android Studio**，只用命令行工具（§13.4）。
16. **实机标准**：30 帧每秒，不达标做丙（§14.6）。
17. **表现以 iPad 为准、做法沿用 Linux**：两边不一样的地方动手前列表，对不齐的回来问你（§6.3）。
18. **语音能不能用只在启动时判一次**（§11）。
19. **「在文件夹中显示」在安卓上打开系统的「下载」列表**（§8.6）。
20. **更新的界面**放在「全局设置」里，状态和按钮见 §13.2 的表。
21. **清单里没有安卓项时显示「已是最新」**，不报错（§13.1）。

### 15.3 留给实施者的

- §6.3、§6.4 里接口和类的名字。
- `session` 模块里输入端的具体形式（通道还是管道），只要 Linux 的可执行文件行为不变。
- §6.5 清单里每一处是改成能力位还是 `touchPlatform`。
- `main_ios.dart` 和 `main_android.dart` 共用部分怎么抽。
- Keystore 密文的文件格式。
- 沉浸模式用哪种（边缘滑出后自动收回的那种即可）。
- `publishDownload` 重名文件怎么起名（建议照 Linux 传文件现有的规则）。
- 分段连续识别不支持时的接续细节。
- P0 发现的任何和这份规格不符的地方：回来改规格，不要绕过去。

## 16. 资料

- [S1] MediaProjection：https://developer.android.com/media/grow/media-projection
- [S2] 受限的屏幕读取：https://source.android.com/docs/core/permissions/restricted-screen-reading
- [S3] RustDesk 手机被控说明：https://rustdesk.com/docs/en/manual/mobile/
- [S4] RustDesk 安卓无人值守的讨论：https://www.github.com/rustdesk/rustdesk/issues/6192
- [S5] 安卓版本占比：https://composables.com/android-distribution-chart.md
- [S6] 华为关于 APK 装不上的支持页（没有写兼容层级别）：https://consumer.huawei.com/ph/support/content/en-us15854164
- [S7] 16 KB 页：https://developer.android.com/guide/practices/page-sizes
- [S8] 本地网络权限：https://developer.android.com/privacy-and-security/local-network-permission
- [S9] Flutter 关于本地网络权限：https://docs.flutter.dev/platform-integration/android/local-network-permission
- [S10] `SpeechRecognizer`：https://developer.android.com/reference/android/speech/SpeechRecognizer
- [S11] `RecognitionSupport`：https://developer.android.com/reference/android/speech/RecognitionSupport
