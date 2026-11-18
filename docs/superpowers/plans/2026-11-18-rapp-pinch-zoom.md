# 双指缩放和局部串流 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iOS（iPad / Duo）上捏合缩放 App 画面和文本终端（1–4 倍），放大时 A 只截取景附近的一块，「输入」旁边有「还原」。

**Architecture:** 一个共用的触摸识别器（`touch_gestures.dart`）把指针事件变成意图；每个（会话，窗口 / 终端）一份 `ZoomView` 算出 `zfit`，画面和终端的所有换算都改用它。App 窗口手势停下 150 ms 后经新的 `set_view` 通道调用告诉 Swift 会话，会话发协议 v14 的 `setView` 并按像素预算重算密度；A 端用纯函数 `viewRegion` 求截取范围。iOS 上每个窗口多一个「底图」纹理，平移时垫在下面不露黑边。

**Tech Stack:** Flutter / Dart（gui/），Swift（RappCore、RappSession、rapp-host、Runner 的 SessionPlugin），Rust（只升版本号）。

**Spec:** `docs/superpowers/specs/2026-11-18-rapp-pinch-zoom-design.md`

## Global Constraints

- 倍数 1–4；`z == 1` 时 `zfit == fit`，App 画面上的一切行为和现在完全一样（反目标第一条）。
- 只在 iOS 上缩放：识别器的缩放开关取 `pinchZoom`（`defaultTargetPlatform == TargetPlatform.iOS`）。macOS、Linux 从不发 `setView`、不注册底图纹理。
- 阈值全部写成具名常量（spec §9）：滑动 8 逻辑像素；T1 挂起 150 ms；放大时长按 500 ms；捏合判定两指距离变化 12 逻辑像素；双指轻点 250 ms / 8 像素；`setView` 停手后 150 ms；要的范围每边加 25 %；密度重发阈值 10 %；还原动画 200 ms；还原后底图再留 1 s。
- 协议 v14：`setView(window: UInt32, rect: CanvasRect)`，类型 41，client → host；`window == 0` = 不限范围；`rect` 是该窗口**内容**里的矩形（A 的点，内容左上为原点，不含标题栏）。
- `setView` **不进** Rust `read_message` 的允许列表。
- 「还原」：`RappButton.secondary`，`onPicture: true`，图标 `Icons.zoom_in_map`，`Key('zoom-reset')`，文字「还原」。
- 终端缩放不改 `_queueView` 的行列数，不发任何新消息。
- 不提交 `gui/pubspec.lock`、`rust/Cargo.lock` 的改动（构建、测试后 `git checkout -- gui/pubspec.lock rust/Cargo.lock`）。提交一律写明路径，不用 `git add -A`。
- Flutter：`export PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH"`。
- 不读 `docs/archives/`。

## Review Focus

1. **识别器抽出后 1 倍行为漂移**：`stage_test.dart` 里 34 处触摸测试和 `term_stage_test.dart` 的鼠标测试必须原样通过；Task 6 不许改这些测试文件。
2. **捏合开始时第一根手指已经按下**（落下超过 150 ms 才放第二根）：按 T2 第二根被忽略、不会变成捏合；放大时第一根还在 500 ms 挂起或平移中，第二根落下要进入双指判定。Task 5 有两条测试钉住。
3. **重连换了新的 `RemoteSession`**：缩放状态要像输入板文字那样搬到新会话（`_dropOld`），新画面挂上后重发取景。Task 4 有测试。
4. **软键盘起落、转屏时的限位**：舞台变小后取景不能让内容整块离开舞台；键盘只放宽下限、不自动挪。Task 4 的 `ZoomView` 测试覆盖。
5. **放大中换窗口标签 / 回全景 / 窗口被关**：旧会话收到一次「不限范围」，新窗口放大过才发它的取景；关掉的窗口的 `ZoomView` 被扔掉。Task 7 有测试。

---

### Task 0: 把软键盘分支并进来

`keyboardLift`（`gui/lib/ui/stage.dart`）在 `fix/ios-composer-keyboard` 上，还没进 main；本计划的键盘下限要用它。

- [ ] **Step 1:** `git merge --no-ff fix/ios-composer-keyboard -m "merge: the writing panel above the soft keyboard (needed for the zoom's keyboard bound)"`。Expected: 无冲突（已用 `git merge-tree` 验过）。
- [ ] **Step 2:** `cd gui && flutter test test/ui/stage_test.dart test/embed/composer_panel_test.dart` → 全过；还原 lockfile。

（交给 rapp-49 合并时说明本分支带着那两个提交。）

### Task 1: 协议 v14 和 `setView`

