你在一台 Windows 机器上，接手 rApp Windows 版里只能在 Windows 上做的事。现在这台机器上还什么都没有。你的任务分两段：先把机器装好并跑一级探针，这一段现在就能做；再验证 A 段代码草稿的 Windows 那一半，这一段要等 Mac 那边先做完。

## 背景

rApp 是远程控制软件，macOS 版在用。Windows 版要对齐 macOS 的功能，设计和九份计划已经写完，代码只有 A、B 两段的草稿，而且**从来没有编译过**。草稿已经合进 `main`，但 `main` 的文件里只有 Mac 不编译的部分（三个没进 workspace 的新 crate、两个 PowerShell 脚本、文档）；对已有 crate 的改动留在分支上，见交接文档 §2.1。Mac 上另有一个 agent 在验证这两段草稿里 Mac 能验的部分。

设计里凡是标了【未验证】的地方，都是对 Windows 的猜测。探针就是用一次性的小程序在真机上把这些猜测换成量出来的结果。C–H 六份计划是探针跑之前写的，探针结果和假设不一样时，计划要跟着改。所以探针的产出不是代码，是一页**结果**：试了什么、在哪台机器上、量到多少、过没过、管用的做法是什么。没见过探针代码的人要能照这一页把正式代码写出来。

## 先读，按这个顺序

仓库 clone 下来之后读：

1. `CLAUDE.md`。最后一小节“Windows 集成 session”是这台机器上另一个 session 的事，见下面“谁推送”。
2. `docs/superpowers/plans/2026-11-26-rapp-windows-handoff.md` 的 §2.1（草稿怎么进的 `main`）、§4（边界）、§5（顺序）、§6（规矩）。
3. 规格 `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` 的 §0.2、§5.3、§16（每个探针要回答什么、过线是多少、退路是什么）、§17.3（要哪些机器）。§16 要全文读完再动手。
4. 计划 `docs/superpowers/plans/2026-11-26-rapp-windows-p-probes.md` 全文。
5. 计划 `…-windows-a-foundation.md` 的任务 1 和任务 8。

不要读、不要搜 `docs/archives/`。

## 第一段：装机器，跑一级探针

**1. 装机器**（计划 A 任务 1 的步骤 4–6）

- 要装的：Git for Windows；Visual Studio 2022 Build Tools，带“使用 C++ 的桌面开发”；Rust（rustup，stable，`x86_64-pc-windows-msvc`）；Flutter，开 `flutter config --enable-windows-desktop`，`flutter doctor` 的 Windows 部分要干净。
- Rust 和 Flutter 的版本要和 Mac 一样。写这份提示词时 Mac 上是 `rustc 1.99.1` 和 `Flutter 3.44.1`，开工前请用户再确认一次。
- **clone 之前**先设好：`git config --global core.autocrlf false` 和 `git config --global core.longpaths true`。Git for Windows 默认会把换行改成 CRLF，那样计划 B 里逐字节比对的样本就全不对了。
- clone 之后核对：`git status` 是干净的；`git ls-files --eol` 里没有 `w/crlf`；仓库根有 `.gitattributes`（内容是 `* -text`）。
- 仓库地址和放在哪个目录，问用户。
- 缺什么软件先列出来给用户看，再装。

**2. 建结果页，记下这台机器**（计划 P 任务 1）

- 结果页是 `docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md`，已经有一份骨架。先对一遍计划 P 任务 1，缺的补上。在分支 `docs/windows-probe-results` 上改，合进这台机器的本机 `main`。
- 机器清单里写：Windows 版本和 build 号、CPU、显卡、checkout 的路径、四个工具的版本。
- 把 checkout 的路径填进 `CLAUDE.md`“其他 session”第 2 条，替换掉“Windows 机器上的路径等机器装好后填在这里”这句。这处改动用户已经同意。

**3. 一级探针**（计划 P 任务 3–11）

- 先做 G1（任务 3）。然后三条线：H1、H3、H5（任务 4–6）；S1、S2、S4（任务 7–9）；T1、T5（任务 10–11）。
- C1（任务 2）在 Mac 上做，不归你。G2（任务 12）要等 A 段做完。二级探针（任务 13–18）到各自那一段开工时再做。
- 每做完一个探针就填结果页并合并，不要攒到最后。

## 第二段：A 段草稿的 Windows 那一半

**现在还不能做。** 要等两件事：Mac 那边把 `feat/windows-foundation` 修到 Mac 门禁全绿；有人把这个分支推到 origin。这个分支现在只在 Mac 上。第一段做完后，告诉用户你在等它。`main` 上虽然已经有 `scripts\check-windows.ps1`，但 A 段的接线不在 `main` 上，在 `main` 上跑它没有意义。

拿到分支后：

