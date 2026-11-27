# rApp Windows 探针结果

规格：`2026-11-26-rapp-windows-design.md` §16。每个探针一节，做完一个填一个。

## 机器

| 代号 | 机器 | 系统和内部版本 | 处理器 / 显卡 | 屏幕和缩放 | 备注 |
|---|---|---|---|---|---|
| mac | Mac（Apple M5） | macOS 27.0.1（26A434），arm64 | Apple M5 | —— | C1 只在这台上做 |
| W11-L | Windows 11 集显主机 | Windows 11 Home China 24H2（26100.9711），x64 | 12th Gen Intel Core i5-1240P / Intel Iris Xe Graphics | 1920×1080 @ 100%（单屏） | checkout 路径 `D:\git\rapp`；当前唯一可用 Windows 实机 |
| W11-D | Windows 11 独显双屏台式机 | 没有 | —— | —— | 暂无此机器 |
| S22-C | Windows Server 2022 无显卡云主机 | 没有 | —— | —— | 暂无此机器；用户已明确无显卡 Server 2022 只提供 `service`、不提供图形 `host` |
| NODISP | 未接显示器的机器或虚拟机 | 没有 | —— | —— | 暂无此机器 |

## 工具版本

| 工具 | 版本 |
|---|---|
| Swift（mac） | Apple Swift 6.4.2（swiftlang-6.4.2.1.9） |
| Rust（mac） | rustc 1.99.1、cargo 1.99.1 |
| 系统 zlib（mac，Swift 用的） | 1.2.12（`zlibVersion()`） |
| cmake（mac，只为编 zlib-ng） | 4.4.5，装在临时 venv 里，不在系统里 |
| Git for Windows（W11-L） | git version 2.50.1.windows.1（`core.autocrlf=false`，`core.longpaths=true`） |
| Visual Studio Build Tools（W11-L） | Visual Studio 2022 Build Tools 17.14.34（17.14.37328.6），Windows SDK 10.0.26100.0 / 10.0.22621.0 |
| Rust（W11-L） | rustc 1.99.1（58cf8f9c3 2026-10-13）、cargo 1.99.1（5f94df478 2026-08-27），`x86_64-pc-windows-msvc` |
| Flutter（W11-L） | Flutter 3.44.1（revision 924134a44c，Engine c416acfeb8，Dart 3.12.1），`D:\tools\flutter` |
| 随包 ConPTY（W11-L，探针 T1） | NuGet `Microsoft.Windows.Console.ConPTY` `1.25.261109001`（x64 `conpty.dll` + `OpenConsole.exe`），`portable-pty =0.9.0` |

## 总表

| 号 | 级 | 结论（过 / 没过 / 部分） | 走的是原方案还是退路 | 日期 | 做的人 |
|---|---|---|---|---|---|
| C1 | 一 | 过 | 原方案：`libz-sys` 静态链接的原版 zlib（已在 W11-L MSVC x64 上核实 `deflate.bin` 逐字节相同） | 2026-11-27 | Mac + Windows agent |
| T1 | 一 | 过（W11-L 已过；S22-C 暂无机器） | 原方案：随包 `conpty.dll` + `OpenConsole.exe` `1.25.261109001`（配合 `portable-pty =0.9.0` 或直接调 `ConptyCreatePseudoConsole`） | 2026-11-27 | Windows agent |

<!-- 每个探针照下面的样子写一节：

## <号>：<标题>

- **分支和提交**：`probe/windows-<id>` @ `<hash>`（在哪台机器上）
- **做了什么**：
- **量到什么**（表格，每台机器一行，带数字）：
- **过关线**：<从规格抄>　**结论**：
- **能用的做法**（系统调用、标志、crate 和版本，写到没看过探针代码的人能照着写）：
- **不能用的做法和原因**：
- **改了系统的什么，还原了没有**：
- **带进哪一段计划的结论**：
-->

## C1：Rust 的压缩和 Swift 的压缩逐字节相同吗

