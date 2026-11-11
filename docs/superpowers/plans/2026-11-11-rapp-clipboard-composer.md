# rapp 剪贴板与编辑器（协议 v5）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A 上复制的文字/图片/文件/数据进 B 的每连接历史（文字自动进 B 剪贴板，大块经旁路连接下载、可续传）；B 的多行编辑器把文字、块、文件按顺序贴进 A，最后由人在 A 上提交。

**Architecture:** 协议、种类判断、拆分、文件名、续传、历史标题、ClipStore/TransferStore（含文件读写）、PasteSession 全部放 RappCore 单元测试；rapp-host 只做 NSPasteboard、NWConnection、⌘V 的胶水；rapp-client 只做 NSTextView/菜单/NWConnection 胶水；hub 在会话期间继续 accept，每个新连接各走一次 `Op::Open` 再原样转发。

**Tech Stack:** Swift 6 / SwiftPM（AppKit、Network、XCTest），Rust（tokio，testkit 假 host/client）。

**Spec:** `docs/superpowers/specs/2026-11-11-rapp-clipboard-composer-design.md`

## Global Constraints

- `protocolVersion = 5`；新消息类型 19…25 按 spec §2.1；v4 消息不变；线上格式不变（1 字节类型 + u32 LE 长度 + 负载）。
- clip 种类：0 文字、1 图片、2 文件、3 数据、4 不支持；`put` 只收 0…3。
- 文字 clip ≤ 1 MB UTF-8（`maxClipText = 1 << 20`），超出截断并置 truncated=1；文件 clip ≤ 100 个。
- `paste` 内联文字 < 60000 字节 UTF-8（`inlinePasteLimit = 60_000`），≥ 的先 `put`。
- `chunk` 每块 ≤ 256 KB（`chunkSize = 256 * 1024`）；上传收齐时 A 回一个空 `chunk`。
- 旁路连接同时 ≤ 4 条（第 5 条 `error("busy")`），第一条消息必须是 `fetch`/`put`，token 用会话的；不占会话位置。
- A：剪贴板每 0.3 秒查一次；只记前台是本会话 app 时的变化；自己写的不记；每会话 50 条，编号从 1 起；内存条目 ≤ 256 MB；上传文件写 A 的 `~/Downloads/rapp/`，`.rapp-part` 收齐后改名，不自动清理。
- A 粘贴：本次发送第一条前存整个剪贴板（> 64 MB 不存、写日志）；⌘V = keyCode 9 + Command；按完等 150 ms 回 `pasted`；最后一条后 2 秒无新 `paste` 就恢复，会话结束也恢复。
- B：历史每连接最近 20 条；编辑器最多 8 行后滚动；内联阈值：< 800 字符且 < 10 行；重试间隔 1、2、4 秒；下载到 B 的 `~/Downloads/rapp/`。
- 错误原因字符串（线上，英文）：`unknown clip`、`file changed`、`busy`、`disk full`、`write failed`、`too large`、`not uploaded`、`not supported`、`target not frontmost`、`no session`。
- 显示文字照抄 spec：`[贴入文字 #n +N 行]`、`[图片 #n 宽×高]`、`[数据 #n 类型 大小]`、`[文件 名字 大小]`；`文字 · …`、`图片 1280×720 · 340 KB`、`文件 app.log · 2.3 MB`、`3 个文件 · 12 MB`、`数据 com.adobe.pdf · 80 KB`、`文件夹（不支持）`；`上传 i/n · 名字 45%`、`下载 名字 45%`；「复制」→「已复制」/「A 上没有复制到东西」；子菜单「A 的剪贴板」。
- relay、service、`Op` 不改。Windows/Omarchy 端不在本计划内（spec §2.6）。
- 每个 commit `swift build` 通过；Swift 任务结束跑 `./scripts/check.sh`（末行 `EXIT=0`）；Rust 任务跑 `cargo test` 与 `cargo clippy --all-targets -- -D warnings`（`~/.cargo/bin/cargo`，在 `rust/` 下）。构建/测试/网络/GUI 命令用 dangerouslyDisableSandbox。
- 安全规矩（tasks/lessons.md）：只按 PID 操作自己启动的进程；合成点击前查顶层窗口；不改用户文档里的文字；不碰钥匙串。

## 已定的取舍

- rapp-host、rapp-client 是可执行 target，XCTest 测不到：能测的逻辑全部放进 RappCore（Task 1–3 走 TDD）；Task 4–9 是胶水，靠 `swift build`、Task 4 的回环脚本、Task 6 的 hub 测试和 Task 10 实机验收把关。
- spec §3.3 第 3 步「焦点窗口属于目标 app」用 `NSWorkspace.frontmostApplication` 的 pid 判断。

## Review Focus

- **A 上在别的 app 里复制（比如密码管理器）**：绝不能进任何会话的历史。→ Task 3 `testChangeWhileOtherAppFrontmostIsNotRecorded`。
- **host 自己粘贴/恢复写剪贴板**：不能被当成新 clip 回传给 B（否则 B→A 一贴，B 的历史里冒出自己贴的东西）。→ Task 3 `testOwnWritesAreNotRecorded`。
- **A 发来的文件名带 `../`、`/`、`:`、开头的 `.`、空名**：B 和 A 写文件都只能落在 `~/Downloads/rapp/` 里。→ Task 2 `testSafeFileNameKeepsOnlyTheLastComponent`。
- **续传遇到 part 比总长大、A 上文件被改**：重新从 0 开始或报 `file changed`，绝不拼出坏文件。→ Task 2 `testResumeOffsetRestartsWhenPartIsLarger`，Task 3 `testFetchOfChangedFileFails`。
- **中文/emoji 正好落在 60000 字节、1 MB 边界上**：内联判断按字节，截断不能切坏字符。→ Task 2 `testClipTextCutsOnCharacterBoundary`、`testNeedsUploadCountsBytes`。

---

### Task 1: RappCore 协议 v5

