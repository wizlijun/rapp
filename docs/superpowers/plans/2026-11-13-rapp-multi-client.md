# rapp 多客户端（接管、输入让步、复用）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同一个 app 第二个 B 连上来时直接接管（旧 B 显示「这个窗口在 〈设备名〉 上打开了」+「拿回来」）；不同 B 同时操作不同 app 时，后来的输入在 1 秒内让步；同一台 B 重复打开同一个 app 复用已开的会话。

**Architecture:** rapp-host 的 `Server.route` 收到第二个合法 `hello` 时结束旧会话（`error("taken over by 〈名〉")` + 现有 `end` 收尾）再接受新会话；设备名由 rapp-service 在接上 worker 的 TCP 后从 stdin 告诉 worker（按本地端口）。输入让步由纯 RappCore `InputYield` 在每个 host 会话里判定：有输入就向 stdout 报 `input`，service 转成 `yield` 命令写给其他 worker 的 stdin，被挡的会话回 B 一条新消息 `inputBlocked`（协议 v6，只发给 v6 的 B）。hub 对独立窗口（rapp-client）会话做复用；嵌入会话的复用 GUI 的 `MainState` 已经在做，只补测试。

**Tech Stack:** Swift 5.9（RappCore、rapp-host、RappSession、rapp-client、runner），Rust（rapp-service、rapp-hub、testkit，tokio），Flutter 3.44（macOS 桌面）。

**Spec:** `docs/superpowers/specs/2026-11-12-rapp-multi-client-design.md`（已确认：4.1 后来者接管、4.2 输入让步 1 秒、4.3 复用已开的）；可观测性规格的访问记录规则（不记密码、token、键入内容、剪贴板内容）。

**范围外：** Windows / Omarchy 的 host（不在这个仓库里，这次不动；它们的 worker 不报 `input`，所以不会挡别人，也收不到 `yield`）；观看模式（4.1 备选 C）；多人协同。

## 裁定（规格没写死、我定的）

| # | 裁定 | 理由 | 错了的代价 |
|---|---|---|---|
| R1 | 「最近一次输入」经 rapp-service 转：worker 报 `{"event":"input"}`，service 给**其他** worker 写 `{"cmd":"yield","by":"<名>"}`；service 不另存 `last_input` | service 已经读每个 worker 的 stdout、握着 stdin、知道设备名；不用共享文件或锁 | 多一跳本机管道，延迟 < 1 ms |
| R2 | 设备名：service 在 `TcpStream::connect` 到 worker 之后、回 B `ok` 之前，向 worker stdin 写 `{"cmd":"peer","port":<本地端口>,"name":"<名>"}`（只对非侧连接、`peer.name` 有值时）；host 用新连接的对端端口查名字，最多记 16 条；查不到 = 无名 | 不改 B 的 `hello`；名字和访问记录里的是同一个 | 查不到时旧 B 显示「另一台设备」 |
| R3 | 接管的错误原文是 `taken over by <名>`，无名时 `taken over`（规格只写 `taken over`） | 旧 B 要显示设备名；`taken over` 前缀不变，旧版 B 显示原文不出错 | 无 |
| R4 | 只有新 `hello` 的 token 和 app 都通过时才接管（同 `Session` 里的检查）；不通过照旧拒绝（原因是检查失败的原因，`bad token` 等），正在跑的会话不受影响。不再有 `busy` | 一个错的连接不能踢掉正在用的会话 | 无 |
| R5 | 旧会话收尾 = 现有 `end` 全部步骤（释放按住的键鼠、结束防锁屏、停截屏、断侧连接），只是先发 `error` 再关连接（发完或 1 秒后）；`onEnd` 原因 `taken over by <名>` | 规格 §5 | 无 |
| R6 | 协议升到 v6：新消息 26 `inputBlocked(by: String)`（host → client）。host 接受 5…6 的 `hello`/`fetch`/`put`，只给 v6 的会话发 26。新 B（v6）连旧 A（v5）照旧报「update both sides」 | 旧 B 收到未知类型会断开，必须按版本发；和以往升级一样 | 先升 B 后升 A 期间连不上（以往每次升级都这样） |
| R7 | 让步规则（`InputYield`）：**挡且算输入**：`text`、`key` 按下、`mouse` 按下、`scroll`、`paste`、`menuPick`、`focus`；**挡但不算输入**：`mouse` move（悬停不该挡别人）；**拖拽**：按下被放行的键（按钮）之后的 drag 和抬起永远放行并算输入（拖拽不被打断）；按下被挡的那一键的 drag/抬起也挡；不在手里的抬起，挡着时丢、不挡时放行。`setStream`、`resize`、`move`、`close` 不挡 | 规格「点击、按键、粘贴」+「拖拽中途不被打断」；抬起永不丢 = A 上不卡键 | 改分类只动一个函数 |
| R8 | 时间：`yieldWindow = 1.0` 秒（收到 `yield` 起算）；worker 报 `input` 最多每 `inputReportEvery = 0.25` 秒一次，末尾那次靠 0.25 秒定时补报；被挡的一方最多每 0.5 秒回 B 一次 `inputBlocked`。挡的时间 = 最后一次输入后 1.0–1.25 秒。时钟用 `ProcessInfo.processInfo.systemUptime` | 持续打字时对方一直被挡，停下 1 秒左右放行 | 改常量 |
| R9 | 同一台 B（两边 `peer.name` 都有值且相同）的两个会话互不让步 | 规格 4.2 的标题是「不同 B」；自己在两个 app 间切换不该被自己挡 | 两台 B 同名时互不挡（回到现状） |
| R10 | service 在旧会话 `session_end` 时判接管：原因本来是 `closed`、不是侧连接、同一 app 上还有更新的非侧会话活着 → 原因写 `taken over`，加 `by`（新会话的 `peer.name`，无则不写）。`kicked` 优先 | 两条访问记录：旧的结束原因 + 新的 `session_start`（已有） | 极少数旧会话恰好自己断开时也记成接管 |
| R11 | `input_blocked` 访问记录：字段只有 `app`、`sid`、`by`；每个会话每分钟最多一条（service 端节流，worker 端每 0.5 秒最多报一次）；进「访问记录」历史 | 规格「每个会话每分钟最多记一条，不记输入内容」 | 无 |
| R12 | hub 复用只做独立窗口（rapp-client）会话：`open` 非嵌入、非 `reconnect`、同一 id+app 有活着的会话 → 发 `focus`，回 `{"event":"opened","sid",…,"reused":true}`，不发新请求。嵌入会话不在 hub 复用（GUI `MainState` 已经切到已开的；同一个端口不能交给第二个 runner） | 规格 4.3；嵌入的复用已存在，补测试钉住 | 无 |
| R13 | GUI：被接管的记录照常是「已断开」，原因词「这个窗口在 X 上打开了」，所有「重连」按钮（舞台、串流菜单「会话」组、「需要你」）在被接管时改叫「拿回来」，动作不变（重连 = 反过来接管）；不自动重连；照常计入「需要你」；不出提示（自发的断开，沿用 S3 R9） | 规格 4.1 | 不想计入「需要你」时改 `needs` 一处 |
| R14 | GUI：`input_blocked` 只对当前舞台上的会话显示提示「A 正在被 X 操作」，1 秒后提示还是这句就清掉；其他会话的忽略 | 规格「状态条显示 1 秒」；看不见的会话不该刷提示 | 无 |
| R15 | rapp-client：`--json`（hub 起的）被接管时照旧退出，原因交给 hub/GUI；独立运行（无 `--json`）弹 `NSAlert`：正文「这个窗口在 X 上打开了」，按钮「拿回来」（用同样的参数和环境重新启动自己，然后退出）和「关闭」。被挡时状态文字显示「A 正在被 X 操作」1 秒 | 独立运行没有 GUI 替它显示；重启自己是最小的重连 | 无 |
| R16 | service 给 worker 写 stdin 改成通道：`Worker.stdin` 换成 `Option<UnboundedSender<String>>`，一个任务独占 `ChildStdin`；丢掉 sender = EOF（和现在丢掉 `ChildStdin` 一样，空闲关闭、`close_all` 不变） | hub `session.rs` 已有同样做法；多个任务要写同一个 stdin | 无 |

