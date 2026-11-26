# 计划 B 任务 13–19 草稿笔记（host-core 会话部分）

分支 `feat/windows-host-core`。这批全是草稿：**一行都没编译过，一个测试都没跑过**。没有运行过 cargo、swift、rustc、rustfmt、clippy、flutter。

计划：`docs/superpowers/plans/2026-11-26-rapp-windows-b-host-core.md`（windows-design 工作树，含 48b5c6eb 的改正）。Swift 源码是标准；计划和 Swift 不一致时，代码按 Swift 写，并记在 §4。

## 提交

| 提交 | 内容 |
|---|---|
| a81f1f81 | 第 2 步：编码组和规则组的共享类型对齐（见下） |
| d0f2aad6 | 任务 13：平台接口、server、握手、接管；testkit 里的假平台和 harness |
| 54665da7 | 任务 14：采集、编码、发送循环，含暂停、视图和省流 |
| 43d93a0d | 任务 15：输入、遮挡、焦点区、状态规则接进会话 |
| 55da1ba5 | 任务 16：剪贴板、粘贴、文件传输 |
| 90f30db9 | 任务 17：锁屏状态和解锁 |
| 5249fde3 | 任务 18：`PORTING.md` 对照表和摘要，带检查测试 |
| 46c89cb9 | 任务 19：`fake-host-core` 程序和服务契约测试 |
| （本文件） | 笔记 |

### 第 2 步（a81f1f81）改了什么

- `resolve_regions` 改为接收整个规则包，和 Swift 的 `resolveRegions(_:in:)`（Regions.swift:5）一致。只遍历表的版本留在 crate 内部，给 SignalEvaluator 的内联区域用。改动在 `state/regions.rs`、`state/engine.rs`、`state/detectors.rs` 和 `tests/state_rules.rs`。
- `clipboard.rs` 的分块大小、旁路连接数、内联粘贴上限和剪贴项上限，改为重新导出 protocol 里的常量，不再自己定义第二份。
- `hints::opens_things` 改为匹配元组变体 `Message::Text(_)`。
- 核对过、本来就一致的：
  - `geometry::Rect {x,y,width,height: f64}`，和 tile.rs 的假设一致；
  - `EncodeReport` 的字段和 `TILE_SIZE`，和 focus/pane.rs 的用法一致；
  - `APP_STATE_LIMIT`、`CanvasRect {x,y,w,h}`、`WindowInfo` 的字段、`ClipInfo`/`ClipKind`、`CodecError::new`、`constant_time_equals`、`DEFAULT_PORT`、`PROTOCOL_VERSION`；
  - lib.rs 重新导出的 `Password` 和 `InflateStream` 都有定义。

## 1. 写了什么

- **任务 13（写完）**
  - `platform.rs`：Platform 及其各个 ops trait、Permissions、OpenError。
  - `run.rs`：唯一入口 `run(args, env, platform, WorkerIo, clock) -> i32`，还有 Output（日志写 stderr，JSON 事件和结果写 stdout，退出事件之后不再写任何东西）。
  - `session/{server,intake,session,tracker,mod}.rs`：
    - 一个 accept 循环；
    - 每条连接一个读线程；
    - 一个会话线程拥有全部状态，用 `Session::post` 投递任务；
    - 握手、5 秒静默断开、接管（taken over by N）、kick/quit/peer/yield、stdin EOF 时退出码 0。
  - 消息分派是没有通配分支的 `match`，和 `DISPOSITION` 一致。
  - testkit：`fake_platform.rs`（脚本化的假平台，919 行）和 `host_harness.rs`（Host、Controller、ScaledClock，SPEED 20）。
- **任务 14（写完）**：`session/capture.rs`。
  - 采集线程，在采集线程上量化。
  - 容量为 1 的槽，新帧覆盖旧帧。
  - `PacedSender` 发帧和 ack；`setStream` 设置 mode/fps/density，fps 为 0 时暂停。
  - 暂停期间每秒发 `changed`，恢复后第一帧是差分帧（48b5c6eb）。
  - 窗口 10 Hz 轮询，`windows` 只在有变化时重发；还有省流阶梯和 stats 事件。