**Files:**
- Create: `Sources/RappCore/Clipboard.swift`（类型与常量）
- Modify: `Sources/RappCore/Protocol.swift`（版本号、7 个 case、编码/解码、`knownTypes`）
- Modify: `Sources/rapp-host/Server.swift:278`、`Sources/rapp-client/main.swift:166`（只为编译通过：新 case 在 host 归入 "unexpected message from client"，client 走 `default`）
- Test: `Tests/RappCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces（`Clipboard.swift`）:
  ```swift
  public enum ClipKind: UInt8, Sendable { case text = 0, image = 1, files = 2, data = 3, unsupported = 4 }
  public struct ClipFile: Equatable, Sendable { public var name: String; public var bytes: UInt64 }
  public enum ClipInfo: Equatable, Sendable {
      case text(String, truncated: Bool)
      case image(width: UInt16, height: UInt16, bytes: UInt64)
      case files([ClipFile])
      case data(uti: String, bytes: UInt64)
      case unsupported(String)
  }
  public enum PasteSource: Equatable, Sendable { case text(String), item(UInt32) }
  public let maxClipText = 1 << 20, maxClipFiles = 100, inlinePasteLimit = 60_000
  public let chunkSize = 256 * 1024, maxSideConnections = 4
  ```
- Produces（`Message` 新 case）:
  ```swift
  case clip(id: UInt32, ClipInfo)                 // 19
  case paste(seq: UInt32, PasteSource)            // 20
  case pasted(seq: UInt32, error: String)         // 21
  case fetch(token: String, clip: UInt32, file: UInt16, offset: UInt64)                       // 22，编码时写 version
  case put(token: String, item: UInt32, kind: ClipKind, uti: String, name: String, total: UInt64) // 23
  case transferStart(UInt64)                      // 24
  case chunk([UInt8])                             // 25
  ```
  负载布局照 spec §2.1/§2.2；文字 clip 的文字是 u32 长度 + UTF-8；`chunk` 负载就是数据本身（`r.rest()`）。

- [ ] **Step 1: 写失败的测试**

  `all` 里加：`.clip(id: 1, .text("你好😀", truncated: false))`、`.clip(id: 0xFFFF_FFFF, .text("", truncated: true))`、`.clip(id: 2, .image(width: 1280, height: 720, bytes: 348_160))`、`.clip(id: 3, .files([ClipFile(name: "app.log", bytes: 2_411_724), ClipFile(name: "空 文件", bytes: 0)]))`、`.clip(id: 4, .data(uti: "com.adobe.pdf", bytes: 81_920))`、`.clip(id: 5, .unsupported("文件夹（不支持）"))`、`.paste(seq: 1, .text("贴😀"))`、`.paste(seq: 2, .item(7))`、`.pasted(seq: 2, error: "")`、`.pasted(seq: 3, error: "target not frontmost")`、`.fetch(token: "t", clip: 9, file: 99, offset: 1 << 40)`、`.put(token: "t", item: 3, kind: .files, uti: "public.data", name: "app.log", total: 5)`、`.transferStart(0)`、`.chunk([])`、`.chunk([UInt8](repeating: 7, count: chunkSize))`。现有的往返测试会覆盖它们。再加：

  ```swift
  func testHelloOfVersion4IsAMismatch()             // 手工拼 v4 hello → ProtocolVersionMismatch
  func testFetchAndPutCarryTheVersion() {           // 负载首字节 == 5；改成 4 → ProtocolVersionMismatch
      XCTAssertEqual(Message.fetch(token: "t", clip: 1, file: 0, offset: 0).encoded()[5], 5)
  }
  func testBadV5PayloadsAreRejected()               // 每条都 XCTAssertThrowsError(try parse(bytes))：
      // clip 种类 5；clip 文字长度 maxClipText + 1；files 个数 101；truncated 标志 2；
      // put 种类 4（unsupported）；paste 来源 2；paste 文字 60000 字节；chunk 长度 chunkSize + 1；
      // pasted 后面多一个字节
  ```

- [ ] **Step 2: 跑测试确认失败**

  Run: `swift test --filter ProtocolTests 2>&1 | tail -20`
  Expected: 编译失败，`type 'Message' has no member 'clip'`。

- [ ] **Step 3: 实现**

  `protocolVersion = 5`；fetch/put 解码先读 version，不等于 `protocolVersion` 抛 `ProtocolVersionMismatch(client:)`；`knownTypes` 加 19…25；编码处的 precondition 与解码处的检查用同一组常量。

- [ ] **Step 4: 跑测试确认通过**

  Run: `swift test --filter ProtocolTests 2>&1 | tail -5`
  Expected: `Executed N tests, with 0 failures`。

- [ ] **Step 5: 全量检查并提交**

  Run: `./scripts/check.sh | tail -1` → `EXIT=0`
  ```bash
  git add Sources/RappCore/Clipboard.swift Sources/RappCore/Protocol.swift Sources/rapp-host/Server.swift Sources/rapp-client/main.swift Tests/RappCoreTests/ProtocolTests.swift
  git commit -m "feat(core): protocol v5 clipboard and transfer messages"
  ```

---

### Task 2: RappCore 纯函数

**Files:**
- Modify: `Sources/RappCore/Clipboard.swift`
- Test: Create `Tests/RappCoreTests/ClipboardTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `ClipInfo`、常量。
- Produces:
  ```swift
  public enum ClipSource: Equatable { case files, image, text, data(uti: String), none }
  public func clipKind(types: [String]) -> ClipSource
  public func clipText(_ s: String) -> (text: String, truncated: Bool)
  public enum PasteDecision: Equatable { case files, image, inlineText(String), textChunk(String), data(uti: String), nothing }
  public func pasteDecision(types: [String], text: String?) -> PasteDecision
  public enum ComposerPiece: Equatable { case text(String), chunk(Int) }      // chunk 在文本里占 1 个 UTF-16 单位（附件字符）
  public struct ComposerItem: Equatable {
      public enum Content: Equatable { case text(String), chunk(Int) }
      public var content: Content
      public var end: Int                                                       // 这一项在编辑器文本里结束处的 UTF-16 偏移
  }
  public func composerItems(_ pieces: [ComposerPiece]) -> [ComposerItem]
  public func needsUpload(_ text: String) -> Bool                               // utf8.count >= inlinePasteLimit
  public func lineCount(_ text: String) -> Int                                   // "\n" 个数 + 1；"" → 1
  public func safeFileName(_ raw: String) -> String
  public func uniqueName(_ name: String, existing: Set<String>) -> String
  public func resumeOffset(partSize: UInt64, total: UInt64) -> UInt64
  public func formatSize(_ bytes: UInt64) -> String
  public func historyTitle(_ info: ClipInfo) -> String
  public enum Chip: Equatable {
      case text(n: Int, lines: Int), image(n: Int, width: Int, height: Int)
      case data(n: Int, uti: String, bytes: UInt64), file(name: String, bytes: UInt64)
  }
  public func chipLabel(_ chip: Chip) -> String
  public struct PasteSession {
      public static let restoreDelay: TimeInterval = 2
      public init()
      public mutating func pasteStarted(now: TimeInterval) -> Bool   // true：先存剪贴板（不在一次发送中）
      public mutating func pasteFinished(now: TimeInterval)
      public func restoreDue(now: TimeInterval) -> Bool               // 有存着的、且最后一条贴完已过 2 秒
      public mutating func restored()
  }
  public let retryDelays: [TimeInterval] = [1, 2, 4]
  ```
  类型名常量：`public.file-url`、`public.png`、`public.tiff`、`public.utf8-plain-text`。

