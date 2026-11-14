# rapp 串流：滚动复制与改尺寸保留旧画面 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 画面整体上下挪动时只发"从旧画面哪里复制"加新露出的部分；改窗口尺寸不再发整帧；整帧不再黑底扫过。协议只认 v9。

**Architecture:** 帧消息的 `full` 字节改成标志位（full/start/end/copies），非整帧的首片带"搬画布"偏移，新增复制块（kind 5）。主机编码器在模型（解码器画布的副本）之外再存一份"比较用像素"（双色档存原始 BGRA，其余档就是样本），先搬画布、再同位置比较、再按行指纹投票得到的上下偏移试复制。按原始像素配上的块会让模型和真实量化结果不同，画面静止 300 ms 后补发。三个解码器（Swift、Rust）同一格式，客户端在整帧和"有新露出区域"的帧收完前不更新显示。

**Tech Stack:** Swift 5.9（RappCore / rapp-host / RappSession / rapp-client，XCTest）、Rust（rapp-client-core、rapp-client-gtk，flate2）、zlib、Python 测试脚本。

**Spec:** `docs/superpowers/specs/2026-11-14-rapp-scroll-copy-design.md`（下称"规格"）。执行者两份都读；冲突以规格为准。

## Global Constraints

- 协议版本 9；主机只接受 v9 的 hello，其他版本照现在的 `ProtocolVersionMismatch` 报错（"update both sides"）。兼容旧版本的代码全部删掉，测试里专测旧版本行为的用例一并删掉。
- 不能画错：复制来源不对、错位、残留旧内容不更新都不允许。宁可多发，不能画错。
- 主机的模型和解码器画布任何时候都一致；Swift 和 Rust 两个解码器对同一串帧必须得到完全相同的画布。
- 截图、量化、分片、弱网档、帧确认的现有行为不变，除了规格 §5 写明的改动。分片照旧：按块行从上往下切，32 KB 一片、首片 8 KB。帧确认照旧每片一个。
- 整帧只在这几种时候发：会话第一帧、换档位（新编码器）、密度改变（像素和点的比例变了）。区域尺寸或原点变了不再发整帧。
- 复制只认完全对上（样本相同或原始像素相同），不做近似匹配；只检测上下滚动。
- 静止后修正：起步值 300 ms。
- 耗时：1080p 窗口每帧额外不超过 3 ms。
- GPL-3.0；不加新的第三方依赖；不加任何新的界面开关或档位。
- 面向用户的文字用中文；代码、注释、提交信息可用英文。只在自己的分支 `feat/scroll-copy` 上提交，不推送。

## 本计划替规格定下的事（规格 §8 留给实现者的）

- **字节布局**（写进 `TileCodec.swift` 顶部注释，Swift/Rust/Python 一致，小端）：
  - 帧消息 type 4：`u8 mode; rect region (4×f32); u16 width; u16 height; u8 flags; [仅当 start 且非 full：i32 dx; i32 dy]; data`。
  - `flags`：bit0 `full`、bit1 `start`、bit2 `end`、bit3 `copies`，其余位必须为 0；`full` 必须带 `start`；`copies` 只能出现在带 `start` 的片上。违者按坏帧处理。
  - 复制块 kind 5：块体 `u16 sx; u16 sy`，源矩形 = 目标块大小（边缘块用真实大小），必须满足 `sx + tw <= width && sy + th <= height`（参考画布就是搬完后的新画布）。帧未置 `copies` 却出现 kind 5 → 坏帧。
  - 搬画布：新画布 `width×height`；新 (x, y) = 旧 (x + dx, y + dy)，落在旧画布外的填 0。
- **比较用像素（key）**：双色档（duogray/duocolor）用原始 BGRA（每像素 4 字节，紧密排列）；其余档量化是逐像素的（`Quantize.swift` 只有双色档按 16×16 块），原始像素相同必然样本相同，所以 key 就是样本，不另存原始像素。规格 §5.3 的"再存一份原始像素"只对双色档做。
- **"未覆盖"的表示**：一帧内只有一个"已覆盖矩形" = 新画布 ∩ 旧画布平移后的位置；其外都是未覆盖。主机在这一帧把未覆盖的块全部发出，所以帧结束后不再有未覆盖。
- **静止后修正**：不用标记"近似块"，而是编码器保存最后一帧的输入（样本、key、区域）；修正时把它按"只比样本、不复制、不搬画布"再编一次。触发条件比规格 §5.5 更宽：**最后一个"按原始像素配上"的帧之后 300 ms**、且没有排队的片和待编的帧（不要求整个画面静止，这样别处一直有动画时也能补上）。由 `Server` 每 100 ms 调一次 `PacedSender.settleIfIdle()`。
- **密度改变的判断**：编码器算 `scale = width / region.w`，和上一帧比相对差超过 1% 就发整帧；`Server.setStream` 不用另外通知编码器。
- **偏移**：`dx = round((region.x − 上一帧 region.x) × scale)`，`dy` 同理（区域坐标是左上原点的点，同 `config.sourceRect`）。方向弄反只会少配上，不会画错（所有复制都逐像素验证过）。
- **测试文件**：`rust/client-core/tests/fixtures/scroll-copy.bin`，由 Swift 测试在 `RAPP_WRITE_FIXTURES=1` 时生成，格式见 Task 6。

