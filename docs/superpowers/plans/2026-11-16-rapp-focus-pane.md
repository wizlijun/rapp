# 「智能」预设与焦点面板（第 0 步 + 第 1 步）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 串流菜单加「智能」预设：总是按网络自动省流量，并且 A 按控件树算出焦点面板发给 B，B 只在显示时把焦点窗口里焦点外的部分画成灰度（不省流量，不改帧格式）。

**Architecture:** A 端：纯逻辑 `RappCore/FocusPane.swift`（规则 2 选面板、坐标换算、规则 3–8 的状态机，时钟由调用方传）+ `rapp-host/FocusReader.swift`（只读无障碍控件树）+ `rapp-host/FocusSession.swift`（把两者接到 Server 上，只在 `focus` 位开着时存在）。协议 v12：`setStream` 末字节变标志位，新增 `focusRegion`（类型 36）。B 端：`StreamChoice.smart`、菜单、`_applyFps` 算 `pinned`/`focus`，事件一路从原生层（Swift `RappSession` / Rust `rapp-session`）送到 Dart，`Picture` 用一层裁剪过的 `BackdropFilter` 画灰。

**Tech Stack:** Swift 5.9（SwiftPM，XCTest），Rust（`rapp-client-core`），Flutter/Dart（`gui/`）。

**Spec:** `docs/superpowers/specs/2026-11-16-rapp-focus-pane-rules.md`（下称「规格」）。每个任务的实施者都要先读规格的 §4、§6、§7。

## Global Constraints

- 协议版本 11 → 12，Swift `protocolVersion` 和 Rust `VERSION` 同一个提交里改（规格 §7.1）。
- `setStream` 末字节：bit0 `pinned`，bit1 `focus`，其余位非 0 是坏消息。`focusRegion` = 类型 36，`u32 window, u8 count(0…3), count × 4×f32`；`count > 3` 是坏消息；`count = 0` = 整窗都是焦点。
- 门槛（规格 §4，起步值，T0 可能改）：最多 40 层；面板占比 < 85% 里取最大；占比 ≥ 15%、宽 ≥ 240 点、高 ≥ 160 点；停 0.5 秒算 hover；点击/按键后 0.2 秒重查键盘；跟随看 1 秒、超过 15%；整窗：合起来包围框 ≥ 85%、窗口 < 480 × 320、出现后头 2 秒、锁屏、没焦点窗口；发送最快 0.3 秒一次；一次查询总共 50 毫秒；矩形四边向外取整。
- 不读控件的标题、值、文字（只读 role、位置、大小、父容器）。日志不写标题和文字。
- `focus` 关着时：A 不建 `FocusSession`、不查控件树、不建通知（F5）。
- 菜单文字：`智能（按网络和焦点自动调）`；配置页开关：`智能时按焦点分区`。
- 灰度：亮度 `(77·R + 150·G + 29·B) / 256`，不压暗、不模糊、不加边框、不渐变；只改显示。
- 桌面会话、独立客户端（`Sources/rapp-client`、`rust/client-gtk`）不做焦点；独立客户端收到类型 36 丢掉不断开。
- 所有用户可见文字用中文；代码、注释、提交信息照仓库惯例用英文。
- Flutter 在 `~/development/flutter/bin/flutter`（不在 PATH）；跑完 Dart 测试 `git checkout gui/pubspec.lock`。
- 工作区：`.claude/worktrees/focus-pane`，分支 `feat/focus-pane`（T0 建）。

## 本计划替规格定下的（规格 §14）

| 规格 §14 的问题 | 本计划的取法 |
|---|---|
| 编码器怎么报 | `FrameEncoder.lastReport: EncodeReport?`，每次 `encodeSlices` 都填（只是把已有的 `changed` 和拷贝瓦片露出来，开销可忽略，不加开关）；`PacedSender.onEncoded` 回调转出去 |
| 换算到窗口内的点 | 画布点 = `region.x + 像素 / scale`（`scale = width / region.w`），窗口点 = 画布点 − `window.rect` 左上角；**含标题栏**，和 `mouse` 一致。无障碍给的全局点 − `display` 原点 − `window.rect` 左上角。B 端反向用 `toRemote` 的逆（`fromRemoteRect`） |
| 通知生命周期 | `FocusReader` 每次 `focus` 打开时为当前 pid 建 `AXObserver`，挂主 run loop，关掉或会话结束时拆；app 换了 pid（重启）时 `FocusSession` 重建 reader |
| `Texture` 怎么部分画灰 | 不动 surface：在 `pic` 上面叠一层 `ClipPath`（焦点矩形外，even-odd）+ `BackdropFilter(ColorFilter.matrix(灰度))`，两条画法共用 |
| `smart` 存在哪 | 在 `StreamChoice` 里，随 `rs.choice`/`r.choice` 走，已有的保存恢复自然带上 |
| 共用协议样例 | 写成字面量，Swift 和 Rust 测试各放一份同样的十六进制（T1、T2 给出） |

## Review Focus

