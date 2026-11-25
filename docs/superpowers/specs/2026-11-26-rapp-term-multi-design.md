# 多文字终端：⌘T 新建、结束终端、退得干净、被控端分得清（设计）

日期：2026-11-26。状态：**已定**（用户：“按你推荐的来”；随后“全部做完，中途不用问我”，审读提的 6 个问题由我定，见各处【我定的】）。标【我定的】的是我替用户做的选择，可以改。

## 0. 用户的要求（原话）

| # | 要求 |
|---|---|
| M1 | “还需要在已经打开终端上响应快捷键 CMD+T 创建新的终端。请规划一下这类多终端的体验功能加速。” |
| M2 | “关掉窗口、退出窗口是最麻烦的，它总退不干净。” |
| M3 | “新建窗口又是一大堆，不知道哪个是哪个。” → 追问后：“在被控 Mac 上看，想看出目录和跑的程序。” |

为什么：同时开好几个文字终端时，新开要绕到总览；用完关不干净，被控 Mac 上堆着「进程已完成」的空窗口，rApp 里留着「已断开」的会话；被控 Mac 上一排标签页都写着 `rapp-term`，分不清。

## 1. 现状（2026-11-26，local main c2eda424）

- **新建**：只能从总览「常用 · 终端」（说「新建」）或设备页开。`MainState.openText(id, {shell})` → hub `open_term` → 设备 `rapp-term serve` 的 `open` → 写一个 `.command` 文件（`exec rapp-term run --dir … --ticket … -- <shell> -l`），用 Terminal 打开。Terminal 已有 rapp 窗口时，新终端开成那个窗口的标签页（`launch.rs` `TERMINAL_TAB`，e09ed951，未发版）。
- **快捷键**：文字终端里 macOS ⌘ 组合先过 `term_keys.dart` `_shortcut`：⌘C 复制、⌘V 粘贴、⌘F 与 ⌘=/⌘− 保留；其余返回 null，冒泡给窗口。⌘T、⌘W 现在没人用。画面会话里 ⌘ 全给远端 app，rApp 自己的键是 ⌃⌘（⌃⌘[ ⌃⌘] 切换、⌃⌘O 总览……）。非 Mac 文字终端用 Ctrl+Shift。
- **关掉**：rApp 里 × 只是不看（文字终端规格 §X8，用户当初要“跟串流应用关闭后不关闭 host 应用一样”）。没有“结束程序”的按钮，规格写“想退出，就在终端里敲 `exit`”。
- **exit 之后**：holder（`rapp-term run`）随程序退出。被控端那个标签页照 Terminal 设置留着或关掉——这台 Mac 上留下了多个「进程已完成」窗口；holder 被 SIGHUP 时退出码 129，“干净退出才关”的设置也不关。rApp 里，视图收到 `session ended`，会话变「已断开」留在列表里，要手动再关。
- **被控端标题**：holder 把程序输出原样转给 Terminal 窗口。Terminal 只看得到 `rapp-term`，标签页写着「bruce — rapp-term — 80×24」，除非程序自己设了标题。holder 不知道前台程序是谁、在哪个目录。holder 已经在扫 OSC 0/1/2（`title.rs`）给 rApp 当名字用。

## 2. 目标 / 非目标 / 反目标

**目标**
1. 在文字终端里按 ⌘T，一步新建同设备的终端，从当前目录开始，落在被控 Mac 同一窗口的新标签页里。
2. 有一个明确的「结束终端」：真的结束，两边都不留东西。
3. 程序自己退出（`exit`、程序结束），两边自动收干净：rApp 不留「已断开」，被控 Mac 不留「进程已完成」。
4. 被控 Mac 上每个 rApp 开的标签页，一眼看出目录和正在跑的程序。

**非目标**
- iTerm 的标签页（iTerm 新终端照旧开新窗口）。
- rApp 里的名字规则（OSC 标题、` · 2` 后缀）不变。
- 画面会话（串流 app）的关闭语义不变。
- 不接管不是 rApp 开的终端（已定原则）；用户手动在自己 shell 里跑的 `rapp-term run` 结束时，不去关它的标签页。

