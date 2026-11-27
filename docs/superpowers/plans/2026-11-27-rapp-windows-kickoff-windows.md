你在一台 Windows 机器上，接手 rApp Windows 版的主要验证工作。现在这台机器上还什么都没有。你的任务分三段：

1. 把机器装好，跑一级探针。现在就能做。
2. 把 A 段代码草稿（地基）修到 Windows 门禁全绿。要等分支出现在 origin 上。
3. 把 B 段代码草稿（主机核心）修到编得过、输出和 Swift 的样本逐字节对上。排在 A 段后面。

## 背景

rApp 是远程控制软件，macOS 版在用。Windows 版要对齐 macOS 的功能，设计和九份计划已经写完，代码只有 A、B 两段的草稿，而且**从来没有编译过，也没有跑过任何测试**。草稿是另一个模型照计划写的，写的时候规定不许编译。它的说明文件里凡是写“写了”的，意思只是文件里有这段代码。

草稿已经合进 `main`，但 `main` 的文件里只有 Mac 不编译的部分（三个没进 workspace 的新 crate、两个 PowerShell 脚本、文档）。**接线只在两个分支上**：`feat/windows-foundation` 是 `main` 加 A 段对已有 crate 的改动，`feat/windows-host-core` 是 `main` 加 B 段的成员表、testkit 测试和样本。编译和测试都在分支上做，在 `main` 上编不到这些代码。见交接文档 §2.1。

用户定的顺序是以 Windows 为主（2026-11-27）：编译和修错都在这台机器上做。Mac 上另有一个 agent 只做一头一尾，它的提示词是 `docs/superpowers/plans/2026-11-27-rapp-windows-kickoff-mac.md`：

- 开头：用 Swift 生成样本，把两个分支推到 origin。
- 收尾：你修绿的提交在 Mac 上再过一次 Mac 门禁，然后由它把接线合进 `main`。

被控端的逻辑现在在 Swift 里（`Sources/`），`rust/host-core` 是它的移植。所以 **Swift 是基准**：草稿和 Swift 不一致时改 Rust，不改 Swift，不改样本。

设计里凡是标了【未验证】的地方，都是对 Windows 的猜测。探针就是用一次性的小程序在真机上把这些猜测换成量出来的结果。C–H 六份计划是探针跑之前写的，探针结果和假设不一样时，计划要跟着改。所以探针的产出不是代码，是一页**结果**：试了什么、在哪台机器上、量到多少、过没过、管用的做法是什么。没见过探针代码的人要能照这一页把正式代码写出来。

## 先读，按这个顺序

仓库 clone 下来之后读：

1. `CLAUDE.md`。最后一小节“Windows 集成 session”是这台机器上另一个 session 的事，见下面“谁推送”。
2. `docs/superpowers/plans/2026-11-26-rapp-windows-handoff.md` 的 §2.1（草稿怎么进的 `main`）、§4（边界）、§5（顺序）、§6（规矩）。做第二段前读 §3.1，做第三段前读 §3.2。
3. 规格 `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` 的 §0.2、§5.3、§16（每个探针要回答什么、过线是多少、退路是什么）、§17.3（要哪些机器）、§19.1。§16 要全文读完再动手。
4. 计划 `docs/superpowers/plans/2026-11-26-rapp-windows-p-probes.md` 全文。
5. 做第二段前：计划 `…-windows-a-foundation.md` 全文。做第三段前：计划 `…-windows-b-host-core.md` 全文。
6. 草稿的说明文件：`docs/superpowers/plans/notes/2026-11-26-windows-{a,b1,b2,b3}-draft-notes.md`。

不要读、不要搜 `docs/archives/`。

## 第一段：装机器，跑一级探针

**1. 装机器**（计划 A 任务 1 的步骤 4–6）

- 要装的：Git for Windows；Visual Studio 2022 Build Tools，带“使用 C++ 的桌面开发”；Rust（rustup，stable，`x86_64-pc-windows-msvc`）；Flutter，开 `flutter config --enable-windows-desktop`，`flutter doctor` 的 Windows 部分要干净。
- Rust 和 Flutter 的版本要和 Mac 一样。写这份提示词时 Mac 上是 `rustc 1.99.1` 和 `Flutter 3.44.1`，开工前请用户再确认一次。
- **clone 之前**先设好：`git config --global core.autocrlf false` 和 `git config --global core.longpaths true`。Git for Windows 默认会把换行改成 CRLF，那样第三段里逐字节比对的样本就全不对了。
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
- 某条线在等用户或等机器时，不用干等：分支已经在 origin 上的话，先去做第二段。

