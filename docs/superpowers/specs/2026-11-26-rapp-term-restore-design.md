# 文本终端：重启后恢复，新建沿用上一个终端的目录（设计）

日期：2026-11-26。状态：**草稿，待用户审**。标【我定的】的是我替用户做的选择，可以改。审读提的 4 个问题由我定，标【审读后我定的】。

相关：文本终端设计（`2026-11-16-rapp-text-terminal-design.md`）、多终端（`2026-11-26-rapp-term-multi-design.md`，下称「多终端」）、CLI 升级（`feat/cli-update` 上的 `2026-11-26-rapp-cli-update-design.md`，下称「CLI 升级」）、程序状态（`2026-11-25-rapp-program-status-design.md`）。

## 0. 用户的要求（原话，2026-11-26）

| # | 要求 |
|---|---|
| R1 | 「rapp-term 在启动了很多终端后，一旦要强制升级，这些 term 都得关掉。但我希望有恢复命令，能在下次重启时还原 term 最后一次打开的场景，包括加载的环境、路径等。请根据常用做法去设计一下」 |
| R2 | 「新建文本终端时，例如点新建或 Cmd+T 快捷键创建时，预加载的路径请默认以上一个或用户当前的文本 term 的为准」 |
| R3 | 追问「除了升级还在什么时候丢」→「重启电脑后也要能还原」 |
| R4 | 上次在跑的程序怎么还原，选了 **B：命令填好，按回车才跑** |
| R5 | 「加载的环境」→「主要是 venv 和 conda，密钥不用存」 |
| R6 | 怎么知道 shell 当时激活了哪个环境，选了 **A：rapp 开的 shell 里装钩子** |

为什么：一台 Mac 上同时开着很多文本终端，每个在不同目录、激活了不同的 venv/conda、跑着 claude 之类的程序。升级或重启电脑以后，这些全没了，要一个个重开、`cd`、激活、再启动程序。

## 1. 现状（origin/main 5924c225，0.15.37）

- **终端由谁持有**：每个文本终端是被控 Mac 上一个 Terminal 标签页里的 `rapp-term run`（holder），它开 pty、起 `<shell> -l`（`launch.rs` `command_file`）。`rapp-term serve` 是服务的子进程，通过 `$ROOT/local/term/pty/<pid>.sock` 找到各个 holder。
- **holder 已经知道的**：前台程序名和目录（`pty/fg.rs`，`tcgetpgrp` + `proc_pidinfo`），每 `FG_EVERY` 查一次，标题到达时也查。它已经在扫 OSC 0/1/2、OSC 7501 和 OSC 133;A（`pty/ps.rs`，`Event::Prompt`）。这些都只在内存里，不落盘。
- **holder 怎么结束**（`holder.rs` 主循环）：`End::Exited`（shell 自己退出，比如敲 `exit`）、`shared.end`（rApp 里「结束终端」/ ⌘W）、外来的 SIGHUP/SIGTERM/SIGINT/SIGQUIT（Terminal 关窗口、注销、关机、`kill`）。三类分得开。
- **升级**：main 上 `procs_in_use` 把 `rapp-term run` 算成「在用」，升级一直等，用户只好关掉终端。CLI 升级规格把它移出「在用」，升级时终端照样跑（尚未合入）。所以**升级本身**在 CLI 升级合入后就不丢终端了；本设计要解决的是**重启电脑**和**窗口被关**之后的还原，升级前手动关掉的也一样能还原。
- **⌘T 已经沿用当前终端的目录**：GUI `newTermFrom(device, term)` → `openText(from: term)` → hub `open_term{from}` → serve `open` 用 `source_of` 取那个 holder 的 `cwd` 和 shell，并开在它旁边的标签页（多终端 §4）。
- **「新建」不沿用**：总览「常用 · 终端」和设备页每个 shell 的「新建」调 `openText(id, shell: …)`，不带 `from`（`main_state.dart:2844`、`devices_tab.dart:512`），总在家目录开。
- **0.15.33 的「打开」**：客户端重启后，第一次点「常用 · 终端」重新打开所有**还在跑**的文本终端。它只管还活着的 holder，和本设计的「恢复」（holder 已经没了）不冲突。

## 2. 目标 / 非目标 / 反目标

