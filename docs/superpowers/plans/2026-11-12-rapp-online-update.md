# rapp 在线升级与权限保持 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 装好一次以后不用再碰 pkg。rapp-service 自己从 `wizlijun/rapp-releases` 发现新版并下载、校验；A 没人在用时自动换掉 `/Applications/rapp.app` 并重启成新版。每一版都用同一个 Apple Development 证书签名，所以屏幕录制、辅助功能在升级后仍然有效。授权记录坏了时，GUI 里点两下就能清掉 rapp 自己的记录，重新授权。

**Architecture:**
- 新 Rust crate `rust/update`（包名 `rapp-update`），只放能单测的部分：版本、manifest、缓存、「该不该检查」，以及下载、校验、安装、标记文件。
  - 所有外部命令（curl、ditto、codesign、plutil、tccutil、open、ps、df）和目录改名都经过可注入的同步 trait `Runner`。
  - crate 里带一个公开的 `FakeRunner`，单测和 service 集成测试都用它。
- `rust/service/src/update.rs` 负责接入 service：定时器、状态机、IPC 命令、「没人在用」的判断、写日志，并请求重启（`main.rs` 收到后 `stop()`，退出码 0，由 launchd `KeepAlive` 拉起新版）。
- `permissions_reset` 和 `permissions_lost_after_update` 放在 service 的现有权限路径上。
- GUI：
  - `gui/lib/update.dart` 放模型和文案纯函数；
  - `gui/lib/pages/update_section.dart` 是 本机 › 版本与升级；
  - `PermissionsPanel` 加重置按钮，侧栏「本机」入口加一个静止的小点。
- 发布端：
  - `scripts/package-macos.sh` 改为稳定签名，并多输出 zip 和 `latest.json`；
  - postinstall 加 chown；
  - 新增 `scripts/upgrade-relay.sh`，`rapp-relay` 加 `--version`。

**Tech Stack:**
- Rust 2021 workspace（tokio、serde_json、sha2、tempfile），不加 HTTP 库。
- Flutter 3.44（Dart，macOS 桌面）。
- bash 脚本。
- Swift（rapp-host、rapp-client）不改。

**Spec:**
- `docs/superpowers/specs/2026-11-12-rapp-online-update-design.md`（全文；§2 三条按推荐，§10 五条假设见下面的「假设怎么处理」）。
- 上位：
  - `docs/superpowers/specs/2026-11-11-rapp-permission-guide-design.md`（PermissionsPanel、首次引导、3 秒轮询）；
  - `docs/superpowers/specs/2026-11-11-rapp-observability-design.md`（`service.log` 事件格式）；
  - `docs/superpowers/specs/2026-11-12-rapp-design-language.md`（§0 三条检查、§6 尺寸、§8 组件、§9 词表）。**设计语言文件只读，不改、不暂存。**

## 规格冲突

- **C1**：规格 §4.4 的 `state` 只有 `idle|checking|downloading|ready|installing|failed|up_to_date`，但 §4.3 ① 又说「不在 `.app` 里运行时整个模块不工作」。本计划加一个 `off`：开发构建、命令行直接跑的 service 都回 `off`，GUI 只写「开发构建，不检查更新」。
- **C2**：§4.3 ④.4 的「打开安装包」要一个 release 页面地址，manifest（§4.2）里没有这个字段。本计划从 asset url 推出来（K14），推不出来时用 asset url 本身。
- **C3**：§6 的 `upgrade-relay.sh` 要「用 `--version` 自检」，但 `rapp-relay` 现在没有 `--version`（`rust/relay/src/main.rs` 的 `parse()` 只认 `--key/--listen/--db/--debug`）。Task 7 加上。
- **C4**：`service_start` 日志里的 `version` 是 `env!("CARGO_PKG_VERSION")`（workspace 0.3.0），不是 bundle 版本。升级比较的「当前版本」按规格取 bundle 的 `CFBundleShortVersionString`（K5），`service_start` 的字段不动，`update_status.current` 才是对用户的版本。
- **C5**：规格 §5 说小点放在「侧栏『本机』入口」，那个入口是设备面板里的 `TabChip(Key('device-local'))`，只在设备面板打开时看得见。本计划就放在这里（K27），不往顶栏加东西（设计语言 §0：升级只能待在边缘）。
- **C6**：§4.3 ④.1 的手动升级只写了「等 GUI 断开，再查一次没人在用」，没写 A 侧正有远程会话时怎么办。本计划规定：有会话就直接回错误，GUI 不退出（K20）。
- **C7**：§8 写「假 manifest 用本地临时 HTTP 服务」，这次的任务要求是用假 curl。本计划的 service 集成测试全部用 `FakeRunner` 假 curl。另外保留一个用真 `/usr/bin/curl` 连本地 `127.0.0.1:0` 小服务器的单测，专门验证 `-C -` 续传（Task 3），不出本机。

## 假设怎么处理（规格 §10，本计划不在这台 Mac 上验证）

| # | 假设 | 计划里的做法 | 不成立时 | 在哪验证 |
|---|---|---|---|---|
| A1 | 没有 root 时 `tccutil reset Accessibility com.rapp.rapp` 能生效 | K22：重置后重新 check。原来是 ✓、tccutil 退出 0、check 变成 ✗，才算重置成功；否则回 `accessibility_reset:false`，GUI 改成说明加深链 | 按钮对辅助功能只起说明作用，屏幕录制照常重置 | Task 8 第 5 步 |
| A2 | Apple Development 证书、不开 hardened runtime，跨两次构建授权一直有效 | Task 1 的签名顺序和 cdhash 检查；Task 3 比对指定要求 | 换 §2.2 备选 B（Developer ID），打包脚本已支持；用重置按钮重新授权一次 | Task 8 第 3、4 步（装两个连续版本） |
| A3 | `/Applications/…` 改名到 `~/Library/…` 在同一个卷上 | K12：`rename` 失败且 `raw_os_error()==Some(18)`（EXDEV）时走 `ditto` 复制再删除 | 只是慢一点 | 单测假 EXDEV；Task 8 用 `stat -f %d` 比较两个目录的卷号 |
| A4 | 退出后 launchd 拉起新路径时会触发 10 秒节流 | 不特殊处理；`healthy_after` 从新进程启动时算起 | 只是晚 10 秒 | Task 8 第 3 步记下从 `update_applied` 前最后一条日志到新 `service_start` 的间隔 |
| A5 | 新 rapp-host 沿用 rapp.app 的授权 | 不特殊处理（登记的是 rapp.app，K3 保证 host 的标识固定） | 用 `permissions_lost_after_update` 的引导兜底（Task 5） | Task 8 第 3 步：升级后 本机 › 权限 两项 ✓，B 能打开 app |

另有一个只读的早期核对（Task 4 Step 0）：`ps -axo pid=,ppid=,comm=` 在这台 Mac 上给的 `comm` 是不是可执行文件的完整路径。只读进程表，不碰任何东西。

## 计划决定（规格没写死、我定的）