## Review Focus

1. **只改密度、不换档位**（「省流 1x」、弱网档进出时 mode 已是 duogray 只改密度）：像素尺寸和区域都变，必须发整帧而不是搬画布 → Task 3 `testDensityOnlyChangeSendsFull`。
2. **区域原点挪了半个点、或一下挪得比画布还远**（已覆盖矩形为空）：不能崩、不能画错，后者等于全部重发但仍不是整帧 → Task 3 `testFractionalAndHugeRegionMoves`。
3. **一帧还没收完就来了新的整帧**（换档位时 `PacedSender.setMode` 丢掉排队的片）：解码器必须接受，显示继续停在上一张完整画面直到新帧 `end` → Task 2 `testFullFrameMayInterruptOpenFrame`。
4. **大片空白或重复的内容**（空终端、满屏相同的行）：全同色行不投票，候选偏移可能指向错的一行，但验证后结果仍正确 → Task 4 `testRepetitiveAndBlankContentStaysCorrect`。
5. **滚完停下但别处还在动**（Agent 输出旁的转圈）：修正仍要在 300 ms 后发出，画布和整帧重编逐像素一致 → Task 5 `testSettleRunsWhileOtherTilesKeepChanging`。

---

### Task 1: 只认 v9，删掉兼容旧版本的代码

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`（1–30 行的版本常量和注释、`Reader.version()` 约 451 行、hello 解析约 247 行）
- Modify: `Sources/RappCore/PacedSender.swift`（删 `acks`、`busy`、`pumpV6`，`transmit` 去掉 `done`）
- Modify: `Sources/rapp-host/Server.swift`（`helloVersion` 及 403/420/470/489/702/732/763 行的分支）
- Modify: `rust/client-core/src/protocol.rs`（`VERSION`、`Address.version`、`protocol` 参数、版本列表、`connect_url`、`hello()`）
- Modify: `rust/client-core/src/text.rs:41`、`rust/client-core/src/bin/rapp-session.rs`（106、155、164、251 行）、`rust/client-gtk/src/ui.rs`（174、900 行）
- Modify: `scripts/test-linux-client.py`、`scripts/side-loopback.py`、`scripts/multi-client-loopback.py`
- Test: `Tests/RappCoreTests/ProtocolTests.swift`、`Tests/RappCoreTests/PacedSenderTests.swift`、`rust/client-core/tests/client.rs`

**Interfaces:**
- Produces: `public let protocolVersion: UInt8 = 9`；`PacedSender.init(mode: Mode, fps: Int, now: @escaping () -> TimeInterval, transmit: @escaping (CanvasRect, FramePayload) -> Void)`；Rust `pub const VERSION: u8 = 9`，`Address` 不再有 `version` 字段（用 `p::VERSION`）。

- [ ] **Step 1: 写失败的测试**
  - `ProtocolTests.testHelloAcceptsOnlyVersion9`：用 `version: 9` 编出的 hello 能解；把版本字节改成 8 和 10 解码都抛 `ProtocolVersionMismatch`。同样覆盖 `fetch`/`put` 开头的版本字节（`Reader.version()`）。
  - Rust `client.rs`：删掉 486 行 `protocol=7` 的断言；新增 `hello_announces_version_9`：`Address::parse("rapp://host/?token=x", None)` 的 hello 包首字节为 9。

- [ ] **Step 2: 运行，确认失败**
  Run: `swift test --filter RappCoreTests.ProtocolTests` 和 `cd rust && cargo test -p rapp-client-core`
  Expected: 新测试失败（版本仍是 8）。

- [ ] **Step 3: 改 Swift**
  - `protocolVersion = 9`；删除 `oldestClientVersion`、`clientSendsFrameAcks`、`clientUnderstandsInputBlocked`、`clientUnderstandsInputSource`；两处范围判断改成 `== protocolVersion`；顶部注释改成只描述 v9（标志位帧格式见 TileCodec）。
  - `PacedSender`：删 `acks`、`busy`、`pumpV6`、`ack`/`tick` 里的 `guard acks`；类注释去掉 v6 段落。
  - `Server.swift`：删 `helloVersion`，所有按它分支的地方保留 v8 行为（总是转发 `setPinned`、`ack`、`inputBlocked`、`weak`、输入来源）。`makePacedSender` 的发送完成回调只处理错误。

- [ ] **Step 4: 改 Rust 和脚本**
  - `VERSION = 9`；删 `Address.version`、`protocol` 查询参数（落到 `_ => ()`）、版本列表检查、`connect_url` 的 `protocol` 追加；`hello()`、`text.rs` 用 `VERSION`。
  - `rapp-session.rs`：删开始 JSON 的 `protocol` 字段和注释，`version >= 7` 的判断去掉（总发确认，`pinned` 总是 `Some`）。
  - `client-gtk/src/ui.rs`：删 `address.version == 4` 分支和 `>= 7` 判断。
  - 脚本：`test-linux-client.py` 期望 `"protocol": 9`，删 legacy v4/v5 用例和 URL 的 `protocol=`；`side-loopback.py`、`multi-client-loopback.py` 的 hello 默认版本改 9，删 v5 客户端用例，"old protocol" 检查改用版本 8。
  - 全仓再搜一遍：`grep -rn "helloVersion\|oldestClientVersion\|clientSends\|clientUnderstands\|address.version\|pumpV6\|protocol=" Sources Tests rust scripts --include='*.swift' --include='*.rs' --include='*.py'`，结果应为空。

- [ ] **Step 5: 删掉/改掉测试**
  删 `PacedSenderTests.testV6PathUsesCompletionNotAcks`；其余 `PacedSender(... acks: true ...)` 和 `transmit` 闭包改成新签名。

- [ ] **Step 6: 运行全部测试**
  Run: `bash scripts/check.sh`（末行 `EXIT=0`）和 `cd rust && cargo test -p rapp-client-core && cargo check -p rapp-client-gtk`
  Expected: 全部通过。若本机没有 GTK4 导致 `client-gtk` 编不过，报告里写明，留给 Linux 构建验证。

- [ ] **Step 7: 提交**
  `git commit -m "protocol: v9 only; drop code for older clients"`

---

### Task 2: Swift 帧格式 v9（标志位、搬画布、复制块、显示时机）

**Files:**
- Modify: `Sources/RappCore/TileCodec.swift`（`FramePayload`、格式注释、`FrameDecoder`；编码器只改输出标志）
- Modify: `Sources/RappCore/Protocol.swift:142-144, 255-261`（帧消息读写）
- Test: `Tests/RappCoreTests/TileCodecTests.swift`、`Tests/RappCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FrameFlags: OptionSet { full = 1, start = 2, end = 4, copies = 8 }
  public struct FramePayload: Equatable {
      mode: Mode; width: UInt16; height: UInt16; flags: FrameFlags
      dx: Int32 = 0; dy: Int32 = 0      // 只在 start 且非 full 时上线
      data: [UInt8]
      var isFull: Bool { flags.contains(.full) }
  }
  // FrameDecoder
  @discardableResult public func decode(_ frame: FramePayload) throws -> Bool  // true = 现在可以更新显示
  ```
  复制块 kind 值 `5`（`private let kindCopy: UInt8 = 5`）。
- 编码器在本任务里：首片带 `.start`（整帧再加 `.full`），末片带 `.end`，单片两者都有；尺寸变了仍发整帧（Task 3 再改）。

- [ ] **Step 1: 写失败的测试**（手工拼块体，用 `DeflateStream().compress` 压）
  - `testSliceFlagsStartAndEnd`：多片整帧 → 首片 `[.full,.start]`、中间无标志、末片 `.end`；单片 → `[.full,.start,.end]`。
  - `testMoveHeaderShiftsCanvas`：先解一个 8×8 已知画布；再解 `start|end` 片，`width=10,height=6,dx=2,dy=-1`、块数 0 → 新画布 (x,y) = 旧 (x+2, y−1)，越界处为 0。
  - `testCopyTileReadsReferenceNotPartialFrame`：同一帧两片，第一片写块 A，第二片复制块的源覆盖 A 原来的位置 → 结果取自"搬完、写 A 之前"的画布。
  - `testCopyTileWithoutCopiesFlagThrows`、`testCopySourceOutOfCanvasThrows`（`sx+tw > width`）、`testUnknownFlagBitsThrow`（如 0x10）、`testCopiesWithoutStartThrows`、`testSliceWithoutOpenFrameThrows`（没有 start 的片紧跟在一帧 `end` 之后）、`testDeltaStartWhileFrameOpenThrows`。
  - `testFullFrameMayInterruptOpenFrame`（Review Focus 3）：一帧只收了 `start` 片，接着来 `[.full,.start,.end]` → 不抛，返回 true。
  - `testDisplayTiming`：会话第一帧整帧逐片返回 true；之后的整帧非末片返回 false、末片 true；带搬画布（尺寸变或 dx/dy 非 0）的帧同样只有末片 true；普通差量帧每片 true。
  - `ProtocolTests`：帧消息往返带 dx/dy（负数）和不带的两种；带 `start` 非 full 时消息里正好多 8 字节。

- [ ] **Step 2: 运行，确认失败**
  Run: `swift test --filter RappCoreTests.TileCodecTests`
  Expected: 编译失败或断言失败（没有 `flags`/kind 5）。

- [ ] **Step 3: 实现**
  - 消息读写按"本计划替规格定下的事"的布局；`Message.decode` 只按 `start` 且非 `full` 决定是否读 dx/dy。标志位的全部校验放在 `FrameDecoder.decode`（测试直接构造 `FramePayload`，绕过消息层），坏帧抛 `CodecError`。
  - `FrameDecoder` 状态：`open: Bool`（一帧在收）、`hold: Bool`（这一帧收完前不显示）、`shown: Bool`（显示过完整画面）、`reference: [UInt8]?`（仅 `copies` 时留）。整帧：清零、`hold = shown`。非整帧 start：要求 `!open` 且已有画布、mode 相同；按尺寸上限检查（同整帧）；搬画布；`hold = 尺寸变了 || dx != 0 || dy != 0`。`end` 时 `open = false`、若返回 true 则 `shown = true`、丢掉 `reference`。返回值 = `!hold || end`。
  - 更新 `TileCodec.swift` 顶部格式注释：消息头、标志位、搬画布、kind 5、参考画布的定义。
  - 修改现有测试里 `FramePayload(..., isFull:, ...)` 的构造为 `flags:`。

- [ ] **Step 4: 运行测试**
  Run: `swift test --filter RappCoreTests`
  Expected: PASS。

- [ ] **Step 5: 提交**
  `git commit -m "codec: v9 frame flags, canvas move header and copy tiles (Swift)"`

---

### Task 3: 编码器——搬画布、比较用像素、整帧只在必要时

**Files:**
- Modify: `Sources/RappCore/TileCodec.swift`（`FrameEncoder`）
- Create: `Tests/RappCoreTests/ScrollScenes.swift`（确定性场景生成器，Task 4/6 复用）
- Test: `Tests/RappCoreTests/TileCodecTests.swift`、新建 `Tests/RappCoreTests/ScrollCopyTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `FramePayload`/`FrameFlags`/`FrameDecoder.decode -> Bool`。
- Produces:
  ```swift
  public func encodeSlices(samples: [UInt8], raw: [UInt8]? = nil, width: Int, height: Int,
                           region: CanvasRect? = nil, limit: Int, firstLimit: Int? = nil) -> [FramePayload]
  public func encode(samples: [UInt8], raw: [UInt8]? = nil, width: Int, height: Int,
                     region: CanvasRect? = nil) -> FramePayload?
  ```
  `internal var model: [UInt8] { previous }`（测试读模型用；`private` 属性 `@testable` 也读不到）。
  `raw`：紧密排列的 BGRA（`width*height*4`），只在双色档有意义，其他档传了也忽略；前后两帧都有 `raw` 时才按原始像素比。`region` 为 nil 时视为 `(0, 0, width, height)`。
