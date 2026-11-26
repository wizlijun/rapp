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
- 结果：合并后 `flutter analyze` 没有问题，49 个测试通过；release 只能构建 arm64（这台机器上的 Xcode 做 universal 时 lipo 出错），部署目标提到 macOS 12；提交 ad26352..7d10467（合并 54988c9）。断开按钮没实际点过；Linux 和 Windows 没构建（Windows 的构建现在归 `docs/superpowers/specs/2026-11-26-rapp-windows-design.md`）

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
- 没测：Windows（现在见 Windows 设计）、Omarchy 端（当时仍是 v3，和新 Mac 端连不上）；多块屏；A 上全屏窗口；打开时才填内容的子菜单（Open Recent、Share）在 B 上可能是空的；只有打开面板时按"新建"，2.5 秒内没出新窗口（原因没查）；Safari 读整个菜单栏的耗时只在探查时量过。

## 未经实机验证（交给用户验收）
跨 NAT 打洞、VPS 部署、Windows 和 Linux 上的服务（Windows 的服务见 Windows 设计 §7）。

## 未来规划
- **多窗口 / 弹出窗口**：macOS 已做（见上）；Omarchy 端升到 v4 待做；Windows 见 Windows 设计
- **按区域选编码**（参考 Xpra）：静止的文字区用无损或低色深，正在变的区域用视频编码；见 `docs/superpowers/specs/2026-11-14-rapp-smooth-streaming-design.md`（第二步）
- **按焦点分区串流**（U146–U148）：焦点面板彩色，其余灰度低流量。规格见 `docs/superpowers/specs/2026-11-16-rapp-focus-pane-rules.md`（第 2 稿，可实施第 0 步探查和第 1 步"看得见"，入口是预设里的「智能」）；真的省流量（改编码）另写设计
- **硬件编码**（参考 Sunshine）：A 端用 VideoToolbox 编 H.264/HEVC，作为"看视频"档；B 端用 VideoToolbox 解码。30 fps 全屏动画时比瓦片编码省流量也省 CPU。见 `docs/superpowers/specs/2026-11-14-rapp-smooth-streaming-design.md`（第二步）；暂不排期

## 回顾
- M1 到 M3 按规格定死的接口分给三个子代理并行做，合并时没有冲突，接口这一步省了很多返工。
- M4 卡在一个和代码无关的问题上：一直开着的旧 rapp-host 让新进程抓屏被 replayd 断开。先单独跑 `serve`、再跑旧写法，把范围缩到"新进程"，再看系统日志才找到原因。已记进 lessons.md。
- 没做的：GUI"启停"按钮本身（pkg 已验证装好并启动 LaunchAgent）、卸载脚本和覆盖重装、`--cm` 窗口上的按钮、跨 NAT 打洞、VPS 上的 relay、Windows 和 Linux 的服务，都留给用户实机验收（Windows 的服务现在归 Windows 设计 §7）。

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
- 未实机验证：360px 窄窗口（只有 widget 测试）；AVATAR 主题的实机外观
- 终审（opus）：Important 1 个——「结束会话」「删除设备」点一次后换了目标仍保持待确认，再点一次会结束/删除另一个；已修（faf2f7b，按目标分键）。同一提交顺带修了：打开失败后回到原来的会话；图例里的灯不再闪。其余 6 个小问题记在下面
- 界面复查（高中生能懂）：分组改「按设备 / 按 App」；添加设备「对方的 ID（同一局域网可写 ID@IP）」；包名框「其他 app 的包名（例：…）」；本机里 Relay 统一为「中继」；会话自己断掉时提示「X 意外结束：原因」，用户结束的仍是「已结束 X」；hub 的英文提示改中文（8b04823）。flutter test 194 个全过
- 留给以后的小问题：主题每次状态变化都重建（性能）；<480px 时提示条占舞台高度且不消失；主题质感（发光字、AVATAR 字重、面板模糊）未做；删除设备时正在进行的探测可能把它算回在线数；用包名打开时会话名显示成包名；「切到窗口」不还原最小化的窗口
- 界面设计层面的建议（等用户定，没改）：添加设备表单藏在远程设备 app 列表下面、会被底栏挡住，建议单独一个「+ 添加设备」；app 名下面显示包名（等宽字）对普通人是噪音；面板打开时舞台上的「打开面板」按钮还看得见；总流量一直是「—」（要等 S3）；设备 ID 用等宽字显示


## Omarchy Rust / GTK 客户端（2026-11-11）
- [x] `rapp-client-core`：v4/v5 协议、五档像素展开、持续 zlib 字典和瓦片增量解码、数据上限、画布命中、Mac 键码映射。
- [x] `rapp-client-gtk` 输出 `rapp-client`：应用画布、镜像菜单、键鼠/滚动/输入框、画质/帧率/采集密度、流量、v5 文字剪贴板接收、hub JSON/EOF 生命周期。
- [x] `scripts/build-linux.sh` 将客户端与 GUI、hub、service 放入同一 bundle；`scripts/test-linux-client.py` 使用独立 Python 编码夹具启动真实 GTK 进程测试。
- 验证：13 项新 core 测试、已有 61 项 Rust 测试、新 crate clippy；GTK 集成覆盖 v4/v5、完整/增量帧、菜单、退出、协议错误、键鼠；通过局域网连接真实 Mac v5 主机并显示 rapp 窗口。
- 限制：Linux 用一个画布显示同一 app 的所有窗口，没有逐窗映射为独立原生窗口；尚无文件/图片剪贴板传输、Linux 采集主机。输入法使用 GTK 本地 Entry，中文预编辑仍需实机人工验收。


### Linux 菜单与流设置对齐最新 Mac
- 参照 `origin/feat/clipboard` 的 `StreamMenu`、`TrafficLabel`、`Geometry`：标题栏流量菜单、客户端菜单、两项预设、三组单选、50–200% 缩放和移动 A 到左上角；流菜单仅显示三种常用画质。
- 密度上下限、1% 相对变化阈值、首次 Hello 的密度与 Mac 一致；持续 zlib 字典和 64×64 瓦片线上格式不变。
- 增加 v5 最近 20 项文字剪贴板历史、复制/发送按钮，Ctrl+V 在空输入框中也留给本地输入框。大文件、附件和多行块编辑器仍未移植。

## 主界面 S2–S6（分支 `feat/main-window-s2-s6`；S7 先不做，S8 不在范围内）
顺序：S2 → S3 → S5 → S6 → S4（S4 第三层要用 S5 的项目、S6 的资源，放最后）。各规格 §6 的假设按默认执行，验收时确认。
- [x] S2 嵌入舞台（规格：`docs/superpowers/specs/2026-11-12-rapp-s2-embedded-stage-design.md`；计划：`docs/superpowers/plans/2026-11-12-rapp-s2-embedded-stage.md`）——代码完成、自动测试全绿；**实机检查待做**
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
- [x] S5 项目与常用（规格：`docs/superpowers/specs/2026-11-12-rapp-s5-projects-favorites-design.md`）
  - 代码 + 测试完成（计划 Task 1–6，提交到 ee61e67；flutter 519、cargo 207、check.sh EXIT=0）；以下实机条目待用户安排时间（Ruling S5-0）
    - [ ] 待实机：设为常用 → 底部「常用」组；点一下打开、嵌入；结束后回到「常用」
    - [ ] 待实机：建项目加两个成员，「全部打开」停在第一个；「全部结束」点两次都结束，提示「结束 2 个会话」
    - [ ] 待实机：一个会话在两个项目里 → 「按项目」时两组各一次；顶栏上一个/下一个不卡；顶栏第二行「<设备> · <项目> · <任务>」
    - [ ] 待实机：成员所在 host 离线 → 「全部打开」提示「<设备> 离线，跳过 1 个」
    - [ ] 待实机：退出再开，常用、项目、任务都在
    - [ ] 待实机：workspace.json 写坏 → 提示「项目和常用没有读到，已从空白开始」，留 workspace.json.bad
    - [x] 打包：随 v0.5.0 发布（963e9cf，Apple Development 签名，arm64）
- [x] S6 全局资源（规格：`docs/superpowers/specs/2026-11-12-rapp-s6-global-resources-design.md`）
  - 代码 + 测试完成（计划 Task 1–6 + 终审修复，提交到 8b843f6；flutter 572、swift 通过、cargo 208、check.sh EXIT=0）；hub 的 sid 改从毫秒时钟起，重启服务后不再重号。以下实机条目待用户安排时间
    - [ ] 待实机：两个会话各在 A 上复制测试文字 → 资源标签两条，来源对、最新在上
    - [ ] 待实机：固定一条 → 结束它的会话 → 固定的还在、「复制到本机」可用；同会话未固定的没了
    - [ ] 待实机：A 上复制测试文件 → 「复制到本机」有进度 → 进传过的 → 「显示位置」选中下载目录里的文件
    - [ ] 待实机：大文件下到一半「取消」→ 下载目录留 `.rapp-part`
    - [ ] 待实机：流菜单第 5 组只显示当前会话最新两条；「全部剪贴板」打开资源标签、流菜单收起
    - [ ] 待实机：按 PID 停掉一个会话的 host → 它的条目变灰「A 已断开，复制不到」
    - [x] 打包：随 v0.5.0 发布（963e9cf，Apple Development 签名，arm64）
- [x] S4 全景（规格：`docs/superpowers/specs/2026-11-12-rapp-s4-overview-design.md`）
  - 代码 + 测试完成（计划 Task 1–4 + 终审修复，提交到 1f308e1；flutter 637、check.sh EXIT=0）；顶栏按实际显示的按钮算宽度，嵌入模式 300–600 px 不再溢出。以下实机条目待用户安排时间
  - [ ] 待实机：两个会话一个断开 → 全景计数「活动 1、已断开 1」，墙上两块状态各自对
  - [ ] 待实机：全景里点另一块 → 一次点击回到窗口模式、当前会话是它
  - [ ] 待实机：停掉一台 host → 30 秒内那一栏变灰「离线」，「设备在线」减 1
  - [ ] 待实机：两种模式顶栏一致；全景里面板、需要你、串流菜单都正常
  - [ ] 待实机：帧率——窗口模式照选的 fps，进全景 3 秒后 ≤ 1 fps，回来恢复（看 host.log [stats]）
  - [ ] 待实机：灰度截图里七种状态凭形状仍能分清
  - [x] 打包：随 v0.5.0 发布（963e9cf，Apple Development 签名，arm64）

## Linux 0.4.0 内嵌舞台（2026-11-12）
- [x] `rapp-session` 无窗口进程复用 client-core 协议、持续 zlib/瓦片解码；JSON 输入、带长度的 BGRA/事件输出，EOF 断开 socket。
- [x] `LinuxSessionPort` 接通 hub 的 embed 模式、窗口/弹窗裁剪、舞台绘制、键鼠/菜单/流设置/文字输入/文字剪贴板历史；逐帧背压限制图像积压。
- [x] 画面获得键盘焦点后将 Ctrl 映射为 Mac Command；F11/Super 保留给本地，失焦释放按键。hub 退出关闭嵌入会话。
- [x] 构建脚本将 rapp-session 放进 bundle；独立 GTK client 保留。
- 验证：Flutter 318 项通过、1 项跳过，analyze 干净；client-core 16 项 + worker 2 项测试通过，clippy 无警告。新测试覆盖真实 worker 到 Flutter 的完整/增量帧、BGRA 色彩、裁剪、输入/中文、EOF、坏帧隔离、舞台图像和键盘焦点。真实 Mac 连接的远程 app 已在 Linux 主窗口舞台显示。
- 限制：内嵌会话的无重连分离/放回尚未实现（按钮禁用）；图片/文件附件暂不支持（显示明确提示）。

## Linux 内嵌性能修复（2026-11-12）
- 像素更新改为独立 ValueNotifier + RepaintBoundary，不再每帧派发 WindowsEvent 并重建整个 MainState/界面；窗口几何变化仍正常更新。
- 帧处理改为单个正在绘制帧 + 最新待显示帧；等待绘制不再阻塞协议事件，旧的待显示帧被替换，不积累显示延迟。
- Rust 重用 BGRA 分配并将帧头与像素分段写入，移除额外整帧打包复制。兼容独立 GTK client 的原解码 API。
- 验证：319 Flutter 测试通过、1 项跳过；analyze、clippy 通过；Rust 17 core + 2 worker 测试通过。回归覆盖像素更新不触发窗口元数据事件、绘制暂停时错误仍及时处理、增量解码复用缓冲地址。
- 对比脚本 `scripts/benchmark-linux-session.py`（这是 worker 解码/传输吞吐，不是端到端交互 FPS）：1080p 120 帧两轮旧版 46.3/42.9 fps，新版 63.2/64.1 fps；无并行构建的 4K 60 帧旧版 18.9 fps，新版 23.5 fps。4K 稳定 30 fps 尚未达到；BGRA 跨进程传输和 GPU 图像上传仍是后续优化方向。
- 新版已本地编译；未替换 GitHub Release 的已发布附件。
## 插入的严重问题（2026-11-12，用户报告）
- [ ] P1 A 锁屏后 B 无法输入：B 提交时报「A 上的目标窗口不在最前」（`Paster.waitFrontmost` → `target not frontmost`），点击被丢弃（`InputInjector.clearToClick` → `click dropped: covered by …`）。原因：锁屏时登录窗口盖在所有窗口上、目标 app 激活不了，按 HID 投递的键鼠都到不了 app。README 写明 rapp 不做远程登录/解锁。待做：
  - [x] 锁屏时 B 明确显示「A 已锁屏，需要在 A 上解锁」，不再报「不在最前」；host 日志记 `click dropped: A is locked`（host 用 `CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked` 判断）
  - [x] 会话在时不让 A 因闲置熄屏、屏保或锁屏（电源断言 + 每 30 秒声明用户活动；仅 macOS host）
  - [x] 设备页「用屏幕共享打开」（仅 macOS B，A 有局域网地址时）：只打开系统「屏幕共享」到 A（`vnc://<A 局域网 IP>`），登录密码由用户在那里自己输入；rapp 不保存、不代输入。hub 只把 A 的局域网地址给 GUI，从不给密码（有测试）。需 A 开启「屏幕共享」
  - 摸底：锁屏时按 PID 投递（`postToPid`）或 AX 写入能否送达 app——要锁 A 的屏做实机测试，需用户安排时间
- [x] P2 多个客户端同时连一个 host：规格 2026-11-12-rapp-multi-client-design.md，计划 2026-11-13-rapp-multi-client.md，代码完成（963e9cf..59dddd7，swift/cargo/flutter 全绿，终审已修）。实机已过（2026-11-13，`scripts/multi-client-loopback.py` 6/6 PASS：接管、坏 token、第三台接管、让位、v5 静默挡）
- [x] P3 触摸屏双指上滑/下滑（用户 2026-11-12）：spec `docs/superpowers/specs/2026-11-13-rapp-touch-scroll-design.md`；只改 Flutter 嵌入画面（b8b7361 + 评审修复 d0857d0，flutter 649 过，check.sh EXIT=0）。待实机：需要一台触摸屏 B。留待以后：滚动量没按缩放换算成 A 的点数（和触控板现状一致）；双指滑动时每帧会发两条 scroll。会话切换时按住的鼠标键已修（5f47ebb，切换时立即在原会话松开）

## 数据目录 ~/rapp（2026-11-13，规格 2026-11-13-rapp-data-dir-design.md，计划 2026-11-13-rapp-data-dir.md）
- [x] 代码完成（9053477..37b4c43，feat/app-profiles 上）；终审 1 严重 2 重要已修：不是 rapp 的文件夹不动 git、机密没被挡住就停（3aaea7f）；没装开发者工具不再弹窗（9384c0e）；「直接用」带上本机 local/（054d177）；出错后下一轮重新同步（37b4c43）。cargo 279、flutter 738 过
- 实机（2026-11-13，用户同意，装 dist/rapp-0.5.1.pkg 测试版）：
  - [x] PASS `~/rapp` 的树和规格 §1 一致；`local/` 0700，service.json/hosts.json 0600；`local/migrated-from` 是旧目录；旧目录文件都在
  - [x] PASS 设备 id 没变（local/service.json 的 id 和装之前一样）
  - [x] PASS 第一次自动提交含 `devices/<id>/device.json`；`git ls-files` 里 `local/`、`files/` 下 0 个
  - [x] PASS service.log 有 `data_commit {files:6}`，没有文件名
  - [ ] 待用户在 GUI 里：设备/常用/项目/主题和装之前一样；设置页「数据目录」显示 ~/rapp、「只在本机」，「打开数据目录」；固定文字 → 提示一次、`clipboard/` 多一个 .md、重开后「之前固定的」、取消固定文件没了；下载文件进 `files/transfers/`、「显示位置」；「更改位置…」到空文件夹 → 「复制」→ 指针文件；「改回默认」→「直接用」→ 指针没了
- [x] 新问题（实机发现，和数据目录无关）：pkg 的 postinstall 先 `launchctl bootout` 紧接着 `bootstrap`，旧服务还没退完 → 「Bootstrap failed: 5: Input/output error」，装完服务没起来（这次手动 bootstrap 起来了）。要改：bootout 后等到服务真的没了再 bootstrap，失败重试几次。已改（0.5.2）：bootout 后最多等 10 秒到旧服务没了，bootstrap 失败重试 5 次；待实机：你装 0.5.2 时看服务是否自己起来
- 暂缓的小问题（终审 M1–M13）：临时文件名可能撞；复制失败留半截；搬家时正在读写的固定条目；固定失败没提示；「直接用」后新目录的固定条目要重开才出来；复制到 .git/index.lock；输入 `~/` 不展开；.gitignore 的 files/ local/ 没锚定；README 里日志位置在 Linux 上不对；`git init -b` 要 git 2.28+；pull 下来的 workspace.json GUI 不重读（后写的赢）

## 积压小问题清理（2026-11-13，用户「继续自主完成更多可以完成的任务」）

- [x] 把各阶段暂缓的小问题对照现码过了一遍：8 个要修、18 个不修（外观/推测/要实机）、11 个早已修好
- [x] F1 太旧的剪贴板条目：固定时提示「这条太旧了，A 上已不保留」，「复制到本机」也会提示 5 秒、不盖掉之后的传输状态（af00f79、799114b、3068d7b）
- [x] F2 已下载好的升级，之后一次检查失败不再变成「升级没有完成」（c37e6e1）
- [x] F3 滚动量按缩放换算成 A 的点数；F4 双指滚动每批只发一条（fb9aedb，规格 T3 已改）
- [x] F5 剪贴板下载显示「下载 图片 45%」而不是 image（00e0534）
- [x] F6 升级残留提示写明要删哪个文件（1eaf91b）
- [x] F7/F8 补测试：没有在用的会话不让位；连续被挡时 1 秒提示重新计时（10390c3、af00f79）
- 验证：swift 264+、check.sh EXIT=0；cargo test 全过、clippy 0 警告；flutter 660 过。滚动换算待实机手感确认

## Linux 合并到 0.4.1（2026-11-12）
- [x] 合并 `release/0.4.1`，保留已有 GTK client、Flutter 内嵌、构建/Omarchy 打包脚本及性能修复；Rust/Flutter 版本同步 0.4.1。
- [x] worker 断线与结束会话分离：断线停止连接但保留最后画面；结束时释放画面。Linux 图像可用于断线舞台，重连首次出图切换新会话并释放旧画面。
- [x] worker 上报每秒帧数，接通 0.4.1 空闲状态；结束正在启动的 worker 会取消启动，避免遗留进程。
- [x] 绘制等待使用逐帧取消信号，避免长期在同一个 Future 上积累回调；保留最新帧邮箱和独立重绘。
- [x] 修正 worker 启动失败测试的隔离性，避免误启动已安装或已编译的真实客户端。
- 验证：Flutter 401 项通过、1 项跳过；Rust workspace 136 项通过；Flutter analyze、workspace Clippy 无问题；Linux release bundle 编译成功。新增/扩展回归覆盖断线保留像素、重连换帧、启动取消、帧数统计和绘制停顿时及时断线。
- 本轮未在真实 Mac 上重新验证；macOS 原生代码来自上游，未在 Linux 编译。0.4.1 Linux 尚未发布，既有 v0.4.0 Release 附件保持原样。

## Linux 输入后画面延迟追赶（2026-11-12）
- 用户报告：远程输入已经执行，画面几秒后才追上。现场采样中 worker 解码 CPU 很低，Flutter 正在持续接收展开的 BGRA 图像。
- 确认的排队问题：worker 在接收线程同步写整帧 stdout，显示管道一慢就停止读取远端；仅在 Dart 保留最新帧不能消除前面的旧帧队列。
- 修复：独立输出线程；压缩增量帧仍逐帧解码，只替换等待输出的完整画布（最多一个）；控制事件保持顺序并有界，替换画布排在对应窗口元数据之后，复用像素缓冲。
- 回归：core/worker 20 项通过、相关 Flutter 46 项通过、Clippy 通过。新慢消费夹具验证跨被跳过画面的增量依赖及最终像素；1080p 60 帧、模拟 64 MiB/s 消费，旧版输出 60 帧、追赶 8.235 秒，新版输出 2 帧、追赶 0.274 秒。这是本机 worker 管道测试，不是实机输入到显示延迟。
- 更新现有吞吐脚本为单帧在途，避免新丢弃策略使旧脚本一直等待被替换的帧。已原子替换本地 0.4.1 bundle 的 rapp-session；已有连接使用原进程，重连后启用修复。尚待用户实机复查。

## 0.4.1 Omarchy/Linux 发版准备（2026-11-12）
- 用户已确认输入后画面延迟问题解决，并授权提交代码、发布到现有 v0.4.1 Release。
- README 安装指引更新到 0.4.1；构建时原子替换 worker，允许本机 app 保持运行，避免覆盖运行中可执行文件导致 ETXTBSY。

## Linux 主线对齐 0.5.0（2026-11-13）
- [x] 先将已发布的 linux/0.4.1 全部变更合并至本机 main，再合并上游 v0.5.0（963e9cf），保留 Linux GTK client、内嵌会话、打包工具和低延迟输出线程。
- [x] 接入共享的项目与常用、全景及 1 fps 后台策略、触屏双指滚动；Linux 双指操作后正确获得键盘焦点。
- [x] S6 文字剪贴板资源：固定副本、结束会话后复制、取消固定释放副本；会话文字历史保留 100 条，与全局未固定条目上限对齐。
- [x] Linux 本机页独立提供版本与检查更新：严格选取对应 GitHub Linux 安装包，浏览器打开发布页/安装包，由系统软件包管理器安装。后台服务未启动时仍可使用；不显示 macOS 权限和自动安装/回滚控件。
- [x] macOS 权限/升级测试通过显式平台参数在 Linux 上验证，另测 Linux 页不需要本机服务、没有 macOS 误导入口。编译脚本将 workspace 版本注入 Linux GUI。
- 验证：Flutter 660 项通过、1 项跳过；Rust workspace 228 项通过；Flutter analyze、workspace Clippy 通过；Linux release bundle 构建成功。低延迟回归保持 60 帧解码、只输出 2 帧、追赶 0.271 秒（本机管道夹具）。
- 既有边界：Linux 被控端、内嵌分离/放回、图片/文件传输仍未实现；Linux 升级走系统安装包，macOS bundle 自动升级与回滚不适用。macOS 原生代码未在 Linux 编译；0.5.0 尚未在真实远程 Mac 上复查，也未发布新的 Linux 附件。

## 0.5.0 Omarchy/Linux 发布（2026-11-13）
- 用户已启动本机 0.5.0 app，确认可以使用并授权发布安装包。
- README 下载和安装指引更新至 v0.5.0；从干净提交构建安装包、便携包和 SHA-256 校验文件，保留现有 macOS/relay 附件。

## relay2 soak (2026-11-13)
- 时长 600 s，50 台假设备（均来自 127.0.0.1），持续登记、牵线、接流（20 KB 往返）、断开重连；共完成约 234000 条流。
- 进程常驻内存：第 2 分钟 30240 KiB，结束 31584 KiB，比值 1.044（上限 1.2）。
- 命令：`cargo test -p rapp-relay2 --release --test soak -- --ignored --nocapture`（`RAPP_SOAK_SECS` 默认 600）。24 小时那次仍由用户执行。

## relay2 bench (2026-11-13)
- 取 7 次交错运行里最快的一次比（R21，干扰只会加时间；每次运行的 CPU 随核位置/温度呈双峰，相差约 15%）。两次完整运行：old_ms=7142 new_ms=7133 ratio=0.999；old_ms=7290 new_ms=7196 ratio=0.987（均通过，上限 1.05）。中位数比 0.992、0.934（仅供参考）。上一版按 7 次中位数：0.979 通过、1.075 失败。CPU 毫秒 = 每个 relay 子进程各自 wait4 的 utime+stime，512 MiB 单向 64 KiB 一块，新 relay 不限速。更早 3 次中位数的比值：1.025、1.006、0.968、0.990、1.072、1.045、0.892；单次噪声约 ±7%，均值约 1.0。
- rss_mb=11.7（100 台设备入网登记后静置 10 s，上限 50）。
- 机器：本机 Mac arm64。命令：`cd rust && cargo build --release -p rapp-relay && cargo test -p rapp-relay2 --release --test bench -- --ignored --nocapture --test-threads=1`。