**目标**
1. 电脑重启、Terminal 被退出、窗口被关、升级前手动关掉之后，能一步把这些文本终端恢复回来：同样的名字、目录、shell，激活同一个 venv/conda，上次在跑的命令填在提示符后面，按回车就跑。
2. 恢复从 rApp 里点，也能在被控 Mac 上敲命令。
3. 「新建」和 ⌘T 新开的终端，默认从当前或上一个文本终端的目录开始。

**非目标**
- 不还原屏幕上的文字（滚动记录）。重开的是新 shell。
- 不还原任意环境变量：只还原 venv 和 conda（R5）。
- 不还原 shell 历史以外的进程状态。程序被重跑，不是被冻结后续上。
- 不接管、不恢复不是 rapp 开的终端（`no-terminal-takeover`）。
- 不做 tmux 那种「关了窗口程序还活着」。
- iTerm 的分组、Terminal 的多窗口布局：恢复时全部开成标签页（§4.6）。

**反目标（做成了也算失败）**
- 恢复时自己把命令跑起来了（R4 选的是按回车才跑）。
- 密钥落盘：快照里出现 API key 之类（R5）。
- 用户敲 `exit` 或点「结束终端」结束的终端，下次又被提议恢复。
- 钩子改坏了用户自己的 shell：提示符、补全、`~/.zshrc` 里的东西表现得和不经 rapp 打开时不一样；或者 `ZDOTDIR` 之类漏给了子进程（嵌套的 zsh、tmux 读错了配置）。
- 目录离开被控端（多终端 §5 的规矩：`TermRow` 不带 `cwd`，目录不经过 relay，也不进日志）。

## 3. 做法（Approaches）

关键是怎么知道每个终端当时激活了哪个 venv/conda、跑的是哪条命令。

| 做法 | 是什么 | 取舍 |
|---|---|---|
| **A. rapp 开的 shell 里装钩子（已选，R6）** | rapp-term 启动 shell 时先让它读 rapp 自带的一小段配置；这段配置照常加载用户自己的配置，再挂钩子：出提示符时报目录和 `VIRTUAL_ENV`/`CONDA_PREFIX`，执行命令前报这条命令。VS Code、Ghostty、kitty 的「shell 集成」都这样做 | shell 空着时也记得准；命令是用户敲的原样（别名也在）；知道提示符什么时候出来，预填不会被吞。代价：zsh、bash、fish 各写一份 |
| B. 不装钩子，读前台程序启动时的环境 | `KERN_PROCARGS2`（Linux 读 `/proc/<pid>/environ`、`cmdline`） | 不碰 shell。shell 空着时读不到 venv；命令只有 argv（`node …/claude` 这类）；预填只能靠等 |
| C. 让用户自己往 `~/.zshrc` 加一行 | 效果同 A | 要手工加，换台机器又要加，不推荐 |

A 用不上的 shell（钩子没装上，或者 `sh`、`nu` 这类没写钩子的）退到 B：能读到什么就记什么【我定的】。

常用做法的参照：tmux-resurrect/continuum 定时存快照，记布局、目录和白名单里的程序；zellij 恢复时把命令摆好，按回车才跑；iTerm2、Terminal.app、Windows Terminal 只还原目录和屏幕上的文字。本设计取 zellij 的「摆好命令」，加上钩子记环境。

## 4. 设计

### 4.1 新建沿用上一个终端的目录（R2）

「新建」（总览「常用 · 终端」、设备页每个 shell 的「新建」）按这个顺序选「旁边的终端」：

1. **当前的终端**：舞台上正显示这台设备的文本终端时，就是它。
2. **上一个终端**：这台主控台本次运行里最后看过、这台设备上还活着（仍在列表里）的文本终端。GUI 在内存里按设备记一个 term id，不写盘【我定的】。GUI 实际的取源顺序：当前的，否则最后看过且仍在列表里的，否则发 `from: "last"`【计划里改的】。
3. **被控端自己挑**：1、2 都没有时，GUI 发 `from: "last"`，serve 依次取：最近有输入的那个还活着的 holder（holder 的 `activity` 是输出时间，这里要的是**输入**时间：`Shared` 新增 `input_at`，每次按键或观看端输入时更新，`Status` 新增 `input`（Unix 秒，0 或不带表示从没有）；不与 CLI 升级的 `activity` 事件共用（那个分支还没合）【计划里改的】）；没有就取最近一份快照（§4.3）的目录；都没有就用家目录。
4. 找到的终端目录已不存在时，往下一级找，不报错（`source_of` 已经过滤 `is_dir`）。

