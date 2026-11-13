# rapp 终端层（一）：探查，`rapp-term` 的核心、tmux 后端、本机和 SSH 执行器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一个能单独用的 `rapp-term` 命令：列出本机或 SSH 主机上的 tmux 会话，把一个面板的屏幕按“只送最新、带确认”的规则流出来，把按键和整段文字送进去。

**Architecture:** 新 crate `rust/term`。最下面是执行器（本机进程或 `ssh`）；上面是 tmux 后端（一次性命令加一个“看的时候才接”的控制模式客户端）；再上面是与工具无关的核心（屏幕、行的比较、发送闸门、未读）；最上面是一个把它们串起来的会话泵，读写的是 JSON 行。这份计划里泵接的是标准输入输出；下一份计划把同一个泵接到 worker 的 TCP 连接上。

**Tech Stack:** Rust 2021，tokio，serde / serde_json，anyhow；系统里的 tmux（3.2 以上）和 OpenSSH 客户端。不新增第三方依赖。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md`（第 2 稿，用户已同意；交互稿 `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-prototype/` 用户已确认）。下文的“§”都指它。实测依据见 `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-review.md` §1 的 E1–E9。

**这份计划的范围：** §16 的 T0，以及 T1–T3 里属于 `rust/term` 的部分：§5、§7（消息和规则）、§8、§9 的执行器、§12 的未读判定、§13 的送输入。**不在这里的**：worker 的 `serve`、`rapp-service` 和 `rapp-hub` 的接线、`local/term.json`、访问记录（下一份计划）；GUI 的 `TermSessionPort`、`TermStage`、设备面板（再下一份）；Windows（第二版）。这份做完时，`rapp-term` 不被任何别的 crate 引用。

## Global Constraints

- `rapp-term` 不依赖 `rapp-service`、`rapp-hub`、`rapp-relay`、`rapp-net`。包名和二进制名都是 `rapp-term`。
- **rapp 对用户的 tmux 只发这些命令**（§8.1）：`list-panes`、`capture-pane`、`display-message`、`send-keys`、`load-buffer`、`paste-buffer`、`new-session`、`refresh-client`、`attach-session`。所有命令只在 `src/tmux/cmd.rs` 里拼。不出现 `set-option`、`bind-key`、`kill-*`、`source-file`。
- 粘贴用名字以 `rapp-` 开头的缓冲区，贴完即删（`paste-buffer -d`）。
- 控制模式的客户端只在有人看这个会话时接着；没人看时只用一次性命令（§8.2）。
- 给 tmux 发命令时用它的会话编号（`$3`）和面板编号（`%5`），不用名字（§5）。
- `term:` 标识只在 `src/id.rs` 里解析和拼（§5）。
- 线上的消息里不出现 tmux 专有的词；面板在线上是一个不透明的字符串。
- JSON 行，UTF-8，一行（含换行符）不超过 65536 字节（§7）。
- 屏幕的每一行是 `capture-pane -e` 吐出来的带颜色转义的文字串，被控端不解析它（§7）。
- 尺寸（§8.3）：会话没有别的客户端接着时，按主控台给的行列数设；有别的客户端接着时不设，除非收到“按我的屏幕重排”。
- 数值：没人看时每 2 秒问一次列表；未读是“有动静后连续 3 秒安静”；tmux 版本下限 3.2；一段粘贴最多 1 MiB（1048576 字节）。这份计划补的：取屏最多每 50 毫秒一次；看的时候每 2 秒无条件重取一次；主控台给的行列数收在 20–500 列、5–200 行之内。
- 日志和错误信息里不出现屏幕内容和输入内容（§14）。
- 命令行守平台规格（`2026-11-11-rapp-platform-design.md`）§5 的通用约定：加 `--json` 时 stdout 只有 JSON 行；退出码 0 正常、1 运行时错误、2 参数错误。
- 测试只用独立的 tmux 服务（`-L rapp-term-test-<pid>-<序号>`，启动时带 `-f /dev/null`），绝不碰默认的那个；只停自己起的服务。机器上没有 tmux 时这些测试打印一行说明后跳过；设了 `RAPP_TERM_REQUIRE_TMUX=1` 时没有 tmux 算失败。
- 提交信息：`feat(term): …`、`test(term): …`、`docs: …`。每次提交前按文件名 `git add`；不用 `git add -u/-A/.`，不用 `git stash/checkout/restore/reset`。
- 用户和别的会话同时在改仓库。在单独的 git worktree 里、分支 `feat/term` 上做（执行时用 superpowers:using-git-worktrees）。不碰 `README.md`、`docs/archives/` 和未跟踪的文件。`rust/Cargo.toml` 只加任务 1 写明的两行。
- 不跑 `cargo fmt`；新建的 Rust 文件只用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。
- 每个任务结束时 `cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term` 全过，`cargo clippy -p rapp-term --all-targets -- -D warnings` 无警告。

## Review Focus

规格没有明说、最可能伤到用户的五种情况，按可能性排。每条都在负责的任务里有测试：

1. **会话名、窗口名里有空格、引号、中日文**：列表不能解析错，后面的命令必须打到对的会话上。（任务 3）
2. **正在看的会话没了**（里面的程序退出、别人 `kill-session`、SSH 断了）：泵要发一条说明原因的错误然后结束，不能挂着不动。（任务 5、11）
3. **输出刷屏而主控台迟迟不确认**（弱网）：被控端手里最多只留一屏，内存不涨；确认一到，发的是最新的。（任务 7、11）
4. **有别人接着时主控台报了自己的行列数**：不能改掉别人的尺寸。这是 §1“不能出现的结果”的第一条。（任务 9）
5. **SSH 目标以 `-` 开头或带空白**：会被 `ssh` 当成选项。必须在起进程之前拒绝。（任务 2）

## File Structure

```
rust/term/
  Cargo.toml
  src/
    lib.rs           模块声明和对外的名字
    id.rs            term: 标识的解析和拼接（唯一的一处）
    runner.rs        执行器：本机 / ssh；参数怎么拼；失败原因的分类
    tmux/
      mod.rs         Tmux：一次性命令（列表、取屏、历史、送键、粘贴、新开、版本）
      cmd.rs         所有 tmux 命令在这里拼；允许的命令名单
      parse.rs       解析 -F 输出的纯函数
      control.rs     控制模式客户端：命令通道、脏面板、布局变化、退出
    screen.rs        Screen：一屏；和上一屏比出变了的行
    proto.rs         线上的消息；一行的上限；一屏拆成几条
    sender.rs        发送闸门：只留最新，确认后才发下一条
    keys.rs          线上的键名 → tmux 的键名；文字 → 码点
    unread.rs        未读的判定
    session.rs       会话泵：读 In、写 Out，把上面的串起来
    main.rs          命令行：version、list、watch、run
  tests/
    common/mod.rs    起一个独立的 tmux 服务；没有 tmux 时跳过
    live.rs          对着真的 tmux 的测试
