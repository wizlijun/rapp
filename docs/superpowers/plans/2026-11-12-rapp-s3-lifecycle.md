# rapp S3（会话生命周期）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 嵌入会话断了不消失：条目、串流设置、当前窗口和最后一帧都留着，一键「重连」；每个会话的状态（连接中、活动、空闲、已断开）和流量在顶栏、会话列表、面板底部看得见；顶栏「需要你」数出断开的会话和掉线的设备，点开直接处理；hub 每 30 秒探一次设备在线。

**Architecture:** runner 侧 `EmbeddedSession` 把"连接断了"（`disconnected`，保留纹理）和"结束"（`closed`，释放纹理）分开，`traffic` 事件多带每秒解码帧数，侧连接下载的字节也计入。Dart 侧 `MainState` 改为按（设备, app）存 `SessionRecord`（新文件 `lifecycle.dart`，纯 Dart），sid 只是记录当前连到哪个 hub 会话；重连 = 同一条记录换新 sid。hub 的 `close` 可带 `reason:"user"`，`open` 可带 `reconnect:true`（只进日志），新加定时探测和 `presence {id, online}` 事件。UI 加已断开的舞台、串流菜单「会话」组的断开/重连、会话行的状态文字、总流量和「需要你」浮层（和串流菜单互斥，由 `MainState.corner` 管）。

**Tech Stack:** Swift 5.9（`RappSession`、runner glue），Flutter 3.44（macOS 桌面），Rust（rapp-hub，tokio；testkit）。

**Spec:** `docs/superpowers/specs/2026-11-12-rapp-s3-lifecycle-design.md`（全文，§6 全部按默认）；上位 `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` §3.1、§3.2、§3.6、§4、§5、§7；`docs/superpowers/specs/2026-11-12-rapp-design-language.md`（§0 三条检查、§2 状态灯、§3 流量和状态计数、§8 组件、§9 词表；**只读，不改这个文件**）；S2 规格和计划 `docs/superpowers/specs/2026-11-12-rapp-s2-embedded-stage-design.md`、`docs/superpowers/plans/2026-11-12-rapp-s2-embedded-stage.md`（S3 建在它上面，R2、R10、R11、R6、R23 沿用）。

## S3 范围裁定（规格没写死、我定的）

| # | 裁定 | 理由 | 错了的代价 |
|---|---|---|---|
| R1 | 不加 `frame` channel 事件；runner 每秒的 `traffic` 改成 `{bytes, frames}`，`frames` = 这一秒解码成功的帧数。"收到第一帧"= 第一次 `frames > 0` 的 tick，灯最多晚 1 秒变活动 | 规格 §3 写"`frame`（已有）"，但 S2 R2 明确不发逐帧事件（UI 线程和平台线程合并）；一秒一次足够算空闲 | 要求画面一出来灯就变时，加一个只发一次的 `first_frame` 事件 |
| R2 | 空闲在 Dart 里算：`RemoteSession` 见过帧之后，连续 `idleAfter = 10` 个 `frames == 0` 的 tick 判空闲，来一个 `frames > 0` 的 tick 立刻回活动。只看帧数，不看字节（侧连接下载不算"画面在动"） | 规格 §2.1 "连续 10 秒没有新帧"；tick 是 1 秒 | ±1 秒误差；改常量一处 |
| R3 | Swift 侧"断开"和"结束"分开：链路任何方式断（对端 EOF、网络错、坏帧、`host says:`）→ 私有 `disconnect(reason:)`：断链、取消传输、**不释放画面**、发一次 `.disconnected(reason:)`；只有 `close(reason:)`（Dart 的 `close`、关独立窗口）才释放画面并发 `.closed(reason:)`。断开后不再发 `traffic` | 规格 §3 "断开时不释放最后一帧的纹理，结束时才释放" | 断开的会话多占每个 A 窗口一块 IOSurface，直到重连成功或结束 |
| R4 | 主动「断开」只走 hub：Dart 发 `{"cmd":"close","sid","reason":"user"}`，hub 掐掉本机 TCP，runner 看到 EOF 照 R3 报 `disconnected`；记录上带 `userDisconnect`，原因一律写「你断开了」。hub 的 `closed` 事件和日志原因是 `user` | 规格 §3 "hub 收到 close 照常释放流，closed 事件里带原因 user"；一条路径，不另加 runner 方法 | hub 已退出时「断开」不可用（灰掉）；要做的话再加 runner 侧 `disconnect` 方法 |
| R5 | hub `close` 的 `reason` 只接受 `"user"`，别的值报错 `bad reason`；存在新的 `Hub.close_why`，只有嵌入会话的"收到 close"分支读它，S1 的 `rapp-client` 路径忽略 | 不让任意字符串进日志 | 无 |
| R6 | 重连是一次新的 `open`（`embed:true`，另带 `reconnect:true`），hub 只把 `"reconnect":true` 记进 `opened` 日志行。"断开"那一行就是 hub 已有的 `closed` 行（原因 `user` / `connection closed` 等）；A 关了 app 这类细分原因只在 A 端 host 日志和 GUI 上，hub 日志里是 `connection closed` | 规格 §3 "断开、重连各记一行（原因、设备、app）"；GUI 进程不写日志文件（S2） | 想在 hub 日志里看到细分原因，要让 GUI 在断开前发一条 `note`（但那时 hub 会话常常已经没了） |
| R7 | 在线探测用新事件 `presence {"event":"presence","id","online":bool}`，不往 `hosts` 里加字段；`Opts.presence_every: Option<Duration>`，`main.rs` 填 30 秒，testkit 默认 `None`（不探）；循环串行，一次一个设备，用新的轻量请求 `request(&host, &Op::Ping)`（走 hub 缓存的连接，和现有探测同一条路径）；A 回 ok，**或**回错误恰好是 `unknown op`（还没升级的旧 service）都算在线；每次探测都发一条 `presence`，失败不发 `error`、不记日志 | 规格 §3 二选一；`hosts` 是请求的回答，掺进周期数据会和 `refresh_hosts` 撞；每次都发让 GUI 不用猜。不用 `ListApps`：A 的 service 每次 `list_apps` 都记一条 `request` 访问日志并起一次 worker，30 秒一次会把 A 的「访问记录」刷满（每台 B 每天约 2880 条），真正的访问反而看不见 | 多一个事件类型和一个 `Op`；旧 service 回 `unknown op` 本来就不记日志 |
| R8 | 断开原因词表 `disconnectWord(raw)`，按顺序匹配：`user` → 你断开了；`host says: …quit` → A 端关闭了 app；含 `bad password` → 密码不对；含 `offline`、`no path to`、`relay unreachable and no LAN address answered` → 对方离线；含 `timed out`、`no reply` → 连接超时；`connection closed`、`the host closed the connection`，或以 `connection error:`、`connection failed:`、`send failed:`、`cannot reach ` 开头 → 网络断了；`GUI did not connect` → 本机没有接上会话；其余 `hubWord(raw)` 去掉 `rapp-client: `、`host says: ` 前缀原样显示 | 规格 §2.1 的六个短语，对到 `Connection.swift` 和 hub `link.rs` 的真实字符串 | 原因归错类只是字不对；改一个函数 |
| R9 | 第一次打开连不上（hub `open` 报错或 runner `start` 报错）也留成一条已断开的记录（原因 + 「重连」），不再像 S2 那样删掉条目；仍出一行提示 `<app> 已断开：<原因>`（这是用户刚做的操作的结果）。之后自发的断开（网络断、A 关 app、坏帧）**不出提示**，只改灯和计数 | 规格 §2.1 连接中 → 已断开；设计语言 §0 第 2 条：只有等你能来找人 | 用户不想要失败的条目时，点两次「结束会话」 |
| R10 | 重连期间舞台继续显示旧的最后一帧（条纹 + 旋转灯 + "正在连接"）；新会话第一次报出带纹理的窗口时才 `port.close(旧 sid)` 换画面；重连失败回到已断开，旧画面还在 | 规格 §2.2 "重连成功后换成新画面" | 重连期间两组纹理同时在；改成立刻释放只动 `_swapIfReady` 一处 |
| R11 | 重连沿用断开时 `RemoteSession.choice`（档位、密度、帧率）和当前窗口 id：`start` 直接带这三个值；新 `RemoteSession.preferWindow(id)`，A 报来的窗口表里有这个 id 就选它，没有照 S2 规则 | 规格 §2.2；A 上同一窗口重开后 id 通常不变 | id 变了就落回第一个普通窗口 |
| R12 | 已断开或重连中的会话不发任何东西给 runner 或 hub：`set_stream`（1 fps 策略）、`note`、`focus` 都跳过；`note` 还要求 sid 仍在 `hub.sessions` 里 | 死 sid 发给 hub 会回 `unknown sid` 错误，变成一条莫名其妙的提示 | 无 |
| R13 | 分离中的会话断开：runner 先发 `disconnected`，再调 `attachSession(sid)`（发 `detached {false}`）；Dart 收到时记录已是已断开，不发 `note` | 规格 §2.2 "独立窗口自动放回舞台"；顺序反了会对死 sid 发 `note` | 无 |
| R14 | 「结束会话」：活动的会话照 S2（`port.close` → runner `closed` → 删条目、提示「已结束 X」）；已断开的会话 `port.close(sid)` 后**立刻**删条目并提示，之后到来的 `closed` 忽略；重连中结束：旧 sid `port.close`，删条目，新 `open` 回来后安静地 `hub.close(新 sid)`，不 `start` | 已断开时 hub 那边已经没有会话，等不到 hub 的 `closed` | 无 |
| R15 | hub 会话在 Dart 看来消失（hub `closed` 先到）而 runner 还没报：等 1 秒（S2 的合并窗口）收 runner 的 `disconnected`，收不到就用 hub 的原因断开；hub 进程退出时原因 `rapp-hub exited`。**不再**像 S2 那样 `port.close`——纹理要留着 | 沿用 S2 合并规则，只是结果从"结束"变"断开" | 无 |
| R16 | "掉线的设备"= 这次启动后见过在线（`probe` 成功或 `presence online:true`），且最近一次结果是离线。手动探测期间那盏转的灯不改变是否掉线；`presence` 碰到正在手动探测的设备跳过这一条 | 规格 §2.4、§6 第 4 条；防止开面板时计数跳一下 | 无 |
| R17 | 「需要你」的顺序用一个事件计数器 `_seq`（每次断开、每次设备转离线 +1），新的在前；不用时钟 | 规格 "按发生时间新的在前"；计数器在 fake_async 下确定 | 无 |
| R18 | 「需要你」按钮：≥ 48px，一盏灯 + 等宽数字（JetBrains Mono 14px、600，顶栏放不下 30px 计数格）；有已断开会话时灯是已断开、边框 `--accent`、底纹斜条纹；只有掉线设备时灯是离线、底纹点阵；为 0 时活动灯、无数字、无底纹。不闪。只要有 hub 就显示（Linux/Windows 上只会有离线设备） | 设计语言 §2、§3 状态计数规则落到顶栏控件；§0 第 2 条 | 想要 30px 计数要加高顶栏 |
| R19 | 「需要你」浮层：最多 3 行，第 4 行起合成「还有 N 件」；会话行动作 `RappButton.accent('重连')`，设备行 `RappButton.secondary('查看')`（打开设备面板、选中它、立刻探一次）；点了动作浮层就收（主界面规格 §5.3 选了就收），重连**不**改当前选中的会话 | 主界面规格 §3.6 | 无 |
| R20 | 右上角浮层互斥由 `MainState.corner`（`Corner.stream` / `Corner.needs` / null）管，`StreamMenuAnchor` 改成受控（`open`、`onToggle`、`onClose`）；当前会话变了，串流菜单自动收。Esc（焦点不在画面上时）顺序：先收右上角浮层，再收面板，再退全屏 | 主界面规格 §5 第 2 条；Esc 规则沿用 S1 | 无 |
| R21 | 已断开时串流菜单只剩第 6 组「会话」：`路径 <路径> · 已断开`、「重连」、「结束会话」；分离、放左上角不显示；档位等 1–5 组和 A 的菜单不显示（死会话上改档位没有对象） | 规格 §2.6 | 想在断开时预改档位，要把选择存到记录上再显示 1–4 组 |
| R22 | 会话行：第一行右侧加状态文字 `Key('session-status-<key>')`：活动 → `formatRate(bytes)`，空闲 → 「空闲」，连接中 → 「连接中」；已断开时第二行换成原因（`已断开：<原因>`），右侧不写。只有嵌入会话有数据，非嵌入行不变 | 规格 §2.3 "在状态文字的位置显示流量数字" | 无 |
| R23 | 数字格式沿用 S2 的 `formatRate`（`48.0 KB/s`，KB = 1000 B），不改成规格例子里的 `48 KB/s`；电平用现成 `levelBars`（0 / 5000 / 15000 / 40000 / 100000，已按设计语言实现并有测试） | 和 `RappCore.formatRate` 一致；规格 §6 第 6 条 | 改一个函数 |
| R24 | 总流量 = 所有活动（`Phase.live`）记录的 `bytesPerSecond` 之和，`formatRate` 显示，为 0 时用 `--muted`；没有 `SessionPort`（Linux/Windows）照旧「—」 | 规格 §2.3 | 无 |
| R25 | 已断开的舞台不接受输入（没有 `Listener`、不抢焦点）；没有最后一帧（第一次就没连上）时只铺条纹和按钮 | 死会话收不了点击 | 无 |

