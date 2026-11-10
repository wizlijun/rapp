# rapp 最小原型 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 A（macOS）上一个 app 窗口的画面用低位深按块编码串流到 B（macOS）的窗口，并把 B 的鼠标、文字、窗口缩放送回 A。

**Architecture:** 一个 SwiftPM 包。`RappCore` 是纯计算库（量化、按块编解码、消息格式、几何换算），有完整单元测试。`rapp-host` 用 ScreenCaptureKit 采集、CGEvent 注入、AX 改窗口大小。`rapp-client` 是 AppKit 窗口程序。两端用一条 TCP 连接通信。

**Tech Stack:** Swift 5.9+、SwiftPM、系统 zlib、ScreenCaptureKit、CoreGraphics、ApplicationServices（AX）、AppKit、Network.framework、XCTest。

**Spec:** `docs/superpowers/specs/2026-11-10-rapp-design.md`

## Global Constraints

- 全部 Swift，没有第三方依赖；压缩只用系统 zlib（通过 `CZlib` 系统库目标引入）。
- `Package.swift`：`swift-tools-version:5.9`，`platforms: [.macOS(.v14)]`。两个可执行目标只在 `#if os(macOS)` 下声明，使 `RappCore` 及其测试也能在 Linux 上编译。
- 默认端口 `47800`；协议版本 `1`；分块边长 `64`；采集最高 `15` fps；文字注入每个事件最多 `20` 个 UTF-16 单元。
- 档位名：`gray4`（默认）、`color8`、`color16`。`scale` 只能是 `1` 或 `2`（默认 `2`）。
- 不加密，只校验口令。不做规格第 11 节列出的任何功能。
- 任何错误打印一行原因后退出（客户端）或回到等待连接（主机），不做重连。

## 执行环境说明

- 执行者的 shell 是 Linux，不能编译 macOS 目标。每个任务的验证命令统一为在 Mac 上运行 `./scripts/check.sh`，它把 `swift build` 和 `swift test` 的输出写到 `.build-logs/check.log`，执行者读这个文件判断结果。
- `git commit` 在 Mac 终端执行（执行者的环境里 git 提交需要整个 `~/git` 的删除权限）。
- 任务 5 起的手工验证需要 A 上的终端有"屏幕录制"和"辅助功能"授权。原型阶段 A 和 B 可以是同一台 Mac（地址用 `127.0.0.1`）。

## Review Focus

1. 窗口尺寸不是 64 的整数倍 → 边缘块按实际宽高编解码，画面右边和下边不能错位（任务 3 `testOddSizeRoundTrips`）。
2. 文字里的 emoji 等代理对正好落在 20 单元的分段边界 → 不能被拆成两半（任务 4 `testChunkDoesNotSplitSurrogatePair`）。
3. 网络上来的残缺、超长、未知类型的消息 → 解析器抛错，进程不能崩（任务 4 `testParserRejectsBadInput`）。
4. 点击落在等比缩放留出的空白边上 → 不发送任何鼠标消息（任务 4 `testPointOutsideImageIsNil`）。
5. app 自己改变窗口大小 → 下一帧是全量帧，解码端按新尺寸重建画布（任务 3 `testSizeChangeForcesFull`）。

---

## File Structure

```
Package.swift
scripts/check.sh                         在 Mac 上构建并测试，日志写入 .build-logs/check.log
.gitignore                               .build/  .build-logs/  .swiftpm/
Sources/CZlib/module.modulemap  shim.h   系统 zlib 的模块封装
Sources/RappCore/
  Deflate.swift        DeflateStream / InflateStream（跨帧保留上下文，sync flush）
  Quantize.swift       Mode、Quantizer（BGRA ↔ 样本）
  TileCodec.swift      FramePayload、FrameEncoder、FrameDecoder
  Protocol.swift       Message、MessageParser、RemoteAddress
  Geometry.swift       等比缩放、坐标换算、尺寸裁剪、UTF-16 分段
Sources/rapp-host/
  main.swift           参数、授权检查、启动 Server
  Server.swift         监听、会话、发送节奏、每秒统计
  WindowCapture.swift  找窗口、SCStream、尺寸变化
  WindowResizer.swift  用 AX 改窗口大小
  InputInjector.swift  鼠标、滚轮、按键、文字注入
Sources/rapp-client/
  main.swift           参数、窗口、把各部分接起来
  Connection.swift     NWConnection 收发消息
  RemoteView.swift     显示画面、鼠标和滚轮
  InputBar.swift       输入条（规格文件清单里没有，从 main.swift 拆出来）
Tests/RappCoreTests/
  DeflateTests.swift  QuantizeTests.swift  TileCodecTests.swift  ProtocolTests.swift  GeometryTests.swift
README.md
```