1. **整帧（首帧、改密度、窗口大小变）在点击后 1 秒内到达**：所有瓦片都"变了"，不能因此触发跟随面板 → T4 测试 `testFullFrameNeverFollows`。
2. **查询结果晚到**：控件查询回来时焦点窗口已经换了，旧结果必须丢掉，不能把旧窗口的面板发成新窗口的 → T4 测试 `testStaleResultAfterWindowChangeDropped`。
3. **窗口缩小后旧面板超出窗口**：发出去的矩形一律先和当前窗口相交 → T4 测试 `testOutputClippedToWindow`。
4. **断开重连 / 新开会话时 `smart` 已经是真**：`hello` 不带 `focus`，必须补发一次带 `focus` 的 `set_stream` → T10 测试 `start of a smart session sends focus`。
5. **焦点窗口关掉了**：B 收到的窗口表里没有 `focusRegion.window` 时立刻清掉，不对别的窗口画灰 → T10 测试 `focus cleared when its window leaves the table`。

---

### Task 0: 工作区 + 第 0 步探查（有用户关卡）

**Files:**
- 工作区内新增：`docs/superpowers/specs/2026-11-16-rapp-focus-pane-rules.md`、`docs/superpowers/plans/2026-11-16-rapp-focus-pane.md`（从主工作区拷过来，主工作区里这两个是未跟踪文件）
- Create: `docs/superpowers/specs/2026-11-16-rapp-focus-pane-probe.md`
- 探查程序：`<scratchpad>/focus-probe/main.swift`（不进仓库）

- [ ] **Step 1: 建工作区**：`git worktree add .claude/worktrees/focus-pane -b feat/focus-pane main`；把上面两份文档拷进去，`git add` 后提交 `docs: focus pane spec and plan`。
- [ ] **Step 2: 写探查程序**（单文件 Swift，`swiftc -O main.swift -o focus-probe`）。每 2 秒对最前面的 app（`NSWorkspace.frontmostApplication`）的焦点窗口（`kAXFocusedWindowAttribute`）打印两段：键盘焦点控件（`kAXFocusedUIElementAttribute`）和鼠标位置下的控件（`AXUIElementCopyElementAtPosition` 用 app 元素，不用 system-wide）。每段：每层 `role`、和窗口相交后的矩形、占比；按规格规则 2 选中的层或 `small/large/blocked`；查询毫秒数。规则 2 照规格 §4 自己写一份（几行），不依赖仓库。参数 `--manual <bundle-id>`：对该 app 设 `AXManualAccessibility = true`，退出（SIGINT）时设回 false。只读 role/position/size/parent。
- [ ] **Step 3: 自己先跑一遍**（关沙盒）：`AXIsProcessTrusted()` 为假就打印提示并退出。能跑就对着 Finder、终端各看一处，确认输出格式可读。
- [ ] **Step 4: 用户关卡**：把运行方法交给用户（照《文本终端 P0 探查》的写法：二进制绝对路径、在终端里跑、终端要有无障碍权限）。用户按规格 §8.2 逐个 app、逐个位置操作，**Chrome 和 Electron 的三个一样做「不设 / `--manual` 设上」两遍**，并用「活动监视器」记 30 秒滚动的 CPU。收回输出。
- [ ] **Step 5: 写 `…-focus-pane-probe.md`**：每 app 每位置一行（选中的层、和人眼认的面板是否一致）；规格 §8.3 四个问题的结论；§5 七个例子逐条核对；探查程序怎么写怎么跑。门槛有改动就回写规格 §4 和本计划 Global Constraints。提交 `docs: focus pane probe results`。
- [ ] **Step 6: 关卡判定**：规格 §8.3 第一行不过（八成一致、没有一处选小）→ **停，把结果交给用户，不做后面的任务**。过了 → 把「Electron/Chrome 设不设开关」的结论记进 probe 文档，T6 Step 4 按它做。

### Task 1: 协议 v12（Swift）

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`（版本号与文件头注释、`setStream`、新 case、编解码）
- Modify: `Sources/rapp-host/Server.swift:497`（host→client 消息列表加 `.focusRegion`，收到即 `fail`）
- Test: `Tests/RappCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `case setStream(mode: Mode, fps: UInt8, density: Float, pinned: Bool, focus: Bool = false)`（类型 11）；`case focusRegion(window: UInt32, rects: [CanvasRect])  // 36, host -> client (v12)`；`public let maxFocusRects = 3`；`protocolVersion = 12`。

- [ ] **Step 1: 写失败测试**

```swift
func testFocusRegionRoundTrips() throws {
    for rects in [[], [CanvasRect(x: 10, y: 20, w: 300, h: 200)],
                  Array(repeating: CanvasRect(x: 0, y: 0, w: 1, h: 1), count: 3)] {
        let m = Message.focusRegion(window: 7, rects: rects)
        XCTAssertEqual(try roundTrip(m), m)   // use the file's existing encode→decode helper
    }
}
func testFocusRegionSharedSample() {
    // Same bytes in rust/client-core/tests/client.rs (focus_region_shared_sample).
    XCTAssertEqual(hex(Message.focusRegion(window: 7, rects: [CanvasRect(x: 10, y: 20, w: 300, h: 200)]).encoded()),
                   "2415000000070000000100002041" + "0000a04100009643" + "00004843")
}
func testFocusRegionMoreThanThreeIsBad()   // hand-built payload with count 4 → decode throws
func testSetStreamFlags() throws {
    for (p, f) in [(false, false), (true, false), (false, true), (true, true)] {
        let m = Message.setStream(mode: .color16, fps: 15, density: 1, pinned: p, focus: f)
        XCTAssertEqual(try roundTrip(m), m)
        XCTAssertEqual(m.encoded().last, UInt8((p ? 1 : 0) | (f ? 2 : 0)))
    }
}
func testSetStreamHighBitsAreBad()         // last byte 4 → decode throws
```

