# rapp 平台实现计划

规格：`docs/superpowers/specs/2026-11-11-rapp-platform-design.md`（下文的"§"都指这份规格）。
原则：`~/git/note.md/AGENTS.md`：KISS、YAGNI；每个里程碑验证通过后单独提交，并记下提交号。
执行方式：M1、M2、M3 的接口都已经在规格里定死，三者互不依赖，各派一个子代理在各自的 git worktree 里同时做。我负责合并、做端到端测试，再接着做 M4、M5。

## M1 Swift worker CLI（§5）：`Sources/`
- [x] `rapp-host serve --app … --bind … --port 0 (--token|--token-env) --json`。事件 listening、session、rejected、stats、exit；stdin 接收 kick、quit，stdin 关闭（EOF）就退出
- [x] 绑定 app 之后，Hello 里 appID 为空表示用绑定的那个；appID 不一致就回 `this host shares <appID>`；旧写法照常能用
- [x] `list-apps [--json]`、`check [--json]`（退出码 3）、`version [--json]`
- [x] `rapp-client [connect] <地址> [--token-env] [--json]`：地址可以不带 app；事件 ready、exit；stdin 接收 quit 和 EOF；`version`
- [x] 把参数解析和 JSON 事件格式放进 RappCore，并写单元测试
- 验证：`./scripts/check.sh` 末行是 `EXIT=0`，并且测试数大于 91；`rapp-host version --json`、`list-apps --json`、`check --json` 实际跑一遍；用 `serve --port 0 --json` 加 `rapp-client --json` 在本机连上 Safari
- 结果：合并后 EXIT=0，108 个测试；提交 93adf58、e57fb20、a865b3a。未经实机验证：缺少权限时退出码 3 的分支（本机已授权）

## M2 Rust：relay、service、hub（§1–4）：`rust/`
- [x] 建 workspace，crate 有 `net`、`relay`、`service`、`hub`
- [x] relay：register、connect、incoming、限速、relay 对接、`relay.json`
- [x] service：配置文件、登记加重连、认证（令牌和局域网密码两种）、list_apps、open、worker 生命周期、IPC 加 subscribe、拉起 `--cm`
- [x] hub：hosts.json、选路（lan → direct → relay，可以用 `RAPP_FORCE_PATH` 强制）、open 时拉起 rapp-client 并对接、事件
- 验证：`cargo test` 全部通过，集成测试覆盖 §7 列的 8 种情况，测试里用一个假的 rapp-host 脚本；`cargo clippy` 没有警告
- 结果：合并后 `cargo test` 50 个全部通过，clippy 干净；提交 1510f14..43d0917（合并 36275d2）。只对假的 worker 跑过，没跑真 v3 的 rapp-host 和 rapp-client；没跨真 NAT 打洞，只测了 IPv4

## M3 Flutter GUI（§4）：`gui/`
- [x] 本机、主机、会话三块界面，托盘或菜单栏图标，关闭窗口只隐藏
- [x] 作为子进程拉起 rapp-hub，用 JSON 行通信；通过 IPC 连 service
- [x] `--cm` 模式
- [x] 服务的启动、停止、重启；macOS 上用 LaunchAgent
- 验证：`flutter analyze` 没有问题，`flutter test` 通过，`flutter build macos` 成功，并能实际启动
- 结果：合并后 `flutter analyze` 没有问题，49 个测试通过；release 只能构建 arm64（这台机器上的 Xcode 做 universal 时 lipo 出错），部署目标提到 macOS 12；提交 ad26352..7d10467（合并 54988c9）。断开按钮没实际点过；Linux 和 Windows 没构建

## M4 合并与本机端到端
- [x] 合并 M1、M2、M3
- [x] 本机：relay 加 service（单独设一个 `RAPP_HOME`）加 hub。lan 和 relay 两条路都能打开 Safari；`--cm` 能断开会话
- 验证：分别记下两条路上 hub 输出的 `opened` 和 `path`，再截图确认窗口确实显示出来
- 结果：`scripts/e2e-local.py` 两条路都通过。lan：`opened` path=lan sid=1；relay：`opened` path=relay sid=1；两张截图里客户端窗口都在播 Safari 里的 bilibili 视频（relay 那路 2.2 MB/s）。断开走的是 `--cm` 断开按钮发的同一个 IPC `kick{sid}`，hub 随后收到 `closed`。`--cm` 窗口上的按钮本身没有点过