- [ ] **Step 1: 写失败的测试**（`ClipboardTests.swift`）

  ```swift
  func testClipKindOrder() {
      XCTAssertEqual(clipKind(types: ["public.utf8-plain-text", "public.file-url"]), .files)
      XCTAssertEqual(clipKind(types: ["public.utf8-plain-text", "public.tiff"]), .image)
      XCTAssertEqual(clipKind(types: ["public.rtf", "public.utf8-plain-text"]), .text)
      XCTAssertEqual(clipKind(types: ["com.adobe.pdf", "com.apple.flat-rtfd"]), .data(uti: "com.adobe.pdf"))
      XCTAssertEqual(clipKind(types: []), .none)
  }
  func testClipTextCutsOnCharacterBoundary() {
      let s = String(repeating: "a", count: maxClipText - 2) + "😀😀"     // 第一个 emoji 跨过 1 MB
      let (t, cut) = clipText(s)
      XCTAssertTrue(cut); XCTAssertEqual(t.utf8.count, maxClipText - 2)
      XCTAssertEqual(clipText("短").text, "短"); XCTAssertFalse(clipText("短").truncated)
  }
  func testPasteDecisionThresholds() {
      let t = "public.utf8-plain-text"
      XCTAssertEqual(pasteDecision(types: [t], text: String(repeating: "字", count: 799)), .inlineText(String(repeating: "字", count: 799)))
      XCTAssertEqual(pasteDecision(types: [t], text: String(repeating: "字", count: 800)), .textChunk(String(repeating: "字", count: 800)))
      let nine = Array(repeating: "x", count: 9).joined(separator: "\n"), ten = nine + "\nx"
      XCTAssertEqual(pasteDecision(types: [t], text: nine), .inlineText(nine))
      XCTAssertEqual(pasteDecision(types: [t], text: ten), .textChunk(ten))
      XCTAssertEqual(pasteDecision(types: ["public.file-url", t], text: "x"), .files)
      XCTAssertEqual(pasteDecision(types: ["public.png", t], text: "x"), .image)
      XCTAssertEqual(pasteDecision(types: ["com.adobe.pdf"], text: nil), .data(uti: "com.adobe.pdf"))
      XCTAssertEqual(pasteDecision(types: [], text: nil), .nothing)
  }
  func testComposerItemsSplitsTrimsAndDropsEmpty() {
      // " 看下\n" [#0] "  " [#1] "和日志 "  → text("看下") end 4、chunk(0) end 5、chunk(1) end 8、text("和日志") end 12
      XCTAssertEqual(composerItems([.text(" 看下\n"), .chunk(0), .text("  "), .chunk(1), .text("和日志 ")]), [
          ComposerItem(content: .text("看下"), end: 4), ComposerItem(content: .chunk(0), end: 5),
          ComposerItem(content: .chunk(1), end: 8), ComposerItem(content: .text("和日志"), end: 12),
      ])
      XCTAssertEqual(composerItems([.text("a"), .text("b")]), [ComposerItem(content: .text("ab"), end: 2)])
      XCTAssertEqual(composerItems([.text(" \n ")]), [])
  }
  func testNeedsUploadCountsBytes() {
      XCTAssertFalse(needsUpload(String(repeating: "字", count: 19_999)))   // 59997 字节
      XCTAssertTrue(needsUpload(String(repeating: "字", count: 20_000)))    // 60000 字节
  }
  func testSafeFileNameKeepsOnlyTheLastComponent() {
      XCTAssertEqual(safeFileName("../../.ssh/authorized_keys"), "authorized_keys")
      XCTAssertEqual(safeFileName(".hidden"), "hidden")
      XCTAssertEqual(safeFileName("a:b.txt"), "ab.txt")
      XCTAssertEqual(safeFileName(""), "file"); XCTAssertEqual(safeFileName("..."), "file"); XCTAssertEqual(safeFileName("dir/"), "dir")
  }
  func testUniqueNameNumbersBeforeTheExtension() {
      XCTAssertEqual(uniqueName("app.log", existing: []), "app.log")
      XCTAssertEqual(uniqueName("app.log", existing: ["app.log", "app (2).log"]), "app (3).log")
      XCTAssertEqual(uniqueName("README", existing: ["README"]), "README (2)")
  }
  func testResumeOffsetRestartsWhenPartIsLarger() {
      XCTAssertEqual(resumeOffset(partSize: 10, total: 100), 10)
      XCTAssertEqual(resumeOffset(partSize: 100, total: 100), 100)
      XCTAssertEqual(resumeOffset(partSize: 101, total: 100), 0)
  }
  func testFormatSize() {
      XCTAssertEqual(formatSize(500), "500 B"); XCTAssertEqual(formatSize(81_920), "80 KB")
      XCTAssertEqual(formatSize(348_160), "340 KB"); XCTAssertEqual(formatSize(2_411_724), "2.3 MB")
      XCTAssertEqual(formatSize(12_582_912), "12 MB")
  }
  func testHistoryTitles() {
      XCTAssertEqual(historyTitle(.text("帮我看下这个报错\n第二行", truncated: false)), "文字 · 帮我看下这个报错 第二行")
      XCTAssertEqual(historyTitle(.text(String(repeating: "长", count: 31), truncated: false)), "文字 · " + String(repeating: "长", count: 30) + "…")
      XCTAssertEqual(historyTitle(.image(width: 1280, height: 720, bytes: 348_160)), "图片 1280×720 · 340 KB")
      XCTAssertEqual(historyTitle(.files([ClipFile(name: "app.log", bytes: 2_411_724)])), "文件 app.log · 2.3 MB")
      XCTAssertEqual(historyTitle(.files(Array(repeating: ClipFile(name: "a", bytes: 4_194_304), count: 3))), "3 个文件 · 12 MB")
      XCTAssertEqual(historyTitle(.data(uti: "com.adobe.pdf", bytes: 81_920)), "数据 com.adobe.pdf · 80 KB")
      XCTAssertEqual(historyTitle(.unsupported("文件夹（不支持）")), "文件夹（不支持）")
  }
  func testChipLabels() {
      XCTAssertEqual(chipLabel(.text(n: 1, lines: 243)), "[贴入文字 #1 +243 行]")
      XCTAssertEqual(chipLabel(.image(n: 2, width: 1280, height: 720)), "[图片 #2 1280×720]")
      XCTAssertEqual(chipLabel(.data(n: 1, uti: "com.adobe.pdf", bytes: 81_920)), "[数据 #1 com.adobe.pdf 80 KB]")
      XCTAssertEqual(chipLabel(.file(name: "app.log", bytes: 2_411_724)), "[文件 app.log 2.3 MB]")
  }
  func testPasteSessionSavesOnceAndRestoresTwoSecondsAfterTheLast() {
      var p = PasteSession()
      XCTAssertTrue(p.pasteStarted(now: 0)); p.pasteFinished(now: 0.2)
      XCTAssertFalse(p.pasteStarted(now: 1.0)); p.pasteFinished(now: 1.2)
      XCTAssertFalse(p.restoreDue(now: 3.1)); XCTAssertTrue(p.restoreDue(now: 3.25))
      p.restored(); XCTAssertFalse(p.restoreDue(now: 9)); XCTAssertTrue(p.pasteStarted(now: 10))
  }
  ```

