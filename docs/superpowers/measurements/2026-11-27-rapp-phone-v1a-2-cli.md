# 手机第一版探查 2：三家 CLI 的按键、`msg` 和计划

规格：`docs/superpowers/specs/2026-11-27-rapp-iphone-v1-requirements.md` §6、§13 的 I2/I3/I7、§18 第 2 条、§20 第 2 条。任务书：`docs/superpowers/plans/2026-11-27-rapp-phone-v1a-2-cli.md`。
探查脚本在分支 `probe/phone-v1a-2`（不合入，留给 V1c 取用），最后一个提交 `92167ba3`。

## 机器和版本

| 项 | 值 |
|---|---|
| 机器 | Mac17,2，Apple M5，macOS 27.0.1 |
| rapp | 0.15.67（`/Applications/rapp.app` 里的 `rapp-term`，未改） |
| Claude Code | 2.1.332，Opus 5.5 |
| Codex | codex-cli 0.172.0，GPT-6.2-Sol |
| agy | Antigravity CLI 1.5.18，Gemini 4 Carbon |
| 外面的窗口 | 私有 tmux 3.8 服务器（`-L rapp-p2`），120×40；里面是 `rapp-term run --dir /tmp/rapp-phone-probe/p2/term` |

做法：
- 每个会话都在 rapp 的终端里跑（`rapp-term run`）。状态从它的本地 socket `status` 每 100 ms 取一次，屏幕和按键走现有的文本终端协议（`view`、`keys`、`text`）。原始输出另存一份，用来解 OSC 7501 原文。
- 按键和计时由 `trials.py` 做。每次一个新编号的文件名，所以每次互不依赖。“成了”的意思是：键按下后状态离开等待；文件该有的有、不该有的没有；或者屏幕上出现了选中的那一项。
- 工作目录全在 `/tmp/rapp-phone-probe/p2/ws/`。被测程序没碰仓库，也没碰用户的会话。用户默认的放行设置都改掉了，改成会问：
  - Claude Code 加 `--permission-mode default`（用户默认是 auto）；
  - Codex 加 `-a on-request -s read-only -c notify=[]`；
  - agy 加 `--settings '{"toolPermission":"request-review"}'`，再用 Shift+Tab 切到不带标签的默认模式。
- 中心服务另起一个私有的（`rapp-center --port 18799 --data /tmp/…`），没往用户的中心服务发过东西。

## 总表

格式：按键序列；成功次数/总次数；要注意的。“早按”指看到 `blocked` 后 0.1–0.2 s 内就按，不等画完。

| | Claude Code | Codex | agy |
|---|---|---|---|
| **允许**（命令） | `1`：6/6，早按 5/5；`Enter`：5/5 | `y`：4/5；`1`：5/5；`Enter`：5/5；早按 `y`：5/5 | `1`：5/5，早按 5/5；`Enter`：5/5 |
| **允许**（改文件） | `1`：5/5 | `y`：5/5 | `1`：新建 5/5，改已有文件 4/4（另 1 次程序自己没停下来问） |
| **拒绝** | `Esc`：命令 5/5，改文件 5/5 | `Esc`：命令 5/5，改文件 5/5 | `Esc`：命令 5/5，新建文件 5/5。**改已有文件时 `Esc` 不管用**（2/2 没反应）：用 `2` 5/5。`Up Enter` 只有 2/5，因为这一问会记住上次光标停在哪。命令上 `Up Enter` 5/5 |
| **选第 N 项** | 数字 `N`：N=2 5/5，N=3 5/5，早按 5/5；`Down Enter`：5/5 | 数字 `N`：N=2 4/4，N=3 4/4；`Down Enter`：5/5。**只在 Plan 模式下才算等你**，见 Q1 | 数字 `N`：N=2 5/5，N=3 5/5；`Down Enter`：5/5 |
| **送一段字** | 括号粘贴 + `Enter`：61/61（每次试都先这样送指令） | 同左：65/66（那 1 次是 `/new` 之后马上送，回车被吃掉，见 Q2） | 同左：58/58 |
| 光标起点 / `Enter` | 第 1 项 / 等于选第 1 项（5/5） | 第 1 项 / 等于选第 1 项（命令 5/5，提问 2/2） | 第 1 项 / 等于选第 1 项（命令 5/5，提问 5/5）。**改已有文件那一问例外**：光标停在上一次选的那项，上次选了 “No”，这次 `Enter` 就是 “No” |
| 提问里按 `Esc` | 取消，回到 `idle`：5/5 | 打断这一轮，回到 `idle`：3/3 | 跳过，答案是 “Skipped”，`done`：5/5 |