```

---

### Task 0: 探查（T0，代码不留）

**Files:**
- Modify: 本文件末尾的“探查结果”表
- Modify: `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md` §17（每条后面写上结论）

四件事来自 §17。每件只跑命令、记结论，不写进仓库的代码。全程用独立的 tmux 服务（`tmux -L rapp-probe -f /dev/null …`），做完 `tmux -L rapp-probe kill-server`。

- [ ] **Step 1: 取 Claude Code 和 Codex 的真实界面**

  在 `tmux -L rapp-probe new-session -d -s p1 -x 120 -y 40 claude` 里让它回答一句带中日文和代码块的话，然后 `capture-pane -e -p -t p1` 存成临时文件，`display-message -p -t p1 '#{cursor_x} #{cursor_y} #{cursor_flag} #{alternate_on}'` 记下光标。对 `codex` 重复一次。
  通过的标准：每一行按东亚宽度算不超过 120 列；光标落在输入框那一行；把临时文件 `cat` 到一个 120×40 的真终端里，请用户看一眼和原画面是否一致。
  哪一个 CLI 没装或没登录，记“未测”并写明是哪个。

- [ ] **Step 2: 整段粘贴**

  往 Step 1 的两个会话里各贴一段三行的中文：`printf '第一行\n第二行\n第三行' | tmux -L rapp-probe load-buffer -b rapp-p - && tmux -L rapp-probe paste-buffer -p -d -b rapp-p -t p1`，再取屏。
  通过的标准：三行都在输入框里，没有被提交（没有出现新的一轮回答）。

- [ ] **Step 3: 从后台服务里用 SSH**

  先问用户要一个平时能免密码 `ssh` 上去、装了 tmux 的主机。没有就记“未测”，后面的任务不受影响。
  有的话：写一个临时的 LaunchAgent（`~/Library/LaunchAgents/com.rapp.probe.plist`），让它执行 `ssh -o BatchMode=yes <目标> 'command -v tmux && tmux -V'`，输出写到 `/tmp/rapp-probe-ssh.txt`；`launchctl bootstrap gui/$UID` 它，看结果，再 `launchctl bootout` 并删掉 plist。
  记下：连没连上；失败时 stderr 的原话；`command -v tmux` 找没找到。

- [ ] **Step 4: 服务起的 tmux 活不活得过服务被停掉**

  macOS：临时 LaunchAgent 执行 `tmux -L rapp-probe4 -f /dev/null new-session -d 'sleep 600'` 然后 `sleep 30`。在它还活着时 `launchctl bootout` 它，再 `tmux -L rapp-probe4 ls`。
  Linux（有 Omarchy 机器时）：同样的事用一个临时的 systemd 用户单元做两遍，一遍直接起，一遍经 `systemd-run --user --scope --quiet`。
  记下每种情况下会话还在不在。这一条的结论给下一份计划（worker 新开会话）用，不挡这份计划。

- [ ] **Step 5: 写结论，停下来的条件**

  把四条结论填进本文件末尾的表和规格 §17，提交：`git add` 这两个文件，`git commit -m "docs: terminal layer probes — results"`。
  **Step 1 或 Step 2 没通过，就停在这里，把现象报给用户**：那意味着“问 tmux 要屏幕”这条路对这个 CLI 不够用，要回到规格去改，不是在计划里绕过去。

---

### Task 1: crate 骨架和 `term:` 标识

**Files:**
- Create: `rust/term/Cargo.toml`、`rust/term/src/lib.rs`、`rust/term/src/id.rs`、`rust/term/src/main.rs`
- Modify: `rust/Cargo.toml`（`members` 里加 `"term"`；`[workspace.dependencies]` 里加 `rapp-term = { path = "term" }`）

**Interfaces:**
- Produces: `rapp_term::id::TermId { backend: String, host: Option<String>, name: String }`，`TermId::parse(&str) -> anyhow::Result<TermId>`，`impl Display`。

- [ ] **Step 1: 建 crate**

  `Cargo.toml` 照 `rust/update/Cargo.toml` 的写法：依赖 `anyhow`、`serde`、`serde_json`、`tokio`（都用 workspace 的）；`[dev-dependencies]` `tempfile`；`[[bin]] name = "rapp-term"`。`main.rs` 先只有一个打印用法并以 2 退出的 `main`。

- [ ] **Step 2: 写失败的测试**（`id.rs` 里的 `#[cfg(test)]`）

```rust
#[test] fn parses_and_prints() {
    let t = TermId::parse("term:tmux:work").unwrap();
    assert_eq!((t.backend.as_str(), t.host.as_deref(), t.name.as_str()), ("tmux", None, "work"));
    let t = TermId::parse("term:tmux@gpu1:训练 run:2").unwrap();
    assert_eq!((t.host.as_deref(), t.name.as_str()), (Some("gpu1"), "训练 run:2"));
    assert_eq!(t.to_string(), "term:tmux@gpu1:训练 run:2");
}
#[test] fn rejects_malformed() {
    for bad in ["tmux:work", "term:", "term::x", "term:tmux:", "term:TMUX:x", "term:tmux@:x", "term:tmux@a b:x", "com.apple.Safari"] {
        assert!(TermId::parse(bad).is_err(), "{bad}");
    }
}
```

- [ ] **Step 3: 跑一下确认失败** — `cd rust && cargo test -p rapp-term id::`，预期：编译不过（`TermId` 不存在）。

- [ ] **Step 4: 实现** — 格式 `term:<后端>[@<主机>]:<名字>`。后端 `[a-z0-9]+`；主机 `[A-Za-z0-9._-]+`；名字是第二个冒号之后的全部，非空，可以含冒号和空格。

- [ ] **Step 5: 跑测试、clippy，提交** — `git add rust/Cargo.toml rust/Cargo.lock rust/term`，`git commit -m "feat(term): crate skeleton and the term: id"`。

---

### Task 2: 执行器

**Files:**
- Create: `rust/term/src/runner.rs`

**Interfaces:**
- Produces:
  - `enum Runner { Local, Ssh { dest: String, ctl_dir: PathBuf } }`（`Clone + Debug`）
  - `Runner::ssh(dest: &str, ctl_dir: &Path) -> anyhow::Result<Runner>`（在这里校验目标）
  - `Runner::argv(&self, program: &str, args: &[String]) -> Vec<String>`
  - `Runner::command(&self, program: &str, args: &[String]) -> tokio::process::Command`（就是把 `argv` 装进去）
  - `sh_quote(&str) -> String`
  - `enum RunFail { HostKey, Auth, Unreachable, NoProgram, Other(String) }`，`classify(code: Option<i32>, stderr: &str) -> RunFail`，`impl Display`（英文短句，界面以后译成中文）

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn local_argv_is_the_program_itself() {
    assert_eq!(Runner::Local.argv("tmux", &["-V".into()]), ["tmux", "-V"]);
}
#[test] fn ssh_argv_is_exact() {
    let r = Runner::ssh("me@gpu1.lab", Path::new("/tmp/c")).unwrap();
    let a = r.argv("/opt/homebrew/bin/tmux", &["list-panes".into(), "-F".into(), "#{pane_id} it's".into()]);
    let mut want = vec!["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"];
    #[cfg(unix)] want.extend(["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/c/%C", "-o", "ControlPersist=60"]);
    want.extend(["--", "me@gpu1.lab", r#"exec '/opt/homebrew/bin/tmux' 'list-panes' '-F' '#{pane_id} it'\''s'"#]);
    assert_eq!(a, want);
}
#[test] fn ssh_rejects_dests_that_ssh_would_misread() {       // Review Focus 5
    for bad in ["-oProxyCommand=x", "", " host", "ho st", "host\n", "a\tb", "-"] {
        assert!(Runner::ssh(bad, Path::new("/tmp/c")).is_err(), "{bad:?}");
    }
    assert!(Runner::ssh("me@gpu1.lab", Path::new("/tmp/c")).is_ok());
    assert!(Runner::ssh("gpu1", Path::new("/tmp/c")).is_ok());
}
#[test] fn classifies_failures() {
    assert!(matches!(classify(Some(255), "Host key verification failed."), RunFail::HostKey));
    assert!(matches!(classify(Some(255), "me@h: Permission denied (publickey)."), RunFail::Auth));
    assert!(matches!(classify(Some(255), "ssh: connect to host h port 22: Connection refused"), RunFail::Unreachable));
    assert!(matches!(classify(Some(255), "ssh: Could not resolve hostname h"), RunFail::Unreachable));
    assert!(matches!(classify(Some(127), "sh: tmux: command not found"), RunFail::NoProgram));
    assert!(matches!(classify(Some(1), "no server running on /tmp/tmux-501/default"), RunFail::Other(_)));
}
```

- [ ] **Step 2: 跑一下确认失败** — `cargo test -p rapp-term runner::`。
- [ ] **Step 3: 实现** — 目标的规则：非空，不以 `-` 开头，不含空白和控制字符。`sh_quote`：整个包进单引号，里面的 `'` 写成 `'\''`。`classify` 按 stderr 里的这些片段判断（不分大小写）：`host key verification failed`；`permission denied`；`connection refused`、`connection timed out`、`could not resolve hostname`、`no route to host`、`network is unreachable`；退出码 127 或 `command not found`。`Display` 的文字里只有类别和 `Other` 的原文，没有别的。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): runners — local process or ssh"`。