- **shell 照按钮来**：点「新建 · zsh」还是 zsh，只借目录。所以 serve 的 `open` 在请求里明写了 `shell` 时，用请求里的 shell、`from` 那边的目录；没写 shell 时（⌘T）两样都沿用，和现在一样。
- **开在哪个窗口**：和 ⌘T 一样，开在旁边终端的那个窗口里成为新标签页。
- **⌘T 不变**。
- **旧被控端**不认 `"last"`，`TermId::parse` 失败就照旧在家目录开，可以接受。

### 4.2 shell 钩子（R6）

**装法**（都只对 rapp-term 启动的 shell 生效，用户的配置文件一行不改）：

| shell | 怎么让它先读 rapp 的配置 |
|---|---|
| zsh | `ZDOTDIR` 指向 rapp 的目录，原值存进 `RAPP_ZDOTDIR`。只需要一个 `.zshenv`（Ghostty 的做法）：它把 `ZDOTDIR` 改回原值，source 用户的 `.zshenv`，交互时装一个一次性的 `precmd`，在用户的 `.zshrc` 之后才加真正的钩子。之后 zsh 自己从用户的 `ZDOTDIR` 读 `.zprofile`、`.zshrc`、`.zlogin`【计划里改的】（P4；原先写的是 rapp 的 `.zprofile`/`.zshrc`/`.zlogin` 各转一遍） |
| bash | 照 VS Code 的做法：用 `--init-file` 让 bash 读 rapp 的文件，rapp 的文件按登录 shell 的顺序 source `/etc/profile`、`~/.bash_profile`（或 `~/.bash_login`、`~/.profile`），再挂钩子（`PROMPT_COMMAND` 和 `DEBUG` trap）。具体参数由计划在本机 bash 3.2 和 Homebrew bash 5 上核对 |
| fish | `fish -l -C 'source <rapp 的文件>'`：`-C` 在用户的配置之后执行 |
| 其他 | 不装，退到 B |

钩子文件由 rapp-term 在启动时写到 `$ROOT/local/term/shell/`（0700），内容来自编进二进制的文本；版本不对就重写【我定的】。

**报什么**：用一个私有 OSC，终端不显示它，**透传给 Terminal 窗口**，和 OSC 7501 现在一样：Terminal.app 和 holder 的 `Emu` 都忽略不认识的 OSC，吞掉没有好处，还要多写一个输出过滤器【计划里改的】（P1；原先写的是「holder 吞掉」）【我定的：编号 7502，名字 `rapp-shell`】。

- 出提示符时（zsh `precmd`、bash `PROMPT_COMMAND`、fish `fish_prompt` 事件）：`ESC ] 7502 ; state ; cwd=<b64> ; venv=<b64> ; conda=<b64> ; conda_name=<b64> BEL`，是字段不是 JSON，空的字段不写，每个值是 UTF-8 字节的标准 base64（shell 脚本没法可靠地转义路径里的字符）【计划里改的】（P2；原先是 base64(JSON)）。只在内容比上次报的有变化时才报 `state`（省掉每个提示符的 fork）【计划里改的】（P3）；`OSC 133;A` 每个提示符都写（用户的主题已经报了也不要紧，holder 只用它判断提示符出来了）。
- 执行命令前（zsh `preexec`、bash `DEBUG` trap 的第一次、fish `fish_preexec`）：`ESC ] 7502 ; run ; <b64> BEL`，`<b64>` 是命令原文的 base64。
- bash 里用户已经有 `DEBUG` trap（bash-preexec 之类）时，我们的钩子不去碰它，只报 `state`，并在 `state` 里加 `norun=<b64 "1">`，表示这个 shell 不会报 `run`【计划里改的】。**钩子没装上或带了 `norun` 时，恢复时填的命令退到前台进程的 argv（退到 B）**【计划里改的】。
- 回到提示符就意味着命令结束了，holder 把「在跑的命令」清空。

**不能漏**：
- `ZDOTDIR`、`RAPP_ZDOTDIR` 之类在 shell 起来后要恢复或删掉，嵌套的 zsh、tmux、子进程看到的和不经 rapp 打开时一样。
- 钩子出错不能打断用户的 shell：钩子里的每条都容错，失败就什么都不报。
- 嵌套 shell（`ssh`、在终端里再开一个 zsh）不带钩子，它们的提示符不会冒充外层 shell 的状态。holder 只认钩子报的状态，不去猜。
- 开关：`term.json` 加 `shellHook`，默认开；关掉时退到 B【我定的】。

