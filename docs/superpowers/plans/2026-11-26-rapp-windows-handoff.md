# rApp Windows 版：边界和交接

写于 2026-11-26。给接手验证、调试和后续实现的人（或 agent）看。先读这一份，再读你要做的那一段的计划。

## 1. 有哪些文档，各管什么

| 文档 | 管什么 |
|---|---|
| `docs/superpowers/specs/2026-11-26-rapp-windows-design.md` | 总体设计。用户已批准（2026-11-26）。说“做成什么样、为什么” |
| `docs/superpowers/plans/2026-11-26-rapp-windows-p-probes.md` | P 段：探针。在 Windows 实机上先试的事，结果写进 `…-windows-probe-results.md` |
| `…-windows-a-foundation.md` | A 段：地基。现有 crate 在 Windows 上编得过、Windows 门禁、空壳 crate |
| `…-windows-b-host-core.md` | B 段：`rust/host-core`，被控端里不认识操作系统的那一半，在 Mac 上对着 Swift 验 |
| `…-windows-c-controller.md` | C 段：控制端（Flutter Windows 外壳、`rapp-svc user`、管道协议） |
| `…-windows-d-host-user.md` | D 段：被控端（用户方式），`rust/host-windows` |
| `…-windows-e-terminal.md` | E 段：文本终端（ConPTY） |
| `…-windows-f-system-service.md` | F 段：系统服务、帮手、登录前、解锁、Ctrl+Alt+Del |
| `…-windows-g-install-upgrade.md` | G 段：安装、升级、退回、卸载、打包 |
| `…-windows-h-release.md` | H 段：语音、输入法、任务栏、总验收、总审计、首发 |
| `docs/superpowers/plans/notes/2026-11-26-windows-*-draft-notes.md` | 代码草稿的说明：写了什么、没写什么、哪些没验证、发现的计划错误。**在各自的代码分支上**，不在 main 上 |

每份计划的开头都有：这一段的**硬约束**（Global Constraints）、**重点审查的输入**（Review Focus，每条都挂到了某个任务的测试上）、**文件表**、**组件选择表**（Component choices：用哪个系统接口、哪个库、钉哪个版本）。C–H 六份是在探针跑之前写的，所以各有一张“探针结果不一样时改哪里”的表。

## 2. 现在到哪了

| 段 | 计划 | 代码 | 在哪 | 状态 |
|---|---|---|---|---|
| P 探针 | 有 | 没有 | —— | 没跑。要一台 Windows 11 和一台 Server 2022（实机或虚拟机） |
| A 地基 | 有 | **草稿，写完了** | 分支 `feat/windows-foundation`，worktree `.worktrees/windows-foundation` | 没编译、没测试、没在 Windows 上碰过。任务 2–7 的代码都写了；任务 1、8、9 里要上机器的步骤没做（见 3.1） |
| B 主机核心 | 有 | **草稿，写完了**（任务 1–19；任务 20 收尾要上机器，没做） | `feat/windows-host-core`（任务 7–12 写在 `feat/windows-host-core-rules` 上，已合进来，那个分支可以不用再看） | 同上；Swift 样本文件一个都还没生成；任务 19 的真机走查没做（见 3.2） |
| C–H | 有 | 没有 | —— | 等接手的人按计划做 |

所有代码草稿都从 main 的 `7ed6c7e4` 分出来，**没有合并进 main**。草稿的每个提交标题都带 `(草稿，未编译未验证)`。

## 3. 草稿是怎么写出来的，能信多少

草稿由 Opus 5.5 照计划写，规矩是：**只写代码，不编译，不跑任何测试、格式化和检查工具**。所以：

- **能信的**：结构、模块划分、文件位置、函数名和签名照计划；核心算法是照着 Swift 源文件逐个分支移过来的，不是空壳（要求是不许留 `todo!()`、空函数体）。组件选择都在计划的表里定死了，草稿照着用。
- **不能信的**：编不编得过；和 Swift 的输出是不是一个字节不差；Windows 系统调用的参数对不对；`Cargo.lock`（**没有重新生成**，新加的依赖还没进去）；样本文件（`rust/host-core/tests/fixtures/` 是空的，要跑 Swift 生成）。
- **每个分支上的说明文件是准的那一份**：写了哪些、哪个算法完整、哪里是猜的、哪里和计划对不上。接手先读它。