**反目标**（做了也算失败）
- × 变成会杀程序：断网、手滑关掉不能伤到正在跑的 Claude。
- 关错标签页：关掉一个用户自己开的、或刚复用同一 tty 的新标签页。
- 标题闪：每秒改一次标题导致 Terminal 卡顿或标签页文字跳。
- 改坏程序看到的东西：rApp 里的画面、名字、OSC 7501 状态因为标题改写而变。

## 3. 做法的选择

被控 Mac 上「目录 · 程序」的标题由谁写：

| | A. holder 写进自己窗口（**选中**） | B. rApp 服务用 AppleScript 改标签页自定义标题 |
|---|---|---|
| 做法 | holder 往它转给窗口的输出里写 OSC 0；程序自己的 OSC 0/1/2 在转给窗口时被改写 | serve 轮询，发现变化就 `set custom title of tab` |
| 好处 | 一两秒内跟上；Linux 终端也一样；不多要权限 | holder 不碰程序输出 |
| 代价 | holder 要改写转给窗口的标题序列 | 只有 Mac；要轮询；频繁 AppleScript，Terminal 偶尔卡 |

用户选 A（“按你推荐的来”）。

其余部分只有一条合理的路（用户已认可）：
- 前台程序和目录由 holder 自己查（它持有 pty，`tcgetpgrp` 就知道前台进程组）。
- 结束走新的设备请求，holder 照“窗口被关”的路子结束程序。
- 关被控端标签页由 serve 用 AppleScript 按 tty 关，因为 Terminal 自己的“退出时关闭”设置靠不住。

## 4. 设计

### 4.1 holder 知道前台程序和目录

- holder 每 **1 秒**【我定的】查一次 pty 的前台进程组首进程（`tcgetpgrp` 在 master fd 上；portable_pty 在 unix 上有 `process_group_leader()`）。
- **程序名**取该进程 `argv[0]` 的文件名，去掉开头的 `-`（登录 shell 是 `-zsh`）。macOS 用 `sysctl KERN_PROCARGS2`，Linux 读 `/proc/<pid>/cmdline`。读不到再退回进程名（macOS `proc_name`，Linux `/proc/<pid>/comm`）。
  - 为什么不用进程名：原生安装的 Claude Code，可执行文件名是版本号（`…/claude/versions/2.x.y`），进程名会是 `2.x.y`，`argv[0]` 才是 `claude`【我定的】。
  - 已知局限：`node foo.js`、`python x.py` 显示 `node`、`python`。
- **目录**取该进程的当前目录（macOS `proc_pidinfo(PROC_PIDVNODEPATHINFO)`，Linux `readlink /proc/<pid>/cwd`）。
- 查不到（进程刚退、权限）就沿用上一次的值，不清空。
- 结果放进 `Shared`，供 4.2 标题、4.3 ⌘T 用。本机 `status` 加可选字段：
  - `fg`：程序名。
  - `cwd`：绝对路径。
  - `shell`：holder 启动的那个程序本身是不是前台，布尔。前台是 holder 直接启动的进程时为 true。
  - `tty`：holder 自己窗口的 tty 路径，如 `/dev/ttys012`，取 `ttyname(0)`，见 4.5。
- 这些字段都是新增可选的，旧 serve 不认就忽略。

### 4.2 被控端窗口标题「目录 · 程序」

- **格式**：`<目录> · <程序>`；程序自己设了标题时，后面接 ` — <程序标题>`。

  ```
  ~/git/rapp · claude — 修复登录
  ~/git/web · zsh
  ~ · vim
  ```

- **目录写法**【我定的】：家目录换成 `~`；超过 32 个字符时只留最后两级，前面写 `…/`（`…/src/pty`）。
- **程序标题**：
  - 用 `title.rs` 已有的清理规则：去掉转圈符号，最长 64 个字符。
  - 前台是 shell 时，丢掉 shell 自己设的标题。oh-my-zsh 设的 `user@host: ~/dir` 跟目录重复【我定的】。
  - 程序标题清理后，等于程序名或目录写法时，也不接【我定的】。
- **写法**：
  - holder 在转给窗口的字节流里，把程序发的 OSC 0/1/2 拿掉，只往窗口写 holder 自己的 `ESC ] 0 ; <标题> BEL`。标题里的控制字符在写之前去掉。
  - 只在标题文字变了时写，同一秒内最多写一次【我定的】。
  - 程序发来新标题时，立刻重算一次，不等下一秒。