| # | 计划决定 | 理由 | 错了的代价 |
|---|---|---|---|
| K1 | 签名身份顺序：`RAPP_SIGN_APP`（设成空串表示强制 ad-hoc，沿用现有 `${…-…}` 写法）→ Developer ID Application → Apple Development → ad-hoc。纯函数放 `scripts/lib/sign-check.sh`：`pick_identity`、`is_cdhash_dr`、`identifier_of`。由 `scripts/test-package.sh` 喂预先录好的 `security`/`codesign` 输出来测，测试里不调用真的 `security`、`codesign` | 规格 §3.1；脚本的真实签名要用钥匙串，测试不能碰 | 无 |
| K2 | 只有 Developer ID 才加 `--options runtime --timestamp`。用 `RAPP_SIGN_APP` 指定的 SHA，在 `find-identity` 输出里那一行含 `Developer ID Application` 时也加。只要不是 ad-hoc，Frameworks 一律用同一身份签 | 规格 §3.1；现在只有带身份时才签 Frameworks | 无 |
| K3 | 四个子程序的标识：`-i com.rapp.service`、`com.rapp.hub`、`com.rapp.host`、`com.rapp.client`。签完以后用 `codesign -d -v` 逐个核对 `Identifier=`，对不上就失败 | 规格 §3.1、§8 | 无 |
| K4 | 发布检查：脚本最后打印 `codesign -d -r- "$APP"`。指定要求是 `cdhash H"…"` 形式时 `exit 1`，除非 `RAPP_ALLOW_ADHOC=1`。postinstall 在 `launchctl bootstrap` 之前执行 `chown -R "$USER_NAME":staff "$APP"`，`USER_NAME` 为空就跳过 | 规格 §3.1 | 无 |
| K5 | 当前版本：`plutil -extract CFBundleShortVersionString raw -o - <bundle>/Contents/Info.plist`。读不出来就按 `off` 处理 | 规格 §4.3 ①；Flutter 的 Info.plist 可能是二进制格式，用 plutil 最稳 | 无 |
| K6 | `is_newer` 只认 `x.y.z`，可以带一个前缀 `v`。其他写法（`0.5.0-beta`、`0.5`、空串）都算解析失败，即「不是更新」。版本号在拼进任何路径之前先过 `parse_version`，防止 `../` 之类的路径穿越 | 规格 §4.3 ①；版本号来自网上 | 带后缀的版本永远不提示，规格 v1 本来就不做 beta |
| K7 | 缓存 `<home>/update.json` 存三个字段，`last_checked_at` 是 unix 秒。读缓存从不报错：文件不存在或坏了当空缓存。`should_check`：从没查过、`now < last_checked_at`（时钟往回拨过）、或 `now - last ≥ 20×3600` 时为真。拉取失败不写缓存 | 规格 §4.3 ①，照 Codex | 时钟乱跳时多查一次 |
| K8 | 启动 30 秒后的第一次和之后每小时一次，用同一条规则：缓存过期才去拉 manifest。缓存里已经有一个更新、没被忽略的版本时，不联网，直接继续下载、校验（`.part` 能续上）。「检查更新」按钮清掉 `dismissed_version`，并且不看 20 小时立即去拉 | 规格 §4.3 ① 的「启动 30 秒后检查一次」不应让频繁重启的 service 每次都访问 GitHub | 最多晚 20 小时才知道有新版；按钮可以补 |
| K9 | `check_updates=false` 时，只停掉定时检查，按钮照样能用。`auto_update=false` 时照样下载、校验，只是不自动安装，等用户点「立即升级」 | 规格 §2.3「关掉以后只提示不安装」；提前下好，点按钮时立刻就能装 | 关掉自动升级的人也会多下一个 zip |
| K10 | manifest：`curl -fsSL --max-time 30 --max-filesize 65536 -o <cache_dir>/latest.json.tmp <url>`。下载：`curl -fL --retry 3 -C - --speed-limit 1024 --speed-time 60 -o <part> <url>`。失败原因只写 `curl 退出码 N`，日志和 GUI 都不出现 URL。`parse_manifest` 要求 asset url 以 `https://` 开头、sha256 是 64 位十六进制（比较时不分大小写）、`size > 0` | 规格 §4.2、§4.3 ②、§7 | 无 |
| K11 | 下载规则：<br>- 可用空间用 `/bin/df -k <cache_dir>` 末行第 4 列，要求 ≥ size×3，读不出就不下；<br>- `.zip` 已在并且 sha 对得上，直接用；<br>- `.part` 比 size 大就删掉；`.part` 正好是 size，不跑 curl，直接核对；<br>- curl 退出码 33（续传范围不对）时删 `.part`；其他失败保留 `.part`，下次接着下；<br>- 核对 size、sha256（sha2 crate，流式读）都对了才改名成 `.zip`；对不上就删 `.part`，记 `update_failed{stage:download}`；<br>- 进度 = `.part` 大小 / size，service 每秒看一次，百分比变了就 `notify()` | 规格 §4.3 ② | 无 |
| K12 | 安装，`move_dir(from,to)` = `Runner::rename`；遇到 EXDEV 就 `ditto from to` 再删 `from`。顺序：<br>① 删掉残留的 `<dir>/.rapp-new.app`，把新 app 搬到这里；<br>② 删掉旧的 `<home>/previous/rapp.app`；<br>③ 把 `bundle` 搬到 `previous/rapp.app`；<br>④ `rename(.rapp-new.app → bundle)`。④ 失败就把 ③ 搬回去，删 `.rapp-new.app`，记 `update_failed{stage:install}`。不事先检查可不可写：① 或 ③ 遇到 `PermissionDenied` 就归为 `NeedsAdmin`，清理 `.rapp-new.app`，不重试 | 规格 §4.3 ④.2–4；先检查再做有竞态；③ 在 root 所有的 bundle 上会因为要改 `..` 而失败 | 无 |
| K13 | 回到上一版用同一个 `install`，源换成 `previous/rapp.app`，`mode=rollback`。效果是两版对调，`previous/` 里留下刚才的新版。只跑 `codesign --verify --deep --strict`，不比指定要求，因为那是自己装过的一版 | 规格 §4.3 ⑥ | 无 |
| K14 | release 页面：asset url 形如 `https://github.com/<o>/<r>/releases/download/<tag>/<file>` 时，取 `https://github.com/<o>/<r>/releases/tag/<tag>`；否则用 asset url 本身 | C2 | 打开的是 zip 而不是页面 |
| K15 | 标记 `<home>/update-applied.json` = `{from,to,at,gui_was_open,mode,perms_before}`，`gui_was_open = (mode != auto)`。新 service 启动时：<br>- 当前版本等于 `to`：记 `update_applied{from,to,mode}`，`gui_was_open` 为真就 `open <bundle>`；过 `healthy_after`（30 秒）以后删掉标记和 `cache_dir` 里的 zip、解包目录；<br>- 不等于 `to`：记 `update_failed{stage:restart, reason:"重启后是 <当前>，不是 <to>"}`，删掉标记；<br>- 标记读不出：删掉，不记 | 规格 §4.3 ⑤；`perms_before` 给 Task 5 用 | 30 秒内又崩一次，会再记一次 `update_applied` |
| K16 | 「在 `.app` 里运行」= `current_exe()` 的上两级是 `Contents/MacOS`，再上一级以 `.app` 结尾（`bundle_of`）。「由 launchd 拉起」= `std::os::unix::process::parent_id() == 1`。不是 launchd 拉起时，自动安装、手动安装、回到上一版都不做，GUI 写「服务不是由系统启动的，请从 release 页面手动装 pkg」并给「打开安装包」 | 规格 §4.3 ①⑤；退出以后没有 KeepAlive，就没人把它拉起来 | 无 |
| K17 | 「没人在用」= 会话表为空，并且 `ps -axo pid=,ppid=,comm=` 里没有 `comm` 以 `<bundle>/Contents/` 开头的进程，排除 pid 是自己、或 ppid 是自己的进程（自己起的 rapp-host worker、`rapp --cm`）。ps 跑失败就当「有人在用」 | 规格 §2.3 | ps 格式不对时永远不自动装：Task 4 Step 0 先只读核对 |
| K18 | 状态机放在 `State.update: Mutex<UpdState>`，一次只有一条流水线（`busy` 标志），按钮在流水线忙时直接回 `ok`、什么都不做。`ready` 以后每 `idle_poll`（60 秒）试一次自动安装。外部命令都在 `spawn_blocking` 里跑 | 简单；不会同时有两个 curl | 无 |
| K19 | `status` 回复里多两个字段：`"update": {…}`（就是 `update_status` 的对象）和 `"permissions_lost_after_update": bool`。`update_status` 对象在规格的字段之外还有 `check_updates`、`can_rollback`（`previous/rapp.app` 存在）、`needs_admin`、`page`、`dismissed`（`latest == dismissed_version`） | GUI 已经订阅 `status`，不用再多一路请求；C1、C2 | 无 |
| K20 | `update_apply` 时：<br>- 不是 `ready` → `{ok:false,error:"没有可装的新版本"}`；<br>- 指定要求变了，而 `confirm_signature_change` 不为真 → `{ok:false,error:"需要确认"}`；<br>- `needs_admin` 或不是 launchd 拉起 → 带 `page` 的错误；<br>- A 侧有会话 → `{ok:false,error:"有 N 个远程会话在用这台电脑"}`；<br>- 都没问题 → 回 `{ok:true}`，后台等这条 IPC 连接断开（最多 `gui_wait` 10 秒），再最多 10 秒内每 500 毫秒查一次「没人在用」。查到了就安装（`mode=manual`）；10 秒后还有人在用，就 `open <bundle>` 把 GUI 重新打开，状态设成 `failed`，原因写「rapp 还开着」 | C6；GUI 已经退出了，失败时不能让人找不到窗口 | 多开了一次 GUI |
| K21 | 「这条连接断开」的实现：`ipc::conn()` 给每条连接建一个 `oneshot::Sender<()>`，函数返回时随之 drop；`update_apply` 拿走对应的 `Receiver`，等到 `Err(Canceled)` 就算断开 | 规格 §4.3 ④.1 | 无 |
| K22 | `permissions_reset`：<br>- 先跑 `/usr/bin/tccutil reset ScreenCapture com.rapp.rapp`，再跑 `/usr/bin/tccutil reset Accessibility com.rapp.rapp`，bundle id 用常量 `rapp_update::BUNDLE_ID`，从不来自 IPC 参数；<br>- 记 `permissions_reset {}`，然后 `refresh_permissions(state, true)`；<br>- 每项「重置成功」= tccutil 退出 0，并且（原来不是 ✓，或者现在是 ✗）；<br>- 回复 `{ok:true, screen_recording_reset, accessibility_reset, permissions}` | 规格 §3.2；A1 的退路 | 原来就是 ✗ 的项看不出 tccutil 是否真生效，只能信退出码 |
| K23 | `permissions_lost_after_update`：有标记、`perms_before` 两项都是 true，而启动时第一次 check 有一项不是 true，就置真。只放在内存里；之后 `set_permissions` 看到两项都 ✓ 时清掉 | 规格 §3.3 | 无 |
| K24 | `Opts` 加 `runner: Arc<dyn Runner>` 和 `update: Option<UpdateOpts>`。测试的 `start_service` 给 `FakeRunner::new()`（没编排的命令一律返回错误）和 `None`。`main.rs` 给 `SystemRunner`（全部用绝对路径），以及 `bundle_of(current_exe())` 推出来的 `UpdateOpts::system`。权限重置也走 `state.runner` | 测试里永远跑不到真的 tccutil、curl、open | 无 |
| K25 | 重启：`State` 加 `restart: watch::Sender<bool>`，`Service::restart_wanted()` 等它变真。`main.rs` 用 `select!` 同时等 `stopped()` 和 `restart_wanted()`，然后 `svc.stop()`（它会 `close_all()` 停掉 worker），最后 `std::process::exit(0)` | 规格 §4.3 ⑤；复用现有 stop 路径 | 无 |
| K26 | GUI 文案（纯函数 `updateView`）：<br>- off：`开发构建，不检查更新`；<br>- idle、up_to_date：`当前 X · 已是最新`（idle 并且 latest 为空时只写 `当前 X`）；<br>- dismissed：`当前 X · V 先不装`；<br>- checking：`当前 X · 正在检查`；<br>- downloading：`正在下载 V（45%）`；<br>- ready：`V 已下载，没人在用时会自动装好`，`auto_update=false` 时只写 `V 已下载`；<br>- 签名变了：`这一版换了签名，装上以后要重新授权屏幕录制和辅助功能`；<br>- needs_admin：`这次需要管理员密码`；<br>- installing：`正在安装 V`；<br>- failed：`升级没有完成：<error>`。<br>按钮：检查更新、立即升级、仍然安装、这一版先不装、打开安装包。开关是「自动升级」，还有 `ConfirmButton`「回到上一版」。`notes` 在 ready 时作为一行 `muted` 小字 | 规格 §5、§4.3 ③④ | 改纯函数 |
| K27 | 小点：`updateBadge(info)` = 状态是 downloading、ready 或 installing，并且没被忽略。点是 8px 实心圆，颜色 `t.muted`，静止，作为 `TabChip(Key('device-local'))` 的 `leading`，加 `ExcludeSemantics`；入口的可访问名称改成 `本机，有新版本`。不用强调色，不闪 | 规格 §5；设计语言 §0 第 2 条、§1 原则 1 | 无 |
| K28 | 「立即升级」「仍然安装」：<br>- 先 `confirmQuit()`：hub 有远程窗口时弹「升级 rapp？」「还有 N 个远程窗口，升级时会断开。」（取消 / 升级），没有远程窗口时不弹；<br>- 再发 `update_apply`；回 ok 就 `quitNow()`（现有 `_quit` 的后半段），否则把 error 放进本机区块的一行提示。<br>`main.dart` 的 `_quit` 拆成 `confirmQuit` 和 `quitNow`，经 `MainWindow` 传给 `LocalSection`，参数类型是 `UpdateHooks? hooks`（测试里为 null 时这两个按钮回退成只发 apply） | 规格 §4.3 ④.1；和现有退出确认一致 | 无 |
| K29 | 重置按钮：`PermissionsPanel` 加 `Future<void> Function()? onReset`，为 null 时不显示。每个 ✗ 行下面一个 `ConfirmButton(label: '设置里已经打开了还是 ✗？重置授权记录')`。回复 `accessibility_reset:false` 时，面板下方出一行：`辅助功能的旧记录要在系统设置里删：选中 rapp，点「−」，再重新添加。`，旁边是「打开系统设置」（辅助功能深链） | 规格 §3.2；A1 | 无 |
| K30 | `permissions_lost_after_update` 为真时，`LocalSection` 本次运行弹一次首次引导，不管 `permission-guide-shown` 标记，也不写这个标记。引导里的 `PermissionsPanel` 带 `onReset` | 规格 §3.3 | 无 |
| K31 | 发布：<br>- zip 用 `ditto -c -k --keepParent "$APP" "$DIST/rapp-$VERSION-macos-arm64.zip"`，在签名、核对之后做；<br>- `latest.json` 由 `scripts/lib/release.sh` 的 `json_escape` 和 `write_manifest` 生成；<br>- `RAPP_RELEASE_BASE` 默认 `https://github.com/wizlijun/rapp-releases/releases/download/v$VERSION`，`notes` 取 `RAPP_RELEASE_NOTES`（默认空串），`published_at` 用 `date -u +%Y-%m-%dT%H:%M:%SZ`；<br>- 写完用 `plutil -convert xml1 -o /dev/null` 验证；<br>- 最后打印一行 `gh release create v$VERSION --repo wizlijun/rapp-releases …`，不执行 | 规格 §6；发布要人看一眼 | 无 |
| K32 | `scripts/upgrade-relay.sh <url>`：用 `${CURL:-curl}`、`${SYSTEMCTL:-systemctl}`、`${RELAY_BIN:-/usr/local/bin/rapp-relay}`，测试里能换成假的。`rapp-relay --version` 打印 `rapp-relay <CARGO_PKG_VERSION>` 并退出 0。自检要求输出以 `rapp-relay ` 开头 | 规格 §6、C3 | 无 |