## Global Constraints

- Tests use temp dirs and ephemeral ports; never ports 47800 or 21116–21119; never touch /Applications/rapp.app, the running rapp-service, ~/Library/Logs/rapp, ~/Library/Application Support/rapp, the keychain or the system clipboard.
- No task may launch a GUI/app window or send synthetic input; the live check is a final task gated on the user's consent.
- Only start/stop processes you launched, by PID; never killall/pkill or name-based process targeting.
- Stage files by name only; never git add -u/-A/.; never git stash/checkout/restore/reset.
- Never touch these user files: README.md, docs/superpowers/specs/2026-11-12-rapp-design-language.md, docs/archives/, "Claude outputs/", and the untracked docs/superpowers/specs/2026-11-12-rapp-{relay-security-requirements,requirements-feedback,conversation-design,domain-candidates}.md.
- Don't add extra crypto or approval steps (the relay is the only gate, spec D8).
- Commit trailer: Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

**另加：**
- 访问记录和日志不记密码、token、键入内容、剪贴板内容；`input_blocked` 只有 `app`、`sid`、`by`（R11）。
- 不跑 `cargo fmt`；新建的 Rust 文件只用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <file>`。用户同时在改仓库，`git status` 里的 `M README.md` 等不是你的。
- 远程数据路径上不准有 `precondition`、`fatalError`、`try!`、强制解包；坏数据只断这一个会话。
- 界面文字只用中文短句，原文见各 Task。

**测试命令：**
- Swift：仓库根目录 `swift test`；交任务前 `./scripts/check.sh`，末行 `EXIT=0`。
- Rust：`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`。
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test --timeout 60s`。
- runner 编译：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`。

## Review Focus

1. **让步挡掉抬起，A 上卡键**：放行的按下在挡的期间抬起，抬起必须过；被挡的按下，它的抬起不能单独漏过去造成半个点击。测试：Task 2 `testReleaseOfAnAdmittedPressPassesWhileBlocked`、`testDragOfAnAdmittedButtonIsNeverBlocked`、`testDragAndUpOfABlockedPressAreDropped`。
2. **一直打字超过 1 秒，对方被放行插进来**：持续输入要持续报，补报不能漏最后一次。测试：Task 2 `testSteadyInputReportsEveryQuarterSecondAndTheTrailingOne`；Task 4 `input_on_one_app_tells_other_apps_to_yield`（两次 `input` 得到两条 `yield`）。
3. **接管后旧会话的 `onEnd` 把新会话清掉、错的 hello 踢掉正在用的会话**：旧会话的收尾只能清它自己；token 错的第二个 hello 不接管。测试：Task 1 `testCheckHelloRejectsBadTokenAndWrongApp`；Task 8 实机脚本的「三连接管」和「错 token 不接管」两步。
4. **旧版 B（v5）收到 26 号消息断开**：只给 v6 会话发。测试：Task 1 `testHostAcceptsV5AndV6Hellos`、`testInputBlockedOnlyForV6`；Task 8 脚本用 v5 hello 的一步。
5. **访问记录里混进输入内容或刷屏**：`input_blocked` 每分钟一条、只有三个字段。测试：Task 4 `input_blocked_is_logged_once_a_minute_without_content`。

---

### Task 1: RappCore 协议 v6、hello 检查、接管和让步的文字、worker 命令

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`（版本、类型 26、hello 版本、`knownTypes`）
- Modify: `Sources/RappCore/WorkerCLI.swift`（`checkHello`、`takenOverError`、`takeoverNotice`、`inputBlockedNotice`、`WorkerCommand`、`WorkerEvent.input`/`.inputBlocked`、`readCommands`）
- Modify: `Sources/rapp-host/main.swift`、`Sources/rapp-host/Server.swift`（`Session.handle` 改用 `checkHello`）、`Sources/rapp-client/main.swift`、`Sources/RappSession/EmbeddedSession.swift`（跟上新签名，行为不变）
- Test: `Tests/RappCoreTests/ProtocolTests.swift`、`Tests/RappCoreTests/WorkerCLITests.swift`

