# rapp 修订 2（极致省流）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 双色档位、15/5 fps、B 端拖角等比缩放（采集密度跟随 B 的显示像素）、拖边改 A 的宽或高、"极限省流"一键组合；协议 v3。

**Architecture:** 双色是量化阶段的事（16×16 小块两色），编码器只多一种与档位无关的块类型。采集密度是客户端算的浮点数，
主机只做 `min(密度, 屏幕倍数)`。缩放判定和尺寸换算写成 `Geometry.swift` 里的纯函数，客户端只负责接线。

**Tech Stack:** Swift 5.9 SwiftPM, macOS 14+, ScreenCaptureKit, AppKit, zlib.

**Spec:** `docs/superpowers/specs/2026-11-10-rapp-design.md`（修订 2 部分：开头摘要、§1.4、§1.8、§3、§4.2、§4.7、§5.2、§5.3、§6、§7、§9、§11）

## Global Constraints

- 协议版本 3；mismatch 文本 "protocol version mismatch: host 3, client N (update both sides)"。
- 帧率只能是 15 或 5；采集密度 Float32，有限且在 (0, 8]，否则 `CodecError`。
- 档位 rawValue：gray4 0、color8 1、color16 2、duogray 3、duocolor 4；名字 `duogray`、`duocolor`。
- 双色：16×16 小块，亮度差 < 24 为一组；阈值从 (lo+hi)/2 起迭代 4 次，t = 两组平均亮度中点向上取整。
- 块类型 3 = 双色小块；只在块内 ≥ 3 种样本且每个 16×16 小块 ≤ 2 种时使用。
- 拖角判定：横竖都在 16 点以内。
- 通过信号：`./scripts/check.sh` 后 `.build-logs/check.log` 最后一行 `EXIT=0`。
- 不是 git 仓库：不提交；基线快照在 scratchpad `baseline-rev2/`。

## Review Focus

1. 拖角时客户端窗口尺寸被 AppKit 再约束（最小尺寸、屏幕边界）后，画面区域不再是锁定比例：应只留细黑边，不发 `Resize`。
2. 客户端窗口拖到另一块倍率不同的屏幕：采集密度要重算，A 端画面像素随之变化。
3. 双色档位下 A 端窗口宽或高不是 16 的倍数：边上的小块按实际大小，往返一致（Task 1、2 有测试）。
4. 快速连续切换档位/帧率/密度：旧档位的样本不能混入新编码器（沿用修订 1 的 seq + 档位标记）。
5. A 端把窗口改到与请求不同的尺寸（app 限制）：`Size` 更新后，下次拖角按新的长宽比锁定。

---

### Task 1: 双色量化

**Files:** Modify `Sources/RappCore/Quantize.swift`; Test `Tests/RappCoreTests/QuantizeTests.swift`

**Interfaces:**
- Produces: `Mode.duogray = 3`, `Mode.duocolor = 4`（`bytesPerSample` 1 / 2，`name` "duogray"/"duocolor"）；
  `Quantizer.quantize(... mode: .duogray/.duocolor)` 返回每个 16×16 小块 ≤ 2 种样本；`Quantizer.expand` 对 duogray 同 gray4、duocolor 同 color16。

- [ ] Step 1: 写失败测试：
  - `testDuoFlatBlockIsOneSample`：16×16 亮度在 100…120 之间渐变 → 全部一个样本。
  - `testDuoBlackTextOnWhiteIsTwoSamples`：白底 + 黑色竖线 + 中间灰抗锯齿（128）列 → 恰好两种样本 {0, 15}（duogray），灰列归到一边。
  - `testDuoEdgeBlocks`：20×18 图，右边 4 列、下边 2 行与主块颜色不同 → 每个小块各自 ≤ 2 种样本，边上小块的颜色来自自己的像素。
  - `testDuoColorKeepsHue`：红底白字 → duocolor 样本里有 RGB565 红（0xF800 附近）。
  - `testDuoExpandMatchesBaseModes`：expand(duogray) == expand(gray4)，expand(duocolor) == expand(color16)，同样的样本。
- [ ] Step 2: `./scripts/check.sh` → 编译失败（没有 `.duogray`）。
- [ ] Step 3: 实现：duo 档位先按现有逐行逻辑（含圆角填补）得到每像素 RGB（中间缓冲），再按 16×16 小块分组写样本。
- [ ] Step 4: `./scripts/check.sh` → `EXIT=0`。

### Task 2: 双色小块（块类型 3）

**Files:** Modify `Sources/RappCore/TileCodec.swift`; Test `Tests/RappCoreTests/TileCodecTests.swift`

**Interfaces:**
- Consumes: Task 1 的样本。
- Produces: 编码器自动选类型 3；解码器在任何档位都接受类型 3。

- [ ] Step 1: 写失败测试：
  - `testDuoSubBlocksRoundTripAndAreSmaller`：64×64、16 个小块各有不同两色（共 > 16 种）→ 往返相等，压缩后比同图逐样本原始表示小。
  - `testDuoKindChosenOnlyWhenEverySubBlockFits`：某一小块 3 种样本 → 不用类型 3（往返仍相等，且块类型字节 ≠ 3，用解压后的帧体检查）。
  - `testDuoEdgeTileRoundTrip`：100×70，duocolor 量化结果往返相等。
  - `testDecoderRejectsBadDuoSubBlock`：手工构造类型 3、n = 3 → `CodecError`。
