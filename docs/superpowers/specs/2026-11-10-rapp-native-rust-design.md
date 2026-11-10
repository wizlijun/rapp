# rapp 原生 Rust 版 技术规格（Windows 主机 · Omarchy 主机 · Omarchy 客户端）

> 在不改协议 v3、不改现有 Mac 主机和 Mac 客户端的前提下，新增三个原生程序：
>
> - **Windows 主机**：把 Windows 上某个程序的窗口串流给任何 rapp 客户端；
> - **Omarchy 主机**：把 Omarchy（Arch + Hyprland）上某个窗口串流出去；
> - **Omarchy 客户端**：在 Omarchy 上打开任何 rapp 主机（Mac / Windows / Omarchy）的窗口。
>
> 三个程序全部用 Rust，共用一个与平台无关的核心库。核心库是 `RappCore`（Swift）的逐字节等价实现。
> 组件选型和工程约定参照本机 `~/git/note.md` 的 Rust 部分，逐条注明沿用还是改动（见第 3 节）。
>
> 原规格 `2026-11-10-rapp-design.md`（含修订 1、2）仍然是协议、编码和交互语义的权威。
> 本文只写 Rust 版**怎么实现**，以及各平台与 Mac 不同的地方。本文写"同原规格 x.y"的地方，以原规格为准。

---

## 0. 共同理解

**用户说过的：**

- 要 Windows 版主机，用原生开发框架；Mac 客户端不改；在用户自己的 Windows 电脑上构建运行，把日志贴回来。
- Windows 上地址里的路径是 **exe 文件名**，不区分大小写；取这个程序最前面的可见主窗口；程序没运行就报错，不自动启动。
- 按键映射：⌘ → Ctrl，⌃ → Ctrl，⌥ → Alt，⇧ → Shift，不发 Win 键。
- 再做原生 Omarchy 版，**主机和客户端都要**。
- 语言用 Rust（用户问过性能：与 Swift/C++ 同为 LLVM 后端，像素循环里的边界检查最多几个百分点）。
- 参照 note.md 对 Rust 组件的选型和要求。

**我的假设（请纠正）：**

- 仍是个人工具：独占模式、可信局域网或 Tailscale、不加密，安全边界同原规格第 6 节。
- 用户有一台 Omarchy 电脑，与 Windows 一样在那台机器上自己构建、运行、贴日志。本机（Mac）上我只能编译检查，不能实机运行。
- Omarchy 主机的地址路径是窗口的 **class**（`hyprctl clients` 里的 `class`），不区分大小写；与 Windows 一样不自动启动。
- 只支持 x86_64。aarch64 能编译，但不打包、不声称可用（与 note.md `docs/linux-omarchy.md` 的口径一致）。

## 1. 要做到什么

**Windows 主机、Omarchy 主机**：用现有 Mac 客户端连上去，原规格第 1 节的八条都成立，只有以下差别：

- 第 1 条：地址路径分别是 exe 文件名 / 窗口 class，不是 bundle-id；目标程序没运行时报错，不启动它。
- 第 6 条：Windows 上"去掉标题栏"是指**只采窗口的客户区**（系统画的标题栏和边框都不在画面里）。
  Hyprland 窗口本来就没有系统标题栏，采的是整个窗口表面。程序自己画在客户区里的标题栏（Chrome、VS Code、GTK 的 HeaderBar）属于内容，照常显示。
- 第 4 条：Omarchy 主机上，A 的窗口是**平铺**的时候，B 拖边改不了 A 的尺寸（见 7.4）。

**Omarchy 客户端**：连接 Mac、Windows、Omarchy 主机都能用，原规格第 1 节的八条都成立，只有以下差别：

- 第 4 条：平铺窗口没有"拖角 / 拖边"，规则改为 8.4。
- 第 3 条：输入条用 Omarchy 上的输入法（fcitx5）。
- 快捷键按 Linux 习惯：Ctrl 组合键当作 ⌘ 发给 A。Super 组合键归 Omarchy，客户端不拦截。

**能在本机（Mac）验证的部分**：核心库的全部单元测试、与 Swift 版的交叉校验（第 9 节）、
Windows 和 Linux 两个主机的 `cargo check`。其余由用户在实机上按第 10 节的清单验收。

## 2. 结构

在仓库里新建 `rust/` 目录，放一个 cargo workspace。Swift 包不动（只多一个测试用的数据导出，见 9.2）。

```
rapp/
├── Package.swift, Sources/, Tests/          现有 Swift 版，不改行为
└── rust/
    ├── Cargo.toml                           workspace、统一的 release profile
    ├── rust-toolchain.toml
    ├── core/                 rapp-core       协议、量化、编解码、几何、主机会话逻辑（纯 Rust）
    │   └── tests/fixtures/                        Swift 导出的交叉校验数据
    ├── host-windows/         rapp-host-windows   Windows 主机（只在 Windows 上编出真程序）
    ├── host-hyprland/        rapp-host-hyprland  Omarchy 主机（只在 Linux 上编出真程序）
    │   └── protocols/hyprland-toplevel-export-v1.xml
    ├── client-gtk/           rapp-client-gtk     Omarchy 客户端（只在 Linux 上构建）
    ├── devtools/             rapp-testhost、rapp-probe   本机联调用的两个小程序（任何系统）
    └── packaging/arch/PKGBUILD
```