**Interfaces:**
- Produces:
  - `public let protocolVersion: UInt8 = 6`，`public let oldestClientVersion: UInt8 = 5`；`hello`/`fetch`/`put` 解码接受 `oldestClientVersion...protocolVersion`，其余抛 `ProtocolVersionMismatch`（文字不变：`host 6, client N`）。
  - `case hello(token: String, bundleID: String, mode: Mode, fps: UInt8, density: Float, version: UInt8 = protocolVersion)`：编码写 `version`，解码填收到的版本。
  - `case inputBlocked(by: String) // 26, host -> client`：载荷一个 `string`；加进 `knownTypes`。
  - `public func clientUnderstandsInputBlocked(_ version: UInt8) -> Bool`（`version >= 6`）。
  - `public func checkHello(token: String, bundleID: String, expected: String, bound: String?) -> Result<String, CodecError>`：先 `constantTimeEquals`，错 → `CodecError("bad token")`；再 `resolveHelloApp`。`Session.handle` 的 hello 和 Task 3 的 `route` 都用它。
  - `public func takenOverError(by name: String?) -> String`：`"taken over by \(name)"`；`nil` 或空 → `"taken over"`。
  - `public func takeoverNotice(_ reason: String) -> String?`：`reason` 去掉可选前缀 `host says: ` 后，`taken over by X` → `"这个窗口在 X 上打开了"`，`taken over` → `"这个窗口在另一台设备上打开了"`，其他 → `nil`。
  - `public func inputBlockedNotice(by: String) -> String`：`"A 正在被 \(by) 操作"`，空 → `"A 正在被另一台设备操作"`。
  - `public enum WorkerCommand: Equatable { case kick, quit, focus, peer(port: UInt16, name: String), yield(by: String) }`；`parseWorkerCommand(_ line: String) -> WorkerCommand?`（不认识的命令、缺字段 → `nil`）；`readCommands(onCommand: @escaping (WorkerCommand) -> Void, onEOF:)`。
  - `WorkerEvent.input` → `{"event":"input"}`；`WorkerEvent.inputBlocked(by: String)` → `{"event":"input_blocked","by":by}`。

- [ ] **Step 1: 写失败的测试**

```swift
// ProtocolTests
func testHostAcceptsV5AndV6Hellos() throws {
    for v: UInt8 in [5, 6] {
        let m = Message.hello(token: "t", bundleID: "b", mode: .gray4, fps: 15, density: 1, version: v)
        XCTAssertEqual(try roundTrip(m), m)            // 用文件里现成的往返写法
    }
    var old = Message.hello(token: "t", bundleID: "b", mode: .gray4, fps: 15, density: 1).encoded()
    old[5] = 4                                          // 版本字节，位置同 testOldClientGetsVersionError
    XCTAssertThrowsError(try decodeOne(old)) { XCTAssertEqual("\($0)", "protocol version mismatch: host 6, client 4 (update both sides)") }
}
func testInputBlockedRoundTrips() throws { XCTAssertEqual(try roundTrip(.inputBlocked(by: "Mac mini")), .inputBlocked(by: "Mac mini")) }
func testInputBlockedOnlyForV6() { XCTAssertFalse(clientUnderstandsInputBlocked(5)); XCTAssertTrue(clientUnderstandsInputBlocked(6)) }
// 已有的 testOldClientGetsVersionError 改期望为 "host 6"；fetch/put 的版本测试同样覆盖 5 和 6。

// WorkerCLITests
func testCheckHelloRejectsBadTokenAndWrongApp() {
    XCTAssertThrowsError(try checkHello(token: "x", bundleID: "", expected: "t", bound: "a").get()) { XCTAssertEqual("\($0)", "bad token") }
    XCTAssertEqual(try checkHello(token: "t", bundleID: "", expected: "t", bound: "a").get(), "a")
    XCTAssertThrowsError(try checkHello(token: "t", bundleID: "b", expected: "t", bound: "a").get()) { XCTAssertEqual("\($0)", "this host shares a") }
}
func testTakeoverWords() {
    XCTAssertEqual(takenOverError(by: "Mac mini"), "taken over by Mac mini")
    XCTAssertEqual(takenOverError(by: nil), "taken over")
    XCTAssertEqual(takenOverError(by: ""), "taken over")
    XCTAssertEqual(takeoverNotice("host says: taken over by Mac mini"), "这个窗口在 Mac mini 上打开了")
    XCTAssertEqual(takeoverNotice("taken over"), "这个窗口在另一台设备上打开了")
    XCTAssertNil(takeoverNotice("host says: Calculator quit"))
    XCTAssertEqual(inputBlockedNotice(by: "Mac mini"), "A 正在被 Mac mini 操作")
    XCTAssertEqual(inputBlockedNotice(by: ""), "A 正在被另一台设备操作")
}
func testWorkerCommands() {
    XCTAssertEqual(parseWorkerCommand(#"{"cmd":"quit"}"#), .quit)
    XCTAssertEqual(parseWorkerCommand(#"  {"cmd":"kick","extra":1}  "#), .kick)
    XCTAssertEqual(parseWorkerCommand(#"{"cmd":"focus"}"#), .focus)
    XCTAssertEqual(parseWorkerCommand(#"{"cmd":"peer","port":50123,"name":"Mac mini"}"#), .peer(port: 50123, name: "Mac mini"))
    XCTAssertNil(parseWorkerCommand(#"{"cmd":"peer","port":70000,"name":"x"}"#))
    XCTAssertEqual(parseWorkerCommand(#"{"cmd":"yield","by":"Mac mini"}"#), .yield(by: "Mac mini"))
    XCTAssertNil(parseWorkerCommand(#"{"cmd":"yield"}"#))
    XCTAssertNil(parseWorkerCommand(#"{"cmd":"dance"}"#))
    // 已有的 "", "quit", {"cmd":3}, ["quit"] 仍为 nil
}
func testInputEvents() {
    XCTAssertEqual(WorkerEvent.input.jsonLine, #"{"event":"input"}"#)              // 用现有事件测试的比较方式
    XCTAssertEqual(WorkerEvent.inputBlocked(by: "M").jsonLine, #"{"by":"M","event":"input_blocked"}"#)
}
```