## Global Constraints

**安全规则（每个实现者都受约束）：**
- 只启停自己起的进程，按 PID。不用 killall/pkill，不在 AppleScript/System Events 里按名字找进程。
- 不碰 `/Applications/rapp.app`、正在跑的 rapp-service（不跑 `launchctl`）、`~/Library/Logs/rapp`、用户真的配置目录 `~/Library/Application Support/rapp`、`~/Library/Caches/rapp`、钥匙串、系统剪贴板。
- 测试一律用临时目录、`FakeRunner`（假 curl、假 tccutil、假 codesign、假 ditto、假 open、假 ps、假 df）和临时端口（`127.0.0.1:0`）；不用 47800，也不用 21116–21119。
- 测试和实现过程中都不跑真的 `tccutil`、`launchctl`、`security`；不用任何身份跑 `codesign --sign`；不跑 `scripts/package-macos.sh`（它会用钥匙串签名）。只读的 `codesign -d …`（对文件）、`ps`、`df` 可以。这些都留到 Task 8。
- `tccutil` 只用于 rapp 自己的 bundle id `com.rapp.rapp`（常量 `BUNDLE_ID`），参数从不来自 IPC 或配置。
- 不打开 GUI 窗口，不发合成输入；用户正在用这台 Mac。`flutter build macos --debug` 只当编译检查，不运行产物。
- 不 push、不 merge、不换分支（留在 `feat/main-window-s2-s6`），不开 subagent。

**Git 规则（用户和别的 agent 会同时在这棵树里改文件）：**
- 只按名字暂存（`git add <paths>`）。不用 `git add -u`、`-A`、`.`。
- 不 `git stash`、`checkout`、`restore`、`reset`。需要基线就跳过，或者在 scratchpad 里 `git worktree add`。
- 不碰的文件（不加、不提交、不改、不移、不删）：README.md、`docs/superpowers/specs/2026-11-12-rapp-design-language.md`、`docs/archives/`、所有未跟踪的 spec 文件（`2026-11-12-rapp-relay-security-requirements.md`、`…-requirements-feedback.md`、`…-conversation-design.md`）、`Claude outputs/`。
- 另一个 agent 在改 `gui/lib/ui/main_state.dart`、`projects.dart`、`projects_tab.dart`。本计划不改这三个文件。Task 6 动手前先 `git status --short gui/lib/ui/main_window.dart gui/lib/ui/devices_tab.dart gui/lib/main.dart`，有别人未提交的改动就停下报告。
- 提交信息末尾：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

**数据规则：**
- 不记密码、令牌、secret、relay key、打的字、剪贴板内容。升级日志不记 URL（K10），`reason` 只写退出码和固定短句。
- 安全姿态（用户决定）：门禁只在自建 relay。不加签名体系、审批步骤、确认弹窗（规格 §1 不做、§9）。`ConfirmButton` 点两次是设计语言的不可撤销规则，不算审批。
- 写文件都用 `rapp_net::config::write_json` / `write_private`（tmp + rename，0600）。

**测试与命令：**
- Rust：`export PATH="$HOME/.cargo/bin:$PATH"; cd rust && cargo test --workspace && cargo clippy --workspace --all-targets`（不跑 `cargo fmt`）。开工前跑一遍，记下通过数当起点。
- Flutter：`cd gui && $HOME/development/flutter/bin/flutter analyze && $HOME/development/flutter/bin/flutter test`。长输出重定向到文件，再看末尾。
- 脚本：`bash scripts/test-package.sh`（Task 1 新建，Task 7 扩充），最后一行 `ALL OK`。
- Swift 不改。只在 Task 8 跑 `swift test` 和 `./scripts/check.sh`（`.build-logs/check.log` 末行 `EXIT=0`）。
- 每个 Task 一个提交；只 `git add <路径>`。

**代码规则：**
- `rapp-update` 只依赖 `anyhow`、`serde`、`serde_json`、`sha2`、`rapp-net`，dev 依赖 `tempfile`。不加 HTTP 库，不加 tokio：它是同步库，service 在 `spawn_blocking` 里调用。
- 外部程序一律用绝对路径常量：`/usr/bin/curl`、`/usr/bin/ditto`、`/usr/bin/codesign`、`/usr/bin/plutil`、`/usr/bin/tccutil`、`/usr/bin/open`、`/bin/ps`、`/bin/df`。
- 新 IPC 命令都是新增的，旧 GUI 不认识就忽略；`status` 只加字段。
- GUI：
  - 只用 `RappTokens`；可点控件高度 ≥ 48px；不可撤销的用 `ConfirmButton`（3 秒复原），其余用 `RappButton.secondary`，「立即升级」用 `RappButton.primary`；
  - 词只用设计语言 §9 和规格 §5、§3.2 给的按钮名；
  - 每个 UI 任务交付前对一遍设计语言 §0 三条检查：① 升级、重置都在 本机 区块里，小点在边缘；② 只有小点，不弹窗、不抢焦点；③ 装完、忽略、升级失败后点击「检查更新」，小点都自己消失。

## Review Focus

1. **安装中途失败不能把 `/Applications/rapp.app` 弄丢**：K12 第 ④ 步失败要还原；EXDEV 要走 ditto；`PermissionDenied` 要归为 `NeedsAdmin` 并且不留 `.rapp-new.app`。测试：Task 3 `second_rename_failure_restores_old_app`、`exdev_falls_back_to_ditto`、`permission_denied_is_needs_admin_and_cleans_up`。
2. **有人在用时绝不自动安装**：A 侧有会话、bundle 里有别的进程、ps 失败、不是 launchd 拉起、`auto_update=false`，这几种都不装；没人在用时才装，写标记，请求重启。测试：Task 4 `sessions_block_auto_install`、`gui_process_blocks_auto_install`、`ps_failure_counts_as_in_use`、`not_launchd_never_installs`、`idle_installs_writes_marker_and_requests_restart`。
3. **签名变了不能悄悄装上**：指定要求不同就进 `needs_confirm`，自动安装和不带确认的 `update_apply` 都拒绝；带 `confirm_signature_change:true` 才装。测试：Task 3 `different_dr_needs_confirm`；Task 4 `signature_change_waits_for_confirm`。
4. **tccutil 只碰 `com.rapp.rapp`，辅助功能重置不生效时要说实话**：测试：Task 5 `permissions_reset_runs_tccutil_for_rapp_only`、`accessibility_reset_failure_is_reported`；Task 6 `reset failure shows the manual steps`。
5. **下载校验和日志**：sha、size 不对都拒绝，并删掉 `.part`；`.part` 能续传；版本号不能穿越路径；日志里没有 URL。测试：Task 3 `bad_sha_deletes_part_and_fails`、`partial_part_resumes_with_c_dash`、`real_curl_resumes_from_local_server`；Task 2 `version_with_path_chars_is_rejected`；Task 4 `update_logs_never_contain_urls`。

---

### Task 1: 稳定签名、打包检查、postinstall chown

**Files:**
- Create: `scripts/lib/sign-check.sh`（只定义函数，不执行任何东西）
- Create: `scripts/test-package.sh`
- Modify: `scripts/package-macos.sh`（`source scripts/lib/sign-check.sh`；签名顺序 K1；runtime K2；`-i` 标识和核对 K3；最后的 cdhash 检查 K4）
- Modify: `scripts/pkg/postinstall`（K4 的 chown，放在 `launchctl bootstrap` 之前）

**Interfaces:**
- Consumes：现有 `identity()` 的 sed 写法；`security find-identity -v -p basic` 的输出格式 `  1) <40 位 SHA> "<名字>: …"`。
- Produces（`sign-check.sh`）：
  - `pick_identity <find-identity 输出文本> [<RAPP_SIGN_APP 是否设置: set|unset>] [<RAPP_SIGN_APP 的值>]`，打印 `<kind> <sha>`，kind ∈ `devid|dev|custom|adhoc`；adhoc 时 sha 是 `-`。
  - `runtime_flags <kind>`：只有 devid 打印 `--options runtime --timestamp`。
  - `is_cdhash_dr <codesign -d -r- 的输出>`：`designated => cdhash H"` 时返回 0。
  - `identifier_of <codesign -d -v 的输出>`：打印 `Identifier=` 后面的值。
  - `EXPECTED_IDS`：`rapp-service:com.rapp.service rapp-hub:com.rapp.hub rapp-host:com.rapp.host rapp-client:com.rapp.client`。