---

### Task 1: 包骨架与 zlib 流

**Files:**
- Create: `Package.swift`, `.gitignore`, `scripts/check.sh`, `Sources/CZlib/module.modulemap`, `Sources/CZlib/shim.h`, `Sources/RappCore/Deflate.swift`
- Create: `Sources/rapp-host/main.swift`, `Sources/rapp-client/main.swift`（各只有一行 `print`，占位到任务 5、6）
- Test: `Tests/RappCoreTests/DeflateTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public final class DeflateStream { public init(level: Int32 = 6); public func compress(_ input: [UInt8]) -> [UInt8]; public func reset() }
  public final class InflateStream { public init(); public func decompress(_ input: [UInt8]) throws -> [UInt8]; public func reset() }
  public struct CodecError: Error, Equatable { public let message: String }
  ```
  `compress` 每次调用以 `Z_SYNC_FLUSH` 结束，上下文保留到下一次调用；`reset` 之后两端都从空上下文开始。

- [ ] **Step 1: 写 `Package.swift`、`CZlib`、`.gitignore`、`scripts/check.sh`**

  `module.modulemap`：`module CZlib [system] { header "shim.h" link "z" export * }`；`shim.h`：`#include <zlib.h>`。
  `scripts/check.sh`：`mkdir -p .build-logs && { swift build 2>&1 && swift test 2>&1; echo "EXIT=$?"; } | tee .build-logs/check.log`。

- [ ] **Step 2: 写失败的测试**

  ```swift
  func testRoundTripAcrossChunks() throws {
      let a = pseudoRandom(count: 4096, seed: 1), b = pseudoRandom(count: 100, seed: 2)
      let d = DeflateStream(), i = InflateStream()
      XCTAssertEqual(try i.decompress(d.compress(a)), a)
      XCTAssertEqual(try i.decompress(d.compress(b)), b)
  }
  func testContextIsKeptBetweenCalls() {
      let a = pseudoRandom(count: 4096, seed: 1); let d = DeflateStream()
      let first = d.compress(a), second = d.compress(a)
      XCTAssertLessThan(second.count, first.count / 4)
  }
  func testResetStartsFresh() throws {
      let a = pseudoRandom(count: 4096, seed: 1); let d = DeflateStream(), i = InflateStream()
      _ = try i.decompress(d.compress(a)); d.reset(); i.reset()
      XCTAssertEqual(try i.decompress(d.compress(a)), a)
  }
  func testGarbageThrows() { XCTAssertThrowsError(try InflateStream().decompress([1, 2, 3, 4, 5])) }
  ```
  `pseudoRandom(count:seed:)` 是测试里的线性同余生成器，放在 `Tests/RappCoreTests/DeflateTests.swift` 顶部供其他测试文件复用。

- [ ] **Step 3: 运行 `./scripts/check.sh`，确认因 `DeflateStream` 未定义而失败**
- [ ] **Step 4: 实现 `Deflate.swift`**（`deflateInit` / `inflateInit` 用默认 zlib 头；输出缓冲不够时循环扩容）
- [ ] **Step 5: 运行 `./scripts/check.sh`，日志末尾 `EXIT=0`，4 个测试通过**
- [ ] **Step 6: Commit** `git init && git add -A && git commit -m "feat: package skeleton and zlib streams"`

---

### Task 2: 像素量化

**Files:**
- Create: `Sources/RappCore/Quantize.swift`
- Test: `Tests/RappCoreTests/QuantizeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum Mode: UInt8, CaseIterable { case gray4 = 0, color8 = 1, color16 = 2
      public var bytesPerSample: Int        // 1, 1, 2
      public var name: String               // "gray4" / "color8" / "color16"
      public init?(name: String) }
  public enum Quantizer {
      /// 输入是 B,G,R,A 字节序；输出长度 width*height*bytesPerSample，color16 为小端
      public static func quantize(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, mode: Mode) -> [UInt8]
      /// 输出 BGRA，A=255，每行 width*4 字节
      public static func expand(samples: [UInt8], width: Int, height: Int, mode: Mode) -> [UInt8] }
  ```