所有成了的次数里，按键到状态离开等待都是 0.15–0.17 s（`Down Enter` 0.30–0.34 s，就是两次按键的间隔）。三家都没出现选项顺序变的情况。按早了被吞掉的，一次都没有。

## 判词（C4、C18–C20、I3）

| | 放行卡片（允许 / 拒绝） | 提问卡片（选第 N 项） | 评审卡片（同意 / 要改） |
|---|---|---|---|
| Claude Code | **有按钮**：允许 `1`，拒绝 `Esc` | **单个问题、单选、选项 ≤4 时有按钮**：数字 `N`。一次问好几个问题，或者是多选的：只有“进去看” | **能认出来，有按钮**：同意 `2`，要改 `3` + 一段字 + `Enter`。要点只能来自 hook 或计划文件 |
| Codex | **有按钮**：允许 `y`，拒绝 `Esc`。但没有 `msg`，C9 的“撤不回”认不出来 | **只有“进去看”**：没有 `msg`，拆不出选项（§6.2 原本就这么定的） | **认不出来**：等你点头时报的是 `done`，没有 `msg`，和“做完了”一样。只能出“做完”卡片 |
| agy | **有按钮**：允许 `1`；拒绝看 `msg`：`Approve Edit:` 开头按 `2`，其他按 `Esc`（`Esc` 在改已有文件时不管用） | **只有“进去看”**：`msg` 只有问题，没有选项 | **能认出来**（`msg` = `Approve plan`）。但屏幕上没有对话框，同意要先送 `/artifact`，再按 `y`；第一版建议只有“进去看” |

## Q1 按键

**三家都是“数字选第几项，`Enter` 选光标所在那项”，光标一般在第 1 项（agy 改文件那一问例外，会记上次的位置）；允许都能用 `1`。拒绝最好不用数字：“不”在第几项，每次不一样。Claude Code 和 Codex 用 `Esc`。agy 改文件用 `2`，其他用 `Esc`：它改已有文件时 `Esc` 被关掉了。**

### Claude Code

- **第一次进目录**：问“trust this folder”，`kind=permission`。光标在 “No, exit”，**按 `Enter` 会退出**。要按 `Down Enter` 才是信任。这一问 rapp 不该给“允许”按钮。
- **跑命令**：屏幕上是 4 项：
  - `1. Yes`
  - `2. Yes, and always allow access to <目录> from this project`
  - `3. Yes, and switch to auto mode`
  - `4. No`

  提示是 “Esc to cancel · Tab to amend”。“以后都允许”是第 2 项，第 3 项会切到 auto 模式。这两项都会改用户的设置，手机上不给。“No” 在第 4 项，但项数随命令变，所以拒绝用 `Esc`：5/5，文件没建出来，状态 0.16 s 回到 `idle`。
- **改文件**（Write）：`1` 允许 5/5，`Esc` 拒绝 5/5。
- **提问**（AskUserQuestion）：
  - 选项排成 “❯ 1. Red / 2. Blue / 3. Green / 4. Type something. / 5. Chat about this”。后两项是程序自己加的，不在 `msg` 里。
  - 数字直接选中、直接交。屏幕上留下 “· Pick a color → Blue”。
  - 一次问两个问题时，上面有一排标签（“☐ Database ☐ Checks ✔ Submit”）。数字答完第一个，会跳到第二个。
  - 多选（multiSelect）时，数字只是打勾。要 `Tab` 到 Submit 页，再按 `1`（Submit answers）才交。手机上一个按钮做不了这件事。
- **计划**：见 Q4。

### Codex

- **跑命令**：屏幕上是
  - “Would you like to run the following command?”，下面是 Reason 和 `$ touch c116.txt`
  - `› 1. Yes, proceed (y)`
  - `2. Yes, and don't ask again for commands that start with … (p)`
  - `3. No, and tell Codex what to do differently (esc)`

  `y`、`1`、`Enter` 都是允许。`Esc` 是第 3 项：拒绝，然后 Codex 结束这一轮。状态是先 `working`（0.15 s），再 `idle`。`p` 会改设置，不给。