## M5 macOS 打包
- [x] `scripts/package-macos.sh` 生成 `dist/rapp.dmg`，再交叉编译 relay，另附 systemd 单元示例
- 验证：从 dmg 里拿出来的 rapp.app 能启动，并能拉起服务
- 结果：dmg 13 MB，里面的 rapp.app 带 rapp、rapp-service、rapp-hub、rapp-host、rapp-client，全是 arm64，ad-hoc 签名通过 `codesign --verify --deep --strict`，沙盒关闭。从 dmg 拷出来的 app：GUI 能启动并拉起自带的 rapp-hub（截图确认三块界面）；用 `RAPP_E2E_BUNDLE` 跑 e2e，service、hub、host、client 全用包里的，不设 `RAPP_BIN_DIR`，lan 和 relay 两条路都通过。没点 GUI 的"启动"（那会往 `~/Library/LaunchAgents` 写常驻服务）。relay 编成 x86_64 musl 静态二进制（4.4 MB，规格 §6 已改），没在 Linux 上跑过
- [x] `rapp-0.2.0.pkg`：pkgbuild + productbuild，不可重定位；postinstall 给控制台用户写 LaunchAgent（与 GUI 的 `launchAgentPlist` 逐字节相同）、`launchctl bootstrap`、打开 GUI；`scripts/uninstall-macos.sh`
- 结果：用户用 Installer 在本机装上。`launchctl print` 显示 state = running、program 是 /Applications/rapp.app/Contents/MacOS/rapp-service、keepalive | runatload；plist 和 GUI 生成的 `cmp` 相同、属主是用户；服务生成了 service.json 和 ipc.token（都是 600）；GUI 已打开；签名校验通过；盘上没有 `._` 文件。没测：卸载脚本（要 sudo，且会删掉刚装好的）、覆盖重装（postinstall 先 bootout 再 bootstrap）
- [ ] Developer ID 签名与公证：脚本已支持（按 SHA-1 找 "Developer ID Application/Installer"，hardened runtime + 时间戳，由内向外签 frameworks → 辅助程序 → app；pkg 用 productbuild --sign；有 notarytool 档案就 submit --wait + staple）。钥匙串里只有 "Apple Distribution: Wuhan Fulin Technology Co., Ltd. (T5G56DH47L)"，它签不了 pkg（productsign 报 Could not find appropriate signing identity），签出的 app 在 App Store 外也过不了 Gatekeeper。缺两张 Developer ID 证书，只能由该团队 Account Holder 登录 Apple ID 创建
- 结果（替身验证）：用 Apple Development 证书走同一条签名路径，pkg 里 7 个代码对象都是 flags=runtime、带时间戳，`codesign --verify --deep --strict` 通过；用 pkg 里的 app 跑 e2e（`RAPP_E2E_BUNDLE`，目标 Finder），lan、relay、id@ip 三轮都过。没测：productbuild --sign、公证、hardened runtime 下的 GUI 本身

## 无 relay：自生成 ID 与 `id@ip`
- [x] service 首次启动自己生成 9 位 ID（relay 接受合法的新 ID）；status 加 `lan_ids`（每个可用 IPv4 一个 `id@ip`，跳过 198.18.0.0/15 代理假 IP）；密码认证成功回 `id`、`name`
- [x] hub `add_host` 接受 `id@ip[:port]`：直连做密码认证、核对 ID 后保存；relay 回 `unknown id`/`offline` 时退到局域网地址
- [x] GUI：relay 未连上时 ID 显示为 `lan_ids`，添加主机输入框写明可填 `ID@IP`
- 结果：cargo test、clippy、flutter analyze/test 全过；e2e 第三轮用没有 relay 的 hub 按 `686712053@10.17.0.235:<port>` 加主机并打开 Safari，路径 lan，踢掉会话后 hub 收到 closed。第一次跑时 A 报的第一个地址是 198.18.0.1（本机 TUN 代理的假 IP），连不上，于是加了过滤