量化公式（整数运算，R、G、B 为 0–255）：

| 档位 | 量化 | 还原 |
|---|---|---|
| `gray4` | `Y = (77R + 150G + 29B) >> 8`；`s = (Y*15 + 127) / 255` | `v = s * 17`，B=G=R=v |
| `color8` | 若 `max(R,G,B) - min(R,G,B) < 16`：`s = 216 + (Y*39 + 127) / 255`；否则 `ri = (R*5 + 127) / 255`（G、B 同理），`s = ri*36 + gi*6 + bi` | `s >= 216`：`v = ((s-216)*255 + 19) / 39`；否则各分量 `i * 51` |
| `color16` | `s = (R>>3)<<11 \| (G>>2)<<5 \| (B>>3)` | `R = (r5<<3)\|(r5>>2)`，`G = (g6<<2)\|(g6>>4)`，`B = (b5<<3)\|(b5>>2)` |

- [ ] **Step 1: 写失败的测试**

  辅助函数 `q(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ mode: Mode) -> [UInt8]` 量化单个像素，`e(_ s: [UInt8], _ mode: Mode) -> [UInt8]` 还原出 `[B, G, R, A]`。
  ```swift
  func testGray4() {
      XCTAssertEqual(q(255,255,255,.gray4), [15]); XCTAssertEqual(q(0,0,0,.gray4), [0])
      XCTAssertEqual(q(128,128,128,.gray4), [8]);  XCTAssertEqual(e([8], .gray4), [136,136,136,255])
  }
  func testColor8() {
      XCTAssertEqual(q(255,0,0,.color8), [180]);     XCTAssertEqual(e([180], .color8), [0,0,255,255])
      XCTAssertEqual(q(128,128,128,.color8), [236]); XCTAssertEqual(e([236], .color8), [131,131,131,255])
      XCTAssertEqual(q(255,255,255,.color8), [255]); XCTAssertEqual(q(0,0,0,.color8), [216])
  }
  func testColor16() {
      XCTAssertEqual(q(255,0,0,.color16), [0x00, 0xF8]); XCTAssertEqual(e([0x00, 0xF8], .color16), [0,0,255,255])
      XCTAssertEqual(q(8,4,8,.color16), [0x21, 0x08]);   XCTAssertEqual(e([0x21, 0x08], .color16), [8,4,8,255])
  }
  func testRowPaddingIsSkipped() {   // 2x2 图像，bytesPerRow = 12（每行多 4 字节填充）
      // 四个像素依次为白、黑、黑、白，填充字节为 0x7F；gray4 结果应为 [15, 0, 0, 15]
  }
  func testModeNames() { XCTAssertEqual(Mode(name: "color8"), .color8); XCTAssertNil(Mode(name: "x")); XCTAssertEqual(Mode.gray4.name, "gray4") }
  ```
- [ ] **Step 2: 运行 `./scripts/check.sh`，确认失败**
- [ ] **Step 3: 实现 `Quantize.swift`**
- [ ] **Step 4: 运行 `./scripts/check.sh`，`EXIT=0`**
- [ ] **Step 5: Commit** `git commit -am "feat: pixel quantization for gray4/color8/color16"`

---

### Task 3: 按块编解码

**Files:**
- Create: `Sources/RappCore/TileCodec.swift`
- Test: `Tests/RappCoreTests/TileCodecTests.swift`

**Interfaces:**
- Consumes: `Mode`、`DeflateStream`、`InflateStream`、`CodecError`
- Produces:
  ```swift
  public let tileSize = 64
  public struct FramePayload: Equatable { public var width: UInt16; public var height: UInt16; public var isFull: Bool; public var data: [UInt8] }
  public final class FrameEncoder {
      public init(mode: Mode)
      /// 没有块变化时返回 nil。首帧、尺寸变化后、reset() 后的一帧是全量帧（isFull = true，并重置压缩流）
      public func encode(samples: [UInt8], width: Int, height: Int) -> FramePayload?
      public func reset()
      public private(set) var lastTileCount: Int
      static func kind(forDistinctCount n: Int) -> UInt8 }
  public final class FrameDecoder {
      public init(mode: Mode)
      public private(set) var width: Int; public private(set) var height: Int
      public private(set) var samples: [UInt8]
      /// isFull 时按新尺寸重建画布并重置解压流；非全量帧在没有画布或尺寸不符时抛 CodecError
      public func decode(_ frame: FramePayload) throws }
  ```

