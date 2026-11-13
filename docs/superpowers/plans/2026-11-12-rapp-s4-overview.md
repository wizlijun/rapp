# rapp S4（全景）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 顶栏「全景」按钮（⌃⌘O）把舞台换成一屏总览：第一层七格状态计数（活动、空闲、连接中、已断开、等你、设备在线、总流量），第二层设备墙（本机在前、其余按添加顺序，每台一栏、每个会话一块，块里写窗口数和流量/状态），第三层项目和资源；点一块一次进入那个会话并回到窗口模式；全景时没有会话在舞台上，按 S2 的规则降到 1 fps。

**Architecture:** 只动 Dart（规格 §3），hub、runner、RappSession 不改。新文件 `gui/lib/ui/overview_model.dart`：纯函数 `overviewCounts(...)`、`deviceColumns(...)`、窗口数和资源两句话，可单测。`MainState` 加 `overview` 布尔、`toggleOverview()`、"选了就收"时退出全景、`_applyFps` 在全景时把舞台当成空的、`showCorner`、`windowsOf`、`showProject`。新文件 `gui/lib/ui/overview.dart`：三层组件。`main_window.dart` 在全景时用 `Overview` 替换 `Stage`、加 ⌃⌘O、Esc 多一级；`top_bar.dart` 在面板按钮后加「全景」按钮；`projects_tab.dart` 能滚到指定项目；`traffic_label.dart` 抽出五格电平组件给块和计数格共用。

**Tech Stack:** Flutter 3.44（Dart，macOS 桌面）。Swift、Rust 不改。

**Spec:** `docs/superpowers/specs/2026-11-12-rapp-s4-overview-design.md`（全文，状态"已确认（按默认）"，§6 假设全部按默认）；上位 `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` §3.1（全景按钮、顶栏两种模式不变）、§3.3（三层、强调规则）、§7 S4 一行（只写窗口数）、§8 第 4 条（不做实时缩略图）、§9 最后一条（一次点击进入）；`docs/superpowers/specs/2026-11-12-rapp-design-language.md`（§0 三条检查、状态灯形状、计数 30px 等宽、电平五格、§6 尺寸、§9 词表；**只读，不改、不暂存这个文件**）；S2、S3、S5、S6 计划（`docs/superpowers/plans/2026-11-12-rapp-s2-embedded-stage.md`、`…-s3-lifecycle.md`、`…-s5-projects-favorites.md`、`…-s6-global-resources.md`；S4 建在 S2 的 `effectiveFps`/`_applyFps`、S3 的 `SessionRecord`/`recordLamp`/`needs`、S5 的 `projects`/`memberLamp`、S6 的 `ResourcesState`/`showPanel` 上）。

## 规格冲突与含糊处的裁定

- **C1（总流量的写法）**：规格 §2.2 写 `48 KB/s`；现有 `formatRate`（`gui/lib/embed/traffic_label.dart`，顶栏和面板底部都用它）写 `48.0 KB/s`。**裁定**：用 `formatRate`，三处一致；规格的写法当示意。S1 模式（`embeds` 假）和面板一样写 `—`。
- **C2（本机那一栏）**：规格 §2.3 "本机在最前"，但本机不是 A、不会有会话，设备面板里本机只有本机设置。**裁定**：本机一栏标题「本机」、在线灯（`Lamp.active`、「在线」）、不写路径，栏里写「没有打开的 app」，**没有**「打开 app」按钮（本机没有可开的 app）。「设备在线」的在线数和总数都**不含**本机（和面板底部 `在线设备` = `onlineDevices` 一致），总数 = `hub.hosts.length`。
- **C3（设备已从 hub 移除、会话还在）**：S3 的记录比连接活得久，它的设备可能不在 `hub.hosts` 里了。**裁定**：这类会话按设备 id 在所有主机栏之后各占一栏（标题 `deviceName(id)`，灯取 `probes[id]`，没有就当离线），保证计数里数到的每个会话墙上都有一块。
- **C4（"所有会话降到 1 fps"和分离窗口）**：规格 §2.1 说"按 S2 的规则……当作不在舞台上"。S2 的规则是：在舞台上或已分离 → 用选的帧率，否则 1 fps。**裁定**：全景时舞台上没有会话（当前会话也不算），已分离的会话照 S2 规则保持原帧率（它的窗口还在屏幕上）；回到窗口模式当前会话恢复原帧率。
- **C5（哪些操作退出全景）**：规格只写了"点一块：选中并退出"。**裁定**：所有"选了就收"的路径都退出全景——`select(key)`、`_open`/`_openEmbedded` 带 `select: true`、`openAll` 选中第一个；`step(±1)`（⌃⌘[ ⌃⌘]）留在全景里，只移动当前块的描边（看总览时换当前会话不该被拉回舞台）；打开面板、需要你、串流菜单都不退出。
- **C6（Esc）**：规格没写。**裁定**：Esc 依次关角落浮层 → 关面板 → 退出全景 → 退出全屏（全景插在全屏前面）。
- **C7（窄顶栏）**：规格"顶栏在两种模式下都不变"，现有测试要求 240px 宽放得下（正好 5×48，间距 0）。**裁定**：「全景」按钮只在顶栏宽 ≥ 300（也就是有间距时）出现，两种模式下一样；更窄时只能用 ⌃⌘O。
- **C8（资源格的数）**：「剪贴板 12 条，固定 3 条」里 12 是全部条目（含固定的）；固定为 0 时只写「剪贴板 12 条」；没有条目写 S6 的 `还没有剪贴板条目`；没有进行中的传输写 S6 的 `没有进行中的传输`。百分比和资源标签一样向下取整，`total` 为 0 时写 0%。

## S4 计划决定（规格没写死、我定的）

