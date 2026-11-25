# rApp

**更多 Agent。一个 Pad。**

Agent 分布在不同机器，你的注意力，留在一处。
rApp 将远程 Mac 上的应用汇入一个工作台，让你在眼前这台电脑上查看、回复、指挥 Agent。

推荐使用 Omarchy 平板电脑。

[官网与下载](https://rapphub.com/?lang=zh) · [发布记录](https://github.com/wizlijun/rapp/releases) · [English](README.md)

## 安装

| 平台 | 安装方式 |
| --- | --- |
| macOS 14+ · Apple 芯片 | 下载并打开 `.pkg`。支持被控端和控制端。 |
| Omarchy / Arch · x86_64 | 下载 `.pkg.tar.zst`，运行 `sudo pacman -U ./rapp-omarchy-*.pkg.tar.zst`。可控制 Mac 应用和桌面，也可提供文本终端及端口共享。 |
| iPhone Duo · iOS / iPadOS | 已适配 iPhone Duo；iOS、iPadOS 版即将推出。 |

在被控 Mac 和控制端电脑上安装 rApp。为被控端授予屏幕录制、辅助功能权限，并保持不睡眠。远程 app 全部关闭后，被控 Mac 会自动锁屏，下次打开 app 时在控制端输入被控 Mac 的系统密码解锁（可在「本机」里关掉）；开机后的登录窗口和睡眠仍不支持。在 rApp 中添加该设备，即可打开应用。

中文等需要输入法的文字在控制端输入：输入板在本机组字后整段发送，被控端始终保持英文输入。想要最流畅的输入体验，推荐使用 [Fcitx5](https://github.com/fcitx/fcitx5) 输入法；在 macOS 上，候选词会直接显示在输入板下方，字体与正文一致。详见[输入板设计说明](docs/writing-panel.md)。

macOS Apple 芯片用户可下载配套的 [Fcitx5 for Sumi 0.5.0.15 安装包（.pkg）](https://github.com/wizlijun/rapp/releases/download/v0.10.7/Fcitx5-for-Sumi-0.5.0.15-arm64.pkg)。

跨网络连接可参考[自建中继说明](docker/relay/README.md)。E2E 中继要求两端均为 rApp 0.6+；Linux v0.5.2 使用旧连接方式。各平台分别选择对应的下载版本。

Linux v0.5.2 无法连接 macOS 0.8+ 被控端。当前 Linux 与 macOS 共用工作区版本号和应用协议 v14，请同步升级两端。若发布页还没有对应版本的 Linux 安装包，可从当前源码构建。

Linux 支持内嵌会话、拆分及合回原生窗口、独立 GTK 客户端，以及文本、图片和文件传输。Linux 现在可以作为整桌面被控端：其他同协议版本的 client 可通过现有局域网、直连或中继连接“桌面”，支持多屏、鼠标键盘和文本输入。支持 Omarchy/Hyprland、提供 wlr screencopy 与虚拟输入协议的 Wayland 合成器，以及 X11（文本输入需安装 `xdotool`）。GNOME/KDE Wayland 的 portal 后端、单应用共享、Linux host 的剪贴板/文件传输及自动输入解锁密码尚未实现；锁屏阻止采集时需在本机解锁。安装新版 Linux 包或运行 `scripts/build-linux.sh` 会包含 `rapp-host`；原有安装升级后需重启服务。运行 `rapp-host check --json` 可检查桌面是否可用。文本终端需要已安装的受支持终端、图形登录会话和 systemd 用户管理器。终端独立运行，重启 rApp 服务不会结束它。Linux 更新通过包管理器安装，或替换完整便携包。

## 编译

需要 Rust/Cargo，以及附带 Dart 3.12.1+ 的 Flutter。

```sh
git clone https://github.com/wizlijun/rapp.git
cd rapp
```

**macOS：** Apple 芯片、macOS 14+、Xcode。

```sh
RAPP_ALLOW_ADHOC=1 ./scripts/package-macos.sh
```

安装包输出到 `dist/`。本地构建允许 ad-hoc 签名；正式签名和公证选项见[打包脚本](scripts/package-macos.sh)。

**Omarchy / Arch：** 支持 SSE4.2 的 x86_64、Python 3.11+、GTK4 ≥ 4.12、GTK3、clang、cmake、ninja、pkgconf、libayatana-appindicator、libpulse，以及稳定版 Flutter ≥ 3.50.0。可用 `FLUTTER=/path/to/flutter/bin/flutter` 指定独立 SDK。旧 Linux 引擎存在 GTK/OpenGL 崩溃路径，上游 Flutter #192137 已修复；安装包通过 `FLUTTER-INFO.json` 和 `BUILD-INFO.json` 记录实际 SDK、引擎提交及引擎文件摘要。

```sh
./scripts/build-linux.sh
./gui/build/linux/x64/release/bundle/rapp
```

生成 Linux 安装包：在干净的工作区运行 `./scripts/package-linux.sh`，另需 makepkg、fakeroot、zstd。产物输出到 `dist/`。

Linux 0.14.13 在应用画面和文字终端支持本地按住说话：长按右 Alt 或语音按钮，松开发送、Esc 取消、Tab 编辑。首次使用下载约 142MB 的校验模型，录音不保存、不上传；识别语言跟随系统，需要 PulseAudio 或 PipeWire PulseAudio 服务。详见 [Linux 语音行为与验证边界](docs/superpowers/specs/2026-11-18-rapp-linux-voice-design.md)。

程序状态：用 `rapp-term run` 开的文本终端里，通过 OSC 7501 报告状态的 CLI，其状态（在干活、等确认、在提问、出错）显示在会话列表里，等你处理的会话进“需要你”。rApp 只读报告、答 CLI 的探测，从不往 CLI 里输入。被控端上需要 Claude Code ≥ 2.1.295、Codex ≥ 0.163.0 或 agy ≥ 1.4.0。在 `local/term.json` 里写 `"programStatus": false` 可对新开的会话关掉。

多个文字终端：在文字终端里按 ⌘T（非 macOS 为 Ctrl+Shift+T），在同一目录、同一个 shell 里新开一个终端，被控 Mac 上是 Terminal 的新标签页，标题为 `<目录> · <程序>`。⌘W 或会话菜单的「结束终端」会结束这个终端（有程序在跑时先确认），标签页随之自动关闭；「关闭」只是不再查看，终端继续在被控端运行。

## 许可证

[GNU GPL v3](LICENSE)。

## 致谢

感谢为 rApp 提供设计参考或技术支持的开源项目：

- [RustDesk](https://github.com/rustdesk/rustdesk)：设备连接与自建中继的设计参考。
- [Sunshine](https://github.com/SunshineStream/Sunshine)：串流技术研究参考。
- [gascity](https://github.com/gastownhall/gascity)：OSC 7501 探测回答和流式扫描器移植自它的程序状态中继，并带上它录下的测试录制文件（MIT，Copyright (c) 2026 Gas City Contributors）。
- [zellij](https://github.com/zellij-org/zellij)：程序状态报告的解析、限制常量和记录表移植自它的 OSC 7501 实现（MIT，Copyright (c) 2020 Zellij contributors）。
- [hurryvc](https://github.com/swigger/hurryvc)：macOS、Windows 上文本终端（伪终端加屏幕状态同步）的设计参考。
- [Fcitx5](https://github.com/fcitx/fcitx5)：输入法，带来输入板流畅的输入体验。
- [Flutter](https://github.com/flutter/flutter)、[GTK](https://www.gtk.org/)：用户界面。
- [Tokio](https://github.com/tokio-rs/tokio)、[Quinn](https://github.com/quinn-rs/quinn)、[rustls](https://github.com/rustls/rustls)：网络基础。