---

### Task 3: tmux 的命令、版本、列表

**Files:**
- Create: `rust/term/src/tmux/mod.rs`、`rust/term/src/tmux/cmd.rs`、`rust/term/src/tmux/parse.rs`、`rust/term/tests/common/mod.rs`、`rust/term/tests/live.rs`

**Interfaces:**
- Consumes: `Runner`、`RunFail`、`classify`（任务 2）。
- Produces:
  - `struct Tmux { pub runner: Runner, pub bin: String, pub socket: Option<String> }`（`Clone`）；`Tmux::local() -> Tmux`（`bin` 是 `"tmux"`）
  - `Tmux::run(&self, args: &[String]) -> anyhow::Result<String>`，`Tmux::run_stdin(&self, args: &[String], stdin: &[u8]) -> anyhow::Result<String>`（一次性进程；失败时错误里带 `RunFail` 的 `Display`）
  - `Tmux::version(&self) -> anyhow::Result<(u32, u32)>`，`Tmux::check(&self) -> anyhow::Result<()>`
  - `Tmux::list(&self) -> anyhow::Result<Vec<PaneInfo>>`
  - `struct PaneInfo { session_id, session, window_id, window, pane, command, title: String, window_index, pane_index, attached: u32, activity: u64, cols, rows: u16, dead: bool }`
  - `cmd::VERBS: &[&str]`；`cmd::list_panes() -> Vec<String>`；`cmd::channel_line(args: &[String]) -> anyhow::Result<String>`
  - `parse::version(&str) -> Option<(u32, u32)>`，`parse::panes(&str) -> Vec<PaneInfo>`
  - 测试用：`common::Server`（`Server::start() -> Option<Server>`，`server.tmux() -> Tmux`，`server.raw(&[&str]) -> String`，`Drop` 时 `kill-server`）

- [ ] **Step 1: 写失败的单元测试**

```rust
// cmd.rs
#[test] fn every_builder_uses_an_allowed_verb() {
    assert_eq!(VERBS, ["list-panes", "capture-pane", "display-message", "send-keys", "load-buffer", "paste-buffer", "new-session", "refresh-client", "attach-session"]);
    assert_eq!(list_panes()[0], "list-panes");
}
#[test] fn channel_line_quotes_and_refuses_what_it_cannot_quote() {
    assert_eq!(channel_line(&["display-message".into(), "-p".into(), "#{cursor_x} #{cursor_y}".into()]).unwrap(), "'display-message' '-p' '#{cursor_x} #{cursor_y}'");
    assert!(channel_line(&["send-keys".into(), "it's".into()]).is_err());
    assert!(channel_line(&["send-keys".into(), "a\nb".into()]).is_err());
}
// parse.rs
#[test] fn parses_versions() {
    assert_eq!(version("tmux 3.4"), Some((3, 4)));
    assert_eq!(version("tmux 3.2a"), Some((3, 2)));
    assert_eq!(version("tmux next-3.5"), Some((3, 5)));
    assert_eq!(version("screen 4.9"), None);
}
#[test] fn parses_pane_rows_and_skips_broken_ones() {
    let row = "$3\t我的 \"work\"\t@7\t1\tmain win\t%12\t0\tclaude\t0\t1794592454\t2\t212\t58\ttitle with spaces";
    let v = panes(&format!("{row}\nbroken line\n"));
    assert_eq!(v.len(), 1);
    assert_eq!((v[0].session_id.as_str(), v[0].session.as_str(), v[0].pane.as_str()), ("$3", "我的 \"work\"", "%12"));
    assert_eq!((v[0].attached, v[0].activity, v[0].cols, v[0].rows, v[0].dead), (2, 1794592454, 212, 58, false));
}
```

- [ ] **Step 2: 写失败的 live 测试**（`tests/live.rs`；每个测试开头 `let Some(s) = common::Server::start() else { return };`）

```rust
#[tokio::test] async fn version_is_at_least_3_2() {
    let Some(s) = common::Server::start() else { return };
    s.tmux().check().await.unwrap();
}
#[tokio::test] async fn lists_sessions_with_awkward_names() {            // Review Focus 1
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "我的 \"work\" it's", "-x", "100", "-y", "30"]);
    s.raw(&["new-session", "-d", "-s", "plain", "-x", "80", "-y", "24"]);
    let v = s.tmux().list().await.unwrap();
    assert_eq!(v.len(), 2);
    let w = v.iter().find(|p| p.session.contains("work")).unwrap();
    assert_eq!((w.session.as_str(), w.cols, w.rows), ("我的 \"work\" it's", 100, 30));
    assert!(w.session_id.starts_with('$') && w.pane.starts_with('%'));
}
#[tokio::test] async fn no_server_is_an_empty_list_not_an_error() {
    if common::Server::start().is_none() { return }
    let t = Tmux { runner: Runner::Local, bin: "tmux".into(), socket: Some(format!("rapp-term-test-none-{}", std::process::id())) };
    assert!(t.list().await.unwrap().is_empty());
}
```

- [ ] **Step 3: 跑一下确认失败。**
- [ ] **Step 4: 实现**
  - `common::Server::start()`：`tmux -V` 跑不起来时，`RAPP_TERM_REQUIRE_TMUX=1` 就 panic，否则 `eprintln!("skipped: tmux is not installed")` 返回 `None`。否则先把服务起好，让它不读用户的配置、也不因为没有会话而退出。夹具自己依次发三条（不经 `Tmux`）：`tmux -L <socket> -f /dev/null new-session -d -s boot`，`set -g exit-empty off`，`kill-session -t boot`。socket 名是 `rapp-term-test-<pid>-<原子计数>`。之后服务在、会话数为 0。`raw()` 每次都带 `-L <socket> -f /dev/null`。
  - `Tmux::run`：`runner.command(&bin, [("-L", socket)?, args…])`，取 stdout；非零退出时 `bail!` 一条带 `classify(...)` 的错误。
  - `list_panes()` 的格式串：`-a -F`，字段用制表符隔开，顺序就是上面单元测试里那一行：`session_id session_name window_id window_index window_name pane_id pane_index pane_current_command pane_dead window_activity session_attached pane_width pane_height pane_title`。
  - `list()`：stderr 里有 `no server running`、`No such file or directory`、`no current target`、`no sessions` 之一时返回空表（tmux 3.4 实测：服务在而会话数为 0 时报的是 `no current target`）。
  - `check()`：低于 3.2 时报 `tmux 3.2 or newer is required (found X.Y)`。
  - `channel_line`：每个参数包进单引号；含 `'`、换行或回车就报错。
- [ ] **Step 5: 跑测试、clippy，提交** — `git commit -m "feat(term): tmux commands, version check and pane list"`。

---

### Task 4: 一屏，和取屏

**Files:**
- Create: `rust/term/src/screen.rs`
- Modify: `rust/term/src/tmux/cmd.rs`、`rust/term/src/tmux/mod.rs`、`rust/term/tests/live.rs`

**Interfaces:**
- Produces:
  - `struct Screen { pub cols, rows, cx, cy: u16, pub cursor, alt: bool, pub lines: Vec<String> }`（`Clone + PartialEq + Debug`）
  - `Screen::from_capture(text: &str, meta: &str) -> anyhow::Result<Screen>`
  - `Screen::changed(&self, prev: Option<&Screen>) -> Vec<(u16, String)>`
  - `cmd::capture(pane: &str) -> Vec<String>`，`cmd::meta(pane: &str) -> Vec<String>`，`cmd::history(pane: &str, before: u32, lines: u32) -> Vec<String>`
  - `Tmux::capture(&self, pane: &str) -> anyhow::Result<Screen>`，`Tmux::history(&self, pane: &str, before: u32, lines: u32) -> anyhow::Result<Vec<String>>`