## Global Constraints

**安全规则（每个实现者都受约束，原文照录；topat 一条按 lessons 改成按 PID 的版本）：**
- Only start/stop processes you launched, by PID. Never killall/pkill or address processes by name in AppleScript/System Events.
- Never touch /Applications/rapp.app, the running rapp-service, ~/Library/Logs/rapp, the user's real config dir, the keychain, or the system clipboard. Tests use temp dirs and ephemeral ports; never ports 47800 or 21116–21119.
- Synthetic clicks only after `topatp X Y <pid>` (scratchpad `s2live/topatp`, checks the owning PID) shows your own GUI's PID at that point — **not** the name-based `topat`; keystrokes only after verifying your app is frontmost by PID. Screenshots only of your own windows (`screencapture -l <id>`).
- Don't modify text in the user's documents; never touch the user's apps.
- No push, no merge, no subagents.

**S3 另加：**
- 实机检查（Task 7）只在用户同意把这台 Mac 让出来一段时间之后做；用户在用就停下，写"待实机"，不反复把自己的窗口提到前面（lessons）。只用自己起的 relay/service/host/hub/GUI 和自己拉起的 app，一律按 PID 操作和收尾。
- 不碰系统剪贴板：Swift 测试只用具名 `NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))`，`tearDown` 里 `releaseGlobally()`；Dart 测试用 `FakeSessionPort`、`FakeTransport`；实机检查不点剪贴板条目、不按「复制」「插入」、不 ⌘V。
- 日志不记密码、token、键入内容、剪贴板内容。`presence` 不记逐次日志；`closed` 行的 `reason` 只会是固定词（`user`、`quit`、`connection closed`、`GUI did not connect`）。
- 线程：每个 `EmbeddedSession` 跑在自己的串行队列上（连接回调、解码、计数都在队列上）；界面对象（`FlutterTexture` 注册、窗口、`TransferQueue`）只在主线程；值在两者之间显式 hop（`run {}` 进队列，`DispatchQueue.main.async` 出队列）。
- 安全姿态（用户定的）：自建 relay 是唯一门禁，性能优先于安全；不加额外加密层、审批步骤或确认弹窗（「结束会话」点两次是设计语言的不可撤销规则，不算审批）。

