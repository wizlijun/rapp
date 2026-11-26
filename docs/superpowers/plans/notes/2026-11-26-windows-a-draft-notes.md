# Windows A 段（地基）草稿笔记

分支 `feat/windows-foundation`（worktree `.worktrees/windows-foundation`），基于 main `7ed6c7e4`；2026-11-27 把 main `c1448855` 合了进来（`a8838b84`，见 §7）。计划：`docs/superpowers/plans/2026-11-26-rapp-windows-a-foundation.md`；规格：`docs/superpowers/specs/2026-11-26-rapp-windows-design.md`。

**这里的代码一行都没编译过，一个测试都没跑过。** 写的人在 Mac 上，规定只写不编。每个提交标题都带“（草稿，未编译未验证）”。下一个人负责编译、验证、调试；先看 §6。

## 1. 每个 Task 写了什么

| Task | 提交 | 状态 | 内容 |
|---|---|---|---|
| 1 | `ef0e9d93` | 部分 | `.gitattributes`（`* -text`）；探针结果页 `docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md` 的骨架（机器、工具、汇总三张表，每个探针一节的模板在 HTML 注释里）。`CLAUDE.md` 没改（见 §2） |
| 2 | `778c9d2e` | 写完 | `rust/host-windows`（bin `rapp-host-windows`，空 lib）、`rust/svc-windows`（bin `rapp-svc`）两个空壳进 workspace；别的系统上打印 “<名字>: 只支持 Windows”，退出码 2 |
| 3 | `0a18dcf5` | 写完 | `rapp-net`：`win.rs`（Windows 的 `unsafe` 只在这里）、`private.rs`（设成私有）、`proc.rs`（`CREATE_NO_WINDOW`）；`datadir`、`config::write_private`、主机名、日志目录、`bins::find`、`quic` 双栈的 Windows 分支 |
| 4 | `34c7efbf` | 写完 | `rapp-service`：`supervise.rs`（`--supervised`、互斥名、升级缓存目录）、Windows 单实例、`UpdateOpts::windows`、`cm.rs` 找 `rapp-gui.exe`、`reset_permissions` 照 Linux、新同步仓库 `core.autocrlf false`、启动程序都走 `rapp_net::proc`；config-reference 三行 |
| 5 | `1cadb684` | 写完 | `rapp-term`：unix 专用的模块挂 `cfg(unix)`，`main.rs` 分派到 `unix_main.rs` / `stub_main.rs`（Windows 上报“不支持文本终端”，退出 1）；四个测试文件 `#![cfg(unix)]`；新 `tests/unsupported.rs` |
| 6 | `656bf1a1` | 写完 | `rapp-cli`：`gui.rs`（`launch_args`、`version_dir_name`、`gui_exe`，各系统都测）；Windows 上先 `console_utf8`，不带子命令时启动 `rapp-gui.exe` 后退出 0 |
| 7 | `61ea0b91`、`b44895ef`、`46873ae7`、`9c662470`、`b4f19477`、`132111ad`、`ddbdc52b` | 写完 | relay `audit.rs` 三处 `cfg(unix)`；relay `admin.rs` 的管理套接字挂 `cfg(unix)`，别的系统上是同名空壳（§4 第 1 条，用户选了 (a)）；换钥匙的八个测试挂 `cfg(unix)`；rapp-state 的权限位只在 unix 上设；余力 `load/disks.rs` 的 Windows 分支（真 bug，规则 4）；七处权限断言加 Windows 访问列表断言；testkit `bins()` 在 Windows 上复制四个程序成 `.exe`；`tasks/todo.md` 新标题「Windows 版：现在在 Windows 上关着的测试」 |
| 8 | `5d1f207c` | 部分 | `rust/.cargo/config.toml`（`+crt-static`，只对 msvc 目标）、`scripts/stage-windows.ps1`、`scripts/check-windows.ps1`。Step 4–6 要 Windows 机器，没做 |
| 9 | `d72c324f` | 部分 | 规格 §19.2 的旧话（16 个文件，最小改动）；`tasks/todo.md` 新标题「Windows 版 A 段（地基）」。完成标记、合并没做 |

