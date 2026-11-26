# rApp Windows 版：功能对齐与总体框架（设计）

日期：2026-11-26。状态：**待用户审阅**。基于 main `0decfe8d`（0.15.41，画面协议 v16）。

本文是 Windows 版的总设计：做什么、不做什么、分成哪些模块、模块之间怎么接、怎么验、怎么发版。具体实现交给别人，本文要让接手的人不用回头问就能排计划。

三种标记：
- **【用户定的】**：用户在 2026-11-26 的对话里选的。
- **【我定的】**：我替用户做的选择，附理由，可以改。
- **【未验证】**：没有在 Windows 实机上试过。**本文所有关于 Windows 系统接口的说法都没有实机验证**，写这份文档的机器是 Mac，一行 Windows 代码都没编过。凡是整个设计压在上面的，都列进了 §16 的探针，先探再做。

## 0. 用户的要求与已定的事

### 0.1 原话

> 现在要实现 windows 版。请先把整个 windows 版的功能对齐和框架全部确定一下。具体执行会交给其他人。请严谨的把已经实现的 macos 的功能对齐到 windows 版上。要求严谨完善。windows 操作系统可以选择2022年后做基准，无需兼容太多老的 os，轻装上阵，将来主要用在远程 windows 服务器、用户的 PC、笔记本电脑上。详细规划，严格审计，确保完整、框架清晰、模块边界清晰，包括发版规则等。

为什么：rApp 现在的被控端只有 Mac（完整）和 Linux（精简），控制端有 Mac、Linux、iOS。用户的 Agent 也跑在 Windows 服务器和 Windows 电脑上，这些机器现在进不了工作台；用 Windows 笔记本的人也没法当控制端。

### 0.2 用户定的十一件事

| # | 事 | 决定 |
|---|---|---|
| U1 | 怎么常驻 | **两层：薄系统服务 + 普通程序。** 干活的程序都以登录用户的身份跑；一个薄的系统服务负责开机拉起、崩溃重启、在登录界面和锁屏上出画面和输入。没人登录的服务器也能连上去登录。安装要管理员权限。没有管理员权限的电脑退到“只在登录后运行”。 |
| U2 | 在哪构建、版本号怎么走 | **像 Linux 那样，Windows 机器上另开一个发版 session。** 它自己取补丁号，发的 release 不标 Latest。Mac 的发版流程不变。 |
| U3 | 没接显示器的机器 | **不做虚拟显示器驱动。** 云主机用它自带的虚拟显示；物理机没接显示器就插 HDMI 假负载。真的没有显示输出时，桌面和应用会话报“没有显示器”，文本终端和端口共享照常。分辨率不跟着控制端窗口变。 |
| U4 | 代码签名 | **按签名设计，证书到位前先发不签名的包。** 打包脚本里有签名这一步，有证书就签，没有就跳过并标出来。设计不依赖任何“必须签名才能用”的系统能力。 |
| U5 | 整体怎么搭 | **全部 Rust，新建共用主机核心。** 见 §4。 |
| U6 | 系统基准 | **Windows 11 和 Windows Server 2022 起（内部版本 ≥ 20348），Windows 10 不支持。** 见 §3.1。 |
| U7 | 第一个公开版的范围 | **A 到 H 全部做完再公开。** 中间的成果只打内部用的 zip，不建 release、不进官网。见 §17.1。 |
| U8 | 自动升级 | **装了系统服务的机器默认开自动升级，没人登录时也升**（由 `rapp-svc` 做）。见 §12.3。 |
| U9 | `host-linux` | **这次不动。** Windows 首发以后再单独把它换到 `host-core` 上。见 §17.1。 |
| U10 | 为了对样本，改不改 Swift | **不动 Swift。** `Sources/RappCore/` 里的算法由 Swift 生成样本、Rust 逐字节对；`Sources/rapp-host/` 里的会话逻辑（握手和接管、解锁的整套步骤、粘贴的步骤、窗口跟踪循环）照着读着搬，靠对照表、假平台整会话测试和实机验收。见 §14.2。 |
| U11 | Windows 的改动怎么进 `origin/main` | **每台机器各管各的推送。** 功能 session 合并到自己那台机器的本机 main，由那台机器的发版 session 过门禁后推送。Mac 发版 session 遇到只动 Windows 的合并：过门禁、立刻推、不发版。Windows 机器上的那个 session 在首发之前只做集成（过门禁、推送、打内部包），不建 release。见 §14.4、§14.5。 |

### 0.3 这份设计让哪些旧话作废

下面这些句子写于只打算做 Windows 被控端的时候，和用户这次的要求冲突，**以本文为准**：

| 旧文字 | 位置 | 现在 |
|---|---|---|
| “Windows 版”指什么（待用户定） | `2026-11-12-rapp-requirements-feedback.md:854` | 定了：被控端和控制端都做，对齐 macOS。 |
| 先做 Windows 的被控端；Windows 当主控台以后再说（X6） | `2026-11-16-rapp-text-terminal-design.md:19` | 两端一起设计，顺序见 §17。 |
| Windows 版 Flutter 不做 | 同上 `:259-267` | 做。 |
| 非目标：Windows 版客户端；Windows 主机的安装包和签名、开机自启、作为服务运行 | `2026-11-10-rapp-native-rust-design.md:440-441` | 都在本文范围内。 |
| 在登录的桌面会话里运行（不是服务），不锁屏；WGC 需要 Windows 10 1903 以上 | 同上 `:251` | 有系统服务，能过锁屏；基准改为 §3.1。 |
| App 没在运行就报错 | `2026-11-10-rapp-host-client-spec.md:817-826` | 照 macOS：按 id 启动，等最多 10 秒（§6.4）。 |
| Windows：HKCU Run + taskkill | `2026-11-11-rapp-platform-design.md:193` | 改为 §7 的两种运行方式。 |
| Windows、Linux 不嵌入 | `2026-11-12-rapp-s2-embedded-stage-design.md:165` | Windows 照 Linux 的办法嵌入（§10.2）。 |
| run ⇄ serve 在 Windows 上换成命名管道 | `2026-11-16-rapp-text-terminal-design.md:259-267` | 换成本机 TCP 加 token（§9.3，【我定的】）。 |
| 安装包不留常驻的高权限进程 | `2026-11-15-rapp-port-sharing-design.md:411` | **U1 明知故犯地放宽了这一条**，代价写在 §7.7。 |

`2026-11-10-rapp-native-rust-design.md` §6 的 Windows 被控端草图是协议 v3 时写的，里面的系统接口选择（WGC、`SendInput`、`SetWindowPos`、exe 文件名当 app id）本文沿用，其余以本文为准。

## 1. 现状（2026-11-26）

**没有一行 Windows 代码被编译或运行过。** 仓库里和 Windows 有关的只有这些：

| 已有 | 位置 | 说明 |
|---|---|---|
| Flutter 的 Windows 工程 | `gui/windows/` | 自带模板：`BINARY_NAME "rapp"`、标题 rApp、图标 `app_icon.ico`。没有自定义通道，没有单实例，没有把旁边的程序打进包的规则。 |
| 平台能力表里的 Windows 一行 | `gui/lib/platform_caps.dart:40-52` | 有服务、托盘、窗口管理、在线升级、端口面板；没有拆窗口。 |
| 服务启停 | `gui/lib/service_control.dart:78-99` | `HKCU\…\Run` + `taskkill /IM … /F`。 |
| 路径 | `gui/lib/paths.dart`、`rust/net/src/config.rs:19,59`、`rust/net/src/log.rs:286-287` | 数据根 `%USERPROFILE%\rapp`，旧配置 `%APPDATA%\rapp`，日志 `%LOCALAPPDATA%\rapp\logs`。 |
| shell 检查 | `rust/term/src/shells.rs:98-137` | `cmd`、PowerShell、`pwsh`、Git Bash、Git sh；写好测好，没接上（`rust/term/src/serve.rs:855-860` 的 `installed_shells()` 在非 unix 上返回空表）。 |
| 升级清单里的位置 | `rust/update/src/lib.rs:293-299` 的测试 | 用了 `windows-x64` 这个键；真正的代码只认 `macos-arm64`（`:21`）。 |
| 官网 | `website/releases.mjs` | 认 `^rapp-.*(?:windows|win32|win64).*(?:\.exe|\.msi)$`；页面写“Windows — No build yet”，测试断言 `windows === null`。 |

**现在在 Windows 上会坏的地方**（都是读代码推断的，没有编过）：

- `rapp-service`：`rust/service/src/lib.rs:117` 用 `std::os::unix::process::parent_id()`；单实例保护只有 Linux 有；重启靠 `exit(0)` 让 launchd 拉起；缓存目录写死 `Library/Caches`；`workers.rs:180-202` 的 `reset_permissions` 在所有非 Linux 系统上跑 `tccutil`；`cm.rs:10` 认为界面程序叫 `rapp`。
- `rapp-term`：`pty/holder.rs`、`pty/local.rs`、`pty/launch.rs`、`pty/fg.rs`、`pty/sweep.rs`、`serve.rs` 都是 unix 专用（unix socket、信号、`/proc` 或 macOS 接口）。
- `rapp-hub`：只因为依赖 `rapp-term` 才编不过（它只用到 `rapp_term::id::is_term` 和 `rapp_term::config::OFF`）。
- `rapp-net`：`quic.rs` 的双栈绑定在非 unix 上直接返回错误。
- `rapp-update`：`runner.rs` 写死 `curl`、`ditto`、`codesign`、`plutil`、`tccutil`、`open`、`ps`、`df`、`lsregister`。
- 界面：`main.dart:93` 只在 macOS、Linux 上建会话端口，Windows 上应用会话走不通；`main.dart:118` 把终端端口也关了；语音、记住解锁密码、数据搬家、自动锁屏这一行，在 Windows 上是隐藏的；开文件夹有两处走到 `xdg-open`（“本机”页和数据页），另外两处已经对（主窗口用 `explorer`，终端里的链接用 `cmd /c start`），见 §10.1。

**可以直接借的 Linux 先例**：控制端的嵌入会话（`rapp-session` 进程解码，Dart 画），传输、文字上传是纯 Dart，键位表 `linuxMacKeyCode`，语音程序 `rapp-speech`，被控端的通用循环 `rust/host-linux/src/{wire,gate,pacing,pause,encode}.rs`，发版用单独的版本号且不标 Latest。

**参照物是 macOS 的 Swift 被控端**（`Sources/`），不是 Linux 的：Linux 被控端没有完整的瓦片编码、滚动复制、分片发送、状态规则、文字识别、启动应用和真正的窗口分类。

## 2. 目标 / 非目标 / 反目标

### 2.1 目标

1. **被控端对齐 macOS**：整桌面会话、单应用会话（多窗口）、剪贴板和文件传输、文本终端、端口共享、自动锁屏和远程解锁、在线升级。画面协议 v16，和现有的 Mac、Linux、iOS 控制端直接连通。
2. **控制端对齐 macOS**：主窗口全部功能、嵌入的远程画面、输入板、文本终端、语音、托盘、传输、历史。
3. **适合三种机器**：远程 Windows 服务器（没人坐在前面，可能没人登录）、用户的 PC、笔记本。
4. **模块边界清楚**：系统无关的算法只写一份；Windows 系统接口只在一个 crate 里；系统权限只在一个进程里。
5. **不动现有平台**：macOS、Linux、iOS 的行为和门禁不变。
6. **能独立发版**：Windows 机器上的发版 session 按写下来的规则自己发。

### 2.2 非目标（这次不做，以后可以做）

- Windows 10、32 位、原生 ARM64 包（ARM 笔记本靠系统自带的 x64 模拟，【未验证】）。
- Server Core（没有桌面的 Server 安装方式）。
- 虚拟显示器驱动（U3）。
- 菜单栏镜像（Windows 的菜单在窗口里，不需要）。
- 把会话拆成独立窗口、独立的 `rapp-client` 窗口程序。
- 任务栏跳转列表（Dock 菜单的对应物；托盘菜单已经有同一份内容）。
- 控制端的原生输入框（macOS 的 `NSTextView` + Sumi 候选栏）；Windows 用 Flutter 输入框加系统输入法。
- 同一台机器上几个 Windows 用户同时各跑一份 rApp。
- 没人登录时的文本终端和端口共享（要先连桌面登录进去）。
- 不登录就完成第一次配置（用命令行配 relay、配对设备）。新装的服务器要登录一次，在界面里配好（§12.1）。
- 微软商店版、MSIX、winget。
- relay 的 Windows 版（relay 只在 Linux 上跑）。
- H.264 等视频编码（主线也没做）。

### 2.3 反目标（做成这样就算失败，哪怕能跑）

- 为了 Windows 改坏或改慢了 macOS、Linux、iOS。
- 系统无关的算法在 Swift 之外出现两份 Rust 实现且互相对不上（Windows 一份、Linux 一份、各自演化）。
- Windows 被控端发出的字节 Mac 控制端解不了，或者要靠版本号以外的“Windows 特判”才能连。
- 在界面代码里到处写 `Platform.isWindows`。
- 以系统权限运行的代码越长越多，最后整个被控端都跑在 SYSTEM 下。
- 冒称支持：系统做不到的事（没有显示器、对方是提权窗口而本机没装系统服务）不报原因，只是没反应。
- 往日志里写密码或用户打的字。

## 3. 约束

### 3.1 系统基准【用户定的，U6；只出 x64 包是我定的】

- **Windows 11（21H2，内部版本 22000 起）和 Windows Server 2022（内部版本 20348 起，带桌面体验）。** 安装程序检查内部版本号 ≥ 20348，不够就拒绝安装并说明。这一条线正好把 Windows 10（最高 19045）挡在外面。
- 理由：逐窗口采集时去掉黄色边框的接口从 20348 起才有（【未验证】）；Windows 11 自带 Windows Terminal；用户说“2022 年后做基准，轻装上阵”。
- **只出 x64 包。**

### 3.2 一直有效的原则（来自现有规格，Windows 版照守）

| 原则 | 出处 | 对 Windows 版意味着什么 |
|---|---|---|
| 性能优先于安全，唯一的门禁是 relay（D8） | `platform-design:18` | 本机的管道、端口只用“目录权限 + token”防同机其他用户，不再加门。 |
| 极简（D9），KISS / YAGNI / DRY | `platform-design:5,19`、`tasks/todo.md:4` | 能复用就不新写；不做“以后可能用到”的东西。 |
| worker 的命令行约定（D10）；Windows 和 Linux 的 Rust worker 按同一份约定 | `platform-design:20,43,195-199` | `rapp-host.exe` 的参数、事件、退出码照 Swift 版。 |
| 代码只留一份；按“平台有什么能力”分开，不到处判断平台；新平台不改已有平台 | `pc-key-bar:9`、`ipad-duo:69,197` | Dart 里用 `PlatformCaps`；Rust 里用 `cfg` 缝，unix 那一支原样不动。 |
| 一种卡片一个实现 | 用户的长期要求 | Windows 不另画界面。 |
| 被控端始终保持英文输入；组字在控制端 | `type-to-compose:19-21` | Windows 被控端收文字前切到英文（§6.6）。 |
| 不接管不是 rApp 开的终端 | `text-terminal:45` | Windows 也只管 `rapp-term run` 开的。 |
| 不侵入 app，只看画面（K2、K5） | `conversation-design:35,38` | 不注入 DLL，不装钩子。 |
| rapp 之外什么都不设；不改用户自己的文件 | `local-ports:30`、`install-level:15` | 安装程序改了什么系统设置，一条条列出来（§12.2），卸载时还原。 |
| 不冒称支持，也不削弱系统安全策略 | Linux 对齐计划 | 做不到就报原因。**§7.7 有两处放宽，单独说明。** |
| 绝不记密码、令牌、打的字 | `observability:15` | 系统服务和帮手也一样。 |
| 画面协议版本必须完全相等，所有关口一起改 | `offstage-pause:107-108` | Windows 从第一天就是 v16，以后每次升版都跟（§14）。 |
| 控制面、终端、服务：只加可选字段，不升版本 | `device-os-marks:69` | Windows 需要的新信息一律走可选字段。 |
| 名字和路径还是 `rapp`，显示名是 rApp | `tasks/todo.md:870` | `rapp.exe`、`%USERPROFILE%\rapp`、注册表键 `rapp`；窗口标题、开始菜单写 rApp。 |
| GPL-3.0（PD16） | `product-decisions:206` | 随包的 ConPTY 是 MIT，可以带。 |
| 依赖钉版本；没有统计和崩溃上报。这两条没有一份总规格写过，是仓库现在的做法（iOS 的规格写过后一条），这里明写成 Windows 的规矩【我定的】 | `ipad-duo-design:470`；`Cargo.lock`、`pubspec.lock` 都在仓库里 | Windows 新加的依赖和随包工具（ConPTY、Inno Setup）钉死版本；不加任何上报。 |
| 照 hurryvc 的方法重写，不搬它的代码 | `text-terminal:20` | 终端照此。 |

## 4. 方案

考虑过三条路，用户选了第一条（U5）。

**方案一：全部 Rust，新建共用主机核心（选中）。** 新建 `host-core`，把 Swift 被控端里和系统无关的算法（瓦片编码、滚动复制、分片发送、窗口表、焦点面板、状态规则、会话循环）搬成 Rust，用 Swift 版生成的样本逐字节核对。新建 `host-windows`，只放 Windows 的采集、输入、窗口、剪贴板、锁屏。控制端照 Linux：`rapp-session` 解码，Dart 画。
- 好处：一种语言、一条工具链；Windows 被控端一开始就是完整画质；Linux 被控端以后可以换到同一个核心上。
- 代价：要先搬一遍约几千行算法；以后协议每加一条被控端行为，Swift 和 `host-core` 各改一次（由样本测试盯住两边一致）。

**方案二：把 Swift 被控端移植到 Windows（没选）。** Swift 能在 Windows 上编译，`RappCore` 可以原样用。没选的原因：多一条很少有人走的工具链和运行库要随包带；和“Windows、Linux 的 worker 用 Rust”这条既定原则相反；Swift 调 Windows 系统接口的绑定要自己写。

**方案三：从精简的 Linux 被控端起步（没选）。** 把 `host-linux` 的通用部分抽出来直接用。没选的原因：起步时的画质和码率就比 Mac 差一截（没有完整瓦片编码、滚动复制、分片发送），之后补齐的工作量和方案一一样，而且“先凑合”的东西容易一直凑合下去。

另外放弃了一个想法：给 Windows 控制端写 C++ 的原生解码和贴图。Linux 已经证明“进程解码 + Dart 画”能用，先走这条；只有 §16 的探针 G2 量出来不够快才回头做原生贴图。

## 5. 总体框架

### 5.1 装在机器上的程序

安装目录【我定的】：带系统服务时是 `%ProgramFiles%\rapp\`，“只为我安装”时是 `%LOCALAPPDATA%\Programs\rapp\`。

```
<安装目录>\
  current               一行文字：现在用的版本目录名，比如 app-0.16.3
  bin\rapp.exe          命令行入口（控制台程序）。只有这个目录进 PATH
  app-<版本号>\          一版一个目录，里面是这一版的全部程序：
    rapp-gui.exe          Flutter 界面，带 flutter_windows.dll、data\、插件 dll
    rapp-svc.exe          监督程序：系统服务方式或用户方式（§7）
    rapp-service.exe      后台服务：连接、会话、端口、升级（用户身份）
    rapp-hub.exe          控制端的连接进程（界面的子进程）
    rapp-host.exe         被控端画面 worker；同一个程序兼做安全桌面帮手
    rapp-session.exe      控制端画面 worker（解码）
    rapp-term.exe         文本终端
    rapp-speech.exe       本地语音识别
    rapp-cli.exe          命令行（bin\rapp.exe 是它的一份拷贝）
    conpty.dll, OpenConsole.exe   随包的 ConPTY
    （VC++ 运行库的三个 dll）
  （卸载程序）
```

**一版一个目录**【我定的】。理由：Windows 不许覆盖正在运行的程序文件，而升级时文本终端必须照样跑（`cli-update-design`），它们的 `rapp-term run` 还开着旧文件。所以升级不覆盖：新版解到新目录，改 `current` 和启动项指过去，旧目录留着给还在跑的终端用，也留着给“回到上一版”用（§12.3）。同一时刻最多留“现在的”和“上一版”，更旧的在没有进程用它时删掉。带系统服务时安装目录只有管理员和 SYSTEM 能写（`%ProgramFiles%` 默认如此），这一点是 §7.7 的安全前提：`rapp-svc install` 装完核对一次，不对就算安装失败；`rapp-svc` 每次以系统服务方式启动时再把它对齐一次，改动过就记一行日志。

界面程序叫 `rapp-gui.exe`、命令行叫 `rapp.exe`【我定的】。理由：Linux 已经是这个分法（Flutter 程序改名 `rapp-gui`，`rapp` 是入口）；Windows 上从 PATH 敲的命令必须是控制台程序，否则 `rapp share` 这样的命令没法把结果打在终端里。`bin\rapp.exe` 就是 `rapp-cli`，在 Windows 上多一条规则：不带子命令（或带 `--cm`、`--background`）时，按 `current` 找到版本目录，启动里面的 `rapp-gui.exe` 然后退出。开始菜单的快捷方式直接指向版本目录里的 `rapp-gui.exe`（每次升级重写这个快捷方式），不会闪一下黑窗口。

### 5.2 运行时谁拉起谁

```
                       ┌──────────── SYSTEM ────────────┐
开机 ──► Windows 服务管理器 ──► rapp-svc（系统服务方式）
                       │   │  有人登录前                │
                       │   ├──► rapp-service --prelogin ──► rapp-host（只有桌面）
                       │   │  机主登录后（以机主身份）  │
                       │   ├──────────────────────────────────┐
                       │   └──► rapp-host secure-helper       │
                       │        （锁屏、登录界面、UAC 上      │
                       │         出画面和输入，按需启动）     │
                       └────────────────────────────────┘     │
                                                              ▼
┌──────────────────────────── 机主的登录会话 ─────────────────────────────┐
│ rapp-service ──► rapp-host   （每个被看的 app 或桌面一个）               │
│      │       ──► rapp-term serve ··► wt.exe / 控制台窗口 ─► rapp-term run │
│      │       ──► rapp-gui --cm （有人接入时）                            │
│      └ 本机 IPC 127.0.0.1:22029 ◄── rapp-gui、rapp.exe                    │
│ rapp-gui ──► rapp-hub ··QUIC··► 别的设备                                  │
│          ──► rapp-session（每个打开的画面会话一个）                       │
│          ──► rapp-speech（按住说话时）                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

“只为我安装”时没有上半部分：`rapp-svc` 以用户方式跑，由 `HKCU\…\Run` 在登录时拉起，只做监督（崩了重启、升级后重启）。

### 5.3 代码放哪（Rust workspace）

