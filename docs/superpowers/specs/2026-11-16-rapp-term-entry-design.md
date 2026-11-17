# rapp 终端入口整理设计：只留文本终端，按 shell 新开

日期：2026-11-16。状态：已完成（分支 `feat/term-entry`，代码头 e6f8fc6，其后是这次的文档提交）。用户 2026-11-16 说“请逐个修正”，照此做的。

- 上游：《文本终端设计》（`2026-11-16-rapp-text-terminal-design.md`，下称“文本终端规格”）、《终端会话设计》（`2026-11-14-rapp-terminal-sessions-design.md`，下称“终端规格”）、终端界面设计（`2026-11-14-rapp-terminal-gui-design.md`）。
- 本文改掉文本终端规格 §2.1 的面板、§2.2 的第 3 步、§2.3 的对话框、§4.2、§6 的“只缩不放”，以及终端规格里所有 tmux 和 SSH 主机的部分。

标【我定的】的是我替用户做的选择，可以改。

## 0. 用户的要求

| # | 要求 | 出处（2026-11-16） |
|---|---|---|
| E1 | 去掉“新开 tmux 会话”：tmux 是进了终端以后用户自己启动的程序，没装更不该出现 | “可以去掉tmux启动，因为他属于进入终端后的应用，如果用户没安装更不应该显示在那里” |
| E2 | 统一新开文本终端的入口，给几个默认的进入选项（各平台的 shell 列表，见 §2.2） | “请优化统一的进入文本终端的入口。且提供一些默认进入选项” |
| E3 | 找不到时的保底：macOS / Linux 用 `/bin/sh`，Windows 用 `cmd.exe` | “为避免未安装导致启动失败，保底选择…” |
| E4 | 去掉“添加 SSH 主机” | “添加ssh主机这个也要去掉，因为他也是进入文本终端之后的事” |
| E5 | 列出可用的命令之前，先检查用户装没装 | “在列出host上默认可以用的 命令时，请先检查下用户是否安装了” |
| E6 | 去掉所有跟 tmux 有关的 | “去掉所有跟tumx有关的。它只是文本终端进去后用户启动的应用” |
| E7 | 能不填的，都不出现在界面上；创建以后再设置 | “可不填的地方，都不要出现在界面上。允许用户创建后再设置” |
| E8 | 会话能改名，名字存在被控端，所有主控台看到同一个（第 B 种） | 选了 B |
| E9 | 文本终端的显示跟着主控台窗口大小自适应，放大也要跟 | “请跟随client的窗口大小，自适应调整terminal的显示…放大时，好像限定在一个固定大小上了” |
| E10 | 会话标题写成 `CLI · zsh`：`CLI` 是固定的类型词，后面是会话名 | “会话的标题上，应该写 CLI·zsh 这样”，选了 A |

## 1. 一句话和边界

**设备下的“终端”只管两样东西：rapp 开的文本终端，和终端 app 的画面。新开文本终端就是点一个装了的 shell，一下就开；其他事（tmux、ssh、cd、跑 claude）进了终端以后用户自己做。**

目标：

- 面板上新开文本终端只有一排 shell 按钮，只列被控端真装了的，点一下直接开，不弹窗。
- 文本终端可以改名，所有主控台看到同一个名字，改名不影响常用、项目、窗口位置。
- 文本终端在主控台上放大、缩小都跟着窗口。
- 顶栏和会话列表的标题是 `CLI · <会话名>`。
- 代码里不再有 tmux、SSH 主机、`rapp-term new`。

不做：

- Windows、Linux 被控端的文本终端（文本终端规格 §9，另起设计）。本文只把那两个平台的 shell 检查写好、测好（§4.1），按钮在能开文本终端的平台上才出现。
- 新开时填目录、命令、名字（E7）。
- 显示终端里前台正在跑的程序（用户选了 A，不是 B）。
- 按主控台窗口改被控端终端的行列数（§2.6）。
- 把旧的 tmux 会话、SSH 主机配置迁移成别的东西。

不能出现的结果（做成了也算失败）：