**测试与命令：**
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`（起点：S2 结束时全绿）。
- Rust：`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`。**不跑 `cargo fmt`**；新 Rust 文件只用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <文件>`。
- Swift：仓库根目录 `swift test`；交任务前跑 `./scripts/check.sh`，`.build-logs/check.log` 末行 `EXIT=0`。
- runner 编译检查：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`。
- 提交信息末尾：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。每个 Task 一个提交；**只** `git add <路径>`（不用 `-u`/`-A`/`.`）；不 `stash`、`checkout`、`restore`、`reset`（用户可能同时在改文件）；不 push、不 merge、不换分支（`feat/main-window-s2-s6`）。

**代码规则（沿用 S2）：**
- 远程数据路径上不准有 `precondition`、`fatalError`、`try!`、强制解包、越界下标；坏数据只让**这一个**会话断开（R3）。
- 纹理只在 `init` 之后注册；**结束**时先注销全部纹理再发 `closed`；**断开**时不注销（R3）。
- runner 只做胶水：事件编码、参数解析在 `RappSession` 里是纯函数并有测试；状态机、原因词表、计数、排序是纯 Dart 并有测试。
- 浮层只盖不挤（「需要你」浮层、已断开的舞台都不改舞台尺寸，不触发 A 的 resize）；选了就收；不可撤销操作点两次、3 秒复原（`ConfirmButton`）；不靠悬停和右键。
- 组件只用 `RappTokens`；可点控件高度 ≥ 48px；状态词只用设计语言 §9 词表（连接中、活动、空闲、已断开、已结束；在线、离线；断开、重连、结束会话）。"断开"和"结束"不混用。
- 设计语言 §0 三条检查，每个 UI 任务交付前对一遍：① 信息在指定的层（灯、计数、流量在边缘；已断开的画面在舞台）；② 断开、掉线只改灯、计数和底纹，不弹窗、不抢焦点、不自动打开浮层，已断开用 `--accent` 但不闪；③ 重连成功、设备回到在线、结束会话后，条纹、计数、浮层里的行自己消失，没有"已处理"一类要再点的东西。

## Review Focus

1. **重连和结束、旧 sid 的迟到事件交错**：重连中点结束，新 sid 回来后要安静关掉、不 `start`、只一条提示；旧 sid 的 `closed` 在重连后才到，不能把新会话删掉。测试：Task 4 `end during reconnect closes the new sid quietly`、`old sid closed after reconnect is ignored`。
2. **死 sid 漏到 hub 或 runner**：断开后 1 fps 策略、`detached` 回调、切会话都不能对死 sid 发 `set_stream`、`note`、`focus`，不出 `unknown sid` 提示。测试：Task 4 `a dead sid never reaches the hub or the runner`、`attach after the hub dropped the session sends no note`。
3. **分离中的会话断开**：先 `disconnected` 后 `detached {false}`；舞台显示已断开的最后一帧，不发 `note`。测试：Task 2 `testLinkDropDisconnectsAndKeepsLastFrame`（Swift，画面不释放），Task 4 `detached session disconnecting comes back to the stage`。
4. **在线探测和手动探测打架、计数跳动**：`presence` 不覆盖正在跑的手动探测；手动探测那一下的转灯不让「需要你」变化；从没在线过的设备不计数。测试：Task 6 `presence skips a probe in flight`、`a manual probe does not flicker the needs count`、`a device never seen online is not counted`；Task 3 `presence_reports_online_then_offline`（Rust）。
5. **侧连接下载让"空闲"判断失灵**：下载文件时字节在涨但画面没动，10 秒后仍应是空闲；流量数字照算。测试：Task 1 `side bytes alone do not keep a session active`（Dart），Task 2 `testSideBytesCountAsTraffic`（Swift）。

---

### Task 1: 生命周期模型和断开原因（纯 Dart）

**Files:**
- Create: `gui/lib/ui/lifecycle.dart`
- Modify: `gui/lib/embed/session_port.dart`（`TrafficEvent` 加 `frames`；新 `DisconnectedEvent`；`parseSessionEvent` 认 `disconnected`）、`gui/lib/embed/remote_session.dart`（空闲、`preferWindow`）
- Test: `gui/test/ui/lifecycle_test.dart`（新）、`gui/test/embed/remote_session_test.dart`、`gui/test/embed/session_port_test.dart`

**Interfaces:**
- Consumes: S2 的 `SessionEvent`、`RemoteSession`、`StreamChoice`/`startChoice`、`Lamp`、`hubWord`（`main_state.dart`，若被 `lifecycle.dart` 引用造成循环依赖，就把 `hubWord` 挪进 `lifecycle.dart` 并在 `main_state.dart` 里 re-export）。
- Produces:
  - `class TrafficEvent extends SessionEvent { const TrafficEvent(super.sid, this.bytes, [this.frames = 0]); final int bytes; final int frames; }`（现有 5 处 `TrafficEvent(` 调用不用改）；解析 `{'event':'traffic','sid','bytes','frames'}`，缺 `frames` 记 0。
  - `class DisconnectedEvent extends SessionEvent { const DisconnectedEvent(super.sid, this.reason); final String reason; }`；解析 `{'event':'disconnected','sid','reason'}`，缺 `reason` 记 `''`。
  - `remote_session.dart`：`const idleAfter = 10;`；`RemoteSession` 加 `bool sawFrame`、`int quietSeconds`、`bool get idle => sawFrame && quietSeconds >= idleAfter`、`void preferWindow(int? id)`（设 S2 已有的 `_pendingCurrent`）。`apply(TrafficEvent)`：`bytesPerSecond = e.bytes`；`frames > 0` → `sawFrame = true; quietSeconds = 0`，否则 `sawFrame` 时 `quietSeconds++`。
  - `lifecycle.dart`：
    - `enum Phase { connecting, live, disconnected }`
    - `class SessionRecord { SessionRecord(this.id, this.app, this.appName, this.path); final String id; final String app; String appName; String path; Phase phase = Phase.connecting; Object? sid; Object? lastSid; String? reason; int seq = 0; bool userDisconnect = false; bool ending = false; StreamChoice choice = startChoice; int? window; String get key => '$id/$app'; }`
      - `sid`：现在连着（或正在连）的 hub sid；`lastSid`：重连期间留着最后一帧的旧 sid（R10）；`ending`：重连中被结束（R14）。
    - `String disconnectWord(String? raw)`（R8 的顺序表，原样照录短语）。
    - `Lamp recordLamp(SessionRecord r, RemoteSession? rs)`：`disconnected` → `Lamp.disconnected`；`connecting` → `Lamp.connecting`；`live`：`rs == null || !rs.sawFrame` → `Lamp.connecting`，`rs.idle` → `Lamp.idle`，否则 `Lamp.active`。

- [ ] **Step 1: 写失败的测试**

```dart
// lifecycle_test.dart
test('disconnect words', () {
  expect(disconnectWord('user'), '你断开了');
  expect(disconnectWord('host says: Calculator quit'), 'A 端关闭了 app');
  expect(disconnectWord('bad password'), '密码不对');
  expect(disconnectWord('offline'), '对方离线');
  expect(disconnectWord('no path to 111'), '对方离线');
  expect(disconnectWord('relay unreachable and no LAN address answered'), '对方离线');
  expect(disconnectWord('connect 10.0.0.2:21118: timed out'), '连接超时');
  expect(disconnectWord('no reply'), '连接超时');
  expect(disconnectWord('connection closed'), '网络断了');
  expect(disconnectWord('the host closed the connection'), '网络断了');
  expect(disconnectWord('connection error: POSIX 54'), '网络断了');
  expect(disconnectWord('cannot reach 127.0.0.1:5001 (refused)'), '网络断了');
  expect(disconnectWord('GUI did not connect'), '本机没有接上会话');
  expect(disconnectWord('cannot decode frame: bad tile'), 'cannot decode frame: bad tile');
  expect(disconnectWord('host says: window gone'), 'window gone');
});
test('record lamps', () {
  final r = SessionRecord('111', 'a', 'Calculator', 'lan');
  expect(recordLamp(r, null), Lamp.connecting);
  r.phase = Phase.live; final rs = RemoteSession(1, 'Calculator');
  expect(recordLamp(r, rs), Lamp.connecting);          // live but no frame yet (R1)
  rs.apply(const TrafficEvent(1, 5000, 2)); expect(recordLamp(r, rs), Lamp.active);
  r.phase = Phase.disconnected; expect(recordLamp(r, rs), Lamp.disconnected);
});
```
`remote_session_test.dart`：
- `ten quiet ticks make a session idle, one frame wakes it`：`apply(TrafficEvent(1, 900, 1))`，再 9 次 `TrafficEvent(1, 0, 0)` → `idle == false`，第 10 次 → `true`；`TrafficEvent(1, 10, 1)` → `false`，`quietSeconds == 0`。
- `no frame yet is never idle`：20 次 `TrafficEvent(1, 0, 0)` → `idle == false`，`sawFrame == false`。
- `side bytes alone do not keep a session active`（Review Focus 5）：一帧之后 10 次 `TrafficEvent(1, 80000, 0)` → `idle == true`，`bytesPerSecond == 80000`。
- `preferWindow picks that window when the table brings it`：`preferWindow(7)`，`apply(WindowsEvent(1, [普通窗口 3, 普通窗口 7]))` → `currentWindow == 7`；`preferWindow(9)` 后同一张表 → 落回 S2 规则（`3`）。

`session_port_test.dart`：`parses traffic frames and disconnected`：`{'event':'traffic','sid':1,'bytes':10,'frames':3}` → `TrafficEvent` 的 `frames == 3`；没 `frames` → 0；`{'event':'disconnected','sid':1,'reason':'connection closed'}` → `DisconnectedEvent` 的 `reason == 'connection closed'`。

- [ ] **Step 2: 跑测试确认失败** — `cd gui && $HOME/development/flutter/bin/flutter test test/ui/lifecycle_test.dart test/embed/remote_session_test.dart test/embed/session_port_test.dart` → 编译失败（`disconnectWord`、`DisconnectedEvent` 未定义）。
- [ ] **Step 3: 实现** 上面 Interfaces 里的类型和函数。`disconnectWord` 先判 `null`/空串 → `hubWord(raw)` 的结果。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/lifecycle.dart gui/lib/embed/session_port.dart gui/lib/embed/remote_session.dart gui/test/ui/lifecycle_test.dart gui/test/embed/remote_session_test.dart gui/test/embed/session_port_test.dart`（若挪了 `hubWord` 再加 `gui/lib/ui/main_state.dart`），`feat(gui): session lifecycle model, idle detection and disconnect words`

---

### Task 2: runner：断开保留画面、流量带帧数和侧连接字节、分离中断开自动放回

**Files:**
- Modify: `Sources/RappSession/EmbeddedSession.swift`、`Sources/RappSession/SessionEvent.swift`、`Sources/RappSession/Channel.swift`、`Sources/RappSession/Transfers.swift`（`TransferQueue.onBytes`）、`gui/macos/Runner/SessionPlugin.swift`
- Test: `Tests/RappSessionTests/EmbeddedSessionTests.swift`、`Tests/RappSessionTests/ChannelTests.swift`

**Interfaces:**
- Consumes: S2 的 `EmbeddedSession`、`MessageLink`、`WindowSurfaces`、`TransferQueue`、`eventPayload`、`SessionPlugin.deliver/attachSession`。
- Produces（channel 协议，Task 4 的 Dart 依赖它）：
  - `SessionEvent.traffic(bytesPerSecond: Int, frames: Int)`；`SessionEvent.disconnected(reason: String)`。
  - `eventPayload`：`.traffic` → `("traffic", ["bytes": n, "frames": f])`；`.disconnected` → `("disconnected", ["reason": r])`。
  - 事件顺序：一个会话最多一次 `disconnected`；之后可能还有一次 `closed`（Dart 调 `close` 或关独立窗口时）；`closed` 之前不会有 `disconnected` 以外的事件丢失。分离中的会话：`disconnected` 一定先于随后的 `detached {detached:false}`。
  - `TransferQueue.onBytes: ((Int) -> Void)?`（主线程调用，只在下载收到数据块时调用）。

- [ ] **Step 1: 写失败的测试**（改 S2 的四条，加四条）

```swift
// 改：坏帧、host 报错现在是断开，画面留着
func testBadFrameEndsOnlyThatSession()      // 断言改为：坏的那个收到一次 .disconnected(reason: 以 "cannot decode frame:" 开头)，没有 .closed；另一个照常出 .surfaces
func testHostErrorClosesWithReason()        // events.last == .disconnected(reason: "host says: Calculator quit")；surfaces.latest(7) != nil
func testTrafficTicksAndResets()            // [.traffic(bytesPerSecond: 2000, frames: 0), .traffic(bytesPerSecond: 0, frames: 0)]
// testCloseUnregistersSurfacesOnceAndReportsOnce 不改：close 两次再 drop → 只有一次 .closed("quit")，没有 .disconnected，latest(7) == nil

// 新
func testLinkDropDisconnectsAndKeepsLastFrame() {
  // feed 一帧（窗口 7）→ link.drop(reason: "the host closed the connection")
  // events 末尾恰好一个 .disconnected(reason: "the host closed the connection")，没有 .closed；surfaces.latest(7) != nil
  // 再 session.close() → 恰好一个 .closed(reason: "quit")；latest(7) == nil；再 close() 不再出事件
}
func testTrafficCountsFrames()      // feed 3 帧后 tickTraffic → .traffic(bytesPerSecond: >0, frames: 3)；再 tick → frames: 0
func testNoTrafficAfterDisconnect() // link.drop 后 tickTraffic → 没有新的 .traffic
func testSideBytesCountAsTraffic()  // 主线程 session.transfers.onBytes?(4096)，等队列 → tickTraffic → .traffic(bytesPerSecond: 4096, frames: 0)
// Channel
func testDisconnectedPayload()      // eventPayload(.disconnected(reason: "x"), sid: 3, textures: …) → ("disconnected", ["reason": "x"])
func testTrafficPayloadCarriesFrames() // .traffic(bytesPerSecond: 10, frames: 2) → ("traffic", ["bytes": 10, "frames": 2])
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter RappSessionTests` → 编译失败（`.disconnected`、`frames:` 不存在）。
- [ ] **Step 3: 实现**
  - `EmbeddedSession`：把 `closed` 拆成队列上的两个标志 `linkDown`、`released`，加队列上的 `frames` 计数。
    - 私有 `disconnect(reason:)`（`link.onClosed`、坏帧、`.error` 都走它）：`linkDown` 已真就返回；置真、`link.cancel()`、主线程 `transfers.cancel()`、发 `.disconnected(reason:)`；**不** `surfaces.keep(only: [])`。
    - `close(reason: String = "quit")`：`released` 已真就返回；置真；若 `!linkDown` 先置真、`link.cancel()`、主线程 `transfers.cancel()`；`surfaces.keep(only: [])`；发 `.closed(reason:)`。
    - `.frame` 解码画好之后 `frames += 1`；`tickTraffic()` 在 `!linkDown` 时发 `.traffic(bytesPerSecond: bytes, frames: frames)` 后两者清零。`post(_:)` 改看 `linkDown`。
    - `start()` 里（主线程）设 `transfers.onBytes = { [weak self] n in self?.run { self?.bytes += n } }`。
  - `TransferQueue.downloadChunk(_:_:)`：写盘前 `onBytes?(bytes.count)`。
  - `SessionPlugin.deliver` 加 `.disconnected` 分支：照 `.closed` 分支 `panels.removeValue(forKey: sid)?.cancel(nil)`、`keysHolder == sid` 时 `keys.releaseAll()` 并置 nil、`focusedSid == sid` 时置 nil；**不**注销纹理、**不**清 `live[sid]`；先 `channel.invokeMethod` 发 `disconnected` 载荷，再在 `detached[sid] != nil` 时 `attachSession(sid)`（R13；它会关独立窗口、必要时把主窗口设为 key、发 `detached {false}`）。`.closed` 分支不变。
- [ ] **Step 4: 跑测试确认通过** — `swift test` 全绿；`./scripts/check.sh` 末行 `EXIT=0`；`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug` 成功。
- [ ] **Step 5: Commit** — `git add Sources/RappSession/EmbeddedSession.swift Sources/RappSession/SessionEvent.swift Sources/RappSession/Channel.swift Sources/RappSession/Transfers.swift gui/macos/Runner/SessionPlugin.swift Tests/RappSessionTests/EmbeddedSessionTests.swift Tests/RappSessionTests/ChannelTests.swift`，`feat(session): disconnect keeps the last frame; traffic counts frames and side bytes`

---

### Task 3: hub：`close` 带 `user`、`open` 带 `reconnect`、30 秒在线探测；`HubClient` 跟上

**Files:**
- Create: `rust/hub/src/presence.rs`（新文件，用上面的 rustfmt 命令格式化）
- Modify: `rust/net/src/msg.rs`（`Op::Ping`，序列化成 `{"op":"ping"}`，和现有 `Op` 的 serde 写法一致）、`rust/service/src/peer.rs`（`serve_request` 里 `Op::Ping` → `reply_and_finish(ok(json!({})))`，**不调 `log_request`**）
- Modify: `rust/hub/src/lib.rs`（`Opts.presence_every`、`Hub.close_why`、`dispatch` 的 `close`/`open`、`run()` 里起停探测）、`rust/hub/src/session.rs`（`close`、`run_embedded`、`finish_session`、`log_opened`）、`rust/hub/src/hosts.rs`（`all()`）、`rust/hub/src/main.rs`、`rust/testkit/tests/common/mod.rs`、`gui/lib/hub_client.dart`
- Test: `rust/testkit/tests/hub.rs`、`gui/test/hub_client_test.dart`

**Interfaces:**
- Consumes: `Hub::request(&host, &Op::Ping)`（本 Task 新加的 `Op`）、`Hub::emit`、`finish_session`、`log_opened`、testkit `Hub::start`、`hub_with_host`、`embed_open`、`gui_connect`、`service(relay)`、`TestService.svc.stop()`、`read_log`、`WAIT`。
- Produces（hub 协议）：
  - `{"cmd":"close","sid":n,"reason":"user"}`：只接受 `"user"`，其他值 → `error` 事件 `bad reason`（会话不受影响）；不带 `reason` 同今天。嵌入会话因此结束时 `closed` 事件和日志 `reason` 为 `"user"`；S1 `rapp-client` 会话忽略 `reason`。
  - `{"cmd":"open",…,"embed":true,"reconnect":true}`：行为同 `embed`，`opened` 日志行多 `"reconnect":true`（不带时不写这个键）；`opened` 事件不变。
  - `{"event":"presence","id":"<id>","online":true|false}`：`presence_every` 为 `Some(d)` 时，每 `d` 一轮，按 `Hosts::all()` 的顺序串行探测，每台一条；stdin 结束时停。
  - Rust：`pub struct Opts { …, pub presence_every: Option<Duration> }`；`Hosts::all(&self) -> Vec<Host>`；`Hub.close_why: Mutex<HashMap<u64, String>>`；`pub fn close(&self, sid: u64, why: Option<&str>) -> Result<()>`；`log_opened(sid, id, app, path, reconnect: bool)`。
  - testkit：`Hub::start` 的 `Opts` 填 `presence_every: None`；新 `Hub::start_with_presence(home, bins, relay, force, every: Duration)`（或给 `start` 加一个参数，所有调用处补 `None`——二选一，取改动少的）。
  - Dart：`void close(Object sid, {String? reason})`；`Future<HubSession> open(String id, String app, {bool embed = false, bool reconnect = false})`（`reconnect` 为真才带键）；`List<({String id, bool online})> takePresence()`（取走并清空）；`_onLine` 收到 `presence` 就排进队列（不匹配任何请求，照常 `notifyListeners`）。

- [ ] **Step 1: 写失败的测试**

`rust/testkit/tests/hub.rs`：
- `embed_close_with_user_reason`：`embed_open` → `gui_connect` → 发 `{"cmd":"close","sid":sid,"reason":"user"}` → 下一个事件 `closed`，`reason == "user"`；GUI 那端 TCP 在 `WAIT` 内读到 EOF；`read_log(home,"hub.log")` 里 `closed` 行 `"reason":"user"`。
- `close_with_bad_reason_is_an_error`：`reason:"nope"` → `error` 事件含 `bad reason`；再发不带 `reason` 的 `close` → `closed` `reason == "quit"`。
- `reconnect_open_is_logged`：带 `"reconnect":true` 的嵌入 `open` → `opened`；日志里这一行有 `"reconnect":true`；之前一次普通嵌入 `open` 的 `opened` 行没有 `reconnect` 键。
- `presence_reports_online_then_offline`：用 200 ms 间隔的 hub 加一台设备 → 等到 `{"event":"presence","id":a.id,"online":true}`；`a.svc.stop()` → `WAIT` 内等到同一 id 的 `online:false`；没有 `error` 事件。
- `ping_is_answered_and_not_logged`：起一台 service，hub 用 200 ms 间隔探测，等到 `online:true` 两次；读 A 的 service 日志（testkit 现有读日志的办法）→ 没有 `"op":"ping"` 的 `request` 行，也没有 `list_apps` 行。
- `presence.rs` 单元测试 `unknown_op_counts_as_online`：`online(&Ok(()))` 真；`online(&Err(anyhow!("unknown op")))` 真；`online(&Err(anyhow!("offline")))`、`online(&Err(anyhow!("timed out")))` 假。
- `no_presence_without_interval`：普通 `hub_with_host`，等 500 ms，`finish()` 返回的事件里没有 `presence`（现有测试的 `finish()` 断言照旧通过）。

`gui/test/hub_client_test.dart`：
- `close carries reason user`：`hub.close(3, reason: 'user')` → `t.sent.last` 等于 `{'cmd':'close','sid':3,'reason':'user'}`；`hub.close(4)` → 没有 `reason` 键。
- `open marks reconnect`：`open('111','a', embed: true, reconnect: true)` → 发出的命令 `reconnect == true`；不带时没有这个键。
- `presence is queued and drained`：emit 两条 `presence` → `takePresence()` 依次是 `(id:'111', online:true)`、`(id:'222', online:false)`；再调为空；期间正在等的 `apps` 请求没被它们完成。

- [ ] **Step 2: 跑测试确认失败** — `cd rust && cargo test -p rapp-testkit --test hub` → 新测试失败（`bad reason` 不存在、没有 `presence`）；`flutter test test/hub_client_test.dart` → 编译失败。
- [ ] **Step 3: 实现**
  - `dispatch` 的 `close`：读可选 `reason`，不是 `"user"` 就 `bail!("bad reason")`；调 `close(sid, why)`，`why` 为 `Some` 时先放进 `close_why` 再取走 `tx`。
  - `run_embedded`：两处"`rx` 关了"的分支（accept 前、splice 中）原因改为 `self.close_why.lock().unwrap().remove(&sid).unwrap_or_else(|| "quit".into())`；`finish_session` 末尾也 `remove(&sid)` 清残留。
  - `presence.rs`：`pub(crate) async fn run(hub: Arc<Hub>, every: Duration)`：`tokio::time::interval(every)`，`MissedTickBehavior::Delay`，每轮 `for host in hub.hosts.all()`：`let online = presence::online(&hub.request(&host, &Op::Ping).await);`，其中 `pub(crate) fn online<T>(r: &anyhow::Result<T>) -> bool` = `Ok` 为真；`Err(e)` 且 `e.to_string() == "unknown op"` 为真；其余为假 → `hub.emit(json!({"event":"presence","id":host.id,"online":online}), &None).await`。`run()` 在读 stdin 前 `spawn`，stdin 结束后 `abort()` 再 `close_all`。
  - `main.rs`：`presence_every: Some(Duration::from_secs(30))`。
  - `HubClient`：照 Interfaces。
- [ ] **Step 4: 跑测试确认通过** — `cargo test --workspace && cargo clippy --workspace --all-targets` 全绿无警告；`flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add rust/net/src/msg.rs rust/service/src/peer.rs rust/hub/src/presence.rs rust/hub/src/lib.rs rust/hub/src/session.rs rust/hub/src/hosts.rs rust/hub/src/main.rs rust/testkit/tests/common/mod.rs rust/testkit/tests/hub.rs gui/lib/hub_client.dart gui/test/hub_client_test.dart`，`feat(hub): close reason user, reconnect flag, 30 s presence probe`

---

### Task 4: `MainState` 按记录管嵌入会话：断开、重连、结束、合并

**Files:**
- Modify: `gui/lib/ui/main_state.dart`、`gui/lib/ui/session_model.dart`
- Test: `gui/test/ui/main_state_test.dart`（`group('embedded sessions')`）

**Interfaces:**
- Consumes: Task 1（`SessionRecord`、`Phase`、`disconnectWord`、`recordLamp`、`DisconnectedEvent`、`TrafficEvent.frames`、`RemoteSession.preferWindow`）；Task 3（`HubClient.close(reason:)`、`open(reconnect:)`）。
- Produces（Task 5、6 用）：
  - `SessionEntry` 加可选命名参数 `int? bytesPerSecond`、`String? reason`（默认 null）；嵌入会话的条目从记录生成：`lamp = recordLamp(r, rs)`，`bytesPerSecond` 只在 `live` 时有，`reason = disconnectWord(...)` 只在 `disconnected` 时有。每个 `TrafficEvent` 重建条目。
  - `SessionRecord? recordFor(String key)`；`SessionRecord? get currentRecord`；`bool get currentDisconnected`。
  - `RemoteSession? get currentRemote`：当前记录 `live` → 它的 `sid` 的 rs；`disconnected` → `sid` 的 rs（最后一帧）；重连中 → `lastSid` 的 rs。
  - `void disconnectCurrent()`：仅当前记录 `live` 且 `hub.sessions` 里有它的 sid 时：`userDisconnect = true`，`hub.close(sid, reason: 'user')`。
  - `Future<void> reconnect(String key)`、`void reconnectCurrent()`：仅 `disconnected` 且 `hubUsable`。
  - `int get totalBytesPerSecond`（R24）。
  - `int get disconnectedCount`（Task 6 用）。
  - 非嵌入（`port == null`）路径一行不改。

行为（照 R9–R15）：
- `openOrSwitch`（嵌入）：已有记录 → `disconnected` 就 `reconnect(key)`，否则只切 `currentKey`（分离着就 `raiseDetached`，同 S2）；没有 → 新记录（`connecting`），`currentKey` 指向它，`_connect(r)`。
- `_connect(r, {bool reconnect = false})`：`hub.open(id, app, embed: true, reconnect: reconnect)`；`r.ending` 已真 → `_quiet.add(sid)`、`hub.close(sid)`、返回（R14）；否则 `r.sid = sid`、建 `RemoteSession`、`rs.preferWindow(r.window)`、`port.start(StartArgs(sid, port, token, r.choice.mode, r.choice.fps, r.choice.density))`、`phase = live`。`open` 或 `start` 抛错 → `start` 失败的先 `_quiet.add(sid)`、`hub.close(sid)`；然后 `_disconnect(r, '$e', hint: true)`；重连失败时把 `lastSid` 还给 `sid`（旧画面还在）。
- `_disconnect(r, raw, {bool hint = false})`：`phase = disconnected`，`reason = r.userDisconnect ? 'user' : raw`，`seq = ++_seq`，存 `r.choice = rs.choice`、`r.window = rs.currentWindow`，`rs.bytesPerSecond = 0`，`_sentFps.remove(sid)`，取消 `_waiting[sid]`；画面有焦点且是这个 sid → `blurPicture()`；`hint` 为真才出 `'${r.appName} 已断开：${disconnectWord(reason)}'`。不改 `currentKey`，不开浮层。
- `DisconnectedEvent(sid)`：sid 是某记录的 `sid` 且 `live` → `_disconnect`；别的忽略。
- `ClosedEvent(sid)`：sid 是某记录的 `lastSid` → 只 `remote.remove(sid)?.dispose()`；是某记录的 `sid` 且 `live` → 删记录、S2 的提示和 `currentKey` 步进（`endedHint`）；别的忽略（已删的已断开记录、`_quiet`）。
- hub 那边 sid 消失、记录 `live`：`_waiting` 1 秒等 `DisconnectedEvent`，到期 `_disconnect(r, hub 原因 ?? 'rapp-hub exited')`；不 `port.close`（R15）。
- `reconnect(key)`：`r.lastSid = r.sid; r.sid = null; r.phase = connecting; r.userDisconnect = false; r.reason = null;` `_connect(r, reconnect: true)`；`currentKey` 不变。新 rs 第一次 `WindowsEvent` 带出有纹理的窗口时 `_swapIfReady(r)`：`port.close(lastSid)`（之后它的 `ClosedEvent` 按上面忽略）、`lastSid = null`。
- `endCurrent`（嵌入）：`live` → 同 S2；`disconnected` → `port.close(sid)`、删记录、提示「已结束 X」、步进；`connecting` 且有 `lastSid` → `port.close(lastSid)`、`r.ending = true`、删记录、提示、步进。
- `_applyFps` 和 `DetachedEvent` 的 `hub.note` 只对 `live` 且 sid 在 `hub.sessions` 里的记录（R12）。

- [ ] **Step 1: 写失败的测试**（`fake_async`；先改 `env` 的假 opener：`reconnect == true` 的 `open` 回 `sid = app.length + 10 * 第几次重连`、`port = 5000 + sid`，普通 `open` 照旧 `sid = app.length`。测试里要让 `open` 失败或挂起时临时换 `t.onSend`。比较 `port.calls` 时用 `.$1`/`.$2` 加 `equals`，不直接比 record。）

```dart
test('first frame makes the lamp active, ten quiet seconds make it idle', ...);
  // TrafficEvent(1, 900, 0) → entries.first.lamp == Lamp.connecting；TrafficEvent(1, 5000, 2) → Lamp.active, bytesPerSecond 5000
  // 10× TrafficEvent(1, 0, 0) → Lamp.idle；TrafficEvent(1, 10, 1) → Lamp.active
test('link drop keeps the entry disconnected with a reason', ...);
  // DisconnectedEvent(1, 'the host closed the connection') → sessionCount 1，lamp disconnected，reason '网络断了'，
  // currentKey '111/a'，hints 为空，port.calls 里没有 'close'，remote.containsKey(1)
test('A quitting the app reads A 端关闭了 app', ...);   // DisconnectedEvent(1, 'host says: Calculator quit') → reason 'A 端关闭了 app'
test('disconnect sends close with reason user and reads 你断开了', ...);
  // st.disconnectCurrent() → t.sent.last == {'cmd':'close','sid':1,'reason':'user'}
  // t.emit closed reason 'user'；elapse 200 ms；DisconnectedEvent(1, 'the host closed the connection') → reason '你断开了'；没有 port 'close'
test('hub closed first, runner silent: disconnected after 1 s with the hub reason', ...);
  // 替换 S2 的 'hub closed first' 和 'hub closed and runner silent…'
  // t.emit closed 'connection closed' → elapse 999 ms → 仍 live；再 1 ms → disconnected，reason '网络断了'；没有 port 'close'；hints 为空
test('runner closed first', ...);           // 改：ClosedEvent(1, 'quit')（结束路径）→ sessionCount 0，hint '已结束 Calculator'；之后 hub closed → hints.length 1
test('decode error disconnects one session, keeps the other', ...);
  // 改名自 S2 的 'decode error ends one session…'：sessions: 2，当前 '111/a'；DisconnectedEvent(1, 'cannot decode frame: bad tile')
  // → 记录 1 disconnected，reason 'cannot decode frame: bad tile'，currentKey 不变，remote.containsKey(2)，hints 为空
test('start failure closes the hub session quietly and stays disconnected', ...);
  // 改：port.startError = 'boom' → t.sent 里有 {'cmd':'close','sid':1}；记录 disconnected，reason 'boom'；hints == ['Calculator 已断开：boom']
test('first open failure stays as a disconnected entry', ...);
  // open 回 error 'bad password' → sessionCount 1，lamp disconnected，reason '密码不对'，currentKey '111/a'，hints == ['Calculator 已断开：密码不对']
test('reconnect opens again with reconnect and keeps choice and window', ...);
  // rs.setChoice(StreamChoice('duogray','saver1x',5))；WindowsEvent(1, [窗口 3, 窗口 7])，选 7；DisconnectedEvent(1, 'connection closed')
  // st.reconnect('111/a') → open 命令 embed true、reconnect true；start 的 $2 equals {'sid':11,'port':5011,'token':'tk','mode':'duogray','fps':5,'density':'saver1x'}
  // currentKey '111/a'，sessionCount 1；还没有 ('close', {'sid':1})；WindowsEvent(11, [窗口 3, 窗口 7]) → remote[11].currentWindow == 7，
  // port.calls 里有 ('close', {'sid':1})，lamp connecting（没帧），TrafficEvent(11, 100, 1) → active
test('reconnect failure goes back to disconnected with the old frame', ...);
  // 重连的 open 回 error 'offline' → disconnected，reason '对方离线'，currentRemote.sid == 1，没有 ('close', {'sid':1})，hints == ['Calculator 已断开：对方离线']
test('opening a disconnected app reconnects it', ...);  // 断开后 openOrSwitch('111','a','Calculator') → 发出的 open 带 reconnect true
test('end a disconnected session removes it at once', ...);
  // 断开后 endCurrent → port.calls.last ('close', {'sid':1})，sessionCount 0，hints == ['已结束 Calculator']；之后 ClosedEvent(1,'quit') → hints 不变
test('end during reconnect closes the new sid quietly', ...);          // Review Focus 1
  // 断开 → reconnect（opener 挂起不回）→ endCurrent → sessionCount 0，有 ('close', {'sid':1})，hints == ['已结束 Calculator']
  // 现在回 opened sid 11 → t.sent.last == {'cmd':'close','sid':11}，没有 sid 11 的 'start'，hints 不变；之后 hub closed 11 → 无变化
test('old sid closed after reconnect is ignored', ...);                // Review Focus 1
  // 重连换画面后 ClosedEvent(1, 'quit') → sessionCount 1，lamp 不变，hints 为空
test('a dead sid never reaches the hub or the runner', ...);           // Review Focus 2
  // sessions: 2，当前 '111/aa'；DisconnectedEvent(1, …)；记下 t.sent/port.calls 长度
  // DetachedEvent(1, false) → t.sent 没有 note；st 切到 '111/a' 再切回 → port.calls 新增里没有 sid 1 的 'set_stream'；st.hint 为 null
test('attach after the hub dropped the session sends no note', ...);   // Review Focus 2：t.emit closed sid 1 后立刻 DetachedEvent(1, false) → 没有 note
test('detached session disconnecting comes back to the stage', ...);   // Review Focus 3
  // DetachedEvent(1, true) → DisconnectedEvent(1, 'connection closed') → DetachedEvent(1, false)
  // → remote[1].detached false，记录 disconnected，t.sent 里 note 只有 detach 那一条
test('total traffic sums live sessions only', ...);
  // sessions: 2；TrafficEvent(1, 3000, 1)，TrafficEvent(2, 2000, 1) → totalBytesPerSecond 5000；DisconnectedEvent(2, …) → 3000
test('hub exiting disconnects embedded sessions', ...);
  // transport 关闭（hub 退出）→ elapse 1 s → 记录 disconnected，reason == disconnectWord('rapp-hub exited')；reconnect 不发任何东西
```
`without a port the S1 path is unchanged` 和 `group('endedHint')` 不改，必须照样通过。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/main_state_test.dart` → 新测试失败。
- [ ] **Step 3: 实现** 照上面的行为。`_records` 用插入有序的 `Map<String, SessionRecord>`（key = `'$id/$app'`），会话顺序 = 插入顺序（重连不改位置）；`_mapEntries()` 在 `embeds` 时从 `_records` 生成，否则照旧。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/main_state.dart gui/lib/ui/session_model.dart gui/test/ui/main_state_test.dart`，`feat(gui): embedded sessions survive disconnects and reconnect in place`

---

### Task 5: 已断开的舞台、串流菜单「会话」组、会话行状态、总流量

**Files:**
- Create: `gui/lib/ui/disconnected_stage.dart`
- Modify: `gui/lib/ui/stage.dart`、`gui/lib/embed/stream_menu.dart`（`StreamMenu` 新参数）、`gui/lib/ui/top_bar.dart`（传参数）、`gui/lib/ui/sessions_tab.dart`、`gui/lib/ui/side_panel.dart`
- Test: `gui/test/ui/stage_test.dart`、`gui/test/embed/stream_menu_test.dart`、`gui/test/ui/side_panel_test.dart`

**Interfaces:**
- Consumes: Task 4（`currentRecord`、`currentRemote`、`currentDisconnected`、`disconnectCurrent`、`reconnectCurrent`、`totalBytesPerSecond`、`SessionEntry.bytesPerSecond/reason`）；S2 `fitRect`、`pictureRect`、`contentSize`（`geometry.dart`）、`rowBackdrop`、`StatusLamp`、`RappButton.accent`、`formatRate`。
- Produces:
  - `class DisconnectedStage extends StatelessWidget { const DisconnectedStage({super.key, required this.session, required this.reason, required this.connecting, this.onReconnect}); final RemoteSession? session; final String reason; final bool connecting; final VoidCallback? onReconnect; }`
    - 底层：`session?.currentWindow` 有纹理时按 Picture 的同一套 `fitRect`/`pictureRect` 放 `Texture`（不包 `Listener`、不要焦点，R25）；没有就空底。
    - 上面整块 `rowBackdrop(Lamp.disconnected, t)` 的斜条纹。
    - 居中一列：`connecting` → `StatusLamp(Lamp.connecting)` + 「正在连接」；否则 `RappButton.accent(key: Key('reconnect-button'), label: '重连', onPressed: onReconnect)`，下一行 `Text(reason, key: Key('disconnect-reason'))`。
  - `Stage` 分支：hub 有问题 → 没有当前会话 → **当前记录 `disconnected`，或 `connecting` 且有 `lastSid`** → `DisconnectedStage(session: state.currentRemote, reason: disconnectWord(r.reason), connecting: r.phase == Phase.connecting, onReconnect: state.hubUsable ? state.reconnectCurrent : null)` → S2 其余分支不变。
  - `StreamMenu` 加 `required String status`（`lampWord(entry.lamp)`）、`required bool disconnected`、`required VoidCallback onDisconnect`、`required VoidCallback onReconnect`；第 6 组：`'路径 $path · $status'`（不可点）；未断开：`ConfirmButton` 之外加 `_Item('断开', onDisconnect)`（一次点击，可逆）、分离/放回、放左上角、`ConfirmButton('结束会话')`；断开时整份菜单只有这一组：路径行、`_Item('重连', onReconnect)`、`ConfirmButton('结束会话')`（R21）。点「断开」「重连」后菜单收起（选了就收）。
  - `TopBar` 把 `status`、`disconnected: state.currentDisconnected`、`onDisconnect: state.disconnectCurrent`、`onReconnect: state.reconnectCurrent` 传进 `StreamMenuAnchor` → `StreamMenu`。
  - 会话行（R22）：第一行右侧 `Text(key: Key('session-status-${e.key}'), …)`，JetBrains Mono 12px，`--muted`；断开时第二行 `已断开：${e.reason}`。Semantics label 里带上这段状态文字。
  - 底部总览：`_Total('总流量', state.embeds ? formatRate(state.totalBytesPerSecond) : '—', const Key('total-traffic'), state.embeds && state.totalBytesPerSecond == 0)`。

- [ ] **Step 1: 写失败的测试**

`stage_test.dart`（`group('embedded')`，用现有 `rw`、`openEmbedded`、`embedded()`）：
- `disconnected shows the last frame, stripes and reconnect`：开会话、`WindowsEvent` 出纹理 42、`DisconnectedEvent(1, 'connection closed')` → `find.byWidgetPredicate((w) => w is Texture && w.textureId == 42)` 一个；`find.byKey(Key('reconnect-button'))` 一个；`Key('disconnect-reason')` 文本 `'网络断了'`；点按钮 → `t.sent.last['reconnect'] == true`。
- `disconnected picture takes no input`：点画面中心 → `port.calls` 里没有 `mouse`。
- `first-open failure shows reconnect without a frame`：`open` 回错 → 没有 `Texture`，有 `reconnect-button`。
- `reconnecting keeps the old frame with a connecting lamp`：重连 opener 挂起 → 还是纹理 42，有 `'正在连接'`，没有 `reconnect-button`。
- `reconnect is off when the hub is gone`：hub 退出后按钮的 `onPressed == null`。
- `overlays never resize`（S2）照样通过——已断开舞台不影响 `stageSize`。

`stream_menu_test.dart`：
- `session group shows status and disconnect`：`status: '活动'`、`path: '局域网'` → `find.text('路径 局域网 · 活动')`；点「断开」→ `onDisconnect` 调了一次，菜单收起。
- `disconnected menu keeps only the session group with reconnect`：`disconnected: true` → 有「重连」「结束会话」；没有「断开」「高彩（图像优化）」「分离成独立窗口」「放左上角」；点「重连」→ `onReconnect` 一次。

`side_panel_test.dart`：
- `session rows show rate, idle and reason`：三条嵌入会话（活动 48000 B/s、空闲、已断开 `host says: Calculator quit`）→ `Key('session-status-111/a')` 文本 `'48.0 KB/s'`；第二条 `'空闲'`；第三条行里有 `'已断开：A 端关闭了 app'`，它的 `session-status` 文本为空。
- `total traffic sums live sessions`：`Key('total-traffic')` 文本 `formatRate(5000)` 即 `'5.0 KB/s'`；全部断开后 `'0 KB/s'` 且颜色是 `t.muted`；无 port 时 `'—'`。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/stage_test.dart test/embed/stream_menu_test.dart test/ui/side_panel_test.dart`。
- [ ] **Step 3: 实现** 照 Interfaces；对一遍设计语言 §0 三条（见 Global Constraints）。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/disconnected_stage.dart gui/lib/ui/stage.dart gui/lib/embed/stream_menu.dart gui/lib/ui/top_bar.dart gui/lib/ui/sessions_tab.dart gui/lib/ui/side_panel.dart gui/test/ui/stage_test.dart gui/test/embed/stream_menu_test.dart gui/test/ui/side_panel_test.dart`，`feat(gui): disconnected stage, disconnect/reconnect in the stream menu, row status and total traffic`

---

### Task 6: 需要你：计数、浮层、和串流菜单互斥、Esc；在线结果和掉线设备

**Files:**
- Create: `gui/lib/ui/needs_you.dart`
- Modify: `gui/lib/ui/main_state.dart`（needs、corner、presence、掉线设备）、`gui/lib/ui/top_bar.dart`、`gui/lib/embed/stream_menu.dart`（`StreamMenuAnchor` 受控）、`gui/lib/ui/main_window.dart`（`_esc`）
- Test: `gui/test/ui/main_state_test.dart`（新 `group('needs')`）、`gui/test/ui/top_bar_test.dart`、`gui/test/embed/stream_menu_test.dart`、`gui/test/embed/traffic_label_test.dart`、`gui/test/ui/main_window_test.dart`

**Interfaces:**
- Consumes: Task 3 `HubClient.takePresence()`；Task 4 记录、`reconnect(key)`、`disconnectedCount`；S1 `probe(id)`、`probes`、`DeviceProbe`、`deviceName(id)`、`panel`、`deviceTab`。
- Produces:
  - `enum NeedKind { session, device }`；`class NeedItem { const NeedItem(this.kind, this.target, this.text, this.seq); final NeedKind kind; final String target /* 记录 key 或设备 id */; final String text; final int seq; }`
  - `List<NeedItem> get needs`（`seq` 大的在前）；`int get needCount`。会话：每条 `disconnected` 记录，文本 `'${r.appName} @ ${deviceName(r.id)} 已断开：${disconnectWord(r.reason)}'`；设备：在 `_seenOnline` 里且在 `_offlineSince`（`Map<String, int>`，值是 `_seq`）里、并且仍在 `hub.hosts` 的设备，文本 `'${deviceName(id)} 离线'`。
  - `void _setOnline(String id, bool online)`：`probe` 的结果和 `presence` 共用。在线 → `_seenOnline.add(id)`、`_offlineSince.remove(id)`、`probes[id] = DeviceProbe(Lamp.active, '在线', apps: 旧 apps)`；离线 → `_offlineSince.putIfAbsent(id, () => ++_seq)`、`probes[id] = DeviceProbe(Lamp.offline, '离线', apps: 旧 apps, error: 旧 error)`。`probe(id)` 设转灯时**不**动 `_offlineSince`（R16）。
  - `_onHub` 里 `for (final p in hub.takePresence())`：`probes[p.id]?.lamp == Lamp.connecting` 就跳过，否则 `_setOnline(p.id, p.online)`。`removeDevice` 同时清 `_seenOnline`、`_offlineSince`。
  - `void showDevice(String id)`：`panel = PanelTab.devices`、`deviceTab = id`、`corner = null`、`probe(id)`。
  - `enum Corner { stream, needs }`；`Corner? corner`；`void toggleCorner(Corner c)`（同一个再点就收，另一个开着就换）；`void closeCorner()`；`currentKey` 变了且 `corner == Corner.stream` → 收（在 `notifyListeners` 覆盖里比较上一次的 key）。
  - `StreamMenuAnchor({…, required bool open, required VoidCallback onToggle, required VoidCallback onClose})`：去掉内部 `_open`，`didUpdateWidget` 里按 `open` 调 `OverlayPortalController.show/hide`；`TopBar` 传 `open: state.corner == Corner.stream`、`onToggle: () => state.toggleCorner(Corner.stream)`、`onClose: state.closeCorner`。
  - `class NeedsYouAnchor extends StatelessWidget { const NeedsYouAnchor({super.key, required this.state}); }`，`TopBar` 里放在流量标签左边，`state.hub != null` 就显示：
    - 按钮 `Key('needs-you')`，≥ 48×48；灯：有已断开会话 → `Lamp.disconnected`，只有设备 → `Lamp.offline`，0 → `Lamp.active`；数字 `Key('needs-count')`（JetBrains Mono 14px 600），0 时不画；有已断开会话时边框 `t.accent`、底纹 `rowBackdrop(Lamp.disconnected, t)`，只有设备时 `rowBackdrop(Lamp.offline, t)`（R18）。Semantics label：`needCount == 0 ? '需要你：没有' : '需要你：$needCount 件'`。
    - 浮层（`OverlayPortal`，同串流菜单的 scrim `Key('needs-scrim')` 和 `t.panelBox()`，宽 340，右上角）：`needs.take(3)` 每行文本 + 动作（会话 `RappButton.accent(key: Key('need-reconnect-<key>'), label: '重连')` → `state.reconnect(key)` 后 `closeCorner()`；设备 `RappButton.secondary(key: Key('need-show-<id>'), label: '查看')` → `showDevice(id)`）；多于 3 件末行 `'还有 ${n - 3} 件'`；空时 `StatusLamp(Lamp.active)` + `'没有需要你处理的事'`。点 scrim 收。
  - `main_window.dart` `_esc()`：`state.corner != null` → `closeCorner()`；否则面板；否则退全屏（R20）。

- [ ] **Step 1: 写失败的测试**

`main_state_test.dart` `group('needs')`（`fake_async`；setUp 的设备 111 'mini'、222 ''）：
- `disconnects and dropped devices count, newest first`：会话 a 断开（seq 1），然后 `presence` 111 online true、online false（seq 2）→ `needCount == 2`，`needs.first.kind == NeedKind.device`、文本 `'mini 离线'`，`needs.last.text == 'Calculator @ mini 已断开：网络断了'`。
- `a device never seen online is not counted`：`presence` 222 online false → `needCount == 0`。
- `a manual probe does not flicker the needs count`：111 见过在线后转离线（count 1）→ `st.probe('111')`（`apps` 挂起）→ 期间 `needCount == 1`；回 error → 仍 1；回成功 → 0。
- `presence skips a probe in flight`：`probe('111')` 挂起时来 `presence 111 online:false` → `probes['111']!.lamp == Lamp.connecting`；回成功 → `Lamp.active`，`needCount == 0`。
- `reconnecting and ending clear the need without a click`：断开 → 1；`reconnect` 成功 → 0；再断开 → 1；`endCurrent` → 0。
- `showDevice opens the device panel on it`：`showDevice('111')` → `deviceTab == '111'`、`corner == null`、发出 `apps` 请求。
- `corners are exclusive and the stream corner follows the session`：`toggleCorner(Corner.stream)` → `stream`；`toggleCorner(Corner.needs)` → `needs`；再点 → null；开 stream 后切会话 → null。
- `disconnects never open a corner or set a hint`：`DisconnectedEvent` 后 `corner == null`，`hints` 为空（§0 第 2 条）。

`top_bar_test.dart`：
- `needs-you shows lamp and count`：0 件 → `find.byKey(Key('needs-count'))` 无，灯是活动；1 个断开会话 → 数字 `'1'`、灯 `Lamp.disconnected`；按钮尺寸 ≥ 48×48；Semantics `'需要你：1 件'`。
- `needs popover lists three and the rest`：4 件 → 3 行 + `'还有 1 件'`；空 → `'没有需要你处理的事'`。
- `reconnect from needs keeps the selection and closes`：点 `need-reconnect-111/a` → 发出 `reconnect:true` 的 `open`，`currentKey` 不变，浮层收起。
- `opening needs closes the stream menu`：点流量标签再点 `needs-you` → 没有 `stream-menu-scrim`，有 `needs-scrim`。

`stream_menu_test.dart`、`traffic_label_test.dart`、`main_window_test.dart` 里用到 `StreamMenuAnchor` 的地方改成小壳：`StatefulBuilder` 持有 `open`，`onToggle` 翻转、`onClose` 置假；原断言不变。
`main_window_test.dart`：
- `escape closes the corner, then the panel, then fullscreen`：开面板、开需要你 → Esc → `corner == null`、面板还开 → Esc → 面板收。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/ui/main_state_test.dart test/ui/top_bar_test.dart test/ui/main_window_test.dart test/embed/stream_menu_test.dart test/embed/traffic_label_test.dart`。
- [ ] **Step 3: 实现** 照 Interfaces；对一遍设计语言 §0 三条。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** — `git add gui/lib/ui/needs_you.dart gui/lib/ui/main_state.dart gui/lib/ui/top_bar.dart gui/lib/embed/stream_menu.dart gui/lib/ui/main_window.dart gui/test/ui/main_state_test.dart gui/test/ui/top_bar_test.dart gui/test/embed/stream_menu_test.dart gui/test/embed/traffic_label_test.dart gui/test/ui/main_window_test.dart`，`feat(gui): needs-you count and popover, exclusive corners, presence-driven offline devices`

---

### Task 7: 实机检查、打包、记录

**前提：只在用户明确同意把这台 Mac 让出来一段时间之后做。** 用户中途在用（焦点被抢、GUI 被关）就停下，把没做的条目记"待实机"，不反复把自己的窗口提到前面。由 controller 派的实机检查子代理执行，全程守 Global Constraints 的安全规则。

**Files:**
- Modify: `tasks/todo.md`（S3 一节，规格 §5 每条一行，写验证方式和结果）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-s3-lifecycle-design.md` 状态行后加"S3 已实现（计划 `docs/superpowers/plans/2026-11-12-rapp-s3-lifecycle.md`）"
- Modify: `tasks/lessons.md`（只在这次真学到东西时加）

- [ ] **Step 1: 全量验证** — `cargo test --workspace`、`cargo clippy --workspace --all-targets`；`./scripts/check.sh` 末行 `EXIT=0`；`flutter analyze`、`flutter test`。
- [ ] **Step 2: 搭环境（只用自己起的进程，每个都记 PID 文件）** — 复用 scratchpad `s2live/` 的布局（`A`、`B`、`bin`，临时端口，不用 47800、21116–21119），换上本次构建的二进制和 `flutter build macos --release`（`FLUTTER_XCODE_ARCHS=arm64`）的 GUI，写 `gui.pid`。点击一律先 `s2live/topatp X Y $(cat gui.pid)`，返回的 PID 等于 `gui.pid` 才点；发键前确认最前 app 的 unix id 等于 `gui.pid`；截图只截自己的窗口。目标 app：`pgrep -x Calculator` 为空才 `open -g -a Calculator`，紧接着记新 PID 到 `calc.pid`；已在跑就跳过需要它的条目并记下来。
- [ ] **Step 3: 逐条对规格 §5 检查**（每条截一张自己窗口的图存 `s2live/s3-*.png`）：
  1. 打开 Calculator：会话行灯从连接中到活动；不动 A 的画面 10 秒后会话行写「空闲」；在画面上点一下数字键（`topatp` 先确认）→ 回到活动、显示流量数字。
  2. 串流菜单点「断开」：条目留着、舞台最后一帧 + 斜条纹 + 「重连」+「你断开了」；「需要你」数字 1；hub 日志 `closed` 行 `reason` 为 `user`。改过的档位（先设 5 fps 双色）和当前窗口在点「重连」后不变；hub 日志 `opened` 行有 `"reconnect":true`；回到活动。
  3. 在 A 上让 Calculator 退出：只 `kill $(cat calc.pid)`（按 PID）→ 会话变已断开，原因「A 端关闭了 app」（若 host 报的是别的原因，原样记下）。
  4. 停掉自己起的 host 服务（按 PID）：会话变已断开；30 秒内设备面板里这台设备变离线，「需要你」出现「<设备> 离线」一件；重新起服务后 30 秒内这一件自己消失。
  5. 顶栏流量随画面变化跳动；两个会话时面板底部「总流量」= 两行数字之和（第二个会话用另一台自己拉起的 app，同样先 `pgrep -x` 确认没在跑；没有合适的就记"单测覆盖"）。
  6. 「结束会话」点两次：条目消失，「需要你」相应减少。
  7. 分离着的会话断开（分离后停 host）：独立窗口自动收回，舞台显示已断开的最后一帧；hub 日志没有 `unknown sid`。
  8. 不点剪贴板条目、不按「复制」「插入」、不 ⌘V。
- [ ] **Step 4: 收尾** — 按 PID 文件逐个 `kill` 自己起的 GUI、Calculator（还在的话）、hub、host/service、relay；`ps -p` 确认都没了。
- [ ] **Step 5: 打包** — `scripts/package-macos.sh`；不替换 `/Applications/rapp.app`，不重启已装的 rapp-service。
- [ ] **Step 6: Commit** — `git add tasks/todo.md docs/superpowers/specs/2026-11-12-rapp-s3-lifecycle-design.md`（改了 lessons 再加 `tasks/lessons.md`），`docs: S3 done — live check, todo, spec status`

---

## Self-review

- **规格覆盖**：§2.1 状态表——连接中/活动（R1，Task 1、4）、空闲 10 秒（R2，Task 1）、连不上 → 已断开（R9，Task 4）、断开/网络断/A 关 app（R3、R4，Task 2、3、4）、重连（Task 4）、结束（R14，Task 4）；关独立窗口仍是结束（Task 2 `close` 路径不变）；六个原因短语（R8，Task 1）。§2.2 条目留着、第二行原因（Task 5 会话行）、最后一帧 + 条纹 + 重连 + 原因（Task 5）、分离中自动放回（R13，Task 2、4）、沿用设置和窗口（R11，Task 4）、不占流量（Task 4 `bytesPerSecond = 0`、R24）。§2.3 每秒字节含侧通道（Task 2）、顶栏电平（S2 已有，R23）、会话行数字/空闲/原因（Task 5）、总流量（Task 5）。§2.4 需要你计数、0 时活动灯、掉线定义、3 件 + 还有 N 件、两类动作、空状态、互斥、Esc（Task 6）。§2.5 30 秒探测 + 打开面板立刻探（Task 3、6；S1 的 `probeAll` 不动）。§2.6 第 6 组（Task 5）、会话行不加按钮（Task 5 只加文字）。§3 接口：runner `traffic`/`disconnected`（Task 2）、hub `close user`（Task 3）、重连 `open`（Task 3、4）、`presence`（Task 3）、日志（R6，Task 3）。§4 拆分 1–5 → Task 1/4、2/3、5、5、6。§5 验收 → Task 7 第 3 步逐条。§6 六条：不自动重连（没有任务做自动重试）、不跨重启（记录只在内存）、10 秒、只算见过在线的、30 秒、档位照设计语言——全部落实。
- **占位扫描**：没有 TBD。`Hub::start_with_presence` 写了二选一和取舍标准，都是能一次定下来的选择；其余名字都来自现有代码（`_waiting`、`_quiet`、`_sentFps`、`_pendingCurrent`、`rowBackdrop`、`ConfirmButton`、`RappButton.accent`、`levelBars`、`formatRate`、`fitRect`、`pictureRect`、`attachSession`、`finish_session`、`log_opened`、`request`）。
- **类型一致**：Swift `.traffic(bytesPerSecond:frames:)` ↔ channel `{bytes, frames}` ↔ Dart `TrafficEvent(sid, bytes, [frames])`；Swift `.disconnected(reason:)` ↔ `{"event":"disconnected","reason"}` ↔ `DisconnectedEvent(sid, reason)`；hub `close {reason:"user"}` ↔ `HubClient.close(sid, reason: 'user')` ↔ `disconnectWord('user') == '你断开了'`；`open {reconnect:true}` ↔ `HubClient.open(reconnect: true)`；`presence {id, online}` ↔ `takePresence()` 的 `({String id, bool online})`；`SessionRecord.key` 和 `SessionEntry.key` 都是 `'$id/$app'`；`Corner`、`NeedItem`、`NeedKind` 只在 Task 6 定义和使用；`StreamMenu` 的 `status/disconnected/onDisconnect/onReconnect` 在 Task 5 定义，Task 6 只改 `StreamMenuAnchor` 的 `open/onToggle/onClose`。
- **Review Focus**：五条的测试名分别出现在 Task 4（1、2、3）、Task 2（3）、Task 6 和 Task 3（4）、Task 1 和 Task 2（5）的 Step 1 里。
- **比例**：只给签名、行为规则、测试名和断言、精确值；代码块只有测试骨架。状态机规则（`_connect`/`_disconnect`/`reconnect`/`endCurrent`/事件分派）写成要点，因为它们是测试决定不了的顺序。