| crate | 状态 | 放什么 | 不放什么 |
|---|---|---|---|
| `rust/host-core` | **新建** | 被控端里和系统无关的一切：协议编解码（被控端方向）、量化、瓦片编码、滚动复制、分片发送、会话循环、接管、省流阶梯、暂停、取景、窗口表后处理、焦点面板规则、状态规则、剪贴板和传输的规则、worker 的命令行和事件、平台接口（trait） | 任何系统调用。只用 `std` 的网络、文件、线程、时间。 |
| `rust/host-windows` | **新建**，产出 `rapp-host.exe`（Cargo 里的目标名是 `rapp-host-windows`，装进版本目录时改名【我定的】：`host-linux` 已经有一个叫 `rapp-host` 的目标，同一个 workspace 里重名，Mac 上的构建产物会互相覆盖，而 `host-linux` 这次不动） | Windows 的采集、输入、窗口枚举和分类、剪贴板、输入法、锁屏、启动应用、文字识别、控件树；安全桌面帮手这个运行方式 | 协议字节、编码、会话逻辑。它只实现 `host-core` 的平台接口。 |
| `rust/svc-windows` | **新建**，产出 `rapp-svc.exe` | 监督 `rapp-service`；系统服务方式下跨会话启动进程、发 Ctrl+Alt+Del；下载、校验、切换升级包；安装和卸载时对系统的全部改动（`install` / `uninstall`，§12） | 协议、采集、会话。它连网只为取升级清单和升级包。 |
| `rust/service` | 改 | 加 Windows 的缝：单实例、退出、缓存目录、worker 启动方式、`--prelogin` | —— |
| `rust/term` | 改 | 加 Windows 的 holder、本机传输、启动器、前台程序、清理 | —— |
| `rust/net`、`rust/update`、`rust/hub`、`rust/cli` | 改 | 各自的 Windows 缝（§8、§12） | —— |
| `rust/speech-linux` | 改（目录名不动） | 加 Windows 的录音；识别部分共用 | —— |
| `rust/client-core` | 基本不动 | `rapp-session` 在 Windows 上编过即可 | —— |
| `rust/wire`、`conn`、`ports` | 预计不用改 | —— | —— |
| `rust/relay`、`host-linux`、`client-gtk`、`hub-ffi` | 不碰（例外：`relay/src/audit.rs` 三处 `#[cfg(unix)]`，§14.3） | Windows 的门禁里排除（§14.3） | —— |

`speech-linux` 不改名【我定的】：改目录名会动到另一台机器维护的 Linux 打包脚本，收益只是名字好看。

**三条边界规则**（审计时逐条查）：

1. **`host-core` 不认识任何操作系统。** 它里面不出现 `cfg(windows)`、`cfg(target_os = …)`、`windows` crate、`libc`。平台差异全部通过它定义的接口进来。
2. **`host-windows` 不产生也不解析协议字节。** 它交出去的是“这一帧的 BGRA 像素”“这些窗口的原始事实”“剪贴板里现在有什么”，拿回来的是“在这个点按下鼠标”“输入这段文字”。
3. **只有 `rapp-svc` 跨登录会话、跨权限启动进程。** 别的程序要这类事，都通过 `rapp-svc` 的本机管道请它做。以 SYSTEM 身份跑的代码只有三处：`rapp-svc`、`rapp-host secure-helper`、登录前的 `rapp-service --prelogin` 和它的 `rapp-host`。

Windows 专用的 crate 在别的系统上要能编过【我定的】：内容用 `cfg(windows)` 包起来，非 Windows 上是空壳（`main` 只打一行“只支持 Windows”）。这样 Mac 发版 session 的 `cargo test --workspace` 和 clippy 一个字不用改。其中和系统无关的小逻辑（键位表、窗口分类的判断、id 换算）不包 `cfg`，在 Mac 上也能跑测试。

### 5.4 界面代码放哪

- `gui/lib/`：共用的 Dart。Windows 需要的差别通过 `PlatformCaps` 加能力位表达（§10.1）。
- `gui/windows/runner/`：C++ 外壳。只做 Dart 做不了的系统事：单实例、几个通道、托盘图标格式（§10.3）。**不做解码，不做画面。**

## 6. 被控端：`host-core` + `host-windows`

参照物是 Swift 被控端（`Sources/rapp-host/`、`Sources/RappCore/`）。下面每张表的“macOS 现在怎么做”一栏都能在这两个目录里找到对应文件，文件名写在表里。

### 6.1 命令行约定（照 Swift 版，不照 Linux 版）

| 形式 | Windows 上的行为 |
|---|---|
| `serve --app <id> (--token <s> \| --token-env <VAR>) [--port] [--bind] [--json]` | 和 Swift 版一样。服务实际用的是 `serve --app <id> --bind 127.0.0.1 --port 0 --token-env RAPP_TOKEN --json`（`rust/service/src/workers.rs:273-282` 的 `worker_cmd`），15 秒内要打出 `listening`（`START_WAIT`，`:22`）。 |
| `list-apps [--json]` | `{"apps":[桌面一项（带 displays）, {"app","name"}…], "permissions":{…}}`。列哪些 app 见 §6.4。 |
| `check [--json]` | 见下面“权限怎么报”。`--prompt` 接受但不做事。 |
| `lock [--json]` | `{"ok":true}` / `{"ok":true,"already":true}` / `{"ok":false,"error"}`。 |
| `version [--json]` | `{"version","protocol","platform":"windows"}`。 |
| `secure-helper --pipe <名字>` | **新增，内部用。** 只由 `rapp-svc` 以 SYSTEM 身份启动（§7.4）。普通用户身份启动时直接退出 2。 |

- **标准输出的事件**（`--json`，一行一个）：`listening`、`ready`（`width,height,title`）、`windows`（`count`）、`session`（started 带 `client,mode,fps`，ended 带 `reason`）、`rejected`、`stats`（每秒一次）、`transfer`（`dir` 是 `"a_to_b"` / `"b_to_a"`，`kind` 是名字）、`input`、`input_blocked`、`unlock`、`exit`。**字段名和取值照 Swift 版**（`Sources/RappCore/WorkerCLI.swift:195-253`）；Linux 版的偏差（`"bToA"`、数字 kind、不发 `stats`）不要学。
- **标准输入的命令**：`kick`、`quit`、`peer{port,name}`、`yield{by}`、`focus`（收下不做事）。标准输入关闭就停止并退出 0。
- **退出码**：0 正常、1 运行失败、2 用法错、3 缺权限、5 版本不对。
- **约定字符串原样用**：粘贴的错误（"target not frontmost"、"screen locked"、"not uploaded"、"not supported"、"no clipboard on this screen"、"远程电脑已锁屏，解锁后再发送"）、"taken over[ by 名字]"、会话结束原因。这些字符串控制端和服务会去匹配。

**权限怎么报【我定的】。** Windows 没有“屏幕录制”“辅助功能”这两个开关，但有真做不到的时候。约定：

- `permissions` 固定报 `{"screen_recording": 能不能出画面, "accessibility": true, "platform": "windows", "applications": 能不能开单个 app 的会话}`，出不了画面时再带一个 `"error"`，写原因。`applications` 平时是 `true`，登录前实例是 `false`（§7.6）。这个字段 `host-linux` 已经在报（`rust/host-linux/src/main.rs:23`），不是新字段。
- 原因只有这几种，文字固定（控制端照着显示）：`no display`（没有显示器）、`session disconnected`（机主的桌面不在本机屏幕上：被远程桌面断开且接不回来，或者被别的用户切走了）、`not interactive`（没有登录的桌面）、`other user`（本机屏幕上登录着的不是机主，§7.2）。
- Windows 上不用退出码 3。`serve` 因为这些原因起不来时退出 1，`exit` 事件的 `reason` 就是上面的文字。
- 配套要改两处共用代码（都是在“只认 linux”旁边加一支“认 windows”，Linux 的行为不变）：`rust/service/src/workers.rs:149-156` 的 `permissions()` 和 `:91-104` 的 `capabilities()`；`gui/lib/permissions.dart:22-25` 的 `missingPermissions`。`workers.rs:180-202` 的 `tccutil` 只在 macOS 上跑。
- **`applications` 要一路带到控制端**【我定的】。现在 `permissions()` 只留 `screen_recording`、`accessibility`，Linux 再留 `platform`、`error`，**把 `applications` 丢了**；`capabilities()` 在 `:101` 去读它，读到的永远是“没有”。所以 Linux 被控端现在对外报的 `applications` 一直是假，控制端因此不显示它的 app 入口（`gui/lib/ui/device_apps.dart:16` 等四处）。这是有意还是漏了，本文不判断，**也不改**（新平台不改已有平台）：Windows 这一支单独写，`platform` 是 `windows` 时 `permissions()` 留下 `platform`、`error`、`applications`，`capabilities()` 报 `desktop: true` 和 `applications`；`platform` 是 `linux` 的那一支一个字不动。把这个发现记进 `tasks/todo.md` 交给 Linux 那边的 session。
- 登录前实例的能力不是算出来的，是写死的：`graphical` 有、`desktop` 有、`applications` 没有、`terminal` 没有、`ports` 没有（§7.6）。`capabilities()` 里 `ports` 现在是写死的 `true`，要加 `--prelogin` 这一支。
- 控制端看到这四种原因，显示中文说明（“这台电脑没有接显示器，画面出不来；文本终端和端口共享不受影响”等），不显示 macOS 的权限引导。

### 6.2 `host-core` 对外的两个面

**对上（给 `rapp-host.exe` 的 `main` 用）**：一个入口，吃命令行参数和一个平台实现，跑完返回退出码。命令行解析、事件输出、会话循环全在里面。

**对下（平台接口）**：`host-core` 定义，`host-windows` 实现。下面是分组和方向，**这是定了的**；具体函数签名由实现的人定。起点是 `rust/host-linux/src/desktop/mod.rs:173-534` 那个 `Desktop` 枚举实际用到的方法，加上 Swift 版有而 Linux 没有的几组。

| 组 | 方向和内容 | 备注 |
|---|---|---|
| 目标 | 列显示器；列可分享的 app；按 id 打开目标（app 没开就启动，桌面就选屏）；目标还活着吗；app 的显示名和版本号 | §6.3、§6.4 |
| 窗口 | 读出目标的窗口原始事实（id、矩形、标题、样式、所有者、是否最小化、是否前台）；抬到前面、关、移、改大小；激活目标 | 分类和后处理在 `host-core` |
| 采集 | 给一个区域和密度，拿回这一帧不透明的 BGRA 像素和实际区域 | **单独一个对象，可以搬到采集线程上**（Linux 版里采集线程自己再连一次桌面，这个耦合不要带过来） |
| 输入 | 鼠标、滚轮、按键、文字、全部松开；按下前那个点上是谁的窗口 | §6.6 |
| 输入法 | 现在是哪个、列表、切换、切到英文 | §6.6 |
| 剪贴板 | 变化计数；读（文字、图片、文件、其他）；写；是不是不该外传的内容 | §6.7 |
| 控件 | 焦点控件和它的各层上级（角色、矩形）；焦点是不是密码框；关掉盖在上面的别人的窗口 | §6.8 |
| 文字识别 | 给一块图，拿回文字行；不支持就说不支持 | §6.8 |
| 锁和电源 | 锁没锁；锁屏；解锁（给密码）；保持唤醒开关 | §6.9 |

`host-core` 的线程模型照 `host-linux`：标准库线程加通道，不用 tokio。读网络的地方现在是 `libc::poll`（`rust/host-linux/src/server.rs:165-206`），换成不依赖系统的写法。

### 6.3 协议里的 macOS 概念在 Windows 上是什么【我定的，除非另注】

| 协议里的东西 | macOS | Windows | 理由 / 注意 |
|---|---|---|---|
| app id | bundle id | **exe 文件名，全小写，带 `.exe`**，如 `chrome.exe`。比较时不分大小写。（沿用旧规格 `host-client-spec:817-826`、`app-profile-authoring:39`） | 重启后不变，`app_profiles.json` 和 `state_rules.json` 才能按 id 认 app。不含 `/`，能放进 `rapp://host/<id>`。同名 exe 的不同程序算同一个 app，接受。 |
| 桌面的 id | `desktop:`、`desktop:<显示器 id>` | 一样 | —— |
| 显示器 id | CGDirectDisplayID | 一个稳定的非零 u32：显示器设备路径的哈希（重启、重新插拔后不变）；拿不到设备路径时用 `\\.\DISPLAYn` 的哈希 | `HMONITOR` 重启会变，不能用。哈希算法由实现的人定，写进测试。 |
| 窗口 id | CGWindowID | HWND 的低 32 位（非零）；桌面会话固定用 1 | 64 位 Windows 的窗口句柄只有低 32 位有效【未验证】。 |
| 遮挡物 id（`covered`） | pid | 那个窗口的 HWND 低 32 位 | 协议只要求是个 u32。 |
| `covered`、`appOpened` 里的 app | bundle id | 和 `list-apps` 同一种 id（exe 文件名） | 控制端会拿它当“可以打开的 app”。 |
| 点 | 点 | 物理像素 ÷（该显示器 DPI ÷ 96）。进程声明 Per-Monitor V2。 | `density` 还是“每点几个像素”，上限是该显示器的缩放比。 |
| 按键 | mac 虚拟键码 + CGEventFlags | mac 键码 → Windows 扫描码（一张表，按物理位置对应），用扫描码发 | 键码本来就是按位置定义的。表放在 `host-windows` 里不带 `cfg`，Mac 上能测。 |
| 修饰键 | ⌘ ⌃ ⌥ ⇧ | ⌘ → Ctrl，⌃ → Ctrl，⌥ → Alt，⇧ → Shift；没有 Win 键（旧规格 `host-client-spec:162-173`，沿用） | 和 Linux 被控端不同（它把 ⌃ 给了 Super），以旧规格为准。 |
| Ctrl+Alt+Del | —— | 收到“⌃ + ⌥ + 向前删除”这个组合时，不走普通按键，改走 §7.5 的系统通道 | 这个组合普通程序发不出来。不加协议消息。 |
| 剪贴板类型 | UTI | 见 §6.7 的对照表 | —— |
| 输入法 id | TIS id | 不透明字符串，如 `hkl:<十六进制>`；`""` 仍表示“切到英文” | 控制端只认 `""`。 |
| 状态规则的环境 | `os:"macos"` | `os:"windows"`（`app-state-rules:140` 已预留） | —— |
| 菜单 | 菜单树 | 不发 `menuBar`（17）；收到 `menuPick`（18）忽略 | 非目标。 |

### 6.4 目标：app 和桌面

| macOS 现在怎么做 | Windows | 状态 |
|---|---|---|
| `list-apps` 列出有“像样的窗口”（屏幕上、≥50×50）的普通 app，按名字排（`WorkerCLI.swift:313-336`） | 列出**正在运行**、至少有一个合格顶层窗口的程序（合格的定义见 §6.5），按名字排。显示名取 exe 版本资源里的“文件说明”，没有就用去掉 `.exe` 的文件名。 | 换实现 |
| app 没开就按 bundle id 启动，等最多 10 秒出窗口（`WindowCapture.swift:51-94`） | 照做。按 exe 名字找程序的顺序：注册表的 `App Paths` → 开始菜单快捷方式指向的同名 exe → PATH。找到就用系统的“打开”启动，等最多 10 秒。找不到报错 `<id> not found`。启动出来的 app 是用户的东西，不能留在 §8.1 的作业对象里（否则服务一重启它就没了）。 | 换实现【我定的，旧规格说“报错”，这次改成对齐 macOS】 |
| app 退出，会话以 "`<名字>` quit" 结束（`Server.swift:1104-1106`） | 照做：该 exe 名字下一个进程都不剩了才算退出。 | 照做 |
| app 版本号读 `Info.plist`（`AppStateWatcher.swift:7-14`） | 读 exe 的版本资源（`app-state-rules:308`）。 | 换实现 |
| 桌面：`desktop:` 是主屏，`desktop:<id>` 是指定屏；标题 “`<电脑名>` · 屏幕 N”；等屏幕醒来最多 5 秒 | 照做。 | 照做 |
| 显示器列表：在线的都列，镜像的去掉 | 照做（复制模式下只列一个）。 | 换实现 |

**微软商店应用（UWP）**：它们的窗口挂在 `ApplicationFrameHost.exe` 名下。第一版的规则【我定的】：能从窗口里找到真正的程序就用真正的 exe 名字；找不到的不列进 `list-apps`，不冒称支持。【未验证】

**资源管理器**：`explorer.exe` 当 app 分享时只算文件夹窗口；任务栏、桌面图标、开始菜单这些系统自己的界面永远不算 app 的窗口。

### 6.5 窗口和画面

**窗口**

| macOS 现在怎么做 | Windows | 状态 |
|---|---|---|
| 每秒 10 次读窗口表，前到后，只要这个 app 的；最多 256 个（`WindowTracker.swift:36-103`） | 照做。合格的窗口：可见、没有被系统隐藏（cloaked）、不是最小化、大于 4×4、属于这个 exe 名字的进程。 | 换实现 |
| 分成 7 种：普通、对话框、浮动、sheet、弹出、菜单、提示（枚举在 `Sources/RappCore/Protocol.swift:56-57`，归类之后的处理在 `RappCore/Windows.swift`） | 第一步“系统事实 → 种类”在 `host-windows`（纯函数，Mac 上能测）：无所有者的带标题栏窗口 = 普通；有所有者的对话框 = 对话框；工具窗口 = 浮动；菜单类 `#32768` = 菜单；提示类 `tooltips_class32` = 提示；其余有所有者的无标题栏弹出（下拉列表、自动完成）= 弹出；sheet 不会出现。第二步的后处理（主窗口提升、找上级等）在 `host-core`，从 Swift 搬过来。对照表由实现的人在实机上按常见 app 校一遍。 | 换实现 |
| 标题、标题行高度、能不能改大小、是不是焦点窗口 | 矩形用“去掉看不见的缩放边框后”的那个矩形。标题行高度：用系统标准标题栏的给系统值，自己画标题栏的（Chrome、VS Code）给 0，不猜。 | 换实现 |
| 抬到前面、关、移、改大小；移动和大小的夹取规则在 `Geometry.swift`、`Windows.swift` | 系统调用换成 Windows 的；夹取规则在 `host-core`。关窗口是“请它关”（相当于点关闭按钮），不是杀进程。 | 换实现 |
| 采集区域 = 各窗口矩形的并集，取整到 8 点；跟着窗口变，不重置编码器 | 照做，在 `host-core`。 | 照做 |

**采集**

| macOS 现在怎么做 | Windows | 状态 |
|---|---|---|
| 单应用：系统把这个 app 在一块屏上的所有窗口合成一张图，不带别的 app（ScreenCaptureKit） | Windows 没有“一个 app 的所有窗口”这种采集。**改成逐个窗口采集，再按前后顺序拼到一张画布上**【用户已知情，我定的】。被别的窗口挡住的部分照样出得来，和 macOS 一样。菜单、提示这类系统不让单独采集的小窗口，从“整块屏的画面”里按它的矩形裁（它们本来就在最上面）。 | 换实现，探针 H1、H2 |
| 一个 app 的会话只在一块屏上：最大的窗口的中心在哪块屏就是哪块 | 照做。 | 照做 |
| 整桌面：采一块屏 | 用“桌面复制”接口（DXGI Desktop Duplication）采整块屏【我定的】。不用逐窗口采集那套接口采屏幕，理由：安全桌面帮手只能用桌面复制（§7.4），整桌面会话和它共用一份代码。 | 换实现，探针 H3、H4 |
| 不采鼠标指针（`showsCursor = false`） | **不采**，照 macOS，不照 Linux。 | 照做【我定的】 |
| 像素数 = 区域 × min(density, 屏幕缩放比)；帧率 30/15/5/1 | 照做。缩放在显卡上做还是在内存里做，由实现的人定，以探针 H3 的性能线为准。 | 照做 |
| 采集中断（屏幕变了）→ 会话以 "capture stopped: …" 结束 | 分辨率或显示器变化、切到别的桌面时，先自己重建采集；重建不了才结束会话。 | 换实现 |
| 没有显示器 | 报 `no display`（§6.1），不装虚拟显示器（U3）。 | 新增 |

**同时有几个进程在采整块屏**【我定的】。每个会话一个 `rapp-host`（照 Swift 版）。桌面会话采整块屏；应用会话为了菜单、提示这类小窗口也要整块屏的画面（上表第一行），只在有这类小窗口时才开，用完就关。所以同一个登录会话里开着几个 app，就可能有几个进程同时在用桌面复制，而“一台机器上开很多个 app 会话”正是 rApp 的主要用法。桌面复制对同时使用它的进程数可能有上限【未验证，探针 H3：同一个登录会话里 8 个进程同时采】。有上限时的做法在这里先定下：每个登录会话只留一个采整块屏的进程（`rapp-host screen-source`，用户身份；第一个需要的 worker 把它起起来，最后一个走了它自己退出），别的 worker 从它那里取帧。它和安全桌面帮手是同一份“本地采集 + 管道外壳”（§7.4），只是身份不同，不另写一套。没有上限就不做这个进程。

**编码和发送：全部在 `host-core`，从 Swift 搬，逐字节对样本（§14.2）**

| 内容 | Swift 文件 | Rust 现状 |
|---|---|---|
| 量化：gray4、color8、color16、duogray、duocolor；圆角透明规则 | `Quantize.swift` | `host-linux/encode.rs` 只有一部分 |
| 瓦片编码：64 像素瓦片；solid、palette 1/2/4、duo、copy、raw；分片；收尾帧 | `TileCodec.swift` 的 `FrameEncoder` | 只有 solid 和 raw |
| 压缩：zlib 6 级，一条连接一个流，同步刷新，全帧时重置 | `Deflate.swift` | `flate2` 的 fast 档，要改成 6 级 |
| 滚动复制 | `ScrollDetect.swift` | 没有 |
| 分片发送：32768 一片，首片 8192；只留最新一帧；静 0.3 秒后收尾 | `PacedSender.swift`、`SendPacer.swift` | 只有确认窗口 |
| 省流阶梯、`saving`、`pinned` | `WeakTier.swift`、`SaveLadder.swift` | `host-linux/pacing.rs` 已有 |
| 暂停（v15）、`changed` | `PauseOutbox.swift` | `host-linux/pause.rs` 已有 |
| 取景（v14 `setView`） | `Windows.swift` 的 `viewFor` | `host-linux` 已有 |
| 统计（每秒一条 `stats`） | `Server.swift:1085-1102` | 没有 |
| 握手、5 秒内要 hello、接管、设备名、一个 worker 一个会话 | `Server.swift`、`WorkerCLI.swift`、`PeerNames.swift` | `host-linux/server.rs` 已有 |

`weak`（28）两个现有被控端都不发，Windows 也不发。

### 6.6 输入和输入法

