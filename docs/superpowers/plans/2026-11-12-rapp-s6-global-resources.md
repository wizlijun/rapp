# rapp S6（全局资源）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 所有会话的剪贴板条目进同一张全局列表（最新在上，最多 100 条未固定），所有会话的文件传输进同一张传输表（进行中 + 本次启动传过的 50 条）；左侧面板第四个标签「资源」把两者放在一起，条目可以「固定」（先取到本机副本，会话结束也还在）、「复制到本机」，传输可以「取消」、「显示位置」；流菜单第 5 组改读全局列表里当前会话的最新两条，「全部剪贴板」打开资源标签。

**Architecture:** Swift + Dart，hub 不改。RappSession（纯库，可测）：`TransferQueue` 给每个任务编号、报结构化进度、按编号取消、下载目录可注入；`ClipHistory` 上限可配（嵌入会话 50）、取副本有完成回调；新的 `ClipCopies`（runner 进程级的本机副本表，会话结束后还在）；`Channel.swift` 加命令和事件。runner `SessionPlugin` 只做胶水。Dart：`session_port.dart` 解析新事件、发新命令；新文件 `gui/lib/ui/resources_state.dart`（纯逻辑：全局条目、传输、固定状态、可用性）；`MainState` 把事件喂给它、在会话断开/结束/重连时处理它；新文件 `gui/lib/ui/resources_tab.dart`（资源标签）；`side_panel.dart` 加第四个标签；`stream_menu.dart` 第 5 组改读全局列表。

**Tech Stack:** Flutter 3.44（Dart，macOS 桌面）；Swift（RappSession 库 + `gui/macos/Runner`）。Rust（rapp-hub）不改。

**Spec:** `docs/superpowers/specs/2026-11-12-rapp-s6-global-resources-design.md`（全文，状态"已确认（按默认）"，§6 假设全部按默认）；上位 `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` §2（资源对象）、§3.4（流菜单第 5 组）、§3.7（面板标签、资源标签 720）、§5（只盖不挤、选了就收、不靠悬停）、§7 S6 一行；`docs/superpowers/specs/2026-11-11-rapp-clipboard-composer-design.md` §4.4、§4.5（条目标题、点击取回、重试 1/2/4 秒、`unknown clip`、历史和续传只在一个会话里有效）；`docs/superpowers/specs/2026-11-12-rapp-design-language.md`（§0 三条检查、§3 种类标签边框、传输中 = 连接中灯 + 进度条、§6 尺寸、§9 词表；**只读，不改、不暂存这个文件**）；S2、S3、S5 计划（`docs/superpowers/plans/2026-11-12-rapp-s2-embedded-stage.md`、`…-s3-lifecycle.md`、`…-s5-projects-favorites.md`；S6 建在 S3 的 `SessionRecord`/`lastSid`/`_endRecord`、S5 的面板第三个标签上）。

## 规格冲突

- **C1（列表放哪）**：主窗口规格 §7 的 S6 一行写"上移到 hub"；S6 规格 §6 第 1 条写列表在 GUI 进程、hub 不改。**按 S6 规格**：列表只在 GUI（Dart 的 `ResourcesState` + runner 的 `ClipCopies`），hub 不动。
- **C2（`transfer` 事件重名）**：S6 规格 §3 的新事件 `transfer {sid,id,dir,name,done,total,state}` 和现有的 `transfer {sid,status}`（输入条上传提示）同名。**裁定**：旧事件改名 `transfer_status`（Swift `SessionEvent.transferStatus`，Dart `TransferStatusEvent`），新事件用 `transfer`，另带 `path`（下载到磁盘完成时 B 上的路径）。
- **C3（`cancel_transfer` 语义）**：现有 `cancel_transfer {sid}` 取消这个会话的全部传输（输入条用）；规格要 `cancel_transfer {sid, id}` 取消一个。**裁定**：`id` 可选；没有 = 全部（输入条不变），有 = 只取消这一个（进行中或排队中），`.rapp-part` 保留。
- **C4（重连后条目"重新可用"）**：规格 §2.5 说断开的条目重连后可用"（剪贴板编号在 A 上仍有效时）"；但 A 的 `ClipStore` 每个会话一份、编号从 1 重新开始（`Sources/rapp-host/Server.swift` `startClipboard`），新会话里同一个编号可能是另一条。**裁定**：条目绑定它到达时的 sid，编号在重连后一律视为无效；重连前的未固定条目（没有副本）保持灰，按钮写「重连前的，复制不到」；已固定的用副本，照常可用。新会话来的条目是新条目。
- **C5（副本存哪、要哪些命令）**：规格 §3 只列了 `fetch_clip`、`cancel_transfer`，但固定的图片/数据副本要在会话结束后还能「复制到本机」，runner 里的会话那时已经关了。**裁定**：runner 进程级 `ClipCopies`（RappSession）存副本；`fetch_clip {sid, clip}` 是有返回值的调用，回 `{copy: n}` 或 `{error: 原因}`；另加三条命令：`copy_local {copy}`（回 bool）、`drop_copy {copy}`、`reveal {path}`（回 bool，Finder 里选中）。未固定、会话还活着的条目「复制到本机」照旧走 `clip_pick(insert: false)`。
- **C6（runner 历史只有 20 条）**：runner 的 `ClipHistory.limit = 20`，Dart 列表要 100、A 端存 50。**裁定**：上限改成构造参数（默认 20，rapp-client 不变），嵌入会话用 50（和 A 一致）；更老的条目在 Dart 里还在，取回时回 `unknown clip`，按钮出错提示。
- **C7（`clipboard` 事件缺种类）**：规格 §2.1 要条目带种类，现在每行只有 `{id,title,pickable}`。**裁定**：每行加 `kind`（`text|image|files|data|unsupported`）；Dart 缺 `kind` 时按 `pickable` 当 `text`/`unsupported`。

## S6 计划决定（规格没写死、我定的）

