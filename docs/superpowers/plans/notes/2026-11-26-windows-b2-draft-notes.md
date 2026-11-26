# 计划 B 任务 7–12 草稿笔记（host-core 规则部分）

分支 `feat/windows-host-core-rules`，worktree `.worktrees/windows-host-core-rules`。所有代码**未编译、未运行、未验证**：没跑过 cargo、swift、测试、格式化或 lint。夹具一个都没生成（`RAPP_WRITE_FIXTURES=1 swift test --filter HostCoreFixtures` 还没跑过），所以 Rust 夹具测试现在全部读不到文件。

| 任务 | 提交 | 内容 |
|---|---|---|
| 7 | ab7fe312 | 窗口表、桌面、命中测试、提示规则 |
| 8 | 20037803 | 焦点窗格和跟踪器 |
| 9 | c07b51b4 | 输入规则和 worker 命令行 |
| 10 | c04925a0 | 剪贴板规则、传输存储、可移植文件名 |
| 11 | 3c8e903e | 锁屏和解锁规则 |
| 12 | b8ccad1c | 应用状态规则引擎 |

## 1. 写了什么

每个 Rust 文件都按文件对应的 Swift 源移植，分支、常量和固定字符串逐字照搬（中文保持中文）。

- **任务 7**
  - `src/geometry.rs` ← `Geometry.swift`；另有 Swift 数值辅助函数 `swift_min/max`、`swift_int`、`swift_double` 等，后续任务共用。
  - `src/wintable.rs` ← `Windows.swift`。
  - `src/desktop.rs` ← `Desktop.swift`。
  - `src/hit_test.rs` ← `HitTest.swift`。
  - `src/hints.rs` ← `HostHints.swift`。
  - 测试：`tests/rules_windows.rs`、`tests/rules_common/mod.rs`。
  - 生成器：`WindowRuleFixtures.swift`。
- **任务 8**
  - `src/focus/{mod,pane,tracker}.rs` ← `FocusPane.swift`、`FocusTracker.swift`。
  - `src/query.rs` ← `QueryCoalescer.swift`、`QueryDeadline.swift`。
  - 测试：`tests/rules_focus.rs`。生成器：`FocusFixtures.swift`。
- **任务 9**
  - `src/input.rs` ← `InputYield.swift`、`HeldInput.swift`、`PeerNames.swift`。
  - `src/cli.rs` ← `WorkerCLI.swift`（host 半边）。
  - `src/platform.rs`：只有 `OpenError` 和 `Permissions`。
  - 测试：`tests/rules_input.rs`、`tests/cli.rs`。生成器：`InputFixtures.swift`、`CLIFixtures.swift`。
- **任务 10**
  - `src/clipboard.rs` ← `Clipboard.swift`。
  - `src/transfers.rs` ← `Transfers.swift`。
  - `src/filename.rs`：按规格 §6.7 写的 `portable_file_name` 和 `unique_name`。
  - 测试：`tests/rules_clip.rs`、`tests/transfers.rs`、`tests/filename.rs`。
  - 生成器：`ClipFixtures.swift`，产出 clip-rules.json、paste-session.json、clip-store.json、transfer-chunks.bin。
- **任务 11**
  - `src/lock.rs` ← `ScreenLock.swift`、`UnlockSequence.swift`、`StayAwake.swift`、`FileLock.swift`。
  - `geometry.rs` 加了 `chunk_ranges`。
  - 测试：`tests/rules_lock.rs`。生成器：`LockFixtures.swift`，产出 lock.json、unlock-sequence.json。
- **任务 12**
  - `src/state/` 下按文件对应 `StateRules/`：
    - `rule_value.rs` ← RuleValue.swift
    - `rule_image.rs` ← RuleImage.swift
    - `rule_pack.rs` ← RulePack.swift
    - `regions.rs` ← Regions.swift
    - `detectors.rs` ← Detectors.swift
    - `table.rs` ← StateTable.swift
    - `engine.rs` ← StateEngine.swift
    - `mod.rs` 做再导出。
  - 测试：`tests/state_rules.rs`。
  - 生成器：`StateRuleFixtures.swift`，产出 rule-pack.json、rule-regions.json、rule-detectors.json、state-table.json、state-engine.json、rule-image.bin。

## 2. 核心算法

**完整**：
- 以下都完整：
  - 窗口表的增删和标题；
  - 桌面布局；
  - 命中测试；
  - 提示；
  - 焦点窗格和跟踪器的全部状态机；
  - 查询合并和截止时间；
  - 输入让位和按住输入；
  - 设备名；
  - worker 命令行解析和 JSON 输出。