（`Mode` 的名字以 `Protocol.swift` 为准；`hex` 没有就在测试文件里加一个小函数。）

- [ ] **Step 2: 跑测试确认失败**：`swift test --filter RappCoreTests.ProtocolTests`，Expected: 编译失败（没有 `focusRegion`）。
- [ ] **Step 3: 实现**：版本号改 12，文件头注释补一句 v12；`setStream` 写 `UInt8((pinned ? 1 : 0) | (focus ? 2 : 0))`，读时 `flag & ~3 != 0` 抛 `CodecError("bad stream flags")`；类型 36 用已有的 `w.rect` / `r.rect()`，`count > maxFocusRects` 抛错。`Server.swift` 里现有 `.setStream(mode, fps, density, pinned)` 的模式改成带 `focus`（这一步先忽略它）。
- [ ] **Step 4: 跑测试**：`swift test --filter RappCoreTests.ProtocolTests` PASS；`swift build` 通过（`rapp-client`、`RappSession` 里对 `Message` 的 switch 若要求穷尽，给 `.focusRegion` 加忽略分支）。
- [ ] **Step 5: 提交** `feat(protocol): v12 setStream flags + focusRegion`

### Task 2: 协议 v12（Rust）+ `rapp-session` 转发

**Files:**
- Modify: `rust/client-core/src/protocol.rs`（`VERSION`、`stream`、`Incoming::FocusRegion`、`decode` 类型 36）
- Modify: `rust/client-core/src/bin/rapp-session.rs`（`set_stream` 读 `focus`；`FocusRegion` → `focus` 事件）
- Modify: `rust/client-gtk/src/ui.rs:729`（`p::stream(…, false, false)`；`Incoming::FocusRegion` 忽略）
- Test: `rust/client-core/tests/client.rs`、`rapp-session.rs` 里已有的 `#[cfg(test)]`

**Interfaces:**
- Produces: `pub fn stream(mode: u8, fps: u8, density: f32, pinned: bool, focus: bool) -> Vec<u8>`；`Incoming::FocusRegion { window: u32, rects: Vec<Rect> }`；JSON 命令 `set_stream` 可带 `"focus": true`；JSON 事件 `{"event":"focus","window":<u32>,"rects":[[x,y,w,h],…]}`（这个形状 T7 的 Swift 层也用）。

- [ ] **Step 1: 写失败测试**：`client.rs` 加 `focus_region_shared_sample`（解 T1 同一串十六进制去掉 5 字节头后的 payload，断言 `window == 7`、一个 `Rect{10,20,300,200}`），`decode(36, count=4 的 payload)` 是 `Err`，`decode(36, &[7,0,0,0,0])` 得空 `rects`；`stream(4, 15, 1.0, false, true).last() == Some(&2)`。`rapp-session.rs` 的 `set_stream_pinned` 旁加 `set_stream_focus`：`{"cmd":"set_stream",…,"focus":true}` → `p::stream(…, false, true)`。
- [ ] **Step 2: 跑**：`cd rust && cargo test -p rapp-client-core`，Expected: 编译失败。
- [ ] **Step 3: 实现**：`VERSION = 12`；`stream` 推 `pinned as u8 | (focus as u8) << 1`；类型 36 `ensure!(count <= 3)`，用已有 `r.rect()`；`rapp-session` 的事件分支照 `ScreenLocked` 那条写。
- [ ] **Step 4: 跑**：`cd rust && cargo test -p rapp-client-core && cargo build -p rapp-client-gtk` 全过。
- [ ] **Step 5: 提交** `feat(client-core): protocol v12 focus flag and focusRegion`

### Task 3: 规则 2 与坐标换算（纯逻辑）

**Files:**
- Create: `Sources/RappCore/FocusPane.swift`
- Test: `Tests/RappCoreTests/FocusPaneTests.swift`

**Interfaces:**
- Produces:

```swift
public enum PanelMiss: String, Equatable { case small, large, blocked }
public struct PanelPick: Equatable { public let rect: CGRect; public let depth: Int; public let share: Double }
public enum FocusPane {
    public static let maxDepth = 40, minShare = 0.15, maxShare = 0.85
    public static let minWidth: CGFloat = 240, minHeight: CGFloat = 160
    /// `chain`: rects in window points, the start control first, then each parent (the window may be last).
    public static func panel(chain: [CGRect], window: CGSize) -> Result<PanelPick, PanelMiss>
    /// Global AX rect → window points (title bar included, like `mouse`).
    public static func windowRect(global: CGRect, display: CGRect, window: CanvasRect) -> CGRect
    public static func windowTiles(_ r: EncodeReport, window: CanvasRect) -> WindowTiles
}
public struct EncodeReport: Equatable {
    public let region: CanvasRect; public let width: Int; public let height: Int  // pixels
    public let full: Bool
    public let changed: [Int]        // tile indexes ty*cols+tx sent this frame (any kind, copies too)
    public let copyBounds: CGRect?   // pixels; bounding box of this frame's copy tiles
}
public struct WindowTiles: Equatable {
    public let changed: [CGRect]     // window points; a tile belongs to the window when its centre is inside
    public let total: Int            // tiles whose centre is inside the window
    public let copyBounds: CGRect?   // window points, intersected with the window
    public let full: Bool
}
```