- `ScrollScenes`：`struct SceneFrame { bgra: [UInt8]; width: Int; height: Int; region: CanvasRect }`，`static func frames(seed: UInt64, count: Int, kinds: [SceneKind]) -> [SceneFrame]`，`enum SceneKind { terminalScroll, webScroll(topBar: Int, sideBar: Int), resize(edge: Edge), regionMove, localChange }`；用自带的 64 位 LCG，不用系统随机数；生成后用 `Quantizer.quantize` 得到样本。

- [ ] **Step 1: 写失败的测试**（`ScrollCopyTests`，每个 mode 都跑：gray4、color16、duogray 带 raw）
  - `testResizeEveryEdgeIsNotFull`：依次拉宽/拉窄四条边（区域原点相应变化）→ 除第一帧外没有 `.full` 片；首片带正确的 `dx/dy`；每帧解完后 `dec.samples` 等于该帧量化结果。
  - `testDensityOnlyChangeSendsFull`（Review Focus 1）：区域不变、像素尺寸 ×2 → `.full`；再回到 ×1 → `.full`。
  - `testFractionalAndHugeRegionMoves`（Review Focus 2）：区域 x 挪 0.5 点（scale 1 和 2）；区域挪出比画布还远（已覆盖矩形为空）→ 都不是整帧，解完逐字节等于量化结果。
  - `testModelMatchesDecoderRandomized`：`ScrollScenes` 种子 1…20、每串 40 帧、混合所有场景 → 每帧所有片解完后 `dec.samples` 等于编码器模型（`@testable` 读 `previous`），且在没有按原始像素配上的档（gray4、color16）等于该帧量化结果。
  - 改 `testSizeChangeForcesFull` 为 `testSizeChangeMovesCanvasInsteadOfFull`。