- **任务 15（写完）**
  - `session/input.rs`：
    - 输入闸门和 yield；
    - 文字按 20 个单元一块、每块间隔 5 ms；
    - key/mouse/scroll 的坐标按窗口点换算；
    - HeldInput，会话结束时释放；
    - `inputBlocked` 最多每 0.5 秒一次，`input`/`input_blocked` 事件最多每 0.25 秒一次；
    - focus/close/move/resize；
    - 输入法上报和 `selectInput`。
  - `session/hints.rs`：
    - covered（每个遮挡每 5 秒一次）和 dismissCover；
    - appOpened、secureFocus；
    - 焦点区：FocusTracker，经 QueryCoalescer 和 QueryDeadline 调用 `focus_chain`，回 `focusRegion`；
    - 状态规则：`stateRules` 交给 StateEngine，每 0.5 秒一拍，回 `appState`。
- **任务 16（写完）**
  - `session/clip.rs`：
    - 剪贴板监视线程，每 0.3 秒一次；
    - 粘贴工作线程和 PasteSession：存旧内容、写入、激活目标、等它到前台、`paste_key`、0.15 秒后回 `pasted`、约 2 秒后恢复旧内容；
    - 各条固定错误文案。
  - `session/side.rs`：fetch/put 旁路连接，每条各一个线程，最多 4 条；256 KiB 分块；用 `.rapp-part` 续传；传输事件带 `a_to_b`/`b_to_a`。
  - 会话测试 11 个。
- **任务 17（写完）**
  - `session/unlock.rs`：密码在独立线程上输入，持有跨 worker 的 `unlock.lock`。
  - 会话结束后不再输入。
  - 锁屏开始的会话先宣布主屏画布，再每秒轮询一次。
  - lock 命令。
  - 临时的 `stage.rs` 已删除。
  - 会话测试 8 个，其中有 `password_never_leaves`。
- **任务 18（写完）**
  - `rust/host-core/PORTING.md`：
    - 第 1 部分 102 行，覆盖 `Sources/rapp-host` 的全部 3830 行；
    - 第 2 部分列出 RappCore 的 44 个文件；
    - 第 3 部分是 64 个文件的 SHA-256；
    - 第 4 部分列出不按字节对齐的地方。
  - `tests/porting.rs` 检查三件事：摘要是最新的；每行写的测试都真实存在；每一行 Swift 都有对应。
  - 审计时补了 3 个会话测试：桌面会话、输入法、窗口命令。
- **任务 19（步骤 1、2、5 写完；步骤 3 未运行；步骤 4 需要手工）**
  - `testkit/src/bin/fake_host_core.rs` 和 `[[bin]] fake-host-core`。
  - `tests/common/mod.rs` 的 `bins_with_host(program)`。
  - `tests/host_service.rs` 有两个测试：
    - `service_lists_starts_and_stops_host_core`：真的 rapp-service 解析 `list-apps --json`，`open` 等到 `listening` 才回 ok，B 的 hello 收到 ready，空闲 200 ms 后关 stdin，`worker_exit` 的 code 为 0、reason 为 `stdin closed`；
    - `an_unknown_app_starts_a_worker_that_refuses_the_hello`。

## 2. 没写的和原因

- **任务 19 步骤 4（真 Mac 控制端手工检查）**：要在真机上运行 `fake-host-core serve --app fake.app --port 47811 …`，用 `swift run rapp-client` 连上去，截图核对 5 种模式、滚动、打字计数和粘贴文件的 SHA-256。这一步只能手工做，本批没有做。
- 任务 19 步骤 3 和所有 “Run” 步骤：按规则不编译、不运行。
- Swift 生成的夹具不在工作树里，比如 `rust/host-core/tests/fixtures/focus-pane.json` 和其他 `*.json`/`*.bin`。要用 `RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'` 生成。
  - 缺夹具的测试会 panic，并提示这条生成命令。
  - 焦点区的会话测试改为用 `focus::panel` 算期望值，允许 ±8 点。
- FocusReader 的 roles 和其他属于平台的部分（FocusReader 105-216、InputInjector 220-233、InputSourceWatcher 17-68、SecureFocusWatcher 66-110、WindowCapture 126-164）：这些是阶段 D 的 host-windows，在 PORTING.md 里标了 “phase D”。
- VisionText OCR、MenuBarReader，以及 Server 488-505、1249-1265：Windows 上没有，PORTING 里标了 not on Windows。
- Timeout.swift：没有移植。Rust 用 clock 和 recv_timeout。
- **任务 20 步骤 4、5（第四批写了）**：
  - `tasks/todo.md` 末尾新增「Windows B 段（主机核心）」：D 段的 5 项实机检查，加一行给发版 session。
  - 「B 段交接」按计划 :743 应该追加到探针结果页，可这一页（`docs/superpowers/specs/2026-11-26-rapp-windows-probe-results.md`）还不存在。所以先写在 `rust/host-core/PORTING.md` 第 5 部分，探针结果页建好后搬过去，PORTING 里留一个链接就行。
  - 第 5 部分在第 4 部分后面，`tests/porting.rs` 只解析第 1、3 部分，加这一部分不影响检查。

