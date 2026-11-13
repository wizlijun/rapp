# rapp 数据目录（`~/rapp`，文字进 git）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rapp 的所有数据放进一个根目录（默认 `~/rapp`，可用 `RAPP_HOME` 或指针文件改）：`shared/`、`devices/<id>/`、`agent/`、`clipboard/` 进 git，`files/`（收发的文件、钉住的图片和文件）和 `local/`（口令、程序状态）不进；旧配置只复制不删；rapp-service 每分钟合成一次提交，用户加了 remote 就 pull/push；GUI 设置页有「数据目录」一节（路径、打开、git 状态、更改位置、改回默认）；钉住的剪贴板条目写盘、下次启动读回。

**Architecture:** 路径规则有三份同样的实现：Rust `rapp_net::config`（service、hub）、Dart `gui/lib/paths.dart`（GUI）、Swift `RappCore.DataPaths`（只算收发目录）。建目录和搬家在 Rust `rapp_net::datadir::prepare` 和 Dart `prepareDataDir` 各一份，规则相同、模板文字以 Rust 那份文件为准（Dart 测试逐字比对）。service 和 hub 的 `Opts.home` 改成传 `<根>/local`，所以 `service.json`、`ipc.token`、`update*.json`、`previous/`、`hosts.json` 等不改代码就落进 `local/`；git 只在 rapp-service 里（新模块 `rust/service/src/data.rs`，调系统的 `git` 命令）。钉住的条目由 runner（Swift `ClipCopies`）写盘/读回，Dart 管文件名、列目录、删文件。

**Tech Stack:** Rust（rapp-net、rapp-service、rapp-hub、testkit，tokio），Swift 5.9（RappCore、RappSession、rapp-host、`gui/macos/Runner`），Flutter 3.44（macOS/Linux 桌面，Dart），系统 `git`（≥ 2.28，用 `init -b`）。