### 4.3 快照

**存哪**：`$ROOT/local/term/saved/<key>.json`，`key` 是 holder 的 `meta.key`（每个 holder 唯一）。目录 0700、文件 0600，写法是先写临时文件再改名。

**内容**（快照里没有 `app`：`restore` 像 `open` 一样带 `app`，GUI 用 `prefs.termAppFor`，CLI 不带、由 serve 取第一个启动器）【计划里改的】（P5）：

```json
{
  "v": 1,
  "key": "…",
  "name": "rapp",           // 终端名字
  "named": false,           // 名字是不是用户手改的
  "shell": "/bin/zsh",
  "cwd": "/Users/bruce/git/rapp",
  "venv": "/Users/bruce/git/rapp/.venv",
  "conda": "/opt/miniconda3/envs/ml",
  "conda_name": "ml",
  "cmd": "claude --dangerously-skip-permissions",  // 在跑的命令，空着就没有
  "prog": "claude",         // 给列表看的程序名
  "started": 1764123456,    // holder 起来的时间，恢复时按这个排序
  "saved": 1764130000
}
```

- **什么时候写**：holder 起来时写一份；之后内容变了（目录、环境、在跑的命令、名字），等 2 秒没有再变就写【我定的】。不定时空写。重启前最后一次变化最多丢 2 秒。
- **命令里不存密钥**（R5）【我定的；后两条是审读后我定的】：
  - 去掉开头的变量赋值（`KEY=xx claude` 只存 `claude`）。
  - 含换行或控制字符的命令不存（只留 `prog`）。
  - 超过 1000 字符不存。
  - 看着像带密钥的命令，整条不存，只留 `prog`，恢复时只填程序名。判断用一张表，宁可多拦：
    - 选项名里含 `key`、`token`、`secret`、`password`、`passwd`、`auth`、`credential`，比如 `--api-key x`、`--token=x`、`-p`（跟在 `mysql`、`psql` 后面）；
    - `Authorization:`、`Bearer `；
    - URL 里带密码（`://user:pass@`）；
    - 常见密钥前缀：`sk-`、`ghp_`、`gho_`、`github_pat_`、`xox`、`AKIA`、`eyJ`（JWT）；
    - 一个 32 个字符以上、只由字母数字和 `-_` 组成的词。
  - 环境只存上面三个字段，别的环境变量一律不存。
  - 这只是尽力：shell 自己的历史文件本来就记着这些命令，本设计不比它多存。
- **没装钩子时**（B）：`cwd` 来自 `fg.rs`；前台不是 shell 时，`cmd` 取前台进程的 argv 拼成一行，`venv`/`conda` 从它启动时的环境里读那三个变量。shell 空着时 `venv`/`conda` 留空。

### 4.4 快照什么时候删

| 结束方式 | 快照 | 理由 |
|---|---|---|
| shell 自己退出（敲 `exit`、程序结束后 shell 也退了，`End::Exited`） | 删 | 用户主动结束（反目标第 3 条） |
| rApp 里「结束终端」/ ⌘W（`shared.end`） | 删 | 同上 |
| 外来的 SIGHUP/SIGTERM/SIGINT/SIGQUIT（关窗口、退出 Terminal、注销、关机、`kill`） | 留。子进程被信号杀死的一律留快照；干净退出（`End::Exited`）要多等 150 ms，看有没有迟到的 hup/term/int/quit，没有才删【计划里改的】 | 关机和关窗口分不出来；留着，由恢复列表让用户勾掉 |
| holder 被 SIGKILL、崩溃、断电 | 留 | 来不及删，正好要恢复 |
| 恢复成功（新 holder 起来了） | 留，同一个 `key` 接着写 | 新 holder 沿用旧 `key`（§4.5） |
| 用户在恢复列表里点「清掉」 | 删 | |
| 超过 30 天，或超过 50 份时最旧的 | 删 | serve 扫的时候顺手删【我定的】 |
| 文件坏了（不是快照、太大、`key` 对不上） | 删 | serve 扫的时候顺手删 |
| 文件这次读不出来（I/O 错误、没权限、描述符用完） | 留，这一轮不列出来也不删，下一轮再看 | 可能是好的快照，删了就再也恢复不了【计划里改的】 |