- [ ] **Step 1: 写失败的测试**

```rust
// screen.rs
#[test] fn capture_is_padded_to_the_pane_height() {
    let s = Screen::from_capture("a\n\x1b[1mb\x1b[0m\n", "3 1 1 0 80 4").unwrap();
    assert_eq!(s.lines, ["a", "\x1b[1mb\x1b[0m", "", ""]);
    assert_eq!((s.cols, s.rows, s.cx, s.cy, s.cursor, s.alt), (80, 4, 3, 1, true, false));
}
#[test] fn changed_rows_only() {
    let a = Screen::from_capture("a\nb\nc\n", "0 0 1 0 80 3").unwrap();
    let mut b = a.clone(); b.lines[1] = "B".into();
    assert_eq!(b.changed(Some(&a)), [(1, "B".to_string())]);
    assert_eq!(b.changed(None).len(), 3);
    let wider = Screen::from_capture("a\nB\nc\n", "0 0 1 0 100 3").unwrap();
    assert_eq!(wider.changed(Some(&a)).len(), 3);          // 尺寸变了就是整屏
}
// live.rs
#[tokio::test] async fn captures_cjk_truecolor_and_cursor() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c", "-x", "100", "-y", "30", "printf '中文 日本語 \\033[38;2;255;100;0mtc\\033[0m \\033[1;4mbu\\033[0m\\n'; sleep 60"]);
    common::settle().await;
    let pane = s.tmux().list().await.unwrap()[0].pane.clone();
    let sc = s.tmux().capture(&pane).await.unwrap();
    assert_eq!((sc.cols, sc.rows, sc.lines.len()), (100, 30, 30));
    assert!(sc.lines[0].starts_with("中文 日本語 \x1b[38;2;255;100;0mtc"));
    assert_eq!((sc.cx, sc.cy), (0, 1));
}
#[tokio::test] async fn history_returns_lines_above_the_screen() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "h", "-x", "80", "-y", "5", "seq 1 40; sleep 60"]);
    common::settle().await;
    let pane = s.tmux().list().await.unwrap()[0].pane.clone();
    let h = s.tmux().history(&pane, 0, 10).await.unwrap();
    assert_eq!(h.len(), 10);
    assert_eq!(h.last().unwrap(), &s.tmux().capture(&pane).await.unwrap().lines[0].parse::<u32>().map(|n| (n - 1).to_string()).unwrap());
}
```

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现**
  - `meta` 的格式串：`#{cursor_x} #{cursor_y} #{cursor_flag} #{alternate_on} #{pane_width} #{pane_height}`，用 `display-message -p -t <pane>`。
  - `capture`：`capture-pane -e -p -t <pane>`。`from_capture` 按 `\n` 切，去掉末尾换行带出的那一个空串，再补空串或截断到正好 `rows` 行。
  - `history(before, lines)`：`capture-pane -e -p -t <pane> -S -(before+lines) -E -(before+1)`。
  - `common::settle()`：`tokio::time::sleep(300ms)`。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): screens — capture, cursor, history, changed rows"`。

---

### Task 5: 控制模式的客户端

**Files:**
- Create: `rust/term/src/tmux/control.rs`
- Modify: `rust/term/src/tmux/cmd.rs`、`rust/term/tests/live.rs`

**Interfaces:**
- Consumes: `Tmux`、`cmd::channel_line`。
- Produces:
  - `enum Event { Layout, Exit(String) }`
  - `struct Control`（`Clone`，内部 `Arc`）
  - `Control::attach(tmux: &Tmux, session_id: &str) -> anyhow::Result<(Control, tokio::sync::mpsc::UnboundedReceiver<Event>)>`
  - `Control::from_io<R, W>(r: R, w: W) -> anyhow::Result<(Control, UnboundedReceiver<Event>)> where R: AsyncBufRead + Unpin + Send + 'static, W: AsyncWrite + Unpin + Send + 'static`（`attach` 起了进程以后就调它；测试直接用它）
  - `Control::command(&self, args: &[String]) -> anyhow::Result<Vec<String>>`（`%begin` 和 `%end` 之间的行；`%error` 变成 `Err`）
  - `Control::dirty(&self) -> Vec<String>`（等到有面板脏了，返回这些面板并清空）
  - `Control::detach(self)`（关 stdin；1 秒内没退出就杀掉自己起的这个进程）
  - `enum Line { Begin, End, Error, Output(String), Layout, Exit(String), Other }`，`parse_line(&str) -> Line`
  - `cmd::attach(session_id: &str) -> Vec<String>`（`-C attach-session -t <id>`）

- [ ] **Step 1: 写失败的测试**

```rust
// control.rs
#[test] fn classifies_control_lines() {
    assert!(matches!(parse_line("%begin 1794592454 12 0"), Line::Begin));
    assert!(matches!(parse_line("%end 1794592454 12 0"), Line::End));
    assert!(matches!(parse_line("%error 1794592454 12 0"), Line::Error));
    assert!(matches!(parse_line("%output %7 hello\\012"), Line::Output(p) if p == "%7"));
    assert!(matches!(parse_line("%extended-output %7 120 : x"), Line::Output(p) if p == "%7"));
    for l in ["%window-add @3", "%window-close @3", "%layout-change @1 abcd,80x24,0,0,1 abcd,80x24,0,0,1 *", "%window-renamed @1 x", "%unlinked-window-close @9"] {
        assert!(matches!(parse_line(l), Line::Layout), "{l}");
    }
    assert!(matches!(parse_line("%exit server exited"), Line::Exit(r) if r == "server exited"));
    assert!(matches!(parse_line("%exit"), Line::Exit(r) if r.is_empty()));      // kill-session 时就是光秃秃的一行（tmux 3.4 实测）
    assert!(matches!(parse_line("%session-changed $1 x"), Line::Other));
}
#[tokio::test] async fn a_stream_that_just_ends_is_reported_as_connection_closed() {     // Review Focus 2：SSH 断了
    let (mut tmux_side, ours) = tokio::io::duplex(4096);
    let (r, w) = tokio::io::split(ours);
    tokio::io::AsyncWriteExt::write_all(&mut tmux_side, b"%begin 1 1 0\n%end 1 1 0\n").await.unwrap();
    let (_ctl, mut ev) = Control::from_io(tokio::io::BufReader::new(r), w).await.unwrap();
    drop(tmux_side);
    assert!(matches!(ev.recv().await, Some(Event::Exit(r)) if r == "connection closed"));
}
// live.rs
#[tokio::test] async fn control_runs_commands_and_reports_dirty_panes_in_any_window() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c", "-x", "100", "-y", "30"]);
    s.raw(&["new-window", "-d", "-t", "c"]);
    let panes = s.tmux().list().await.unwrap();
    let (ctl, _ev) = Control::attach(&s.tmux(), &panes[0].session_id).await.unwrap();
    let out = ctl.command(&cmd::meta(&panes[0].pane)).await.unwrap();
    assert_eq!(out.len(), 1);
    let e = ctl.command(&cmd::capture("%999")).await.unwrap_err();            // 通道上的 %error 变成 Err
    assert!(e.to_string().contains("can't find pane"));
    s.raw(&["send-keys", "-t", &panes[1].pane, "echo hi", "Enter"]);      // 第二个窗口里的面板
    let d = tokio::time::timeout(std::time::Duration::from_secs(2), ctl.dirty()).await.unwrap();
    assert!(d.contains(&panes[1].pane));
    ctl.detach().await;
}
#[tokio::test] async fn control_reports_exit_when_the_session_is_killed() {   // Review Focus 2
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c"]);
    let id = s.tmux().list().await.unwrap()[0].session_id.clone();
    let (_ctl, mut ev) = Control::attach(&s.tmux(), &id).await.unwrap();
    s.raw(&["kill-session", "-t", "c"]);
    let reason = tokio::time::timeout(std::time::Duration::from_secs(2), async { loop { if let Some(Event::Exit(r)) = ev.recv().await { break r } } }).await.unwrap();
    assert_ne!(reason, "connection closed");     // 是 tmux 说的 %exit，不是连接断了
}
#[tokio::test] async fn control_client_does_not_resize_the_window() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c", "-x", "100", "-y", "30"]);
    let p = s.tmux().list().await.unwrap()[0].clone();
    let (ctl, _ev) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    let after = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((after.cols, after.rows), (p.cols, p.rows));
    ctl.detach().await;
}
```

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现**
  - 进程：`tmux [-L socket] -C attach-session -t <id>`，经 `tmux.runner`，stdin、stdout 接管道。接上以后 tmux 先为 attach 自己发一个 `%begin…%end` 块，把它吃掉再返回。
  - 一个读线程（tokio 任务）逐行读 stdout：`Begin` 开始收集；`End` / `Error` 把收集到的行交给最早那个在等的 `command`；`Output(pane)` 把面板编号放进一个 `Mutex<HashSet<String>>` 并 `notify`，**内容丢掉不存**；`Layout`、`Exit` 发进事件通道。读到 EOF 而之前没有 `Exit`，补发一个 `Exit("connection closed")`（SSH 断了走这里）。
  - `command`：经 `channel_line` 写一行，按先后顺序等结果。`command` 之间用一个 `tokio::sync::Mutex` 串行。
  - `Layout` 的行前缀：`%window-add`、`%window-close`、`%window-renamed`、`%layout-change`、`%unlinked-window-add`、`%unlinked-window-close`、`%session-window-changed`、`%pane-mode-changed`。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): control-mode client — command channel, dirty panes, exit"`。