## 新 relay 服务（`rust/relay2`，规格 `docs/superpowers/specs/2026-11-13-rapp-relay-design.md`；提交范围 `39c1330..HEAD`）
- [x] 任务 1 设备身份和指纹（`rapp-wire`）：`39c1330..bf6e114`
- [x] 任务 2 key 格式和推导：`bf6e114..bea0503`
- [x] 任务 3 双向 TLS、行协议、relay 消息：`bea0503..1ca73e4`
- [x] 任务 4 分层配置：`1ca73e4..1642934`
- [x] 任务 5 设备登记簿：`1642934..497810f`
- [x] 任务 6 审计日志：`497810f..c423aec`
- [x] 任务 7 上限和限速：`c423aec..3d3cfdd`
- [x] 任务 8 传输、准入、入网：`3d3cfdd..88eda20`
- [x] 任务 9 登记、牵线、吊销名单：`88eda20..78caa8d`
- [x] 任务 10 中继流和计量：`78caa8d..0fc7551`
- [x] 任务 11 管理套接字、子命令、优雅停止：`0fc7551..00993fc`
- [x] 任务 12 统计行和指标接口：`00993fc..24733dc`
- [x] 任务 13 密钥扫描、畸形输入、久跑：`24733dc..7dc326d`
- [x] 任务 14 Docker 镜像：本提交。第 3 步（`--multi`）在 colima 上 amd64、arm64 都构建成功（amd64 在 QEMU 里编译 6 分半），`docker run --platform linux/amd64 … --version` 输出 `rapp-relay2 0.5.2`；arm64 镜像压缩后 5.7 MB，冒烟检查 8 项全过
- [x] 任务 15 性能：relay 开销对比旧 relay、空闲内存：`7dc326d..b0a3086`
- [x] 任务 16 文档（配置规范总览、可观测性规格、本文件）：本提交

### 未经实机验证
- 任务 14 第 3 步（多架构构建）：已在 colima 上做完（见上）；未做的是推送到 ghcr.io（`--push`，待用户登录后执行）和在真正的 Linux 主机上用 `network_mode: host` 跑一遍
- 来源地址实测（`network_mode: host`，另一台机器 `probe` 入网，看审计日志 `enroll` 的 `from` 是不是公网地址）：待用户的 VPS
- 24 小时久跑（`RAPP_SOAK_SECS=86400 cargo test -p rapp-relay2 --release --test soak -- --ignored --nocapture`）：待用户

## 写作面板（规格 `docs/superpowers/specs/2026-11-14-rapp-composer-writing-panel-design.md`，W1–W16）
- [x] S1：Flutter 编辑器（`ComposerEditor` 缝、`FlutterEditor`）、写作面板（720 宽、一行 48、字号 15、行高 22，往上长到舞台一半）、「＋」浮层（300 宽）和提示行、打开时画面上移 64 而 A 的尺寸不变、各平台 Ctrl+Enter（macOS ⌃↩ 留在本机，Linux 不发给 A，概览里不响应）
- [ ] S0、S2（macOS 原生编辑器）、S3（Linux 探查）未做
- S2 计划必须包含（S1 最终评审留下的）：attach 排在没做完的 detach 后面（或每个会话一个编辑区）；空闲拷贝带代号，过时的结果丢掉；画面取焦点的守卫要跟着 `editorFocused` 变化重试（原生焦点是异步的）；`read`/`take` 出错时怎么办；`FlutterEditor.read()` 组字时没排在待写入的 `setText`/`insert` 后面，不合 FIFO 约定；`adoptFrom` 读旧编辑区时如果它在组字，新面板已经接上，会用旧草稿；三种编辑区（Fake、Flutter、原生）共用一套编辑区约定测试（规格 A4）；`onArrow`、隐藏、位置（H2/A3）
- 待实机（不在这个计划里验收）：
  - 真实 app 上画面上移 64 碍不碍事（规格评审 U1）
  - 中文输入法下打字；组字时点击
  - 打开的「＋」浮层（约 290 px 高）可能盖住提示行（W9、W11）
  - 输入区打开时，ClipRect 会把 A 窗口最上面 64 px 藏起来（W4、规格评审 U1）
  - 输入法提示的点按区域只有约 28 px 高（W11）

## 输入记录（规格 `docs/superpowers/specs/2026-11-14-rapp-input-history-design.md`，§10 H1–H3）
- [x] H1：记录和草稿的读写（§4、§5）、写作面板发送和草稿接上、两个开关（`input_history`、`recordInput`，§8）、数据目录 README 和几份规格的文字（§11）
- [x] H2：↑ 取上一条（R2、R3）、输入历史列表（写作面板「＋」和资源标签，R4、R5）、主界面规格 §3.7 和写作面板规格 W17
- [ ] H3 未做
- [x] 2026-11-17 修了四处：往 A 的密码框发过一次之后，这个会话之后的话都不再记、草稿也不再存；记录关着时发送失败的文字崩溃后找不回；↑ 取出来没改的话在会话结束时又记成一条「没发出」；结束会话丢掉最后 1 秒打的字
- H1/H2 最终审查留给 H3 的（这次没改）：
  - 草稿只存文字：没发出去的块（长文本粘贴、文件）不进 `draft` 记录，崩溃或结束后也不恢复（§5.2）
  - [x] 记录关着时，发送失败那一轮的文字只在内存里的失败行，崩溃或会话结束就没了（修复：没有记录接住时，失败的那一段留在草稿文件里）
  - [x] 主动「结束」会话时，最后不到 1 秒打的字可能没进草稿（修复：结束时直接读编辑区）
  - 内存：每条记录整份 `raw` 留着，本机新加的在 `_added` 里还有一份；做索引前要收
- 待实机（不在这个计划里验收）：
  - 真机上发送中强杀 rapp 再开，文字还在输入框里（§5.2、§10 H1 验收）
  - 两台主控台同步后，能看到对方 `devices/<id>/inputs/` 里的文件（§5.1）
  - 触屏上「＋」→ 输入历史的点按大小（§6 R4）
- [x] 2026-11-21 iPad 上输入记录一直写不进去（用户报告）：iOS 没有 rapp-service，`local/service.json` 没有 `id`，每条都因「还不知道这台设备的 id」失败，`gui.json` 也从不保存。修复 fix/ios-device-id：启动时 `ensureDeviceId` 补 9 位 id 和 `devices/<id>/device.json`（模拟器上看过：生成、重开不变）
  - [ ] iPad 实机：发一句话后杀掉 app 再开，↑ 能取回、「＋」→ 输入历史里有这条，来源显示 iPad 的名字
  - [ ] iPad 实机：改一项全局设置（如主题）后杀掉 app 再开，设置还在
  - 没做（要用户定）：iOS 没有 git 同步，iPad 和 Mac 的输入历史互相看不到

## 项目作为工作域（规格 `docs/superpowers/specs/2026-11-14-rapp-project-design.md`，计划 `docs/superpowers/plans/2026-11-14-rapp-project-working-spheres.md`，G1–G12）
- [x] 2cc38b7 pinned
- [x] e6685bc 排列偏好 `first` + `local/project_positions.json`
- [x] 868473d 纯函数
- [x] 759f4f7 + dd956cb 当前/上一个项目、回来的线索、结束只在项目内
- [x] 8a36f05 搬数据目录时的位置文件修正
- [x] f68f2d8 存成项目、固定、删后可撤销
- [x] c774b87 + f228964 项目页
- [x] a69d84e 顶栏、分组标题可点、流中菜单加入项目
- [x] 6bda0bf 排列下拉（设备在前/项目在前）+ 全景排序
- [x] 文档：S5、主界面、设计语言、路线图、配置规范
- 未经实机验证：
  - 平板上新控件的触控大小：切到、固定、存成项目、撤销、上一个项目、加入项目、排列下拉
  - 回来的线索的位置是否挡住别的东西
  - 全景里项目那一排在上面时插画的大小
  - 很窄的顶栏上「上一个项目」被隐藏
  - 线索里「等你」的个数只有单元测试，现在没有会话会亮 Lamp.waiting
- [x] 收尾（分支 fix/spheres-followups）：项目外的会话打开失败不再离开项目；在别的项目卡片上点「全部打开」先切到它；项目里没有开着的会话时线索显示在顶栏项目名下面；成员很多的窄卡片上灯会折行，标题行不再溢出
- 仍然留着：在项目里选会话后不到 1 秒就强退，这次选择可能没记住（位置 1 秒后才写盘）

## 智能预设与焦点面板第 1 步（规格 `docs/superpowers/specs/2026-11-16-rapp-focus-pane-rules.md`，计划 `docs/superpowers/plans/2026-11-16-rapp-focus-pane.md`，T0–T12，分支 feat/focus-pane）
- [x] T1–T11：协议 v12、A 端无障碍读焦点面板、「智能」预设、app 配置 `focusPane`、B 端把焦点外变灰
- [x] T12 文档与收尾
- 交付说明：
  - 第 1 步灰色只在 B 显示时画，不省流量，也不改帧格式；省流量是第 2 步
  - 自动测试：`scripts/check.sh` EXIT=0（Swift 453 项通过、1 项跳过）；`cargo test -p rapp-client-core` 全过、`cargo build -p rapp-client-gtk` 通过；`flutter analyze` 干净，`flutter test` 1655 项通过、8 项跳过
  - `scripts/focus-loopback.py` 在 T6 时对假宿主的回环里通过
  - 规格 §10 的十个场景没有一个在真机上看过，全部留给用户
  - T0 探查没跑：门槛仍是起步值（40 层 / 85% / 15% / 240×160 / 50 ms）；探查文档和调门槛等用户的真机结果
  - `AXManualAccessibility` 第 1 步没有在任何地方设置；Electron 和 Chrome 不给控件树时整窗保持彩色
- [x] 调试框：B 在每个焦点矩形内侧画 2px 框（颜色跟主题走，用主题的 `on` 色：黑客帝国绿、阿凡达青、西部世界白），看 A 选了哪块。开关是 `gui/lib/embed/focus_gray.dart` 的 `showFocusFrames`，默认该关，现在为调门槛先开着；调完改成 `false`
- 未经实机验证：
  - 规格 §10 的十个场景：§5 的七个例子；鼠标横穿不换焦点；停住约半秒换一次；写作面板发送期间键盘面板不变；弹出菜单和对话框全是彩色；拖边改窗口大小后焦点跟着走；触屏点和滑；智能与最清晰来回切；智能下关掉"网络差时自动省流量"仍会降档；开着智能用半天 A 端 app 不卡（重点 Electron 三个）
  - 真实 app 构建编译 `gui/macos/Runner/SessionPlugin.swift`（只有真机构建才编译它）
  - `BackdropFilter` 灰度叠在 `Texture` 上的真机效果

## 端口分享：用本机端口访问（规格 `docs/superpowers/specs/2026-11-16-rapp-port-sharing-local-ports-design.md`，分支 feat/port-map，2026-11-16 按用户要求并进 main，U152）
- [x] `rust/service/src/maps.rs`：给（设备，端口）分配 28000–28999 里的本机端口，监听 `127.0.0.1` 和 `::1`，连进来的走 `pipe::open`；存 `local/maps.json`，启动时恢复
- [x] IPC `shares`（带 `to`）、`hosts` 的回复带 `local` 和 `addr`（`http://localhost:<端口>`、`ssh -p <端口> localhost`）；`url` 字段去掉
- [x] `rapp hosts` 每个端口一行带地址；`rapp share` 不再打印 `.rapp` 地址
- [x] 面板：地址照服务给的显示，"打开"直接可用；去掉"还没有启用 .rapp 域名"
- 验证（Linux arm64，rustc 1.100）：`cargo test --workspace --exclude rapp-client-gtk` 里 testkit 的 `maps` 10、`share_set` 18、`forward` 65 全过，`rapp-service` 单元测试里 `maps` 12 条全过，`rapp-cli` 10 条全过；`cargo clippy -p rapp-service -p rapp-cli -p rapp-testkit --all-targets` 没有警告。这台机器上本来就不过的 3 条（`data::tests::a_rebase_that_cannot_start_is_an_error_and_retried`，`rapp-term` 的 `open_without_shell_uses_the_default`、`open_runs_the_shell_as_a_login_shell`）在 `main` 上同样不过，和这次改动无关

- 交接：`docs/superpowers/plans/2026-11-16-port-sharing-local-ports-handoff.md`（东西在哪、验证到哪、下一步）

### 未经实机验证
- [x] `cd gui && flutter analyze && flutter test`：2026-11-16 在 Mac 上跑过。`a share that leaves this device out` 不过，是测试数据给不含本机的分享也配了地址（服务不给），改了测试数据（8133648），之后 1693 条全过
- [x] macOS 上 `cargo test --workspace`：2026-11-16 547 条过；`rapp-term` 的 `a_dead_socket_is_removed_and_skipped` 跑全套时失败一次，单跑 3 次都过，和这次改动无关
- [ ] 真机：两台设备，一台分享 Jupyter / Ollama / Vite / sshd，另一台在面板里点"打开"、用 `curl http://localhost:<端口>`、`ssh -p <端口> localhost`；经 relay 和局域网各一次
  - 2026-11-16（0.12.2）：用户报告别的机器经本机映射端口访问这台的 8007（Python display_server）成功。反方向：MacBook-M4-Pro 的 8007 没有服务在听，这台连 `localhost:28000` 时日志如实记 `map_refused … refused`。还差：sshd（22）、经 relay 和局域网各一次分开确认
- [ ] 真机：访问方的服务重启后，不打开面板，原来的地址还能用
- [ ] macOS：别的程序在"所有地址"上监听 28000 时，rapp 跳过它

## 协议 v13：A 端提示（弹窗挡点击、点开了别的 app、密码框）（已合并到 main，随 0.13.0 发布）
- [x] 协议 v12 → v13，四条新消息：`covered`(37)、`dismissCover`(38)、`appOpened`(39)、`secureFocus`(40)；Swift、RappSession、SessionPlugin → Dart、Rust client-core / rapp-session / client-gtk 一起改，两边用同一段十六进制样例测
- [x] 问题 1（系统级弹窗挡点击）：无障碍复查不再只认程序坞。任何 app 的半透明窗口、或盖住所在屏幕 85% 以上的窗口，只有无障碍命中它（或什么都没命中）才算挡住；普通窗口不调无障碍。被挡的按下扔掉，A 发 `covered`（同一个 app 5 秒最多一次）
  - B 顶上一条黄条：「A 上「名字」的弹窗挡住了点击」，按钮「在桌面会话里处理」（打开或切到 `desktop:`），A 说可以时再加「关掉它」，× 关掉，15 秒自己消失
  - 「关掉它」只在 B 点了才做：A 先重新核对这个 app 能不能关，再用无障碍按取消 / 关闭按钮。SecurityAgent、loginwindow、CoreServicesUIAgent、通知授权、触控 ID、屏保，以及包名里带 security / auth / password / keychain / login / permission / privacy 的，一律不关，只给「在桌面会话里处理」
- [x] 问题 2（点开的浏览器、预览没显示）：输入后 2 秒内别的普通 app 到了前台，A 发 `appOpened`（只 app 会话发；程序坞、通知中心、控制中心、聚焦搜索、rapp 自己等不算）。B 黄条「A 上打开了「名字」」，「打开」就是 openOrSwitch
  - 已知：这台 B 在同一台 A 上开着两个 app 会话，在第一个里输入后 2 秒内切到第二个，第一个可能报第二个"被打开了"；点「打开」只是切过去
  - 重新激活没改：在会话里打字时 A 仍会把会话的 app 拉回前台，盖住刚打开的浏览器。所以要看浏览器得点「打开」
- [x] 问题 3②（密码框）：A 只读焦点控件的 role / subrole（`AXSecureTextField`），从不读内容，变化时发 `secureFocus`。B 在密码框里时：打字不再弹写作面板（macOS 在 SessionPlugin 里按键时就判，Linux 在 LinuxSessionPort 里判）；面板已开着时发出去的字不记进输入记录；断线时清掉
- 自动测试（2026-11-17，Mac）：`swift build` 通过；`swift test` RappCoreTests 478 项通过（1 项跳过），RappSessionTests 171 项通过；`flutter analyze` 干净，`flutter test` 1703 项通过、8 项跳过；`flutter build macos --debug` 通过；`cargo test -p rapp-client-core` 全过
- 没验证到的：
  - `rust/client-gtk/src/ui.rs` 只在 Linux 编译，Mac 上 `cargo build -p rapp-client-gtk` 不编它，改动没编过
  - LinuxSessionPort 的密码框开关没有单元测试
  - 写作面板里已经打了没发的字，在密码框里仍会照常存进草稿文件（只是不记"已发送"）
  - 分离出去的会话窗口不显示这条黄条
- 实机检查：
  - [ ] A 上弹出通知中心横幅 / 系统授权框挡住 app 窗口时，在 B 点被挡的地方：出黄条，名字对；授权框只给「在桌面会话里处理」，点了切到桌面会话
  - [ ] 通知横幅点「关掉它」：横幅关掉，之后点击能到 app；日志里有 CoverCloser 的结果
  - [ ] 半透明的悬浮窗（比如录屏工具的控制条）不挡点击时，点击照常到 app，不出黄条
  - [ ] 在会话里点一个链接打开 Safari / Chrome，点图片打开预览：出「A 上打开了…」，点「打开」后在 B 上看到它
  - [ ] 两个 app 会话之间快速切换，看会不会误报「打开了」
  - [ ] 在会话里点进登录密码框（网页的、系统的）：直接打字不弹写作面板，字直接到 A；离开密码框后又会弹
  - [ ] 写作面板开着时把焦点放进密码框发送：输入记录里没有这一条
  - [ ] 桌面会话里的密码框（不装观察器，只靠每秒检查）：最多晚 1 秒生效
  - [ ] 旧 B（v12）连新 A、新 B 连旧 A：版本不符的提示照常
## 统一分享号 真机检查

- [ ] M5 分享 8007，M5 和另外两台都用同一个 `http://localhost:<分享号>` 打开
- [ ] 一个 MCP 服务（SSE 或 Streamable HTTP）经分享号接入 Claude Code 之类的客户端，跑一个工具调用
- [ ] MCP 连接保持 5 分钟不断（期间有空闲，也有调用）
- [ ] 一个 tcp 服务（比如 Redis）用 `rapp share <端口> --proto tcp` 分享，`redis-cli -p <分享号>` 能用
- [ ] 访问方上先让别的程序占住分享号，看到"这台上是 …（… 被占）"；退出那个程序后地址换回
- [ ] 撞号要等设备 ID 大的那台读到另一台的分享表才解开：让 ID 大的那台当不开面板的分享方（只跑服务，不跑 `rapp hosts`），和另一台撞号，确认它读到对方的表之前不换号，读到之后（开一次面板或跑一次 `rapp hosts`）才换

## iPad / Duo P0 探查留下的

规格 `docs/superpowers/specs/2026-11-17-rapp-ipad-duo-design.md`，测量结果 `docs/superpowers/measurements/2026-11-17-rapp-ipad-p0.md`。探查代码在分支 `probe/ipad-p0`，不合并。

- [ ] `scripts/build-ios.sh sim` 在这台 Mac 上失败（Xcode 27.2 / 27B52 + Flutter 3.44.1，framework 2026-05-29）：Xcode 自己编完（约 135 秒），之后 Flutter 报 `Xcode build is missing expected TARGET_BUILD_DIR build setting` 并以 1 退出，`Runner.app` 不生成。`device` 模式同机同版本是通的（已装到 Duo 上跑过），所以只有模拟器这条路受影响；疑似 Flutter 读 `xcodebuild -showBuildSettings` 跟不上新 Xcode，没有验证。先升 Flutter 再看
- [ ] 查 A 没锁屏时窗口抓取不出帧（这台 Mac，macOS 27）：测试页在画、窗口在屏幕内，客户端还是 0 fps；锁屏后 29–30 fps
- [ ] 上面查清后，补做手机和 macOS 的 CPU 对比（过关条件：不超过 macOS 同档的两倍），A 上不能有别的设备连着
- [ ] Duo 真机：开合序列、外屏窗口大小、开合时 App 是否一直活动
- [ ] iPad 真机：Q2–Q5 重量一遍
- [ ] 点一下到画面变化的延迟（随 P1 触摸的真机检查一起量）
- [ ] 6 个会话同时开着的内存，拔电时每小时耗电（§9.5）
- [ ] "本地网络"弹框在哪一步弹出，被拒绝时怎么提示；关掉本地网络再连一次，确认只走 relay 也能连上（记下 path）
- [x] FFI 接口（代码和 Rust 测试，68605e3、df442e0）：hub 退出后发 `on_line(NULL)` 当结束标记，`rapp_hub_send` 区分没启动和已退出（-3），`stop` 等转发线程读完再返回
- [ ] FFI 接口真机部分：Dart 收到 NULL 后让所有等待的请求失败，在 Duo 上确认
- [x] 密钥不经 `--dart-define`（493fca4：`scripts/build-ios.sh` 不传 `--dart-define`，Generated.xcconfig 里的 DART_DEFINES 只有 Flutter 自己的版本项；key 由 App 内填写）：它会被抄进 Flutter 生成的 xcconfig 和 App.framework。改成运行时传入（启动参数/环境变量或 0600 文件）
- [ ] iPad 多任务（分屏、侧拉、台前调度）下的窗口大小：探查带了 `UIRequiresFullScreen`，没量
- [x] 设备名由入口传给 hub（68605e3 加 name 参数，e21a731 `main_ios.dart` 传入；真机上 A 显示什么待查；原先 A 上显示 "rapp"）
- [x] Dart 在 iOS 上没有 `HOME`（e21a731：`main_ios.dart` 用 `iosChannel.paths()` 的 dataRoot，不读 HOME）：`gui/lib/paths.dart` 等改用原生传进来的家目录
- [x] RappCore 的 iOS 测试（1723bbc：`.swiftpm/.../RappCore-iOS.xcscheme`，`scripts/check.sh` 在 iPad 模拟器上跑）：提交一个 scheme 或测试计划
- [x] 签名（215b2b1 Automatic，团队 T5G56DH47L，Task 12 在 Duo 上装机成功）：Xcode 登录账号或 CI 签名

### P1 真机验收清单（分支 feat/ipad-p1，Duo 已装上，详见 `docs/superpowers/measurements/2026-11-17-rapp-ipad-p1.md`）

- [ ] 接入引导出现；填接入点和 key 后看到设备，打开 app 会话和终端会话（横竖两个方向）
- [ ] 手指：点、拖、双指滚动、双指轻点右键；控件不小于 48
- [ ] 键盘和触控板：英文、⌘C/⌘V、方向键、悬停、右键、滚动；粘滞 ⌘ + Tab 切换 A 的 app（随快捷键排暂缓：用户 2026-11-17 决定，远程画面那排快捷键先不出现，后续再设计，c874871；实机验收不判粘滞 ⌘ + Tab）
- [ ] 拼音硬件键盘第一个字母、长按 ⌫/方向键、Caps Lock、分屏或台前失焦后没有卡键
- [ ] 输入板：中文输入法一致、听写；软键盘弹收时 A 上窗口不改尺寸（看 A 的日志）
- [ ] 切走 30 秒回来 2 秒内画面恢复，草稿还在；A 锁屏且记住密码同样
- [ ] 关掉 Wi-Fi 再打开，与断网冻结规格一致
- [ ] 只有 IPv6 的网络（Mac 互联网共享）下经 relay 连上
- [ ] 无线数据被拒绝时的错误码是不是 -1009
- [ ] 内存告警：只释放 Flutter 纹理，`EmbeddedSession.surfaces` 仍被持有，用 Instruments 看
- [ ] keep-awake、`sessionActive`、UIScene 的 `onHide`/`onShow`
- [ ] 外接键盘接上或拔掉后 textInputAction 的 10 秒滞后；`latch_used` 往返
- [ ] 主窗口（带会话）在 Duo 上横竖屏、安全区、按键排不被遮挡（随快捷键排暂缓：用户 2026-11-17 决定，远程画面那排快捷键先不出现，后续再设计，c874871；实机验收不判这一项）
- [ ] 换掉默认占位图标和启动图
- [ ] TestFlight：确认 App Store Connect 有 App 记录后，用户决定上传方式（`rapp.ipa` 已能出，未上传）

## 终端跟着主控台窗口 真机检查（分支 feat/term-fit）

注意：iTerm 没有测过，下面第 1 条要在 iTerm 上实机看。

- [ ] iTerm：勾着时，iTerm 窗口跟着主控台窗口变；iTerm 设置里关掉"允许会话调整窗口大小"后，主控台照旧缩放、不出错
- [ ] Terminal：拖主控台窗口，松手约 0.3 秒后被控端窗口跟着变，vim / htop 按新尺寸重画，两边一致
- [ ] 主控台是 4K 屏、被控端是 1080p：被控端窗口停在最大，主控台按 1 倍靠左上画，不放大
- [ ] 两台主控台轮流打字：一台停手 2 秒以后另一台再打字，被控端改成另一台的尺寸；两台同时一直打字时不来回重排。另一台只是打开来看、或断线重连，不会改被控端窗口
- [ ] 被控端的人手动拖窗口：主控台接着打字不会把它拉回去；主控台拖一下自己的窗口才重新生效
- [ ] 不勾"跟着我的窗口"：和现在一样；缩放后的字和 1 倍时一样清楚，两个不同尺寸的终端笔画粗细一样
- [ ] 主控台窗口连续拖小时画面不卡（不卡就不用把字号量化到 0.25pt）

## Linux 四组件对齐（2026-11-17，0.13.8）

范围经用户确认：`rapp-term`、`rapp-service`、`rapp-hub`、`rapp-cli`；Linux 图形应用/桌面被控端另做。