- 列出一个没装的 shell，或者点了以后才报“找不到”。
- 没装 tmux 的机器上，界面或日志里还提到 tmux。
- 改名以后，常用、项目成员、窗口位置找不到这个会话。
- 放大后文字糊、选中复制的位置对不上格子。
- 新版主控台连旧版被控端（0.11.0 及以前）时报错或崩；旧版主控台连新版被控端时崩。

## 2. 用户看到的

### 2.1 设备面板

```
bruce-mac                                       ● 在线 · 局域网
 应用  桌面 · 终端 ▾ · Claude · Safari …
        终端
         ● zsh         文本   刚刚有输出          [打开]
         ○ 后端         文本   12 分钟没动静       [打开]   ← 改过名
         ◌ Terminal    只能用画面看                [画面]
         ◌ iTerm       只能用画面看                [画面]
         新开   [zsh]  [bash]  [sh]  [fish]               ← 只列装了的，默认的排第一
         终端 app   ● Terminal   ○ iTerm                   ← 装了不止一个才出现
         打开方式   ● 文本   ○ 画面
```

- 去掉：tmux 会话的行、SSH 主机的行和“移除”、“新开文本终端…”、“新开 tmux 会话…”、“添加 SSH 主机…”。
- “这台设备上现在没有终端会话。”留着。
- 被控端报不出 shell 列表（旧版，见 §5），“新开”后面只有一个按钮“默认 shell”。
- 被控端开不了文本终端（`launchers` 空：Linux，或者以后的 Windows 在做好之前），“新开”和“终端 app”两行都不出现。

### 2.2 新开（E2、E3、E5、E7）

各平台的候选，按这个顺序排（用户给的）：

| 平台 | 候选 |
|---|---|
| macOS | `zsh`、`bash`、`sh`、`fish`、`tcsh` |
| Windows | `cmd.exe`、`powershell.exe`、`pwsh.exe`、`bash.exe`（Git Bash）、`sh.exe`（Git Bash） |
| Linux | `bash`、`sh`、`zsh`、`fish`、`dash` |

- 只列找得到的（§4.1）。按钮上写名字，不写路径；Windows 上写 `cmd`、`PowerShell`、`pwsh`、`Git Bash`、`Git sh`【我定的】。
- **默认**：被控端用户的登录 shell（§4.1）。它在候选里，就排到第一个；它不在候选里（比如用户的登录 shell 是 `nu`），也照样列出来排第一，名字取文件名【我定的】。读不到登录 shell，或者它不存在，默认就是保底的 `/bin/sh` / `cmd.exe`（E3）。保底的那个总在列表里。
- 点一个 shell：被控端用“终端 app”选的那个开一个窗口，里面跑这个 shell；主控台的舞台直接切到这个会话。不弹窗，不问目录、命令、名字（E7）。目录是被控端用户的家目录。
- 名字：shell 的名字（`zsh`），已经有了就依次 `zsh-2`、`zsh-3`（照现在的 `pick_name`）。
- 点了以后到会话出现之前，那个按钮显示忙；失败时，错误写在这一排下面，和现在“移除”失败的写法一样【我定的】。

### 2.3 终端 app（设置）

- 原来对话框里的“用哪个终端 app”改成面板上的一项设置（E7）：每台被控端设备记一个，存在主控台的 `gui.json`，新字段 `term_app`，值是 `{"<被控端设备 id>": "Terminal" | "iTerm"}`【我定的】。
- 没写，或者写的那个不在 `launchers` 里了，就用 `launchers` 的第一个。
- `launchers` 只有一个时这一行不出现。

### 2.4 打开方式

文本终端规格 §2.2 的顺序改成：

1. 有 rapp 开的文本终端，打开最近有动静的那个；
2. 一个都没有，而 `launchers` 不空，**直接用默认 shell 开一个**（不再弹对话框）；
3. 都不行，照“画面”办。

原来的第 3 步（打开 tmux 会话）去掉。

### 2.5 改名（E7、E8）

- 在面板的文本终端那一行上改，和项目改名一样的做法（`projects_tab.dart` 的行内编辑）【我定的】。
- 名字存在被控端那个 `rapp-term run` 里（§4.3），改了以后所有连着的主控台在下一次列表更新时看到新名字；正在看的舞台、顶栏标题跟着变。
- 规则：去掉首尾空白后不能为空，不能有控制字符，最长 64 个字符【我定的】。可以和别的会话重名：标识不靠名字（§4.3），重名不会混【我定的】。
- 进程退出、窗口关掉，名字跟着没了（会话本来就没了）。