**Files:**
- Modify: `Sources/RappCore/Protocol.swift`（版本注释、`protocolVersion`、`Message`、`encoded()`、解码 `case 41`、`knownTypes`）
- Modify: `rust/client-core/src/protocol.rs:4`（`VERSION = 14`，允许列表不动）
- Modify: `gui/lib/embed/session_protocol.dart:2`（`sessionProtocolVersion = 14`）
- Test: `Tests/RappCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `Message.setView(window: UInt32, rect: CanvasRect)`，类型 41，载荷 `u32 window` + `rect`（`w.rect` / `r.rect`，和 `focusRegion` 一样）。

- [ ] **Step 1: 写失败测试**：`ProtocolTests.swift` 里 `XCTAssertEqual(protocolVersion, 13)` 改成 `14`；新增 `testSetViewRoundTrip`：`.setView(window: 7, rect: CanvasRect(x: 10, y: 20, w: 300, h: 200))` 和 `.setView(window: 0, rect: CanvasRect(x: 0, y: 0, w: 0, h: 0))` 编码后首字节是 41，解码等于原值；载荷多一个字节解码抛错。
- [ ] **Step 2:** `swift test --filter ProtocolTests` → FAIL（`setView` 不存在）。
- [ ] **Step 3: 实现**：版本注释加一行 `v14 = v13 + setView (client -> host: which part of a window B shows; window 0 = all)`；`case setView(window: UInt32, rect: CanvasRect) // 41, client -> host (v14)`；`knownTypes` 加 41。Rust、Dart 两处版本号改成 14。
- [ ] **Step 4:** `swift test --filter ProtocolTests` → PASS；`cd rust && cargo test -p rapp-client-core && cargo clippy -p rapp-client-core -- -D warnings` → PASS；`cd gui && flutter test test/embed/linux_session_port_test.dart` → PASS（版本号测试读 Rust 源码比对；`rapp-session` 夹具的用例只在 Linux 跑，macOS 上跳过属正常）。
- [ ] **Step 5:** `git grep -nE "protocol.*\b13\b|\b13\b.*protocol" -- Sources Tests gui/lib gui/test rust/*/src rust/*/tests` 确认没有漏掉写死的 13。提交 `feat(protocol): v14 adds setView`。

### Task 2: `viewRegion` 和 `viewDensity`（RappCore 纯函数）

**Files:**
- Modify: `Sources/RappCore/Windows.swift`（`viewRegion`）
- Modify: `Sources/RappCore/Geometry.swift`（`viewDensity`）
- Test: `Tests/RappCoreTests/ViewRegionTests.swift`（新建）

**Interfaces:**
- Produces:
  - `public func viewRegion(view: (window: UInt32, rect: CanvasRect)?, windows: [WindowInfo], display: CGSize) -> CanvasRect?`
  - `public func viewDensity(zoom: CGFloat, backingScale: CGFloat, choice: DensityChoice, content: CGSize, range: CGSize) -> Float`

`viewRegion`：`base = captureRegion(windows:display:)`。`view == nil`、`window == 0`、窗口 id 不在 `windows` 里 → `base`。否则：把 `rect` 平移到画布（`x + win.rect.x`，`y + win.rect.y + win.titleBar`），和所有 `parent == window` 的窗口外框求并，再和 `base` 求交，按 `captureRegion` 的规则向外取 8 的倍数、夹在 `display` 内；交集为空 → `base`。

`viewDensity`：`d₁ = captureDensity(zoom: 1, …)`；`range` 面积为 0 或 `content` 面积为 0 → `d₁`；否则 `min(captureDensity(zoom: zoom, …), d₁ × √(content 面积 ÷ range 面积))`，再夹进 `[0.01, 8]`。

- [ ] **Step 1: 写失败测试**（`ViewRegionTests`）：
  - `testNoViewIsCaptureRegion`：`view: nil` 和 `window: 0` 都等于 `captureRegion(...)`。
  - `testUnknownWindowIsCaptureRegion`：`window: 99` 不在表里 → `captureRegion(...)`。
  - `testViewIsRectOnCanvas`：窗口 `rect (100, 50, 800, 600)`、`titleBar 28`，`view rect (200, 100, 160, 120)` → 结果包含 `(300, 178, 160, 120)`，四边都是 8 的倍数，比原框最多多 8。
  - `testViewTakesChildPopups`：再加一个 `parent == 窗口 id` 的菜单在 `(700, 400, 200, 300)` → 结果也包含菜单外框；`parent` 是别的窗口的不算。
  - `testViewClippedToDisplay`：窗口一部分在屏幕外（`x = -200`），`view rect` 落在屏外那段 → 结果夹在 `display` 内，不为空时 `x >= 0`；整个落在屏外 → `captureRegion(...)`。
  - `testDensityAtOneIsUnchanged`：`zoom 1`、`range == content` → 和 `captureDensity(zoom: 1, …)` 相等，三种 `choice` 各一次。
  - `testPixelBudget`：`backingScale` 取 2 和 3，`choice` 取三种，`zoom` 取 1、1.5、2、3、4，`range = content ÷ zoom × 1.5`（宽高各乘），A 的上限 `native = 2`：断言 `range 面积 × min(d, native)² ≤ content 面积 × min(d₁, native)² × 1.0001`。
- [ ] **Step 2:** `swift test --filter ViewRegionTests` → FAIL（函数不存在）。
- [ ] **Step 3:** 按上面的规则实现两个函数。
- [ ] **Step 4:** `swift test --filter ViewRegionTests` → PASS。
- [ ] **Step 5:** 提交 `feat(core): viewRegion and the zoom's pixel budget`。