### 3.1 A 段草稿的实际情况

说明文件：分支上的 `docs/superpowers/plans/notes/2026-11-26-windows-a-draft-notes.md`（六节：写了什么、没写什么、和计划不同的地方、计划的错、编译风险、先验什么）。

- **写了的**：两个空壳 crate 进 workspace；`rapp-net` 的 Windows 部分（`rust/net/src/win.rs`，新增的 `unsafe` 只在这一个文件）；`rapp-service` 的单实例和 `--supervised`；`rapp-term` 的 unix 部分包起来；`rapp-cli` 在 Windows 上的入口；测试在 Windows 上的写法（七处权限断言、testkit 复制四个假程序）；`.gitattributes`；`rust/.cargo/config.toml`；`scripts/stage-windows.ps1`、`scripts/check-windows.ps1`；规格 §19.2 列的旧文档句子；`tasks/todo.md` 末尾两个新标题。
- **没做的**：`CLAUDE.md` 没动（四条文字在说明文件第 2 节，要先给用户看）；所有要 Windows 机器的步骤；Flutter 的 Windows 构建；§17.2 的完成标记；合并。
- **计划里错的，已经改回计划 A**：中继只改 `audit.rs` 不够（见 4.2，用户已同意再改 `admin.rs`，草稿里已经写了：提交 `132111ad`、`ddbdc52b`；Windows 上因此关掉“换钥”一组八个测试，首发前手工验一次，在计划 H 任务 5）；`rapp-state` 和余力的 `disks.rs` 是计划之后才进 main 的 unix 代码；testkit 的假程序是四个不是三个；`rapp-term` 的“改名检查”要改成比内容；`rust/.cargo/config.toml` 只在当前目录是 `rust\` 时生效。
- **最先会撞上的**：
  1. `Cargo.lock` 没重新生成。第一次跑 cargo 会改它，这是加依赖的正常结果，和功能一起提交（只是不许动里面的版本号行，那归发版 session）。
  2. `rust/net/src/win.rs` 里 `windows-sys` 0.61 的签名和特性开关（`SetNamedSecurityInfoW`、`EXPLICIT_ACCESS_W`/`TRUSTEE_W`、`GetAce`、`GetDiskFreeSpaceExW`）是凭记忆写的。
  3. `rust/service/src/lib.rs` 里 `UpdateOpts::windows` 的闭包类型可能推不出来。
  4. 两个 PowerShell 脚本没跑过；`Step` 靠脚本块返回一个布尔值，命令往管道里多吐东西就会被判成失败。
- **先在 Mac 上做的**：`cargo check --workspace`（确认没碰坏 macOS），再 `cargo check --target x86_64-pc-windows-msvc`（只查类型，不链接），然后才上 Windows 机器。

### 3.2 B 段草稿的实际情况

B 段分三批写，前两批在两个分支上并行，互相没看过对方的代码；第三批把两边合到 `feat/windows-host-core` 上接着写。现在只看这一个分支就行。下面按批写，是因为每批的风险不一样。

**编码组：任务 1–6，分支 `feat/windows-host-core`**（说明文件 `docs/superpowers/plans/notes/2026-11-26-windows-b1-draft-notes.md`）

- **写了的**：crate 外壳、时钟、Swift 样本工具、边界测试（任务 1）；画面协议编解码和“不处理”的消息表（2）；deflate 流，直接绑 `libz-sys`（3）；量化（4）；分块编码和滚动检测（5）；发送节奏、弱网档、省流阶梯、暂停队列（6）。每个任务都有 Swift 样本生成器和 Rust 对照测试。
- **现在编不过，原因是已知的**：`lib.rs` 在任务 1 就把任务 7–19 的模块全声明了，`tile.rs` 还用了任务 7 的 `geometry::Rect`（假定字段是 `x, y, width, height: f64`）。写这一批时编不过；现在三批都在一个分支上了，模块齐了，但整个 crate 一次都没编过。
- **样本文件一个都没生成**（不许跑 swift）。生成命令：`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`。
- **和计划不同的名字**：说明文件第 3 节有完整清单。要紧的几处已经按 Swift 改回计划 B：`encode` 返回 `Option`、`region` 可空；`offer` 多一个 `captured`；`SenderOutput::Frame` 带 `region`；`set_paused`/`set_pinned`/`set_steps` 有返回值；`take_stats` 要 `now`。
- **草稿没照计划做的三处，接手的人要改或者认下来**：
  1. `tests/pacing.rs` 用 `serde_json::Value` 比结果。计划 B 的规矩是反序列化成 Rust 类型再比，不比 `Value`。
  2. 轨迹里每一步写成 `{"op": …, "pic": …}`，计划写的是 `{"call": …, "scene": …}`。两边一致就行，改不改都可以，改就两边一起改。
  3. 超过 512 字节的帧只记长度和 FNV 校验，不记十六进制。对不上时看不到是哪个字节不同，要查就临时把上限调大。
- **计划里错的，已经改回计划 B**（提交 `0c29a2ce`、`48b5c6eb`）：恢复暂停后发的是差量，不是整帧（只有暂停期间换了模式才是整帧；计划的审查重点 5 和任务 14 的测试原来也写错了，已改）；区域大小变化不强制整帧，只有密度变 1% 以上才是；输出缓冲是固定 64 KiB 循环取，不是越长越大；分块样本要带每次调用的输入，不然 Rust 没法重放；`lib.rs` 的模块要按任务逐个声明。
- **最先会撞上的**：
  1. **zlib 输出是不是逐字节相同**。Windows 上 `libz-sys` 用它自己编的 zlib（草稿说是 1.3.x，没核对），Swift 用的是苹果系统的 zlib，两边的输出没比过。探针 C1 本来该先回答这个问题，草稿是在 C1 之前写的。不相同就走计划 B 任务 3 写好的退路（比解压后的字节），任务 5 的切片边界跟着变。
  2. `deflate.rs` 是这个 crate 里唯一有 `unsafe` 的文件：`zalloc`/`zfree` 的指针类型、`deflateCopy`、`Box` 的处理都是凭记忆写的。
  3. Swift 生成器可能过不了类型检查（很长的元组数组字面量、`SenderTrace.init` 里的 `[unowned self]` 闭包）。
  4. 时间和 RTT 是 `f64`，经过 JSON 来回一趟要一位不差。
  5. 样本很大、跑得慢：发送器有 1080p 和 75 秒的轨迹，协议拒收样本有几 MB。
  6. 没有计时器时发送器把每次编码都算 0 毫秒，真实的编码计时那条路没有样本覆盖。
- **先验的顺序**：先让它编过（`cargo check`、`clippy -D warnings`）→ 边界测试 → 生成样本、修生成器 → 协议和 deflate 测试（deflate 的结果决定走不走退路）→ 量化 → 分块（先跑 `decoder_agrees`）→ 节奏。

**规则组：任务 7–12，分支 `feat/windows-host-core-rules`**（说明文件 `docs/superpowers/plans/notes/2026-11-26-windows-b2-draft-notes.md`）

- **写了的**：几何、窗口表、桌面、命中测试、提示（7）；焦点窗格和跟踪器（8）；输入规则和 worker 命令行（9）；剪贴板规则、传输存储、可移植文件名（10）；锁屏和解锁规则（11）；应用状态规则引擎，在 `src/state/` 下八个文件（12）。每组都有 Swift 样本生成器和 Rust 对照测试。`src/` 里没有平台相关写法，取时间只在 `clock.rs`。
- **现在编不过，原因是已知的**：它用的协议类型（`CanvasRect`、`WindowInfo`、`Message`、`APP_STATE_LIMIT` 等）和 `tile::EncodeReport` 在另一个分支上，字段名是照编码组早先的提交猜的。两边对不上的地方第三批合并后改过一遍（见下）。
- **要 Rust 1.89 以上**：`File::lock`（计划 B 指定用它，为了不碰 `libc`）和 `Option::is_none_or`。仓库没有固定工具链版本，Mac 和 Windows 构建机都要先确认版本够。
- **草稿和 Swift 不一样的一处**：`resolve_regions` 收的是区域表，Swift 的 `resolveRegions` 收整个规则包（`Sources/RappCore/StateRules/Regions.swift:5`）。第三批已照 Swift 改回（提交 `a81f1f81`）。
- **计划里错的，已经改回计划 B**（提交 `48b5c6eb`）：`Input` 事件没有字段；找不到程序时的文字按规格 §6.4 写 `<id> not found`；`with_unlock_lock` 多一个 `log` 参数；`RuleImage::sample` 可能返回空；Swift 的 `PutSink` 不自己续传；计划漏列了 `view_region`、`clamp_size`、`shareable_apps`、`apps_text`、`ListedWindow`；`lock_json` 用到的 `LockOutcome` 要在任务 9 就定义。
- **样本测不到的两条上限**：一次最多 100 个文件、图片不超过 64 MiB。这两条在 Swift 的 `rapp-host` 里，不在 `RappCore`，样本生成器调不到。Rust 这边只核对了常量，行为要靠任务 16 的会话测试。
- **最先会撞上的**：
  1. **状态规则的大图是重画出来的**。800×600 和 1600×1000 的画面存不下，样本里只有画法和 SHA-256，Rust 测试用移植的 `RuleCanvas.swift` 重画后比哈希。重画移植错了，所有状态规则测试都会先停在这里，所以先看哈希对不对，再看规则。
  2. **字符串和数字的细节是近似的**：Swift 按字素簇和规范等价比较字符串，Rust 按字节；`isNumber`、`Double` 转字符串的分界点、`"%.1f"` 的舍入、`localizedStandardCompare` 都是照推测写的。样本里只放了几例组合字符，对不上时先怀疑这里。
  3. Swift 遇到溢出会崩，Rust 这边改成了饱和或回绕，不会崩但会给出一个值。
  4. 大文件（`tracker.rs`、`transfers.rs`、`state/*`）里闭包借用和 `json!` 宏多，没编过，借用检查会报一批错。
  5. 任务 12 的 Swift 生成器有几处类型推断可疑（`Any` 字典字面量、`as?` 区分两种字典）。
- **没有样本的场景**：传输测试里靠 `chmod` 造失败的一例（只能在 POSIX 上跑）；状态引擎单次耗时的测试（只移植了场景，没测时间）。

**第三批：任务 13–19，分支 `feat/windows-host-core`**（说明文件 `docs/superpowers/plans/notes/2026-11-26-windows-b3-draft-notes.md`）

- **先做的两件**：把规则组的分支合进来（提交 `aad5c90b`，两组没有改到同一个文件）；改齐两组互相猜错的类型（`a81f1f81`：`resolve_regions` 改回收整个规则包、剪贴板的上限改用协议里的常量、`hints` 里一处消息匹配）。我抽查了 `geometry::Rect`、`EncodeReport`、`WindowInfo`、`CanvasRect`、`APP_STATE_LIMIT` 这几处两边的用法，字段对得上；没有逐个文件查，编译会给出其余的。
- **写了的**：平台接口、入口 `run.rs`、握手和接管、testkit 里的假平台（13）；采集、编码、发送的循环，含暂停、视区、省流（14）；输入、遮挡提示、焦点窗格、状态规则接进会话（15）；剪贴板、粘贴、文件传输（16）；锁屏和解锁（17）；`PORTING.md` 和摘要测试（18）；`fake-host-core` 程序和服务对接测试（19 的步骤 1、2、5）。会话代码在 `rust/host-core/src/session/` 下十一个文件，会话测试在 `rust/testkit/tests/host_session.rs` 和 `host_service.rs`。
- **没做的**：任务 19 步骤 4，用真的 Mac 控制端连 `fake-host-core` 走一遍（五种模式、滚动、打字、粘贴文件），只能手工做；任务 20 收尾；所有“运行”步骤。
- **草稿和 Swift 不一样、接手的人要补或者认下来的**：
  1. **锁着时开始的会话，画布总是按主显示器报**。Swift 会先找这个程序的窗口在哪块屏上（`Server.swift:676-697`）。草稿的平台接口在锁屏时拿不到窗口位置，所以没用上已经移植好的 `locked_start_display`。多显示器的机器上会和 macOS 表现不同。D 段做平台层时，如果 Windows 锁屏下能列出窗口，就给平台接口加这个入口并接上。
  2. **焦点窗格没有控件角色**：起点写成 `-`，选中的写成 `depth<n>`。角色要平台层给，属于 D 段。
  3. `menuPick` 既没处理也没拦（计划说收到后忽略、会话继续）。要确认它确实什么都不改。
  4. 移植了 `lock::StayAwake`，但会话直接调平台的 `stay_awake`，前者没用上，这两处调用也没有测试。
  5. 语言固定取 `en` 或环境变量 `RAPP_LOCALE`。
  6. “目标程序不在最前时复制不通知”这条路径没有测试。
  7. 焦点区的会话测试用 Rust 自己算的期望值，允许差 8 点，不是和 Swift 样本逐值比。
- **计划里错的，已经改回计划 B**（提交 `cdbed67e`）：密码输错后不会再发一次“已锁”（Swift 只在状态变了才发）；鼠标坐标换算用的是“显示器原点 + 窗口左上角 + (x, y)”，不是 `global_point`；状态报告里没有 `os` 字段；超大的规则包在协议解码时就被拒，会话以 `bad data from client: rules too large` 结束；收到不该收的消息时文字是 `unexpected message from client`；`stats` 事件里没有在途帧数。
- **最先会撞上的**：
  1. 借用和类型推断：`session/unlock.rs` 里几个闭包（`is_locked` 被移进另一个闭包、`with_unlock_lock` 的 `FnOnce`/`FnMut` 约束），`run.rs` 里读标准输入那段。
  2. `Cargo.lock` 会变：testkit 加了依赖和一个新程序。照 3.1 第 1 条处理。
  3. 会话测试用 20 倍速的时钟，几处时间窗很紧（输错密码后的 8–10 秒、暂停 2 秒、每 5 毫秒 20 个单位、粘贴后 0.15 秒和 2 秒恢复）。失败时先单独重跑，分清是负载还是逻辑。
  4. `host_service.rs` 对真的服务有四个假定：正好两个程序且 `desktop:` 在前；权限正好是录屏和辅助功能两项为真；`session_start` 带 `name`；`worker_exit` 的原因是 `stdin closed`。对不上先看服务这边实际输出什么。
  5. 比较时类型不一致（`&String` 对 `&str`、`Vec<String>` 对数组）。
- **B 段整体先验的顺序**：
  1. `cargo check -p rapp-host-core --all-targets`，再 `-p rapp-testkit --all-targets`，把编译错误改完，让 `Cargo.lock` 更新。
  2. 生成 Swift 样本：`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`，修生成器。
  3. `cargo test -p rapp-host-core --no-fail-fast`。先看边界测试和 deflate（决定走不走退路），再看其余。
  4. `cargo test -p rapp-testkit --test host_session`，再 `--test host_service`。
  5. `clippy -D warnings`。
  6. 任务 19 步骤 4 的真机走查，然后任务 20。

## 4. 边界

### 4.1 三条模块边界（规格 §5.3，改这些要回来问用户）

1. **`host-core` 不认识操作系统。** 里面没有 `cfg(windows)`、`cfg(unix)`、`target_os`、`libc`、`windows` 系列 crate。操作系统只通过 `platform.rs` 的那组接口进来。`tests/boundary.rs` 守着。
2. **`host-windows` 不产生也不解析协议字节。** 它只实现 `host-core` 的平台接口。
3. **只有 `rapp-svc` 跨登录会话、跨权限启动进程。** 而且只在 `rust/svc-windows/src/elevate.rs` 一个文件里（计划 F）。

### 4.2 不许动的

- `Sources/`（Swift）、`rust/host-linux/`、`rust/client-gtk/`、`rust/hub-ffi/`：不改。Swift 是对照的基准，草稿和它不一致时**以 Swift 为准，改 Rust**。
- 中继（`rust/relay/`）：只批准了两处，都只为让中继的库在 Windows 上编得过：`audit.rs` 里三处 `#[cfg(unix)]`；`admin.rs` 的 unix 代码原样放到 `#[cfg(unix)]` 后面、别的系统给同名替身（用户 2026-11-26 两次同意）。再多要问用户。登录 VPS 也要用户同意。
- 协议：不为 Windows 加消息，不升协议号。控制面只加可选字段，而且只在 Windows 上出现。
- macOS、Linux、iOS 的行为：不变。每条缝都是“加一支”，unix 那一支的代码差异为零；Mac 门禁的命令一个字不改。
- `docs/archives/`：不读不搜。
- 版本号、tag、推送、release、官网部署：归发版 session，功能 session 不碰。

### 4.3 各段之间约好的接口（名字在哪定的，谁在用）

| 接口 | 定在哪 | 谁用 |
|---|---|---|
| 平台接口（采集、输入、窗口、剪贴板、锁屏……的 trait） | 计划 B 任务 13，`host-core/src/platform.rs` | D 实现，B 的假平台实现 |
| worker 命令行、事件、退出码 | 计划 B 任务 9，`host-core/src/cli.rs`；规格 §6.1 | `rapp-service`、D |
| 版本目录的布局、旁边的程序怎么找 | 计划 A（`rapp_net::proc`、`stage-windows.ps1`）；规格 §5.1 | 全部 |
| `rapp-svc` 管道的请求和回答（`Request`、`Status`、`Response`、`client::request`） | 计划 C 任务 7，`svc-windows/src/proto.rs`、`client.rs` | F 实现其中五个请求，G 实现三个并给 `Status` 加三个可选字段、给 `ApplyUpdate` 加 `confirm` |
| 帮手的帧格式（`HELPER_V`、`ToHelper`、`FromHelper`） | 计划 F 任务 4 | `rapp-host` 和 `rapp-host secure-helper` |
| `PlatformCaps`（界面里的平台差别） | 计划 C | C、D、H；界面里 `Platform.isWindows` 的次数不许比现在多 |
| `Switcher`（`rapp-service` 的升级怎么交给 `rapp-svc`） | 计划 G 任务 6 | `rapp-service`；macOS 上是 `None`，原路不变 |
| `install::Item`、`System`（安装时对系统的每一项改动） | 计划 G 任务 2 | 安装、卸载、切换；Inno Setup 脚本里不许有这些 |
| 门禁和打包脚本的名字、日志最后一行 `EXIT=<0\|1>` | 计划 A 任务 8、计划 G 任务 7 | 集成 session、发版 session |

改这张表里任何一个名字或签名：在定它的那份计划里改，并在同一个提交里改用到它的计划。

## 5. 接手以后按这个顺序做

**0. 先读**：规格 §0.2（用户定的十一件事）、§5.3、§19.1；这一份；要做的那一段的计划；那个分支上的说明文件。

**1. `CLAUDE.md` 的四条先加上**（规格 §14.5 第 1–4 条）。**第一行 Windows 代码合并进 main 之前必须做**，否则 Mac 发版 session 会为每一次只动 Windows 的合并发一个 macOS 版。文字要用户点头，给用户看一次再提交。计划 A 任务 1。

**2. 探针**（计划 P），在 Windows 实机上。一级探针先跑（G1、G2、H1、H3、H5、S1、S2、S4、T1、T5、C1）：它们的结果能推翻结构。每个结果写进探针结果文件；和计划假设不一样的，照那份计划开头的表改计划，再动代码。表里写了“回来问用户”的（S1、S2、H1 的退路、I1 的退路）必须问。

**3. A 段草稿（`feat/windows-foundation`）**，在 Mac 上：
   1. `git merge main`；读说明文件。
   2. 重新生成 `Cargo.lock`（`cargo metadata` 或一次 `cargo build`；**不改版本号**）。
   3. `cargo build`、`cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`、`swift test`、`flutter analyze`、`flutter test`。修到全绿。修的时候守住：unix 那一支的行为不变（拿 main 上同一条测试对）。
   4. 到 Windows 机器上：`scripts\check-windows.ps1`（计划 A 任务 8），修到 `EXIT=0`。
   5. 计划 A 每个任务的“实机检查”逐条做，结果写进 `tasks/todo.md`。
   6. 两个门禁都绿了再合并（`merge: …（feat/windows-foundation）`，文字见计划 A）。

**4. B 段草稿**，在 Mac 上：
   1. 两个分支已经合好了，只用 `feat/windows-host-core`。先读 3.2 节和分支上的三个说明文件（`…windows-b1/b2/b3-draft-notes.md`）。
   2. 任务 3（压缩）要先有探针 C1 的结论。
   3. 生成样本：`RAPP_WRITE_FIXTURES=1 swift test`（每个任务里写了各自的 `--filter`），然后不带那个变量再跑一遍（比对方式）。生成器只调用 `Sources/RappCore/` 的代码；Swift 符号在测试里看不到时，照计划 B 任务 2 的办法绕，**不改 Swift 的访问级别**。
   4. `cargo test -p rapp-host-core`。红的地方：以 Swift 为准改 Rust。做不到一个字节不差的，按计划 B“Fixture rules”最后一条处理并写进 `PORTING.md`。
   5. 任务 13–19 的草稿写完了：`cargo test -p rapp-testkit --test host_session`，再 `--test host_service`。然后补 3.2 节“草稿和 Swift 不一样”的七条。
   6. 用真的控制端连 `fake-host-core` 试一次（计划 B 任务 19）。
   7. `host-core` 是共用代码：过完整的 Mac 门禁，合并后照常发 macOS 版。Mac 门禁不能明显变慢（`host-core` 的测试加会话测试 60 秒以内）。

**5. C → D → E → F → G → H**，照计划做。依赖（规格 §17.2）：C 要 A 和探针 G2；D 要 A、B 和 H1、H3、H5；E 要 A 和 T1、T5（界面那一半要 C）；F 要 D（管道协议来自 C）和 S1、S2；G 要 C、F 和 S4、I1；H 要全部。C 和 D 可以两个人同时做。F 段做完要换一个没写这段代码的人审规格 §18.2。

**6. 首发**（计划 H 任务 7）：发之前问用户两件事（`CLAUDE.md` 后两条的文字；现在发不发）。不标 Latest。

## 6. 验证和调试时的规矩

- **草稿和 Swift 不一致**：改 Rust。**草稿和计划不一致**：看 Swift 和规格谁对；计划错了就改计划，写在同一个提交里，并在那一段的说明文件“计划错误”一节记一行。
- **计划留给实现的人定的**（规格 §19.1 第一张单子）：自己定，写进计划。**不留的**（第二张单子，以及 §4.1、§4.2）：停下来问用户。
- **验证过的提交不再带“草稿”字样。** 草稿提交留在历史里不改写；修的提交用平常的标题（`fix(...)`、`test(...)`）。分支上最后一个草稿之后至少要有一个提交写明“在 Mac 上过了门禁”或“在 Windows 上过了门禁”，合并说明里也写。
- 每加一个配置项、环境变量、注册表值、文件，同一个提交里改 `config-reference`。
- 新加的依赖：合并说明里写名字、版本、许可证。
- 日志里绝不出现：密码、PIN、token、密钥、打的字、剪贴板内容。
- Mac 上：`grep` 是 ugrep，用 `/usr/bin/grep`；没有 `timeout`；按路径提交，不用 `git add -A`、不用 `git stash`、不跑 `cargo fmt --all`；flutter 在 `~/development/flutter/bin`，跑完测试把 `pubspec.lock` 还原。

## 7. 计划里我替用户定了、和规格字面不完全一样的地方

接手的人不用再问，但要知道。第 1、2 条用户 2026-11-26 已经点头，规格 §7.5、§12.3 的文字也跟着改了；第 3–5 条是规格留给实现的人定的。

1. **Ctrl+Alt+Del 不提前置灰**（计划 F）。规格 §7.5 写的是“做不到时置灰”。计划里改成：照常能点，被控端发不出去时回 `inputBlocked`（`by = "sas"`），控制端显示“这台电脑现在收不到 Ctrl+Alt+Del”。原因：能不能发要到那一刻才知道（策略随时可能被改）。
2. **升级地址的覆盖两种方式都只从注册表读**（计划 G 决定 4）。规格 §12.3 只对系统服务方式这么要求；计划里用户方式也一样（读 `HKCU`），Windows 上不读 `service.json` 的 `update_url`。原因：一条规则，少一条可以被别的程序改写的路。
3. **静默安装带系统服务时必须给 `/OWNER`**（计划 G 决定 5），不给就失败、什么都不改。
4. **认领机主的时间窗是 10 分钟**（计划 F）。
5. **第一版语音只用默认录音设备；麦克风被关用注册表里的隐私开关加打开失败两头判断**（计划 H 决定 1–2）。

## 8. 还没人做、容易漏的

- Windows 机器、虚拟机快照、集成 session 都还没有（计划 A 任务 1）。
- `update-windows` 这个固定 release 首发时才建（计划 H 任务 7）。
- 规格 §19.2 列的旧文档里的旧话，归做 A 段的人改（计划 A 任务 9），只改文档。
- 规格里的【未验证】要在首发前全部换成探针结果（计划 H 任务 6）。
- 首发以后才做的：`host-linux` 换到 `host-core` 上（U9）、代码签名证书（U4）、虚拟显示器（U3）、arm64。