- [ ] **Step 2: 跑测试确认失败**

  Run: `swift test --filter ClipboardTests 2>&1 | tail -20`
  Expected: 编译失败，`cannot find 'clipKind' in scope`。

- [ ] **Step 3: 实现**（`Clipboard.swift`）

  `formatSize`：< 1024 → `N B`；< 1 MB → KB 四舍五入取整；< 10 MB（GB 同理）→ 一位小数；≥ 10 → 取整；单位 1024。`historyTitle` 文字：换行/制表换成空格，取前 30 个 Character，更长加 `…`。`pasteDecision` 的数据分支取 `types.first`。

- [ ] **Step 4: 跑测试确认通过**

  Run: `swift test --filter ClipboardTests 2>&1 | tail -5`
  Expected: `0 failures`。

- [ ] **Step 5: 提交**

  ```bash
  git add Sources/RappCore/Clipboard.swift Tests/RappCoreTests/ClipboardTests.swift
  git commit -m "feat(core): clipboard kinds, composer split, names, resume and titles"
  ```

---

### Task 3: RappCore ClipStore 与 TransferStore（A 端存取、断点续传）

**Files:**
- Create: `Sources/RappCore/Transfers.swift`
- Test: Create `Tests/RappCoreTests/TransferTests.swift`

**Interfaces:**
- Consumes: Task 1 常量与 `ClipInfo`/`ClipKind`；Task 2 `safeFileName`、`uniqueName`。
- Produces:
  ```swift
  public struct FileRef: Equatable { public var url: URL; public var size: UInt64; public var modified: Date }
  public enum ClipPayload: Equatable { case inline, bytes([UInt8]), files([FileRef]) }
  public struct StoredClip: Equatable { public let id: UInt32; public let info: ClipInfo; public let payload: ClipPayload }
  public final class ClipStore {
      public static let capacity = 50
      public init(changeCount: Int)
      public func changed(changeCount: Int, targetFrontmost: Bool) -> Bool  // true：这次变化要记
      public func noteOwnWrite(changeCount: Int)
      @discardableResult public func add(_ info: ClipInfo, payload: ClipPayload) -> StoredClip
      public func clip(_ id: UInt32) -> StoredClip?
  }
  public struct TransferError: Error, Equatable { public let reason: String }
  public final class TransferStore {
      public init(clips: ClipStore, uploads: URL, memoryLimit: Int = 256 << 20)
      public let clips: ClipStore
      public func fetch(clip: UInt32, file: UInt16, offset: UInt64) throws -> FetchSource
      public func put(item: UInt32, kind: ClipKind, uti: String, name: String, total: UInt64) throws -> PutSink
      public func received(_ item: UInt32) -> ReceivedItem?               // 没收齐是 nil
  }
  public final class FetchSource { public let total: UInt64; public func next() throws -> [UInt8]? }  // 每块 ≤ chunkSize，完了 nil
  public final class PutSink { public private(set) var have: UInt64; public let total: UInt64; public func write(_ bytes: [UInt8]) throws -> Bool }  // true：收齐（文件已改名）
  public enum ReceivedItem: Equatable { case text(String), image([UInt8]), data(uti: String, [UInt8]), file(URL) }
  public final class SideSlots { public init(limit: Int = maxSideConnections); public func take() -> Bool; public func release() }
  ```
  规则：put 的 sink 已收齐（have == total）时再 put 同参数 → 返回这个 sink，`have == total`，调用者直接回空 `chunk`。fetch 只对图片/数据（文件序号必须 0）和文件（序号 < 个数）有效，其余 → `unknown clip`；文件 fetch 时重读大小和修改时间，不一致 → `file changed`；offset > total → `unknown clip`。put：同一条目号且种类/名字/总长相同 → 续用原来的 sink（`have` 保留），否则重新开始；种类 0/1/3 进内存，`total > memoryLimit` → `too large`；种类 2 写 `uploads/<uniqueName(safeFileName(name))>.rapp-part`，收齐后改名为 `uploads` 里不重名的最终名；写盘 ENOSPC → `disk full`，其它写错 → `write failed`；`write` 超出 total → `too large`。`uploads` 目录不存在就建。全部只在调用者的一个队列上用，不加锁。

- [ ] **Step 1: 写失败的测试**（`TransferTests.swift`，临时目录 `FileManager.default.temporaryDirectory/UUID`，tearDown 删掉）

  ```swift
  func testChangeWhileOtherAppFrontmostIsNotRecorded() {
      let s = ClipStore(changeCount: 10)
      XCTAssertFalse(s.changed(changeCount: 11, targetFrontmost: false))
      XCTAssertFalse(s.changed(changeCount: 11, targetFrontmost: true))   // 那次变化已经看过
      XCTAssertTrue(s.changed(changeCount: 12, targetFrontmost: true))
  }
  func testOwnWritesAreNotRecorded() {
      let s = ClipStore(changeCount: 1); s.noteOwnWrite(changeCount: 2)
      XCTAssertFalse(s.changed(changeCount: 2, targetFrontmost: true))
      XCTAssertTrue(s.changed(changeCount: 3, targetFrontmost: true))
  }
  func testStoreKeepsFiftyNumberedFromOne() {
      let s = ClipStore(changeCount: 0)
      for i in 0..<51 { s.add(.text("\(i)", truncated: false), payload: .inline) }
      XCTAssertNil(s.clip(1)); XCTAssertEqual(s.clip(2)?.info, .text("1", truncated: false)); XCTAssertEqual(s.clip(51)?.id, 51)
  }
  func testFetchResumesFromOffset()        // 600 KB 随机字节的文件 clip：fetch(0) 读 1 块后丢掉，fetch(块长) 读完；拼起来 == 原文件；total == 600 KB；每块 ≤ chunkSize
  func testFetchOfImageFromMemory()        // .bytes payload，file 0 → 内容一致；file 1 → TransferError("unknown clip")
  func testFetchOfUnknownClipFails()       // 编号 99 → "unknown clip"；文字 clip → "unknown clip"
  func testFetchOfChangedFileFails()       // add 之后往文件追加 1 字节 → "file changed"
  func testPutResumesWithHave() {          // 文件条目 300 KB：写 100 KB 后丢掉 sink；再 put 同参数 → have == 100 KB；写剩下的 → true
      // received(item) == .file(uploads/"app.log")，内容一致；uploads 里没有 .rapp-part
  }
  func testPutOfCompleteItemReportsHaveEqualsTotal()  // 收齐后再 put 同参数 → have == total，received 仍是那一项
  func testPutWithDifferentTotalStartsOver()  // 同条目号、total 不同 → have == 0
  func testPutNamesAreSafeAndUnique()      // uploads 里已有 "app.log"；put name "../app.log" 收齐 → "app (2).log"
  func testPutTextInMemoryAndLimit()       // memoryLimit 10：kind .text total 11 → "too large"；total 6 写 "你好" → .text("你好")
  func testReceivedIsNilUntilComplete()
  func testSideSlotsLimitFour() {          // take ×4 true，第 5 次 false；release 一次后 true
  }
  ```