| crate | 职责 | 依赖 |
|---|---|---|
| `rapp-core`（库） | 与 `RappCore` 一一对应的模块，再加缩小采样和"主机会话"（第 5 节） | `flate2`、`thiserror` |
| `rapp-host-windows` | 找窗口、WGC 采集、SendInput 注入、SetWindowPos 改尺寸 | core、`windows`、`clap` |
| `rapp-host-hyprland` | hyprctl IPC 找窗口、toplevel-export 采集、虚拟键鼠注入、dispatch 改尺寸 | core、`wayland-client`、`wayland-scanner`、`serde_json`、`libc`、`clap` |
| `rapp-client-gtk` | 连接、解码显示、输入、标题和流量、右键菜单 | core、`gtk4`、`clap` |
| `rapp-devtools` | `testhost`：合成画面的假主机；`probe`：无界面的假客户端 | core、`clap` |

每个平台程序的 `main.rs` 在别的系统上只编出一个打印 "rapp-host-windows only runs on Windows" 并退出的空程序，
平台依赖全部放在 `[target.'cfg(...)'.dependencies]` 下，所以在任何系统上 `cargo test --workspace` 都能跑（GTK 客户端除外，见 8.1）。

## 3. 工具链与工程约定（参照 note.md）

| 项 | note.md 的做法 | rapp | 理由 |
|---|---|---|---|
| 工具链 | `rust-toolchain.toml`：`channel = "stable"`、`profile = "minimal"`、显式列 targets | **沿用**。targets 取 `aarch64-apple-darwin`、`x86_64-apple-darwin`、`x86_64-pc-windows-msvc`、`x86_64-unknown-linux-gnu`、`aarch64-unknown-linux-gnu`；另加 `components = ["clippy", "rustfmt"]` | 本机已装这些 target |
| edition | 2021 | **沿用** 2021 | 与 note.md 一致 |
| 平台无关核心 + 平台适配 | searchidx："one algorithm, three adapters" | **沿用**：core 不含任何平台代码，平台差异只在三个程序里 | 同一套逻辑在 Mac 上测完，三端共用 |
| crate 组织 | 各 crate 独立、`path` 依赖、各自 `Cargo.lock` | **改**为一个 workspace | 三个程序共用一个 core 和一个 release profile，一份 lock 更简单 |
| release profile | `opt-level = "z"`、`lto = true`、`codegen-units = 1`、`panic = "abort"`、`strip = true` | **改 `opt-level = 3`**，其余沿用 | `"z"` 优化体积。这里的热点是逐像素的量化和编码循环，要的是速度 |
| dev profile | `incremental = false`、`debug = 0`（write-core） | `[profile.dev.package.rapp-core] opt-level = 3`，其余默认 | Swift 版未优化时一帧要 1 秒。这样即使用 debug 构建跑主机也可用 |
| 依赖注释 | 每个依赖上方一行注释写为什么要它 | **沿用** | |
| 避免构建障碍 | `git2` 的 vendored-openssl 在 windows-msvc 上要 Perl + NASM，所以收窄 | **沿用**：不引入需要 C 编译器以外工具的依赖；zlib 用纯 Rust 后端 | Windows 上只装 MSVC Build Tools 就能编 |
| 平台逻辑可在 Mac 上测 | `#![cfg(any(target_os = "ios", test))]` | **沿用**：键码表、坐标换算这类纯数据模块用 `#![cfg(any(windows, test))]` / `#![cfg(any(target_os = "linux", test))]` | 键码表在 Mac 上就能跑单元测试 |
| Windows API | `windows-sys = "0.59"` | **改用 `windows` crate** | WGC（`Windows.Graphics.Capture`）是 WinRT API，`windows-sys` 不包含 WinRT。全部 Win32 调用也走 `windows`，不同时引两个 |
| GTK | `gtk = "0.18"`（GTK3，因为 tauri/wry 绑定 GTK3） | **改用 `gtk4`（gtk4-rs）** | 独立程序，没有 wry 的约束。Arch 自带 GTK4，GTK4 在 Wayland 上的输入法和分数缩放更好 |
| 异步 | `tokio` | **不用 tokio**，用 `std::thread` + `std::net` | 连接数是个位数。采集回调本身在系统线程里（WGC 线程池、Wayland 事件循环），阻塞读写最直接，少一个大依赖 |
| 命令行 | `clap = { version = "4", features = ["derive"] }` | **沿用** | |
| 错误 | `thiserror = "2"`（write-core） | **沿用**于 core；程序里用 `Box<dyn Error>`，出错打印一行退出（同原规格第 8 节） | |
| 日志 | `tracing` + `tracing-subscriber`（vaultgitsync） | **不用**，`println!` / `eprintln!`，格式与 Mac 主机逐字相同 | 用户要把日志贴回来，三端格式一致才好对比 |
| 测试 | 单元测试写在模块里，集成测试放 `tests/`，夹具放 `tests/fixtures/` | **沿用** | |
| Linux 快捷键 | 应用快捷键用 Ctrl，Super 组合归 Omarchy | **沿用**（7.5） | |
| Linux 打包 | `.pkg.tar.zst`，`pacman -U` 安装；在 Debian 12 容器里构建 | `.pkg.tar.zst` **沿用**；**改为**在 Omarchy 本机用 `makepkg` 构建 | 个人工具只给自己装，不需要容器出多发行版的包 |
| 实机验收 | 按优先级排列的清单，用户执行；未实机验证的写明"未经实机验证" | **沿用**（第 10 节） | |
| 评审口径 | P1/P2、精确到 `文件:行号`、写明"未编译 / 未实机验证" | **沿用**于本项目的代码评审 | |

