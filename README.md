# rapp

把 A 电脑（macOS）上某个 app 的窗口画面，用低位深按块编码串流到 B 电脑（macOS）的一个窗口里，
并把 B 端的鼠标、文字和窗口缩放送回 A。app 始终在 A 上真实运行。

这是一个最小原型。设计见 [docs/superpowers/specs/2026-11-10-rapp-design.md](docs/superpowers/specs/2026-11-10-rapp-design.md)。

## 运行

需要 macOS 14 或更高版本，以及 Xcode 或 Xcode 命令行工具（提供 `swift`）。

A 上（被控端）：

```
swift run -c release rapp-host --token <口令> [--port 47800]
```

B 上（操作端）：

```
swift run -c release rapp-client "rapp://<A的地址>[:端口]/<bundle-id>?token=<口令>&mode=gray4&fps=15"
```

例：`swift run -c release rapp-client "rapp://mac-a.local/com.apple.TextEdit?token=abc"`

| 参数 | 取值 | 说明 |
|---|---|---|
| `mode` | `gray4`（默认）、`color8`、`color16`、`duogray`、`duocolor` | 16 级灰阶、256 色、RGB565；双色·灰度、双色·彩色（见下） |
| `fps` | `15`（默认）、`5` | 每秒最多采集几帧 |

`mode` 和 `fps` 只是开始时的取值，连上以后可以在客户端里随时改（见下面"使用"）。
旧的 `scale` 参数已去掉，写了也会被忽略：采集密度现在跟着 B 上画面的实际显示大小走。

双色档位把画面切成 16×16 的小块。每块取两种基色：最暗的那一小撮像素的颜色（笔画）和最亮的那一小撮像素的颜色（背景）。
其余像素按亮度落到这两色之间的四级上，所以文字的抗锯齿边缘会保留一两级过渡，不会断笔、也不会在字周围出灰块。
渐变和照片会变成色块。这是最省流的档位，适合看文字。

协议版本是 5（在 v4 多窗口的基础上加了剪贴板和编辑器，新增消息 19–25，见 `docs/superpowers/specs/2026-11-11-rapp-clipboard-composer-design.md`）。
Mac 两端都要用这一版：v4 的客户端或主机要先升级，连新的会收到 `protocol version mismatch` 的提示。
Omarchy 的 Rust/GTK 客户端已支持 v4/v5（见下文）；Windows/Omarchy 主机端不在本仓库当前实现中。

一定要带 `-c release`。未优化的构建处理一帧 Retina 画面要 1 秒左右。

查一个 app 的 bundle-id：`osascript -e 'id of app "文本编辑"'`。

## 使用

- 多窗口：A 上 app 的每个窗口在 B 上各是一个窗口，A 开新窗口、关窗口，B 跟着开关。
  - 有框窗口（文档窗口、对话框、字体面板这类浮动面板）有 B 自己的标题栏，可以挪；在 B 上挪它，A 上的窗口不动
    （被挡住时用菜单把 A 的窗口挪到左上角）；在 B 上点它，A 上也把它提到最前。
  - 关掉 B 上的任一窗口 = 断开这个会话（和 ⌘Q 一样），A 上的窗口和 app 都不动；⌘W 照常发给 A 的 app。
  - 只切掉 A 窗口的系统标题栏；带工具栏的窗口、自绘标题栏的窗口（Chrome、Electron 应用等）整窗传过来，
    画面里会有 A 自己的红绿灯，点它等于在 A 上点。
  - 弹出窗口（右键菜单、菜单栏下拉菜单、弹出按钮的列表、提示条、sheet、popover）在 B 上是无边框的窗口，
    挂在父窗口上、位置跟 A 上一致，B 上不能单独挪。
  - 整个 app 是一条流：A 上两个窗口叠在一起时，下面那个窗口被盖住的部分画的是上面那个窗口。
    B 上窗口的相对位置和 A 一致，所以正常情况下被盖住的那块在 B 上也被盖住。
  - 只显示一块屏：会话开始时 app 最大的普通窗口所在的那块。
- 菜单栏：B 的菜单栏是"rapp-client"菜单加上 A 上 app 的菜单，跟着 A 变（切换窗口后 0.5 秒、选完一项后 1 秒重读）。
  灰掉、打勾和 A 一致，快捷键显示在标题右边。选一项就在 A 上按那一项。
  这些菜单项本身不带快捷键：在 B 上按快捷键，照下面的规则作为按键发给 A。