**哪些算「可以恢复」**：`saved/` 里 `key` 不等于任何活着的 holder 的快照。活着的 holder 不出现在恢复列表里（它们还在，用 0.15.33 的「打开」）。

### 4.5 恢复时一个终端怎么开

serve 收到恢复请求（§4.6）后，对每份选中的快照，按 `started` 从早到晚，逐个走现有的 `open` 流程（`opening` 锁已经保证一个接一个），区别是 `.command` 文件里多一个 `--restore <key>`：

```
exec rapp-term run --dir … --ticket … --restore <key> --cwd <cwd> -- <shell> -l
```

`--cwd` 照旧给（目录不存在就不给，从家目录开）。holder 带 `--restore` 起来后：

1. 读 `saved/<key>.json`（读不出来就每 200 ms 再试，共 5 次；还读不出来，holder 报错退出，快照留着，不换新 `key` 起一个新终端，免得旧快照以后又被恢复一遍【计划里改的】），**沿用旧 `key`** 当自己的 `meta.key`，所以 term id（`term:pty:<key>`）不变：常用、项目成员（`workspace.json` 里存的就是 term id）、「全部打开」照旧认得它，GUI 不用改【审读后我定的】。用里面的名字（`named` 原样带过来，名字冲突照 `pick_name` 加后缀）。`saved/<key>.json` 不删，由新 holder 原地接着写。它一起来，这个 `key` 就是活的，不再算可恢复，两次恢复撞不到一起（serve 的 `opening` 锁也一个接一个开）。
2. 把 `venv`、`conda` 放进给 shell 的环境变量 `RAPP_RESTORE_VENV`、`RAPP_RESTORE_CONDA`。钩子在用户配置加载完以后：
   - 有 conda 且 `conda` 命令可用：`conda activate <前缀>`。
   - 有 venv 且 `<venv>/bin/activate` 存在（fish 用 `activate.fish`）：source 它。conda 先、venv 后（venv 常常建在 conda 的 python 上）。
   - 目标不存在：打印一行「rApp：上次的环境 <路径> 已不在，没有激活」，接着往下。
   - 然后删掉这两个变量。
   - 激活只是设环境变量，所以自动做，不等回车【我定的】。
3. 收到第一个提示符（`OSC 133;A`）以后，把要填的命令写进 pty 的输入，**不带回车**。2 秒内没等到提示符（没装钩子的 shell）就直接写【我定的】。
4. 填进去的命令在用户执行别的命令之前，一直留在快照的 `cmd` 里：恢复后还没按回车又重启了，下次还能填回来。规则是：holder 收到第一个 `run`（用户按了回车，执行的不管是不是它）或者 shell 退出之前，`cmd` 保持恢复时的值【审读后我定的】。

**要填的命令**：
- 一般就是 `cmd` 原样。
- claude、codex 这类改成「接着上次对话」的写法，原来的选项保留：claude 加 `--continue`（已有 `-c`/`--continue`/`-r`/`--resume` 就不加）；codex 改成 `codex resume --last`。原来带着一段提示词（位置参数）的，丢掉提示词，免得重发一遍。改写规则放一张表，方便以后加程序。改写不了就填原样。
- 已知限制：同一个目录里开着两个 claude，`--continue` 都会接上同一个最近的对话。能不能记住各自的会话，见 §8。

### 4.6 从哪里发起恢复

**rApp 里**：
- **设备页的终端那一组**：有可恢复的快照时，多一行「上次没关的 3 个终端　[恢复…]」。
- **总览「常用 · 终端」**：这台设备没有活着的文本终端、但有**这次开机以前**存的可恢复快照时，按钮说「恢复」，不说「新建」。顺序是：有没打开的活终端，说「打开」（0.15.33）；否则有开机前的快照，说「恢复」；否则说「新建」。只是点红色按钮关掉的窗口（开机以后的快照）不会把按钮变成「恢复」，它们只在设备页那一行和列表里出现【审读后我定的】。`saved` 里每份带 `boot: true`，表示存于这次开机以前。开机时间 macOS 读 `kern.boottime`，Linux 读 `/proc/stat` 的 `btime`。
- 点了都弹出同一个列表，开机前的默认勾上，开机后的默认不勾。列表里另有「新建」，点了就照 §4.1 新开一个，不恢复任何东西【审读后我定的】：

