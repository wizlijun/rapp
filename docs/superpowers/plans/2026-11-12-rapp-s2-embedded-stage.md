# rapp S2（嵌入舞台）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 macOS 上，打开的远程 app 画面直接嵌在主窗口舞台里显示和操作（点、拖、滚、键盘、多窗口标签、附属窗口），串流菜单和输入区搬进主窗口；会话可以分离成独立窗口再放回，不断开连接；不在舞台上的会话降到 1 fps。

**Architecture:** 新 Swift 库 target `RappSession`（依赖 `RappCore`）装连接、解码进 IOSurface 像素缓冲池、窗口表、输入区发送、剪贴板历史、侧连接传输；`rapp-client` 改为依赖它，行为不变、改用 IOSurface 显示。GUI 的 macOS runner 链这个库，经一个 `rapp/session` MethodChannel 和每个 A 窗口一个 `FlutterTexture` 跟 Dart 说话；Dart 侧 `SessionPort` 抽象 + `RemoteSession` 模型 + `Texture`/`Listener`/`Focus` 组件。hub 的 `open` 加 `embed`：不拉起 `rapp-client`，回 `{port, token}`，GUI 自己连本机端口，TCP 断开即会话结束。键盘在 runner 里用 `NSEvent.addLocalMonitorForEvents` 按规则分流。分离窗口是 runner 里的原生 NSWindow，显示同一组 IOSurface。

**Tech Stack:** Swift 5.9（AppKit、CoreVideo、IOSurface、Network；SwiftPM），Flutter 3.44（macOS 桌面，`Texture`、`MethodChannel`），Rust（rapp-hub, tokio）。

**Spec:** `docs/superpowers/specs/2026-11-12-rapp-s2-embedded-stage-design.md`（全文，§6 全部按默认）；上位 `docs/superpowers/specs/2026-11-12-rapp-main-window-design.md` §3.1、§3.2、§3.4、§3.5、§5、§9；`docs/superpowers/specs/2026-11-12-rapp-design-language.md`；输入区与剪贴板行为 `docs/superpowers/specs/2026-11-11-rapp-clipboard-composer-design.md`。

## S2 范围裁定（规格没写死、我定的）

| # | 裁定 | 理由 | 错了的代价 |
|---|---|---|---|
| R1 | 纹理按 **A 窗口** 分，不按会话：每个窗口（普通、对话框、浮动、附属）一个 `FlutterTexture` + 一个 IOSurface 像素缓冲池，缓冲尺寸 = 该窗口的 `cropRect` 像素尺寸；窗口表里带 `texture` id 和 `visible`（窗口内容里被拍到的那部分，0–1 归一化） | 规格 §4 写"每个会话一个纹理 id"，但一帧的 region 不等于窗口表，标签、附属窗口和分离窗口都要按窗口取图；今天 `rapp-client` 也是按窗口裁 | 改成单纹理要在 Dart 里裁剪，返工 Picture |
| R2 | 没有 `frame` channel 事件；新帧只靠 `textureFrameAvailable` 通知引擎 | 每帧一次 channel 往返白白占 UI 线程（UI 和平台线程合并，S0 警告 5） | 无 |
| R3 | 输入区的块照主界面规格 §3.5 放在输入框**上方**一排（虚线 chip，点一下删）；发送顺序 = 块按加入顺序，最后是文字 | 主界面规格明写块在输入框上方；`rapp-client` 是行内 chip，Flutter 的 TextField 做行内附件代价大 | 想要行内顺序时改 `pieces()` 一处 |
| R4 | 嵌入输入区不做拖放文件进来；用「附件」按钮和 ⌘V。独立 `rapp-client` 的拖放照旧 | 拖放要原生 dragging destination 套在 FlutterView 上，S2 不值 | 以后加一个 runner 侧 drop 处理 |
| R5 | 串流菜单第 5 组：最新两条 + 「全部剪贴板」（在菜单里展开到最多 20 条；资源面板是 S6）。每条右侧一个「插入」按钮代替 Option-点（规格 §5.5 不靠修饰键/悬停）；点条目本身 = 取到 B 的剪贴板（同今天） | 主界面规格 §3.4 写了"全部剪贴板"，但资源面板 S6 才有 | S6 时改成打开资源面板 |
| R6 | 分离出去的会话算"可见"，保持选定帧率 | 它就在屏幕上 | 改 `effectiveFps` 一行 |
| R7 | 分离状态下 A 上普通窗口变成 0 个（只剩附属窗口或空表）：自动放回舞台，舞台显示"正在连接"样式的等待 | 没有窗口可显示时独立窗口无处容身 | 无 |
| R8 | 附属窗口的 `parent` 不在表里（或为 0）时画在当前窗口上面 | 规格只说"画在所属窗口上面" | 无 |
| R9 | 窗口标签只算普通、对话框、浮动（`WindowKind.isDecorated`），≥2 个才出现 | 规格 §2.3 "两个以上普通窗口" | 无 |
| R10 | hub 嵌入协议：`{"cmd":"open","id","app","embed":true}` → `opened` 多 `port`、`token`；`closed` 原因：`"quit"`（hub 收到 `close`/`close_all`）、`"connection closed"`（本机 TCP 断）、`"GUI did not connect"`（10 秒没连上）。新命令 `{"cmd":"note","sid","what":"detach"\|"attach","windows":k}`，hub 记一行事件 `detach`/`attach` `{sid, windows}`，不回事件 | 分离/放回"各记一行"要有地方记，GUI 进程自己不写日志文件；hub 已经记着这个会话的开和关 | hub 协议多一条命令 |
| R11 | 新会话起始：`color16`、15 fps、自适应（同今天 hub 拉起的 client） | 沿用 | 无 |
| R12 | 改尺寸：A 窗口的内容尺寸 = 舞台逻辑尺寸（zoom 固定 1，嵌入里没有缩放菜单）。当前窗口变了（含首个窗口、切标签）立刻发一次；舞台尺寸变了停 0.3 秒发一次；A 回来的尺寸和舞台不同（最小/最大尺寸）不再追发；只对 `resizable` 窗口发 | 规格 §2.2 的规则落到可测的状态机 | 无 |
| R13 | 第 6 组"会话"：路径、「分离成独立窗口」/「放回主窗口」、「放左上角」、「结束会话」（点两次） | 主界面规格 §3.4 说菜单沿用 `rapp-client` 标签菜单，「放左上角」在那里 | 无 |
| R14 | 双击、三击在 Dart 里数：间隔用 runner `init` 回的 `NSEvent.doubleClickInterval`（毫秒），位移容差 4 逻辑像素 | Flutter 的 PointerEvent 不带 clickCount | 无 |
| R15 | 画面有焦点时，按键（含修饰键 `flagsChanged`）按真实的按下/抬起发给 A；焦点离开、换会话、分离/放回、主窗口失去 key 时，把还按着的键补发抬起 | 不补发会卡键 | 无 |
| R16 | 嵌入输入区空着时**不**透传回车、方向键给 A（规格 §2.5"输入框有焦点时按键不发给 A"）；空着按发送提示"按键直接发给 A"；Esc 先清空文字，已空则收起输入区 | 主界面规格 §3.5；`rapp-client` 的空输入透传在嵌入里由「按键」行和点画面代替 | 无 |
| R17 | `rapp-client` 的显示也换成 IOSurface 做 layer 内容（规格 §5 第 0 项） | 省约 17 点 CPU | 无 |
| R18 | 串流选择、输入区草稿和展开状态按会话记，切会话时各自恢复；不存盘 | 规格 §2.7 "分离状态记在会话上"，同理 | 无 |
| R19 | Linux、Windows 不变：没有 `SessionPort`，`open` 不带 `embed`，舞台用 S1 占位 | 规格 §1 非目标 | 无 |
| R20 | 分离窗口：每个普通 A 窗口一个 NSWindow，初始内容尺寸 = A 的内容尺寸，夹在屏幕 `visibleFrame` 里，放在主窗口右边（放不下放左边，再不行和主窗口错开 24pt），多个窗口依次错开 24pt；画面等比放、留边；用户拖尺寸停 0.3 秒后改 A 的尺寸（同 R12 规则） | 规格只说"放在主窗口旁边" | 无 |
| R21 | 放回时当前标签 = 分离期间最后成为 key 的那个独立窗口 | 用户最后看的窗口 | 无 |
| R22 | 镜像菜单是串流菜单最后一组"A 的菜单"，点进子菜单逐级展开（不依赖悬停）；快捷键文字由 runner 用 `shortcutText` 算好随 `menu` 事件下发 | 规格 §6 第 9 条 | 无 |
| R23 | 结束提示：runner 原因 `quit` → "已结束 X"；`host says: <名字> quit` → "X 已结束：A 端关闭了 app"；`connection closed` → "X 意外结束：连接断了"；`GUI did not connect` → "X 意外结束：本机没有接上会话"；其他 → "X 意外结束：<原因>"（同 S1） | 规格 §2.8 的例子 | 无 |
| R24 | 焦点离开画面：顶栏、浮层、输入区外面套 `Listener(onPointerDown: (_) => state.blurPicture())`（不吃事件） | Flutter 没有"点画面外"的通知 | 无 |
| R25 | IRON MAN 的网格（`Backdrop` 里盖在全部内容上面的 `_HoloGrid`）**不盖远程画面**：`Backdrop` 加参数 `ValueListenable<Rect?>? hole`；网格画家改名公开 `HoloGrid(on, hole)`，画之前 `canvas.clipPath(Path()..fillType = PathFillType.evenOdd..addRect(全幅)..addRect(hole))` 挖掉这块；`Picture` 每次布局后把纹理所在矩形换算到 `Backdrop` 的坐标系写进 `MainState.pictureHole`（`ValueNotifier<Rect?>`），舞台不显示画面时写 null。其他主题不变（它们的图层在内容下面） | 设计语言写 IRON MAN 网格"全屏叠"，但画面是 A 的内容，盖上去就改了用户看到的东西；0a41e89 起网格在最上层 | 盖在画面上的面板、浮层那一块也没有网格 |

## Global Constraints

**安全规则（每个实现者都受约束，原文照录）：**
- Only start/stop processes you launched, by PID. Never killall/pkill or address processes by name in AppleScript/System Events.
- Never touch /Applications/rapp.app, the running rapp-service, ~/Library/Logs/rapp, the user's real config dir, the keychain, or the system clipboard. Tests use temp dirs and ephemeral ports; never ports 47800 or 21116–21119.
- Synthetic clicks only after `topat X Y` (scratchpad tool) shows your own app at that point; keystrokes only after verifying your app is frontmost by PID. Screenshots only of your own windows (`screencapture -l <id>`).
- Don't modify text in the user's documents; never touch the user's apps.
- No push, no merge, no subagents.

**测试与命令：**
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`（起点 194 条全绿）。
- Rust：`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`（起点 90 条全绿）。**不跑 `cargo fmt`**；新 Rust 文件只用 `rustfmt --edition 2021 --config max_width=120,use_small_heuristics=Max <文件>`。
- Swift：仓库根目录 `swift test`（起点 224 条全绿）；交任务前跑 `./scripts/check.sh`，`.build-logs/check.log` 末行 `EXIT=0`。
- runner 编译检查：`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`。打包同 `scripts/package-macos.sh`（已带 `FLUTTER_XCODE_ARCHS=arm64`）。
- Swift 测试里**不用 `NSPasteboard.general`**：`LocalPasteboard(board: NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)")))`，`tearDown` 里 `releaseGlobally()`。Dart 测试用 `FakeSessionPort`（Task 5）和 `FakeTransport`，不碰真 channel。
- 提交信息末尾：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。每个 Task 一个提交；不 push、不 merge、不换分支（`feat/main-window-s2-s6`）。