- 画面区域：点击、双击、拖拽、右键、滚轮直接作用到 A 上的窗口。
- 底部编辑器：用 B 的输入法打字，可以多行，回车发送，⇧回车换行；输入法正在组字时回车照输入法处理。Esc 清空。
  - ⌘V 粘贴：短文字直接插入；800 字以上或 10 行以上的长文字、图片、文件、其他数据会变成一个小标签（块），如 `[贴入文字 #1 +243 行]`、`[图片 #1]`，可以整块删掉。
  - 「📎 附件」选文件（可多选），或把文件拖进编辑器，每个文件一个块。文件夹不收；文件直接从磁盘流式上传，没有大小上限。图片、其他数据这类放在内存里的块单个最多 256 MB。
  - 点「发送 ⏎」（或回车）：文字和块按顺序一个个贴到 A 上当前的目标 app；大的先上传，传输条显示进度。
    全部成功后编辑器清空，A 的剪贴板恢复成发送前的内容。中途失败会停下，已贴的去掉，剩下的保留，再点发送接着来（已上传的部分续传）。
  - 传输条上的「取消」停掉当前的上传或下载，已收到的部分留着，下次续传。
- 复制：点编辑器旁的「复制」，在 A 上按一次 ⌘C，A 上复制到的东西进下面的历史（文字同时写进 B 的剪贴板）。
  A 上没复制到东西时按钮上显示「A 上没有复制到东西」。
- A 的剪贴板历史：A 上复制的任何东西都进历史，在应用菜单或流量标签右键菜单的「A 的剪贴板」里，最新的在最上面，每个连接（每个 rapp-client 进程、每个打开的 app）一份，最多 20 条，会话结束就清空。
  - 点一项：文字直接写进 B 的剪贴板；图片、数据下载后写进 B 的剪贴板；文件下载到 B 的 `~/Downloads/rapp/` 再写进 B 的剪贴板，重名加序号，中断后再点一次续传。
  - 按住 ⌥ 点：不写剪贴板，把这一项插进编辑器（文字直接插，其他变成块）。
  - 复制文件夹暂不支持，历史里是灰色的「文件夹（不支持）」。
  - 上传到 A 的文件在 A 的 `~/Downloads/rapp/`，不自动清理。
- 编辑器为空时：回车、删除、Tab、Esc、方向键，以及带 ⌘ 的组合键，直接发给 A 上的 app。
- ⌘Q 始终只退出这个客户端。
- 缩放：整个客户端一个值，在"rapp-client"菜单的"缩放"里选 50%–200%，默认 100%。所有窗口一起缩放；
  画面缩小后，A 端按 B 上实际显示的像素采集，流量随之下降。（v3 的"拖角只缩 B"没有了：多窗口时弹出窗口会对不上父窗口。）
- 改变 B 上窗口的大小（拖边、拖角、缩放按钮），松手后 A 的窗口按当前缩放换算改成同样大小。
  A 上的 app 不接受请求的尺寸时，画面在客户端窗口里留黑边，客户端窗口不会被再改一次。
- 客户端标题栏显示 A 上那个窗口的标题，随 A 变化。画面不含 A 窗口的标题栏，四角是方的；
  A 标题栏里的按钮（关闭、缩放、标题栏里的工具按钮）在 B 上点不到。
- 标题栏右上角每秒显示一次收到的流量，单位 `KB/s`，满 1000 KB 换成 `MB/s`（1 KB = 1024 字节），
  画面静止时是 `0 KB/s`。
- 在流量文字上点右键（或按住 Control 点击），可以随时切换，当前选择打勾：
  - **最省流**：一次选好双色·灰度 + 自适应 + 1 fps；**最清晰**：一次选好高彩 + 原画 + 15 fps
    （这两项本身不打勾，打勾的是下面三组）；
  - 档位：双色·灰度（文本优化）、双色·彩色、高彩（图像优化）。灰度 16 级和 256 色不在菜单里，
    地址里写 `mode=gray4` / `mode=color8` 仍然可用；
  - 采集密度：省流 1x（按 B 的点，文字略软）、自适应（按 B 的物理像素，随缩放变，默认）、
    原画（按 A 自己的像素，不管 B 上缩得多小）；
  - 帧率：1 fps、5 fps、15 fps、30 fps（看视频）。画面不变时都不发数据；30 fps 全屏动起来的流量约是 15 fps 的两倍，
    适合局域网；1 fps 只对一直在变的内容（动画、闪烁的光标）更省，
    代价是打字和点击的回显最多慢 1 秒。

  主机打印 `stream -> <档位>, <n> fps, density <采集密度>`。客户端窗口拖到倍率不同的屏幕上时，采集密度自动重算。