- [ ] **Step 1: 写失败的测试** — `scripts/test-package.sh`（`set -euo pipefail`，每条 `check "<名字>" <命令>`，失败就打印名字并 `exit 1`，全过打印 `ALL OK`）：
  - `pick prefers developer id`：输入同时有 `Developer ID Application: X (T5G56DH47L)` 和 `Apple Development: bruce lee (M753G3H4R8)` 两行 → 打印 `devid <DevID 的 SHA>`。
  - `pick falls back to apple development`：只有 Apple Development 一行 → `dev <它的 SHA>`。
  - `pick with nothing is adhoc`：空输入 → `adhoc -`。
  - `explicit empty RAPP_SIGN_APP forces adhoc`：`set ""` → `adhoc -`。
  - `explicit sha of a developer id is devid`：`set <DevID 的 SHA>` → `devid <SHA>`；`set <Apple Dev 的 SHA>` → `custom <SHA>`。
  - `runtime only for devid`：`runtime_flags devid` 含 `--options runtime`；`dev`、`custom`、`adhoc` 输出为空。
  - `cdhash dr detected`：录好的 `designated => cdhash H"dee3c9…"` → 0；`designated => identifier "com.rapp.rapp" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: bruce lee (M753G3H4R8)" …` → 非 0。
  - `identifier parsed`：`Executable=…\nIdentifier=com.rapp.host\nFormat=…` → `com.rapp.host`。
  - `postinstall chowns before bootstrap`：`grep -n 'chown -R "$USER_NAME":staff "$APP"'` 的行号 < `grep -n 'launchctl bootstrap'` 的行号。
  - `package script has the adhoc gate`：`grep -q 'RAPP_ALLOW_ADHOC' scripts/package-macos.sh`，并且 `grep -q -- '-i com.rapp.service'`。
  - `scripts parse`：`bash -n` 过 `package-macos.sh`、`pkg/postinstall`、`lib/sign-check.sh`。
- [ ] **Step 2: 跑测试确认失败** — `bash scripts/test-package.sh` → `sign-check.sh` 不存在。
- [ ] **Step 3: 实现**：
  - `package-macos.sh` 签名段改成：`read KIND SIGN_ID < <(pick_identity "$(security find-identity -v -p basic)" "${RAPP_SIGN_APP+set}" "${RAPP_SIGN_APP-}")`。
    - `SIGN=(codesign --force $(runtime_flags $KIND) --sign "$SIGN_ID")`；
    - 不是 adhoc 时签 Frameworks；
    - 每个子程序加 `-i`；app 照旧 `--preserve-metadata=entitlements`；
    - `codesign --verify --deep --strict` 之后逐个用 `identifier_of` 核对 `EXPECTED_IDS`；
    - 打印 `codesign -d -r- "$APP"`，`is_cdhash_dr` 为真并且 `RAPP_ALLOW_ADHOC` 不是 1 就 `echo "release build is ad-hoc (cdhash DR); set RAPP_ALLOW_ADHOC=1 for local builds" >&2; exit 1`。
  - 开头 `echo "== signing: …"` 改成打印 KIND。
  - 文件头注释补上签名顺序和 `RAPP_ALLOW_ADHOC`。
  - postinstall 加 K4 那一行，前面加 `[ -n "$USER_NAME" ] &&`。
- [ ] **Step 4: 跑测试确认通过** — `bash scripts/test-package.sh` → `ALL OK`。**不运行** `package-macos.sh`。
- [ ] **Step 5: Commit** — `git add scripts/lib/sign-check.sh scripts/test-package.sh scripts/package-macos.sh scripts/pkg/postinstall`，`feat(pkg): stable signing identity, fixed identifiers, ad-hoc release gate`

---

### Task 2: `rapp-update` crate 的纯逻辑

**Files:**
- Create: `rust/update/Cargo.toml`（`name = "rapp-update"`，`version.workspace = true` 等；依赖见代码规则）、`rust/update/src/lib.rs`
- Modify: `rust/Cargo.toml`（members 加 `update`；`[workspace.dependencies]` 加 `rapp-update = { path = "update" }`）
- Test: `rust/update/src/lib.rs` 里的 `#[cfg(test)] mod tests`

**Interfaces:**
- Consumes：`rapp_net::config::{read_json, write_json}`。
- Produces（`lib.rs`）：
  - `pub const BUNDLE_ID: &str = "com.rapp.rapp";`
  - `pub const DEFAULT_URL: &str = "https://github.com/wizlijun/rapp-releases/releases/latest/download/latest.json";`
  - `pub const PLATFORM: &str = "macos-arm64";`
  - `pub const CHECK_EVERY_SECS: u64 = 20 * 3600;`
  - `pub fn parse_version(s: &str) -> Option<(u64, u64, u64)>`；`pub fn is_newer(latest: &str, current: &str) -> bool`（K6）
  - `pub struct Asset { pub url: String, pub sha256: String, pub size: u64 }`；`pub struct Manifest { pub version: String, pub published_at: Option<String>, pub notes: Option<String>, pub asset: Asset }`
  - `pub fn parse_manifest(bytes: &[u8]) -> Result<Option<Manifest>, String>`：没有 `assets.macos-arm64` 时返回 `Ok(None)`；JSON 坏、缺字段、版本解析不了、sha 不是 64 位十六进制、`size == 0`、url 不是 `https://` 开头，都返回 `Err(<短句>)`；不认识的字段忽略（K10）
  - `#[derive(Default, Serialize, Deserialize)] pub struct Cache { latest_version: Option<String>, last_checked_at: Option<u64>, dismissed_version: Option<String> }`（字段 pub，`#[serde(default)]`）
  - `pub fn load_cache(path: &Path) -> Cache`（从不报错）；`pub fn save_cache(path: &Path, c: &Cache) -> io::Result<()>`
  - `pub fn should_check(c: &Cache, now: u64) -> bool`（K7）；`pub fn offer(c: &Cache, current: &str) -> Option<String>`：`latest_version` 比 current 新，并且不等于 `dismissed_version`
  - `pub fn bundle_of(exe: &Path) -> Option<PathBuf>`（K16）
  - `pub fn parse_dr(codesign_output: &str) -> Option<String>`：取 `designated => ` 后面的部分，去掉首尾空白
  - `pub fn is_cdhash_requirement(dr: &str) -> bool`
  - `pub fn release_page(asset_url: &str) -> String`（K14）
  - `pub fn now_secs() -> u64`

- [ ] **Step 1: 写失败的测试**：
  - `is_newer_compares_numerically`：`is_newer("0.10.0","0.9.9")`、`("1.0.0","0.99.99")`、`("v0.5.0","0.4.1")` 都为真；`("0.4.1","0.4.1")`、`("0.4.0","0.4.1")` 为假。
  - `bad_or_suffixed_versions_are_not_newer`：`"0.5.0-beta"`、`"0.5"`、`""`、`"0.5.0.1"`、`"x.y.z"` 对 `"0.4.1"` 都为假；当前版本坏了（`"dev"`）也为假。
  - `version_with_path_chars_is_rejected`：`parse_version("../0.5.0")`、`"0.5.0/.."`、`"0.5.0\n"` 都是 `None`（Review Focus 5）。
  - `manifest_full_roundtrip`：规格 §4.2 的样例，外加 `"extra":1` → `Ok(Some(m))`，`m.asset.size == 31457280`，`m.notes == Some("一句话说明，GUI 原样显示")`。
  - `manifest_without_platform_is_none`：`assets` 只有 `"windows-x64"` → `Ok(None)`。
  - `manifest_missing_fields_is_err`：分别缺 `version`、`assets.macos-arm64.sha256`、`size`；sha 长度 63；url 是 `http://…`；`size: 0` → 都是 `Err`。
  - `cache_missing_or_corrupt_checks_now`：路径不存在 → `Cache::default()`，`should_check` 为真；文件内容是 `{x` → 同样。
  - `twenty_hour_rule`：`last = 1_000_000`，`now = last + 20*3600 - 1` → 假；`now = last + 20*3600` → 真；`now = last - 5` → 真。
  - `dismissed_only_hides_that_version`：缓存 `latest = "0.5.0"`，`dismissed = "0.5.0"` → `offer(c, "0.4.1") == None`；`latest` 改成 `"0.5.1"` → `Some("0.5.1")`；`latest == current` → `None`。
  - `cache_save_load_roundtrip`：在临时目录里 save 再 load，三个字段原样；文件权限 0600。
  - `bundle_of_only_inside_app`：`/Applications/rapp.app/Contents/MacOS/rapp-service` → `Some("/Applications/rapp.app")`；`/x/rust/target/debug/rapp-service` → `None`；`/x/rapp/Contents/MacOS/rapp-service`（上级目录不以 `.app` 结尾）→ `None`（覆盖规格 §8「不在 `.app` 里不工作」的纯逻辑部分）。
  - `parse_dr_and_cdhash`：输入 `"Executable=/x\ndesignated => cdhash H\"dee3c9\"\n"` → `is_cdhash_requirement` 为真；Apple Development 那种形式为假；没有 `designated` 行 → `None`。
  - `release_page_from_github_asset`：`…/releases/download/v0.5.0/rapp-0.5.0-macos-arm64.zip` → `https://github.com/wizlijun/rapp-releases/releases/tag/v0.5.0`；`https://vps.example/rapp/x.zip` → 原样返回。
- [ ] **Step 2: 跑测试确认失败** — `cargo test -p rapp-update` → crate 不存在或函数未定义。
- [ ] **Step 3: 实现** 上面的签名。
- [ ] **Step 4: 跑测试确认通过** — `cargo test -p rapp-update && cargo clippy -p rapp-update --all-targets` 无警告。
- [ ] **Step 5: Commit** — `git add rust/Cargo.toml rust/Cargo.lock rust/update/Cargo.toml rust/update/src/lib.rs`，`feat(update): version, manifest, cache and check rules`

---

### Task 3: 下载、校验、安装（可注入 Runner）

**Files:**
- Create: `rust/update/src/runner.rs`、`rust/update/src/fake.rs`（`pub mod fake`，不加 `cfg(test)`，testkit 也要用）、`rust/update/src/fetch.rs`、`rust/update/src/apply.rs`
- Modify: `rust/update/src/lib.rs`（`pub mod` 加 re-export）
- Test: 各文件里的 `#[cfg(test)] mod tests`