## 多窗口（RAIL 式，协议 v4，只做 macOS）
规格：`docs/superpowers/specs/2026-11-11-rapp-multiwindow-design.md`；计划：`docs/superpowers/plans/2026-11-11-rapp-multiwindow.md`；分支 `multiwindow`。
- [x] Task 1 探查（结果在规格附录）；Task 2 协议 v4；Task 3 纯函数（父窗口、摆放）；Task 4 host 窗口表、按窗口注入、focus/close/move/resize；Task 5 client 每个 A 窗口一个 B 窗口；Task 6 菜单栏镜像；Task 7 e2e 和文档
- 结果：`swift test` 160 个全过。e2e 三轮（lan、relay、id@ip，目标 Calculator）都过，每轮 client 都报 `windows: 1`（client 在 `--json` 时把窗口数写 stderr，hub 日志里能看到；hub 本身不转发事件）。
  实机（TextEdit，空文档、不打字、最后不存关掉）：右键菜单、格式菜单、字体面板、存储 sheet 在 B 上各是独立窗口且位置对；B 上挪窗口 0.5 秒内 A 跟着挪；B 菜单栏和 A 一致（灰掉、快捷键文字），B 上选"File ▸ New"在 A 上开出第二个窗口，B 上也多一个。
- 没测：Windows、Omarchy 端（仍是 v3，和新 Mac 端连不上）；多块屏；A 上全屏窗口；打开时才填内容的子菜单（Open Recent、Share）在 B 上可能是空的；只有打开面板时按"新建"，2.5 秒内没出新窗口（原因没查）；Safari 读整个菜单栏的耗时只在探查时量过。

## 未经实机验证（交给用户验收）
跨 NAT 打洞、VPS 部署、Windows 和 Linux 上的服务。

## 未来规划
- **多窗口 / 弹出窗口**：macOS 已做（见上）；Windows、Omarchy 端升到 v4 待做
- **按区域选编码**（参考 Xpra）：静止的文字区用无损或低色深，正在变的区域用视频编码；下一个，单独出 spec
- **硬件编码**（参考 Sunshine）：A 端用 VideoToolbox 编 H.264/HEVC，作为"看视频"档；B 端用 VideoToolbox 解码。30 fps 全屏动画时比瓦片编码省流量也省 CPU。暂不排期

## 回顾
- M1 到 M3 按规格定死的接口分给三个子代理并行做，合并时没有冲突，接口这一步省了很多返工。
- M4 卡在一个和代码无关的问题上：一直开着的旧 rapp-host 让新进程抓屏被 replayd 断开。先单独跑 `serve`、再跑旧写法，把范围缩到"新进程"，再看系统日志才找到原因。已记进 lessons.md。
- 没做的：GUI"启停"按钮本身（pkg 已验证装好并启动 LaunchAgent）、卸载脚本和覆盖重装、`--cm` 窗口上的按钮、跨 NAT 打洞、VPS 上的 relay、Windows 和 Linux 的服务，都留给用户实机验收。

# 权限引导（规格：`docs/superpowers/specs/2026-11-11-rapp-permission-guide-design.md`）
执行方式：我自己按顺序做（后一步要用前一步的字段），每步先写测试、看到失败再实现，每步单独提交；最后派一个新的审查者看整个改动。

- [x] P1 (8fe5497) rapp-host：`check --prompt`、`list-apps` 带 permissions、`serve` 的提示文案（§1）。验证：`./scripts/check.sh` 末行 `EXIT=0`；实机跑 `rapp-host check --prompt --json`、`list-apps --json`
- [x] P2 (e591962) service + 假 rapp-host：`State.permissions` 加锁并在变化时通知、IPC `permissions`、list_apps 带 permissions、open 缺权限后重新 check（§2）。验证：`cargo test`、`cargo clippy` 没有警告
- [x] P3 (4881806) hub：apps 事件转发 permissions（§3）。验证同 P2
- [x] P4 (1fc03d3) GUI：`permissions.dart`、`PermissionsPanel`、本机区块和轮询、首次引导、主机区块提示（§4）。验证：`flutter analyze` 没有问题，`flutter test` 通过
- [x] P5 打包 arm64 pkg/dmg，实机验证 §5 最后一条；整体审查后修 Critical/Important
  - 审查：0 Critical，2 Important 已修（引导对话框里没有「重启」按钮；check 慢/失败会拖住设置页并把权限记成全缺）。测试：`failed_check_keeps_last_known_permissions`、`guide: …重启服务…`、`promptThenOpen …` 先红后绿
  - 实机：屏幕录制深链打开 "Screen & System Audio Recording"；辅助功能深链打开的页面标题是 "Device Control and Data Access"（macOS 27 改了分组？待人眼确认）
  - 留着的 Minor：轮询没有"正在查"保护；`_guard` 用当前选中的主机名；橙色/红色提示重复且授权后不刷新；一次 --prompt 弹所有缺失项；`open` 失败的异常没接；标记文件在对话框显示前写入；LocalSection 没有组件测试

