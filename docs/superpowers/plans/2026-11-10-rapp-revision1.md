# rapp 修订 1 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B 上看到去掉标题栏、四角方正的窗口内容；A 的标题同步到 B 的标题栏；B 标题栏右侧显示流量，右键切换档位和清晰度；找窗口有超时，隐藏的窗口会被叫回；协议升到 2。

**Architecture:** 纯计算（圆角填补、标题栏高度与坐标换算、超时、消息格式、流量文字）放进 `RappCore` 并做单元测试；主机用 AX 量标题栏、读标题，用 `sourceRect` 只采内容区；客户端加一个标题栏尾部附件显示流量并带右键菜单。

**Tech Stack:** Swift 5.9 SwiftPM，macOS 14+，ScreenCaptureKit、AppKit、ApplicationServices（AX）、Network.framework、XCTest。

**Spec:** `docs/superpowers/specs/2026-11-10-rapp-design.md`（修订 1）

## Global Constraints

- 不加第三方依赖。
- `protocolVersion = 2`；版本不同的错误文字：`protocol version mismatch: host 2, client N (update both sides)`。
- 新消息类型号：`Title` = 10（A→B），`SetMode` = 11（B→A）。
- 标题栏高度 = 2 ×（关闭按钮中心 y − 窗口顶边 y），取整；无按钮、≤ 0、> 窗口高度一半 → 0。
- 内容区是 `Ready` 尺寸、`Mouse`/`Scroll` 的 0–1 坐标、`Resize` 尺寸的基准。
- 标题：空 → app 名字；最长 200 个字符。
- 找窗口总时限 10 秒；超时文字：`timed out asking macOS for windows (check the Screen Recording permission, and look for a permission prompt on A)`。
- 流量文字：`%.1f kbps`，零为 `0 kbps`；系统字体 11 号，`secondaryLabelColor`；收到 `Ready` 前不显示。
- 菜单项文字（按顺序）：`灰度 16 级 (gray4)`、`256 色 (color8)`、`高彩 (color16)`、分隔线、`清晰 (Retina, 2x)`、`省流 (1x)`。
- 主机切换时打印：`mode -> <档位名>, scale <n>`。
- 这个目录**不是 git 仓库**：每个任务的最后一步是 `./scripts/check.sh` 输出 `EXIT=0`，代替提交。

## Review Focus

1. **切换档位时还有旧档位的帧在路上**（capture 队列刚量化完、或 `pending` 里存着）。新编码器的 `precondition` 会因样本字节数不符直接崩溃。期望：旧档位的样本被丢弃，下一帧按新档位全量。由 Task 6 的样本档位检查保证，并在 Task 6 手工步骤里快速连切验证。
2. **窗口进入全屏**：全屏时标题栏隐藏，但 AX 仍报关闭按钮，会误裁掉内容顶部。期望：全屏时不裁。Task 4 读 `AXFullScreen`，为真时标题栏高度为 0，手工验证。
3. **旧版（协议 1）客户端连新主机**：期望看到可读的版本错误，而不是 `bad data`。Task 1 单元测试 + 主机直接转发该错误文字。
4. **解码端在全量帧之前收到不同档位的增量帧**：期望明确报错，而不是错位解码。Task 1 单元测试。
5. **整行透明 / 第一行透明 / 只有 1 像素边框半透明的普通行**：期望不产生黑边、不吃掉内容。Task 2 单元测试（已在真实窗口实测：圆角行透明段最长 48 px，中间行只有 1 px）。

---