**Interfaces:**
- Consumes：Task 2 的 `Manifest`、`Asset`、`parse_version`、`parse_dr`、`parse_manifest`。
- Produces：
  - `runner.rs`：
    - `pub struct Out { pub code: i32, pub stdout: String, pub stderr: String }`，加上 `Out::ok(stdout)`、`Out::fail(code, stderr)`
    - `pub trait Runner: Send + Sync { fn run(&self, prog: &str, args: &[String]) -> io::Result<Out>; fn rename(&self, from: &Path, to: &Path) -> io::Result<()> { std::fs::rename(from, to) } }`
    - `pub struct SystemRunner;`（`std::process::Command`，stdin 为 null）
    - 常量 `CURL`、`DITTO`、`CODESIGN`、`PLUTIL`、`TCCUTIL`、`OPEN`、`PS`、`DF`
  - `fake.rs`：
    - `pub struct FakeRunner`，以及 `FakeRunner::new()`
    - `.on(prog, impl Fn(&[String]) -> Out + Send + Sync + 'static) -> Self`：处理函数可以写文件，例如假 curl 按 `-o` 写内容
    - `.rename_fails(nth: usize, err: io::Error) -> Self`：第 nth 次 rename 失败，从 1 开始数
    - `.calls() -> Vec<(String, Vec<String>)>`
    - 没编排的程序返回 `Err(io::ErrorKind::NotFound)`
    - 小工具 `pub fn arg_after<'a>(args: &'a [String], flag: &str) -> Option<&'a str>`
  - `fetch.rs`：
    - `pub enum Stage { Download, Verify, Install, Restart }`，带 `as_str()`；`pub struct Failure { pub stage: Stage, pub reason: String }`
    - `pub fn fetch_manifest(r: &dyn Runner, url: &str, cache_dir: &Path) -> Result<Option<Manifest>, String>`（K10）
    - `pub fn free_bytes(r: &dyn Runner, dir: &Path) -> Option<u64>`
    - `pub fn part_path(dir: &Path, v: &str) -> PathBuf`（`rapp-<v>.zip.part`）；`pub fn zip_path(dir: &Path, v: &str) -> PathBuf`
    - `pub fn sha256_file(p: &Path) -> io::Result<String>`（小写十六进制）
    - `pub fn download(r: &dyn Runner, dir: &Path, m: &Manifest) -> Result<(PathBuf, u64), Failure>`：返回 zip 路径和这次实际下载的字节数（K11）
  - `apply.rs`：
    - `pub fn bundle_version(r: &dyn Runner, app: &Path) -> Option<String>`（K5）；`pub fn designated(r: &dyn Runner, app: &Path) -> Option<String>`（`codesign -d -r- <app>`，stdout 和 stderr 合起来交给 `parse_dr`）
    - `pub fn verify(r: &dyn Runner, zip: &Path, dir: &Path, version: &str, current_dr: &str) -> Result<Verified, Failure>`
      - `pub struct Verified { pub app: PathBuf, pub signature_changed: bool }`
      - 步骤：删 `<dir>/<v>` → `ditto -x -k <zip> <dir>/<v>` → 要求 `<dir>/<v>/rapp.app` 存在 → `codesign --verify --deep --strict` 退出 0 → `bundle_version == version` → `designated != current_dr` 时 `signature_changed`
    - `pub fn verify_local(r: &dyn Runner, app: &Path) -> Result<(), Failure>`（只跑 `codesign --verify`，回到上一版用）
    - `pub enum InstallError { NeedsAdmin, Failed(String) }`
    - `pub fn install(r: &dyn Runner, new_app: &Path, bundle: &Path, previous_dir: &Path) -> Result<(), InstallError>`（K12）
    - `#[derive(Serialize, Deserialize)] pub struct Marker { pub from: String, pub to: String, pub at: u64, pub gui_was_open: bool, pub mode: String, #[serde(default)] pub perms_before: serde_json::Value }`
    - `pub fn write_marker(home: &Path, m: &Marker) -> io::Result<()>`；`pub fn read_marker(home: &Path) -> Option<Marker>`（读不出就删文件，返回 None）；`pub fn clear_marker(home: &Path)`
    - `pub const MARKER: &str = "update-applied.json";`

- [ ] **Step 1: 写失败的测试**（全部在 `tempfile::tempdir()` 里；`bundle` 是 `<tmp>/Applications/rapp.app`，里面放一个 `Contents/marker` 文件，用来认出是哪一版）：
  - `fetch_manifest_uses_fixed_flags`：假 curl 往 `-o` 写规格的样例 → `Ok(Some(_))`；调用参数里有 `-fsSL`、`--max-time`、`30`、`--max-filesize`、`65536`。
  - `fetch_failure_reason_has_no_url`：假 curl 返回 `Out::fail(22, "The requested URL returned error: 404 https://x/latest.json?token=1")` → `Err(e)`，`e == "curl 退出码 22"`，`!e.contains("http")`。
  - `bad_sha_deletes_part_and_fails`：假 curl 写入 size 个字节，但内容不对 → `Failure{stage:Download}`，`reason == "sha256 不对"`；`.part`、`.zip` 都不存在（Review Focus 5）。
  - `wrong_size_is_rejected`：写入 size−1 个字节 → `reason == "大小不对"`；`.part` 留着（还能续）。
  - `partial_part_resumes_with_c_dash`：先放一个 size/2 的 `.part`；假 curl 检查参数里有 `-C`、`-`，并把剩下的一半追加上去 → `Ok((zip, bytes))`，`bytes == size - size/2`，sha 对得上，`.part` 已经改名成 `.zip`。
  - `full_part_skips_curl` 和 `oversized_part_is_deleted`：前者 calls 里没有 curl；后者 curl 被调用之前 `.part` 已经删掉了（用假 curl 里的断言检查）。
  - `curl_33_deletes_part`：退出码 33 → `.part` 不存在。
  - `not_enough_space_does_not_download`：假 df 输出 `Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 100 50 10 50% /` → `Failure{Download}`，原因以 `可用空间不够` 开头；calls 里没有 curl。
  - `real_curl_resumes_from_local_server`（只用 `SystemRunner` 的 curl，并且只连本机）：
    - 起一个 `std::net::TcpListener::bind("127.0.0.1:0")` 小服务器，支持 `Range: bytes=N-` 并回 206；
    - 先放一个前 1000 字节的 `.part`；
    - 用 `Asset{url: "http://127.0.0.1:<port>/a.zip"}` 直接调 `download` → 成功；服务器收到的 Range 是 `bytes=1000-`。
    - `/usr/bin/curl` 不存在就 `return`（打印 skip）。
  - `verify_happy_path`：假 ditto 在目标目录建 `rapp.app/Contents`，假 codesign `--verify` 返回 0、`-d -r-` 返回与 current 相同的 DR，假 plutil 返回 `"0.5.0"` → `Ok(Verified{signature_changed:false})`。
  - `different_dr_needs_confirm`：`-d -r-` 返回另一个 DR → `signature_changed == true`（Review Focus 3）。
  - `verify_rejects_bad_signature_and_wrong_version`：`--verify` 退出 1 → `Failure{Verify}`；plutil 返回 `"0.4.9"` → `Failure{Verify}`，原因含 `0.4.9`。
  - `install_swaps_and_keeps_one_previous`：先放一个旧的 `previous/rapp.app`（marker=old0）。装新版以后，`bundle` 的 marker 是 new，`previous/rapp.app` 的 marker 是当前版，old0 已经没了；`.rapp-new.app` 不存在。
  - `second_rename_failure_restores_old_app`：`rename_fails(3, …)`（① 是第 1 次，③ 是第 2 次，④ 是第 3 次）→ `Err(Failed(_))`；`bundle` 的 marker 仍是当前版；`.rapp-new.app` 不存在（Review Focus 1）。
  - `exdev_falls_back_to_ditto`：`rename_fails(2, io::Error::from_raw_os_error(18))`；假 ditto 真的复制目录（`cp -R` 的等价实现，用 `std::fs` 递归写）→ `Ok(())`；calls 里有 `ditto <bundle> <previous>/rapp.app`；源目录已经删掉（Review Focus 1）。
  - `permission_denied_is_needs_admin_and_cleans_up`：`rename_fails(2, PermissionDenied)` → `Err(NeedsAdmin)`；`bundle` 不动；`.rapp-new.app` 不存在（Review Focus 1）。
  - `rollback_swaps_current_and_previous`：`install(r, previous/rapp.app, bundle, previous_dir)` → `bundle` 变成旧版，`previous/rapp.app` 变成刚才的当前版。
  - `marker_roundtrip_and_corrupt_is_removed`：写入再读出，字段原样；把文件内容写成 `{x` → `None`，文件已删。
- [ ] **Step 2: 跑测试确认失败** — `cargo test -p rapp-update` → 模块未定义。
- [ ] **Step 3: 实现** 上面的签名。`download` 不自己算进度，service 读 `.part` 的大小（K11）。
- [ ] **Step 4: 跑测试确认通过** — `cargo test -p rapp-update && cargo clippy -p rapp-update --all-targets`。
- [ ] **Step 5: Commit** — `git add rust/update/src/lib.rs rust/update/src/runner.rs rust/update/src/fake.rs rust/update/src/fetch.rs rust/update/src/apply.rs rust/update/Cargo.toml rust/Cargo.lock`，`feat(update): download, verify and atomic install behind a Runner`

---

### Task 4: service 接入：定时检查、IPC、没人在用、重启

**Files:**
- Create: `rust/service/src/update.rs`
- Modify:
  - `rust/service/Cargo.toml`（加 `rapp-update.workspace = true`）
  - `rust/service/src/lib.rs`（`Opts` 加 `runner`、`update`；`pub use rapp_update::{Runner, SystemRunner}`；`pub struct UpdateOpts`；`Service::restart_wanted()`；`start` 里 spawn 升级任务，并处理标记 K15）
  - `rust/service/src/state.rs`（`runner`、`update: Mutex<update::UpdState>`、`update_opts: Option<UpdateOpts>`、`restart: watch::Sender<bool>`；`status()` 加 `update` 字段 K19）
  - `rust/service/src/config.rs`（`update_url: Option<String>`、`auto_update: Option<bool>`、`check_updates: Option<bool>`，默认值由访问器给：`DEFAULT_URL`、true、true）
  - `rust/service/src/ipc.rs`（新命令；每条连接一个 `oneshot`，K21）
  - `rust/service/src/main.rs`（K24、K25）
  - `rust/testkit/tests/common/mod.rs`（`start_service` 补上 `runner: Arc::new(FakeRunner::new()), update: None`；新增 `start_service_with(home, bins, runner, update)`）
  - `rust/testkit/Cargo.toml`（dev 依赖加 `rapp-update`）
- Test: `rust/testkit/tests/update.rs`（新）