1. 读分支上的说明文件 `docs/superpowers/plans/notes/2026-11-26-windows-a-draft-notes.md` 和交接文档 §3.1。
2. 跑 `scripts\check-windows.ps1`（计划 A 任务 8），修到日志最后一行是 `EXIT=0`。这个脚本本身也是草稿，没跑过。
3. 证明门禁既能绿也能红：故意弄坏一处，确认它报 `EXIT=1`，再改回来。
4. 计划 A 每个任务的“实机检查”逐条做，结果写进 `tasks/todo.md`。
5. 你改过的提交要回 Mac 再过一次 Mac 门禁（计划 A 第 24 行的办法：推分支，不推 `main`）。两边都绿了才能把接线合并进 `main`。
6. A 段合并以后做 G2（计划 P 任务 12）。

## 规矩

**探针的**

- 探针代码只放在分支 `probe/windows-<号>` 上，目录 `probes/windows/<号>/`，永远不合进 `main`，也不推送，除非用户要。Rust 探针是独立的 Cargo 项目，`Cargo.toml` 里带一个空的 `[workspace]`，这样它不会进 `rust/` 的 workspace，也不会碰 `rust/Cargo.lock`。
- 探针阶段不改正式代码：`rust/`、`gui/lib/`、`Sources/` 都只读。
- 不装驱动，不注入 DLL，不装钩子。除了 §16 那一行写明的，不改任何系统设置。每个探针列出自己改了什么，做完改回去。S1 会打开软件 SAS 策略，做完必须关掉。
- 结果页和探针日志里不许出现密码、token、打的字。锁屏和登录的探针从只在那一次运行里设的环境变量读密码。
- 用到的每个版本都钉住并写进结果页：Rust 工具链、`windows` crate、`portable-pty`、ConPTY 包、Flutter、Inno Setup 等。
- 采集类探针用生成的测试图案按数值比，不靠眼睛看。输入类探针按计划里的六个程序和确切次数做，不能只在记事本上试。
- 很多探针的表里有“没有显卡的 Server 2022 云主机”这一行，它是必做的。你手上没有这台机器时，结果页里把这一行标成“没做”，这个探针就不算过。
- 基准是 Windows 11（build ≥ 22000）和 Windows Server 2022（build ≥ 20348），只做 x64。不测 Windows 10。

**整个仓库的**

- 不改：`Sources/`、`rust/host-linux/`、`rust/client-gtk/`、`rust/hub-ffi/`。
- 中继 `rust/relay/` 只许草稿里已有的两处改动。再多要先问用户。
- 三条模块边界（规格 §5.3）不能破。
- 不升协议号，不为 Windows 加消息。
- 不改版本号、不打 tag、不建 release、不动 `website/releases.json`。
- 按路径提交，不用 `git add -A`，不用 `git stash`，不跑 `cargo fmt --all`。
- 草稿提交留在历史里不改写。你的提交用平常的标题，不带“草稿”字样。

**谁推送**

你是做功能的 session：只合并到这台机器的本机 `main`，不推 `main`。推送归这台机器上的“Windows 集成 session”，它还没开。机器装好、结果页第一次合并之后，请用户开一个，常驻指令就是 `CLAUDE.md` 最后一小节。A 段的门禁脚本合并之前，它的“Windows 门禁”只是 `cargo metadata --manifest-path rust/Cargo.toml --format-version 1` 能成功。它第一次把只改文档的合并推到 `origin/main`、Mac 那边能拉到，这条路就算通了。

## 这些事停下来告诉用户，不要自己定

- **一级探针没过。** 那条线停下，写好结果，告诉用户。不要临场想办法绕。
- 退路写着“回来问用户”的（H1、S1、S2）和“回来告诉用户”的（G1 在云主机上不行、T1）。
- 要登录云主机或别的机器，要冷启动、重启、断电，要有人坐在机器前操作。S2 要从冷启动、没人碰机器的状态做，结果里要写明确实是这样做的。
- 要改规格 §19.1 第二张单子上的事，或者上面“不改”“边界”里的任何一条。
- A 段的接线合并进 `main` 之前。

二级探针没过不用问：照 §16 写好的退路走，把规格 §15 里那个功能的那一行改成“有限制”。过线的数字是起点，量出来发现线定错了，就在规格里连同原因一起改，不要悄悄算过或算不过。

## 交回什么

1. 机器清单：系统版本、硬件、checkout 路径、工具版本。
2. 一张总表：每个探针在哪几台机器上做了，过没过，哪几行没做和原因。
3. 每个探针管用的做法在结果页的哪一节。
4. 和计划假设不一样的结果，各改了哪份计划的哪里，在哪个提交。
5. 每个探针对系统改了什么，是否都改回去了。
6. 第二段做了的话：`check-windows.ps1` 的结果、草稿里错了什么和怎么改的、实机检查的结果。
7. 在等用户或等 Mac 那边的事。