| # | 计划决定 | 理由 | 错了的代价 |
|---|---|---|---|
| K1 | 计划决定：计数只从 `_entries` 的灯算（嵌入模式 = 记录顺序的 `_entryOf`；S1 模式 = hub 会话 + `_pending`），`Lamp.waiting` 照数（S8 前恒 0）；纯函数不碰 `MainState` | 规格 §3 "算法放纯函数" | 无 |
| K2 | 计划决定：块里窗口数 = `MainState.windowsOf(key)` = `_stageRemote(r)?.tabs.tabs.length ?? 0`（顶栏窗口标签用的同一张表）；≥ 2 时写「N 个窗口」，否则不写；S1 模式恒 0 | 规格 §2.3；§8 第 4 条不做缩略图 | 无 |
| K3 | 计划决定：块的第二行：活动 → 五格电平 + `formatRate(bytesPerSecond ?? 0)`（S1 模式没有流量，写「活动」）；空闲 →「空闲」；连接中 →「连接中」；已断开 →「已断开：<原因>」（`SessionEntry.reason`，即 `disconnectWord`）；等你 →「等你」 | 规格 §2.3；词表 §9 | 无 |
| K4 | 计划决定：块描边 `rowBorder(lamp, t, selected: key == currentKey)`，当前块线宽 2、其余 1；底纹 `rowBackdrop(lamp, t)`；块高 56（≥ 48）；整块一个 `InkWell`，点 = `state.select(key)` | 规格 §2.3、§2.1；设计语言行状态 | 无 |
| K5 | 计划决定：栏宽固定 220、栏间距 12、外边距 12；栏标题：`deviceName`、路径（栏里第一个 `pathLabels[path]` 有值的会话的路径词，没有就不写）、灯和词（`probes[id]?.lamp ?? Lamp.connecting`，词 `probes[id]?.word ?? '连接中'`，和设备面板芯片一致）；离线时标题用 `t.muted`、词「离线」。1194×834 下 5 栏（本机 + 4 台）每栏 4 块都不滚 | 规格 §2.3 "至少 4 栏、每栏 4 块" | 改数字 |
| K6 | 计划决定：主机栏没有会话 → 「没有打开的 app」+ `RappButton.secondary`「打开 app」→ `state.showDevice(id)`（规格原文，离线设备也有：设备面板里能看它为什么离线、重试） | 规格 §2.3 | 无 |
| K7 | 计划决定：计数格固定宽 150、高 ≥ 88，排一行（放不下时横向滚动）；每格：状态灯（14px）、数字（`t.mono`、30px、w600）、名字（12px、`t.muted`）；总流量格用五格电平代替灯。为 0 时数字 `t.muted`；已断开、等你不为 0 时整格边框 `t.accent` + `rowBackdrop`（同块）。计数行的灯不动（`MediaQuery(disableAnimations: true)` 包住这一行，同面板图例）——动的只在块里 | 规格 §2.2；设计语言"只有等你闪、连接中转"，计数是汇总不是某个会话 | 改一个包裹 |
| K8 | 计划决定：「已断开」格（≠ 0 且 `hub != null`）点 = `state.showCorner(Corner.needs)`（打开，不切换）；「设备在线」格点 = `state.showPanel(PanelTab.devices)`；其余格不是按钮（不包 `InkWell`、Semantics 不标 button） | 规格 §2.2 | 无 |
| K9 | 计划决定：MainWindow 在 `state.overview` 时 `Positioned.fill(child: Overview(state: state))` 代替 `Stage`；Overview 不调 `stageSize`，所以 A 的窗口不被改尺寸；`Picture` 被拆掉时照旧在帧后 `release` 洞，背景网格补上；输入条草稿在 `RemoteSession.composer` 里，回来还在 | 规格 §2.1 "舞台换成总览、画面不显示" | 无 |
| K10 | 计划决定：`toggleOverview()` 进全景时 `_blur()`（键回到 rapp）；全景里 `focusPicture` 什么都不做 | 全景里没有画面可以有焦点 | 无 |
| K11 | 计划决定：顶栏「全景」按钮紧跟面板按钮：key `overview-button`、`Icons.grid_view`、提示「全景」、48×48；全景时按下样式 = `t.raiseBox(border: t.text)` + `Semantics(selected: true)`；`sessionMax` 在按钮出现时多减一个 48 和一个间距 | 主界面规格 §3.1；C7 | 改图标 |
| K12 | 计划决定：⌃⌘O = `SingleActivator(LogicalKeyboardKey.keyO, control: true, meta: mac, includeRepeats: false)` → `state.toggleOverview`（非 mac ⌃O，和 `prefixOf` 一致）；按住不来回切 | 规格 §2.1、§6 第 3 条；照 ⌃⌘D 的写法 | 无 |
| K13 | 计划决定：第三层固定高 88：左边项目格横向滚动（每格宽 200：项目名一行省略 + 每个成员一盏 `StatusLamp(state.memberLamp(m))`，同 S5 卡片标题），右边资源格固定宽 300 不随滚动；没有项目一格「还没有项目」 | 规格 §2.4 "最右一格资源" | 改数字 |
| K14 | 计划决定：项目格点 = `state.showProject(id)`：`panel = PanelTab.projects`、`focusProject = id`；`ProjectsTab` 改成 `StatefulWidget`，列表改 `SingleChildScrollView` + `Column`（项目不多，换掉懒加载才能滚到还没建的卡），每张卡外包 `KeyedSubtree(key: <GlobalKey>)`（卡自己的 `Key('project-<id>')` 不变）；有 `focusProject` 时帧后 `Scrollable.ensureVisible(..., alignment: 0)` 然后清掉 `focusProject`（不 notify）。「还没有项目」格点 = `showPanel(PanelTab.projects)`；资源格点 = `showPanel(PanelTab.resources)` | 规格 §2.4 "滚到这个项目" | 项目很多时一次建全部卡 |
| K15 | 计划决定：Overview 用 `ListenableBuilder(listenable: Listenable.merge([state, state.resources]))`；新 key：根 `overview`、计数格 `count-active/idle/connecting/disconnected/waiting/online/traffic`、墙 `wall`、栏 `column-local`/`column-<id>`、块 `block-<key>`、「打开 app」`open-app-<id>`、项目格 `ov-project-<id>`、`ov-no-projects`、资源格 `ov-resources` | 测试要找得到 | 无 |
| K16 | 计划决定：`LevelBars(bytesPerSecond)` 从 `TrafficLabel` 里抽出来（亮 `t.on`、暗 `t.line`，用 `levelBars`），`TrafficLabel` 改用它，外观不变 | 设计语言电平五格只画一种 | 无 |