- [ ] **Step 2: 跑测试确认失败**

  Run: `swift test --filter TransferTests 2>&1 | tail -20`
  Expected: 编译失败，`cannot find 'ClipStore' in scope`。

- [ ] **Step 3: 实现** `Sources/RappCore/Transfers.swift`（FileHandle 读写；`FetchSource` 打开时 seek 到 offset）。

- [ ] **Step 4: 跑测试确认通过**

  Run: `swift test --filter TransferTests 2>&1 | tail -5`
  Expected: `0 failures`。

- [ ] **Step 5: 全量检查并提交**

  Run: `./scripts/check.sh | tail -1` → `EXIT=0`
  ```bash
  git add Sources/RappCore/Transfers.swift Tests/RappCoreTests/TransferTests.swift
  git commit -m "feat(core): clip store and resumable transfer store"
  ```

---

### Task 4: rapp-host 分流、旁路连接、剪贴板监视（A→B）

**Files:**
- Modify: `Sources/rapp-host/Server.swift`（`accept` 先读第一条消息再分流；`Session` 持有 `TransferStore`；会话结束清掉）
- Create: `Sources/rapp-host/SideConnection.swift`（fetch/put 的连接胶水）
- Create: `Sources/rapp-host/ClipboardWatcher.swift`

**Interfaces:**
- Consumes: Task 1 消息；Task 2 `clipKind`、`clipText`；Task 3 `ClipStore`、`TransferStore`、`SideSlots`、`FileRef`。
- Produces（给 Task 5）: `Session` 上的 `transfers: TransferStore?`（会话开始抓屏时建，`uploads` = `~/Downloads/rapp`），`clipWatcher: ClipboardWatcher?`；`ClipboardWatcher.noteOwnWrite(changeCount:)`。

分流（spec §1.2、§2.4）：新连接先读到第一条完整消息（5 秒没有 → 关掉；现在的 "no hello received" 照旧记日志）。`hello` → 现在的 `Session` 流程（已有会话 → `error("busy")`），把已读到的剩余字节一起交给它。`fetch`/`put` → 先 `SideSlots.take()`，满了 `error("busy")`；token 用 `constantTimeEquals` 比会话的 token，不对 `error("bad token")`；没有进行中的会话 → `error("no session")`；然后：
- fetch：`transferStart(total)`，`next()` 一块块发；每块在上一块 `.contentProcessed` 后再发（背压）；发完关连接。
- put：`transferStart(have)`；`have == total` 时立即回空 `chunk` 再关；否则每个 `chunk` → `write`，收齐回空 `chunk` 再关。
- 任何 `TransferError` → `error(reason)` 后关；连接关闭时 `release()`。旁路连接不发 `.sessionStarted`/`.rejected` 事件，只写一行日志（`side fetch clip 3 file 0 from 1048576` / `side put item 2 have 0`）。

剪贴板监视（spec §3.1）：会话 ready 后在**主队列**上每 0.3 秒读 `NSPasteboard.general.changeCount`；前台判断用 `NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier`；`changed` 为 true 时按 `clipKind(types:)` 取内容：
- 文件：`readObjects(forClasses: [NSURL.self])` 的文件 URL；有文件夹 → `.unsupported("文件夹（不支持）")`；超过 100 个 → `.unsupported("文件太多（不支持）")`。
- 图片：PNG 原样，TIFF 经 `NSBitmapImageRep` 转 PNG；宽高取像素数，截到 u16。
- 文字：`clipText`。
- 数据：首个类型的 data，≥ 64 MB 不记。

结果回到会话队列 `add` 并发 `.clip(id, info)`。会话结束停 timer。

- [ ] **Step 1: 实现上面三块**（纯逻辑已在 Task 2/3 测过，这里只有胶水）。

- [ ] **Step 2: 编译**

  Run: `swift build 2>&1 | tail -5`
  Expected: `Build complete!`，无新警告。

- [ ] **Step 3: 写回环测试脚本 `scripts/side-loopback.py`（spec §7 的 host 测试，不碰剪贴板）**

  用法 `scripts/side-loopback.py <rapp-host 路径>`：起 `rapp-host serve --app com.apple.calculator --bind 127.0.0.1 --port 0 --token-env T --json`（T=runtest123；Calculator 照 `e2e-local.py` 的做法由脚本自己启动、记 PID，结束只按 PID 关），按 Protocol.swift 的线格式发 v5 hello，等到 `ready` 后在旁路上依次检查，每项打印 `ok <名字>`，全部通过打印 `PASS`：
  1. `fetch(clip 99)` → `error("unknown clip")`。
  2. `put(item 1, kind data, uti "public.data", name "", total 600 KB)` 发 300 KB 后关；再 put 同参数 → `transferStart(300 KB)`；发剩下的 → 空 `chunk`。
  3. 同参数第三次 put → `transferStart(600 KB)` + 空 `chunk`。
  4. 开 4 条 put（item 2…5，total 1 MB，不发数据、不关），第 5 条 put → `error("busy")`；关掉一条后再开 → `transferStart(0)`。
  5. 错 token 的 fetch → `error("bad token")`；会话关掉后 fetch → `error("no session")`。
  6. v4 hello → `protocol version mismatch`。
  （fetch 续传读字节的正确性由 Task 3 `testFetchResumesFromOffset` 覆盖，需要真剪贴板才有 clip，留到 Task 10。）

  Run: `python3 scripts/side-loopback.py .build/debug/rapp-host`
  Expected: 末行 `PASS`。

- [ ] **Step 4: 全量检查并提交**

  Run: `./scripts/check.sh | tail -1` → `EXIT=0`
  ```bash
  git add Sources/rapp-host/Server.swift Sources/rapp-host/SideConnection.swift Sources/rapp-host/ClipboardWatcher.swift scripts/side-loopback.py
  git commit -m "feat(host): side connections for fetch/put and per-session clipboard history"
  ```

---

### Task 5: rapp-host 粘贴（B→A）

**Files:**
- Create: `Sources/rapp-host/Paster.swift`（存/写/恢复剪贴板、⌘V）
- Modify: `Sources/rapp-host/Server.swift`（`.paste` 从 unexpected 里拿出来交给 `Paster`；会话结束时恢复）

**Interfaces:**
- Consumes: Task 2 `PasteSession`；Task 3 `TransferStore.received`、`ReceivedItem`；Task 4 `ClipboardWatcher.noteOwnWrite`、`Session.transfers`。
- Produces: 无（终端功能）。