`panel` 的规则（写进文档注释）：只看前 40 层；每层先和 `(0,0,window)` 相交；占比 < 0.85 的层里取占比最大的（并列取更外层）；一层都没有 → `.large`；选中的占比 < 0.15 或宽 < 240 或高 < 160 → `.small`；空链 → `.small`。`depth` = 选中层在 `chain` 里的下标。

- [ ] **Step 1: 写失败测试**（窗口 1000×800）：
  - `testPicksLargestUnderMax`：`[100×50, 600×800(60%), 1000×800]` → `.success(depth 1, share 0.6)`
  - `testAllSmall`：所有层 < 15% → `.failure(.small)`；`testOnlyHuge`：`[950×800, 1000×800]` → `.failure(.large)`
  - `testTallContainerIntersectedFirst`：`[CGRect(0,-2000,600,5000)]` → rect `(0,0,600,800)`、share 0.6
  - `testMinWidthHeight`：`[230×800]`、`[1000×150]` 都是 `.small`
  - `testDepthCappedAt40`：40 个小层后第 41 层是 60% → `.small`
  - `testWindowRect`：display `(0,25,1440,875)`、window rect `(100,50,…)`、global `(110,85,10,10)` → `(10,10,10,10)`
  - `testWindowTilesRetina`：region `(0,0,800,600)` 宽 1600 像素（scale 2），tile 0 在窗口 `(0,0,400,300)` 里 → changed `[(0,0,32,32)]`；中心在窗口外的瓦片不算；`total` 正确；`copyBounds` 换算后再和窗口相交
- [ ] **Step 2: 跑**：`swift test --filter RappCoreTests.FocusPaneTests`，Expected: 编译失败。
- [ ] **Step 3: 实现** 上面的签名（`tileSize` 用 `TileCodec.swift` 的常量）。
- [ ] **Step 4: 跑** 同上 PASS。
- [ ] **Step 5: 提交** `feat(core): focus pane picking and geometry`

### Task 4: 焦点状态机（规则 3–8，纯逻辑）

**Files:**
- Modify: `Sources/RappCore/FocusPane.swift`（加 `FocusTracker`）
- Test: `Tests/RappCoreTests/FocusTrackerTests.swift`

**Interfaces:**
- Consumes: T3 的 `PanelPick`、`PanelMiss`、`WindowTiles`、`FocusPane.panel`。
- Produces:

```swift
public final class FocusTracker {
    public enum Cause: String { case on, key, click, scroll, hover, follow, notify, resize, window, lock }
    public enum Query: Equatable { case keyboard; case pointer(CGPoint); case follow(CGPoint) }
    public struct Output: Equatable { public let window: UInt32; public let rects: [CGRect]; public let cause: Cause } // [] = whole
    public enum Action: Equatable { case query(Query, generation: Int); case send(Output) }
    public enum Pointer { case click, drag, scroll, move }
    public init()
    public func start(now: TimeInterval) -> [Action]                 // cause .on
    public func window(id: UInt32?, size: CGSize, appeared: TimeInterval?, now: TimeInterval) -> [Action]
    public func locked(_ on: Bool, now: TimeInterval) -> [Action]
    public func pointer(_ kind: Pointer, at: CGPoint, now: TimeInterval) -> [Action]
    public func key(now: TimeInterval) -> [Action]                   // key, text, paste
    public func keyboardChanged(now: TimeInterval) -> [Action]       // AX notification
    public func result(_ q: Query, generation: Int, _ r: Result<PanelPick, PanelMiss>, now: TimeInterval) -> [Action]
    public func frame(_ t: WindowTiles, now: TimeInterval) -> [Action]
    public func tick(now: TimeInterval) -> [Action]                  // caller ticks every 0.1 s
}
```

`generation` 在焦点窗口换了（或大小变了）时加一；`result` 的 generation 不是当前的就丢掉。规则细节照规格 §4，以下几处规格没写死，按这里：
- 键盘面板：`.failure` → 置空并记下原因。指针面板：`.failure` → 保持原样，记下原因。
- 规则 6 生效条件：键盘最后一次原因是 `.blocked`，指针面板为空，且指针从没查过或最后原因是 `.blocked`；用最近一次非空 `copyBounds` 过 `FocusPane.panel(chain: [copy], window:)`。
- 规则 5：点击/按键后 1 秒内，累计**不重复**的、中心不在当前焦点矩形里的变化瓦片；`frame.full` 为真的帧整个不算；超过 `total × 0.15` 发 `.query(.follow(包围框中心))`，本次动作不再判。当前是整窗时不判。
- 输出：键盘、指针、跟随三个矩形去掉被另一个包含的，四边向外取整，再和窗口相交；规则 7 的条件成立就是 `[]`；和上次发出的一样就不发；距上次发送不足 0.3 秒就挂起，由 `tick` 到点发最后一个。
- `pointer(.move)`：记点和时刻；`tick` 时停满 0.5 秒、且点不在当前指针面板里，才发 `.query(.pointer)`（cause `.hover`）。`.click/.drag/.scroll` 点不在当前指针面板里就立刻查。`.click` 和 `key` 另外在 0.2 秒后补一次 `.query(.keyboard)`。