- **只改给窗口的那一路**：holder 自己的模拟器（rApp 画面）和 `title.rs` 的名字仍然看程序原样的 OSC。rApp 里的名字、画面、OSC 7501 都不变（反目标 4）。
- **切分安全**：
  - OSC 可能被拆在两次 read 里。改写要跟 `ps::Scanner` 一样带状态，跨块认序列。
  - 认不全的序列（超长、坏掉）照原样转给窗口，不吞字节。
  - 只拿掉 OSC 0/1/2，其他 OSC 一个字节不改，比如 7、8 和 7501 的回答。
- **holder 不在 tty 上时不写**：stdout 不是 tty（测试、管道）就不写标题。已有 `Window::tty(...)` 判断。
- Linux 的终端（GNOME Terminal 等）认同一个 OSC 0，跟着就有。
- **Terminal 描述文件自带的标题部分不动**【我定的】：
  - Terminal 可能会在我们的标题后面再接它自己的部分，比如活动进程名、尺寸。所以标签页可能显示成 `~/git/rapp · claude — rapp-term — 80×24`。
  - 这可以接受：「目录 · 程序」在最前面，一眼能看到。
  - 不去改用户的 Terminal 描述文件设置。真机检查 2 要记下实际样子。

### 4.3 ⌘T 新建

- **哪里生效**：只在文字终端画面有焦点时。
  - macOS ⌘T；iPad 接键盘时也是 ⌘T，跟 `term_keys` 对 ⌘ 的处理一致。
  - Linux / Windows 是 Ctrl+Shift+T。
  - 画面会话里 ⌘T 照旧发给远端 app。
- **做什么**：`MainState.newTermFrom(device, term)`，在当前终端所在设备上新建一个。
  - 新终端开在被控 Mac 上**当前终端所在的那个窗口**的新标签页里【我定的】：
    - `TERMINAL_TAB` 多收一个参数：源 tty，即 `from` 那个 holder 的 `tty`。
    - 脚本先找含这个 tty 的标签页所在窗口，没有再照旧找任一含 `rapp-term` 的窗口。
    - 没有源 tty（从总览新建）时传空串，照旧。
  - 终端程序用 `prefs.termAppFor(device, launchers)`，跟总览「新建」一样。
  - 打开后切到新终端，和 `openText` 一样。
- **从当前目录、用当前 shell 开始**：
  - `Op::OpenTerm` 加可选字段 `from: Option<String>`，是当前终端的 term id。旧设备不认就忽略，照旧在家目录开，可以接受。
  - 设备端 `open` 查这个 holder 的 `status`：
    - 用它的 `cwd` 加 `--cwd`。`cwd` 不是目录时不加。
    - 用它的 `command` 当 shell，前提是那个 shell 在设备列出的 shells 里，否则用默认 shell【我定的】。
  - GUI 不需要知道目录。目录不经过 B，也不进日志。`log_fields` 只记 `from` 有没有，不记值。
- **不能新建时**：设备没有可用的终端窗口（launchers 空）、hub 不可用、设备离线时，给提示「这台设备没有可用的终端窗口」或 hub 的原话，不弹别的。
- **连按**：前一个 ⌘T 还在开时，再按一次照样排队开（`opening` 锁已经让设备端一次一个）。不吞，不合并【我定的】。

### 4.4 结束终端

- **入口**：
  - 文字终端的会话菜单（`StreamMenuAnchor` 那个菜单）里，现有的「结束」对文字终端改叫「关闭」，行为不变，仍只是不看【我定的】。
  - 紧跟其后加一项「结束终端」（危险色）。
  - 画面上的「结束会话」按钮对文字终端也改叫「关闭」。
  - 这样“关闭 = 不看”和“结束终端 = 真结束”不会混（反目标 1）。画面会话的「结束」不变。
  - 文字终端里 ⌘W，非 Mac 是 Ctrl+Shift+W。
  - × 不变，仍只是不看。
- **先问一句**：
  - 当前 `shell == false`（前台跑的不是 holder 启动的 shell）时，弹确认：
    - 标题：「结束终端？」
    - 正文：「里面还在跑 <fg>，结束后它也会被关掉。」
    - 按钮：「结束」（危险色）和「取消」，默认焦点在「取消」。
  - 前台就是 shell 时不问，直接结束。
  - 设备没报 `shell`（旧设备）时，菜单项不出现，见下面「旧设备」。