（`"\($0)"` 的写法按 `CodecError` 现有的描述方式调整。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RappCoreTests`
Expected: 编译失败（`checkHello`、`inputBlocked` 等未定义）。

- [ ] **Step 3: 实现上面 Produces 的全部内容**

`Session.handle` 的 hello 分支改用 `checkHello`（行为不变）；rapp-host `main.swift` 的命令处理改成 `switch` `.kick`/`.quit`（`.peer`、`.yield` 先忽略，Task 3 接上）；rapp-client 的 `.quit`/`.focus` 同样；rapp-client 和 `EmbeddedSession` 里 `switch message` 新增的 `.inputBlocked` 先 `break`（Task 6 接上）。`Connection.swift` 的 `.hello(...)` 不用改（默认 `version`）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test` 然后 `./scripts/check.sh`
Expected: 全部 PASS；`.build-logs/check.log` 末行 `EXIT=0`。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappCore/Protocol.swift Sources/RappCore/WorkerCLI.swift Sources/rapp-host/main.swift Sources/rapp-host/Server.swift Sources/rapp-client/main.swift Sources/RappSession/EmbeddedSession.swift Tests/RappCoreTests/ProtocolTests.swift Tests/RappCoreTests/WorkerCLITests.swift
git commit -m "feat(core): protocol v6 inputBlocked, hello check, takeover words, typed worker commands"
```

---

### Task 2: RappCore `InputYield`（纯判定）

**Files:**
- Create: `Sources/RappCore/InputYield.swift`
- Test: `Tests/RappCoreTests/InputYieldTests.swift`

**Interfaces:**
- Consumes: `Message`（Task 1）。
- Produces:
  - `public let yieldWindow: TimeInterval = 1.0`，`public let inputReportEvery: TimeInterval = 0.25`，`public let blockedNoticeEvery: TimeInterval = 0.5`
  - `public enum YieldDecision: Equatable { case pass(report: Bool); case drop(notify: String?) }`：`report` = 这次要向 stdout 报 `input`；`notify` = 要回 B 的设备名（距上次通知 ≥ 0.5 秒才非 nil，名字可为空串）。
  - `public struct InputYield { public init(); public mutating func admit(_ m: Message, at now: TimeInterval) -> YieldDecision; public mutating func yielded(to by: String, at now: TimeInterval); public mutating func tick(at now: TimeInterval) -> Bool }`
    - `yielded`：`blockedUntil = now + yieldWindow`，记下 `by`。
    - `admit`：按 R7 分类；不挡的类型（`setStream`、`resize`、`move`、`close`，及其他非输入）→ `.pass(report: false)`；算输入的放行时，距上次报 ≥ `inputReportEvery` → `report: true`，否则记"欠一次报"。
    - `tick`：有欠的报且距上次报 ≥ `inputReportEvery` → 返回 true 并清掉。
    - `notify` 只在"因为正在挡"而丢时给（≥ 0.5 秒一次）；挡过期后丢掉被挡按下的后续（drag/抬起）给 `nil`。不在手里的抬起放行时不算输入（`report: false`）。
    - 按住的键/按钮自己记（`Set<UInt16>`、`Set<MouseButton>`），和 `InputInjector` 的 `HeldInput` 无关。

- [ ] **Step 1: 写失败的测试**（`k(_ code, down)` = `.key(keyCode:modifiers:0,down:)`，`m(_ kind)` = 左键 `.mouse`，`t` = `.text("a")`）

```swift
func testOwnInputPassesAndReportsAtMostEveryQuarterSecond() {
    var y = InputYield()
    XCTAssertEqual(y.admit(t, at: 0), .pass(report: true))
    XCTAssertEqual(y.admit(t, at: 0.1), .pass(report: false))
    XCTAssertEqual(y.admit(t, at: 0.3), .pass(report: true))
}
func testSteadyInputReportsEveryQuarterSecondAndTheTrailingOne() {
    var y = InputYield()
    _ = y.admit(t, at: 0); _ = y.admit(t, at: 0.1)
    XCTAssertFalse(y.tick(at: 0.2))
    XCTAssertTrue(y.tick(at: 0.25))      // 0.1 那次补报
    XCTAssertFalse(y.tick(at: 0.5))      // 没有新的输入
}
func testInputWithinOneSecondOfAYieldIsDroppedThenPasses() {
    var y = InputYield()
    y.yielded(to: "Mac mini", at: 10)
    XCTAssertEqual(y.admit(t, at: 10.2), .drop(notify: "Mac mini"))
    XCTAssertEqual(y.admit(t, at: 10.4), .drop(notify: nil))        // < 0.5 秒不再通知
    XCTAssertEqual(y.admit(t, at: 10.8), .drop(notify: "Mac mini"))
    XCTAssertEqual(y.admit(t, at: 11.0), .pass(report: true))        // 正好 1 秒放行
}
func testHoverIsBlockedButNeverReported() {
    var y = InputYield()
    XCTAssertEqual(y.admit(m(.move), at: 0), .pass(report: false))
    y.yielded(to: "x", at: 1)
    XCTAssertEqual(y.admit(m(.move), at: 1.1), .drop(notify: "x"))
}
func testReleaseOfAnAdmittedPressPassesWhileBlocked() {
    var y = InputYield()
    _ = y.admit(k(56, true), at: 0); _ = y.admit(m(.down), at: 0)
    y.yielded(to: "x", at: 0.5)
    XCTAssertEqual(y.admit(k(56, false), at: 0.6), .pass(report: true))
    XCTAssertEqual(y.admit(m(.up), at: 0.9), .pass(report: true))
}
func testDragOfAnAdmittedButtonIsNeverBlocked() {
    var y = InputYield()
    _ = y.admit(m(.down), at: 0)
    y.yielded(to: "x", at: 0.1)
    XCTAssertEqual(y.admit(m(.drag), at: 0.2), .pass(report: false))   // 0.25 内，欠报
    XCTAssertEqual(y.admit(m(.drag), at: 0.3), .pass(report: true))
}
func testDragAndUpOfABlockedPressAreDropped() {
    var y = InputYield()
    y.yielded(to: "x", at: 0)
    XCTAssertEqual(y.admit(m(.down), at: 0.1), .drop(notify: "x"))
    XCTAssertEqual(y.admit(m(.drag), at: 1.5), .drop(notify: nil))   // 挡已过期，但这一键的按下被挡了
    XCTAssertEqual(y.admit(m(.up), at: 1.6), .drop(notify: nil))
    XCTAssertEqual(y.admit(m(.down), at: 1.7), .pass(report: true))  // 下一次点击正常
}
func testStrayReleaseIsDroppedOnlyWhileBlocked() {
    var y = InputYield()
    XCTAssertEqual(y.admit(k(0, false), at: 0), .pass(report: false))
    y.yielded(to: "x", at: 1)
    XCTAssertEqual(y.admit(k(0, false), at: 1.1), .drop(notify: "x"))
}
func testWindowCommandsAreNeverBlocked() {
    var y = InputYield()
    y.yielded(to: "x", at: 0)
    for msg: Message in [.resize(id: 1, width: 10, height: 10), .move(id: 1, x: 0, y: 0), .close(1),
                         .setStream(mode: .gray4, fps: 5, density: 1)] {
        XCTAssertEqual(y.admit(msg, at: 0.1), .pass(report: false))
    }
}
func testPasteMenuPickFocusAndScrollAreInput() {
    var y = InputYield()
    y.yielded(to: "x", at: 0)
    for msg: Message in [.paste(seq: 1, .text("a")), .menuPick([0]), .focus(1), .scroll(window: 1, x: 0, y: 0, dx: 0, dy: 1)] {
        if case .drop = y.admit(msg, at: 0.1) {} else { XCTFail("\(msg)") }
    }
}
```

（`.paste`、`.focus`、`.scroll` 的构造按 `Protocol.swift` 里的实际标签写。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter InputYieldTests`
Expected: 编译失败（`InputYield` 未定义）。