- [ ] **Step 1: 写失败测试**（窗口 1000×800，`appeared` 设成 −10 避开头 2 秒；每个测试用手写的时刻）：
  - 规格 §9 状态机那一串：`testClickQueriesAtOnce`、`testMoveAcrossDoesNotQuery`（每 0.1 秒移动一次横穿，`tick` 不出 `.pointer`）、`testHoverAfterHalfSecondOnce`、`testNoQueryInsideCurrentPointerPanel`、`testEmptyKeyboardUsesPointerOnly`、`testUnionOver85IsWhole`、`testSmallWindowWhole`（479×800）、`testFirstTwoSecondsWhole`、`testLockedWhole`、`testNoWindowWhole`、`testThrottleKeepsLast`（0.1 秒内两次变化 → 0.3 秒时只出后一个）、`testUnchangedNotSent`
  - 规则 5：`testFollowWithinOneSecond`（点击后 0.5 秒一帧，焦点外 16% 不重复瓦片 → `.query(.follow(中心))`）、`testNoFollowAfterOneSecond`、`testNoFollowWithoutAction`、`testScrollAndMoveDoNotArmFollow`、`testNextClickClearsFollow`、`testFullFrameNeverFollows`
  - 规则 6：`testCopyBoundsWhenBlocked`、`testNoCopyFallbackWhenSmallOrLarge`、`testCopyBoundsBelowThresholdWhole`
  - Review Focus：`testStaleResultAfterWindowChangeDropped`、`testOutputClippedToWindow`（面板 `(600,0,400,800)` 后窗口缩到 800 宽 → 发 `(600,0,200,800)` 或整窗，绝不超出）
- [ ] **Step 2: 跑**：`swift test --filter RappCoreTests.FocusTrackerTests`，Expected: 编译失败。
- [ ] **Step 3: 实现** `FocusTracker`。所有常量用 `FocusPane` 里的或在 `FocusTracker` 里具名（`hoverDelay = 0.5`、`keyRecheck = 0.2`、`followWindow = 1`、`followShare = 0.15`、`sendInterval = 0.3`、`settle = 2`、`minWindow = CGSize(480, 320)`）。
- [ ] **Step 4: 跑** 同上 PASS，再跑 `swift test --filter RappCoreTests` 全过。
- [ ] **Step 5: 提交** `feat(core): focus tracker state machine`

### Task 5: 编码器报出变化瓦片和拷贝瓦片

**Files:**
- Modify: `Sources/RappCore/TileCodec.swift`（`FrameEncoder.lastReport`）
- Modify: `Sources/RappCore/PacedSender.swift`（`onEncoded`）
- Test: `Tests/RappCoreTests/TileCodecTests.swift`、`PacedSenderTests.swift`

**Interfaces:**
- Consumes: T3 的 `EncodeReport`。
- Produces: `FrameEncoder.lastReport: EncodeReport?`（`encodeSlices` 每次填，返回 `[]` 时 `changed` 为空；`encodeSettle` 不动它）；`PacedSender.onEncoded: ((EncodeReport) -> Void)?`，在 `pump()` 里 `encodeSlices` 之后、同一线程调用。

- [ ] **Step 1: 写失败测试**：`testReportMatchesSentTiles`（改两个瓦片 → `changed` 正是这两个下标，`full == false`）；`testReportFullFrame`（首帧 `full == true`、`changed` 是全部）；`testReportCopyBounds`（用 `ScrollScenes` 里已有的滚动场景，`copyBounds` 等于解码端看到的 kind 5 瓦片的包围框；无拷贝时 nil）；`PacedSenderTests` 里 `testOnEncodedCalledPerEncode`。
- [ ] **Step 2: 跑**：`swift test --filter RappCoreTests.TileCodecTests`，Expected: 编译失败。
- [ ] **Step 3: 实现**：在第二遍循环里记下发出的瓦片下标和 kind 5 的包围框，结尾组装 `EncodeReport`。不改任何编码结果；现有 `TileCodecTests`、`ScrollCopyTests`、`CrossFixtureTests` 必须原样通过。
- [ ] **Step 4: 跑** `swift test --filter RappCoreTests` 全过。
- [ ] **Step 5: 提交** `feat(codec): report changed and copied tiles per frame`

### Task 6: A 端接线：FocusReader + FocusSession + Server

**Files:**
- Create: `Sources/rapp-host/FocusReader.swift`、`Sources/rapp-host/FocusSession.swift`
- Modify: `Sources/rapp-host/Server.swift`（`setStream` 分支、输入分支 `:421`、`.paste` 分支、窗口表更新 `:732/:825`、锁屏 `sendLocked`、`makePacedSender`、`end`）
- Create: `scripts/focus-loopback.py`（照 `scripts/multi-client-loopback.py`）

**Interfaces:**
- Consumes: T1 消息；T3/T4/T5 全部。
- Produces（rapp-host 内部）：