**Interfaces:**
- Consumes：Task 2、3 的全部；现有 `State`、`notify()`、`state.log.event`、`workers::close_all`、`ipc::handle`、`conn`。
- Produces：
  - `pub struct UpdateOpts { pub bundle: PathBuf, pub launchd: bool, pub cache_dir: PathBuf, pub first_check: Duration, pub tick: Duration, pub idle_poll: Duration, pub healthy_after: Duration, pub gui_wait: Duration }`
    - `UpdateOpts::system(bundle) -> Self`：30s、1h、60s、30s、10s，`launchd = parent_id() == 1`，`cache_dir = $HOME/Library/Caches/rapp/update`
  - `update.rs`：
    - `pub struct UpdState { state: &'static str, latest, progress: Option<u8>, error, notes, needs_confirm: bool, needs_admin: bool, page, busy: bool, ready_app: Option<PathBuf>, dr_current: Option<String> }`
    - `pub fn status_json(state: &State) -> Value`（K19 的全部字段，加上 `current`）
    - `pub fn spawn(state: Arc<State>) -> JoinHandle<()>`：`update_opts` 为 None 时不启动
    - `pub async fn on_start(state: &Arc<State>)`（K15；Task 5 在这里接 K23）
    - `pub async fn check_now(state: &Arc<State>)`；`pub fn dismiss(state: &State, v: &str) -> Value`；`pub async fn apply(state: &Arc<State>, confirm: bool, closed: oneshot::Receiver<()>) -> Value`；`pub async fn rollback(state: &Arc<State>, closed: oneshot::Receiver<()>) -> Value`；`pub fn set(state: &State, auto: Option<bool>, check: Option<bool>) -> Value`
    - `pub async fn in_use(state: &State) -> Option<String>`（K17，返回原因）
  - IPC（全部回 JSON 一行）：`update_status` → `{ok:true, …status_json}`；`update_check` → `{ok:true}`（后台跑）；`update_apply {confirm_signature_change?}`（K20）；`update_dismiss {version}`；`update_rollback`；`set_update {auto_update?, check_updates?}`（写配置并 `notify()`）。
  - 日志：`update_check {result, latest?, reason?}`、`update_download {version, result, bytes}`、`update_applied {from, to, mode}`、`update_failed {stage, reason}`，字段名和规格 §7 一致。
  - `Service::restart_wanted(&self) -> impl Future<Output = ()>`

- [ ] **Step 0: 只读核对 ps 格式** — 在这台 Mac 上跑 `ps -axo pid=,ppid=,comm= | head -5` 和 `ps -axo pid=,ppid=,comm= | grep -c '/Contents/MacOS/'`。只看进程表，不对任何进程做事。
  - 如果 `comm` 是完整路径，K17 照写。
  - 如果被截断，或者不是路径，改用 `args=`，按「以 `<bundle>/Contents/` 开头」匹配；把结果写进 `update.rs` 的注释。
- [ ] **Step 1: 写失败的测试** — `rust/testkit/tests/update.rs`：
  - 一个辅助函数造假的 bundle 和 `FakeRunner`：
    - `<tmp>/Applications/rapp.app/Contents/marker`；
    - 假 plutil 按路径回版本：当前 `0.4.1`，`<cache>/0.5.0/…` 回 `0.5.0`；
    - 假 codesign：`-d -r-` 回固定 DR，`--verify` 回 0；
    - 假 curl：`latest.json.tmp` 写 manifest，zip 写固定字节，sha 和 size 预先算好；
    - 假 ditto 建 `rapp.app`；假 df 回很大的可用空间；
    - 假 ps 默认只有自己（`std::process::id()`）；假 open 只记下调用。
  - `UpdateOpts` 用很短的时长：first_check 50ms、tick 50ms、idle_poll 50ms、healthy_after 200ms、gui_wait 300ms，`launchd: true`。
  - `service_json` 加 `"update_url":"https://example.invalid/latest.json"`。
  - 测试列表：
    - `not_in_bundle_is_off`：`update: None` → `status.update.state == "off"`；FakeRunner 的 calls 为空。
    - `finds_downloads_and_auto_installs_when_idle`（`idle_installs_writes_marker_and_requests_restart`）：
      - 等 `svc.restart_wanted()`（≤ WAIT）；
      - `bundle` 的 marker 是 new，`<home>/previous/rapp.app` 存在；
      - `<home>/update-applied.json` 里 `{from:"0.4.1", to:"0.5.0", mode:"auto", gui_was_open:false}`；
      - 日志依次有 `update_check{result:"available", latest:"0.5.0"}`、`update_download{version:"0.5.0", result:"ok"}`。
    - `sessions_block_auto_install`：先开一个 echo 会话（复用 `open_echo` 的写法），状态到 `ready` 以后再等 3 个 idle_poll，`bundle` 不变，`restart_wanted` 没有触发；结束会话以后 ≤ WAIT 内装好（Review Focus 2）。
    - `gui_process_blocks_auto_install`：假 ps 多一行 `999 1 <bundle>/Contents/MacOS/rapp` → 一直 `ready`，不装；去掉这一行以后装好。另外，ppid 是自己的 `<bundle>/Contents/MacOS/rapp-host` 不算有人在用。
    - `ps_failure_counts_as_in_use`：假 ps 返回退出码 1 → 不装。
    - `not_launchd_never_installs`：`launchd: false` → 停在 `ready`；`update_apply` 回 `ok:false`，带 `page`。
    - `auto_update_off_downloads_but_waits`：`auto_update:false` → 到 `ready`，不装；`update_apply` 回 `{ok:true}`，然后关掉这条 IPC 连接 → 装好，标记里 `mode:"manual", gui_was_open:true`。
    - `signature_change_waits_for_confirm`：新 app 的 DR 不一样 → `ready`，并且 `needs_confirm:true`；不装；`update_apply{}` 回 `{ok:false,error:"需要确认"}`；`update_apply{confirm_signature_change:true}` 加断开连接 → 装好（Review Focus 3）。
    - `manual_apply_with_sessions_is_refused`：有会话时 `update_apply` 回 `ok:false`，error 含 `个远程会话`。
    - `manual_apply_reopens_gui_when_still_in_use`：GUI 进程一直在 ps 里 → 300ms+300ms 后状态 `failed`，error 是 `rapp 还开着`，calls 里有 `open <bundle>`。
    - `dismiss_hides_that_version_and_check_clears_it`：
      - `update_dismiss{version:"0.5.0"}` → `update.dismissed:true`，此后不装；
      - `update_check` → 缓存里 `dismissed_version` 是 null，重新走流水线。
    - `check_failure_keeps_cache_and_logs`：假 curl 回 22 → 日志 `update_check{result:"failed", reason:"curl 退出码 22"}`；`update.json` 没有被写。
    - `marker_on_start_logs_applied_and_reopens_gui`：
      - 预先写好标记 `{from:"0.4.0", to:"0.4.1", mode:"manual", gui_was_open:true}`；
      - 启动后日志里有 `update_applied{from:"0.4.0", to:"0.4.1", mode:"manual"}`，calls 里有 `open <bundle>`；
      - 过 healthy_after 以后标记文件不在了，`cache_dir` 里的 zip 也不在了。
    - `marker_with_wrong_version_logs_restart_failure`：`to:"0.9.9"` → 日志 `update_failed{stage:"restart"}`，标记已删。
    - `progress_is_reported`：假 curl 分两次写，中间 sleep 1.2 秒 → 订阅者在 downloading 期间至少收到一次 `changed`，`status.update.progress` 在 1 到 99 之间出现过。
    - `rollback_swaps_and_restarts`：先装好一次（或预先放好 `previous/rapp.app`）→ `can_rollback:true`；`update_rollback` 加断开连接 → `bundle` 是上一版，标记 `mode:"rollback"`。
    - `update_logs_never_contain_urls`：跑完 happy path 后，`service.log` 全文不含 `example.invalid` 和 `https://`（Review Focus 5）。
    - `set_update_persists`：`set_update{auto_update:false}` → `service.json` 里 `auto_update:false`，`status.update.auto_update == false`。
- [ ] **Step 2: 跑测试确认失败** — `cargo test -p rapp-testkit --test update` → `UpdateOpts`、`restart_wanted` 未定义。
- [ ] **Step 3: 实现** 上面的签名。
  - 现有 `tests/service.rs` 等不改（`start_service` 补上默认值）。
  - `main.rs` 按 K24、K25 改；`std::process::exit(0)` 放在 `svc.stop()` 之后。
- [ ] **Step 4: 跑测试确认通过** — `cargo test --workspace && cargo clippy --workspace --all-targets` 全绿，通过数 = 起点 + 新增。
- [ ] **Step 5: Commit** — `git add rust/service/Cargo.toml rust/service/src/update.rs rust/service/src/lib.rs rust/service/src/state.rs rust/service/src/config.rs rust/service/src/ipc.rs rust/service/src/main.rs rust/testkit/Cargo.toml rust/testkit/tests/common/mod.rs rust/testkit/tests/update.rs rust/Cargo.lock`，`feat(service): background update check, idle install and restart`

---

### Task 5: `permissions_reset` 和 `permissions_lost_after_update`

**Files:**
- Modify:
  - `rust/service/src/ipc.rs`（`permissions_reset` 命令，异步分支，和 `permissions` 放在一起）
  - `rust/service/src/workers.rs`（`pub async fn reset_permissions(state) -> Value`）
  - `rust/service/src/state.rs`（`perms_lost: Mutex<bool>`；`set_permissions` 两项 ✓ 时清掉它；`status()` 加 `permissions_lost_after_update`）
  - `rust/service/src/update.rs`（`on_start` 里按 K23 置位；装之前把 `state.permissions` 放进标记的 `perms_before`）
- Test: `rust/testkit/tests/service.rs`（新增几个测试，放在 permissions 那几个旁边）、`rust/testkit/tests/update.rs`

**Interfaces:**
- Consumes：`workers::refresh_permissions(state, prompt)`、`state.runner`、`rapp_update::{BUNDLE_ID, runner::TCCUTIL}`、Task 4 的标记。
- Produces：
  - IPC `{"cmd":"permissions_reset"}` → `{ok:true, screen_recording_reset: bool, accessibility_reset: bool, permissions: {…}}`；tccutil 跑都跑不起来（`Err`）时，对应项为 false。
  - 日志 `permissions_reset {}`，没有别的字段。
  - `status.permissions_lost_after_update: bool`。

- [ ] **Step 1: 写失败的测试**：
  - `permissions_reset_runs_tccutil_for_rapp_only`（Review Focus 4）：
    - FakeRunner 编排 `/usr/bin/tccutil`：返回 0，并把 bins 里的 `perms` 写成两项都 false，模拟重置生效；
    - 起点两项 ✓；调 `permissions_reset`；
    - calls 里的 tccutil 恰好是 `["reset","ScreenCapture","com.rapp.rapp"]` 和 `["reset","Accessibility","com.rapp.rapp"]`，按这个顺序，没有别的 tccutil 调用；
    - 回复两个 `_reset` 都是 true，`permissions` 两项都是 false；
    - `host.log` 里有 `check --prompt`；日志里有 `permissions_reset`。
  - `accessibility_reset_failure_is_reported`（A1，Review Focus 4）：假 tccutil 对 ScreenCapture 回 0 并改掉 perms 里的 screen_recording，对 Accessibility 回 0 但什么都不改 → `screen_recording_reset:true`，`accessibility_reset:false`。
  - `tccutil_missing_reports_false`：没编排 tccutil → 两项都是 false，`ok:true`，仍然跑了 `check --prompt`。
  - `permissions_lost_after_update_set_and_cleared`（放在 `update.rs`）：
    - 标记带 `perms_before:{screen_recording:true, accessibility:true}`，`to` 等于当前版本；`perms` 文件里两项 false；
    - 启动后 `status.permissions_lost_after_update == true`；
    - 把 `perms` 改成两项 true，再调 `permissions` → 变成 false，订阅者收到 `changed`。
  - `no_marker_means_not_lost`：没有标记、两项都是 false → `false`。
  - `install_records_perms_before`：在 Task 4 的 happy path 里，标记的 `perms_before` 等于装之前的 `status.permissions`。