压缩前的帧体格式（小端）：

```
u16 tileCount
重复 tileCount 次：
  u16 tileIndex      行优先，每行 ceil(width/64) 块
  u8  kind           0=纯色  1=1bit  2=2bit  4=4bit  255=原始
  kind 0：  1 个样本
  kind 1/2/4：u8 n，n 个样本（按样本值升序），然后逐行的索引位，每行高位在前、行尾补齐到整字节
  kind 255：块内全部样本，行优先
```
边缘块的宽高是 `min(64, width - x0)` × `min(64, height - y0)`。块内不同样本数与 `kind` 的对应：1→0，2→1，3–4→2，5–16→4，>16→255。

- [ ] **Step 1: 写失败的测试**

  `randomSamples(width:height:mode:seed:)` 生成合法样本（`gray4` 每字节 0–15）。
  ```swift
  func testFirstFrameIsFullAndRoundTrips() throws { for mode in Mode.allCases {
      let s = randomSamples(width: 128, height: 64, mode: mode, seed: 3)
      let enc = FrameEncoder(mode: mode), dec = FrameDecoder(mode: mode)
      let p = try XCTUnwrap(enc.encode(samples: s, width: 128, height: 64))
      XCTAssertTrue(p.isFull); XCTAssertEqual(p.width, 128); XCTAssertEqual(p.height, 64)
      try dec.decode(p); XCTAssertEqual(dec.samples, s) } }
  func testOddSizeRoundTrips() throws { /* 同上，尺寸 130×70，三个档位；另加一帧改动右下角像素后再次往返相等 */ }
  func testUnchangedFrameReturnsNil() { /* 同一份样本编码两次，第二次为 nil */ }
  func testSinglePixelChangeEncodesOneTile() throws { /* 改 (70, 10) 处一个样本：isFull == false，lastTileCount == 1，解码后相等 */ }
  func testSizeChangeForcesFull() throws { /* 先 130×70 再 64×64：第二帧 isFull == true，dec.width == 64，dec.samples 相等 */ }
  func testResetForcesFull() { /* reset() 后编码同一份样本，返回非 nil 且 isFull == true */ }
  func testKindSelection() { XCTAssertEqual([1,2,3,4,5,16,17].map(FrameEncoder.kind(forDistinctCount:)), [0,1,2,2,4,4,255]) }
  func testLowColorTileIsSmallerThanRaw() { /* color16、64×64、只有 2 种样本的棋盘格：data.count < 64*64*2 / 8 */ }
  func testDeltaBeforeFullThrows() { /* 新建解码器直接 decode 一个 isFull == false 的帧，抛错 */ }
  func testCorruptDataThrows() { /* FramePayload(width: 64, height: 64, isFull: true, data: [1,2,3]) 抛错 */ }
  ```
- [ ] **Step 2: 运行 `./scripts/check.sh`，确认失败**
- [ ] **Step 3: 实现 `TileCodec.swift`**

  编码器保存上一次**已返回**的样本画布，逐块比较字节，不同的块才编码。解码器对每个字段做越界检查，越界抛 `CodecError`。
- [ ] **Step 4: 运行 `./scripts/check.sh`，`EXIT=0`**
- [ ] **Step 5: Commit** `git commit -am "feat: tile palette codec with persistent deflate stream"`

---

### Task 4: 消息格式、地址解析、几何换算

**Files:**
- Create: `Sources/RappCore/Protocol.swift`, `Sources/RappCore/Geometry.swift`
- Test: `Tests/RappCoreTests/ProtocolTests.swift`, `Tests/RappCoreTests/GeometryTests.swift`