- [ ] **Step 2: 运行，确认失败**
  Run: `swift test --filter RappCoreTests.ScrollCopyTests`
  Expected: FAIL（尺寸变化仍发整帧）。

- [ ] **Step 3: 实现**
  - 新状态：`previousKey: [UInt8]?`（双色档存 raw，否则 nil 表示用样本）、`previousRegion: CanvasRect`、`previousScale: Double`；`full = forceFull || 首帧 || |scale/previousScale − 1| > 0.01`。
  - 非整帧：算 dx/dy，若尺寸变或偏移非 0 就把模型和 `previousKey` 按偏移搬进新尺寸，得到已覆盖矩形；碰到已覆盖矩形之外的块必须编码。
  - 同位置判断：样本相同，或（前后都有 raw 时）raw 相同 → 不发。只因 raw 相同而不发的块会让模型 ≠ 当前样本：记 `lastEncodeDiverged = true`、`needsSettle = true`（Task 4/5 用；本任务先把这两个属性加上：`public private(set) var lastEncodeDiverged = false`、`public private(set) var needsSettle = false`）。
  - 模型更新：搬完的模型上，把编码的块换成当前样本；`previousKey` 整体换成当前 key（不变式见规格 §5.3）。
  - 首片：`start`，非整帧时带 dx/dy；末片 `end`。`nothing changed` 且无搬画布时返回 `[]`；有搬画布时即使没有块也要发一片（块数 0）。
  - 1080p 下搬画布用整行 `memmove`/切片拷贝，不要逐像素。