## 第二段：A 段草稿，修到 Windows 门禁全绿

**要等一件事**：Mac 那边把 `feat/windows-foundation` 和 `feat/windows-host-core` 推到 origin。`git fetch origin` 之后看得到这两个分支就能开工；看不到就告诉用户你在等。`main` 上虽然已经有 `scripts\check-windows.ps1`，但 A 段的接线不在 `main` 上，在 `main` 上跑它没有意义。

在 `feat/windows-foundation` 上做，建议另开一个 worktree：

1. `git merge main`。读说明文件 `…windows-a-draft-notes.md` 和交接文档 §3.1，那里列了最先会撞上的地方。
2. 让 `Cargo.lock` 自己更新，不要手改，不要动版本号那几行，和代码改动一起提交。
3. 跑 `scripts\check-windows.ps1`（计划 A 任务 8），修到日志 `.build-logs\check-windows.log` 最后一行是 `EXIT=0`。这个脚本本身也是草稿，没跑过。
4. 证明门禁既能绿也能红：故意弄坏一处，确认它报 `EXIT=1`，再改回来。
5. 计划 A 每个任务的“实机检查”逐条做，结果写进 `tasks/todo.md`。
6. **记一张清单**：你改过的地方里，哪些落在 unix 也编译的代码上（不在 `cfg(windows)` 里的）。尽量少改这种地方；必须改时，unix 那一支的行为不能变。你在这台机器上验不了 macOS，这张清单是 Mac 那边核对用的。
7. 推分支：`git push origin feat/windows-foundation`。这是这条线的固定步骤，不用另外问。只推分支，不推 `main`，不强推。
8. 告诉用户：A 段在 Windows 上绿了，是哪个提交，可以让 Mac 那边跑 Mac 门禁了。Mac 那边如果又改了 Windows 也编译的代码，会请你在新的提交上再跑一次门禁。两边在同一个提交上都绿，Mac 那边才把接线合进 `main`。
9. A 段做完以后做 G2（计划 P 任务 12）。

A 段在 Windows 上绿了就可以接着做第三段，不用等它进 `main`。

## 第三段：B 段草稿，修到和 Swift 的样本对上

在 `feat/windows-host-core` 上做。动手前确认两件事：

- `rust\host-core\tests\fixtures\` 里有样本文件。没有就是 Mac 那边还没生成，告诉用户你在等。
- `rustc --version` 不低于 1.89，草稿用了这个版本才有的接口。

步骤：

1. `git merge main`，再把修绿的 `feat/windows-foundation` 合进来：testkit 依赖的那些 crate 要有 A 段的接线才能在 Windows 上编。两段都改 `rust/Cargo.toml` 的成员表和 `rust/testkit/tests/common/mod.rs`，冲突时两边的都留。
2. 读交接文档 §3.2（末尾有“B 段整体先验的顺序”）和三个说明文件 `…windows-b1/b2/b3-draft-notes.md`。
3. `cargo check -p rapp-host-core --all-targets`，再 `-p rapp-testkit --all-targets`，把编译错误改完。
4. `cargo test -p rapp-host-core --no-fail-fast`。先看边界测试和压缩。红的地方以 Swift 为准改 Rust。做不到一个字节不差的，按计划 B“Fixture rules”最后一条处理，写进 `rust/host-core/PORTING.md`。
5. 压缩（计划 B 任务 3）走哪条路，看结果页里探针 C1 的结论，那是 Mac 那边做的。
6. `cargo test -p rapp-testkit --test host_session`，再 `--test host_service`。会话测试用 20 倍速的时钟，几处时间窗很紧；偶发失败先单独重跑，分清是负载还是逻辑。
7. 补上或认下 §3.2“草稿和 Swift 不一样”剩下的四条，每条的处理写进 `PORTING.md`。
8. 跑一遍完整的 `scripts\check-windows.ps1`，要 `EXIT=0`。
9. 推分支：`git push origin feat/windows-host-core`，告诉用户是哪个提交。

样本的规矩：

- **样本文件只读。** 不改，不重新生成，这台机器上也生成不了。
- 样本测试第一次就全绿时，故意改坏 Rust 的一处再跑一次，确认它真的在比东西。
- 你认为某个样本本身是错的（生成器的错，不是 Rust 的错）时，写清楚是哪个文件、Swift 源码里哪一段说明它错了，交回给用户转给 Mac 那边。重新生成只能在 Mac 上做。
- 样本对不上先查换行：`git ls-files --eol rust/host-core/tests/fixtures` 里不能有 `w/crlf`。

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

- 不改：`Sources/`、`rust/host-linux/`、`rust/client-gtk/`、`rust/hub-ffi/`、`rust/host-core/tests/fixtures/` 里的样本。
- 中继 `rust/relay/` 只许草稿里已有的两处改动：`audit.rs` 的三处 `#[cfg(unix)]`，`admin.rs` 的 unix 代码放到 `#[cfg(unix)]` 后面加同名替身。再多要先问用户。
- 三条模块边界（规格 §5.3）不能破：`host-core` 里没有任何操作系统相关的代码；`host-windows` 不产生也不解析协议字节；只有 `rapp-svc` 跨登录会话启动进程。
- 不升协议号，不为 Windows 加消息。
- 不改版本号、不打 tag、不建 release、不动 `website/releases.json`。
- 草稿和计划不一致时，看 Swift 和规格谁对。计划错了就改计划，和代码改动放在同一个提交里，并在那一段说明文件的“计划错误”一节记一行。
- 日志里绝不出现密码、PIN、token、密钥、打的字、剪贴板内容。
- 按路径提交，不用 `git add -A`，不用 `git stash`，不跑 `cargo fmt --all`。
- 草稿提交留在历史里不改写。你的提交用平常的标题（`fix(...)`、`test(...)`），不带“草稿”字样。