**Interfaces:**
- Consumes: `Mode`、`FramePayload`、`CodecError`
- Produces:
  ```swift
  public let protocolVersion: UInt8 = 1
  public let defaultPort: UInt16 = 47800
  public let maxMessageLength = 64 * 1024 * 1024
  public enum MouseKind: UInt8 { case down = 0, up = 1, drag = 2 }
  public enum MouseButton: UInt8 { case left = 0, right = 1 }
  public enum Message: Equatable {
      case hello(token: String, bundleID: String, mode: Mode, scale: UInt8)                    // 类型 1
      case ready(title: String, width: UInt16, height: UInt16)                                 // 2
      case error(String)                                                                        // 3
      case frame(FramePayload)                                                                  // 4
      case text(String)                                                                         // 5
      case key(keyCode: UInt16, modifiers: UInt64, down: Bool)                                  // 6
      case mouse(kind: MouseKind, button: MouseButton, x: Float, y: Float, clickCount: UInt8)   // 7
      case scroll(x: Float, y: Float, dx: Float, dy: Float)                                     // 8
      case resize(width: UInt16, height: UInt16)                                                // 9
      public func encoded() -> [UInt8] }          // 含 5 字节头：u8 类型 + u32 小端长度
  public struct MessageParser { public init(); public mutating func append(_ bytes: [UInt8]); public mutating func next() throws -> Message? }
  public struct RemoteAddress: Equatable {
      public var host: String; public var port: UInt16; public var bundleID: String
      public var token: String; public var mode: Mode; public var scale: UInt8
      public init(url: String) throws }
  // Geometry.swift
  public func aspectFitRect(imageSize: CGSize, in viewSize: CGSize) -> CGRect
  public func normalizedPoint(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> (x: Float, y: Float)?   // 视图坐标原点在左上
  public func globalPoint(x: Float, y: Float, windowFrame: CGRect) -> CGPoint
  public func clampSize(requested: CGSize, origin: CGPoint, screen: CGRect) -> CGSize                        // 下限 100×100
  public func chunkUTF16(_ s: String, max: Int = 20) -> [[UInt16]]
  ```
  负载编码：字符串 = u16 小端长度 + UTF-8；`Float` 按 IEEE 754 位模式小端；`hello` 负载首字节是 `protocolVersion`，版本不符时解析抛错；`frame` 负载 = u16 宽、u16 高、u8 isFull、其余为压缩数据。`key` 的 `modifiers` 是 `CGEventFlags.rawValue`。

- [ ] **Step 1: 写失败的测试**

  ```swift
  // ProtocolTests
  func testEveryMessageRoundTrips() throws { /* 上面 9 种各构造一个（文本含 "你好😀"），encoded() 后喂给解析器，next() 等于原值 */ }
  func testParserHandlesSplitAndCoalescedInput() throws { /* 两条消息拼成一个数组，在任意位置切成两段 append；依次取出两条，然后 next() == nil */ }
  func testParserRejectsBadInput() {
      /* 以下每种情况 next() 抛错：类型 99；长度字段为 maxMessageLength + 1；
         hello 负载里字符串长度超出负载；hello 版本号为 2；mode 字节为 7；frame 负载不足 5 字节 */ }
  func testAddressDefaults() throws {
      let a = try RemoteAddress(url: "rapp://mac-a.local/com.apple.TextEdit?token=abc")
      XCTAssertEqual(a, RemoteAddress(host: "mac-a.local", port: 47800, bundleID: "com.apple.TextEdit", token: "abc", mode: .gray4, scale: 2)) }
  func testAddressFull() throws { /* "rapp://10.0.0.5:5000/com.x.Y?token=t&mode=color16&scale=1" → port 5000、.color16、scale 1 */ }
  func testAddressErrors() { /* 以下各抛错：scheme 为 http；没有 token；没有 bundle-id；scale=3；mode=foo */ }
  // GeometryTests
  func testAspectFit() { XCTAssertEqual(aspectFitRect(imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 400, height: 400)), CGRect(x: 0, y: 100, width: 400, height: 200)) }
  func testNormalizedPoint() { /* 上例中 (200,200) → (0.5, 0.5) */ }
  func testPointOutsideImageIsNil() { /* 上例中 (200,50) → nil */ }
  func testGlobalPoint() { XCTAssertEqual(globalPoint(x: 0.5, y: 0.5, windowFrame: CGRect(x: 100, y: 200, width: 800, height: 600)), CGPoint(x: 500, y: 500)) }
  func testClampSize() {
      let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080), o = CGPoint(x: 100, y: 100)
      XCTAssertEqual(clampSize(requested: CGSize(width: 3000, height: 2000), origin: o, screen: screen), CGSize(width: 1820, height: 980))
      XCTAssertEqual(clampSize(requested: CGSize(width: 10, height: 10), origin: o, screen: screen), CGSize(width: 100, height: 100)) }
  func testChunkDoesNotSplitSurrogatePair() {
      let chunks = chunkUTF16(String(repeating: "a", count: 19) + "😀b")
      XCTAssertEqual(chunks.map(\.count), [19, 3]); XCTAssertEqual(chunkUTF16(""), []) }
  ```
  `RemoteAddress` 需要一个逐成员初始化器供测试使用。
