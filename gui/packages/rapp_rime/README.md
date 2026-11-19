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