### Task 3: A 端处理 `setView`

**Files:**
- Modify: `Sources/rapp-host/Server.swift`（`handle` 的关口列表 ~405、新 `case .setView`、`tableChanged` ~914、新 `private var view`、一个共用的 `applyRegion(_ windows: [WindowInfo])`）
- Test: 现有 host 测试里能驱动 `Server` 的那套（实施者找；没有可驱动的就把判定写成纯函数放 RappCore，在 `ViewRegionTests` 里测，并在 ledger 记一条 Ruling）

**Interfaces:**
- Consumes: `viewRegion(view:windows:display:)`（Task 2），`Message.setView`（Task 1）。

规则：`setView` 进关口列表（和 `.setStream` 同一组，要 `started`）。`window == 0` → `view = nil`，否则 `view = (window, rect)`。然后 `applyRegion(table)`：`viewRegion(view: view, windows: table, display: display.size)`，和 `region` 不同就 `region = new` 并 `capture.setRegion(new)`。`tableChanged` 里原来的 `captureRegion` 换成同一个 `applyRegion(next)`。整屏会话的表是 `desktopTable`（窗口 id 1，标题栏 0），同一个 `applyRegion` 就对，因为它不走 `tableChanged`，所以 `setView` 的处理必须自己调。每次 region 变化打一行日志 `region: x,y w×h`（验收 6 要看）。

- [ ] **Step 1: 写失败测试**：App 会话收到 `setView(window: id, rect)` 后截取范围变成 `viewRegion(...)` 的结果；之后窗口表变化（弹出层出现）按同一规则重算；收到 `window: 0` 回到 `captureRegion`；整屏会话收到 `setView` 也调了 `setRegion`。
- [ ] **Step 2:** 跑测试 → FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** `swift test` → 全过。
- [ ] **Step 5:** 提交 `feat(host): capture only the part of the window B shows`。

### Task 4: Swift 会话：`set_view`、像素预算、底图纹理

**Files:**
- Modify: `Sources/RappSession/Channel.swift`（`ChannelCommand.setView`、`known` 集合 ~93 加 `"set_view"`、解析）
- Modify: `Sources/RappSession/EmbeddedSession.swift`（`setView(window:rect:zoom:)`；`sendStreamIfChanged` ~323 和 `link.density` ~83 改用 `viewDensity`）
- Modify: `Sources/RappSession/WindowSurfaces.swift`（底图）
- Modify: `gui/macos/Runner/SessionPlugin.swift`（iOS 上每个窗口再注册一个 `BaseTexture`；`windows` 载荷加 `"base"`；`.surfaces` 时一并标记）
- Modify: `Sources/RappSession/Channel.swift` 的 `eventPayload` "windows"（~346–356，加 `"base"`）
- Test: `Tests/RappSessionTests/`（Channel、EmbeddedSession、WindowSurfaces 现有测试文件里加）

**Interfaces:**
- Consumes: `viewDensity`（Task 2），`Message.setView`（Task 1）。
- Produces:
  - 通道方法 `set_view`，参数 `{sid, window, x, y, w, h, zoom}`（`window` 整数，其余浮点；`window == 0` 为不限范围，此时 `zoom` 取 1）。
  - `EmbeddedSession.setView(window: UInt32, rect: CanvasRect, zoom: Float)`。
  - `WindowSurfaces.base(_ id: UInt32) -> CVPixelBuffer?`。
  - `windows` 事件载荷里每个窗口可选的 `"base": <texture id>`（只有 iOS 有）。

`EmbeddedSession.setView`：`link.send(.setView(window:rect:))`，记下 `view`（窗口 id、`rect` 大小、`zoom`），再 `sendStreamIfChanged()`。密度：`view` 为空、`window == 0` 或窗口不在表里 → `viewDensity(zoom: 1, …, content: .zero, range: .zero)`（等于现在的值）；否则 `content` 取该窗口内容大小（`rect.w × (rect.h − titleBar)`），`range` 取 `rect` 大小。`linkDown` 时照旧不发。

底图：`Slot` 加 `base: CVPixelBuffer?` 和 `baseSize`（窗口 `rect` 的宽高）。`draw` 里：窗口宽高和 `baseSize` 不同 → `base = nil`；新画的 `visible` 覆盖整窗（四个值和 `(0,0,1,1)` 差都 ≤ 0.001）→ `base = buffer`、`baseSize = 当前宽高`。`keep(only:)` 一并扔掉。

SessionPlugin：`#if os(iOS)` 下，和 `SurfaceTexture` 同处注册 / 注销 `BaseTexture`（读 `surfaces.base(window)`）；`.surfaces(ids)` 时，`visible(id)` 覆盖整窗的那些也对底图纹理调 `textureFrameAvailable`。macOS 不注册，载荷里没有 `"base"`。