| # | 计划决定 | 理由 | 错了的代价 |
|---|---|---|---|
| K1 | 计划决定：Dart 收到 `clipboard`（整张表，新的在前）时，只加这个 sid 没见过的编号，按从旧到新的顺序加到全局列表顶上，所以这次里最新的在最上。"见过"记在 `_seen[(sid, clip)]`，被挤掉（超 100）的也记着，不会因为 runner 下次还列着它又加回来；会话结束时清掉这个 sid 的 `_seen` | 规格 §2.1 每条事件加一条；runner 每次发整张表 | 无 |
| K2 | 计划决定：条目的来源文字 `<app> @ <设备>` 和时间 `HH:mm` 在加进来那一刻定下，之后不变；时间来自 `MainState` 可注入的 `clock`（默认 `DateTime.now`） | 规格 §2.1；测试要固定时间 | 无 |
| K3 | 计划决定：超过 100 条未固定时，从最老的未固定开始删；固定的不算数、不删（被删的都没有副本，不用 `drop_copy`）；取消固定后它重新算数，超了就当场删最老的未固定 | 规格 §2.1、§6 第 2 条 | 无 |
| K4 | 计划决定：「复制到本机」可用的条件：有副本；或者条目的 sid 就是它所在记录现在活动（`Phase.live`、没在重连）的 sid、种类不是 `unsupported`。有副本 → `copy_local`；否则 → `clip_pick(sid, clip, false)`。不可用时按钮灰、文字依次是：`unsupported` →「不支持」；记录已断开或已结束 →「A 已断开，复制不到」；重连前的（C4）→「重连前的，复制不到」 | 规格 §2.3、§2.5 | 无 |
| K5 | 计划决定：固定：文字和其他种类同一条路，都是 `await fetchClip(sid, clip)`（文字 runner 当场回）；拿到 `copy` 才标记固定；期间按钮「固定」灰着；失败时提示 `固定没成功：<原因>`，条目保持未固定。条目不在线（K4 的不可用情况、且没有副本）时「固定」灰。取副本时会话结束：runner 回错，条目照会话结束规则删掉，不出提示 | 规格 §2.4 | 文字多一次往返（本机、很快） |
| K6 | 计划决定：取消固定：会话还在（记录还在、未结束）→ 条目留着、`drop_copy`、重新算 100 条；会话已结束 → 条目删掉、`drop_copy`。文件副本不删磁盘上的文件（`drop_copy` 只忘掉它） | 规格 §2.4 "取消固定时如果来源会话已经结束就删掉"；删用户的 Downloads 文件不可逆 | ~/Downloads/rapp 里文件自己留着 |
| K7 | 计划决定：会话结束（`_endRecord`）：删这个记录的全部未固定条目；固定的留下、`ended = true`；这个记录的进行中传输在 Dart 里当场标成「已取消」进传过的（runner 关会话时自己会取消）。断开（`DisconnectedEvent`）：条目留着、按 K4 变灰；进行中传输标成「没传完」进传过的。之后再来的同一个 `(sid, id)` 传输事件一律不理 | 规格 §2.5；runner 关会话后可能来不及发事件 | 无 |
| K8 | 计划决定：重连（新 sid，同一个记录）：旧 sid 的条目留着、按 C4 灰；新 sid 的条目正常加。重连成功后旧 sid 的 `_seen` 可以丢 | C4 | 无 |
| K9 | 计划决定：传输编号是每个 `TransferQueue`（= 每个会话）从 1 开始递增；Dart 里用 `(sid, id)` 认。`running` 事件在任务入队、开始、整数百分比变化时发；`done`/`failed`/`cancelled` 各发一次。入队还没开始的显示 0% | 规格 §3；不按块发，免得每 64 KB 一次平台消息 | 无 |
| K10 | 计划决定：传过的（`TransferRow.ended`）按结束时间新的在前，最多 50 条，超出删最老的；`failed`、`cancelled` 也进传过的，大小那一栏写 `没传完`／`已取消`，没有「显示位置」。`done` 的下载写大小和「显示位置」；`done` 的上传写 `A：~/Downloads/rapp/<名字>`（只是文字、不能点；A 上实际可能加了序号，所以是近似），不是文件的上传不写位置 | 规格 §2.3、§6 第 5 条；上传到 A 后 B 不知道最终名字 | 失败的条目占传过的名额 |
| K11 | 计划决定：「显示位置」→ `reveal {path}`，runner `NSWorkspace.shared.activateFileViewerSelecting([url])`；文件不在了回 false，提示 `文件不在了：<名字>` | 规格 §2.3 | 无 |
| K12 | 计划决定：下载目录：`TransferQueue(address:downloads:)`，`downloads` 默认 `~/Downloads/rapp`；`EmbeddedSession` 透传；runner 在环境变量 `RAPP_DOWNLOADS` 非空时用它（实机检查用 scratchpad 目录），否则默认。rapp-client 不变 | 规格 §5 测试用临时下载目录；不碰用户的 ~/Downloads | 无 |
| K13 | 计划决定：资源标签：`PanelTab.resources`，第四个标签「资源」，key `tab-resources`，宽 720；上半「剪贴板」、下半「文件」（再分「进行中」「传过的」），两半各自滚动、各占一半高。空状态：`还没有剪贴板条目`、`没有进行中的传输`、`这次启动还没有传过文件` | 规格 §2.3；主窗口 §3.7 | 改文字 |
| K14 | 计划决定：剪贴板行：种类标签、标题（等宽字体，单行省略）、`<来源> · HH:mm`、「固定」/「取消固定」、「复制到本机」。种类标签照设计语言 §3：文字单实线、图片虚线、文件双线、数据虚线（同图片）、不支持双线灰 + 灰字；标签字是 `文字`、`图片`、`文件`、`数据`、`其他` | 设计语言 §3 只定了前三种 | 改一个小组件 |
| K15 | 计划决定：进行中行：连接中灯 + 进度条（设计语言"传输中"）、方向 `↓ 从 A` / `↑ 到 A`、名字、`N%`、来源、「取消」（一次点击，`.rapp-part` 保留可续，不算不可撤销） | 规格 §2.3；续传在同一个会话里还能接上 | 想要点两次就换 `ConfirmButton` |
| K16 | 计划决定：流菜单第 5 组：全局列表里 `key == 当前记录 key` 的最新两条；点一条 = 「复制到本机」（K4 的同一个函数），可用的才可点；活动会话的可用条目保留「插入」（`clip_pick(insert: true)`）；有条目时总有「全部剪贴板」→ `showPanel(PanelTab.resources)` 并关掉流菜单。去掉原来的就地展开 `_allClips` | 规格 §2.2；主窗口 §5 选了就收 | 无 |
| K17 | 计划决定：`MainState.showPanel(tab)`：打开到这个标签（已开着就停在它上面，不像 `togglePanel` 会关） | 「全部剪贴板」点两次不该把面板关掉 | 无 |
| K18 | 计划决定：GUI 和 runner 都不记剪贴板内容、条目标题、粘贴/输入的文字；固定、取消固定、复制到本机都不写日志。runner 现有的 `downloaded <path>` 日志（文件路径）保留 | 规格 §3；Global Constraints 数据规则 | 无 |
| K19 | 计划决定：提示只在出错时出（K5、K11、`copy_local` 回 false 时 `本机副本不在了`、`clip_pick` 下载失败沿用 runner 现有的 `transfer_status` 失败文字）；成功不出提示（界面本身变了） | 设计语言 §0 第 2 条 | 无 |

## Global Constraints