| macOS 现在怎么做 | Windows | 状态 |
|---|---|---|
| 鼠标：按下、抬起、拖、移动，左右键，连击数；画布坐标 → 全局坐标（`InputInjector.swift`、`Geometry.swift`） | 用系统的输入注入接口，绝对坐标，跨所有显示器。坐标换算在 `host-core`。 | 换实现 |
| 滚轮：像素单位，夹到 ±10000 | 像素 → 滚轮刻度的系数在实机上调，验收标准是“控制端滚一屏，被控端大致滚一屏”。 | 换实现 |
| 按键：原样发 | 查 §6.3 的表发扫描码。修饰键以事件带的标志位为准。 | 换实现 |
| 文字：20 个 UTF-16 单位一段，每段隔 5 毫秒 | 照做，用“直接送 Unicode 字符”的方式发。分段在 `host-core`。 | 换实现，探针 H5 |
| 会话结束时松开所有还按着的键和鼠标键（`HeldInput.swift`） | 照做，在 `host-core`。 | 照做 |
| 点穿保护：按下前看那个点最上面是谁的窗口，是别的程序的就不按，告诉控制端（`covered`），同一个遮挡物 5 秒说一次 | 照做。“那个点上是谁”由平台给；节流和判断在 `host-core`。Swift 版里认 Dock 的那些特判换成认任务栏和系统界面。 | 换实现 |
| 输入前先把 app 拿到前台 | 照做。Windows 会拦“后台程序抢前台”，绕过的办法由实现的人定。 | 换实现，探针 H5 |
| 几台控制端之间让输入（`yield`，1 秒） | 照做，在 `host-core`。 | 照做 |
| 输入法：报告现在是哪个（开始时、变化时、每秒）；`selectInput("")` 切到英文布局；按 id 切换（`InputSourceWatcher.swift`） | 照做。“被控端始终保持英文”：会话开始和每次激活目标后，把前台窗口切到英文键盘布局；机器上没有英文布局就把中文输入法切到英文状态；两样都做不到就照常发，记一条日志。 | 换实现，探针 H6 |
| **以管理员身份运行的窗口** | Windows 不让普通程序给它们发输入，也不让普通程序移动、关闭它们或读它们的控件【未验证，探针 H5 逐项试】。画面照常出。**装了系统服务**：输入由帮手发；抬到前面、移动、改大小、请它关闭这四个窗口操作，目标是管理员窗口时也交给帮手做（§7.4）；读控件的三样（焦点面板、密码框提示、用到控件的状态规则）对管理员窗口不做，焦点面板按协议退成“整个窗口”；切英文布局做不到就照上一行记日志（发文字不经过输入法，不受影响）。**没装**：输入不发，回 `inputBlocked`（26），`by` 写约定值 `elevated`，worker 的 `input_blocked` 事件同样；四个窗口操作不做。控制端把 `elevated` 说成“这个窗口以管理员身份运行，这台电脑没装系统服务，不能远程操作”（§10.6）。 | 新增【我定的】，探针 H5、S1 |

### 6.7 剪贴板和传输

规则（什么时候算一次复制、大小上限、粘贴的步骤、出错文字、断点续传）全部在 `host-core`，从 `Clipboard.swift`、`Transfers.swift`、`Paster.swift` 搬；`host-linux/transfers.rs` 里的 unix 专用写法（设备号、硬链接）换成通用写法。

| macOS 现在怎么做 | Windows | 状态 |
|---|---|---|
| 每 0.3 秒看一次剪贴板变没变；只有会话的 app 在前台时才算（桌面会话总是算）；自己写的不算 | 照做。 | 换实现 |
| 标了“隐藏”的内容不外传（密码管理器） | 认 Windows 上同样用途的标记（“不进剪贴板历史”“不上传云剪贴板”），有就跳过。 | 换实现【未验证】 |
| 文字 ≤1 MiB；图片转成 PNG，<64 MiB；文件 ≤100 个，文件夹不支持；其他数据按类型，<64 MiB | 照做。 | 换实现 |
| 粘贴：存旧内容 → 写 → 激活 app → 等到前台 → 发 ⌘V → 0.15 秒后回答 → 约 2 秒后若没变就恢复旧内容 | 照做，发的是 Ctrl+V。 | 换实现 |
| 传输：另开连接，最多 4 条，256 KiB 一块，`<名字>.rapp-part` 续传，落到传输目录 | 照做。传输目录：`RAPP_DOWNLOADS`，否则 `<数据根>\files\transfers`。文件名里 Windows 不允许的字符和保留名（`CON`、`NUL` 等）要改写，规则写成纯函数。 | 照做 |

类型对照【我定的】：

| 协议里的 UTI | Windows 剪贴板格式 |
|---|---|
| `public.utf8-plain-text` | Unicode 文字 |
| `public.png`（`public.tiff` 收到后转 PNG） | 优先 PNG 格式，没有就从位图转 |
| `public.file-url` | 文件列表 |
| `public.html` | HTML 格式（收发时加、去它特有的头） |
| `public.rtf` | RTF 格式 |
| 其他 UTI | 发来的丢掉；本机的其他格式不外传 |

### 6.8 焦点、提示、状态规则

| macOS 现在怎么做 | Windows | 状态 |
|---|---|---|
| 菜单栏镜像（`MenuBarReader.swift`） | 不做（非目标）。 | 不适用 |
| 焦点面板（v12）：找焦点控件，沿上级走到窗口（只看角色、位置、大小，最多 40 层，有时间预算），挑一块占窗口 15–85%、≥240×160 的面板，发最多 3 个矩形（`FocusReader.swift`、`FocusTracker.swift`、`FocusPane.swift`） | 平台用系统的“界面自动化”读焦点控件和各层上级；挑哪一块、状态机、时间预算在 `host-core`。控件角色的对照表在 `host-windows`。 | 换实现 |
| 密码框提示（v13 `secureFocus`） | 界面自动化里“是密码框”这个属性。 | 换实现 |
| 关掉遮挡（v13 `dismissCover`）：只通过辅助功能关，有一张“不许关”的名单 | 请那个窗口关闭（等于点它的关闭按钮）。“不许关”的名单换成 Windows 的系统程序名。 | 换实现 |
| 开了别的 app 的提示（v13 `appOpened`，输入后 2 秒内） | 照做：输入后 2 秒内前台换成了别的程序。 | 换实现 |
| 状态规则（v16）：规则 JSON → 引擎，每 0.5 秒从最新一帧取主窗口，一点一个像素，有变化才报（`StateRules/` 7 个文件，`AppStateWatcher.swift`） | 引擎整个搬到 `host-core`。环境里 `os` 填 `windows`，语言取系统界面语言。 | 照做，量最大的一块搬运 |
| 文字识别：本机识别，简体中文加英文（`VisionText.swift`） | 用系统自带的文字识别。机器上没装对应语言的识别包时，不报 `text` 这项能力（规格允许）。 | 换实现，探针 H7 |

### 6.9 锁屏、电源

| macOS 现在怎么做 | Windows | 状态 |
|---|---|---|
| 报告锁没锁（v11，开始时和变化时） | 照做。 | 换实现 |
| 锁着的时候开 app 会话：先报画布和“已锁”，每秒看一次，解锁后才开始采集 | 照做，规则在 `host-core`（`ScreenLock.swift`）。 | 照做 |
| `lock` 子命令：立刻锁屏，2 秒内确认 | 照做。 | 换实现 |
| 自动锁屏：在服务里，最后一个计数的会话结束 10 秒后跑 `rapp-host lock`（`rust/service/src/autolock.rs`） | 服务的代码不用改。**只在装了系统服务时生效**：没有系统服务就解不了锁，锁了等于把自己关在门外，所以用户方式下这个开关隐藏并视为关。 | 照做 + 限制【我定的】 |
| 解锁（v11）：点一下唤醒输入框，打密码，回车；几个 worker 之间用文件锁保证一次一个；等最多 8 秒；密码 ≤1024 字节，绝不进日志 | 步骤在 `host-core`（`UnlockSequence.swift`）。打字这一步交给帮手（§7.4）。**Server 版默认要先按 Ctrl+Alt+Del 才出密码框**：`host-windows` 看系统策略，要的话先请 `rapp-svc` 发一次（§7.5），等输入框出来再打【未验证，探针 S1】。打进去的是锁屏上当前那个输入框要的东西，密码或 PIN，rApp 不分。没装系统服务：收到的密码直接丢掉（和“没锁时收到”一样处理），继续报已锁；协议里没有“解锁失败”这条消息，macOS 也是靠再报一次锁屏状态。控制端从对方的 `resident: "user"` 知道解不了，不弹解锁框，写“这台电脑没装系统服务，要在本机解锁”（§10.6）。 | 换实现，探针 S1 |
| 会话期间不让屏幕睡、不让屏保和锁屏出来（`PowerHold.swift`） | 照做。没有会话时不管；电脑睡了就连不上，和 Mac 一样，在说明里提醒用户改电源设置（笔记本合盖也是）。 | 换实现 |

**远程桌面（RDP）和 rApp 一起用**【我定的】。服务器的管理员常用远程桌面。远程桌面断开后，那个登录会话没有画面可采。规则：

- 远程桌面连着的时候：rApp 采的就是远程桌面里的那个桌面。【未验证，探针 S3】
- 远程桌面断开以后：装了系统服务的，rApp 需要画面时请 `rapp-svc` 把这个会话接回本机控制台，**接回后立刻锁屏**，再走正常的解锁流程（不然本机屏幕上会亮着一个没锁的桌面）。没装系统服务的，报 `session disconnected`。

## 7. 常驻：`rapp-svc`、系统服务和登录前

### 7.1 两种运行方式

| | 系统服务方式 | 用户方式 |
|---|---|---|
| 什么时候 | 安装时选“带系统服务”（要管理员） | 安装时选“只为我安装”，或者没有管理员权限 |
| `rapp-svc` 怎么起 | Windows 服务，开机自动启动，以 SYSTEM 身份 | 登录时由 `HKCU\…\Run` 拉起，以用户身份 |
| 开机没人登录时 | 能连上，看到登录界面，登录进去 | 连不上 |
| 锁屏、UAC 提示 | 能看、能操作 | 看不到，报原因 |
| 远程解锁、自动锁屏 | 有 | 没有（开关隐藏） |
| 管理员身份运行的窗口 | 能看、能输入、能移动和关闭；读不到里面的控件（§6.6） | 只能看，输入报原因 |
| 崩溃重启、升级后重启 | 有 | 有 |
| 在线升级 | 静默装 | 静默装 |
| 文本终端、端口共享、app 和桌面会话 | 有 | 有 |

两种方式用**同一个 `rapp-svc.exe`**，区别只在参数（`service` / `user`）。`rapp-service` 永远有一个监督它的上级，所以它“退出等人拉起”的写法（`rust/service/src/main.rs:65-67`，macOS 上靠 launchd）不用改。

控制端看得到对方是哪种方式：`list_apps` 的回答里加一个可选字段 `"resident": "system" | "user"`（放在哪、要一起改哪几处见 §8.1），设备卡片和出错提示用它。

### 7.2 机主

一台机器只有一个“机主”：rApp 以谁的身份干活、读谁的数据根。

- 系统服务方式下，机主的 SID 记在 `HKLM\Software\rapp`。安装程序最后以“发起安装的那个用户”的身份运行 `rapp-svc claim-owner`，服务从管道对端的身份里取 SID，**不从消息内容里取**。已有机主时再认领要管理员权限。
- **无人值守安装时没有“发起安装的用户”**（管理工具是以 SYSTEM 或另一个管理员的身份跑的）【我定的】：静默安装系统服务方式时，必须用安装参数 `/OWNER=<账户>` 指明机主，`rapp-svc install` 把它解析成 SID 写进去，这时不走 `claim-owner`。没给这个参数就失败并说明，不猜。
- **本机屏幕上登录着的不是机主**【我定的】：rApp 不为别的用户启动，也不把别人的桌面给机主看。
  - 机主没有登录会话：SYSTEM 身份的那个实例（就是登录前实例，§7.6）留着不停，但不再给桌面：`permissions` 报 `screen_recording: false`、`error: "other user"`，能力全关，正在进行的桌面会话以 `other user` 结束。设备还在线，卡片上写“别的用户正在使用这台电脑”。那个用户注销后回到登录前的状态。
  - 机主有登录会话，但被切到了后台（快速切换用户）：机主的 `rapp-service` 照常跑，文本终端和端口共享照常；桌面和应用会话报 `session disconnected`。**这时不做 `reattach`**：接回本机屏幕会把坐在机器前的那个人踢回锁屏。`rapp-svc` 看到本机屏幕上登录着别的用户就拒绝 `reattach`。
  - 别的用户用远程桌面登录不占本机屏幕，不算这两种情况。
  - 几个用户同时各跑一份是非目标。

### 7.3 `rapp-svc` 做什么

只做下面这些，别的不做：

1. **监督 `rapp-service`**：启动它，崩了按退避重启（1、2、4…最多 60 秒），它正常退出（升级、手动重启）就立刻再起。
2. （系统服务方式）**跟着登录会话走**：机主登录 → 在机主的会话里以机主身份启动 `rapp-service`；机主注销 → 停掉；没人登录 → 启动登录前实例（§7.6）。
3. （系统服务方式）**替别人做需要系统权限的几件事**：启动安全桌面帮手、发 Ctrl+Alt+Del、把断开的会话接回控制台。
4. **升级**：下载、校验、解包、切换版本目录、起不来时退回（§12.3）；登录前没人管的时候自己查升级。
5. **回答状态查询**，接受启动、停止、重启 `rapp-service` 的请求。
6. **安装和卸载时改系统设置**：`rapp-svc install` / `uninstall` 两个子命令，由安装程序和卸载程序调用，不走管道（§12.1、§12.2）。

**本机接口**：一条命名管道，一行一个 JSON，一问一答。系统服务方式的管道只允许 SYSTEM 和机主连；用户方式的管道只允许这个用户连。按 D8，不再加别的校验。

| 请求 | 做什么 | 哪种方式有 |
|---|---|---|
| `status` | 返回方式、机主、`rapp-service` 在不在跑、重启过几次、是不是登录前实例、版本 | 都有 |
| `start` / `stop` / `restart` | 管 `rapp-service` | 都有 |
| `claim-owner` | §7.2 | 系统 |
| `helper` | 在**请求方自己所在的登录会话**里启动安全桌面帮手，让它连到请求方给的管道 | 系统 |
| `spawn-host` | 登录前用：在控制台会话里以 SYSTEM 身份启动 `rapp-host`，把它的标准输入输出接给请求方。**只接受 SYSTEM 身份的请求方**（也就是登录前实例） | 系统 |
| `sas` | 发 Ctrl+Alt+Del | 系统 |
| `reattach` | 把**请求方自己的**断开的会话接回控制台，然后锁屏 | 系统 |
| `fetch-update` / `apply-update` / `rollback` | §12.3。请求里只有版本号，没有文件路径 | 都有 |

**请求里的东西不当真**【我定的】：是谁、在哪个登录会话，一律从管道对端取，不从消息内容取。请求方能给的只有“做哪件事”和几个不涉及权限的值（管道名、版本号）。`rapp-svc` 以系统权限启动的程序，只能是它自己那个版本目录里的 `rapp-host.exe`、`rapp-service.exe`、`rapp-svc.exe`，用完整路径，不查 PATH，不接受请求方给的路径。理由：否则机主身份下的任何程序都能借它拿到系统权限，或者往别人的登录会话里发输入。

界面和命令行不直接说管道：`rapp-svc ctl <请求>` 是它自己的客户端，`gui/lib/service_control.dart` 的 Windows 分支改成调这个（现在的 `reg add` + `taskkill` 作废）。

管道而不是本机 TCP 的理由：这里对面是系统权限，要靠操作系统认“连过来的是谁”，token 文件做不到。

### 7.4 安全桌面帮手

Windows 把锁屏、登录界面、UAC 提示、Ctrl+Alt+Del 那一屏放在另一个“安全桌面”上，普通程序看不到也碰不到。

- **帮手是什么**：`rapp-host secure-helper`，和 `rapp-host` 同一个程序的另一种运行方式，由 `rapp-svc` 以 SYSTEM 身份、在机主的登录会话里启动。它只会三件事：把“当前显示的那个桌面”的画面采出来（桌面复制）；把收到的鼠标键盘事件发进去；对指定的窗口做四个固定的操作（抬到前面、移动、改大小、请它关闭），只在目标是管理员身份的窗口、`rapp-host` 自己做不了时才用（§6.6）。它跟着系统在普通桌面和安全桌面之间切。
- **谁是会话的主人**：还是用户身份的那个 `rapp-host`。协议、编码、剪贴板、传输都在它那里。帮手只是它的“另一块屏”和“另一只手”。
- **两者怎么连**：用户身份的 `rapp-host` 开一条只许 SYSTEM 和自己连的管道，把名字交给 `rapp-svc`，帮手连上来。管道上走三种东西：帧（宽、高、像素）、输入事件、上面那四个窗口操作（目标只用窗口句柄指明）。没有别的命令。帧走管道还是共享内存由实现的人定，以探针 S1 量出来的延迟为准。
- **什么时候用帮手**【我定的】：
  - 输入：系统服务方式下，**所有输入都经帮手发**（这样管理员身份的窗口也能操作，而且只有一条路）。用户方式下由 `rapp-host` 自己发。
  - 画面：平时 `rapp-host` 自己采；整桌面会话在系统切到安全桌面时改用帮手的画面，切回来再换回去。
  - 单应用会话遇到安全桌面：不切画面（那一屏不是这个 app 的），画面停在最后一帧。**锁屏**照现有的办法报 `screenLocked(true)`（34）。**不是锁屏的安全桌面**（UAC 提示、Ctrl+Alt+Del 那一屏）借用现有的 `covered`（37）：控制端这时发来输入，就回一条 `covered`，`name` 写“系统确认（UAC）”，`bundleID` 写 `consent.exe`，`dismissable` 是假，节流照点穿保护（5 秒说一次）。已经发出去的控制端会显示“A 上「系统确认（UAC）」的弹窗挡住了点击”，意思是对的；新的控制端认出这个 id，后面多说一句“请打开桌面会话处理”。不能报成锁屏：那样控制端会弹解锁框。
  - 用户方式（没有帮手）遇到安全桌面：桌面会话也和上一条一样处理，画面停在最后一帧，锁屏报 `screenLocked(true)`，别的报 `covered`。用户身份的进程看不到安全桌面上是什么，只知道“切走了”和“锁没锁”。【未验证，探针 H4】
- **在 `host-windows` 里的样子**：采集和输入各有两个实现，“本地的”和“经帮手的”，对 `host-core` 是同一个接口。帮手本身就是“本地的”那个实现加一个管道外壳。**不为帮手另写一套采集和输入。**

没选的做法：让整个桌面 worker 以 SYSTEM 身份跑（一些远程桌面软件这么做）。没选是因为那样协议、编码、剪贴板、文件传输全在系统权限下，违反 §2.3 的反目标。

### 7.5 Ctrl+Alt+Del

这个组合只有系统服务能发，而且要先打开一条系统策略（“允许服务模拟安全注意序列”）。系统服务方式安装时由 `rapp-svc install` 打开它，记下原值，卸载时还原，并在安装界面上列出来（§12.2）。【未验证，探针 S1】

这条策略不只是为了菜单里那一项：Windows Server 默认要先按 Ctrl+Alt+Del 才出密码框，所以这些机器上的远程解锁（§6.9）和登录前的登录（§7.6）都靠它。

发到哪个登录会话【未验证，探针 S3】：机主在远程桌面会话里的时候，它可能落到本机屏幕而不是机主的会话。落不到的话，这种情况下菜单项置灰并说明原因。

控制端怎么触发：Windows 控制端按不出来（本机系统会先截走），Mac 上也别扭。所以**被控端是 Windows 的桌面会话，会话菜单里加一项“发送 Ctrl+Alt+Del”**，发的就是 §6.3 说的那个键组合，不加协议消息。

### 7.6 登录前

开机后、或机主注销后，没有人登录。系统服务方式下：