- **分支和提交**：`probe/windows-c1` @ `ed922300`（在 mac 上）。没推，不合进 `main`。
- **Swift 实际怎么调**（`Sources/RappCore/Deflate.swift`）：
  - 库：系统 zlib，通过 `CZlib` 模块（`link "z"`、`#include <zlib.h>`），不是 Compression 框架。这台 Mac 上 `zlibVersion()` 是 `1.2.12`。
  - 初始化：`deflateInit_(strm, level, ZLIB_VERSION, size)`，`TileCodec` 用默认的 6 级。所以窗口位 15、内存级 8、默认策略、带 zlib 头尾。
  - 刷新：每次 `compress` 都是 `deflate(strm, Z_SYNC_FLUSH)`，输出缓冲固定 64 KiB，循环到这一轮没写满为止。一条连接一条流。
  - `compress(_:ifAtMost:)`：先 `deflateCopy` 出一条试用流来压，结果不超过 `limit` 才换成试用流，超了就丢掉。
  - `reset()` 是 `deflateReset`，编码器在整帧时调用。
  - 和规格 §16 写的“系统 zlib，6 级，同步刷新”一致。
- **做了什么**：
  - `Tests/RappCoreTests/DeflateProbeTests.swift` 用 Swift 的 `DeflateStream` 生成语料，写到 `probes/windows/c1/corpus/`，共 612 项，加一份 `manifest.txt` 记录每一步的操作和流名。语料包括：空输入、1 字节、64 KiB 全零、64 KiB 随机、200 段真实瓦片流（gray4，`ScrollScenes.frames(seed: 7, count: 400, …)` 经 `FrameEncoder.encodeSlices` 后用 `InflateStream` 还原出压缩前的字节），先每段单独一条流压，再 200 段走一条流，在编码器重置的地方重置（这就是线上的样子，测试里核对了它和编码器自己发出的字节相同），再 200 段走一条流完全不重置，然后是一段 4 MiB 输入，最后 7 步 `ifAtMost` 试压：放得下、放不下后接普通压、差一个字节、刚好相等。
  - 语料是确定的：跑两次，sha 全部相同。
  - `probes/windows/c1/` 是独立的 Cargo 工程，带空的 `[workspace]`。它照 Swift 的调法重放语料：6 级、zlib 头、64 KiB 缓冲加 Sync 刷新循环。每个后端一个 feature。flate2 不能复制流，所以放不下的试压改成在新流上先重放历史再压。加 `--direct` 就不走 flate2，直接调后端的 C 接口：`deflateInit_`、`deflate`、`deflateCopy`、`deflateReset`。
  - 每一项都和 Swift 的输出比，并用 flate2 把 Swift 的输出和我们的输出都解回去，和输入比。
  - 另外加了一个对照组 `zlib-system`：Rust 链这台 Mac 自己的 libz，用来证明比的方法本身没错。
- **量到什么**（mac，arm64；格子里是“相同项/总项”，括号里是第一个不同的位置）：

| 项 | zlib-system（对照） | zlib（libz-sys 静态，原版 1.4） | rust_backend（miniz_oxide 0.9.1） | zlib-ng（2.3.3） | zlib-rs（0.6.9） |
|---|---|---|---|---|---|
| 空 | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 |
| 1 字节 | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 |
| 64 KiB 全零 | 1/1 | 1/1 | 0/1（字节 3） | 1/1 | 1/1 |
| 64 KiB 随机 | 1/1 | 1/1 | 0/1（字节 3） | 0/1（字节 3） | 0/1（字节 3） |
| 200 段瓦片，各自一条流 | 200/200 | 200/200 | 41/200 | 48/200 | 48/200 |
| 200 段一条流，按编码器重置 | 200/200 | 200/200 | 41/200 | 43/200 | 43/200 |
| 200 段一条流，不重置 | 200/200 | 200/200 | 41/200 | 43/200 | 43/200 |
| 4 MiB | 1/1 | 1/1 | 0/1（字节 6） | 0/1（字节 4） | 0/1（字节 4） |
| 试压（deflateCopy） | 7/7 | 7/7 | 0/7 | 0/7 | 0/7 |
| 放不放得下的判断和 Swift 不同的次数 | 0 | 0 | 0 | 0 | 0 |
| Swift 的输出 / 我们的输出解回原文 | 610/610、610/610 | 610/610、610/610 | 610/610、610/610 | 610/610、610/610 | 610/610、610/610 |

  - 压完的总字节（Swift / 我们）：200 段各自一条流是 15800 / 15800（zlib）、16407（miniz_oxide）、16261（zlib-ng、zlib-rs）；4 MiB 是 1819392 / 1819392（zlib）、1814684、1820434、1820434。
  - `--direct` 的结果和走 flate2 的完全一样：zlib 全部相同（`zlibVersion()` 报 `1.4`），zlib-ng（报 `2.3.3`）和 zlib-rs（报 `1.3.0-zlib-rs-0.6.9`）的表和上面一样。
  - 解回去只算让流往前走的 610 项。放不下的那两次试压是在副本上压的，没有解。
  - “200 段一条流”的两种走法这次结果一样，因为这串帧里只有第一帧是整帧（全程只重置 1 次）。