### Task 1: 协议 2、帧带档位、`Title` / `SetMode`

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`、`Sources/RappCore/TileCodec.swift`
- Modify: `Sources/rapp-host/Server.swift`（编译通过 + 转发版本错误）、`Sources/rapp-client/main.swift`（标题、按帧档位展开）
- Test: `Tests/RappCoreTests/ProtocolTests.swift`、`Tests/RappCoreTests/TileCodecTests.swift`

**Interfaces:**
- Produces:
  - `protocolVersion: UInt8 = 2`
  - `public struct ProtocolVersionMismatch: Error, CustomStringConvertible { public let client: UInt8 }`，`description` 为 Global Constraints 里的文字（N = `client`）。
  - `FramePayload.mode: Mode`；`init(mode: Mode = .gray4, width:height:isFull:data:)`。线上顺序：`u8 mode, u16 width, u16 height, u8 full, data`。
  - `Message.title(String)`（10，`w.string`）、`Message.setMode(mode: Mode, scale: UInt8)`（11，`u8 mode, u8 scale`，scale 只能 1 或 2）。`knownTypes = 1...11`。
  - `FrameEncoder.encode` 返回的 payload 带编码器自己的 `mode`。
  - `FrameDecoder`：`init(mode: Mode = .gray4)`；`public private(set) var mode: Mode`。全量帧采用帧里的档位（重算每样本字节数）；增量帧档位与画布不同 → `CodecError("update frame mode does not match canvas")`。

- [ ] **Step 1: 写失败的测试**

`ProtocolTests.all` 里加：`.title("文档 2 — 已编辑")`、`.setMode(mode: .color16, scale: 1)`、`.frame(FramePayload(mode: .color16, width: 130, height: 70, isFull: true, data: [1, 2, 3, 250]))`。新增：

```swift
func testOldClientGetsVersionError() {
    // A protocol-1 hello: version 1, token "a", bundle "b", gray4, scale 2 (strings are u16 LE length + UTF-8).
    var p = MessageParser()
    let payload: [UInt8] = [1, 1, 0, 0x61, 1, 0, 0x62, 0, 2]
    p.append([1, UInt8(payload.count), 0, 0, 0] + payload)
    XCTAssertThrowsError(try p.next()) { error in
        XCTAssertEqual((error as? ProtocolVersionMismatch)?.client, 1)
        XCTAssertEqual("\(error)", "protocol version mismatch: host 2, client 1 (update both sides)")
    }
}
func testSetModeRejectsBadScale() {
    var p = MessageParser()
    p.append([11, 2, 0, 0, 0, 1, 3])
    XCTAssertThrowsError(try p.next())
}
```
`TileCodecTests` 新增：

```swift
func testDecoderFollowsModeOfFullFrames() throws {
    let dec = FrameDecoder()
    let g = [UInt8](repeating: 7, count: 64 * 64)
    try dec.decode(FrameEncoder(mode: .gray4).encode(samples: g, width: 64, height: 64)!)
    XCTAssertEqual(dec.mode, .gray4)
    let c = [UInt8](repeating: 9, count: 64 * 64 * 2)
    try dec.decode(FrameEncoder(mode: .color16).encode(samples: c, width: 64, height: 64)!)
    XCTAssertEqual(dec.mode, .color16)
    XCTAssertEqual(dec.samples, c)
}
func testUpdateFrameWithOtherModeIsRejected() throws {
    let enc = FrameEncoder(mode: .gray4), dec = FrameDecoder()
    var s = [UInt8](repeating: 1, count: 64 * 64)
    try dec.decode(enc.encode(samples: s, width: 64, height: 64)!)
    s[0] = 2
    var update = enc.encode(samples: s, width: 64, height: 64)!
    update.mode = .color8
    XCTAssertThrowsError(try dec.decode(update))
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test 2>&1 | tail -20` — Expected: 编译失败（`title`、`setMode`、`ProtocolVersionMismatch`、`mode:` 不存在）。

- [ ] **Step 3: 实现 Produces 里的接口**

`Hello` 解码时先读版本，不等于 2 就抛 `ProtocolVersionMismatch(client:)`。
主机 `Session.receive` 的 `catch`：`ProtocolVersionMismatch` 直接 `fail(error.description)`，其他仍是 `bad data from client: …`。
主机 `handle`：`.title` 归入"unexpected message from client"；`.setMode` 暂时 `break`（Task 6 实现）。
客户端：`case let .title(t): window.title = t`；展开用 `decoder.mode` 代替 `address.mode`。

- [ ] **Step 4: 运行测试** — `swift test 2>&1 | tail -5`，Expected: 全部通过。

- [ ] **Step 5: 检查** — `./scripts/check.sh`，Expected: 最后一行 `EXIT=0`。

---

### Task 2: 圆角填补

**Files:**
- Modify: `Sources/RappCore/Quantize.swift`（`quantize` 行为，签名不变）
- Test: `Tests/RappCoreTests/QuantizeTests.swift`

**Interfaces:**
- Produces: `Quantizer.quantize(bgra:width:height:bytesPerRow:mode:)` 签名不变；alpha < 255 的行首、行尾像素取最近不透明像素的样本。

- [ ] **Step 1: 写失败的测试**

辅助函数 `img(_ rows: [[(UInt8, UInt8, UInt8, UInt8)]]) -> [UInt8]`（R, G, B, A → BGRA 字节）。用 `.gray4`，白 = 15、黑 = 0：

```swift
func testCornerFillLeftAndRight() {
    // row: transparent, transparent, white, black, transparent
    let px = img([[(0,0,0,0), (0,0,0,0), (255,255,255,255), (0,0,0,255), (0,0,0,0)]])
    XCTAssertEqual(quant(px, w: 5, h: 1), [15, 15, 15, 0, 0])
}
func testFullyTransparentRowCopiesRowAbove() {
    let px = img([[(0,0,0,255), (255,255,255,255)], [(0,0,0,0), (0,0,0,0)]])
    XCTAssertEqual(quant(px, w: 2, h: 2), [0, 15, 0, 15])
}
func testFirstRowFullyTransparentIsWhite() {
    let px = img([[(0,0,0,0), (0,0,0,0)], [(0,0,0,255), (0,0,0,255)]])
    XCTAssertEqual(quant(px, w: 2, h: 2), [15, 15, 0, 0])
}
func testTranslucentPixelInsideRowIsKept() {
    // Only the ends are filled; a non-opaque pixel between opaque ones is quantized as is.
    let px = img([[(255,255,255,255), (0,0,0,128), (255,255,255,255)]])
    XCTAssertEqual(quant(px, w: 3, h: 1), [15, 0, 15])
}
func testOpaqueImageUnchanged() { /* 现有 testGray4 等全部 alpha 255，保持通过即可；另加一个 3×2 全不透明随机图，与逐像素 q() 结果相同 */ }
```

再加一个 `.color16` 的行尾填补用例，确认 2 字节样本整体复制。

- [ ] **Step 2: 运行，确认失败** — `swift test --filter QuantizeTests 2>&1 | tail -10`，Expected: 前四个失败。

- [ ] **Step 3: 实现**

每行：从左找第一个 alpha == 255 的下标 `f`，从右找最后一个 `l`（只扫描透明段，开销只在角上）。
没有 → 整行复制上一行输出；第一行则填白色的样本（量化 `(255,255,255)`）。
有 → 正常量化 `f...l`，`0..<f` 填 `f` 的样本，`l+1..<width` 填 `l` 的样本。不额外复制整帧。

- [ ] **Step 4: 运行测试** — `swift test --filter QuantizeTests`，Expected: 全部通过。

- [ ] **Step 5: 检查** — `./scripts/check.sh`，Expected: `EXIT=0`。

---

### Task 3: 标题栏与内容区换算、标题规则、超时、流量文字（纯函数）

**Files:**
- Modify: `Sources/RappCore/Geometry.swift`
- Create: `Sources/RappCore/Timeout.swift`
- Modify: `Sources/RappCore/Protocol.swift`（`windowTitle`、`formatKbps` 放在文件末尾）
- Test: `Tests/RappCoreTests/GeometryTests.swift`、Create `Tests/RappCoreTests/TimeoutTests.swift`、`Tests/RappCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces:
  - `public func titleRowHeight(closeButtonFrame: CGRect?, windowFrame: CGRect) -> CGFloat`
  - `public func contentRect(windowFrame: CGRect, titleRow: CGFloat) -> CGRect` — 窗口去掉顶部 `titleRow`。
  - `public func windowSize(forContent content: CGSize, titleRow: CGFloat, origin: CGPoint, screen: CGRect) -> CGSize` — 高度加 `titleRow` 后交给现有 `clampSize`。
  - `public func windowTitle(_ raw: String?, appName: String?) -> String` — 空/nil → `appName ?? "rapp"`，再取前 200 个字符。
  - `public func formatKbps(bytes: Int) -> String`
  - `public struct TimeoutError: Error {}`；`public func withTimeout<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T`

- [ ] **Step 1: 写失败的测试**

```swift
// GeometryTests
let win = CGRect(x: 100, y: 50, width: 800, height: 600)
XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 107, y: 59, width: 14, height: 14), windowFrame: win), 32)  // TextEdit
XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 120, y: 69, width: 14, height: 14), windowFrame: win), 52)  // Calculator
XCTAssertEqual(titleRowHeight(closeButtonFrame: nil, windowFrame: win), 0)
XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 107, y: 30, width: 14, height: 14), windowFrame: win), 0)  // above the window
XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 107, y: 80, width: 14, height: 14),
                              windowFrame: CGRect(x: 100, y: 50, width: 800, height: 60)), 0)                        // > half height
XCTAssertEqual(contentRect(windowFrame: win, titleRow: 32), CGRect(x: 100, y: 82, width: 800, height: 568))
XCTAssertEqual(globalPoint(x: 0, y: 0, windowFrame: contentRect(windowFrame: win, titleRow: 32)), CGPoint(x: 100, y: 82))
let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
XCTAssertEqual(windowSize(forContent: CGSize(width: 800, height: 568), titleRow: 32, origin: win.origin, screen: screen),
               CGSize(width: 800, height: 600))
XCTAssertEqual(windowSize(forContent: CGSize(width: 800, height: 1100), titleRow: 32, origin: win.origin, screen: screen).height, 1030)

// ProtocolTests
XCTAssertEqual(windowTitle("", appName: "Calculator"), "Calculator")
XCTAssertEqual(windowTitle(nil, appName: nil), "rapp")
XCTAssertEqual(windowTitle(String(repeating: "字", count: 300), appName: "x").count, 200)
XCTAssertEqual(formatKbps(bytes: 0), "0 kbps")
XCTAssertEqual(formatKbps(bytes: 6538), "52.3 kbps")

// TimeoutTests
func testFastOperationReturns() async throws {
    let v = try await withTimeout(seconds: 1) { 42 }
    XCTAssertEqual(v, 42)
}
func testOperationThatNeverReturnsTimesOut() async {
    let start = Date()
    do {
        _ = try await withTimeout(seconds: 0.2) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never resumed
        }
        XCTFail("expected timeout")
    } catch { XCTAssertTrue(error is TimeoutError) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
}
func testOperationErrorIsPassedThrough() async { /* operation throws CodecError("x") → caught error is CodecError */ }
```

- [ ] **Step 2: 运行，确认失败** — `swift test 2>&1 | tail -20`，Expected: 编译失败（函数不存在）。

- [ ] **Step 3: 实现**

`withTimeout` **不能用 task group**：group 退出时要等所有子任务结束，而卡住的系统调用不响应取消，会让超时失效。做法：
`withCheckedThrowingContinuation` + 一个加锁的"已完成"标志；
启动两个非结构化 `Task`：一个跑 `operation`，一个 `Task.sleep` 后抛 `TimeoutError`；谁先到谁 resume，另一个被忽略（卡住的那个就留在后台）。

- [ ] **Step 4: 运行测试** — `swift test`，Expected: 全部通过。

- [ ] **Step 5: 检查** — `./scripts/check.sh`，Expected: `EXIT=0`。

---

### Task 4: 主机只采内容区；找窗口超时并叫回隐藏窗口

**Files:**
- Modify: `Sources/rapp-host/WindowResizer.swift`、`Sources/rapp-host/WindowCapture.swift`、`Sources/rapp-host/Server.swift`

**Interfaces:**
- Consumes: `titleRowHeight`、`contentRect`、`windowSize(forContent:…)`、`withTimeout`、`TimeoutError`（Task 3）。
- Produces:
  - `WindowResizer.titleRowHeight(pid: pid_t, currentFrame: CGRect) -> CGFloat` — AX 匹配窗口；`kAXFullScreenAttribute`（字符串 `"AXFullScreen"`）为真 → 0；否则取 `kAXCloseButtonAttribute` 的位置和尺寸，交给 `titleRowHeight(closeButtonFrame:windowFrame:)`。
  - `WindowResizer.title(pid: pid_t, currentFrame: CGRect) -> String?` — `kAXTitleAttribute`。
  - `WindowCapture.titleRow: CGFloat`（只读，加锁）、`WindowCapture.contentFrame: CGRect?` = `contentRect(currentFrame, titleRow)`。
  - `WindowCapture.refreshIfNeeded() async -> Bool`（替换 `refreshSizeIfNeeded`）：窗口尺寸或标题栏高度变了就 `updateConfiguration`，返回 true。

- [ ] **Step 1: `WindowCapture`**
  - `init` 从 `window.owningApplication?.processID` 取 pid，`start()` 前先量一次 `titleRow`。
  - `makeConfiguration(windowSize:titleRow:)`：
    - `sourceRect = CGRect(x: 0, y: titleRow, width: w, height: h − titleRow)`；
    - 输出宽高 = 内容区尺寸 × `min(scale, pointPixelScale)`；
    - 其余设置不变。
  - `find`：每次 `SCShareableContent` 调用都包在 `withTimeout(seconds: 剩余时间)` 里，`TimeoutError` 转成 `HostError(超时文字)`。第一次扫描没有候选窗口时，对已运行的 app 调用一次：
    ```swift
    NSWorkspace.shared.openApplication(at: app.bundleURL!, configuration: cfg)   // cfg.activates = true
    ```
    `bundleURL` 为 nil 就跳过。

- [ ] **Step 2: `Session` 改用内容区**
  - `Ready` 的宽高取 `contentFrame`；
  - `InputInjector` 的 `frameProvider` 改成 `{ capture?.contentFrame }`；
  - `tick` 调 `refreshIfNeeded`；
  - `resizeWindow` 用 `windowSize(forContent:titleRow:origin:screen:)`，`WindowResizer.resize` 仍按窗口 `currentFrame` 匹配。

- [ ] **Step 3: 检查** — `./scripts/check.sh`，Expected: `EXIT=0`。

- [ ] **Step 4: 手工验证**（重启主机，`run_in_background` 启动，不用 `nohup`）
  - 文本编辑：B 上没有标题栏；点画面最上方一行，A 上光标落在正文第一行附近。
  - 计算器：画面顶部是显示屏，没有模式按钮那一行。
  - B 上拖大窗口：A 窗口左上角不动，B 画面清晰。
  - A 上把文本编辑切到全屏：B 画面不缺顶部内容。
  - 关掉 Claude 窗口（⌘W，app 不退出）后连接：主机叫回窗口并开始传输。

---

### Task 5: 同步标题

**Files:**
- Modify: `Sources/rapp-host/Server.swift`

**Interfaces:**
- Consumes: `WindowResizer.title(pid:currentFrame:)`（Task 4）、`windowTitle(_:appName:)`（Task 3）、`Message.title`（Task 1）。

- [ ] **Step 1: 实现**
  - `Session` 加 `lastTitle: String`。
  - `captureReady` 里 `Ready` 的标题 = `windowTitle(AX 标题 ?? capture.window.title, appName: app.localizedName)`，并记入 `lastTitle`。
  - `tick` 每秒重算，与 `lastTitle` 不同就 `send(.title(新标题))` 并更新 `lastTitle`。

- [ ] **Step 2: 检查** — `./scripts/check.sh`，Expected: `EXIT=0`。

- [ ] **Step 3: 手工验证**
  - 文本编辑里 ⌘N 新建、在两个文档间切换：B 的标题 1 秒内跟着变。
  - 连 Claude：B 标题显示 "Claude"。

---

### Task 6: 主机处理 `SetMode`

**Files:**
- Modify: `Sources/rapp-host/Server.swift`、`Sources/rapp-host/WindowCapture.swift`

**Interfaces:**
- Consumes: `Message.setMode`（Task 1）、`WindowCapture.refreshIfNeeded`（Task 4）。
- Produces:
  - `WindowCapture.setScale(_ scale: Int) async -> Bool` — 改倍数并按当前内容区 `updateConfiguration`；倍数没变返回 false。

- [ ] **Step 1: 实现**
  - `mode` 改为加锁读写：capture 队列的 `frameArrived` 读它来量化，并把用到的档位随样本一起交给 `submit`。
  - `submit` 发现样本档位 ≠ 当前 `mode` 就丢弃（Review Focus 1）。
  - 收到 `.setMode(m, s)`：
    - `m` 变了：设 `mode = m`，`encoder = FrameEncoder(mode: m)`，`pending = nil`；
    - `s` 变了：`await capture.setScale(Int(s))` 成功后在 `queue` 上 `encoder?.reset()`；
    - 任何一项变了就打印 `mode -> \(m.name), scale \(s)`；两项都没变则什么也不做。

- [ ] **Step 2: 检查** — `./scripts/check.sh`，Expected: `EXIT=0`。

- [ ] **Step 3: 手工验证**（Task 7 完成后一起做）。

---

### Task 7: 客户端流量显示与右键菜单

**Files:**
- Create: `Sources/rapp-client/TrafficLabel.swift`
- Modify: `Sources/rapp-client/Connection.swift`、`Sources/rapp-client/main.swift`

**Interfaces:**
- Consumes: `formatKbps`（Task 3）、`Message.setMode`（Task 1）。
- Produces:
  - `Connection.onBytes: ((Int) -> Void)?` — `receive` 每收到一块数据就以 `data.count` 回调（收到的全部字节都算，包括消息头）。
  - `final class TrafficLabel: NSTextField`：
    - `init(mode: Mode, scale: UInt8)`；
    - `var onSelect: ((Mode, UInt8) -> Void)?`；
    - `func add(bytes: Int)`；
    - `func start()` — 显示出来并开始每秒刷新，刷新时显示 `formatKbps(本秒字节数)` 并清零。
  - 右键和 Control-点击：用 `NSView.menu`，菜单项文字见 Global Constraints，`state = .on` 标出当前选择。选中某项就更新选择、刷新勾选，并回调 `onSelect(当前档位, 当前倍数)`。

- [ ] **Step 1: 实现**
  - `TrafficLabel`：不可编辑、无边框、无背景，字体 `.systemFont(ofSize: 11)`，颜色 `.secondaryLabelColor`，初始隐藏。
  - `main.swift`：
    - 用 `NSTitlebarAccessoryViewController`（`layoutAttribute = .trailing`）把它放到标题栏右侧，右边留 8 点；
    - `connection.onBytes` 接 `label.add`；
    - `.ready` 时 `label.start()`；
    - `onSelect` 时发 `.setMode(mode:scale:)`。

- [ ] **Step 2: 检查** — `./scripts/check.sh`，Expected: `EXIT=0`。

- [ ] **Step 3: 手工验证**（连文本编辑）
  - 连接中看不到流量；连上后画面静止时显示 `0 kbps`，打字时数字变化。
  - 右键流量文字，菜单与规格第 7 节一致，gray4 和 2x 打勾；Control-点击效果相同。
  - 切到 `color8`：画面立即变彩色，主机打印 `mode -> color8, scale 2`，码率变化。再切到 `省流 (1x)`：画面变软、码率下降。
  - 在 A 上滚动文本的同时，快速连切 gray4 → color16 → gray4 几次：主机不崩溃，B 画面正常（Review Focus 1）。

---

### Task 8: 文档与端到端验收

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README**
  - 协议版本 2：两端都要更新。
  - 右键流量文字可以切换档位和清晰度。
  - 第一次采集时 A 上可能弹出授权确认，要点"允许"。
  - 画面不含标题栏，标题栏里的按钮在 B 上不可用。

- [ ] **Step 2: 检查** — `./scripts/check.sh`，Expected: `EXIT=0`，测试数量比 42 多。

- [ ] **Step 3: 端到端** — 按规格第 9 节逐条验证第 1 节的八条（文本编辑、计算器各一遍），并截图 B 窗口作为记录：
  - 顶部无标题栏；
  - 底部两角不黑；
  - 标题正确；
  - 右上角有流量。