- [ ] **Step 3: 在 `Sources/RappCore/InputYield.swift` 实现 `InputYield`**

被挡的按下记进 `droppedKeys`/`droppedButtons`，它的 drag/抬起丢（不看是否还在挡），抬起后清掉；放行的按下记进 `heldKeys`/`heldButtons`，它的 drag/抬起放行并算输入。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter InputYieldTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/RappCore/InputYield.swift Tests/RappCoreTests/InputYieldTests.swift
git commit -m "feat(core): InputYield decides which input waits for another session"
```

---

### Task 3: rapp-host 接管、设备名、让步接线

**Files:**
- Modify: `Sources/rapp-host/Server.swift`（`route`、`Server.peer/yieldTo`、`Session.takeOver`、`end` 的告别消息、输入分支过 `InputYield`、0.25 秒定时）
- Modify: `Sources/rapp-host/main.swift`（`.peer`、`.yield` 命令）

**Interfaces:**
- Consumes: Task 1 `checkHello`、`takenOverError`、`clientUnderstandsInputBlocked`、`WorkerCommand`、`WorkerEvent.input/.inputBlocked`、`Message.inputBlocked`；Task 2 `InputYield`。
- Produces（Task 4 的 fake host 照这些 stdin/stdout 行为模仿）：
  - stdin `{"cmd":"peer","port":P,"name":N}` → `Server.peer(port: UInt16, name: String)`：`peerNames[P] = N`，超过 16 条丢最早的。
  - stdin `{"cmd":"yield","by":N}` → `Server.yieldTo(_ by: String)`：`queue.async { session?.yielded(to: by) }`。
  - stdout `{"event":"input"}`（会话有输入，R8 节流）；`{"event":"input_blocked","by":N}`（被挡并通知 B 的那一次）；旧会话被接管时 `{"event":"session","state":"ended","reason":"taken over by N"}`。

- [ ] **Step 1: `route` 的 `.hello` 分支**

已有会话时：`checkHello(token:bundleID:expected: options.token, bound: options.app)` 失败 → `reject(connection, "\(error)", notify: true)`，旧会话不动（R4）；成功 → `old.takeOver(by: peerNames[对端端口])`，再照常建新会话并把名字交给它（`Session` 新参数 `peerName: String?`）。建会话的 `onEnd` 闭包里 `self.session = nil` 和中断侧连接改成只在 `self.session === newSession` 时做（Review Focus 3）。对端端口取 `connection.endpoint` 的 `.hostPort` 的 `port.rawValue`。

- [ ] **Step 2: `Session.takeOver(by:)` 和告别消息**

`end(_ reason: String, farewell: Message? = nil)`：其余步骤不变；`farewell` 非 nil 时 `connection.cancel()` 换成先 `send(farewell)`，发完或 1 秒后再 `cancel`。`takeOver(by name: String?)` = `end(takenOverError(by: name), farewell: .error(takenOverError(by: name)))`。

- [ ] **Step 3: 输入过 `InputYield`**

`handle` 里 `.text/.key/.mouse/.scroll`、`.paste`、`.focus`、`.menuPick` 先 `yield.admit(message, at: ProcessInfo.processInfo.systemUptime)`：`.pass(report)` → 原逻辑，`report` 时 `output.emit(.input)`；`.drop(notify)` → 不执行，`notify` 非 nil 时 `output.emit(.inputBlocked(by:))`，且 `clientUnderstandsInputBlocked(helloVersion)` 时 `send(.inputBlocked(by:))`。`resize`/`move`/`close`/`setStream` 也过 `admit`（结果总是放行，保持一个入口）。会话开始时起一个 0.25 秒的 `DispatchSourceTimer`，`yield.tick` 为真时 `output.emit(.input)`；`end` 里取消。`Session.yielded(to:)` 转给 `yield.yielded`。

- [ ] **Step 4: `main.swift` 接上 `.peer` → `server.peer`，`.yield` → `server.yieldTo`**

- [ ] **Step 5: 编译和单测**

Run: `swift test` 然后 `./scripts/check.sh`
Expected: PASS，末行 `EXIT=0`。（host 的真机行为在 Task 8 验。）

- [ ] **Step 6: 提交**

```bash
git add Sources/rapp-host/Server.swift Sources/rapp-host/main.swift
git commit -m "feat(host): second valid hello takes over; input yields to other sessions"
```

---

### Task 4: rapp-service 设备名、接管记录、输入转发、`input_blocked` 记录

**Files:**
- Modify: `rust/service/src/workers.rs`（stdin 通道、`tell`、`tell_others`、stdout 里的 `input`/`input_blocked`）
- Modify: `rust/service/src/peer.rs`（`splice_session`：写 `peer` 命令、接管原因）
- Modify: `rust/service/src/state.rs`（`live_session`、`newer_session`）
- Modify: `rust/service/src/ipc.rs`（`in_history` 加 `input_blocked`）
- Modify: `rust/testkit/src/bin/fake-rapp-host.rs`
- Test: `rust/testkit/tests/service.rs`

**Interfaces:**
- Consumes: Task 3 的 stdin/stdout 行。
- Produces:
  - `Worker.stdin: Option<tokio::sync::mpsc::UnboundedSender<String>>`（R16）；`pub fn tell(state: &State, app: &str, line: String) -> bool`（worker 不在或已关 → false）。
  - `fn tell_others(state: &State, app: &str)`：取 `state.live_session(app)` 的 peer 作为来源；对其他每个有活会话的 app，若两边 `peer.name` 不是"都有值且相同"（R9），写 `{"cmd":"yield","by": 来源 name 或 ""}`。
  - `State::live_session(&self, app: &str) -> Option<(u64, Peer)>`：该 app 最新的非侧会话。
  - `State::newer_session(&self, app: &str, sid: u64) -> Option<Peer>`：该 app 上 sid 比它大的非侧会话。
  - 访问记录：`session_end` 可有 `reason: "taken over"` + `by`；新事件 `input_blocked {app, sid, by}`。
  - fake host：stdin 每行写 host.log `stdin <app> <line>`；新的合法会话先关掉上一个会话的 TCP（模拟接管）；会话里收到一整行 `input` → stdout `{"event":"input"}`，`blocked <名>` → `{"event":"input_blocked","by":"<名>"}`（照常回显）。

- [ ] **Step 1: 写失败的测试**（B 端用现有 `direct(&ep, a_addr(&svc), auth)`，`auth` 里带 `"name"`；会话用现有 `echo_through` 那一套开 `open`）

```rust
#[tokio::test]
async fn takeover_logs_the_old_session_as_taken_over_by_the_new_device() {
    // b-one 开 com.example.echo，b-two 再开同一个
    // host.log 有 `stdin com.example.echo {"cmd":"peer","port":<n>,"name":"b-two"}`
    let end = wait_log(home, "session_end", |v| v["sid"] == first_sid).await;
    assert_eq!((&end["reason"], &end["by"]), (&json!("taken over"), &json!("b-two")));
    wait_log(home, "session_start", |v| v["sid"] == second_sid && v["name"] == "b-two").await;
    // 历史（ipc history）里旧的那条 session_end 还在
}