- 剪贴板分类、截断和恢复判断；ClipStore；FetchSource；PutSink（写 part、改名收尾）；TransferStore；可移植文件名；unique_name。
- 锁屏流程、解锁序列、StayAwake、跨进程文件锁 `with_unlock_lock`（`std::fs::File::lock`）。
- 状态规则全部完整：
  - RuleValue 解析和合并补丁；
  - 规则包解码（向前兼容、65536 字节上限）；
  - 区域解析（box、edge、blob、strip，有循环保护）；
  - 检测器（形状、前景色、运动、文字，文字有节流）；
  - 状态表的 hold 和 release；
  - 引擎的变体、自检、换变体、unfit/invalid 健康状态，以及报告 JSON 的 8 步收缩（保证不超过 4096 字节）。

**部分**：没有算法是只写了一半的。平台相关的部分（真正的 OCR、截屏、发按键）按计划留给平台层，host-core 只放 trait 和注入的闭包。

## 3. 没写的和原因

- protocol.rs、deflate.rs、quantize.rs、tile.rs、scroll.rs、pacing.rs、pause.rs：按要求不建，归任务 2–6。
- 文件锁不设 0600 权限：要用 `std::os`，host-core 禁止用。
- 手写夹具：一个都没写，全部由 Swift 生成器产出。
- 以下场景没有夹具：
  - TransferTests 里的 chmod 场景（`testFailedFinishIsNotCompleteAndRetryWritesAtHave`）：只能在 POSIX 上跑。
  - 100/101 个文件和 64 MiB 两条上限：在 rapp-host 的 ClipboardWatcher 里，RappCore 没有，夹具调不到，测试只核对常量。
  - StateEngineTests 的单次 tick 耗时测试：只移植了场景，没测时间。

## 4. 未验证

### 预计的编译问题

- **依赖任务 2 的类型**，都从 `crate::protocol` 引入。protocol.rs 不在这个 worktree 里，所以下面这些现在都编译不过：

  | 文件 | 引入的类型 |
  |---|---|
  | wintable.rs、desktop.rs | `CanvasRect`、`WindowInfo`、`WindowKind` |
  | hints.rs | `Message`、`MouseKind` |
  | input.rs | `Message`、`MouseButton`、`MouseKind` |
  | cli.rs | `constant_time_equals`、`ClipKind`、`CodecError`、`Mode`、`DEFAULT_PORT`、`PROTOCOL_VERSION` |
  | transfers.rs | `ClipInfo`、`ClipKind` |
  | focus/pane.rs | `CanvasRect`，以及 `crate::tile::{EncodeReport, TILE_SIZE}`（任务 4） |
  | state/engine.rs | `APP_STATE_LIMIT`（Swift 值为 4096） |

  字段名照草稿 670f7904 猜的。`EncodeReport` 假定字段是 pub，`changed` 是 usize。