依赖版本在实现时取当时最新的稳定版并写死次版本号（例如 `"0.61"`）。只取发布超过两周的版本。

## 4. 核心库 `rapp-core`

### 4.1 模块与 Swift 对应

| Rust 模块 | Swift 文件 | 内容 |
|---|---|---|
| `protocol` | `Protocol.swift` | 12 种消息的编解码、`MessageParser`（流式拆帧）、`RemoteAddress`（地址解析）、版本常量 3 |
| `quantize` | `Quantize.swift` | 五个档位、圆角填补、预乘 alpha 还原（修订 2 的 I5 规则） |
| `tilecodec` | `TileCodec.swift` | 64×64 分块编码器与解码器、四种块表示含类型 3 双色小块 |
| `deflate` | `Deflate.swift` | 每连接一个 deflate 流、每帧 sync flush、全量帧时重置；解压带上限 |
| `geometry` | `Geometry.swift` | 0–1 坐标换算、尺寸裁剪、拖动类型判定、采集密度公式、`stream_changed`（1% 密度容差） |
| `timeout` | `Timeout.swift` | 带截止时间的等待 |
| `resample` | （新） | BGRA 面积平均缩小，见 4.3 |
| `session` | `Server.swift` 里与平台无关的部分 | 主机会话，见第 5 节 |
| `client` | Mac 客户端里与界面无关的部分 | 缩放比例 z、拖动后发 `Resize` 还是 `SetStream`、流量格式化（`6.4 KB/s`），供 GTK 客户端用 |

`UpdateGate.swift` 解决的是 ScreenCaptureKit 异步重设配置的并发问题。Rust 版的采集重设在会话的单一线程里串行执行（5.2），所以不移植这个类型，只保留它的三条保证。

### 4.2 必须逐字节一致的东西

- 消息帧：1 字节类型 + 4 字节长度（小端）+ 负载；所有整数小端，字符串 = u16 小端字节长度 + UTF-8（最长 65535 字节），唯一例外是 Text（类型 5）的负载直接是整段 UTF-8；`f32` 按 IEEE 754 小端，解码时坐标类 f32 必须是有限数。完整字节布局以《host 与 client 应用规格》第 3 章为准。
- 上限：单条消息 ≤ 64 MiB；画布 ≤ 8192 × 8192；块数 ≤ 65535；解压结果不超过"块数 × (3 + 64×64×每样本字节数) + 2"。
  超过一律是 `CodecError`，不 panic、不预先分配超限内存。
- 量化结果（样本数组）、编码器在 deflate 之前产生的帧主体、解码器从同一串压缩数据还原出的画布。
- **deflate 的压缩输出不要求逐字节相同**：Swift 用系统 zlib，Rust 用 `flate2` 的纯 Rust 后端（`zlib-rs` 特性），两者可能选出不同的匹配。
  要求的是互相能解：Rust 能解 Swift 压出的流，Swift 能解 Rust 压出的流，结果相同（第 9 节）。压缩级别同 Swift，取 6。
- 编码器在"不是全量、且没有变化的块"时不产生帧（同 Swift，静止时没有流量）。

### 4.3 输入像素与缩小

- 平台程序交给 core 的永远是一块 BGRA 8bit 像素，带行跨度。像素是**预乘 alpha**：WGC 的 `B8G8R8A8UIntNormalized` 和 Wayland 的 `ARGB8888` 在内存里都是这个排列，也都是预乘的。
- 平台只给得出 `XRGB8888`（alpha 字节无意义）时，调用方传 `opaque = true`，量化时把 alpha 当 255。
- macOS 上缩放由 ScreenCaptureKit 做。WGC 和 toplevel-export 都只给原始物理像素，所以 core 提供
  `resample::downscale(src, dst_w, dst_h)`：面积平均（按目标像素覆盖的源像素加权平均，在预乘空间里平均）。
  只缩小或原样复制，从不放大：目标尺寸 = 内容区点尺寸 × min(采集密度, 屏幕倍数)，最多等于物理尺寸。
  目标与源尺寸相同时直接跳过。

## 5. 主机会话（core `session`，三端主机共用）

### 5.1 平台接口

平台程序实现一个 trait，会话逻辑只通过它访问系统。示意如下，最终的签名在实现计划里定：

```rust
pub trait Platform: Send + Sync + 'static {
    type Window: Window;
    /// 按地址路径找目标窗口；超过 deadline 返回超时错误。
    fn find_window(&self, app: &str, deadline: Instant) -> Result<Self::Window, HostError>;
}

pub trait Window: Send + Sync + 'static {
    fn content_size(&self) -> Result<SizePt, HostError>;  // 内容区，逻辑单位（"点"）
    fn screen_scale(&self) -> f32;                         // 每点几个物理像素
    fn title(&self) -> Result<String, HostError>;
    /// 开始采集；之后每有新画面就调用 sink（可能在任意线程）。
    fn start_capture(&self, fps: u8, sink: FrameSink) -> Result<Box<dyn Capture>, HostError>;
    fn inject(&self, input: &Input) -> Result<(), HostError>;
    /// 请求内容区尺寸（点），返回实际尺寸。
    fn resize_content(&self, want: SizePt) -> Result<SizePt, HostError>;
}
```