#[tokio::test]
async fn input_on_one_app_tells_other_apps_to_yield() {
    // b-one 开 com.example.echo，b-two 开 com.apple.Safari；b-one 的会话里发 "input\n"，过 0.6 秒再发一次
    // host.log 两次出现 `stdin com.apple.Safari {"by":"b-one","cmd":"yield"}`（按 serde_json 输出的键序比较整行）
    // com.example.echo 自己没有收到 yield
}

#[tokio::test]
async fn same_device_does_not_yield_to_itself() {
    // b-one 开两个 app；一个会话里发 "input\n"；等 500 ms
    // host.log 没有任何 `"cmd":"yield"`
}

#[tokio::test]
async fn input_blocked_is_logged_once_a_minute_without_content() {
    // 一个会话发两次 "blocked b-two\n"
    let v = wait_log(home, "input_blocked", |_| true).await;
    let keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
    // 除了日志自带的 ts/lvl/ev，只有 app、sid、by
    assert_eq!(v["by"], "b-two");
    // 再等 300 ms，log_events(home) 里 input_blocked 只有 1 条；ipc history 里有它
}
```

再改 `idle_worker_gets_stdin_closed`、`open_splices_bytes_to_worker_and_kick_ends_it` 不需要（行为不变），跑一遍确认。

- [ ] **Step 2: 跑测试确认失败**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test -p rapp-testkit --test service`
Expected: 新的 4 个 FAIL（host.log 里没有 `stdin` 行、没有 `taken over`）。

- [ ] **Step 3: 改 fake host**（Produces 里那三条）

- [ ] **Step 4: 实现 service**

`spawn` 里建通道和写入任务（照 `rust/hub/src/session.rs` 的 rapp-client stdin 写法）；`start_session` 和空闲/`close_all` 改为丢 sender。stdout 读任务：`input` → `tell_others(&state, &app)`；`input_blocked` → 取 `state.live_session(&app)` 的 sid，距这个 sid 上次记录 ≥ 60 秒（读任务里局部的 `HashMap<u64, Instant>`）才记 `input_blocked {app, sid, by}`（`Lvl::Info`）。`splice_session`：非侧连接、`peer.name` 有值时 `tell(state, app, json!({"cmd":"peer","port":tcp.local_addr()?.port(),"name":name}).to_string())`，在回 B `ok` 之前；结束时按 R10 改原因并加 `by`。`ipc::in_history` 加 `"input_blocked"`。

