# rapp 多窗口（协议 v4）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS host 把目标 app 的所有窗口（含菜单、sheet、提示条）放在一条流里发出去，B 上每个 A 窗口一个 B 窗口，A 的菜单栏镜像到 B。

**Architecture:** host 按"屏 + app"抓屏，区域取窗口并集；窗口表 10 Hz 推送；B 从每帧裁出各窗口。纯逻辑全部放 RappCore 测试，host/client 只做 AppKit/AX/SCK 胶水。

**Tech Stack:** Swift 6 / SwiftPM，ScreenCaptureKit，Accessibility，AppKit，XCTest。

**Spec:** `docs/superpowers/specs/2026-11-11-rapp-multiwindow-design.md`

## Global Constraints

- protocolVersion = 4；消息类型 13…18 按 spec §2.1；10、12 不再解码。
- 窗口表 ≤ 256 项；菜单 ≤ 6 层、≤ 5000 项；menuPick 路径 1…8 层；标题 ≤ 200 字符。
- 坐标 f32、单位点、画布原点在屏左上角；非有限数是坏数据。
- 区域向外取整到 8 点；查窗口 10 Hz；mouse move ≤ 30 次/秒；按下前顶层检查，raise 后等 50 ms。
- 缩放档 50/75/100/125/150/200%，默认 100%。
- 每个 commit 都要 `swift build` 通过；`swift test` 全绿。

## Review Focus

- 窗口刚关掉时 B 还在发它的 ID：host 必须丢掉而不是断开。
- 区域变化与帧的先后：B 用帧自己带的区域裁，不能用窗口表推算。
- 程序摆窗口触发的 windowDidMove 不能回发 move（否则 A、B 互相拉扯）。
- A 拒绝挪/改大小：B 不拽回，弹出窗口仍贴着父窗口。
- 顶层检查不能让点击落到别的 app 的窗口上（独占模式下最重要的安全性）。

---

### Task 1: 探查（一次性脚本，不进仓库）

**Files:** scratchpad 里的 `probe.swift`；Modify: spec 附录、必要时 §3.2/§3.3。

- [ ] 写脚本：TextEdit 新建空文档；按 spec §6 依次用 AX 打开右键菜单、格式菜单、存储面板、字体面板、关于窗口，指针停工具栏等提示条；每步列出新窗口的层级、alpha、owner、AX role/subrole；同时跑一条 `display+including:[app]` 的流，每步存一张 PNG；改一次 `sourceRect` 后看 `screenRect`/`contentRect` 附件；计时读 Safari 菜单栏。点击前查顶层窗口。
- [ ] 运行，看 PNG 确认每种弹出都在画面里。
- [ ] 结果写进 spec 附录；与 §3.3 不符处改表；决定帧区域来源（screenRect 或配置编号）。
- [ ] Commit `docs: multi-window probe results`

### Task 2: 协议 v4 + 单窗口版 host/client

**Files:** Modify `Sources/RappCore/Protocol.swift`, `Tests/RappCoreTests/ProtocolTests.swift`, `Sources/rapp-host/{Server,InputInjector}.swift`, `Sources/rapp-client/{main,RemoteView}.swift`

**Produces:**
- `public struct CanvasRect: Equatable { x, y, w, h: Float }`
- `public enum WindowKind: UInt8 { normal, dialog, floating, sheet, popover, menu, tooltip }`，`var isDecorated: Bool`
- `public struct WindowInfo: Equatable { id: UInt32; parent: UInt32; kind: WindowKind; resizable: Bool; focused: Bool; rect: CanvasRect; titleBar: Float; title: String }`
- `public struct MenuItem: Equatable { title: String; enabled: Bool; checked: Bool; separator: Bool; key: String; modifiers: UInt8; children: [MenuItem] }`
- `MouseKind.move = 3`
- `Message` 变为：`.ready(appName:width:height:)`、`.frame(region: CanvasRect, FramePayload)`、`.mouse(kind:button:window:x:y:clickCount:)`、`.scroll(window:x:y:dx:dy:)`、`.resize(window:width:height:)`、`.windows([WindowInfo])`、`.focus(UInt32)`、`.close(UInt32)`、`.move(window:x:y:)`、`.menuBar([MenuItem])`、`.menuPick([UInt16])`；删掉 `.title`、`.size`。

- [ ] 测试先行：每条新/改消息 round trip；`testWindowsRejectsDuplicateIDs`、`…UnknownParent`、`…MoreThan256`、`…ExtraFlagBits`、`…UnknownKind`、`…NonPositiveSize`、`…TitleBarNotBelowHeight`；`testMenuBarRejectsDepth7`、`…MoreThan5000Items`、`…ExtraFlagBits`；`testMenuPickRejectsEmptyAndNineLevels`；`testTypes10And12AreUnknown`；`testV3HelloIsVersionMismatch`。
- [ ] 跑 `swift test --filter ProtocolTests`，看到编译失败/红。
- [ ] 实现编解码。
- [ ] host 改成 spec §2.6 单窗口版：ready 发应用名 + 窗口内容大小作画布、frame 区域 = (0,0,w,h)、每次大小/标题变化发一项的 windows 表（id = 窗口 ID、titleBar 0）；mouse/scroll 用点坐标；resize 带 ID。client 对应：按一项窗口表设标题/大小，鼠标发点坐标。
- [ ] `swift build && swift test` 全绿；跑 e2e 一轮确认还能用。
- [ ] Commit `feat: protocol v4 messages (single-window host and client)`