- **怎么结束**：
  - 新设备请求 `Op::EndTerm { term }`：hub 命令 `end_term`，设备 `serve` 的 `Req::End { term }`，再到 holder 本机 socket 的 `end` op。
  - holder 收到 `end`，做跟收到 SIGHUP（窗口被关）一样的事：
    - 给程序发 SIGHUP。
    - 等 `KILL_WAIT`（1 秒）还没退就杀掉。
    - 然后照常退出，告诉 viewer `session ended`。
  - 回 `{"ok":true}` 后才开始结束，让回答先送到。
- **rApp 这边**：
  - 请求成功就把这个会话从列表里拿掉，提示「已结束 <名字>」，切到下一个，跟画面会话「结束」一样走 `_endRecord`。
  - 失败就留着，提示 hub 的原话。
- **旧设备**：
  - 门槛是终端列表的行有没有 `shell` 字段（新 serve 加新 holder 才有）。没有就不出现「结束终端」，⌘W 也不响应，冒泡给窗口，跟现在一样。
  - **不改协议版本**【我定的】：`client-core` 的 `VERSION`（16）是画面流的握手，要求两边完全一致；为终端功能加一会让所有旧设备的画面会话断掉。
  - 万一请求被旧设备回了 `unknown op`，提示「这台设备的 rApp 太旧，不能结束终端」。

### 4.5 退得干净

**rApp 不留「已断开」**
- 文字终端视图收到 `session ended`（程序自己退了，或被结束了），会话直接从列表里拿掉，提示「已结束 <名字>」，切到下一个。不再变「已断开」，也不留最后一屏【我定的：用户要退干净】。
- **断线期间结束的也算**【我定的】：
  - 程序在断线时退了，重连时设备回 `no such text terminal`（`serve.rs` `NO_TEXT_TERMINAL`）。
  - 这也当作结束：拿掉会话，提示「已结束 <名字>」，不再重试。
  - 加进 `lifecycle.dart` 的 `stopsAutoReconnect` 和结束判断。
- 断网、连不上照旧是「已断开」，会自动重连。只有 `session ended` 和 `no such text terminal` 这两种原因走结束这条路。

**被控 Mac 不留「进程已完成」**
- 谁来关：设备上的 `rapp-term serve`。它已经有 Terminal 的自动化权限，开标签页就用它。
- 关哪些：只关 rApp 开的终端，也就是带 `--ticket` 的 holder（反目标 2，也是“不接管”原则）。
- **留记号，不靠 serve 记着**【我定的】。审读指出：serve 按需启动、闲了就停，也只在有 watch 时才扫，记在内存里的 tty 会丢。所以：
  - 带 ticket 的 holder 退出前，在 `<term 目录>/ended/` 下写一个文件。文件名是 tty 的文件名（`ttys012`），内容是退出时的 Unix 秒。
  - holder 不在 tty 上时不写。
  - serve 在下面三个时机扫一遍 `ended/`：
    - serve 启动时；
    - 每轮扫列表（`ask_pty`）时；
    - 收到 holder 的 `end` 回答 1.5 秒后。
  - 扫到的每个记号：
    - 超过 **10 分钟**的直接删，不关【我定的：防 tty 复用后关错】。
    - 没超过的，跑一段 AppleScript 去关。
    - 不论关没关成，记号都删。
  - 结果：用着 rApp 时，`exit` 之后一两秒标签页就关了。当时没有 rApp 连着的话，下次 serve 起来时关，10 分钟内有效。
- 怎么关：AppleScript 在 Terminal 里找 `tty of tab` 等于这个 tty 的标签页，只在它已经没有在跑的进程时才关。
  - 具体判断要在真机上看「进程已完成」的标签页报什么，例如 `busy` 为 false 且 `processes` 为空。
  - 有进程就不关：tty 已被新标签页复用，说明那不是我们的。
- 关法：关单个标签页；窗口里只剩它就关窗口。不会弹「要终止进程吗」，因为里面已经没有进程。
- Terminal 没在跑，或者没有这个 tty，就什么都不做。AppleScript 出错或超时（5 秒）只记日志。
- 一次扫到多个记号时，合成一个脚本关【我定的】。
- 这台 Mac 上已经堆着的旧「进程已完成」窗口不清扫：分不出是不是 rApp 的，留给用户手动关。
- **Linux**：终端窗口在程序退出后通常自己关（holder 是窗口里直接 exec 的程序），这一步只在 macOS 做。