## Global Constraints

**安全规则（每个实现者都受约束）：**
- Only start/stop processes you launched, by PID. Never `killall`/`pkill` (including `flutter_tester`) or address processes by name in AppleScript/System Events.
- Never touch /Applications/rapp.app, the running rapp-service, ~/Library/Logs/rapp, the user's real config dir, the keychain, or the system clipboard. Tests use fakes, temp dirs and ephemeral ports; never ports 47800 or 21116–21119.
- Do NOT launch any GUI/app window or send synthetic input. The user is actively using this Mac. (Task 5 live check is parked until the user agrees; no other task needs it.) `flutter build macos --debug` is a compile check only — never run the built app.
- `scripts/package-macos.sh` now signs with a keychain identity: run it only in Task 5, after the user agrees.
- Don't modify text in the user's documents; never touch the user's apps.
- No push, no merge, no branch switch (stay on `feat/main-window-s2-s6`), no subagents inside a task.

**Git 规则（用户会同时在这棵树里改文件）：**
- Stage files BY NAME only (`git add <paths>`). Never `git add -u`, `-A` or `.`.
- Never `git stash`, `checkout`, `restore`, `reset` anything. For a baseline, skip it or use `git worktree add` under the scratchpad.
- Hands-off user files — never add, commit, edit, move, restore or delete:
  - README.md (uncommitted edit)
  - docs/superpowers/specs/2026-11-12-rapp-design-language.md (uncommitted edit; read-only reference — its §0 three checks apply to UI work)
  - docs/archives/
  - docs/superpowers/specs/2026-11-12-rapp-relay-security-requirements.md
  - docs/superpowers/specs/2026-11-12-rapp-requirements-feedback.md
  - docs/superpowers/specs/2026-11-12-rapp-conversation-design.md
  - docs/superpowers/specs/2026-11-12-rapp-domain-candidates.md
  - `Claude outputs/` (if it appears)
- Commit message ends with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