---

### Task 6: 线上的消息

**Files:**
- Create: `rust/term/src/proto.rs`

**Interfaces:**
- Consumes: `Screen`。
- Produces:
  - `const PROTO: u32 = 1; const MAX_LINE: usize = 65536;`
  - `enum Out`（`#[serde(tag = "t", rename_all = "snake_case")]`）：`Hello { v: u32, backend: String }`、`Panes { panes: Vec<Pane> }`、`Screen { pane: String, rev: u64, cols: u16, rows: u16, cx: u16, cy: u16, cursor: bool, alt: bool, full: bool, more: bool, lines: Vec<(u16, String)> }`、`History { pane: String, before: u32, lines: Vec<String> }`、`Pasted { ok: bool, error: Option<String> }`（`error` 为 `None` 时不出现）、`Error { error: String }`
  - `struct Pane { id, window, title, command: String, cols, rows: u16, dead: bool }`
  - `enum In`（同样的 tag）：`View { pane: Option<String>, cols: u16, rows: u16 }`、`Ack { rev: u64 }`、`Text { pane: String, data: String, enter: bool }`、`Keys { pane: String, keys: Vec<String> }`、`Type { pane: String, text: String }`、`History { pane: String, before: u32, lines: u32 }`、`Refit { pane: String, cols: u16, rows: u16 }`
  - `encode(&Out) -> String`（一行，带结尾的 `\n`）
  - `screen_msgs(pane: &str, rev: u64, s: &Screen, lines: Vec<(u16, String)>, full: bool) -> Vec<Out>`

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn wire_shapes_are_exact() {
    assert_eq!(encode(&Out::Hello { v: 1, backend: "tmux".into() }), "{\"t\":\"hello\",\"v\":1,\"backend\":\"tmux\"}\n");
    assert_eq!(encode(&Out::Pasted { ok: true, error: None }), "{\"t\":\"pasted\",\"ok\":true}\n");
    let i: In = serde_json::from_str(r#"{"t":"view","pane":"%3","cols":118,"rows":38}"#).unwrap();
    assert!(matches!(i, In::View { pane: Some(p), cols: 118, rows: 38 } if p == "%3"));
    let i: In = serde_json::from_str(r#"{"t":"view","pane":null,"cols":0,"rows":0}"#).unwrap();
    assert!(matches!(i, In::View { pane: None, .. }));
    assert!(serde_json::from_str::<In>(r#"{"t":"set_option"}"#).is_err());
}
#[test] fn big_screens_split_under_the_line_limit() {
    let s = Screen { cols: 500, rows: 200, cx: 0, cy: 0, cursor: true, alt: false, lines: vec!["\x1b[38;2;1;2;3mx".repeat(60); 200] };
    let msgs = screen_msgs("%1", 7, &s, s.changed(None), true);
    assert!(msgs.len() > 1);
    let mut seen = 0;
    for (i, m) in msgs.iter().enumerate() {
        assert!(encode(m).len() <= MAX_LINE);
        let Out::Screen { rev, more, lines, full, .. } = m else { panic!() };
        assert_eq!((*rev, *full, *more), (7, true, i + 1 < msgs.len()));
        seen += lines.len();
    }
    assert_eq!(seen, 200);
}
#[test] fn a_small_change_is_one_message() {
    let s = Screen { cols: 80, rows: 24, cx: 1, cy: 2, cursor: true, alt: false, lines: vec![String::new(); 24] };
    assert_eq!(screen_msgs("%1", 2, &s, vec![(3, "x".into())], false).len(), 1);
}
```

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现** — `screen_msgs` 按行累加编码后的长度来切；没有变化的行但光标动了，也发一条 `lines` 为空的 `Screen`。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): wire messages and the 64 KiB line limit"`。

---

### Task 7: 发送闸门

**Files:**
- Create: `rust/term/src/sender.rs`

**Interfaces:**
- Consumes: `Screen`、`Out`、`screen_msgs`。
- Produces: `struct Sender`；`Sender::new(pane: &str) -> Sender`；`Sender::offer(&mut self, s: Screen) -> Vec<Out>`；`Sender::ack(&mut self, rev: u64) -> Vec<Out>`。

- [ ] **Step 1: 写失败的测试**

```rust
fn scr(tag: &str) -> Screen { Screen { cols: 80, rows: 3, cx: 0, cy: 0, cursor: true, alt: false, lines: vec![tag.into(), "".into(), "".into()] } }
fn rev_of(v: &[Out]) -> u64 { match &v[0] { Out::Screen { rev, .. } => *rev, _ => panic!() } }

#[test] fn first_screen_goes_out_whole() {
    let mut s = Sender::new("%1");
    let out = s.offer(scr("a"));
    assert!(matches!(&out[0], Out::Screen { full: true, rev: 1, lines, .. } if lines.len() == 3));
}
#[test] fn nothing_more_goes_out_until_the_ack_and_then_only_the_latest() {     // Review Focus 3
    let mut s = Sender::new("%1");
    let r1 = rev_of(&s.offer(scr("a")));
    for i in 0..1000 { assert!(s.offer(scr(&format!("flood {i}"))).is_empty()); }
    let out = s.ack(r1);
    assert!(matches!(&out[0], Out::Screen { full: false, rev: 2, lines, .. } if lines == &[(0, "flood 999".to_string())]));
}
#[test] fn unchanged_screens_and_stale_acks_send_nothing() {
    let mut s = Sender::new("%1");
    let r1 = rev_of(&s.offer(scr("a")));
    assert!(s.ack(r1).is_empty());
    assert!(s.offer(scr("a")).is_empty());
    assert!(s.ack(99).is_empty());
    assert!(s.ack(r1).is_empty());
}
#[test] fn a_cursor_move_alone_is_sent() {
    let mut s = Sender::new("%1");
    let r1 = rev_of(&s.offer(scr("a")));
    s.ack(r1);
    let mut moved = scr("a"); moved.cx = 5;
    assert!(matches!(&s.offer(moved)[0], Out::Screen { cx: 5, lines, .. } if lines.is_empty()));
}
```

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现** — 三个槽：对方已确认的一屏、在途的一屏（带版本号）、最新的一屏。`offer` 只换掉“最新”；没有在途的才发。`ack` 对上在途的版本号才算，然后比“已确认”和“最新”，不同就发。`Sender` 手里最多这三屏。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): send gate — only the latest screen, one in flight"`。

---

### Task 8: 送输入

**Files:**
- Create: `rust/term/src/keys.rs`
- Modify: `rust/term/src/tmux/cmd.rs`、`rust/term/src/tmux/mod.rs`、`rust/term/tests/live.rs`

**Interfaces:**
- Produces:
  - `keys::tmux_name(wire: &str) -> Option<String>`，`keys::utf8_hex(text: &str) -> Vec<String>`（UTF-8 的每个字节，两位小写十六进制。tmux 3.4 实测：`send-keys -H` 收的是字节，按码点发中日文会被丢掉）
  - `cmd::send_named(pane: &str, names: &[String]) -> Vec<String>`，`cmd::send_hex(pane: &str, hex: &[String]) -> Vec<String>`，`cmd::load_buffer(name: &str) -> Vec<String>`，`cmd::paste_buffer(name: &str, pane: &str) -> Vec<String>`
  - `const MAX_PASTE: usize = 1_048_576;`
  - `Tmux::paste(&self, pane: &str, text: &str, enter: bool) -> anyhow::Result<()>`
  - `Tmux::send(&self, args: Vec<String>) -> anyhow::Result<()>`（一次性地发 `send_named` / `send_hex` 拼出来的命令）

- [ ] **Step 1: 写失败的测试**

```rust
// keys.rs
#[test] fn maps_wire_names() {
    for (w, t) in [("Esc", "Escape"), ("Enter", "Enter"), ("Tab", "Tab"), ("Shift-Tab", "BTab"), ("Backspace", "BSpace"), ("Delete", "DC"),
                   ("Up", "Up"), ("Down", "Down"), ("Left", "Left"), ("Right", "Right"), ("Home", "Home"), ("End", "End"),
                   ("PageUp", "PPage"), ("PageDown", "NPage"), ("Ctrl-C", "C-c"), ("Ctrl-d", "C-d")] {
        assert_eq!(tmux_name(w).as_deref(), Some(t), "{w}");
    }
    for bad in ["", "Ctrl-", "Ctrl-1", "Ctrl-cc", "F13x", "set-option", "C-c"] { assert_eq!(tmux_name(bad), None, "{bad}"); }
}
#[test] fn text_becomes_utf8_bytes() { assert_eq!(utf8_hex("a中\n"), ["61", "e4", "b8", "ad", "0a"]); }
// live.rs
#[tokio::test] async fn types_cjk_and_named_keys() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "k", "-x", "80", "-y", "10", "cat"]);
    let t = s.tmux(); let pane = t.list().await.unwrap()[0].pane.clone();
    t.send(cmd::send_hex(&pane, &keys::utf8_hex("你好 it's"))).await.unwrap();
    t.send(cmd::send_named(&pane, &["Enter".into()])).await.unwrap();
    common::settle().await;
    let sc = t.capture(&pane).await.unwrap();
    assert_eq!((sc.lines[0].as_str(), sc.lines[1].as_str()), ("你好 it's", "你好 it's"));
}
#[tokio::test] async fn pastes_multiline_text_as_one_bracketed_paste_and_leaves_no_buffer() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "p", "-x", "80", "-y", "10", "printf '\\033[?2004h'; cat -v"]);
    common::settle().await;
    let t = s.tmux(); let pane = t.list().await.unwrap()[0].pane.clone();
    t.paste(&pane, "第一行\n第二行 it's \"q\"", false).await.unwrap();
    common::settle().await;
    let sc = t.capture(&pane).await.unwrap();
    assert!(sc.lines[0].starts_with("^[[200~"));
    assert!(sc.lines.iter().any(|l| l.contains("^[[201~")));
    assert!(!s.raw(&["list-buffers"]).contains("rapp-"));
}
#[tokio::test] async fn refuses_a_paste_over_one_mebibyte() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "p", "cat"]);
    let t = s.tmux(); let pane = t.list().await.unwrap()[0].pane.clone();
    let e = t.paste(&pane, &"x".repeat(1_048_577), false).await.unwrap_err();
    assert_eq!(e.to_string(), "text is too long (1 MiB at most)");
}
```

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现**
  - `tmux_name`：上表逐项对应；`Ctrl-<一个字母>` 不分大小写映射成 `C-<小写>`；别的一律 `None`。
  - `send_named`：`send-keys -t <pane> <names…>`。`send_hex`：`send-keys -t <pane> -H <hex…>`。
  - `paste`：缓冲区名 `rapp-<进程号>-<原子计数>`；`run_stdin(load_buffer(name), text)`，再 `run(paste_buffer(name, pane))`，其中 `paste_buffer` 是 `paste-buffer -p -d -b <name> -t <pane>`；`enter` 为真再发一个 `Enter`。`load-buffer` 成功而 `paste-buffer` 失败时，缓冲区会留下：这种情况下再发一次带 `-d` 的 `paste-buffer` 到同一个面板没有意义，直接把错误交回去，并在错误里不带文字内容。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): input — named keys, typed text, bracketed paste"`。