**Spec:** `docs/superpowers/specs/2026-11-13-rapp-data-dir-design.md`（已确认，以 commit c4ccbe1 为准，含 D12「根目录用户可以改」）；要跟着改的《配置规范总览》`docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（§0.4、§1–§3、§6，Task 13）。

**范围外：** `files/` 的同步（D8，第一版不做）；Linux GTK 客户端（`rust/client-gtk`，不在测试范围）的下载目录；Windows 的 GUI（路径规则照写、测试覆盖，但「更改位置…」在 Windows 上不显示）；替用户建远端、存远端口令（§4）。

**和 app 配置计划的关系：** `docs/superpowers/plans/2026-11-13-rapp-app-profiles.md` 停在 Task 3 之后；它的 Task 4 起读写 `apps.json`。本计划 Task 8 之后，那边的 `AppProfileStore.load(dir, …)` 一律传 `state.data.sharedDir`（即 `<根>/shared/apps.json`），不再用旧的 `configDir`。

## 裁定（规格没写死、我定的）

| # | 裁定 | 理由 | 错了的代价 |
|---|---|---|---|
| R1 | service 和 hub 的 `Opts.home` 继续叫 `home`，意思变成「本机私有目录」，`main.rs` 传 `config::local(&root)`。于是 `ipc.token`、`previous/`、`last-dr` 也进 `local/`（规格没列，但都是本机的、`ipc.token` 是机密） | 改动最小，所有 `home.join(…)` 自动落到 `local/`；testkit 照传临时目录，不用改 | 无 |
| R2 | 搬家的「旧配置目录」：设了 `RAPP_HOME` 时就是 `$RAPP_HOME` 本身（旧版平铺在那里），否则是平台旧目录（规格 §2）。`$RAPP_HOME/service.json` → `$RAPP_HOME/local/service.json`，平铺的旧文件原样留着 | 设了 `RAPP_HOME` 的老用户（和 e2e 脚本）也要能搬 | 无 |
| R3 | `.gitignore` 用白名单：`/*` 后只放行 `.gitignore`、`README.md`、`shared/`、`devices/`、`agent/`、`clipboard/`，再写 `files/`、`local/`、`*.tmp`、`*.bad`。规格 D3 写的是「`files/  local/`」，白名单是它的超集 | R2 让根目录上可能平铺着旧的 `service.json`、`hosts.json`；用户也可能往根上丢文件。黑名单挡不住，口令进了 git 历史收不回（D4） | 用户想让根上别的文件进 git 要自己改 `.gitignore` |
| R4 | 搬家时 `service.json` **最后**复制；`prepare` 出错时 service 和 hub 都以退出码 1 退出（不带着半套配置启动） | `local/service.json` 在 = 搬完了；搬到一半就启动会让 `Config::load_or_init` 生成新 id 和口令，设备身份就变了 | launchd 会一直重启失败的 service，错误在 `launchd.log` |
| R5 | `previous/`（升级回滚用的旧版 app）不复制。升级到这一版后的第一次，「回到上一版」不出现（`can_rollback` 在 `previous/rapp.app` 不在时本来就是 false） | 规格 §2 的表没列；复制 `.app` 要处理符号链接，不值得 | 只这一次升级不能一键回滚 |
| R6 | 指针文件 `<平台旧目录>/data-root`：取第一行、去首尾空白；不是绝对路径（`/` 开头，Windows 是 `X:\` 或 `\\`）就当没有。设了 `RAPP_HOME` 时不读指针。环境变量为空串 = 没设（三份实现一致；原来 Rust 的 `home()` 把空串当设了） | 手改写坏了不该把数据写到当前目录里 | 无 |
| R7 | 指针指向的位置不在了（外接盘没插）：照样用它；建目录失败 → service/hub 退出（R4），GUI 的「数据目录」一节照样显示这个路径和「改回默认」 | 悄悄退回 `~/rapp` 会分出两份数据 | 盘没插时 rapp 起不来，要用户改回或插盘 |
| R8 | 「改动后 60 秒内合成一次提交」= 每 `commit_every`（60 秒）看一次 `git status --porcelain`，有改动就 `git add -A` + `git commit`。不用文件监视 | 不加依赖；一分钟一次 `git status` 很便宜；自然合并 | 最长 60 秒才提交 |
| R9 | 提交作者：`-c user.name=rapp -c user.email=<设备名>`（`git log --format='%an <%ae>'` 正好是规格的 `rapp <设备名>`）；设备名去掉 `<`、`>`、换行，空就写 `rapp`。另加 `-c commit.gpgsign=false`；子进程去掉 `GIT_DIR`、`GIT_WORK_TREE`、`GIT_INDEX_FILE`、`GIT_AUTHOR_*`、`GIT_COMMITTER_*`，设 `GIT_TERMINAL_PROMPT=0`，stdin 为空，每条 git 命令最多 120 秒。提交说明 `自动保存（<设备名>）` | 用户的 git 配置（签名、环境变量）不能让 service 卡住或提交到别处 | 无 |
| R10 | 「`git pull --rebase` + `git push`」实现为：remote 取 `git remote` 里的 `origin`，没有就取第一个；分支 = `git symbolic-ref --short HEAD`；`git fetch <r>` → 远端分支在就 `git rebase <r>/<b>`（失败 → `git rebase --abort`，算冲突）→ `git push <r> HEAD:refs/heads/<b>`。仓库用 `git init -b main` 建 | 和 pull --rebase 等价，但远端是空仓库（第一次推）时不报错，冲突和网络错能分开 | 无 |
| R11 | 冲突后：本机照常每分钟提交，pull/push 停到 rapp-service 下次启动（启动时再试一次）。网络等其他错 → 状态 `error`，下一轮照常再试 | 规格「停同步」；用户手工解完冲突后重启 service（或改位置、升级）就恢复 | 手工解完要等重启 |
| R12 | `local/sync.json`：`{"git": "missing"\|"local"\|"synced"\|"conflict"\|"error", "last_commit": RFC 3339 或 null, "last_sync": RFC 3339 或 null, "error": 字符串或 null}`。`error` 是 git stderr 的最后一行、去掉 URL 里的 `用户:口令@`、截到 200 字。GUI 直接读这个文件 | 规格 §1 | 无 |
| R13 | 日志只记 `data_commit {"files": N}` 和 `data_sync {"ok": bool, "step": "fetch"\|"rebase"\|"push", "code": 退出码}`，**不记 git 的输出**（冲突的输出里有 `clipboard/<时间>-<短标题>.md` 这类文件名，等于剪贴板标题） | 可观测性规格：不记剪贴板内容和标题 | 排查要看 `sync.json` |
| R14 | GUI 的 git 状态文字：`missing` →「没装 git，文字没有版本记录」；`local` →「只在本机」；`synced` →「已同步 HH:MM」（`last_sync` 换成本地时间）；`conflict` →「同步有冲突，需要手工处理」；`error` →「同步没成功：<error>」；文件没有/读不出 →「还没有版本记录」 | 规格 §3 给了前四种；`error` 和没文件是规格没写到的状态 | 改一张表 |
| R15 | 「更改位置…」：新位置**等于**当前根 →「已经是这个位置」；新位置在当前根里面或包着它 →「新位置不能在当前数据目录里面，也不能包着它」；新位置有 `README.md` 且第一行是 `# rapp 数据目录` → 直接用（不复制）；不存在或空文件夹 → `cp -Rp <旧根>/. <新根>`（保留 0600/0700 和 `.git`）；别的 →「这个文件夹里已经有别的东西，选一个空文件夹」。动手前弹确认，正文按「复制」或「直接用」两种写（见 Task 10），都写「会重启服务，正在连着的会话会断一次」 | 规格 D12；「直接用」可能是一份旧的（比如改回默认时 `~/rapp` 是上次留下的），用户得在动手前知道不会复制 | 无 |
| R16 | 「改回默认」= 同一流程，新位置是 `~/rapp`，最后删指针而不是写指针。设了 `RAPP_HOME` 时两个按钮都不显示，换成一行「位置由环境变量 RAPP_HOME 决定」 | 规格 D12；`RAPP_HOME` 优先于指针，写指针没用 | 无 |
| R17 | 改位置后：写/删指针 → `ServiceController.run(ServiceAction.restart)`（测试里换成假的）→ hub 新命令 `set_home {"dir": <新根>/local}`（重读 `hosts.json`）→ `MainState.relocate(DataDir(新根))`（以后的读写都去新根，`workspace.json` 从新根重读）。hub 和 GUI 不重启 | 规格只说重启 service；hub 和 GUI 还拿着旧路径的话，之后加的设备、改的常用会写进旧根，下次启动就丢了 | 多一个 hub 命令 |
| R18 | 钉住条目的文件名：`<yyyyMMdd-HHmmss>-<短标题>` + 扩展名，时间是本地时间。短标题：标题去掉控制字符和 `/ \ : * ? " < > |`、去首尾空白和开头的 `.`，取前 20 个字（按 rune）；空的用 `kindWord(kind)`（文字/图片/文件/数据）。文字 → `clipboard/<名>.md`（内容就是原文）；图片 → `files/clipboard/<名>.png`；数据 → `files/clipboard/<名>.<UTI 的扩展名，没有就 bin>`；文件 → 文件夹 `files/clipboard/<名>/`，里面是那些文件的副本。重名时 runner 加 `-2`、`-3`… | 规格 §1 | 无 |
| R19 | 启动时读回 `clipboard/` **和** `files/clipboard/`（规格 §3 只写了 `clipboard/`；图片和文件也是钉住的，只读文字会让它们重启后消失、文件却留着）。读回的钉住条目：`source` 是「之前固定的」，`ended = true`（不能「插入」，能「复制到本机」「取消固定」）；标题取文件名去掉时间前缀和扩展名；时间取文件名里的时间。取消固定 → 删那个文件/文件夹 | 规格 §3「读回来当钉住的条目」；它不属于任何正在跑的会话 | 无 |
| R20 | 「提示一次」：第一次固定成功时 `hint` =「固定的条目存进了数据目录；文字会进 git 历史，取消固定只删文件，历史里还在」，然后写标记 `local/pin-hint-shown`（照 `permission-guide-shown`） | 规格 D5；界面上的按钮叫「固定」 | 无 |
| R21 | Linux 端口（`LinuxSessionPort`，副本只有文字、存在 Dart 里）自己实现 `pin_save`/`pin_load`，只认文字（`.md`）；其他种类回 null，照旧只在内存里 | Linux 的副本本来就只有文字 | 无 |
| R22 | 设备 id：GUI 每次要用时读 `local/service.json` 的 `id`（`DataDir.deviceId()`）。读不到（service 还没跑过）时界面偏好照默认、不写盘 | id 只由 service 生成 | 第一次启动极少数情况下主题选择不记住 |
| R23 | `devices/<id>/device.json` 由 service 每次启动写（内容 `{"id","name","os","version"}`，`os` 用 `std::env::consts::OS`），内容没变就不写 | 规格 §1；不变不写 = 不白提交 | 无 |
| R24 | README 和 `agent/README.md`、`.gitignore` 的原文放在 `rust/net/src/datadir/` 三个文件里，Rust 用 `include_str!`；Dart 里是同样的常量，Dart 测试读 `../rust/net/src/datadir/*` 逐字比对 | 规格 §3「同一段逻辑」：谁先启动谁写，内容必须一样 | 改文字要改两处（测试会提醒） |
| R25 | 《配置规范总览》§0.4、§1–§3、§6 在 Task 13 一次改完，而不是每个 Task 各改一行 | 位置是一起变的；中间的提交里文档和代码对不上只持续到 Task 13 | 中间几个提交违反总览 §9 |

## Global Constraints

- **测试只用临时目录。** 所有测试用临时 `RAPP_HOME`（或直接传临时根目录）和临时目录；**不准**读写真实的 `~/rapp`、`~/Library/Application Support/rapp`、`~/Library/Logs/rapp`、`~/Downloads/rapp`。Rust 测试用 `tempfile::tempdir()` 并把路径函数的环境作为参数传入（照 `log_dir_from`），不改进程环境变量；Dart 测试用 `Directory.systemTemp.createTempSync()`，环境用 Map 传；Swift 测试用 `FileManager.default.temporaryDirectory` 下的新目录。
- **git 测试：** remote 只用临时目录里的裸仓库（`git init --bare -b main`），不用网络 remote（唯一例外：Task 4 的推送失败测试用 `https://user:s3cret@127.0.0.1:9/x.git`，本机回环、马上被拒）。测试自己跑的 git 命令一律带 `GIT_CONFIG_GLOBAL=/dev/null`、`GIT_CONFIG_NOSYSTEM=1`、`GIT_AUTHOR_NAME/EMAIL`、`GIT_COMMITTER_NAME/EMAIL`；被测代码通过 `DataOpts.git_env` 拿到 `GIT_CONFIG_GLOBAL=/dev/null` 和 `GIT_CONFIG_NOSYSTEM=1`。用户的 git 配置一个字都不改，不跑 `git config --global`。
- **机密不进被跟踪的路径：** `service.json`、`hosts.json`（以及 `ipc.token`）只在 `local/`；任何进 git 的目录（`shared/`、`devices/`、`agent/`、`clipboard/`）里都不写口令、key、secret、token。`device.json` 没有口令和地址。
- **日志** 不记剪贴板内容和标题（包括钉住条目的文件名），不记带口令的远端 URL，不记 git 的输出（R13）。
- **搬家只复制**：不删、不移动、不改旧目录里的任何文件；`~/Downloads/rapp` 里的文件不搬。唯一会删的是：取消固定时删这个条目的文件（规格 D5）、「改回默认」删指针文件（规格 D12）。
- **不启动** GUI 或任何 app；不碰 `/Applications/rapp.app`、正在跑的 rapp-service、`launchctl`、钥匙串、系统剪贴板。「重启服务」在产品代码里走 `ServiceController`，测试一律注入假的。只结束自己起的进程（按 PID），不准 `pkill`/`killall`。不用端口 47800、21116–21119。
- **git 操作（仓库本身）：** 只按文件名 stage，不准 `git add -u/-A/.`；不准 `git stash`、`checkout`、`restore`、`reset`，唯一例外是 `git checkout -- gui/pubspec.lock`（Flutter 会改它，永不提交）。不 push。
- **不碰的文件：** 规格 `2026-11-13-rapp-data-dir-design.md`、`README.md`、`docs/superpowers/specs/2026-11-12-rapp-design-language.md`、`docs/archives/`、`Claude outputs/` 和所有未跟踪的文件。《配置规范总览》只在 Task 13 改。
- 不加额外的加密或审批（relay 是唯一的门禁）。不跑 `cargo fmt`；新建 Rust 文件只用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。
- 界面文字只用中文短句，原文见各 Task 和 R14/R15/R20。
- 提交尾行：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。用户同时在改仓库，`git status` 里的 `M README.md` 等不是你的。

**测试命令：**
- Rust：`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace --exclude rapp-client-gtk && cargo clippy --workspace --exclude rapp-client-gtk --all-targets -- -D warnings`
- Swift：仓库根目录 `swift test`
- runner 编译（Task 6、11）：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（只编译，不启动）
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test --timeout 60s`，然后 `git checkout -- gui/pubspec.lock`

## Review Focus

1. **口令被提交进 git**：设了 `RAPP_HOME` 的老用户根目录上平铺着旧的 `service.json`/`hosts.json`（R2 只复制不删），或者用户往根上丢了文件；`git add -A` 不能把它们带进去。测试：Task 2 `gitignore_keeps_secrets_and_binaries_out`；Task 3 `ignored_paths_never_get_committed`。
2. **用户自己的 git 配置/环境让 service 卡住或失败**：全局开了 `commit.gpgsign`、`gpg.program` 指向不存在的程序、远端要口令（会弹提示卡住）。测试：Task 3 `commit_ignores_the_users_signing_config`；Task 4 `a_failed_push_is_an_error_and_keeps_the_commit`（`GIT_TERMINAL_PROMPT=0` 下不卡）。
3. **service、hub、GUI 同时第一次启动**：三方同时搬家，不能互相盖掉、不能有半个文件、不能生成新的设备 id；第二次是空操作；本机已有的新文件不被旧文件盖。测试：Task 2 `second_run_is_a_no_op`、`never_overwrites_an_existing_file`、`a_failed_copy_leaves_no_service_json`；Task 7 同名的 Dart 测试。
4. **改位置选错文件夹**：选了当前根里面的文件夹、包着当前根的文件夹（比如家目录）、非空的别的文件夹、或改回默认时 `~/rapp` 里是一份旧数据。测试：Task 10 `refuses a folder inside or around the current root`、`refuses a non-empty folder that is not rapp's`、`adopting says so before doing anything`。
5. **冲突或网络失败把仓库留在半途**：rebase 失败必须 `--abort`，本机的提交还在，之后照常本机提交；`sync.json` 和日志里没有远端口令和剪贴板标题。测试：Task 4 `conflict_aborts_the_rebase_and_stops_syncing`、`logs_carry_no_file_names`。

---

### Task 1: Rust 路径规则（根目录、指针、子目录、日志目录）

**Files:**
- Modify: `rust/net/src/config.rs:1-22`（`home()` 及新函数；同文件 tests）
- Modify: `rust/net/src/log.rs:236-256`（`log_dir_from`）、`:461-468`（测试）

**Interfaces:**
- Produces（`rapp_net::config`）：
  - `pub const POINTER_FILE: &str = "data-root";`
  - `pub fn home() -> PathBuf` —— 数据根目录：`home_from(&env_var, std::env::consts::OS, &read_text)`。
  - `pub fn home_from(var: &dyn Fn(&str) -> Option<OsString>, os: &str, read: &dyn Fn(&Path) -> Option<String>) -> PathBuf` —— `RAPP_HOME` → 指针（R6）→ `$HOME/rapp`（Windows `%USERPROFILE%\rapp`）。
  - `pub fn platform_config_dir_from(var: &dyn Fn(&str) -> Option<OsString>, os: &str) -> PathBuf` —— 旧的平台目录（macOS `~/Library/Application Support/rapp`，Linux `$XDG_CONFIG_HOME/rapp` 默认 `~/.config/rapp`，Windows `%APPDATA%\rapp`），不看 `RAPP_HOME`。
  - `pub fn legacy_dir() -> PathBuf` / `pub fn legacy_dir_from(var, os) -> PathBuf` —— 搬家的来源（R2）：`RAPP_HOME`，否则平台旧目录。
  - `pub fn pointer_file() -> PathBuf` —— `platform_config_dir()/data-root`。
  - `pub fn local(root: &Path) -> PathBuf`、`shared(root)`、`device(root: &Path, id: &str)`（`devices/<id>`）、`files(root)`。
  - `os` 取 `"macos"`、`"linux"`、`"windows"`（`std::env::consts::OS` 的值），其他按 linux。空串环境变量 = 没设（R6）。
- `rapp_net::log::log_dir_from`：`RAPP_HOME` 那一档改成 `$RAPP_HOME/local/logs`（D10），其余不变。

- [ ] **Step 1: 写失败的测试**（`config.rs` tests，`env(&[(k, v)])` 返回闭包，照 `log.rs` 测试的写法）

```rust
#[test]
fn data_root_rapp_home_then_pointer_then_home_rapp() {
    let none = |_: &Path| None;
    let ptr_at = PathBuf::from("/Users/u/Library/Application Support/rapp/data-root");
    let ptr = |p: &Path| (p == ptr_at).then(|| "/Volumes/D/rapp\n".to_string());
    assert_eq!(home_from(&env(&[("RAPP_HOME", "/h"), ("HOME", "/Users/u")]), "macos", &ptr), PathBuf::from("/h"));
    assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &ptr), PathBuf::from("/Volumes/D/rapp"));
    assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &none), PathBuf::from("/Users/u/rapp"));
    assert_eq!(home_from(&env(&[("RAPP_HOME", ""), ("HOME", "/Users/u")]), "macos", &none), PathBuf::from("/Users/u/rapp"));
}

#[test]
fn a_bad_pointer_is_ignored() {
    for text in ["", "  \n", "rapp\n", "~/x"] {
        let read = |_: &Path| Some(text.to_string());
        assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &read), PathBuf::from("/Users/u/rapp"), "{text:?}");
    }
    let read = |_: &Path| Some("/a/b\nextra\n".to_string());
    assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &read), PathBuf::from("/a/b"));
}

#[test]
fn three_systems() {
    let none = |_: &Path| None;
    let lin = env(&[("HOME", "/home/u"), ("XDG_CONFIG_HOME", "/xdg")]);
    assert_eq!(home_from(&lin, "linux", &none), PathBuf::from("/home/u/rapp"));
    assert_eq!(platform_config_dir_from(&lin, "linux"), PathBuf::from("/xdg/rapp"));
    assert_eq!(platform_config_dir_from(&env(&[("HOME", "/home/u")]), "linux"), PathBuf::from("/home/u/.config/rapp"));
    let win = env(&[("USERPROFILE", r"C:\Users\u"), ("APPDATA", r"C:\R")]);
    assert_eq!(home_from(&win, "windows", &none), PathBuf::from(r"C:\Users\u").join("rapp"));
    assert_eq!(platform_config_dir_from(&win, "windows"), PathBuf::from(r"C:\R").join("rapp"));
    let read = |p: &Path| (p == PathBuf::from(r"C:\R").join("rapp").join("data-root")).then(|| r"D:\rapp".to_string());
    assert_eq!(home_from(&win, "windows", &read), PathBuf::from(r"D:\rapp"));
}

#[test]
fn legacy_dir_is_rapp_home_or_the_old_config_dir() {
    assert_eq!(legacy_dir_from(&env(&[("RAPP_HOME", "/h"), ("HOME", "/Users/u")]), "macos"), PathBuf::from("/h"));
    assert_eq!(legacy_dir_from(&env(&[("HOME", "/Users/u")]), "macos"), PathBuf::from("/Users/u/Library/Application Support/rapp"));
}

#[test]
fn sub_dirs() {
    let r = Path::new("/r");
    assert_eq!((local(r), shared(r), device(r, "123456789"), files(r)),
        (PathBuf::from("/r/local"), PathBuf::from("/r/shared"), PathBuf::from("/r/devices/123456789"), PathBuf::from("/r/files")));
}
```

`log.rs` 的 `log_dir_prefers_rapp_log_dir_then_rapp_home` 里 `/h/logs` 两处改成 `/h/local/logs`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test -p rapp-net config:: log::tests::log_dir`
Expected: 编译失败（`home_from` 等未定义），`log_dir` 测试断言失败。

- [ ] **Step 3: 实现** 上面 Interfaces 里的函数；`home()` 的 `read` 用 `std::fs::read_to_string(p).ok()`。`rust/service/src/main.rs:1,11`、`rust/hub/src/main.rs:2,11` 的注释和 usage 里「config dir」改成「data root（`$RAPP_HOME`、`data-root` 指针或 `~/rapp`）」。

- [ ] **Step 4: 跑测试，确认通过**

Run: 同上，再跑全套 Rust 测试和 clippy（Global Constraints）。
Expected: PASS，clippy 无警告。

- [ ] **Step 5: 提交**

```bash
git add rust/net/src/config.rs rust/net/src/log.rs rust/service/src/main.rs rust/hub/src/main.rs
git commit -m "net: data root ~/rapp with RAPP_HOME and data-root pointer; logs under local/"
```

---

### Task 2: 建目录和搬家（Rust），service/hub 改用 `local/`

**Files:**
- Create: `rust/net/src/datadir.rs`、`rust/net/src/datadir/README.md`、`rust/net/src/datadir/agent-README.md`、`rust/net/src/datadir/gitignore`
- Modify: `rust/net/src/lib.rs`（`pub mod datadir;`）、`rust/service/src/main.rs:14-16`、`rust/hub/src/main.rs:14-16`、`scripts/e2e-local.py:122-144`

**Interfaces:**
- Consumes: Task 1 的 `config::{home, legacy_dir, local, shared, device, files}`、`config::write_private`、`config::read_json`。
- Produces（`rapp_net::datadir`）：
  - `pub const README: &str = include_str!("datadir/README.md");`、`pub const AGENT_README: &str`、`pub const GITIGNORE: &str`
  - `pub const README_MARKER: &str = "# rapp 数据目录";`（README 的第一行；Task 10 用它认 rapp 的目录）
  - `pub const MIGRATED_FROM: &str = "migrated-from";`
  - `pub fn prepare(root: &Path, legacy: &Path) -> anyhow::Result<bool>` —— 返回这次是否搬了家。步骤：建 `shared/`、`devices/`、`agent/`、`clipboard/`、`files/transfers/`、`files/clipboard/`、`local/`（unix 下 `local/` 0700）；`README.md`、`.gitignore`、`agent/README.md` 不存在才写；`local/service.json` 不在且 `legacy/service.json` 在 → 按规格 §2 的表复制（目标已存在的跳过，`gui.json` 的 `<id>` 取旧 `service.json` 的 `id`，没有 id 就不复制 `gui.json`）→ 写 `local/migrated-from`（内容是 `legacy` 的路径加换行）→ **最后**复制 `service.json`（R4）。复制用 `write_private`（0600，临时文件 + 改名）。不复制 `ipc.token`、`previous/`、`logs/`、`last-dr`（R1、R5）。

模板内容（R3、R24）：
- `gitignore` 逐字：

```
# rapp 写的。只有下面放行的进 git（数据目录规格 D2、D3）
/*
!/.gitignore
!/README.md
!/shared/
!/devices/
!/agent/
!/clipboard/
files/
local/
*.tmp
*.bad
```

- `README.md` 第一行是 `# rapp 数据目录`，接着用中文短句写：每个子目录是什么（规格 §1 的树）；进 git 的和不进的（D2、D3）；机密只在 `local/`、不会进 git（D4）；二进制在 `files/`，可以用 Syncthing、iCloud 云盘、坚果云等文件夹同步工具指向 `files`（D8）；要同步文字就自己 `git remote add origin <地址>`，rapp 每分钟提交、有 remote 就推拉（D6、D7）；第二台设备先 `git clone <地址> ~/rapp` 再启动 rapp；日志不在这里，在 `~/Library/Logs/rapp`（D10）；取消固定只删文件、git 历史里还在（D5）；位置可以在 rapp 设置页「数据目录」里改（D12）。
- `agent-README.md`：两三句：这里放 agent 的上下文，内容归用户和 agent，rapp 不动；改 rapp 的配置前先读 rapp 仓库里的《配置规范总览》`docs/superpowers/specs/2026-11-13-rapp-config-reference.md`。

- [ ] **Step 1: 写失败的测试**（`datadir.rs` tests，全在 `tempfile::tempdir()` 里；`legacy` 和 `root` 是同一个 tempdir 下的两个子目录，R2 那条除外）

```rust
#[test]
fn fresh_root_gets_the_layout() {
    let (t, root, legacy) = dirs();
    assert!(!prepare(&root, &legacy).unwrap());
    for d in ["shared", "devices", "agent", "clipboard", "files/transfers", "files/clipboard", "local"] {
        assert!(root.join(d).is_dir(), "{d}");
    }
    assert!(std::fs::read_to_string(root.join("README.md")).unwrap().starts_with(README_MARKER));
    assert_eq!(std::fs::read_to_string(root.join(".gitignore")).unwrap(), GITIGNORE);
    assert_eq!(std::fs::read_to_string(root.join("agent/README.md")).unwrap(), AGENT_README);
    #[cfg(unix)]
    assert_eq!(mode(&root.join("local")), 0o700);
}

#[test]
fn existing_texts_are_kept() { /* README.md = "mine" 先写好 → prepare 后仍是 "mine" */ }