## 3. 名字和签名与计划 B 不同的地方（全部）

任务 13
- 客户端发来不该发的消息时，文案是 `unexpected message from client`（Server.swift:538），不是计划写的文案。
- `OpenError::NotFound` 的文案是 `<id> not found`（spec §6.4）。
- `secure-helper` 子命令在 core 里报 “not available on …”，由 Windows 自己的 main 处理。
- 新增了 `session/tracker.rs`。
- Event 枚举和计划不同；`Event::Frame` 改名为 `FrameReady`。
- takeover 和 stop 最多等 2 秒的 ack。
- yield 测试通过 `input` 事件确认输入被接受。
- 输入法每 0.25 秒轮询一次。
- menuPick 走闸门（和 Swift `Server.swift:415` 一样），过了闸门就按 Swift“A 已经没有这个菜单项”的分支只写一行日志（`:490-494`），不回 B 任何消息，会话继续（第四批补上）。

任务 14
- 用容量为 1 的槽代替 sync_channel。
- 在采集线程上量化。
- 没有加 `Session::tables()`，第四批也不加：计划说它给任务 15 用，可任务 15 的代码就在 `session` 模块里，直接读 `self.table`、`self.raw`。加一个公开访问器只会把会话内部状态露出去，没有调用方。
- resize 留到任务 15 做。
- fps 不取整到档位：查过 Swift，它也不取整。协议解码只收 30/15/5/1（setStream 还收 0，表示暂停；Protocol.swift:676-684），省流梯子把上限压到 min(上限, 5)。Rust 的 `.max(1)`（capture.rs 两处）只是防御，到不了。第四批加了测试 `set_stream_fps_must_be_a_tier`：合法档位会话照常，fps 7 以 `bad data from client: fps must be 30, 15, 5, 1 or 0` 结束会话。
- harness 新增 `auto_ack`、`frames`、`last_frame`、`hello_at`。
- 假平台新增 `frame_calls`、`set_frame_size`、`set_scale`。

任务 15
- 新增 `session/input.rs` 和 `session/hints.rs`。
- 窗口操作返回 ()，所以没有 “could not move a window” 日志（Swift 在 Server.swift:484-486 有）。
- covered 的名字来自 `screen()`，bundle 来自 `ControlOps::cover_at`。
- 遮挡关闭的日志不带 `: detail`。
- FocusReader 的 roles 拿不到：start 记 “-”，picked 记 `depth<n>`，depth 用链的长度。
- locale 用 “en” 或 `RAPP_LOCALE`。
- secure、appOpened、keyboard_changed 改为 0.1 秒定时器轮询，不用观察者。
- key 和 text 用焦点窗口中心去问 `blocked_by`。
- capture 的 `latest` 改为 `Arc<Frame>`；新增 `SharedText` 包装。
- `yield_blocks_then_releases` 和已有的 yield 测试有重叠。
- 假平台新增 `set_focus_delay`。
- appState 测试检查 pack/rev/inferred/health，不和整份夹具比。

任务 16
- `route` 返回 `Option<SideConnection>`；新增 `TransferSlot`。
- 粘贴写入期间一直持有 store 锁。
- `png_size` 读 IHDR。
- 假平台在锁屏时拒绝 activate。
- 测试比较字节，不算 SHA-256。
- `CLIP_NAME_LIMIT` 为 1024。
- “target not frontmost” 补了测试（第四批）：`paste_when_the_target_stays_behind_fails_with_the_fixed_text`。假平台新增 `set_stays_behind`，打开后 `activate` 不把程序带到最前；测试同时查目标在后面时的复制不宣布（`host_copy_is_announced` 里原来也有这一段）。

任务 17
- 会话的 `is_locked` 闭包同时检查会话的 `alive`。
- 解锁在名为 “rapp-host unlock” 的 std 线程上运行。
- 密码在这个线程上转成 `Zeroizing` 的 UTF-16 单元，用完立即丢弃。
- 线程起不来时把 `unlocking` 复位，并记一行日志。
- 假平台新增 `set_lock_error`，`FakeLock::lock` 可以失败。
- `can_unlock` 为 false 的分支来自计划和 spec，Swift 没有这个分支。
- lock 命令在 run.rs 里本来就有。
- 锁屏开始时宣布主屏画布（见 §4）。