- **需要较新的 Rust**：`Option::is_none_or` 和 `File::lock` 要 Rust ≥ 1.89；`ErrorKind::StorageFull` 要 ≥ 1.83。
- **借用和类型推断可能出错**：大文件（tracker.rs、transfers.rs、state/*）里有不少闭包借用和 `json!` 宏，没编译过，难免有这类错误。
- **`StayAwake` 和 `RuleEnv.reread_version` 的闭包要求 `Send`**：调用方必须满足。

### 猜测的 Swift 行为

- 数字：
  - `UInt32("-0")` 的结果。
  - `"%.1f"` 在正好居中时往哪边舍入。
  - `NSDecimalNumber("-0.0")` 打印成什么。
  - `as? Int` 是否接受 bool 和整数值的 double。
  - JSON 里的 double 能否原样往返。
- 字符和字符串：
  - Swift 的 `Character` 是字素簇，Rust 这边用 unicode-segmentation 模拟。`==` 和 `hasPrefix` 在 Swift 里按规范等价比较，Rust 按字节，组合字符会有差别（夹具只放了几例）。
  - `isNumber` 用 `char::is_numeric` 近似，CJK 数字可能不同。
  - 空白集合是手写的谓词。
  - 小写按单个标量转，没有希腊词尾 σ 规则。
  - `String <` 在 Rust 里是字节序。
  - `localizedStandardCompare` 是近似实现。
- Swift `Double.description` 的移植（rangeHolds 用）：小数和指数形式的分界点（2^53）没验证。`Double(String)` 的十六进制浮点形式是手写的，Swift 是否拒绝前导空白也是假定。
- 溢出：Swift 会 trap 的地方，Rust 用饱和或回绕（例如 `Int(timeout)`、`Int(Double)`、`w*h*4`），所以 Rust 不会崩，只会得出某个值。
- `max(by:)` 遇到相等时取第一个，这是假定。
- 字典序：Darwin 的 `sortedKeys` 不一定是字节序；JSON 转义写法也可能不同。所以测试比较解析后的对象和字节长度，只有 WireShape 和 default 两例比较原文。
- 文件：
  - Swift `String(s[..<idx])` 是否对齐到 Character 边界。
  - `from_utf8_lossy` 和 Swift `String(decoding:)` 的替换字符个数。
  - lstat 和 `fs::metadata` 的区别。
  - Windows 上改名正在打开的文件，靠 Rust 默认的 FILE_SHARE_DELETE。
- `unique_name` 可能把名字推过 200 个单位。
- fetch 回放遇到错误时会 panic（Swift 是记一条错误）。

### 夹具

- 生成器全部没跑过，Swift 端也可能有编译错误。任务 12 生成器里可疑的地方：
  - 字典字面量 `Any` 推断；
  - 用 `as?` 区分 `[String:[[Int]]]` 和 `[String:Int]`（已把 rects 放在前面判断）；
  - `XCTAssertEqual(mPack, mBuilt)`。
- **rule-image.bin 格式超出计划**：大于 64 KB 的帧（800×600 和 1600×1000 的窗口）不存像素，只存 SHA-256（tag 3），另加 tag 4 记录画法配方。Rust 用移植的 `RuleCanvas.swift` 重画，然后比较像素或哈希。重画移植错了，所有规则测试都会先在这里失败。
- NaN 阈值的规则包写不成 JSON，Rust 测试里按 Swift 测试的构造方式手工搭建。
- 夹具文件名和生成器类名对照：

  | 夹具 | 生成器类 |
  |---|---|
  | window 系列 | `WindowRuleFixtures` |
  | focus 系列 | `FocusFixtures` |
  | input、cli | `InputFixtures`、`CLIFixtures` |
  | clip 系列 | `ClipFixtures` |
  | lock 系列 | `LockFixtures` |
  | 状态规则 6 个文件 | `StateRuleFixtures` |

### 暂时不可能通过的测试

- 所有读夹具的测试：夹具还没生成。
- `boundary.rs` 本身没问题，但整个 crate 在任务 2–6 合进来之前编译不过。

## 5. 计划错误

- 计划里没有的东西（照 Swift 移植了）：
  - `view_region`；
  - `window_title` 放在 wintable 下；
  - `clamp_size`；
  - `shareableApps` / `appsText` / `ListedWindow`。
- lib.rs 再导出了 `Password`、`InflateStream`，任务 2/3 的产出清单里没有。
- 任务 9 的 `lock_json` 依赖任务 11 的 `LockOutcome`。任务 9 提交里只放了一个桩，任务 11 补全。
- 计划说 NotFound 用"Swift 的文字"，规格 §6.4 写的是 `<id> not found`。
- 计划写的是 `Input { … }`，但 Swift 的 `.input` 没有字段，所以做成了单元变体。
- Swift `WindowTiles.changed` 的下标可以是负数，usize 表达不了，夹具避开了这种情况。
- Swift PutSink 从不从已有的 part 续传，`resumeOffset` 只是纯函数。所以"从 0 续传"等于新建一个 sink。
- 100/101 文件上限不在 RappCore 里（见第 3 节）。
- `with_unlock_lock` 多了一个 `log` 参数，计划的签名里没有。
- `RuleImage::sample` 返回 `Option<RuleImage>`，计划写的是直接返回 `RuleImage`。Swift 本来就返回可空值。
- `resolve_regions` 接受区域表 `&BTreeMap<String, RegionSpec>`，不是整个规则包。
- 计划的 rule-image.bin 放不下 800×600 和 1600×1000 的整帧（一共几十 MB），所以改成配方加哈希（见第 4 节）。
- StayAwake 的轨迹也写进了计划里的 lock.json，没有另开文件。

## 6. 取舍

- 区域、信号、计数都用 BTreeMap。Swift 字典顺序只影响 OCR 调用的先后，不影响调用次数，所以测试里的阅读器是无状态的。
- `TextReader` 的形状：`lines(&mut self, &RuleImage, RuleRect)`，`ready(&self)` 默认返回 true，要求 `Send`。
- `RuleEnv.reread_version` 是 `Box<dyn FnMut() -> Option<String> + Send>`。
- 帧检查：`w*h*4` 溢出时当作没有帧。
- 剪贴板：
  - `next_id` 回绕；
  - sink 用 `Arc<Mutex<PutSink>>`；
  - 改名前先检查目标是否已存在；
  - `portable_file_name` 取最后一个非空路径段；
  - 加了 `MAX_CLIP_DATA`、`TOO_MANY_FILES`、`FOLDER_UNSUPPORTED` 几个常量。
- `SecureHelper` 的参数错误照 Swift；`apps_json` 总是带 permissions；`check_json` 就是 permissions 对象。
- 时间都由调用方注入。`Instant::now`、`SystemTime::now`、`thread::sleep` 只出现在 clock.rs。boundary 列出的平台词在 `src/` 里一个都没有（已用 grep 确认）。
