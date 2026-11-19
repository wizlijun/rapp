# rapp_rime

Local Flutter plugin (iOS/iPadOS only) that embeds librime with the 雾凇 (rime-ice) schema, so a hardware
keyboard can type Chinese in the input panel without the system IME. Design: `docs/superpowers/specs/2026-11-20-rapp-ios-rime-ime-design.md`.

## 目录

- `scripts/fetch.sh`: downloads and expands everything below (sha256-checked, idempotent). `scripts/build-ios.sh` runs it.
- `ios/rapp_rime/Package.swift`: SwiftPM targets `CRime` (C, headers only), `RappRimeKeys` (pure Swift key map), `rapp_rime` (plugin).
- `ios/rapp_rime/Frameworks/`: 10 static xcframeworks, linked as `.binaryTarget(path:)` (this worked; no `unsafeFlags` fallback needed). Git-ignored.
- `ios/rapp_rime/Sources/CRime/include/`: librime headers copied by fetch.sh. Git-ignored (`.keep` stays).
- `ios/rapp_rime/Sources/rapp_rime/RimeData/`: 雾凇 shared data plus OpenCC tables, bundled via `.copy("RimeData")`. Git-ignored. `rapp_rime_data_version` holds `<commit7>-<DATA_REV>`.
- `vendor/`: download cache and stamp. Git-ignored.

## 模拟器端到端（`tools/sim/`）

`simkey.m` 发真实的 HID 按键（退格、Esc、单独的 Shift、按住连发都能发），`hwkb.m` 打开模拟器的实体键盘；两者用 CoreSimulator/SimulatorKit 的私有接口，只做测试工具，不进 app。`sim.sh` 第一次用到时自己编：`clang -fobjc-arc -framework Foundation -o simkey simkey.m`（`hwkb` 同理）。

1. `scripts/build-ios.sh sim --install <udid>`
2. `tools/sim/sim.sh <udid> prep`：把系统简体拼音设成模拟器的第一个输入源、重启模拟器、在 app 的 `local/gui.json` 里打开「实体键盘用内置输入法」，再启动 app。app 没有读启动参数的办法，所以开关这样打开；如果设备已经有 id（prefs 在 `devices/<id>/`），就在模拟器的设置里**手动打开一次开关**，之后一直开着。
3. 手动：接入、打开一个会话、打开输入板（光标在里面，空的）。脚本不会点屏幕。
4. `tools/sim/sim.sh <udid> <label> builtin repeat compose`，截图在 `tools/sim/out/<label>/`。每个场景该看到什么写在 `sim.sh` 开头。

## 模拟器脚本

`tools/sim/sim.sh` 的用法和步骤见上一节「模拟器端到端」，各场景该看到什么写在脚本开头注释里，这里只记几点：

- 场景有 `prep`、`builtin`、`repeat`、`compose`。模拟器上没有会话，所以 `builtin`、`repeat`、`compose` 需要先手动接入并打开一个会话，`prep` 不需要。
- `simkey` 和 `hwkb` 的编译命令（`clang -fobjc-arc -framework Foundation -o simkey simkey.m`）不是从探查版照搬的，是这一版 `sim.sh` 自己用的；它们已被 git 忽略，改了 `.m` 文件会自动重编。
- 两者里写死了 Xcode 的路径 `/Applications/Xcode.app/...`（SimulatorKit 和开发者目录）。Xcode 装在别处或改了名，要自己改 `simkey.m` 和 `hwkb.m`。

## 真机检查（补充）

完整清单见设计文档 §7。这里补充模拟器跑不到的：

- 补发的顺序：会话画面上、输入板关着，**快速**打 `n i 空格 1`，输入板打开后显示「你1」（不是「1」，也不是「1你」）。
- 补发的退格：输入板里有「abc」，关上输入板，在会话画面上**快速**打 `n i 空格 ⌫` → 输入板里是「abc」；切到「英」再快速打 `h i ⌫` → 「abch」。

## 升级 librime

Edit `KIT_URL` and `KIT_SHA` in `scripts/fetch.sh` (LibrimeKit-iOS release `Frameworks.tgz`), and `DEPS_URL`/`DEPS_SHA` if the OpenCC tables change. Delete the stale file in `vendor/dl/`, rerun `fetch.sh`.

## 升级雾凇

Edit `ICE_COMMIT` and `ICE_SHA` (sha256 of the codeload tarball: `curl -L <url> | shasum -a 256`) and bump `DATA_REV` by one. Do not use the rolling `nightly` release.

## 版本和许可证

| 组件 | 版本 | 许可证 |
| --- | --- | --- |
| librime | 1.16.1 | BSD-3-Clause |
| boost | (bundled in LibrimeKit-iOS v0.2.2) | BSL-1.0 |
| glog | bundled | BSD-3-Clause |
| leveldb | bundled | BSD-3-Clause |
| marisa-trie | bundled | BSD-2-Clause / LGPL-2.1 |
| OpenCC | bundled | Apache-2.0 |
| yaml-cpp | bundled | MIT |
| 雾凇 rime-ice | 927e1cf | GPL-3.0 |

## 雾凇与公开分发

雾凇是 GPL-3.0，而 rapp 公开分发的二进制包含它的数据，二者的许可证存在冲突，需要在发布前处理。详见设计文档 §3：
`docs/superpowers/specs/2026-11-20-rapp-ios-rime-ime-design.md`。