- [ ] **Step 5: 跑测试确认通过**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`
Expected: 全部 PASS，clippy 无警告。

- [ ] **Step 6: 提交**

```bash
git add rust/service/src/workers.rs rust/service/src/peer.rs rust/service/src/state.rs rust/service/src/ipc.rs rust/testkit/src/bin/fake-rapp-host.rs rust/testkit/tests/service.rs
git commit -m "feat(service): tell workers who connected, forward input as yield, log takeovers and blocked input"
```

---

### Task 5: rapp-hub 复用独立窗口会话

**Files:**
- Modify: `rust/hub/src/lib.rs`（`sessions` 的值）、`rust/hub/src/session.rs`（`open`、`focus`、`close`、`finish_session` 跟上新结构）
- Test: `rust/testkit/tests/hub.rs`

**Interfaces:**
- Produces:
  - `sessions: Mutex<HashMap<u64, HubSession>>`，`struct HubSession { tx: Option<UnboundedSender<String>>, id: String, app: String, path: String, embed: bool }`（`tx` 语义同现在的 `Option<UnboundedSender>`）。
  - `open` 非嵌入、`!reconnect`、有 `embed == false && tx.is_some()` 且 id+app 相同的会话 → 给它发 `{"cmd":"focus"}`，回 `{"event":"opened","sid","id","app","path","reused":true}`（带 `req`），hub.log 记 `opened` 行加 `"reused":true`；不发 `Op::Open`。

- [ ] **Step 1: 写失败的测试**

```rust
#[tokio::test]
async fn second_open_of_the_same_app_reuses_the_session() {
    // 同 focus_reaches_the_client_and_unknown_sid_errors 的准备
    let r1 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o1"})).await;
    let r2 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o2"})).await;
    assert_eq!((r2["event"].clone(), r2["sid"].clone(), r2["reused"].clone(), r2["req"].clone()),
               (json!("opened"), r1["sid"].clone(), json!(true), json!("o2")));
    wait_for_file(&a.bins.path().join("client.focus")).await;               // 被调到前面
    // A 端只开过一次：service 访问记录里 com.example.echo 的 session_start 只有 1 条
    hub.send(json!({"cmd":"close","sid":r1["sid"]})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":r1["sid"],"reason":"echo ok"}));
}

#[tokio::test]
async fn embedded_opens_are_not_reused_by_the_hub() {
    // 两次 embed open 同一 app → 两个不同的 sid（复用由 GUI 做，R12）
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test -p rapp-testkit --test hub second_open`
Expected: FAIL（第二次拿到新 sid）。

- [ ] **Step 3: 实现 `HubSession` 和复用分支**

- [ ] **Step 4: 跑测试确认通过**

Run: `export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add rust/hub/src/lib.rs rust/hub/src/session.rs rust/testkit/tests/hub.rs
git commit -m "feat(hub): reopening an app that is already open brings its window forward"
```

---

### Task 6: B 端 Swift：`inputBlocked` 事件、rapp-client 的接管提示和「拿回来」

**Files:**
- Modify: `Sources/RappSession/SessionEvent.swift`（`.inputBlocked(by:)`）、`Sources/RappSession/EmbeddedSession.swift`（收到 `.inputBlocked` 发事件）、`Sources/RappSession/Channel.swift`（`eventPayload`）
- Modify: `gui/macos/Runner/SessionPlugin.swift`（若它按事件分支，补这一支）
- Modify: `Sources/rapp-client/main.swift`、`Sources/rapp-client/TrafficLabel.swift`
- Test: `Tests/RappSessionTests/EmbeddedSessionTests.swift`、`Tests/RappSessionTests/ChannelTests.swift`

**Interfaces:**
- Consumes: Task 1 `Message.inputBlocked`、`takeoverNotice`、`inputBlockedNotice`。
- Produces: channel 事件 `input_blocked {sid, by}`（Task 7 解析）。

- [ ] **Step 1: 写失败的测试**

```swift
// EmbeddedSessionTests
func testInputBlockedBecomesAnEventAndKeepsTheLink() throws {
    let link = FakeLink(); var events = [SessionEvent]()
    let (_, q) = make(link) { events.append($0) }
    q.sync { link.feed(.windows([w])); link.feed(.inputBlocked(by: "Mac mini")) }
    XCTAssertEqual(events.last, .inputBlocked(by: "Mac mini"))
    XCTAssertFalse(events.contains { if case .disconnected = $0 { return true }; return false })
}
func testTakenOverDisconnectsWithTheHostText() throws {
    // 同 testHostErrorClosesWithReason：feed(.error("taken over by Mac mini"))
    XCTAssertEqual(events.last, .disconnected(reason: "host says: taken over by Mac mini"))
}
// ChannelTests
func testInputBlockedPayload() {
    let p = eventPayload(.inputBlocked(by: "Mac mini"), sid: 3, textures: [:])
    XCTAssertEqual(p?.method, "input_blocked")
    XCTAssertEqual(p?.args["by"] as? String, "Mac mini")
    XCTAssertEqual(p?.args["sid"] as? Int64, 3)        // 和其他 payload 的 sid 类型一致
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RappSessionTests`
Expected: 编译失败（`.inputBlocked` 不是 `SessionEvent`）。

- [ ] **Step 3: 实现 RappSession 部分**

- [ ] **Step 4: rapp-client**

`.inputBlocked(by)` → `TrafficLabel` 显示 `inputBlockedNotice(by:)` 1 秒后恢复原文字（新方法 `flash(_ text: String, for seconds: TimeInterval)`）。`.error(reason)`：`--json` 时照旧 `finish`；否则 `takeoverNotice(reason)` 非 nil → `NSAlert`（`messageText` = 该文字，按钮「拿回来」「关闭」）：「拿回来」用 `Process` 以 `CommandLine.arguments` 和当前环境重新启动自己后 `finish(ExitCode.ok, …)`，「关闭」照旧 `finish`。不是接管的错误照旧。

- [ ] **Step 5: 跑测试和编译**

Run: `swift test`；`./scripts/check.sh`；`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`
Expected: PASS，末行 `EXIT=0`，runner 编译成功（不运行它）。

- [ ] **Step 6: 提交**

```bash
git add Sources/RappSession/SessionEvent.swift Sources/RappSession/EmbeddedSession.swift Sources/RappSession/Channel.swift Sources/rapp-client/main.swift Sources/rapp-client/TrafficLabel.swift Tests/RappSessionTests/EmbeddedSessionTests.swift Tests/RappSessionTests/ChannelTests.swift
git commit -m "feat(b): input_blocked event; rapp-client offers 拿回来 when taken over"
```

（`SessionPlugin.swift` 改了就一起按名加上。）

---

### Task 7: GUI（Dart）：接管的文字和「拿回来」、被挡提示、访问记录、复用测试

**Files:**
- Modify: `gui/lib/embed/session_port.dart`（`InputBlockedEvent`、解析）
- Modify: `gui/lib/ui/lifecycle.dart`（`takenOver`、`reconnectLabel`、`disconnectWord`）
- Modify: `gui/lib/ui/main_state.dart`（`input_blocked` 提示、`endedHint`）
- Modify: `gui/lib/ui/disconnected_stage.dart`、`gui/lib/ui/needs_you.dart`、`gui/lib/ui/session_model.dart`（按钮文字）
- Modify: `gui/lib/access_log.dart`
- Test: `gui/test/embed/session_port_test.dart`、`gui/test/ui/lifecycle_test.dart`、`gui/test/ui/main_state_test.dart`、`gui/test/access_log_test.dart`、`gui/test/ui/main_window_test.dart`

**Interfaces:**
- Consumes: Task 6 的 `input_blocked {sid, by}`；Task 3 的错误原文；Task 4 的访问记录。
- Produces:
  - `class InputBlockedEvent extends SessionEvent { const InputBlockedEvent(super.sid, this.by); final String by; }`，缺 `by` 记 `''`。
  - `bool takenOver(String? raw)`：去掉可选 `rapp-client: ` 前缀后以 `host says: taken over` 开头。
  - `String reconnectLabel(String? raw) => takenOver(raw) ? '拿回来' : '重连';`
  - `disconnectWord`：最前面加：被接管 → `这个窗口在 $name 上打开了`（`taken over by ` 后的名字），无名 → `这个窗口在另一台设备上打开了`。`endedHint(appName, reason)` 被接管 → `$appName：这个窗口在 X 上打开了`（同样的无名写法）。
  - `const blockedHintFor = Duration(seconds: 1);`；`String inputBlockedHint(String by)`：`A 正在被 $by 操作`，空 → `A 正在被另一台设备操作`（同 Task 1 `inputBlockedNotice`）。

- [ ] **Step 1: 写失败的测试**

```dart
// session_port_test
test('input_blocked parses', () {
  final e = parseSessionEvent({'event': 'input_blocked', 'sid': 3, 'by': 'Mac mini'}) as InputBlockedEvent;
  expect((e.sid, e.by), (3, 'Mac mini'));
});
// lifecycle_test
test('taken over words and label', () {
  expect(disconnectWord('host says: taken over by Mac mini'), '这个窗口在 Mac mini 上打开了');
  expect(disconnectWord('host says: taken over'), '这个窗口在另一台设备上打开了');
  expect(disconnectWord('rapp-client: host says: taken over by M'), '这个窗口在 M 上打开了');
  expect(reconnectLabel('host says: taken over by M'), '拿回来');
  expect(reconnectLabel('connection closed'), '重连');
  expect(endedHint('Safari', 'rapp-client: host says: taken over by M'), 'Safari：这个窗口在 M 上打开了');
});
// main_state_test（embedded sessions 组的 env 写法）
test('input blocked shows for a second on the current session only', ...);
  // 当前会话 sid 收到 InputBlockedEvent('Mac mini') → st.hint == 'A 正在被 Mac mini 操作'
  // a.elapse(999 ms) 仍是；a.elapse(1 ms) 后不是这句
  // 另一个不在舞台上的会话收到 → hint 不变
  // by 为空 → 'A 正在被另一台设备操作'
test('a taken over session stays disconnected, counts in needs, does not reconnect by itself', ...);
  // DisconnectedEvent(sid, 'host says: taken over by M') → phase disconnected，needCount == 1，
  // 再过 10 秒 t.sent 里没有新的 open；hint 不变
test('opening an embedded app that is open switches to it without a second open', ...);
  // openOrSwitch 同一 app 两次 → t.sent 里 cmd == 'open' 只有 1 条，hint == '已切到 <app>'
// main_window_test
testWidgets('a taken over session offers 拿回来', ...);
  // 已断开的舞台按钮 Key('reconnect-button') 文字是「拿回来」，点了发 open（reconnect:true）
// access_log_test
test('takeover and blocked input rows', () {
  expect(historyRow({'ev': 'session_end', 'reason': 'taken over', 'by': 'b-two', ...}).text, '被 b-two 接管');
  expect(historyRow({'ev': 'session_end', 'reason': 'taken over', ...}).text, '被另一台设备接管');
  expect(historyRow({'ev': 'input_blocked', 'by': 'b-two', ...}).text, '输入被挡：b-two 正在操作');
});
```

（`historyRow` 的字段名和行的必填字段照 `access_log_test.dart` 现有用例补全；`.text` 换成 `HistoryRow` 里实际的文字字段。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd gui && $HOME/development/flutter/bin/flutter test --timeout 60s test/embed/session_port_test.dart test/ui/lifecycle_test.dart test/ui/main_state_test.dart test/access_log_test.dart test/ui/main_window_test.dart`
Expected: 新用例 FAIL（复用那条可能已经过——那就是钉住现有行为，保留）。

- [ ] **Step 3: 实现**

`_onPortEvent`：`InputBlockedEvent` 且 `e.sid` 是当前记录的 sid → `hint = inputBlockedHint(e.by)`（Dart 里同 Task 1 的文字），起一个 `blockedHintFor` 的 `Timer`，到时 `hint` 还是这句就设为 null 并 `notifyListeners()`；`dispose` 取消。三处「重连」按钮文字改用 `reconnectLabel(rec.reason)`。`access_log.dart`：`session_end` 的 `reason == 'taken over'` → `被 $by 接管` / `被另一台设备接管`（不标警告色）；`input_blocked` → `输入被挡：$by 正在操作`（`by` 空写「另一台设备」，不标警告色）。

- [ ] **Step 4: 跑全部 Flutter 测试**

Run: `cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test --timeout 60s`
Expected: analyze 无问题，全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add gui/lib/embed/session_port.dart gui/lib/ui/lifecycle.dart gui/lib/ui/main_state.dart gui/lib/ui/disconnected_stage.dart gui/lib/ui/needs_you.dart gui/lib/ui/session_model.dart gui/lib/access_log.dart gui/test/embed/session_port_test.dart gui/test/ui/lifecycle_test.dart gui/test/ui/main_state_test.dart gui/test/access_log_test.dart gui/test/ui/main_window_test.dart
git commit -m "feat(gui): 拿回来 for taken-over sessions, blocked-input hint, takeover rows in the access log"
```

---

### Task 8: 实机检查（用户同意后才跑）

**Files:**
- Create: `scripts/multi-client-loopback.py`（照 `scripts/side-loopback.py` 的写法：自己起 `rapp-host serve` 于 127.0.0.1 端口 0，app 用 Calculator，已在运行就什么都不做；只按 PID 收尾）

- [ ] **Step 1: 写脚本（不运行）**，逐步打印 PASS/FAIL：
  1. 连接 1 `hello`（v6）→ 收到 `ready`。
  2. 往 host stdin 写 `{"cmd":"peer","port":<连接 2 的本地端口>,"name":"test-b2"}`，连接 2 `hello` → 连接 1 收到 `error("taken over by test-b2")` 后被关，连接 2 收到 `ready`；host stdout 有 `{"event":"session","state":"ended","reason":"taken over by test-b2"}`。
  3. 连接 3 `hello` 带错 token → 被拒（`bad token`），连接 2 仍在（还在收 `frame`）。
  4. 连接 4 合法 `hello` → 连接 2 被接管、连接 4 `ready`（三连接管，Review Focus 3）。
  5. stdin 写 `{"cmd":"yield","by":"x"}`，连接 4 发一次 `mouse move` → 连接 4 收到 26 `inputBlocked("x")`，host stdout 有 `input_blocked`（这次移动在挡的期间，应被丢掉，A 的指针不动）。
  6. 连接 5 用 v5 `hello` 接管 → `ready`；同第 5 步再挡一次 → 连接 5 收不到 26 号消息，也不断开（Review Focus 4）。

- [ ] **Step 2: 问用户**：「要用这台 Mac 跑一次多客户端检查：会起 Calculator，约 1 分钟，只发一次应被挡掉的鼠标移动。可以吗？」没同意就停，在 `tasks/todo.md` 记"待实机"。

- [ ] **Step 3: 跑脚本**

Run: `./scripts/check.sh && python3 scripts/multi-client-loopback.py .build/release/rapp-host`
Expected: 全部 PASS；脚本退出后它起的进程都已按 PID 结束。

- [ ] **Step 4: 两台 B 的检查**（只在用户在场、愿意用两台 B 操作时；否则写"待实机"）：B1 开 TextEdit、B2 开同一个 → B1 显示「这个窗口在 〈B2〉 上打开了」+「拿回来」，点了反过来接管、不来回抢。B1 开 TextEdit、B2 开 Calculator，B1 打字时 B2 点击 → B2 顶栏「A 正在被 〈B1〉 操作」，B1 停约 1 秒后 B2 能点；B1 拖拽窗口内容时 B2 的点击不插进来。A 的「访问记录」有「被 〈B2〉 接管」「输入被挡」行，没有打的字。

- [ ] **Step 5: 提交脚本**

```bash
git add scripts/multi-client-loopback.py
git commit -m "test: host-side loopback check for takeover, yield and v5 clients"
```