- `rapp-svc` 以 SYSTEM 身份启动 `rapp-service --prelogin`，环境里指明机主的数据根。它用机主的设备密钥和 relay 配置，所以**对外是同一台设备**。
- 它**只提供整桌面**（登录界面）。能力里报：有图形、有桌面，没有应用、没有终端、没有端口；再加一个可选字段 `"prelogin": true`，控制端在设备卡片上写“未登录，只能打开桌面”。
- 它**不写机主的数据根**（只读密钥和配置），不开本机 IPC，不跑数据同步、自动锁屏、`--cm`。日志写到 `%ProgramData%\rapp\logs\`。升级不归它管：登录前的自动升级由 `rapp-svc` 自己做（§12.3），否则长期没人登录的服务器会停在旧版，协议一升版就再也连不上去登录。
- 它**不执行、不加载数据根里指到的任何程序**，只启动自己版本目录里的程序。数据根是机主可写的，SYSTEM 身份的进程只把它当数据读。
- 画面和输入：请 `rapp-svc` 用 `spawn-host` 在控制台会话里启动一个 SYSTEM 身份的 `rapp-host`（它直接用“本地的”采集和输入实现，不需要帮手）。
- 机主登录后：`rapp-svc` 停掉登录前实例，在机主会话里启动正常的 `rapp-service`。控制端的连接会断一下，靠现有的重连逻辑接上。
- 登录进来的不是机主：登录前实例不停，改成“被别人占用”的状态，不再给桌面（§7.2）。

登录前不可用的情况（服务日志里写明原因，不报错给用户）：机主的数据根在网络盘或加密文件夹里，SYSTEM 读不到；开机要先输 BitLocker 密码的机器，系统还没起来。

设备密钥因此**不用“只有本人登录后才能解开”的系统加密**来保护，否则登录前读不了。它靠文件权限保护（§13.2）。

### 7.7 安全上的代价（明说）【用户选了 U1，这些是它带来的】

1. **多了一个常驻的系统权限进程。** 这和“安装包不留常驻的高权限进程”那条旧原则相反，是为了登录前、锁屏、UAC 能用。它的代码量要压到最小，审计时单独看（§18）。
2. **装了系统服务以后，能以机主身份运行代码的程序，实际上也能操作 UAC 提示**（请帮手往安全桌面上发输入）。对机主本身就是管理员的机器，这等于把“提权要人点一下”这道栏放低了。远程桌面类工具都有这个性质。这和“不削弱系统安全策略”那条原则有冲突，这里明知并接受，理由是 D8：唯一的门是 relay。
3. **登录前，对着网络的那个进程是 SYSTEM 身份。** 它能做的事被限制在“整桌面”一项，但它确实在系统权限下解析网络数据。
4. **Ctrl+Alt+Del 的系统策略被打开。**
5. 不想要这些的机器，选“只为我安装”，代价是 §7.1 表里右边那一列。

## 8. 现有 Rust crate 的 Windows 缝

总规则：每条缝都是**加一支** `cfg(windows)`，unix 那一支一个字不动。下面的行号是 main `0decfe8d` 上的。

### 8.1 `rapp-service`

| 位置 | 现在 | Windows 上 |
|---|---|---|
| 单实例（`rust/service/src/main.rs:8-9,19-30`、`instance.rs`） | 只有 Linux 有：抽象 unix socket `com.rapp.service.<uid>` | 命名互斥量，名字带登录会话（登录前实例和登录后实例不同名）。第二个实例照 Linux 的写法退出。 |
| 重启（`main.rs:65-67`） | `exit(0)`，launchd 拉起 | 不改。上级是 `rapp-svc`（§7.1）。 |
| 停止（`stopped()`） | SIGTERM、Ctrl+C | Windows 没有 SIGTERM。【我定的】`rapp-svc` 启动它时带 `--supervised`，握着它标准输入的写端；**标准输入读到结束就是“请停”**。`rapp-svc` 自己死了，这一端也跟着关，`rapp-service` 自己退出，不会留下占着端口的孤儿。不带 `--supervised`（开发时手动跑）不看标准输入。 |
| 孤儿进程 | unix 上靠信号和进程组 | 【我定的】`rapp-svc` 把 `rapp-service` 放进一个“上级没了就全部结束”的作业对象，worker 都在里面。**作业里只该有 rApp 自己的后台进程**（`rapp-service`、`rapp-host`、`rapp-term serve`、`rapp-speech` 这类）。下面三样启动时都要脱离这个作业，否则重启服务、升级会把用户的东西一起带走：**文本终端的窗口**（§9.4）；**`rapp-host` 替控制端打开的 app**（§6.4，用户在远程开的 Chrome 不能因为服务重启就没了）；**界面程序**（`--cm` 小窗和升级后重新打开的主界面）。验收写在探针 T5。 |
| 升级选项（`rust/service/src/lib.rs:113-128` `UpdateOpts::system`；`bundle_of` 在 `rust/update/src/lib.rs:172`，从 `rust/service/src/main.rs:55` 调） | `launchd: parent_id() == 1`；缓存目录 `Library/Caches/rapp/update`；`bundle_of` 找 `.app` | “有人监督”改成看 `--supervised`；“装在哪”改成自己所在的版本目录；下载和安装不在这里（§12.3）。 |
| 界面程序在哪（`cm.rs:9-12`） | `RAPP_GUI`，否则旁边的 `rapp` | 旁边的 `rapp-gui.exe`，带 `--cm`。 |
| 权限、能力、重置权限（`workers.rs:91-104,149-156,180-202`） | 见 §6.1 | 见 §6.1。`tccutil` 那一段只在 macOS 上跑。 |
| 启动 worker | `Command::new` | 不许弹出黑窗口：`rapp-host.exe`、`rapp-term.exe` 是控制台程序，从没有窗口的进程里启动时要明说“不要窗口”。程序名一律带 `.exe`，在自己的版本目录里找。 |
| 常驻方式 | 没有这个概念 | `rapp-svc` 启动它时告诉它是 `system` 还是 `user`（参数）。两个可选字段 `resident`、`prelogin`（§7.6）**放在对端的 `list_apps` 回答里**（和 `os`、`version`、`capabilities` 并排，控制端就是从这里知道对方是什么机器的），本机 IPC 的 `status` 里也报一份给“本机”页用。只在 Windows 上出现，macOS、Linux 的回答一个键都不多。**加字段的同一个提交里**改：hub 转发已知字段的 `apps_event`（`rust/hub/src/lib.rs:466-481`，不加就传不到界面）、`rust/testkit/tests/service.rs:381` 那条整个对象相等的断言（它在 Mac 上跑，Mac 的回答没变，所以它应该原样还是绿的；另加一条 Windows 的）、`config-reference`。 |
| 自动锁屏（`autolock.rs`） | 开关在服务配置里 | 代码不改。`resident` 不是 `system` 时这个开关视为关（§6.9）。 |
| 数据同步 | 只有它跑 git | 照做。Windows 没有自带 git：找不到 `git.exe` 就只提示，不同步（`data-dir` D6 已经这么写）。同步仓库在初始化时关掉换行符转换（`core.autocrlf=false`），不然 Mac 和 Windows 之间会把每个文件都当成改过。 |
| 本机 IPC（`127.0.0.1:22029` + `local/ipc.token`） | TCP | 照做，不改。 |

### 8.2 其余 crate

| crate | 要改什么 |
|---|---|
| `rapp-net` | `rust/net/src/quic.rs:269-356`（unix 的 `mod sys` 在 269-346，非 unix 的在 348-356）：双栈绑定现在在非 unix 上直接报错，加 Windows 一支，行为和 unix 一样（一个 UDP 口同时收 IPv4 和 IPv6）。`log.rs:283-287`：找不到环境变量时的兜底目录认 `USERPROFILE`。设权限的三处：`datadir.rs:22-26`（把 `local` 设成 0700）、`config.rs:96-111` 的 `write_private`（写 0600 的文件）、`log.rs:218-225`（日志目录 0700），见 §13.2。 |
| `rapp-wire`、`rapp-conn` | 自己不设权限，写密钥文件都调 `rapp-net` 的 `write_private`（`rust/wire/src/identity.rs:85-86`、`rust/conn/src/paired.rs:75`），所以 §13.2 改好 `write_private` 这两个 crate 就跟着对了。协议和连接逻辑不动。 |
| `rapp-ports` | 预计不改。它只在回环地址上开口子。Windows 会把一些端口段留给系统（装了 Hyper-V、WSL 的机器尤其如此），28000–28999 里的号可能开不了：这种失败要和“端口被占”一样报出来，不能当成程序错。【未验证，探针 N1】 |
| `rapp-hub` | 自己的代码没有平台分支，只因为依赖 `rapp-term` 才编不过；§9 做完它就能编。转发字段表加 `resident`、`prelogin`。 |
| `rapp-cli` | Windows 一条规则：不带子命令时启动界面（§5.1）。启动时把控制台输出设成 UTF-8，否则中文是乱码。【未验证】 |
| `rapp-client-core`（`rapp-session`） | 预计只要编过。它和界面之间走标准输入输出的二进制帧，Rust 的标准库在 Windows 上不做换行转换。 |
| `rapp-update` | §12.3。 |
| `rapp-term` | §9。 |

**Windows 上所有进程都要守的四条**（界面启动的 `rapp-hub`、`rapp-session`、`rapp-speech` 也一样）：不弹黑窗口；上级没了自己跟着没（终端除外）；找旁边的程序时带 `.exe`、用完整路径、不查 PATH；拼路径用路径接口，不手写 `/`。

## 9. 文本终端

### 9.1 什么不用动

控制端的终端界面、`serve` 和控制端之间的协议、屏幕状态同步、按键编码、OSC 7501 程序状态扫描、标题、未读，这些模块和系统无关（`config, id, keys, list, proto, screen, sender, unread, wire, pty/{fit,grid,view,ps,title,wintitle}`），原样用。要写 Windows 一支的是 `pty/holder.rs`、`pty/local.rs`、`pty/launch.rs`、`pty/fg.rs`、`serve.rs` 里的几处，以及把 `libc` 依赖限制在 unix 上。`pty/sweep.rs`（关掉 macOS 终端里已结束的标签页）Windows 不需要。

规矩照旧：不接管不是 rApp 开的终端；方法照 hurryvc 重写，不搬代码。

### 9.2 `rapp-term run`（把程序握在终端窗口里）

| unix 现在怎么做 | Windows | 状态 |
|---|---|---|
| 用系统的 pty | **随包的 ConPTY**（`conpty.dll` + `OpenConsole.exe`，和 Windows Terminal 用的是同一份）。不用系统自带的那份：Server 2022 上的太旧，会吞掉它不认识的转义序列，程序状态和标题都靠这些序列。`portable-pty` 能不能加载随包的这份要先试。 | 换实现，探针 T1 |
| 把外面的终端窗口设成原始模式，字节两头照搬 | 把外面的控制台设成“直通”模式（输入、输出都按终端转义序列走，关掉行编辑和回显）。 | 换实现，探针 T2 |
| 窗口大小变了，pty 跟着变 | 照做。 | 换实现 |
| 结束条件：程序退出，或者自己收到 SIGHUP（窗口被关）、SIGTERM、SIGINT、SIGQUIT | 程序退出，或者控制台的“窗口被关”“注销”“关机”通知。Ctrl+C 是打给里面的程序的，不是打给 `run` 的。退出码规则不变：程序的退出码；窗口被关时用 129（沿用 SIGHUP 的数字，`serve` 和测试不用分平台）。 | 换实现 |
| 回答 OSC 7501 探测 | 照做，前提是 ConPTY 把这条序列原样放出来。 | 照做，探针 T1 |
| 前台程序和当前目录（`fg.rs`）：读 pty 的前台进程组，再读那个进程的程序名和目录 | Windows 没有“前台进程组”。程序名：从 `run` 启动的那个 shell 往下找最新的子孙进程。当前目录：shell 用转义序列报了就用报的；没报就用启动时的目录。**读别的进程的当前目录没有正式的系统接口**，探针 T4 试过能稳定读到再用。读不到的后果：标题里的目录、“在同一目录新开终端”用的是启动目录。 | 换实现，探针 T4 |
| 让窗口跟着控制端的大小变（`term-fit`，`ESC[8;行;列t`） | 先发着。外面的终端不理这条序列时，控制端按 `term-fit` 规格里已有的退路缩放显示。 | 暂缓，探针 T3 |

### 9.3 `run` ⇄ `serve` 的本机通道【我定的】

unix 上是 unix socket `pty/<pid>.sock`。Windows 上换成**回环 TCP**：`run` 绑 `127.0.0.1:0`，把端口号写进 `pty/<pid>.port`。请求行、token 行、协议版本（`LOCAL_V = 2`）都不变。

- 为什么不用命名管道：tokio 的 TCP 在各平台是同一套写法，`local.rs` 只要把“流”和“监听”换个类型；命名管道在 tokio 里是另一套接口和另一种接入循环。项目里本机 IPC 早就定了用 TCP 取代 unix socket 和命名管道（`platform-design:145`），这里是同一个决定。
- 谁能连：靠 token（文件在 `local\term\` 下，权限见 §13.2）。和 unix 上“目录 0700 + token 0600”一个意思：只防同一台机器上的别的用户，不是新的一道门（`text-terminal:275`）。
- `.port` 文件过期（`run` 被强杀）：`serve` 列表时照 unix 的办法，连不上就清掉。
- unix 那一支不跟着改成 TCP：新平台不改已有平台。

### 9.4 `rapp-term serve`（开终端、列 shell）

- **shell 列表**：接上已经写好的 `shells.rs:98-137`（现在 `rust/term/src/serve.rs:855-860` 的 `installed_shells()` 在非 unix 上返回空表）。规则照 `term-entry`：默认 `cmd.exe`；按钮叫 `cmd`、`PowerShell`、`pwsh`、`Git Bash`、`Git sh`；`System32\bash.exe` 是 WSL 的入口，永远不列。
- **开窗口**：装了 Windows Terminal 就让它在**已有窗口里开一个新标签页**，里面跑 `rapp-term.exe run …`（对应 macOS 上“在 Terminal 的窗口里开标签页”）；没装（Server 2022 默认没有）就开一个普通控制台窗口。不写 `.command` 脚本文件，命令行直接给。5 秒内没等到 `run` 回来报到，报 `START_TIMEOUT`，和现在一样。
- **终端不归服务管**：窗口进程启动时脱离 §8.1 的作业对象。重启服务、升级都不结束终端（`cli-update-design` 的要求）；升级后旧版本目录留着，它们继续用旧的 `rapp-term.exe`（§5.1）。
- **结束终端**（Ctrl+Shift+W、会话菜单）：结束里面的程序，`run` 随之退出。Windows Terminal 默认只在退出码是 0 时自动关标签页，所以 rApp 主动结束的终端让 `run` 以 0 退出。【未验证，探针 T2】
- **以谁的身份**：永远是机主，在机主的登录会话里。登录前没有终端（非目标）。
- macOS 上“等对方允许 rApp 控制 Terminal”的那条提示（`NO_ANSWER`）Windows 没有对应物，不出现。

## 10. 控制端

### 10.1 平台能力位

界面里不写 `Platform.isWindows`。现在 `gui/lib/platform_caps.dart:40-52` 给 Windows 的是：有服务、有托盘、有窗口管理、在线升级、端口面板。要改和要加的（能力位的名字由实现的人定）：

| 能力 | macOS | Linux | Windows | 现在是怎么判断的 |
|---|---|---|---|---|
| 画面由 `rapp-session` 进程解码、Dart 画 | 否（原生） | 是 | **是** | `main.dart:93-97` 按系统名分支 |
| 用系统程序打开文件、文件夹、网址 | 是（`open`） | 是（`xdg-open`） | **是**（现在只对了一半） | **这不是一个能力位。** `systemOpen` 只有 iOS 是真（`gui/lib/platform_caps.dart:17,37-41`），意思是“走 iOS 的系统接口，不起子进程”；桌面三个系统都是假，Windows 也保持假。要改的是下面说的那个共用函数 |
| 记住解锁密码 | 钥匙串 | 只在内存 | **系统凭据管理器** | `ui/unlock.dart` 按系统名 |
| 语音 | 原生 | `rapp-speech` | **`rapp-speech`** | `gui/lib/ui/main_state.dart:170-175` |
| 搬数据目录 | 是 | 是 | **是** | `pages/data_section.dart:165` 对 Windows 隐藏（因为用了 `cp -Rp`） |
| 键栏“按了实体键就收起”时 Ctrl 不算 | 否 | 是 | **是** | `embed/key_bar.dart:176-183` 只认 Linux |
| 拆出独立窗口 | 是 | 是 | 否（非目标） | 已有 |
| 原生输入框、Dock 菜单 | 是 | 否 | 否 | 已有 |

“自动锁屏”这一行不是平台能力：它看**对方或本机服务报的 `resident`**（§7.1），macOS 上一直显示。

“用系统程序打开”收成一个函数（macOS `open`、Linux `xdg-open`、Windows 上文件夹用资源管理器、文件和网址用系统的“打开”）。现在它散在六处，各写各的：`gui/lib/ui/main_window.dart:39-43`（经 `service_control.dart:122-125` 的 `openFolderCommand`，Windows 上已经是 `explorer`）、`gui/lib/term/term_stage.dart:47-61`（Windows 上已经是 `cmd /c start`）、`gui/lib/embed/linux_session_port.dart:473`、`gui/lib/pages/local_section.dart:40-46` 和 `gui/lib/pages/data_section.dart:52-57`（**这两处在 Windows 上落到 `xdg-open`，是错的**）。六处都改成调这一个函数；iOS 那一支（`systemOpen`）留在函数里面。

### 10.2 嵌入的远程画面

照 Linux 的办法，**不另写一套**：每个会话一个没有窗口的 `rapp-session.exe`，hub 的 `open` 在回环地址上开口子并给出 `opened {sid, port, token}`，界面用标准输入给 worker 发命令，从标准输出收事件和帧（24 字节头 + BGRA），在 Dart 里画。

- **`LinuxSessionPort` 不复制成 `WindowsSessionPort`**【我定的】。这个类名字带 Linux，内容九成和系统无关。把里面真正和 Linux 绑着的几处抽成一个小接口，Linux、Windows 各给一个实现：剪贴板读写（文字、图片、文件列表）、选文件、拖文件进来、藏窗口和关窗口、在资源管理器里显示、结束子进程（Windows 没有 SIGTERM）、`LANGUAGE` 环境变量、路径拼接。要不要顺手改类名由实现的人定；改的话单独一个只改名的提交。
- **按键**：照 Linux。Flutter 在 Windows 上给的也是 USB HID 键位，`linuxMacKeyCode` 那张表直接用。Ctrl 当远端的 ⌘，Alt 当 ⌥，Win 键留在本机，F11 是本机全屏不外发，Ctrl+Enter 留给输入板。
- **本机系统先截走的键发不出去**：Alt+Tab、Win 组合键、Ctrl+Alt+Del、Alt+F4（它关的是 rApp 自己的窗口，也就是藏到托盘）。不装键盘钩子去抢（§3.2）。要给远端发这些，用键栏和会话菜单。AltGr 在 Windows 上等于 Ctrl+Alt，直接按会被当成 ⌘⌥；带 AltGr 的字符走输入板。
- **够不够快**是探针 G2 要回答的。不够才做 §4 里放弃的原生贴图。
- 总流量、离线冻结、取景、捏合缩放、窗口菜单、多屏挑选、焦点面板的显示，都在共用的 Dart 里，跟着嵌入画面一起有。

### 10.3 外壳（`gui/windows/runner/`，C++）

只做这些：

| 事 | 说明 |
|---|---|
| 程序名 | `BINARY_NAME` 从 `rapp` 改成 `rapp-gui`。窗口标题、图标（已有的 `app_icon.ico`，桌面那一套）不变。 |
| 单实例 | 命名互斥量。第二次启动：让第一个实例把主窗口显示出来，自己退出。`--cm` 小窗不受单实例限制，但主窗口在屏幕上时它直接退出（照 macOS 的规则；Linux 的 `--background` 是另一回事）。 |
| `rapp/system` 通道 | `fontSize`（系统的文字大小设置，现在兜底是 15）和 `visible`（主窗口在不在屏幕上，`main.dart:126-129` 用）。 |
| `rapp/unlock` 通道 | 读、写、删系统凭据管理器里的一项（密码和“自动解锁”两个字段），只存本机、不漫游。 |
| 剪贴板、选文件、拖文件 | 方法名和参数照 `rapp/linux` 通道现有的那几个（`clipboard_read`、`clipboard_write`、`choose_files`、`drop_files`、`hide_window`、`close_window`），Dart 这边才能共用。用现成的插件还是自己写由实现的人定，新依赖要钉版本。 |
| 托盘 | `tray_manager` 在 Windows 上要 `.ico`（`main.dart:243` 现在给的是 PNG 模板图）。菜单内容和别的平台同一份。 |
| 清单 | 加“支持长路径”。每屏独立缩放已经有了。 |
| 任务栏固定 | 给进程和开始菜单快捷方式设同一个应用标识，升级换版本目录后固定在任务栏上的图标不失效。【未验证，探针 G4】 |

不做：`rapp/session`（画面走 worker）、`rapp/composer` 和候选栏（非目标）、`rapp/dock`（非目标）、`rapp/speech`（走 worker）。`rapp/secure-input` 在 macOS 上是输密码时打开系统的安全输入，Windows 没有对应物：共用代码要容得下这个通道不存在。界面程序不设开机自启（macOS 也没有）。

把旁边那些 `.exe` 放进包里不写进 CMake，由打包脚本拼版本目录（Linux 的 `scripts/build-linux.sh` 就是这么做的）。

### 10.4 输入板和输入法

用 Flutter 输入框加系统输入法（`composer-writing-panel:82` 早就这么定了）。输入历史、输入块、快捷区开关、键栏和常用语条照 PC 的逻辑走（`pc-key-bar:47`）。要在实机上确认的是 Flutter 在 Windows 上和输入法配合得怎么样：候选窗跟不跟光标、组字时按回车是不是只上屏不发送、“在画面上直接打字就进输入板”时第一个键会不会丢。【未验证，探针 G3】

### 10.5 语音

照 Linux：长按右 Alt 0.3 秒开始，松开发送，Esc 取消，Tab 编辑；只在 rApp 是当前窗口时有效，不做全局快捷键（`macos-voice:14`）。

- 程序还是 `rapp-speech`，识别部分（钉死版本的 whisper）和模型文件（同一个文件、同一个摘要，首次使用时下载并校验）共用。Windows 只换**录音**：用系统的音频接口直接录，转成 16 kHz 单声道。模型放 `%LOCALAPPDATA%\rapp\speech\`，不进同步的数据目录。录音只在内存里，不存不传。
- 为什么不用 Windows 自带的语音识别【我定的】：它要用户另外打开在线语音的隐私开关、装语言包，效果和 Linux 那套不一样；共用一份识别代码更省事。
- 快捷键设置那一行（`ui/side_panel.dart:276`）在 Windows 上照 Linux 不显示：存的是 macOS 的键码。
- 系统设置里把麦克风关了的时候要报出来，不能只是没反应。在 AltGr 键盘布局上长按右 Alt 会和 AltGr 冲突，这是已知限制，用语音按钮。
- 语音整理、语音学习、本地纠词都在共用的 Dart 和网关那边，不分平台。
- 【未验证，探针 V1】：whisper 在 Windows 工具链下能不能编、不开新指令集优化时的速度。

### 10.6 共用界面里要补的小处

- `paths.dart:60-99` 手写 `/` 拼路径；`paths.dart:103-118` 和 `rust/net/src/log.rs` 的兜底只认 `HOME`。
- `service_control.dart:78-99`：启停服务改成 `rapp-svc ctl`；`:116-120` 和 `data_dir.dart:203-208` 的“设成私有目录”在 Windows 上是空操作，见 §13.2。
- `data_relocate.dart:51` 的 `cp -Rp` 换成不依赖外部命令的复制。
- `embed/linux_speech.dart`、`main.dart:93-97` 里写死的不带 `.exe` 的程序名，都走 `findBinary`。
- “本机”页：权限那一行在 Windows 上显示的是常驻方式（带系统服务 / 只为我）和“有没有显示器”，没有 macOS 的授权引导。
- **被控端是 Windows 时控制端要会说的话**（在共用的 Dart 里，所以 Mac、Linux、iOS 控制端也都有）：`no display`、`session disconnected`、`not interactive`、`other user` 四种原因；`inputBlocked` 的 `by` 是 `elevated` 时不套“远端正在被 X 操作”那句（`gui/lib/ui/main_state.dart:4757` 的 `inputBlockedHint`、`gui/lib/access_log.dart:37`），换成 §6.6 的那句；`covered` 的 `bundleID` 是 `consent.exe` 时在原句后面加“请打开桌面会话处理”（§7.4）；对方的 `resident` 是 `user` 时，锁屏不弹解锁框，写“这台电脑没装系统服务，要在本机解锁”（§6.9）；登录前的设备卡片“未登录，只能打开桌面”；`other user` 时“别的用户正在使用这台电脑”；解锁框写“密码或 PIN”；桌面会话菜单里的“发送 Ctrl+Alt+Del”（§7.5）。
- **已经发出去的控制端遇到这些会怎样**【我定的】：`elevated` 会被说成“远端正在被 elevated 操作”，别扭但不出错；`covered` 那句本来就通；不认识的原因按原文显示。这些话都在共用的 Dart 里，C、D 段合并以后随 macOS、iOS 的正常发版出去，比第一个公开的 Windows 版（U7）早，所以用户实际碰不到。`elevated` 是约定值，设备名正好叫这个的会被说错，接受。
- **审一遍写死“Mac”的句子**：提示语里“在那台 Mac 上……”这类话，对方是 Windows 时要按对方的系统说（设备的 `os` 字段已经有了）。
- 终端的等宽字体回退表里要有 Windows 自带的等宽字体；正文的回退表已经有微软雅黑（`design-language:141`）。

## 11. 端口共享和随共用代码一起有的功能

### 11.1 端口共享

代码全在 `rapp-ports`、`rapp-service`（`share_cmds.rs`、`maps.rs`、`pipe.rs`）、`rapp-hub`（`ports.rs`）、`rapp-cli` 里，没有系统专用的部分，预计只要编过。

| 现在怎么做 | Windows | 状态 |
|---|---|---|
| `rapp share <端口>`、`rapp unshare`、`rapp hosts`、`rapp pipe` | 照做。命令是 `bin\rapp.exe`。 | 照做 |
| 控制端在 `localhost` 上开共享号 28000–28999（`local-ports` 规格） | 照做。只绑回环地址，**不需要防火墙规则**，也不会弹防火墙提示。 | 照做，探针 N1 |
| 转发的节奏控制（forward pacing） | 在共用代码里。 | 照做 |
| 端口面板 | 能力位已经有了。 | 照做 |
| `rapp pipe` 用标准输入输出传原始字节 | Rust 在 Windows 上不做换行转换，预计不用改。 | 照做【未验证】 |
| 登录前 | 没有（非目标）：登录前实例的能力里不报端口。 | 不适用 |

### 11.2 不用写 Windows 代码、但要在 Windows 上验的

下面这些全在共用的 Dart、`rapp-hub`、`rapp-service`、`rapp-conn` 里，Windows 版编过就有。它们不出现在 §6–§10 的改动表里，但都在 §15 的对齐总表里，验收时一条条过：

设备密钥和轮换、relay 配置、直连和中继、断线重连、平滑显示和滚动复制的显示、离线冻结、看不见的会话暂停、多台控制端接管、设备的系统图标（`gui/lib/ui/os_mark.dart` 已经有 Windows 的图标）、版本标签、应用档案、状态规则的显示、程序状态和状态队列、总览（含“打开应用”和“正在被接入”）、顶栏、侧栏、会话卡片、日志页、输入历史、输入块、快捷区开关、键栏和常用语条、缩放快捷键、语音整理和语音学习、数据同步。

## 12. 安装、升级、卸载

### 12.1 安装程序

- **一个 `.exe`**，用 Inno Setup 做（版本钉死）【我定的】。文件名 `rapp-<版本>-windows-x64-setup.exe`，正好落在官网已有的匹配规则里（`website/releases.mjs`）。不做 MSI、MSIX（非目标）。
- **装之前检查**：内部版本号 ≥ 20348；有桌面（Server Core 拒绝）；x64（ARM 机器靠系统模拟，放行，【未验证】）。不满足就说明原因并退出。
- **让用户选一次**：“带系统服务（要管理员；开机就在、能过锁屏和登录界面）”或“只为我安装（不要管理员；登录后才在）”。默认前者。选择页上直接列出 §12.2 里这种方式会改的系统设置。
- **安装程序自己只做三件事**：解出版本目录、显示界面和提权、调 `app-<版本>\rapp-svc.exe install --mode system|user`。**所有对系统的改动都在 `rapp-svc install` 这一个 Rust 函数里**【我定的】，卸载是它的反函数 `rapp-svc uninstall`。理由：在线升级时 `rapp-svc` 本来就要重做其中几步（改启动项、重写快捷方式），同一件事不在安装脚本和 Rust 里各写一遍；Rust 这边能测。
- 系统服务方式下，最后以**发起安装的那个用户**的身份运行 `rapp-svc claim-owner`（§7.2）。
- **装在哪**：系统服务方式固定是 `%ProgramFiles%\rapp\`，不让改【我定的】（装到别的盘，目录权限就不是“只有管理员能写”，§7.7 的前提没了）。“只为我安装”固定是 `%LOCALAPPDATA%\Programs\rapp\`。
- **再装一次就是升级**：解出新的版本目录，走和在线升级同一个“切换”（§12.3）。换方式（只为我 → 带系统服务，或反过来）也是再跑一次安装程序：`rapp-svc install` 先撤掉另一种方式留下的东西。两种方式不同时存在。
- **无人值守**：Inno Setup 自带静默安装参数，方式用一个参数给；系统服务方式还要用 `/OWNER=<账户>` 指明机主（§7.2）。给批量装服务器的人用，不另做工具。
- **静默安装只把程序和服务装上，第一次配置要在界面里做**【我定的】。`rapp` 命令行现在只有 `share`、`unshare`、`hosts`、`pipe`、`update`（`rust/cli/src/args.rs`），没有配 relay、配对设备的命令，这次不加（relay 是唯一的门，不为了 Windows 给它开新的入口）。所以一台新服务器要有人登录一次（本机或者远程桌面），打开 rApp 配好；配好以后就不用再登录，重启后登录前实例用的就是这份配置（§7.6）。不登录就完成第一次配置是非目标。
- 安装不结束正在跑的文本终端，也不要求重启电脑。

### 12.2 安装会改哪些系统设置（全部列在这里，卸载时还原）

| 改什么 | 在哪 | 哪种方式 | 卸载时 |
|---|---|---|---|
| 程序文件 | 安装目录 | 都有 | 删 |
| Windows 服务 `rapp`：开机自动启动，SYSTEM 身份，失败后自动重启 | 服务管理器 | 系统 | 停掉，删 |
| 登录时启动 `rapp-svc user` | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 里的 `rapp` | 用户 | 删 |
| 机主、方式、保存的原策略值、（可选的）升级地址 | `HKLM\Software\rapp` | 系统 | 删 |
| PATH 里加 `<安装目录>\bin` | 系统 PATH（系统方式）或用户 PATH（用户方式） | 都有 | 只去掉自己加的那一段 |
| 开始菜单里的 rApp | 所有用户的（系统方式）或当前用户的开始菜单 | 都有 | 删 |
| “应用和功能”里的卸载项 | 注册表的卸载项 | 都有 | 删 |
| 防火墙入站规则：UDP 22028，只给 `rapp-service.exe` | Windows 防火墙 | 系统 | 删 |
| 允许服务发 Ctrl+Alt+Del 的策略 | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` 的 `SoftwareSASGeneration` | 系统 | 还原成安装前的值，原来没有就删 |
| 日志和升级缓存 | `%ProgramData%\rapp\` | 系统 | 删 |

**不改的**（写出来是为了审计时能查）：电源和睡眠设置（只在说明里提醒）、Windows Defender 的排除项、输入法设置、默认终端、Windows Terminal 的配置文件、用户的 shell 配置文件、文件关联、`rapp://` 之类的协议注册。

用户方式没有管理员权限，加不了防火墙规则：`rapp-service` 第一次监听时系统会弹防火墙提示。点了允许，局域网直连可用；没点，只是别人直连不进来，走 relay 照常。版本目录换了以后这个提示会不会再弹一次要实机看【未验证，探针 N2】。防火墙规则绑的是程序路径，所以系统方式下每次切换版本都要重写它。

### 12.3 在线升级

**不变的**（都在 `rapp-service` 和共用界面里）：20 小时查一次；状态和提示；“空闲了才自动装”的规则（本机键盘鼠标 10 分钟没动，并且远程会话 10 分钟没动；手动安装和回退不等远程会话）；`rapp update` 和它的本机 IPC 命令；让界面先退出、装完再打开；`rapp-term` 和 `rapp-cli` 不拦升级（`rust/service/src/update.rs:514`）；`auto_update` 开关。

**Windows 上不一样的**：

| 环节 | macOS 现在 | Windows |
|---|---|---|
| 清单地址 | `…/releases/latest/download/latest.json` | `https://github.com/wizlijun/rapp/releases/download/update-windows/latest.json`。Windows 的 release 不标 Latest（U2），“latest” 这个地址永远指向 macOS 的版本，所以另放一个**固定的 release**（tag `update-windows`，不是版本号，不标 Latest），里面只有这一份清单，每次 Windows 发版覆盖它。【我定的】 |
| 清单内容 | 顶层一个 `version`，`assets["macos-arm64"]` | 同一种格式，键是 `windows-x64`。因为顶层只有一个版本号，各平台的版本号又不同，**一个平台一份清单**。`rapp-update` 里写死的平台名（`lib.rs:21`）和 `scripts/lib/release.sh:29-46` 里写死的键都改成按平台取。 |
| 升级包 | `.app` 的 zip | `rapp-<版本>-windows-x64.zip`：一个版本目录的全部内容。 |
| 谁下载 | `rapp-service` 调 `curl` | **`rapp-svc` 自己下载**，两种方式同一段代码。用系统自带的 `%SystemRoot%\System32\curl.exe`，写完整路径。理由：系统方式下，下载下来的东西要以系统权限运行，所以“从哪下、下的是不是那一份”必须由 `rapp-svc` 自己说了算，不能听用户身份的进程的。 |
| 请求里有什么 | —— | 只有版本号。`rapp-svc` 自己去取清单，只接受“清单里现在的那个版本”；清单地址用内置的，系统方式下的覆盖值只从 `HKLM\Software\rapp` 读，**不读数据根里的 `update_url`**；包的地址必须以 `https://github.com/wizlijun/rapp/releases/download/` 开头（用了覆盖地址时以覆盖地址的站点为准）。 |
| 校验 | 大小、sha256；签名者变了要用户确认 | 大小、sha256。有了证书以后再加“签名者和正在跑的这一版相同”：从没签名变成有签名直接放行；签名者换了或者签名没了，自动升级不装，手动升级要确认（沿用现有的“签名变了要确认”那条路）。 |
| 解包 | `ditto` | 系统自带的 `%SystemRoot%\System32\tar.exe`，先解到临时名字，解完、核对过再改名成 `app-<版本>`。 |
| 换上去 | 换掉 `.app`，重启服务 | 切换版本目录，见下。 |
| 回到上一版 | 备份的上一个 `.app` | 上一个版本目录，同一个切换。 |
| 安装等级（install-level） | 有：旧包缺了要管理员才能装的东西时提醒重装 | **没有**。系统方式下 `rapp-svc` 本身就是 SYSTEM，安装时要管理员做的事它升级时都能重做；用户方式没有要管理员的步骤。 |
| 缓存目录 | `Library/Caches/rapp/update` | 系统方式 `%ProgramData%\rapp\update`，用户方式 `%LOCALAPPDATA%\rapp\update`。 |

**切换**（安装、在线升级、回退用的是同一个函数）：

1. 新版本目录已经完整（最后写一个“解完了”的标记文件；没有标记的目录不算数，启动时清掉）。
2. `rapp-service` 让界面退出，留下“装完再打开”的标记，然后请 `rapp-svc` `apply-update <版本>`。
3. 旧的 `rapp-svc` 启动 `app-<新版本>\rapp-svc.exe take-over`（路径由 `rapp-svc` 自己用版本号拼，版本号只许数字和点），这个进程不能随旧的监督程序一起被结束。
4. `take-over` 停掉旧的监督程序（它带着 `rapp-service` 和 worker 一起停，文本终端不停），把启动项（服务的程序路径，或者 `Run` 值）改指新目录，启动新的监督程序。
5. **新的 `rapp-svc` 每次启动都以自己所在的目录为准，把别的东西对齐过来**：`current`、`bin\rapp.exe`（旧的正在被用就先改名挪开再放新的）、开始菜单快捷方式、防火墙规则。所以第 4 步中途断了也不要紧：启动项指着哪个目录，哪个目录就是真的。
6. **新的起不来就退回去**【我定的】：`take-over` 等最多 30 秒，新的监督程序报不出“`rapp-service` 在跑”，就把启动项改回旧目录、启动旧的，并记下这个版本失败过（不再自动装它，手动可以）。理由：被控的服务器没人在旁边，一次坏升级不能让它再也连不上。除了这一条，不做别的自动回退（`online-update-design` 的非目标照旧）。
7. 新的 `rapp-service` 起来后看到标记，重新打开界面（现有逻辑）。

**旧目录什么时候删**：`rapp-svc` 启动时和切换后，删掉既不是“现在的”也不是“上一版”的版本目录；删不掉（还有文本终端开着里面的文件）就留到下次。

**自动升级默认开，登录前也升**【用户定的，U8】：`auto_update` 的默认值现在就是开（`rust/service/src/config.rs:86-88`），Windows 上不改这个默认，系统服务方式也一样。没人登录时没有用户身份的 `rapp-service`，由 `rapp-svc` 自己按同样的间隔查（判断函数用 `rapp-update` 里现成的），在没有它启动的 `rapp-host` 在跑的时候（也就是没人连着登录界面）下载并切换。机主的 `auto_update` 关了就不做。理由：长期没人登录的服务器如果停在旧版，协议一升版就连不上去登录，只能到机房去。

**信任明说**：没有证书的时候，升级包的可信度就是“HTTPS + 谁能往这个仓库发 release”；sha256 和清单同源，只防下载坏了（`online-update-design` 对 macOS 也是这么写的）。系统方式下这意味着**能发 release 的人能在所有装了系统服务的机器上以系统权限运行代码**。这是自动升级加系统服务必然带来的，写在这里让用户知道；不想要就把 `auto_update` 关掉。

### 12.4 卸载

卸载程序调 `rapp-svc uninstall`（还原 §12.2 的每一项），再删安装目录。

- **留下的**：数据根（`%USERPROFILE%\rapp`）、它的指针（`%APPDATA%\rapp`）、日志、凭据管理器里记住的解锁密码。卸载界面上说明这些留着，以及在哪删。
- **删掉的**：升级缓存、语音模型（是下载来的缓存）。
- 有 rApp 开的文本终端还在跑时，它们开着安装目录里的文件，删不掉：卸载程序列出来，问用户是结束它们还是先取消卸载【我定的】。

### 12.5 签名（U4）

- 打包脚本里有签名这一步：环境里给了证书就签自己编出来的全部 `.exe`、`.dll` 和安装程序；没给就跳过，在输出里明显地标一行，发版说明里也写“未签名”。
- 没签名的后果只有一个：下载和第一次运行安装程序时系统会警告（“更多信息 → 仍要运行”）。README 的安装说明里写清楚。
- **设计不依赖签名**：不用任何“签了名才给”的系统能力。特别是不用“界面自动化访问权限（UIAccess）”来碰提权窗口，那条路要签名加固定安装位置；这里走的是系统服务加帮手。
- 证书到位以后：升级校验加上签名者（§12.3）。别的不变。

### 12.6 构建和打包脚本

照 Linux 的分法（`scripts/build-linux.sh`、`scripts/package-linux.sh`、`scripts/test-linux-bundle.py`），脚本名和用什么脚本语言由实现的人定，要做到的事是定的：

- **构建**：编出 §5.1 列的全部程序（目标 `x86_64-pc-windows-msvc`；Rust 程序把 C 运行库静态链接进去，只有 Flutter 那部分需要随包的运行库 dll），Flutter 出 release 包并改名 `rapp-gui.exe`，把随包的 ConPTY 取下来（版本和 sha256 钉死，照 `rapp_rime` 取外部文件的做法），拼成一个版本目录。
- **打包**：签名（有证书时）、出 zip、出安装程序、出 `SHA256SUMS`、出清单。记一份 `BUILD-INFO.json`（Rust、Flutter、引擎、Inno Setup、ConPTY 的实际版本），Linux 包里已经有同样的东西。
- **包的自检**：版本目录里每个程序都在；每个程序报的版本号一致；`rapp-host version --json` 报的协议号等于仓库里的；没有带进调试文件。

## 13. 数据、日志、密钥

### 13.1 东西放哪

| 东西 | 位置 | 谁写 |
|---|---|---|
| 数据根（配置、设备、历史、同步的内容） | `%USERPROFILE%\rapp`（已有） | 机主身份的进程 |
| 数据根的指针、旧配置 | `%APPDATA%\rapp` | 同上 |
| 机密（设备密钥、token、终端的本机通道） | `<数据根>\local\`，不进 git | 同上 |
| 传输收到的文件 | `RAPP_DOWNLOADS`，否则 `<数据根>\files\transfers` | `rapp-host` |
| 日志（用户身份的进程） | `%LOCALAPPDATA%\rapp\logs` | 各进程 |
| 日志（系统身份的进程：系统方式的 `rapp-svc`、帮手、登录前实例） | `%ProgramData%\rapp\logs` | 只有 SYSTEM 和管理员能写，机主能读 |
| 升级缓存 | §12.3 | `rapp-svc` |
| 语音模型 | `%LOCALAPPDATA%\rapp\speech` | `rapp-speech` |
| 系统方式的设置 | `HKLM\Software\rapp` | 只有 `rapp-svc`（SYSTEM）和安装时 |
| 记住的解锁密码（这台机器当控制端时） | 系统凭据管理器 | 界面 |

数据根可以搬（现有功能）。搬到网络盘或加密文件夹以后，登录前实例读不到（§7.6），界面上搬家时提醒一句。

### 13.2 文件权限

unix 上的规矩是“目录 0700、文件 0600”。Rust 里真正设权限的有五处（别的 `chmod` 都在测试里）：`rust/net/src/datadir.rs:22-26`（`local` 目录）、`rust/net/src/config.rs:96-111` 的 `write_private`（密钥和配置文件，`rapp-wire`、`rapp-conn` 都调它）、`rust/net/src/log.rs:218-225`（日志目录）、`rust/term/src/pty/local.rs:30-37`（终端的几个目录）、`rust/service/src/lib.rs:303-311` 的 `make_private`（launchd 的日志，Windows 上没有这个文件，不用管）。Windows 上【我定的】：

- 在 `rapp-net` 里加一个函数“设成私有”：关掉继承，只留**这个用户、SYSTEM、Administrators**。原来做 `chmod` 的地方在 Windows 上都调它。
- 为什么不能什么都不做：`%USERPROFILE%` 下面默认就是这三者，看起来不用管；但数据根搬到 `D:\rapp` 这类地方以后，默认权限是“本机所有用户可读”，密钥就漏了。
- Dart 里那两处（`service_control.dart:116-120`、`data_dir.dart:203-208`）：调系统自带的 `icacls`（完整路径），或者保证 Rust 一侧总是先于第一次写机密把目录设好，二选一由实现的人定。
- **验收**：新装之后，以及把数据根搬到非用户目录的盘之后，`<数据根>\local` 的权限里只有上面三者。
- SYSTEM 留在名单里是必须的：登录前实例要读设备密钥。所以**设备密钥不用“只有本人登录后才能解开”的系统加密**，本机的管理员和 SYSTEM 读得到它。这和 macOS 上 root 读得到是同一个水平。
- 本机 IPC 的 token、终端通道的 token：同样的权限，意思和 unix 上一样，只防同一台机器上的别的普通用户。
- 命名管道的权限见 §7.3、§7.4；安装目录的权限见 §5.1、§12.1。

### 13.3 日志

格式、轮转、级别用 `rapp-net` 里现成的那一套，`rapp-svc` 和帮手也用它，不另写。不往 Windows 事件日志里写（服务起不来时服务管理器自己会记）。

- **绝不记**：密码、PIN、token、密钥、打的字、剪贴板内容。解锁只记“成功”或“失败”。帮手收到的输入事件不记内容。
- `rapp-svc` 的管道请求每条记一行：谁（SID）、哪个登录会话、哪种请求、结果。这是系统权限的入口，要留痕。
- 日志页（现有功能）能看到用户身份的日志；系统身份的日志机主可读，要不要在日志页里一起显示由实现的人定。

### 13.4 配置参考

`config-reference` 的规矩是“代码改了字段，同一个提交里改文档”。Windows 版会加进去的：`list_apps` 回答和本机 `status` 里的 `resident`、`prelogin`；`HKLM\Software\rapp` 里的各个值；各个路径的 Windows 写法；`permissions` 里 Windows 的四种原因和 `applications`；`inputBlocked` 的约定值 `elevated`；`covered` 里表示系统确认的 `consent.exe`；安装参数 `/OWNER`。

## 14. 协议、测试、发版

### 14.1 协议

- Windows 从第一天就是画面协议 v16，和现有各端必须完全相等才能连。**不为 Windows 加协议消息，不升版本**：§6.3 把每个 macOS 概念都落到了现有字段上，新信息走控制面的可选字段。
- `host-core` 的协议号**直接用 `rapp_client_core::protocol::VERSION`**（`host-linux` 已经这么做，`rust/host-linux/src/main.rs:17`），不另设常量。所以 Rust 这边还是一个数。
- 改协议时要一起改的地方，从四处变成五处：Swift（`Sources/RappCore/Protocol.swift:15` 和 `:490` 的已知类型表）、Rust 控制端（`rust/client-core/src/protocol.rs:4` 和 `:350-365` 的放行表）、Dart（`sessionProtocolVersion`）、`rapp-session` 的样本文件、**`host-core` 的行为和它的样本**。
- **新规矩**：给协议加被控端行为的那个提交，要同时在 `host-core` 里实现，并补上 Swift 生成的样本。门禁里有一条测试盯着：协议里每一种消息类型，`host-core` 要么处理，要么出现在一张明写的“不处理”表里（现在表里是 `menuBar` 17、`menuPick` 18、`weak` 28）。新加了类型却两边都没有，Mac 上的门禁就红。“协议里有哪些类型”这张单子本身也由 Swift 生成成样本（§14.2），不在 Rust 里手抄。这是 U5 的长期代价（§4）。
- **这条规矩管得住“新加的消息”，管不住“旧消息的行为变了”**（比如编码器换了一种瓦片的选法）。后一种靠 §14.2 的逐字节样本：Swift 一改，样本重新生成，`host-core` 对不上就红。两样合起来，才是“协议号相等就一定连得通”的依据。

### 14.2 样本测试：`host-core` 和 Swift 逐字节一致

这是“Windows 被控端发出的字节 Mac 控制端一定解得了”的保证，也是搬运几千行算法时唯一靠得住的对照。

- **样本由 Swift 生成**，`host-core` 只读样本、比结果，不自己造期望值。已有先例：`Tests/RappCoreTests/CrossFixtureTests.swift` 生成 `rust/client-core/tests/fixtures/scroll-copy.bin`。
- 每个样本是“输入 + Swift 的输出”：给定的像素帧序列（含上一帧）、参数（模式、密度、是否全帧）→ 编码后的字节；给定的窗口原始事实 → 窗口表；给定的控件层级 → 焦点面板矩形；给定的规则和像素 → 状态规则的结果；给定的事件序列 → 分片发送的时序决定。
- **哪些能出样本，哪些不能**【用户定的，U10：不动 Swift】。样本生成器是 `Tests/RappCoreTests/` 下的测试，只能调 `Sources/RappCore/` 里不碰系统的代码。所以分两类：
  - **`Sources/RappCore/` 里有的，全部出样本、逐字节对**：量化的五种模式和圆角规则（`Quantize`）、瓦片编码的每种瓦片和分片与收尾帧（`TileCodec`）、压缩（`Deflate`；同一个 zlib 级别、同样的刷新点，输出要逐字节相同；`flate2` 用哪个后端才能和 Swift 的 zlib 一致要先试，【未验证，探针 C1】）、滚动复制（`ScrollDetect`）、分片发送和省流阶梯（`PacedSender`、`SendPacer`、`SaveLadder`、`WeakTier`）、暂停（`PauseOutbox`）、取景和几何（`Geometry`）、窗口后处理和夹取（`Windows`）、点穿判断（`HitTest`）、焦点面板（`FocusPane`、`FocusTracker`）、状态规则引擎（`StateRules/`）、解锁步骤表（`UnlockSequence`）、锁屏判断（`ScreenLock`）、剪贴板规则（`Clipboard`）、传输的续传规则（`Transfers`）、消息的编码解码和已知类型表（`Protocol`）、命令行解析（`WorkerCLI`）、按住的键和让出输入（`HeldInput`、`InputYield`）、查询的合并和超时（`QueryCoalescer`、`QueryDeadline`、`PendingActions`）。以搬的时候 `Sources/RappCore/` 里实际有的文件为准，上面没点到名的也算。
  - **只在 `Sources/rapp-host/` 里有的，出不了样本**：握手和接管的先后、会话主循环里各种消息的处理顺序（`Server.swift`）、解锁时“打字、等、再看锁没锁”的整套编排（`Server.swift`、`UnlockTyper.swift`）、粘贴的步骤（`Paster.swift`）、窗口跟踪循环什么时候重发窗口表（`WindowTracker.swift`）、关掉遮挡的重试（`CoverCloser.swift`）。这些和 macOS 的系统接口写在一起，不改 Swift 就单独调不了。**不为了出样本去改 Swift**（U10）：改 macOS 被控端要过门禁、发版，有回归风险，而且和“新平台不改已有平台”相反。
- **第二类靠三样东西代替样本**：
  1. **一张对照表**，放在 `rust/host-core/` 里（一份 Markdown）。每一行：Swift 的文件和行号范围 → 这段规定了什么行为 → `host-core` 里哪个模块实现 → 哪条测试钉住。搬一段写一行。没有测试的行不算搬完。
  2. **假平台整会话测试**：`host-core` 配假平台，对面是**真的 Rust 控制端代码**（`rapp-client-core` 的协议读写和解码器；测试台放在 `rapp-testkit`，B 段新建），把握手、接管、暂停恢复、解锁（成功、密码错、没锁时收到）、粘贴、传文件、窗口增减、遮挡各走一遍。控制端解得了、状态走得对，才算过。
  3. **实机验收**：Mac 控制 Windows，§15.3 逐行过（D、F 段的完成标准）。
- **Swift 那边以后改了怎么办**【我定的】。第一类不用管：样本一重新生成，`host-core` 没跟上门禁就红。第二类没有这道保险，所以对照表里记下它引用的每个 Swift 文件当时的内容摘要，Mac 门禁里加一条测试核对。有人改了 `Server.swift` 这类文件，这条测试就红，提醒他看一眼 `host-core` 要不要跟着改；看过以后更新摘要（要改就一起改，不用改就在对照表里那一行写一句为什么）。代价是 Mac 上改被控端的人每次多这一步；换来的是两份被控端不会不知不觉走岔。这条测试只读文件、算摘要，不拖慢门禁。
- 逐字节做不到的地方（比如压缩后端的输出确实不同），退一步的标准是“Swift 的解码器解 `host-core` 的输出，得到的像素完全相同”，并且在文档里记下是哪一处、为什么。
- 这些测试和系统无关，**在 Mac 的门禁里就跑**（`host-core` 不认识操作系统，§5.3）。Mac 上的人改了 Swift 的算法，样本一重新生成，`host-core` 没跟上就红。

另外三层测试：

- **`host-windows` 里不带 `cfg` 的纯逻辑**（键位表、窗口分类、显示器 id、文件名改写）：单元测试，Mac 上也跑。
- **用假平台跑整个会话**：`host-core` 的平台接口配一个假实现（固定的帧、固定的窗口），用 `rapp-client-core` 现成的协议读写和解码器搭一个控制端连上来走完整流程（测试台放在 `rapp-testkit`，B 段新建；`rapp-testkit` 现在的假程序不说画面协议）。Mac 上也跑。
- **只能在 Windows 上跑的**：采集、输入、锁屏、帮手、服务、终端、安装和升级。分两种：能自动化的写成脚本放进 Windows 的门禁；不能的（登录界面、UAC、远程桌面）写成 §16、§17 里的实机检查表，每次发版前不重跑，改到相关代码时跑。

### 14.3 两边的门禁

**Mac 的门禁不改命令**：`swift test`、`cargo test --workspace --no-fail-fast`、clippy `-D warnings`、`flutter analyze`、`flutter test`。新 crate 是 workspace 成员，自动进来：`host-core` 整个在 Mac 上测；`host-windows`、`svc-windows` 在 Mac 上是空壳加纯逻辑测试（§5.3）。加了 Windows 代码以后，Mac 上的门禁时间不能明显变长。

**Windows 的门禁**（Windows 机器上的集成 session、首发后的发版 session 用，功能 session 在 Windows 机器上开发时也用）：

1. `cargo test --workspace --no-fail-fast`，排除 `rapp-relay`、`rapp-host-linux`、`rapp-client-gtk`、`rapp-hub-ffi`（这四个的测试 Windows 上不跑）。排除管不到依赖：`rapp-conn`、`rapp-testkit` 的测试要在进程里起一个中继，所以 `rapp-relay` 的**库**在 Windows 上还是会被编译。为此 `rust/relay/src/audit.rs` 里三处 unix 专用的写法加 `#[cfg(unix)]`（只为编过，Linux 上的代码不变，中继仍然不为 Windows 构建、不在 Windows 上发）——用户 2026-11-26 同意。
2. `cargo clippy` 同样的范围，`-D warnings`。
3. `flutter analyze`、`flutter test`。
4. 构建和包的自检（§12.6）。
5. Windows 上能自动化的那部分实机测试（§14.2）。

Swift 的测试 Windows 上不跑。**Mac 上看不到 Windows 专用代码的编译错误**（空壳把它们包掉了），所以改了 `cfg(windows)` 里的代码，要在 Windows 机器上过了门禁才能合并；Mac 上的功能 session 改到共用代码时，Windows 那一支编不编得过，只能等 Windows 机器上那个 session 的门禁发现（它发现了就在 `tasks/todo.md` 记一条并自己修，或者交回给改的人；修好之前不发 Windows 版）。这是 U2 的已知代价，和 Linux 现在的情况一样。要不要加 CI 来提前发现，不在这次范围里。

### 14.4 Windows 发版 session 的规则（U2）

照 Linux 现在的做法，写成明文。

**代码怎么到 `origin/main`**【用户定的，U11】：

- 每台机器有自己的本机 main 和自己的发版 session。功能 session 合并到**自己那台机器**的本机 main（现在的规矩，只是不再只有 Mac 一台），不推送；推送归那台机器的发版 session。
- **Mac 发版 session**：只动 Windows 的合并（§14.5 第 1 条列的那些路径）照常过 Mac 门禁，**过了就立刻推到 `origin/main`，不发版、不改版本号、不打 tag**。不推的话这些提交到不了 Windows 机器。只改文档的合并也一样：现在是“攒到下一次代码改动”，改成立刻推，因为 Windows 机器上的人要读到最新的规格和计划【我定的】。
- **Windows 机器上的 session**：看这台机器的本机 main 和 `origin/main`。本机有新合并：先 `git fetch`、合并 `origin/main`，过 Windows 门禁，推送。推被拒就再 fetch、合并、重过门禁。
- **首发之前它是“集成 session”**：只做上面这件事，外加按需打内部用的 zip（U7）。不取版本号、不打 tag、不建 release、不动清单。H 段做完那天它才变成发版 session，下面的规则从那天起生效。
- 两台机器都改到同一个共用文件时，后推的那边合并。冲突由后推的那个 session 解；解不了就停下来报告，不硬推。

**Windows 发版 session**（首发之后）：

- **在哪**：一台 Windows 机器上的专用 session。它看这台机器的本机 main 和 `origin/main`，不看别的机器的本机 main。
- **什么时候发**：`origin/main` 上出现了影响 Windows 的代码改动。不发的：只改文档的；只影响 macOS、iOS 的（`Sources/`、`gui/macos/`、`gui/ios/`、`cfg(target_os = "macos")` 等）；只影响 Linux 的；`release: x.y.z`、`docs(website): snapshot …`、`docs(release): …` 和发版时产生的 `merge:` 提交。拿不准算影响。
- **版本号**：`git fetch origin`，合并 `origin/main`，取 `max(所有 v* tag, pubspec)` + 1；pubspec 的 build 号加 1。`update-windows` 这个 tag 不是版本号，不参与。
- **先占号再打包**【我定的】：门禁过了以后，先提交 `release: x.y.z`、打 tag，**立刻推 main 和 tag**，推成功了再打包、上传。推被拒（别人先推了）就 fetch、合并、重新取号。理由：三台机器（Mac、Linux、Windows）抢同一串补丁号，打包要十几分钟，这段时间里号很容易被别人用掉。占了号但打包失败，这个号就废掉，下次用下一个（仓库里已有废号的先例）。
- **发布**：
  1. 在专用的 worktree 里切到要发的提交，跑 §14.3 的 Windows 门禁。真失败就停下来报告。
  2. 提交 `release: x.y.z`，打 tag，推送（见上）。
  3. 打包：安装程序、升级用的 zip、`SHA256SUMS`、清单。有证书就签名，没有就标“未签名”。
  4. 建 draft release，上传，核对每个文件在 GitHub 上的大小和 sha256，再公开，**`--latest=false`**。公开后核对 GitHub 的 Latest 仍然是 macOS 的那一版（macOS 的自动升级靠它）。
  5. 把清单传到 `update-windows` 那个固定 release 上，覆盖旧的；再匿名下载一次核对。**这一步做完，装着旧版的 Windows 机器才会开始升级**，所以放在第 4 步核对无误之后。
  6. 提交 `docs(release): record Windows x.y.z verification and downloads`：在 `tasks/todo.md` 记一条（源码提交号、文件的大小和摘要、签没签名），刷新 `website/releases.json` 这份备用快照。**不部署网站**（部署归 Mac 发版 session；网站页面本来就是实时读 GitHub 的，快照只是读不到时的兜底）。推送。
- **不做的**：不标 Latest；不部署网站；不碰 macOS、Linux 的附件；不装 iPhone。
- **协议升版的时候**：Mac 先发了新协议的版本，Windows 的还没发出来之前，Windows 机器和新版的 Mac 互相连不上。这和 Linux 现在的情况一样（`tasks/todo.md` 里有记录）。Windows 发版 session 看到协议号变了，要优先发。

### 14.5 要加进 `CLAUDE.md` 的文字

**第一行 Windows 代码合并进 main 之前就要加**（否则 Mac 发版 session 会为每一次只动 Windows 的合并发一个 macOS 版）：

1. Mac 发版 session 那条“只影响 Linux 的改动也不发 macOS 版”后面加：“只影响 Windows 的改动（`rust/host-windows/`、`rust/svc-windows/`、`gui/windows/`、`scripts/` 里 Windows 的脚本、`cfg(windows)` 里的代码）也不发 macOS 版，但要过门禁并立刻推到 `origin/main`，Windows 机器等着用。只改文档的合并同样立刻推。”改到共用代码的（`host-core`、`rapp-service` 的缝、共用 Dart）照常算 macOS 的改动，照常过门禁、发版。
2. “其他 session”第 2 条里的“合并到本机 checkout（`/Users/bruce/git/rapp`）的 `main`”改成“合并到**自己这台机器**的本机 main”，并写明 Windows 机器上 checkout 的路径（到时填）。
3. 给做功能的 session 加一条：“改了 `cfg(windows)` 里的代码，要在 Windows 机器上过了 Windows 的门禁再合并；给协议加被控端行为时，`host-core` 和它的样本在同一个提交里改；改了 `Sources/rapp-host/` 里被 `host-core` 对照表引用的文件，同一个提交里看 `host-core` 要不要跟着改，并更新对照表里的摘要。”
4. 新加一小节“Windows 集成 session（首发前）”，内容是 §14.4 里“代码怎么到 `origin/main`”的后三条。

**第一次发 Windows 版时加**：

5. “版本号协调”那条里，“另一台机器的 Linux”改成“另外两台机器的 Linux 和 Windows”；跳过的提交里加上 `docs(release): …`。
6. “Windows 集成 session”那一小节换成“Windows 发版 session”，内容就是 §14.4 的后一半。

规矩本身用户已经定了（U2、U11）；`CLAUDE.md` 的具体文字要用户点头，这两批到时候各给用户看一次。

### 14.6 第一次发 Windows 版时要一起改的

- 官网：`website/app.js` 里 “Windows — No build yet” 的文字，`website/releases.test.mjs:30` 断言 `windows === null` 的那条测试。改文字和测试归功能 session，部署归 Mac 发版 session。
- 两份 README：安装表加 Windows 一行（基准系统、两种安装方式、未签名时的提示）；致谢里加随包的 ConPTY（MIT，微软）。
- 建好 `update-windows` 这个固定 release。
- `CLAUDE.md`（§14.5）。

## 15. 对齐总表

这张表是验收的清单：macOS 版今天（0.15.41）有的每一项功能，Windows 版是什么状态。细节在所指的那一节，这里不重复。**表里没有的功能，就是漏了，按缺陷报。**

状态的说法：

- **照做**：行为一样；系统无关的代码直接用，或从 Swift 搬进 `host-core`。
- **换实现**：行为一样，系统接口换成 Windows 的。
- **共用**：代码在共用的 Dart 或 Rust 里，Windows 版编过就有。不写 Windows 代码，但要在实机上验。
- **有限制**：能用，比 macOS 少一块，少的是什么写在旁边。
- **新增**：macOS 没有，Windows 需要。
- **不做**：非目标（§2.2）。
- **——**：这一端没有这件事。

### 15.1 连接和设备

| 功能（macOS 现在有） | Windows 当被控端 | Windows 当控制端 | 在哪 / 探针 |
|---|---|---|---|
| 自建中继 | 共用。relay 本身只在 Linux 上跑，不出 Windows 版 | 共用 | §2.2 |
| 设备密钥、配对、密钥轮换 | 共用；“保护密钥文件”换实现 | 同左 | §13.2 |
| 直连加中继、断线重拨 | 共用；UDP 双栈绑定加 Windows 一支 | 同左 | §8.2 |
| 局域网直连（入站 UDP 22028） | 系统服务方式：安装时加防火墙规则。用户方式：看系统弹不弹框 | 同左 | §12.2，N2 |
| 握手、协议版本完全相等 | 照做（v16） | 共用 | §14.1 |
| 网络状态（ping/pong）、省流阶梯、`saving`、`pinned` | 照做 | 共用 | §6.5 |
| 平滑显示第 1 步、滚动复制 | 照做，逐字节对样本 | 共用（`rapp-session` 解码） | §6.5、§14.2，C1 |
| 离线冻结 | —— | 共用 | §11.2 |
| 看不见的会话暂停（v15） | 照做 | 共用 | §6.5 |
| 几台控制端：接管、让输入 | 照做 | 共用 | §6.5、§6.6 |
| 设备的系统图标 | 共用。服务已经按系统报 `os`（`rust/service/src/peer.rs:186`），Windows 上报 `windows`，图标已有（`gui/lib/ui/os_mark.dart:99`） | 共用 | §11.2 |
| 版本标签、设备在线、总流量 | 共用 | 共用 | §11.2 |

### 15.2 常驻和本机

| 功能 | Windows | 在哪 / 探针 |
|---|---|---|
| 后台服务自启、崩溃重启（launchd） | 换实现：`rapp-svc`，系统服务方式或用户方式 | §7.1、§7.3 |
| 本机 IPC（`127.0.0.1:22029` + token） | 照做 | §8.1 |
| 服务只跑一份 | 换实现（命名互斥量） | §8.1 |
| 有人接入时的小窗（`--cm`）、总览里“正在被接入” | 换实现（服务找 `rapp-gui.exe`）；界面共用 | §8.1、§10.3 |
| 界面只跑一份、再次启动唤起主窗口 | 换实现（外壳里） | §10.3，G1 |
| 托盘图标和菜单、关窗口藏到托盘、退出前先问 | 共用；图标格式换成 `.ico`。“退出前先问”是共用的（`main.dart` 的 `_askQuit`），托盘菜单的“退出”已经走它 | §10.3，G1 |
| Dock 菜单、⌘Q | 不做（托盘菜单是同一份内容） | §2.2 |
| 开机后、登录前能连上（macOS 不支持） | **新增**，只有系统服务方式有 | §7.6，S2 |
| 两种常驻方式，控制端看得到是哪种 | **新增**（可选字段 `resident`、`prelogin`） | §7.1、§8.1 |
| 本机屏幕上登录着的不是机主 | **有限制**：不给桌面和 app，报 `other user`；机主自己的会话还在时终端、端口照常。不接回、不踢人 | §7.2，S2 |

### 15.3 被控端：应用会话和桌面会话

| 功能 | Windows 当被控端 | 在哪 / 探针 |
|---|---|---|
| 列出可分享的 app | 换实现。微软商店应用认不出真正程序的不列 | §6.4 |
| app 没开就启动它（等 10 秒） | 换实现 | §6.4 |
| 单应用会话：一个 app 的所有窗口合成一张画面 | 换实现：逐窗口采集再拼 | §6.5，H1、H2 |
| 窗口表（7 种窗口）、抬前、关、移、改大小 | 换实现；sheet 不会出现 | §6.5 |
| 整桌面会话、多屏挑选、屏幕标题 | 换实现 | §6.4、§6.5，H3、H4 |
| 没接显示器 | **有限制**：桌面和应用会话报 `no display`；终端、端口照常（U3） | §6.1、§6.5 |
| 不采鼠标指针 | 照做 | §6.5 |
| 量化、瓦片编码、压缩、分片发送、收尾帧、统计 | 照做（`host-core`） | §6.5、§14.2 |
| 取景（v14 `setView`，捏合缩放的被控端一半） | 照做 | §6.5 |
| 权限检查和授权引导（屏幕录制、辅助功能） | 不适用。换成四种“出不了画面”的原因 | §6.1 |
| 鼠标、滚轮、按键、文字输入；结束时松开所有键 | 换实现 | §6.6，H5 |
| 被控端保持英文输入；报告和切换输入法 | 换实现 | §6.6，H6 |
| 点穿保护（`covered`）、关掉遮挡（`dismissCover`）、开了别的 app 的提示（`appOpened`） | 换实现；规则在 `host-core` | §6.6、§6.8 |
| 焦点面板（v12）、密码框提示（v13） | 换实现（系统的界面自动化） | §6.8 |
| 状态规则（v16） | 照做（引擎搬进 `host-core`）。**随包的规则内容**见表下说明 | §6.8 |
| 应用档案（`app_profiles.json`） | 共用（在控制端）。按 app id 认，Windows 的 id 是 exe 名字，见表下说明 | §6.3 |
| 文字识别 | 换实现；没装语言包就不报这项能力 | §6.8，H7 |
| 菜单栏镜像 | 不做（Windows 的菜单在窗口里，随画面一起出） | §2.2 |
| 剪贴板同步（文字、图片、文件、HTML、RTF）、粘贴 | 换实现；规则在 `host-core` | §6.7 |
| 文件传输、断点续传 | 照做；文件名改写规则是新的 | §6.7 |
| 报告锁屏状态；锁着时开 app 会话先等 | 换实现 / 照做 | §6.9 |
| 自动锁屏、远程解锁 | **有限制**：只有系统服务方式有；用户方式下开关隐藏 | §6.9、§7.4，S1 |
| 会话期间保持唤醒 | 换实现 | §6.9 |
| 以管理员身份运行的窗口 | **新增**。系统服务方式：能输入、能抬前、移动、改大小、关闭；**读不到里面的控件**（没有焦点面板矩形、密码框提示、用到控件的状态规则）。用户方式：只能看，输入报 `inputBlocked`（`elevated`） | §6.6，H5、S1 |
| UAC 提示、锁屏、登录界面上的画面和输入 | **新增**，只有系统服务方式有，只在整桌面会话里。单应用会话和用户方式下：画面停住，锁屏报已锁，别的借 `covered` 说明 | §7.4，S1、H4 |
| Ctrl+Alt+Del | **新增**，只有系统服务方式有。机主在远程桌面会话里时可能不可用 | §7.5，S1、S3 |
| 几个 app 会话同时开着 | 照做；同时采整块屏的进程数有没有上限要先试，有就合成一个采集进程 | §6.5，H3 |
| 和远程桌面（RDP）一起用 | **新增** | §6.9，S3 |

**状态规则和应用档案的内容**【我定的】。机制在 Windows 上是全的，但随包的规则和档案是对着 macOS 的 app 写的（按 bundle id）。第一版 Windows 不承诺任何一个 Windows app 有现成的规则或档案：exe 名字对不上任何条目时，状态规则不报状态，档案用默认值，和 macOS 上一个没写过规则的 app 一样。给哪些 Windows app 补内容是之后的事，不在本文范围。文本终端里的程序状态不受影响（它走 OSC 7501，和 app id 无关）。

### 15.4 文本终端

| 功能 | Windows 当被控端 | Windows 当控制端 | 在哪 / 探针 |
|---|---|---|---|
| `rapp-term run`：把程序握在本机终端窗口里 | 换实现（随包的 ConPTY） | —— | §9.2，T1、T2 |
| `rapp-term serve`：屏幕状态同步、按键、未读 | 照做 | 共用 | §9.1 |
| shell 列表 | 照做（`shells.rs` 已写好，接上） | 共用 | §9.4 |
| 新建终端：在本机终端程序里开标签页 | 换实现（Windows Terminal，没装就开控制台窗口） | 共用 | §9.4，T5 |
| ⌘T 在同一目录新开、标签页、标题（`<目录> · <程序>`）、重名加后缀 | 照做；目录读不到时用启动目录 | 共用；快捷键照 Linux（Ctrl+Shift+T） | §9.2，T4 |
| ⌘W / “结束终端”，标签页自动关 | 换实现 | 共用（Ctrl+Shift+W） | §9.4，T2 |
| 终端窗口跟着控制端的大小变（term-fit） | **有限制**：外面的终端不理就缩放显示 | 共用 | §9.2，T3 |
| 重启服务、升级不结束终端 | 换实现（脱离作业对象、旧版本目录留着） | —— | §9.4、§12.3，T5 |
| 程序状态（OSC 7501）、状态队列、“需要你” | 照做，前提是 ConPTY 放行这条序列 | 共用 | §9.2，T1 |
| 不接管不是 rApp 开的终端 | 照做 | —— | §9.1 |
| 关掉已结束的标签页（`sweep`） | 不适用（终端程序自己关） | —— | §9.1 |
| 登录前的终端 | 不做 | —— | §2.2 |

### 15.5 端口共享

| 功能 | Windows 当被控端 | Windows 当控制端 | 在哪 / 探针 |
|---|---|---|---|
| `rapp share` / `unshare` / `hosts` / `pipe` | 照做 | 照做 | §11.1 |
| 控制端在 `localhost` 上开共享号 28000–28999 | —— | 照做 | §11.1，N1 |
| 转发节奏、端口面板 | 共用 | 共用 | §11.1 |
| 登录前的端口共享 | 不做 | —— | §2.2 |

### 15.6 控制端

| 功能 | Windows 当控制端 | 在哪 / 探针 |
|---|---|---|
| 主窗口、总览（含“打开应用”“正在被接入”）、顶栏、侧栏、会话卡片 | 共用 | §11.2 |
| 嵌入的远程画面 | 换实现：照 Linux，进程解码、Dart 画 | §10.2，G2 |
| 把会话拆成独立窗口、独立的 `rapp-client` | 不做 | §2.2 |
| 窗口菜单、多屏挑选、焦点面板的显示、捏合缩放、缩放快捷键 | 共用。触控板捏合在 Windows 上要验 | §10.2 |
| 键盘：本机键 → 远端键 | 照 Linux 的表；本机系统截走的键走键栏 | §10.2 |
| 输入板、在画面上直接打字、输入历史、输入块、快捷区开关 | 共用，Flutter 输入框加系统输入法 | §10.4，G3 |
| 原生输入框和 Sumi 候选栏 | 不做 | §2.2 |
| 键栏、常用语条 | 共用（PC 的逻辑） | §10.4 |
| 剪贴板、选文件、拖文件进来、传输列表 | 换实现（外壳里的通道，方法名照 Linux） | §10.2、§10.3 |
| 按住说话 | 换实现：照 Linux 用 `rapp-speech`，只换录音 | §10.5，V1 |
| 语音整理、语音学习、本地纠词 | 共用 | §10.5 |
| 文本终端的界面 | 共用。现在 `main.dart:118` 因为没有会话端口把它关了，有了端口就开 | §9.1 |
| 记住解锁密码 | 换实现（系统凭据管理器） | §10.3 |
| 打开文件、文件夹、网址 | 换实现（收成一个函数） | §10.1 |
| 日志页、访问记录 | 共用 | §13.3 |
| 设置：本机、数据、全局设置 | 共用；“权限”一行换成常驻方式和有没有显示器 | §10.6 |
| 任务栏图标固定后升级不失效 | 新增 | §10.3，G4 |

### 15.7 安装、升级、数据

| 功能 | Windows | 在哪 / 探针 |
|---|---|---|
| 安装包（`.pkg`） | 换实现：一个 `setup.exe`，两种安装方式 | §12.1，I1 |
| 命令行 `rapp`（`/usr/local/bin/rapp`） | 换实现：`bin\rapp.exe` 进 PATH | §5.1、§12.2 |
| 在线升级：自动、手动、回到上一版、有会话时等一等 | 照做；下载和切换换实现 | §12.3，S4 |
| `rapp update` | 照做（转给 `rapp-svc`） | §12.3 |
| 升级不结束文本终端 | 照做 | §12.3，T5 |
| 安装级别、重装提醒（`install-level`） | 不适用（没有“个人装还是全机装”之外的级别；安装方式由 `resident` 表达） | §12.3 |
| 上一版的备份不会被系统当成 app 启动 | 不适用（旧版本目录没有任何启动项指向它） | §12.3 |
| 卸载 | 新增（macOS 没有卸载程序）：按 §12.2 的表逐项还原 | §12.4 |
| 代码签名、公证 | 有步骤，证书到位前跳过（U4） | §12.5 |
| 数据根、指针文件、搬数据目录 | 照做；复制换成不靠外部命令的 | §13.1、§10.6 |
| 数据同步（git） | 照做；没有 `git.exe` 就只提示 | §8.1 |
| 私有文件的保护（0700 / 0600） | 换实现 | §13.2 |
| 日志、访问记录 | 照做 | §13.3 |
| 发版 | Windows 发版 session，自己取号，不标 Latest（U2） | §14.4 |

### 15.8 哪个平台都还没做的，Windows 也不承诺

这些在规格里有、主线上没有，写在这里是为了没人把它们当成 Windows 的欠账：状态规则的 R5、R7；程序状态的 S2–S4；平滑显示第 2 步（视频编码）；焦点面板第 2 步；iOS 的紧凑布局。主线做了哪一项，Windows 那天跟着做（被控端行为进 `host-core`，界面进共用 Dart）。

### 15.9 Windows 版比 macOS 版少的（给用户看的一张单子）

1. 没接显示器的机器没有画面（U3）。
2. “只为我安装”时：登录前连不上；锁屏、UAC 看不到；不能远程解锁；管理员身份的窗口操作不了。带系统服务时管理员窗口能操作，但焦点面板、密码框提示对它们不起作用。
3. 新装的机器要登录一次，在界面里配好 relay 和设备；不能只靠命令行配（§12.1）。
4. 别的用户坐在这台机器前登录着的时候，机主连上来没有桌面和 app（§7.2）。
5. 没有菜单栏镜像、拆出独立窗口、任务栏跳转列表、原生输入框。
6. 认不出真正程序的微软商店应用不能单独分享（整桌面会话里照样能用）。
7. 终端窗口可能不跟着控制端变大小（T3）；标题里的目录可能停在启动目录（T4）。
8. 控制端上被本机系统截走的键（Alt+Tab、Win 组合键、Ctrl+Alt+Del）要用键栏和菜单发。
9. 随包的状态规则和应用档案里还没有 Windows app 的内容（§15.3）。
10. 证书到位前安装包不签名，系统会多提示一次。

## 16. 探针：先在实机上试，再照着做

**这一节是整份设计里最不能跳的。** 前面每一处【未验证】都对应下面一行。探针是能扔的小程序，不进 main，放在 `probe/windows-<编号>` 分支上；每个探针交一页结果（做了什么、量到什么、过没过），写进 `docs/superpowers/specs/` 下一份 `…-windows-probe-results.md`。

- **一级**：整个结构压在上面。没过就不能照本文做，要回来改设计，改之前先告诉用户。
- **二级**：只影响一个功能。没过就走表里写好的退路，在对齐总表里把那一行改成“有限制”，不用回来问。

过关线里的数字是【我定的】起点，做探针的人量出实际值后可以连同理由一起改。

### 16.1 界面（G）

| 号 | 级 | 要回答什么 | 怎么试 | 过关线 | 没过怎么办 |
|---|---|---|---|---|---|
| G1 | 一 | 现在的 Flutter 工程在 Windows 上起不起得来 | `flutter build windows`；逐个看 `pubspec.yaml` 里的插件有没有 Windows 实现；托盘（`.ico`）、藏窗口再显示、命名互斥量单实例；在没有显卡的 Server 2022 云主机上起一次（Flutter 会退到软件渲染） | 主窗口起来；托盘菜单能点；关窗口藏到托盘；第二次启动唤起第一个；云主机上界面能用 | 缺 Windows 实现的插件逐个换掉或在外壳里补。云主机上起不来：服务器上只当被控端用，界面只留 `--cm` 和设置，回来告诉用户 |
| G2 | 一 | “进程解码 + Dart 画”够不够快 | `rapp-session.exe` 连一台 Mac 被控端，在 4K、缩放 150% 的屏上全屏滚网页和代码 | 30 帧不掉；界面线程超过 16 毫秒的帧不到 5%；不比配置相近的 Linux 控制端差 | 在外壳里做原生贴图（解码后的帧直接交给显卡纹理），Dart 只管摆位置。工作量加到 §17 的 C 阶段 |
| G3 | 二 | Flutter 输入框和 Windows 输入法配不配 | 微软拼音、搜狗、微信输入法各试：候选窗跟不跟光标；组字时回车是不是只上屏；在画面上直接打字时第一个键丢不丢 | 三种输入法下三条都对 | 哪条不对修哪条（外壳里补输入法位置）；修不了的写进已知限制，不做原生输入框 |
| G4 | 二 | 升级换了版本目录，固定在任务栏的图标还在不在 | 给进程和快捷方式设同一个应用标识，固定，换目录，再点 | 图标还在，点了启动的是新版 | 固定的图标指向 `bin\` 下一个固定路径的无窗口小启动器 |

### 16.2 被控端画面和输入（H）

| 号 | 级 | 要回答什么 | 怎么试 | 过关线 | 没过怎么办 |
|---|---|---|---|---|---|
| H1 | 一 | 逐个窗口采集再拼，行不行 | 用系统的逐窗口采集接口同时采一个 app 的 1、3、10 个窗口：有没有黄边框、带不带指针、被挡住的部分出不出、每个窗口的帧到得齐不齐；Server 2022 没有显卡时能不能用；窗口移动、改大小时会不会断 | 没有边框和指针；被完全挡住的窗口内容正确；10 个窗口时处理器占用不超过一个核的一半；没有显卡的机器上也能出画 | 改成“采整块屏，按窗口矩形裁”。代价是被别的 app 挡住的地方出不来（这时那块涂掉并报 `covered`）。**这是产品上的退步，要回来问用户** |
| H2 | 二 | 菜单、提示、下拉列表这些小窗口怎么出 | 试能不能单独采；试从整屏画面里按矩形裁，看它和主窗口差几帧、阴影怎么办 | 点开菜单后 100 毫秒内出现在画面里，位置不偏 | 全部从整屏裁；裁不干净的阴影不要 |
| H3 | 一 | 桌面复制采整块屏，性能和适用面 | 4K 屏 30 帧采集并缩到目标密度，量处理器和显卡占用；集显加独显的笔记本、HDR 屏、竖屏、Hyper-V 和云主机的虚拟显示 | 4K 30 帧时采集加缩放不超过一个核的 40%；上面几种机器都能出画，颜色不偏；**同一个登录会话里 8 个进程同时采整块屏，个个出画** | 个别机器不行：退到逐屏的窗口采集接口（帮手除外）；再不行用最老的整屏拷贝，帧率降到 15。普遍不行：回来改设计。8 个进程不能同时采：每个登录会话合成一个采集进程（§6.5 已写），不用回来问 |
| H4 | 二 | 桌面切换时采集断不断得回来；用户身份的进程知不知道“现在是安全桌面” | 普通桌面 ↔ UAC、锁屏、Ctrl+Alt+Del 那一屏；改分辨率；插拔显示器；全屏游戏。另用普通用户身份的进程试：安全桌面出现和消失时收不收得到明确的信号，分不分得出“锁了”和“没锁但切走了” | 切换后 1 秒内恢复出画，会话不断；用户身份下 1 秒内知道切走了、切回来了，并且分得出锁没锁 | 恢复不了的那种情况单独报原因，会话以 "capture stopped: …" 结束（和 macOS 一样）。分不出是不是安全桌面：用户方式下只报锁屏状态，UAC 时画面停住、不另外说明，写进已知限制 |
| H5 | 一 | 输入发得准不准 | 往记事本、Chrome、VS Code、Windows Terminal、Office、一个 Java 程序里直接送 Unicode 文字（含 emoji、换行、Tab）；扫描码按键在非美式布局下位置对不对；把后台窗口拿到前台的几种办法；对管理员窗口发输入时能不能知道被拦了。**对管理员窗口逐项试**（普通用户身份）：采画面、抬到前面、移动、改大小、请它关闭、读它的控件，各自行不行、不行时有没有明确的失败 | 1000 字中英混排连发 20 次，不丢不乱；抢前台 50 次成功 50 次；被拦时能得到明确的失败；管理员窗口的六项各有一个明确的结论，写进结果 | 文字在个别 app 里不行：那个 app 走“写剪贴板再粘贴”（已有的粘贴流程）。抢不到前台：报原因，不硬发。管理员窗口上判断不出被拦：发输入前先看目标窗口是不是管理员身份，是就不发、直接报 |
| H6 | 二 | 怎么让被控端停在英文 | 有英文键盘布局时切布局；只有中文输入法时切它的英文状态；微软拼音、搜狗、微信输入法各试 | 会话开始后，原样按键出来的是英文字母 | 做不到的输入法：记日志，在控制端提示“被控端的输入法没切到英文”。文字输入不受影响（它不经过输入法） |
| H7 | 二 | 系统自带的文字识别能不能用 | 列出可用语言；没装中文包时的表现；Server 2022 上有没有；一块 800×200 的图要多久 | 简体中文和英文都能识别；一次不超过 200 毫秒 | 不报 `text` 这项能力（规格允许），用到文字的状态规则在 Windows 上不生效 |

### 16.3 系统服务（S）

| 号 | 级 | 要回答什么 | 怎么试 | 过关线 | 没过怎么办 |
|---|---|---|---|---|---|
| S1 | 一 | 安全桌面帮手行不行 | 系统服务在机主的登录会话里以 SYSTEM 身份启动一个小程序：跟着系统切到当前显示的桌面，采画面、发输入。试锁屏上打密码、点 UAC 提示、打开策略后发 Ctrl+Alt+Del；对管理员窗口做抬前、移动、改大小、请它关闭；量帧经管道和经共享内存的延迟。**Windows 11 和 Server 2022 各一台**：Server 默认要先按 Ctrl+Alt+Del 才出密码框，试“先发它、等输入框出来、再打密码” | 两种系统上，锁屏上远程打密码解锁各 20 次成功 20 次；UAC 框看得见、点得动；Ctrl+Alt+Del 那一屏出得来；管理员窗口的四个操作都成；帮手这条路每帧多出来的延迟不超过 5 毫秒 | 某一项做不到（比如锁屏上采不到画面）：系统服务方式的好处就少了一块，**回来问用户**还值不值得装服务 |
| S2 | 一 | 登录前能不能连上去登录 | 冷启动、不碰本机：服务（在系统自己的那个会话里）起登录前实例，在控制台会话里起 `rapp-host`，标准输入输出接得过去；登录界面采得到；输密码登录；登录后切到机主会话。再试开了自动登录的机器；Server 上先发 Ctrl+Alt+Del 再登录；**别的用户在本机登录**（机主没登录、机主被切到后台两种） | 从控制端看到登录界面并登录成功；登录后 10 秒内自动重连到机主的会话，不用人管；别的用户在本机时，控制端看到的是 `other user`，没有任何一帧是那个用户的桌面，那个用户没有被踢回锁屏 | 登录界面采不到：登录前只报“未登录”，不给桌面，**回来问用户**。重连慢：只是体验，调重连参数 |
| S3 | 二 | 和远程桌面一起用 | 远程桌面连着时 rApp 采的是什么；断开后把会话接回控制台再锁屏；没有物理显示输出的云主机上接回控制台后有没有画面；机主在远程桌面会话里时发 Ctrl+Alt+Del，落到哪个会话 | 连着时采到远程桌面里的桌面；断开后接回并锁屏，再从 rApp 解锁成功；Ctrl+Alt+Del 落在哪弄清楚并写进结果 | 接不回来：报 `session disconnected`，说明里写“别用远程桌面的断开，注销或者直接用 rApp”。Ctrl+Alt+Del 落不到机主的会话：机主在远程桌面会话里时那个菜单项置灰并说明（§7.5） |
| S4 | 一 | 升级的切换和退回 | 两个假版本 A、B：系统服务方式和用户方式各来回切 20 次；放一个起不来的版本看会不会自己退回；切换时开着文本终端；切到一半断电 | 40 次切换不用人管；坏版本 30 秒后自己退回并且不再自动装它；终端全程不断；断电重启后停在 A 或 B 之一，能连 | 改启动项这条路不稳：换成“系统里登记的是一个固定路径的极小启动器，它读 `current` 再起对应版本”。这是另一种结构，在探针里两种都比一下再定 |

### 16.4 文本终端（T）

| 号 | 级 | 要回答什么 | 怎么试 | 过关线 | 没过怎么办 |
|---|---|---|---|---|---|
| T1 | 一 | 随包的 ConPTY 能不能用 | `portable-pty` 加载放在旁边的 `conpty.dll`；把仓库里那批 OSC 7501 测试录制文件、改标题、报目录的序列喂进去，看出来的是不是原样；定下钉哪个版本 | 上面几种序列原样出来，扫描器的结果和 unix 上一样；Server 2022 和 Windows 11 上都行 | 不经 `portable-pty`，自己调随包那份的接口。再不行：用系统自带的，程序状态在 Windows 被控端上不可用并报原因，**回来告诉用户** |
| T2 | 二 | 外面的控制台能不能直通 | 在 Windows Terminal 的标签页和老式控制台窗口里各跑：按键、粘贴、鼠标、改窗口大小都按转义序列进来；Ctrl+C 当成一个字节传进去；窗口被关时来不来得及收尾；`run` 以 0 退出后标签页自己关不关 | Claude Code、vim、`cmd` 的行编辑在两种窗口里都正常；主动结束的终端标签页自己关 | 老式控制台窗口里不行的功能写进已知限制（建议装 Windows Terminal）。标签页不自己关：留着，显示“已结束” |
| T3 | 二 | 终端窗口能不能跟着控制端变大小 | 给 Windows Terminal 和老式控制台发 `ESC[8;行;列t`；老式控制台另试直接改窗口 | 至少一种终端跟着变 | 都不行：`term-fit` 规格里已有的退路（控制端缩放显示） |
| T4 | 二 | 前台程序和当前目录读不读得到 | 从 shell 往下找最新的子孙进程；各种 shell 报目录的转义序列；试读别的进程的当前目录 | 程序名在 `cmd`、PowerShell、Git Bash 下都对；目录至少在会报的 shell 下对 | 目录用启动目录（§9.2 已写） |
| T5 | 一 | 终端开得出来、留得住 | 从后台服务里让 Windows Terminal 在已有窗口开标签页（它是商店应用，入口是个别名）；没有窗口时、没装时；窗口进程脱离作业对象；重启 `rapp-service`、重启 `rapp-svc`、升级之后终端还在、`serve` 还找得到。同样的三种重启，再看 `rapp-host` 替控制端打开的 app（记事本、Chrome 各一个）和主界面还在不在 | 三种情况下都开得出来；三种重启之后终端都还在、还能接着用；打开的 app 和主界面也都还在 | Windows Terminal 从服务里起不来：一律开普通控制台窗口。脱离不了作业对象：终端不放进作业（由 `run` 自己看 `serve` 在不在） |

### 16.5 其余（N、V、C、I）

| 号 | 级 | 要回答什么 | 怎么试 | 过关线 | 没过怎么办 |
|---|---|---|---|---|---|
| N1 | 二 | 系统保留的端口段碰不碰到我们 | 在装了 Hyper-V、WSL2、Docker Desktop 的机器上看保留段盖没盖到 22028、22029、28000–28999；绑一个被保留的口，错误和“被占”分不分得开 | 默认配置下不碰到；碰到时能报出“被系统保留” | 报清楚的错误并在说明里写怎么查。**不去改系统的端口保留**（rapp 之外什么都不设） |
| N2 | 二 | 用户方式下防火墙怎么表现 | 没有管理员权限时第一次收 UDP 22028 弹不弹框；不点允许时直连和中继各怎样；换版本目录后再不再弹 | 行为弄清楚并写进说明；不点允许时经中继照样能用 | 用户方式的说明里写明“局域网直连要点允许；不点只走中继”。每次升级都弹的话，用户方式的界面里给一句提示 |
| V1 | 二 | 语音识别在 Windows 上能不能编、够不够快 | 用 Windows 的工具链编钉死版本的 whisper；同一段 10 秒的话和 Linux 上比时间 | 编得过；10 秒的话 5 秒内出结果 | 太慢：打开处理器的新指令集（要定最低处理器）。编不过：第一版 Windows 控制端不带语音，按钮隐藏 |
| C1 | 一 | Rust 的压缩和 Swift 的压缩出来的字节一不一样 | 同一批输入，Swift 版（系统 zlib，6 级，同步刷新）和 `flate2` 的几种后端各压一遍，逐字节比。**这个探针在 Mac 上就能做，不用 Windows 机器** | 有一种后端完全一样 | 没有：压缩这一层的核对标准改成“Swift 的解码器解出来像素完全一样”（§14.2 已写），其余各层照旧逐字节 |
| I1 | 二 | 安装程序的几处细节 | 标准用户用另一个管理员账号的密码提权安装时，“发起安装的用户”是谁；静默安装（以 SYSTEM 身份、带 `/OWNER`；不带 `/OWNER`）；PATH 改完不重启生不生效；未签名时系统的提示长什么样；卸载后 §12.2 的每一项还原了没有 | 机主是那个标准用户；带 `/OWNER` 的静默安装机主是指定的账户，不带的失败并说清原因；卸载后逐项核对无残留 | 认领机主改成“装完后第一次以普通身份打开界面时认领”（先到先得，已有机主时要管理员） |

### 16.6 做探针的顺序

1. **C1** 和 **G1** 先做，最便宜：一个在 Mac 上，一个只要装好 Flutter。
2. 然后三条线可以同时：**H1、H3、H5**（被控端画面和输入）；**S1、S2、S4**（系统服务）；**T1、T5**（终端）。
3. **G2** 要等 `rapp-session` 在 Windows 上编过（§17 的 A 阶段）。
4. 二级探针跟着各自的阶段做，不用提前。

需要的机器见 §17.3。

## 17. 分期

本文只定先后和每一段怎么算做完，不排人和日期。每一段各写一份实现计划（`docs/superpowers/plans/`）。

### 17.1 规矩

- **每一段做完都能合并进 main**：Mac 的门禁是绿的，macOS、Linux、iOS 的行为没变。半成品用“Windows 上还没接上”的方式留在 main 里，不用长期分支。
- **第一行 Windows 代码合并之前，先把 §14.5 的前四条加进 `CLAUDE.md`**，否则 Mac 发版 session 会为只动 Windows 的合并白发版，Windows 机器也拿不到这些提交。
- **公开的第一个 Windows 版要等 A 到 H 全部做完**【用户定的，U7】。理由：升级机制必须从第一个公开版本起就是对的（不然装出去的机器升不上来）；主要用途之一是远程服务器，没有系统服务那一半就不成立。中间的成果打成 zip 给自己人装，不建 release、不进官网。
- **过渡期 Rust 里有两份被控端代码**【用户定的，U9】：`host-core`（新，完整）和 `host-linux`（旧，精简）。`host-core` 起步时可以把 `host-linux` 里已经有的通用部分（握手、接管、省流、暂停、取景）拷过来再对着 Swift 的样本校；**这次不改 `host-linux`**（它由另一台机器的 session 维护，“新平台不改已有平台”）。把 `host-linux` 换到 `host-core` 上是 Windows 首发以后单独的一件事，那时 §2.3 的第二条反目标才算真正守住。在那之前，协议加被控端行为要改三处：Swift、`host-core`、`host-linux`。

### 17.2 各段

| 段 | 做什么 | 在哪做 | 要先有 | 怎么算做完 |
|---|---|---|---|---|
| **P 探针** | §16，按 §16.6 的顺序 | Windows 机器（C1 在 Mac） | —— | 每个一级探针有结果；没过的已经回来改了设计 |
| **A 地基** | `CLAUDE.md` 前四条，Windows 集成 session 开张（§14.4）；三个新 crate 的空壳进 workspace；§8 里“为了编过”的缝（`rapp-net` 双栈和日志兜底、“设成私有”函数、`rapp-service` 的单实例、停止、`--supervised`、缓存目录、worker 启动方式、`rapp-cli`、`rapp-term` 把 unix 专用的部分包起来并在 Windows 上先报“不支持”）；Windows 门禁的脚本 | 两边 | P 里的 G1 | Windows 上 §14.3 的 1–3 步是绿的；`flutter build windows` 过；Mac 门禁是绿的 |
| **B 主机核心** | `host-core` 全部：Swift 样本生成器和样本；编码发送一组（量化、瓦片、压缩、滚动复制、分片、省流、暂停、取景）；会话一组（握手、接管、命令行、事件、会话循环）；规则一组（窗口后处理、焦点面板、点穿、剪贴板、传输、锁屏和解锁步骤）；状态规则引擎；“不处理的消息”那张表和它的测试（§14.1）；`Sources/rapp-host/` 的对照表和核对摘要的那条测试（§14.2） | **Mac**，不需要 Windows 机器 | P 里的 C1 | §14.2 的样本测试在 Mac 门禁里全绿；对照表里每一行都有测试；假平台整会话测试把 §14.2 列的几条流程都走过；一台真的 Mac 控制端连上“假平台”的 `host-core`，测试图案画得对、能滚、能传一个文件；**`Sources/` 没有改动** |
| **C 控制端** | 外壳（§10.3）；`rapp-hub`、`rapp-session` 编过并接上；会话端口的小接口（§10.2）；能力位（§10.1）；§10.6 的小处；文本终端的界面打开；端口面板、`localhost` 共享号；`rapp-svc user` 的最小版（只监督） | Windows | A；G2 的结果 | 一台 Windows 笔记本能添加一台 Mac，打开应用和桌面、打字（含中文）、传文件、开文本终端、用共享端口；§15.6 除语音外逐行过 |
| **D 被控端（用户方式）** | `host-windows`：目标、窗口、采集、输入、输入法、剪贴板、控件、文字识别、锁屏状态、保持唤醒；`rapp-service` 认 Windows 的 worker；§6.1 的四种原因和 §10.6 里控制端的说法 | Windows | A、B；H1、H3、H5 的结果 | 从 Mac 控制一台**已登录、没锁屏**的 Windows：§15.3 里不标“只有系统服务方式有”的每一行都过；Mac 控制端一行代码不用为它改（除了 §10.6 说的那几句话） |
| **E 文本终端（被控端）** | `rapp-term` 的 Windows 一支（§9）：ConPTY、本机通道、开窗口、前台程序、结束 | Windows | A；T1、T5 的结果 | §15.4 逐行过；重启服务后终端还在 |
| **F 系统服务** | `rapp-svc service`、机主、管道和它的权限、安全桌面帮手、所有输入经帮手、远程解锁、自动锁屏、Ctrl+Alt+Del、登录前实例、远程桌面接回 | Windows | D；S1、S2 的结果 | §7.1 表里左边一列逐行过；§18.2 的审计过了 |
| **G 安装和升级** | `rapp-svc install` / `uninstall`；Inno Setup 脚本；`rapp-update` 的 Windows 一支；`fetch-update` / `apply-update` / `take-over` / 退回；登录前的自动升级；构建和打包脚本、包的自检、签名这一步（没证书就跳过） | Windows | C、F；S4、I1 的结果 | 干净的机器上两种方式各装一遍、升一遍、退一遍、卸一遍；卸载后按 §12.2 逐项核对；坏版本自己退回 |
| **H 收尾和首发** | 语音（§10.5）；输入法打磨（G3）；任务栏（G4）；审一遍写死“Mac”的句子；§15 全表验收；§14.6 的几样；`CLAUDE.md` 后两条；Windows 集成 session 转成发版 session | Windows | 以上全部 | 第一个 Windows release 建好、不是 Latest；官网和 README 更新；一台已装的机器经在线升级升到下一个版本 |

可以同时走的三条线：**B**（Mac 上，一开始就能动）；**A → C**（Windows 控制端）；**A → D → F**（Windows 被控端）。**E** 在 A 之后随时可以插进来，和 D 互不相干。**G** 最晚，但它的探针（S4、I1）要早做，因为“一版一个目录”这个结构是 A 就要定死的。

每一段做完时，把这一段新出现的“要在实机上看的事”写进 `tasks/todo.md`（照现在别的功能的做法），不留在聊天记录里。

### 17.3 要准备的机器

| 机器 | 验什么 |
|---|---|
| Windows 11 台式机，有独立显卡，两块缩放比不同的屏 | 日常开发；多屏、每屏缩放、性能线 |
| Windows 11 笔记本，集成显卡，触控板 | 控制端；合盖和电池；触控板捏合；集显加独显的采集 |
| Windows Server 2022 云主机，没有显卡，平时没人登录 | 登录前；远程桌面共存；软件渲染；没装 Windows Terminal 的终端 |
| 一台没接显示器的物理机或虚拟机 | `no display` 这条路 |
| 一个没有管理员权限的账号（可以在上面任何一台里） | 用户方式；防火墙提示（N2） |
| 中文系统加三种中文输入法 | 两端的输入法（G3、H6） |

Windows Server 2025 和 Windows 11 的后续版本也在基准线以上，首发前各装一次，跑 §15 的被控端部分。

## 18. 审计清单

合并每一段之前照着查，首发前全部重查一遍。每条都写了“怎么查”，查不了的条目不算数。

### 18.1 模块边界

| # | 要成立的事 | 怎么查 |
|---|---|---|
| 1 | `host-core` 不认识操作系统 | 在 `rust/host-core/` 里搜 `cfg(windows)`、`cfg(unix)`、`target_os`、`libc`、`windows`，一处都没有；它的 `Cargo.toml` 里没有按平台分的依赖 |
| 2 | `host-windows` 不产生也不解析协议字节 | 它不依赖 `rapp-client-core` 的协议模块；搜不到消息类型的数字和编码函数的调用 |
| 3 | 只有 `rapp-svc` 跨登录会话、跨权限启动进程 | 在 `rust/` 里搜“以别的用户身份创建进程”“取登录会话的令牌”这一类系统调用，只出现在 `rust/svc-windows/` |
| 4 | 界面里不按系统名分支 | `gui/lib/` 里 `Platform.isWindows` 的出现次数不比现在多（现在 4 处：`data_dir.dart:205`、`data_relocate.dart:11`、`service_control.dart:118`、`term/term_stage.dart:55`），最好更少；新的差别都在 `PlatformCaps` 里 |
| 5 | 外壳不做解码、不做画面 | `gui/windows/runner/` 里没有像素处理的代码；通道只有 §10.3 列的那几个 |
| 6 | 所有对系统的改动只在 `rapp-svc install` 一个地方 | Inno Setup 脚本里没有写注册表、加服务、加防火墙规则、改 PATH 的段；这些只在 `rust/svc-windows/` 的一个模块里，卸载是同一个模块里的反函数 |

### 18.2 系统权限（F 段做完时单独审，最好换一个没写这段代码的人）

| # | 要成立的事 | 怎么查 |
|---|---|---|
| 1 | 以 SYSTEM 身份跑的代码只有三处：`rapp-svc`、`rapp-host secure-helper`、登录前的 `rapp-service --prelogin` 和它的 `rapp-host` | 列出 `rapp-svc` 里每一处启动进程的调用，逐个看身份和程序路径 |
| 2 | `rapp-svc` 启动的程序只来自它自己的版本目录，用完整路径 | 同上；没有一处用到请求里、环境变量里、数据根里给的路径；不查 PATH |
| 3 | 身份和登录会话从管道对端取，不从消息里取 | 读管道请求的处理函数：消息的字段里没有用户、SID、会话号 |
| 4 | 管道只许该连的人连 | 系统服务方式：SYSTEM 和机主；用户方式：这个用户。写成自动测试：换一个用户连，被拒 |
| 5 | `spawn-host` 只接受 SYSTEM 身份的请求方 | 自动测试：机主身份请求，被拒 |
| 6 | 安装目录只有管理员和 SYSTEM 能写（系统服务方式） | `rapp-svc install` 装完核对一次，不对就算安装失败；`rapp-svc` 每次启动把它对齐一次并记日志（§5.1）。实机上手动放宽权限再重启服务，看它改回来 |
| 7 | 登录前实例不写机主的数据根，不执行、不加载数据根指到的任何东西 | 读 `--prelogin` 这条路径上所有的文件操作；自动测试：数据根里放一个改过的配置指向别的程序，登录前实例不理它 |
| 8 | 系统服务方式下，升级的地址不能被机主身份的程序改掉 | 改数据根里的 `update_url`，系统服务方式下不生效；升级包的地址必须以 §12.3 的那个前缀开头 |
| 9 | 帮手只做三件事：采当前桌面、发输入、对指定窗口做四个固定操作（抬前、移动、改大小、请它关闭） | 读 `secure-helper` 的入口：没有文件操作、没有网络、不启动进程、不结束进程（“请它关闭”是给窗口发关闭请求，不是杀进程）；管道上的命令只有 §7.4 列的那几种，多一种都算没过；普通用户身份启动它直接退出 2 |
| 10 | `rapp-svc` 的代码量是小的 | 首发时记下 `rust/svc-windows/` 的行数；以后每次明显变长，在合并说明里解释为什么这件事非得在系统权限下做 |
| 11 | §7.7 的五条代价写进了安装界面和 README | 看安装程序“带系统服务”那一页和 README 的 Windows 一节 |

### 18.3 协议和现有平台

| # | 要成立的事 | 怎么查 |
|---|---|---|
| 1 | Windows 被控端发出的字节和 Swift 的一样 | §14.2 的样本测试在 Mac 门禁里是绿的 |
| 2 | 每种消息类型要么 `host-core` 处理，要么在“不处理”的表里 | §14.1 的那条测试 |
| 3 | 没有为 Windows 加协议消息、没有升协议号 | 协议号还是合并前的那个；Swift 的 `knownTypes` 没有因为 Windows 多出类型 |
| 4 | 控制面只加了可选字段（`list_apps` 回答和本机 `status` 里的 `resident`、`prelogin`），而且只在 Windows 上出现 | `rust/testkit/tests/service.rs:381` 那条整个对象相等的断言没有改也是绿的（Mac、Linux 的回答一个键都没多）；hub 的 `apps_event`（`rust/hub/src/lib.rs:466-481`）在同一个提交里加了转发；老版本的控制端连新的 Windows 被控端不出错（用 0.15.41 的 Mac 控制端试一次） |
| 5 | macOS、Linux、iOS 的行为没变 | Mac 门禁的命令一个字没改，并且是绿的；`Sources/` 没有改动，样本生成器在 `Tests/RappCoreTests/` 下（先例是 `CrossFixtureTests.swift`）；unix 那一支的代码差异为零（每条缝都是加一支） |
| 5a | 出不了样本的那部分（`Sources/rapp-host/`）有对照表兜着 | 对照表里每一行都指到一条存在的测试；核对 Swift 文件摘要的那条测试在 Mac 门禁里；随手改一下 `Server.swift`，门禁变红 |
| 6 | Mac 的门禁没有明显变慢 | 记下合并前后 `cargo test --workspace` 的时间 |
| 7 | 字段名和约定字符串照 Swift 版 | §6.1 列的事件和字符串有样本或测试钉住；没有学 Linux 版的偏差 |

### 18.4 不冒称、不泄露

| # | 要成立的事 | 怎么查 |
|---|---|---|
| 1 | 做不到的事都报了原因 | 实机上逐个造出来：没显示器、远程桌面断开、没人登录、别的用户占着本机屏幕、对管理员窗口输入（用户方式）、单应用会话里弹出 UAC、用户方式下请求解锁、没装语言包、麦克风被关、端口被系统保留。每一种控制端上都有一句看得懂的话 |
| 2 | 用户方式下不出现用不了的开关 | 自动锁屏、远程解锁在 `resident` 不是 `system` 时隐藏 |
| 3 | 日志里没有密码、令牌、密钥、打的字、剪贴板内容 | 实机上做一遍解锁、粘贴、打字、配对，然后在全部日志目录（含 `%ProgramData%\rapp\logs\`）里搜这些内容；读 `rapp-svc` 和帮手里每一条日志语句 |
| 4 | 密码不经过命令行、环境变量、临时文件 | 读解锁这条路：控制端 → 协议 → `rapp-host` → 管道 → 帮手，中间不落盘 |
| 5 | 私有文件真的是私有的 | 数据根放在 `D:\rapp` 这样的地方，换一个普通用户登录，读不到密钥和 token（§13.2 的验收） |
| 6 | 没有统计、没有崩溃上报、没有本文没列的联网 | 首次安装后抓一段时间的网络连接：只有 relay、对端设备、升级清单和升级包、（用到语音时）模型下载 |

### 18.5 安装、升级、发版

| # | 要成立的事 | 怎么查 |
|---|---|---|
| 1 | 安装程序改了什么，和 §12.2 的表一样，不多不少 | 装之前、装之后各导出一次服务列表、启动项、防火墙规则、PATH、相关注册表，比差异 |
| 2 | 卸载把它们都还原了，数据留着 | 卸载后再导出一次，和装之前一样；数据根还在 |
| 3 | 升级不结束文本终端、不要求重启 | 开着终端升级；升完终端还能用，新开的终端用新版 |
| 4 | 坏版本会自己退回 | S4 的那个测试留在 Windows 的门禁里 |
| 5 | Windows 的 release 没有抢走 Latest | 发完后看 GitHub 的 Latest 还是 macOS 的那个；`releases/latest/download/latest.json` 还是 macOS 的清单 |
| 5a | 只动 Windows 的合并到得了 Windows 机器，又没有白发 macOS 版 | 首发前挑一次只动 `rust/host-windows/` 的合并：Mac 发版 session 推了、没有新 tag；Windows 机器 fetch 得到 |
| 6 | 版本号没有和别的机器撞 | 发版 session 是先推 `release:` 提交和 tag、再打包的 |
| 7 | 包里的东西对得上 | 包的自检：每个程序的版本号一致，`rapp-host version --json` 报的协议号和 main 上的一致，ConPTY 的摘要对得上钉的那个 |
| 8 | 依赖都钉了版本，许可证都相容 | `Cargo.lock`、`pubspec.lock` 进了仓库；新加的每个依赖在合并说明里写了许可证；ConPTY 的许可证文件在包里 |

### 18.6 文档

| # | 要成立的事 | 怎么查 |
|---|---|---|
| 1 | 每加一个配置项、环境变量、注册表值、文件，`config-reference` 在同一个提交里改了 | 看提交 |
| 2 | §19.2 列的旧话都改了或标了作废 | 逐条看 |
| 3 | 探针结果写下来了，本文里对应的【未验证】换成了结果 | 首发时本文里不该再有【未验证】，只剩“已验证”和“已知限制” |

## 19. 收尾

### 19.1 留给实现的人定的

下面这些本文故意不定，定了也只是猜。做的人按探针结果和代码实际定，定完写进各段的实现计划：

- `host-core` 平台接口的函数签名（分组和方向定了，§6.2）；`host-core` 内部怎么分模块。
- 显示器 id 的哈希算法；mac 键码到扫描码那张表的具体内容；窗口种类的对照细则（实机上按常见 app 校）。
- 采集的缩放在显卡上做还是在内存里做；帮手的帧走管道还是共享内存；把窗口拿到前台用哪种办法；滚轮的换算系数。
- 能力位叫什么名字；`LinuxSessionPort` 要不要改名；外壳里的剪贴板、选文件、拖文件用现成插件还是自己写。
- 管道请求的 JSON 具体长什么样；`rapp-svc` 各子命令的参数写法；注册表值的名字。
- Windows 门禁脚本、构建脚本、打包脚本叫什么、用什么写。
- 钉哪一版 ConPTY、哪一版 Inno Setup。
- 探针过关线里的数字（量出实际值后连同理由一起改）。

**不留给实现的人定的**（改这些要回来问）：§0.2 的十一件事；§5.3 的三条边界；§6.1 的命令行约定和四种原因的文字；§6.3 的对照表；§7.3 的“请求里的东西不当真”；一版一个目录；协议不为 Windows 加消息；§14.4 的发版规则。

### 19.2 要顺手改的旧文档

这些地方的说法和本文或和现状对不上。本文获批后，由做 A 段的人改（只改文档，不触发发版）：

| 文档 | 位置 | 问题 |
|---|---|---|
| `README.zh-CN.md`、`README.md` | `:28` | 写着“应用协议 v14”，现在是 v16 |
| 同上 | 安装表、致谢 | 首发时加 Windows 一行和 ConPTY（§14.6） |
| `2026-11-10-rapp-host-client-spec.md` | 标题、`:817-826`、`:847`、`:863` | 标题还是 v3；Windows 一节是旧设想（§0.3） |
| `2026-11-10-rapp-native-rust-design.md` | §6、`:251`、`:440-441` | Windows 被控端草图和非目标已被本文取代，加一行指向本文 |
| `2026-11-11-rapp-platform-design.md` | `:193` | “Windows：HKCU Run + taskkill” |
| `2026-11-12-rapp-requirements-feedback.md` | `:854` | “Windows 版指什么”已定 |
| `2026-11-12-rapp-s2-embedded-stage-design.md` | `:35`、`:165` | “Windows 不嵌入” |
| `2026-11-16-rapp-text-terminal-design.md` | `:19`、`:259-267` | “先只做被控端”“Flutter 不做”“换成命名管道” |
| `2026-11-15-rapp-port-sharing-design.md` | `:402`、`:411`、`:634` | 和 Windows 有关的几句；“不留常驻高权限进程”加一句“Windows 例外，见本文 §7.7” |
| 端口面板规格和它的交接文档 | `:216`、`:179` | `openUrl` 在 Windows 上的说法（现在有了，§10.1） |
| 焦点面板、`term-fit`、`term-entry`、桌面会话几份规格 | `focus-pane-rules:43`、`term-fit:31`、`term-entry:39,73`、`desktop-sessions:40` | “被控端只有 macOS”一类的句子 |
| `ipad-duo` 规格 | 能力表 | 没有 Windows 一列 |
| `config-reference` | `:24-25`（已有的 Windows 路径）、`:235`，加 §13.4 的内容 | Windows 的路径和新增项 |
| `tasks/todo.md` | `:30`、`:58`、`:60-61`、`:64`、`:72`、`:812`、`:819` | 提到 Windows 的旧待办，改成指向本文或删掉 |

### 19.3 我替用户定的事（请重点看前六条）

全文标【我定的】的地方都在这里。前六条影响面最大，改了要动结构；后面的改起来便宜。原来在这张单子上的三条（系统基准、全部做完再公开和 `host-linux` 不动、登录前也升级）已经由用户定了，挪到 §0.2 的 U6–U9。

**影响大的**

1. **单应用会话改成“逐个窗口采集再拼”**；探针 H1 没过的退路是产品上的退步，到时回来问（§6.5）。
2. **机主只有一个**：别的用户登录这台机器时 rApp 不为他们工作；别的用户坐在本机前登录着时，机主连上来没有桌面，rApp 不把他的桌面给机主看，也不把他踢回锁屏。登录前用的是机主的设备身份，所以设备密钥只靠文件权限保护，不用“登录后才能解开”的加密（§7.2、§7.6）。
3. **装了系统服务：所有输入都经系统权限的帮手发**，所以管理员窗口和 UAC 提示也能远程操作；帮手还替管理员窗口做四个窗口操作（抬前、移动、改大小、请它关闭）。这把系统的一道栏放低了，代价写在 §7.7。管理员窗口里的控件仍然读不到（§6.6、§7.4）。
4. **一版一个目录、升级靠改启动项切换、新版起不来 30 秒后自己退回**（§5.1、§12.3）。
5. **Windows 的 release 不标 Latest，升级清单放在固定的 `update-windows` release 上；发版时先推版本号再打包**（§12.3、§14.4）。
6. **新装的机器要登录一次、在界面里做第一次配置**，不为 Windows 加配 relay、配对的命令行；静默安装系统服务方式必须用 `/OWNER` 指明机主，不猜（§7.2、§12.1）。

**影响小的**

7. 只出 x64 的包（§3.1）。
8. 界面程序叫 `rapp-gui.exe`，命令行叫 `rapp.exe`，装在固定目录、不让选（§5.1、§12.1）。
9. app 的 id 是小写的 exe 文件名；⌘ 和 ⌃ 都对到 Ctrl，没有 Win 键；Ctrl+Alt+Del 用一个键组合表示，不加协议消息（§6.3、§7.5）。
10. app 没开就启动它（旧规格写的是报错）（§6.4）。
11. 整桌面用桌面复制接口采；不采鼠标指针（§6.5）。
12. 同时采整块屏的进程数要是有上限，每个登录会话合成一个采集进程，和帮手共用外壳（§6.5，H3）。
13. 权限固定报“辅助功能有”，出不了画面时报四种原因之一：`no display`、`session disconnected`、`not interactive`、`other user`（§6.1）。
14. `applications` 这项能力只给 Windows 加一支带到控制端；Linux 那一支现在把它丢了，本文不改，记进待办交给 Linux 的 session（§6.1）。
15. `resident`、`prelogin` 放在 `list_apps` 的回答和本机 `status` 里，只在 Windows 上出现（§8.1）。
16. 新出现的三种情况都借现有消息说，不加消息：管理员窗口用 `inputBlocked` 加约定值 `elevated`；单应用会话和用户方式遇到 UAC 用 `covered` 加 `consent.exe`；用户方式下的解锁请求丢掉并再报已锁，控制端凭 `resident` 不弹解锁框。已发出去的控制端看到的话别扭但不出错（§6.6、§6.9、§7.4、§10.6）。
17. 自动锁屏、远程解锁只在系统服务方式下有（§6.9）。
18. Server 上解锁和登录前先发一次 Ctrl+Alt+Del；机主在远程桌面会话里而它落不到那个会话时，菜单项置灰（§6.9、§7.5）。
19. 远程桌面断开后，rApp 把会话接回本机并立刻锁屏；本机屏幕上有别的用户时不接回（§6.9、§7.2）。
20. `rapp-service` 靠“标准输入关了就停”和作业对象来收尾；作业里只有 rApp 自己的后台进程，终端、替控制端打开的 app、界面程序都不在里面（§8.1）。
21. `run` 和 `serve` 之间用回环 TCP 加 token，不用命名管道（§9.3）。
22. 语音用和 Linux 同一套本地识别，不用 Windows 自带的（§10.5）。
23. 嵌入画面不另写一个 Windows 的会话端口类，从 Linux 那个里抽小接口（§10.2）。
24. 安装程序用 Inno Setup，所有系统改动收在 `rapp-svc install` 里（§12.1）。
25. 卸载时有终端在跑就先问（§12.4）。
26. Windows 上私有文件的保护办法（§13.2）。
27. Windows 专用的 crate 在别的系统上编成空壳；`speech-linux` 不改名（§5.3）。
28. 第一版不带任何 Windows app 的状态规则和应用档案（§15.3）。
29. 微软商店应用认不出真正程序的不列（§6.4）。
30. “依赖钉版本、没有统计和崩溃上报”当成一直有效的原则来守（§3.2）。
31. 出不了样本的会话逻辑用对照表兜着，表里记 Swift 文件的摘要，Mac 门禁核对：以后在 Mac 上改 `Sources/rapp-host/` 的人每次多一步（§14.2）。
32. 只改文档的合并，Mac 发版 session 也立刻推，不再攒到下一次代码改动（§14.4）。
33. 探针过关线里的数字（§16）。

### 19.4 本文之后

用户审过本文 → 按 §17 的各段分别写实现计划 → P 段的探针先做。探针结果改了设计的，回来改本文并告诉用户。