## 2. 没写的和原因

### 只能运行才做得了的步骤（全部没做）

- Task 1：Step 1（问用户批准 `CLAUDE.md`）、Step 3（`git add --renormalize .` 核对、合并到 main）、Step 4（装 Windows 机器）、Step 5（记机器）、Step 6（开集成 session）。
- Task 2–8 的每个 “Run/Verify/Expected” 步骤：`cargo check/test/clippy`、`flutter analyze/test` 都没跑。
- Task 3 里手动证伪 `child_has_no_console`（用 `std::process::Command::new` 跑一次应打印 `console=true`）没做。
- Task 4 里 Windows 上“没有 git.exe”时的行为、Git for Windows 认不认 `/dev/null` 没查。
- Task 5 Step 4 的 git 改名检查（另见 §4 第 2 条）。
- Task 7 Step 3、5、6：在 Windows 上跑全部测试、逐个分类、证明门禁。
- Task 8 Step 4（按探针 G1 的结果改 Flutter 构建；探针结果页里 G1 还是空的）、Step 5（证明门禁能绿能红）、Step 6（手看一次）。
- Task 9 Step 3（完成线的证据）、Step 4（合并）；§17.2 的 A 段完成标记要等合并提交，没打。
- `Cargo.lock` 没重新生成（规定不碰）。`rapp-net` 新加了 `windows-sys`、`socket2` 两个 Windows 目标依赖，两个新 crate 进了 workspace，所以第一次 `cargo` 就会改它；`--locked` 会失败。

### `CLAUDE.md` 建议的四处改动（计划 Task 1 Step 1，原文照抄；要先问用户）

**2026-11-27：这四处已经在 main 上了**（`7fdeb32d`，合并 `bf79f733`），合并后本分支的 `CLAUDE.md` 和 main 一样；第 2 条的 Windows 路径写成“等机器装好后填在这里”。下面留作记录。

1. 第 30 行“也不发 macOS 版。”之后加：
   > 只影响 Windows 的改动（`rust/host-windows/`、`rust/svc-windows/`、`gui/windows/`、`scripts/` 里 Windows 的脚本、`cfg(windows)` 里的代码）也不发 macOS 版，但要过门禁并立刻推到 `origin/main`，Windows 机器等着用。只改文档的合并同样立刻推。改到共用代码（`rust/host-core/`、`rapp-service` 这些 crate 里不带 `cfg(windows)` 的部分、共用的 Dart）照常算 macOS 的改动。
2. 第 15 行改成：
   > 2. 完成且自测通过后，**合并到自己这台机器的本机 `main` 即可**（Mac 上是 `/Users/bruce/git/rapp`，Windows 机器上是 `<Windows checkout>`）：
3. “其他 session（做功能的）”下第 22 行之后，新的第 5 条：
   > 5. Windows 相关：改了 `cfg(windows)` 里的代码，要在 Windows 机器上过了 Windows 的门禁（`scripts/check-windows.ps1`）再合并；给协议加被控端行为时，`host-core` 和它的样本在同一个提交里改；改了 `Sources/rapp-host/` 里被 `host-core` 对照表引用的文件，同一个提交里看 `host-core` 要不要跟着改，并更新对照表里的摘要。
4. 文件末尾新的小节：
   > ### Windows 集成 session（首发前）
   >
   > - Windows 机器上常开一个 session：本机 `main` 有新合并，就 `git fetch origin`、合并 `origin/main`、跑 Windows 的门禁、推到 `origin/main`；推被拒就再 fetch、合并、重跑。
   > - 首发前它只是**集成** session：不改版本号、不打 tag、不建 release、不动 `website/releases.json`。要给自己人装，就按需打内部 zip。
   > - 冲突由后推的一方解决；不强推。