## B 挪窗口与 A 解耦、「移到左上角」（多窗口 spec §4.2、§4.3、§4.5 修订 2026-11-11）

- [x] B 上挪窗口不再发 move；A 挪窗口 B 不动，A 改大小 B 内容区左上角不动。验证：`./scripts/check.sh` 末行 `EXIT=0`；实机（按 PID 找自己开的 Calculator）B 挪了 200 点，A 的 Calculator 没动
- [x] 应用菜单和流量标签右键菜单加「把 A 上的这个窗口移到左上角」，堆叠摆放（`moveToTopLeftMessages`，空位 (0,0)、(28,28)…）。验证：单元测试 RED→GREEN；实机 Calculator 落到 (0,30)

## 剪贴板与编辑器（协议 v5）（规格：`docs/superpowers/specs/2026-11-11-rapp-clipboard-composer-design.md`）

- [x] 1 (ce8b289) 协议 v5 消息 19–25（clip、传输）
- [x] 2 (1cfec04, fix df01058) core：剪贴板种类、编辑器拆分、命名、续传、标题
- [x] 3 (56057d2, fix 99dc22c) core：ClipStore 与可续传的 TransferStore
- [x] 4 (2ef31a3, fix d2fec60) host：旁路连接 fetch/put、每会话剪贴板历史
- [x] 5 (4fb0bfd, fix e65f7dd) host：粘贴到目标 app 并恢复剪贴板
- [x] 6 (5dcb458) hub：旁路连接用自己的 open 转发
- [x] 7 (70d2ab8, fix 96fe896) client：旁路传输、每连接剪贴板历史
- [x] 8 (a40f350, fix 4fbd759) client：多行编辑器、块、附件、复制按钮
- [x] 9 (8fb6e98, fix f5e47f5) client：发送器逐条发到 A
- [ ] 10 实机验收（TextEdit：发送、复制、1 GB 文件续传、非目标 app 不进历史）
- [ ] 10 打包 arm64 pkg/dmg（不替换已装的 /Applications/rapp.app）

## 可观测性（规格：`docs/superpowers/specs/2026-11-11-rapp-observability-design.md`）
执行方式：我自己按顺序做，每步先写测试、看到失败再实现，每步单独提交；最后派一个新的审查者看整个改动。

- [x] O1 `rapp_net::log`（格式、轮转、重复合并、read_recent、目录）；`splice_metered` + `Meter` 计字节（splice 会被 kick 取消，返回值拿不到）；msg 加可选 `name`、`side`。验证：`cargo test -p rapp-net`
- [x] O2 relay：§4.2 事件，`Opts.log`。验证：relay 集成测试含"日志里没有密码和 key"
- [x] O3 service：§4.1 事件、worker stderr 转写、`transfer`/`rejected` 转写、IPC `history`、status 带 `log_dir`、launchd.log 清理。验证：service 集成测试
- [x] O4 hub：§4.4 事件、client stderr 转写、上报 `name`、side 标记。验证：hub 集成测试
- [x] O5 Swift：`--json` 不写 `[stats]` 文本；host 发 `transfer` 事件。验证：`./scripts/check.sh` 末行 `EXIT=0`
- [x] O6 GUI：访问记录、打开日志文件夹；plist 和 postinstall 加 StandardOut/ErrorPath。验证：`flutter analyze`、`flutter test`
- [x] O7 整体审查、修 Critical/Important、打包

## 主界面 S1：外壳与设计语言 + 启动全屏（计划：`docs/superpowers/plans/2026-11-12-rapp-main-window-s1.md`）