- [ ] **Step 1: 写失败测试**：
  - Channel：`set_view` 能解析成 `ChannelCommand.setView`，缺参数报错；`"set_view"` 在 `known` 里。
  - EmbeddedSession（假 link）：`setView(window: 1, rect: 内容的四分之一, zoom: 2)` 发出 `.setView`，随后发一次 `.setStream`，密度等于 `viewDensity(...)`；`setView(window: 0, …)` 后密度回到 `captureDensity(zoom: 1, …)`；同一取景再发一次不重发 `setStream`（1 % 规则）。
  - WindowSurfaces：整窗一帧后 `base(id)` 不为空；随后一帧只覆盖局部，`base(id)` 仍是前一张整窗的；窗口大小变化后第一帧（局部）`base(id) == nil`；`keep(only: [])` 后为空。
- [ ] **Step 2:** `swift test --filter RappSessionTests` → FAIL。
- [ ] **Step 3:** 实现以上；SessionPlugin 改完用 `scripts/build-ios.sh` 的模拟器或设备构建确认编译（不安装），macOS 跑 `cd gui && flutter build macos --debug` 确认编译。
- [ ] **Step 4:** `swift test` → 全过；两个构建成功；还原 lockfile。
- [ ] **Step 5:** 提交 `feat(session): set_view, the zoom's density and a base picture per window`。

### Task 5: 共用的触摸识别器

**Files:**
- Create: `gui/lib/embed/touch_gestures.dart`
- Modify: `gui/lib/platform_caps.dart`（`bool get pinchZoom => defaultTargetPlatform == TargetPlatform.iOS;`）
- Test: `gui/test/embed/touch_gestures_test.dart`（新建）

**Interfaces:**
- Produces（Task 6、8 用）：

```dart
/// What fingers mean on a picture and on a terminal alike (pinch-zoom spec §6.2): one recognizer for both.
abstract interface class TouchSink {
  void press(PointerDownEvent e);           // a finger press now; `e` is the finger's down event
  void drag(PointerMoveEvent e);            // the pressed finger moved
  void release(Offset at, PointerEvent e);  // the pressed finger lifted or was cancelled; a tap's `at` is where it landed
  void scroll(Offset centre, Offset delta); // two fingers' centre moved (one call per event batch, T3), logical px
  void rightTap(Offset at);                 // T8
  void twoDown(Offset centre);              // a second finger landed (T7: take focus)
  void pan(Offset delta);                   // move the view
  void zoom(double z, Offset focal);        // the zoom is now z (unclamped), about focal
  void settled();                           // all fingers up after a pan or a zoom (and a trackpad zoom's end)
}

class TouchGestures {
  TouchGestures({required TouchSink sink, required double Function() zoom,
      required bool Function(Offset local) inside, bool zoomable = false});
  void down(PointerDownEvent e);   // touch only
  void move(PointerMoveEvent e);
  void up(PointerEvent e);          // PointerUpEvent or PointerCancelEvent
  void panZoomStart(PointerPanZoomStartEvent e);
  void panZoomUpdate(PointerPanZoomUpdateEvent e); // only the scale part; the pan part stays the widget's
  void panZoomEnd(PointerPanZoomEndEvent e);
  void reset();                     // drop everything in flight, emit nothing
  void dispose();
}
```

常量（文件顶部，具名）：`touchSlop = 8.0`、`touchHold = 150 ms`、`zoomedHold = 500 ms`、`pinchSlop = 12.0`、`twoTapTime = 250 ms`、`twoTapSlop = 8.0`。

规则（照 spec §6.2 和现在 `picture.dart` 的 T1–T8）：
- `z == 1`：单指落在 `inside` 里先挂起；150 ms 到或移动超过 8 → `press`，之后 `drag`；挂起中抬起 → `press` + `release(落点)`；挂起中取消 → 什么也不发（T6）。落在 `inside` 外 → 立刻 `press`（让画面去失焦）。
- `z > 1`：挂起；移动超过 8 → 平移模式，先 `pan(累计位移)`，之后每次移动 `pan(位移)`，抬起 `settled`；500 ms 不动 → `press`，之后是 `drag`；没动就抬起 → `press` + `release(落点)`。
- 已经 `press` 了的手指还按着时，其他手指落下一概不理（T2）。
- 第二根手指落下（第一根在挂起或平移中）：丢掉挂起，`twoDown(中心)`，进入双指判定。中心离起点 ≤ 8 期间：`zoomable` 且两指距离变化先超过 12 → 捏合（直到所有手指抬起）；中心先超过 8 → 滚动，把缓存的位移一次发出，之后按 T3 合批 `scroll`。三根以上同 T5。所有手指抬起：没判定、250 ms 内抬起 → `rightTap(起点中心)`；捏合过 → `settled`。
- 捏合中每批移动：`zoom(开始倍数 × 当前距离 ÷ 开始距离, 当前中心)`，再 `pan(中心位移)`。
- 触控板：`zoomable` 且 `e.scale != 1` → `zoom(开始倍数 × e.scale, e.localPosition)`；`panZoomEnd` 时缩放过 → `settled`。
- `zoomable == false` 时永远判不成捏合，触控板不缩放（macOS、Linux 不变）。