```
恢复上次的终端 · bruce-mac
 ☑ rapp       claude        2 小时前
 ☑ train      python        2 小时前
 ☑ shell      —             3 天前
          [全部清掉]   [新建]   [取消]   [恢复所选]
```

- 列表里只有名字、程序名、多久以前，**不显示目录**（§2 反目标最后一条）【我定的】。
- 恢复所选：逐个打开，全开成被控端同一个 Terminal 窗口里的标签页（launch 现有的「找到有 rapp-term 的窗口就开标签页」）。舞台切到第一个。一个失败（比如等「允许 rApp 控制终端」）就停下，提示原因，剩下的留在列表里。
- 全部清掉：删掉这台设备上所有可恢复的快照。

**被控 Mac 上**【我定的】：用 `/usr/local/bin/rapp`（pkg 装好的、已在 PATH 上的那个），不用 `rapp-term`（它在 app 包里，不在 PATH 上）：

```
rapp term restore            # 全部恢复
rapp term restore --list     # 列出可恢复的：序号、名字、程序、多久以前、目录
rapp term restore rapp train # 只恢复这几个（按名字或 --list 的序号）
rapp term restore --forget   # 全部清掉
```

- 本机命令行可以显示目录：在本机打印，不出设备。
- 经 hub 来的调用一律给 `restore_terms` 明写 `keys`；CLI 先用一次本机 `term_saved` 把它们算出来，所以没有可恢复的终端时，`rapp term restore` 打印「没有可以恢复的终端」并以 0 退出【计划里改的】。
- CLI 的参数：`rapp term restore 2`，全是数字的是从 1 开始的序号；其他的是名字，精确匹配，同名的快照全部选中；`--forget` 不接受参数【计划里改的】。
- 路径和 GUI 一样：CLI → 服务的 `Op` → serve 的新请求 `restore`。只对本机，不对别的设备【我定的】。

### 4.7 线上和本地协议的改动

- hub → 服务 → serve：
  - 新请求 `{"op":"restore","keys":[…]}`（空表示全部）；
  - `{"op":"forget","keys":[…]}`；
  - `open` 的 `from` 多接一个值 `"last"`；`open` 带着 `shell` 又带 `from` 时，shell 用请求里的。
- 终端列表里本机那一行（`HostRow`，`host == null`）加可选字段 `saved: [{key, name, prog, saved, boot}]`。不带 `cwd`、`cmd`、`venv`。
- 都是加字段，协议版本不升（多终端的做法）。旧设备不发 `saved`，GUI 就不显示「恢复」；旧 serve 不认 `restore`，GUI 不会对没有 `saved` 的设备发它。
- `log_fields`：`restore` 只记个数；`from` 只记有没有、是不是 `last`，不记值。

## 5. 兼容

| 情况 | 结果 |
|---|---|
| 新 GUI，旧被控端 | 没有「恢复」；「新建」在家目录开（`from` 是活终端 id 时旧 serve 认，能沿用；是 `"last"` 时不认，家目录） |
| 旧 GUI，新被控端 | `saved` 被忽略，看不到「恢复」；被控端上 `rapp term restore` 照样能用 |
| 升级前开的终端（旧 holder，没有钩子、不写快照） | 升级后不会出现在恢复列表里；新开的才有。升级前要关掉的那一批，只有在新版本里开过才能恢复 |
| CLI 升级合入后 | 升级不再关终端，快照不受影响；恢复主要用于重启电脑 |
| Linux 被控端 | 代码在 rapp-term 里，同一套；B 用 `/proc`。Linux 的终端 app 怎么开标签页按现有 launch 走。Linux 的实机检查由 Linux 那边做 |

## 6. 测试

- 单元：
  - OSC 7502 的解析：`state`、`run`、坏 base64、超长、被截成两半；
  - 快照的写法：去掉赋值、换行不存、超长不存、只存三个环境字段；
  - 删不删的判断表（§4.4 每一行）；
  - 可恢复的判断（活 key 排除、30 天、50 份）；
  - claude/codex 改写表；
  - `from: "last"` 的选择顺序；
  - `open` 里请求的 shell 与 `from` 的目录的组合。
- 集成（真起 shell）：
  - zsh、bash、fish 各起一个带钩子的 holder，`cd` 到别处、激活一个临时 venv，检查快照；
  - 跑 `sleep 100` 时快照有 `cmd`，回到提示符后清空；
  - 带 `--restore` 起来时激活了 venv，输入行里是填好的命令而没有执行；
  - 嵌套 zsh 看到的 `ZDOTDIR` 等于原值。