流程照 spec §3.3：`.paste(seq, source)` → 取内容（`.item` 没收齐 → `pasted(seq, "not uploaded")`）→ `pasteStarted` 为 true 时存快照（所有 item 的所有类型的 data；累计 > 64 MB 不存，日志 `clipboard too large to save; it will not be restored`）→ 主队列写剪贴板（文字 `.string`；图片 `public.png`；数据它的 UTI；文件 `NSURL` 对象），`noteOwnWrite(changeCount:)` → 激活目标 app，最多等 0.5 秒（每 50 ms 查一次）前台 pid == 目标 pid，否则 `pasted(seq, "target not frontmost")` → 发 ⌘V（keyCode 9，flags `.maskCommand`，按下、抬起）→ `asyncAfter(0.15)` 后 `pasteFinished`、回 `pasted(seq, "")`，并在 2 秒后查 `restoreDue`，到了就写回快照、`noteOwnWrite`、`restored()`。会话结束：有快照就立即恢复。不要在会话队列上 `usleep`。

- [ ] **Step 1: 实现 `Paster`**，接进 `Session.handle`。

- [ ] **Step 2: 编译**

  Run: `swift build 2>&1 | tail -5`
  Expected: `Build complete!`。

- [ ] **Step 3: 全量检查并提交**（实机验证在 Task 10）

  Run: `./scripts/check.sh | tail -1` → `EXIT=0`
  ```bash
  git add Sources/rapp-host/Paster.swift Sources/rapp-host/Server.swift
  git commit -m "feat(host): paste items into the target app and restore the clipboard"
  ```

---

### Task 6: hub 会话期间继续接受旁路连接

**Files:**
- Modify: `rust/hub/src/session.rs`
- Modify: `rust/testkit/src/bin/fake-rapp-client.rs`
- Test: `rust/testkit/tests/hub.rs`

**Interfaces:**
- Consumes: 现有 `Hub::request(&host, &Op::Open{app})`、`splice`。
- Produces: 无。

`open` 接到第一个连接后不丢 `listener`，交给 `run`；`run` 里起一个任务循环 `accept`，每个新连接 `set_nodelay`，各自 `request(&host, &Op::Open { app })` 拿流再 `splice`（任务放进 `JoinSet`）；`request` 失败只 `eprintln!` 一行，不影响会话。会话结束（client 退出）时先 abort 循环和 `JoinSet`，再 drop listener。

假 client：主连接 ping/echo 成功后、打印 `ready` 前，再连一次同一地址，发 token 行、等 `ok`、发 `side\n` 等回显，失败 `exit(1, "side failed")`；把端口写到 argv[0] 同目录的 `client.port`。

- [ ] **Step 1: 改假 client，写失败的测试**

  ```rust
  #[tokio::test]
  async fn side_connection_gets_its_own_open_and_listener_closes_with_session() {
      // 同 add_host_hosts_apps_open_close_remove 的准备；open_and_close(&mut hub, &a.id, "lan").await
      //（closed 的 reason 是 "echo ok" 说明旁路连接也通了）
      // 然后读 a.bins.path().join("client.port")，断言 TcpStream::connect(("127.0.0.1", port)) 失败
  }
  ```

- [ ] **Step 2: 跑测试确认失败**

  Run: `cd rust && ~/.cargo/bin/cargo test -p rapp-testkit --test hub side_connection 2>&1 | tail -15`
  Expected: FAIL，`closed` 的 reason 是 `"rapp-client exited before connecting"` 或 `"side failed"`（旁路连接没人接）。

- [ ] **Step 3: 实现 `session.rs` 的改动。**

- [ ] **Step 4: 跑 Rust 全量**

  Run: `cd rust && ~/.cargo/bin/cargo test 2>&1 | grep -E "test result|FAILED" ; ~/.cargo/bin/cargo clippy --all-targets -- -D warnings 2>&1 | tail -3`
  Expected: 所有 `test result: ok`（包括走 relay 的 `forced_relay_path_end_to_end`，它现在也经过旁路连接），clippy 无警告。

- [ ] **Step 5: 提交**

  ```bash
  git add rust/hub/src/session.rs rust/testkit/src/bin/fake-rapp-client.rs rust/testkit/tests/hub.rs
  git commit -m "feat(hub): forward side connections through their own open"
  ```

---

### Task 7: rapp-client 旁路传输与「A 的剪贴板」历史

**Files:**
- Create: `Sources/rapp-client/SideConnection.swift`（一次 fetch 或 put 的 NWConnection）
- Create: `Sources/rapp-client/Transfers.swift`（`TransferQueue`：串行、重试、取消、进度）
- Create: `Sources/rapp-client/ClipHistory.swift`（历史、菜单、点选）
- Create: `Sources/rapp-client/LocalPasteboard.swift`（B 剪贴板的读写）
- Modify: `Sources/rapp-client/main.swift`（`.clip` 进历史；应用菜单加子菜单）、`Sources/rapp-client/TrafficLabel.swift` 或 `StreamMenu.swift`（流量标签菜单加同一个子菜单）