- **过关线**：有一种后端完全一样。**结论**：过。`libz-sys` 静态编译的原版 zlib 在 612 项上逐字节相同，走 flate2 和直接调 C 接口（含 `deflateCopy`）都一样。另外三种后端都有差异，但输出都能正确解压。
- **能用的做法**：
  - `host-core` 依赖 `libz-sys = { version = "1", default-features = false, features = ["static"] }`，这次是 1.1.33，自带 zlib 1.4。
  - 直接调 C 接口：`z_stream` 放在 `Box` 里，`deflateInit_(strm, 6, zlibVersion(), size_of::<z_stream>())`。
  - 每次压缩用 64 KiB 缓冲循环 `deflate(strm, Z_SYNC_FLUSH)`，直到这一轮没写满。
  - 试压用 `deflateCopy` 到第二个 `Box<z_stream>`，放得下就交换，放不下就 `deflateEnd` 掉副本。
  - `libz-sys` 的 `z_stream` 里 `zalloc`/`zfree` 是不可为空的函数指针，不能直接整个清零。探针先用 `MaybeUninit::zeroed()`，再填自己的 calloc/free，然后才 `assume_init`。
  - Apple 的 zlib 1.2.12 和原版 1.4 在这批输入上输出一样。
- **不能用的做法和原因**：
  - flate2 默认后端 miniz_oxide 和 Swift 不同，从字节 3 起就不同：它对“全零”和“随机”的块选择和 zlib 不一样，而且 C1 要的 `deflateCopy` 它没有。
  - zlib-ng 2.3.3 和 zlib-rs 0.6.9 两者输出彼此一样，但和原版 zlib 不同（随机数据从字节 3 起就不同）。
  - 走 flate2 本身也不行：它不能复制流，而且一开 zlib 类 feature 就会通过 feature 合并改掉整个工作区的 flate2（计划 B 任务 3 已写）。
- **改了系统的什么，还原了没有**：
  - 系统没改。
  - 编 zlib-ng 要 cmake，这台机器上没有，就用 `python3 -m venv` 在 session 的临时目录里装了一个 cmake 4.4.5（pip 包），只在那一次命令的 PATH 里用过，没装进系统，也没用 brew。
  - 探针自己的 `target/` 在 `.gitignore` 里。
- **Windows x86_64 实测补充（2026-11-27，W11-L）**：
  - 在 `W11-L`（MSVC 14.44.35207，`x86_64-pc-windows-msvc`，`libz-sys` 开启 `["static", "stock-zlib"]`）上运行 `cargo test -p rapp-host-core --no-fail-fast`，130 条测试全过，其中 `tests/deflate.rs`（`script_matches_swift` 与 `copy_overflow_matches_swift`）与 Swift 生成的 `deflate.bin` 逐字节完全一致。
- **带进哪一段计划的结论**：
  - 计划 B 任务 3 走原方案：`libz-sys` 静态原版 zlib，直接调 C 接口，样本逐字节比，不走“只比解压后字节”的退路。
  - `rust/host-core/Cargo.toml` 已加 `"stock-zlib"`（`features = ["static", "stock-zlib"]`），并在 Windows MSVC 上验证通过。