```swift
final class FocusReader {   // own serial queue; one query at a time, newest queued one wins
    struct Chain { let roles: [String]; let rects: [CGRect] /* window points */; let ms: Int }
    init(pid: pid_t, onKeyboardChanged: @escaping () -> Void)  // AXObserver on the main run loop
    func query(_ q: FocusTracker.Query, window: WindowInfo, display: CGRect,
               done: @escaping (Result<Chain, PanelMiss>) -> Void)   // only .blocked as a failure; 50 ms in all
    func stop()
}
final class FocusSession {  // lives on the Server's session queue; exists only while `focus` is on
    init(pid: pid_t, display: CGRect, queue: DispatchQueue, send: @escaping (Message) -> Void, log: @escaping (String) -> Void)
    func input(_ m: Message)          // mouse, scroll, key, text, paste
    func windows(_ table: [WindowInfo])
    func locked(_ on: Bool)
    func encoded(_ r: EncodeReport)
    func stop()
}
```

- [ ] **Step 1: `FocusReader`**：`AXUIElementCreateApplication(pid)`；键盘起点 `kAXFocusedUIElementAttribute`，指针/跟随起点 `AXUIElementCopyElementAtPosition(appElement, …)`（窗口点 → 全局点：`display` 原点 + `window.rect` 左上角 + 点）；沿 `kAXParentAttribute` 往上，`kAXRoleAttribute` 为 `AXWindow` 停（含这一层），最多 40 层；每层 `kAXPosition`/`kAXSize` 换成窗口点（`FocusPane.windowRect`）。开始时记截止时刻 +50 ms，每次调用前 `AXUIElementSetMessagingTimeout(element, 剩余秒数)`，过了截止或任何调用失败 → `.blocked`。`kAXFocusedUIElementChangedNotification` 的 `AXObserver` 源加到 `CFRunLoopGetMain()`，回调里转给 `onKeyboardChanged`。不读 title/value/description。
- [ ] **Step 2: `FocusSession`**：持有 `FocusTracker`、`FocusReader`、一个 0.1 秒的 `DispatchSourceTimer`（`tracker.tick`）。`input`：`mouse(.down)` → `.click`，`.drag`/`.move` 同名，`scroll` → `.scroll`，`key`/`text`/`paste` → `tracker.key`。`windows`：取 `focused` 的那个（没有 → `id: nil`），新 id 第一次出现记 `appeared = now`。`encoded`：对焦点窗口做 `FocusPane.windowTiles` 喂 `tracker.frame`。`.query` → `reader.query`，结果回到 `queue` 上先 `FocusPane.panel(chain: rects, window: size)` 再 `tracker.result`。`.send` → `send(.focusRegion(window:, rects:))` 并写一行 `[focus]` 日志（规格 §7.5 的字段，同一行；`start=`/`depth=`/`picked=`/`share=` 取最近一次查询，`out=whole` 表示 `[]`）。时钟用 rapp-host 已有的 `uptimeSeconds`。
- [ ] **Step 3: Server 接线**：`setStream` 分支：`focus && !desktop && app != nil` 且 `focusSession == nil` → 建（把当前 `table`、锁屏状态喂进去，再 `start`）；`!focus` → `stop()` 后置 nil。`makePacedSender` 里 `paced.onEncoded = { [weak self] in self?.focusSession?.encoded($0) }`。输入、`.paste`、窗口表、锁屏变化各调一处。`end` 里 `stop()`。`focus` 关着时这几处只是一个 nil 判断（F5）。
- [ ] **Step 4: Electron/Chrome 开关**：按 T0 结论。要设：`FocusReader.init` 里对 app 元素设 `AXManualAccessibility = true`（只对 T0 判定要设的那几类，按 bundle id 列表），`stop()` 设回 false，失败只写日志。不设：跳过本步，在提交信息里写一句。
- [ ] **Step 5: `scripts/focus-loopback.py`**：起 `rapp-host serve`（照 multi-client-loopback 的启动、清理和不打印 token 的写法，app 用 Calculator），`hello` v12，`setStream` 末字节 2 → 10 秒内收到类型 36；末字节 0 → 之后 3 秒内不再收到 36。用法写在文件头。
- [ ] **Step 6: 验证**：`swift build -c release` 通过；`swift test` 全过；**关沙盒**跑 `scripts/focus-loopback.py .build/release/rapp-host`，Expected: 打印 PASS。跑不了（权限）就写明。
- [ ] **Step 7: 提交** `feat(host): compute and send the focus region when asked`

### Task 7: macOS 原生会话层（RappSession）

**Files:**
- Modify: `Sources/RappSession/Channel.swift:30,157,377`、`EmbeddedSession.swift:48,107,296,313`、`SessionEvent.swift:82`
- Test: `Tests/RappSessionTests/ChannelTests.swift`、`EmbeddedSessionTests.swift`

**Interfaces:**
- Consumes: T1 消息；T2 的事件 JSON 形状。
- Produces: 命令 `set_stream` 可带 `focus`（`optionalBool`）；`EmbeddedSession.setStream(mode:fps:choice:pinned:focus: Bool = false)`；`SessionEvent.focusRegion(window: UInt32, rects: [CanvasRect])` → 通道载荷 `payload("focus", ["window": w, "rects": [[x,y,w,h], …]])`（数字是 Double）。