- [ ] **Step 1: 写失败测试**（`testWidgets` + `tester.pump(时长)` 推进计时器；用一个记录调用的 `TouchSink` 假件；事件用 `PointerDownEvent(kind: PointerDeviceKind.touch, pointer:, position:, timeStamp:)` 构造）：
  - `holds a touch 150 ms then presses`（T1）
  - `a move past 8 before 150 ms presses then drags`
  - `a quick tap is press and release where it landed`
  - `a cancelled held-back touch sends nothing`（T6）
  - `a finger outside presses at once`
  - `two fingers moving together scroll after 8 px, buffered moves first`（T3）
  - `a quick two-finger tap is a right tap at the start centre`（T8）
  - `a third finger is ignored while scrolling`（T5）
  - `a second finger while the first is pressed is ignored`（T2）
  - `two fingers spreading 12 px pinch: zoom with start × ratio, pan by centre move, settled at the end`
  - `not zoomable: spreading fingers scroll, never zoom`
  - `zoomed: a one-finger drag pans and never presses; settled on lift`
  - `zoomed: holding 500 ms presses, then drags; release on lift`
  - `zoomed: a tap between 150 and 500 ms is press and release`
  - `zoomed: a second finger while panning starts a two-finger gesture`（Review Focus 2）
  - `zoomed: a second finger 200 ms after the first (still held back) can pinch`（Review Focus 2）
  - `trackpad scale zooms when zoomable, not otherwise; end settles`
  - `reset drops a held-back press`
- [ ] **Step 2:** `cd gui && flutter test test/embed/touch_gestures_test.dart` → FAIL（文件不存在）。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 同一命令 → PASS；`flutter analyze lib/embed/touch_gestures.dart lib/platform_caps.dart` 无问题。
- [ ] **Step 5:** 提交 `feat(gui): one touch recognizer for the picture and the terminal`。

### Task 6: `picture.dart` 改用识别器（不改行为）

**Files:**
- Modify: `gui/lib/embed/picture.dart`（删掉 `_touches`、`_pending*`、`_touchScroll`、`_two*`、`_scrollAcc/_scrollAt/_scrollQueued`、`_touchDown`、`_flush`、`_dropPending`、`_touchScrollBy` 和 `_move/_up` 里的触摸分支；`_PictureState` 实现 `TouchSink`）

**Interfaces:**
- Consumes: `TouchGestures`、`TouchSink`（Task 5）。此任务 `zoom: () => 1`、`zoomable: false`；`pan`、`zoom`、`settled` 暂为空。

映射：`press` → 现在的 `_press(e)`；`drag` → 现在的鼠标拖动路径（`_held` + `clampTo`）；`release(at, e)` → 现在的松开路径；`scroll` → `_scroll(centre, panToRemote(delta))`；`rightTap` → 现在的 `_twoTap` 内容；`twoDown` → 中心在画面上时 `_focus.requestFocus()` + `focusPicture`（T7）；`inside` → `_at(p).usable && _at(p).pic.contains(p)`。`didUpdateWidget` 里冻结、换窗口、换会话时调 `reset()`；`dispose` 调 `dispose()`。鼠标、滚轮、触控板滚动的路径一行不动。

- [ ] **Step 1:** 先跑 `cd gui && flutter test test/ui/stage_test.dart test/embed/focus_gray_test.dart test/embed/app_key_row_test.dart` 记下全过的基线。
- [ ] **Step 2:** 重构。
- [ ] **Step 3:** 同一命令 → 全过，**测试文件一行不改**（`git diff --stat -- gui/test` 为空）。
- [ ] **Step 4:** 提交 `refactor(gui): the picture's touch rules come from the shared recognizer`。

### Task 7: 取景状态和 `setView` 的时机（Dart）

**Files:**
- Create: `gui/lib/embed/zoom_view.dart`（`ZoomView`、`ViewLink`、`viewRange`、`viewFactor`）
- Modify: `gui/lib/embed/remote_session.dart`（每窗口的 `ZoomView`、`ViewLink`、`ReadyEvent` 重发、`WindowsEvent` 扔掉不在表里的、`adoptZoom`）
- Modify: `gui/lib/ui/main_state.dart`（`_dropOld` ~1721：`to?.adoptZoom(gone)`，和 `composer.adoptFrom` 一起）
- Modify: `gui/lib/embed/session_port.dart`（`SessionPort.setView`；`RemoteWindow.baseTexture` 从 `"base"` 解析）
- Modify: `gui/lib/embed/linux_session_port.dart`（`setView` 空实现）
- Test: `gui/test/embed/zoom_view_test.dart`（新建）、`gui/test/embed/remote_session_test.dart`

**Interfaces:**
- Produces（Task 8、9、10 用）：