"点"在三端的含义：macOS 是点；Windows 是物理像素 ÷ (窗口 DPI / 96)；Hyprland 是逻辑像素（物理像素 ÷ 显示器缩放）。
`Ready`、`Size`、`Resize` 用的都是点，所以任何客户端看到的尺寸都与 A 上"看起来多大"一致。

### 5.2 线程与节奏

每个连接：

1. **读线程**：拆消息。`Hello` 校验同原规格 4.1 第 1 步（版本、口令），然后 `find_window`（10 秒上限，超时文案按平台改写，见 6.1、7.1）。
   之后 `Text`/`Key`/`Mouse`/`Scroll` 直接 `inject`；`Resize` 和 `SetStream` 只写入"期望配置"并唤醒会话线程。
2. **会话线程**：唯一修改采集配置的地方。它每 1 秒或被唤醒时，读期望配置和窗口当前的尺寸、标题，与当前状态比较：
   尺寸或采集密度变了就重设采集并让下一帧全量，然后发 `Size`；帧率变了只改帧率；档位变了换新编码器；标题变了发 `Title`。
   这样重设永远不重叠、永远用最新的期望值、连接关闭后不再执行（即 `UpdateGate` 的三条保证）。
3. **发送线程**：采集回调只把最新一帧放进一个单格槽（新的覆盖旧的）。发送线程取出、缩小、量化、编码、阻塞写出。
   写的时候到达的帧只覆盖槽，写完后取最新的那一帧（同原规格 4.3）。

主机每秒打印一行码率和帧数，格式与 Mac 主机相同。连接断开时：关闭采集、结束三个线程、回到等待；目标程序继续运行。
监听 `0.0.0.0:<port>`（默认 47800），对每个连接设 `TCP_NODELAY`，可以同时有多个连接（同 Mac 主机）。

### 5.3 输入的平台无关部分

core 把消息转成平台无关的 `Input`：内容区 0–1 坐标、按钮、连击数、滚动量（点）、文本、
Mac 虚拟键码 + 修饰键位（`CGEventFlags`：⇧ `0x20000`、⌃ `0x40000`、⌥ `0x80000`、⌘ `0x100000`）。
键码到各平台键码的表放在各自平台程序里。

滚动量的单位是点（Mac 客户端把"行"按 1 行 = 10 点换算），正的 dy 表示内容向下移（手指向下拨）。

## 6. Windows 主机 `rapp-host-windows`

### 6.1 找到窗口

1. 地址路径是 exe 文件名，`notepad` 和 `Notepad.exe` 等价（去掉 `.exe` 后不区分大小写比较）。
2. `EnumWindows` 按 Z 序从前到后枚举，取第一个满足条件的窗口：属于该 exe 的进程（`GetWindowThreadProcessId` →
   `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` → `QueryFullProcessImageNameW`）、可见、没有被 DWM 隐藏（`DWMWA_CLOAKED` 为 0）、
   没有所有者窗口、不是 `WS_EX_TOOLWINDOW`。
3. 没有这个 exe 的进程：回 `Error`："no running program named notepad.exe on A (start it first)"。
4. 有进程但所有窗口都最小化：对 Z 序最前的那个调用一次 `ShowWindow(SW_RESTORE)`（相当于 Mac 的"重新打开"），继续等待。
5. 整个查找最多 10 秒，超时文案："timed out waiting for a window of notepad.exe"。