- [ ] **Step 4: 运行测试**
  Run: `swift test --filter RappCoreTests`
  Expected: PASS（包括旧的 TileCodec/PacedSender 测试）。

- [ ] **Step 5: 提交**
  `git commit -m "codec: keep the old picture on resize and region moves; full only on mode/density"`

---

### Task 4: 编码器——上下滚动检测和复制块、静止修正编码

**Files:**
- Modify: `Sources/RappCore/TileCodec.swift`（`FrameEncoder`）
- Test: `Tests/RappCoreTests/ScrollCopyTests.swift`、新建 `Tests/RappCoreTests/ScrollCopyPerfTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `encodeSlices(samples:raw:width:height:region:limit:firstLimit:)`、`ScrollScenes`。
- Produces:
  ```swift
  public func encodeSettle(limit: Int) -> [FramePayload]   // needsSettle 为 false 时返回 []
  var copiesEnabled = true                                  // internal，测试对比基线用
  ```
  `encodeSettle` = 把最后一次输入（样本、raw、区域）按"只比样本、不复制、不搬画布"再编一次；之后 `needsSettle = false`。

- [ ] **Step 1: 写失败的测试**
  - `testTerminalScrollSendsCopies`：`terminalScroll` 场景（16 px 一行，往上推一行，底部新出一行）→ 非首帧带 `.copies`，且字节数 ≤ 同场景 `copiesEnabled = false` 的 20%（gray4、color16、duogray 带 raw 各测一次）。
  - `testWebScrollWithFixedBarsSendsCopies`：`webScroll(topBar: 60, sideBar: 200)`，每帧滚 37 px → 字节数 ≤ 基线的 40%。
  - `testCopiesNeverReadUncovered`：同时搬画布和滚动 → 解码不抛（源全在已覆盖矩形内），结果逐字节等于模型。
  - `testRepetitiveAndBlankContentStaysCorrect`（Review Focus 4）：全白画面、满屏相同的行再滚动 → 不崩，解完等于模型；全白时没有复制块（同色行不投票）。
  - `testSettleRestoresExactQuantization`：duogray 带 raw，内容挪 5 px（非 16 倍数）→ 若 `needsSettle`，调 `encodeSettle` 解完后 `dec.samples` 逐字节等于最后一帧的 `Quantizer.quantize`，之后 `needsSettle == false`、再调返回 `[]`。
  - 把 `testModelMatchesDecoderRandomized` 扩展到开着复制。
  - `ScrollCopyPerfTests.testExtraEncodeTimeAt1080p`：仅在 `RAPP_PERF=1` 时运行（否则 `XCTSkip`），1920×1080 网页滚动 60 帧，duogray 带 raw 和 color16，打印开/关复制的平均每帧毫秒，断言差值 ≤ 3 ms。

- [ ] **Step 2: 运行，确认失败**
  Run: `swift test --filter RappCoreTests.ScrollCopyTests`
  Expected: FAIL（没有复制块）。

- [ ] **Step 3: 实现**
  - 第一遍：同位置判断，得到"变了的块"。变了的块少于 4 个时只试上一帧用过的 dy。
  - 行指纹：在 key 上，按 64 px 宽的列条，只算含有变了的块的列条；当前帧和（搬完的）上一帧各一份；同色行不入表。每列条把"当前行指纹 → 上一帧里相同指纹的行"的差值 `dy`（源行 = 当前行 + dy，`dy != 0`）计票；全图合计取票数最多的至多 3 个，加上一帧用过的 dy。
  - 第二遍：每个变了的块依次试候选 dy，源 `(x0, y0 + dy)` 必须整个落在已覆盖矩形内；源和当前块样本相同或（有 raw 时）raw 相同 → 写复制块（`sx = x0, sy = y0 + dy`），只因 raw 相同时同 Task 3 记 diverged；都不行就照常编码。用上的 dy 记为下一帧的"上一帧 dy"。
  - 有复制块时首片置 `.copies`；模型更新要从"搬完、写块之前"的模型快照里取复制源（和解码器一样）。
  - 估算分片大小时复制块按 4 字节计。
  - 1080p 超 3 ms 时先减少行指纹的计算范围（只算变了的块所在列条已是第一步），再减候选数；把实测数字写进报告。

- [ ] **Step 4: 运行测试**
  Run: `swift test --filter RappCoreTests` 和 `RAPP_PERF=1 swift test -c release --filter RappCoreTests.ScrollCopyPerfTests`
  Expected: PASS；perf 测试打印的两组毫秒数写进报告。

- [ ] **Step 5: 提交**
  `git commit -m "codec: detect vertical scrolls and send copy tiles; settle re-encode"`

---

### Task 5: PacedSender 和主机接线

**Files:**
- Modify: `Sources/RappCore/PacedSender.swift`
- Modify: `Sources/rapp-host/Server.swift`（`frameArrived`/`quantizeAndSubmit`/`submit`/`setStream` 重绘路径、计时器、每秒统计；`tableChanged` 和 `setStream` 里"新像素尺寸会触发整帧"的注释）
- Test: `Tests/RappCoreTests/PacedSenderTests.swift`

**Interfaces:**
- Consumes: Task 4 的 `encodeSlices(...raw:region:...)`、`encodeSettle(limit:)`、`lastEncodeDiverged`、`needsSettle`。
- Produces:
  ```swift
  public func offer(samples: [UInt8], raw: [UInt8]?, width: Int, height: Int, region: CanvasRect, captured: TimeInterval)
  public func settleIfIdle()        // 会话队列上每 100 ms 调一次
  Stats 增加: fullFrames: Int（上一秒发出的整帧数）, encodeMsMax: Int?（上一秒最慢一次编码）
  ```

- [ ] **Step 1: 写失败的测试**
  - `testSettleAfter300msOfNoDivergence`：duogray 带 raw，挪 5 px 的两帧（使 `needsSettle`）→ 发完并确认；假时钟 +0.29 s `settleIfIdle()` 不发；+0.31 s 发出修正片；解完逐字节等于最后一帧的量化结果；再调不发。
  - `testSettleWaitsForQueueAndHeldOffer`：还有排队的片或待编的帧时，过了 300 ms 也不发修正。
  - `testSettleRunsWhileOtherTilesKeepChanging`（Review Focus 5）：滚动后，每 100 ms 来一帧只改右下角一个块（不再有按原始像素配上的块）→ 300 ms 后修正照样发出，最后解码画布等于最后一帧量化结果。
  - `testStatsCountFullFramesAndEncodeTime`：第一帧后 `takeStats().fullFrames == 1`，下一秒为 0；`encodeMsMax` 不为 nil。
  - 现有测试改用新的 `offer`。

- [ ] **Step 2: 运行，确认失败**
  Run: `swift test --filter RappCoreTests.PacedSenderTests`
  Expected: FAIL。

- [ ] **Step 3: 实现 PacedSender**
  - `Offer` 加 `raw`；`pump` 调 `encodeSlices(samples:raw:width:height:region:limit:firstLimit:)`，用 `now()` 量编码耗时；整帧（首片 `.full`）计数。
  - `lastEncodeDiverged` 为真时记 `divergedAt = now()`。`settleIfIdle()`：`encoder.needsSettle && queue.isEmpty && latest == nil && now() - divergedAt >= 0.3` 时 `encodeSettle(limit: sliceLimit)` 入队（区域用最后一帧的）并 `pump()`。`setMode` 新编码器时清 `divergedAt`。

- [ ] **Step 4: 实现 Server**
  - `quantizeAndSubmit`：mode 为 duogray/duocolor 时，从 `CVPixelBuffer` 逐行拷出紧密 BGRA 作为 `raw`（缓冲会被复用），其他档 `raw = nil`；经 `submit` 传给 `offer`。换档位重绘路径同样带上。
  - 在现有 1 s 计时器旁加一个 100 ms 的 `DispatchSourceTimer`（会话队列）调 `paced?.settleIfIdle()`，会话结束时一并取消。
  - 每秒统计（文本和 `--json` 两种输出）加上 `fulls` 和 `encMs`。
  - 改掉两处"新像素尺寸会让编码器发整帧"的注释：现在改尺寸搬画布、密度改变由编码器按比例判断发整帧。

- [ ] **Step 5: 运行测试并构建**
  Run: `bash scripts/check.sh`
  Expected: 末行 `EXIT=0`。

- [ ] **Step 6: 提交**
  `git commit -m "host: pass raw pixels and region to the encoder, settle after 300 ms, log fulls/encMs"`

---

### Task 6: Rust 解码器、两端一致的测试文件、Python 脚本的帧格式

**Files:**
- Modify: `rust/client-core/src/protocol.rs`（`Incoming::Frame` 和解析）、`rust/client-core/src/codec.rs`
- Create: `Tests/RappCoreTests/CrossFixtureTests.swift`、`rust/client-core/tests/fixtures/scroll-copy.bin`
- Modify: `rust/client-core/tests/client.rs`、`rust/client-core/src/bin/rapp-session.rs` 的测试辅助 `tiny_frame`（约 406 行）
- Modify: `scripts/test-linux-client.py`、`scripts/benchmark-linux-session.py`、`scripts/test-linux-session-latency.py`（`struct.pack('<BffffHHB', ..., full)` 那一字节改成标志位；单片整帧 `0x07`）

**Interfaces:**
- Consumes: Task 2 的字节布局、Task 3 的 `ScrollScenes`。
- Produces:
  ```rust
  Incoming::Frame { mode: u8, region: Rect, width: usize, height: usize, flags: u8, dx: i32, dy: i32, data: Vec<u8> }
  pub const FULL: u8 = 1; pub const START: u8 = 2; pub const END: u8 = 4; pub const COPIES: u8 = 8;  // codec.rs
  impl Decoder {
      pub fn decode_into(&mut self, mode: u8, w: usize, h: usize, flags: u8, dx: i32, dy: i32,
                         compressed: &[u8], pixels: &mut Vec<u8>) -> Result<bool>;   // true = 已展开到 pixels，可显示
      pub fn decode(&mut self, mode: u8, w: usize, h: usize, flags: u8, dx: i32, dy: i32,
                    compressed: &[u8]) -> Result<Option<Vec<u8>>>;                    // None = 先别显示
      pub fn samples_le(&self) -> Vec<u8>;   // 与 Swift FrameDecoder.samples 同布局（bps 1 或 2，小端）
  }
  ```
  返回 false/None 时不展开 BGRA（省时间）。
- 测试文件格式（小端，记录连续排列）：`u8 tag`；`tag 1` = 片：`u8 mode, u16 w, u16 h, u8 flags, i32 dx, i32 dy, u32 n, n 字节 data`；`tag 2` = 期望画布：`u16 w, u16 h, u32 n, n 字节样本`，每个 `end` 片之后写一条。

- [ ] **Step 1: 写测试**
  - `CrossFixtureTests.testFixtureDecodesInSwift`：`RAPP_WRITE_FIXTURES=1` 时用 `ScrollScenes`（种子 7，60 帧，gray4、color16、duogray 带 raw 各一段，每段以换档位整帧开头，包含搬画布、复制、修正帧）生成并写文件；否则读已提交的文件，用 Swift `FrameDecoder` 解，期望画布逐字节相同。文件控制在 1 MB 以内（画布约 200×150）。
  - Rust `client.rs`：`scroll_copy_fixture_matches_swift`：读同一文件，`samples_le()` 与每条期望画布逐字节相同。
  - Rust 单元测试照 Task 2 的 Swift 用例各写一份：搬画布、复制读参考画布、各种坏帧（未知标志位、无 copies 的 kind 5、越界源、无 start 的片、帧未结束又来非整帧 start）、显示时机、整帧打断未完成的帧。

- [ ] **Step 2: 生成测试文件并确认 Rust 失败**
  Run: `RAPP_WRITE_FIXTURES=1 swift test --filter RappCoreTests.CrossFixtureTests` 然后 `cd rust && cargo test -p rapp-client-core`
  Expected: Swift PASS 且写出文件；Rust FAIL。

- [ ] **Step 3: 实现 Rust**
  照 Swift 解码器的状态机（`open`/`hold`/`shown`/参考画布）；协议解析照 Task 2 的校验。`rapp-session.rs`、`client-gtk/src/ui.rs` 的调用先改成新签名，确认照旧每片发 `frame_ack`；显示规则在 Task 7 接。

- [ ] **Step 4: 改 Python 脚本**
  三个脚本的帧头：整帧单片标志 `0x07`；差量单片标志 `0x06` 后跟 `struct.pack('<ii', 0, 0)`。

- [ ] **Step 5: 运行测试**
  Run: `swift test --filter RappCoreTests.CrossFixtureTests`、`cd rust && cargo test -p rapp-client-core && cargo check -p rapp-client-gtk`
  Expected: 全部通过（GTK 不可用时同 Task 1 说明）。

- [ ] **Step 6: 提交**
  `git add rust/client-core/tests/fixtures/scroll-copy.bin ...`；`git commit -m "client-core: v9 frame decoding with copy tiles; Swift/Rust cross-check fixture"`

---

### Task 7: 客户端显示时机

**Files:**
- Modify: `Sources/RappSession/EmbeddedSession.swift:238-252`、`Sources/rapp-client/main.swift:184-196`
- Modify: `rust/client-core/src/bin/rapp-session.rs:233-256`、`rust/client-gtk/src/ui.rs:160-182`
- Test: `Tests/RappSessionTests/EmbeddedSessionTests.swift`

**Interfaces:**
- Consumes: Swift `FrameDecoder.decode -> Bool`；Rust `decode_into -> Result<bool>`、`decode -> Result<Option<Vec<u8>>>`。

- [ ] **Step 1: 写失败的测试**
  `EmbeddedSessionTests.testHeldFrameDrawsOnlyAtEnd`：先送一张完整画面；再送两片的整帧（第二片才 `end`）→ 第一片后没有 `.surfaces` 事件、第二片后有；两片各发一个 `frameAck`。`testFirstFrameDrawsPerSlice`：会话第一帧两片 → 每片后都有 `.surfaces`。

- [ ] **Step 2: 运行，确认失败**
  Run: `swift test --filter RappSessionTests.EmbeddedSessionTests`
  Expected: FAIL。

- [ ] **Step 3: 实现**
  四处调用点：解码返回"先别显示"时跳过绘制/输出（`surfaces.draw`、`coordinator.show`、`out.frame`、`Event::Image`），但照旧发帧确认、照旧计数。

- [ ] **Step 4: 运行测试**
  Run: `bash scripts/check.sh` 和 `cd rust && cargo test -p rapp-client-core && cargo check -p rapp-client-gtk`
  Expected: 全部通过。

- [ ] **Step 5: 提交**
  `git commit -m "clients: hold the old picture until a full or resized frame is complete"`

---

### Task 8: 文档和真机验收

**Files:**
- Modify: `README.md`（协议版本、帧格式、实测码率相关段落）
- Modify: `docs/superpowers/specs/2026-11-14-rapp-smooth-streaming-design.md`（加一行修订，指向滚动复制规格及其 §2）
- Create: `docs/superpowers/specs/2026-11-14-rapp-scroll-copy-acceptance.md`（验收记录）

- [ ] **Step 1: 改文档**
  README 里 v8/帧格式的描述改成 v9（标志位、搬画布、复制块），不兼容旧版本写明"两端都要升级"。流畅串流规格修订行：规则三的"静止层不改"以滚动复制规格为准，"停下来补清晰"做规则三时与其 §5.5 合并。

- [ ] **Step 2: 真机验收**（在用户的 Mac 上，`swift build -c release`，按 README 的方式起主机和客户端；对照基线用 `main` 上的 0.7.1）
  按规格 §7 的表逐项做，数字记进验收记录：
  - S1：终端连续输出（如 `yes | head -n 100000` 或 `seq 1 200000`），本机像素密度，双色·灰度和高彩各 30 秒，看 service.log 每秒 kbps → 比 0.7.1 少 80% 以上。
  - S2：有固定顶栏和侧栏的网页，滚轮上下滚 30 秒，总字节 → 少 60% 以上。
  - S3：拖动窗口四条边，看每秒统计的 `fulls` → 拖动期间为 0；画面没有黑屏扫过。
  - S4：逐像素一致由 Task 4/5 的单元测试保证；真机上双色·灰度滚动后停下 1 秒，确认停下后约 300 ms 有一次小流量（修正片）、`fulls` 为 0，肉眼看文字不比 0.7.1 糊。
  - 弱网档（双色·灰度 + 密度 1.0）：S1、S2 再测一遍，终端少 80% 以上，网页只记录。
  - S5：以 Task 4 的 `RAPP_PERF=1` 测试为准（开/关复制差值 ≤ 3 ms）；真机上再记录 1080p 窗口持续滚动时的 `encMs`（0.7.1 没有这项统计，只记数字）。
  没达到的项如实记录，不要调测试去凑数字。

- [ ] **Step 3: 提交**
  `git commit -m "docs: protocol v9, scroll copy; acceptance record"`