- **改文件**（patch）：“Would you like to make the following edits?”，下面是 `1. Yes, proceed (y)`、`2. … don't ask again for these files (a)`、`3. No … (esc)`。`y` 5/5，`Esc` 5/5。
- 这两种确认**只在用户的放行策略会问时才出现**。用户自己的配置是不问（`approval never` + `danger-full-access`）。在那种配置下，Codex 根本不会停下来等放行。
- **提问**（request_user_input）：
  - 屏幕上是 “Question 1/1 … / › 1. Red (Recommended) / 2. Blue / 3. Green / 4. None of the above”，提示 “tab to add notes | enter to submit answer | esc to interrupt”。
  - 数字直接交，屏幕上留下 “answer: Blue”。
  - **只在 Plan 模式下会停下来等**。在默认模式下，状态一直是 `working`。屏幕上只有一行 “• Queued follow-up inputs / ? 1 question / ⇧← to answer”，要按 `Shift-Left` 才打开选项。没人答，这一轮就挂着：实测挂了 4 分钟多。rapp 看到的是“在干活”，不会出卡片。
  - 有 10 次没停下来等，都是模式不对，不是按键的问题，不计入总表：9 次是提问时模式被 `/new` 切回了默认；1 次是放行时模式还停在 Plan，Codex 在 Plan 模式下没去跑命令。另有 1 次是 `/new` 之后马上粘贴的指令，回车没被处理。

### agy

- **第一次进目录**：问 “Trust this folder?”，光标在 Yes，`Enter` 就是信任。启动时还有一闪而过的 `blocked kind=auth msg=Sign in required`，0.1 s 后变 `idle`。
- **跑命令**：屏幕上是
  - `> 1. Yes, run command`
  - `2. Yes, and always allow in this conversation for commands that start with 'touch'`
  - `3. Yes, and always allow … (Persist to settings.json)`
  - `4. No, cancel`

  第 3 项会写进用户的设置文件，不给。复合命令（`ls … && python3 --version`）只有两项：“1. Yes, run command / 2. No, cancel”。**所以“不”在第几项是变的。**
- **新建文件**：“> 1. Yes, allow creation / 2. No, deny creation”。`1` 5/5，`Esc` 5/5。
- **改已有文件**：“Accept this file edit? / > 1. Yes, accept this change / 2. No, reject this change”。**按 `Esc` 没用**，屏幕上提示 “Esc disabled during file edits — press 1 to accept or 2 to reject.”。
  - `msg` 和新建文件一样，都是 `Approve Edit: Write: <路径>`，从 `msg` 分不出这两种。
  - **这一问会记住上次光标停的位置。** 上一次选了 “No”，下一次框一出来光标就在 “No” 上，这时 `Enter` 是拒绝，`Up Enter` 反而绕回 “Yes” 改了文件（5 次里 3 次这样，都紧跟在一次 “No” 后面）。`2` 5/5，`1` 4/4，不受影响。
  - 命令那一问不记：每次都从第 1 项开始。`Up` 从第 1 项绕到最后一项 “No, cancel”，`Up Enter` 5/5。
  - 新建文件和改已有文件的第 2 项都是 “No”，所以 `msg` 以 `Approve Edit:` 开头时按 `2` 就是拒绝。新建文件上按 `2` 没量，新建文件上量过的是 `Esc` 5/5。
- **读工作目录外的文件**：“> 1. Yes, allow access / 2. Yes, and always allow non-workspace access / 3. No, deny access”，`msg` = `Approve ReadFile: Read: <路径>`。
- **提问**（ask_question）：
  - 屏幕上是 “Question 1/1: Pick a color / > 1. Red / 2. Blue / 3. Green / 4. Write-in...”，提示 “↑/↓ Navigate · enter Select · esc Skip”。
  - 数字直接交，屏幕上留下 “> Blue”。
- **计划**：见 Q4。

## Q2 稳不稳

**按键本身很稳：三家所有该成的都成了，没有按了没反应，没有按早了被吞，选项顺序没变过。不稳的是“程序有没有停下来等”，以及我们自己这一头的时机。**