任务 18
- 新增 3 个测试：`desktop_session_shows_the_main_display`、`input_source_is_reported_and_selected`、`window_commands_reach_the_platform`。
- 保持唤醒按 Swift 接上（第四批）：会话里有一个 `lock::StayAwake`，用一个专用的锁句柄调 `LockOps::stay_awake`，在合法 hello 时 `begin()`、结束时无条件 `end()`。原来的草稿把 `stay_awake(true)` 发到 `self.lock`，可打开目标后 `self.lock` 换成了目标的句柄，结束时的 `stay_awake(false)` 落在另一个句柄上；Windows 的执行状态跟线程走，这样会关不掉。假平台现在按句柄记保持，测试 `stay_awake_spans_the_session`（程序和桌面两种）、`a_refused_hello_never_holds_a_awake`。PowerHold 的两行日志由 host-core 写；`stay_awake` 没有返回值，“could not keep A awake” 这一行没法对应。
- Timeout.swift 没移植。
- sha2 本来就是 dev-dependency，Cargo.toml 没改。
- 摘要测试跳过点开头的隐藏文件。

任务 19
- 计划写 `rapp_host_core::run(...)`。第四批在 lib.rs 里加了 `pub use run::{run, WorkerIo};`，两种写法都能用（模块 `run` 和函数 `run` 不在同一个命名空间）；harness 和 `fake_host_core.rs` 仍写 `rapp_host_core::run::{run, WorkerIo}`，不用改。
- stdin 外面包了一层 `BufReader`，因为 `WorkerIo.stdin` 要求 `BufRead + Send`（run.rs:24）。
- “停止共享” 用的是服务的空闲关闭：worker_idle 设为 200 ms，会话结束后服务关掉 stdin。测试没有走 IPC 的 unshare。
- 多写了一个测试 `an_unknown_app_starts_a_worker_that_refuses_the_hello`。

## 4. 计划错误（计划行号，然后是证据）

- **计划 :698（任务 17）**：“app session started while locked announces the canvas of `locked_start_display`” 和 Swift 不一致。
  - Swift 的 `waitForUnlock` 用 `lockedAppDisplay`，后者通过 NSRunningApplication 和 CGWindowList 找到 app 所在的屏，找不到才用主屏（Server.swift:676-697，WindowCapture.swift:273-287）。
  - 平台接口给不出锁屏时 app 的窗口，所以 Rust 总是用主屏（session.rs `wait_for_unlock`）。
  - PORTING 第 4 部分记了这条。
- **计划 :700（任务 17，`unlock_with_a_wrong_password`）**：“`screenLocked(true)` arrives after the 8 s wait” 是错的。
  - Swift 的 `sendLocked` 只在状态变化时才发（Server.swift:863-871 的 `guard locked != sentLocked`；输完密码后在 :909 调用）。
  - 密码错时一直是锁定，所以不会再发 `screenLocked(true)`。
  - 测试改为检查：`press_return` 之后，下一次 unlock 在主机时间 8–10 秒之间被接受。
- **计划 :676（任务 15）**：“`scroll` with point conversion through `global_point`” 是错的。
  - Swift 的输入用窗口点：显示器原点 + 窗口左上角 + (x, y)，限制在显示器内（InputInjector.swift:227-231）。
  - `geometry::global_point` 收的是 0…1 的比例（Geometry.swift:21；geometry.rs:166）。
  - 旧笔记写的 InputInjector.swift:252-257 是错行号，那个文件只有 233 行。
- **计划 :676（任务 15，covers）**：Swift 的 dismissCover 和 covered 用 NSRunningApplication 判断遮挡的主人和 bundle（Server.swift:551-552、:571-573）。Rust 改用 `ControlOps::cover_at`，名字取自 `screen()`。
- **计划 :678（任务 15）**：说 appState 报告带 `os` `fake`。实际 `AppStateReport` 没有 os 字段（state/engine.rs:39-52），os 只在 `RuleEnv` 里用于匹配（engine.rs:21）。
- **计划 :678（任务 15，过大的 stateRules）**：过大的规则在协议解码器那一层就被拒了（protocol.rs:1019-1022；Swift Protocol.swift:474），会话以 `bad data from client: rules too large` 结束，根本到不了 engine。
- **计划 :633/:641（任务 13）**：unexpected message 的文案应以 Server.swift:538 为准，即 `unexpected message from client`。
- **计划 :661（任务 14）**：stats 事件没有 `in_flight` 字段。测试改为检查帧数（没有 ack 时为 1）和 stats fps ≤ 1。
- **任务 14 的空区域场景**：`capture_region` 走不到空区域，测试只好强制一个 0x0 帧，命中 `sendable` 守卫。