---

### Task 9: 尺寸规则和新开

**Files:**
- Modify: `rust/term/src/tmux/cmd.rs`、`rust/term/src/tmux/mod.rs`、`rust/term/src/tmux/control.rs`、`rust/term/tests/live.rs`

**Interfaces:**
- Consumes: `Control`、`PaneInfo.attached`。
- Produces:
  - `cmd::set_size(cols: u16, rows: u16) -> Vec<String>`（`refresh-client -C <cols>x<rows>`）
  - `cmd::new_session(name: &str, cols: u16, rows: u16, command: &[String]) -> Vec<String>`
  - `fn clamp_size(cols: u16, rows: u16) -> (u16, u16)`（20–500，5–200）
  - `Control::fit(&self, tmux: &Tmux, session_id: &str, cols: u16, rows: u16, force: bool) -> anyhow::Result<bool>`（设了返回 `true`）
  - `Tmux::new_session(&self, name: &str, command: &[String], cols: u16, rows: u16) -> anyhow::Result<()>`

- [ ] **Step 1: 写失败的测试**

```rust
#[tokio::test] async fn sizes_the_window_when_nobody_else_is_attached() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "z", "-x", "100", "-y", "30"]);
    let p = s.tmux().list().await.unwrap()[0].clone();
    let (ctl, _e) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    assert!(ctl.fit(&s.tmux(), &p.session_id, 140, 45, false).await.unwrap());
    let after = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((after.cols, after.rows), (140, 45));
    ctl.detach().await;
}
#[tokio::test] async fn leaves_the_size_alone_when_someone_else_is_attached() {      // Review Focus 4
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "z", "-x", "100", "-y", "30"]);
    let p = s.tmux().list().await.unwrap()[0].clone();
    let (other, _e1) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();      // 扮演另一个接着的人
    other.command(&cmd::set_size(100, 30)).await.unwrap();
    let (ctl, _e2) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    assert!(!ctl.fit(&s.tmux(), &p.session_id, 140, 45, false).await.unwrap());
    let same = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((same.cols, same.rows), (100, 30));
    assert!(ctl.fit(&s.tmux(), &p.session_id, 140, 45, true).await.unwrap());        // “按我的屏幕重排”
    ctl.detach().await; other.detach().await;
}
#[tokio::test] async fn new_session_runs_the_command_at_the_given_size() {
    let Some(s) = common::Server::start() else { return };
    s.tmux().new_session("fix relay", &["sh".into(), "-c".into(), "echo it's up; sleep 60".into()], 118, 38).await.unwrap();
    common::settle().await;
    let p = s.tmux().list().await.unwrap().into_iter().find(|p| p.session == "fix relay").unwrap();
    assert_eq!((p.cols, p.rows), (118, 38));
    assert_eq!(s.tmux().capture(&p.pane).await.unwrap().lines[0], "it's up");
}
#[test] fn clamps_viewer_sizes() { assert_eq!(clamp_size(5, 2), (20, 5)); assert_eq!(clamp_size(9000, 9000), (500, 200)); assert_eq!(clamp_size(118, 38), (118, 38)); }
```

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现**
  - `fit`：`force` 为假时先看这个会话的 `attached`（来自 `tmux.list()`）。它把自己这个控制客户端也算在内，所以“有别人”是 `attached > 1`。
  - `new_session`：`new-session -d -s <name> -x <cols> -y <rows> <command 的每一项，各是一个参数>`。不要把命令拼成一个字符串：tmux 3.4 实测，多个参数时 tmux 直接按参数执行，不经 shell，引号不用处理；而把整条命令包成一个带引号的字符串时，会话一建就没了。`command` 为空时后面什么都不带（开默认的 shell）。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): size rule and new sessions"`。