`<Windows checkout>` 等 Task 1 Step 4 定了路径再填。另外建议第 1 条里的 “`scripts/` 里 Windows 的脚本” 现在就是 `scripts/check-windows.ps1`、`scripts/stage-windows.ps1` 两个。

## 3. 和计划不一样的地方

- **cli 启动失败多一句话**（Task 6）：计划只写了找不到界面程序时打印 `找不到 rApp 的界面程序（<p>）`。找到了但 `spawn` 失败时，草稿打印 `rApp 的界面程序没有启动（<p>：<错误>）` 并退出 1，而不是照样退出 0（`rust/cli/src/main.rs:61-63`）。
- **rapp-state 和余力的工作盘也改了**（Task 7）：计划写在它们合并之前，没提到。两处都是无条件的 unix 代码，不改 Windows 上整个 workspace 编不过（见 §4 第 3 条）。
  - `services/state/src/disk.rs`：权限位挂 `cfg(unix)`；Windows 上目录靠继承 `<数据根>\local` 的访问列表。
  - `rust/service/src/load/disks.rs`：Windows 的 `mount_of`（按盘符或 `\\server\share\`，名字小写后取哈希，最高位清零，和 `synthetic_dev` 分开）和 `statvfs`（`GetDiskFreeSpaceExW`，文件数报 `None`）。
- **testkit 复制四个程序**（Task 7 Step 2）：计划列了三个；`bins()` 现在有第四个 `rapp-state`，一起复制成 `.exe`。
- **`rapp_net::private::private_acl()` 公开**：别的 crate 的测试要拿它比；原来测试里的 `expected_acl()` 改成调它。
- **workspace 的 `windows-sys` 多开 `Win32_Storage_FileSystem` 特性**：给 `disk_space` 用。特性不进 `Cargo.lock`，不算改版本。
- **`a_stuck_disk_gets_one_thread_not_one_per_read` 改用临时目录**，不再用 `/dev`：任何盘都证明同一件事，macOS / Linux 上照样跑。
- **门禁脚本不加 `--locked`**：`Cargo.lock` 这次没重新生成。重新生成并提交以后可以加上。
- **todo 里关着的测试**：除了计划点名的，还列了 rapp-state 的两个权限测试、余力的三个测试（要两块文件系统或建符号链接），以及 Task 5 关掉的 `rapp-term` 单元测试。
- Task 9：`tasks/todo.md:812`（Windows 用 `app_icon.ico`）本来就对，没改。`config-reference` 的 Windows 路径和 `--supervised` 已由 Task 4 加了，这次只加了 Windows 上“私有”的意思。`port-sharing-design` 的 `.rapp` 后缀那一行写的是“Windows 设计 §11.1 只做 `localhost` 上的共享号，没有安排 `.rapp` 后缀”——这是我读规格得出的，规格里确实没写 `.rapp` 在 Windows 上怎么办。

## 4. 计划里的错（带位置）

1. **只挂 relay `audit.rs` 的三处，relay 的库在 Windows 上还是编不过**（计划 Task 7 Step 1，以及 Task 8 Step 3 只 `--exclude rapp-relay`）。
   - `rust/relay/src/admin.rs:12` 顶层 `use std::os::unix::fs::PermissionsExt;`
   - `admin.rs:25` `use tokio::net::{UnixListener, UnixStream};`，用在 `:69`、`:157`、`:167`、`:172`、`:200`
   - `admin.rs:174`、`:384` `from_mode`；`:373` `.mode()`
   - `--exclude rapp-relay` 不管用：`rust/conn/Cargo.toml:25` 和 `rust/testkit/Cargo.toml:58` 把它当 dev-dependency，`cargo test --workspace` 照样要编它。用到它的测试：`testkit/tests/common/mod.rs`（RelayRig，从 `:478` 起）、`conn/tests/relay.rs`、`testkit/tests/key_change.rs`、`netmon.rs`、`forward.rs`。
   - 不改的话：Windows 上 rapp-conn 和 testkit 的测试全部编不过，`check-windows.ps1` 第 1、2 步必然红。
   - **已定：(a)，只动 `admin.rs`**（用户 2026-11-26 批准；`132111ad`、`ddbdc52b`）。
     - `admin.rs` 里用 Unix 套接字和权限位的部分挂 `#[cfg(unix)]`：常量、`call`、`issue_key`、`Cmd`、`Server` 和它的 `impl`/`Drop`、`connection`、`Handler`、`resolve`、`persist_enroll`，以及只给它们用的 `use`（从合在一起的 `use` 里拆出来单挂）。unix 上的代码没有挪动、改名或改写。
     - 别的系统上的空壳，名字和签名同 unix：`pub fn socket_path`、`pub const SOCKET`、`pub struct NotRunning`（共用，没动）；`pub async fn call(&Path, Value) -> Result<Value>`、`pub async fn issue_key(&Path, bool) -> Result<Option<Key>>`（一律报 `the admin socket is not available on this system (<路径>)`，不是 `NotRunning`）；`pub(crate) struct Server`（单元结构）、`Server::bind(&Path) -> Result<Server>`（成功、什么也不开）、`Server::serve(&mut self, Ctx)`（什么也不做）、空的 `Drop`（让 `server.rs:224` 的 `drop(admin)` 不触发 clippy `drop_non_drop`）。`Control`、`Ctx` 共用，挂 `cfg_attr(not(unix), allow(dead_code))`。
     - `server.rs`、`lib.rs`、`main.rs`、`store.rs` 等没动。`main.rs:215`（`DirBuilderExt::mode`）和 `main.rs:17`（`tokio::signal::unix`）留着：relay 的程序不在 Windows 上编（`--exclude rapp-relay`；dev-dependency 只编库）。
     - 关掉的测试（挂在测试上，不挂整个文件）：`conn/tests/relay.rs` 的 `rotate_key_closes_every_device_with_code_4`、`requests_after_a_key_change_say_key_changed`、`an_open_relayed_stream_says_key_changed_after_a_rotate`；`testkit/tests/key_change.rs` 的 `service_stops_and_says_key_changed_after_rotate`、`a_new_key_reconnects_with_the_same_id`、`a_wrong_new_key_says_bad_key`、`hub_presence_says_key_changed_and_stops_dialing`、`hub_reports_key_changed`。只给它们用的 `CLOSE_KEY_CHANGED`（import）、`rotate`、`audit_events`、`hex` 也挂上；`conn/tests/relay.rs` 的 `Rig.data` 在别的系统上只用来保住临时目录，挂 `allow(dead_code)`。都列进了 `tasks/todo.md`。
     - `relay/tests/` 下的 `admin.rs`、`secrets.rs`、`bench.rs` 也用 `admin::`，没挂：relay 自己的测试在 Windows 上不编（`--exclude rapp-relay`）。