- [x] 1 主题 token、四套主题、gui.json 偏好
- [x] 2 状态灯、按钮、两次确认
- [x] 3 hub `focus` 命令 + client 提到最前
- [x] 4 `HubClient.focus` 与会话分组、上一个/下一个
- [x] 5 `MainState`
- [x] 6 顶栏、舞台占位、主题背景
- [x] 7 左侧面板外框、会话标签、主题下拉、图例
- [x] 8 设备标签（本机、远程 app、添加设备）
- [x] 9 主窗口组装、启动全屏、替换 HomePage
- [x] 10 实机检查、打包、记录
- 验证：`flutter analyze` 无问题、`flutter test` 187 个全过；`cargo test --workspace` 90 个、clippy 无警告；`./scripts/check.sh` EXIT=0；每个任务一个实现子代理 + 一个新的评审子代理
- 实机（只用自己起的 service、GUI、Calculator，按 PID 收尾）：启动即全屏（1920×1080）；主题切到 WESTWORLD 后 gui.json 保存、重启保持；设备标签显示在线 · 局域网和 app 列表；打开 Calculator 后舞台占位出现、提示「已打开 Calculator @ …」；「切到窗口」把 rapp-client 窗口提到最前；「结束会话」点一次变「再点一次确认」，3 秒内再点才结束（hub 记 `closed`）；⌃⌘F 进全屏、Esc 先关面板再退全屏
- 实机发现并修好：顶栏全屏按钮会随提示长短左右漂移（0c44535，加了测试）
- 提交：de6e07e..0c44535；打包 `dist/rapp-0.2.0.pkg`、`dist/rapp.dmg`（未替换已装的 rapp.app）
- 未实机验证：360px 窄窗口（只有 widget 测试）；四套主题里 IRON MAN、AVATAR 的实机外观
- 终审（opus）：Important 1 个——「结束会话」「删除设备」点一次后换了目标仍保持待确认，再点一次会结束/删除另一个；已修（faf2f7b，按目标分键）。同一提交顺带修了：打开失败后回到原来的会话；图例里的灯不再闪。其余 6 个小问题记在下面
- 界面复查（高中生能懂）：分组改「按设备 / 按 App」；添加设备「对方的 ID（同一局域网可写 ID@IP）」；包名框「其他 app 的包名（例：…）」；本机里 Relay 统一为「中继」；会话自己断掉时提示「X 意外结束：原因」，用户结束的仍是「已结束 X」；hub 的英文提示改中文（8b04823）。flutter test 194 个全过
- 留给以后的小问题：主题每次状态变化都重建（性能）；<480px 时提示条占舞台高度且不消失；主题质感（发光字、AVATAR 字重、面板模糊）未做；删除设备时正在进行的探测可能把它算回在线数；用包名打开时会话名显示成包名；「切到窗口」不还原最小化的窗口
- 界面设计层面的建议（等用户定，没改）：添加设备表单藏在远程设备 app 列表下面、会被底栏挡住，建议单独一个「+ 添加设备」；app 名下面显示包名（等宽字）对普通人是噪音；面板打开时舞台上的「打开面板」按钮还看得见；总流量一直是「—」（要等 S3）；设备 ID 用等宽字显示


## 主界面 S2–S6（分支 `feat/main-window-s2-s6`；S7 先不做，S8 不在范围内）
顺序：S2 → S3 → S5 → S6 → S4（S4 第三层要用 S5 的项目、S6 的资源，放最后）。各规格 §6 的假设按默认执行，验收时确认。
- [x] S2 嵌入舞台（规格：`docs/superpowers/specs/2026-11-12-rapp-s2-embedded-stage-design.md`；计划：`docs/superpowers/plans/2026-11-12-rapp-s2-embedded-stage.md`）——代码完成、自动测试全绿；**实机检查待做**
  - IRON MAN 网格在画面处留洞（R25），有单测。
  - 自动验证（2026-11-12）：`cargo test --workspace` 97 过、clippy 0 警告、`./scripts/check.sh` EXIT=0（Swift 311 过）、`flutter analyze` 干净、`flutter test` 314 过；`scripts/package-macos.sh` 出包 `dist/rapp-0.3.0.pkg`（未安装）。
  - 实机检查没做成：检查时用户正在用这台 Mac，并用 ⌘Q 退出了测试 GUI；为了不反复抢焦点，没有重开。§7 逐条（待实机）：
    - [ ] 打开 app，画面在舞台上、没有独立窗口
    - [ ] 点、拖、滚、右键、打字到 A；Esc、⌘W 到 A；⌃⌘F 进出全屏（⌘W 后 gui.log 无键盘断言）
    - [ ] 开合面板、串流菜单、输入区，A 窗口尺寸不变——用 Chess（Calculator 不可改尺寸）；host 只记失败的 resize，要按 `unix id` 读 A 窗口尺寸来判断
    - [ ] 改主窗口大小，停下后 A 窗口改成舞台尺寸，一次（同上，用 Chess）
    - [ ] 两个以上窗口出现标签，点标签切窗口（Calculator ⌘T 纸带）
    - [ ] 分离/放回不重连、画面不黑；独立窗口位置（右→左→错开 24pt）；Calculator 基本↔科学切换时独立窗口跟着变尺寸；⌃⌘D 前后 A 上没有卡住的键
    - [ ] 关掉独立窗口，会话结束
    - [ ] 不在舞台上的会话降到 1 fps
    - [ ] 30 fps 时 GUI CPU 不高于独立 `rapp-client`；两者颜色一致（IOSurface 色彩空间）
  - 只有单测、不做实机：坏帧只结束一个会话（Task 3、6）；滚轮幅度 /4 和触控板（Task 8，Calculator 没有可滚内容）；⌘V/编辑›粘贴、输入区发送、输入法回车（会碰系统剪贴板或输入法设置）；多显示器缩放（只有一块屏）。
  - 已知：hub 退出后，嵌入的会话和独立窗口不会被 GUI 关掉（S2 之前就如此）。
  - 实机检查的脚本在 scratchpad `s2live/`；`tclick.sh` 改用按 PID 判断的 `topatp`（用户机上同时有多个名叫 rapp 的进程）。