### 2.6 舞台的尺寸（E9）

> 2026-11-17 起：勾着「跟着我的窗口」时被控端窗口跟着主控台走，见 2026-11-17-rapp-term-fit-design.md。

- 被控端终端的行列数不变（文本终端规格 §6：只跟被控端窗口走）。主控台按它的行列数**等比缩放**到正好装进舞台，放大、缩小都这样，宽和高取能装下的那个比例。现在 `term_stage.dart:639-640` 只在装不下时缩小，装得下就按 1 倍画，这是“放大时停在固定大小”的原因。
- 不设上限【我定的】：窗口多大，字就放多大。
- 放大要清楚：按放大后的字号重新排字、画字，不能把 1 倍的画面拉伸（`term_painter.dart:200` 现在是 `canvas.scale`，放大时文字边缘要保持锐利，做法留给计划，验收看 §7）。
- 拖选、点链接、光标的位置都按缩放后的格子算（`term_stage.dart:378` 已经除以 `_scale`，放大时同样要对）。
- 舞台底下那句“另有终端也接着这个会话……按 M×N 原样缩小显示”去掉【我定的】：现在缩放是常态，不需要解释；它原本解释的“为什么不按我的屏幕重排”也随 tmux 去掉了。
- 送给被控端的“我的屏幕能放下几行几列”（`_queueView`）照旧，只用来决定一屏取多少历史，不改尺寸。

### 2.7 标题（E10）

- 顶栏标题：`CLI · <会话名>`，例如 `CLI · zsh`、`CLI · 后端`。现在是 `${pane.command} · ${appName}`（`top_bar.dart:50`），开一个 zsh 就显示 `zsh · zsh`。
- 左边会话列表那一行的名字、全景里的标签、常用里的名字：也是 `CLI · <会话名>`【我定的】，让人一眼分出这是命令行，不是 app 画面。
- 设备面板“终端”下面的那一行只写会话名（已经在“终端”里面了）。
- 顶栏第二行（设备 · 线路）后面原来接的 tmux 面板标题去掉；文本终端只有一个面板，标题就是会话名，再写一遍是重复。

## 3. 做法的选择（Approaches）

关键是**谁来判断装了哪些 shell**。

| 做法 | 是什么 | 取舍 |
|---|---|---|
| **A. 被控端检查，跟着终端列表报上来（已选）** | `rapp-term serve` 每次生成列表时查一遍候选，把找得到的（名字、路径、是不是默认）放进列表；主控台只显示报上来的；点了把路径送回去，被控端只认自己列表里的路径 | 只有被控端知道自己装了什么，也只有这样能做到 E5。检查只是看文件在不在，很快 |
| B. 主控台写死每个平台的列表，被控端启动时再检查 | 简单，不改协议 | 会列出没装的，点了才报错，正是 E1、E5 不要的。排除 |
| C. 不给列表，命令栏放几个快捷填写 | 改动最小 | 同 B，还违反 E7（命令栏是可不填的）。排除 |

用户 2026-11-16 认可 A（之后又加了 E7，把对话框整个去掉，A 不受影响）。

改名同理选了**名字放在被控端**（E8 的 B），代价是会话标识要和名字拆开（§4.3）。另一种“名字只存在这台主控台上”改起来简单，但几台主控台各看各的名字，用户排除了。

## 4. 结构

### 4.1 shell 检查（`rapp-term`，新文件 `shells.rs`【我定的】）

一个纯函数，输入是平台、`/etc/shells` 的内容、PATH、登录 shell、一个“这个路径是不是可执行文件”的判断，输出是列表。测试喂假的输入，三个平台的规则在任何平台上都能测【我定的】。