## 5. 编译和行为风险（最可能的在前）

1. **借用和类型推断。**
   - `session/unlock.rs` 的闭包：`is_locked` 被移进 `locked`，同时又有 `&mut || hold(&lock)…` 的共享借用；`with_unlock_lock` 的 body 是否要求 FnOnce/FnMut。
   - `run.rs` 的 `read_commands` 对 stdin BufRead 的借用方式。
2. **Cargo.lock 会变。** testkit 新增了对 rapp-host-core、rapp-client-core 的依赖，还有新 bin。我按规则没碰 Cargo.lock，第一次构建会更新它。
3. **ScaledClock（×20）下的计时断言偏紧**：错密码的 8–10 秒窗口、`disconnect_while_typing_frees_the_lock`、暂停 2 秒、20 单元/5 ms 间隔、0.15 秒/2 秒的粘贴恢复。机器负载高时可能偶发失败。
4. **host_service.rs 对服务行为的假设。**
   - `apps` 正好 2 项（`desktop:` 排第一）；`permissions` 正好是 `{"screen_recording":true,"accessibility":true}`（服务的 `permissions()` 在 workers.rs:149）。
   - password 加 name 认证后，`session_start` 日志带 `name`。
   - 关 stdin 后退出事件的 reason 是 `stdin closed`（run.rs `on_eof`）。
   - 服务启动时可能先调用 `rapp-host check --json` 等命令，fake-host-core 都支持。
5. **比较类型（第四批逐处看过，判断能编译）**：
   - `&String == &str` 走 `impl PartialEq<&B> for &A`（要 `String: PartialEq<str>`，有）；`Vec<String> == [&str; N]`、`Vec<&String> == [&str; N]` 走 `impl PartialEq<[U; N]> for Vec<T>`（要 `T: PartialEq<U>`，有）。看过的地方：host_session.rs:37、789、827、842、1485、1887、1920，rules_lock.rs:248，filename.rs:140，regions.rs:77，detectors.rs:87，hints.rs:131。
   - 会编不过的是 `&&String == &str` 和 `Option<String> == Option<&str>`。第四批按这两种写法搜过，没有找到；`Option` 的比较都先 `.as_deref()` 了。
   - 编译器真报出来时，改法是 `.as_str()` 或 `.as_deref()`。
6. **会话互斥锁持有过久。**
   - 慢的 `focus_chain` 期间，会话的 `Shared<dyn ControlOps>` 锁一直被持有，会挡住会话线程的 secure 和 cover 轮询。
   - “clear to input” 在会话线程上最多睡 50 ms。
7. **夹具缺失**：focus-pane.json 等要先由 Swift 生成，否则相关测试一定失败。
8. **color16 和 gray4 的细节**：color16 采样的字节序、gray4 copy 边框解码后是否相等。另外 `div_ceil` 需要 Rust 1.73 以上。
9. **peer 命令可能和 hello 竞争**：服务先 `tell` peer 再回 ok，但 worker 的 stdin 线程和会话线程之间没有严格顺序。
10. **porting.rs 的分段**：`part()` 取到下一个 `## ` 为止，所以第 1 到 3 部分内部不能再有 `## ` 标题。另外，任何 Swift 文件一改，摘要测试就会失败，这是故意的。
11. **桌面测试的标题**：期望的 “Fake PC · 屏幕 1” 依赖 `desktop_title` 和 `ordered_displays`。
12. **`bins()`/`bins_with_host` 只能在 unix 上用**（`std::os::unix::fs::symlink`）。testkit 的服务测试本来只在 Mac/Linux 上跑。

## 6. 验证的人先做什么

1. `cargo check --manifest-path rust/Cargo.toml -p rapp-host-core --all-targets`，再对 `-p rapp-testkit --all-targets` 跑一遍。先把编译错误修完（重点看 §5 的 1 和 5），允许 Cargo.lock 更新。
2. 用 `RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'` 生成夹具。
3. `cargo test -p rapp-host-core --no-fail-fast`：边界测试、`porting`、各夹具测试。
4. `cargo test -p rapp-testkit --test host_session`，然后 `--test host_service`。计时类测试失败时，先单独重跑，分清是负载问题还是逻辑问题。
5. 跑一遍 clippy `-D warnings`。
6. 手工做任务 19 步骤 4（真 Mac 控制端），结果写进记录。