- [x] 核对四组件共用的协议和实现：终端发现/订阅/创建/重命名/查看/输入/历史/fit，service 鉴权、会话管理、端口分享和数据目录，hub 设备管理、直连/中继/路由切换与终端代理，CLI `share`/`unshare`/`hosts`/`pipe`。
- [x] Linux 终端发现和启动合并当前 systemd 用户管理器的 PATH，保留显式 service PATH 的优先级；服务早于图形登录启动时也能发现桌面环境中的终端。
- [x] service 拉起连接管理窗口前刷新当前桌面环境；查询在阻塞线程池进行，不阻塞终端/应用数据转发。macOS 保持原有启动时序。
- [x] 启动器的进程退出和 stdout 读取共用超时；后代进程持有管道、大量输出、超过输出上限都不会让等待无期限延长。
- [x] 新增 `scripts/test-linux-components.py`：四个真实 worker 在私有网络命名空间联调。验证当前桌面 PATH、终端创建/重命名/画面/输入/fit、连接管理窗口环境、CLI 二进制管道半关闭，以及 service/hub 重启后重新发现同一终端。只有终端窗口和 systemd 命令适配器使用夹具；真实 cgroup 生命周期另由 `test-linux-terminal-service.py` 验证。
- [x] Flutter 相关回归 282 项通过，1 项既有性能测试跳过；真实 systemd cgroup 会话保留、service 单实例/崩溃恢复、Linux 启动器参数及构建路径回归通过。
- [x] 最终四组件 Rust 测试 357 项通过；testkit 的 15 组集成测试累计 314 项通过、6 项既有显式跳过。端口释放后立即回收的用例在整组运行中偶发失败一次，单独连续三次及整组重跑均通过，未放宽断言。
- [x] 四组件 Clippy（所有 target，警告视为错误）通过；0.13.8 release 二进制输出在 `rust/target/release/`，再次通过四组件联调和真实 systemd cgroup 测试。未安装、未重启现有 rapp 服务。日志为 `.build-logs/components-linux-*.log`。

Linux 服务生命周期使用 systemd，升级沿用系统安装包/完整便携包；macOS 的 TCC 权限、锁屏和 `.app` 自动替换/回滚不作为 Linux 四组件的实现接口。fit 请求会转发给终端窗口，实际窗口是否响应仍取决于终端模拟器，不能把伪终端验证当作所有模拟器的实机验收。

## Linux 0.13.9 发布（2026-11-17）