- [ ] **Step 2: 跑测试确认失败** — `cargo test -p rapp-testkit --test service --test update`。
- [ ] **Step 3: 实现** 上面的改动。tccutil 在 `spawn_blocking` 里跑；bundle id 只用常量。
- [ ] **Step 4: 跑测试确认通过** — `cargo test --workspace && cargo clippy --workspace --all-targets`。
- [ ] **Step 5: Commit** — `git add rust/service/src/ipc.rs rust/service/src/workers.rs rust/service/src/state.rs rust/service/src/update.rs rust/testkit/tests/service.rs rust/testkit/tests/update.rs`，`feat(service): reset rapp's own TCC records; flag permissions lost after update`

---

### Task 6: GUI 本机 › 版本与升级、重置按钮、小点

**Files:**
- Create: `gui/lib/update.dart`、`gui/lib/pages/update_section.dart`
- Modify:
  - `gui/lib/service_client.dart`（`ServiceStatus.update`、`permissionsLostAfterUpdate`；`ServiceConnection` 新方法；`ServiceMonitor` 包装）
  - `gui/lib/pages/permissions_panel.dart`（`onReset`，K29）
  - `gui/lib/pages/local_section.dart`（放 `UpdateSection`；`hooks`；K30 的引导）
  - `gui/lib/ui/devices_tab.dart`（`localBadge`，K27）
  - `gui/lib/ui/main_window.dart`（把 `updateBadge(monitor.status?.update)` 和 `hooks` 传下去）
  - `gui/lib/main.dart`（`_quit` 拆分，K28）
- Test:
  - `gui/test/update_test.dart`（新）、`gui/test/update_section_test.dart`（新）
  - `gui/test/permissions_panel_test.dart`、`gui/test/service_client_test.dart`、`gui/test/ui/devices_tab_test.dart`（都是加测试）

**Interfaces:**
- Consumes：Task 4、5 的 IPC；`ConfirmButton`、`RappButton`、`TabChip.leading`、`RappTokens`、`openSettingsPane`、`Permission.accessibility.settingsUrl`、`PermissionGuideDialog`。
- Produces：
  - `update.dart`（纯 Dart）：
    - `class UpdateInfo { final String current, state; final String? latest, error, notes, page; final int? progress; final bool autoUpdate, checkUpdates, needsConfirm, needsAdmin, dismissed, canRollback; static UpdateInfo? fromJson(Object? j); }`：j 不是 Map 就返回 null；缺字段时用默认值
    - `enum UpdateAction { check, apply, applyAnyway, dismiss, openPage }`
    - `({String line, List<UpdateAction> actions}) updateView(UpdateInfo u)`（K26）
    - `bool updateBadge(UpdateInfo? u)`（K27）
  - `service_client.dart`：
    - `ServiceStatus`：`final UpdateInfo? update; final bool permissionsLostAfterUpdate;`
    - `ServiceConnection`：`updateCheck()`、`updateApply({bool confirm = false})`、`updateDismiss(String v)`、`updateRollback()`、`setUpdate({bool? autoUpdate, bool? checkUpdates})`、`permissionsReset()`，都返回 `Future<Map<String, Object?>>`
    - `ServiceMonitor` 上有同名的包装方法
  - `update_section.dart`：`UpdateSection({required UpdateInfo info, required Future<void> Function() onCheck, required Future<void> Function(bool confirm) onApply, required Future<void> Function(String version) onDismiss, required Future<void> Function() onRollback, required Future<void> Function(bool) onSetAuto, required void Function(String url) onOpenPage})`
  - `local_section.dart`：`class UpdateHooks { const UpdateHooks({required this.confirmQuit, required this.quitNow}); final Future<bool> Function() confirmQuit; final Future<void> Function() quitNow; }`；`LocalSection(..., UpdateHooks? hooks)`
  - `devices_tab.dart`：`DevicesTab(..., bool localBadge = false)`
  - `main.dart`：`Future<bool> _confirmQuit({required String title, required String body, required String ok})`、`Future<void> _quitNow()`；`_quit` 改用这两个，文案不变

- [ ] **Step 1: 写失败的测试**：
  - `update_test.dart`：
    - `fromJson tolerates missing fields`：`{'current':'0.4.1','state':'idle'}` → `autoUpdate == true`，其余是 false 或 null；`fromJson(null) == null`。
    - `view per state`：表驱动，每个状态的 `line` 和 `actions` 都写成 K26 的原文。例如：
      - `downloading`、progress 45、latest `0.5.0` → `('正在下载 0.5.0（45%）', [])`；
      - `ready`、autoUpdate → `('0.5.0 已下载，没人在用时会自动装好', [apply, dismiss])`；
      - `ready`、needsConfirm → `('这一版换了签名，装上以后要重新授权屏幕录制和辅助功能', [applyAnyway, dismiss])`；
      - `ready`、needsAdmin → `('这次需要管理员密码', [openPage, dismiss])`；
      - `up_to_date` → `('当前 0.4.1 · 已是最新', [check])`；
      - `off` → `('开发构建，不检查更新', [])`；
      - `failed`、error `大小不对` → `('升级没有完成：大小不对', [check])`；
      - dismissed → `('当前 0.4.1 · 0.5.0 先不装', [check])`。
    - `badge only while an update is pending`：downloading、ready、installing 为真；dismissed、up_to_date、failed、off、null 为假。
  - `update_section_test.dart`（`wrap(...)`）：
    - `ready shows apply and dismiss`：点「立即升级」→ `onApply(false)`；点「这一版先不装」→ `onDismiss('0.5.0')`；按钮高度 ≥ 48。
    - `apply anyway confirms the signature change`：needsConfirm 时点「仍然安装」→ `onApply(true)`。
    - `rollback needs two taps`：canRollback 时点一次「回到上一版」→ 出现 `再点一次确认`，onRollback 没调用；再点 → 调用 1 次。canRollback 为 false 时没有这个按钮。
    - `auto switch calls set`：点「自动升级」开关 → `onSetAuto(false)`。
    - `notes shown only when ready`：ready 时显示 `find.text(notes)`，up_to_date 时没有。
    - `no accent colour`：区块里所有 `Container`/`DecoratedBox` 的颜色都不是 `t.accent`（设计语言 §1 原则 1）。
  - `permissions_panel_test.dart`：
    - `reset button under each missing row needs two taps`：一项 ✗ → 只有 1 个 `重置授权记录` 按钮；点一次不调用 onReset，再点调用 1 次；`onReset == null` 时没有这个按钮；两项都 ✓ 时也没有。
    - `reset failure shows the manual steps`（Review Focus 4，放在 `local_section` 的组件测试里，用 `FakeService` 回 `accessibility_reset:false`）：出现 `辅助功能的旧记录要在系统设置里删：选中 rapp，点「−」，再重新添加。` 和一个「打开系统设置」。
  - `service_client_test.dart`：
    - `status parses update and lost flag`：FakeService 回带 `update:{…}` 和 `permissions_lost_after_update:true` 的 status → 字段原样。
    - `update commands send the right json`：六个方法各发一次，FakeService 记下 `cmd` 和参数，例如 `updateApply(confirm:true)` → `{"cmd":"update_apply","confirm_signature_change":true}`，`setUpdate(autoUpdate:false)` → `{"cmd":"set_update","auto_update":false}`。
    - 旧 status 没有 `update` → `update == null`。
  - `devices_tab_test.dart` `local chip shows a quiet dot`：`localBadge:true` → `device-local` 下面有 `Key('update-dot')`，颜色是 `t.muted`，没有 `AnimationController`、`FadeTransition`；可访问标签含 `本机，有新版本`。为 false 时没有这个点。
  - `local_section` 组件测试（加到 `permissions_panel_test.dart`，那里已经有 FakeService 和 LocalSection 的写法）：
    - `lost after update shows the guide even if already shown`：`permission-guide-shown` 已经存在，status 带 `permissions_lost_after_update:true` → 弹出 `PermissionGuideDialog`；标记文件内容不变。
    - `apply asks to quit then quits`：`hooks.confirmQuit` 返回 true → FakeService 收到 `update_apply` → `quitNow` 被调 1 次；`confirmQuit` 返回 false → 没发 `update_apply`。
    - `apply error stays in the section`：FakeService 回 `{ok:false,error:'有 1 个远程会话在用这台电脑'}` → 显示这句话，`quitNow` 没调用。
- [ ] **Step 2: 跑测试确认失败** — `flutter test test/update_test.dart test/update_section_test.dart test/permissions_panel_test.dart test/service_client_test.dart test/ui/devices_tab_test.dart`。
- [ ] **Step 3: 实现** 上面的签名。
  - `UpdateSection` 放在 `LocalSection` 卡片里权限面板的下面，标题行写 `版本与升级`。
  - 「打开安装包」用 `Process.run('open', [page])`，只在 macOS 上。
  - 主窗口外壳不弹任何东西（K27）。
  - 开工前按 Git 规则检查那三个文件有没有别人的未提交改动。
- [ ] **Step 4: 跑测试确认通过** — `flutter analyze && flutter test` 全绿；`cd gui && FLUTTER_XCODE_ARCHS=arm64 $HOME/development/flutter/bin/flutter build macos --debug`（只编译，不运行）。对一遍设计语言 §0 三条检查。
- [ ] **Step 5: Commit** — `git add gui/lib/update.dart gui/lib/pages/update_section.dart gui/lib/service_client.dart gui/lib/pages/permissions_panel.dart gui/lib/pages/local_section.dart gui/lib/ui/devices_tab.dart gui/lib/ui/main_window.dart gui/lib/main.dart gui/test/update_test.dart gui/test/update_section_test.dart gui/test/permissions_panel_test.dart gui/test/service_client_test.dart gui/test/ui/devices_tab_test.dart`，`feat(gui): version and update section, reset permissions, quiet update dot`

---

### Task 7: 发布输出（zip、latest.json）和 `scripts/upgrade-relay.sh`

**Files:**
- Create: `scripts/lib/release.sh`、`scripts/upgrade-relay.sh`、`rust/relay/tests/version.rs`
- Modify:
  - `scripts/package-macos.sh`（签名、核对之后：zip、`latest.json`、打印 `gh release create` 那一行，K31）
  - `scripts/test-package.sh`（加测试）
  - `rust/relay/src/main.rs`（`--version`，K32；`USAGE` 里加一行）