2. **Task 5 Step 4 的改名检查做不到**：计划要 git 把 `unix_main.rs` 认成从 `main.rs` 改名，但 `main.rs` 还在（变成了分派），git 只会显示 `unix_main.rs` 是新加的。检查应改成“`unix_main.rs` 的内容和旧 `main.rs` 只差 `fn main` → `pub fn main`”（`git diff 7ed6c7e4:rust/term/src/main.rs HEAD:rust/term/src/unix_main.rs`）。
3. **计划早于 rapp-state 和余力**：`services/state`（0.15.48 起是 workspace 成员，testkit 的普通依赖）和 `rust/service/src/load/disks.rs`（0.15.47）都是无条件的 unix 代码，计划的 File Map 和 Task 7 都没提到。不改的话 Windows 上 `rapp-service` 和 testkit 都编不过。
4. **计划 Task 7 Step 2 列了三个假程序**，`rust/testkit/tests/common/mod.rs` 的 `bins()` 现在有四个（多 `rapp-state`）。
5. **探针结果页还不存在**（计划 Task 1 的 Files 说“由计划 P Task 1 建，不存在就照它的骨架建”）：这次照 P 的骨架建了。
6. **`.cargo/config.toml` 放在 `rust/` 下，只在从 `rust\` 目录里跑 cargo 时生效**（计划 Task 8 Step 1）。cargo 按当前目录找配置，不按 `--manifest-path`；`scripts/build-linux.sh:27` 那种从仓库根用 `--manifest-path rust/Cargo.toml` 的写法会漏掉它。这次两个脚本都 `cd rust`；G 段打包脚本要照做，或者把配置放到仓库根的 `.cargo/`。
7. **Task 4 的 `Command::new` 检查列得太少**（计划 Task 4 Step 4 “Every place in product code that starts a program” 那一条的最后一句）：grep 除了 `cm.rs` 和测试，还会列出 `data.rs` 的 `xcode-select`（只在 macOS 上跑）、`net/src/config.rs` 的 `hostname`（`cfg(not(windows))` 那一支；Windows 读 `COMPUTERNAME`）、`cli/src/main.rs` 启动界面那一行（在 `cfg(windows)` 里，界面不是控制台程序）。这几处都不该换，计划已改成把它们列全。

## 5. 编译和行为上的风险

按可能性从高到低：

1. **relay `admin.rs` 的空壳**（§4 第 1 条）：
   - Windows 上没有管理套接字挡着，同一个数据目录可以起两个 relay（unix 上第二个在 `bind` 就报 `another relay is using …`）。只影响测试，relay 不在 Windows 上发。
   - 非 unix 上没人调用 `Control` 的方法：已给 trait 挂 `allow(dead_code)`，按 rustc 的规则带 `allow` 的项算活的根，`server.rs` 里只从 `impl Control for Shared` 调到的 `Shared::unbind_id`、`Shared::key_changed`（`server.rs:484`、`:521`）应该不报未用；若 Windows 的 clippy 还是报，只能动 `server.rs`（按规定没碰，要再问）。
   - `Ctx` 的字段在非 unix 上只写不读，已挂 `allow(dead_code)`。
   - 测试里挂掉换钥匙的测试以后，`key_change.rs`、`conn/tests/relay.rs` 还可能剩别的只给它们用的东西没被我看出来，Windows 上的 `-D warnings` 会指出来。
2. **windows-sys 0.61 的签名**（`rust/net/src/win.rs`）：`SetNamedSecurityInfoW` 的路径参数是 `PCWSTR` 还是 `PWSTR`；`EXPLICIT_ACCESS_W` / `TRUSTEE_W` 的字段名和类型（`grfAccessPermissions` 是 `u32`，`grfInheritance` 的类型）；`GetAce`、`GetSecurityDescriptorControl` 的参数；`GetDiskFreeSpaceExW`（`PCWSTR`，三个 `*mut u64`，返回 `BOOL`）；各常量所在的模块和要开的特性。第一次 `cargo check --target x86_64-pc-windows-msvc` 多半要在这里改几处。
   - **2026-11-27 已对过源码**：按本机 cargo 缓存里的 `windows-sys-0.61.2` 源码逐个对了 `win.rs` 用到的函数、结构体字段、常量和它们所在的模块/特性，`socket2-0.6.5` 的 `set_only_v6`、`SockAddr::from`、`into()` 也对过，没发现不合的。只是读，没编译；风险降为“读漏了”。
3. **`Cargo.lock` 没重新生成**：第一次 cargo 会改它；要提交（这是 A 段的依赖变化，不是版本号）。确认用户同意由 A 段提交它。
4. **`UpdateOpts::windows` 里的闭包**（`rust/service/src/lib.rs:148`）：`&|k| std::env::var_os(k).map(Into::into)` 传给 `&dyn Fn(&str) -> Option<PathBuf>`，`k` 的类型和 `Into` 的目标可能推不出来，要写成 `|k: &str| std::env::var_os(k).map(PathBuf::from)`。**已改**（`f628efe7`）。
5. **PowerShell 脚本没跑过**：`check-windows.ps1` 里 5.1 下 `2>&1` 把 stderr 变成错误记录（已用 `"$_"` 取文字，`$ErrorActionPreference = 'Continue'`）；`Step` 用脚本块返回布尔值，若哪个命令往管道里多吐了东西，返回值会变成数组而判成失败。`stage-windows.ps1` 用 `Copy-Item <Release>\* -Recurse` 复制 Flutter 目录。
6. `rapp-state` 在 Windows 上没有自己设私有，靠继承 `<数据根>\local` 的访问列表；有人把 `--data` 指到别处时不私有。
7. Windows 的 `mount_of` 把挂在文件夹上的卷算作那个文件夹所在的盘；网络盘 `GetDiskFreeSpaceExW` 卡住时靠现有的“卡住的盘一条线程”机制兜。
8. `std::fs::rename` 在 Windows 上目标被占用时会失败；`config::write_private` 重试 10 次 × 20 ms，`services/state` 的 `write_bytes` 没重试。
9. Git for Windows 认不认 `core.hooksPath=/dev/null`、`GIT_CONFIG_GLOBAL=/dev/null`（以为会映射到 `nul`，没查）。
10. `rapp-cli` 的 `gui` 模块挂了 `cfg_attr(not(windows), allow(dead_code))`；clippy 在 Windows 上可能还有别的未用项。
11. testkit 的假程序在 Windows 上是复制出来的 `.exe`，它们靠 argv[0] 的上级目录找日志目录（`testkit/src/bin/fake-rapp-host.rs:67`、`fake-rapp-term.rs:36`），复制后照样成立；但复制要在每次 `bins()` 时做，四个文件不小，测试会慢一些。

## 6. 验证的人先做什么（按顺序）

1. 先问用户由 A 段提交 `Cargo.lock`（§2 的 `CLAUDE.md` 四处已在 main 上；§4 第 1 条已定 (a)）。
2. Mac 上：`cd rust && cargo check --workspace --all-targets`，确认 macOS 没变坏，顺带生成 `Cargo.lock`；再跑完整门禁（`swift test`、`cargo test --workspace --no-fail-fast`、clippy `-D warnings`、`flutter analyze`、`flutter test`）。`a_stuck_disk_gets_one_thread_not_one_per_read` 换了临时目录，要看它在 macOS、Linux 上仍然过。
3. Mac 上交叉检查：`rustup target add x86_64-pc-windows-msvc`，`cargo check --workspace --all-targets --target x86_64-pc-windows-msvc --exclude rapp-relay --exclude rapp-host-linux --exclude rapp-client-gtk --exclude rapp-hub-ffi`。不用链接就能先把 §5 第 2、4 条的签名问题改掉（缺 MSVC 的 C 依赖时，个别 crate 可能要到 Windows 机器上才能查）。
4. Windows 机器（Task 1 Step 4）：clone 后 `git ls-files --eol` 没有 `w/crlf`；在 `rust\` 里 `cargo test` 先跑 `-p rapp-net`（`win.rs` 的测试、`private.rs` 的三个测试，含中文带空格的目录），再 `-p rapp-service`、`-p rapp-cli`、`-p rapp-term`。
5. Task 3 的手动证伪：把 `proc::command` 临时换成 `Command::new`，`child_has_no_console` 应失败；改回来。
6. 跑 `scripts\check-windows.ps1`，按 Task 7 的五条规则分类每个失败；关掉的测试照 `tasks/todo.md` 的格式加一行。
7. Task 8 Step 4–6：探针 G1 的结果落到 Flutter 构建上，`check-windows.ps1 -Build` 全绿，再故意弄坏 `rust/cli/src/gui.rs` 一条断言看第 1 步变红、其余照跑、`EXIT=1`；然后手看一次 `bin\rapp.exe --help`、启动界面、双击两次 `rapp-service.exe` 只剩一个。
8. 过一遍 `tasks/todo.md`「Windows 版 A 段（地基）」的六条实机检查，再按计划 Task 9 Step 3–4 收尾、合并。

## 7. 合并 main 和第二轮读查（2026-11-27）

还是只读不编：这一轮也没跑 `cargo`、`flutter`、`swift`、PowerShell。

### 合并（`a8838b84`，main `c1448855`）

- `services/state/src/disk.rs`：main 新加了测试 `an_old_file_without_desks_loads`，留着；`files_are_private` 保持 `#[test] #[cfg(unix)]`。
- `tasks/todo.md`：两边都留，main 新加的小节在前。
- `CLAUDE.md`、`Cargo.lock` 没冲突。