- [ ] **Step 1: 写失败测试**：`ChannelTests`：`set_stream` 带 `"focus": true` 解析出 `focus == true`，不带为 false；`.focusRegion` 事件的载荷形状如上。`EmbeddedSessionTests`（用 `FakeLink`）：`setStream(…, focus: true)` 发出的 `.setStream` 带 `focus: true`；只改 `focus` 也会重发；收到 `.focusRegion` 发出同名事件。
- [ ] **Step 2: 跑**：`swift test --filter RappSessionTests`，Expected: 编译失败。
- [ ] **Step 3: 实现**：照 `pinned` / `sentPinned` 的写法加 `focus` / `sentFocus`；`handle` 里加 `.focusRegion` 分支。
- [ ] **Step 4: 跑** `swift test --filter RappSessionTests` 全过；`swift build` 通过（`rapp-client` 若穷尽 switch `SessionEvent`，加忽略分支）。
- [ ] **Step 5: 提交** `feat(session): carry the focus flag and focusRegion to Dart`

### Task 8: `StreamChoice.smart` 与菜单

**Files:**
- Modify: `gui/lib/embed/stream_choice.dart`、`gui/lib/embed/stream_menu.dart:593-595`
- Test: `gui/test/embed/stream_choice_test.dart`、`gui/test/embed/stream_menu_test.dart`

**Interfaces:**
- Produces: `const StreamChoice(this.mode, this.density, this.fps, {this.smart = false})`；`final bool smart`（进 `==`、`hashCode`、`toString`）；`copyWith({String? mode, String? density, int? fps})` 的结果 `smart` 一律为 false（手动改即退出智能）；`const presetSmart = StreamChoice('color16', 'adaptive', 15, smart: true)`。

- [ ] **Step 1: 写失败测试**：`presetSmart` 的 mode/density/fps 和 `startChoice` 相同但 `presetSmart != startChoice`；`presetSmart.copyWith(fps: 15).smart == false`；菜单：「预设」下三条依次是 `最省流（…）`、`智能（按网络和焦点自动调）`、`最清晰（…）`；点智能后 `session.choice == presetSmart` 且只有它打勾；再点「档位」任一项，智能不打勾。
- [ ] **Step 2: 跑**：`cd gui && ~/development/flutter/bin/flutter test test/embed/stream_choice_test.dart test/embed/stream_menu_test.dart`，Expected: FAIL。
- [ ] **Step 3: 实现**：菜单在两条之间加 `_Item('智能（按网络和焦点自动调）', checked: c == presetSmart, onTap: () => _choose(presetSmart))`。
- [ ] **Step 4: 跑** 同上 PASS；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `feat(gui): 智能 stream preset`

### Task 9: app 配置 `focusPane`

**Files:**
- Modify: `gui/lib/embed/app_profile.dart`（照 `typeToCompose`：`:137,154,178,197,249,282,300,349`）、`gui/lib/pages/app_profile_page.dart`（`:105` 的空判断、「画面」那一块加开关）
- Test: `gui/test/embed/app_profile_test.dart`、配置页已有的测试文件（`gui/test/ui/` 下找 `app_profile_page`）

**Interfaces:**
- Produces: `AppProfile.focusPane: bool?`（JSON 键 `focusPane`，只写非 null）；`ResolvedProfile.focusPane: bool`（默认 true，`mine` 优先于内置）。

- [ ] **Step 1: 写失败测试**：读 `{"focusPane": false}` → false；不写 → null；写回 JSON 不带 null；`resolveProfile` 默认 true、`mine` 的 false 盖过内置；配置页「画面」块里有 `智能时按焦点分区` 开关，切换后 draft 的 `focusPane` 变化。
- [ ] **Step 2: 跑**：`flutter test test/embed/app_profile_test.dart <配置页测试>`，FAIL。
- [ ] **Step 3: 实现**。内置配置（`builtin_profiles`）不加这个字段。
- [ ] **Step 4: 跑** PASS；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `feat(gui): focusPane app setting`

### Task 10: B 端事件、会话状态、`_applyFps`

**Files:**
- Modify: `gui/lib/embed/session_port.dart`（`setStream` 带 `focus`；`FocusRegionEvent`；事件解析加 `'focus'`）、`gui/lib/embed/linux_session_port.dart`（`set_stream` 透传，确认 `focus` 事件走同一个解析）、`gui/lib/embed/remote_session.dart`、`gui/lib/ui/main_state.dart:609-640,1526`
- Test: `gui/test/embed/session_port_test.dart`、`linux_session_port_test.dart`、`remote_session_test.dart`、`gui/test/ui/` 下 `_applyFps` 现有测试所在文件

**Interfaces:**
- Consumes: T7/T2 事件 JSON；T8 `smart`；T9 `focusPane`。
- Produces: `void setStream(Object sid, String mode, int fps, String density, {bool pinned = false, bool focus = false})`（`if (focus) 'focus': true`）；`class FocusRegionEvent extends SessionEvent { final int window; final List<Rect> rects; }`（`rects` 多于 3 个或不是 4 个数 → 整条丢掉）；`RemoteSession.focus: ({int window, List<Rect> rects})?`，`void clearFocus()`。