**安全规则（每个实现者都受约束）：**
- Only start/stop processes you launched, by PID. Never `killall`/`pkill` (including `flutter_tester`) or address processes by name in AppleScript/System Events.
- Never touch /Applications/rapp.app, the running rapp-service, ~/Library/Logs/rapp, the user's real config dir, the keychain, or the system clipboard. Tests use temp dirs and ephemeral ports; never ports 47800 or 21116–21119.
- Do NOT launch any GUI/app window or send synthetic input. The user is actively using this Mac. (Task 7 live check is parked until the user agrees; no other task needs it.) `flutter build macos --debug` is a compile check only — never run the built app. `reveal` / Finder is never exercised outside Task 7.
- `scripts/package-macos.sh` now signs with a keychain identity: run it only in Task 7, after the user agrees.
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
- Never log passwords, tokens, secrets, relay keys, typed text, pasted text or clipboard content (K18). Test failure messages don't print clipboard bytes either.
- Swift tests never use `NSPasteboard.general`: only named `rapp.test.<uuid>` boards, `releaseGlobally()` in tearDown. Dart tests use `FakeSessionPort` / `FakeTransport`; no Dart test reaches the system clipboard.
- Swift download tests use a temp `downloads:` dir (`FileManager.default.temporaryDirectory` + UUID, removed in tearDown) — never `~/Downloads`.
- Security posture (user's decision): the self-hosted relay is the only gate; do not add crypto layers, approval steps or confirm dialogs.

**S6 另加：**
- 实机检查（Task 7）只在用户明确同意把这台 Mac 让出来一段时间之后做；那时点击一律先 `topatp X Y <pid>`（scratchpad `s2live/topatp`，按 PID 判断）确认点到的是自己的 GUI；发键前确认最前的 app 是自己的 GUI（按 PID）；截图只截自己的窗口（`screencapture -l <id>`）。剪贴板条目只来自自己起的 host 上、自己起的 app 里写进去的测试文字和测试文件。
- 本机副本只在 runner 内存里（图片、数据、文字）或是 `downloads` 目录里已有的文件；不写别的地方、重启就没（规格 §6 第 3 条）。

**测试与命令：**
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`（起点：S5 结束时 519 过，`analyze` 干净）。长输出重定向到 scratchpad 里的文件再看末尾。
- Swift：仓库根目录 `swift test`（单个类用 `swift test --filter TransferQueueTests`），然后 `./scripts/check.sh`，`.build-logs/check.log` 末行 `EXIT=0`。
- runner 编译检查：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（只编译，不运行）。
- Rust 不改，只在 Task 7 全量验证：`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`（S5 结束时 207 过、0 警告；不跑 `cargo fmt`）。
- 每个 Task 一个提交；**只** `git add <路径>`；不 push、不 merge、不换分支。

**代码规则：**
- 组件只用 `RappTokens`；可点控件高度 ≥ 48px（设计语言 §6）；剪贴板内容（条目标题）用等宽字体（`t.mono` + `t.monoFallback`）。
- 词只用设计语言 §9 和规格 §2 定的：固定、取消固定、复制到本机、全部剪贴板、取消、显示位置、进行中、传过的、不支持；已断开、已结束。
- 强调色只用于"已断开"和"等你"；资源标签里灰掉的按钮用 `t.muted`，不用强调色。
- 浮层只盖不挤；选了就收（「全部剪贴板」关流菜单）；不靠悬停和右键。
- 设计语言 §0 三条检查，每个 UI 任务交付前对一遍：① 全局列表在左侧面板（浮层）和流菜单（角落），不进舞台；② 只有出错才出一行提示，不弹窗、不抢焦点；③ 会话结束后未固定条目和进行中传输自己消失/收尾，不留要再清一次的东西。

## Review Focus

1. **重连后旧编号被当成新会话的同号条目**（C4）：旧 sid 的条目重连后不发 `clip_pick`（发了会取到 A 上另一条）。测试：Task 5 `entries from before a reconnect stay grey and never pick`。
2. **runner 每次发整张表 + 100 条上限**：同一条不重复加、被挤掉的不回来、最新在上。测试：Task 4 `a resent table adds only unseen clips, newest on top`、`evicted clips do not come back`。
3. **按编号取消只取消那一个，并留着 `.rapp-part`**；不带编号仍取消全部（输入条不回归）。测试：Task 1 `testCancelByIdLeavesOthersAndKeepsPart`、`testCancelAllStillCancelsEverything`；Task 3 `cancelTransfer without id sends no id`。
4. **固定的东西活过会话结束，未固定的不留**：结束后固定条目还能 `copy_local`；未固定条目和进行中传输都没了，之后迟到的 `transfer` 事件不让它们复活。测试：Task 5 `ending a session keeps pinned entries and drops the rest`、`late transfer events after an end are ignored`；Task 2 `testCopiesOutliveTheSession`。
5. **不记剪贴板内容**：日志闭包收到的字符串里没有测试文字。测试：Task 2 `testFetchAndCopyNeverLogContent`（收集 `ClipHistory` 和 `TransferQueue` 的所有日志行，断言没有一行含测试文字 `hello`）。

---

### Task 1: `TransferQueue`：编号、结构化进度、按编号取消、可注入下载目录

**Files:**
- Modify: `Sources/RappSession/Transfers.swift`
- Create: `Tests/RappSessionTests/FakeSideHost.swift`（测试用的 side-connection 假 A）
- Create: `Tests/RappSessionTests/TransferQueueTests.swift`

**Interfaces:**
- Consumes: 现有 `TransferQueue`、`SideConnection`、`Message.fetch/.transferStart/.chunk`、协议的错误消息（`grep -n "case error" Sources/RappCore/Protocol.swift` 找名字）。
- Produces（`Transfers.swift`）：
  - `public enum TransferDirection: String { case down, up }`
  - `public enum TransferState: String { case running, done, failed, cancelled }`
  - `public struct TransferProgress: Equatable { public let id: UInt32; public let dir: TransferDirection; public let name: String; public let done: UInt64; public let total: UInt64; public let state: TransferState; public let path: String?; public let error: String? }`——`path` 只在下载到磁盘 `done` 时有；`error` 只在 `failed` 时有（A 的错误文字或"连接断开"、"无法写入 …"）。
  - `public var onProgress: ((TransferProgress) -> Void)?`（主队列）。`onStatus` 保留不变（输入条和 rapp-client 用）。
  - `public init(address: RemoteAddress, downloads: URL? = nil)`；`downloadsDirectory()` 改成实例属性 `downloads`（`nil` → `~/Downloads/rapp`）。所有用到的地方（`prepareDiskFile`、`finishDownload`、错误文字）改用它。
  - `download(...)`、`upload(...)` 返回 `@discardableResult UInt32`（任务编号，每个队列从 1 递增）。
  - `public func cancel(id: UInt32)`：正在跑的 → 断开连接、关文件句柄（`.rapp-part` 留着），`finish(.failure("已取消"))`，`pump()` 下一个；排队中的 → 从队列删、`finish`；不认识的编号什么都不做。`cancel()`（全部）不变，但每个任务也发一次 `cancelled`。
  - 进度规则（K9）：入队发 `running`（done = 已有续传量或 0）；`progress(...)` 里只在整数百分比变了时发；`complete` 里按结果发 `done`/`failed`/`cancelled`（"已取消"失败 → `cancelled`）。
- Produces（测试辅助 `FakeSideHost`，`NWListener` 监听 `127.0.0.1` 的临时端口）：`init(serving: [UInt8], failWith: String? = nil, pauseAfter: Int? = nil)`；`port: UInt16`（`ready` 之后）；收到 `fetch(offset:)` 回 `transferStart(total)`，然后从 `offset` 起每块 64 KB 发 `chunk`，发完关；`failWith` 非空时回错误消息；`pauseAfter` 发到这么多字节后停住不关（用来测取消）；`fetches: [UInt64]` 记每次请求的 offset；`stop()` 在 tearDown 调。

- [ ] **Step 1: 写失败的测试**（`TransferQueueTests`，`setUp` 建临时下载目录，`tearDown` 删目录、`host.stop()`；`RemoteAddress(host: "127.0.0.1", port: host.port, bundleID: "x", token: "t", mode: .color16)`；用 `XCTestExpectation` 等主队列回调）：
  - `testDownloadReportsIdsAndProgressThenDone`：服务 300 KB；`download(clip: 1, file: 0, name: "a.bin", total: 300_000, toDisk: true)` 返回 1，第二个下载返回 2；`onProgress` 序列：第一个以 `running`（done 0）开头，`done` 单调不减、没有两个相邻的同百分比 `running`，以 `done` 结尾且 `path` == `<下载目录>/a.bin`，文件内容等于服务的字节。
  - `testDownloadsGoToTheInjectedDirectory`：完成后 `<下载目录>/a.bin` 存在；`~/Downloads/rapp/a.bin` 的存在与否和测试前一样（只读检查，不建不删）。
  - `testCancelByIdLeavesOthersAndKeepsPart`（Review Focus 3）：`pauseAfter: 128 KB`；入队 A（磁盘）、B（内存）；A 收到 ≥ 64 KB 后 `cancel(id: 1)` → A 收到 `cancelled`、`<下载目录>/a.bin.rapp-part` 存在且大小 > 0；B 接着开始并 `done`。
  - `testCancelQueuedById`：入队 A、B；`cancel(id: 2)` → B 收到 `cancelled`，A 照常 `done`，B 的 host 从没收到 fetch（`fetches.count == 1`）。
  - `testCancelAllStillCancelsEverything`（Review Focus 3）：入队两个，`cancel()` → 两个都 `cancelled`，`onStatus` 最后是 `nil`（和现有行为一样）。
  - `testHostErrorIsFailedWithReason`：`failWith: "unknown clip"` → 最后一个事件 `state == .failed`、`error == "unknown clip"`。
- [ ] **Step 2: 跑测试确认失败** — `swift test --filter TransferQueueTests` → 编译失败（`onProgress`、`downloads:` 未定义）。
- [ ] **Step 3: 实现** 上面的接口。`Job` 加 `id`、`dir`；`complete` 发结束事件；`cancel(id:)` 照 `cancel()` 的写法只处理一个任务（正在跑的那个要 `generation += 1`，免得挂着的重试再开）。
- [ ] **Step 4: 跑测试确认通过** — `swift test`（全部，含现有 `ClipHistoryTests`、`EmbeddedSessionTests`、`SenderTests` 不变），`./scripts/check.sh` 末行 `EXIT=0`。
- [ ] **Step 5: Commit** — `git add Sources/RappSession/Transfers.swift Tests/RappSessionTests/FakeSideHost.swift Tests/RappSessionTests/TransferQueueTests.swift`，`feat(session): numbered transfers, progress events, cancel by id`

---

### Task 2: 剪贴板种类、取副本、`ClipCopies`、通道命令和事件

**Files:**
- Modify: `Sources/RappSession/ClipHistory.swift`、`Sources/RappSession/EmbeddedSession.swift`、`Sources/RappSession/SessionEvent.swift`、`Sources/RappSession/Channel.swift`
- Create: `Sources/RappSession/ClipCopies.swift`
- Test: `Tests/RappSessionTests/ClipHistoryTests.swift`、`Tests/RappSessionTests/EmbeddedSessionTests.swift`、新 `Tests/RappSessionTests/ClipCopiesTests.swift`、通道测试所在文件（`grep -ln channelCommand Tests/RappSessionTests`）

**Interfaces:**
- Consumes: Task 1 的 `TransferProgress`、`cancel(id:)`、`downloads:`；`FakeSideHost`。
- Produces：
  - `ClipHistory.init(pasteboard:limit:log:)`，`limit` 默认 20（C6）；`public let limit: Int` 取代 `static let limit`（现有测试改读实例属性）。
  - `public enum ClipCopy { case text(String), image([UInt8]), data(uti: String, [UInt8]), files([URL]) }`
  - `ClipHistory.fetch(_ id: UInt32, info: ClipInfo, transfers: TransferQueue, done: @escaping (Result<ClipCopy, TransferFailure>) -> Void)`：文字当场 `.success(.text)`；图片/数据下到内存；文件按顺序下到磁盘；`unsupported` → `.failure("不支持")`。`pick` 改成复用同一组带完成回调的 `fetchBytes`/`fetchFiles`（失败时照旧只记 `clip <id> download failed: <原因>`，不记内容）。
  - `ClipCopies.swift`：`public final class ClipCopies { public init(); public func add(_ c: ClipCopy) -> Int; public func copy(_ n: Int) -> ClipCopy?; public func drop(_ n: Int); public func write(_ n: Int, to board: LocalPasteboard) -> Bool }`——编号从 1 递增不复用；`write` 对 `.files` 先检查每个 URL 还存在，有一个不在就回 false、不写；不认识的编号回 false。只在主队列用，不记日志。
  - `EmbeddedSession`：`init(..., downloads: URL? = nil)` 透传给 `TransferQueue`；`ClipHistory(pasteboard:, limit: 50, log:)`；`transfers.onProgress` → `post(.transferProgress($0))`；`transfers.onStatus` → `post(.transferStatus($0))`；`public func fetchCopy(_ id: UInt32, done: @escaping (Result<ClipCopy, TransferFailure>) -> Void)`（在会话队列读 `history.info`；`linkDown` → `.failure("A 已断开")`；没有 → `.failure("unknown clip")`；然后在主队列 `history.fetch`；`done` 总在主队列调）；`public func cancelTransfer(id: UInt32)`（主队列 `transfers.cancel(id:)`）。
  - `SessionEvent`：`case transfer(String?)` 改名 `case transferStatus(String?)`；新 `case transferProgress(TransferProgress)`；`ClipRow` 加 `kind: String`（C7；`.clip` 处理里由 `ClipInfo` 算：`text|image|files|data|unsupported`）。
  - `Channel.swift`：
    - `ChannelCommand.cancelTransfer(sid: Int64, id: UInt32?)`；新 `fetchClip(sid: Int64, clip: UInt32)`、`copyLocal(copy: Int)`、`dropCopy(copy: Int)`、`reveal(path: String)`；`known` 加 `fetch_clip`、`copy_local`、`drop_copy`、`reveal`；参数缺失或类型不对 → `.bad`（照现有 `Args`）。
    - `eventPayload`：`.clips` 每行加 `"kind"`；`.transferStatus` → `"transfer_status" {status}`；`.transferProgress(p)` → `"transfer" {id, dir, name, done, total, state, path?, error?}`（`done`/`total` 为 `Int`；没有的字段不放）。
    - `public func clipCopyReply(_ r: Result<Int, TransferFailure>) -> [String: Any]` → `["copy": n]` 或 `["error": reason]`（runner 回给 Dart 的形状）。

- [ ] **Step 1: 写失败的测试**
  - `ClipHistoryTests`：`testLimitIsConfigurable`（`limit: 50`，加 60 条 → 留 50 条，最新在前）；现有 `testClipHistoryKeepsNewestTwentyNewestFirst` 用默认值照过。
  - `ClipCopiesTests`（命名板 `rapp.test.<uuid>`，tearDown `releaseGlobally()`）：`testAddWriteDrop`（`.text("t1")` → `write` 回 true、板上字符串 == "t1"；`drop` 后 `write` 回 false）；`testFilesCopyFailsWhenAFileIsGone`（临时文件 → true；删掉 → false，板没被写）；`testNumbersAreNotReused`（add、drop、add → 第二个编号 == 2）。
  - `EmbeddedSessionTests`（照现有 `make(link)`，另把 `downloads:` 指到临时目录、地址端口指到 `FakeSideHost`——给 `make` 加可选的 `address`、`downloads` 参数）：
    - `testClipRowsCarryKind`：喂 `.clip` 文字、图片、文件、`unsupported` 各一条 → `.clips` 的 `kind` 依次对。
    - `testFetchCopyOfTextIsImmediate`：喂文字 `"hello"` → `fetchCopy(id)` 回 `.success(.text("hello"))`，`FakeSideHost.fetches` 为空。
    - `testFetchCopyOfImageDownloadsToMemory`：服务 1000 字节 → `.success(.image(bytes))` 且等于服务的字节。
    - `testFetchCopyOfUnknownOrDownLink`：没喂的编号 → `.failure("unknown clip")`；`link.drop("x")` 之后 → `.failure("A 已断开")`。
    - `testTransferProgressAndStatusAreBothForwarded`：`pickClip` 一个图片 → 事件里既有 `.transferProgress`（最后是 `done`），也有 `.transferStatus`。
    - 现有 `testUploadStatusIsForwardedAndCancelEndsTheRound` 改用 `.transferStatus`，其余断言不变。
    - `testCopiesOutliveTheSession`（Review Focus 4）：`fetchCopy` 图片 → 存进一个 `ClipCopies` → `s.close()` → `copies.write(n, to: board)` 仍回 true，板上有 PNG 类型的数据。
    - `testFetchAndCopyNeverLogContent`（Review Focus 5；直接建 `ClipHistory(pasteboard:limit:log:)` 和 `TransferQueue`，两个的 `log` 都收集到一个数组）：加一条文字 `"hello"` 并 `fetch`、`pick` 它，再对一张图片 `fetch`（`failWith: "unknown clip"`）→ 收集到的每一行都不含 `"hello"`。
  - 通道测试：`cancel_transfer {sid:1}` → `.cancelTransfer(sid: 1, id: nil)`；`{sid:1,id:3}` → `id: 3`；`fetch_clip {sid:1, clip:2}`、`copy_local {copy:4}`、`drop_copy {copy:4}`、`reveal {path:"/tmp/x"}` 各自解析对；`fetch_clip` 缺 `clip` → `.bad`；`eventPayload(.transferProgress(…done, path))` 的方法名是 `"transfer"`、有 `path`、没有 `error`；`.transferStatus("x")` 的方法名是 `"transfer_status"`；`.clips` 行有 `"kind"`；`clipCopyReply(.success(3)) == ["copy": 3]`。
- [ ] **Step 2: 跑测试确认失败** — `swift test` → 编译失败。
- [ ] **Step 3: 实现** 上面的接口。rapp-client（`Sources/rapp-client`）里用到 `.transfer`、`ClipHistory.limit`、`TransferQueue(address:)` 的地方跟着改名/改读法，行为不变（`grep -rn "\.transfer(\|ClipHistory.limit" Sources`）。
- [ ] **Step 4: 跑测试确认通过** — `swift test` 全绿；`./scripts/check.sh` 末行 `EXIT=0`。
- [ ] **Step 5: Commit** — `git add` 上面列出的每个 Sources 和 Tests 文件（加上改到的 rapp-client 文件，逐个写名字），`feat(session): clip kinds, fetch copies, copy store, channel commands`

---

### Task 3: runner 胶水和 Dart `SessionPort`

**Files:**
- Modify: `gui/macos/Runner/SessionPlugin.swift`
- Modify: `gui/lib/embed/session_port.dart`、`gui/lib/embed/remote_session.dart`
- Modify: `gui/test/fakes.dart`
- Test: `gui/test/embed/session_port_test.dart`（现有解析测试所在文件；`grep -ln "'clipboard'" gui/test` 找）、`gui/test/embed/remote_session_test.dart`（同上）

**Interfaces:**
- Consumes: Task 2 的通道命令、事件、`ClipCopies`、`clipCopyReply`、`EmbeddedSession(downloads:)`、`fetchCopy`、`cancelTransfer(id:)`。
- Produces（runner，`SessionPlugin`）：
  - 插件持有一个 `let copies = ClipCopies()` 和 `let downloads: URL?`（`ProcessInfo.processInfo.environment["RAPP_DOWNLOADS"]`，非空才用，K12），`start` 时传给 `EmbeddedSession`。
  - `fetch_clip`：`live[sid]` 不在 → `result(["error": "A 已断开"])`；否则 `session.fetchCopy(clip) { r in result(clipCopyReply(r.map { copies.add($0) })) }`。
  - `copy_local` → `result(copies.write(copy, to: LocalPasteboard()))`；`drop_copy` → `copies.drop`、`result(nil)`；`reveal` → 文件存在时 `NSWorkspace.shared.activateFileViewerSelecting([url])`、`result(true)`，否则 `result(false)`；`cancel_transfer` 带 `id` → `session.cancelTransfer(id:)`，不带 → `cancelTransfers()`（不变）。
- Produces（Dart，`session_port.dart`）：
  - `enum ClipKind { text, image, files, data, unsupported }`；`ClipRow(id, title, pickable, [kind])`——解析 `kind`，缺或不认识时 `pickable ? text : unsupported`（C7）。
  - `TransferEvent` 改名 `TransferStatusEvent(sid, status)`，解析 `transfer_status`。
  - 新 `TransferProgressEvent(sid, id, down, name, done, total, state, path, error)`，`state` 是 `enum TransferState { running, done, failed, cancelled }`，解析 `transfer`；字段坏 → 和现有坏事件一样丢掉。
  - 新命令：`Future<({int? copy, String? error})> fetchClip(Object sid, int clip)`（`PlatformException`/`MissingPluginException`/坏回答 → `error: '没有连上 runner'`，照 `_pasteCall` 的写法）；`Future<bool> copyLocal(int copy)`；`void dropCopy(int copy)`；`Future<bool> reveal(String path)`（异常 → false）；`void cancelTransfer(Object sid, {int? id})`——`id == null` 时参数里**没有** `id` 键。
- Produces（`remote_session.dart`）：`TransferEvent` 改 `TransferStatusEvent`；`TransferProgressEvent` 在 `RemoteSession.apply` 里不改状态（交给 `MainState`），只是不出错。
- Produces（`fakes.dart`）：`FakeSessionPort` 加可设的 `fetchReply`（默认 `{copy: <递增>}`）、`copyLocalReply`（默认 true）、`revealReply`（默认 true），`invoke` 对 `fetch_clip`、`copy_local`、`reveal` 按它们回；调用都记进 `calls`。

- [ ] **Step 1: 写失败的测试**（Dart）：
  - `clipboard rows carry kind`：`{kind:'image'}` → `ClipKind.image`；缺 `kind`、`pickable:false` → `unsupported`。
  - `transfer_status still drives the upload strip`：`transfer_status {status:'上传 1/1 0%'}` → `RemoteSession.transferStatus` 是它。
  - `transfer progress parses`：`transfer {id:3,dir:'down',name:'a.log',done:10,total:20,state:'done',path:'/x/a.log'}` → 字段全对；`state:'weird'` → 丢掉。
  - `cancelTransfer without id sends no id`（Review Focus 3）：`calls` 里 `cancel_transfer` 的参数 == `{'sid': 1}`；带 `id: 3` 时 == `{'sid': 1, 'id': 3}`。
  - `fetchClip returns copy or error`：fake 回 `{copy: 7}` → `copy == 7`；回 `{error: 'unknown clip'}` → `error == 'unknown clip'`；`invoke` 抛 `PlatformException` → `error == '没有连上 runner'`。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/embed` → 编译失败。
- [ ] **Step 3: 实现** 上面的接口；现有用到 `TransferEvent` 的地方（`grep -rn TransferEvent gui/lib gui/test`）改名。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿；runner 编译检查 `FLUTTER_XCODE_ARCHS=arm64 flutter build macos --debug` 通过（不运行）。
- [ ] **Step 5: Commit** — `git add gui/macos/Runner/SessionPlugin.swift gui/lib/embed/session_port.dart gui/lib/embed/remote_session.dart gui/test/fakes.dart` 加上改到的测试文件，`feat(gui): runner glue and port for clip copies and transfer progress`

---

### Task 4: `ResourcesState`（纯 Dart）

**Files:**
- Create: `gui/lib/ui/resources_state.dart`
- Test: `gui/test/ui/resources_state_test.dart`（新）

**Interfaces:**
- Consumes: Task 3 的 `ClipRow`、`ClipKind`、`TransferProgressEvent`、`TransferState`。
- Produces（只 import `package:flutter/foundation.dart` 和 `../embed/session_port.dart`）：
  - `const maxUnpinned = 100; const maxEnded = 50;`
  - `class ClipEntry { final int seq; final String key; final Object sid; final int clip; final ClipKind kind; final String title; final String source; final DateTime at; bool pinned = false; bool pinning = false; int? copy; bool ended = false; }`——`seq` 是本地递增编号（UI 和 `MainState` 用它指条目）。
  - `class TransferRow { final Object sid; final int id; final String key; final bool down; final String name; final String source; int done, total; TransferState state; String? path; String? error; DateTime? endedAt; }`
  - `class ResourcesState extends ChangeNotifier`：
    - `ResourcesState({DateTime Function()? clock})`
    - `List<ClipEntry> get clips`（新的在前）；`List<ClipEntry> clipsOf(String key)`；`ClipEntry? entry(int seq)`
    - `void addClips(String key, Object sid, String source, List<ClipRow> rows)`（K1、K3）
    - `void beginPin(int seq)`；`void pinned(int seq, int copy)`；`void pinFailed(int seq)`
    - `int? unpin(int seq, {required bool sessionEnded})`——回要 `drop_copy` 的副本编号（K6）
    - `List<TransferRow> get running`（入队顺序）；`List<TransferRow> get ended`（结束时间新的在前，≤ 50）
    - `void transfer(String key, String source, TransferProgressEvent e)`——认 `(sid, id)`；已结束的行再来事件不理（K7）；结束状态把行从 `running` 移到 `ended` 顶上
    - `List<(Object sid, int id)> sessionEnded(String key, Set<Object> sids)`——K7：删未固定条目、固定的 `ended = true`、这些 sid 的进行中行标 `cancelled` 移进传过的、清 `_seen`；回被标掉的 `(sid, id)`
    - `void linkDown(Object sid)`——这个 sid 的进行中行标 `failed`、`error = '没传完'`、移进传过的
  - 纯函数：`String hhmm(DateTime t)`（两位补零）；`String sizeText(int bytes)`（`< 1024` → `N B`；`< 1 MB` → 整数 `KB`；`< 1 GB` → 一位小数 `MB`；否则一位小数 `GB`，照剪贴板规格 §4.5 的样子）；`String kindWord(ClipKind k)`（K14）。

- [ ] **Step 1: 写失败的测试**（`clock` 固定在 `DateTime(2026, 11, 12, 9, 5)`）：
  - `entries carry kind, title, source and time`：`addClips('111/calc', 1, 'Calculator @ mini', [ClipRow(1, '文字 · hi', true, ClipKind.text)])` → 一条，`source`、`hhmm(at) == '09:05'`、`kind` 对。
  - `a resent table adds only unseen clips, newest on top`（Review Focus 2）：先 `[2, 1]`，再 `[3, 2, 1]` → 顺序 `3, 2, 1`，共 3 条；两个会话交错加 → 全局按到达顺序新的在前，每条的 `source` 对。
  - `evicted clips do not come back`（Review Focus 2）：一个 sid 依次发 101 次表（每次多一条新的编号，表里带上全部编号）→ 未固定 100 条，编号 1 没了；再发一次同样的表 → 还是 100 条、编号 1 没回来。
  - `pinned entries do not count and are not evicted`：固定最老的一条，再加 100 条 → 共 101 条，固定的还在。
  - `unpin keeps a live entry and removes an ended one`：`unpin(seq, sessionEnded: false)` → 条目在、回 `copy`；`sessionEnded: true` → 条目没了、回 `copy`；取消固定后超 100 → 当场删最老的未固定。
  - `pinFailed leaves the entry unpinned`：`beginPin` → `pinning`；`pinFailed` → `pinned == false && pinning == false`。
  - `transfer rows move from running to ended`：`running`(0/20) → 在 `running`；`done` 带 `path` → 在 `ended` 顶上、`endedAt` 有值；再来一个同 `(sid,id)` 的 `running` → 不理。
  - `ended keeps fifty`：结束 51 个 → `ended.length == 50`，最老的没了。
  - `sessionEnded drops unpinned, keeps pinned and cancels transfers`：两条（一条固定）、一个进行中 → 回 `[(1, 3)]`；只剩固定的那条且 `ended`；传输在 `ended` 里 `state == cancelled`。
  - `linkDown fails the running rows of that sid only`：两个 sid 各一个进行中 → 只有那个 sid 的进了传过的、`error == '没传完'`。
  - `sizeText and hhmm`：`sizeText(512) == '512 B'`、`sizeText(340 * 1024) == '340 KB'`、`sizeText((2.3 * 1024 * 1024).round()) == '2.3 MB'`；`hhmm(DateTime(2026,1,1,7,3)) == '07:03'`。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/resources_state_test.dart` → 编译失败。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/resources_state.dart gui/test/ui/resources_state_test.dart`，`feat(gui): global resources state`

---

### Task 5: `MainState` 接线

**Files:**
- Modify: `gui/lib/ui/main_state.dart`
- Test: `gui/test/ui/main_state_test.dart`（新 `group('resources')`）

**Interfaces:**
- Consumes: Task 3 的 port 命令和事件，Task 4 的 `ResourcesState`；现有 `_onPortEvent`、`_recordOfSid`、`_recordOfLastSid`、`_endRecord`、`deviceName`、`hint`、`SessionRecord`（`key`、`sid`、`lastSid`、`phase`）。
- Produces：
  - 构造参数 `DateTime Function()? clock`；`final ResourcesState resources`（`MainState.dispose` 里一起 dispose）；`enum PanelTab` 加 `resources`（UI 在 Task 6）；`void showPanel(PanelTab tab)`（K17）。
  - `_onPortEvent`：`ClipsEvent` → `resources.addClips(r.key, e.sid, '${r.app 的显示名} @ ${deviceName(r.id)}', e.clips)`（找记录用 `_recordOfSid`；找不到不加）；`TransferProgressEvent` → `resources.transfer(...)`；`DisconnectedEvent` → `resources.linkDown(sid)`；`_endRecord(r)` → `resources.sessionEnded(r.key, {r.sid, r.lastSid}.whereType<Object>().toSet())`（runner 那边关会话就会取消，不另发命令）。
  - `bool canCopy(ClipEntry e)`、`String? copyBlockedWord(ClipEntry e)`（K4：返回 null 表示可用，否则是灰按钮上的字）；`bool canPin(ClipEntry e)`（没在固定中，且有副本或 `canCopy`）。
  - `Future<void> copyLocal(ClipEntry e)`：有副本 → `await port.copyLocal(copy)`，false → `hint = '本机副本不在了'`；否则可用 → `port.clipPick(e.sid, e.clip, false)`；不可用什么都不做。
  - `Future<void> togglePin(ClipEntry e)`：已固定 → `unpin(sessionEnded: e.ended)`，有副本就 `port.dropCopy`；未固定且 `canPin` → `beginPin`、`await port.fetchClip`；回来时条目已经不在了（会话结束删了）→ 如果拿到了副本就 `dropCopy`，不出提示；拿到 → `pinned`；错 → `pinFailed`、`hint = '固定没成功：$error'`。
  - `void cancelTransfer(TransferRow t)` → `port.cancelTransfer(t.sid, id: t.id)`（状态等 runner 的 `cancelled` 事件）。
  - `Future<void> reveal(TransferRow t)` → `await port.reveal(t.path!)`，false → `hint = '文件不在了：${t.name}'`。
  - 不写任何日志（K18）。

- [ ] **Step 1: 写失败的测试**（照文件顶部现有的 `t`、`hub`、`tmp`、`FakeSessionPort` 和打开一个嵌入会话的辅助函数；`clock` 固定）：
  - `clips from two sessions land in one list with sources`：开 `111/Calculator`、`222/Notes`，分别 `port.emit(ClipsEvent(...))` → `resources.clips` 新的在前，`source` 分别是 `Calculator @ <111 的名字>`、`Notes @ <222 的名字>`。
  - `copyLocal of a live unpinned entry picks the clip`：→ `calls` 里有 `clip_pick {sid, clip, insert:false}`。
  - `pinning waits for the copy then marks pinned`：`fetchReply` 用 `Completer` 控制 → 完成前 `pinning`、`canPin == false`；完成 `{copy: 5}` → `pinned`、`copy == 5`。
  - `a failed pin hints and stays unpinned`：`{error:'unknown clip'}` → `hint == '固定没成功：unknown clip'`。
  - `ending a session keeps pinned entries and drops the rest`（Review Focus 4）：一条固定、一条没固定、一个进行中传输 → 结束会话 → 只剩固定那条；`copyLocal` 它 → `calls` 里有 `copy_local {copy}`、没有 `clip_pick`；传输在 `resources.ended`、`cancelled`。
  - `late transfer events after an end are ignored`（Review Focus 4）：结束后再 `emit` 这个 `(sid,id)` 的 `running` → `resources.running` 还是空。
  - `a disconnected session greys its entries`：`DisconnectedEvent` → `copyBlockedWord == 'A 已断开，复制不到'`、`canPin == false`；`copyLocal` 不发任何命令。
  - `entries from before a reconnect stay grey and never pick`（Review Focus 1）：断开 → `reconnect` → 新 sid 就绪 → 旧条目 `copyBlockedWord == '重连前的，复制不到'`，`copyLocal` 不发 `clip_pick`；新 sid 来的条目可用、`clip_pick` 用新 sid。
  - `unpinning after the session ended removes it and drops the copy`：→ 条目没了，`calls` 有 `drop_copy {copy}`。
  - `the pin reply after the entry was removed drops the copy`：固定中结束会话 → 再完成 `{copy: 9}` → `calls` 有 `drop_copy {copy: 9}`，`hint` 没变。
  - `reveal of a missing file hints`：`revealReply = false` → `hint == '文件不在了：a.log'`。
  - `showPanel does not close an open tab`：`showPanel(resources)` 两次 → `panel == PanelTab.resources`。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/main_state_test.dart` → 编译失败。
- [ ] **Step 3: 实现**。记录里 app 显示名从哪拿：照顶栏现在写 `<app> @ <设备>` 的地方用的字段（`grep -n "' @ '" gui/lib`）。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/main_state.dart gui/test/ui/main_state_test.dart`，`feat(gui): wire global resources into main state`

---

### Task 6: 「资源」标签、第四个面板标签、流菜单第 5 组

**Files:**
- Create: `gui/lib/ui/resources_tab.dart`
- Modify: `gui/lib/ui/side_panel.dart`、`gui/lib/embed/stream_menu.dart`、`gui/lib/ui/top_bar.dart`（给 `StreamMenuAnchor` 传新参数）
- Test: `gui/test/ui/resources_tab_test.dart`（新）、`gui/test/ui/side_panel_test.dart`、`gui/test/embed/stream_menu_test.dart`（现有文件名以 `grep -ln StreamMenu gui/test` 为准）

**Interfaces:**
- Consumes: Task 5 的 `MainState`（`resources`、`canCopy`、`copyBlockedWord`、`canPin`、`copyLocal`、`togglePin`、`cancelTransfer`、`reveal`、`showPanel`、`PanelTab.resources`）；`controls.dart`（`RappButton.secondary`、`DashedOutline`）；`RappTokens`。
- Produces：
  - `resources_tab.dart`：`class ResourcesTab extends StatelessWidget { const ResourcesTab({super.key, required this.state}); final MainState state; }`（K13）；`class KindTag extends StatelessWidget { const KindTag(this.kind); }`（K14）。行和按钮的 key：剪贴板行 `clip-<seq>`，按钮 `pin-<seq>`、`copy-<seq>`；进行中行 `run-<sid>-<id>`，按钮 `cancel-<sid>-<id>`；传过的行 `ended-<sid>-<id>`，按钮 `reveal-<sid>-<id>`。
  - 剪贴板行（K14）：`KindTag`、标题（等宽、单行省略）、`<来源> · HH:mm`、「固定」/「取消固定」（`canPin` 假时灰）、「复制到本机」（`copyBlockedWord` 非空时灰，按钮字换成那句话）。
  - 进行中行（K15）：连接中灯 + `LinearProgressIndicator`（颜色用 token）、`↓ 从 A`/`↑ 到 A`、名字、`N%`、来源、「取消」。
  - 传过的行（K10）：名字、`sizeText(total)` 或 `没传完`/`已取消`、来源、`HH:mm`、下载 `done` 有「显示位置」；上传 `done` 写 `A：~/Downloads/rapp/<名字>`（只是文字）。
  - `side_panel.dart`：第四个 `TabChip` 「资源」、key `tab-resources`；`PanelTab.resources` 宽 720；内容 `ResourcesTab(state: s)`。
  - `stream_menu.dart`（K16）：`StreamMenuAnchor`/`StreamMenu` 新参数 `List<ClipEntry> clips`、`bool Function(ClipEntry) canCopy`、`void Function(ClipEntry) onCopy`、`VoidCallback onAllClips`；第 5 组用 `clips.take(2)`；点条目 `_then(() => onCopy(e))`；可用且条目 sid == 当前会话 sid 时带「插入」（`clipPick(..., true)`）；`clips` 非空时最后一项「全部剪贴板」 → `_then(onAllClips)`；删 `_allClips`。`top_bar.dart` 传 `state.resources.clipsOf(record.key)`、`state.canCopy`、`state.copyLocal`、`() => state.showPanel(PanelTab.resources)`，并用 `ListenableBuilder` 听 `state.resources`。

- [ ] **Step 1: 写失败的测试**（widget 测试照 S5 `projects_tab_test` 的搭法：`MainState` + `FakeSessionPort` + 固定 `clock`）：
  - `resources tab lists clips with kind, source and time`：两条 → 两行，`find.text('Calculator @ mini · 09:05')`，`KindTag` 的字 `文字`、`图片`。
  - `kind tags use the design language borders`：文字标签是单实线 `Border`、图片标签外面是 `DashedOutline`、文件标签是两层边框（照 `controls_test` 判断边框的写法）。
  - `copy button greys with the reason`：断开后 `copy-<seq>` 里的字是 `A 已断开，复制不到`、点了 `calls` 不变；`unsupported` 条目是「不支持」。
  - `pin toggles the label`：点 `pin-<seq>` → 等 `fetch_clip` 回 → 字变「取消固定」。
  - `running transfers show direction, percent and cancel`：`emit` 一个 `running` 10/20 → `find.text('↓ 从 A')`、`find.text('50%')`；点 `cancel-1-3` → `calls` 有 `cancel_transfer {sid:1, id:3}`。
  - `ended rows reveal downloads and show upload paths as text`：下载 `done` → 点 `reveal-1-3` → `calls` 有 `reveal {path}`；上传 `done` 名字 `b.txt` → `find.text('A：~/Downloads/rapp/b.txt')`，这一行没有 `reveal-` 按钮。
  - `empty sections say so`：三句空状态文字（K13）都在。
  - `all controls are at least 48 tall`：tab 里每个 `InkWell`/按钮 `getSize().height >= 48`。
  - side panel：`resources tab is the fourth tab and 720 wide`：点 `tab-resources` → 面板宽 720，`ResourcesTab` 出现。
  - stream menu：`group five shows the session's two newest from the global list`：这个会话 3 条、别的会话 1 条 → 第 5 组只出这个会话最新的 2 条；`tapping an entry copies and closes`（`onCopy` 被调、`onClose` 被调）；`all clips opens the resources tab`（点「全部剪贴板」→ `panel == PanelTab.resources`、流菜单关了）；`a grey entry is not tappable`。现有引用 `_allClips` 展开的测试删掉或改成新行为。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/resources_tab_test.dart test/ui/side_panel_test.dart test/embed` → 编译失败。
- [ ] **Step 3: 实现**；交付前对一遍设计语言 §0 三条（Code rules）。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/resources_tab.dart gui/lib/ui/side_panel.dart gui/lib/embed/stream_menu.dart gui/lib/ui/top_bar.dart` 加上改到的测试文件，`feat(gui): resources tab and stream menu clipboard group`

---

### Task 7: 实机检查、打包、记录

**前提：只在用户明确同意后做（用户同意把这台 Mac 让出来一段时间，并同意打包签名）。** 用户中途在用（焦点被抢、GUI 被关）就停下，把没做的条目记"待实机"，不反复把自己的窗口提到前面。全程守 Global Constraints 的安全规则。

**Files:**
- Modify: `tasks/todo.md`（S6 一行改成完成，下面按规格 §5 每条一行，写验证方式和结果）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-s6-global-resources-design.md` 状态行后加"S6 已实现（计划 `docs/superpowers/plans/2026-11-12-rapp-s6-global-resources.md`）"
- Modify: `tasks/lessons.md`（只在这次真学到东西时加）

- [ ] **Step 1: 全量验证** — `flutter analyze`、`flutter test`；`swift test`、`./scripts/check.sh` 末行 `EXIT=0`；`cargo test --workspace`、`cargo clippy --workspace --all-targets`（Rust 没改，应和 S5 结束时一样：207 过、0 警告）。
- [ ] **Step 2: 搭环境（只用自己起的进程，每个都记 PID 文件）** — 复用 scratchpad `s2live/` 的布局（`A`、`B`、`bin`，临时端口，不用 47800、21116–21119），换上 `flutter build macos --release`（`FLUTTER_XCODE_ARCHS=arm64`）的 GUI，`RAPP_HOME` 指向 scratchpad 里的配置目录，`RAPP_DOWNLOADS` 指向 scratchpad 里的 `s6-downloads/`（**不是**用户的 ~/Downloads），写 `gui.pid`。点击一律先 `s2live/topatp X Y $(cat gui.pid)`，返回的 PID 等于 `gui.pid` 才点；发键前确认最前 app 的 unix id 等于 `gui.pid`；截图只截自己的窗口。目标 app 只用自己起的：`pgrep -x TextEdit` 为空才 `open -g -a TextEdit` 一个 scratchpad 里的测试文件，紧接着记 PID；已在跑就跳过需要它的条目并记下来。A 端剪贴板内容只放测试文字（如 `s6-test-1`）和 scratchpad 里的测试文件（≥ 5 MB，看得到进度）。
- [ ] **Step 3: 逐条对规格 §5 检查**（每条截一张自己窗口的图存 `s2live/s6-*.png`）：
  1. 两个会话各在 A 上复制一段测试文字 → 资源标签剪贴板里两条，来源各自对，最新在上。
  2. 固定其中一条 → 结束它的会话（「结束会话」点两次）→ 固定的那条还在、「复制到本机」可用；同一会话的未固定条目没了。（复制到本机后不读系统剪贴板内容，只看界面不报错。）
  3. A 上复制测试文件 → 「复制到本机」→ 进行中有进度 → 进传过的 → 「显示位置」在 Finder 里选中 `s6-downloads/` 里的那个文件（截 Finder 窗口前确认它是这次打开的、只截那个窗口，或者只看 GUI 不截 Finder）。
  4. 再下载一次大文件，进行到一半点「取消」→ `s6-downloads/` 里留着 `.rapp-part`。
  5. 流菜单第 5 组只显示当前会话最新两条；「全部剪贴板」打开资源标签、流菜单收起。
  6. 断开一个会话（按 PID 停掉它的 host）→ 它的条目变灰「A 已断开，复制不到」。
- [ ] **Step 4: 收尾** — 按 PID 文件逐个 `kill` 自己起的 GUI、TextEdit（还在的话）、hub、host/service、relay；`ps -p` 确认都没了；删 `s6-downloads/` 里的测试文件（只删自己放的）。
- [ ] **Step 5: 打包（用户同意后）** — `scripts/package-macos.sh`（它用钥匙串里的身份签名）；不替换 `/Applications/rapp.app`，不重启已装的 rapp-service。
- [ ] **Step 6: Commit** — `git add tasks/todo.md docs/superpowers/specs/2026-11-12-rapp-s6-global-resources-design.md`（改了 lessons 再加 `tasks/lessons.md`），`docs: S6 done — live check, todo, spec status`

---

## Self-review

- **规格覆盖**：§2.1 每条 `clipboard` 事件加到顶上、种类/显示文字/来源/时间/所属会话（Task 2 C7、Task 4 K1/K2、Task 5）、100 条未固定挤最老、固定不算（Task 4 K3）、文字照旧自动进本机剪贴板（runner `ClipHistory.add` 不变）。§2.2 流菜单第 5 组两条 + 点击 = 复制到本机 + 「全部剪贴板」开资源标签（Task 6 K16、K17）。§2.3 资源标签 720、剪贴板行五样、断开灰「A 已断开，复制不到」、文件夹「不支持」（Task 6 K4/K14）、进行中（方向、名字、%、来源、取消、留 `.rapp-part`）（Task 1、Task 6 K15）、传过的（本次启动、名字、大小、来源、时间、显示位置；上传只写文字；50 条）（Task 4 K10、Task 6、K11）。§2.4 固定：文字立刻、其余先取副本再标记、离线灰、副本在内存/文件、取消固定删已结束的（Task 2 `ClipCopies`、Task 5 K5/K6）。§2.5 结束删未固定 + 取消传输、断开变灰、重连（C4、K7、K8，Task 5）。§3 runner `clipboard` 加 `kind`（C7）、新 `transfer` 事件（C2）、`fetch_clip`/`cancel_transfer`（C3、C5）、新文件 `resources_state.dart`、hub 不改（C1）、不记内容（K18，Review Focus 5）。§4 拆四块 → Task 1–2（runner）、3（通道）、4–5（状态）、6（界面）。§5 验收 → Task 7 第 3 步六条，测试用自己的 host/app（按 PID）、命名剪贴板、临时下载目录（Global Constraints、K12）。§6 五条假设：在 GUI（C1）、100（K3）、不跨重启（副本只在 runner 内存和已有文件）、先下载再固定（K5）、传过的本次启动 50 条（K10）。
- **占位扫描**：没有 TBD。"照现有写法"的地方都给了 grep 命令或现有测试名（`_pasteCall`、`make(link)`、`controls_test` 的边框判断、`projects_tab_test` 的搭法）。
- **类型一致**：`TransferProgress`（Swift，Task 1）→ `eventPayload` `"transfer"`（Task 2）→ `TransferProgressEvent`（Dart，Task 3）→ `ResourcesState.transfer`（Task 4）→ `TransferRow`（Task 4、6）；`(sid, id)` 在四处都是同一对；`ClipCopy` → `ClipCopies.add` 的 `Int` → `{copy: n}` → `ClipEntry.copy` → `copy_local`/`drop_copy`；`ClipRow.kind`（Swift `String`）↔ `ClipKind`（Dart enum）名字一一对应；`PanelTab.resources` 在 Task 5 定义、Task 6 用；`showPanel` 在 Task 5 定义、Task 6 用；`TransferEvent` → `TransferStatusEvent` 的改名在 Task 2（Swift）、Task 3（Dart）各做一次。
- **Review Focus**：五条的测试名都写在 Task 5（1、4）、Task 4（2）、Task 1 和 Task 3（3）、Task 2（4、5）的 Step 1 里。
- **比例**：只给签名、规则、测试名和断言、精确文字；没有大段实现代码。