- **macOS / Linux**：每个候选名依次在这些地方找，第一个找到的可执行文件就是它：`/etc/shells` 里文件名对得上的条目、PATH 里的每一项、`/opt/homebrew/bin`、`/usr/local/bin`、`/bin`、`/usr/bin`。要额外查这几个目录，是因为 `rapp-term serve` 是 launchd 起的，PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，Homebrew 装的 fish、新版 bash 靠 PATH 找不到。
- **登录 shell**：`getpwuid(getuid())->pw_shell`，不用 `$SHELL`（launchd 起的服务里多半没有）。
- **Windows**（写好、测好，暂时不接到界面）：`cmd.exe`、`powershell.exe` 在 `%SystemRoot%\System32`（后者在 `WindowsPowerShell\v1.0\`）找；`pwsh.exe` 在 PATH 和 `%ProgramFiles%\PowerShell\*\` 找；Git Bash 的 `bash.exe`、`sh.exe` 只在 `%ProgramFiles%\Git\bin\` 和 PATH 里属于 Git 的目录（路径里有 `\Git\`）找。**`System32\bash.exe` 是 WSL 的启动器，不算 Git Bash，不能列出来。** Windows 没有“登录 shell”，默认就是 `cmd.exe`。
- 什么时候查：每次 `serve` 生成终端列表时都查（§4.5），新装了 fish 不用重启服务【我定的】。监视流（`watch`）里只有列表内容变了才推送，shell 列表变了也算变了。

### 4.2 开一个 shell

- 主控台送 `open`，带 `shell`（路径）和 `app`。`serve` 先核对 `shell` 在不在它这一刻查到的列表里，不在就回错误“这个 shell 找不到了”【我定的】；这一条也挡掉了随便指定一个程序去跑。
- `.command` 文件里写 `-- '<shell 路径>' -l`（路径照 `quote` 转义）：作为登录 shell 起，读用户的 `.zprofile`、`.bash_profile`，和直接打开 Terminal 一样【我定的】。`sh`、`dash`、`tcsh`、`fish` 都认 `-l`。
- 不再写 `--cwd`、`--name`；`rapp-term run` 的这两个选项留着，手敲时还能用【我定的】。
- `rapp-term run` 没有命令时还是起登录 shell（现在的 `new_default_prog`），手敲 `rapp-term run` 不受影响。
- 会话的默认名字：`default_name` 取命令第一个词的文件名，`/bin/zsh -l` 得到 `zsh`，现成的规则就对。

### 4.3 会话标识和名字分开（E8）

- 标识改成 `term:pty:<编号>`。编号是 `run` 起来时生成的随机串（16 个十六进制字符【我定的】），放在 `Meta` 里，一辈子不变。名字照旧放在 `Meta.name`，可以改。
- 现在标识是 `term:pty:<名字>`，GUI 的常用、项目成员、窗口位置、`termDisplayName` 的调用方都拿标识当钥匙。改了以后，凡是要显示的地方都读列表里的 `name`，不再从标识里拆名字（`main_state.dart:1739` 的 `parseTermId(term)?.name` 这种退路改成显示“CLI · 已结束”或列表最后一次见到的名字，计划核对每一处）。
- 旧标识不迁移【我定的】：文本终端关了窗口就没了，旧格式的常用、项目成员只会指向已经结束的会话，照“找不到会话”的现有规则显示。
- `run` ⇄ `serve` 的本机协议加一条“改名”，带新名字；`run` 改 `Meta.name`，回成功。状态里本来就有名字，`serve` 下一次扫描就拿到新的。本机协议的版本号加一；`serve` 对旧版 `run`（升级前开的窗口）照旧能列、能看，只是不能改名，改名时回“这个窗口是旧版本开的，不能改名”。
- 本机 socket 还是 `<pid>.sock`，不动。

### 4.4 改名的一路

主控台 → hub → service → `serve` → `run`。新请求 `rename_term`，带 `term`（标识）和 `name`。各层只是转发；名字的规则（§2.5）在 `serve` 检查一次，主控台在输入框里也挡一次。成功后 `serve` 立刻重新生成列表推给监视流，不等下一次轮询。

### 4.5 线协议的改动

- `TermList`：`hosts` 只剩本机那一条【我定的：保留数组和本机这一条，旧主控台照旧读得到 `launchers`】。`HostRow` 去掉 `target`、`tmux`、`error`，加 `shells: [{name, path, default}]`。
- `TermRow`：`host` 总是空；`panes` 总是 1；`dead` 总是 false（文本终端规格 §4.3）。字段先不删，旧主控台要读【我定的】。
- `Op` / `Req`：去掉 `NewTerm`、`AddTermTarget`、`RemoveTermTarget`；`OpenTerm` 去掉 `cwd`、`name`、`command`，加 `shell`；加 `RenameTerm`。
- `Hello` 的 `backend` 总是 `pty`。tmux 才有的会话协议消息（多窗口、新开窗口、按我的屏幕重排）去掉，清单见 §4.6。

### 4.6 删掉的

2026-11-16 清点的结果（行号是当时的 `main` c2a3389）。用户读的文档（两份 README、`docs/writing-panel.md` 等）里没有提到 tmux 和 SSH 主机，不用改；要改的只有代码里的说明注释。

**`rust/term`**

- 整个删掉：`tmux/`（`mod`、`cmd`、`control`、`parse`）、`session.rs`、`runner.rs`。**先挪走** `tmux/mod.rs:14-25` 的 `HistoryRows`、`MAX_HISTORY`、`MAX_PASTE`（`wire.rs:5`、`pty/grid.rs:5`、`pty/view.rs:321` 的测试在用），放进 `wire.rs`【我定的】。
- `list.rs`：只留 `TermRow`；`rows`、`host_rows`、`Backoff` 删掉。
- `config.rs`：只留 `allow`、`load`、`INVALID`、`OFF`；`tmux`、`targets`、`Target`、`check_target`、`check_tmux`、`MAX_TARGETS`、`target()`、`tmux_bin()` 删掉，读到这些字段时忽略（§5）。
- `id.rs`：留 `TermId`、`is_term`、`session_name`、`default_name`；`valid_host` 删掉；测试改用 `term:pty:`。`session_name` 把 `:`、`.` 换成 `_` 的规则留着（无害），注释改掉 tmux 的说法。
- `keys.rs`：留 `to_bytes`、`csi_form`；`tmux_name`、`named`、`utf8_hex` 删掉。
- `screen.rs`：留 `Screen`、`strip_escapes`；`from_capture`、`wrapped_rows` 删掉。
- `proto.rs`：删掉 `Out::WindowOpened`、`In::NewWindow`、`In::Refit`。`Pane` 的 `win`、`active`、`window` 字段留着、照旧填固定值，旧主控台要读【我定的】。`PROTO` 不变（还是 2）。
- `serve.rs`：删掉 `Req::New`、`new_session`、`tmux_for`、`ask_host`、`Watched`/`rewatch`、`list()`/`table()` 里 tmux 那一半、`said`、`LIST_FAILED`、`UNKNOWN_HOST`、`TAKEN`、`TMUX`、`ServeOpts.socket`、`ServeOpts.ctl_dir`、`view` 里 tmux 那一支、`host_list` 里的目标；加 `Req::Rename`（§4.4），`Req::Open` 改成带 `shell`（§4.2）。**`view_pty` 现在按 `s.name == id.name` 找会话（`serve.rs:513`），要改成按编号找（§4.3）。**
- `main.rs`：只留 `version`、`run`、`serve`；`list`、`watch`、`new`、`BACKEND`、`tmux_of`、`check_host`、`ctl_dir`/`private_dir`、`--ssh/--host/--tmux/--socket` 删掉，USAGE 跟着改。
- `lib.rs`：去掉 `pub mod tmux`，加 `pub mod shells`。
- `unread.rs`、`sender.rs`、`wire.rs`（除了上面那个 import）、`pty/*`：不动。
- 测试：`tests/live.rs`、`tests/locale.rs`、`tests/grid_live.rs`（拿 tmux 的输出当标准答案）、`tests/common/mod.rs`（私有 tmux 服务器）删掉；`tests/cli.rs` 只留 `version_json`、`bad_arguments_exit_2`、`run_refuses_a_cwd…`；`tests/serve.rs` 的 246-560 删掉，565-704 的 pty 测试现在借 tmux 的 `Server::start()` 和 `--socket` 起服务（没装 tmux 就跳过），**要换一个不靠 tmux 的测试架子**，让它们在没装 tmux 的机器上也跑。`tests/pty.rs`、`tests/common/pty.rs` 不动。

**`rust/service`**

- `term.rs`：删掉 `NewTerm`、`AddTermTarget`、`RemoveTermTarget` 的处理（69-81、94-97），以及 `targets`/`edit`/`add`/`remove`/`save`/`lock`/`EDIT`。本机 IPC 的 `term`/`set_term`（`ipc.rs:122-123`）只留 `allow`（没找到 GUI 在用 `tmux`、`targets`）。加 `RenameTerm` 的转发。
- `peer.rs:199-207`：终端那组请求跟着改。`workers.rs` 不动。

**`rust/net`**：`msg.rs` 照 §4.5 改，测试（125-150）跟着改。

**`rust/hub`**

- `terms.rs`：`command()`、`event()` 去掉 `new_term`、`add_term_target`、`remove_term_target` 和 `term_targets` 事件，加 `rename_term`。
- `lib.rs:326` 的命令名单跟着改（旧主控台送来已删的命令，得到 `unknown cmd`）。

**`rust/testkit`**：`src/bin/fake-rapp-term.rs` 改成只报 `term:pty:` 的会话，带 `shells`，认 `rename`；`tests/term.rs`、`tests/hub_terms.rs` 里 targets、`new_term`、IPC tmux 路径的测试删掉，加 shell 列表和改名的。

**`gui/lib`**

- `hub_client.dart`：删 `addTermTarget`、`newTerm`、`removeTermTarget`、`TermHost.target`/`.tmux`/`.error`；`TermHost` 加 `shells`；加 `renameTerm`；`openTerm` 改成带 `shell`。
- `ui/devices_tab.dart`：删 SSH 主机的行、`_removeHost`、`_newTerm`、`_AddHostDialog`、`_NewTermDialog`、`_NewTextDialog`、`showNewTextDialog`、三个“新开/添加”按钮、列表里“文本/tmux”的种类字（只剩文本，不用写了【我定的】）；加 shell 按钮排、终端 app 设置、行内改名（§2.1–§2.5）。
- `ui/terms_entry.dart`：去掉 tmux 那一步，`AskNewText` 换成“用默认 shell 开”（§2.4）；只认 `term:pty:` 的行（§5）。
- `ui/main_state.dart`：删 `canNewTermWindow`、`newTermWindow`、`_newWindowPending`（560-583）、`newTextAsks`；`openText` 改成带 `shell`；1739 的名字退路改掉（§4.3）。
- `ui/main_window.dart`：去掉“新开文本终端”对话框的排队（97 一带）。
- `ui/top_bar.dart`：标题改成 `CLI · <名字>`（§2.7）；删「＋」新开窗口（72-73、245-258）。
- `ui/stream_menu.dart:411`：删“按我的屏幕重排”。
- `ui/session_model.dart`、`ui/session_row.dart`：`paneTitle` 去掉（§2.7）。
- `ui/lifecycle.dart:110`：只改注释（`session ended` 两边都发）。
- `term/term_session_port.dart`：删 `_Window` 队列、`newWindow`、`canNewWindow`、`windowFailed`/`noSuchPane`、`TermWindowOpened`、`opening`（46-105、178、267-290、397-411）。`TermPanes`→标签的映射留着（只有一个标签）。
- `term/term_wire.dart`：删 `TermWindowOpened`、`newWindowMsg`；`tabLabels` 的窗口、面板编号去掉。
- `embed/session_port.dart:305`：删 `TermOpenedPaneEvent`。
- `term/term_stage.dart`：§2.6 的缩放和那句说明。

**`gui/test`**：`term_main_test`（157、230、298-360）、`term_port_send_test`（232-340）、`term_wire_test`（28、34、68）、`terms_entry_test`（44-80）、`hub_client_test`（469、484）、`devices_tab_test`（SSH 主机、新开 tmux 那些）删掉或改写；`draft_store_test`、`term_composer_test`、`term_key_row_test`、`term_stage_keys_test`、`term_select_test`、`term_session_port_test`、`shares_section_test`、`shares_test` 里拿 `term:tmux:` 当样例的，改成 `term:pty:`。

**说明注释**：`serve.rs:1-6`、`service/term.rs:1-4`、`hub/terms.rs:1`、`main.rs:1-31`、`config.rs:1`。

## 5. 新旧版本混用

| 组合 | 会怎样 |
|---|---|
| 新主控台 + 旧被控端（0.11.0 及以前） | 旧被控端还会报 tmux 会话、SSH 主机：新主控台只显示 `term:pty:` 开头的会话，其余忽略。旧的报不出 `shells`：“新开”只有一个“默认 shell”，点了送 `open` 不带 `shell`（旧被控端也不认），旧被控端用 `$SHELL` 开，和现在一样。旧标识（`term:pty:<名字>`）照样能打开、能看；改名按钮不出现（看列表里有没有 `shells` 判断被控端新旧【我定的】） |
| 旧主控台 + 新被控端 | 旧主控台的“新开 tmux 会话”“添加 SSH 主机”送来的请求，被控端回“不认识的请求”，旧主控台把它当错误显示，不崩。旧主控台的“新开文本终端”对话框送来的 `open` 带 `cwd`、`name`、`command`、不带 `shell`：被控端忽略这三项，用默认 shell 开【我定的】 |
| 被控端上旧的 `term.json` 里的 `targets`、`tmux` | 留在文件里不动，不再读；读配置时忽略这些字段，不报错 |
| 升级前开的文本终端窗口 | 照旧列出、能看（§4.3），标识是旧格式，不能改名 |

## 6. 配置

- 主控台 `gui.json`：加 `term_app`（§2.3）；`term_open` 不变。写进《配置规范总览》§2.4。
- 被控端 `term.json`：只剩 `allow`。`targets`、`tmux` 从规范里删掉，读的时候忽略（§5）。

## 7. 验收

| 步 | 做什么 | 验收 |
|---|---|---|
| 1 删 tmux | §4.6 全部删掉 | 代码里（除了 §5 的兼容忽略和 CHANGELOG）搜不到 `tmux`；`cargo test`、`flutter test` 全过 |
| 2 shell 列表 | §4.1、§2.2 | 三个平台的规则各有测试，包括“没装的不出现”“Homebrew 目录里的 fish 能找到”“`System32\bash.exe` 不算 Git Bash”“登录 shell 不在候选里也排第一”“什么都找不到时只有保底”；真机上卸掉（或改名）fish，刷新后按钮消失 |
| 3 新开 | §2.2–§2.4、§4.2 | 真机：点 `zsh`，被控端出现窗口，舞台直接是它，名字 `zsh`；再点得到 `zsh-2`；终端 app 切到 iTerm 再点，窗口开在 iTerm；文本方式下没有会话时点“终端”，直接开一个默认 shell |
| 4 改名 | §2.5、§4.3、§4.4 | 在 Mac 上改名，手机上的列表、顶栏跟着变；改名后常用和项目里的它照样能打开 |
| 5 尺寸 | §2.6 | 舞台拉大，字跟着放大到填满宽或高，文字清楚；缩小同样；拖选复制、点链接的位置对得上 |
| 6 标题 | §2.7 | 顶栏、会话列表、全景、常用里都是 `CLI · zsh`；改名后是 `CLI · <新名字>` |
| 7 混用 | §5 | 新主控台连 0.11.0 被控端：没有 tmux 行，“默认 shell”能开；0.11.0 主控台连新被控端：点“新开 tmux 会话”看到错误，不崩 |

## 8. 留给计划和实现的

- 放大时怎么保持文字锐利（按字号重排，还是别的办法），只要验收 5 过。
- `shells.rs` 的具体接口；Windows 那部分放在哪个 `cfg` 下面。
- 行内改名的控件复用到什么程度。
- tmux 删除的先后顺序，只要每一步测试都过。

## 9. 确认后要跟着改的文档

- 文本终端规格：§2.1–§2.4、§4.2、§6 指向本文。
- 终端规格：标“tmux 部分已在 2026-11-16 去掉，见本文”。
- 《配置规范总览》§2.4（`term_app`）、`term.json` 那一节。
- README 里提到 tmux、SSH 主机的地方。