```dart
class ZoomView extends ChangeNotifier {
  static const maxZoom = 4.0;
  double get z;                 // 1–4
  Offset get centre;            // the content point at the stage's centre, 0–1 of the content; (0.5, 0.5) at first
  bool get zoomed;              // z > 1
  bool get restoring;           // the 200 ms back to 1
  bool get backdrop;            // zoomed, restoring, or within 1 s after a restore ended (§6.4)
  Rect zfit(Rect fit, Size stage, {double keyboard = 0});
  void zoomTo(double z, Offset focal, Rect fit, Size stage, {double keyboard = 0});
  void panBy(Offset delta, Rect fit, Size stage, {double keyboard = 0});
  void restore();               // to z 1 in 200 ms on frame callbacks, centre kept; notifies each frame
  void adopt(ZoomView other);   // z and centre, no animation
}

Rect viewRange(Rect seen, Size content);             // seen + 25 % of its width / height on each side, inside the content
double viewFactor(double z, Rect range, Size content); // min(z, √(content area ÷ range area))

class ViewLink {
  ViewLink(void Function(int window, Rect rect, double zoom) send);
  void settled(int window, Rect seen, Size content, double z);
  void unlimited();
  void resend();
}

// RemoteSession
ZoomView zoomOf(int id);        // made on first use
ZoomView? zoomIfAny(int id);
Listenable get zooms;           // notifies when any of its ZoomViews does
bool get currentZoomed;         // zoomIfAny(currentWindow)?.zoomed == true
void restoreCurrent();          // zoomIfAny(currentWindow)?.restore(); then view.unlimited()
final ViewLink view;
void adoptZoom(RemoteSession old);

// SessionPort
void setView(Object sid, int window, Rect rect, double zoom); // _send('set_view', {sid, window, x, y, w, h, zoom})
// RemoteWindow
final int? baseTexture;
```

`zfit`：`z == 1` → `fit`。否则 `w = fit.width × z`、`h = fit.height × z`，`left = stage.width / 2 − centre.dx × w`、`top = stage.height / 2 − centre.dy × h`（以舞台中心为锚，键盘不让它自动挪），再夹住：`left ∈ [min(0, stage.width − w), max(0, stage.width − w)]`，`top ∈ [min(0, stage.height − keyboard − h), max(0, stage.height − h)]`。`zoomTo` 先把 z 夹进 1–4，保持 `focal` 下的内容点不动，用新矩形反推 `centre`；`panBy` 平移后按夹住的矩形反推 `centre`（不在边上累积）。

`ViewLink.settled`：`z == 1` → `unlimited()`。否则 `range = viewRange(seen, content)`；上次发的是同一窗口、`seen` 在上次的 `range` 里、且 `viewFactor` 相对上次变化 ≤ 10 % → 不发；否则发 `(window, range, z)` 并记下。`unlimited()`：上次发的是有范围的才发 `(0, Rect.zero, 1)`。`resend()`：上次有范围就原样再发。macOS、Linux 上从不会有 `z > 1`，所以从不发。

`RemoteSession.apply`：`ReadyEvent` → `view.resend()`；`WindowsEvent` → 扔掉 id 不在新表里的 `ZoomView`。

- [ ] **Step 1: 写失败测试**（`zoom_view_test.dart`，舞台 `1000×700`，`fit = fitRect(Size(800, 600), stage)`）：
  - `z 1 is fit`；`zoomTo clamps to 1–4`；`zoomTo keeps the point under the focal`（放大前后 focal 下的内容分数相等，误差 1e-6）。
  - `pan stops at the stage edges`：大力 `panBy` 后 `zfit.left == stage.width − zfit.width` 或 `0`。
  - `the keyboard lowers the top bound, never moves the view`：`keyboard: 300` 时可 `panBy` 到 `zfit.bottom == 400`，不 `panBy` 时 `zfit` 和不带键盘相同。
  - `a stage resize keeps z and centre`：换成 `700×1000` 后 `z`、`centre` 不变，`zfit` 仍在限位内（Review Focus 4）。
  - `restore reaches 1 in 200 ms`（`tester.pump` 推帧）；`backdrop` 在之后 1 s 内为真、1 s 后为假。
  - `viewRange`：`seen (100, 100, 200, 100)`、内容 `800×600` → `(50, 75, 300, 150)`；靠边时夹在内容内。
  - `ViewLink`：首次 `settled` 发；`seen` 在范围里、倍数不变 → 不发；`seen` 出了范围 → 发；倍数从 2 到 2.1（变化 < 10 %）不发、到 2.5 发；`z == 1` → 发一次 `(0, Rect.zero, 1)`，再一次 `unlimited()` 不发；`resend()` 重发上次有范围的。
  - `remote_session_test.dart`：`ReadyEvent` 后重发；窗口从表里消失后 `zoomIfAny(id) == null`；`adoptZoom` 搬过 `z` 和 `centre`（Review Focus 3）；`RemoteWindow` 从载荷 `"base": 5` 解析出 `baseTexture == 5`，没有时为 null。
- [ ] **Step 2:** `cd gui && flutter test test/embed/zoom_view_test.dart test/embed/remote_session_test.dart` → FAIL。
- [ ] **Step 3:** 实现；`main_state.dart` 的 `_dropOld` 里加 `to?.adoptZoom(gone)`，并在 `main_state_test.dart` 里加一条：重连交换后新会话的当前窗口仍是同一倍数。
- [ ] **Step 4:** 同一命令加 `test/ui/main_state_test.dart` → PASS。
- [ ] **Step 5:** 提交 `feat(gui): per-window zoom state and when to ask A for a view`。

### Task 8: App 画面的缩放