- [ ] **Step 2: 运行 `./scripts/check.sh`，确认失败**
- [ ] **Step 3: 实现 `Protocol.swift` 和 `Geometry.swift`**
- [ ] **Step 4: 运行 `./scripts/check.sh`，`EXIT=0`**
- [ ] **Step 5: Commit** `git commit -am "feat: wire messages, address parsing, geometry helpers"`

---

### Task 5: 主机——采集并发送画面

**Files:**
- Modify: `Sources/rapp-host/main.swift`
- Create: `Sources/rapp-host/Server.swift`, `Sources/rapp-host/WindowCapture.swift`

**Interfaces:**
- Consumes: 任务 2–4 的全部公开接口
- Produces:
  ```swift
  final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
      /// app 未运行则启动并等待，最多 10 秒；取屏幕上 windowLayer == 0 且面积最大的窗口
      static func find(bundleID: String) async throws -> (window: SCWindow, app: NSRunningApplication)
      init(window: SCWindow, scale: Int, onFrame: @escaping (CVPixelBuffer) -> Void, onStopped: @escaping (String) -> Void)
      func start() async throws
      func stop()
      var currentFrame: CGRect? { get }               // 用 CGWindowListCopyWindowInfo 按 windowID 实时查询，全局坐标，原点左上
      func refreshSizeIfNeeded() async -> Bool }      // 尺寸变了就 updateConfiguration，返回 true
  final class Server { init(port: UInt16, token: String); func start() throws }
  final class Session {    // Server.swift 内；一条连接一个，所有状态在一个串行队列上
      func send(_ m: Message)
      var capture: WindowCapture? { get }; var app: NSRunningApplication? { get }
      var onInput: ((Message) -> Void)? }             // text/key/mouse/scroll/resize 交给它，任务 7、8 接上
  ```

行为要点：
- `main.swift`：解析 `--token`（必填）和 `--port`；用 `CGPreflightScreenCaptureAccess` 和 `AXIsProcessTrusted` 检查授权，缺哪项就打印哪项并触发系统授权提示后退出；打印 `listening on <port>`。
- 同一时间只接受一条连接；第二条连接收到 `error("busy")` 后被关闭。
- 口令用常数时间比较；不符回 `error("bad token")` 并断开。
- `SCStreamConfiguration`：`pixelFormat = kCVPixelFormatType_32BGRA`、`showsCursor = false`、`minimumFrameInterval = 1/15`、宽高 = 窗口点尺寸 × scale、`queueDepth = 3`。只处理状态为 `.complete` 的帧。
- 发送节奏按规格 4.3：`sendInFlight` 为真时只保存最新的样本数组；发送完成回调里若有保存的样本就编码并发送。
- 每秒一次：调用 `refreshSizeIfNeeded()`，返回 true 时 `encoder.reset()`；打印 `[stats] <kbps> kbps <fps> fps <宽>x<高>`（只统计 `frame` 消息的字节）。
- 连接断开：停止采集，打印原因，回到等待连接。窗口关闭或 app 退出（流停止回调）：发 `error` 后断开。

- [ ] **Step 1: 实现 `WindowCapture.swift`**
- [ ] **Step 2: 实现 `Server.swift`（含 `Session`）和 `main.swift`**
- [ ] **Step 3: 运行 `./scripts/check.sh`，`EXIT=0`**
- [ ] **Step 4: 手工验证** 在 Mac 上运行 `swift run rapp-host --token abc`，输出 `listening on 47800`；首次运行按提示给终端授权后重跑。
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: host window capture and frame streaming"`

---

### Task 6: 客户端——连接并显示画面

**Files:**
- Modify: `Sources/rapp-client/main.swift`
- Create: `Sources/rapp-client/Connection.swift`, `Sources/rapp-client/RemoteView.swift`

**Interfaces:**
- Consumes: `RemoteAddress`、`Message`、`MessageParser`、`FrameDecoder`、`Quantizer.expand`
- Produces:
  ```swift
  final class Connection {
      init(address: RemoteAddress)
      var onMessage: ((Message) -> Void)?       // 在主队列回调
      var onClosed: ((String) -> Void)?
      func start()                               // 连上后自动发送 hello
      func send(_ m: Message) }
  final class RemoteView: NSView {               // isFlipped = true；acceptsFirstResponder = false
      var imageSize: CGSize { get }              // 当前画面的像素尺寸
      func show(bgra: [UInt8], width: Int, height: Int)   // 生成 CGImage 赋给 layer.contents；contentsGravity = .resizeAspect
      var onMouse: ((Message) -> Void)? }        // 任务 7 使用
  ```

