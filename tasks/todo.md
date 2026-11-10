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

## 无 relay：自生成 ID 与 `id@ip`
- [x] service 首次启动自己生成 9 位 ID（relay 接受合法的新 ID）；status 加 `lan_ids`（每个可用 IPv4 一个 `id@ip`，跳过 198.18.0.0/15 代理假 IP）；密码认证成功回 `id`、`name`
- [x] hub `add_host` 接受 `id@ip[:port]`：直连做密码认证、核对 ID 后保存；relay 回 `unknown id`/`offline` 时退到局域网地址
- [x] GUI：relay 未连上时 ID 显示为 `lan_ids`，添加主机输入框写明可填 `ID@IP`
- 结果：cargo test、clippy、flutter analyze/test 全过；e2e 第三轮用没有 relay 的 hub 按 `686712053@10.17.0.235:<port>` 加主机并打开 Safari，路径 lan，踢掉会话后 hub 收到 closed。第一次跑时 A 报的第一个地址是 198.18.0.1（本机 TUN 代理的假 IP），连不上，于是加了过滤

## 未经实机验证（交给用户验收）
跨 NAT 打洞、VPS 部署、Windows 和 Linux 上的服务。

## 回顾
- M1 到 M3 按规格定死的接口分给三个子代理并行做，合并时没有冲突，接口这一步省了很多返工。
- M4 卡在一个和代码无关的问题上：一直开着的旧 rapp-host 让新进程抓屏被 replayd 断开。先单独跑 `serve`、再跑旧写法，把范围缩到"新进程"，再看系统日志才找到原因。已记进 lessons.md。
- 没做的：GUI"启停"按钮本身（pkg 已验证装好并启动 LaunchAgent）、卸载脚本和覆盖重装、`--cm` 窗口上的按钮、跨 NAT 打洞、VPS 上的 relay、Windows 和 Linux 的服务，都留给用户实机验收。