**代码规则：**
- 远程数据路径（帧、窗口表、菜单、剪贴板、`pasted`、侧连接）上不准有 `precondition`、`fatalError`、`try!`、强制解包、越界下标：坏数据抛错或返回 nil，由 `EmbeddedSession` 结束**这一个**会话（原因 `cannot decode frame: …` 等）。本机产生的数据（编码端、协议编码）的现有 precondition 不动。
- 线程：每个 `EmbeddedSession` 一条串行 `DispatchQueue`；连接回调、解码、写像素缓冲都在这条队列上；发给 Dart 的事件、开关窗口切回主线程。`FlutterTexture.copyPixelBuffer` 只在 `NSLock` 里取最新缓冲并 `passRetained`。
- 纹理只在 Dart 调过 `init` 之后注册（S0 坑 4：引擎启动后才注册）；会话结束时先注销它的全部纹理，再发 `closed` 给 Dart。
- runner 只做胶水：channel 参数解析、按键分流、窗口几何、事件编码都是 `RappSession` 里的纯函数并有测试；Dart 侧坐标换算、点击计数、改尺寸节流、标签选择、帧率策略都是纯 Dart 单元并有测试。
- 键盘规则：画面有焦点时**只有同时按着 ⌃⌘ 的组合归 rapp**（⌃⌘F 全屏、⌃⌘[ ⌃⌘] 上/下一个会话、⌃⌘D 分离/放回），⌘Q 退出 rapp；其余全部发给 A，包括 Esc、⌘W、⌘[。S1 的 ⌘[ ⌘] 在 macOS 上改成 ⌃⌘[ ⌃⌘]（Linux/Windows 的 Ctrl+[ Ctrl+] 不变）。
- 浮层只盖不挤：左侧面板、串流菜单、输入区开合都不改变舞台尺寸，也不触发 A 的 resize。选了就收（主界面规格 §5.3）；不可撤销操作点两次、3 秒复原（§5.4）；不靠悬停和右键（§5.5，右键只是第二入口）。
- 组件只用 `RappTokens`；可点控件高度 ≥ 48px；状态词只用设计语言 §9 的词表（连接中、活动、空闲、已断开、已结束；打开、切到、断开、重连、结束会话…）。
- 日志：不记按键、粘贴、剪贴板内容；token 不进日志；嵌入会话的开、关由 hub 记（同今天）；分离、放回各一行（hub `note`）。runner 不另开日志文件。

## Review Focus

1. **坏帧数据只结束那一个会话**：两个会话，一个喂坏帧，它结束并报原因，另一个照常出帧，进程不退。测试：Task 3 `testBadFrameEndsOnlyThatSession`（Swift），Task 6 `decode error ends one session, keeps the other`（Dart）。
2. **浮层不改 A 的尺寸；舞台尺寸变化停 0.3 秒后只发一次；切标签立刻发一次**。测试：Task 7 `overlays never resize`、`stage resize settles then sends once`、`tab switch resizes at once`。
3. **按键分流和不卡键**：⌃⌘ 组合与 ⌘Q 归 rapp，Esc、⌘W、⌘[ 归 A；失焦、换会话、分离时补发抬起。测试：Task 8 `testRouteKey`、`testKeyTrackerReleasesHeldKeys`（Swift），`picture focus follows taps`（Dart）。
4. **分离/放回不重开会话**：同一个 sid，hub 只收到过一次 `open`；关掉独立窗口 = 结束会话；⌃⌘D 两个方向都有效。测试：Task 12 `detach and attach keep the sid and send no open`、`closing the detached window ends the session`、`ctrl-cmd-D toggles both ways`。
5. **runner `closed` 和 hub `closed` 任意先后到达**：条目只移除一次，提示只出一次且用 runner 的原因，纹理已注销。测试：Task 6 `runner closed first`、`hub closed first`（Dart，fake_async），Task 3 `testCloseUnregistersSurfacesOnceAndReportsOnce`（Swift）。

---

### Task 1: `RappSession` 库：搬家与解耦

**Files:**
- Modify: `Package.swift`（`#if os(macOS)` 块里加 `.library(name: "RappSession", targets: ["RappSession"])`、`.target(name: "RappSession", dependencies: ["RappCore"])`、`.testTarget(name: "RappSessionTests", dependencies: ["RappSession"])`；`rapp-client` 依赖加 `"RappSession"`）
- Move（`git mv`，类型和用到的成员改 `public`）：`Sources/rapp-client/{Connection,SideConnection,Transfers,LocalPasteboard,Sender,RemoteView,PopupPanel}.swift` → `Sources/RappSession/`
- Split: `Sources/rapp-client/ClipHistory.swift` → 模型 `Sources/RappSession/ClipHistory.swift` + 菜单 `Sources/rapp-client/ClipHistoryMenu.swift`
- Split: `Sources/rapp-client/Composer.swift` 里块的存放、编号和标签 → `Sources/RappSession/ComposerBlocks.swift`（`ChipPayload`、`InsertPayload`、`SendCounters` 一起搬）
- Modify: `Sources/rapp-client/{main,WindowCoordinator,Composer,ComposerBar,StreamMenu}.swift`（`import RappSession`；`ComposerBar` 实现 `ComposerSink`）
- Test: `Tests/RappSessionTests/{LocalPasteboardTests,ClipHistoryTests,ComposerBlocksTests,SenderTests}.swift`

**Interfaces:**
- Produces:
  - `public protocol MessageLink: AnyObject { var onMessage: ((Message) -> Void)? { get set }; var onClosed: ((String) -> Void)? { get set }; var onBytes: ((Int) -> Void)? { get set }; var density: Float { get set }; func start(); func send(_ message: Message); func cancel() }`
  - `public final class Connection: MessageLink`，`public init(address: RemoteAddress, queue: DispatchQueue = .main)`（回调在 `queue` 上；`rapp-client` 用默认 `.main`，行为不变）；新 `cancel()`：关连接，**不**调 `onClosed`。
  - `public final class LocalPasteboard { public init(board: NSPasteboard = .general) }`，方法同今天（`write(text:)`、`write(png:)`、`write(uti:data:)`、`write(files:)`、`fileURLs()`、`imagePNG()`、`data(uti:)`）。
  - `public final class ClipHistory { public static let limit = 20; public var onClip: (() -> Void)?; public func add(id: UInt32, _ info: ClipInfo); public var entries: [(id: UInt32, info: ClipInfo)] /* newest first */; public func info(_ id: UInt32) -> ClipInfo? }`；取用逻辑 `public func pick(_ id: UInt32, insert: Bool, transfers: TransferQueue, pasteboard: LocalPasteboard, onInsert: (ClipInfo, InsertPayload) -> Void)`（从今天的 `pick` 原样搬，菜单无关）。`ClipHistoryMenu`（rapp-client）只建 NSMenu，行为、标题、"（空）"不变。
  - `public final class ComposerBlocks { public func add(_ p: ChipPayload) -> Int /* block number */; public func payload(_ n: Int) -> ChipPayload?; public func remove(_ n: Int); public func label(_ n: Int) -> String? /* chipLabel 原样 */ }`
  - `public protocol ComposerSink: AnyObject { func payload(_ chunk: Int) -> ChipPayload?; func uploadedItem(_ chunk: Int) -> UInt32?; func setUploadedItem(_ item: UInt32, for chunk: Int); func setSending(_ on: Bool); func finished(pieces: [ComposerPiece], sent: Int, failure: String?) }`（`sent` = 已完整贴进 A 的 piece 数）
  - `public final class Sender { public init(sink: ComposerSink, transfers: TransferQueue, counters: SendCounters, send: @escaping (Message) -> Void); public func start(pieces: [ComposerPiece]); public func pasted(seq: UInt32, error: String) -> Bool }`。"清掉已发前缀 / （发送中改过内容，未清除）"留在 `ComposerBar.finished` 里（rapp-client 行为不变）。
  - `public final class TransferQueue`、`SideConnection`、`RemoteView`、`PopupPanel`：接口不变，只加 `public`。

- [ ] **Step 1: 写失败的测试**

```swift
final class LocalPasteboardTests: XCTestCase {
    var board: NSPasteboard!
    override func setUp() { board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)")) }
    override func tearDown() { board.releaseGlobally() }
    func testWritesToTheBoardItIsGiven() {
        LocalPasteboard(board: board).write(text: "x")
        XCTAssertEqual(board.string(forType: .string), "x")
    }
}
func testClipHistoryKeepsNewestTwentyNewestFirst()   // add 25 → entries.count == 20, entries[0].id == 25, entries.last!.id == 6
func testComposerBlocksNumbersAndLabels()            // add(.text(60 行)) == 1；label(1) == "[贴入文字 #1 +60 行]"；add(.image(png, 10, 20)) == 2，label == "[图片 #2 10×20]"；remove(1) → payload(1) == nil
func testSenderPastesTextThenReportsAllSent()        // FakeSink；start([.text("hi")]) → send 收到 .paste(seq: 1, .text("hi"))；pasted(seq:1, error:"") == true → sink.finished(sent: 1, failure: nil)
func testSenderReportsPasteError()                   // pasted(seq:1, error:"x") → finished(sent: 0, failure: pasteErrorMessage("x"))
func testSenderFailsAMissingChunk()                  // start([.chunk(7)])，sink.payload(7) == nil → finished(sent: 0, failure: "找不到这一块的内容")
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter RappSessionTests` → 编译失败（没有 `RappSession`）。
- [ ] **Step 3: 实现** — `git mv` 搬文件、加 `public`、拆 `ClipHistory` 和 `ComposerBlocks`、`ComposerBar: ComposerSink`。`rapp-client` 只改 import 和调用点。
- [ ] **Step 4: 跑测试确认通过** — `swift test` 全绿（224 + 新增）；`./scripts/check.sh` 末行 `EXIT=0`。
- [ ] **Step 5: Commit** `refactor(swift): RappSession library holds connection, transfers, clip history, sender`

---

### Task 2: 直接解码进 IOSurface 像素缓冲池；去掉远程数据上的 precondition

**Files:**
- Modify: `Sources/RappCore/Quantize.swift`（`expand` 改成 throws，加写进外部缓冲的版本）
- Create: `Sources/RappSession/WindowSurfaces.swift`
- Modify: `Sources/rapp-client/main.swift:174-185`、`WindowCoordinator.swift:333-350`、`Sources/RappSession/RemoteView.swift`（`show` 收 `CVPixelBuffer`，`layer.contents = CVPixelBufferGetIOSurface(buf)?.takeUnretainedValue()`）
- Modify: `Tests/RappCoreTests/QuantizeTests.swift:14, 255-259`（调用加 `try`；"太短"那条改成断言抛错）
- Test: `Tests/RappCoreTests/QuantizeTests.swift`、`Tests/RappSessionTests/WindowSurfacesTests.swift`

**Interfaces:**
- Produces:
  - `public enum ExpandError: Error, Equatable { case shortSamples, badRect }`
  - `public static func expand(samples: [UInt8], width: Int, height: Int, mode: Mode) throws -> [UInt8]`（原签名加 throws，缓冲不够抛 `.shortSamples`）
  - `public static func expand(samples: [UInt8], width: Int, height: Int, mode: Mode, rect: (x: Int, y: Int, w: Int, h: Int), into dst: UnsafeMutableRawPointer, bytesPerRow: Int) throws`（只展开 `rect`，按 `bytesPerRow` 写 BGRA、alpha 255；`rect` 超出 `width×height` 或为空抛 `.badRect`）。前者用后者实现。
  - `public final class WindowSurfaces`：
    - `public func draw(table: [WindowInfo], decoder: FrameDecoder, region: CanvasRect) throws -> [UInt32]`：对表里每个窗口算 `cropRect(window:region:pixelWidth:pixelHeight:)`，拿该窗口的池（尺寸变了就重建池）取一个缓冲、`expand` 进去，设为该窗口最新缓冲；返回这次更新了的窗口 id。
    - `public func latest(_ id: UInt32) -> CVPixelBuffer?`（加锁读）；`public func visible(_ id: UInt32) -> CGRect?`（`visiblePart` 的结果，归一化到窗口内容 0–1）
    - `public func keep(only ids: Set<UInt32>) -> [UInt32]`（丢掉不在表里的窗口，返回被丢的 id）
    - `public private(set) var poolsCreated: Int`（测试用）
  - 池属性：`kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA`、`kCVPixelBufferIOSurfacePropertiesKey: [:]`、`kCVPixelBufferMetalCompatibilityKey: true`、`kCVPixelBufferPoolMinimumBufferCountKey: 3`。

- [ ] **Step 1: 写失败的测试**

```swift
func testExpandShortSamplesThrows() {
    XCTAssertThrowsError(try Quantizer.expand(samples: [0], width: 4, height: 4, mode: .color16)) {
        XCTAssertEqual($0 as? ExpandError, .shortSamples)
    }
}
func testExpandRectIntoStridedBuffer()   // 4×2 color16 已知样本，rect (1,0,2,2)，bytesPerRow 16 → 第 0 行前 8 字节 = 像素 (1,0)(2,0) 的 BGRA，第 8–15 字节未动
func testExpandRectOutsideThrows()       // rect (3,0,2,1) on width 4 → .badRect
func testDrawMakesOnePoolPerWindowSizedToCrop()   // 两个窗口的表 + FrameEncoder(mode:.color16) 编的 64×32 帧 → latest(a) 宽高 == cropRect 尺寸；poolsCreated == 2；再画同尺寸一帧 poolsCreated 仍 2
func testDrawRebuildsPoolWhenWindowSizeChanges()  // 窗口 w 改了 → poolsCreated == 3
func testKeepOnlyDropsGoneWindows()               // keep(only: [a]) == [b]；latest(b) == nil
func testPixelBuffersAreIOSurfaceBacked()         // CVPixelBufferGetIOSurface(latest(a)!) != nil
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter "QuantizeTests|WindowSurfacesTests"` → 编译失败。
- [ ] **Step 3: 实现** — `expand` 两个版本；`WindowSurfaces`；`rapp-client` 帧路径改成 `try decoder.decode` → `try surfaces.draw(...)` → 每个更新了的窗口 `if let buf = surfaces.latest(id) { remoteView.show(buf, ...) }`（不强制解包）；去掉 `makeImage`。解码或展开失败仍 `output.finish(ExitCode.runtime, "rapp-client: cannot decode frame: \(error)")`，并在 `finish` 后 `return`（今天会接着走 expand）。
- [ ] **Step 4: 跑测试确认通过** — `swift test` 全绿；`./scripts/check.sh` 末行 `EXIT=0`。
- [ ] **Step 5: Commit** `perf(client): decode straight into IOSurface pixel buffer pools`

---

### Task 3: `EmbeddedSession`（一个嵌入会话的全部非界面逻辑）

**Files:**
- Create: `Sources/RappSession/EmbeddedSession.swift`、`Sources/RappSession/SessionEvent.swift`
- Test: `Tests/RappSessionTests/EmbeddedSessionTests.swift`、`Tests/RappSessionTests/FakeLink.swift`

**Interfaces:**
- Consumes: `MessageLink`、`WindowSurfaces`（Task 1、2）；`captureDensity`、`streamChanged`、`formatRate` 不在这里用（流量数字给 Dart）。
- Produces:
  - `public struct SessionWindow: Equatable { public let info: WindowInfo; public let visible: CGRect }`
  - `public enum SessionEvent: Equatable { case ready(appName: String); case windows([SessionWindow]); case surfaces([UInt32]); case traffic(bytesPerSecond: Int); case clips([ClipRow]); case menu([MenuItem]); case transfer(String?); case composer(ComposerEvent); case closed(reason: String) }`，`public struct ClipRow: Equatable { id: UInt32; title: String /* historyTitle */; pickable: Bool }`（`ComposerEvent` 在 Task 11 填，这里先 `case sending(Bool)`）。
  - `public final class EmbeddedSession`：
    - `public init(address: RemoteAddress, choice: DensityChoice, backingScale: CGFloat, link: MessageLink, pasteboard: LocalPasteboard, queue: DispatchQueue)`
    - `public var onEvent: ((SessionEvent) -> Void)?`（在 `queue` 上调；runner 自己切主线程）
    - `public let surfaces: WindowSurfaces`；`public func start()`；`public func send(_ m: Message)`
    - `public func setStream(mode: Mode, fps: UInt8, choice: DensityChoice)`（用 `captureDensity(zoom: 1, backingScale:choice:)` + `streamChanged` 去重后发 `.setStream`）；`public var backingScale: CGFloat`（变了重算密度）
    - `public func tickTraffic()`（每秒由 runner 调一次：发 `.traffic(bytesPerSecond:)`，清零计数）
    - `public func close(reason: String = "quit")`：只生效一次：`link.cancel()`、`surfaces.keep(only: [])`、发 `.closed(reason:)`。
  - 消息处理（从 `rapp-client` `handle()` 搬，去掉 UI）：`.ready` → `.ready`；`.windows` → 存表、`surfaces.keep(only:)`、发 `.windows`；`.frame` → `do { try decoder.decode(p); let ids = try surfaces.draw(...); onEvent(.surfaces(ids)) } catch { close(reason: "cannot decode frame: \(error)") }`；`.menuBar` → `.menu`；`.clip` → `history.add` + `.clips`；`.pasted` → Task 11；`.error(r)` → `close(reason: "host says: \(r)")`；`link.onClosed(r)` → `close(reason: r)`。

- [ ] **Step 1: 写失败的测试**

```swift
func testReadyWindowsAndFrameProduceEvents()   // FakeLink 喂 .ready(appName:"Calc",…)、.windows([w])、.frame(region, 好帧) → 事件依次 [.ready("Calc"), .windows([SessionWindow(info: w, visible: (0,0,1,1))]), .surfaces([w.id])]
func testBadFrameEndsOnlyThatSession() {
    // s1、s2 各一个 FakeLink；s1 喂好帧的 payload 截掉一半；s2 喂好帧
    XCTAssertEqual(events1.last, .closed(reason: /* hasPrefix */ "cannot decode frame: "))
    XCTAssertTrue(link1.cancelled)
    XCTAssertEqual(events2.last, .surfaces([w.id])); XCTAssertNotNil(s2.surfaces.latest(w.id))
}
func testFrameLargerThanDecoderThrowsNotCrash()  // 表里窗口超出 region 的帧 + 不一致的 payload 尺寸 → .closed，不崩
func testCloseUnregistersSurfacesOnceAndReportsOnce()  // close() 两次 + link.onClosed("x") → .closed 只一次，reason "quit"；surfaces.latest(w.id) == nil
func testHostErrorClosesWithReason()   // .error("Calculator quit") → .closed(reason: "host says: Calculator quit")
func testSetStreamDedupes()            // setStream(.color16, 15, .adaptive) 两次 → link.sent 里 .setStream 只一条；fps 改 1 → 第二条 fps 1
func testTrafficTicksAndResets()       // link.onBytes(1500)、onBytes(500)；tickTraffic() → .traffic(bytesPerSecond: 2000)；再 tick → 0
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter EmbeddedSessionTests` → 编译失败。
- [ ] **Step 3: 实现**（`FakeLink` 记 `sent`、`cancelled`，能 `feed(_:)` 和 `drop(_:)`；测试用 `DispatchQueue(label:)` 同步等 `queue.sync {}`）。
- [ ] **Step 4: 跑测试确认通过** — `swift test` 全绿。
- [ ] **Step 5: Commit** `feat(session): EmbeddedSession decodes into surfaces and ends alone on bad data`

---

### Task 4: hub `open` 的 `embed` 选项 + `note` 命令；`HubClient` 跟上

**Files:**
- Modify: `rust/hub/src/session.rs`（`open` 分出 `open_embedded`；`run` 处理"没有 child"）、`rust/hub/src/lib.rs`（dispatch 传 `embed`、加 `note`）
- Modify: `docs/superpowers/specs/2026-11-11-rapp-platform-design.md` hub 命令表（`open` 的 `embed`、`note`）
- Modify: `gui/lib/hub_client.dart`
- Test: `rust/testkit/tests/hub.rs`、`gui/test/hub_client_test.dart`

**Interfaces:**
- Produces（hub stdin 协议）：
  - `{"cmd":"open","id","app","embed":true}`：不找、不拉起 `rapp-client`；`request(Op::Open{side:false})` 拿到 stream 和 token；bind `127.0.0.1:0`；分配 sid；**先**插入 `sessions`、记 `opened` 日志（不含 token）、发 `{"event":"opened","sid","id","app","path","port":<u16>,"token":<str>}`；再后台等连接（`ACCEPT_WAIT` 10 秒）。超时 → 日志 `closed` + 事件 `{"event":"closed","sid","reason":"GUI did not connect"}`。连上后同今天：splice 主连接，后续连接当侧连接（各自 `Op::Open{side:true}` + splice）。
  - 嵌入会话的结束：`select!{ splice 结束 => "connection closed", rx.recv() 返回 None（close/close_all 丢了发送端）=> "quit" }`；收到的行（`focus`）丢弃。`closed` 日志和事件格式不变。
  - `{"cmd":"note","sid","what":"detach"|"attach","windows":<u64>}` → 日志事件 `ev: "detach"|"attach"`，字段 `{sid, windows}`；成功不回事件；sid 不在 → `{"event":"error","error":"unknown sid"}`；`what` 不是这两个或 `windows` 缺 → `{"event":"error","error":"bad note"}`（带 `req` 则回带）。
  - 不带 `embed` 的 `open` 完全不变。
- Produces（Dart）：
  - `Future<HubSession> HubClient.open(String id, String app, {bool embed = false})`：只在 `embed` 为真时加 `'embed': true`。
  - `HubSession` 加 `final int? port; final String? token;`（从 `opened` 读）。
  - `void HubClient.note(Object sid, String what, int windows)` → `{'cmd':'note','sid','what','windows'}`，不等回复。

- [ ] **Step 1: 写失败的测试**（`hub.rs`，搭建同 `focus_reaches_the_client_and_unknown_sid_errors`）

```rust
#[tokio::test]
async fn embed_open_returns_port_and_token_and_spawns_no_client() {
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","embed":true,"req":"o"})).await;
    let (port, token) = (r["port"].as_u64().unwrap(), r["token"].as_str().unwrap().to_string());
    // 扮演 fake-rapp-client：token 行 → "ok\n" → "ping\n" 回显
    let mut tcp = TcpStream::connect(("127.0.0.1", port as u16)).await.unwrap();
    /* write token + "\n"; read "ok\n"; write "ping\n"; read "ping\n" */
    assert!(!a.bins.path().join("client.port").exists(), "no rapp-client was started");
    drop(tcp);
    assert_eq!(hub.next().await, json!({"event":"closed","sid":r["sid"],"reason":"connection closed"}));
    let text = std::fs::read_to_string(home.path().join("logs").join("hub.log")).unwrap();
    assert!(!text.contains(&token));
}
#[tokio::test] async fn embed_close_command_ends_with_quit()          // 连上后 close → closed reason "quit"；tcp 读到 EOF
#[tokio::test] async fn embed_side_connection_gets_its_own_open()     // 第二条连接 token → ok → "side\n" 回显（同 side_connection_… 的断言）
#[tokio::test] async fn embed_without_connect_reports_gui_did_not_connect()  // 不连；15 秒内收到 closed reason "GUI did not connect"
#[tokio::test] async fn note_logs_detach_and_attach() {
    // embed open；note detach windows 2；note attach windows 2
    // read_log(.., "hub.log") 里 ev=="detach" 一条且 ["windows"]==2、["sid"]==sid；ev=="attach" 一条
    // note sid 999 → error "unknown sid"；what "x" → error "bad note"
}
```
Dart：
```dart
test('open with embed sends the flag and keeps port and token', () async {
  final f = hub.open('a', 'com.x', embed: true);
  expect(t.sent.last, {'cmd': 'open', 'id': 'a', 'app': 'com.x', 'embed': true, 'req': anything});
  t.emit({'event': 'opened', 'sid': 1, 'id': 'a', 'app': 'com.x', 'path': 'lan', 'port': 5000, 'token': 'tk', 'req': t.sent.last['req']});
  final s = await f; expect([s.port, s.token], [5000, 'tk']);
});
test('open without embed sends no embed key', ...);   // t.sent.last.containsKey('embed') == false
test('note sends what and windows', ...);             // {'cmd':'note','sid':1,'what':'detach','windows':2}
```

- [ ] **Step 2: 跑测试确认失败** — `cargo test -p rapp-testkit --test hub embed_ note_` → FAIL；`flutter test test/hub_client_test.dart` → FAIL。
- [ ] **Step 3: 实现** hub（`run` 的 child 改成 `Option<Child>`，嵌入走 `select!` 两路）和 Dart。
- [ ] **Step 4: 跑测试确认通过** — `cargo test --workspace`（90 + 新增）全绿、`cargo clippy --workspace --all-targets` 无警告；`flutter analyze && flutter test` 全绿。
- [ ] **Step 5: 文档** — 平台规格 hub 命令表：`open` 加 `embed`（回 `port`、`token`；三种 closed 原因）；新行 `note`。
- [ ] **Step 6: Commit** `feat(hub): embedded open returns port and token; note logs detach/attach`

---

### Task 5: runner 链库 + `SessionPlugin` + channel；Dart `SessionPort`

**Files:**
- Modify: `gui/macos/Runner.xcodeproj/project.pbxproj`（`XCLocalSwiftPackageReference` relativePath `"../.."`；`XCSwiftPackageProductDependency` productName `RappSession`，加进 Runner target 的 `packageProductDependencies` 和 Frameworks 阶段；`SessionPlugin.swift` 的 PBXFileReference、PBXBuildFile、Runner 组、Sources 阶段；`MACOSX_DEPLOYMENT_TARGET = 14.0` 三处，第 474、556、606 行）
- Create: `gui/macos/Runner/SessionPlugin.swift`
- Modify: `gui/macos/Runner/MainFlutterWindow.swift`（`RegisterGeneratedPlugins` 之后 `SessionPlugin.register(with: flutterViewController.registrar(forPlugin: "RappSession"))`）
- Create: `Sources/RappSession/Channel.swift`
- Create: `gui/lib/embed/session_port.dart`
- Modify: `gui/test/fakes.dart`（加 `FakeSessionPort`）
- Test: `Tests/RappSessionTests/ChannelTests.swift`、`gui/test/embed/session_port_test.dart`

**Interfaces:**
- Produces（channel `rapp/session`，参数都是 map；sid 用 hub 的 sid 原样）：
  - Dart → runner：`init` → `{doubleClickMs:int}`；`start {sid, port, token, mode, fps, density}`；`close {sid}`；`mouse {sid, window, kind:'down'|'up'|'drag'|'move', button:'left'|'right', x, y, clicks}`；`scroll {sid, window, x, y, dx, dy}`；`key {sid, keyCode, modifiers}`（按下+抬起一对，给「按键」行用）；`picture_focus {sid|null}`；`resize {sid, window, w, h}`；`select_window {sid, window}`；`set_stream {sid, mode, fps, density}`；`move_top_left {sid, window}`；`menu_pick {sid, path:[int]}`；`clip_pick {sid, clip, insert}`；`composer_paste {sid}` → `{text}|{blocks:[{n,label}]}|{status}|{}`；`composer_attach {sid}` → 同上；`composer_send {sid, pieces:[{text}|{block}]}`；`composer_drop_block {sid, block}`；`cancel_transfer {sid}`；`detach {sid}`；`attach {sid}`；`raise_detached {sid}`。mode 取 `duogray|duocolor|color16|gray4|color8`，density 取 `saver1x|adaptive|original`。
  - runner → Dart（`invokeMethod`，都带 `sid`）：`ready {appName}`；`windows {windows:[{id, parent, kind, title, x, y, w, h, titleBar, resizable, focused, texture, visible:[x,y,w,h]}]}`；`traffic {bytes}`；`clipboard {clips:[{id, title, pickable}]}`；`menu {items:[{title, enabled, checked, separator, shortcut, children}]}`；`composer {sending:bool}` / `composer {done:{sent:int, failure:String?}}`；`composer_insert {text}|{blocks}`；`transfer {status:String?}`；`detached {detached:bool, current:int?}`；`closed {reason}`。
  - Swift 纯函数：`public enum ChannelCommand: Equatable { case start(sid: Int64, port: UInt16, token: String, mode: Mode, fps: UInt8, density: DensityChoice), close(sid: Int64), mouse(sid: Int64, Message), … }`；`public func channelCommand(_ method: String, _ args: Any?) throws -> ChannelCommand`（缺字段、类型不对、值超范围抛 `ChannelError.bad(method)`；数值用 `clamping`）；`public func eventPayload(_ e: SessionEvent, sid: Int64, textures: [UInt32: Int64]) -> (method: String, args: [String: Any])?`。
  - runner 胶水 `SessionPlugin: NSObject, FlutterPlugin`：`[Int64: Live]`，`Live` = `EmbeddedSession` + 每个窗口一个 `SurfaceTexture: NSObject, FlutterTexture`（`copyPixelBuffer` → `surfaces.latest(id)` 的 `passRetained`）+ 纹理 id；`.surfaces(ids)` → 各自 `textureFrameAvailable`；`.windows` → 新窗口 `register`、消失的 `unregisterTexture`；`.closed` → 全部注销后再发 `closed`；1 秒定时器调 `tickTraffic()`。`init` 前收到 `start` → 回 `FlutterError(code: "not_ready")`。
  - Dart：`abstract class SessionPort { Stream<SessionEvent> get events; Future<int> init(); Future<void> start(StartArgs a); void close(Object sid); … 与上面一一对应 }`；`sealed class SessionEvent { Object get sid; }` + `ReadyEvent`、`WindowsEvent(List<RemoteWindow>)`、`TrafficEvent(int)`、`ClipsEvent`、`MenuEvent`、`ComposerStateEvent`、`ComposerInsertEvent`、`TransferEvent`、`DetachedEvent(bool, int?)`、`ClosedEvent(String)`；`class RemoteWindow { id, parent, kind (WindowKind 枚举同 Swift), title, rect, titleBar, resizable, focused, texture, visible; bool get decorated }`；`SessionEvent? parseSessionEvent(String method, Object? args)`（坏数据返回 null，不抛）；`class ChannelSessionPort implements SessionPort`。
  - `FakeSessionPort`：`calls`（`[(method, args)]`）、`emit(SessionEvent)`、`startError`（非空时 `start` 抛）、`doubleClickMs = 500`。

- [ ] **Step 1: 写失败的测试**

```swift
func testStartParses()   // channelCommand("start", ["sid": 3, "port": 5000, "token": "t", "mode": "color16", "fps": 15, "density": "adaptive"]) == .start(sid: 3, port: 5000, token: "t", mode: .color16, fps: 15, density: .adaptive)
func testMouseBecomesAMessage()  // "mouse" kind "down" button "right" x 10.5 y 20 clicks 2 → .mouse(sid: 1, .mouse(kind: .down, button: .right, window: 7, x: 10.5, y: 20, clickCount: 2))
func testBadArgsThrow()          // "start" 少 token、"mouse" kind "hop"、port 70000 → 抛错
func testWindowsPayloadCarriesTextureAndVisible()  // eventPayload(.windows([...]), sid: 1, textures: [7: 42]) 里 windows[0]["texture"] == 42、["visible"] == [0, 0, 1, 0.5]、["kind"] == "menu"
```
```dart
test('parses windows and ignores junk', () {
  final e = parseSessionEvent('windows', {'sid': 1, 'windows': [ {...'kind': 'normal', 'texture': 42, 'visible': [0, 0, 1, 1]} ]});
  expect((e as WindowsEvent).windows.single.texture, 42);
  expect(parseSessionEvent('windows', {'sid': 1, 'windows': 'x'}), isNull);
  expect(parseSessionEvent('nope', {}), isNull);
});
test('closed carries the reason', ...);   // ClosedEvent.reason == 'quit'
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter ChannelTests`、`flutter test test/embed` → 编译失败。
- [ ] **Step 3: 实现** `Channel.swift`、`session_port.dart`、`FakeSessionPort`；runner 的 `SessionPlugin` 和 pbxproj 改动。
- [ ] **Step 4: 跑测试确认通过** — `swift test`、`flutter analyze && flutter test` 全绿；runner 编译检查通过（`flutter build macos --debug`，`FLUTTER_XCODE_ARCHS=arm64`）。
- [ ] **Step 5: Commit** `feat(gui-macos): runner links RappSession; rapp/session channel and SessionPort`

---

### Task 6: `RemoteSession` + `MainState` 接上嵌入会话（含结束顺序和提示）

**Files:**
- Create: `gui/lib/embed/remote_session.dart`
- Modify: `gui/lib/ui/main_state.dart`、`gui/lib/main.dart`（macOS 上构造 `ChannelSessionPort` 并 `await port.init()`，传给 `MainState`）
- Test: `gui/test/embed/remote_session_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Consumes: `SessionPort`、`SessionEvent`（Task 5）；`HubClient.open(embed:)`（Task 4）。
- Produces:
  - `class RemoteSession extends ChangeNotifier { final Object sid; String appName; bool ready; List<RemoteWindow> windows; int? currentWindow; bool detached; int bytesPerSecond; List<ClipRow> clips; List<MenuEntry> menu; StreamChoice choice /* Task 10 */; String? endReason; void apply(SessionEvent e); }`（`currentWindow` 的选择 Task 9 再细化，这里取第一个 decorated）
  - `MainState({…, SessionPort? port})`；`final Map<Object, RemoteSession> remote`；`RemoteSession? get currentRemote`；`bool get embeds => port != null`。
  - `openOrSwitch`：`embeds` 时 `hub.open(id, app, embed: true)` → `port.start(StartArgs(sid, port, token, 'color16', 15, 'adaptive'))`，建 `RemoteSession`；`start` 抛错 → `hub.close(sid)`、提示 `hubWord`；已开的会话 → 只切 `currentKey`，分离着则 `port.raiseDetached(sid)`（不调 `hub.focus`）。
  - `endCurrent`：嵌入会话 → `port.close(sid)`（runner 断 TCP，hub 自己发现）；非嵌入照旧 `hub.close`。
  - 结束合并规则（Review Focus 5）：
    - runner `ClosedEvent` 先到：记 `endReason`，条目立刻从 `_entries` 去掉（`_mapEntries` 过滤 `endReason != null` 的 sid），当前项按 S1 规则移到下一个，提示 `endedHint(appName, reason)` 一次；之后 hub `closed` 到来不再出提示。
    - hub `closed` 先到且 runner 还没报：条目立刻去掉，提示**延后**：等 runner `ClosedEvent` 用它的原因，最多 1 秒；1 秒到了还没来 → `port.close(sid)`、用 hub 原因出提示。
  - `endedHint` 扩展（R23）：先去 `rapp-client: ` 前缀；`quit`/`stdin closed`/null → `已结束 X`；`host says: … quit` → `X 已结束：A 端关闭了 app`；`connection closed` → `X 意外结束：连接断了`；`GUI did not connect` → `X 意外结束：本机没有接上会话`；其他同 S1。

- [ ] **Step 1: 写失败的测试**（`fake_async`；hub 用 `FakeTransport`，port 用 `FakeSessionPort`）

```dart
test('opening embeds: open carries embed, then start with defaults', () { ...
  expect(t.sent.last['embed'], true);
  // emit opened port 5000 token 'tk'
  expect(port.calls.last, ('start', {'sid': 1, 'port': 5000, 'token': 'tk', 'mode': 'color16', 'fps': 15, 'density': 'adaptive'}));
});
test('start failure closes the hub session and hints', ...);  // port.startError = 'boom' → t.sent.last == {'cmd':'close','sid':1}；state.hint == 'boom'
test('end current closes through the port, not the hub', ...); // calls.last == ('close', {'sid':1})；t.sent 里没有 close
test('runner closed first', () { fakeAsync((a) {
  port.emit(ClosedEvent(1, 'host says: Calculator quit'));
  expect(state.sessionCount, 0); expect(state.hint, 'Calculator 已结束：A 端关闭了 app');
  t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'}); a.flushMicrotasks();
  expect(state.hint, 'Calculator 已结束：A 端关闭了 app'); expect(hintChanges, 1);
});});
test('hub closed first', () { fakeAsync((a) {
  t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'}); a.flushMicrotasks();
  expect(state.sessionCount, 0); expect(hintChanges, 0);
  a.elapse(const Duration(milliseconds: 200)); port.emit(ClosedEvent(1, 'quit'));
  expect(state.hint, '已结束 Calculator'); expect(hintChanges, 1);
});});
test('hub closed and runner silent: hub reason after 1 s and port closed', ...);  // elapse 1 s → hint 'Calculator 意外结束：连接断了'；calls 含 ('close', {'sid':1})
test('decode error ends one session, keeps the other', ...);  // 两个会话 1、2，当前 1；ClosedEvent(1, 'cannot decode frame: bad tile') → 当前变 2，remote.containsKey(2)，hint 'Calculator 意外结束：cannot decode frame: bad tile'
test('switching to an open embedded session does not focus through the hub', ...);
test('without a port the S1 path is unchanged', ...);   // port: null → open 不带 embed，没有 start
```
`remote_session_test.dart`：`apply(ReadyEvent)` → `ready`、`appName`；`apply(WindowsEvent)` → `windows`、`currentWindow` 是第一个 decorated；`apply(TrafficEvent(2048))` → `bytesPerSecond == 2048`，每次 apply 只 notify 一次。

- [ ] **Step 2: 跑测试确认失败** → 编译失败。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** `feat(gui): embedded sessions in MainState with one removal and one hint`

---

### Task 7: 舞台画面 + 改尺寸策略

**Files:**
- Create: `gui/lib/embed/geometry.dart`、`gui/lib/embed/resize_policy.dart`、`gui/lib/embed/picture.dart`
- Modify: `gui/lib/ui/stage.dart`（嵌入会话：没 ready/没窗口 → S1 的"正在连接"；有窗口 → `Picture`；非嵌入、或分离着（Task 12）→ 占位）、`gui/lib/ui/main_state.dart`（`stageSize(Size)`、把 `ResizePolicy` 的输出交给 `port.resize`）
- Test: `gui/test/embed/geometry_test.dart`、`gui/test/embed/resize_policy_test.dart`、`gui/test/ui/stage_test.dart`

**Interfaces:**
- Produces:
  - `Rect fitRect(Size content, Size box)`：等比放进 `box`、居中；任一边 ≤0 返回 `Rect.zero`。
  - `Rect pictureRect(Rect fit, Rect visible)` = `Rect.fromLTWH(fit.left + visible.left * fit.width, fit.top + visible.top * fit.height, visible.width * fit.width, visible.height * fit.height)`。
  - `Offset toRemote(Offset local, Rect fit, RemoteWindow w)` → A 点坐标（窗口左上为原点，y 加 `titleBar`）：`x = (local.dx - fit.left) / fit.width * w.rect.width`，`y = w.titleBar + (local.dy - fit.top) / fit.height * (w.rect.height - w.titleBar)`。
  - `Size contentSize(RemoteWindow w)` = `(w.rect.width, w.rect.height - w.titleBar)`。
  - `class ResizePolicy { ResizePolicy(void Function(int window, int w, int h) send); void stage(Size s); void current(RemoteWindow? w); void dispose(); }`：`current` 换了窗口（id 变）→ 立刻判一次；`stage` 变了 → 0.3 秒 `Timer` 节流后判一次；判 = 窗口 `resizable` 且 `(s.width.round(), s.height.round()) != contentSize(w).rounded` 才 `send`；同一窗口后续 `windows` 更新（A 给的尺寸）不触发。
  - `Picture({required RemoteSession session, required RemoteWindow window})`：`LayoutBuilder` 里 `fitRect(contentSize(window), box)`，底色 `t.bg`，`Positioned.fromRect(pictureRect(...))` 放 `Texture(textureId: window.texture)`；舞台的 `LayoutBuilder` 把尺寸报给 `state.stageSize`。
  - R25：`Backdrop({theme, child, ValueListenable<Rect?>? hole})`；公开 `class HoloGrid extends CustomPainter { HoloGrid(Color on, {Rect? hole}); }`；`MainState.pictureHole: ValueNotifier<Rect?>`，`main_window.dart` 把它传给 `Backdrop`。改动文件加 `gui/lib/ui/backdrop.dart`、`gui/lib/ui/main_window.dart`。

- [ ] **Step 1: 写失败的测试**

```dart
test('fitRect letterboxes', () => expect(fitRect(const Size(200, 100), const Size(400, 400)), const Rect.fromLTWH(0, 100, 400, 200)));
test('toRemote adds the title bar', ...);  // w rect 0,0,200,128 titleBar 28；fit 0,100,400,200；local (200, 200) → (100, 78)
test('pictureRect places the visible part', ...);  // visible (0, 0, 1, .5) → 上半
test('tab switch resizes at once', () { fakeAsync((a) {
  p.stage(const Size(800, 600)); a.elapse(const Duration(milliseconds: 400)); sent.clear();
  p.current(win(2, 640, 480 + 28, resizable: true));
  expect(sent, [(2, 800, 600)]);
});});
test('stage resize settles then sends once', () { fakeAsync((a) {
  p.current(win(1, 800, 628)); sent.clear();
  for (final w in [810.0, 820, 830]) { p.stage(Size(w, 600)); a.elapse(const Duration(milliseconds: 100)); }
  expect(sent, isEmpty); a.elapse(const Duration(milliseconds: 300)); expect(sent, [(1, 830, 600)]);
});});
test('A refusing the size does not trigger another resize', ...);  // current(同 id、A 回 700×528) → sent 不变
test('non-resizable windows are left alone', ...);
testWidgets('overlays never resize', (t) async {
  // MainWindow + FakeSessionPort；一个 ready 会话、窗口和舞台同尺寸；calls 里 resize 清零
  await tester.tap(find.byTooltip('会话'));        // 左侧面板开、关
  await tester.tap(find.byKey(const Key('traffic'))); // 串流菜单（Task 10 起有；本 Task 先测面板）
  await tester.pump(const Duration(seconds: 1));
  expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
});
testWidgets('stage shows connecting, then the texture', ...);  // 无 windows → find.text('正在连接')；WindowsEvent 后 find.byType(Texture) 的 textureId == 42
testWidgets('IRON MAN grid leaves the picture uncovered', ...);  // ironMan 主题、一个 ready 会话：找到 painter is HoloGrid 的 CustomPaint，hole == Texture 的全局矩形（tester.getRect(find.byType(Texture))）；会话结束后 hole == null
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** `feat(gui): stage shows the remote picture; stage size drives A's window size`

---

### Task 8: 指针和键盘（焦点规则、⌃⌘ 保留键、滚动方向、触控板）

**Files:**
- Create: `Sources/RappSession/KeyRouting.swift`
- Modify: `gui/macos/Runner/SessionPlugin.swift`（`NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged])`；`picture_focus`；主窗口 `didResignKey` → 补抬起）
- Create: `gui/lib/embed/pointer.dart`
- Modify: `gui/lib/embed/picture.dart`（`Listener`、焦点边框）、`gui/lib/ui/main_state.dart`（`focusPicture`、`blurPicture`、`pictureFocused`）、`gui/lib/ui/main_window.dart`（macOS 快捷键改 ⌃⌘[ ⌃⌘] ⌃⌘D；顶栏和浮层套 `Listener`，R24）
- Test: `Tests/RappSessionTests/KeyRoutingTests.swift`、`gui/test/embed/pointer_test.dart`、`gui/test/ui/stage_test.dart`、`gui/test/ui/main_window_test.dart`

**Interfaces:**
- Produces（Swift）：
  - `public enum KeyRoute: Equatable { case local, remote }`
  - `public func routeKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, pictureFocused: Bool) -> KeyRoute`：`flags` 同时含 `.control` 和 `.command` → `.local`；`flags ∩ [.command, .control, .option, .shift] == [.command]` 且 `keyCode == 12`（Q）→ `.local`；否则 `pictureFocused ? .remote : .local`。
  - `public struct KeyTracker { public mutating func down(_ code: UInt16); public mutating func up(_ code: UInt16); public mutating func releaseAll() -> [UInt16] /* 升序 */ }`；修饰键 `flagsChanged` 按 keyCode（54–63）和该修饰位是否还在判断按下/抬起。
  - runner：`.remote` → 发 `.key(keyCode:, modifiers: UInt64(event.modifierFlags.rawValue), down:)` 给当前有焦点的会话（或事件所在的分离窗口的会话，Task 12），返回 `nil` 吃掉；`.local` → 原样返回给 Flutter。`picture_focus` 换 sid / 置空、主窗口失去 key → `releaseAll()` 逐个发抬起。
- Produces（Dart）：
  - `class ClickCounter { ClickCounter(Duration interval, {double slop = 4}); int down(Offset p, Duration time, int button); }`
  - `Offset wheelToRemote(Offset scrollDelta) => -scrollDelta`；`Offset panToRemote(Offset localPanDelta) => localPanDelta`。
  - `Picture` 的 `Listener`：`onPointerDown`（`kPrimaryButton` → left、`kSecondaryButton` → right；落点不在 `pictureRect` 里不发；先 `state.focusPicture(sid)`）、`onPointerMove`（按着 → drag，坐标夹进 fit）、`onPointerUp`（夹进 fit）、`onPointerHover`（只对 kind == menu 的附属窗口发 move，Task 9）、`onPointerSignal`（`PointerScrollEvent` → `wheelToRemote`）、`onPointerPanZoomUpdate`（`panToRemote`）。
  - `MainState.focusPicture(Object sid)` → `port.pictureFocus(sid)`、`pictureFocused = sid`；`blurPicture()` → `port.pictureFocus(null)`；换当前会话时先 `blurPicture()`。焦点在画面上时画面外一圈 1px `t.on` 边。

- [ ] **Step 1: 写失败的测试**

```swift
func testRouteKey() {
    XCTAssertEqual(routeKey(keyCode: 3, flags: [.control, .command], pictureFocused: true), .local)   // ⌃⌘F
    XCTAssertEqual(routeKey(keyCode: 2, flags: [.control, .command], pictureFocused: true), .local)   // ⌃⌘D
    XCTAssertEqual(routeKey(keyCode: 33, flags: [.control, .command], pictureFocused: true), .local)  // ⌃⌘[
    XCTAssertEqual(routeKey(keyCode: 12, flags: [.command], pictureFocused: true), .local)            // ⌘Q
    XCTAssertEqual(routeKey(keyCode: 53, flags: [], pictureFocused: true), .remote)                   // Esc
    XCTAssertEqual(routeKey(keyCode: 13, flags: [.command], pictureFocused: true), .remote)           // ⌘W
    XCTAssertEqual(routeKey(keyCode: 33, flags: [.command], pictureFocused: true), .remote)           // ⌘[
    XCTAssertEqual(routeKey(keyCode: 12, flags: [.command, .shift], pictureFocused: true), .remote)   // ⇧⌘Q
    XCTAssertEqual(routeKey(keyCode: 53, flags: [], pictureFocused: false), .local)
}
func testKeyTrackerReleasesHeldKeys() {
    var k = KeyTracker(); k.down(0); k.down(56); k.down(0); k.up(0); k.down(11)
    XCTAssertEqual(k.releaseAll(), [11, 56]); XCTAssertEqual(k.releaseAll(), [])
}
```
```dart
test('click counter counts within interval and slop', ...);  // 500 ms：t0 (0,0) → 1；t300 (3,0) → 2；t600 (3,0) → 3；t700 (10,0) → 1；t1300 (10,0) → 1；换 button → 1
test('wheel is flipped, trackpad pan passes through', () {
  expect(wheelToRemote(const Offset(0, 40)), const Offset(0, -40));
  expect(panToRemote(const Offset(0, 12)), const Offset(0, 12));
});
testWidgets('picture focus follows taps', (t) async {
  await t.tapAt(pictureCenter); expect(port.calls, contains(('picture_focus', {'sid': 1}))); expect(border, findsOneWidget);
  await t.tapAt(topBarPoint);   expect(port.calls.last, ('picture_focus', {'sid': null}));   expect(border, findsNothing);
});
testWidgets('down outside the picture is not sent; drag is clamped', ...);  // 边上留白处 down → 没有 mouse；里面 down 后拖到外面 → drag 的 x == 窗口宽
testWidgets('right button sends right', ...);
testWidgets('mouse down sends A points and click count', ...);  // calls 里 ('mouse', {kind:'down', button:'left', window:7, x:100, y:78, clicks:1})
testWidgets('ctrl-cmd brackets step sessions; cmd brackets no longer do', ...);  // macOS：⌃⌘] → 当前变下一个；⌘] → 不变
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败 / 断言失败。
- [ ] **Step 3: 实现**（Swift 纯函数、runner 监视器、Dart pointer 和焦点）。
- [ ] **Step 4: 跑测试确认通过** — `swift test`、`flutter analyze && flutter test` 全绿；runner 编译检查通过。
- [ ] **Step 5: Commit** `feat(gui): pointer, scroll and keyboard reach A; only ctrl-cmd chords stay with rapp`

---

### Task 9: 多窗口标签和附属窗口

**Files:**
- Create: `gui/lib/embed/window_tabs.dart`
- Modify: `gui/lib/embed/remote_session.dart`（用 `WindowTabs` 定 `currentWindow`；`selectWindow(int id)`）、`gui/lib/ui/top_bar.dart`（标签）、`gui/lib/embed/picture.dart`（附属窗口叠画）、`gui/lib/embed/geometry.dart`（`popupRect`）
- Test: `gui/test/embed/window_tabs_test.dart`、`gui/test/embed/geometry_test.dart`、`gui/test/ui/top_bar_test.dart`

**Interfaces:**
- Produces:
  - `class WindowTabs { int? get current; List<RemoteWindow> get tabs; void update(List<RemoteWindow> all); void select(int id); }`：`tabs` = `decorated` 的，按 A 给的顺序；`update` 里新出现的 decorated 窗口成为 current（多个新的取表里最前的）；current 消失 → MRU 里最近用过、还在的那个；都没了 → null。MRU 由 `select` 和"新窗口成为 current"推进。
  - `Rect popupRect(RemoteWindow popup, RemoteWindow parent, Rect parentPicture)`（`popupFrame` 的 Dart 版：`scale = parentPicture.width / contentSize(parent).width`，以 parent 内容左上为原点）；parent 找不到 → 用当前窗口（R8）。
  - `RemoteSession.selectWindow(id)` → `tabs.select(id)`、`port.selectWindow(sid, id)`（runner 发 `.focus(id)` = 今天的 raise）、`ResizePolicy.current(...)`（立刻判一次，Task 7）。
  - 顶栏：`tabs.length >= 2` 时在会话名后显示标签（`TabChip`，48px 高，标题 `TextOverflow.ellipsis`、最大宽 200），当前标签选中样式。
  - 附属窗口：`Picture` 的 `Stack` 里按表的逆序（后面的先画）叠 `Texture`，各自的 `Listener` 收指针；kind == menu 时 hover 发 `move`。

- [ ] **Step 1: 写失败的测试**

```dart
test('new window becomes current; closing current falls back to MRU', () {
  tabs.update([w(1), w(2)]); expect(tabs.current, 1);
  tabs.select(2); tabs.update([w(1), w(2), w(3)]); expect(tabs.current, 3);
  tabs.update([w(1), w(2)]); expect(tabs.current, 2);
  tabs.update([w(1)]); expect(tabs.current, 1);
  tabs.update([]); expect(tabs.current, isNull);
});
test('popups and sheets are not tabs', ...);  // [w(1), menu(5), sheet(6, parent:1)] → tabs.map(id) == [1]
test('popupRect scales from the parent picture', ...);  // parent content 200×100 at (0,28)，parentPicture (0,0,400,200)，popup rect (50,48,20,10) → (100, 40, 40, 20)
testWidgets('tabs appear at two windows and switch on tap', ...);  // 1 个窗口 → 无标签；2 个 → 两个标签；点第二个 → calls 含 ('select_window', {'sid':1,'window':2}) 和一条 resize
testWidgets('popup over a missing parent draws over the current window', ...);
testWidgets('hover over a menu popup sends move, over a normal window not', ...);
```

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** `feat(gui): window tabs and popups drawn over their parent`

---

### Task 10: 流量标签 + 串流菜单（含 A 的剪贴板和镜像菜单）

**Files:**
- Create: `gui/lib/embed/traffic_label.dart`、`gui/lib/embed/stream_choice.dart`、`gui/lib/embed/stream_menu.dart`
- Modify: `gui/lib/ui/top_bar.dart`（顶栏右端流量标签，`Key('traffic')`；点或右键打开菜单）、`gui/lib/embed/remote_session.dart`（`choice`、`setChoice`）
- Modify: `Sources/RappSession/Channel.swift`（`menu` 事件带 `shortcut`；`clipboard` 事件；`clip_pick`、`menu_pick`、`move_top_left` 解析）、`Sources/RappSession/EmbeddedSession.swift`（`pickClip(_:insert:)` 走 `ClipHistory.pick`；`menuPick`、`moveToTopLeft` 用 `moveToTopLeftMessages`）
- Test: `gui/test/embed/traffic_label_test.dart`、`gui/test/embed/stream_menu_test.dart`、`Tests/RappSessionTests/ChannelTests.swift`

**Interfaces:**
- Produces（Dart）：
  - `int levelBars(int bytesPerSecond)`：0 → 0；<5 KB/s → 1；<15 → 2；<40 → 3；<100 → 4；否则 5（KB = 1000 B，同 `formatRate`）。
  - `String formatRate(int bytes)`：0 → `0 KB/s`；kb < 1000 → `%.1f KB/s`；否则 `%.1f MB/s`（同 RappCore）。
  - `TrafficLabel`：5 根柱，3px 宽、高 4–12px 递增；亮 `t.on`、暗 `t.line`；数字 `--mono`；菜单开着时用选中样式；`Semantics(label: '流量 <数字>，打开串流菜单')`。
  - `class StreamChoice { final String mode; final String density; final int fps; }`；`const presetLeast = StreamChoice('duogray', 'adaptive', 1)`、`presetSharpest = StreamChoice('color16', 'original', 15)`；起始 `StreamChoice('color16', 'adaptive', 15)`（R11）。
  - `StreamMenu`（浮层，选了就收）分组：
    1. 预设：「最省流（双色·灰度 + 自适应 + 1 fps）」「最清晰（高彩 + 原画 + 15 fps）」
    2. 档位：「双色·灰度（文本优化）」「双色·彩色」「高彩（图像优化）」
    3. 密度：「省流 1x」「自适应」「原画」
    4. 帧率：「1 fps」「5 fps」「15 fps」「30 fps（看视频）」
    5. A 的剪贴板：最新两条（`historyTitle`，不可取的灰掉）+ 「全部剪贴板」（就地展开到 20 条）；每条右侧「插入」；空 → 「（空）」（R5）
    6. 会话：路径（`pathLabels`）、「分离成独立窗口」/「放回主窗口」（Task 12 接上）、「放左上角」、「结束会话」（`ConfirmButton` 点两次）
    7. A 的菜单：顶层标题逐个，点进去逐级展开；分隔线、灰掉、勾选、`shortcut` 文字照显示；点叶子 → `port.menuPick(sid, path)`（path 含分隔线下标，同 `MirroredMenu`）（R22）
  - 当前选中项打勾；选 1–4 组 → `session.setChoice(c)` → `port.setStream(sid, c.mode, effectiveFps(...) /* Task 13 前等于 c.fps */, c.density)`。

- [ ] **Step 1: 写失败的测试**

```dart
test('level bars thresholds', () => expect([0, 4999, 5000, 14999, 39999, 99999, 100000].map(levelBars), [0, 1, 2, 2, 3, 4, 5]));
test('formatRate', () => expect([0, 1500, 999949, 2500000].map(formatRate), ['0 KB/s', '1.5 KB/s', '999.9 KB/s', '2.5 MB/s']));
testWidgets('traffic label opens the menu by tap and by right click', ...);
testWidgets('picking a preset sets stream and closes the menu', ...);  // 点「最省流…」→ calls.last == ('set_stream', {'sid':1,'mode':'duogray','fps':1,'density':'adaptive'})；菜单消失
testWidgets('clipboard group shows two, expands to all, insert is a button', ...);  // 5 条 clips → 两条 + 「全部剪贴板」；点后 5 条；点「插入」→ ('clip_pick', {'sid':1,'clip':5,'insert':true})；点行 → insert:false
testWidgets('end session needs two taps', ...);
testWidgets('A menu drills down and picks by path', ...);  // items [文件[新建, —, 关闭]] → 点「文件」再点「关闭」→ ('menu_pick', {'sid':1,'path':[0,2]})
```
```swift
func testMenuPayloadCarriesShortcutText()   // MenuItem(key:"n", modifiers: command) → ["shortcut"] == shortcutText(key:"n", modifiers: …)
func testClipPickParses()                   // channelCommand("clip_pick", ["sid":1,"clip":5,"insert":true])
```

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** — `swift test`、`flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** `feat(gui): traffic label and stream menu with A's clipboard and menus`

---

### Task 11: 输入区

**Files:**
- Create: `Sources/RappSession/EmbeddedComposer.swift`
- Modify: `Sources/RappSession/EmbeddedSession.swift`（持有 `EmbeddedComposer`；`.pasted` 交给 `Sender`；`transfer` 状态转发）、`Sources/RappSession/SessionEvent.swift`（`ComposerEvent` 填全）、`Sources/RappSession/Channel.swift`
- Modify: `gui/macos/Runner/SessionPlugin.swift`（`composer_attach` 开 `NSOpenPanel`，多选文件、可选目录以便报错）
- Create: `gui/lib/embed/composer_model.dart`、`gui/lib/embed/composer_bar.dart`
- Modify: `gui/lib/ui/stage.dart`（右下角「输入」按钮、底部浮出的输入条，盖在画面上）
- Test: `Tests/RappSessionTests/EmbeddedComposerTests.swift`、`gui/test/embed/composer_model_test.dart`、`gui/test/embed/composer_bar_test.dart`

**Interfaces:**
- Produces（Swift）：
  - `public enum ComposerEvent: Equatable { case sending(Bool), done(sent: Int, failure: String?), insert(PasteResult) }`；`public enum PasteResult: Equatable { case text(String), blocks([BlockChip]), status(String), nothing }`；`public struct BlockChip: Equatable { n: Int; label: String }`
  - `public final class EmbeddedComposer: ComposerSink { init(pasteboard: LocalPasteboard, transfers: TransferQueue, counters: SendCounters, send: @escaping (Message) -> Void, emit: @escaping (ComposerEvent) -> Void) }`：
    - `func paste() -> PasteResult`：`pasteDecision(types:text:)` → `inlineText` → `.text`；`textChunk`/`image`/`data`/`files` → 存进 `ComposerBlocks` → `.blocks`；`nothing` → `.nothing`。
    - `func attach(_ urls: [URL]) -> PasteResult`：目录 → `.status("不支持文件夹：<name>")`；单个 > 256 MB → `.status("太大了，A 最多收 256 MB")`；否则 `.blocks`。
    - `func send(_ pieces: [ComposerPiece])` → `Sender.start(pieces:)`；`func drop(_ n: Int)`；`func insert(_ info: ClipInfo, _ p: InsertPayload)`（剪贴板「插入」→ `.insert(...)`）。
  - 上传状态文字 `i/n`、`i/n · name` 沿用 `Transfers`，经 `transfer {status}` 下发；`cancel_transfer` → `TransferQueue.cancel()`。
- Produces（Dart）：
  - `class ComposerModel extends ChangeNotifier { String text; List<BlockChip> blocks; bool open; bool sending; String? status; List<Map<String, Object>> pieces(); SendOutcome send(); void done(int sent, String? failure); void esc(); void copyPressed(); void clipArrived(); }`：
    - `pieces()` = 块按加入顺序 `{'block': n}`，再 `{'text': text}`（文字非空才有）（R3）。
    - `send()`：空 → `status = '按键直接发给 A'`（R16），返回 `SendOutcome.empty`；`sending` 时忽略；否则记快照、返回 `SendOutcome.sent`。
    - `done(sent, failure)`：内容和快照相同 → 去掉前 `sent` 个 piece（全发完则清空）；不同 → `status = '（发送中改过内容，未清除）'`；`failure != null` → `status = failure`；status 5 秒后清。
    - `esc()`：文字非空 → 清空文字；已空 → `open = false`（R16）。
    - `copyPressed()` → 由调用方 `port.key(sid, 8, 1048576)`（⌘C）；`status = '已复制'`；2 秒内 `clipArrived()` 没来 → `status = 'A 上没有复制到东西'`，再 2 秒清。
  - `ComposerBar`：`[按键] [附件] [多行输入框 + 块] [复制] [发送] [收起]`，块是输入框上方一排虚线 chip（点一下 → `port.composerDropBlock` + 移除）；Enter 发送，Shift+Enter 换行，`TextEditingValue.composing` 非空时 Enter 归输入法；⌘V → `port.composerPaste`，结果 `.text` 插到光标处、`.blocks` 加 chip、`.status` 显示；输入框得到焦点 → `state.blurPicture()`。
  - 「按键」行（弹出一排）：Esc 53、Tab 48、⌘（粘滞，1048576）、⌥（粘滞，524288）、← 123、→ 124、↓ 125、↑ 126、删除 51、回车 36；点键 → `port.key(sid, code, 粘滞修饰位)`，然后粘滞位清零。
  - 草稿和展开状态存在 `RemoteSession.composer`（R18）。

- [ ] **Step 1: 写失败的测试**

```swift
func testPasteShortTextIsInline()       // 测试 board 写 "hi" → paste() == .text("hi")
func testPasteLongTextBecomesABlock()   // 900 字符 → .blocks([BlockChip(n: 1, label: "[贴入文字 #1 +1 行]")])
func testPastePNGBecomesImageBlock()    // board 写 10×20 PNG → label "[图片 #1 10×20]"
func testAttachFolderIsRefused()        // 临时目录 → .status("不支持文件夹：<name>")
func testSendOrderAndDone()             // send([.chunk(1), .text("x")])：块（小文字块走 inline paste，大块走 put 上传——用小块）→ sent 依次两条 .paste；两个 pasted 成功 → emit .done(sent: 2, failure: nil)
```
```dart
test('pieces are blocks in insert order, then text', ...);  // blocks [3, 1] + text 'x' → [{'block':3}, {'block':1}, {'text':'x'}]
test('empty send hints', ...);  // send() == empty；status == '按键直接发给 A'
test('done clears what was sent if unchanged, else notes', ...);
test('esc clears text, then collapses', ...);
test('copy reports nothing copied after 2 s', () { fakeAsync((a) { m.copyPressed(); expect(m.status, '已复制'); a.elapse(const Duration(seconds: 2)); expect(m.status, 'A 上没有复制到东西'); });});
testWidgets('enter sends, shift-enter newlines, enter while composing does not send', ...);
testWidgets('keys row sends codes with sticky command', ...);  // 点 ⌘ 再点 ← → ('key', {'sid':1,'keyCode':123,'modifiers':1048576})；再点 ← → modifiers 0
testWidgets('opening the composer does not resize A', ...);   // calls 里没有 resize
testWidgets('tapping a block removes it', ...);
```

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** — `swift test`、`flutter analyze && flutter test` 全绿；runner 编译检查通过。
- [ ] **Step 5: Commit** `feat(gui): composer on the stage, sending through RappSession`

---

### Task 12: 分离和放回

**Files:**
- Create: `Sources/RappSession/Detach.swift`（纯几何）
- Create: `gui/macos/Runner/DetachedWindow.swift`（加进 pbxproj：PBXFileReference、PBXBuildFile、Runner 组、Sources 阶段）
- Modify: `gui/macos/Runner/SessionPlugin.swift`（`detach`/`attach`/`raise_detached`；按键监视器认分离窗口）
- Modify: `gui/lib/ui/main_state.dart`（`detach`、`attach`、`toggleDetach`）、`gui/lib/ui/stage.dart`（分离占位）、`gui/lib/ui/main_window.dart`（⌃⌘D）、`gui/lib/embed/stream_menu.dart`（第 6 组）
- Test: `Tests/RappSessionTests/DetachTests.swift`、`gui/test/ui/main_state_test.dart`、`gui/test/ui/stage_test.dart`、`gui/test/ui/main_window_test.dart`

**Interfaces:**
- Produces（Swift）：
  - `public func detachedFrames(contents: [CGSize], screen: CGRect, beside main: CGRect) -> [CGRect]`（AppKit 坐标）：每个尺寸先夹进 `screen`；第一个放 `main.maxX` 右边、顶对齐 `main.maxY`；放不下放 `main.minX` 左边；还不行 `main.origin + (24, -24)`；第 i 个再错开 `(24i, -24i)`，整体夹回 `screen`（R20）。
  - runner `DetachedWindow`：`final class DetachedSession { init(session: EmbeddedSession, windows: [SessionWindow], onAttach: @escaping () -> Void); func update(_ windows: [SessionWindow]); func surfacesUpdated(_ ids: [UInt32]); var lastKey: UInt32?; func close() /* 不结束会话 */ }`；每个普通窗口一个 `NSWindow`（`contentView` = `RemoteView`，`layer.contents` = 该窗口 IOSurface），附属窗口用 `PopupPanel`；`windowShouldClose` → `session.close(reason: "quit")`；`windowDidBecomeKey` → `lastKey`、`.focus(id)`；`windowDidResize` 停 0.3 秒（`PendingActions`）按 R12 规则发 `.resize`；表里普通窗口变 0 个 → `onAttach()`（R7）。
  - 按键：事件的 window 是某个分离窗口时，`⌃⌘D`（keyCode 2）→ 放回；⌘Q → 本地；其余 → 该会话（同一个 `KeyTracker`）。
  - channel：`detach {sid}` → 建 `DetachedSession`，回 `detached {detached:true}`；`attach {sid}` 或分离窗口里 ⌃⌘D → 关掉窗口、回 `detached {detached:false, current: lastKey}`（R21）；`raise_detached {sid}` → `orderFront` 全部、`lastKey` 那个 `makeKeyAndOrderFront`。
- Produces（Dart）：
  - `MainState.detach()` / `attach()` / `toggleDetach()`（作用于当前会话）：`port.detach(sid)`；收到 `DetachedEvent(true)` → `session.detached = true`、`hub.note(sid, 'detach', 普通窗口数)`；`DetachedEvent(false, current)` → `detached = false`、`tabs.select(current)`、`hub.note(sid, 'attach', n)`、`ResizePolicy.current(...)`（舞台尺寸和 A 不同则发一次）。分离和放回都不调 `hub.open`、不换 sid。
  - 分离占位（舞台）：`<app> 在单独的窗口里 · <设备> · <路径>`；按钮「切到窗口」（`port.raiseDetached`）、「放回主窗口」（`attach`）、「结束会话」（两次确认）；右下角「输入」按钮仍在；顶栏流量标签对这个会话照常。
  - 快捷键：macOS ⌃⌘D → `toggleDetach()`（焦点在画面上时 ⌃⌘ 归 rapp，所以也走 Flutter）。

- [ ] **Step 1: 写失败的测试**

```swift
func testDetachedFramesGoRightOfMainWhenRoom()   // screen (0,0,2000,1200)，main (100,200,800,800)，content 600×400 → x == 900, maxY == 1000
func testDetachedFramesFallBackLeftThenOffset()  // main 贴右边 → 放左边；两边都不够 → main.origin + (24, -24)
func testDetachedFramesClampToScreenAndCascade() // 3000×2000 夹成 2000×1200；第二个窗口错开 24
```
```dart
test('detach and attach keep the sid and send no open', () {
  state.toggleDetach(); expect(port.calls.last, ('detach', {'sid': 1}));
  port.emit(DetachedEvent(1, true)); expect(t.sent.last, {'cmd': 'note', 'sid': 1, 'what': 'detach', 'windows': 1});
  state.toggleDetach(); port.emit(DetachedEvent(1, false, current: 7));
  expect(t.sent.where((m) => m['cmd'] == 'open').length, 1); expect(state.currentRemote!.sid, 1);
  expect(state.currentRemote!.tabs.current, 7);
});
test('closing the detached window ends the session', ...);  // detached 时 ClosedEvent(1, 'quit') → sessionCount 0，hint '已结束 Calculator'
testWidgets('ctrl-cmd-D toggles both ways', ...);  // ⌃⌘D → ('detach'…)；emit detached true；⌃⌘D → ('attach'…)
testWidgets('detached placeholder shows the words and buttons', ...);  // find.text('Calculator 在单独的窗口里 · mini · 局域网')、「切到窗口」「放回主窗口」「结束会话」、「输入」
testWidgets('stream menu offers detach or attach by state', ...);
```

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**（`RemoteView` 的 IOSurface 显示 Task 2 已有；`DetachedWindow.swift` 加进 pbxproj）。
- [ ] **Step 4: 跑测试确认通过** — `swift test`、`flutter analyze && flutter test` 全绿；runner 编译检查通过。
- [ ] **Step 5: Commit** `feat(gui-macos): detach a session into native windows and attach it back`

---

### Task 13: 不在舞台上的会话降到 1 fps

**Files:**
- Modify: `gui/lib/embed/stream_choice.dart`、`gui/lib/ui/main_state.dart`
- Test: `gui/test/embed/stream_choice_test.dart`、`gui/test/ui/main_state_test.dart`

**Interfaces:**
- Produces:
  - `int effectiveFps(StreamChoice c, {required bool onStage, required bool detached}) => (onStage || detached) ? c.fps : 1;`（R6）
  - `MainState._applyFps()`：当前会话变、分离/放回、会话开始、`setChoice` 之后调用；对每个 `RemoteSession` 算 `effectiveFps`，和上次发的不同才 `port.setStream(sid, mode, fps, density)`；`session.choice` 不变（菜单仍显示用户选的帧率）。

- [ ] **Step 1: 写失败的测试**

```dart
test('effectiveFps', () {
  const c = StreamChoice('color16', 'adaptive', 30);
  expect(effectiveFps(c, onStage: true, detached: false), 30);
  expect(effectiveFps(c, onStage: false, detached: false), 1);
  expect(effectiveFps(c, onStage: false, detached: true), 30);
});
test('switching away drops to 1 fps and back restores the chosen rate', ...);
  // 会话 1（选 30）、2；当前 1 → 选 2：calls 含 ('set_stream', {'sid':1,'fps':1,…})；切回 1：('set_stream', {'sid':1,'fps':30,…})；session(1).choice.fps 仍 30
test('ten sessions: only the current one streams above 1 fps', ...);
test('a detached session keeps its rate when another is current', ...);
test('no duplicate set_stream when nothing changed', ...);
```

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿。
- [ ] **Step 5: Commit** `feat(gui): off-stage sessions stream at 1 fps`

---

### Task 14: 实机检查、打包、记录

由 controller 派的实机检查子代理执行，全程守 Global Constraints 的安全规则。

**Files:**
- Modify: `tasks/todo.md`（S2 一节，规格 §7 每条一行，写验证方式和结果）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-s2-embedded-stage-design.md` 状态行后加"S2 已实现（计划 `docs/superpowers/plans/2026-11-12-rapp-s2-embedded-stage.md`）"
- Modify: `tasks/lessons.md`（只在这次真学到东西时加）

- [ ] **Step 1: 全量验证** — `cargo test --workspace`、`cargo clippy --workspace --all-targets`；`./scripts/check.sh` 末行 `EXIT=0`；`flutter analyze`、`flutter test`。
- [ ] **Step 2: 搭环境（只用自己起的进程，每个都记 PID 文件）** — 在 scratchpad 新建 `s2live/{A,B,bin}`，照 `scratchpad/s1live` 的做法：`A` 是 rapp-service 的 `RAPP_HOME`（临时端口，不用 47800、21116–21119），`B` 是 GUI 的 `RAPP_HOME`（`gui.json`、`hosts.json`），`bin` 放本次构建的 `rapp-client`、`rapp-host`、`rapp-hub`、`rapp-service`（`RAPP_BIN_DIR` 指向它）；从 `s1live` 复制 `key.sh`（发键前确认最前 app 的 unix id 等于 `gui.pid`）、`shot.sh`（`screencapture -x -o -l <自己窗口 id>`）、`tclick.sh`（`topat` 返回 rapp 才点）、`onscreen`，路径改到 `s2live`。GUI 用本次 `flutter build macos --release`（`FLUTTER_XCODE_ARCHS=arm64`）的 app，照 s1live 的方式起并写 `gui.pid`。目标 app：`pgrep -x Calculator` 为空才 `open -g -a Calculator`，紧接着记下新 PID 到 `calc.pid`；第二个会话用 Chess（同样先确认没在跑）；任一已在跑就跳过那一项并记下来。设备用 `id@127.0.0.1` 加。
- [ ] **Step 3: 逐条对规格 §7 检查**（每条截一张自己窗口的图存 `s2live/`）：
  1. 打开 Calculator：画面在舞台上；`pgrep -P <hub pid>` 没有 `rapp-client`；`onscreen` 里 GUI PID 只有主窗口。
  2. 用 `tclick.sh` 点画面里的数字键（每次先 `topat`）：A 上计算器显示变；点画面后 `key.sh` 打数字、Esc（计算器清零）；⌃⌘F 进出全屏。
  3. 开合左侧面板、串流菜单、输入区：`s2live/A` 的 host 日志里没有新的 resize 记录。
  4. 改主窗口大小（System Events 只按 `unix id is <gui.pid>` 定位进程）：停下后 host 日志里恰好一条 resize，尺寸 = 舞台尺寸。
  5. 画面有焦点时 ⌘T（计算器的纸带窗口）：出现两个标签；点标签切窗口，A 上窗口提前。
  6. ⌃⌘D：出现独立窗口、舞台变占位、画面不黑；独立窗口里点一下数字键有效（`topat` 先确认）；独立窗口里 ⌃⌘D 放回；hub 日志里 `detach`、`attach` 各一行，A 端日志没有新会话。
  7. 再分离，点独立窗口的关闭按钮（`topat` 先确认）：会话结束，提示"已结束 Calculator"。
  8. 重新打开 Calculator，再打开 Chess 并切过去：Calculator 的流量标签数字（切回前从会话列表看不到时，看 hub/host 日志的 setStream fps 1）降到 1 fps 的量级；切回恢复。
  9. CPU：Calculator 会话设 30 fps，`ps -o %cpu -p <gui pid>` 每秒采一次共 15 次取平均；再对同一个 host 手动起一个独立 `rapp-client`（`--token-env`，同 S1 的起法，记 PID），同样采；记录两者，GUI 不应高于独立 client。独立 client 也确认画面正常（IOSurface 显示，R17）。
  10. 滚动方向：Calculator 没有可滚内容的话记"未实机验证，单测覆盖"（Task 8）；不去打开用户的文档。
  11. 最后在画面有焦点时 ⌘W 关掉计算器窗口（A 上 Calculator 退出）：提示"Calculator 已结束：A 端关闭了 app"。
  12. 不点剪贴板条目、不按「复制」「插入」、不 ⌘V（会碰系统剪贴板）；坏帧那条由 Task 3、Task 6 的单测覆盖，在 todo 里写明。
- [ ] **Step 4: 收尾** — 按 PID 文件逐个 `kill` 自己起的 GUI、Chess、Calculator（还在的话）、独立 client、hub、service；`ps -p` 确认都没了。
- [ ] **Step 5: 打包** — `scripts/package-macos.sh`；不替换 `/Applications/rapp.app`，不重启已装的 rapp-service。
- [ ] **Step 6: Commit** `docs: S2 done — live check, todo, spec status`

---

## Self-review

- **规格覆盖**：§2.1 打开即嵌入、切会话 → Task 6、7；1 fps → Task 13。§2.2 等比、0.3 秒、浮层不改尺寸、只改当前窗口、附属窗口叠画 → Task 7、9。§2.3 标签、raise、新窗口成当前、关当前回 MRU → Task 9。§2.4 指针、焦点边框、⌃⌘ 规则、⌘Q、S1 快捷键改名、输入法不经画面、滚动方向和触控板 → Task 8。§2.5 输入区 → Task 11。§2.6 串流菜单第 6 组 → Task 10、12。§2.7 分离、放回、占位、关窗即结束、不记盘 → Task 12（不记盘：`detached` 只在 `RemoteSession` 里）。§2.8 连接中和结束提示 → Task 6、7。§3 纹理 + 链库、直接解码进 IOSurface、`rapp-client` 也受益 → Task 1、2、5。§4 每一条 → Task 1–5、8、10（镜像菜单）、Task 4（日志）。§5 拆分 0–7 → Task 1–13 一一对应。§7 验收 → Task 14 第 3 步逐条；坏帧 → Task 3、6 单测。
- **占位扫描**：没有 TBD；"同今天"处都指到具体文件或函数。`ComposerEvent` 在 Task 3 先只有 `sending`，Task 11 补全，已写明。
- **类型一致**：`SessionWindow`/`SessionEvent`（Swift）↔ `RemoteWindow`/`SessionEvent`（Dart）字段由 Task 5 的 channel 表统一；`StreamChoice` 字段 `mode/density/fps` 在 Task 10、13 一致；`ComposerSink.finished(pieces:sent:failure:)` ↔ channel `done {sent, failure}` ↔ `ComposerModel.done(sent, failure)` 一致；sid 在 channel 里是 hub 的整数 sid，Dart 用 `Object`（同 S1 `HubSession.sid`）。
- **Review Focus**：五条的测试名分别在 Task 3、6（1）、Task 7（2）、Task 8（3）、Task 12（4）、Task 6、3（5）的 Step 1 里出现。
- **比例**：只给签名、测试名和断言、精确数值；算法给了公式的有 `fitRect`/`toRemote`/`pictureRect`/`popupRect`/`detachedFrames`/`routeKey`/结束合并规则，其余照搬现有代码。