**谁推送**

你是做功能的 session。你能推的只有 `feat/windows-foundation` 和 `feat/windows-host-core` 这两个分支；`main` 你只合并到这台机器的本机 `main`，不推。而且这两个分支的接线你不往 `main` 里合，那是 Mac 那边在两个门禁都绿了以后做的事。你合进本机 `main` 的只有文档：结果页、`CLAUDE.md` 里的路径、计划的改正。

推 `main` 归这台机器上的“Windows 集成 session”，它还没开。机器装好、结果页第一次合并之后，请用户开一个，常驻指令就是 `CLAUDE.md` 最后一小节。A 段的接线进 `main` 之前，它的“Windows 门禁”只是 `cargo metadata --manifest-path rust/Cargo.toml --format-version 1` 能成功。它第一次把只改文档的合并推到 `origin/main`、Mac 那边能拉到，这条路就算通了。

## 这些事停下来告诉用户，不要自己定

- **一级探针没过。** 那条线停下，写好结果，告诉用户。不要临场想办法绕。
- 退路写着“回来问用户”的（H1、S1、S2）和“回来告诉用户”的（G1 在云主机上不行、T1）。
- 要登录云主机或别的机器，要冷启动、重启、断电，要有人坐在机器前操作。S2 要从冷启动、没人碰机器的状态做，结果里要写明确实是这样做的。
- 要升级 Rust 工具链。Mac 的发版 session 用的是同一套，两边要一样。
- 要改规格 §19.1 第二张单子上的事，或者上面“不改”“边界”里的任何一条。
- 你认为某个样本本身是错的。

二级探针没过不用问：照 §16 写好的退路走，把规格 §15 里那个功能的那一行改成“有限制”。过线的数字是起点，量出来发现线定错了，就在规格里连同原因一起改，不要悄悄算过或算不过。规格 §19.1 第一张单子上的事是留给实现的人定的，你自己定，写进计划。

## 交回什么

1. 机器清单：系统版本、硬件、checkout 路径、工具版本。
2. 一张总表：每个探针在哪几台机器上做了，过没过，哪几行没做和原因。
3. 每个探针管用的做法在结果页的哪一节。
4. 和计划假设不一样的结果，各改了哪份计划的哪里，在哪个提交。
5. 每个探针对系统改了什么，是否都改回去了。
6. A 段：`check-windows.ps1` 的结果和推上去的提交；草稿里错了什么、怎么改的，按文件列；那张“改到了 unix 也编译的代码”的清单；实机检查的结果。
7. B 段：每条命令和它的结果，没跑的要说没跑；草稿里错了什么、怎么改的；压缩结果和样本是否逐字节相同，走了退路的话是哪一条；“草稿和 Swift 不一样”剩下的四条各是补上了还是认下来了；推上去的提交。
8. 在等用户或等 Mac 那边的事。
