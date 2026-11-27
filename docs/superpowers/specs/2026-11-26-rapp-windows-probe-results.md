# rApp Windows 探针结果

规格：`2026-11-26-rapp-windows-design.md` §16。每个探针一节，做完一个填一个。

## 机器

| 代号 | 机器 | 系统和内部版本 | 处理器 / 显卡 | 屏幕和缩放 | 备注 |
|---|---|---|---|---|---|
| mac | Mac（Apple M5） | macOS 27.0.1（26A434），arm64 | Apple M5 | —— | C1 只在这台上做 |

## 工具版本

| 工具 | 版本 |
|---|---|
| Swift（mac） | Apple Swift 6.4.2（swiftlang-6.4.2.1.9） |
| Rust（mac） | rustc 1.99.1、cargo 1.99.1 |
| 系统 zlib（mac，Swift 用的） | 1.2.12（`zlibVersion()`） |
| cmake（mac，只为编 zlib-ng） | 4.4.5，装在临时 venv 里，不在系统里 |

## 总表

| 号 | 级 | 结论（过 / 没过 / 部分） | 走的是原方案还是退路 | 日期 | 做的人 |
|---|---|---|---|---|---|
| C1 | 一 | 过 | 原方案：`libz-sys` 静态链接的原版 zlib | 2026-11-27 | Mac 上的 agent |

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
- **没验证的**：
  - 只在 Mac arm64 上跑过，Windows x86_64（MSVC 编出来的同一份 zlib 源码）没跑。
  - 原版 zlib 的压缩是可移植的 C，按理和架构无关，但这是推断。等 Windows 上 `host-core` 的 `deflate.bin` 样本测试（`cargo test -p rapp-host-core --test deflate`）过了才算证实。
  - 语料也提交在探针分支上了，Windows 机器拉到这个分支就能直接 `cargo run`。
- **带进哪一段计划的结论**：
  - 计划 B 任务 3 走原方案：`libz-sys` 静态原版 zlib，直接调 C 接口，样本逐字节比，不走“只比解压后字节”的退路。
  - 有一处要 Windows 那边改 Rust 时顺带看：草稿的 `rust/host-core/Cargo.toml` 写的是 `features = ["static"]`，没带 `stock-zlib`。`libz-sys` 的 build.rs 里，只要有别的 crate 打开 `libz-sys/zlib-ng`，又没开 `stock-zlib`，就会改编 zlib-ng（`build.rs:16-19`）。这样输出会悄悄和 Swift 不同。加上 `"stock-zlib"` 就能防住。现在的工作区里没有谁打开它，这是防患，不是已经出了的错。