行为要点：
- `main.swift`：第一个参数是地址；缺失或解析失败时打印用法后以状态 2 退出。`NSApp.setActivationPolicy(.regular)` 并激活。
- 收到 `ready`：窗口标题设为远程窗口标题；窗口内容区 = 画面区域（`ready` 的宽 × 高，点）+ 下方 28 点高的输入条位置（任务 7 填入）。
- 收到 `frame`：`decoder.decode` → `Quantizer.expand` → `remoteView.show`。解码抛错：打印后退出。
- 收到 `error` 或连接关闭：打印原因，以状态 1 退出。关闭窗口即退出程序。

- [ ] **Step 1: 实现 `Connection.swift`、`RemoteView.swift`、`main.swift`**
- [ ] **Step 2: 运行 `./scripts/check.sh`，`EXIT=0`**
- [ ] **Step 3: 手工验证（规格 1.1、1.5）**

  终端 1：`swift run rapp-host --token abc`。先打开"文本编辑"并新建一个文稿。
  终端 2：`swift run rapp-client "rapp://127.0.0.1/com.apple.TextEdit?token=abc"`。
  预期：出现一个窗口显示文本编辑的灰阶画面；直接在文本编辑里打字，客户端画面跟着更新；停手后主机的 `[stats]` 行显示 `0.0 kbps 0 fps`。
  再分别用 `&mode=color8`、`&mode=color16`、`&scale=1` 各连一次，画面正常。把三档打字时的 kbps 记到 README。
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat: client connection and display"`

---

### Task 7: 输入——鼠标、滚轮、输入条

**Files:**
- Modify: `Sources/rapp-client/RemoteView.swift`, `Sources/rapp-client/main.swift`, `Sources/rapp-host/Server.swift`
- Create: `Sources/rapp-client/InputBar.swift`, `Sources/rapp-host/InputInjector.swift`

**Interfaces:**
- Consumes: `normalizedPoint`、`globalPoint`、`chunkUTF16`、`Session.onInput`、`WindowCapture.currentFrame`
- Produces:
  ```swift
  final class InputBar: NSTextField, NSTextFieldDelegate {
      var onSend: ((Message) -> Void)? }         // 发出 .text 或 .key
  final class InputInjector {
      init(app: NSRunningApplication, frameProvider: @escaping () -> CGRect?)
      func handle(_ m: Message) }                // 处理 text / key / mouse / scroll，其他忽略
  ```

客户端行为：
- `RemoteView`：`mouseDown/Up`、`rightMouseDown/Up` 发 `mouse(.down/.up, …, clickCount)`；`mouseDragged` 发 `mouse(.drag, .left, …)`；`scrollWheel` 发 `scroll`，`dx/dy` 取 `scrollingDeltaX/Y`（非精确滚动设备乘以 10）。坐标经 `normalizedPoint` 换算，返回 nil 时不发送。`mouseMoved` 不处理。
- `InputBar`：始终是第一响应者。
  - 有内容：回车发 `text(内容)` 并清空，其余按键本地处理。
  - 为空：在 `control(_:textView:doCommandBy:)` 里把 `insertNewline:`、`deleteBackward:`、`insertTab:`、`cancelOperation:`、`moveUp:`、`moveDown:`、`moveLeft:`、`moveRight:` 转成对应虚拟键码（36、51、48、53、126、125、123、124）的一对按下/抬起 `key` 消息。
  - 带 ⌘ 的按键：用 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 拦截；⌘Q 放行给本地；输入条为空时其余组合发一对 `key`（`modifiers` 取事件的 `CGEvent.flags.rawValue`）并吞掉事件；不为空时放行给本地。