**Files:**
- Modify: `gui/lib/embed/picture.dart`
- Modify: `gui/lib/ui/stage.dart`（`Picture(..., keyboard: keyboardLift(MediaQuery.of(context), fullscreen: fullscreen))`，两处 ~120、~149）
- Test: `gui/test/ui/stage_test.dart`（新增用例，原有用例不改）

**Interfaces:**
- Consumes: `TouchGestures(zoomable: pinchZoom)`（Task 5），`ZoomView`、`ViewLink`、`RemoteWindow.baseTexture`（Task 7）。
- Produces: `Picture` 新参数 `final double keyboard`（默认 0）。

内容：
- `build` 里 `fit` 之后算 `zfit = zoom.zfit(fit, stage, keyboard: widget.keyboard)`，之后所有用 `fit` 的地方（`pictureRect`、`popupRect`、`fromRemoteRect`、`_inputMark`、`_Target`）改用 `zfit`；整个 `Stack` 外加 `ClipRect`。`zoom = widget.session.zoomOf(widget.window.id)`，监听它重建。
- 底图：`zoom.backdrop && win.baseTexture != null && win.visible` 不是整窗时，在实时纹理下面先画 `Texture(textureId: win.baseTexture!)` 铺满 `zfit`。
- 识别器 `zoom: () => zoom.z`，`zoomable: pinchZoom`；`pan` → `zoom.panBy`；`zoom` → `zoom.zoomTo`（`fit`、`stage` 取最近一次布局）；`settled` → 重启一个 150 ms 计时器，到点调 `_sendView()`。
- `_sendView()`：`seen` = `Rect(0, 0, stage.width, stage.height − keyboard)` ∩ `zfit` 换算到内容坐标（A 的点）；`session.view.settled(win.id, seen, contentSize(win), zoom.z)`。
- 挂上后第一次布局完、换了窗口（`didUpdateWidget`）时：`_sendView()`（1 倍时它自己发「不限范围」）。`dispose` 和换会话时：对旧会话调 `view.unlimited()`（Review Focus 5）。
- 触控板：`onPointerPanZoomStart/Update/End` 先交给识别器的 `panZoom*`，原来的滚动处理照旧。

- [ ] **Step 1: 写失败测试**（`stage_test.dart`，`debugDefaultTargetPlatformOverride = TargetPlatform.iOS`，假 port）：
  - `pinch zooms and sends nothing to A`：两指张开后 `zoomOf(id).z > 1`，`calls` 里没有 `mouse`、`scroll`。
  - `zoomed tap lands where it shows`：捏到 2 倍后轻点某点，`mouse` 的坐标等于 `toRemote(点, zfit, win)`。
  - `zoomed drag pans only`；`zoomed hold 500 ms then drag sends down, drag, up`；`zoomed two-finger move scrolls`。
  - `setView 150 ms after the fingers lift, not during`：手势中 `calls` 里没有 `set_view`；抬起 149 ms 没有、151 ms 有一次，`window` 是当前窗口。
  - `back to 1 sends the unlimited view`。
  - `switching tab sends unlimited for an unzoomed window and the view for a zoomed one`；`leaving the stage (overview) sends unlimited`（Review Focus 5）。
  - `the base texture is drawn under the live one only while zoomed`：载荷带 `base` 时，放大且 `visible` 是局部 → 找得到 `Texture(textureId: base)`；1 倍时找不到。
  - `macOS: pinch never zooms`（不设 iOS 覆盖，两指张开 → 发 `scroll`，`z == 1`）。
- [ ] **Step 2:** `cd gui && flutter test test/ui/stage_test.dart` → 新用例 FAIL、旧用例 PASS。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** `cd gui && flutter test` → 全过；还原 lockfile。
- [ ] **Step 5:** 提交 `feat(gui): pinch zoom on the app picture, asking A for only what shows`。

### Task 9: 终端的缩放

**Files:**
- Modify: `gui/lib/term/term_stage.dart`
- Modify: `gui/lib/ui/stage.dart`（`TermStage(..., keyboard: …)`）
- Test: `gui/test/term/term_stage_test.dart`

**Interfaces:**
- Consumes: `TouchGestures`、`TouchSink`（Task 5），`RemoteSession.zoomOf`（Task 7）。
- Produces: `TermStage` 新参数 `final double keyboard`（默认 0）。