### main 新代码要不要接缝

都不要。看过的：`hub` 的 `lib.rs`、`link.rs`、`services.rs`；`net/src/msg.rs`（`SetService`）；`service` 的 `companion.rs`（serve / answer / ipc）、`peer.rs`、`share_cmds.rs`；`testkit/tests` 的 `common`、`hub`、`hub_terms`、`route`、`set_service`；`services/state` 的 `http`、`store`、`tests`。里面没有新的起程序、私有文件、unix 专用 API、找同级程序或数据/日志目录的地方。

### 改掉的错

| 提交 | 文件 | 改了什么 |
|---|---|---|
| `f628efe7` | `rust/service/src/lib.rs` | §5 第 4 条：`UpdateOpts::windows` 的闭包写成 `\|k: &str\| std::env::var_os(k).map(PathBuf::from)` |
| `40a7db52` | `rust/service/src/main.rs` | 草稿用 `std::env::args().collect()` 取参数：遇到非 UTF-8 的参数会 panic（退出 101），main 原来是报用法、退出 2。改成 `args_os` + `to_string_lossy`，unix 上回到原样 |
| `375bf339` | `rust/conn/src/paired.rs` | `paired.json` 走 `config::write_private`，原来只有 unix 的权限测试；加了 Windows 的访问列表测试 `file_is_private_on_windows` |