---

### Task 10: 未读

**Files:**
- Create: `rust/term/src/unread.rs`

**Interfaces:**
- Produces: `const QUIET_SECS: u64 = 3;`，`struct Unread`（`Default`），`Unread::new(started: u64) -> Unread`，`Unread::seen(&mut self, session: &str, now: u64)`，`Unread::is_unread(&self, session: &str, activity: u64, now: u64) -> bool`。时间都是 Unix 秒。

- [ ] **Step 1: 写失败的测试**

```rust
#[test] fn unread_is_output_then_three_quiet_seconds_since_last_seen() {
    let mut u = Unread::new(1000);
    assert!(!u.is_unread("w", 990, 1100));     // 服务启动之前的输出不算
    assert!(!u.is_unread("w", 1050, 1052));    // 还在动
    assert!(u.is_unread("w", 1050, 1053));     // 安静满 3 秒
    u.seen("w", 1060);
    assert!(!u.is_unread("w", 1050, 1100));    // 看过了
    assert!(u.is_unread("w", 1070, 1073));     // 之后又有输出并停下
    assert!(u.is_unread("other", 1050, 1100)); // 各会话各算各的
}
```

- [ ] **Step 2–4: 确认失败，实现（一个 `HashMap<String, u64>` 加启动时间），跑测试、clippy，提交** — `git commit -m "feat(term): unread — output, then three quiet seconds"`。

---

### Task 11: 会话泵

**Files:**
- Create: `rust/term/src/session.rs`
- Modify: `rust/term/src/lib.rs`、`rust/term/tests/live.rs`

**Interfaces:**
- Consumes: 前面全部。
- Produces:
  - `struct Opts { pub poll: Duration, pub min_gap: Duration }`，`Opts::default()` 是 2 秒和 50 毫秒
  - `async fn run<R, W>(tmux: &Tmux, session: &str, r: R, w: W, unread: Arc<std::sync::Mutex<Unread>>, opts: Opts) -> anyhow::Result<()> where R: tokio::io::AsyncBufRead + Unpin, W: tokio::io::AsyncWrite + Unpin`
  - `fn panes_of(list: &[PaneInfo], session_id: &str) -> Vec<proto::Pane>`

**行为（每条都有下面的一个测试）：**
1. 按名字在 `tmux.list()` 里找会话。没有：写 `Error { error: "no such session" }`，返回 `Ok`。
2. 写 `Hello { v: 1, backend: "tmux" }`，再写 `Panes`。
3. `View { pane: Some(p), cols, rows }`：还没接控制客户端就接上；`fit(…, force: false)`；取屏；`Sender::offer`；写出去。换了面板就换一个新的 `Sender`。`View { pane: None, .. }`：`detach`。
4. 看着的时候：`Control::dirty()` 里有当前面板，就取屏并 `offer`，两次取屏之间至少隔 `min_gap`；每过 `poll` 无条件取一次，并重发变了的 `Panes`。每写出一条 `Screen` 都 `unread.seen(session, now)`。
5. `Ack` → `Sender::ack`。
6. `Keys`：每个键名过 `keys::tmux_name`，有一个不认识就写 `Error { error: "unknown key" }`，一个都不发。`Type` → `send_hex(pane, utf8_hex(text))`。两者都走控制通道。`Text` → `Tmux::paste`，然后写 `Pasted`（失败时 `ok: false` 和原因）。
7. `History` → 写 `History`。`Refit` → `fit(…, force: true)` 再取屏。
8. 事件 `Exit(原因)`：原因是 `connection closed` 就写 `Error { error: "connection lost" }`，别的都写 `Error { error: "session ended" }`；轮询时会话不在列表里了也写 `session ended`。然后 `detach`，返回 `Ok`。
9. `r` 读到 EOF：`detach`，返回 `Ok`。读到不是合法 `In` 的一行：写 `Error { error: "bad message" }`，继续。

- [ ] **Step 1: 写失败的 live 测试**（用 `tokio::io::duplex` 接两头；辅助函数 `next(&mut lines) -> Out` 带 3 秒超时，`say(&mut w, In)` 写一行）

```rust
#[tokio::test] async fn view_type_ack_roundtrip() {
    // 起 `cat`；run(); 读到 Hello、Panes(1 个面板，command == "cat")
    // say(View{pane, 118, 38}) → Screen{full:true, rev:1, cols:118, rows:38}（没有别人接着，所以按主控台设了）
    // say(Ack{1}); say(Type{pane, "你好"}); say(Keys{pane, ["Enter"]})
    // → 一条或几条 Screen{full:false}，把它们叠到第一屏上以后 lines[0] == "你好" 且 lines[1] == "你好"；每条都要先 Ack 才会来下一条
}
#[tokio::test] async fn text_is_pasted_and_acknowledged() {
    // say(Text{pane, "a\nb", enter:false}) → 收到 Pasted{ok:true}；say(Text{pane, 1 MiB + 1 字节}) → Pasted{ok:false, error:"text is too long (1 MiB at most)"}
}
#[tokio::test] async fn unknown_keys_send_nothing() {
    // say(Keys{pane, ["Enter", "set-option"]}) → Error{"unknown key"}；随后取屏，光标还在第 0 行（Enter 没有被发出去）
}
#[tokio::test] async fn a_flood_without_acks_sends_one_screen_then_the_latest() {     // Review Focus 3
    // 起 `sh -c 'i=0; while :; do echo line $i; i=$((i+1)); done'`；View 以后只读到 1 条 Screen；
    // 等 500 ms，确认 duplex 里没有第二条；kill 掉刷屏的进程（send Ctrl-C），Ack → 下一条 Screen 的内容等于此刻 capture 的内容
}
#[tokio::test] async fn ends_cleanly_when_the_session_is_killed() {                   // Review Focus 2
    // View 之后 server.raw(["kill-session", …]) → 3 秒内收到 Error{"session ended"}，并且 run 返回 Ok
}
#[tokio::test] async fn missing_session_and_bad_lines() {
    // run(…, "nope", …) → Error{"no such session"}，返回 Ok
    // 对存在的会话写一行 "not json\n" → Error{"bad message"}，之后 View 照常工作
}
#[tokio::test] async fn viewing_marks_the_session_seen() {
    // Unread::new(now - 100)；会话有过输出并已安静 → is_unread 为真；View 并收到 Screen 之后 → is_unread 为假
}
```

  这七个测试的函数体由实现的人照注释写全；注释里的每个断言都要有。

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现** — 一个 `tokio::select!` 循环，分支是：读一行 `In`、`Control::dirty()`、事件通道、`poll` 的定时器。没接控制客户端时后两个分支不参与。写出去统一经一个 `async fn put(w, &Out)`（`encode` 之后 `write_all` 加 `flush`）。
- [ ] **Step 4: 跑测试、clippy，提交** — `git commit -m "feat(term): the session pump"`。

---

### Task 12: 命令行，SSH 的回环测试，收尾

**Files:**
- Modify: `rust/term/src/main.rs`、`rust/term/tests/live.rs`
- Create: `rust/term/tests/cli.rs`