- [x] 按用户要求先拉取最新 main（`27010a0`），合并四组件适配 `271f9dc`；发布源码 `bb8434b921948ee88dedf2c1620977c6746a5584` 包含 v0.13.9 的全部变更，推送到 main 和 `linux/0.13.9`。
- [x] 在干净 worktree `rapp-linux-0139` 完整构建；保留主工作区尚未提交的输入、舞台与性能诊断改动，未将其带入安装包。
- [x] Rust workspace 1101 项通过、9 项显式跳过；Flutter 1879 项通过、3 项显式跳过，analyze 无问题。四组件 Clippy 所有 target 无警告。额外全 workspace Clippy 在既有 GTK `focus.rs` 的 `chunks_exact_mut(4)` 触发新工具链风格 lint；未为发版改变该逻辑。
- [x] 安装包和便携包 33 个文件逐一摘要一致；12 个 ELF 依赖解析通过；GUI/worker 版本、BUILD-INFO 源码提交匹配。解包后通过 bundle smoke、四组件联调、真实 systemd cgroup 会话保留、GTK4 对端夹具与 GTK3 原生窗口/输入测试。
- [x] 已上传到 [v0.13.9 Release](https://github.com/wizlijun/rapp/releases/tag/v0.13.9)：`rapp-omarchy-0.13.9-1-x86_64.pkg.tar.zst`、`rapp-0.13.9-omarchy-x86_64.tar.gz`、`rapp-0.13.9-omarchy-x86_64-SHA256SUMS`；GitHub 返回的大小和 SHA256 与本地产物一致。更新 Linux 发布说明，macOS 原附件摘要保持不变。
- [x] 更新网站源码中的下载备用快照，8 项选择规则/快照测试通过；线上页面正常从 GitHub API 自动获取此版本，本轮未部署网站。

产物在 `dist/linux-0.13.9/`。构建日志在主工作区 `.build-logs/package-linux-0139.log`，完整测试日志在发布 worktree 的 `.build-logs/*0139.log`。真实 macOS 对端及各终端模拟器的物理窗口/输入体验仍需设备验收。


## Linux 桌面 host 与 0.14.1（2026-11-17）

- [x] 新增 Rust `rapp-host`，复用现有 v13 协议，支持 Omarchy/Hyprland、兼容 wlroots 的 Wayland 和 X11 桌面被控端。包含显示器列表、逐屏会话、增量帧、键鼠/滚轮/Unicode 文本输入、鉴权、接管、让出输入、踢出、退出释放输入、帧确认背压。
- [x] 服务启动 worker 前刷新图形会话环境；区分整桌面与单应用能力，Linux 的诊断不再显示 macOS 授权提示；构建与 Arch/便携打包包含 host。
- [x] 原生采集、跨协议解码、错误 token、接管、踢出和 EOF 在 Omarchy 实测通过；隔离 Xvfb 与 headless labwc 验证输入坐标、快捷键、中文输入、修饰键释放与物理键映射恢复。可用 `python3 scripts/test-linux-host.py --current` 重现（需要 Xvfb、labwc、Xwayland）。
- [x] 相关 GUI 112 项、service 集成 50 项回归通过，Flutter analyze 与新 host Clippy 无问题。端口映射测试在独立网络命名空间通过，避免运行中的服务占用测试端口。
- [x] 完成实现后再次执行 `git pull --rebase`，整合上游 `27f637e`（0.14.0 / iOS hub）；保留 hub-ffi 和 host-linux workspace 成员，Linux 发布顺延为 0.14.1。
- 边界：GNOME/KDE Wayland portal、单应用共享、Linux host 的剪贴板/文件传输、自动输入解锁密码尚未实现。X11 文本输入依赖 `xdotool`；本轮无法在 Linux 构建或真机验收 macOS client。

## Linux 0.14.1 发布验收（2026-11-17）

- [x] 发布源码 `10f19766a54bd0bbb7e02e11bd168912117891df` 整合最新上游 0.14.0；main 和 v0.14.1 标签已推送 GitHub。干净 worktree 构建产物位于 `dist/linux-0.14.1/`。
- [x] 合并后的相关 GUI 回归 471 项通过，1 项既有跳过；service 集成 50 项通过；client-core 与 host 测试、Flutter analyze、新 host Clippy 和 Linux 构建路径夹具通过。
- [x] 隔离 Xvfb、headless labwc 验证采集、输入、中文、修饰键释放、鉴权和接管。本机 Omarchy debug 原生采集在并行构建期间出现过一次超时，随后复验通过；最终解包后的 hub → QUIC service → host 桌面采集连续四次通过。未以此代替真实 macOS/iOS 对端验收。
- [x] 安装包与便携包 33 个文件逐一摘要一致，13 个 ELF 依赖解析通过；host 版本 0.14.1 / 协议 v13、BUILD-INFO 源码提交及 SHA256 匹配。
- [x] [v0.14.1 Release](https://github.com/wizlijun/rapp/releases/tag/v0.14.1) 已公开：Arch 安装包、便携包、SHA256SUMS；GitHub 返回的大小和 SHA256 均与本地一致。发布使用 latest=false，保留 macOS 0.14.0 的 latest.json 更新入口。
- [x] 从 GitHub 已公开数据刷新网站下载备用快照；未部署网站、未安装新包或重启本机服务。

## Linux 0.14.3 发布（2026-11-18）

- [x] 按用户要求重新拉取 main 至 `1e66efa`，纳入 0.14.2 修复及侧栏/设备选择界面合并；修正「本机」页仍声称 Linux 不能共享桌面的旧提示，按实际 capabilities 显示。
- [x] 发布源码 `96e326015f0db97d04d3d033c92c006965353b04`，main 与 v0.14.3 标签已推送。干净 worktree `rapp-linux-0143` 构建；最终产物位于 `dist/linux-0.14.3-final/`。
- [x] 相关 GUI 首轮 586 项通过、1 项既有跳过，1 项旧文案断言失败；修正断言并覆盖桌面能力提示后，受影响的 27 项复验全部通过。Flutter analyze、host/client-core 测试、host Clippy、构建路径夹具通过。
- [x] 两种安装包 33 个文件摘要一致，13 个 ELF 依赖解析通过；host 0.14.3 / v13、BUILD-INFO 源码提交及 SHA256 校验通过。解包后的 hub → QUIC service → Omarchy 桌面采集及 CLI/分享端口检查连续三次通过。
- [x] [v0.14.3 Release](https://github.com/wizlijun/rapp/releases/tag/v0.14.3) 已公开，包含 Arch 包、便携包和 SHA256SUMS；GitHub 端文件大小和 SHA256 与本地一致。latest=false 保留 macOS 0.14.2 更新入口。
- [x] 根据 GitHub 公开数据更新网站备用快照；未部署网站、未安装或重启本机服务。本轮未进行 macOS/iOS 真机验收。

## Linux 桌面空标识握手修复与 0.14.6（2026-11-18）

- [x] 定位 `wrong desktop`：Swift SessionPlugin 与 Rust rapp-session 的内嵌连接发送空 app，代表使用已绑定的桌面；Linux host 原先强制要求 app 完全相同，与 macOS host 的约定不一致。修复后允许空标识，保留 token/协议校验及明确指定错误桌面的拒绝。
- [x] 新增真实 Address 编码的回归用例，原生与 bundle 测试也改用空 app 握手。已安装的 0.14.3 原包能稳定复现报错，修复包通过 Wayland/X11、鉴权/接管、输入及完整串流验证。
- [x] 先以本机包 `0.14.3-2` 安装修复、重启服务与 GUI，用户明确确认“可以连上了”；随后按约定发布。其他设备的 client 无需升级。
- [x] 拉取并合入上游 `93a5ce6` / 0.14.5 日志界面，正式发布源码 `742991c6a2bc208e5d2bc1359c5e6b9a81299951`，main 与 v0.14.6 标签已推送 GitHub。
- [x] GUI 相关回归 497 项通过、1 项既有跳过；analyze 无问题。Rust 相关测试首轮 274 项通过、2 项原生 opt-in 跳过；唯一“未安装 host”用例受到本机已安装 host 的 PATH 回退干扰，隔离 PATH 后复验通过。包含 7 项日志集成、52 项 service 集成用例；host Clippy 与 Linux 构建路径夹具通过。
- [x] 干净 worktree `rapp-linux-0146` 构建产物位于 `dist/linux-0.14.6/`。两包 33 个文件摘要一致，13 个 ELF 依赖解析通过；BUILD-INFO、版本/协议、SHA256 匹配。最终包空 app 握手与完整桌面串流连续三次通过。
- [x] [v0.14.6 Release](https://github.com/wizlijun/rapp/releases/tag/v0.14.6) 已公开，Arch 安装包、便携包、SHA256SUMS 的 GitHub 大小与摘要均匹配本地；latest=false 保留 macOS 0.14.5 更新入口。网站备用下载快照已更新，未部署网站。
- 本机继续运行用户已验证的 0.14.3-2 修复包；此次正式发布未再次替换本机程序。未在本机进行 macOS/iOS 真机验收。
## iPad 捏合缩放与局部串流（2026-11-18，feat/pinch-zoom）

- [x] 协议 v14 `setView`、A 端按取景截局部、iOS 双指缩放（App 画面和文本终端）、底图、「还原」按钮已实现；规格 `docs/superpowers/specs/2026-11-18-rapp-pinch-zoom-design.md`，iPad 规格里的"不做捏合缩放"已改成指向它。
- [ ] 真机验收 1–8（Duo 和 iPad 各一遍，条目见该规格 §8「真机验收」）：不放大时行为不变；捏合放大和平移、按住再拖选字；流量不超过不放大时；平移不露黑边；输入板和软键盘；断网重连后取景还在，且 App 和桌面会话（A 端）各自在 `setView` 之后都记了 `region:` 日志（第 6 项，Task 8 留下的检查）；「还原」按钮；文本终端的放大、平移、滚回历史、选字。

## 按住说话（0.14.x，feat/voice-input）

- [x] iOS 语音按钮：按住长出发送圆盘和「编辑」「取消」环带，气泡边说边出字，松手按所指的那段发送、放进草稿或取消；规格 `docs/superpowers/specs/2026-11-18-rapp-voice-input-design.md` §5.1、§5.2。
- [ ] 真机验收（Duo 和 iPad 各一遍，条目见该规格 §8）：
  - [ ] 1. 按住说中文：按钮长成圆盘、环带长出、气泡出字、音量条跟声音；松手圆盘缩回，A 收到这句并按设置补回车。
  - [ ] 2. 输入板上翻历史能看到这句话。
  - [ ] 3. 滑到「取消」段：亮起、轻震、「松手 取消」，松手 A 什么都没收到；滑回圆盘变回「松手 发送」。
  - [ ] 3b. 滑到「编辑」段松手：输入板打开，草稿末尾是这句话，A 什么都没收到。
  - [ ] 4. 按住不说话就松手：显示「没听清」，什么都没发。
  - [ ] 5. 首次按下弹两个授权框；设置里关掉麦克风后再按，显示「需要麦克风和语音识别权限」和「去设置」。
  - [ ] 6. 「输入」拖到左边整组吸左；杀掉 App 再开仍在左边；轻点「输入」仍能打开输入板。
  - [ ] 7. 软键盘弹出时按钮组让开；文本终端按键行出现时，按钮组在按键行上方。
  - [ ] 8. 断 Wi-Fi 让会话冻结，按住说话再松手：提示内容未发送，文字在输入板草稿里。
  - [ ] 9. 深浅主题下三个按钮、圆盘、环带、气泡与舞台其它控件一致，没有发光和阴影。
  - [ ] 10. 按钮组在左边时圆盘、环带、气泡全部镜像，「编辑」仍是靠屏幕边、偏上的那段。
  - [ ] 11. 打开「减少动态效果」：按下和松手没有变形动画，直接出现和消失。
  - [ ] 12. 按住时以及在圆盘和环带之间滑动时能感到轻震（录音中允许触感）。
  - [ ] 13. iOS 26：后台放音乐时快速轻点语音按钮，音乐不被打断。
  - [ ] 14. iOS 26：按下到圆盘出现的延迟；超过约 300 ms 再考虑按下即显示等待态。
- [ ] 按住说话后续（终审留下的小项）：
  - [ ] 语音发出后若 A 端失败，输入板关着时用户看不到，考虑给提示。
  - [ ] 按住时连上 AirPods 会没声：监听 `AVAudioEngineConfigurationChange` 重接输入。
  - [ ] 极快轻点时真正的「需要麦克风和语音识别权限」或「正在准备语音识别」被一并静默，可放行这两种回复。
  - [ ] 松手等结果的 1 秒内再按被静默忽略，考虑轻提示。
  - [ ] 提前松手时遮罩和气泡透明度跳变；松手后「输入」「还原」等动画结束才淡入。
  - [ ] 语音按钮对 VoiceOver 没有动作；`voice_overlay.dart` 拆出气泡和音量条（现约 530 行）。

## 0.14.7 发布（2026-11-18，捏合缩放 + 协议 v14 + 剪贴板崩溃修复）

- [x] 合入 `feat/pinch-zoom`（73f9a77，协议 v13→v14、`setView` type 41、A 端按取景截局部、「还原」按钮、文本终端同手势）与 `fix/pasteboard-main`（103ca0d，`NSPasteboard` 只在主线程访问，修 0.14.5 的 abort）。另一台设备的 Linux 0.14.6 改了同一个 `rust/host-linux/src/wire.rs`，git 自动合并未报冲突，已逐条确认空标识握手、type 41 分支与三个新测试都在；`tasks/todo.md` 冲突保留两段。
- [x] 合并后全套门禁：analyze 干净、Flutter 2150 通过 / 23 跳过、Swift 493 通过 / 1 跳过 / 0 失败、Rust 1171 通过（唯一失败为 `pty::local` 绑真端口的已知 load flake，隔离 3/3 通过）、clippy `-D warnings` 退出 0、`scripts/check.sh` 退出 0。
- [x] [v0.14.7 Release](https://github.com/wizlijun/rapp/releases/tag/v0.14.7) 已公开并设为 Latest，pkg / zip / latest.json 三个资产的 GitHub 大小与 sha256 均与本地一致；网站备用快照刷新至 44 个 release（macOS → 0.14.7，Linux → 0.14.6）。
- [x] Linux 协议 v14 安装包已随 0.14.8 发布，可与 0.14.7+ 客户端连接。
- [ ] 网站未部署：`npx --yes wrangler@4.135.0 deploy --config website/wrangler.jsonc` 仍需 `CLOUDFLARE_API_TOKEN` 或交互登录（累计 14 版快照已提交未部署）。

## Linux host 卡顿与连接监控后台运行（2026-11-18，本机验证）

- [x] 用户反馈本地桌面和远程端同时卡顿。Wayland 采集改为复用 RAM-backed shm buffer，遵守 compositor release 后再复用；融合缩放与像素转换，避免逐帧完整 4K 中间图像和重复页分配。
- [x] 采集/编码移入独立线程，输入与 ping 不再等待采集；最多一个任务和一帧确认在途，按工作耗时保留桌面处理时间，静态画面退避，实际输入唤醒。接管、模式/密度切换使用独立 epoch 重建全帧参考。
- [x] Linux service 自动启动连接管理时传入 `--cm --background`；原生入口不创建窗口或 Flutter engine，也不抢焦点；显式 `rapp --cm` 仍可查看连接。
- [x] host 10 项单元测试与 Clippy 通过；隔离 Xvfb、headless labwc 和本机 Omarchy 通过原生串流、输入、Unicode、接管、画质切换、踢出和 EOF。首次与编译并行时 labwc Unicode 事件检查失败，停止编译后原样复验通过，未弱化断言。四组件联调用不含 host 的独立二进制目录验证；完整 bundle 通过 hub → QUIC service → host 桌面串流。
- [x] 新增只读 `scripts/benchmark-linux-host.py`。本机 3840×2400 / scale 3，15 fps、density 2，各采样 10 秒：host CPU 55.9% → 23.1%，Hyprland CPU 26.7% → 7.3%，ping P95 108.82 ms → 4.02 ms。画面内容可能变化，ping 衡量控制通路，不等于端到端画面延迟或用户实机验收。日志 `.build-logs/host-perf-{before,after}-nodelay.json`。
- [x] 原生窗口回归发现并修复手动 CM 关闭/重开时的 SIGSEGV：栈位于 GDK 绘制末尾，日志出现 EGL context 失效；共享进程内改为隐藏/复用 CM，独立 CM 关闭则退出。实际 Omarchy 窗口回归覆盖自动后台不抢焦点、显式 CM、反复关闭/重开、CM-first 和独立退出，全部通过；CM 定时器 5 项测试和 Flutter analyze 通过。
- [x] 本机验证包 `0.14.6-2` 从干净 worktree 构建，源码 `b46086e8a4b95c94352aaf0738974fa4ad4f7fb6`；Arch/便携包 33 文件摘要一致、13 个 ELF 依赖解析通过。解包后完整串流与原生 GUI 回归通过；系统认证后安装成功，33 个已安装文件与验证包一致。服务已重启，IPC 确认桌面能力；原先主 GUI 未运行，因此未主动弹出主窗口。产物在 `dist/linux-0146-local-responsive/`。
- [x] 用户随后提供崩溃交接报告，并于本轮明确要求：解决后提交代码、发布新版本并安装；按新授权推进最终回归和发布。

## Linux GUI 崩溃修复与 0.14.8（2026-11-18）

- [x] 读取 `/home/bruce/Work/rapp-crash-2026-11-18.md`，对照 core 228221 和实际引擎提交：GTK 绘制末尾空 GL context 的证据成立。已安装引擎 `89c39edf...` 的 `fl_view_renderer_draw` 仍清空当前 context；Flutter 3.50.0 的源码包含上游 #192137 的保留 context 修复。独立 SDK 路径 `~/development/flutter-rapp-3.50.0`，原 SDK 保持原状。
- [x] 加强压力测试后，0.14.6-2 于 PID 237036 再次崩溃：栈为 `wl_proxy_get_version → GDK make-current → gdk_cairo_draw_from_gl`，与先前空 context 栈不同。主窗口隐藏改为 GTK idle 回调，避免 Flutter 同步等帧期间处理平台消息时直接取消 Wayland 窗口映射。CM 的隐藏/复用和自动后台入口继续保留。
- [x] Linux 构建要求稳定版 Flutter >= 3.50.0，拒绝旧版或预发布引擎；包内增加 `FLUTTER-INFO.json`，BUILD-INFO 记录实际引擎摘要。构建路径与版本拒绝夹具通过。
- [x] 拉取并整合上游 main `5b7bf7a` / 0.14.7（含发布快照记录）（含 macOS NSPasteboard 主线程修复与协议 v14）。本次版本计划 0.14.8；对端需支持 v14，旧 v13 client 需更新。Linux 继续整桌面采集，兼容 v14 setView 消息但不声称实现局部截取。
- [x] 合并后 host/client-core 78 项测试通过，host Clippy 通过；隔离 Xvfb/labwc 原生输入与串流通过。首次当前桌面采集超时，随后同测试原样复验通过，安装版只读串流采样亦通过；未放宽断言。
- [x] Flutter 3.50.0 全量回归 2158 项通过、15 项既有跳过；analyze 无 error/warning，113 项 Flutter material 导入弃用 info，`--no-fatal-infos` 通过。Linux GUI 和全部 7 个 Rust worker 构建成功。
- [x] 真实桌面解锁后，最终解包 GUI 通过 20 轮关闭/重开、缩放、最大化及主窗口/CM 独立生命周期回归；自动 CM 不映射窗口、不抢焦点，无 EGL make-current 或 implicit-view removal 错误。最终包也通过本机 Omarchy 的 hub → QUIC service → host 完整串流。日志 `.build-logs/gui-0148-final-stress.log`、`.build-logs/bundle-0148-final-current.log`。
- [x] 干净 worktree 从 `a7c482d` 构建 0.14.8-1；Arch/便携包 34 文件摘要一致、13 个 ELF 依赖解析通过，Flutter 3.50.0 / engine `371f77202a73e8dff57a8b3bff75bca55c090aee` 与实际引擎 SHA256 匹配。解包后隔离 headless Wayland 完整 hub → QUIC service → host 桌面串流通过；四组件终端/端口/重启联调通过。
- [x] [v0.14.8 Release](https://github.com/wizlijun/rapp/releases/tag/v0.14.8) 已公开，三个附件大小/SHA256 与本地一致；latest=false 保留 macOS 0.14.7 的 latest.json 及原附件摘要。刷新网站备用下载快照，未部署网站。
- [x] 本机已安装 `rapp-omarchy 0.14.8-1`；系统认证完成后重启 `rapp-service.service`，确认运行 `/opt/rapp/rapp-service`，34 个安装文件摘要与发布包一致，IPC 桌面/图形/终端/端口能力正常。

## iOS 断开后连不上中继、重连全失败（2026-11-18，用户报告，diag/ios-net-errors）
现象：断开后显示「连不上中继，通了自动重连」，自动和手动重连都失败，结束会话重启 app 才好。Duo hub.log：11-18 06:41、06:53、07:20 三次 `rebind`（net_changed 换新 UDP socket）之后，局域网和中继的每次拨号都 `timed out`，直到 `hub_start`；重启后同一网络立刻全通。日志里没有 `endpoint stopping`，所以 quinn 的 endpoint 驱动还活着，是新 socket 发不出或收不到。quinn-udp 吞掉发送错误，hub 看不到原因；之后只有再次回前台或本机 IPv4 变了才会再换 socket，手动「重连」不换。用户选「先只加诊断，确认原因再修」。
- [x] 诊断：quinn/quinn-udp 的 warn/error（`sendmsg error`、驱动 `I/O error`）以 `{"ev":"lib"}` 写进 hub.log；`relay dial:` 失败从 debug 提到 warn。
- [x] Duo 又坏了一次（11-18 07:54）：`lib` 行是 `sendmsg error: Os { code: 32, kind: BrokenPipe }`。iOS 收回了后台 app 的 socket，07:54:57 回前台换了新 socket，之后照样全部 `timed out`，新 socket 上没有任何发送错误。
- [x] 根因（fix/quinn-recv-spin）：quinn 的 tokio socket 在 `poll_recv` 里用 `if let Ok(..) = try_io(..)` 吞掉收包错误，然后立刻重试。被收回的 socket 一直可读，recvmsg 每次都失败，endpoint 驱动就在它上面死循环（rebind 之后它是 `prev_socket`，每轮先收它），再也读不到新 socket，所以只有重启 app 才好。修法：`rapp_net::udp::Runtime` 换上自己的 socket，收包失败后清掉可读状态，等系统下次报可读再试，并以 `recvmsg error` 写进 hub.log。测试 `net/tests/recv_error.rs` 用一个有连接排队的 TCP 监听 socket 模拟（一直可读、recvmsg 一直 ENOTCONN），先红后绿。
- [ ] 实机：Duo 切后台几分钟再回来，不用重启 app 就能自动连上；hub.log 里有 `recvmsg error` 行也没关系。
- [ ] 以后可以做：rapp-service（`service/src/lib.rs`）和 relay 仍用 quinn 自带的 socket。macOS/Linux 上没见过这种情况，暂时不换。
- [x] ~~另一个风险~~：quinn 的 tokio socket 根本不会把收包错误交给驱动（见上面的根因），驱动也就不会因此停掉；之前的实验走的是别的路径。原文：收包出错会让 quinn 的 endpoint 驱动永久停掉，`Endpoint::rebind` 救不回来，之后拨号立刻报 `endpoint stopping`。真要防只能重建 endpoint。
## 重连时 A 报「first message must be hello」（2026-11-18，用户报告，fix/hello-first）
现象：Duo 回前台换端口（rebind）后自动重连，局域网会话一连上就断（hub.log `opened` → `closed: connection closed`，0 秒），要点很多次才进得去；A 端报 `first message must be hello, fetch or put`。原因：`RappSession.Connection` 等 TCP `.ready` 才发 hello，而在此之前调用的 `send`（重连时马上补发的 `set_view`/`set_stream` 等）先进了 NWConnection 的发送队列，排到 hello 前面。0.14.7 捏合缩放加了 `set_view` 之后才常见。
- [x] hello 在 `start()` 里随连接启动立刻排队，之后的消息都在它后面；测试 `ConnectionHelloFirstTests`（先红后绿）。
- [ ] 实机：Duo 放大一个窗口后切到后台再回来，重连一次就进得去，A 不再报这个错。

## macOS 按住说话（真机）
规格：`docs/superpowers/specs/2026-11-18-rapp-macos-voice-design.md` §9。
- [ ] 1. 鼠标按住「按住说话」说一句中文：气泡里边说边出字，音量条在动。松开后 A 上的程序收到这句话，并按设置补了回车。上翻输入历史能看到这句话。
- [ ] 2. 按住后把指针拖到「取消」上：目标亮起，提示变成「松手 取消」，松开后 A 什么都没收到。拖回别处，提示又变回「松手 发送」。
- [ ] 3. 拖到「编辑」上松开：输入板打开，草稿末尾是这句话，A 什么都没收到。
- [ ] 4. 舞台有焦点时长按右 Option 说话，松开后发送成功。说话过程中 A 上没有任何 Option 按下的效果（例如菜单栏没有出现 Option 状态）。
- [ ] 5. 长按右 Option 说话时按 Esc：气泡消失，什么都没发；再松开 Option，A 也没收到任何键。按 Tab：输入板打开，字在草稿里。
- [ ] 6. 在 A 上用右 Option 打组合键：⌥← 按词移动、⌥ 加字母打特殊字符，都和以前一样。轻点一下右 Option，A 能收到这次按键。
- [ ] 7. 在设置里把快捷键改成 ⌃⌥Space：按住说话，松开发送。改成「关」以后，长按右 Option 没有反应，鼠标按钮仍然能用。重启 App 后设置还在。
- [ ] 8. 第一次使用时弹出麦克风和语音识别的授权框，而且是用 Developer ID 签名的安装包测。在系统设置里关掉麦克风后再按，显示提示和「去设置」，点「去设置」打开麦克风那一页。
- [ ] 9. 断开网络让会话冻结，按住说话再松开：提示内容没发出去，字在输入板草稿里。
- [ ] 10. 说话过程中用 ⌘Tab 切到别的 App：录音取消，什么都没发，回来以后 A 上也没有卡住的 Option。
- [ ] 11. 深色和浅色主题下，按钮、气泡和目标都和舞台上其它控件一致。
- [ ] 12. iOS 版（Duo）按住说话照常可用（检查共用 Swift 文件后没有回归）。
- [ ] 13. 在文字终端里（例如跑着 Claude Code）：鼠标按住说话和长按右 Option 都能发送；轻点右 Option、⌥ 组合键和以前一样。
- [ ] 14. 长按右 Option 不到 0.3 秒就在画面上 ⌥点击：A 收到的是带 Option 的点击。说话过程中点画面：录音取消，点击照常生效。
- [ ] 15. 用鼠标说完一句发出去以后，不点画面直接打字，字能到 A。
- [ ] 16. 系统首选语言第一项是简体中文时，说中文能识别；第一次用完弹出一次「识别语言跟随系统…」，第二次不再弹。Mac 上点「去设置」打开「语言与地区」。
- [ ] 17. 在系统里把 English 排到首选语言第一项，回到 rapp 后：Mac 上说英文能识别；Duo 上列表里还有中文时说中文能识别，把中文从列表里删掉后说英文能识别。
- [ ] 18. 某种语言第一次用、资源还没下载时，提示「正在准备语音识别」，下载完后再按就能识别。
- [ ] 19. 按住右 Option 说话时，用鼠标在侧栏点「关」（或「恢复默认」、录新快捷键），松开后打字：字照常送到 A，键盘不会一直被吞（这一条的原生部分没有自动化测试）。
- [ ] 20. 窄窗口（约 420 px 宽）第一次发送后：语言提示换行显示，「去设置」看得见、点得到。
## iOS 语音按钮单手位置 + 输入板打开时保留（fix/ios-voice-panel-open，真机）

- [ ] 1. 单手握 Duo，大拇指不用伸到角上就能按住语音按钮；竖屏时「输入」在它靠中间一侧横排，横屏时在它正上方，都够得着。拖到左边后一样。数字（离边 80、离底 88）需要的话在真机上再调。
- [ ] 1b. 竖屏有上传/下载进度时：进度条在按钮行上方，不挡按钮；转成横屏后按钮变回竖排。
- [ ] 1c. 语音、输入、还原三个按钮一样大（56）、方的，角和 Mac 那排按钮一样；按住语音时圆盘从方按钮平滑长成圆；平时 30% 透明，能看清后面的画面又找得到按钮；手指按上去立刻变实，松开后回到 30% 透明。Mac 和 Linux 上那排还原、输入、按住说话也是平时 30% 透明，鼠标移上去或按下时变实。深色、浅色、AVATAR 主题下都看得清。
- [ ] 1d. 实时字幕跟得上：iPhone 和 Mac 上按住说一句话，每个字在说完那一刻就出现在气泡里，不再明显滞后；早出的字偶尔被后面的结果改正属正常，松手后发出的是改正后的整句。
- [ ] 2. 打开输入板：语音按钮还在，在输入板外右上方（整组在左时在左上方），不压在输入板上；弹出键盘、拖动输入板时跟着走。
- [ ] 3. 输入板开着、键盘弹出时按住说话再松手：A 收到这句，输入板还开着，草稿没变，键盘没收起。
- [ ] 4. 文字终端里打开输入板（按键行在输入板上方时）：语音按钮在按键行上方，不挡按键。
- [ ] 5. 键盘弹出、输入板关着时：整组在键盘上方，不被键盘挡住；终端按键行开着时在按键行上方。

## iOS 内置输入法 实机检查（分支 feat/ios-rime，规格 `docs/superpowers/specs/2026-11-20-rapp-ios-rime-ime-design.md` §7，Duo 和 iPad 各一遍，接实体键盘）

- [ ] 1. 系统输入源是「简体拼音」和「英文」时，内置输入法都没有系统候选条插手。
- [ ] 2. 雾凇加载后，引擎带来的内存。用 `phys_footprint` 量，在 Flutter 已经稳定之后量。参考线 100 MB。
- [ ] 3. 真机首次部署雾凇的用时（决定 §6.6 要不要预编译）。
- [ ] 4. 拔掉实体键盘，用软键盘打字，和现在一样。
- [ ] 5. 「内」开着时听写可用。
- [ ] 6. 打字中途点小按钮切到「系」再切回来，两边都对。
- [ ] 7. 输入板关着时按一个字母（type-to-compose），面板打开后，这个字母进了 Rime 的组字，而不是以英文上屏。冷启动 app、接入会话后的**第一次**也要这样（引擎在启动时就加载，不等输入板拿到焦点）。
- [ ] 8. 按住退格、按住字母会连发；快打一句长句，不丢键。
- [ ] 9. 全局开关关着时，输入板和现在一模一样。
- [ ] 10. 用户自己的 Rime 目录放进「文件」app，选「我的目录」后能用。
- [ ] 11. 组字时按住语音说一句话，或者关掉输入板：组字按原文上屏，语音结果接在后面，什么都不丢。
- [ ] 12. 误按 Shift 后，候选行的「中 / 英」标记跟着变。
- [ ] 13. 输入板关着，在会话画面上**快速**打 `n i 空格 1`：输入板打开后显示「你1」（不是「1」，也不是「1你」）。
- [ ] 14. 输入板里有「abc」，关上输入板，在会话画面上**快速**打 `n i 空格 ⌫`：输入板里是「abc」。
- [ ] 15. 输入板里先有「abc」，切到「英」，关上输入板，在会话画面上**快速**打 `h i ⌫`：输入板打开后是「abch」。
- [ ] 16. Task 0 的数字记进规格 §6.6：冷启动部署毫秒数、内存增量（`phys_footprint`）、系统重复和自带重复各是几次。
- [ ] 17. 雾凇里打出繁体或用简繁切换（若方案带有），字形正确（OpenCC 表换成了 librime 1.16.1 正式版的）。
- [ ] 18. 按住 Shift 点一下画面或按一个不出字的键再松开，候选行的「中 / 英」不变；接着按住自带连发的键时再按别的键，连发立即停。
- [ ] 19. 会话设置里关掉「接实体键盘时用内置输入法」后，这个会话走系统输入法、别的会话不受影响。
- [ ] 20. 「内 / 系」改的是当前会话，重开 app 后记得。
- [ ] 21. 全局设置里的词库 / 重新部署 / 状态 能用。

## Linux 0.14.11 功能对齐（2026-11-18）

- [x] `git pull --ff-only` 更新 main 至 `b2a14c4` / 0.14.11（Flutter `0.14.11+50`，应用协议 v14）。与 Linux 0.14.8 发布基线比较，本轮共享代码已包含统一 40px 桌面控件、设备列版本号、输入板追加与草稿修复，以及 QUIC 收包错误后的驱动恢复和网络诊断日志。
- [x] 检查 Linux `rapp-session`：hello 在启动 stdin 写线程前同步发出，不存在 Swift 旧实现的握手消息乱序。iOS 语音与单手按钮按原规格仅用于 iOS；Linux host 仍整桌面采集，接收 v14 setView 但不实现局部截取。
- [x] 独立 GTK 对端夹具从 v13 更新到 v14，保留独立协议常量校验，私有 Broadway 的 7 组场景通过；修正中英文 README 的协议说明和过期验证入口。服务单实例测试原先在 token 改写后立即发 SIGTERM，可能早于退出信号处理器注册；改为等待处理器就绪，保留退出码 0 的断言，正式包并发启动/跨目录互斥/崩溃恢复/正常退出复验通过。
- [x] 构建路径、旧 Flutter 引擎拒绝、启动器参数保真，以及 GTK3 私有 Broadway 原生窗口/弹窗/共享草稿/输入法 FIFO 回归通过。
- [x] Flutter 全量 2314 项通过、15 项跳过；analyze 无 error/warning，120 项现有 SDK 弃用 info（`--no-fatal-infos` 通过）。Rust 单元/集成共 1188 项通过、11 项显式跳过：workspace 首轮在 forward 目标结束时停止，随后补跑剩余 testkit 目标及 update/wire。首次 one-RTT 用例在编译和其他测试并行时收到 `stream reset by peer`，停下负载后原样单独复验通过，channel 串行/并行中位数 54.37 / 55.79 ms，75 ms 门槛不变；不推断单次失败的确定根因。缺少 host 用例受本机 PATH 中已安装的 host 干扰，隔离 PATH 后通过。此次未补跑整个 workspace 的 doctest。
- [x] 独立干净 worktree `/home/bruce/git/rapp-build-01411` 从 `b2a14c4` 构建 0.14.11-1，使用 Flutter 3.50.0。安装包与便携包 34 个文件摘要一致，13 个 ELF 依赖解析通过，源码提交、引擎摘要及 SHA256SUMS 校验通过。文档及测试夹具改动留在主工作区，不影响包内程序代码。
- [x] 正式 worker 的 hub → QUIC service → 当前 Omarchy 桌面只读串流通过；隔离网络命名空间的终端、端口共享、二进制 pipe/half-close、service/hub 重启后终端恢复全部通过。四组件验收使用实际复制的二进制（不能软链接回含 host 的完整包，否则 `current_exe` 回退会启用图形能力）。
- 产物：`dist/linux-0.14.11/rapp-omarchy-0.14.11-1-x86_64.pkg.tar.zst`、`rapp-0.14.11-omarchy-x86_64.tar.gz` 及 `rapp-0.14.11-omarchy-x86_64-SHA256SUMS`。首轮仅生成产物；用户随后明确要求发布并安装。未进行 macOS/iOS 对端及物理桌面输入验收。
- 日志：主工作区 `.build-logs/{flutter-01411-*,rust-01411-*,linux-01411-*}`；构建 worktree `.build-logs/package.log`、`verify-package.log` 及 `verified/file-sha256.json`。原有未跟踪的 `scripts/__pycache__/` 保留。

## Linux 0.14.11 发布与安装（2026-11-18）

- [x] 用户明确要求发布并安装。验证/测试修正提交 `18497f4` 已推送 main；二进制仍对应此前已验证的 `b2a14c4`，两个提交间不含程序实现改动。
- [x] 本机由 `rapp-omarchy 0.14.10-1` 升级至 `0.14.11-1`，系统管理员认证完成。已重启 `rapp-service.service`，进程运行 `/opt/rapp/rapp-service`，34 个安装文件摘要与正式包一致；CLI/host/client 版本 0.14.11、协议 v14，IPC 桌面/图形/终端/端口能力正常。安装前没有存活的主 GUI，未主动弹出主窗口。
- [x] [v0.14.11 Release](https://github.com/wizlijun/rapp/releases/tag/v0.14.11) 已补齐 Linux 安装包、便携包及 SHA256SUMS，三个附件的 GitHub 大小和 SHA256 均与本地一致；原 macOS 资产 ID/大小/摘要保持不变。发布说明修正旧 Linux v13 表述并补充验证与安装步骤，网站备用下载快照更新到两平台 0.14.11，未部署网站。
- 上传受当前代理线路反复 408/停滞影响，通过绑定物理网卡的临时进程代理完成；结束后临时进程及配置已清理，系统路由和全局代理选择未修改。

## Linux 0.14.12 同步与能力边界（2026-11-18）

- [x] `git pull --ff-only` 从 `1df423b` 更新至 `2d7eab9`，含 macOS 按住说话、快捷键、输入板及 iOS 按钮/语言修复。Linux 共享的 Flutter 输入板/按钮布局代码随之同步；Rust 仅 workspace 版本和 lockfile 从 0.14.11 更新为 0.14.12，协议仍为 v14。
- [x] 逐项核对新增语音：`MainState.voice`、桌面语音按钮、设置行和终端 gate 仍按上游规格限于 macOS/iOS；Linux 没有 `rapp/speech` 实现。不能把共享 Dart 状态机的存在称为 Linux 已支持按住说话。本机 Superwhisper CLI 可用但服务未能启动，未修改它的设置、录音或启用云识别。已询问本轮是否扩展 Linux 语音，尚未获得范围选择。
- [x] Flutter 3.50.0 全量 2396 项通过、15 项跳过；analyze 无 error/warning，124 项 SDK 弃用 info（`--no-fatal-infos` 通过）。Rust 实现相较已验证的 0.14.11 未变，本轮以正式 release workers 做集成验收，未重复全量 Rust 单元测试。
- [x] 私有 Broadway GTK4 客户端 7 组 v14 场景、GTK3 原生窗口/弹窗/草稿/输入法 FIFO、启动器、构建路径和旧引擎拒绝检查通过。正式包单实例/崩溃恢复、终端与端口共享/pipe/half-close、重启后终端恢复通过。完整 hub → QUIC service → Omarchy 桌面串流首轮采集超时，构建结束后同一测试原样复验通过；未放宽断言。
- [x] 干净 worktree `/home/bruce/git/rapp-build-01412` 从 `2d7eab9` 构建 0.14.12-1；Arch/便携包 34 文件摘要一致、13 个 ELF 依赖解析通过，BUILD-INFO 源码/Flutter 引擎及 SHA256SUMS 校验通过。产物在 `dist/linux-0.14.12/`，验证日志在主工作区 `.build-logs/*01412*` 及构建 worktree `.build-logs/`。
- [x] [v0.14.12 Release](https://github.com/wizlijun/rapp/releases/tag/v0.14.12) 已补齐 Linux 安装包、便携包和 SHA256SUMS；三个附件大小/SHA256 与本地一致，原 macOS 资产 ID/大小/摘要不变。网站备用下载快照已更新为两平台 0.14.12。
- [ ] 更新并部署 `rapphub.com`：站点构建和 8 项下载选择测试通过；Wrangler 未登录；有限 scope 的浏览器 OAuth 等待超时，已改用设备授权入口等待用户登录。站点部署 dry-run 通过；不能把更新仓库中的备用快照当作网站已部署。
- 本轮尚未新增 Linux 语音后端，未安装新包、未重启已安装服务，也未进行 macOS/iOS 对端及物理桌面输入验收。

## Linux 0.14.13 语音能力对齐（2026-11-18）

- [x] 按用户“能力对齐”要求扩展 Linux 范围，新增本地 `rapp-speech`，复用桌面按钮、发送/编辑/取消、输入历史和热键 gate；应用画面与文字终端均接入，首次下载固定摘要模型，录音仅驻留内存。
- [x] 主窗口失焦/后台、取消、断开、切会话停止录音；采集子进程绑定父进程死亡信号。普通 Alt 组合键保留，密码焦点不启动画面语音快捷键；Linux 提示与快捷键标签不再指向 Apple 设置。
- [x] 最终源码 Flutter 全量 2420 项通过、15 项跳过；包含主窗口失焦/延迟热键取消及 Linux 快捷键补充用例。analyze 无 error/warning，124 项既有 material.dart 弃用 info。Rust 新 worker 2 项单测通过。
- [x] 正式优化 worker 使用官方 base 模型和公开 JFK PCM 完成真实识别；静音返回空文本。假的 parec 验证 stop、cancel、SIGKILL 崩溃后三种采集进程退出；未调用用户麦克风。模型实际下载摘要匹配固定 SHA256。
- [x] 构建路径/旧 SDK 拒绝测试通过；打包新增 worker、libpulse 依赖和上游许可。语音后端的 CPU 目标明确为 SSE4.2，禁用构建机专有指令和 AVX。
- [x] 从干净提交 `98d14b1` 构建 0.14.13-1，37 文件在 Arch/便携包中摘要一致、14 个 ELF 依赖解析通过，源提交和 Flutter 引擎摘要匹配。打包 worker 的真实语音/静音/采集退出、hub → QUIC → 桌面串流、终端/CLI/共享/重启恢复和单服务实例测试通过；main 代码已推送。集成 fixture 使用私有网络 namespace 并启用 lo；终端专用 fixture 使用四个 worker 的独立副本，避免意外发现同目录的桌面 host。
- [x] [v0.14.13](https://github.com/wizlijun/rapp/releases/tag/v0.14.13) 已发布 Linux 安装包、便携包及 SHA256SUMS；GitHub 三个附件大小和摘要与本地一致，匿名下载校验清单也一致。安装包 SHA256：`f9eb380c812bd494625be1efad53d3a2f5269c0b8c2e3eab89cd09f1a6ad1c77`。发布使用 `--latest=false`，核验 GitHub Latest 仍为 v0.14.12，保证 macOS 自动更新清单可用。网站 50 条发布快照和说明已更新，构建/8 项测试通过。
- [ ] Cloudflare 静态部署未完成：两次设备授权均超时，本机无登录凭据，仓库无 Actions secret；最终正式部署命令因缺少 `CLOUDFLARE_API_TOKEN` 失败。线上静态快照仍是 v0.6.0；线上下载模块与仓库一致，配合已公开的发布列表可选中 Linux v0.14.13 / macOS v0.14.12，但不能称为备用静态快照已上线。需用户完成本机 `npx --yes wrangler@4.135.0 login` 后部署 `website/wrangler.jsonc` 并核验。
- 验收边界：未用物理麦克风测试中文/多语言准确率，也未新增 macOS/iOS 真机对端验收；详情见 [Linux 语音规格](../docs/superpowers/specs/2026-11-18-rapp-linux-voice-design.md)。


## Dock 右键菜单（feat/dock-menu）实机检查

- [ ] Dock 上右键 rapp 图标，每台主机只出现一次：先是已打开的（前面有 ●），再是没打开的常用（无圆点）；没有单独的「常用」段
- [ ] ● 和无圆点两种行的应用名大致左对齐（不齐就调空格数）
- [ ] 点一个会话，主窗口切过去
- [ ] 点一个已分离的会话，只提起它自己的独立窗口，主窗口不出来
- [ ] 点一个常用，在对应主机上打开（已开着就切过去）
- [ ] 离线主机的常用置灰，标题带「（离线）」
- [ ] 托盘菜单的分组与 Dock 一致
- [ ] 分离窗口不在 Dock 菜单顶部的系统窗口列表里重复出现（菜单栏「窗口」里也不再有它们）
- [ ] 有远程窗口时，Dock 的「退出」和 Cmd+Q 都先弹确认框；点取消后 rapp 不退出
- [ ] 关机 / 重启 / 注销时不被确认框拦住
- [ ] 确认框开着时再按 Cmd+Q，仍然只有一个确认框
- [ ] 设置里「升级 rapp？」框开着时按 Cmd+Q，不再叠出第二个框
- [ ] Cmd+` 仍能在主窗口和分离窗口之间切换（分离窗口已不在「窗口」菜单里；不通就回头商量）

## Linux 0.15.1 桌面客户端对齐（2026-11-20）

- [x] 对齐 main `4aa638e0`：确认托盘设备分组/常用/分离会话提起、多屏窗口菜单、内存输入历史与终端共享历史已进入 Linux 共享路径。
- [x] 补 Linux Ctrl+V、Shift+Insert 和右键粘贴的应用剪贴板路径，支持文本及附件块；组字中粘贴仍等待提交，不覆盖预编辑内容。
- [x] 修复 GTK 分离窗口组字期间误召回历史、排队发送或执行快捷键；补草稿历史与 Linux 原生通道回写回归。
- [x] Flutter 全量 2506 通过、15 跳过；analyze 无 error/warning。GTK 私有 Broadway、构建/启动器夹具通过；Linux GUI/全部 Rust 组件构建成功，14 个 ELF 依赖解析通过，无图形隔离 bundle 检查通过。
- 产物在 `gui/build/linux/x64/release/bundle/`。本轮未发布或安装；真实 macOS 对端、物理输入法和多屏操作未验收。宿主既有限制及首轮 Wayland 采集超时的环境说明见 [对齐记录](../docs/superpowers/plans/2026-11-20-linux-0151-parity.md)。

## Linux 0.15.2 发布与安装（2026-11-20）

- [x] 用户要求发版并安装后，提交并推送 main `8ded36d2` 与 `v0.15.2` 标签。干净 worktree `rapp-build-0152` 构建，产物在 `dist/linux-0.15.2/`；Arch/便携包 37 个文件一致，14 个 ELF 依赖、源码提交、Flutter 引擎摘要及隔离 bundle 检查通过。
- [x] [v0.15.2 Release](https://github.com/wizlijun/rapp/releases/tag/v0.15.2) 已公开，三个资产大小/SHA256 与本地一致，匿名下载校验清单一致。安装包 SHA256：`4c4d3c02a8ed4dcab60432db4171e28a4b3d690996342d2b10d6d359b0cc134d`。使用 `--latest=false`；macOS Latest 仍为 v0.15.1，三个 macOS 附件 ID/大小/摘要均未改变。
- [x] 网站 56 条发布快照已推送（`d015091a`），构建及 8 项测试通过。线上 `releases.mjs` 与源码一致，用匿名 GitHub API 验证选中 Linux 0.15.2 / macOS 0.15.1。
- [ ] 网站备用静态快照部署待 Cloudflare 授权：本机无登录凭据或 API token，正式 deploy 命令被拒绝；已发起设备授权。
- [x] 随后管理员认证完成；下一轮核验本机已安装 0.15.2-1，67 个包文件无改动。服务当时仍是旧进程，GUI 已停止，服务重启纳入后续 0.15.4 安装流程。

## Linux 0.15.4 对齐 macOS 0.15.3 与发布（2026-11-20）

- [x] `git pull --ff-only` 更新至 `b248fc66`，同步单行输入历史、⋮ / 右键菜单、悬停全文和紧凑范围按钮；补 Linux 平台回归。
- [x] 修复 320px 历史面板中多行草稿的 46px 溢出：时间列宽度不超过整行三分之一。Linux / macOS 菜单回填与全文复制回归通过，完整 Flutter 2518 通过、15 跳过；analyze 无 error/warning，GTK 原生回归通过。
- [x] 源码 `98ab8551` 与 `v0.15.4` 标签已推送。干净 worktree `rapp-build-0154` 构建，产物在 `dist/linux-0.15.4/`；Arch/便携包 37 个文件一致、14 个 ELF 依赖、源码/引擎摘要及隔离 bundle 检查通过。
- [x] [v0.15.4 Release](https://github.com/wizlijun/rapp/releases/tag/v0.15.4) 已公开，三个资产大小/SHA256 与本地一致，匿名下载校验清单一致。安装包 SHA256：`2e4f3fee9041564d9d85deb0079d0d0a8f061ed74d7085ad2a4efee50314030a`。macOS Latest 保持 v0.15.3，macOS 三个附件 ID/大小/摘要未变。
- [x] 网站 58 条发布快照已推送（`1e778e01`），构建及 8 项测试通过；线上下载模块与源码一致，匿名 API 验证选中 Linux 0.15.4 / macOS 0.15.3。备用静态快照部署仍缺 Cloudflare 登录凭据。
- [ ] 已发起 0.15.4 系统安装，等待本机管理员认证。临时用户服务 `rapp-finish-install-0154` 将在包安装完成后校验 37 个文件、运行 `pacman -Qkk` 并重启后台服务；结果写入 `.build-logs/linux-0154-install-result.json`。未获得成功结果前不声称安装完成。
- 对齐范围与设备验收边界见 [记录](../docs/superpowers/plans/2026-11-20-linux-0154-parity.md)。

## 长语音先让 AI 整理（feat/llm-endpoint，2026-11-20）实机检查

规格：`docs/superpowers/specs/2026-11-20-rapp-voice-ai-tidy-design.md`。需在 全局设置 填好 LLM 接入点（localhost:28001）。

- [ ] 1. macOS 按住说话超过 10 个字，松手后说话的气泡不消失、也不弹新窗口，原地变成「AI 整理中…」；AI 的字从前往后逐个替换原话（没替换到的部分颜色淡一些）；整理完显示「整理好了，马上发送」和一条缩短的进度条，约 1.5 秒后发出，气泡消失。（2026-11-20 改：原来是另弹卡片、整理完立刻发）
- [ ] 2. 整理中点「直接发送」：原话立刻发出，之后 AI 结果不再发。整理好、等发送的 1.5 秒里点「编辑」：写作面板打开，里面是 AI 文字，不发送；点「发送」：立刻发出 AI 文字。
- [ ] 3. 停掉网关（或填错 key）：卡片显示「AI 整理失败」和原因，不自动发；点「直接发送」或「编辑」都可用。
- [ ] 4. 松手时选「编辑」：整理完写作面板打开，里面是 AI 文字；卡片上「编辑」是主按钮；面板打开后直接能打字（不用再点一下）。
- [ ] 5. iOS：松手后圆盘和两条带子照常收回，说话的气泡（带小尾巴）留在原处变成整理气泡，不跳位置；写作面板开着时卡片在面板上方的语音按钮上面；舞台其他按钮照常能点。
- [ ] 6. 输入历史里这条记录带「AI」标记；⋮ 菜单里「原话放进输入框」「复制原话」拿到的是原话。
- [ ] 7. 整理中断网重连：重连后结果仍发到新会话（或失败卡片仍在），不丢原话。
- [ ] 8. 整理中关掉这个窗口（写作面板开着、里面有字）：输入历史的草稿记录里既有面板里的字，也有原话。
- [ ] 9. 整理中切到别的窗口：整理完发到原来那个窗口；顶栏提示「<应用>：已用 AI 整理并发出」。
- [ ] 10. 整理好、等发送时又按住说话：上一段 AI 文字先发出，再开始听新的一段。
- [ ] 11. 短语音（10 个字以内）照旧：松手气泡上飘消失、直接发送，没有整理气泡。

## 整理提速（feat/tidy-faster，2026-11-21）实机检查

规格：`docs/superpowers/specs/2026-11-20-rapp-voice-ai-tidy-design.md` §9。热词要等 rapp-llm 的 feat/hotwords 合并、网关重启以后才有。

- [ ] 1. 长语音松手后，AI 的字是一个一个冒出来的，不是一下子全出来；整理好的文字放完后约 1.5 秒发出。
- [ ] 2. 「AI 整理时先思考」默认关；打开后整理明显慢一点，关掉恢复。
- [ ] 3. 说一段话，中间停一下（约 1 秒）再说完松手：整理气泡出来后，AI 的字比以前快得多就开始冒（日志里有 `prefetched … ms ahead`）。
- [ ] 4. 一口气说完马上松手：AI 的第一个字比以前早大约 1 秒（日志 `start` 那行带 `prefetched`）。
- [ ] 5. 停顿后又改口、多说了几句：发出去的是整段话整理后的结果，不是停顿前那半句。
- [ ] 6. 热词（macOS 26 / iOS 26）：说「Supabase」「Lovable」「n8n」「note.md」这类词，听写气泡里认得对，和没合并 feat/hotwords 时对比。
- [ ] 7. 热词（旧系统，如 macOS 15）：同上，确认不报错、能认出。
- [ ] 8. 停掉网关：按住说话照常能听写，没有卡住或报错。

## app 端口映射（feat/app-port-maps，2026-11-20）实机检查

规格：`docs/superpowers/specs/2026-11-20-rapp-app-port-maps-design.md`。iOS app 里的 hub 自己开 `localhost:28000–28999`，只有 app 内能连；Mac、Linux 照旧由后台服务开。

- [ ] 1. iOS 全局设置把 LLM 接入点设成 `localhost:28001`，点「测试」能通（Mac 共享着 rapp-llm 网关的端口）。
- [ ] 2. iOS 上长语音（超过 10 个字）能整理，AI 文字发出去。
- [ ] 3. app 切到后台几分钟再回来，马上点「测试」或说一段长语音，仍然能通。
- [ ] 4. 日志页能看到 `ports` 一行，里面有 `{"id","port","local":28001}`；回前台后能看到 `ports_relisten`。
- [ ] 5. 杀掉 app 再开（Mac 先不动）：日志里第一行 `ports` 就带上次的映射（从 `maps.json` 读的），不用等问到。
- [ ] 6. Mac 上的 hub 不开 28000 段（`lsof -iTCP:28001 -sTCP:LISTEN` 只有 rapp-service）。

## 主程序图标 B-Aqua（feat/app-icon-aqua，2026-11-21）实机检查

来源：设计稿 `rapp-black-glass.zip` 里的 B-Aqua（Icon Composer `.icon`）。macOS、iOS 工程都加了 `Runner/AppIcon.icon`，它优先于 `AppIcon.appiconset`：26 以上的系统按液态玻璃规范自己画边框、高光、深色/着色/透明模式；旧系统用 actool 从 `.icon` 生成的兜底图。`AppIcon.appiconset` 的 PNG 也换成了 B-Aqua（macOS 版留白加投影，iOS 版满版不透明），Linux 打包读 `app_icon_256.png`，Windows 用 `app_icon.ico`。

- [ ] 1. macOS 26+：Dock、启动台、访达里是黑色玻璃底、蓝色玻璃板、青色 r，四周留白和别的 app 一样大。
- [ ] 2. macOS 26+ 切到深色 / 着色 / 透明图标风格：图标跟着变，没有白底或缺角。
- [ ] 3. macOS 14/15（如有机器）：显示新图标，不是旧的绿色 r。
- [ ] 4. iPhone / iPad 主屏：新图标，圆角由系统裁，边缘没有多出来的一圈框。
- [ ] 5. 装过旧版本的 Mac：升级后 Dock 里图标刷新（不刷新就 `killall Dock` 再看）。
- [ ] 6. Linux 打包后的桌面图标、Windows 版 exe 图标也是新的（Windows 的那一半等 Windows 版能构建再看，见 Windows 设计）。

## iOS 输入/收起 + 按键区（feat/ios-input-toggle，2026-11-21）
- 实机检查：规格 `docs/superpowers/specs/2026-11-21-rapp-ios-input-toggle-design.md` §7 第 1–22 条，Duo 和 iPad 各一遍
- 以后再做：App 里 ⌃ 锁住时按「复制」发出的是 ⌃⌘C；AI 整理卡片开合时跟着 IosDock 的动画走，不跳；PullDown 和 FloatingComposer 的回弹代码合成一份；在 Caps Lock 下按 ⌥+字母大小写

## Linux 非语音原生能力补齐（2026-11-21，0.15.9）

- [x] 按用户要求同步至 main `b724666c`（含 0.15.8 和随后合并的 iOS 输入按键区），补齐 Linux host 的 v14 取景、剪贴板/typed paste/文件续传、独立应用与窗口操作、焦点/菜单/密码角色、输入源、弱网节流和锁状态；语音相关原生实现未改。
- [x] X11 Composite 与 Hyprland toplevel export/mapping 使用独立表面采集；跨输出窗口坐标及输入经过隔离双显示器回归；Hyprland resize 保持窗口原点，跨显示器移动同步目标 workspace。
- [x] Rust workspace 1215 项、最新 Flutter 2745 项及原生窗口 smoke 通过。更多验证及平台边界见 `docs/superpowers/plans/2026-11-21-linux-nonvoice-parity.md`。
- [x] 干净源码 `2cd87a69` 打包，验证产物及上传摘要；发布 Linux v0.15.9（保留 macOS Latest v0.15.8），网站快照更新并通过 8 项测试。
- [ ] 完成本机管理员认证后重新安装与校验；完成 Cloudflare 登录后部署网站静态更新。

## iOS 常用语条（feat/phrases，2026-11-22）
- 实机检查：规格 `docs/superpowers/specs/2026-11-22-rapp-ios-phrases-design.md` §7 第 1–10 条，Duo 和 iPad 各一遍
- 留意：App 会话里 ⌃⌥⌘ 锁住时，A 端修饰键还按着，常用语的文字和回车会不会被带上修饰键（规则 5 说常用语不受粘滞影响；面板发送也是同一条路，实机看一眼）

## 看不见的会话停画面（feat/offstage-pause，协议 v15，2026-11-22）

规格 `docs/superpowers/specs/2026-11-22-rapp-offstage-pause-design.md`，计划 `docs/superpowers/plans/2026-11-22-rapp-offstage-pause.md`。B 不看的会话 `set_stream` fps 0：A 不发画面，屏幕变了每秒最多一条 `changed`（灯照常亮），窗口表最多 5 秒一次，菜单栏和焦点区留到恢复时一起发；恢复时第一帧是对 B 手上那帧的差分。

- 实机检查：规格 §5 第 1–9 条（A 为 macOS 和 Linux 各一台，B 为 macOS；第 8 条 Linux B，第 9 条 iPad）。
- [ ] 10. 切走一个会话后看它的灯：不应因为切走本身亮「活动」约 10 秒（ScreenCaptureKit 改成 1 fps 时可能补发一帧没变的画面，审查时没法在本机验证）。
- [ ] 11. Linux B：主窗口关到托盘后，从启动器或再运行一次 `rapp` 打开，舞台上的会话照常满帧率。
- [ ] 12. 放大/改密度后马上切回（同一条 `set_stream` 里既恢复又改密度）：帧率回到原来的，不卡在 1 fps。
- Linux：`host-linux` 和 `rapp-session` 在 alpine 容器里 `cargo check` 通过、没有警告；容器里链接不了（缺本机库），Linux 上的 `cargo test -p rapp-host-linux` 和实机留给 Linux 那台机器。


## Linux v15 对齐（2026-11-22，0.15.13）

- [x] 对齐 macOS 0.15.12 / v15；补齐 GTK 主窗口和多分离窗口可见性，以及暂停期间未确认帧的超时/弱网处理。
- [x] Flutter 2773 项、原生窗口、隔离 X11/Wayland 主机测试通过，Clippy 无警告，GUI release 构建成功。平台边界和测试细节见 `docs/superpowers/plans/2026-11-22-linux-v15-parity.md`。
- [x] Rust 工作区 1227 项通过；最终包内容、依赖、隔离 QUIC 主机/服务/端口共享及远端 SHA256 校验通过。已发布 Linux v0.15.13（源码 `a5675f5f`），macOS Latest 保持 v0.15.12；未自动安装。


## Linux 5 分钟语音对齐（2026-11-24，0.15.15）

- [x] 对齐 macOS 0.15.14，修复 Linux 适配层仍以 80 秒终止长录音最终识别的遗漏，等待上限统一为 5 分钟。
- [x] 598 项 Flutter 相关回归、2 项 Rust 语音测试、Clippy 和真实 Whisper 长录音/截断/进程回收验证通过。详见 `docs/superpowers/plans/2026-11-24-linux-01515-parity.md`。
- [x] Linux v0.15.15 已公开发布（源码 `6e327a1e`）。两种包内容、动态依赖、隔离服务/端口共享及三个远端资产的 SHA256 均校验通过；macOS Latest 保持 v0.15.14，未自动安装。

## 语音记住改法 + 按用途整理（feat/voice-learn、feat/voice-mode，2026-11-21）实机检查
- 实机检查：规格 `docs/superpowers/specs/2026-11-21-rapp-voice-learn-design.md` §8 第 1–12 条，macOS 一遍，iOS 上 1、2、7 再做一遍
- [ ] 1–6：虚线词点回原话（停住、不自动发）；记住提示与「语音学到的词」；编辑路改词后记住并在下一次整理里生效；热词 10 分钟内刷新；note.md pending 确认；不记住则文件不变
- [ ] 7–8：微信按「对人」、终端按「提示词」；气泡里点用途切换后重新整理，按应用记住；全局设置「恢复默认」
- [ ] 9–11：网关停掉点「记住」不报错；整段重写不标虚线；密码框会话没有记住提示也没有 learn 请求
- [ ] 12：iOS 上 1、2、7 各做一遍

## 应用名统一为 rApp（feat/name-rApp）

只改看得见的名字；命令 `rapp`、`rapp.app` 文件名（升级/回滚靠它）、`~/rapp` 数据目录和它的 `# rapp 数据目录` 标记、`rapp://`、key 前缀、SNI、bundle id、日志前缀 `rapp:` 都不动。

实机检查：
- [ ] macOS 菜单栏显示 rApp，「关于 / 隐藏 / 退出 rApp」；窗口标题、托盘「显示 rApp」、⌘Q「退出 rApp？」
- [ ] macOS 程序坞和访达里的名字：文件名还是 rapp.app，看系统是否按 CFBundleDisplayName 显示 rApp；仍显示 rapp 的话再决定要不要把包改名（要连升级和回滚一起改）
- [ ] iOS 主屏幕图标下显示 rApp；「文件」里 app 的文件夹显示 rApp，和 Rime 提示里的「文件 → rApp → Rime」一致
- [ ] Linux 窗口标题和启动器名字是 rApp，`scripts/test-linux-single-gui.py` 通过

## PC 端按键区 + 常用语条（feat/pc-key-bar，2026-11-24）

macOS / Linux 改用 iOS 的 `KeyBar` 和常用语条，贴在画面底部；按下实体键盘的非修饰键后快捷区收起，点文本框 ＋ 右边的快捷区开关展开（0.15.21 起；原来是 ⊙）。旧的六颗键（`TermKeyRow`）和「按键排」菜单项已删除。规格：`docs/superpowers/specs/2026-11-24-rapp-pc-key-bar-design.md`。

实机检查：
- [ ] 1 macOS 终端会话：按键区贴底，画面上移；⌃ 粘滞、↑ 长按连发、上滑出 PgUp
- [ ] 2 在终端里打一个字：快捷区收起，开关不亮；点开关展开，再打字又收起（写作框里打字也一样，原生输入框走 `typed` 事件）
- [ ] 3 只按 ⌘ 或 ⌘Tab：按键区不收
- [ ] 4 App 会话：写作框打开时才有按键区；⌘C / ⌘V 能用
- [ ] 5 设置 → 常用语：增、改、删、排序都能用（用鼠标左滑删除是否顺手）
- [ ] 6 Linux 同 1–3
- [ ] 7 已知限制：macOS 的 `port.latch` 什么都不做，所以 App 会话里，按键区上锁住的 ⌃ 按一下实体键后不会自动放开。看实际用起来会不会别扭
- [ ] 8 终端画面上移后，最上面一个按键区高的几行被顶栏挡住（iOS 本来就这样）。看 PC 上能不能接受
- [ ] 9 macOS：写作框关着，直接在 App 画面里打字（键走 SessionPlugin 发给 A，Flutter 收不到）：快捷区也要收起（`key_typed` 事件）
- [ ] 10 按键区上点亮 ⌘（或 ⌃ ⌥ ⇧）后再按实体键：按键区先不收，等修饰键灭了，下一个键才收
- [ ] 11 Linux：按 Ctrl+]、Ctrl+O 这类快捷键时按键区不收；AltGr、NumLock 也不收
- [ ] 12 已知：在设置的常用语页、改名框里打字也会收起按键区（也算用了键盘），看是否别扭

## Linux 语音学习对齐与打包安装（2026-11-24，0.15.16）

- [x] 对齐 main `833d134e` 的共享语音纠错、学习和按用途整理，补齐 Linux 热词到 Whisper 的传递。
- [x] 722 项 Flutter、4 项 Rust 单元测试、Clippy、真实模型 8 项检查通过；analyze 无 error/warning。
- [x] 源码 `0b5672d0` 构建 Arch/便携包，内容、依赖、SHA256 及隔离运行校验通过；产物在 `dist/`。
- [x] 本机已安装 0.15.16-1，40 个文件与包一致，pacman 检查 0 改动；后台服务已重启且运行二进制摘要一致。当前 GUI 退出重开后使用新版。详见 `docs/superpowers/plans/2026-11-24-linux-01516-parity.md`。

## Linux PC 按键区与名称对齐（2026-11-24）

- [x] 补通 Linux `key_event` 和 `latch`，覆盖实体按键的单次/锁定修饰键、重复与释放、失焦清理及写作框路由。
- [x] Linux 共用 PC 按键区、常用语条和自动收起规则；补充与 macOS 同组的布局及键盘回归。
- [x] GTK 独立客户端可见名称与包内说明统一为 rApp；核对新图标已进入 Linux 打包路径。
- [x] 299 项不同 Flutter 用例、10 项 Rust 会话测试通过；GTK 编译检查、Linux release GUI 构建、构建路径回归和 diff 检查通过。
- [ ] 实机确认触屏按住/上滑、实体快捷键及安装后的新图标。代码及 Linux 0.15.18 发布包验证已完成，本机尚未升级。详见 `docs/superpowers/plans/2026-11-24-linux-pc-controls-parity.md`。

- [x] Linux [v0.15.18](https://github.com/wizlijun/rapp/releases/tag/v0.15.18) 已公开发布（源码 `d1ce9a1a`）：Arch/便携包 40 个文件一致、14 个 ELF 依赖解析、隔离 QUIC 主机/服务/端口共享及真实 Whisper 8 项检查通过；三个远端资产 SHA256 校验通过。Latest 保留上传期间另一端发布的 macOS v0.15.19，本机未自动升级。

## 输入块（feat/input-dock，2026-11-24）实机检查

macOS、Linux、Duo、iPad 各一遍。

- [ ] 1 终端会话、终端类 App、普通 App：开合文本区、开合快捷区，远端画面一个像素都不动，顶部始终看得到、点得到。
- [ ] 2 文本区开合时，快捷区的键不挪位置；快捷区开合时，锚点不动，文本区被平滑地推上去或落下来。
- [ ] 3 点快捷区开关收起快捷区，开关不亮；再点展开。文本区开着（开关在 ＋ 右边）和收着（开关在「输入」旁边）都试一遍。
- [ ] 4 PC：「输入」打开后变成「收起」并亮起，再点一下只折叠文本区，草稿还在；抓手旁没有 ×。
- [ ] 5 Esc、＋「收起」、直接回车且隐藏、iOS 往下拉：都只折叠文本区，快捷区留着。
- [ ] 6 普通 App（如 Safari）：
  - 一开始快捷区收起，开关不亮；
  - 点开后快捷区一直留着，开合文本区也不受影响；
  - 按住语音时快捷区不出现、不消失，按键组不动；
  - 松手后可以直接点 ⏎ 或常用语。
  - 终端类和普通 App 的展开、收起各记各的。
- [ ] 7 ＋ 菜单两端一致：没有按键格子；「快捷区」一组里的三个开关和「编辑常用语…」都能用；关掉「打字后自动收起」后，打字不再收起快捷区。
- [ ] 8 PC：往画面里打字时快捷区自动收起；在写作框里打字不收；按着 ⌘、⌘Tab、亮着 ⌃ 时也不收。
- [ ] 9 终端会话：
  - 把块拖到别处后位置记住，新开的文本终端也用这个位置；
  - 快捷区盖住提示符时能拖开。
  - PC 默认位置不压住右下角那排按键。
- [ ] 10 iOS：软键盘弹起时整块站在键盘上，键盘落下后回到原位；iPad 上快捷区和面板一样宽、跟着面板走。
- [ ] 11 旧偏好里 `key_bar_slim` 为 true：升级后终端类会话的快捷区是收起的，开关不亮。
- [ ] 12 AI 整理卡片在块的上方，不压住块，也不跑出舞台。

## 语音本机纠词 L1（feat/voice-fix，2026-11-25，规格 `docs/superpowers/specs/2026-11-24-rapp-voice-local-fix-design.md` §10）实机检查

网关 `GET /v1/vocabulary/rules` 已上线（rapp-llm 672e022），现在下发 2 条：徐逊→徐迅、文萱→玟萱。「拍森 → Python」要先在 rapp 里学一次。macOS、Duo、iPad 各一遍；Linux 跑第 1–7 条（规格 §10 第 16 条）。

- [ ] 1 说「打开拍森」（10 个字以内）：按住时气泡里就是 Python，松手后 A 收到 Python。
- [ ] 2 停掉网关，重启 rapp，再说第 1 条：结果一样。
- [ ] 3 网关停着、整理开着，说一段超过 10 个字、含「拍森」的话：整理失败后，A 收到的是 Python。
- [ ] 4 网关正常，说一段超过 10 个字、含「拍森」的话：
  - 整理气泡里 Python 下有虚线，「原话」行里是「拍森」；
  - 点 Python 切回「拍森」，出现「记住：别把『拍森』改成『Python』？」，点「记住」后下一句不再改；
  - 另说一句，在整理好的气泡上点「还原」：A 收到的是 Python，不是「拍森」。⌘Z 撤回整理也回到 Python。
- [ ] 5 正式词表的规则：说一段含「徐逊」的长句，点虚线的「徐迅」切回：这一次发「徐逊」，提示「这条在正式词表里，要改请去 note.md」，没有「记住」；下一句照样改成「徐迅」。
- [ ] 6 关掉「长语音先让 AI 整理」。说一句识别错的新词，选「编辑」，在写作面板里改对并发出：出现「记住这个改法？」。点「记住」后，下一句（任何长度）直接改对，网关慢的时候也是。
- [ ] 7 关掉整理，说「打开拍森」，选「编辑」，在写作面板里把 Python 改回「拍森」发出：出现「记住：别把『拍森』改成『Python』？」，点「记住」后下一句不再改。
- [ ] 8 密码框会话：说词表里的词，A 收到的是识别器的原样，没有任何提示。
- [ ] 9 输入历史：第 1 条的记录里有 `fix.heard`，第 4 条的记录里 `ai.original` 是识别器原样。
- [ ] 10 说「九个人」之类和某个词表词同音的普通话：没有被改。
- [ ] 11 编辑路学一条单字改法：`rules` 的返回里没有它，本机纠词不改；LLM 整理仍照它改。
- [ ] 12 把一条学到的规则在 note.md 里确认成不带 `(always)` 的正式条目：`rules` 里仍有它，L1 照改。
- [ ] 13 日志里每次语音有 1 行 `voice: first …ms, final …ms, fix N in …ms, out …ms`，只有数字没有文字；fix 耗时不超过 5 毫秒。第二次按住比第一次快（语言、模型、音频格式的查询已缓存）；换识别语言后仍能正常识别。
- [ ] 14 识别模块换成了 `DictationTranscriber` + 热词（探针 17/30 对 4/30，规格 §8）。macOS、Duo、iPad 各说几句带人名和产品名的话（如「明天约徐迅过方案」「用 Windsurf 打开 rapp 的仓库」）：按住时字照常一个个出来，松手后最终文字比以前更常写对；第一次按住不报错，报错时有失败提示，第二次正常。
- [ ] 15 macOS 识别也中文优先：系统首选语言 English 在前、中文在后（如这台 Mac 的 en-GB、zh-Hans-JP），按住说中文能识别成中文；首选语言里没有中文时仍按第一项听。
- 规格 §10 第 15 条（L2）这次没做。

## 快捷区开关（feat/quick-toggle，2026-11-25）实机检查

规格：`docs/superpowers/specs/2026-11-25-rapp-quick-toggle-design.md`。⊙ 键和圆圈小把手已去掉，开关在文本框 ＋ 右边；文本区收起时开关站到「输入」旁边。上面「PC 端按键区」「输入块」两节里的 ⊙ 和小把手已改成开关的说法。

- [ ] 1 macOS：原生编辑器的字从开关右边开始，光标和输入法候选框位置对。（调试版没在本机启动截图：和正在用的 rApp 同一个 bundle id，怕打断在线会话。）
- [ ] 2 Linux：Flutter 编辑器同上。
- [ ] 3 iPhone 竖屏：文本框里三个键之后，字还有舒服的宽度。
- [ ] 4 iPad 和 iPhone：文本区收起时，开关在「输入」旁边，亮不亮对；整列拖到另一边时开关一起过去。
- [ ] 5 在画面里打字会自动收起快捷区，开关的灯随之熄灭。
- [ ] 6 缩放加1、加2：三个键一起变大，不出滚动条。
- [ ] 7 ＋ 菜单从 ＋ 往右开；块拖到左边缘时菜单不跑出舞台。
- 0.15.23 评审修正：
  - [ ] 8 iPhone 上大小调到最大：＋、开关、发送不再跟着变大到挤掉字，打字区至少还有一截能看清的宽度（约 120 px），字本身照样放大。
  - [ ] 9 iPhone 横屏，开「更多按键」和常用语条，文本区收起：语音、开关、「输入」排成一横行，不压住快捷区右边的键。
  - [ ] 10 Linux：在文本框里打字时用鼠标点开关，光标还在文本框里，接着打字不用再点。
  - [ ] 11 VoiceOver：开关只念一次名字（「收起快捷区」或「显示快捷区」）。
  - [ ] 12 文本区收起时，「输入」旁的开关是淡入的，不是一下跳出来；系统开了「减弱动态效果」就直接出现。
  - [ ] 13 iPhone SE 这类 320 宽的屏：＋ 菜单不超出右边。


## Linux 0.15.22 输入块与本机纠词对齐及发布（2026-11-25）

- [x] 对齐 macOS 0.15.21：共享浮动输入块、快捷区开关、按类型保存显隐和 L1 本机纠词；补齐 Linux 中文优先语言选择及语音 timing 事件。
- [x] 共 3081 项 Flutter 用例、14 项 Rust 用例通过；analyze 无 error/warning。发布包 40 个文件一致、14 个 ELF 依赖完整，隔离 QUIC 会话/CLI/端口共享及真实 Whisper 8 项检查通过。
- [x] [Linux v0.15.22](https://github.com/wizlijun/rapp/releases/tag/v0.15.22) 已发布，源码 `6c6992a0`；三个远端资产大小及 SHA256 核对通过。macOS Latest 保持 v0.15.21，既有附件未变。
- [x] 网站下载快照已更新；本轮不部署静态站、不自动安装或重启服务。
- [ ] 实际麦克风中文/多语言效果、物理触屏和 macOS 真机对端验收。详见 `docs/superpowers/plans/2026-11-25-linux-01522-parity.md`。


## Linux 0.15.24 快捷区开关评审修正对齐与发布（2026-11-25）

- [x] 对齐 macOS 0.15.23 的共享修复：快捷区开关保持光标、窄窗口大字号与菜单限宽、开关淡入和无障碍去重。
- [x] 补充 Linux 选区、IME composing 与继续输入、各级缩放不多余滚动，以及三平台窄窗口回归；完整 Flutter 3096 项通过、3 跳过，analyze 无 error/warning。
- [x] [Linux v0.15.24](https://github.com/wizlijun/rapp/releases/tag/v0.15.24) 已发布（源码 `4c992ac0`）。两种包 40 文件一致、14 个 ELF 依赖完整，隔离 QUIC/CLI/端口共享检查通过；三个附件远端大小/SHA256 和匿名校验清单核验通过。
- [x] macOS Latest 保留 v0.15.23；仓库下载快照更新。本轮不安装系统包、不重启服务、不部署静态站。
- [ ] 实际物理输入法、触屏及 macOS 真机对端验收；详见 `docs/superpowers/plans/2026-11-25-linux-01524-parity.md`。

## 快捷区按键重排（feat/key-bar-keys，2026-11-25，已发版 0.15.25）

依据和排法：`docs/superpowers/specs/2026-11-25-rapp-key-bar-keys-research.md`。第一排 `Tab ⇧Tab Esc ⌃C ⌃ ⋯ ↑ ↓ ⌫ ⏎`，第二排 `⌘C ⌘V ⌥ (⌘) ← → ⌃O ⌃R ⌃T ⌃B ⌃L`。上面几节实机检查里写的旧键位（⋯ 在最右、⌫ 和「复制 粘贴」在第二排末尾、⌃D）以这里为准。

- [x] `key_bar_keys_test.dart`、`key_bar_test.dart`、`linux_key_bar_test.dart` 共 82 项通过（云端 Linux 副本，Flutter 3.50.1）。全量 3086 通过、11 跳过、11 失败；这 11 项在没改动的副本上同样失败，是那个环境的问题（以 root 跑所以只读目录写得进去；副本里没有 `rust/`、`Tests/`、原生库和 systemd）。本机还没跑全量。

实机检查：
- [ ] 1 iPhone 竖屏：第一排的字都没被裁（后来改成 11 颗，见下面 ⋯ ⌄ 一节）（重点看 `⇧Tab`）；第二排终端 10 颗、App 会话 11 颗也不裁。
- [ ] 2 Claude Code 权限框：↑ ↓ 选、⏎ 确认、Esc 拒绝；右手拇指够 ↑ ↓ ⌫ ⏎ 顺不顺，⋯ 在中间别不别扭。
- [ ] 3 不开 ⋯：⌫ 能删远端提示符里的字，长按连发。
- [ ] 4 不开 ⋯：点 ⌃ 再在软键盘上打 o / r / t，远端收到 ⌃O / ⌃R / ⌃T，草稿里没多出字母；点 ⌃ 再点 ⌫ 删一个词。
- [ ] 5 第二排：⌘C 复制终端里选中的字，⌘V 把本机剪贴板贴过去；App 会话里 ⌘C 发 ⌘C。
- [ ] 6 第二排：← → 挪远端光标，上滑是 Home / End；⌃L 重画 Claude Code 的画面。
- [ ] 7 VoiceOver：⌘C ⌘V 两颗念「复制」「粘贴」。
- [ ] 8 macOS / Linux：同 2–6。

### 第一排末尾 ⋯ ⌄（分支 `feat/key-bar-fold`，2026-11-25）

用户：「是不是还却一个隐藏键的位置」→「把... 和折叠 放在第一行的末尾」。第一排改成 `Tab ⇧Tab Esc ⌃C ⌃ ↑ ↓ ⌫ ⏎ ⋯ ⌄`（11 颗），⌄ 收起快捷区，框里的开关照留。

- [x] `key_bar_keys_test` / `key_bar_test` / `linux_key_bar_test` 通过；本机全量 3092 通过、16 跳过；`linux_detach_test` 两项在新 worktree 里缺 `rust/target/release/rapp-session` 才失败，借主目录的构建重跑 5 项全过。
- [ ] 9 iPhone 竖屏 11 颗：`⇧Tab` 和 `⌄` 的字不裁，⋯ ⌄ 两颗不容易点错。
- [ ] 10 点 ⌄：快捷区收起，框里的开关变暗；再点开关又出来。⌃ 亮着时点 ⌄ 也收。
- [ ] 11 VoiceOver：⌄ 念「收起快捷区」。

### 总览「打开应用」菜单（分支 `feat/overview-open-apps`，2026-11-25）

用户：「每个设备常用应用的最下面 版本号的右边 右对齐的地方，增加一个打开应用的连接，点开后，以列表的方式显示设备所有的可能的应用」，效果图选 A 下拉菜单。规格 `docs/superpowers/specs/2026-11-25-rapp-overview-open-apps-design.md`。只列正在运行的；本机列不放；空列原来的「打开 app」按钮去掉。

- [x] `overview_test`（40）+ `device_apps_test`（6）通过；整分支评审 6 项重要 + 若干次要已修；全量 3114 通过、16 跳过（`rapp-session` 借主目录构建）；analyze 干净
- [ ] 1 macOS：总览每台远程设备列底部版本号右边是「打开应用 ▾」，本机列没有；离线设备的是灰的、点不开
- [ ] 2 点开：菜单右边和链接对齐，屏幕 / 终端 / 应用（N）三组和设备页同序；已打开的显示「已打开」、灯和会话一致
- [ ] 3 直接打字筛选，↑↓ 选、回车打开、Esc 关；点星改常用，菜单不关，列里的「常用」跟着变
- [ ] 4 窗口拉矮、设备列很长时菜单往上翻，不出窗口；应用多时列表内部滚动，筛选框和底部不动
- [ ] 5 包名框输入 com.apple.TextEdit 回车能打开；「设备详情 ›」跳到设备页那台
- [ ] 6 iPad：点链接不弹软键盘；点一行直接打开；VoiceOver 念「打开应用，<设备名>」
- [ ] 7 Linux：同 1–5
- [ ] 8 菜单开着时拔网线 / 关掉对方：菜单里出现断开原因，点行不打开

## 升级后开机冒出旧版 rApp（2026-11-25，分支 `fix/update-previous-inert`，已发版 0.15.25）

原因：升级把旧版整个挪到 `~/rapp/local/previous/rapp.app` 留作回退。那份仍是登记过的 `.app`，系统按 bundle id 在登录时把它和新版一起打开（总览本机显示 0.15.20、旧的圆形快捷区按钮）。

- [x] 备份改名为 `previous/rapp.backup`（换下时的暂存名 `.rapp-old.backup`），换完用 `lsregister -u` 注销；回退照常从它装回
- [x] 服务启动时把老版本留下的 `previous/rapp.app` 先注销再改名；两份都在时不删任何一份
- [ ] 实机 1：装新版后重启电脑，只起一个 rApp，总览本机是新版本号
- [ ] 实机 2：「回到上一版」仍可用，回退后再升级回来也正常
- [ ] 实机 3：`lsregister -dump | grep previous/` 不再有 rapp
- 注意：回退到 0.15.24 及更早的版本后，那个旧版自己的升级会再留下 `previous/rapp.app`，要等再升到新版、服务启动时才会被改名

## Linux 0.15.26 快捷区按键重排、折叠键与 Omarchy 锁屏对齐发布（2026-11-25）

- [x] 对齐 macOS 0.15.25 快捷区按键重排（第一排 11 颗 `Tab ⇧Tab Esc ⌃C ⌃ ↑ ↓ ⌫ ⏎ ⋯ ⌄`，第二排 `⌘C ⌘V ⌥ (⌘) ← → ⌃O ⌃R ⌃T ⌃B ⌃L`）并随包发布已合入的 Omarchy Quickshell 锁屏密码输入支持（`0853fa0d`）。
- [x] 为 `KeyBar` 增加 `TextFieldTapRegion`，修复 Linux 桌面鼠标点击快捷区（含 `⌄` 与 `⋯`）时写作框失焦的问题，并补充 Linux 键序、语义、`⌃L`、`⌄` 收起释放粘滞 `⌃`、选区/IME 保持与 `evdev` 键码映射回归用例。
- [x] 核验 macOS `previous/rapp.app` 防开机重起修复不适用于 Linux（Linux 通过 pacman / 便携包与单个 systemd 用户服务运行，不启用 `.app` 自更新）；Rust 更新测试与全量 Flutter 3112 项通过（3 跳过），analyze 无 error/warning。
- [x] [Linux v0.15.26](https://github.com/wizlijun/rapp/releases/tag/v0.15.26) 已发布（源码 `ca1805fe`，`--latest=false`）；两包 40 文件一致、14 ELF 依赖完整，隔离命名空间服务/CLI/端口共享验证通过，三个远端附件大小与 SHA256 一致，macOS Latest 保留 `v0.15.25`。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-25-linux-01526-parity.md`。
- [ ] 实机验收：物理输入法、触屏、真实锁屏跨设备解锁及与 macOS 真机对端联调。

## Linux 0.15.28 总览「打开应用」下拉菜单对齐与发布（2026-11-25）

- [x] 对齐 macOS 0.15.27 总览设备列底部「打开应用 ▾」下拉菜单（共享 Dart 实现，Linux 桌面复用行高 32、自动聚焦筛选、悬停提示、键盘导航与能力感知分组）；补充 Linux 桌面与仅桌面宿主（`applications: false`）回归用例。
- [x] Flutter 全量 3134 项通过（3 跳过），analyze 无 error/warning；Rust 套件与构建脚本测试通过。
- [x] [Linux v0.15.28](https://github.com/wizlijun/rapp/releases/tag/v0.15.28) 已发布（源码 `cc9583a6`，`--latest=false`）；两包 40 文件一致、14 ELF 依赖完整，隔离网络命名空间服务/CLI/端口共享测试通过；三个远端附件 SHA256 与匿名校验清单一致，macOS Latest 保留 `v0.15.27`。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-25-linux-01528-parity.md`。
- [ ] 实机验收：Linux / Omarchy 下连接远端设备的总览「打开应用」菜单交互与中文输入法筛选。

## 程序状态 S1（分支 `feat/program-status-s1`，2026-11-25）实机检查

规格 `docs/superpowers/specs/2026-11-25-rapp-program-status-design.md` §8、§9；计划 `docs/superpowers/plans/2026-11-25-rapp-program-status-s1.md`。S2–S4 待写计划。

- [ ] 1 `rapp-term run -- claude`：Claude Code 开始报状态；会话列表里看得到“在干活”
- [ ] 2 让 Claude Code 跑一条要确认的命令：不点开会话，设备页那一行是“等确认 · approve Bash: …”，“需要你”多一条，点“打开”进到会话；看过以后不清，回了才清
- [ ] 3 同时开三个会话各跑一个 CLI：不点开就看得出哪个在等确认；Agent 安静思考时不亮未读
- [ ] 4 Codex：等确认时是“等确认”（没有 `msg`）
- [ ] 5 agy（P0 第 1、2 条）：答了探测以后报不报、结尾是什么、`msg` 里是什么
- [ ] 6 外层是 iTerm2 ≥ 3.7.5 或 kitty ≥ 0.50.0 时，程序收到两次探测回答有没有副作用（P0 第 3 条）
- [ ] 7 Claude Code 的 `done` 和 `idle` 各在什么时候出现，回合结束是否正好亮一次未读（P0 第 5 条）
- [ ] 8 `term.json` 写 `{"programStatus": false}` 后新开的会话：和现在完全一样，没有状态
- [ ] 9 错误色没做，`error` 只靠“出错 · …”的字（Task 6）
- [ ] 10 真伪终端加真窗口：程序先读到 7501 的回答，再读到窗口对设备属性查询的回答（目前只有单元测试，没有在真窗口里验过）
- [x] 11 遗留小项：已打开终端卡片的“等待”灯不看设备是否离线——在 `feat/overview-term-status` 修了（`_termPs` 查 `_offlineSince`）；~1062 的缩进没动

## 状态队列、需要你直达、总览程序状态（分支 `feat/overview-term-status`，2026-11-25）实机检查

规格 `docs/superpowers/specs/2026-11-25-rapp-status-queue-design.md`。

- [ ] 1 总览：已打开的 CLI 终端块第二行跟着程序走：在干活 · N%、等确认 · …、在提问、出错 · …、完成、空闲；没报状态的终端仍是流量
- [ ] 2 设备页终端那一行：程序做完写“完成”、空闲写“空闲”（不再是“未读”“N 分钟没动静”）；没看过的仍亮等待灯
- [ ] 3 顶部提示右边 ▾：程序开始干活、等确认、换了新问题、完成、出错各记一条，前面有灯；进度数字变化不记；刚打开 rApp 时已有的状态不刷屏
- [ ] 4 ▾ 里点一条程序的记录：切到（或打开）那个会话，菜单关上；顶栏那一行字不被程序状态占
- [ ] 5 “需要你”：整行可点——等确认的终端进会话，断开的会话切到舞台（不自动重连），离线设备到设备页；四条以上全列出、可滚
- [ ] 6 设备离线：已打开终端的卡片不再亮等待灯，总览不再写它旧的程序状态
- [ ] 7 以后：GUI 客户端（Claude / ChatGPT / Antigravity）状态识别做好后，接进同一个队列，标“推断”

## 终端名用标题、总览终端新建（分支 `feat/term-title`，2026-11-25）实机检查

规格 `docs/superpowers/specs/2026-11-25-rapp-term-title-design.md` §5。

- [ ] 1 装了 oh-my-zsh 的 zsh：新开后名字是 `~/目录`，`cd` 后跟着变；跑 `vim x` 时变成命令，退出后回到目录
- [ ] 2 Claude Code：名字是它的任务标题，开头没有转动的符号，不闪
- [ ] 3 改过名的终端：名字一直是改的那个
- [ ] 4 不设标题的 shell：仍是 zsh / sh
- [ ] 5 旧版被控端：照旧显示 zsh
- [ ] 6 总览「常用 · 终端」：写「新建」，点两次开出两个新终端；画面模式写「打开」，照旧
- [ ] 7 同一台设备两个终端都在 `~/git/rapp`：先开的叫 `~/git/rapp`，后开的叫 `~/git/rapp · 2`；其中一个 `cd` 走后，另一个回到不带后缀（分支 `feat/term-title-dupes`）
- [ ] 8 重启 rApp 后第一次点「常用 · 终端」：写「打开」，点后把还在跑的文字终端全部重新列出来；之后写「新建」（0.15.33）

## 状态规则 R1–R4、R6（分支 `feat/app-state-rules`，2026-11-25）实机检查

规格 `docs/superpowers/specs/2026-11-25-rapp-app-state-rules-design.md`；计划 `docs/superpowers/plans/2026-11-25-rapp-app-state-rules.md`。协议 v16（类型 43 `stateRules`、44 `appState`）。

- [ ] 1 ChatGPT 做完一轮：灯从在干活回到空闲，行上显示完成 + 推断
- [ ] 2 Claude 桌面端：在干活时灰点、做完绿点，灯跟着变
- [ ] 3 Claude 要你确认时：灯变“等你”；`ask` 没验过时**不**进“需要你”
- [ ] 4 关掉 `stateRules`（配置页选“关”）：重连后灯和以前一样
- [ ] 5 在“我的”（`<数据目录>/shared/state_rules/`）里放一个只改一个数的补丁：配置页显示“我的（有补丁）”
- [ ] 6 放一个故意对不上的包：大约 5 轮后配置页和会话菜单出现“状态规则可能过期”，不弹窗
- [ ] 7 最小化 app 窗口一会儿：不会被判成对不上
- [ ] 8 被控端日志里没有识别出的文字；报告里没有标题
- [ ] 9 规则开着时 CPU：活动监视器里 rapp-host 比关掉规则时多不到 5%
- [ ] 10 Linux 操作端连 macOS 被控端：灯一样会变（Linux 也发规则）
- [x] 11 ✅ 已在本机回环验过（本机 Claude 7.37095.0）：日志那一行、`appState`、`invalid`、发 `""` 关掉规则，都和规格一致
- [ ] 12 静止的 Claude 窗口：回环里窗口什么都没跑，却报了 working，因为 claude-desktop 包的 `rowGray` 数到 2 个灰点。到真机上看侧栏里被数的是哪个灰；不是 Claude 会话的灰点就在 rev 2 里重调这一包。没有屏幕证据，没有重调
- [ ] 13 静止的 Claude 会话从 working 变 done 后，灯应停在 done，不能停在 working
- [ ] 14 B 在这个会话上开着缩放或焦点面板时，状态停在最后一次读数，这是预期的；缩放关掉后，灯几秒内追上
- [ ] 15 ChatGPT 的“Worked for”文字从没出现过，所以 `by` 里的 `workedFor` 未实测；到真机上找
- [ ] 16 用 `/usr/bin/log stream --process rapp-host` 确认识别出的文字不出现在日志里（要写全路径，zsh 内建的 `log` 会盖住它）
- [ ] 17 新启动的 rApp：Vision 预热期间（约 13 秒）文字标志还不生效，之后才生效；这段时间不出现任何错误
- [ ] 18 移动一个静止的 Claude 窗口：灯不会闪一下“在干活”（移动后头一次取图可能还是移动前的画面）

## 新文字终端开在 Terminal 标签页里（分支 `feat/term-tabs`，2026-11-25）实机检查

做法：被控 Mac 上已有 rApp 开的 Terminal 窗口时，把它提到最前、按 ⌘T，在新标签页里启动；没有这样的窗口、权限被拒、⌘T 没出标签页，都照旧开新窗口。

- [ ] 1 第一个文字终端：照旧开一个新 Terminal 窗口
- [ ] 2 再新建两个：都成了那个窗口里的标签页，不再多出窗口；rApp 列表里三个终端都在、都能打字
- [ ] 3 第一次会弹「rApp 想控制 Terminal / System Events」：允许后标签页正常；拒绝后照旧开新窗口，不会开出两个
- [ ] 4 rApp 开的窗口最小化了、或在别的桌面：被拉回来并开出标签页
- [ ] 5 只有用户自己开的 Terminal 窗口（没有 rApp 终端）：不往里加标签页，开新窗口
- [ ] 6 新标签页里那行 ` exec /bin/sh …` 前有空格：开了 hist_ignore_space 的 zsh 不记进历史

## 总览「正在被接入」、连接管理小窗口不弹（分支 `feat/overview-inbound`，2026-11-25）实机检查

规格 `docs/superpowers/specs/2026-11-25-rapp-overview-inbound-sessions-design.md`。

- [ ] 1 另一台设备打开本机的应用：本机列出现「正在被接入 · 1」和一张虚线卡片，写 app 名、对方设备名、接入多久（秒数在走）
- [ ] 2 另一台设备打开本机的文字终端：卡片标题是 `CLI · …`
- [ ] 3 点卡片空白处没有反应；点「断开」后对方断开，卡片消失
- [ ] 4 主窗口在屏幕上时有设备接入：不弹「rApp 连接管理」小窗口，Dock 也不闪出第二个图标
- [ ] 5 主窗口关掉（留在 Dock）、最小化或退出后再有设备接入：小窗口照旧弹出
- [ ] 6 Linux 主窗口：总览同样显示「正在被接入」
- [ ] 7 局域网接入（不经中继）：卡片上是对方自称的设备名，不是 ip:端口
- [ ] 8 刚好在有设备接入的同时打开 rApp：主窗口照常出现（不会悄悄没开）

## 多终端：⌘T 新建、结束终端（分支 `feat/term-multi`，2026-11-26）实机检查

规格 `docs/superpowers/specs/2026-11-26-rapp-term-multi-design.md` §6。

- [ ] 1 在文字终端里按 ⌘T：几秒内出现新终端，rApp 切过去；被控 Mac 上是同一窗口的新标签页；`pwd` 跟原终端一样。
- [ ] 2 被控 Mac 标签页标题：
  - [ ] shell 里显示 `~/… · zsh`。
  - [ ] `cd` 后一两秒内跟着变。
  - [ ] 开 Claude 后变 `~/… · claude — <任务名>`，转圈符号不闪。
  - [ ] 退出 Claude 回到 `· zsh`。
- [ ] 3 rApp 里的名字、画面不受标题改写影响，跟 0.15.33 一样。
- [ ] 4 「结束终端」：
  - [ ] shell 空闲时直接结束，标签页关掉，rApp 列表里消失。
  - [ ] 跑着 Claude 时先问，取消则什么都不变。
- [ ] 5 ⌘W 跟菜单一样。
- [ ] 6 终端里 `exit`：rApp 会话自动消失，提示「已结束」；被控 Mac 上标签页自动关掉，不留「进程已完成」。
- [ ] 7 用户自己在 Terminal 里手动跑 `rapp-term run` 再 exit：它的标签页**不**被关。
- [ ] 8 断网再连：会话是「已断开」并自动重连，不被当成结束。断网期间在被控端 exit，重连后会话消失，提示「已结束」。
- [ ] 8a 会话菜单里文字终端显示「关闭」和「结束终端」两项；画面会话仍是「结束」。
- [ ] 8b 没有 rApp 连着时在被控端 exit，10 分钟内打开 rApp 连上，标签页被关掉。
- [ ] 9 旧设备（0.15.33）：⌘T 能开，从家目录开始；没有「结束终端」；其他照旧。
- [ ] 10 Linux 被控端：标题跟着变；⌘T（Ctrl+Shift+T）能开；exit 后窗口自己关。

- 已在本机验证：CLOSE_TABS 能关掉只剩一个标签页且已退出（「进程已完成」）的 Terminal 窗口。Terminal 无法用脚本关单个标签页，所以关的是窗口。仍待真机：一个窗口里有多个标签页（Terminal「优先使用标签页」设置）的情况，其中已结束的标签页按设计保留不关。
- [ ] 带键盘的 iPad：⌘T/⌘W 目前跟现有 term_keys 规则一致（非 macOS 为 Ctrl+Shift+T/W，与 ⌘C 同）；规格写的是 ⌘T，到真机上决定 iPad 是否该用 ⌘。
- 新增提示文案（规格里没有）：「新建终端没有回应，请稍后再试」（⌘T 等了 20 秒）。
- 后续：8 位 C1 OSC（0x9d）标题没有被剥掉；三个 serve open_from 集成测试各要约 10 秒。
- 后续（M5）：同一 tty 在 10 分钟内被重用时，旧的结束标记可能关掉用户自己已退出的单标签 Terminal 窗口；做法：清扫时看到该 tty 上有活进程就删掉它的标记。
- 后续：worker 重启后没见过的终端，若同时有别的 holder 一直不回话，会一直回「busy」重试而显示不出「已结束」；做法：连续 busy 若干次或 `terms` 列表里没有这一行就按已结束处理。
- 后续：结束被拒时提示直接显示英文 `text terminal busy`，可换成中文文案（需定文案）。
- 后续：标题刷屏的程序每个带标题的输出块都会探一次前台程序，可限到 100–200 ms 一次。


## Linux 0.15.34 程序状态、状态队列、终端标题与常用终端恢复对齐与发布（2026-11-25）

- [x] 对齐 macOS 0.15.29–0.15.33：OSC 7501 程序状态 S1、顶栏提示右侧 `▾` 状态队列与「需要你」全量可滚/整行直达、OSC 0/1/2 终端程序标题与重名 ` · 2` 后缀，以及总览「常用 · 终端」重启后首次点击恢复运行中文字终端并随后切换「新建」。
- [x] 修正 `gui/lib/ui/main_state.dart` 中 `_termListMissing`：无应用级画面共享的 Linux 宿主（`graphical: false` 或 `applications: false`）在终端列表尚未到达时即使存过 `pixels` 偏好也先等待列表，不再跳过恢复与新建判断；补充 `TargetPlatform.linux` 回归用例（覆盖总览五态、重名标题、`▾` 状态队列与「需要你」直达及仅桌面 Linux 宿主恢复/新建）。
- [x] Flutter 3.50.0 `analyze` 无 error/warning（141 条既有弃用 info），全量基线及本次新增回归（634 项核心 UI/状态用例）全部通过；Rust 套件（`rapp-term`、`rapp-host-linux`、`rapp-service`、`rapp-hub`、`rapp-client-core`、`rapp-update`、`rapp-speech-linux`、`rapp-testkit --test term --test update`）clippy `-D warnings` 与测试通过；`scripts/test-linux-build.py` 与打包产物 `scripts/test-linux-terminal-service.py` 通过。
- [x] [Linux v0.15.34](https://github.com/wizlijun/rapp/releases/tag/v0.15.34) 已发布（源码 `2f544075`，`--latest=false`）；两包 40 文件逐字节一致、14 个 ELF 依赖完整、`BUILD-INFO.json` 与隔离网络命名空间服务/CLI/端口共享测试通过；三个远端附件大小与 SHA256 与本地一致，macOS Latest 保留 `v0.15.33`。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-25-linux-01534-parity.md`。
- [ ] 实机验收：Linux / Omarchy 下运行 Claude Code / Codex / agy 验证 OSC 7501 状态与 OSC 0/1/2 标题、重名 ` · 2` 编号及重启 rApp 后总览「常用 · 终端」首点恢复。

## Linux 0.15.36 协议 v16 状态规则客户端、本机接入列表与多文字终端对齐与发布（2026-11-26）

- [x] 对齐 macOS 0.15.35：协议升至 **v16**（`rapp-client-core`、`rapp-session`、`LinuxSessionPort` 与 `rapp-client-gtk` 完整支持向兼容被控端发送 `stateRules` 并接收 `appState` 推断状态；`rapp-host-linux` 校验并安全忽略收到的规则包）、总览本机列「正在被接入 · N」与「断开」（Linux `--cm --background` 保持隐藏）、以及多文字终端 `Ctrl+Shift+T` / `Ctrl+Shift+W`、「结束终端」、干净退出与 Linux `/proc` 宿主 `<目录> · <程序>` 窗口标题。
- [x] 补充 Linux 回归用例：真实 `rapp-session` 进程的协议 v16 `state_rules`/`appState` 往返测试、`TargetPlatform.linux` 下 `Ctrl+Shift+W` 结束终端与运行程序确认弹窗/防重复测试、以及总览本机列「正在被接入 · N」展示与「断开」测试。
- [x] Flutter 3.50.0 全量 3262 项通过（3 项条件跳过），`flutter analyze` 无 error/warning（145 条既有弃用 info）；Rust 套件（`rapp-term` 284、`rapp-host-linux` 41、`rapp-client-core` 70、`rapp-client-gtk` 8、`rapp-service` 113、`rapp-hub` 45、`rapp-update` 61、`rapp-speech-linux` 4、`rapp-testkit --test term --test update` 52）与 `scripts/test-linux-build.py`、打包产物 `scripts/test-linux-terminal-service.py` 全部通过。
- [x] [Linux v0.15.36](https://github.com/wizlijun/rapp/releases/tag/v0.15.36) 已发布（源码 `5b9ce64e`，`--latest=false`）；两包 41 文件逐字节一致、14 个 ELF 依赖完整、`BUILD-INFO.json`、协议 v16 版本校验与隔离网络命名空间服务/CLI/端口共享测试通过；三个远端附件大小与 SHA256 与本地一致，macOS Latest 保留 `v0.15.35`。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-26-linux-01536-parity.md`。
- [ ] 实机验收：Linux 连接 macOS 0.15.35 验证协议 v16 状态规则推断显示；Linux 本地验证 `Ctrl+Shift+T`/`Ctrl+Shift+W`、宿主终端 `<目录> · <程序>` 标题与总览本机列「正在被接入」。

## 文本终端恢复（规格：docs/superpowers/specs/2026-11-26-rapp-term-restore-design.md，计划：docs/superpowers/plans/2026-11-26-rapp-term-restore.md）

已完成（任务 1–9）：

- [x] 1 shell 钩子（zsh/bash/fish）与 OSC 7502 上报
- [x] 2 快照存盘、命令过滤、清理
- [x] 3 快照的删除规则
- [x] 4 serve `restore` / `forget`、`term_saved`
- [x] 5 `rapp-term run --restore`（沿用旧 key、环境激活、命令预填）
- [x] 6 `rapp term restore` 命令行
- [x] 7 「新建」沿用上一个终端的目录（`from: "last"`）
- [x] 8 GUI 恢复列表与入口
- [x] 9 testkit 端到端测试

实机检查（规格 §7）：

- [ ] 1 开 3 个终端：一个在 venv 里跑 claude，一个在 conda 环境里空着，一个在别的目录跑 `npm run dev`。重启电脑，在 rApp 里恢复：目录、环境（提示符前的 `(venv)`、`(ml)`）、填好的命令都对，没有一个自己跑起来。
- [ ] 2 同上，改在被控 Mac 上敲 `rapp term restore`。
- [ ] 3 敲 `exit` 结束的、在 rApp 里点「结束终端」的，不在恢复列表里。
- [ ] 4 点 Terminal 的红色关闭按钮关掉的，在恢复列表里，勾掉就不恢复。
- [ ] 5 在终端 A（`~/git/x`）里点总览「新建」：新终端在 `~/git/x`；在设备页点「新建 · bash」：bash，在 `~/git/x`。
- [ ] 6 重启 rApp 后什么都不看，直接点「新建」：在最近有输入的那个终端的目录。
- [ ] 7 自己的 `~/.zshrc` 里的提示符（oh-my-zsh、starship 之类）、补全、别名在 rApp 开的终端里和直接开 Terminal 一样。
- [ ] 8 在 rApp 开的终端里再敲 `zsh`、`tmux`：读的是用户自己的配置。
- [ ] 9 `KEY=xxx claude` 跑着时重启，恢复后填的是 `claude --continue`，`saved/` 里搜不到 `xxx`；`claude --api-key sk-abc…` 跑着时重启，恢复后只填 `claude`，`saved/` 里搜不到 `sk-`。
- [ ] 10 恢复后不按回车再重启一次，命令还能填回来。
- [ ] 11 只关窗口（不重启）后，总览按钮仍说「新建」；设备页有「上次没关的 1 个终端」。
- [ ] 12 macOS 自己的「重新登录时重新打开窗口」：重启后 Terminal 会不会把 rapp 的旧标签页重开成普通 shell，和恢复出来的混在一起（规格 §8）。⌘Q 的情形见第 13 项。
- [ ] 13 Terminal.app ⌘Q 实验（会关掉本机所有 Terminal 窗口，先确认没有别的会话在用）：开一个 rapp 文字终端，⌘Q 退出 Terminal 再打开。看标签页回不回来，回来的是同目录的普通 shell 还是重跑 `.command`；再看 rApp 恢复同一个终端后会不会出现两份。结果写进规格 §8。已知 `NSQuitAlwaysKeepsWindows` 没设（系统默认，退出时关闭窗口）。

跟进：

- [ ] `rust/term/src/pty/resume.rs` 改写表的三处问题（终审第 3 条，只影响预填，不会执行）：`claude -p hi` 被改成 `claude -p --continue`（一次性打印，不是交互会话）；表里没有的带值选项（如 `--system-prompt`、`--output-format`）会把 `--continue` 吞成自己的值，或把自己的值当提示词丢掉；子命令也被改写（`claude doctor` → `claude --continue`，`codex exec x` → `codex resume --last`）。做法：claude 的 `-p/--print` 和已知子命令原样不动。
- [ ] 恢复时快照恰好读不出来（极少见）：终端窗口里写了原因，但 rApp / `rapp term restore` 只说「10 秒内没打开」。做法：holder 读不出来时先把原因交回 serve，再退出。
- [ ] 快照存命令时，双引号里的 `\"` 没跳过：`TOKEN="abc\" def" claude` 会存成 `def" claude`，漏出值的一部分。做法：`strip_assignments` 在双引号里也认 `\`。
- [ ] 规格的密钥规则表补上 `docker/podman login -p`（代码已拦）。
- [ ] `rust/term/tests/shell_hook.rs`：`strip_osc` 插进了 `home()` 和它的注释之间，把注释挪回 `home()` 上。

## Linux 0.15.38 新建终端防重开与前台程序标题对齐与发布（2026-11-26）

- [x] 对齐 macOS 0.15.37：`rapp-term serve` 跳过请求方已断开的排队 `open`、`rapp-hub` 禁止重发 `open_term`/`end_term` 并将 `open_term` 超时放宽至 45 秒、GUI 单设备「新建」串行互斥（提示「正在新建终端，请稍候」），以及文字终端标题显示前台程序 `<程序> · <标题>` 且 `CLI` 移至副标题。
- [x] 补充 `TargetPlatform.linux` 回归用例（覆盖总览终端块 `claude · ~/git/rapp · 2` 前台标题、`CLI · …` 副标题与「新建」单并发防重开提示）；Flutter 3.50.0 全量 3266 项通过（3 跳过），`analyze` 无 error/warning；Rust 全套 clippy `-D warnings` 与测试通过。
- [x] [Linux v0.15.38](https://github.com/wizlijun/rapp/releases/tag/v0.15.38) 已发布（源码 `8ac509fe`，`--latest=false`）；两包 41 文件逐字节一致、14 个 ELF 依赖完整、`BUILD-INFO.json` 与隔离网络命名空间服务/CLI/端口共享测试通过；三个远端附件大小与 SHA256 与本地一致，macOS Latest 保留 `v0.15.37`。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-26-linux-01538-parity.md`。

## rapp update / 自动升级（规格：`docs/superpowers/specs/2026-11-26-rapp-cli-update-design.md`，分支 `feat/cli-update`）
- [x] 服务：记最后一次远程活动和 GUI 的远程窗口数；所有安装都先请 GUI 退出（`quit_gui`），装好再打开；自动升级只在 10 分钟没人操作时装
- [x] CLI：`rapp update`、`update check`、`update status`、`update rollback`，`--json`、`--yes`、`--timeout`，退出码按 §5.4
- [x] GUI：看到 `quit_gui` 就退出（主窗口和 `--cm` 窗口），报告远程窗口数，文案「10 分钟没人操作时会自动装好」
- 第一次升级到带这个功能的版本，还要手工点一次「立即升级」；之后才会自动装
- 实机检查（要等一个比它更新的版本发布出来才能做，§5.8）：
  - [ ] 1. 开着几个文本终端，里面跑着 claude，执行 `rapp update`：升级完成，终端里的程序照样跑，窗口照样能用
  - [ ] 2. GUI 开着时执行 `rapp update`：GUI 退出，装好后重新打开，没有弹 ⌘Q 确认
  - [ ] 3. MacBook-M4-Pro 连着在看终端，但两边都 10 分钟不碰：自动装上，M4-Pro 那边断开几秒后自己重连
  - [ ] 4. 本机一直在打字：不自动装（`rapp update status` 不显示原因；日志里 `update_auto_wait` 写着「最近本机有人操作」）
  - [ ] 5. M4-Pro 一直往终端里输入：不自动装
  - [ ] 5a. 本机开着一个看别的设备桌面的远程窗口：不自动装；只开着文本终端标签页：照样自动装，重开后标签页恢复
  - [ ] 6. `rapp update --json`、`rapp update check --json`、`rapp update status --json` 的输出能被 `jq` 解析，退出码符合 §5.4
  - [ ] 7. `rapp update --timeout 1`：退出码 5
  - [ ] 8. 开着「rApp 连接管理」小窗（`--cm`）时执行 `rapp update`：小窗也关掉，升级不会因为它卡住
- 审查留下的两条小问题（没修）：
  - [ ] ps 的 `comm` 分不出 `--cm` 小窗和主窗口：上次服务留下的孤儿 `--cm` 会被当成「主窗口开着」，升级后多开一次主窗口（要改读 `args=`）
  - [ ] 安装中途 panic 会让 `quit_gui` 一直是 true，GUI 一打开就退，直到服务重启（可用 drop guard 清掉）

## 设备系统图标（2026-11-26，规格 `docs/superpowers/specs/2026-11-26-rapp-device-os-marks-design.md`，计划 `docs/superpowers/plans/2026-11-26-device-os-marks.md`）

- [x] service 的 `list_apps` 回报 `os`（macos / windows / linux / omarchy）；hub 记进 hosts.json 并转给 GUI；总览每个设备列在状态灯左边画单色系统图标（9 种，含「未知」），悬停显示系统名。分支 `feat/device-os-marks`。
- [ ] 实机检查：① Mac 本机列显示苹果；② 已升级的另一台 Mac / Omarchy / Linux 列显示对的图标；③ 未升级的设备显示「未知」，升级后变对；④ 设备离线后图标还在；⑤ iPad、iPhone 本机列是平板 / 手机外形加苹果；⑥ 三套主题下都看得清；⑦ 悬停显示系统名。

## 会话标注（2026-11-26，规格 `docs/superpowers/specs/2026-11-26-rapp-session-labels-design.md`，计划 `docs/superpowers/plans/2026-11-26-rapp-session-labels.md`，分支 `feat/session-labels`）

- [x] 第一期：被控端服务存 `labels.json`（标题 ≤64 字、备注 ≤200 字），新 Op `WatchLabels` / `SetLabel` / `ResetLabel`、`OpenTerm.label_from`；本机 IPC `labels` / `set_label` / `reset_label`；hub 每台在线设备一个标注 watch，推 `labels` 事件，旧设备推 `unsupported`
- [x] GUI：总览、顶栏会话列表、侧栏会话页、「打开应用」菜单都显示标注标题和备注；卡片右键 / 长按「改标题和备注…」「还原」；有标注但没打开的会话排在所属分组末尾（「没有打开 · 打开」或「已停止 · 启动」，后者在家目录新开并搬走标注）；本机列「正在被接入」卡片并进同一张卡片，下面列出「有标注的会话」
- 第二期（等 `feat/term-restore` 合入后做，规则见规格 §7.2）：
  - [ ] 钉住：标注表里的 `term:pty:<key>` 交给 serve，holder 在 shell 退出 /「结束终端」时不删钉住的快照，改记 `ended`
  - [ ] `HostRow.saved` 加 `pinned`、`ended`；`ended` 的不进「恢复上次的终端」，钉住的不参加 30 天 / 50 个清理，`ForgetTerms` 跳过
  - [ ] 「启动」有快照时用 `RestoreTerms{keys:[key]}` 恢复原目录；还原标注时解除钉住，已 `ended` 的快照删掉
- 小项（审查时看到，不急）：
  - [ ] 状态队列那几行（`_trackPrograms`、`termDisplayName`）和「已结束 …」提示还用默认名，没用标注标题
  - [ ] 设备关了终端会话时，有标注的终端仍显示「已停止 · 启动」，点了会失败；应隐藏或说明
- 实机检查：
  - [ ] 1. A 上给一个终端改标题和备注，B、iPad 上同一张卡马上变；B 改回来，A 也变
  - [ ] 2. 退出重开 GUI、重启被控端服务：标注还在
  - [ ] 3. 「还原」后标题回到默认名，提示「已还原，标题回到 …」；没打开的那张卡消失
  - [ ] 4. 有标注的终端里 `exit`：每台客户端都出「已停止 · 启动」，点「启动」在家目录新开，标注跟过去，提示「原来的目录没有记下，已在家目录新开」
  - [ ] 5. 有标注的图形 App 没打开：卡片在设备列末尾写「没有打开 · 打开」，点了打开；不计入顶部计数
  - [ ] 6. 被控端本机列：被接入的卡片显示标注，右键能改；没人接入的有标注会话列在「有标注的会话」下，能改能还原
  - [ ] 7. 连一台没升级的设备：卡片没有标注菜单，其他照常
  - [ ] 8. 设备离线：没打开的标注卡收起；已打开的卡菜单变灰，写「设备离线，连上后再改」
  - [ ] 9. 标题 65 个字、标题里有换行：对话框里红字说明，不关闭；备注里的换行变成空格
  - [ ] 10. 按 App 分组时，改了标题的会话仍在原来那个 App 组里
  - [ ] 11. `service.log` 里只记 `set_label` 这件事，不出现标题、备注和 app

## Linux 0.15.42 统一会话卡片、rapp update 命令与设备系统图标对齐与发布（2026-11-26）

- [x] 对齐 macOS 0.15.39–0.15.41：顶栏、侧栏「会话」页与总览统一 `SessionBlock` / `FavoriteBlock` 卡片；补齐 Linux 启动脚本 `rapp update` 分发与 `rapp-cli` 在 Linux 下的当前版本回报及发布页链接映射（`not_launchd`，退出码 `7`）；核对实机 `/usr/share/omarchy/shell` 识别 `omarchy` 系统图标。
- [x] 补充 `TargetPlatform.linux` 侧栏统一卡片/常用终端回归用例（`gui/test/ui/side_panel_test.dart`）及打包启动器/集成断言（`scripts/test-linux-launcher.py`、`scripts/test-linux-bundle.py`）；Flutter 3.50.0 全量 3282 项通过（4 跳过），Rust 全套 clippy `-D warnings` 与测试通过。
- [x] [Linux v0.15.42](https://github.com/wizlijun/rapp/releases/tag/v0.15.42) 已发布（源码 `018e8d3b`，`--latest=false`）；两包 41 文件逐字节一致、14 个 ELF 依赖完整、`BUILD-INFO.json` 与隔离网络命名空间测试通过；三个远端附件大小与 SHA256 与本地一致，保留 macOS Latest。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-26-linux-01542-parity.md`。

## Linux 0.15.44 会话标注与官方设备系统标志对齐与发布（2026-11-26）

- [x] 对齐 macOS 0.15.43：被控端持久化会话标注（`local/labels.json` `0600`、`watch_labels`/`set_label`/`reset_label` 与 `open_term` `label_from` 原子搬迁）、全卡片统一 `SessionCard` 标题/备注/右键菜单、分组末尾待机与已停止终端一键「启动」恢复，以及总览设备系统标志改用官方图形（含 `omarchy.org` MIT 图形）。
- [x] 补充 `TargetPlatform.linux` 会话标注/Omarchy 标志/`ghostty` 重启回归用例（`gui/test/ui/session_labels_test.dart`）及打包服务本机 `labels` IPC 与日志脱敏校验（`scripts/test-linux-bundle.py`）；Flutter 3.50.0 全量测试与 Rust 全套 clippy `-D warnings` / 测试全部通过。
- [x] [Linux v0.15.44](https://github.com/wizlijun/rapp/releases/tag/v0.15.44) 已发布（源码 `2e2e7513`，`--latest=false`）；两包 41 文件逐字节一致、14 个 ELF 依赖完整、`BUILD-INFO.json` 与隔离网络命名空间测试通过；三个远端附件大小与 SHA256 与本地一致，保留 macOS Latest。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-26-linux-01544-parity.md`。

## 常用语条命令（feat/strip-commands，2026-11-26）实机检查（规格 `docs/superpowers/specs/2026-11-26-rapp-strip-commands-design.md` §13）

- 默认常用语改成 7 条短的（继续 · 按你推荐来 · 进度 · 全做完别问我 · 先写方案别改代码 · 跑下测试 · 提交并推送）；只有新用户和点「恢复默认」的人会看到，老用户的列表不动
- [ ] 1. 文字终端里开 Claude Code：条上前面是 6 个命令按钮；点「新对话」，Claude Code 真的清空并开始新对话
- [ ] 2. 同一个终端退出到 zsh：命令按钮消失，条上只剩常用语，画面高度不变
- [ ] 3. 开 Codex：「新对话」发的是 `/new`；Codex 没有的意图按钮是灰的，点了提示原因
- [ ] 4. 「换模型」：弹出模型列表，用 ↑ ↓ ⏎ 能选中
- [ ] 5. 「搜历史」：Claude Code 和 Codex 里进入 ⌃R 搜索
- [ ] 6. 1 秒内连点两次命令，只发一次；断网冻结时命令按钮也是灰的
- [ ] 7. 命令不进输入历史：↑ 翻不到 `/clear`，历史列表里也没有
- [ ] 8. 管理页：拖动让命令和常用语交叉排序，条上的顺序跟着变；新建一个命令「审查」（Codex `/review`），在 Codex 里能用
- [ ] 9. 改内置命令在某个工具上的写法后能生效；「恢复这一项」和「恢复默认」都能用
- [ ] 10. 老用户升级：原来的常用语还在，6 个命令出现在最前面，只插一次
- [ ] 11. App 会话（远程 iTerm2 里跑 claude）：不出现命令按钮
- [ ] 12. macOS、Linux 的 PC 按键区上同样能用
- [ ] 13. Claude Code 被 `kill -9` 后在同一终端开 vim / ssh：常用语条不显示命令

## 输入法跟着意图走（feat/ime-intent，2026-11-26）实机检查（规格 `docs/superpowers/specs/2026-11-26-rapp-ime-intent-design.md`）

- 终端（终端、iTerm2、Ghostty、Warp）默认不再因字母开写作版；用户自己改过开关的以用户的为准
- [ ] 1. 本机停在 ABC 时开写作版，直接打出中文
- [ ] 2. 按字母开写作版，第一个字母进拼音（`nihao` → 你好）
- [ ] 3. 鼠须管、搜狗下同上；切不过去时第一个字母照现状上屏，不丢字
- [ ] 4. 回到画面后本机是英文；在写作版里自己按 ⌃空格 切成英文后不会被切回中文
- [ ] 5. A 在拼音时直接打 `ls`，得到 `ls`；打 `y` 回答 Claude Code，不弹写作版
- [ ] 6. 点「切回 拼音」后在 A 上直接打中文；打开写作版后恢复自动切英文
- [ ] 7. Linux 被控端：开头几个字不丢（并在 Linux 机器上编译、跑 clippy `host-linux`）
- [ ] 8. iOS「内」模式下开写作版回到「中」
- [ ] 9. Linux 客户端（fcitx5 / ibus）进出写作版能切换
- [ ] 10. 设置开关关掉后回到老行为
- [ ] 11. 重连时光标从旧写作版交给新写作版（冻结舞台重连），本机不出现先英文再中文的来回切换
- [ ] 12. Linux 客户端：光标在写作版里时切到别的应用（Alt-Tab），别的应用的输入法不被改；切回 rApp 只切一次中文
- [ ] 13. 离开写作版后约 200 ms 才切回英文，期间点进另一个写作版不切
- [ ] 14. 密码框（解锁对话框）从写作版拿走光标、再回到画面时，本机输入法是否回到英文（已知可能停在中文）
- [ ] 15. Mac：按字母开写作版时，原生编辑器拿到焦点的顺序是否让第一个字母进中文（focus 事件早于 readyForInput）
- [ ] 16. Linux 客户端：按字母开写作版，第一个字母不被拆开（输入法保持原样）

开发侧遗留：Linux 被控端 `rust/host-linux/src/input_source.rs` 只在 Mac 上写过、没在 Linux 上编译过，需要在 Linux 机器上 `cargo build`、`cargo clippy -p host-linux -- -D warnings`、`cargo test -p host-linux`。另外 `select` 排队等满 300 ms 仍忙时，`server.rs:714` 的 `?` 会结束会话；应改成记一行日志、丢掉这次 select（规格 §3.2 实现偏差），同样要在 Linux 上改和验证。

## 设备负载（规格 `docs/superpowers/specs/2026-11-26-rapp-device-load-design.md`，计划 `docs/superpowers/plans/2026-11-26-rapp-device-load.md`，分支 `feat/device-load`）

- [x] 服务采样 CPU / GPU / 内存 / 磁盘 / 温度 / 电池，算余力和警告；hub 每台在线设备一条 `watch_load`；`rapp load` / `rapp load pick`；总览设备列的余力行和明细；资源警告进「需要你」，带建议动作和「1小时内不再提醒」。
- 实机检查：
  - [ ] 1. 本机列显示余力
  - [ ] 2. 另一台 Mac 和 Linux 机器的列显示余力
  - [ ] 3. 把一块盘写到剩不到 10% 且不到 20 GB：余力行变橙，「需要你」里有这一行
  - [ ] 4. 点「1小时内不再提醒」：这一行不见了
  - [ ] 5. 点「到 <设备> 上新建终端」：终端开在那台设备上
  - [ ] 6. `rapp load`、`rapp load pick --json` 能用
  - [ ] 7. 活动监视器里服务 CPU 一直低于 0.5%，开 1 小时后内存（RSS）涨不到 5 MB
  - [ ] 8. 没升级的旧设备：没有余力行，日志里也没有相关记录
  - [ ] 9. 开着约 20 个终端跑 1 小时：服务的 CPU 和 RSS 仍在预算内（平均 < 0.5% 一个核，RSS 涨不到 5 MB）
  - [ ] 10. macOS 上余力明细的「内存」可用 % 和活动监视器对得上
  - [ ] 11. Linux 采样器跑一遍：CPU / 内存 / 磁盘 / 温度 / 电池的数都合理，读不到的项是「—」
  - [ ] 12. 停掉对端的服务，或者断开中继：那一列的余力在约 20 秒内消失，「需要你」里不留资源行

## rapp-state 状态服务（2026-11-26，规格 `docs/superpowers/specs/2026-11-26-rapp-state-design.md`，分支 `feat/rapp-state-p1`）

- [x] P1：`rapp-state` 服务、`rapp-service` 的发件箱（终端程序状态）、附带服务（`local/services.json`）、`Share.kind` 和 `Op::StateSink` 找服务、`rapp state [on|off]`、进 macOS 和 Linux 安装包。release 构建的 `rapp-state` 二进制 1,850,784 字节（约 1.8 MB，本机 Apple 芯片）。规格 §18 第 4 条“hyper 进来以后安装包大多少”：还要打一次包，对比 zip 或 pkg 前后的大小
- [ ] P1 实机检查：
  - [ ] ① 两台真机，一台 `rapp state on`，另一台跑 Claude Code，`curl localhost:<分享号>/v1/queue` 里有 working、blocked、done
  - [ ] ② 停状态服务期间让状态变 3 次，服务恢复后补到
  - [ ] ③ 纯服务器上 `rapp state on`，在 Mac 上 `rapp hosts` 一次后，别的设备的 `rapp state` 都看到它
  - [ ] ④ 没开状态服务的网里，`rapp state` 显示发件箱没在发
- [ ] P1 遗留小问题（总审查记下的，不挡合并）：
  - [x] Linux 机器上跑一遍 `scripts/test-linux-build.py`、`test-linux-bundle.py`（已加 `rapp-state`，macOS 上跑不了）
  - [ ] 状态服务反复起不来时，本机发件箱一直对着本机那个死端口，不会改投别台的状态服务；`rapp state` 还列着“本机的 <端口>”
  - [ ] 开着时改 `local/services.json` 的端口要先 `rapp state off` 再 `on` 才生效（写进配置参考）
  - [ ] 用户手动建的分享备注恰好是“状态服务”时，`off` 会把它当成自己的删掉
  - [ ] 知道有状态服务、又开着终端时，发件箱会让终端 worker 一直活着（设计如此，看耗电/资源）
  - [ ] 服务停时留下的 kind state 分享，若下次以 off 状态启动不会被收回
- [x] P2：app 接入（设置里的“状态服务”块、`/v1/watch`、`/v1/seen`，队列和“需要你”在连上时改从服务来，iOS 经内嵌 hub 的分享找服务）。P2 决定不借 `list_apps` 带出分享表：iPad 自己看得到 hub 的 `ports` 事件里 `kind: state` 的分享，就能找到服务。
  - 纯服务器上开的状态服务，仍要等一台 GUI 设备看过一次它的分享表（`rapp hosts` 或分享页）才传得开（P2 不改这一条）
  - 规格 §18 第 3 条（iOS 前台 SSE 长连接是否稳）见实机检查 6
- [ ] P2 实机检查：
  - [ ] 1. Mac 和 iPad 的队列逐行相同
  - [ ] 2. “需要你”的先后相同
  - [ ] 3. Mac 上看过，iPad 上不再是新的
  - [ ] 4. Mac 的 rApp 退出后终端完成一轮，iPad 看到
  - [ ] 5. 关掉状态服务，两边各用各的队列，只记一行中断
  - [ ] 6. iPad 进后台再回来，没有重复行，重连所需时间记下来（规格 §18 第 3 条）
- [ ] P2 遗留小问题（总审查记下的，不挡合并）：
  - [ ] “新”用设备时钟比服务时钟（`StateSync.fresh`），两台时钟差大时看过的行可能还粗体（规格 §18 第 1 条）
  - [ ] 连到 P1 的旧状态服务时 `/v1/watch` 是 404，只显示“连不上”，没有“版本太旧”的提示
  - [ ] 旧服务的推送不带 `id`/`device` 时补拉一次 `/v1/state`；补拉期间到的推送没缓冲，可能被旧快照盖一下，下一条推送就好
  - [ ] 一次 refresh 后没真正发起连接（落到“没找到”“已关”或接着改配置），那次的宽限会留着，下次真断要晚 2 秒才报
  - [ ] 补拉完成时若上一轮 `/v1/seen` 还在发，等着的“已看过”要等下一次标记或重连才发
  - [ ] 连上之后 hello 刚到 watch 就断（iOS hub 端口重建晚于 refresh，或 Mac 睡醒超过 45 秒空闲）仍会记一行“状态服务连不上”
  - [ ] 设置里手填地址：别处改了 `local/state.json` 的地址，输入框不跟着变；手机上点模式时，失焦会先存一次手填地址（结果对，只是多存一次）
  - [ ] 监视器已连上、但服务的 `state` 回复当时为空时，要等 60 秒才再找
- [x] P3：桌面和代报（`/v1/desk`、“别处开着”那一组、GUI 客户端推断状态代报、远程开启用设备间新请求 `SetService`、设备页“状态服务”开关）。分支 `feat/rapp-state-p3`，计划 `docs/superpowers/plans/2026-11-26-rapp-state-p3.md`
- [ ] P3 实机检查：
  - [ ] 1. Mac 上开 3 个会话，iPad 的会话面板“别处开着”列出这 3 个，卡片写 `<那台设备名> · 在 <Mac> 上开着`，点一个在 iPad 上打开
  - [ ] 2. Mac 上 Claude 桌面端等确认，iPad 的“需要你”里有它，带“（推断）”，点了在 iPad 打开
  - [ ] 3. Mac 和 iPad 都开着同一个 Claude，iPad 关掉后 iPad 的“需要你”里它还在（Mac 报的）
  - [ ] 4. iPad 设备页把另一台设备的“状态服务”打开，那台 `rapp state` 显示开着，再关掉
  - [ ] 5. 对一台 0.15.51 及更早的设备，开关不出现
  - [ ] 6. 杀掉 Mac 上的 rApp 再打开，上次留下的推断行被清掉
- [ ] P3 遗留：
  - [ ] 退出 app 时不发空桌面，别处会留着“在 <它> 上开着”，直到它下次打开或 30 天
  - [ ] 不确定的 `blocked` 不代报（已报过的确定 `blocked` 变不确定时发 `gone` 撤回）
  - [ ] 没有 hub 的 `me`（旧 hub）时，这台 app 自己的桌面可能短暂出现在“别处开着”里
  - [ ] `stateHost` 遇到任何错误、以及状态还没加载时都返回 null，设备页就不显示“已经有一个在 … 上”
  - [ ] app 退出或睡眠后，它推断并代报的「在等你」会一直留在别的设备上，直到这个 app 再打开；要是在那台设备本机已经答过，这条就过时了
- [ ] P4：`rapp emit`（IPC 的 `emit`、命令行、`RAPP_TERM`）。计划还没写
- [ ] 规格 §18 第 1、2、5 条仍没验证：设备时钟差；发件箱对终端 `watch_terms` 的开销和会话从关到开的跟随；Windows 上 `rapp-service` 的现状

## 总览本机列折叠（分支 `feat/overview-fold-local`，2026-11-26，合并 bf06a8a6）

用户：「作为 pad 或 duo 终端，本机是没有 host 服务的……请默认折叠这种没有 host 会话的列。只显示个图标加标题，尽量少的占横向空间。点开后再展开。」范围选「只折没有 host 的本机」。规格 `docs/superpowers/specs/2026-11-26-overview-fold-local-design.md`。

- [x] `overview_test` 新增 6 条；ui 1478 通过；全量只剩 `linux_detach_test` 2 条（worktree 里没编 `rapp-session`，改动前同样失败）；整分支评审 2 项重要已修
- [ ] 1 iPad / Duo：总览「本机」列是约 56 宽的小竖条（系统图标、灯、「本机」），右边的设备列紧挨着
- [ ] 2 点竖条展开成原来的样子；列头右边 ‹ 折回，手指好点
- [ ] 3 展开后进一个 app 再回全景，仍是展开的；重开 rApp 又是折叠的
- [ ] 4 Mac / Linux：本机列和以前一样，没有竖条、没有 ‹
- [ ] 5 VoiceOver 念「展开 本机」「折叠 本机」

## 新建文本终端被授权框卡住（分支 `fix/term-consent`，2026-11-26）

用户：「在新建文本终端时，总会被权限框卡住。应该立即识别出来提醒用户有权限框，跳过去点确认才能继续。否则用户会一直点新建无反应。」原因：被控 Mac 用 AppleScript 驱动「终端」和 System Events，macOS 弹「“rApp”想要控制…」时脚本一直等；10 秒后被掐掉、再等 10 秒才提示，掐掉时授权框可能跟着没了，下次又卡。改成：开窗口前先用 `AEDeterminePermissionToAutomateTarget` 不弹框地问；要问就马上弹框（线程等用户回答），立即回 `ASKING`；GUI 提示「弹出了授权框，点「允许」，点完再新建」，远程设备自动切到它的桌面。

- [x] `consent` 单测 5 条、`overview_test` 新增 3 条（去掉跳转后确实失败）；clippy、cargo 全量（`net_follows_the_relay` 负载偶发，单跑通过）、flutter analyze 通过；flutter 全量只剩 `linux_detach_test` 2 条（main 上同样失败）
- [ ] 1 被控 Mac 上撤掉授权（`tccutil reset AppleEvents`，再重启 rApp 服务），在另一台设备点新建：1 秒内提示「授权框」，并切到那台 Mac 的桌面，能看到授权框
- [ ] 2 点「允许」（可能连着两个：终端、System Events），再点新建：终端正常开成新标签
- [ ] 3 授权框还没点时连点新建：一直是同样的提示，不会堆出多个授权框
- [ ] 4 点「不允许」后再新建：开成一个新窗口（不是标签），不卡
- [ ] 5 在 Mac 本机给本机新建：只提示，不切桌面，授权框就在本机屏幕上
- [ ] 6 「恢复所选」碰到授权框也是同样的提示和切桌面
- [ ] 7 多屏 Mac（用户截图里框在屏幕 2）：画面上正开着它的屏幕 2 时新建，不被切回主屏，提示「不在这块屏上就换一块屏看看」

## Linux 0.15.45 与 0.15.50 版本跟随对齐与发布（2026-11-26）

- [x] 严格遵循版本号跟随规则（不抢先递增版本号、不新建 tag），依次将 Linux / Omarchy `x86_64` 产物构建并挂载至已发布的 `v0.15.45` 与 `v0.15.50` GitHub Release（保留原有 macOS `.pkg`、`.zip`、`latest.json` 及 `Latest` 标记）。
- [x] 对齐 macOS `0.15.45`–`0.15.50`：补齐 `scripts/linux/rapp` 对 `term`、`state`、`load` 三个顶层 CLI 子命令的分发；修复 `rust/term/src/pty/fg.rs` Linux `execve` 测试竞态；补充 `TargetPlatform.linux` 下终端恢复（`term_restore_test.dart`）与常用语条按工具发命令（`phrase_strip_cmds_test.dart`）回归用例；扩充 `scripts/test-linux-launcher.py` 与 `scripts/test-linux-bundle.py` 端到端校验（覆盖 `rapp term restore --list/--forget`、`rapp state on/off` + `rapp-state` 伴随服务、`LinuxSampler` + `rapp load --json` / `rapp load pick --json`）。
- [x] [v0.15.45](https://github.com/wizlijun/rapp/releases/tag/v0.15.45)（源码 `47f5046a`）与 [v0.15.50](https://github.com/wizlijun/rapp/releases/tag/v0.15.50)（源码 `e8b1627d`）双格式包逐字节对比（42 文件 / 15 个 ELF）、`BUILD-INFO.json`、systemd 终端驻留及隔离网络命名空间测试全部通过，远端 SHA256 摘要校验一致。
- [x] 仓库下载快照已更新（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-26-linux-01545-parity.md`、`docs/superpowers/plans/2026-11-26-linux-01546-parity.md` 与 `docs/superpowers/plans/2026-11-26-linux-01550-parity.md`。

## Linux 0.15.51 版本跟随对齐与发布（2026-11-26）

- [x] 严格遵循版本号跟随规则（不抢先递增版本号、不新建 tag），将 Linux / Omarchy `x86_64` 产物构建并挂载至已发布的 [v0.15.51](https://github.com/wizlijun/rapp/releases/tag/v0.15.51) GitHub Release（保留原有 macOS `.pkg`、`.zip`、`latest.json` 及 `Latest` 标记）。
- [x] 对齐 macOS `0.15.51`（`feat/rapp-state-p2`）：Linux 桌面端 `main.dart` / `GlobalSections` / `StateSection`（`0600` 权限保存 `local/state.json`）与 `StateSync`（本机或端口映射发现 `rapp-state`、`/v1/watch` SSE 实时流与 `/v1/seen` 多端已读同步、离线回退本机队列）完整生效；补充 `gui/test/pages/state_section_test.dart`（`TargetPlatform.linux` 下 `GlobalSections` 与 `0600` 权限断言）及 `scripts/test-linux-bundle.py`（IPC `state.url` 与 `/v1/watch` SSE `hello` 端到端断言）。
- [x] `v0.15.51`（源码 `87ace3f2`）双格式包逐字节对比（42 文件 / 15 个 ELF）、`BUILD-INFO.json`、systemd 终端驻留及隔离网络命名空间测试全部通过，远端 SHA256 摘要校验一致，仓库下载快照已同步（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-26-linux-01551-parity.md`。

## 等候卡片（分支 `feat/wait-card`，2026-11-26）

用户：「在文本终端上按 cmd+T 时，等候时间很长，导致用户以为失效了。请在用户按下快捷键后，到需要权限交互或者打开新的文本终端之间，增加一个等候窗口……设置为全局的功能，类似的这种交互都可以出现。」做法：`Waits`（`gui/lib/ui/waits.dart`）+ 舞台最上层的 `WaitCard`（`gui/lib/ui/wait_card.dart`）。⌘T、总览/常用「新建」、「恢复」、待机「启动」、设备页开 shell 都接上了；⌘T 碰到授权框现在也会切到被控 Mac 的桌面（以前只出一行字）。设计 `docs/superpowers/specs/2026-11-26-rapp-wait-card-design.md`，计划 `docs/superpowers/plans/2026-11-26-rapp-wait-card.md`。

- [x] `waits_test` 7 条、`wait_card_test` 4 条、term_main / overview / main_window 新增 4 条（授权切桌面、点击穿透、挂载都做过"去掉就失败"）；flutter analyze 通过；flutter 全量只剩 `linux_detach_test` 2 条（main 上同样失败）
- [ ] 1 在被控 Mac 的文本终端里按 ⌘T：0.3 秒内舞台中央偏上出现「正在新建终端…」卡片，下面是设备名和「在『…』旁边」，秒数在走；新终端打开时卡片消失
- [ ] 2 连按 3 次 ⌘T：卡片显示「还有 2 个排队」，每开出一个减一
- [ ] 3 被控 Mac 上 `tccutil reset AppleEvents` 后按 ⌘T：卡片变成橙色的授权提示，停 8 秒，并切到那台 Mac 的桌面
- [ ] 4 总览「新建」、「恢复所选」、设备页开 shell（侧栏开着时也看得见卡片）都出卡片
- [ ] 5 卡片出现时照常能在终端里打字、点卡片下面的东西
- [ ] 6 浅色、深色主题和远端画面上都看得清；iPad 窄屏不超出舞台
- [ ] 7 （放大后，`fix/wait-card-big`）卡片宽 360–560、主字 18、转圈 22；授权提示整句三行内显示完，不再出现「…」

## Linux 0.15.55 版本跟随对齐与发布（2026-11-27）

- [x] 严格遵循版本号跟随规则（不抢先递增版本号、不新建 tag），将 Linux / Omarchy `x86_64` 产物构建并挂载至已发布的 [v0.15.55](https://github.com/wizlijun/rapp/releases/tag/v0.15.55) GitHub Release（保留原有 macOS `.pkg`、`.zip`、`latest.json` 及 `Latest` 标记）。
- [x] 对齐 macOS `0.15.52`–`0.15.55`（含 Linux `0.15.54` `fix/linux-terminal-paste`）：放大版非阻塞 `WaitCard` 舞台等候卡片（`Ctrl+Shift+T` 排队计数与远端 Mac 授权自动切桌面）、`rapp-host-linux` 终端窗口 `Ctrl+Shift+V` 中文粘贴与 Wayland 选区往返同步、以及 `rapp-state` 第 3 步（`PUT /v1/desk/<fp>` 会话面板「别处开着」一键接力、`StateOut` 应用状态规则代报与「需要你」`推断` 标记、`Op::SetService` 节点间控制及设备页 `StateServiceRow` 开关）；补充 `scripts/test-linux-bundle.py`、`gui/test/term/term_main_test.dart`、`gui/test/ui/state_service_row_test.dart` 与 `gui/test/ui/wait_card_test.dart` Linux 侧回归校验。
- [x] `v0.15.55`（源码 `1038f30b`）双格式包逐字节对比（42 文件 / 15 个 ELF）、`BUILD-INFO.json`、systemd 终端驻留及隔离网络命名空间测试全部通过，远端 SHA256 摘要校验一致，仓库下载快照已同步（`website/releases.json`、`website/README.md`）。详见 `docs/superpowers/plans/2026-11-26-linux-01555-parity.md`。

## Windows 版：现在在 Windows 上关着的测试

计划 A Task 7 规则 2：这些测试在 Windows 上挂了 `#[cfg(unix)]`，macOS / Linux 照常跑。到了写着的那一段，打开它，或者写出 Windows 的版本。

- [ ] `rust/term/tests/cli.rs`、`pty.rs`、`serve.rs`、`shell_hook.rs`（整个文件）—— E 段做完时打开
- [ ] `rust/term/src/pty/fg.rs::tests::status_roundtrips_without_new_fields` —— E 段做完时打开
- [ ] `rust/term/src/pty/view.rs::tests::viewers_are_counted` —— E 段做完时打开
- [ ] `rust/term/src/pty/shell.rs::tests::install_rewrites_on_version_change` —— E 段做完时打开
- [ ] `rust/update/src/apply.rs::tests::exdev_copy_with_failed_delete_keeps_bundle_whole` —— G 段做完时打开（Windows 上只读目录挡不住删里面的文件，要换个挡法）
- [ ] `services/state/src/disk.rs::tests::files_are_private`、`loose_modes_are_made_private` —— rapp-state 在 Windows 上自己设私有时打开（现在靠继承 `<数据根>\local` 的访问列表；哪一段做还没定，最晚 G 段打包 rapp-state 之前）
- [ ] `rust/service/src/load/disks.rs::tests::hung_disk_is_unreadable_and_others_still_come` —— 不跟某一段走：要两块文件系统，等有两块盘的 Windows 测试机再写 Windows 版
- [ ] `rust/service/src/load/disks.rs::tests::a_symlink_across_file_systems_is_the_target`、`a_symlink_does_not_change_the_mount` —— 不跟某一段走：Windows 上建符号链接要管理员或开发者模式；要测就改用目录联接（junction）
- [ ] `rust/conn/tests/relay.rs::rotate_key_closes_every_device_with_code_4`、`requests_after_a_key_change_say_key_changed`、`an_open_relayed_stream_says_key_changed_after_a_rotate` —— 不跟某一段走：中继的管理接口只在 unix 上有（这三个靠 `rapp_relay::admin::issue_key` 换钥匙；中继本身不在 Windows 上跑，Windows 上的 `admin` 只有同名的空壳）
- [ ] `rust/testkit/tests/key_change.rs::service_stops_and_says_key_changed_after_rotate`、`a_new_key_reconnects_with_the_same_id`、`a_wrong_new_key_says_bad_key`、`hub_presence_says_key_changed_and_stops_dialing`、`hub_reports_key_changed`（连同只给它们用的 `rotate`、`audit_events`、`hex`）—— 不跟某一段走：中继的管理接口只在 unix 上有（同上）。要在 Windows 上测换钥匙，得先给测试一个不经管理接口换钥匙的办法

## Windows 版 A 段（地基）（计划 `docs/superpowers/plans/2026-11-26-rapp-windows-a-foundation.md`，分支 `feat/windows-foundation`）

现状（2026-11-27）：代码是草稿，**还没在任何机器上编译、没跑过测试**。草稿笔记在 `docs/superpowers/plans/notes/2026-11-26-windows-a-draft-notes.md`，验证的人先看它的第 6、7 节。

- **已合进本机 `main`，这次合并不发版。** `main` 的文件里只有 Mac 不编译的部分：`rust/host-windows/`、`rust/svc-windows/`（都不在 `rust/Cargo.toml` 的成员表里）、`scripts/check-windows.ps1`、`scripts/stage-windows.ps1`、`.gitattributes` 和文档。Mac 编译的文件和合并前一个字节都不差，所以不影响 macOS 和 iOS 发版。
- **接线不在 `main` 的文件里。** 对已有 crate 的改动（约 55 个文件）在提交 `118b1f72` 里撤下了，它们在 `main` 的历史里。分支 `feat/windows-foundation` 上已经把这个提交还原好，验证的人直接在分支上编译、修。
- **接线进 `main` 的条件**：Mac 门禁全绿，Windows 门禁（`scripts\check-windows.ps1`）全绿，再照常合并。那一次合并改的是共用代码，算 macOS 的改动。

- A 段做完后，一台 Windows 机器能：编出全部 Rust crate（`rapp-relay`、`rapp-host-linux`、`rapp-client-gtk`、`rapp-hub-ffi` 除外）、跑过测试和 clippy（`scripts\check-windows.ps1`）、编出 Flutter 界面、用 `scripts\stage-windows.ps1` 摆出开发用的版本目录、从 `bin\rapp.exe` 启动界面、当控制端连别的设备。
- 还不能：当被控端（没有 `rapp-host`，D 段）、开文本终端（E 段）、自己升级（G 段）、有监督程序和系统服务（`rapp-svc`，C 段）、语音（H 段）、安装包（G 段）。
- **给 Linux session 的发现**（规格 §6.1、§19.3 第 14 条）：`rust/service/src/workers.rs` 的 `permissions()` 没有把 `applications` 留下，`capabilities()` 读到的永远是“没有”，所以 Linux 被控端一直对外报不能开单个 app，控制端不显示它的 app 入口（`gui/lib/ui/device_apps.dart:16` 等四处）。有意还是漏了，由 Linux 的 session 判断；Windows 这次没有改它。
- **要在实机上看的**（未验证）：
  - [ ] 1. 中文用户名（带空格）的账户下：`<数据根>\local` 的访问权限只有本人、SYSTEM、Administrators；数据根搬到 D 盘以后还是这样（规格 §13.2 的验收）。
  - [ ] 2. `cmd`、Windows PowerShell 5.1、Windows Terminal 里 `rapp --help` 的中文都不乱码（规格 §8.2【未验证】）。
  - [ ] 3. 从没有窗口的上级启动 `rapp-service` 再连一次：全程没有黑窗口闪过。
  - [ ] 4. `rapp-service --supervised`：上级关掉它的标准输入后 5 秒内退出，退出码 0；上级被强行结束也一样。
  - [ ] 5. 同一个登录会话里启动第二个 `rapp-service`：立刻退出，第一个不受影响；远程桌面的会话里另起一个不算“第二个”。
  - [ ] 6. Server 2022 云主机（没有显卡）上 `scripts\check-windows.ps1 -Build` 也是绿的。
- Windows 上暂时关着的测试单列在上面的「Windows 版：现在在 Windows 上关着的测试」。

## Windows B 段（主机核心）（计划 `docs/superpowers/plans/2026-11-26-rapp-windows-b-host-core.md`，分支 `feat/windows-host-core`，2026-11-27）

现状（2026-11-27）：`rust/host-core` 加上 testkit 里的 `FakePlatform`、`fake-host-core` 都是草稿，**还没在任何机器上编译、没跑过测试**。

- **已合进本机 `main`，这次合并不发版。** `main` 的文件里只有 `rust/host-core/` 整个目录和文档；`host-core` 不在 `rust/Cargo.toml` 的成员表里，Mac 的门禁和打包看不到它。Mac 编译的文件和合并前一个字节都不差，所以不影响 macOS 和 iOS 发版。
- **接线不在 `main` 的文件里。** 成员表那一行、`rust/testkit` 里的假平台和两组会话测试、`Tests/RappCoreTests/HostCoreFixtures/` 的 Swift 样本生成器，在提交 `6b27449b` 里撤下了，它们在 `main` 的历史里。分支 `feat/windows-host-core` 上已经把这个提交还原好，验证的人直接在分支上编译、修。
- **接线进 `main` 的条件**：分支上 Mac 门禁全绿（先生成 Swift 样本：`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`，再跑 `cargo test --workspace`），再照常合并。那一次合并是共用代码，算 macOS 的改动；macOS 版的行为不变，macOS 的被控端还是 Swift 的 `rapp-host`。
- A、B 两段的接线都改 `rust/Cargo.toml` 的成员表和 `rust/testkit/tests/common/mod.rs`，后合的一方解冲突。

验证顺序见 `docs/superpowers/plans/notes/2026-11-26-windows-b3-draft-notes.md` §6。下面几项假平台演不出来，要等 D 段有了真的 Windows 平台再到实机上看。交接内容见 `rust/host-core/PORTING.md` 第 5 部分「B 段交接」。

- [ ] 1 真的 Windows 截屏在五种模式（gray4、color8、color16、duogray、duocolor）下画面都对：颜色和灰阶不错位，块边界上没有错行
- [ ] 2 滚动复用：在一个真会滚的程序里（浏览器、长文档）滚轮滚动，画面跟着平滑走，没有撕裂的行。日志里看得出滚动复用确实生效了，不是每帧整张重发
- [ ] 3 在一个真的程序里打字（中英文都打，每段超过 20 个字），字都到了，没丢也没重复
- [ ] 4 从 Mac 粘贴文件到 Windows：文件落在 NTFS 的下载目录里。名字是保留名（如 `CON.txt`、`aux`）时改名为 `_CON.txt` 这类，同名再来时编号为 `_CON (2).txt`；SHA-256 和原文件一致
- [ ] 5 锁屏后经系统服务解锁：B 端输入密码，A 真的解开；密码错时 A 保持锁着，B 端还显示「已锁」；日志里没有密码
