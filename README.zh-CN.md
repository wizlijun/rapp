# rapp

**更多 Agent。一个 Pad。**

Agent 分布在不同机器，你的注意力，留在一处。
rapp 将远程 Mac 上的应用汇入一个工作台，让你在眼前这台电脑上查看、回复、指挥 Agent。

推荐使用 Omarchy 平板电脑。

[官网与下载](https://rapphub.com/?lang=zh) · [发布记录](https://github.com/wizlijun/rapp/releases) · [English](README.md)

## 安装

| 平台 | 安装方式 |
| --- | --- |
| macOS 14+ · Apple 芯片 | 下载并打开 `.pkg`。支持被控端和控制端。 |
| Omarchy / Arch · x86_64 | 下载 `.pkg.tar.zst`，运行 `sudo pacman -U ./rapp-omarchy-*.pkg.tar.zst`。仅支持控制端。 |

在被控 Mac 和控制端电脑上安装 rapp。为被控端授予屏幕录制、辅助功能权限，并保持唤醒、解锁。在 rapp 中添加该设备，即可打开应用。

跨网络连接可参考[自建中继说明](docker/relay/README.md)。E2E 中继要求两端均为 rapp 0.6+；Linux v0.5.2 使用旧连接方式。各平台分别选择对应的下载版本。

Linux v0.5.2 无法连接 macOS 0.8+ 被控端。在兼容的安装包发布前，请从当前源码构建 Linux 客户端，并同步升级两端。

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

**Omarchy / Arch：** x86_64、Python 3.11+、GTK4 ≥ 4.12、GTK3、clang、cmake、ninja、pkgconf、libayatana-appindicator。

```sh
./scripts/build-linux.sh
./gui/build/linux/x64/release/bundle/rapp
```

生成 Linux 安装包：在干净的工作区运行 `./scripts/package-linux.sh`，另需 makepkg、fakeroot、zstd。产物输出到 `dist/`。

## 许可证

[GNU GPL v3](LICENSE)。

## 致谢

感谢为 rapp 提供设计参考或技术支持的开源项目：

- [RustDesk](https://github.com/rustdesk/rustdesk)：设备连接与自建中继的设计参考。
- [Sunshine](https://github.com/SunshineStream/Sunshine)：串流技术研究参考。
- [Flutter](https://github.com/flutter/flutter)、[GTK](https://www.gtk.org/)：用户界面。
- [Tokio](https://github.com/tokio-rs/tokio)、[Quinn](https://github.com/quinn-rs/quinn)、[rustls](https://github.com/rustls/rustls)：网络基础。