## T1：随包的 ConPTY 能不能用

- **分支和提交**：`probe/windows-t1` @ `46a054d1`（在 `W11-L` 上）。没推，不合进 `main`。
- **随包版本与文件摘要**：
  - NuGet 包：`Microsoft.Windows.Console.ConPTY` **`1.25.261109001`**
    - `.nupkg` SHA-256：`3d77f535df848e44225c2a8912ac844fecb23f3057732b639f3034b587496f09`
    - `runtimes\win-x64\native\conpty.dll`（119,608 字节）SHA-256：`e971856f89748dc3b458125e9afdd79b5e9574a7c937676116d3cbbd3b71f492`
    - `build\native\runtimes\x64\OpenConsole.exe`（1,089,336 字节）SHA-256：`b17e48b07ef153b420f0a6e178bacd31fb4c3390e21ae746586213fc0719a775`
  - `conpty.dll` 同时导出标准名（`CreatePseudoConsole`、`ResizePseudoConsole`、`ClosePseudoConsole`）和前缀名（`ConptyCreatePseudoConsole` 等，指向同一入口 RVA `0x59C0`）。
- **做了什么**：
  - 在 `probes/windows/t1/` 建独立 `[workspace]`，只读引用 `rapp-term` 的 `pty::ps::{Scanner, Records, parse}` 和 `pty::title::Titles`，对比四种伪终端调用方式：
    - **(a) `portable-pty =0.9.0`**：把 `conpty.dll` 和 `OpenConsole.exe` 放在可执行文件同目录，启动后用 `GetModuleHandleW(L"conpty.dll")` 核实确实加载了旁边的 `conpty.dll`；
    - **(b) 系统自带 `kernel32.dll` `CreatePseudoConsole`**（同目录不放 `conpty.dll`）；
    - **(c0) 直接调随包 `conpty.dll` 的 `ConptyCreatePseudoConsole`**（`dwFlags = 0`）；
    - **(c8) 直接调随包 `conpty.dll` 的 `ConptyCreatePseudoConsole`**（`dwFlags = 0x8`）。
  - 逐一喂入：`rust/term/testdata/ps/` 全部 5 份录制（按 `.reads` 分块写出：`claude-turns`、`claude-children`、`claude-error`、`codex-turns`、`synthetic-split`）；合成序列（`OSC 0`/`1`/`2` 中英文标题、`OSC 7` file URI、`OSC 9;9` 带中文和空格的目录汇报、`OSC 133;A`、`OSC 7501`）；以及 1 MiB 突发输出（首、中、尾各嵌一条 `OSC 7501`）。
- **量到什么**（`W11-L`，Windows 11 24H2 Build 26100.9711）：

| 方式 | `conpty.dll` 已加载 | 5 份 OSC 7501 录制（事件数与状态轨迹） | `OSC 0/1/2` 标题序列 | `OSC 7` / `OSC 9;9` 目录序列 | 1 MiB 突发（含首中尾 7501） | 单次启动+读完耗时（`claude-turns` 19,023 B） | 输出字节数（`claude-turns`） |
|---|---|---|---|---|---|---|---|
| **(a) `portable-pty =0.9.0` + 随包 DLL** | 是 | 5/5 全对（15、13、7、7、16） | **全保留**（`OSC 0`、`OSC 1`、`OSC 2` 各自原样到达，`shown == "tab-one"`） | 全保留（BEL 与 ST 均原样到达） | 过（1,048,668 B，1162 ms） | 1205.8 ms | 19,090 B |
| **(b) 系统 `kernel32` ConPTY（对照）** | 否 | 5/5 对（26100 上 7501 未被吞） | **有损**：`OSC 0/1/2` 被重绘合并成一条 `OSC 0:window 修复 终端`，**丢掉了 `OSC 1` 标签名** | 保留 | 过（1,048,761 B，354.5 ms） | 147.4 ms | **13,080 B**（重绘改写了约 6 KB 终端流） |
| **(c0) 直接调 `ConptyCreatePseudoConsole`（`flags=0`）** | 是 | 5/5 全对（15、13、7、7、16） | **全保留**（与 unix 完全一致） | 全保留 | 过（1,048,664 B，268.5 ms） | **147.9 ms** | 19,086 B |
| **(c8) 直接调 `ConptyCreatePseudoConsole`（`flags=0x8`）** | 是 | 5/5 全对 | **全保留** | 全保留 | 过（1,048,664 B，169.7 ms） | **146.3 ms** | 19,086 B |

  - `S22-C`（Server 2022）：暂无此机器，未测。