内容：
- `_onDown` 的主键部分抽成 `_pressAt(Offset local, Duration time, int pointer)`，`_onMove` 抽成 `_dragTo(Offset local, int pointer)`，`_onUp` 抽成 `_release(int pointer)`；鼠标事件照旧走它们，触摸事件先做 `_onDown` 开头的聚焦、`blurPicture`、`_stopFling`，再交给识别器。
- `TouchSink` 映射：`press` → `_pressAt`；`drag` → `_dragTo`；`release` → `_release`；`scroll` → `_scroll(delta.dy / _zoomed.cellH)`（和触控板 `_onPanUpdate` 同号）；`rightTap` → 无；`twoDown` → `_focus.requestFocus()`；`pan` / `zoom` → `ZoomView`；`settled` → 无（终端不发消息）。`inside` 恒为真。
- 缩放：`fit = Rect.fromLTWH(0, 0, m.cols × _drawn.cellW, m.rows × _drawn.cellH)`；`zfit = zoom.zfit(fit, stage, keyboard: widget.keyboard)`；`_zoomed = _measured(_drawn.style.fontSize! × zoom.z)`（1 倍时就是 `_drawn`）；格子按 `_zoomed` 画在 `zfit.topLeft`，外加 `ClipRect`；`Listener` 在裁剪外面，收到的坐标是舞台坐标。
- `_cellAt(local)` 先减 `zfit.topLeft`，再按 `_zoomed` 的格子算。C1 的上下边改用 `Rect(0, 0, w, h − keyboard) ∩ zfit` 的上下边。
- `_queueView` 那一行**不动**（仍按 `_metrics` 的格子算行列）。
- 触控板捏合交给识别器 `panZoom*`，平移滚动照旧。

- [ ] **Step 1: 写失败测试**（iOS 覆盖）：
  - `two fingers moving together scroll back through history`（`m.offset` 变大）。
  - `one finger held 150 ms then dragged still selects`。
  - `zoomed: a one-finger drag pans, never selects`；`zoomed: hold 500 ms then drag selects`。
  - `zoomed: a tap hits the cell it shows`：2 倍并平移后轻点，`_cellAt` 命中的格子（经选区或链接测试可观察的结果）等于按 `zfit` 和放大格子算出的那格。
  - `zooming never changes the requested rows and columns`：捏到 3 倍后 `term` port 收到的 view 行列和之前一样（或没有新的 view 请求）。
  - 现有鼠标拖选、滚轮、触控板测试不改、全过。
- [ ] **Step 2:** `cd gui && flutter test test/term/term_stage_test.dart` → 新用例 FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** `cd gui && flutter test test/term` → 全过；还原 lockfile。
- [ ] **Step 5:** 提交 `feat(gui): pinch zoom on the text terminal, the same gestures as the picture`。

### Task 10: 「还原」按钮

**Files:**
- Modify: `gui/lib/embed/composer_panel.dart`（`composerLayer` 里 `Key('composer-open')` 那一行的 `Positioned`）
- Test: `gui/test/embed/composer_panel_test.dart`

**Interfaces:**
- Consumes: `RemoteSession.zooms`、`currentZoomed`、`restoreCurrent()`（Task 7）。

规则：`listenable` 再并上 `session.zooms`。`zoomed = session.currentZoomed && !session.composer.open`。整行隐藏的条件改成 `(session.composer.open && button) || (transfer == null && !button && !zoomed)`（Ruling：「输入」不允许时「还原」也照样出现，否则那种会话放大了就只能捏回去）。行里 `if (button)` 的「输入」前面，`if (zoomed)` 放「还原」，中间 `SizedBox(width: 8)`。按下 → `session.restoreCurrent()`。

- [ ] **Step 1: 写失败测试**：
  - `zoom-reset shows only while the current window is zoomed`：`zoomOf(current).zoomTo(2, …)` 后 `find.byKey(Key('zoom-reset'))` 找到一个，且在 `composer-open` 左边；1 倍时找不到。
  - `zoom-reset restores and sends unlimited once`：先让 `view` 发过一次有范围的，点按钮 → 200 ms 后 `z == 1`，`calls` 里多一次 `set_view` 且 `window == 0`。
  - `hidden while the writing panel is open`。
  - `terminal: zoom-reset restores the terminal's zoom and sends nothing`（用 `TermSessionPort` 的假件）。
- [ ] **Step 2:** `cd gui && flutter test test/embed/composer_panel_test.dart` → FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 同一命令 → PASS。
- [ ] **Step 5:** 提交 `feat(gui): 还原 beside 输入 while zoomed`。

### Task 11: 文档、全套测试、iOS 构建

**Files:**
- Modify: `docs/superpowers/specs/2026-11-17-rapp-ipad-duo-design.md`（§8.1 "常规档里远程画面和舞台一样大，不做捏合缩放" 改成指向本规格；§7.5 「看 / 点」切换钮一句改成"按 `2026-11-18-rapp-pinch-zoom-design.md` 的手势，不做切换钮"）
- Modify: `docs/superpowers/specs/2026-11-18-rapp-pinch-zoom-design.md`（状态改成"已实现，待真机验收"；§9 写明底图的实际做法）
- Modify: `tasks/todo.md`（加真机验收 1–8 一项）

- [ ] **Step 1:** 改文档。
- [ ] **Step 2:** 全套：`swift test`；`cd gui && flutter analyze && flutter test`；`cd rust && cargo test && cargo clippy --all-targets -- -D warnings`。Expected: 全过（`rapp-hub-ffi` 的 clippy 若仍是已知的 `not_unsafe_ptr_arg_deref`，照实记下，不在本分支修）。
- [ ] **Step 3:** `scripts/build-ios.sh device` 构建成功（不安装）；还原 lockfile。
- [ ] **Step 4:** 提交 `docs: pinch zoom replaces the iPad spec's no-zoom line; acceptance in todo`。