**Interfaces:**
- Consumes：Task 1 的脚本结构；`VERSION`、`DIST`、`APP` 变量。
- Produces：
  - `release.sh`：`json_escape <s>`（转义 `\`、`"`、换行、制表符和其他控制字符）；`write_manifest <out> <version> <url> <sha256> <size> <notes> <published_at>`，输出规格 §4.2 的形状。
  - `dist/rapp-$VERSION-macos-arm64.zip`、`dist/latest.json`。
  - `upgrade-relay.sh <url>`：
    1. `$CURL -fL -o "$tmp" "$1"`，然后 `chmod +x`；
    2. `"$tmp" --version` 的输出必须以 `rapp-relay ` 开头，否则删掉 tmp、`exit 1`，不动旧文件；
    3. `mv "$tmp" "$RELAY_BIN"`；
    4. `$SYSTEMCTL restart rapp-relay`，`$SYSTEMCTL is-active rapp-relay` 必须输出 `active`。
    - 退出码：0 成功，1 失败。tmp 放在 `$(dirname "$RELAY_BIN")` 里，保证 `mv` 是原子的。
  - `rapp-relay --version` → stdout 是 `rapp-relay 0.3.0`（随 workspace 版本），退出码 0。

- [ ] **Step 1: 写失败的测试**：
  - `test-package.sh`：
    - `manifest is valid json with escaped notes`：`write_manifest "$tmp/l.json" 0.5.0 https://x/r.zip <64 个 a> 123 $'一句"话"\n第二行' 2026-11-20T08:00:00Z`，然后检查：
      - `plutil -convert xml1 -o /dev/null` 成功；
      - `plutil -extract version raw -o - "$tmp/l.json"` 是 `0.5.0`；
      - `plutil -extract assets.macos-arm64.size raw` 是 `123`；
      - `plutil -extract notes raw` 原样还原，包括引号和换行。
    - `default release base`：`grep -q 'wizlijun/rapp-releases/releases/download/v\$VERSION' scripts/package-macos.sh`。
    - `zip after verify`：在 `package-macos.sh` 里，`ditto -c -k --keepParent` 的行号大于 `codesign --verify --deep --strict` 的行号。
    - `upgrade-relay happy path`：在临时目录里放：
      - 假 `CURL`：往 `-o` 写一个 shell 脚本，`--version` 时打印 `rapp-relay 9.9.9`；
      - 假 `SYSTEMCTL`：把参数记进文件，`is-active` 时打印 `active`；
      - `RELAY_BIN=$tmp/bin/rapp-relay`，原来的内容是 old。
      - 跑完退出 0，`RELAY_BIN --version` 打印 `rapp-relay 9.9.9`，systemctl 的记录依次是 `restart rapp-relay`、`is-active rapp-relay`。
    - `upgrade-relay refuses a bad binary`：假 curl 写的东西 `--version` 打印 `oops` → 退出 1，`RELAY_BIN` 内容仍是 old，没有调用 systemctl，临时文件已删。
    - `bash -n` 过 `release.sh`、`upgrade-relay.sh`。
  - `rust/relay/tests/version.rs` `version_flag_prints_version`：`Command::new(env!("CARGO_BIN_EXE_rapp-relay")).arg("--version")` → 退出 0，stdout 是 `format!("rapp-relay {}\n", env!("CARGO_PKG_VERSION"))`；不监听任何端口。
- [ ] **Step 2: 跑测试确认失败** — `bash scripts/test-package.sh`；`cargo test -p rapp-relay --test version`。
- [ ] **Step 3: 实现** 上面的签名。在 `main()` 里先看 `--version`，在 `parse()` 之前处理。**不运行** `package-macos.sh`。
- [ ] **Step 4: 跑测试确认通过** — `bash scripts/test-package.sh` → `ALL OK`；`cargo test --workspace && cargo clippy --workspace --all-targets`。
- [ ] **Step 5: Commit** — `git add scripts/lib/release.sh scripts/upgrade-relay.sh scripts/package-macos.sh scripts/test-package.sh rust/relay/src/main.rs rust/relay/tests/version.rs`，`feat(release): zip and latest.json outputs, relay upgrade script, rapp-relay --version`

---

### Task 8: 实机验收、发布、记录 —— PARKED

**前提：只在用户明确同意以后做。** 这一步会：
- 用钥匙串里的证书签名，第一次签名时钥匙串会弹窗问是否允许，要点「始终允许」；
- 替换 `/Applications/rapp.app`，并重启用户正在用的 rapp-service；
- 在 `wizlijun/rapp-releases` 上发 release；
- 重置 rapp 自己的授权记录（要用户在系统设置里重新打开两个开关）。

用户中途在用这台 Mac，就停下来，把没做的条目记成「待实机」。全程守 Global Constraints 的安全规则，只是这一步允许做以上几件事。

**Files:**
- Modify: `tasks/todo.md`（加一节「在线升级」：规格 §8 实机验收每条一行，写验证方式和结果；§10 A1–A5 各一行，写结论）
- Modify: `docs/superpowers/specs/2026-11-12-rapp-online-update-design.md`（状态行后加「已实现（计划 `docs/superpowers/plans/2026-11-12-rapp-online-update.md`）」；§10 每条后面写验证结果）
- Modify: `tasks/lessons.md`（只在真学到东西时加）

- [ ] **Step 1: 全量验证** — `cargo test --workspace`、`cargo clippy --workspace --all-targets`、`flutter analyze`、`flutter test`、`swift test`、`./scripts/check.sh`（末行 `EXIT=0`）、`bash scripts/test-package.sh`（`ALL OK`）。
- [ ] **Step 2: 打两个连续版本**：
  - `gui/pubspec.yaml` 依次改成 N 和 N+1（用户定版本号），各跑一次 `scripts/package-macos.sh`；
  - 确认输出里签名是 `dev`，`codesign -d -r-` 是证书形式，四个 `Identifier=` 都对；
  - N+1 用 `RAPP_RELEASE_BASE` 指向 rapp-releases 上 `vN+1` 的地址。
- [ ] **Step 3: 装 N，升级到 N+1**（A2、A3、A4、A5）：
  - 双击 N 的 pkg 安装 → `ls -ld /Applications/rapp.app` 的所有者是登录用户（K4）；
  - 在系统设置里授权两项 → 本机 › 权限 两项 ✓；
  - 照 Task 7 打印的那一行发布 `vN+1`（三个文件）；
  - GUI 点「检查更新」→ 下载 → 关掉所有会话和 GUI → 自动装好；
  - 记下 `update_applied` 前后的时间差（A4）；
  - 看 `previous/rapp.app` 和 `/Applications/rapp.app` 是否在同一个卷（`stat -f %d`），日志里有没有走 ditto（A3）；
  - 升级后 本机 › 权限 两项仍是 ✓，从 B 打开一个 app 能看到画面、能操作（A2、A5）。
- [ ] **Step 4: 有人在用时不装**：再发一个 N+2，从 B 开着一个会话 → 停在「已下载，没人在用时会自动装好」，小点静止；断开会话、关掉 GUI → 自动装好。再试一次「立即升级」的手动路径。
- [ ] **Step 5: 重置授权记录**（A1）：本机 › 权限 的「重置授权记录」点两下：
  - 屏幕录制变成 ✗；
  - 辅助功能变成 ✗，或者出现手动删除的说明，按结果把 A1 的结论写下来；
  - 按引导重新授权，两项 ✓。
- [ ] **Step 6: 回到上一版**：点「回到上一版」两下 → 回到 N+1，权限仍是 ✓。
- [ ] **Step 7: relay**（可选，要用户同意动 VPS）：在 VPS 上跑 `scripts/upgrade-relay.sh <url>` → `systemctl is-active rapp-relay` 是 `active`，B 能经 relay 连上 A。
- [ ] **Step 8: Commit** — `git add tasks/todo.md docs/superpowers/specs/2026-11-12-rapp-online-update-design.md`（改了 lessons 再加 `tasks/lessons.md`），`docs: online update live check, todo, spec status`

---

## Self-review

- **规格覆盖**：
  - §2.1 公开仓库、`update_url` 可改：K10、`DEFAULT_URL`、Task 4 config。
  - §2.2 证书：Task 1。
  - §2.3「没人在用」、自动升级开关：K17、K9，Task 4、6。
  - §3.1 签名顺序、`-i`、runtime、cdhash 检查、chown：Task 1。
  - §3.2 `permissions_reset`、只动 rapp、ConfirmButton：Task 5、6，K22、K29。
  - §3.3 迁移：Task 5 K23、Task 6 K30。
  - §4.1 crate 划分、Runner、不加 HTTP 库：Task 2、3。
  - §4.2 manifest：Task 2。
  - §4.3：① Task 2、4（K7、K8）；② Task 3（K11）；③ Task 3（verify、needs_confirm）；④ Task 3、4（K12、K20）；⑤ Task 4（K15、K25）；⑥ Task 3、4（K13）。
  - §4.4 IPC：Task 4，C1 补了 `off`。
  - §5 GUI：Task 6（K26、K27）。
  - §6 发布端：Task 7。
  - §7 日志：Task 4、5，字段名照抄。
  - §8 测试：Task 2–7 都有对应；C7 说明了和 §8 的偏差；实机部分在 Task 8。
  - §9：没有新增签名体系（Global Constraints）。
  - §10：A1–A5 表，每条都有退路和验证位置。
- **占位扫描**：没有 TBD。Task 4 Step 0 是一个明确的只读核对，两种结果怎么做都写好了。版本号 N 由用户定，写在 Task 8 里。
- **类型一致**：
  - Task 2–5 里，`Runner`、`Out`、`FakeRunner` 的名字和 `rapp_update::{BUNDLE_ID, runner::TCCUTIL}` 一致。
  - `Marker.perms_before` 在 Task 3 定义，Task 5 写入和读取。
  - `UpdState` 和 `status_json` 的字段，与 Task 6 的 `UpdateInfo.fromJson` 一一对应：`current`、`latest`、`state`、`progress`、`error`、`notes`、`auto_update`、`check_updates`、`needs_confirm`、`needs_admin`、`page`、`dismissed`、`can_rollback`。
  - IPC 参数名 `confirm_signature_change`、`auto_update`、`check_updates`、`version`，与 Task 6 发出的 JSON 一致。
  - `Stage::as_str()` 产出 `download|verify|install|restart`，就是规格 §7 的 stage。
- **Review Focus**：五条的测试名分别写在 Task 3（1、3、5）、Task 4（2、3、5）、Task 5（4）、Task 6（4）、Task 2（5）的 Step 1 里。
- **比例**：只给签名、精确值、文案原文、测试名和断言，没有函数体。