**Interfaces:**
- Consumes: 前面全部。
- Produces（命令行，下一份计划的 worker 和人都会用）：
  - `rapp-term version [--json]` → `{"version":"<包版本>","proto":1}`
  - `rapp-term list [--json] [--ssh <目标> --host <名字>] [--tmux <路径>]` → `{"sessions":[{"id":"term:tmux:work","name":"work","command":"claude","panes":3,"attached":1,"activity":1794592454,"dead":false}]}`；不带 `--json` 时每行 `id<TAB>command<TAB>panes`
  - `rapp-term watch <term 标识> [--ssh <目标>] [--tmux <路径>] [--json]` → stdin 读 `In`，stdout 写 `Out`
  - `rapp-term run [--name <名字>] [--size <列>x<行>] [--ssh <目标> --host <名字>] [--tmux <路径>] -- <命令…>` → 新开会话，打印它的标识
  - 所有子命令都认隐藏的 `--socket <名字>`（测试用）
  - 一个会话的 `command` 取它当前窗口里第一个面板的；`activity` 取各窗口里最大的；`dead` 是所有面板都退出了

- [ ] **Step 1: 写失败的测试**（`tests/cli.rs`，用 `env!("CARGO_BIN_EXE_rapp-term")` 起进程）

```rust
#[test] fn version_json() {
    let o = run(&["version", "--json"]);
    assert_eq!(o.code, 0);
    let v: serde_json::Value = serde_json::from_str(o.stdout.trim()).unwrap();
    assert_eq!(v["proto"], 1);
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
}
#[test] fn bad_arguments_exit_2() {
    for a in [&[][..], &["nope"], &["watch"], &["watch", "com.apple.Safari"], &["run"], &["run", "--size", "axb", "--", "sh"], &["list", "--ssh", "-oProxyCommand=x"]] {
        assert_eq!(run(a).code, 2, "{a:?}");
    }
}
#[test] fn list_run_and_watch_against_a_private_server() {
    let Some(s) = common::Server::start() else { return };
    let o = run(&["run", "--socket", &s.socket, "--name", "cli demo", "--size", "90x20", "--", "cat"]);
    assert_eq!((o.code, o.stdout.trim()), (0, "term:tmux:cli demo"));
    let o = run(&["list", "--json", "--socket", &s.socket]);
    let v: serde_json::Value = serde_json::from_str(o.stdout.trim()).unwrap();
    assert_eq!(v["sessions"][0]["id"], "term:tmux:cli demo");
    assert_eq!(v["sessions"][0]["command"], "cat");
    // watch：stdin 写一行 view（pane 取自第一条 panes 消息），读到 hello、panes、screen 三种消息各至少一条，关 stdin 后进程以 0 退出
}
#[test] fn runtime_errors_exit_1_and_do_not_echo_content() {
    let Some(s) = common::Server::start() else { return };
    let o = run(&["run", "--socket", &s.socket, "--tmux", "/nonexistent/tmux", "--", "echo", "SECRET-TEXT"]);
    assert_eq!(o.code, 1);
    assert!(!o.stderr.contains("SECRET-TEXT"));
}
```

  `tests/live.rs` 里再加一个只在设了 `RAPP_TERM_TEST_SSH=<目标>` 时才跑的测试 `ssh_runner_lists_and_captures`：用 `Runner::ssh(目标, 临时目录)` 对远端 `new-session`（名字带进程号）、`list`、`capture`，最后经同一个执行器发 `kill-session` 清掉它（测试夹具自己发，不经 `cmd.rs`）。没设这个变量时打印一行说明后返回。

- [ ] **Step 2: 跑一下确认失败。**
- [ ] **Step 3: 实现** — 手写参数解析（仓库里的二进制都没有用 `clap`）。`--ssh` 的控制连接目录用 `std::env::temp_dir()/rapp-term-<用户名>`，建成 0700。带 `--ssh` 而没带 `--host` 时，标识里不写主机。`watch` 和 `run` 开始前先 `Tmux::check()`。错误写到 stderr，一行，英文，不带屏幕和输入内容。
- [ ] **Step 4: 整体验证**

  ```
  cd rust && RAPP_TERM_REQUIRE_TMUX=1 cargo test -p rapp-term
  cargo clippy -p rapp-term --all-targets -- -D warnings
  cargo test --workspace        # 别的 crate 不受影响
  grep -rnE "set-option|bind-key|kill-|source-file" rust/term/src && echo "FOUND" || echo "clean"
  ```
  预期：前三条全过、无警告；最后一条打印 `clean`。
  再手工看一眼：在自己的一个 tmux 会话里跑着东西，另开一个终端执行 `rapp-term list`，然后 `rapp-term watch term:tmux:<那个会话>`，敲一行 `{"t":"view","pane":"<%号>","cols":100,"rows":30}`，确认有 `screen` 出来；这期间原来那个终端的尺寸没有变。

- [ ] **Step 5: 提交** — `git commit -m "feat(term): the rapp-term command — version, list, watch, run"`。

---

## 探查结果（任务 0 填）

| # | 探查 | 结论 | 日期 |
|---|---|---|---|
| 1 | 取 Claude Code、Codex 的真实界面 | 通过（自动检查）。tmux 3.8，120×40：Claude Code 2.1.323、Codex 0.166.0 各答一句带中日文和代码块的话；去掉转义后每行按东亚宽度算最宽 120 / 119 列，没有超过 120；`cursor_y` 分别是 37 / 36，正是输入框（`❯` / `›`）所在行；`cursor_flag`=1，`alternate_on`=1。注意：`capture-pane -e` 会把链接吐成 OSC 8 序列（`ESC ] 8 ;; url ESC \`），算宽度前要一并去掉，客户端渲染要认得它。Codex 首次启动有“有新版本”的提示，按 Esc 跳过，未更新。画面一致性：待用户对照（文件路径 /private/tmp/claude-501/-Users-bruce-git-rapp/6b2ed6ea-3e13-4d0f-8ef7-769d03517790/scratchpad/probe-claude.txt、/private/tmp/claude-501/-Users-bruce-git-rapp/6b2ed6ea-3e13-4d0f-8ef7-769d03517790/scratchpad/probe-codex.txt） | 2026-11-14 |
| 2 | 整段粘贴进 Claude Code、Codex | 通过。`paste-buffer -p` 后两个 CLI 的输入框里都是完整三行（第一行/第二行/第三行），没有提交；约 5 秒后再取屏，仍没有新一轮回答。之后 Ctrl-C（Claude Code）、Ctrl-C 加 Ctrl-U（Codex）清掉了输入。 | 2026-11-14 |
| 3 | 从后台服务里用 SSH；远端找不找得到 tmux | 未测（执行时没有可用的主机） | 2026-11-14 |
| 4 | 服务起的 tmux 活不活得过服务被停（launchd；systemd 直接起和经 `systemd-run`） | macOS（launchd）：LaunchAgent 里 `tmux -L rapp-probe4 new-session -d 'sleep 600'` 后接 `sleep 30`，在它还活着时 `launchctl bootout`，之后 `tmux -L rapp-probe4 ls` 会话仍在（服务的 sh 被收掉，tmux 服务进程的父进程是 1，不受影响）。macOS 上不需要额外手段。Linux：未测（没有 Linux 机器）：systemd 直接起、经 `systemd-run --user --scope` 起，两行均未测。已清理 plist 和 job，并停掉 rapp-probe4 服务。 | 2026-11-14 |

## 这份计划之后

- 第二份：`rapp-term serve`（worker）、`rapp-service` 的 `list_terms` / `watch_terms` / `open term:`、`rapp-hub` 的 `terms` 和监视流、`local/term.json`、访问记录。探查 4 的结论在那里用。
- 第三份：GUI 的 `TermSessionPort`、`TermStage`（含选中复制）、设备面板的“终端”一组和“添加 SSH 主机”，照已确认的交互稿。