- [ ] Step 2: 跑 → 失败（大小断言或类型断言）。
- [ ] Step 3: 实现编码（判定在原调色板扫描之后，distinct ≥ 3 时尝试）与解码。帧体格式写进 `FrameEncoder` 的文档注释。
- [ ] Step 4: `EXIT=0`。

### Task 3: 缩放几何（纯函数）

**Files:** Modify `Sources/RappCore/Geometry.swift`; Test `Tests/RappCoreTests/GeometryTests.swift`

**Interfaces — Produces:**
- `public enum ResizeHandle { case corner, horizontal, vertical, both }`
- `public func resizeHandle(mouse: CGPoint, windowFrame: CGRect, cornerSize: CGFloat = 16) -> ResizeHandle`（不会返回 `.both`；`.both` 用于非拖动的尺寸变化）
- `public func lockedAspectSize(proposed: CGSize, current: CGSize, aspect: CGSize) -> CGSize`（画面区域尺寸；取相对变化较大的一边）
- `public func remoteResize(view: CGSize, zoom: CGFloat, remote: CGSize, handle: ResizeHandle) -> CGSize`（`.corner` 返回 remote 不变）
- `public func captureDensity(zoom: CGFloat, backingScale: CGFloat, saver1x: Bool) -> Float`

- [ ] Step 1: 失败测试：四个角 ±16 内为 corner；左右边中部 horizontal；上下边中部 vertical；17 点处不是 corner；
  `lockedAspectSize`（宽变大 → 高按 1600:1000 比例；高变化更大时以高为准）；
  `remoteResize`（zoom 0.5，view 宽 600 → horizontal 宽 1200 高不变；vertical；both）；`captureDensity`（0.5×2 = 1.0，saver → 0.5）。
- [ ] Step 2: 失败。Step 3: 实现。Step 4: `EXIT=0`。

### Task 4: 协议 v3 + 主机

**Files:** Modify `Sources/RappCore/Protocol.swift`, `Sources/rapp-host/Server.swift`, `Sources/rapp-host/WindowCapture.swift`, 客户端调用点（只为编译：`main.swift` 发 hello/setStream）；Test `ProtocolTests.swift`

**Interfaces — Produces:**
- `protocolVersion = 3`
- `.hello(token:bundleID:mode:fps:density:)`（fps `UInt8`，density `Float`）
- `.setStream(mode: Mode, fps: UInt8, density: Float)`（类型 11），`.size(width: UInt16, height: UInt16)`（类型 12）
- `RemoteAddress.fps: UInt8`（默认 15）；去掉 `scale`；`scale` 参数忽略。
- `WindowCapture.setStream(fps: Int, density: Double) async -> Bool`（替代 `setScale`），`refreshIfNeeded` 后由 Server 发 `.size`。

- [ ] Step 1: 失败测试：hello/setStream/size 往返；fps 3、density 0、−1、9、NaN 被拒；版本 2 的 hello → mismatch；
  地址 `fps=5`、`mode=duogray`、`fps=7` 报错、带 `scale=2` 仍能解析。更新原有用到 `scale`/`setMode` 的测试。
- [ ] Step 2: 失败。
- [ ] Step 3: 实现协议；主机：配置 `factor = min(density, pointPixelScale)`、`minimumFrameInterval = 1/fps`；
  `setStream` 处理（档位走原路径；密度变化 → reset 编码器；打印 `stream -> …`）；`refreshIfNeeded` 返回 true 时发 `.size`；
  客户端暂时发 `density = backingScaleFactor`。
- [ ] Step 4: `EXIT=0`。

### Task 5: 客户端缩放与菜单

**Files:** Modify `Sources/rapp-client/main.swift`, `Sources/rapp-client/TrafficLabel.swift`

**Interfaces — Consumes:** Task 3 的函数、Task 4 的消息。

- [ ] Step 1: `TrafficLabel`：状态 (mode, fps, saver1x)；菜单按规格 §7（五档位、跟随 B 屏幕/省流 1x、15/5 fps、极限省流）；
  `onSelect: ((Mode, UInt8, Bool) -> Void)`。
- [ ] Step 2: `AppDelegate`：保存 `remoteSize`（Ready、Size 更新）、`zoom`（初始 1）、`handle`；
  `windowWillStartLiveResize` 判定 handle；`windowWillResize(_:to:)` 在 corner 时用 `lockedAspectSize` 改提议尺寸；
  结束时 corner → 更新 zoom、必要时发 `setStream`；边 → 防抖后发 `remoteResize`；非拖动 → `.both`。
  `windowDidChangeBackingProperties` → 重发密度。只在密度/档位/帧率与上次发送不同时发送。
- [ ] Step 3: `./scripts/check.sh` → `EXIT=0`。
- [ ] Step 4: 手工：起 host + Safari 客户端；各档位 KB/s；拖角缩一半 A 不动、码率下降；拖右边 A 只改宽；"极限省流"后三项打勾正确。

### Task 6: 文档

**Files:** `README.md`

- [ ] 写明新档位、`fps` 参数、`scale` 已去掉、三种拖法、极限省流、实测数字；协议版本 3。`EXIT=0`。