- **过关线**：上面几种序列原样出来，扫描器的结果和 unix 上一样；Server 2022 和 Windows 11 上都行。**结论**：在 `W11-L` 上**过**（(a) 和 (c0)/(c8) 均完整保留全部序列，且证明即使在最新的 Windows 11 24H2 上，系统自带 ConPTY 也会重绘吞改 `OSC 1` 标签名和终端字节，必须用随包 ConPTY）。`S22-C` 待有机器后补跑。
- **能用的做法**（给 E 段实现 `rust/term` Windows 分支用）：
  1. 随包带 NuGet `Microsoft.Windows.Console.ConPTY` `1.25.261109001` 的 `conpty.dll` 和 `OpenConsole.exe`，与 `rapp-term.exe` 放在同一版本目录（`app-<版本>\`）。
  2. **推荐直接调随包 `conpty.dll`（或注意 `portable-pty` 的 1 秒光标查询延迟）**：
     - `portable-pty =0.9.0` 在 `psuedocon.rs` 里写死了 `PSEUDOCONSOLE_INHERIT_CURSOR (0x1)`，导致 `OpenConsole.exe` 启动时向主端发 `ESC[6n` 并等待 1 秒超时（实测每次启动固定多等 **1.0 秒**：1205 ms vs 148 ms）。若用 `portable-pty`，主端读到开头的 `\x1b[6n` 立即回写 `\x1b[1;1R` 可消除这 1 秒等待；若不经 `portable-pty` 直接 `LoadLibraryExW` 同目录 `conpty.dll` 调 `ConptyCreatePseudoConsole(size, in_read, out_write, 0, &mut hpc)`，默认无这 1 秒延迟且代码仅百余行。
  3. **关键细节（必守）**：用 `CreateProcessW` + `EXTENDED_STARTUPINFO_PRESENT`（`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016`）拉起子进程时，**必须**在 `STARTUPINFOEXW.StartupInfo` 中设 `dwFlags = STARTF_USESTDHANDLES`，并把 `hStdInput`、`hStdOutput`、`hStdError` 全部设为 `INVALID_HANDLE_VALUE`（且 `bInheritHandles = FALSE`）。否则当父进程（如无窗口的 `rapp-term` worker）自身的标准输出被重定向到管道时，子进程会继承父进程的管道直接往外写，绕过伪终端（探针第一次跑 `c0` 时实测踩中此坑）。
  4. 关闭顺序：子进程退出后，后台读线程继续读 `out_read`，主线程调 `ClosePseudoConsole(hpc)` 触发 `OpenConsole.exe` 刷空剩余缓冲并关闭写端，读线程收到 EOF 后再关 `out_read`，不会死锁也不丢尾部字节。
- **不能用的做法和原因**：
  - 系统自带 `kernel32` `CreatePseudoConsole`：即使在 Build 26100 上仍做屏幕缓冲重绘（`19023 B` 变成 `13080 B`），且把 `OSC 1` 独立标签名合并覆盖掉；Server 2022 系统自带版本更旧。
  - `CreateProcessW` 不显式把三路标准句柄设为 `INVALID_HANDLE_VALUE`：在父进程被重定向 stdio 时子进程输出会漏出伪终端。
- **改了系统的什么，还原了没有**：没改任何系统设置；NuGet 包解在会话临时目录，探针运行时的临时目录已自动删除。
- **带进哪一段计划的结论**：带进 **E 段（`rapp-term` Windows 一支）** 和 **G 段（打包脚本把 `conpty.dll`、`OpenConsole.exe` 放进 `app-<版本>\`）**。