- `cargo test --workspace --no-fail-fast`（协议加字段要过 testkit）；GUI 的 `flutter test`（`saved` 的解析、按钮说「恢复」的条件、列表）。

## 7. 实机检查（写进 tasks/todo.md）

1. 开 3 个终端：一个在 venv 里跑 claude，一个在 conda 环境里空着，一个在别的目录跑 `npm run dev`。重启电脑，在 rApp 里恢复：目录、环境（提示符前的 `(venv)`、`(ml)`）、填好的命令都对，没有一个自己跑起来。
2. 同上，改在被控 Mac 上敲 `rapp term restore`。
3. 敲 `exit` 结束的、在 rApp 里点「结束终端」的，不在恢复列表里。
4. 点 Terminal 的红色关闭按钮关掉的，在恢复列表里，勾掉就不恢复。
5. 在终端 A（`~/git/x`）里点总览「新建」：新终端在 `~/git/x`；在设备页点「新建 · bash」：bash，在 `~/git/x`。
6. 重启 rApp 后什么都不看，直接点「新建」：在最近有输入的那个终端的目录。
7. 自己的 `~/.zshrc` 里的提示符（oh-my-zsh、starship 之类）、补全、别名在 rApp 开的终端里和直接开 Terminal 一样。
8. 在 rApp 开的终端里再敲 `zsh`、`tmux`：读的是用户自己的配置。
9. `KEY=xxx claude` 跑着时重启，恢复后填的是 `claude --continue`，`saved/` 里搜不到 `xxx`；`claude --api-key sk-abc…` 跑着时重启，恢复后只填 `claude`，`saved/` 里搜不到 `sk-`。
11. 恢复后不按回车再重启一次，命令还能填回来。
12. 只关窗口（不重启）后，总览按钮仍说「新建」；设备页有「上次没关的 1 个终端」。
10. macOS 自己的「重新登录时重新打开窗口」：重启后 Terminal 会不会把 rapp 的旧标签页重开成普通 shell，和恢复出来的混在一起（§8）。**⌘Q 再开 Terminal 的情形还没实测过**：标签页会不会回来、回来的是同目录的普通 shell 还是重跑 `.command`（见 todo 第 13 项的 ⌘Q 实验）。

## 8. 留给实现的

- **重启后 Terminal 自己恢复的窗口**（计划 P7；本机只查了设置，没做会关掉用户窗口的实验）：
  - 已观察：`defaults read com.apple.Terminal NSQuitAlwaysKeepsWindows` 和 `defaults read NSGlobalDomain NSQuitAlwaysKeepsWindows` 都没设，走系统默认，「退出应用时关闭窗口」是开着的。
  - **还没观察**：⌘Q 或重启后再开 Terminal，rapp 的标签页会不会回来；回来的话是同一目录里的普通 shell，还是重新跑了那个 `.command`。没有做，因为退出 Terminal 会关掉本机上所有人（包括别的会话）的 Terminal 窗口；已列为 todo 里一项没勾的实机检查。
  - 风险：Terminal 自己重开一个窗口，rapp 又恢复同一个终端，同一个终端就出现两份。
  - 最省事的缓解想法（只是想法，没做）：恢复时 sweep 一遍 Terminal 里没有 holder 的 rapp 旧标签页并关掉，或让 `.command` 的窗口不参与 Terminal 自己的恢复。
- **「最近有输入」**：已定，在 holder 的 status 里加 `input` 时间，不与 CLI 升级的 `activity` 共用（§4.1）【计划里改的】。
- **bash 的装法细节**：`--init-file` 和登录 shell 不能同时用；要在 bash 3.2（macOS 自带）上确认 `DEBUG` trap 拿到的是整行命令。
- **claude 各自的会话**：能否知道每个终端里 claude 用的是哪个会话（例如 `~/.claude/projects/<目录>/` 下的会话文件和进程的对应关系），从而填 `claude --resume <id>` 而不是 `--continue`。查不到就先用 `--continue`，记作已知限制。
- **iTerm**：恢复时开标签页的方式按现有 launch 走（iTerm 的标签页还没做，可能开成多个窗口）。
- 钩子文件的具体内容、OSC 7502 的字段名、快照写盘的防抖实现，由计划定。