- 主机端每秒打印一行 `[stats] <kbps> kbps <fps> fps <宽>x<高>`，画面静止时是 0。

## Omarchy / Linux 客户端

在 [GitHub Release](https://github.com/wizlijun/rapp/releases/tag/v0.4.1) 下载
`rapp-omarchy-0.4.1-1-x86_64.pkg.tar.zst`，运行 `sudo pacman -U ./rapp-omarchy-0.4.1-1-x86_64.pkg.tar.zst`，
然后从应用启动器打开 rapp。也提供 `rapp-0.4.1-omarchy-x86_64.tar.gz` 便携包，解压后运行 `./rapp`。
安装包面向 Omarchy / Arch x86_64；便携包的依赖与用法见包内 `README-LINUX.txt`。
发布包可从干净的源码提交运行 `./scripts/package-linux.sh` 重建，包内记录确切源码提交。

现在可以在 Omarchy 上构建 **Rust + GTK4 的 `rapp-client`**，连接 macOS v4/v5 主机（默认 v5；v4 地址加 `protocol=4`）。
Rust 网络后台继续复用；`rust/client-core` 实现可跨平台复用的协议和解码，
`rust/client-gtk` 负责 Linux 显示和输入。Linux **被控端**仍未实现。

0.4.1 的 Linux 管理界面已支持**内嵌远程画面**：从设备列表打开 app 后，画面直接显示在主窗口舞台中。
`rapp-session` 无窗口进程复用 Rust 解码器，通过有背压的二进制管道将 BGRA 画面交给 Flutter；
支持窗口标签、弹窗、点击/拖动/滚动、键盘、画质/帧率/密度、远程菜单和文字输入区。
点击画面后键盘发给 Mac（Ctrl 映射为 ⌘，Super 留给 Linux，F11 控制本地全屏）；
中文可在“输入”区通过本地输入法组句后发送。退出会话或管理界面会关闭解码进程与连接。
目前内嵌会话的“分离/放回”和图片/文件附件尚未实现，分离按钮禁用，附件操作会说明限制。
支持断线保留最后画面、重连换帧和空闲状态。
像素更新独立重绘；worker 独立输出线程和 Flutter 都只保留最新待显示帧，避免慢速显示导致旧帧排队。
断线停止 worker，结束会话时释放保留画面。
独立 GTK `rapp-client` 仍可单独使用；下面的应用画布和独立客户端菜单说明适用于它。

构建依赖：Rust、GTK4 ≥ 4.12、pkgconf。连同 Flutter 管理界面打包还需要 Flutter
（Dart ≥ 3.12.1）、clang、cmake、ninja、gtk3、libayatana-appindicator。

```bash
# 只编译远程窗口客户端
cargo build --manifest-path rust/Cargo.toml --release --locked -p rapp-client-gtk
./rust/target/release/rapp-client  # 打开地址/口令输入窗口

# 编译管理界面、后台和客户端，放进同一个 bundle
./scripts/build-linux.sh
./gui/build/linux/x64/release/bundle/rapp

# 单元测试；图形会话内还可运行独立 Python 主机夹具测试
cargo test --manifest-path rust/Cargo.toml -p rapp-client-core
python3 scripts/test-linux-client.py
# 额外通过 Xwayland + xdotool 验证真实键鼠输入（会短暂聚焦测试窗口）
python3 scripts/test-linux-client.py --input
```

管理界面打开应用时会自动调用同目录的 `rapp-session`，把画面显示在舞台中。也可以直接连接 host 的 TCP 端口：
`rapp-client 'rapp://主机:47800/com.apple.TextEdit?mode=color16' --token-env RAPP_TOKEN`。
地址中的 app 标识和口令属于 host；管理服务的 `ID@IP` / 密码应在管理界面添加主机，不能直接填进这个 TCP 地址。

首版采用**一个应用画布**：多窗口、菜单、弹窗按远端位置一起显示，按窗口表从前到后命中鼠标。
菜单按 Mac 最新客户端（`origin/feat/clipboard`）对齐：左上角 `rapp-client` 菜单和标题栏流量数字
的点击/右键菜单共用流设置。两项预设是“最省流（双色·灰度 + 自适应 + 1 fps）”和
“最清晰（高彩 + 原画 + 15 fps）”；其后依次是三种常用画质、三档采集密度、1/5/15/30 fps。
预设本身不打勾，三组当前值各自打勾；旧 gray4 / color8 地址仍可使用，但不占用菜单。

客户端菜单提供 50%–200% 的实际点数缩放、适应窗口、把当前 A 窗口移到左上角（避开已有窗口，
每层错开 28 点）；缩放超过本地视口时使用滚动条。缩放只改变本地画布，不自动改 A 的尺寸。
采集密度与 Mac 相同：省流 = 缩放、自适应 = 缩放 × 本地屏幕倍率、原画请求 8 再由 A 限制到原生像素；
密度相对变化超过 1% 才重新设置采集。右上角流量静止时显示 `0 KB/s`。

流压缩与 Mac 共用现有线上格式：64×64 瓦片增量，按瓦片使用纯色、1/2/4-bit 调色板、16×16
双色子块或原始样本，再用带持续字典的 zlib `Z_SYNC_FLUSH` 压缩。完整帧重置字典，增量帧延续字典。
双色档的量化由 Mac 主机完成（两种基色及中间过渡色）；Linux 负责正确解码，设置切换通过 SetStream
让主机换编码，客户端没有另开一种不兼容的压缩算法。静止画面不发送新帧。

支持远程菜单、点击/拖动/滚动、本地输入法组句后回车发送，输入框旁有“复制”和“发送”。
空输入框的 Ctrl 快捷键作为 Mac 的 ⌘ 快捷键发送；Ctrl+V 始终粘贴到本地输入框，回车再发出。
Ctrl+Q 和本地关闭按钮只断开连接，Super 留给 Hyprland。v5 的“A 的剪贴板”菜单保留最近 20 项记录，
点击完整文字可重新复制到本地；不支持下载的图片/文件和截断内容明确禁用。远端标题栏和边框仍可通过画面操作。
尚未把每个远端窗口拆成独立的 Linux 窗口，v5 支持把远端复制的文字同步到本地剪贴板；图片/文件传输和 Linux 主机端尚未实现。
与不支持的协议版本连接时会明确报告版本不匹配。

## A 上的前提

- 保持登录、不锁屏、显示器开着，目标窗口没有最小化。
- 当前输入源设为英文键盘，避免 A 的输入法拦截发过来的按键。
- 运行主机的终端 app 在"系统设置 > 隐私与安全性"里已获得"屏幕录制"和"辅助功能"授权。
  首次运行会提示，授权后重启终端再运行。
- 第一次开始采集时，A 上可能弹出确认窗口询问是否允许录制，要点"允许"。不点的话，客户端 10 秒后
  会收到 `timed out asking macOS for windows ...` 的提示。
- 目标 app 在运行但没有窗口时（比如窗口被关掉了），主机会请它重新打开一个窗口。
- 独占使用：远程操作会移动 A 的真实光标，并把目标 app 切到最前。

## 安全

**连接不加密，只校验口令。** 主机在所有网络接口上监听。请只在可信的局域网里使用，
或者通过 Tailscale 连接（Tailscale 自带加密）。不要把端口暴露到公网。

## 在同一台 Mac 上试

A 和 B 可以是同一台机器，地址填 `127.0.0.1`。此时每次点击或发送文字，焦点都会跳到目标 app，
光标也会跳到目标窗口上；要继续操作需要再点回客户端窗口。这只适合验证功能，正常使用需要两台 Mac。

## 开发

```
./scripts/check.sh      # 构建（release）并运行单元测试，日志写入 .build-logs/check.log
```

- `Sources/RappCore`：像素量化、按块编解码、消息格式、几何换算。纯计算，有单元测试，Linux 上也能编译和测试。
- `Sources/rapp-host`：ScreenCaptureKit 采集、找窗口建窗口表、CGEvent 注入、辅助功能接口挪窗口和改大小、读菜单栏和按菜单项。
- `Sources/rapp-client`：每个 A 窗口一个 AppKit 窗口（弹出窗口是挂在父窗口上的面板）、镜像菜单栏、输入条。

```
./scripts/package-macos.sh   # 生成 dist/rapp-0.3.0.pkg、dist/rapp.dmg、dist/rapp-relay-x86_64-linux（静态）和 dist/rapp-relay.service
python3 scripts/e2e-local.py <工作目录>   # 本机端到端：relay + service + hub，lan、relay 和无 relay 的 id@ip 各开一次 Safari
```

安装：双击 `rapp-0.3.0.pkg`（或 `sudo installer -pkg rapp-0.3.0.pkg -target /`）。它把 rapp.app 装进 /Applications，给当前登录用户写 `~/Library/LaunchAgents/com.rapp.service.plist`（和 GUI"启动"写的一样，开机自启、崩溃重启），启动服务并打开 GUI。首次运行要给 rapp 屏幕录制和辅助功能权限。包默认是 ad-hoc 签名，没有公证：从别的机器 AirDrop 或下载过来的，要在 Finder 里右键 → 打开，或到"隐私与安全性"里点"仍要打开"。钥匙串里有 "Developer ID Application" / "Developer ID Installer" 证书时，打包脚本自动用它们签 app（hardened runtime + 时间戳）和 pkg；再执行过 `xcrun notarytool store-credentials rapp-notary --apple-id <Apple ID> --team-id <Team ID>`，就会顺带公证并 staple，别的 Mac 双击即可安装。也可以用 `RAPP_SIGN_APP` / `RAPP_SIGN_PKG`（证书 SHA-1）/ `RAPP_NOTARY_PROFILE` 指定。只有 arm64。

卸载：`scripts/uninstall-macos.sh`（停服务、删 plist 和 /Applications/rapp.app，会要一次 sudo；保留 `~/Library/Application Support/rapp` 里的 ID、密码和主机列表）。

没有 relay 也能用：服务首次启动自己生成 9 位 ID。relay 没连上时，GUI"本机"里的 ID 显示成 `ID@IP`，本机每个 IP 一行（例如 Wi-Fi 一个、Tailscale 一个）。在另一台机器的"添加主机"里填其中一个 `ID@IP` 和密码，就直接连过去，不经过 relay；只接受私有网段（含 Tailscale）的来源。之后配了 relay、ID 不变，已加的主机照样能用。

relay 部署到 VPS 的步骤写在 `scripts/rapp-relay.service` 开头的注释里，只需要开放 UDP 21116。

## 实测码率

**整帧大小**：静止画面只在开始和变化时发送，下表是一帧完整画面压缩后的字节数，
用实际编码器对两张截图算出（A 是 Retina 屏）。"缩一半"指拖角把画面缩到一半。

| 画面 | 采集 | gray4 | color8 | color16 | duogray | duocolor |
|---|---|---|---|---|---|---|
| 文本编辑（586×354 点） | 自适应（2x） | 7.1 KB | 8.7 KB | 14.2 KB | 3.0 KB | 3.4 KB |
| | 省流 1x | 3.7 KB | 5.0 KB | 8.3 KB | 1.5 KB | 1.7 KB |
| | 缩一半 + 省流 1x | 1.4 KB | 2.0 KB | 3.6 KB | 0.6 KB | 0.7 KB |
| Safari 网页（876×622 点） | 自适应（2x） | 43.7 KB | 58.9 KB | 95.9 KB | 17.6 KB | 19.8 KB |
| | 省流 1x | 21.3 KB | 30.9 KB | 58.8 KB | 7.5 KB | 8.5 KB |
| | 缩一半 + 省流 1x | 8.2 KB | 12.1 KB | 23.8 KB | 2.8 KB | 3.3 KB |

同样大小下，双色·灰度大约是 gray4 的 40%、color16 的 20%。

注意：上表的双色两列是旧的纯双色算法测出来的。现在为了文字边缘清晰改成"两种基色 + 两级过渡"，
双色档的整帧大约变为原来的 2 倍多。用一张合成的中英文文字页（460×250 点，从 2x 缩放到采集密度）实测：

| 采集密度 | gray4 | duogray 旧 → 新 | duocolor 旧 → 新 |
|---|---|---|---|
| 2x | 23.8 KB | 8.7 → 16.5 KB | 9.6 → 19.0 KB |
| 1x | 11.1 KB | 3.6 → 8.2 KB | 4.0 → 11.3 KB |
| 0.5x | 3.7 KB | 1.3 → 3.0 KB | 1.4 → 4.3 KB |

**持续画面变化**（Safari 播放直播视频，主机每秒打印的码率，同一台 Mac 上）：

| 设置 | 采集像素 | 码率 |
|---|---|---|
| color16、30 fps、自适应（B 站视频，视频只占窗口一部分） | 1586×1342 | 约 2.9 MB/s，实测 28–30 fps |
| color16、15 fps、自适应 | 1554×1228 | 约 14.7 MB/s |
| color16、5 fps、自适应 | 1554×1228 | 约 1.9 MB/s |
| duogray、5 fps，拖角缩小到约 0.3 倍 | 491×388 | 约 24 KB/s |
| duogray、5 fps，A 窗口加宽加高后拖角缩小到约 0.12 倍 | 469×226 | 约 12 KB/s |

视频是最坏情况。打字、滚动之类只有局部变化，码率远低于这些数字。

## 原型不做的事

加密和配对、滚动检测、视频类内容的专门编码、音频、剪贴板和拖放、使用 A 端输入法、自动重连、
Developer ID 签名和公证；多窗口这一轮也不做：别的屏上的窗口、调度中心空间、每个窗口单独一条流。