#[test]
fn migrates_by_the_table_and_copies_only() {
    // legacy: service.json {"id":"123456789",...}, hosts.json, update.json, update-applied.json,
    // workspace.json, apps.json, gui.json, permission-guide-shown, ipc.token, previous/rapp.app/x
    assert!(prepare(&root, &legacy).unwrap());
    for (old, new) in [("service.json", "local/service.json"), ("hosts.json", "local/hosts.json"),
        ("update.json", "local/update.json"), ("update-applied.json", "local/update-applied.json"),
        ("permission-guide-shown", "local/permission-guide-shown"), ("workspace.json", "shared/workspace.json"),
        ("apps.json", "shared/apps.json"), ("gui.json", "devices/123456789/gui.json")] {
        assert_eq!(read(&legacy.join(old)), read(&root.join(new)), "{new}");
        assert!(legacy.join(old).exists(), "old {old} kept");
    }
    assert!(!root.join("local/ipc.token").exists() && !root.join("local/previous").exists());
    assert_eq!(std::fs::read_to_string(root.join("local/migrated-from")).unwrap().trim(), legacy.to_str().unwrap());
    #[cfg(unix)]
    assert_eq!(mode(&root.join("local/service.json")), 0o600);
}

#[test]
fn second_run_is_a_no_op() { /* 搬完后改 shared/workspace.json → 再 prepare 返回 false，内容不变 */ }

#[test]
fn never_overwrites_an_existing_file() { /* local/hosts.json 已有（没有 local/service.json）→ 搬家后 hosts.json 仍是本地那份 */ }

#[test]
fn rapp_home_flat_layout_migrates_into_local() {
    // root == legacy：root/service.json 平铺 → 复制到 root/local/service.json，root/service.json 还在
}

#[test]
fn no_legacy_service_json_no_migration() { /* legacy 只有 workspace.json → false，shared/workspace.json 不存在 */ }

#[cfg(unix)]
#[test]
fn a_failed_copy_leaves_no_service_json() {
    // legacy/hosts.json chmod 000（以 root 身份跑时跳过）→ prepare 返回 Err，root/local/service.json 不存在
}