### Task 3: 纯函数

**Files:** Create `Sources/RappCore/Windows.swift`, `Tests/RappCoreTests/WindowsTests.swift`

**Produces:**
- `classifyWindow(level: Int, role: String?, subrole: String?) -> WindowKind`（层级比较用 `CGWindowLevelForKey`，按 Task 1 结果）
- `assignParents(_ windows: [WindowInfo]) -> [WindowInfo]`（有框窗口 parent 0；弹出窗口取重叠面积最大的有框窗口，平局取更靠前的；不重叠取最前面的有框窗口；没有则 0）
- `captureRegion(windows: [WindowInfo], display: CGSize) -> CanvasRect?`（并集 ∩ 屏，minX/minY 向下、maxX/maxY 向上取到 8 的倍数，再裁到屏；空表或无交集 nil）
- `cropRect(window: WindowInfo, region: CanvasRect, pixelWidth: Int, pixelHeight: Int) -> CGRect?`（去标题行 → ∩ 区域 → 减原点 → × 像素密度，取整到整像素；无交集 nil）
- `struct WindowPlacement { origin: CGPoint; zoom: CGFloat }`：`toB(_ canvas: CGPoint) -> CGPoint`、`toCanvas(_ b: CGPoint) -> CGPoint`、`static func centering(content: CGRect, on screen: CGRect, zoom:) -> WindowPlacement`、`popupOrigin(popup: CanvasRect, parentContent: CanvasRect, parentContentInB: CGPoint) -> CGPoint`、`rezoomed(to: CGFloat, keeping canvas: CGPoint) -> WindowPlacement`（B 坐标用左上原点，翻转在 client 里做）
- `menuItem(at path: [UInt16], in items: [MenuItem]) -> MenuItem?`

- [ ] 测试先行，每个函数至少：正常、边界（区域刚好在 8 的倍数、窗口一半在屏外、tooltip 不和任何窗口重叠、两个有框窗口与菜单重叠面积相同）、空输入；`WindowPlacement` 往返误差 < 0.001。
- [ ] 红 → 实现 → 绿。
- [ ] Commit `feat: window classification, parents, capture region, crop and placement`

### Task 4: host 多窗口

**Files:** Create `Sources/rapp-host/WindowTracker.swift`; Modify `WindowCapture.swift`（按屏 + app 过滤、`setRegion`）、`Server.swift`、`InputInjector.swift`、`WindowResizer.swift`（按 ID 找 AX 窗口、raise、close、move、role/subrole）。

**Consumes:** Task 2 的消息、Task 3 的 `classifyWindow`/`assignParents`/`captureRegion`。
**Produces:** `WindowTracker.poll() -> [WindowInfo]`（缓存分类）；`WindowCapture.setRegion(_:)`；`InputInjector.handle(_ message:, table: [WindowInfo])`。

- [ ] 实现 spec §3.1–§3.4、§3.6、§3.7；区域来源按 Task 1 的决定。
- [ ] 在 TextEdit 上跑：host `serve --json` + client，截图看右键菜单在画面里（此时 client 仍是单窗口，裁的是第一项；能看到窗口表日志即可）。
- [ ] `swift build && swift test` 全绿。
- [ ] Commit `feat(host): capture every window of the app and send the window table`

### Task 5: client 多窗口

**Files:** Create `Sources/rapp-client/{RemoteWindow,PopupPanel,WindowCoordinator,StreamMenu}.swift`；Modify `main.swift`、`RemoteView.swift`、`TrafficLabel.swift`（菜单拆进 StreamMenu，标签可多个）。

**Consumes:** Task 3 的 `cropRect`、`WindowPlacement`。

- [ ] 实现 spec §4.1–§4.4、§4.5 的应用菜单与缩放、§4.6。程序摆窗口时设标志，windowDidMove/Resize 见标志不回发。
- [ ] 手动验证：TextEdit 右键菜单、格式菜单、字体面板、存储 sheet 在 B 上的位置；B 上挪窗口 A 跟着挪。截图。
- [ ] Commit `feat(client): one B window per A window, popups attached to their parent`

### Task 6: 菜单栏镜像

**Files:** Create `Sources/rapp-host/MenuBarReader.swift`、`Sources/rapp-client/MirroredMenu.swift`；Modify `Server.swift`、`main.swift`。

**Consumes:** Task 2 的 `MenuItem`、Task 3 的 `menuItem(at:in:)`。

- [ ] host §3.5；client §4.5（镜像项无 keyEquivalent，快捷键作标题右侧文字；编辑菜单改隐藏项）。
- [ ] 手动验证：B 菜单栏"文件 > 新建"在 A 上开出第二个窗口，B 上出现第二个 B 窗口。截图。
- [ ] Commit `feat: mirror the app's menu bar on B`

### Task 7: e2e、文档

**Files:** Modify `scripts/e2e-local.py`（client 的 `windows` 事件 count ≥ 1——hub 不转发时改为读 client 日志）、`docs/superpowers/specs/2026-11-10-rapp-host-client-spec.md`（指向 v4 文档）、`README.md`、`tasks/todo.md`。

- [ ] e2e 三轮通过。
- [ ] 文档更新；todo 记结果和没测的。
- [ ] Commit `test/docs: multi-window e2e and docs`