- [ ] **Step 1: 写失败测试**：
  - port：`focus` 事件解析成 `FocusRegionEvent`；4 个矩形返回 null；`setStream(…, focus: true)` 发出的参数带 `focus: true`，false 时不带。
  - `RemoteSession`：收到事件后 `focus` 是它；`linkDown()` 清掉；`focus cleared when its window leaves the table`（窗口表事件里没有那个 id）；`clearFocus()` 清掉并通知。
  - `_applyFps`：智能时 `pinned == false`、`focus == true`，即使 `prefs.autoSaveTraffic == false`；**桌面会话手动选了智能，`pinned == false`、`focus == false`**；`focusPane == false` 的 app `focus == false`；只有 `focus` 变了也重发、没变不重发；从智能切走时 `rs.focus` 被清掉；`start of a smart session sends focus`（会话 start 后紧跟一条 `focus: true` 的 `set_stream`）。
- [ ] **Step 2: 跑** 这几个测试文件，FAIL。
- [ ] **Step 3: 实现**：

```dart
bool _wantsFocus(RemoteSession rs, SessionRecord r) =>
    rs.choice.smart && !isDesktopApp(r.app) && rs.profile.focusPane;
// in _applyFps:
final pin = !c.smart && (_pinned || (isDesktopApp(r.app) && rs.streamPinned));
final focus = _wantsFocus(rs, r);
if (!focus) rs.clearFocus();
```

`_sentFps` 的元组加一个 `bool focus`；start 处记 `(c.mode, c.fps, c.density, false, false)`，条件改为 `if (_pinned || _wantsFocus(rs, r)) _applyFps();`（`r` 的类型名以 `main_state.dart` 为准）。
- [ ] **Step 4: 跑** PASS；`flutter analyze` 干净；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `feat(gui): ask A for the focus region under 智能`

### Task 11: 画灰

**Files:**
- Create: `gui/lib/embed/focus_gray.dart`
- Modify: `gui/lib/embed/geometry.dart`（加 `fromRemoteRect`）、`gui/lib/embed/picture.dart:453-456`
- Test: `gui/test/embed/geometry_test.dart`、新 `gui/test/embed/focus_gray_test.dart`

**Interfaces:**
- Consumes: T10 `RemoteSession.focus`。
- Produces: `Rect fromRemoteRect(Rect r, Rect fit, RemoteWindow w)`（`toRemote` 的逆，含标题栏偏移）；`const lumaFilter = ColorFilter.matrix([...])`（三行都是 `77/256, 150/256, 29/256, 0, 0`，第四行 `0,0,0,1,0`）；`Widget focusGray(Size size, List<Rect> rects)`：`IgnorePointer(ClipPath(clipper: 外部(even-odd: 整块减去 rects), child: BackdropFilter(filter: lumaFilter, child: SizedBox.expand())))`，key `focus-gray`。

- [ ] **Step 1: 写失败测试**：`fromRemoteRect(toRemote 的几个点)` 互逆（含标题栏 28 的窗口）；`focus_gray_test`：clipper 的 path 包含矩形外的点、不包含矩形内的点；`Picture` 上：`session.focus` 的 window 是当前窗口且有矩形 → 有 `focus-gray`，且叠在 surface 上面、`pic` 范围内；`rects` 为空、window 不是当前窗口、`clearFocus()` 之后 → 没有 `focus-gray`；`image`（`CustomPaint`）和 `texture` 两种 `RemoteWindow` 各测一次。
- [ ] **Step 2: 跑**，FAIL。
- [ ] **Step 3: 实现**：在 `picture.dart` 的 surface 那个 `Positioned.fromRect(rect: pic, …)` 之后（焦点框之前）加一层 `Positioned.fromRect(rect: pic, child: focusGray(pic.size, rects 转成 pic 局部坐标))`；转换：`fromRemoteRect(r, fit, win).shift(-pic.topLeft)`。弹出窗口不加。
- [ ] **Step 4: 跑** PASS；`flutter analyze` 干净；`git checkout gui/pubspec.lock`。
- [ ] **Step 5: 提交** `feat(gui): gray out what is outside the focus panes`

### Task 12: 文档与收尾

**Files:**
- Modify: `README.md`、`README.en.md`（协议版本；预设三条；第 2 步之前智能的焦点一半不省流量）；《app 配置》规格、配置参考、《app 配置编写规范》（`focusPane`）；《网络状态》规格 §6（智能时总是开）；`tasks/todo.md`（任务清单 + 「未经实机验证」：规格 §10 的十个场景）；产品决策文件（「焦点按面板算，固定规则，不用模型」）；规格本身（把 T0 的改动和本计划 §14 的取法回写，状态改成「第 1 步已实现」）
- 先用 `grep -rln "protocol v11\|协议 v11\|最清晰（" README* docs` 找到要改的确切位置。

- [ ] **Step 1: 改上面这些文档**（只改事实，不重写段落）。
- [ ] **Step 2: 全量验证**：`scripts/check.sh` 末行 `EXIT=0`；`cd rust && cargo test -p rapp-client-core && cargo build -p rapp-client-gtk`；`cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`（记下通过/跳过数），然后 `git checkout gui/pubspec.lock`。
- [ ] **Step 3: 交付说明**（写进 `tasks/todo.md` 这一项下面）：哪些自动测试过了；`focus-loopback.py` 跑没跑；规格 §10 哪些场景自己在真机看过，哪些没条件看（人看的部分由用户做）。
- [ ] **Step 4: 提交** `docs: focus pane step 1`