| 现象 | 哪家 | 次数 | 怎么回事 |
|---|---|---|---|
| 状态报了 `blocked`，0.1 s 后就变 `working`，确认框却还在屏幕上 | agy | 1 次（ag2，`pip` 那条命令） | 原因没查清。0.3 s 后按 `1`，那条命令显示失败（多半是命令本身失败）。只出现过一次 |
| 提问不报 `blocked` | Codex | 默认模式下每次都这样 | 见 Q1。Codex 的提问只在 Plan 模式下才算等你 |
| `/new` 之后立刻送的回车没处理 | Codex | 1 次（#105） | 脚本时机问题，不是按键失败。`/new` 之后等 4–8 s 再送，就没再出现 |
| `view` 刚连上、第一屏还没回来就发的键丢了 | agy（ag2） | 连着 4 次 | **这是文本终端协议这一头的事，不是 CLI 的事。** 连上 `view`、发完 `view` 请求就立刻发 `keys`，键没进程序；等第一屏 `screen` 回来再发，就都进去了。之前几百次没碰上，是因为屏幕小、第一屏回得快。I2 的实现要等对方确认就位再按，或者在 `rapp-term` 里把这种键排队，别丢 |

## Q3 `msg`

**Claude Code 的 `msg` 最全，提问也带选项。但选项用 “ · ” 连起来，选项里自己有 “ · ” 或括号时就拆错。agy 的提问只有问题，没有选项。Codex 什么时候都没有 `msg`。**

OSC 7501 原文的样子是 `blocked;kind=permission;app=claude-code;msg=<base64>`（BEL 结尾）；Codex 的用 ST 结尾，没有 `msg` 字段。下面是解开 base64 之后的 `msg`。

### Claude Code（`app=claude-code`）

| 类 | `state` / `kind` | `msg` |
|---|---|---|
| 跑命令 | `blocked` / `permission` | `approve Bash: touch a101.txt` |
| 跑命令 | 同上 | `approve Bash: touch a152.txt` |
| 改文件 | 同上 | `approve Write: /private/tmp/rapp-phone-probe/p2/ws/cc1/w116.txt` |
| 改文件 | 同上 | `approve Write: /private/tmp/rapp-phone-probe/p2/ws/cc3/calc/core.py` |
| 信任目录 | 同上 | `trust this folder` |
| 提问 | `blocked` / `question` | `answer: Pick a color (Red · Blue · Green)` |
| 提问（两个问题） | 同上 | `answer: Which database for the demo? (SQLite · Postgres · No database)` |
| 提问（拆不出来） | 同上 | `answer: Deploy which build (staging or prod)? (v1.2 (rc) · v1.3 · beta · Skip (wait))` |
| 计划 | `blocked` / `permission` | `approve plan` |
| 干活中 | `working` | `Creating empty file a101.txt`；`Writing ~/.claude/plans/<名字>.md` |
| 做完 | `done` | 没有 `msg` |

提问的规律是 `answer: <问题> (<选项> · <选项> · …)`。
- 只要问题和选项里都没有括号和 “ · ”，按“最后一对括号”和 “ · ” 拆，就拆得对。
- 选项标签只有短标签，没有屏幕上第二行的说明。
- 程序自己加的 “Type something.” 和 “Chat about this” 不在里面。它们在屏幕上排第 4、5 项（或第 N+1、N+2 项），不影响前 N 项的数字。
- 拆不出来的例子在上表最后一行：选项 “v1.3 · beta” 里自己有 “ · ”，拆出来是 4 项，屏幕上是 3 项；问题里也有括号。
- 一次问两个问题时，`msg` 只有第一个问题，第二个问题和多选的标记都不在 `msg` 里。

**建议**：
- 拆出来的项数要和选项数对得上，问题里也不能有不配对的括号，否则只有“进去看”。
- 单选、多选、一次几个问题，从 `msg` 分不出来。手机上照第一个问题出按钮：如果其实是多问题，按数字只答了第一个，程序会停在第二个问题上，状态还是 `blocked`、`seq` 不变。C13 的“限定时间内状态离开了等待才算成功”会把它判成没成功，写“没成功，进去看看”，不会出错。

### Codex（`app=codex`）

| 类 | `state` / `kind` | `msg` |
|---|---|---|
| 跑命令 | `blocked` / `permission` | 没有（30 次都没有） |
| 改文件 | 同上 | 没有 |
| 提问（Plan 模式） | `blocked` / `question` | 没有（21 次都没有） |
| 计划等你点头 | `done` | 没有 |
| 干活中 / 做完 | `working` / `done` | 没有 |