**Interfaces:**
- Consumes: Task 1 消息；Task 2 `safeFileName`、`uniqueName`、`resumeOffset`、`historyTitle`、`formatSize`、`retryDelays`。
- Produces（给 Task 8/9）:
  ```swift
  final class TransferQueue {           // 每个 client 进程一个，主队列
      init(address: RemoteAddress)      // 旁路连接连同一个 host:port，token 用 address.token
      var onStatus: ((String?) -> Void)?          // "下载 app.log 45%" / "上传 2/3 · app.log 45%" / 错误文字；nil = 空闲
      func download(clip: UInt32, file: UInt16, name: String, total: UInt64, toDisk: Bool,
                    done: @escaping (Result<DownloadResult, TransferFailure>) -> Void)
      func upload(item: UInt32, kind: ClipKind, uti: String, name: String, data: UploadData, label: String,
                  done: @escaping (Result<Void, TransferFailure>) -> Void)
      func cancel()                     // 停当前这件、清空排队；已收/已发的留着
  }
  enum DownloadResult { case bytes([UInt8]), file(URL) }
  enum UploadData { case bytes([UInt8]), file(URL) }
  struct TransferFailure: Error { let reason: String }   // A 的 error 原文，或 "连接断开"、"已取消"
  final class ClipHistory {             // 每个 client 进程一个
      static let limit = 20
      init(pasteboard: LocalPasteboard, transfers: TransferQueue, log: @escaping (String) -> Void)
      var onInsert: ((ClipInfo, InsertPayload) -> Void)?    // ⌥ 点：交给 Task 8 的编辑器
      var onClip: (() -> Void)?                             // 「复制」按钮用
      func add(id: UInt32, _ info: ClipInfo)
      func makeMenuItem() -> NSMenuItem                     // "A 的剪贴板" 子菜单，菜单打开时按最新的重建
  }
  enum InsertPayload { case text(String), bytes([UInt8]), files([URL]) }
  final class LocalPasteboard {
      func write(text: String); func write(png: [UInt8]); func write(uti: String, data: [UInt8]); func write(files: [URL])
      var types: [String] { get }; var string: String? { get }
      func fileURLs() -> [URL]; func imagePNG() -> (png: [UInt8], width: Int, height: Int)?; func data(uti: String) -> [UInt8]?
  }
  ```
  下载到磁盘：目录 `~/Downloads/rapp/`（没有就建）；每个 (clip, 文件序号) 在本会话里第一次下载时定名 `uniqueName(safeFileName(name), existing: 目录里的名字（.rapp-part 去掉后缀也算）)`，记住，之后续传用同一个 `.rapp-part`；offset = `resumeOffset(partSize:total:)`（为 0 时截断 part 文件）；`transferStart` 的 total 和期望不一致 → 截断从 0 重来；收齐后改名（改名时再 `uniqueName` 一次），日志 `downloaded <路径>`。重试：连接断开（不是 A 的 `error`）时按 `retryDelays` 等待后从当前进度续，三次都不行 → 失败 "连接断开"；A 的 `error` 不重试。上传：`transferStart(have)` 后从 have 发，`chunkSize` 一块，等 `.contentProcessed` 再发下一块，收到空 `chunk` 算完成。

  历史点选（spec §4.5）：文字 → `write(text:)`；图片/数据 → `download(toDisk: false)` 后写剪贴板；文件 → 逐个 `download(toDisk: true)`，都完了 `write(files:)`；不支持 → 灰的、不可点。⌥ 点 → 同样先下载，然后 `onInsert`。`add` 时文字自动 `write(text:)`；超过 20 条丢最旧的。

- [ ] **Step 1: 实现上面四个文件并接线**；`onStatus` 先只写日志（Task 8 接到传输条）。

- [ ] **Step 2: 编译**

  Run: `swift build 2>&1 | tail -5`
  Expected: `Build complete!`。

- [ ] **Step 3: 全量检查并提交**

  Run: `./scripts/check.sh | tail -1` → `EXIT=0`
  ```bash
  git add Sources/rapp-client
  git commit -m "feat(client): side-connection transfers and per-connection clipboard history"
  ```

---

### Task 8: rapp-client 编辑器（取代 InputBar）

**Files:**
- Create: `Sources/rapp-client/Composer.swift`（`NSTextView` 子类、块附件）
- Create: `Sources/rapp-client/ComposerBar.swift`（传输条 + 滚动的编辑器 + 按钮行）
- Delete: `Sources/rapp-client/InputBar.swift`
- Modify: `Sources/rapp-client/RemoteWindow.swift`（`inputBar` → `composerBar`；条的高度可变）、`Sources/rapp-client/WindowCoordinator.swift`（`keyInputBar` → `keyComposer`、`onSend` 接线、状态广播、「复制」反馈）、`Sources/rapp-client/main.swift`（⌘ 快捷键规则）

**Interfaces:**
- Consumes: Task 2 `pasteDecision`、`chipLabel`、`lineCount`、`ComposerPiece`；Task 7 `LocalPasteboard`、`TransferQueue.onStatus`、`ClipHistory.onClip`/`onInsert`、`InsertPayload`。
- Produces（给 Task 9）:
  ```swift
  enum ChipPayload { case text(String), image(png: [UInt8], width: Int, height: Int), data(uti: String, [UInt8]), file(URL, bytes: UInt64) }
  final class Composer: NSTextView {
      var onSend: ((Message) -> Void)?         // 空编辑器直通的按键，同 InputBar
      var onSubmit: (() -> Void)?              // 回车（非空、不在组字）
      var isEmpty: Bool { get }                // 无文字、无块、无组字
      func pieces() -> [ComposerPiece]         // 按顺序；块用它的 chip id
      func payload(_ chip: Int) -> ChipPayload?
      func uploadedItem(_ chip: Int) -> UInt32?; func setUploadedItem(_ chip: Int, _ item: UInt32)
      func removeUpTo(_ end: Int)              // 删掉 [0, end)
      func insert(_ payload: InsertPayload, info: ClipInfo)   // ⌥ 点历史
      func insertFiles(_ urls: [URL])          // 📎、拖入
  }
  final class ComposerBar: NSView {
      let composer: Composer
      var onHeightChange: ((CGFloat) -> Void)?
      var onAttach, onCopy, onSendButton, onCancel: (() -> Void)?
      func setStatus(_ text: String?)          // nil 隐藏传输条
      func setSending(_ busy: Bool)            // 发送按钮变灰
      func showCopyFeedback(_ text: String?)   // "已复制" / "A 上没有复制到东西" / nil 复原
  }
  ```
  - 字体 `NSFont.systemFont(ofSize: 14)`，占位文字照 `InputBar` 的 `"Type here, press Return to send  ·  在此输入，回车发送"`。
  - 块：`NSTextAttachment` 子类带 chip id，cell 画圆角标签，文字是 `chipLabel`；编号（贴入文字、图片、数据各自）在一个窗口里递增。
  - ⌘V（`paste(_:)` 覆写）按 `pasteDecision`：files → 每个文件一个块，文件夹跳过并 `setStatus("不支持文件夹：名字")`；image → 图片块；inlineText → 插文字；textChunk → 贴入文字块；data → 数据块（> 256 MB → `setStatus("太大了，A 最多收 256 MB")` 不插）；nothing → 什么都不做。
  - 拖入：注册 `.fileURL`，放下 → `insertFiles`。📎 → `NSOpenPanel`（可多选，只选文件）。
  - 高度：1…8 行随内容变，多了滚动；变化时 `onHeightChange`，`RemoteWindow` 保持远端画面大小、顶边不动、窗口高度跟着变。
  - 按键：回车发送、⇧回车换行、组字中交给输入法、空时直通键照 `InputBar.passThrough`，Esc 非空时清空。
  - 「复制」：`onSend` 发 ⌘C（keyCode 8，modifiers = `NSEvent.ModifierFlags.command.rawValue`）按下、抬起；`showCopyFeedback("已复制")`；2 秒内 `ClipHistory.onClip` 没来 → `"A 上没有复制到东西"`；再 2 秒复原。
  - main.swift 的 ⌘ 监听：⌘V 在编辑器是第一响应者时**总是**进编辑器（即使为空）；其它 ⌘ 键照旧（空 → 发给 A）。
  - 传输状态：`TransferQueue.onStatus` → coordinator 广播到所有窗口的 `setStatus`；「取消」→ `TransferQueue.cancel()`。

- [ ] **Step 1: 实现**（回车先只调 `onSubmit`，Task 9 接发送）。