#[test]
fn gitignore_keeps_secrets_and_binaries_out() {
    // 没装 git 就 eprintln 后 return。git 命令带测试环境（Global Constraints）。
    // prepare 后 `git init -b main`；写 root/service.json、root/hosts.json（平铺旧文件）、local/service.json、
    // files/transfers/a.bin、shared/x.tmp、shared/workspace.json.bad、shared/workspace.json、clipboard/a.md、devices/1/gui.json
    // `git status --porcelain --untracked-files=all` 的路径集合 ==
    //   {".gitignore", "README.md", "agent/README.md", "shared/workspace.json", "clipboard/a.md", "devices/1/gui.json"}
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test -p rapp-net datadir`
Expected: 编译失败（`prepare` 未定义）。

- [ ] **Step 3: 实现 `prepare` 和三个模板文件**

- [ ] **Step 4: service、hub 接上**：两个 `main.rs` 里 `let root = rapp_net::config::home();` → `if let Err(e) = rapp_net::datadir::prepare(&root, &rapp_net::config::legacy_dir()) { eprintln!("rapp-service: 数据目录 {}: {e:#}", root.display()); std::process::exit(1); }`（hub 同样，前缀 `rapp-hub`）→ `home: rapp_net::config::local(&root)`。`scripts/e2e-local.py`：写 `service.json` 和读 `ipc.token` 改到 `<home>/local/`（`os.makedirs(..., exist_ok=True)`）。脚本不运行，只 `python3 -m py_compile scripts/e2e-local.py`。

- [ ] **Step 5: 跑测试，确认通过**

Run: 全套 Rust 测试和 clippy；`python3 -m py_compile scripts/e2e-local.py`
Expected: PASS；testkit 照常通过（它直接传临时 `home`，不经 `main.rs`）。

- [ ] **Step 6: 提交**

```bash
git add rust/net/src/datadir.rs rust/net/src/datadir/README.md rust/net/src/datadir/agent-README.md rust/net/src/datadir/gitignore rust/net/src/lib.rs rust/service/src/main.rs rust/hub/src/main.rs scripts/e2e-local.py
git commit -m "net: prepare the data dir and copy the old config into it; service and hub use local/"
```

---

### Task 3: service：`device.json` 和本机的定时提交

**Files:**
- Create: `rust/service/src/data.rs`
- Modify: `rust/service/src/lib.rs:32-45`（`Opts.data`）、`:94-140`（写 `device.json`、起任务）、`rust/service/src/main.rs`（`data: Some(DataOpts::system(root))`）、`rust/testkit/tests/common/mod.rs:72,92`、`rust/testkit/tests/hub.rs:834`（都加 `data: None`）
- Test: `rust/service/src/data.rs`（tests）、`rust/testkit/tests/service.rs`

**Interfaces:**
- Consumes: Task 1 `config::{local, device}`；Task 2 `datadir::prepare`（测试里建目录）；`rapp_net::log::{Log, Lvl, timestamp}`。
- Produces（`rapp_service`，`pub use data::{DataOpts, SyncStatus}`）：
  - `pub struct DataOpts { pub root: PathBuf, pub git: PathBuf, pub commit_every: Duration, pub pull_every: Duration, pub git_env: Vec<(String, String)> }`；`DataOpts::system(root)` = `git: "git"`、60 秒、300 秒、空 env。
  - `Opts` 加 `pub data: Option<DataOpts>`；None = 不写 `device.json`、不碰 git（testkit 用 None）。
  - `pub const SYNC_FILE: &str = "sync.json";`
  - `#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)] pub struct SyncStatus { pub git: String, pub last_commit: Option<String>, pub last_sync: Option<String>, pub error: Option<String> }`（R12）
  - `pub struct DataGit`；`DataGit::new(opts: &DataOpts, device_name: &str, log: Log) -> DataGit`；`pub async fn tick(&mut self) -> SyncStatus` —— 做一轮并写 `local/sync.json`。
  - `pub fn write_device_json(root: &Path, id: &str, name: &str) -> anyhow::Result<()>`（R23）
  - `pub fn spawn(opts: DataOpts, name: String, log: Log) -> JoinHandle<()>` —— 立即 tick 一次，之后每 `commit_every` 一次。
- 这个 Task 里 `tick`：git 跑不起来（`<git> --version` 失败）→ `git: "missing"`，什么都不做；`root/.git` 不在 → `git init -b main`；`git status --porcelain` 非空 → `git add -A` + `git commit`（R9 的参数和环境），`last_commit` = 现在，日志 `data_commit {"files": N}`；没有 remote → `git: "local"`。所有 git 子进程按 R9 处理环境，`opts.git_env` 最后加上。

- [ ] **Step 1: 写失败的测试**（`data.rs` tests；`fn opts(root) -> DataOpts` 用 `git_env = [("GIT_CONFIG_GLOBAL","/dev/null"),("GIT_CONFIG_NOSYSTEM","1")]`；`fn git(dir, args) -> String` 是测试自己的 git，带 Global Constraints 的全套环境；没装 git 的机器上除 `no_git_is_not_an_error` 外都 `return`）

```rust
#[tokio::test]
async fn two_changes_in_one_interval_make_one_commit() {
    let (t, root) = prepared();
    let mut g = DataGit::new(&opts(&root), "test-a", Log::file(&t.path().join("logs"), "service.log"));
    std::fs::write(root.join("shared/workspace.json"), "{}").unwrap();
    std::fs::write(root.join("clipboard/a.md"), "x").unwrap();
    let s = g.tick().await;
    assert_eq!((s.git.as_str(), s.last_commit.is_some()), ("local", true));
    assert_eq!(git(&root, &["rev-list", "--count", "HEAD"]).trim(), "1");
    assert_eq!(git(&root, &["log", "-1", "--format=%an <%ae>"]).trim(), "rapp <test-a>");
    g.tick().await;
    assert_eq!(git(&root, &["rev-list", "--count", "HEAD"]).trim(), "1", "nothing changed, no commit");
    let saved: SyncStatus = rapp_net::config::read_json(&root.join("local/sync.json")).unwrap().unwrap();
    assert_eq!(saved.git, "local");
}

#[tokio::test]
async fn ignored_paths_never_get_committed() {
    // root/service.json（平铺旧文件）、local/service.json、local/hosts.json、files/x.png、shared/a.tmp + shared/ok.json
    // tick 后 `git ls-files` == [".gitignore", "README.md", "agent/README.md", "shared/ok.json"]
}

#[tokio::test]
async fn no_git_is_not_an_error() {
    let mut o = opts(&root);
    o.git = "/nonexistent/git".into();
    let s = DataGit::new(&o, "test-a", log).tick().await;
    assert_eq!(s.git, "missing");
    assert!(!root.join(".git").exists());
    // local/sync.json 写的也是 "missing"
}

#[tokio::test]
async fn commit_ignores_the_users_signing_config() {
    // 先 tick 一次建仓库；`git config commit.gpgsign true` 和 `git config gpg.program /nonexistent`（仓库本地配置）
    // 再改一个文件 tick → 提交数 +1
}

#[test]
fn device_json_is_written_only_when_it_changes() {
    write_device_json(&root, "123456789", "test-a").unwrap();
    let p = root.join("devices/123456789/device.json");
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&p).unwrap()).unwrap();
    assert_eq!(v, json!({"id": "123456789", "name": "test-a", "os": std::env::consts::OS, "version": env!("CARGO_PKG_VERSION")}));
    let before = std::fs::metadata(&p).unwrap().modified().unwrap();
    std::thread::sleep(Duration::from_millis(20));
    write_device_json(&root, "123456789", "test-a").unwrap();
    assert_eq!(std::fs::metadata(&p).unwrap().modified().unwrap(), before);
}
```

`rust/testkit/tests/service.rs` 加 `service_with_a_data_dir_commits_its_device_json`：临时根目录先 `prepare`，`Opts { home: local(&root), data: Some(DataOpts { commit_every: 200ms, git_env: 测试环境, ..DataOpts::system(root) }), .. }` 起 service；5 秒内轮询 `git log --name-only` 出现 `devices/<id>/device.json`；`git show HEAD:devices/<id>/device.json` 不含 `password`、`secret`、`key`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test -p rapp-service data:: && cargo test -p rapp-testkit --test service service_with_a_data_dir`
Expected: 编译失败（`DataGit` 未定义）。

- [ ] **Step 3: 实现** `data.rs`（git 用 `tokio::process::Command`、`kill_on_drop(true)`、`tokio::time::timeout(120 s)`）；`Service::start` 在 `data` 是 Some 时 `write_device_json(&root, &id, &cfg.name)`（失败只记日志）并把 `data::spawn(...)` 放进 `tasks`。

- [ ] **Step 4: 跑测试，确认通过**

Run: 全套 Rust 测试和 clippy。
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add rust/service/src/data.rs rust/service/src/lib.rs rust/service/src/main.rs rust/testkit/tests/common/mod.rs rust/testkit/tests/hub.rs rust/testkit/tests/service.rs
git commit -m "service: device.json and a commit of the data dir every minute"
```

---

### Task 4: service：有 remote 时推拉，冲突停同步，去掉口令

**Files:**
- Modify: `rust/service/src/data.rs`

**Interfaces:**
- Consumes: Task 3 的 `DataGit`、`SyncStatus`。
- Produces:
  - `tick` 补上 R10、R11：这一轮提交了，或距上次同步 ≥ `pull_every`（第一轮总算到期）→ 有 remote 且没在冲突里 → fetch / rebase / push。成功 → `git: "synced"`、`last_sync` = 现在、`error: None`；rebase 失败 → `rebase --abort`、`git: "conflict"`、以后的轮只提交；fetch/push 失败 → `git: "error"`、`error` = `scrub(stderr 最后一行)`。日志按 R13。
  - `pub fn scrub(s: &str) -> String` —— `scheme://user[:pass]@` → `scheme://***@`，只留一行，截到 200 个字符。

- [ ] **Step 1: 写失败的测试**（`fn bare(t) -> PathBuf`：`git init --bare -b main`；`fn other_device(t, bare) -> PathBuf`：`git clone`，用测试作者身份提交和推送）

```rust
#[tokio::test]
async fn push_and_pull_through_a_bare_repo() {
    // A：prepared root，`git init -b main` 后 `git remote add origin <bare>`；opts.pull_every = 0
    // 写 shared/a.json → tick → synced；`git --git-dir <bare> log --format=%s` 有 "自动保存（test-a）"
    // other_device 克隆、写 shared/b.json、提交、推送 → A 再 tick → root/shared/b.json 存在，状态 synced，last_sync 有值
}

#[tokio::test]
async fn conflict_aborts_the_rebase_and_stops_syncing() {
    // A 和 other_device 各自改 shared/workspace.json 成不同内容，other 先推
    // A tick → git == "conflict"；root/.git/rebase-merge 和 rebase-apply 都不在；
    // `git log -1 --format=%s` 是 A 自己的提交；工作区干净
    // A 再写 shared/c.json → tick → 本机提交数 +1，状态仍 conflict，bare 的 main 没变
    // 新建一个 DataGit（= service 重启）→ tick 再试一次（仍冲突 → 仍 conflict）
}

#[tokio::test]
async fn a_failed_push_is_an_error_and_keeps_the_commit() {
    // remote = "https://user:s3cret@127.0.0.1:9/x.git"
    // 写文件 → tick → git == "error"，error 不含 "s3cret"、含 "***@" 或不含 URL；本机提交在
    // local/sync.json 和日志文件全文都不含 "s3cret"
}

#[tokio::test]
async fn logs_carry_no_file_names() {
    // 两边都改 clipboard/20261113-120000-我的密码.md 造成冲突 → tick
    // 日志文件全文不含 "我的密码"、不含 "clipboard/"，含 `"ev":"data_sync"` 和 `"step":"rebase"`
}

#[test]
fn scrub_removes_credentials() {
    assert_eq!(scrub("fatal: unable to access 'https://u:p@h/x.git/': refused"), "fatal: unable to access 'https://***@h/x.git/': refused");
    assert_eq!(scrub("ssh://git@host/x"), "ssh://***@host/x");
    assert_eq!(scrub("a\nb"), "a");
    assert_eq!(scrub(&"x".repeat(300)).chars().count(), 200);
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test -p rapp-service data::`
Expected: 新测试 FAIL（没有同步），`scrub` 未定义。

- [ ] **Step 3: 实现**（照 R10、R11、R13）

- [ ] **Step 4: 跑测试，确认通过**

Run: 全套 Rust 测试和 clippy。
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add rust/service/src/data.rs
git commit -m "service: pull --rebase and push the data dir when it has a remote; stop on conflict"
```

---

### Task 5: hub 命令 `set_home`

**Files:**
- Modify: `rust/hub/src/hosts.rs:18-28`（`path` 改成 `Mutex<PathBuf>`，加 `reload`）、`rust/hub/src/lib.rs`（`dispatch` 加一支）、`gui/lib/hub_client.dart:138`（加 `setHome`）
- Test: `rust/hub/src/hosts.rs`（tests）、`rust/testkit/tests/hub.rs`、`gui/test/hub_client_test.dart`

**Interfaces:**
- Produces:
  - `Hosts::reload(&self, dir: &Path) -> anyhow::Result<()>` —— 读 `<dir>/hosts.json`（不在 = 空），成功才换路径和列表；之后 `upsert`/`remove` 写新路径。
  - hub 命令 `{"cmd":"set_home","dir":"<新根>/local"}` → `{"event":"home_set"}`；读不出 → `{"event":"error","error":…}`，旧的照用。relay 设置不重读（`service.json` 是复制过去的同一份）。
  - Dart：`Future<void> HubClient.setHome(String localDir)` —— `_request({'cmd': 'set_home', 'dir': localDir}, 'home_set')`。

- [ ] **Step 1: 写失败的测试**
  - `hosts.rs`：`reload_switches_the_file`：a/hosts.json 有 `x`，b/hosts.json 有 `y` → `load(a)` 后 `reload(b)` → `all()` 只有 `y`；`upsert(z)` 写进 b/hosts.json，a/hosts.json 不变；`reload` 一个坏 JSON 的目录 → Err，`all()` 仍是 `y`。
  - `rust/testkit/tests/hub.rs`：`set_home_reads_hosts_from_the_new_dir`：两个临时目录，第二个里 `write_json(hosts.json, [{"id":"111111111","name":"n","password":"p","lan":[]}])`；`Hub::start(home1, bins, None, None)` → `call({"cmd":"set_home","dir":home2,"req":1})` == `{"event":"home_set","req":1}` → `call({"cmd":"hosts"})` 的 hosts 是 `[{"id":"111111111","name":"n"}]`（没有 password）。
  - `hub_client_test.dart`：`setHome sends set_home and waits for home_set`（照该文件里 `removeHost` 测试用的假 transport）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test -p rapp-hub hosts:: && cargo test -p rapp-testkit --test hub set_home`；`cd gui && $HOME/development/flutter/bin/flutter test test/hub_client_test.dart`
Expected: FAIL / 编译失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: 全套 Rust 测试和 clippy；Flutter analyze + test；`git checkout -- gui/pubspec.lock`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add rust/hub/src/hosts.rs rust/hub/src/lib.rs rust/testkit/tests/hub.rs gui/lib/hub_client.dart gui/test/hub_client_test.dart
git commit -m "hub: set_home reloads hosts.json from a moved data dir"
```

---

### Task 6: 收发目录 `<根>/files/transfers`（Swift）

**Files:**
- Create: `Sources/RappCore/DataPaths.swift`、`Tests/RappCoreTests/DataPathsTests.swift`
- Modify: `Sources/rapp-host/Server.swift:585`、`Sources/RappSession/Transfers.swift:57-61`、`gui/macos/Runner/SessionPlugin.swift:47-51,158-160,369`、`gui/lib/ui/resources_tab.dart:290`、`gui/lib/embed/session_port.dart:232`（注释）、`gui/test/ui/resources_tab_test.dart:169,188`

**Interfaces:**
- Produces（`RappCore`）：
  - `public enum DataPaths { public static func root(env: [String: String], home: URL, read: (URL) -> String? = DataPaths.readFile) -> URL; public static func transfers(env: [String: String], home: URL, read: (URL) -> String? = DataPaths.readFile) -> URL; public static func readFile(_ url: URL) -> String? }`
  - `root`：`RAPP_HOME` → `home/Library/Application Support/rapp/data-root` 的第一行（R6，`/` 开头才算）→ `home/rapp`。`transfers`：`RAPP_DOWNLOADS`（非空）→ `root/files/transfers`。
- rapp-host 的上传目录、`TransferQueue` 的默认、SessionPlugin 的下载目录和「显示位置」的允许范围都用 `DataPaths.transfers(env: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)`。SessionPlugin 的 `downloads` 从 `let` 改成每次用时算的计算属性（改位置后新的下载和「显示位置」跟着新根，R17）。
- GUI 文字：`'A：~/Downloads/rapp/${x.name}'` → `'A：~/rapp/files/transfers/${x.name}'`。

- [ ] **Step 1: 写失败的测试**（`DataPathsTests.swift`，`home = URL(fileURLWithPath: "/Users/u")`，`read` 注入）

```swift
func testDownloadsEnvWins() {
    XCTAssertEqual(DataPaths.transfers(env: ["RAPP_DOWNLOADS": "/d", "RAPP_HOME": "/h"], home: home, read: { _ in nil }).path, "/d")
}
func testRappHomeThenPointerThenHomeRapp() {
    let ptr: (URL) -> String? = { $0.path == "/Users/u/Library/Application Support/rapp/data-root" ? "/Volumes/D/rapp\n" : nil }
    XCTAssertEqual(DataPaths.transfers(env: ["RAPP_HOME": "/h"], home: home, read: ptr).path, "/h/files/transfers")
    XCTAssertEqual(DataPaths.transfers(env: [:], home: home, read: ptr).path, "/Volumes/D/rapp/files/transfers")
    XCTAssertEqual(DataPaths.transfers(env: [:], home: home, read: { _ in nil }).path, "/Users/u/rapp/files/transfers")
}
func testEmptyValuesAndRelativePointerAreIgnored() {
    XCTAssertEqual(DataPaths.transfers(env: ["RAPP_DOWNLOADS": "", "RAPP_HOME": ""], home: home, read: { _ in "rapp" }).path,
                   "/Users/u/rapp/files/transfers")
}
```

`resources_tab_test.dart` 两处期望改成 `'A：~/rapp/files/transfers/b.txt'`、`'A：~/rapp/files/transfers/report.pdf'`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter DataPathsTests`；`cd gui && $HOME/development/flutter/bin/flutter test test/ui/resources_tab_test.dart`
Expected: 编译失败 / 文字不对。

- [ ] **Step 3: 实现**，改上面列的调用处；`Transfers.swift:57` 注释改成「nil 时用 `DataPaths.transfers`」。`Tests/RappSessionTests/TransferQueueTests.swift:66` 已经注入目录，不用改。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test`；runner 编译；Flutter analyze + test；`git checkout -- gui/pubspec.lock`
Expected: PASS，编译成功。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappCore/DataPaths.swift Tests/RappCoreTests/DataPathsTests.swift Sources/rapp-host/Server.swift Sources/RappSession/Transfers.swift gui/macos/Runner/SessionPlugin.swift gui/lib/ui/resources_tab.dart gui/lib/embed/session_port.dart gui/test/ui/resources_tab_test.dart
git commit -m "transfers go to <data root>/files/transfers on A and B; reveal follows it"
```

---

### Task 7: Dart 路径规则和建目录/搬家

**Files:**
- Modify: `gui/lib/paths.dart:1-35`
- Create: `gui/lib/data_dir.dart`
- Test: `gui/test/paths_test.dart`、`gui/test/data_dir_test.dart`

**Interfaces:**
- Produces（`paths.dart`；`configDir` 这个 Task 先留着、标 `@Deprecated('use dataRoot')`，Task 8 改完调用处后删掉）：
  - `String platformConfigDir(Map<String, String> env, String os)` —— 旧的平台目录（不看 `RAPP_HOME`）。
  - `String legacyDir(Map<String, String> env, String os)` —— `RAPP_HOME`，否则 `platformConfigDir`（R2）。
  - `String pointerFile(Map<String, String> env, String os)` —— `platformConfigDir` + 分隔符 + `data-root`（Windows 用 `\`）。
  - `String defaultDataRoot(Map<String, String> env, String os)` —— `$HOME/rapp`，Windows `%USERPROFILE%\rapp`。
  - `String dataRoot(Map<String, String> env, String os, {String? Function(String path) read = readFileOrNull})` —— `RAPP_HOME` → 指针（R6）→ `defaultDataRoot`。
  - `String logDir(…)`：`RAPP_HOME` 那一档改成 `$RAPP_HOME/local/logs`。
  - `class DataDir { const DataDir(this.root); final String root; String get localDir; String get sharedDir; String deviceDir(String id); String get filesDir; String get clipboardDir; String get filesClipboardDir; String? deviceId(); String? prefsDir(); }` —— 子路径用 `/` 拼；`deviceId()` 读 `localDir/service.json` 的 `id`（字符串，非空），任何错都返回 null；`prefsDir()` = id 有时 `deviceDir(id)`，否则 null（R22）。**`sharedDir` 是 app 配置计划要用的 `apps.json` 所在目录。**
- Produces（`data_dir.dart`）：
  - `const dataReadme`、`const agentReadme`、`const dataGitignore`（和 `rust/net/src/datadir/` 三个文件逐字相同）；`const readmeMarker = '# rapp 数据目录';`
  - `bool prepareDataDir(String root, String legacy)` —— 和 Rust `prepare` 同样的规则（Task 2 的 Interfaces），同步 I/O，出错抛 `FileSystemException`；`local/` 用 `chmod 700`、复制的文件 `chmod 600`（`Process.runSync('chmod', …)`，Windows 跳过）。
  - `bool isRappDataDir(String dir)` —— `dir/README.md` 的第一行是 `readmeMarker`。

- [ ] **Step 1: 写失败的测试**
  - `paths_test.dart`：原 `configDir` 组换成 `dataRoot`、`platformConfigDir`、`legacyDir`、`pointerFile` 四组，取值和 Task 1 的 Rust 测试一一对应（macOS 三档顺序、空串、坏指针 `''`/`'rapp'`/`'~/x'`、Linux XDG、Windows `USERPROFILE`/`APPDATA` 和 `D:\rapp` 指针）；`logDir` 的 `'/h/logs'` 改成 `'/h/local/logs'`；`DataDir('/r')` 的五个子路径；`deviceId` 在临时目录里：没文件 null、`{"id":"123456789"}` → `'123456789'`、`{"id":null}` → null、坏 JSON → null。
  - `data_dir_test.dart`：Task 2 的前八个 Rust 测试照搬成 Dart（同名，`fresh root gets the layout` 等，`a failed copy leaves no service.json` 用 `chmod 000`），外加：

```dart
test('templates match the Rust copies word for word', () {
  expect(dataReadme, File('../rust/net/src/datadir/README.md').readAsStringSync());
  expect(agentReadme, File('../rust/net/src/datadir/agent-README.md').readAsStringSync());
  expect(dataGitignore, File('../rust/net/src/datadir/gitignore').readAsStringSync());
  expect(dataReadme.split('\n').first, readmeMarker);
});

test('isRappDataDir: only a README whose first line is the marker', () { /* 无文件 false；"# 别的" false；dataReadme true */ });
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test test/paths_test.dart test/data_dir_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: Flutter analyze + 全套 test；`git checkout -- gui/pubspec.lock`
Expected: PASS（analyze 对 `configDir` 的 deprecated 提示只在 `info` 级、不算失败；如果项目把它当错误，就先不加 `@Deprecated`）。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/paths.dart gui/lib/data_dir.dart gui/test/paths_test.dart gui/test/data_dir_test.dart
git commit -m "gui: data root paths with the data-root pointer, and prepareDataDir"
```

---

### Task 8: GUI 改用新位置

**Files:**
- Modify: `gui/lib/main.dart:25-90`、`gui/lib/ui/main_state.dart:55-82,1060,1242`、`gui/lib/ui/main_window.dart:34-42,98`、`gui/lib/pages/local_section.dart:41-51,122,185`、`gui/lib/service_client.dart:346-347`、`gui/lib/ui/prefs.dart`（注释）、`gui/lib/ui/workspace_store.dart:1`（注释）
- Modify: `gui/lib/paths.dart`（删 `configDir`）、`gui/lib/pages/permissions_panel.dart:139-141`（参数改名 `localDir`）
- Test: 构造 `MainState`/`MainWindow`/`LocalSection` 时传 `configDir` 的测试：`gui/test/linux_update_test.dart`、`gui/test/permissions_panel_test.dart`、`gui/test/ui/{projects_tab,stage,devices_tab,side_panel,main_window,main_state,overview,top_bar,resources_tab}_test.dart`、`gui/test/embed/composer_bar_test.dart`；`gui/test/ui/main_state_test.dart` 加两个新测试

**Interfaces:**
- Consumes: Task 7 的 `DataDir`、`dataRoot`、`legacyDir`、`prepareDataDir`。
- Produces:
  - `MainState({…, required DataDir data, …})`（替换 `configDir`）；`DataDir data`（可变，Task 10 的 `relocate` 改它）。`workspace.json` 读写用 `data.sharedDir`；界面偏好保存用 `data.prefsDir()`，null 时不写（R22）。
  - `MainWindow({…, required DataDir data})`，给 `LocalSection` 传 `state.data`。
  - `LocalSection({…, required DataDir data})`：`claimPermissionGuide(data.localDir)`、`service.json` 读 `data.localDir`。
  - `Future<String?> Function() tokenFileReader(String Function() localDir)` —— 每次读时取当前目录（改位置后 service 把 `ipc.token` 写到新根）。
  - `main.dart`：`final root = dataRoot(env, os);` → `try { prepareDataDir(root, legacyDir(env, os)); } catch (e) { stderr.writeln('rapp: 数据目录 $root: $e'); }` → `final data = DataDir(root)`；`UiPrefs.load(data.prefsDir() ?? data.localDir)`（目录里没有 `gui.json` 就是默认）；`--cm` 分支同样用 `data.localDir`。
- 测试里一律 `data: DataDir(tmp.path)`（tmp 下先 `Directory('${tmp.path}/shared').createSync(recursive: true)` 不是必须的：`saveWorkspace` 自己建目录）。`side_panel_test.dart:389` 的「坏目录」用 `DataDir('${f.path}/sub')`。

- [ ] **Step 1: 写失败的测试**（`main_state_test.dart`）

```dart
test('workspace is read from and saved to shared/', () {
  final root = Directory.systemTemp.createTempSync('rapp-data');
  Directory('${root.path}/shared').createSync();
  File('${root.path}/shared/workspace.json').writeAsStringSync(
      '{"version":1,"favorites":[{"device":"1","bundle":"b","name":"n"}],"projects":[]}');
  final s = MainState(hub: FakeHub(), data: DataDir(root.path), prefs: UiPrefs());
  expect(s.workspace.favorites.single.bundle, 'b');
  // 加一个常用 → shared/workspace.json 里有两个；根目录下没有 workspace.json
});

test('prefs go to devices/<id>/gui.json, and are not written without an id', () {
  // 没有 local/service.json：改主题 → devices/ 下没有任何文件
  // 写 local/service.json {"id":"123456789"} → 再改主题 → devices/123456789/gui.json 的 theme 是新值
});
```

（`FakeHub` / 改主题 / 加常用的写法照该文件已有的测试。）

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test test/ui/main_state_test.dart`
Expected: 编译失败（`data` 参数不存在）。

- [ ] **Step 3: 实现**，改所有调用处和测试（`grep -rn 'configDir' gui/lib gui/test` 最后应为空）。

- [ ] **Step 4: 跑测试，确认通过**

Run: Flutter analyze + 全套 test；`git checkout -- gui/pubspec.lock`
Expected: analyze 无问题，全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/paths.dart gui/lib/main.dart gui/lib/ui/main_state.dart gui/lib/ui/main_window.dart gui/lib/pages/local_section.dart gui/lib/pages/permissions_panel.dart gui/lib/service_client.dart gui/lib/ui/prefs.dart gui/lib/ui/workspace_store.dart
git add gui/test/linux_update_test.dart gui/test/permissions_panel_test.dart gui/test/ui/projects_tab_test.dart gui/test/ui/stage_test.dart gui/test/ui/devices_tab_test.dart gui/test/ui/side_panel_test.dart gui/test/ui/main_window_test.dart gui/test/ui/main_state_test.dart gui/test/ui/overview_test.dart gui/test/ui/top_bar_test.dart gui/test/ui/resources_tab_test.dart gui/test/embed/composer_bar_test.dart
git commit -m "gui: data root paths; workspace in shared/, prefs in devices/<id>/, token and markers in local/"
```

---

### Task 9: 设置页「数据目录」一节（路径、打开、git 状态）

**Files:**
- Create: `gui/lib/pages/data_section.dart`
- Modify: `gui/lib/pages/local_section.dart`（在「本机」卡片后面放 `DataSection`）
- Test: `gui/test/data_section_test.dart`

**Interfaces:**
- Consumes: Task 8 的 `DataDir`；Task 3 的 `local/sync.json` 格式（R12）。
- Produces:
  - `String syncStatusText(Map<String, dynamic>? sync, {DateTime Function(String) parse = DateTime.parse})` —— R14 的表；`synced` 的 HH:MM 用 `parse(last_sync).toLocal()`。
  - `Map<String, dynamic>? readSyncStatus(DataDir d)` —— 读 `local/sync.json`，任何错 null。
  - `class DataSection extends StatefulWidget { const DataSection({super.key, required this.data, this.openFolder = openFolderDefault, this.relocate}); final DataDir data; final Future<void> Function(String path) openFolder; final DataRelocator? relocate; }` —— `relocate` 是 Task 10 的；这个 Task 里传 null 时不显示那两个按钮。
  - `Future<void> openFolderDefault(String path)`：macOS `open`、Linux `xdg-open`（产品代码；测试注入假的）。
- 界面：`SectionCard(title: '数据目录', …)`：一行路径（可选中复制）、一行 git 状态、按钮「打开数据目录」。每 10 秒重读 `sync.json`（`Timer.periodic`，dispose 时取消）。

- [ ] **Step 1: 写失败的测试**

```dart
test('sync status words', () {
  expect(syncStatusText(null), '还没有版本记录');
  expect(syncStatusText({'git': 'missing'}), '没装 git，文字没有版本记录');
  expect(syncStatusText({'git': 'local'}), '只在本机');
  expect(syncStatusText({'git': 'synced', 'last_sync': '2026-11-13T09:05:00.000Z'},
      parse: (s) => DateTime.parse(s).toLocal()), startsWith('已同步 '));
  expect(syncStatusText({'git': 'conflict'}), '同步有冲突，需要手工处理');
  expect(syncStatusText({'git': 'error', 'error': 'push refused'}), '同步没成功：push refused');
  expect(syncStatusText({'git': 'weird'}), '还没有版本记录');
});

testWidgets('shows the path and the status; 打开数据目录 opens the root', (t) async {
  // 临时根，local/sync.json = {"git":"local"}；openFolder 记下参数
  // 找到文字 root 路径、'只在本机'；点 '打开数据目录' → 记下的是 root
  // relocate 为 null → 找不到 '更改位置…'
});
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test test/data_section_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: Flutter analyze + 全套 test；`git checkout -- gui/pubspec.lock`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/pages/data_section.dart gui/lib/pages/local_section.dart gui/test/data_section_test.dart
git commit -m "gui: 数据目录 section with path, open button and git status"
```

---

### Task 10: 「更改位置…」和「改回默认」（D12）

**Files:**
- Create: `gui/lib/data_relocate.dart`
- Modify: `gui/lib/pages/data_section.dart`、`gui/lib/ui/main_state.dart`（`relocate`）、`gui/lib/ui/main_window.dart`（把 `DataRelocator` 交给 `LocalSection` → `DataSection`）、`gui/lib/pages/local_section.dart`、`gui/lib/main.dart`（真实的 `DataRelocator`）
- Test: `gui/test/data_relocate_test.dart`、`gui/test/data_section_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 5 `HubClient.setHome`；Task 7 `isRappDataDir`、`pointerFile`、`defaultDataRoot`；Task 8 `MainState.data`；`ServiceController.run(ServiceAction.restart)`（`gui/lib/service_control.dart:38`）。
- Produces（`data_relocate.dart`）：
  - `enum RelocateKind { copy, adopt }`
  - `({RelocateKind? kind, String? error}) planRelocation(String from, String to)` —— R15 的判定，路径先规范化（`Directory(x).absolute.path`，去掉末尾 `/`）；不动盘。
  - `Future<String?> applyRelocation({required String from, required String to, required RelocateKind kind, required String pointer, required bool isDefault, Future<ProcessResult> Function(String, List<String>) run = Process.run})` —— copy：`mkdir -p to` 后 `run('cp', ['-Rp', '$from/.', to])`，非 0 → 返回「复制没成功：<stderr 第一行>」且不碰指针；然后 `isDefault` → 删 `pointer`（不在也算成功），否则写 `pointer`（`to` + `\n`，先建父目录）。返回 null = 成功。
  - `class DataRelocator { DataRelocator({required this.env, required this.os, required this.restartService, required this.setHubHome, required this.state}); Future<String?> Function() restartService; Future<void> Function(String localDir) setHubHome; … }`，方法 `Future<String> run(String to, {required bool isDefault})`：apply → `restartService()` → `setHubHome('$to/local')`（失败只记 stderr）→ `state.relocate(DataDir(to))` → 返回要显示的那句话：「数据目录已改到 〈to〉，服务已重启」；重启失败时「数据目录已改到 〈to〉，服务没重启成功：<错误>」。
  - `MainState.relocate(DataDir d)`：换 `data`，从 `d.sharedDir` 重读 `workspace.json`（读不出照 `loadProblem` 提示），已钉住条目里路径在旧根下的换成新根下的同一相对路径（Task 12 的 `ClipEntry.path`；这个 Task 先加好方法，路径部分在 Task 12 补测试），`notifyListeners()`。
- 界面（`DataSection`）：`relocate != null` 且 `env['RAPP_HOME']` 为空且不是 Windows 时，显示「更改位置…」和（当前根 ≠ `defaultDataRoot` 时）「改回默认」；`RAPP_HOME` 设了时显示「位置由环境变量 RAPP_HOME 决定」。「更改位置…」用 `file_selector` 的 `getDirectoryPath()`（已在依赖里就用它；不在就用 `TextField` 对话框让用户输入路径——实现前先 `grep file_selector gui/pubspec.yaml` 决定，**不加新依赖**）。确认对话框：标题「改数据目录的位置？」；copy 时正文「会把 〈from〉 里的数据复制到 〈to〉，原来的留着不动。会重启服务，正在连着的会话会断一次。」；adopt 时正文「〈to〉 里已经有 rapp 的数据，会直接用它，〈from〉 里的不复制过去。会重启服务，正在连着的会话会断一次。」；按钮「取消」「改」。结果用 SnackBar 显示。测试通过 `DataSection.pickFolder` 注入（`Future<String?> Function()`）。

- [ ] **Step 1: 写失败的测试**（`data_relocate_test.dart`，全在临时目录里；`run` 用真的 `Process.run`（`cp` 只在临时目录间复制）或注入假的）

```dart
test('refuses a folder inside or around the current root', () {
  expect(planRelocation('/t/rapp', '/t/rapp').error, '已经是这个位置');
  expect(planRelocation('/t/rapp', '/t/rapp/sub').error, '新位置不能在当前数据目录里面，也不能包着它');
  expect(planRelocation('/t/rapp', '/t').error, '新位置不能在当前数据目录里面，也不能包着它');
  expect(planRelocation('/t/rapp', '/t/rapp2').error, isNull); // 名字前缀相同但不是里面
});

test('refuses a non-empty folder that is not rapp\'s', () { /* to 里有 x.txt → '这个文件夹里已经有别的东西，选一个空文件夹' */ });

test('copy: missing or empty folder; keeps modes and .git; old root untouched', () async {
  // from：prepareDataDir 后加 local/service.json(0600)、.git/HEAD、files/transfers/a.bin
  // plan → copy；apply → null；to 里这些都在，local/service.json 仍 0600；from 里文件都还在；pointer 内容 == '$to\n'
});

test('adopt: a folder with rapp\'s README is used as is', () async {
  // to：prepareDataDir 过、shared/workspace.json = 'theirs'；plan → adopt；apply → null；to 的 workspace.json 仍是 'theirs'
});

test('back to default deletes the pointer', () async { /* 先写 pointer；isDefault: true → pointer 不在 */ });

test('a failed copy leaves the pointer alone', () async {
  // run 假的：返回 exitCode 1、stderr 'cp: no space'；结果 '复制没成功：cp: no space'；pointer 文件不存在
});
```

`data_section_test.dart`：
- `adopting says so before doing anything`：pickFolder 返回一个有 rapp README 的临时目录 → 对话框正文含「会直接用它」；点「取消」→ 假 `restartService` 没被调、pointer 不在。
- `a change restarts the service, moves the hub and the state`：点「改」→ 假 `restartService` 调了一次，`setHubHome` 收到 `'$to/local'`，`state.data.root == to`，SnackBar「数据目录已改到 $to，服务已重启」。
- `RAPP_HOME set: no buttons, a note`。

`main_state_test.dart`：`relocate reads the workspace of the new root`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test test/data_relocate_test.dart test/data_section_test.dart test/ui/main_state_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**；`main.dart` 里真实的 `DataRelocator`：`restartService: () async => control?.run(ServiceAction.restart) ?? '找不到 rapp-service'`、`setHubHome: hub?.setHome`。

- [ ] **Step 4: 跑测试，确认通过**

Run: Flutter analyze + 全套 test；`git checkout -- gui/pubspec.lock`
Expected: PASS。测试里没有一处调到真的 `ServiceController`。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/data_relocate.dart gui/lib/pages/data_section.dart gui/lib/ui/main_state.dart gui/lib/ui/main_window.dart gui/lib/pages/local_section.dart gui/lib/main.dart gui/test/data_relocate_test.dart gui/test/data_section_test.dart gui/test/ui/main_state_test.dart
git commit -m "gui: change the data dir location (copy or adopt), back to default, service restarted"
```

---

### Task 11: runner 把钉住的副本写盘、读回（Swift）

**Files:**
- Modify: `Sources/RappSession/ClipCopies.swift`、`gui/macos/Runner/SessionPlugin.swift`（两个新方法）、`gui/lib/embed/session_port.dart`（`savePin`、`loadPin`）、`gui/lib/embed/linux_session_port.dart`（R21）
- Test: `Tests/RappSessionTests/ClipCopiesTests.swift`（不存在就新建）、`gui/test/embed/session_port_test.dart`、`gui/test/embed/linux_session_port_test.dart`

**Interfaces:**
- Produces（Swift，`ClipCopies`）：
  - `public func save(_ n: Int, textDir: URL, fileDir: URL, stem: String) throws -> URL?` —— R18：text → `textDir/<stem>.md`（UTF-8 原文）；image → `fileDir/<stem>.png`；data → `fileDir/<stem>.<UTType(uti).preferredFilenameExtension ?? "bin">`；files → 文件夹 `fileDir/<stem>/`，逐个 `copyItem`。目标已存在就 `<stem>-2`、`-3`…。未知编号返回 nil。目录不在就建。先写 `.tmp` 再改名（文件夹：先建 `<名>.tmp/` 再改名）。
  - `public func load(_ url: URL) -> (n: Int, kind: String)?` —— `.md` → text；`.png` → image；文件夹 → files（里面的文件按名字排序，跳过 `.` 开头的）；其他扩展名 → data（`UTType(filenameExtension:)?.identifier ?? "public.data"`）。读不出返回 nil。`kind` 是 `text`/`image`/`files`/`data`。
- runner 通道：`pin_save {copy, text_dir, file_dir, stem}` → `{"path": <写下的路径>}` 或 `{"error": <原因>}`；`pin_load {path}` → `{"copy": n, "kind": k}` 或 null。
- Dart（`SessionPort`）：`Future<String?> savePin(int copy, {required String textDir, required String fileDir, required String stem})`；`Future<({int copy, ClipKind kind})?> loadPin(String path)`。`PlatformException`/`MissingPluginException` → null（照 `fetchClip`）。`LinuxSessionPort`：`pin_save` 只对文字副本写 `<text_dir>/<stem>.md`（重名加 `-2`…），其他回 null；`pin_load` 只认 `.md`。

- [ ] **Step 1: 写失败的测试**
  - Swift `ClipCopiesTests`：`testSaveTextWritesMarkdown`（内容逐字、路径 `textDir/s.md`）、`testSaveAvoidsNameClashes`（同一 stem 两次 → `s.md`、`s-2.md`）、`testSaveImageAndData`（`.png`；`public.rtf` → `.rtf`）、`testSaveFilesCopiesIntoAFolder`（临时目录里两个源文件 → `fileDir/s/` 下两个，源文件还在）、`testLoadRoundTrips`（四种都 save 再 load，`write(_:to:)` 写到假的 `LocalPasteboard`——照 `Tests/RappSessionTests` 里已有的假剪贴板，**不碰系统剪贴板**——内容和原来一样）、`testUnknownCopyIsNil`。
  - Dart `session_port_test.dart`：`savePin and loadPin map the runner replies`（`invoke` 假的：`{'path': '/x/s.md'}` → `'/x/s.md'`；`{'error': 'x'}` → null；`{'copy': 3, 'kind': 'files'}` → `(copy: 3, kind: ClipKind.files)`；null → null）。
  - `linux_session_port_test.dart`：`pin_save writes text copies only; pin_load reads .md back`（临时目录）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `swift test --filter ClipCopiesTests`；`cd gui && $HOME/development/flutter/bin/flutter test test/embed/session_port_test.dart test/embed/linux_session_port_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**；SessionPlugin 的两支在主线程用 `copies`（和 `copy_local` 一样）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `swift test`；runner 编译；Flutter analyze + test；`git checkout -- gui/pubspec.lock`
Expected: PASS，编译成功。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappSession/ClipCopies.swift Tests/RappSessionTests/ClipCopiesTests.swift gui/macos/Runner/SessionPlugin.swift gui/lib/embed/session_port.dart gui/lib/embed/linux_session_port.dart gui/test/embed/session_port_test.dart gui/test/embed/linux_session_port_test.dart
git commit -m "runner: save a pinned copy to the data dir and load it back"
```

---

### Task 12: 钉住的条目写盘、取消就删、启动时读回（Dart）

**Files:**
- Create: `gui/lib/ui/pin_files.dart`
- Modify: `gui/lib/ui/resources_state.dart`（`ClipEntry.path`、`addRestored`）、`gui/lib/ui/main_state.dart:1288-1315`（`togglePin`、启动时读回、`relocate` 的路径换根）、`gui/test/fakes.dart`（`pin_save`/`pin_load` 的假回复）
- Test: `gui/test/ui/pin_files_test.dart`、`gui/test/ui/resources_state_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 11 `SessionPort.savePin`/`loadPin`；Task 8 `MainState.data`；`kindWord`。
- Produces：
  - `pin_files.dart`：`String pinStem(DateTime at, String title, ClipKind kind)`（R18）；`List<String> pinnedPaths(DataDir d)`（`clipboard/*.md` 和 `files/clipboard/*` 的文件和文件夹，跳过 `.` 开头和 `.tmp` 结尾，按名字升序）；`String pinTitle(String path)`；`DateTime? pinTime(String path)`；`void deletePin(String path)`（文件或文件夹，不抛）；`const pinHint = '固定的条目存进了数据目录；文字会进 git 历史，取消固定只删文件，历史里还在';`、`const pinHintMarker = 'pin-hint-shown';`、`const restoredSource = '之前固定的';`
  - `ClipEntry` 加 `String? path`。`ResourcesState.addRestored({required String path, required int copy, required ClipKind kind, required String title, required DateTime at})` —— 插到最后（最旧）、`pinned = true`、`ended = true`、`source = restoredSource`、`key = ''`、`sid` 用一个私有常量对象。
  - `MainState`：
    - 固定成功（拿到 `copy`）后 `savePin(copy, textDir: data.clipboardDir, fileDir: data.filesClipboardDir, stem: pinStem(e.at, e.title, e.kind))`，返回的路径记进 `e.path`；返回 null 时条目照样钉在内存里（不提示）。第一次成功且 `local/pin-hint-shown` 不在 → `hint = pinHint`、写标记（R20）。
    - 取消固定：`e.path != null` → `deletePin(path)`，再走原来的 `unpin`/`dropCopy`。
    - 构造时有 `port`：`pinnedPaths(data)` 逐个 `loadPin`，成功的 `addRestored`（`title = pinTitle`、`at = pinTime ?? 文件修改时间`）。
    - `relocate`：`e.path` 以旧根开头的换成新根。
- 日志/stderr 里不写标题和路径。

- [ ] **Step 1: 写失败的测试**

```dart
test('pinStem: time, cleaned 20-char title, kind word when empty', () {
  final at = DateTime(2026, 11, 13, 9, 5, 7);
  expect(pinStem(at, '你好 世界', ClipKind.text), '20261113-090507-你好 世界');
  expect(pinStem(at, 'a/b\\c:d*e?f"g<h>i|j\nk', ClipKind.text), '20261113-090507-abcdefghijk');
  expect(pinStem(at, '..hidden', ClipKind.text), '20261113-090507-hidden');
  expect(pinStem(at, '一二三四五六七八九十一二三四五六七八九十多', ClipKind.text).length, 16 + 20);
  expect(pinStem(at, '  \n ', ClipKind.text), '20261113-090507-文字');
  expect(pinStem(at, '', ClipKind.image), '20261113-090507-图片');
});

test('pinnedPaths lists both places, skips temp and hidden files; title and time come back', () {
  // clipboard/20261113-090507-a.md、clipboard/.x、clipboard/b.md.tmp、files/clipboard/20261113-090508-图片.png、files/clipboard/20261113-090509-文件/
  // pinnedPaths 三项；pinTitle(…a.md) == 'a'；pinTime(…) == DateTime(2026,11,13,9,5,7)
});
```

`resources_state_test.dart`：`restored entries are pinned, ended, oldest, and never evicted`。

`main_state_test.dart`（照该文件已有的 pin 测试和 `FakeSessionPort`）：
- `pinning saves the copy to the data dir and hints once`：固定 → `calls` 里有 `pin_save`，参数 `text_dir == '${root}/clipboard'`、`file_dir == '${root}/files/clipboard'`；`hint == pinHint`；`local/pin-hint-shown` 存在；再固定一条 → hint 不再是 `pinHint`。
- `unpinning deletes the file`：假 `pin_save` 回一个真实存在的临时文件路径 → 取消固定后文件不在。
- `restored pins load at start`：根下放 `clipboard/20261113-090507-a.md`，假 `pin_load` 回 `{'copy': 7, 'kind': 'text'}` → `resources.clips.single` 的 `pinned`、`ended`、`source == '之前固定的'`、`title == 'a'`、`copy == 7`；`canInsert` 为 false。
- `relocate moves pin paths to the new root`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test test/ui/pin_files_test.dart test/ui/resources_state_test.dart test/ui/main_state_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: Flutter analyze + 全套 test；`git checkout -- gui/pubspec.lock`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/ui/pin_files.dart gui/lib/ui/resources_state.dart gui/lib/ui/main_state.dart gui/test/fakes.dart gui/test/ui/pin_files_test.dart gui/test/ui/resources_state_test.dart gui/test/ui/main_state_test.dart
git commit -m "gui: pinned clips are saved to clipboard/ or files/clipboard/, deleted on unpin, loaded at start"
```

---

### Task 13: 改《配置规范总览》和卸载脚本的说明

**Files:**
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md`（§0.4、§1、§2、§3、§6）、`scripts/uninstall-macos.sh:3,12`（只改注释和 echo 的文字）

**Interfaces:**
- Consumes: Task 1–12 的实际路径和行号（用 `grep -n` 现查，不照抄本计划里的行号）。

- [ ] **Step 1: 改 §0.4**：`$HOME_DIR` 换成「数据根目录」（下称 `$ROOT`）：`RAPP_HOME` → 指针 `<旧配置目录>/data-root` → `~/rapp`（Windows `%USERPROFILE%\rapp`）；目录树照规格 §1；进 git 和不进 git 的；机密只在 `local/`；旧配置目录只用来放指针和作搬家来源；代码位置 `rust/net/src/config.rs`、`gui/lib/paths.dart`、`Sources/RappCore/DataPaths.swift`。§0.5 的「设 `RAPP_HOME=<临时目录>`」保留。

- [ ] **Step 2: 改 §1 一览和 §2**：`service.json`、`hosts.json` → `$ROOT/local/`；`workspace.json`、`apps.json` → `$ROOT/shared/`；`gui.json` → `$ROOT/devices/<id>/gui.json`；新增一行 `device.json`（`$ROOT/devices/<id>/`，程序自管，没有机密）、一行 `data-root` 指针（GUI「更改位置…」写，可手改：一行绝对路径；改完重启 rapp-service）、一行 `clipboard/` 和 `files/clipboard/`（GUI 写，可手删 = 取消固定，下次启动生效）、一行 `agent/`（用户和 agent 的，rapp 不动）。§2.1 手改的生效方式不变；agent 改 `shared/` 和自己设备的 `devices/<id>/` 时注意 rapp-service 一分钟内会提交。

- [ ] **Step 3: 改 §3**：`ipc.token`、`update.json`、`update-applied.json`、`previous/`、`permission-guide-shown` → `$ROOT/local/`；新增 `local/sync.json`（R12 的字段）、`local/migrated-from`、`local/pin-hint-shown`、`last-dr`；日志目录规则改成 D10（`$RAPP_HOME/local/logs`）。

- [ ] **Step 4: 改 §6**：`RAPP_HOME` 的含义改成「数据根目录，优先于指针」；`RAPP_DOWNLOADS` 改成「A 收上传、B 下载的目录（A：rapp-host；B：GUI 嵌入会话），默认 `$ROOT/files/transfers`」，代码位置 `Sources/RappCore/DataPaths.swift`。

- [ ] **Step 5: 卸载脚本**：注释和 echo 改成「保留 `~/rapp`（数据目录）和 `~/Library/Application Support/rapp`（旧配置、指针）」。不改脚本的行为。`bash -n scripts/uninstall-macos.sh`。

- [ ] **Step 6: 自查**：`grep -n 'HOME_DIR\|GUI 配置目录\|Downloads/rapp' docs/superpowers/specs/2026-11-13-rapp-config-reference.md` 只剩「旧位置」的说法；表里每个代码位置 `文件:行号` 都打开看过。

- [ ] **Step 7: 提交**

```bash
git add docs/superpowers/specs/2026-11-13-rapp-config-reference.md scripts/uninstall-macos.sh
git commit -m "docs(配置规范): locations move into the data root ~/rapp"
```

---

### Task 14: 实机检查（用户同意后才跑）

**Files:**
- Modify: `tasks/todo.md`（只加一行结果：没同意就记「数据目录：待实机」，跑了就记各条 PASS/FAIL）

- [ ] **Step 1: 问用户**：「要在这台 Mac 上实机检查数据目录：装上这一版 rapp（会重启 rapp-service，正在连着的会话会断一次），它会第一次建 `~/rapp` 并从 `~/Library/Application Support/rapp` 复制配置（旧的不动）。之后我会看 `~/rapp` 的内容和 git 记录，请你在设置页点一次「更改位置…」到一个临时文件夹再「改回默认」。可以吗？」没同意就停。

- [ ] **Step 2（同意后）**：按用户平时的方式装这一版（`scripts/package-macos.sh` 打包，用户自己装）。检查：
  1. `~/rapp` 的树和规格 §1 一致；`local/` 是 0700；`local/migrated-from` 是旧目录；旧目录里的文件都还在。
  2. GUI 里设备、常用、项目、主题都和装之前一样；同一个设备 id（`local/service.json` 的 `id` 没变）。
  3. 一分钟后 `git -C ~/rapp log --name-only` 有 `devices/<id>/device.json`；`git -C ~/rapp ls-files` 里没有 `local/`、`files/` 下的任何东西。
  4. 设置页「数据目录」显示 `~/rapp` 和「只在本机」；「打开数据目录」打开 Finder。
  5. 固定一条文字 → 出现一次 `pinHint`，`~/rapp/clipboard/` 下多一个 `.md`；退出再开 GUI，这条还在、来源「之前固定的」；取消固定 → 文件没了。
  6. 从 B 下载一个文件 → 在 `~/rapp/files/transfers/`，「显示位置」能打开。
  7. 「更改位置…」选一个新建的空文件夹 → 确认框说「复制」→ 提示「数据目录已改到 …，服务已重启」；`~/Library/Application Support/rapp/data-root` 是这个路径；再「改回默认」→ 确认框说「直接用」→ 指针文件没了。
  8. `~/Library/Logs/rapp/service.log` 里有 `data_commit`，没有剪贴板标题和文件名。

- [ ] **Step 3: 记录**：每一条 PASS/FAIL 告诉用户；FAIL 的写成新任务，不在这里修。`git add tasks/todo.md && git commit -m "todo: data dir live check"`。
