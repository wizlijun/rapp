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
- [ ] O7 整体审查、修 Critical/Important、打包