主机行为（规格 4.4）：
- 每次 `handle` 开头：若 `app.isActive == false` 则 `app.activate()`，并等待 50 毫秒。
- `mouse`：`globalPoint` 换算后构造 `leftMouseDown/Up`、`rightMouseDown/Up`、`leftMouseDragged`，设置 `mouseEventClickState = clickCount`，`post(tap: .cghidEventTap)`。
- `scroll`：先在该位置投递一个 `mouseMoved`，再投递 `CGEvent(scrollWheelEvent2Source:units:.pixel, wheelCount: 2, wheel1: dy, wheel2: dx)`。
- `text`：对 `chunkUTF16` 的每一段，构造虚拟键码 0 的按下和抬起事件，都调用 `keyboardSetUnicodeString`，依次投递，段间等待 5 毫秒。
- `key`：按 `keyCode`、`down` 构造事件，`flags = CGEventFlags(rawValue: modifiers)`。
- `frameProvider` 返回 nil（窗口没了）时丢弃这条输入。

- [ ] **Step 1: 实现 `InputInjector.swift`，在 `Session` 建立采集后创建并接到 `onInput`**
- [ ] **Step 2: 实现 `RemoteView` 的鼠标和滚轮、`InputBar`，在 `main.swift` 里把两者的回调接到 `connection.send`**
- [ ] **Step 3: 运行 `./scripts/check.sh`，`EXIT=0`**
- [ ] **Step 4: 手工验证（规格 1.2、1.3）** 按任务 6 的方式连接文本编辑，逐项确认：
  1. 在客户端画面里单击，文本编辑里的插入点移到对应位置；双击选中一个词；拖拽选中一段。
  2. 滚轮滚动长文稿。
  3. 输入条里用中文输入法输入"你好，世界😀"，回车后整段出现在文本编辑里，输入条清空。
  4. 输入条为空时：回车换行、删除键删字、方向键移动、⌘A 全选、⌘Z 撤销。
  5. 输入条有内容时 ⌘A 只选中输入条里的文字；⌘Q 只退出客户端，文本编辑仍在运行。
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: mouse, scroll and input bar"`

---

### Task 8: 窗口大小跟随 + README

**Files:**
- Create: `Sources/rapp-host/WindowResizer.swift`, `README.md`
- Modify: `Sources/rapp-host/Server.swift`, `Sources/rapp-client/main.swift`

**Interfaces:**
- Consumes: `clampSize`、`WindowCapture.currentFrame`、`WindowCapture.refreshSizeIfNeeded()`、`FrameEncoder.reset()`
- Produces:
  ```swift
  enum WindowResizer {
      /// 在 app 的 AX 窗口里找位置和尺寸与 currentFrame 相差都不超过 2 点的窗口（找不到用第一个），只设置 kAXSizeAttribute。失败返回 false
      static func resize(pid: pid_t, currentFrame: CGRect, to size: CGSize) -> Bool }
  ```

行为要点（规格 4.5、第 7 节"窗口尺寸"）：
- 客户端：实现 `windowDidEndLiveResize`，发 `resize(画面区域的宽, 高)`（点，四舍五入）。拖动过程中不发。收到 `ready` 时设置的初始尺寸不触发发送。
- 主机收到 `resize`：屏幕取包含窗口左上角的那块 `NSScreen`（换算成原点左上的全局坐标）；`clampSize` 后调用 `WindowResizer.resize`；等待 200 毫秒后调用 `refreshSizeIfNeeded()`，返回 true 则 `encoder.reset()`。不改窗口位置。
- 设置失败或 app 没有按请求改变大小：不报错，客户端继续等比显示。
- `README.md`：用途一段话；规格第 3 节的两条命令和参数；规格第 10 节的三条前提；"不加密，只在可信局域网或 Tailscale 上使用"；任务 6 记录的三档实测码率；指向规格文件的链接。

- [ ] **Step 1: 实现 `WindowResizer.swift`，在 `Session` 里处理 `resize`**
- [ ] **Step 2: 在客户端 `main.swift` 的窗口代理里发送 `resize`**
- [ ] **Step 3: 写 `README.md`**
- [ ] **Step 4: 运行 `./scripts/check.sh`，`EXIT=0`**
- [ ] **Step 5: 手工验证（规格 1.4）**
  1. 连接文本编辑，记下 A 上窗口左上角的位置。
  2. 把客户端窗口拖大再松手：A 上的文本编辑窗口变成同样大小，左上角没动；客户端画面是按新尺寸重新排版的清晰文字。
  3. 拖小再松手，同样成立。
  4. 把客户端拖到比 A 的屏幕还大：A 的窗口停在屏幕边缘以内，客户端画面等比显示、有留白，点击位置仍然准确。
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat: remote window resize, README"`