### unix 那一支

对 `git diff main` 里每个 Mac 上会编的文件逐个看过。unix 上改到的只有这几类，行为都不变：

- `Command::new` → `rapp_net::proc::command` / `tokio_command`（`hub/src/session.rs`、`service/src/{companion,data,workers}.rs`、`update/src/runner.rs`）：非 Windows 上就是 `Command::new`；tokio 的 `Command::new` 本身就是 `From<std::process::Command>`（tokio 1.54.1 源码）。
- `DirBuilder` / `OpenOptions` 的 `.mode()` 拆成 `cfg(unix)` 的语句（`relay/src/audit.rs`、`services/state/src/disk.rs`、`net/src/config.rs`）：同样的标志、同样的顺序。
- 原样代码外面套 `#[cfg(unix)]` / `#[cfg(not(windows))]`，`cfg(target_os = "linux")` 扩成 `cfg(any(target_os = "linux", windows))`。
- testkit 用 `rapp-host{EXE_SUFFIX}`（unix 上后缀是空的）。
- `rapp-term` 的 `main.rs` 拆成分派 + `unix_main.rs`（和原 `main.rs` 只差 `pub fn main`）。
- `rapp-service` 的参数：unix 上 `parse_args(.., false)` 有任何参数就返回原来那句用法，退出 2；`stopped()` 的 unix 一支没动。
- `load/disks.rs` 的 `a_stuck_disk_gets_one_thread_not_one_per_read` 从 `/dev` 换成临时目录（§3），这是唯一改了 unix 上测试内容的地方，要在 macOS、Linux 上跑过才算数。

没看出不确定的。

### 还剩的风险

§5 的第 1、3、5–11 条照旧；第 2 条只剩“读漏了”；第 4 条已改。