- [ ] **Step 2: 编译**

  Run: `swift build 2>&1 | tail -5`
  Expected: `Build complete!`；`grep -rn InputBar Sources` 无结果。

- [ ] **Step 3: 本机快速看一眼（只看自己的 client 窗口）**

  用 Calculator 起 `rapp-host serve` + `rapp-client`（都记 PID）；B 窗口里点进编辑器，本机剪贴板先存好（Task 10 的 `clipsnap`），放一段 1000 字文字 → ⌘V 出现 `[贴入文字 #1 +N 行]`；输入多行到 9 行开始滚动；空时方向键仍发给 A。截图只截 client 窗口。测完恢复剪贴板、按 PID 关掉两个进程。
  Expected: 如上所述。

- [ ] **Step 4: 全量检查并提交**

  Run: `./scripts/check.sh | tail -1` → `EXIT=0`
  ```bash
  git add -A Sources/rapp-client
  git commit -m "feat(client): multi-line composer with chips, attachments and copy button"
  ```

---

### Task 9: rapp-client 发送顺序

**Files:**
- Create: `Sources/rapp-client/Sender.swift`
- Modify: `Sources/rapp-client/WindowCoordinator.swift`（每个 `RemoteWindow` 一个 `Sender`；`pasted(seq:error:)` 转给发出这条的 Sender）、`Sources/rapp-client/main.swift`（`.pasted` → coordinator）

**Interfaces:**
- Consumes: Task 2 `composerItems`、`needsUpload`、`ComposerItem`；Task 7 `TransferQueue.upload`、`ClipHistory.onInsert`；Task 8 `Composer`、`ComposerBar`。
- Produces: 无（终端功能）。

流程照 spec §4.2：`composerItems(composer.pieces())` → 依次处理：需要上传的（块，或 `needsUpload` 的文字）：块若还没有 `uploadedItem` 就分配一个条目号（client 级 u32 计数，从 1 起）并**先** `setUploadedItem` 再 `upload`，这样失败后再发送会用同一个条目号续传（A 回 `have`，收齐的回空 `chunk`）；直接打出来的超长文字没有块可挂条目号，失败后重发从 0 开始（贴进来的长文字都是块，这种情况只出现在手打 ≥ 60000 字节时），状态 `上传 i/n · 名字 百分比`（i/n 只数要上传的）；然后一个个发 `.paste(seq, .text / .item)`（seq client 级计数），等对应 `pasted` 再发下一个。put 的参数：长文字 kind `.text`、UTI `public.utf8-plain-text`、名字 `""`；图片 `.image`、`public.png`；数据 `.data`、它的 UTI；文件 `.files`、`UTType(filenameExtension:)?.identifier ?? "public.data"`、文件名。全部成功 → 清空编辑器、`setStatus(nil)`，不按回车。失败（上传失败或 `pasted` 带错误）→ `removeUpTo(最后一个成功条目的 end)`，`setStatus` 显示：`target not frontmost` → "A 上的目标窗口不在最前"，`not uploaded` → "A 还没收齐这一项"，`not supported` → "A 不支持粘贴"，其它原样。发送中 `setSending(true)`，结束复原；发送中编辑不影响这一轮（开始时已拆好条目并取好 payload）。⌥ 点历史 → `ClipHistory.onInsert` → key 窗口的 `composer.insert`。

- [ ] **Step 1: 实现 `Sender` 并接线**（`onSubmit` 与「发送」按钮都调它）。

- [ ] **Step 2: 编译**

  Run: `swift build 2>&1 | tail -5`
  Expected: `Build complete!`。

- [ ] **Step 3: 全量检查并提交**

  Run: `./scripts/check.sh | tail -1` → `EXIT=0`
  ```bash
  git add Sources/rapp-client
  git commit -m "feat(client): send composer items to A one by one"
  ```

---

### Task 10: 文档、打包、实机验收

**Files:**
- Modify: `README.md`（剪贴板与编辑器的用法、协议 v5、v4 端要升级）、`tasks/todo.md`（本功能一节，勾掉做完的）
- Create（scratchpad，不进仓库）: `clipsnap.swift`（`save <file>` / `restore <file>`：本机剪贴板全部 item、全部类型；`file <path>`：把剪贴板设成这一个文件 URL）

- [ ] **Step 1: 改文档并提交**

  ```bash
  git add README.md tasks/todo.md
  git commit -m "docs: clipboard history and composer (protocol v5)"
  ```

- [ ] **Step 2: 全量**

  Run: `./scripts/check.sh | tail -1`；`cd rust && ~/.cargo/bin/cargo test 2>&1 | grep -E "test result|FAILED"`；`~/.cargo/bin/cargo clippy --all-targets -- -D warnings`；`cargo build --release` 后 `scripts/e2e-local.py <scratchpad>/e2e com.apple.calculator`
  Expected: `EXIT=0`；全部 `test result: ok`；clippy 无警告；e2e 三轮都 `closed`。

- [ ] **Step 3: 实机验收（spec §7）**

  先 `pgrep -x TextEdit`：**在运行就停下来问用户**（不能动用户的 TextEdit）。没在运行：`clipsnap save` → 自己 `open -a TextEdit` 新建空白文档、记 PID → 本机直连起 `rapp-host serve` + `rapp-client`（记 PID；hub 路径由 Task 6 的测试覆盖）→ 依次：
  1. B 编辑器贴 1000 行文字（块）+ 一张图（块）+ 一句话，发送 → TextEdit 里依次出现，编辑器清空，A 的剪贴板 2 秒后恢复为发送前的内容。
  2. 在 B 上拖选 TextEdit 里一段字（合成拖动前查顶层窗口是自己的 client 窗口），点「复制」→ B 剪贴板是那段字，历史有 `文字 · …`。
  3. scratchpad 里 `dd` 出 1 GB 随机文件；TextEdit 在最前时 `clipsnap file <它>`（剪贴板在 A 的目标 app 前台时变化，host 记成文件 clip）→ 历史有 `文件 … · 1 GB`；点它下载，传输条出现百分比后点「取消」→ 再点一次，host 日志里 `from <非 0 offset>`，最终 `~/Downloads/rapp/` 里的文件和原文件 `cmp` 一致。
  4. 切到别的 app 复制东西 → 历史不变。
  收尾：TextEdit 不保存关掉（按 PID）、关自己的进程、`clipsnap restore`、删掉 scratchpad 的 1 GB 文件和 `~/Downloads/rapp/` 里本次下载的那个文件（只删自己产生的，按名字核对）。
  Expected: 四项都如上；截图只截 client 窗口。

- [ ] **Step 4: 打包**

  Run: `./scripts/package-macos.sh 2>&1 | tail -3`
  Expected: `dist/rapp-0.2.0.pkg` 与 `rapp.dmg` 重新生成。不替换用户已装的 /Applications/rapp.app（由用户决定何时装）。

- [ ] **Step 5: 推送**

  ```bash
  git push origin main
  ```