### 4.6 协议和兼容

| 改动 | 旧的一方怎么样 |
|---|---|
| 本机 `status` 加 `fg` `cwd` `shell` `tty` | 旧 serve 忽略；新 serve 遇旧 holder：没有标题改写，⌘T 从家目录开，不关标签页，「结束终端」不出现（旧 holder 不认 `end`） |
| `TermRow` 加 `fg` `shell` | 旧 GUI 忽略 |
| `Op::OpenTerm.from` | 旧设备忽略，从家目录开 |
| `Op::EndTerm` | 旧设备回 `unknown op`；GUI 看 `TermRow.shell` 有没有来决定入口，见 4.4 |
| holder 本机 op `end` | 旧 holder 回 `unsupported`，serve 把它当失败报回去 |
| `TERMINAL_TAB` 多一个源 tty 参数 | 只在设备内部，没有兼容问题 |
| `ended/` 记号目录 | 旧 serve 不扫，记号留着；新 serve 起来后按 10 分钟规则处理 |

- 新 serve 怎么判断某个 holder 能不能结束：看它的 status 有没有 `shell` 字段（新 holder 才有）。`TermRow` 带 `shell`，GUI 据此决定菜单项出不出现【我定的】。
- `TermRow` 不带 `cwd`，也不带 `tty`：目录和 tty 不出设备。
- **不改 `client-core` 的协议 `VERSION`**，见 4.4。
- 按以前的教训：
  - testkit 的断言要跟着改，跑 `cargo test --workspace`。
  - 第二个协议允许名单（`peer.rs` 的 op 列表）要加 `EndTerm`。
  - `relay_link.rs` 里按 op 分会话的地方也要看一下 `EndTerm` 该不该算。

## 5. 留给实现的人

- 菜单项放在会话菜单的什么位置、图标：跟“改名”放在一起，危险色。
- 前台进程查询的具体系统调用封装；Linux 和 macOS 各一份，放在 `pty/` 下一个新文件里。
- OSC 改写器放 `title.rs` 旁边还是 `fit.rs` 的 `Window` 里：看哪个离“转给窗口”的写入点近。
- AppleScript 里判断“标签页里已经没有进程”的确切写法：在真机上用「进程已完成」的标签页试出来，写进测试说明。
- 4.5 的 10 秒、4.1 的 1 秒、4.2 的 32 字符，都可以按真机感受微调，改了要在文档里记一笔。

## 6. 实机检查（写进 tasks/todo.md）

1. 在文字终端里按 ⌘T：几秒内出现新终端，rApp 切过去；被控 Mac 上是同一窗口的新标签页；`pwd` 跟原终端一样。
2. 被控 Mac 标签页标题：
   - shell 里显示 `~/… · zsh`。
   - `cd` 后一两秒内跟着变。
   - 开 Claude 后变 `~/… · claude — <任务名>`，转圈符号不闪。
   - 退出 Claude 回到 `· zsh`。
3. rApp 里的名字、画面不受标题改写影响，跟 0.15.33 一样。
4. 「结束终端」：
   - shell 空闲时直接结束，标签页关掉，rApp 列表里消失。
   - 跑着 Claude 时先问，取消则什么都不变。
5. ⌘W 跟菜单一样。
6. 终端里 `exit`：rApp 会话自动消失，提示「已结束」；被控 Mac 上标签页自动关掉，不留「进程已完成」。
7. 用户自己在 Terminal 里手动跑 `rapp-term run` 再 exit：它的标签页**不**被关。
8. 断网再连：会话是「已断开」并自动重连，不被当成结束。断网期间在被控端 exit，重连后会话消失，提示「已结束」。
8a. 会话菜单里文字终端显示「关闭」和「结束终端」两项；画面会话仍是「结束」。
8b. 没有 rApp 连着时在被控端 exit，10 分钟内打开 rApp 连上，标签页被关掉。
9. 旧设备（0.15.33）：⌘T 能开，从家目录开始；没有「结束终端」；其他照旧。
10. Linux 被控端：标题跟着变；⌘T（Ctrl+Shift+T）能开；exit 后窗口自己关。