进程启动时调用 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`，之后所有坐标都是物理像素。

### 6.2 采集

- `IGraphicsCaptureItemInterop::CreateForWindow` 得到采集项；D3D11 设备 + `Direct3D11CaptureFramePool::CreateFreeThreaded`
  （`B8G8R8A8UIntNormalized`，2 个缓冲）；`IsCursorCaptureEnabled(false)`。
  系统支持时设 `IsBorderRequired(false)`，去掉黄色采集边框；不支持就留着，打印一行说明。
- WGC 采的是窗口的可见外框（`DWMWA_EXTENDED_FRAME_BOUNDS`）。客户区在帧里的偏移 = `ClientToScreen(0,0)` − 外框左上角，
  尺寸 = `GetClientRect`。每帧 `CopyResource` 到 staging 纹理、`Map`，只把客户区那一块交给 core。
- 帧率：系统支持 `MinUpdateInterval` 时用它；否则在回调里丢掉距上一帧不到 1/fps 秒的帧。
- WGC 只在窗口内容有变化时送新帧，加上编码器不发无变化的帧（4.2），静止时没有流量。
- 帧尺寸（`ContentSize`）变了就 `Recreate` 帧缓冲池。
- 内容区点尺寸 = 客户区物理尺寸 ÷ (`GetDpiForWindow` / 96)，屏幕倍数 = `GetDpiForWindow` / 96。

### 6.3 注入输入

- 每次注入前，目标窗口不是前台窗口就先把它拉到前台：最小化则 `SW_RESTORE`。
  Windows 不允许后台进程直接抢前台，所以先用 `SendInput` 送一次 Alt 按下抬起，再 `SetForegroundWindow`。
  仍然失败时，每个连接只打印一次警告。
- 鼠标：客户区 0–1 → 屏幕物理坐标（`ClientToScreen`）→ `SendInput` 绝对坐标（`MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`，
  按虚拟桌面范围换算到 0–65535）。按下/抬起用左右键各自的标志；拖拽 = 带按键状态的移动。
  连击数不用：Windows 自己按时间间隔识别双击，B 端实时转发的两次点击就会被识别。
- 滚动：`MOUSEEVENTF_WHEEL` / `MOUSEEVENTF_HWHEEL`，1 行 = 10 点 = `WHEEL_DELTA`(120)，即每点 12 个单位。
  不足一个单位的余量累计到下一次。方向：Mac 正 dy = Windows 正 wheel（向上滚）。
- 文字：每个 UTF-16 单元一对 `KEYEVENTF_UNICODE` 按下/抬起，与键盘布局和输入法无关。
- 按键：Mac 虚拟键码 → Windows 虚拟键码查表（字母、数字、回车、删除、Tab、Esc、方向键、Home/End/PageUp/PageDown、F1–F12）。
  不在表里的键忽略并打印一次。修饰键 ⌘/⌃ → Ctrl，⌥ → Alt，⇧ → Shift，不发 Win 键。
  按下：先按下所需修饰键，再按键；抬起：先抬键，再抬起修饰键。方向键等带 `KEYEVENTF_EXTENDEDKEY`。

### 6.4 改尺寸、标题

- `Resize`：目标客户区物理尺寸 = 请求的点 × DPI/96；窗口尺寸 = 它 + （窗口矩形 − 客户区）的差；
  从窗口当前左上角起裁到所在显示器的工作区（`MonitorFromWindow` + `GetMonitorInfo().rcWork`）；
  `SetWindowPos(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)`；读回实际尺寸，由会话线程按实际值重设采集。
  窗口最大化（`IsZoomed`）时不改，打印一行（与"有尺寸限制的窗口"同样处理，B 端等比显示）。
- 标题：每秒 `GetWindowTextW`；为空时用 exe 名（不含 `.exe`）；最长 200 个字符。
- 目标窗口没了（`IsWindow` 为假）：回 `Error`："the window was closed on A"，断开。

### 6.5 前提条件（写入 README 的 Windows 部分）

- 在登录的桌面会话里运行（不是服务、不是 SSH 会话），不锁屏。WGC 需要 Windows 10 1903 以上，去掉黄框需要 Windows 11。
- 第一次运行时 Windows 防火墙会询问，只勾"专用网络"。
- 目标程序以管理员身份运行时，普通权限的主机注入不进去（UIPI）。主机也要以管理员身份运行才能操作它。

## 7. Omarchy 主机 `rapp-host-hyprland`

必须在 Hyprland 会话里运行（`WAYLAND_DISPLAY`、`HYPRLAND_INSTANCE_SIGNATURE` 存在），例如在 Omarchy 的终端里。
启动时检查：Hyprland IPC 套接字能连上；Wayland 注册表里有 `hyprland_toplevel_export_manager_v1`、
`zwlr_virtual_pointer_manager_v1`、`zwp_virtual_keyboard_manager_v1`。缺任何一个都打印缺了哪个，然后退出。

### 7.1 找到窗口

1. 连 `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`，发 `j/clients`，用 `serde_json` 解析。
2. 地址路径与 `class` 不区分大小写比较。取 `mapped` 且不 `hidden` 的窗口里 `focusHistoryID` 最小的（最近获得焦点的）。
3. 没有匹配的窗口：回 `Error`："no window with class foot on A (start it first)"。不启动程序。
   Hyprland 的窗口没有"关闭后隐藏"的情况，所以没有叫回这一步。
4. 查找最多 10 秒（IPC 读写都设超时），超时文案："timed out asking Hyprland for windows"。
5. 记住窗口的 `address`，之后的所有操作都按 address 指定窗口。

### 7.2 采集

- Wayland 客户端用 `wayland-client`（默认的纯 Rust 后端，不链接 libwayland）。`hyprland-toplevel-export-v1.xml`
  从 hyprland-protocols 复制进仓库（注明来源版本），用 `wayland-scanner` 的宏生成绑定。
- 每一帧：`capture_toplevel(overlay_cursor = 0, handle = address 的低 32 位)` → 收到 `buffer` 事件（格式、宽、高、跨度）→
  用 `memfd_create`（`libc`）建 wl_shm 缓冲 → `copy(buffer, ignore_damage = 0)` → `ready` 后把像素交给 core → 再请求下一帧。
  `ignore_damage = 0` 让合成器等窗口有变化才复制，静止时没有帧。相邻两次请求至少间隔 1/fps 秒。
- 格式优先 `ARGB8888`，其次 `XRGB8888`（`opaque = true`，见 4.3）。收到 `failed` 时等 1 秒重试，连续 10 次失败按"窗口没了"处理。
- 缓冲是物理像素；点尺寸取 `clients` 里的 `size`，屏幕倍数取该窗口所在显示器（`j/monitors`）的 `scale`，支持分数缩放（1.25、1.5、2）。
- Hyprland 的圆角和边框是合成时画的，不在导出的表面里。即使有透明角，core 的圆角填补也会处理。

### 7.3 注入输入

- 每次注入前，`j/activewindow` 的 address 不是目标就 `dispatch focuswindow address:0x…`（会切到它所在的工作区）。
- 鼠标：`zwlr_virtual_pointer_v1`。坐标 = 窗口 `at` + 0–1 × `size`（逻辑像素），用 `motion_absolute`，
  范围取所有显示器拼起来的逻辑区域。按钮用 `BTN_LEFT`/`BTN_RIGHT`。连击数不用，由应用自己识别。
- 滚动：`axis` 的值按点直接给，另给 `axis_discrete`（每 10 点 1 格）。方向与 Mac 相反（Wayland 正值 = 内容向上移），取反。
- 键盘：`zwp_virtual_keyboard_v1`，需要先上传一份 XKB keymap。
  - 按键：上传一份固定的 US 布局 keymap，Mac 虚拟键码 → evdev 键码查表（范围同 6.3）。
    修饰键 ⌘/⌃ → Ctrl，⌥ → Alt，⇧ → Shift，不发 Super（Super 组合归 Omarchy）。
  - 文字：做法同 `wtype`：为这段文字里出现的字符生成一份临时 keymap（每个字符一个键码，keysym 用 `U+XXXX`），
    上传后依次按下抬起，发完换回固定 keymap。不依赖外部程序。
- 输入法：注入的是虚拟键盘的键，A 上 fcitx5 若处于中文状态会拦截按键。与 Mac 一样写进前提条件：A 上保持英文输入状态。

### 7.4 改尺寸、标题

- **浮动窗口**：`dispatch resizewindowpixel exact W H,address:0x…`，W、H 是逻辑像素。
  从窗口当前左上角起裁到所在显示器内（`monitors` 的 `x/y/width/height` 除以 `scale`，再减保留区 `reserved`）。读回实际尺寸。
- **平铺窗口**：不改尺寸，每个连接打印一次 "window is tiled on A; resize ignored"。B 端照常等比显示。
  —— 这是**默认选择，待用户确认**（第 11 节问题 2）。
- 标题、尺寸、窗口是否还在：会话线程每秒发一次 `j/clients` 一并取到（不订阅 `.socket2.sock` 事件，只保留一条路径）。
  标题为空时用 class；最长 200 字符。窗口没了回 `Error`："the window was closed on A"。

## 8. Omarchy 客户端 `rapp-client-gtk`

### 8.1 构建

依赖 `gtk4`（gtk4-rs），要求系统 GTK ≥ 4.12（`gdk::Surface::scale()` 分数缩放）。Arch 的 `gtk4` 包已带头文件，再装 `pkgconf` 即可。
gtk4-sys 构建时要 pkg-config 找到系统 GTK，所以这个 crate **只在 Omarchy 上构建**。
它的非界面逻辑全部在 core `client` 模块里，在 Mac 上测试。

### 8.2 窗口

- 一个 `gtk::ApplicationWindow`，`gtk::HeaderBar` 作标题栏：中间是标题（同原规格第 7 节："Connecting to <地址>…" → `Ready` 的标题 → 每条 `Title`）；
  右侧（`pack_end`）是流量文字，灰色小字，格式与 Mac 相同（core `client` 格式化）。
- 画面：每次解码后用 BGRA 画布生成 `gdk::MemoryTexture`（`B8G8R8A8_PREMULTIPLIED`），放进 `gtk::Picture`，`ContentFit::Contain`（等同 `resizeAspect`）。
- 输入条：`gtk::Entry`，始终持有焦点。
- 右键菜单：流量文字上的右键（`GestureClick`，按钮 3），弹出 `PopoverMenu`，项目、分组和打勾规则与原规格第 7 节完全相同（用 GAction 的单选状态打勾）。

### 8.3 采集密度

- B 倍率 = 客户端窗口所在 surface 的 `scale()`（可以是 1.25、1.5 这类分数）；选了"省流 (1x)"按 1 算。
- 倍率变化（窗口移到另一块显示器）时重算并按 `stream_changed` 判断是否发 `SetStream`。

### 8.4 窗口尺寸

Hyprland 上没有"用鼠标拖角或拖边"：平铺窗口的尺寸由布局决定（开新窗口、切布局都会变），
浮动窗口用 Super + 右键拖动，不区分角和边。所以规则改为：

- 连接成功后请求窗口大小为 A 内容区的尺寸（z = 1）。平铺时这个请求不生效，按布局给的尺寸显示，z 按实际算。
- **客户端窗口尺寸的任何变化都按"拖角"处理**：A 不动，B 上等比缩放；尺寸稳定 0.3 秒后，
  z = 实际显示的画面宽 ÷ A 内容区宽，重算采集密度，有变化就发 `SetStream`。
- 右键菜单在"帧率"之后、"极限省流"之前加一组：**"让 A 适应此窗口"**。选它时按当前 z 发一次 `Resize`：
  宽 = 画面区域宽 ÷ z，高 = 画面区域高 ÷ z。这就是 Mac 上"拖边"的效果，只是改成手动触发。
  —— 这是**默认选择，待用户确认**（第 11 节问题 3）。

### 8.5 鼠标与键盘

- 鼠标：`GestureClick`（左、右键，`n_press` 作连击数）、按住时的移动作拖拽、`EventControllerScroll`。
  坐标按 `Picture` 里实际画面区域换算成 0–1，区域外的按下不发。
  滚动：有 `scroll` 平滑量时按点发；只有离散格时 1 格 = 10 点（同 Mac 客户端）。方向换成 Mac 的约定（正 dy = 内容向下移）。
- 输入条（`EventControllerKey` 挂在 Entry 上，捕获阶段）：
  - 有内容时：本地编辑，回车把整段作为 `Text` 发出并清空。输入法预编辑期间的回车属于输入法，不发送。
  - 为空时：回车、退格、Delete、Tab、Esc、方向键，以及 **Ctrl 组合键**作为 `Key` 立即发给 A。
    GDK keyval → Mac 虚拟键码查表；Ctrl → ⌘ 标志，Alt → ⌥，Shift → ⇧。
    这样 Ctrl+C 在 Mac 主机上是 ⌘C，在 Windows 主机上又映射回 Ctrl+C。
  - **Ctrl+Q** 例外：只退出客户端，不发给 A（对应 Mac 上的 ⌘Q）。
  - Super 组合键不处理，交给 Omarchy。
- 出错（连不上、口令错、版本不同、解码失败、断开）：在终端打印一行原因然后退出，同原规格第 8 节。

## 9. 测试

### 9.1 core 单元测试（本机 `cargo test`）

把 Swift 版 `RappCoreTests` 里每一个测试按同样的输入和期望移植过来（协议往返与拒绝、量化五档、圆角填补、预乘还原、
编解码往返与边缘块、类型 3 判定、解压上限与超大帧拒绝、几何、`stream_changed`）。另外加：

- `resample`：等尺寸原样返回；2× 缩小时每个目标像素等于对应 2×2 的平均；非整数倍时总和守恒（误差 ≤ 1/像素）。
- `session`：用一个假的 `Platform`（内存里的窗口，记录调用）测：口令错、版本错、找窗口超时的 `Error` 文案；
  `Resize` 和 `SetStream` 快速连发时重设不重叠且最后一次用最新值；连接关闭后不再重设；尺寸变化后发 `Size` 并且下一帧是全量；
  静止时没有 `Frame`。
- `client`：z 与采集密度、"让 A 适应此窗口"的 `Resize` 尺寸、流量格式化（`0 KB/s`、`6.4 KB/s`、`2.3 MB/s`）。
- 三端键码表与滚动换算（在 Mac 上按 `cfg(test)` 编译）：每个表项、修饰键组合、累计余量、方向。

### 9.2 与 Swift 版交叉校验

- Swift 测试里加一个只在设置了 `RAPP_EXPORT_FIXTURES` 环境变量时才运行的导出：
  固定的几张输入图（文字、渐变、带透明角、半透明像素）在五个档位下的样本数组、编码器的帧主体（deflate 之前）、
  连续几帧的压缩流，以及每种消息的编码字节，写到 `rust/core/tests/fixtures/`，随仓库保存。
- Rust 测试：样本数组、帧主体、消息字节**逐字节相等**；解开 Swift 的压缩流得到的画布与 Swift 解出的相同。
- 反方向：Rust 测试把自己压出的流写到 `rust/core/tests/fixtures/rust-*.bin`；Swift 再加一个测试，在文件存在时解开并比较画布。
- Swift 版的这两个测试只读写夹具，不改主机和客户端的任何代码。

### 9.3 本机联调（真实 Mac 程序 + Rust）

- `rapp-testhost`（Rust，跑在 Mac 上）：用 core `session` 和一个合成画面的假平台——几行文字、一个每秒移动的方块、
  每 5 秒变一次的标题，响应 `Resize` 改变画面尺寸，把收到的输入打印出来。
  用**现有 Mac 客户端**连它，验证 Rust 编码器、会话逻辑和 Swift 解码器能一起工作。
- `rapp-probe`（Rust，无界面）：连接一个主机，解码收到的帧，每秒打印尺寸、帧数和码率；
  可选把最后一帧存成原始 BGRA 文件供查看。用它连**现有 Mac 主机**，验证 Rust 解码器。
- 这两个都是我在本机能直接跑的。它们是测试工具，不对外交付。

### 9.4 编译检查（本机）

`rust/scripts/check.sh`（与现有 `scripts/check.sh` 同样的约定：输出写进 `.build-logs/rust-check.log`，最后一行 `EXIT=<码>`）依次运行：

1. `cargo fmt --check`、`cargo clippy --workspace --exclude rapp-client-gtk -- -D warnings`
2. `cargo test --workspace --exclude rapp-client-gtk`
3. `cargo check --target x86_64-pc-windows-msvc -p rapp-host-windows`
4. `cargo check --target x86_64-unknown-linux-gnu -p rapp-host-hyprland`

第 3、4 步只做类型检查，不链接。实现开始时先验证这两步在本机确实能跑通；
跑不通时，在计划里写明原因，改为只在实机上编译。

## 10. 实机验收清单（用户执行，按优先级）

每一项都附上主机或客户端打印的日志。没有跑过的项一律标"未经实机验证"。

**Windows 主机**（Mac 客户端连接）：

1. `cargo build --release -p rapp-host-windows` 通过；运行后防火墙询问时只允许专用网络。
2. 记事本：画面出现、无系统标题栏和边框、四角无黑角；B 上点击、拖选、滚动生效；输入条中文整段送达；回车、退格、⌘A（→ Ctrl+A）生效。
3. 在 100%、150% 缩放的显示器上各试一次：点击位置准确，`Size` 的点尺寸与 A 上看起来一致。
4. B 拖右边 → A 只改宽度、左上角不动；拖角 → A 不动，码率下降；最大化的窗口拖边不改尺寸，打印说明。
5. 标题同步（记事本打开另一个文件）；静止时 `0 KB/s`；右键切档位、密度、帧率（含 1 fps）、最省流和最清晰，码率随之变化。
6. A 上把记事本最小化后连接 → 被还原；A 上关掉记事本 → B 打印 "the window was closed on A"。
7. 另一个程序在前台时，B 上点击能把目标窗口拉到前台；Chrome、VS Code（自绘标题栏）各试一次。

**Omarchy 主机**（Mac 客户端连接）：

1. `makepkg -si` 安装通过；启动时三个 Wayland 接口都找到。
2. foot 终端（class `foot`）：画面、点击、滚动、整段文字（含中文、emoji）、回车、Ctrl+C（来自 ⌘C）。
3. 1.0、1.5、2.0 缩放各试一次：点击位置准确、文字清晰。
4. 浮动窗口拖边改尺寸、左上角不动；平铺窗口打印 "resize ignored"。
5. 目标窗口在别的工作区时，点击会切过去；标题同步；静止 `0 KB/s`；右键切档位。
6. 一个 GTK 程序和一个 Electron/Chromium 程序各试一次采集和输入。

**Omarchy 客户端**（分别连 Mac 主机、Windows 主机、Omarchy 主机）：

1. 构建通过；窗口出现在平铺布局里，标题、流量显示正常。
2. 点击、拖拽、滚动方向与 Mac 客户端一致；双击能选中单词。
3. fcitx5 中文输入：预编辑期间回车不发送，上屏后回车整段送达。
4. 输入条为空时 Ctrl+A / Ctrl+C / Ctrl+V 到达 A；Ctrl+Q 只退出客户端；Super 组合仍由 Omarchy 处理。
5. 布局变化（开关旁边的窗口）时画面等比缩放，A 不动，码率随画面变小而下降；"让 A 适应此窗口"后 A 改为新尺寸，画面清晰。
6. 在 1.5 缩放的显示器上采集密度正确（主机打印的 `density` 约等于 z × 1.5）。

## 11. 待确认的问题（括号里是我的默认）

1. **实现顺序**（core → Windows 主机 → Omarchy 主机 → Omarchy 客户端）：Windows 是先提出的，决定也最齐全；Omarchy 的两个问题定了再做。
   每一段单独出一份实现计划、单独验收。
2. **Omarchy 主机上 A 窗口是平铺的**（不改尺寸，只打印说明）：另两个选择是连接时把窗口设为浮动（会改动你的布局），
   或者调整平铺的分割比例（只能近似）。
3. **Omarchy 客户端的缩放**（任何尺寸变化都只在 B 上等比缩放，菜单里加"让 A 适应此窗口"）：
   另一个选择是像 Mac 的"非拖动尺寸变化"一样，每次 B 的平铺尺寸变化都自动改 A。但平铺布局变得很频繁，A 的窗口会跟着来回变。
4. **你有 Omarchy 电脑吗**？是否和 Windows 一样由你构建、运行、贴日志？（假设有、方式相同）
5. **aarch64**（只编译，不打包、不声称可用）。

## 12. 不做的事

- 协议、编码格式、Mac 主机和 Mac 客户端的任何行为改动。
- Windows 版客户端；GNOME、KDE、Sway 等非 Hyprland 的 Linux 桌面（Hyprland 专有接口不通用）；X11。
- Windows 主机的安装包和签名、开机自启、作为服务运行；Omarchy 的 Debian 容器构建和发布。
- 自动启动目标程序；UWP/商店应用（它们的窗口属于 `ApplicationFrameHost.exe`，按 exe 名找不到本体）。
- 加密、配对、白名单、自动重连、音频、剪贴板（同原规格第 11 节）。

## 13. 风险

1. **WGC 与 DPI**：每显示器 DPI 不同、窗口在两块显示器之间时，客户区偏移和点尺寸可能差一两个像素。验收第 3 项专门检查。
2. **Windows 前台限制**：`SetForegroundWindow` 在某些情况下仍会失败（例如用户正在 A 上操作别的窗口）。失败时只打印警告，点击可能落在别的窗口上。
   独占模式下可接受，与 Mac 版"注入前激活"的风险同级。
3. **虚拟键盘换 keymap**：Hyprland 对虚拟键盘的 keymap 按设备区分，但个别应用可能在发文字期间短暂看到临时 keymap。遇到时先记录。
4. **toplevel-export 与不可见窗口**：目标窗口在非当前工作区时，导出可能只给最后一帧或很慢。点击会切过去，之后正常。
5. **hyprland-toplevel-export-v1 是 Hyprland 专有协议**，随 Hyprland 版本可能变动。XML 随仓库固定，启动检查找不到接口时明确报错。
6. **本机只能做类型检查**：Windows 和 Linux 的链接、运行问题只能在实机上暴露。按第 10 节尽早上机（Windows 第 1、2 项在 Windows 实现的第一周内跑）。
7. **GTK4 分数缩放**：`MemoryTexture` 在 1.5 倍时由 GTK 缩放显示，文字可能略软。按设计采集密度已经是 z × 1.5，画面像素与屏幕像素一一对应；不一致时先记录。