- [x] S3 生命周期（规格：`docs/superpowers/specs/2026-11-12-rapp-s3-lifecycle-design.md`；计划：`docs/superpowers/plans/2026-11-12-rapp-s3-lifecycle.md`）——代码完成、自动测试全绿；**实机检查待做**
  - 自动验证（2026-11-12）：`cargo test --workspace` 117 过、clippy 0 警告、`./scripts/check.sh` EXIT=0（`swift test` 237 过）、`flutter analyze` 干净、`flutter test` 395 过。最终审查的 I-1、I-2、I-3、M-6 已修并复审通过。
  - relay 这次有改动（在线探测不再刷访问记录），要重新部署到 VPS 才生效——需用户同意 SSH。
  - §5 逐条（单测已覆盖，待实机）：
    - [ ] 打开 app：连接中 → 活动；A 画面不动 10 秒变空闲，动一下回到活动
    - [ ] 串流菜单「断开」：条目留着、最后一帧 + 斜条纹 + 「重连」；需要你 +1；「重连」后设置和窗口不变
    - [ ] A 上关掉被串流的 app（自己拉起的 Calculator，按 PID）：已断开，原因「A 端关闭了 app」
    - [ ] 停掉自己起的 host：会话已断开；30 秒内设备变离线、需要你出现「离线」一件，恢复后自己消失
    - [ ] 顶栏流量随画面跳动；总流量 = 各活动会话之和
    - [ ] 「结束会话」点两次：条目消失、需要你相应减少
- [ ] S5 项目与常用（规格：`docs/superpowers/specs/2026-11-12-rapp-s5-projects-favorites-design.md`）
- [ ] S6 全局资源（规格：`docs/superpowers/specs/2026-11-12-rapp-s6-global-resources-design.md`）
- [ ] S4 全景（规格：`docs/superpowers/specs/2026-11-12-rapp-s4-overview-design.md`）

## 插入的严重问题（2026-11-12，用户报告）
- [ ] P1 A 锁屏后 B 无法输入：B 提交时报「A 上的目标窗口不在最前」（`Paster.waitFrontmost` → `target not frontmost`），点击被丢弃（`InputInjector.clearToClick` → `click dropped: covered by …`）。原因：锁屏时登录窗口盖在所有窗口上、目标 app 激活不了，按 HID 投递的键鼠都到不了 app。README 写明 rapp 不做远程登录/解锁。待做：
  - [x] 锁屏时 B 明确显示「A 已锁屏，需要在 A 上解锁」，不再报「不在最前」；host 日志记 `click dropped: A is locked`（host 用 `CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked` 判断）
  - [x] 会话在时不让 A 因闲置熄屏、屏保或锁屏（电源断言 + 每 30 秒声明用户活动；仅 macOS host）
  - 摸底：锁屏时按 PID 投递（`postToPid`）或 AX 写入能否送达 app——要锁 A 的屏做实机测试，需用户安排时间
- [ ] P2 多个客户端同时连一个 host：要先设计（现在是独占模式），再实现