**数据规则：**
- Never log passwords, tokens, secrets, relay keys, typed text, pasted text or clipboard content. Test failure messages don't print clipboard bytes either. 全景的资源格只写条数和传输的文件名、百分比，**不**显示剪贴板条目标题或内容。
- Dart tests use `FakeSessionPort` / `FakeTransport`; no Dart test reaches the system clipboard. （S4 不改 Swift；如果哪个任务意外碰到 Swift 测试：只用命名的 `rapp.test.<uuid>` 剪贴板、tearDown 里 `releaseGlobally()`，下载用临时目录。）
- Security posture (user's decision): the self-hosted relay is the only gate; do not add crypto layers, approval steps or confirm dialogs.

**S4 另加：**
- 实机检查（Task 5）只在用户明确同意把这台 Mac 让出来一段时间之后做；那时点击一律先 `topatp X Y <pid>`（scratchpad `s2live/topatp`，按 PID 判断）确认点到的是自己的 GUI；发键前确认最前的 app 是自己的 GUI（按 PID）；截图只截自己的窗口（`screencapture -l <id>`）。帧率只看自己起的 host 的日志。
- 全景不发任何新的平台消息：只复用现有 `set_stream`（帧率）和 `picture_focus`（失焦）。

**测试与命令：**
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`（起点：S6 结束时 567 过，`analyze` 干净）。长输出重定向到 scratchpad 里的文件再看末尾。
- runner 编译检查（Task 3 之后跑一次，确认没碰坏）：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（只编译，不运行）。
- Swift、Rust 不改，只在 Task 5 全量验证：仓库根 `swift test`（S6 结束时 237 过）、`./scripts/check.sh`（`.build-logs/check.log` 末行 `EXIT=0`）；`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`（207 过、0 警告；不跑 `cargo fmt`）。
- 每个 Task 一个提交；**只** `git add <路径>`；不 push、不 merge、不换分支。

**代码规则：**
- 组件只用 `RappTokens`（颜色 `bg/line/text/muted/on/accent/accentInk/tint`、`r`、`mono`/`monoFallback`、`panelBox`/`raiseBox`）；可点控件高度 ≥ 48px（设计语言 §6），块 ≥ 48（主界面规格 §9）。
- 词只用设计语言 §9 和规格 §2 定的：全景、活动、空闲、连接中、已断开、等你、设备在线、总流量、在线、离线、本机、局域网、直连、中继、没有打开的 app、打开 app、N 个窗口、还没有项目、剪贴板 N 条、固定 M 条、下载、上传、N 个传输；S6 的空状态两句。
- 强调色只用于"已断开"和"等你"（计数格、块）；当前块描边用 `t.text`，不用强调色。
- 浮层只盖不挤（面板、需要你、串流菜单盖在总览上面，总览不让位）；选了就收（C5）；不靠悬停和右键。
- 设计语言 §0 三条检查，每个 UI 任务交付前对一遍：① 全景只换舞台那块，顶栏和浮层不变；② 不弹窗、不抢焦点（进全景只是失焦，不移焦点到别处）；③ 不留要人去清的东西（全景里没有新的待办或提示）。

## Review Focus

1. **帧率**：全景时每个已开始、可达、未分离的会话都收到 1 fps，分离的保持原帧率，回窗口模式当前会话恢复；不重复发同一个值。测试：Task 2 `overview drops the current session to 1 fps`、`a detached session keeps its rate in overview`、`leaving overview restores the current rate`。
2. **选了就收 vs 步进**：`select`、带 `select` 的打开、`openAll` 退出全景；`step` 不退出；面板/需要你/串流菜单不退出。测试：Task 2 `select leaves overview`、`opening with select leaves overview`、`openAll leaves overview`、`step stays in overview`、`panels and corners keep overview`。
3. **每个会话在墙上都有一块**（C3）：设备已不在 `hub.hosts` 的会话也出现，墙上块数 = 计数之和。测试：Task 1 `sessions on an unknown device get their own column`、`every entry lands in exactly one column`。
4. **顶栏两种模式一样、窄宽度不溢出**（C7）：240/360 的现有测试照过；按钮只在 ≥ 300 时出现；按下样式只在全景时。测试：Task 2 `top bar fits 240/360px with long names`（现有，加全景状态再跑一遍）、`overview button only from 300px`、`overview button shows pressed in overview`。
5. **强调规则**：已断开/等你 ≠ 0 才整格强调色 + 底纹；其余 0 时数字 `t.muted`；强调色不出现在别的格和当前块上。测试：Task 3 `zero counts are muted`、`a nonzero disconnected count is accent with backdrop`、`the current block is outlined in text colour, not accent`。

---

### Task 1: `overview_model.dart`：计数、设备栏、窗口数、资源两句话（纯函数）

**Files:**
- Create: `gui/lib/ui/overview_model.dart`
- Create: `gui/test/ui/overview_model_test.dart`

**Interfaces:**
- Consumes: `SessionEntry`（`gui/lib/ui/session_model.dart`：`id`、`key`、`lamp`、`path`、`bytesPerSecond`、`reason`）、`pathLabels`；`Lamp`（`gui/lib/ui/lamp.dart`）；`HubHost(id, name)`（`gui/lib/hub_client.dart`）；`DeviceProbe(lamp, word, …)`（`gui/lib/ui/main_state.dart`）；`ClipEntry`（`pinned`）、`TransferRow`（`down`、`name`、`done`、`total`）（`gui/lib/ui/resources_state.dart`）。
- Produces（`overview_model.dart`，不 import Flutter widgets）：
  - `typedef OverviewCounts = ({int active, int idle, int connecting, int disconnected, int waiting, int online, int devices});`
  - `OverviewCounts overviewCounts(List<SessionEntry> entries, {required int online, required int devices})`——按 `lamp` 数（K1）；`Lamp.offline`、`Lamp.notOpened` 不计。
  - `class DeviceColumn { const DeviceColumn({required this.id, required this.name, required this.lamp, required this.word, required this.path, required this.entries}); final String? id; /* null = 本机 */ final String name; final Lamp lamp; final String word; final String path; /* 路径词，没有为 '' */ final List<SessionEntry> entries; bool get offline => lamp == Lamp.offline; }`
  - `List<DeviceColumn> deviceColumns({required List<HubHost> hosts, required Map<String, DeviceProbe> probes, required List<SessionEntry> entries, required String Function(String id) name})`——顺序：本机（`id: null`、`name: '本机'`、`Lamp.active`、`'在线'`、`path: ''`、`entries: []`，C2）→ `hosts` 按顺序（K5 的灯和词）→ `entries` 里不在 `hosts` 的设备 id，按第一次出现的顺序（灯 `probes[id]?.lamp ?? Lamp.offline`，词 `probes[id]?.word ?? '离线'`，C3）。每栏的 `entries` 保持传入顺序；`path` = 栏里第一个 `pathLabels[e.path] != null` 的词。
  - `String? windowsWord(int n)` → `n >= 2 ? '$n 个窗口' : null`（K2）。
  - `String clipSummary(List<ClipEntry> clips)`、`String transferSummary(List<TransferRow> running)`（C8）。

- [ ] **Step 1: 写失败的测试**（直接构造 `SessionEntry`、`HubHost`、`DeviceProbe`；`ClipEntry`、`TransferRow` 照 `resources_state_test.dart` 的构造写法）：
  - `counts each lamp`：灯 [active, active, idle, connecting, disconnected] → `active 2, idle 1, connecting 1, disconnected 1, waiting 0`；`online`/`devices` 原样带出。
  - `waiting is counted when present`：一个 `Lamp.waiting` → `waiting 1`。
  - `columns: local first, then hosts in add order, offline hosts too`：hosts [m1, m2, m3]，m2 的 probe 是 `Lamp.offline` → 栏 id `[null, m1, m2, m3]`，m2 `offline == true`、`word == '离线'`；没有 probe 的 m3 是 `Lamp.connecting`、`连接中`；本机栏 `name == '本机'`、`entries` 空。
  - `sessions on an unknown device get their own column`（Review Focus 3）：会话在 `gone` 上（不在 hosts、没有 probe）→ 最后一栏 id `gone`、`name` 来自 `name('gone')`、`offline == true`。
  - `every entry lands in exactly one column`（Review Focus 3）：三台设备、六个会话（含一个未知设备）→ 各栏 `entries` 合起来正好是传入的六个、每栏内顺序不变。
  - `column path comes from its sessions and is empty without them`：一栏两个会话 path `['', 'relay']` → `中继`；没会话的栏 `''`。
  - `windows word only from two`：0、1 → null；2 → `2 个窗口`。
  - `clip summary`：空 → `还没有剪贴板条目`；3 条 0 固定 → `剪贴板 3 条`；12 条 3 固定 → `剪贴板 12 条，固定 3 条`。
  - `transfer summary`：空 → `没有进行中的传输`；一个下载 `app.log` 429/1000 → `下载 app.log 42%`；一个上传 total 0 → `上传 <名字> 0%`；三个 → `3 个传输`。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/overview_model_test.dart` → 编译失败（文件不存在）。
- [ ] **Step 3: 实现** `overview_model.dart`。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿（567 + 新增）。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/overview_model.dart gui/test/ui/overview_model_test.dart`，`feat(gui): overview counts and device columns`

---

### Task 2: `MainState` 全景切换、退出规则、帧率、失焦；⌃⌘O、Esc、顶栏按钮

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Modify: `gui/lib/ui/main_window.dart`（只加快捷键和 Esc；换舞台在 Task 3）
- Modify: `gui/lib/ui/top_bar.dart`
- Modify: `gui/test/ui/main_state_test.dart`、`gui/test/ui/main_window_test.dart`、`gui/test/ui/top_bar_test.dart`

**Interfaces:**
- Consumes: `_applyFps`、`effectiveFps(c, onStage:, detached:)`（`gui/lib/embed/stream_choice.dart`）、`_sentFps`、`currentRecord`、`_blur()`、`focusPicture`、`select`、`step`、`_open`/`_openEmbedded`（`if (select) { currentKey = key; panel = null; }` 三处）、`openAll`（`currentKey = plan.first; panel = null;`）、`toggleCorner`/`closeCorner`、`Corner`、`_stageRemote(r)`、`_records`；`TopBar` 的 `_icon(...)`、`gap`、`sessionMax`；`_MainWindowState.build` 的 `bindings`、`_esc`。
- Produces（`MainState`）：
  - `bool overview = false;`
  - `void toggleOverview()`：取反；进全景时 `_blur()`（K10）；`notifyListeners()`（`_applyFps` 在里面跑）。
  - `select(key)`、`_open`/`_openEmbedded` 的 `if (select)` 分支、`openAll` 选中第一个时：同时 `overview = false`（C5）。`step` 不动 `overview`。
  - `_applyFps`：`final onStage = overview ? null : currentRecord;`（C4），其余不变。
  - `focusPicture`：`if (overview) return;` 放在最前（K10）。
  - `void showCorner(Corner c)`：`if (corner == c) return; corner = c; notifyListeners();`（K8）。
  - `int windowsOf(String key)`：`final r = _records[key]; final rs = r == null ? null : _stageRemote(r); return rs?.tabs.tabs.length ?? 0;`（K2；`_stageRemote` 按实际签名调用）。
- Produces（`main_window.dart`）：`bindings` 加 K12 那一条 → `state.toggleOverview`；`_esc`：角落 → 面板 → `if (state.overview) { state.toggleOverview(); return; }` → 全屏（C6）。
- Produces（`top_bar.dart`）：`final showOverview = box.maxWidth >= 300;`；面板按钮后 `if (showOverview)` 一个 48×48 的「全景」按钮（K11，key `overview-button`，`onPressed: state.toggleOverview`，全景时 `raiseBox(border: t.text)` + `Semantics(selected: true)`）；`sessionMax = (box.maxWidth - (showOverview ? 6 : 5) * 48 - (showOverview ? 8 : 7) * gap).clamp(0.0, 260.0)`。

- [ ] **Step 1: 写失败的测试**
  - `main_state_test.dart`（'embedded sessions' 组的 env 搭法：FakeAsync、FakeTransport、FakeSessionPort，开 `111` 和 `aa` 得到 sid 1、2，名字 Calculator/Notes；用现有 `sets(port, sid)` 看 `set_stream`）：
    - `overview drops the current session to 1 fps`（Review Focus 1）：两个会话都开始、当前是 2、选的帧率 30 → `toggleOverview()` → `sets(port, 2).last` 的 fps 是 1；sid 1 本来就是 1，不再多发。
    - `a detached session keeps its rate in overview`（Review Focus 1）：把 2 分离（照现有分离测试发 `DetachedEvent`）→ 进全景 → sid 2 没有新的 fps 1。
    - `leaving overview restores the current rate`（Review Focus 1）：进再出 → sid 2 最后一条回到 30；同一个值不重复发。
    - `entering overview blurs the picture`：`focusPicture(2)` → `toggleOverview()` → `pictureFocused == null`、port 收到 `picture_focus` null；`focusPicture(2)` 在全景里不改 `pictureFocused`。
    - `select leaves overview`、`opening with select leaves overview`（`openOrSwitch(...)`：已开的会话走"已切到"分支，和新开的各一次）、`openAll leaves overview`（'projects' 组的搭法）、`step stays in overview`（Review Focus 2：`step(1)` 后 `overview` 还是真、`currentKey` 变了）。
    - `panels and corners keep overview`（Review Focus 2）：全景里 `togglePanel()`、`showPanel(PanelTab.devices)`、`toggleCorner(Corner.needs)`、`showDevice(id)` 之后 `overview` 仍为真。
    - `showCorner opens and stays`：连调两次 `showCorner(Corner.needs)` → 还是 `Corner.needs`。
    - `windowsOf counts the session's tabs`：照现有窗口标签测试发两个装饰窗口 → `windowsOf(key) == 2`；不认识的 key → 0。
  - `main_window_test.dart`：`ctrl+cmd+O toggles overview`（按住 controlLeft + metaLeft 发 keyO，和现有 ⌃⌘D 测试同写法；再按一次关；按住重复不来回切）；`esc leaves overview after corners and panel`（开面板 + 全景：第一次 Esc 关面板、第二次退全景、全屏不变）。
  - `top_bar_test.dart`：`overview button only from 300px`（240 → 没有 `overview-button`；360 → 有）；`overview button toggles and shows pressed in overview`（点它 → `state.overview` 真，按钮的 `Semantics` `isSelected`；再点 → 假）；`top bar fits 240/360px with long names`、`…two-digit needs count`（现有两条，每条加一遍 `overview = true` 再 pump，不溢出）（Review Focus 4）。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/main_state_test.dart test/ui/main_window_test.dart test/ui/top_bar_test.dart` → 编译失败或断言失败。
- [ ] **Step 3: 实现**；交付前对一遍设计语言 §0 三条。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/main_state.dart gui/lib/ui/main_window.dart gui/lib/ui/top_bar.dart gui/test/ui/main_state_test.dart gui/test/ui/main_window_test.dart gui/test/ui/top_bar_test.dart`，`feat(gui): overview mode toggle, exit rules and 1 fps off stage`

---

### Task 3: 状态计数行、设备墙；MainWindow 换舞台

**Files:**
- Create: `gui/lib/ui/overview.dart`
- Create: `gui/test/ui/overview_test.dart`
- Modify: `gui/lib/ui/main_window.dart`（`Stage` ↔ `Overview`）
- Modify: `gui/lib/embed/traffic_label.dart`（抽出 `LevelBars`，K16）
- Modify: `gui/test/ui/main_window_test.dart`

**Interfaces:**
- Consumes: Task 1 全部；Task 2 的 `overview`、`showCorner`、`windowsOf`；`MainState` 现在没有公开的会话列表：Task 3 加 `List<SessionEntry> get entries => List.unmodifiable(_entries);`、`currentKey`、`hub`、`probes`、`deviceName`、`onlineDevices`、`totalBytesPerSecond`、`embeds`、`select`、`showDevice`、`showPanel`；`StatusLamp(kind, {size})`、`rowBorder`、`rowBackdrop`；`formatRate`、`levelBars`；`RappButton.secondary`（`gui/lib/ui/controls.dart`）；`RappTokens`。
- Produces：
  - `traffic_label.dart`：`class LevelBars extends StatelessWidget { const LevelBars(this.bytesPerSecond, {super.key}); final int bytesPerSecond; }`；`TrafficLabel` 改用它，现有 traffic label 测试不改照过。
  - `overview.dart`：`class Overview extends StatelessWidget { const Overview({super.key, required this.state}); final MainState state; }`（根 key `overview`）。布局：`Column`：计数行（K7）→ `Expanded` 设备墙（K5，key `wall`：横向 `ListView`，每栏标题 + `Expanded` 纵向 `ListView` 的块）→ 第三层占位（Task 4 填；这一步先留一个高 88 的空 `SizedBox`，免得 Task 4 再改布局）。计数格 `_CountCell`（K7、K8）、栏 `_Column`、块 `_Block`（K2–K4）都是私有组件。
  - `main_window.dart`：`Positioned.fill(child: state.overview ? Overview(state: state) : Stage(state: state))`（K9）。

- [ ] **Step 1: 写失败的测试**（`overview_test.dart`，搭法照 `projects_tab_test.dart`：`MainState` + `FakeSessionPort` + FakeTransport hub + 固定 `clock`，`helpers.dart` 的 `wrap`；给 hub 加主机照 `devices_tab_test.dart` 现有写法；尺寸 `tester.view.physicalSize = const Size(1194, 834)`、`devicePixelRatio = 1`，tearDown 复位）：
  - `two sessions, one disconnected: counts and blocks`（规格 §5 第 1 条）：开两个、断开一个 → `count-active` 里数字 `1`、`count-disconnected` 里 `1`；墙上两块，各自的状态文字（`48.0 KB/s` 之类的速率、`已断开：<原因>`）。
  - `zero counts are muted`（Review Focus 5）：`count-idle` 的数字 `Text.style.color == t.muted`。
  - `a nonzero disconnected count is accent with backdrop`（Review Focus 5）：`count-disconnected` 的 `DecoratedBox`/`Container` 边框颜色 `t.accent`、有 `rowBackdrop` 的装饰；为 0 时边框是 `t.line`。
  - `the current block is outlined in text colour, not accent`（Review Focus 5）：当前块边框 `t.text`、宽 2；另一块 `t.line`、宽 1。
  - `one click on a block enters it`（规格 §5 第 2 条）：全景里点 `block-<另一个 key>` → `state.overview == false`、`currentKey` 是它；只 tap 一次。
  - `windows count shows from two`：当前会话两个装饰窗口 → 块里有 `2 个窗口`；一个时没有 `个窗口` 字样。
  - `columns follow the device panel order; offline is grey`：hosts m1、m2（m2 离线）→ `column-local` 在最左、然后 `column-m1`、`column-m2`（比较 `getTopLeft().dx`）；m2 标题颜色 `t.muted`、栏里有 `离线`。
  - `an empty host column offers 打开 app`：点 `open-app-m1` → `state.panel == PanelTab.devices`、`state.deviceTab == 'm1'`；`column-local` 里有 `没有打开的 app`、没有 `打开 app` 按钮。
  - `count taps`：点 `count-disconnected`（≠ 0）→ `state.corner == Corner.needs`；点 `count-online` → `state.panel == PanelTab.devices`；`count-active` 没有 `InkWell` 祖先。
  - `device online shows online/total without 本机`：两台主机一台在线 → `count-online` 里 `1/2`。
  - `traffic cell uses formatRate and — without embedding`（C1）：嵌入 → `formatRate(state.totalBytesPerSecond)` 的文字；S1 模式（`port: null`）→ `—`。
  - `four columns of four fit without scrolling at 1194x834`：本机 + 4 台主机各 4 个会话 → `wall` 里横向 `Scrollable` 的 `position.maxScrollExtent == 0`，每栏纵向的也是 0。
  - `blocks and buttons are at least 48 tall`：每个 `block-*`、`open-app-*`、可点的计数格 `getSize().height >= 48`。
  - `count lamps are still`：计数行里的 `StatusLamp` 在 `MediaQuery.disableAnimations` 为真的子树里（K7）。
  - `main_window_test.dart`：`overview replaces the stage and back`：`toggleOverview()` → 有 `Overview`、没有 `Stage`；再切 → 反过来；`a panel opens over the overview`：全景里开面板 → `scrim` 和 `SidePanel` 出现、`Overview` 还在。`composer draft survives a trip through overview`：照 `stage_test.dart` 现有输入条测试的搭法写一段草稿 → 进出全景 → 草稿还在。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/overview_test.dart test/ui/main_window_test.dart` → 编译失败。
- [ ] **Step 3: 实现**；交付前对一遍设计语言 §0 三条（Code rules）。然后跑一次 runner 编译检查（只编译）。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/overview.dart gui/test/ui/overview_test.dart gui/lib/ui/main_window.dart gui/lib/embed/traffic_label.dart gui/test/ui/main_window_test.dart gui/lib/ui/main_state.dart`（最后一个是为了 `entries`），`feat(gui): overview counts row and device wall`

---

### Task 4: 第三层：项目和资源；跳到项目

**Files:**
- Modify: `gui/lib/ui/overview.dart`（把 Task 3 的 88 高占位换成第三层）
- Modify: `gui/lib/ui/main_state.dart`（`focusProject`、`showProject`）
- Modify: `gui/lib/ui/projects_tab.dart`（K14）
- Modify: `gui/test/ui/overview_test.dart`、`gui/test/ui/projects_tab_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `clipSummary`、`transferSummary`；`state.projects`（`Project(id, name, members)`）、`state.memberLamp(Member)`、`state.resources.clips`、`state.resources.running`、`showPanel`、`PanelTab.projects`/`PanelTab.resources`；`ProjectsTab`、`_ProjectCard(key: Key('project-<id>'))`。
- Produces：
  - `MainState`：`String? focusProject;`、`void showProject(String id) { panel = PanelTab.projects; focusProject = id; notifyListeners(); }`。
  - `projects_tab.dart`：`ProjectsTab` 变 `StatefulWidget`（构造不变 `ProjectsTab({super.key, required this.state})`），`ListView` 换 `SingleChildScrollView(padding: EdgeInsets.all(10), child: Column(...))`，每张卡 `KeyedSubtree(key: _cards.putIfAbsent(p.id, GlobalKey.new), child: _ProjectCard(...))`；`build` 里 `state.focusProject` 非空时 `addPostFrameCallback`：`ensureVisible(alignment: 0)` 后 `state.focusProject = null`（K14）。
  - `overview.dart` 第三层（K13）：项目格 `ov-project-<id>`（名字 + 成员灯，点 → `showProject(id)`）；没有项目 `ov-no-projects`「还没有项目」（点 → `showPanel(PanelTab.projects)`）；资源格 `ov-resources` 两行 `clipSummary(...)`、`transferSummary(...)`（点 → `showPanel(PanelTab.resources)`），固定在最右。

- [ ] **Step 1: 写失败的测试**
  - `overview_test.dart`：
    - `a project cell shows its name and one lamp per member`：一个项目三个成员（一个开着）→ `ov-project-<id>` 里有名字、三个 `StatusLamp`，开着的那盏是它的会话灯。
    - `tapping a project opens the projects tab on it`：12 个项目，点最后一个的格 → `panel == PanelTab.projects`；pump 完 `find.byKey(Key('project-<最后一个 id>'))` 的顶在面板可见区域里（`getTopLeft().dy` 在 56 和 834 之间），`state.focusProject == null`。
    - `no projects: one cell that opens the projects tab`：点 `ov-no-projects` → `panel == PanelTab.projects`。
    - `the resources cell sums clips and transfers and opens the resources tab`：照 S6 测试发 `clipboard` 事件三条、固定一条（`fetch_clip` 回 `{copy: 1}`）、一个 `transfer running` 42/100 → `剪贴板 3 条，固定 1 条`、`下载 <名字> 42%`；点 `ov-resources` → `panel == PanelTab.resources`。
    - `the resources cell shows no clipboard titles`（数据规则）：条目标题 `s4-secret-title` 不出现在 `ov-resources` 子树里。
    - `the resources cell stays at the right edge`：项目格多到要横向滚动 → `ov-resources` 的右边 = 总览右边减外边距；滚项目行它不动。
    - `third-row cells are at least 48 tall`。
  - `projects_tab_test.dart`：`focusProject scrolls the card into view and clears`（直接设 `state.showProject(id)`，不经总览）；现有测试照过（卡的 `Key('project-<id>')` 没变）。
  - `main_state_test.dart`：`showProject opens the projects tab and keeps overview`。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/overview_test.dart test/ui/projects_tab_test.dart test/ui/main_state_test.dart`。
- [ ] **Step 3: 实现**；交付前对一遍设计语言 §0 三条。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/overview.dart gui/lib/ui/main_state.dart gui/lib/ui/projects_tab.dart gui/test/ui/overview_test.dart gui/test/ui/projects_tab_test.dart gui/test/ui/main_state_test.dart`，`feat(gui): overview projects and resources row`

---

### Task 5: 实机检查、打包、记录

**前提：只在用户明确同意后做（用户同意把这台 Mac 让出来一段时间，并同意打包签名）。** 用户中途在用（焦点被抢、GUI 被关）就停下，把没做的条目记"待实机"，不反复把自己的窗口提到前面。全程守 Global Constraints 的安全规则。

**Files:**
- Modify: `tasks/todo.md`（S4 一行改成完成，下面按规格 §5 每条一行，写验证方式和结果）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-s4-overview-design.md` 状态行后加"S4 已实现（计划 `docs/superpowers/plans/2026-11-12-rapp-s4-overview.md`）"
- Modify: `tasks/lessons.md`（只在这次真学到东西时加）

- [ ] **Step 1: 全量验证** — `flutter analyze`、`flutter test`；`swift test`、`./scripts/check.sh` 末行 `EXIT=0`；`cargo test --workspace`、`cargo clippy --workspace --all-targets`（Swift、Rust 没改，应和 S6 结束时一样：237 / 207 过、0 警告）。
- [ ] **Step 2: 搭环境（只用自己起的进程，每个都记 PID 文件）** — 复用 scratchpad `s2live/` 的布局（`A`、`B`、`bin`，临时端口，不用 47800、21116–21119），起**两台**自己的 host（不同临时端口、不同名字，日志各自重定向到 `s2live/A*/host.log`），换上 `flutter build macos --release`（`FLUTTER_XCODE_ARCHS=arm64`）的 GUI，`RAPP_HOME` 指向 scratchpad 里的配置目录、`RAPP_DOWNLOADS` 指向 scratchpad 里的目录，写 `gui.pid`。点击一律先 `s2live/topatp X Y $(cat gui.pid)`，返回的 PID 等于 `gui.pid` 才点；发键前确认最前 app 的 unix id 等于 `gui.pid`；截图只截自己的窗口。目标 app 只用自己起的：一个在 scratchpad 里自己编的、不停在动的小窗口（例如每 100 ms 改一次标签的 Swift 小程序，按 PID 起停；`s2live/` 里已有能用的就复用），保证 host 一直有帧可发。
- [ ] **Step 3: 逐条对规格 §5 检查**（每条截一张自己窗口的图存 `s2live/s4-*.png`）：
  1. 开两个会话（两台 host 各一个）→ 按 PID 停掉其中一个会话的 app 或断它的连接（不动另一台）→ 进全景：活动 1、已断开 1（整格强调色 + 底纹），墙上两块状态各自对。
  2. 全景里点另一块 → 一次点击回到窗口模式、当前会话是它。
  3. 按 PID 停掉一台自己的 host → 30 秒内它那一栏标题变灰写「离线」、「设备在线」减 1。
  4. 两种模式下顶栏一样（两张截图对比，只有「全景」按钮的按下样式不同）；全景里开面板、开需要你、开串流菜单都正常，串流菜单作用于当前会话。
  5. 帧率：窗口模式下看当前会话那台 host 的 `host.log` 最近几行 `[stats] … N fps`（`Sources/rapp-host/Server.swift` 打的那行），N 和选的帧率相近；进全景等 3 秒，后续 `[stats]` 行 fps ≤ 1；回窗口模式恢复。
  6. 灰度截图：`screencapture -l <自己窗口的 id> s2live/s4-gray-src.png`，`sips --matchTo '/System/Library/ColorSync/Profiles/Generic Gray Gamma 2.2 Profile.icc' s2live/s4-gray-src.png --out s2live/s4-gray.png`；看灰度图里计数行和块的七种状态（活动、空闲、连接中、已断开、等你、离线、未打开——等你、未打开在墙上没有就看面板图例）仍能凭形状分清。
- [ ] **Step 4: 收尾** — 按 PID 文件逐个 `kill` 自己起的 GUI、小程序、hub、两台 host/service、relay；`ps -p` 确认都没了。
- [ ] **Step 5: 打包（用户同意后）** — `scripts/package-macos.sh`（它用钥匙串里的身份签名）；不替换 `/Applications/rapp.app`，不重启已装的 rapp-service。
- [ ] **Step 6: Commit** — `git add tasks/todo.md docs/superpowers/specs/2026-11-12-rapp-s4-overview-design.md`（改了 lessons 再加 `tasks/lessons.md`），`docs: S4 done — live check, todo, spec status`

---

## Self-review

- **规格覆盖**：§2.1 按钮切换 + 按下样式（Task 2 K11）、⌃⌘O（K12）、舞台换总览 + 画面不显示（Task 3 K9）、1 fps 和恢复（Task 2 C4）、点一块一次进入（Task 3 K4、Task 2 C5）、面板/需要你/串流菜单照常（Task 2、Task 3 测试）。§2.2 七格、灯/数字/名字、在线数/总数、总流量（C1、C2、K7）、强调和变暗（K7，Review Focus 5）、等你恒 0（K1）、两格可点（K8）。§2.3 栏顺序、离线也占一栏（Task 1、C2、C3）、栏标题三样（K5）、块四样 + 当前描边（K2–K4）、空栏「打开 app」（K6）、滚动和 1194×834 下 4×4 不滚（K5，Task 3 测试）、块 ≥ 48（K4）。§2.4 项目格 + 滚到项目（K13、K14）、没有项目（K14）、资源格两句（C8）。§3 只动 Dart、`overview` 布尔、`overview.dart`、`overviewCounts` 纯函数、帧率复用 S2、hub/runner 不变（Architecture）。§4 三块拆分 → Task 1–2、3、4。§5 六条 → Task 5 第 3 步，只用自己的 host/app（按 PID）、只截自己的窗口。§6 五条假设：排在 S5、S6 后（第三层用真数据）、不做缩略图（K2）、⌃⌘O（K12）、全部 1 fps（C4）、离线也占一栏（Task 1）。
- **占位扫描**：没有 TBD。"照现有写法"的地方都指了现有测试文件（`projects_tab_test`、`devices_tab_test`、`resources_state_test`、`stage_test`、⌃⌘D 测试、'embedded sessions' 组的 `sets`）。Task 3 第三层的空 `SizedBox` 是有意的布局占位，Task 4 换掉。
- **类型一致**：`OverviewCounts`、`DeviceColumn`、`deviceColumns`、`windowsWord`、`clipSummary`、`transferSummary` 在 Task 1 定义，Task 3、4 用；`overview`、`toggleOverview`、`showCorner`、`windowsOf` 在 Task 2 定义，Task 3 用；`focusProject`、`showProject` 在 Task 4 定义并用；`LevelBars` 在 Task 3 定义；key 名统一见 K15。
- **Review Focus**：五条的测试名都写在 Task 2（1、2、4）、Task 1（3）、Task 3（5）的 Step 1 里。
- **比例**：只给签名、规则、测试名和断言、精确文字；没有大段实现代码。