### agy（`app=antigravity`）

| 类 | `state` / `kind` | `msg` |
|---|---|---|
| 跑命令 | `blocked` / `permission` | `Approve Bash: touch g101.txt` |
| 跑命令（长的被截断） | 同上 | `Approve Bash: python3 -m pip --version; python3 -c "import setuptools; print(setuptools.__ver…` |
| 跑命令（复合） | 同上 | `Approve Bash: ls -la /private/tmp/rapp-phone-probe/p2/ws/ag2 && python3 --version` |
| 新建 / 改文件 | 同上 | `Approve Edit: Write: /private/tmp/rapp-phone-probe/p2/ws/ag1/w116.txt`；`Approve Edit: Write: …/ws/ag2/calc.py` |
| 读目录外的文件 | 同上 | `Approve ReadFile: Read: /private/tmp/rapp-phone-probe/p2/hooks/emit_text.py` |
| 信任目录 | 同上 | `Trust this folder?` |
| 登录 | `blocked` / `auth` | `Sign in required`（启动时一闪） |
| 提问 | `blocked` / `question` | `Pick a color`（只有问题，26 次都是这样） |
| 计划 | `blocked` / `permission` | `Approve plan` |
| 做完 | `done` | 有一句结果，例如 ``Ran `touch g101.txt` to create [g101.txt](file:///…/g101.txt).``；提问被跳过时是 `Skipped`，答了是答案本身，如 `Blue` |

agy 做完时的 `msg` 带 Markdown 链接（`[名字](file:///…)`）。C8 拿它当一句结果时，要把链接换成名字。

## Q4 计划

**Claude Code 和 agy 的计划能从 `msg` 认出来（`approve plan` / `Approve plan`），Codex 认不出来（报 `done`）。“前三条”从屏幕上取，只有 Codex 和短计划靠得住。完整的计划原文，三家都在被控端的文件里，现有的文本终端协议拿不到。**

| | 等你点头时的状态 | 屏幕上 | 完整原文在哪 | 按键 |
|---|---|---|---|---|
| Claude Code | `blocked` / `permission` / `approve plan`，和普通确认分得开（7 次都一样） | 全屏对话框 “Ready to code? / Here is Claude's plan:”，接着是计划正文，最后是 “1. Yes, and use auto mode / 2. Yes, manually approve edits / 3. Tell Claude what to change”。**计划长时被截断**，下面有 “↓”；长计划的第一屏只露出第 1 步的一部分 | `~/.claude/plans/<名字>.md`（路径在对话框底下，也在干活时的 `msg` 里：`Writing ~/.claude/plans/….md`）；hook 拿到的 `tool_input.plan` 是全文（实测 4479 字） | 同意 `2`（`1` 会切到 auto 模式，不给）；要改 `3`，然后一段字 + `Enter`（重新出计划，11 s 后又 `approve plan`）；拒绝 `Esc`（5/5 + 1）。`PageDown` 翻计划正文，状态不变 |
| Codex | **`done`，没有 `msg`**，和普通的“做完了”一样 | 计划正文（“• Proposed Plan”，带编号）在对话里，下面是 “Implement this plan? / › 1. Yes, implement this plan / 2. Yes, clear context and implement / 3. No, stay in Plan mode”。8 步的计划一屏放得下；alt 屏，没有回滚 | 会话记录 `~/.codex/sessions/…/rollout-….jsonl` 里，助手那条消息带 `<proposed_plan>…</proposed_plan>` 全文 | 同意 `1`（切到默认模式开干，1 次）；要改：`Esc`，然后一段字 + `Enter`（重新出计划，12 s 后又是 `done`，1 次）；`3` 是留在 Plan 模式 |
| agy | `blocked` / `permission` / `Approve plan` | **没有对话框**。只有它的一段总结，底下一行 “1 artifact · /artifact to review”。总结里有没有步骤看运气：一次只有 “Key design notes…”，一次列了 4 步。不是 alt 屏，有回滚 | `~/.gemini/antigravity-cli/brain/<id>/implementation_plan.md`（路径打在屏幕上）。`/artifact` 里按 `p` 预览，只出约 12 行，然后是 “... 134 more lines” | 同意：送 `/artifact` + `Enter`，出 “Action required (1 left) / › □ new implementation_plan.md open approve reject”，再按 `y`（1 次）；要改：同样先 `/artifact`，再按 `n`，它回一句“告诉我要改什么”，状态 `done`，然后再送一段字（1 次）。送 `/artifact` 时状态一直是 `blocked` |

**按规则取“前三条”（C19 ②）**：
- **Claude Code**：从屏幕上取，长计划不行，第一屏连第 1 步都不全；靠翻页拼也是猜屏幕，不建议。从 hook 拿到的全文取，按 `^\s*\d+[.)]\s+` 取前三个编号行，两次都取对了。
- **Codex**：屏幕上的编号行就是步骤，8 步的计划取得出来。但它根本不报“等你点头”，取了也没有卡片可挂。
- **agy**：屏幕上不一定有步骤。全文只在文件里。

## Q5 评审用的 skill（§20 第 2 条）

**Claude Code 用 hook 能做到：时机准，三条要点对，拿得到全文。Claude Code 用说明文字、agy 用说明文字，也发得出来，但早了 8–46 秒，而且挂不上会话。Codex 用说明文字发不出来。三家都卡在同一件事上：程序不知道自己在 rapp 的哪个会话里。**

| | 做法 | 发出来没有 | 时机 | 带得上会话吗 |
|---|---|---|---|---|
| Claude Code | 项目设置里加 PreToolUse hook，`matcher: ExitPlanMode`，脚本从 `tool_input.plan` 取前三个编号行，`POST /v1/events` 发 `emit` | 发出来了（204），2 次 | **早 0.1 s**：hook 在 316.40 发，`approve plan` 在 316.48 报出来；“要改”以后重新出计划，又发一次 | 能拿到程序所在的伪终端名（`ttys038`）。但 `rapp-term` 的 `status` 里的 `tty` 是**外面窗口**那个（`ttys037`），不是程序的，所以对不上会话。见下 |
| Claude Code | 只给说明文字：“出计划前跑 `python3 emit_text.py "<三行>"`” | 发出来了（204），1 次。计划模式里跑这条命令没问它；它先读了一遍脚本 | 早约 8.5 s | 不能：Bash 工具里没有控制终端（`tty` 是 `??`） |
| Codex | 同样的说明文字，在 Plan 模式 | **没发**，1 次。它说“这个 hook 会把计划发到一个服务、还会写日志，所以在 Plan 模式下我跳过了” | — | — |
| agy | 同样的说明文字，在 plan 模式 | 发出来了（204），1 次。跑之前问了一次放行（`Approve Bash: python3 …emit_text.py "- Add multiply(a, b) to ca…`），还读了一次脚本（目录外，也要放行） | 早约 46 s | 拿到的是程序的伪终端（`ttys028`），和 Claude Code 的 hook 一样对不上 `status` |

要点的质量：
- 模型自己写的三条都是一句话，能直接上卡片。
- hook 按规则从全文取的是整段步骤：三段加起来超过 500 字，第三条被中心服务截掉了。按 C23 一行最多折两行，要再截成第一句。

**挂会话**：
- 中心服务的 `emit` 有 `session` 字段，但程序那一头填不出 rapp 的会话：
  - 子进程只有 `TERM`，没有 `RAPP_TERM` 之类的环境变量；
  - `rapp emit` 命令 0.15.67 里还没有（`rapp-cli emit` 报“不认识的命令”），状态规格 §11 里写着要做；
  - `status` 只给外面窗口的 `tty`，不给程序的伪终端。
- 探查里用的是 `session = "tty:<程序的伪终端>"`。这只能证明“拿得到一个能对上的标识”，不是接口。

**结论**：skill 先给 Claude Code，用 hook。它是三家里唯一时机准、内容全、不用模型配合的。
- 但 hook 写在用户（或项目）的 Claude Code 设置里。C22 说 rapp 不替用户装、不改用户配置，所以只能由用户自己装。
- agy 的说明文字能用，但每次要放行两次，早 46 s。
- Codex 的说明文字在 Plan 模式下被拒。而且它的计划本来就认不出来，给它 skill 也没卡片可挂。

## 建议的 app 配置（每家的按键对照）

格式留给 V1c，这里只列内容。“没有”的那一项，手机上只有“进去看”（I3）。

```
claude-code:
  认程序: app=claude-code
  放行.允许: ["1"]
  放行.拒绝: ["Esc"]
  放行.例外: msg 是 "trust this folder" 时不给按钮（Enter=退出）
  提问.选第N项: ["<N>"]        # 只在 msg 拆得出、N ≤ 4、项数对得上时
  评审.认法: kind=permission 且 msg == "approve plan"
  评审.同意: ["2"]              # 不用 1：会切到 auto 模式
  评审.要改: ["3", 文字, "Enter"]
  送一段字: 括号粘贴 + Enter

codex:
  认程序: app=codex
  放行.允许: ["y"]
  放行.拒绝: ["Esc"]
  提问.选第N项: 没有            # 没有 msg
  评审: 没有                    # 等你点头时报 done，认不出来
  送一段字: 括号粘贴 + Enter

antigravity:
  认程序: app=antigravity
  放行.允许: ["1"]
  放行.拒绝: msg 以 "Approve Edit:" 开头 → ["2"]，其他 → ["Esc"]
                               # 改已有文件时 Esc 不管用；那一问记光标，Up Enter 不稳
  提问.选第N项: 没有            # msg 只有问题，没有选项
  评审.认法: kind=permission 且 msg == "Approve plan"
  评审.同意: 第一版没有         # 要 "/artifact" Enter 再 "y"，中间要等列表画出来
  评审.要改: 第一版没有
  送一段字: 括号粘贴 + Enter
```

几条通用的：
- **允许一律用第 1 项**。三家的第 1 项都是“只这一次”。“以后都允许”的那几项会写用户的设置，手机上都不给：Claude Code 的 2、3，Codex 的 `p`/`a`，agy 的 2、3。
- **拒绝尽量不用数字**：“不”在第几项，每家、每种确认都不一样。唯一的例外是 agy 改文件，只有两项，`2` 就是 “No”。
- **不要靠光标位置**：agy 改文件那一问会记上次的光标。要选哪项就按哪个数字。
- 按完到状态离开等待，三家都在 0.2 s 以内。C13 的“限定时间”定 3 s 绰绰有余；`Down Enter` 这种两键的也在 0.35 s 内。

## 没验过的

- **用户自己的配置下**三家会不会停下来问。实测时都把放行改成会问了。用户本机的默认是：Claude Code auto，Codex 不问 + 全权限，agy 总是放行。照这个配置，三家多半很少报放行。
- agy 新建文件上按 `2`、读目录外文件那一问的拒绝（`Esc` 或 `3`），都没量。
- agy 别的确认（命令、读文件、提问）会不会也记光标，只在命令上看过：命令不记。
- Claude Code 的计划“同意 `2`”只做了 1 次，“要改 `3`”1 次。Codex 和 agy 的计划按键各 1 次。计划一次要几分钟，没做满五次。
- Claude Code 的多问题、多选提问只看了 1 次，没量稳定性。
- Codex 在 Plan 模式下的提问：`Enter` 只有 2 次有效（3 次是模式被切回默认，没停下来），`Esc` 只做了 3 次，数字 `N` 各 4 次。都不到五次。不过 Codex 的提问本来就只有“进去看”，不影响判词。
- agy 那次“`blocked` 0.1 s 就变 `working`”的原因。
- 三家在中文界面、窄屏（比如手机那么窄的 `view`）下的样子。所有量都在 120×40。
- Claude Code 的 skill（不是 hook）形式；hook 以外，有没有更正式的接口能拿到计划。
- 程序在 tmux 里（rapp 只看到 tmux）时，这些都拿不到。这是 §6.2 已有的结论，没再量。

## 对规格的影响

1. **C18–C20 对 Codex 落空**：Codex 的计划等你点头时报的是 `done`，没有 `msg`。照 §6.2 “没有 `msg` 不猜屏幕”，它只能出“做完”卡片，点“知道了”不往终端里发东西。要给 Codex 评审卡片，有两条路，都要用户定：
   - 让 `rapp-term` 认 Codex 的 “Implement this plan?” 这一屏。这是猜屏幕，和 §19 第 2 条冲突。
   - 或者等 Codex 自己在状态上报里加上这一种。
2. **Codex 的提问只在 Plan 模式下才算等你**。默认模式下不报 `blocked`，手机上看到的是“在干活”。§6.2 的“Codex 在问你”只对 Plan 模式成立。
3. **Codex 放行没有 `msg`，C9 的“撤不回”认不出来**。§6.2 已经定了“两个按钮照样有”。那么 Codex 的 `git push` 也是一张没有条纹的普通卡片，点一下就推了。要不要对 Codex 的放行只给“进去看”，请用户定。
4. **C4 的解析规则要加限制**：
   - Claude Code 的 `msg` 里，选项用 “ · ” 连，选项里本身有 “ · ” 或括号时拆错；
   - 一次多个问题、多选，都分不出来。

   建议：拆出来对不上，就只有“进去看”；多问题时按钮只答第一个，靠 C13 兜底。
5. **agy 的提问只有“进去看”**：`msg` 只有问题。§6.2 写的 agy “没有实测”，现在可以改成：放行有 `msg`，有按钮；提问 `msg` 只有问题，只有“进去看”；评审认得出来，但第一版只有“进去看”。
6. **C19 ② 的“前三条”实际只能从计划文件或 hook 来**。现有的文本终端协议拿到的屏幕，Claude Code 长计划是截断的，agy 不一定有步骤。要从文件取，就要给协议加一种请求（读被控端的计划文件），或者让 skill/hook 发 C21。这是加协议消息，要用户定。不加的话，C19 对没装 skill 的大多落到 ③：“出了计划，等你点头”。
7. **C21 / I7 挂会话缺一块**：程序不知道自己在 rapp 的哪个会话里。状态规格 §11 的 `RAPP_TERM` 环境变量和 `rapp emit` 还没做。没有它，`emit` 只能是一条普通通知（I7 的后半句）。C21 的 skill 要等这一块。
8. **I2 的实现要等第一屏**：在文本终端协议上，`view` 刚连上就发的键会丢（见 Q2）。I2 走新请求的话，要保证这种键不丢。
9. **Claude Code 的评审“同意”要用 `2`，不能用 `1`**。第 1 项是 “Yes, and use auto mode”，会把会话的放行模式切到 auto。这和 C14 “没有任何自动放行”的意思相冲突。
10. **Claude Code 的信任目录那一问，`kind` 也是 `permission`**。
   - 光标停在 “No, exit”，`Enter` 会退出程序；按 `Down Enter` 才是信任。
   - 数字键在这一问上没量。
   - 建议 `msg` 是 `trust this folder` 时只有“进去看”。agy 的 “Trust this folder?” 光标在 Yes，同样建议只有“进去看”：信任一个目录不是一次性的放行。

## 给下一期的话

- 认程序看 `ps.app`：`claude-code`、`codex`、`antigravity`。
- 认计划：
  - Claude Code：`kind=permission` 且 `msg == "approve plan"`；
  - agy：`kind=permission` 且 `msg == "Approve plan"`（大小写不同）；
  - Codex：认不出来。
- Claude Code 提问的 `msg`：`answer: <问题> (<选项1> · <选项2> · …)`，分隔符是 U+00B7 前后各一个空格。
- 三家按键到状态离开等待都是 0.15–0.17 s。按键后等状态离开等待，用 `seq` 变没变判断：三家每次变状态，`seq` 都加 1。
- 文本终端协议发键前，先等 `view` 回第一屏。不然可能丢键，探查脚本吃过这个亏。
- 按钮只发数字或 `Esc`，不发 `Enter`、`Up Enter` 这种靠光标的键：agy 改文件那一问会记上次的光标。
- 送一段字用现有的 `text`（括号粘贴，`enter: true`），三家都认。Codex 刚 `/new` 完要等几秒。
- “以后都允许”的选项都会写用户的设置。手机上永远不给。
- Claude Code 的计划文件路径会出现在干活时的 `msg` 里：`Writing ~/.claude/plans/<名字>.md`。“要改”以后是 `Editing …`。如果以后加“读计划文件”的请求，可以从这里拿路径。
- Claude Code 的 hook 样例在探查分支的 `probes/phone-v1a-2/hooks/emit_plan.py`：取前三个编号行，发 `emit`，`level=ask`，`key=plan:<tty>`。
- 探查脚本：`probes/phone-v1a-2/probe.py`（开会话、看屏幕、按键、解 OSC 7501）和 `trials.py`（重复试）。plans/ 里是每种情况的试法。
