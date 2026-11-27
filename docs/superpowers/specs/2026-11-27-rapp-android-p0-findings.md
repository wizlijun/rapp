# rApp 安卓平板 P0 探查结果

规格：`2026-11-27-rapp-android-tablet-design.md` §14.1。计划：`../plans/2026-11-27-rapp-android-p0-probe.md`。做完一项填一项。

## 工具和镜像

| 东西 | 版本 |
|---|---|
| Flutter | 3.44.1（framework 924134a44c，engine c416acfeb8） |
| compileSdk / targetSdk | Flutter 默认（36）；minSdk 34；只出 arm64-v8a；applicationId `com.rapphub.rapp` |
| NDK | 28.2.13676358 |
| build-tools | 36.0.0（AGP 自己装的）；机器上原有 35.0.0 |
| CMake | 3.22.1（AGP 自己装的，空壳也会装） |
| platform-tools（adb） | 37.0.1 |
| AGP | 9.0.1 |
| Gradle | 9.1.0（wrapper，`-all` 发行包） |
| Kotlin（Gradle 插件） | 2.3.20 |
| 构建用 JDK | Homebrew openjdk@21 21.0.13.1（只在命令里设 `JAVA_HOME`） |
| 机器默认 JDK | Homebrew OpenJDK 27（`sdkmanager` 能用；Gradle 9.1 不认，见第 1 节） |
| 模拟器 emulator | 37.3.10.0 |
| 系统镜像 34 | `system-images;android-34;default;arm64-v8a`，`source.properties` 里 Pkg.Revision=2（`sdkmanager --list_installed` 显示的版本号是 4） |
| 系统镜像 36 | `system-images;android-36;google_apis;arm64-v8a`，Pkg.Revision=7 |
| Rust | rustc 1.99.1；target `aarch64-linux-android` |
| cargo-ndk | 4.1.2 |

## 总表

| # | 看什么 | 结论（过 / 没过 / 部分 / 没测） | 规格要不要改 | 日期 |
|---|---|---|---|---|
| 1 | 工具和空壳 | 过（两个模拟器都能装、能启动、截图有 `rApp P0 shell`；36 上第一次截图撞上 System UI 无响应弹框，再试后正常） | 不用 | 2026-11-27 |

## 1 工具和空壳

日期 2026-11-27。

**模拟器。** `pixel_tablet` 设备存在，直接用，没有替换。两个 AVD：`rapp-p0-34`（AOSP 14，不带 Google）、`rapp-p0-36`（Android 16，带 Google API）。`config.ini` 里改成 `hw.keyboard=yes`、`hw.ramSize=4096`（avdmanager 默认是 `no` 和 `2G`）。两个都是 2560x1600、横屏起来：`adb shell wm size` 都是 `Physical size: 2560x1600`；`ro.build.version.sdk` 分别是 34、36（release 14、16）；abi `arm64-v8a`。34 上没有任何带 google 的包；36 上有 `com.google.android.gms`。两个镜像都是 arm64，在 Apple 芯片上能起来（34 上 `sys.boot_completed` 约 22 秒）。

**空壳。** `gui/lib/main_p0_shell.dart` 只显示 `rApp P0 shell` 和 `Platform.operatingSystemVersion`。`flutter build apk --debug -t lib/main_p0_shell.dart --target-platform android-arm64` 出 81 MB 的调试 APK。两个模拟器各装一次、用 `am start -n com.rapphub.rapp/.MainActivity` 启动、`screencap` 截图（图在 scratchpad，不进仓库）：
- API 34：白底，中间大字 `rApp P0 shell`，下面一行小字 `sdk_phone64_arm64-userdebug 14 UE1A.230829.036.A1 11228894 test-keys`；底部是平板的任务栏。`logcat -d -s flutter AndroidRuntime` 里只有两行 flutter 的 Impeller（OpenGLES）和 Dart VM service 信息，没有 FATAL。
- API 36：同样的页面，小字 `sdk_gphone64_arm64-userdebug 16 BE2A.250530.026.F3 13894323 dev-keys`；底部是手势条。`logcat` 没有 FATAL。**第一次截图（冷启动后立刻装、启动）截到的是系统弹的「System UI isn't responding」对话框**，不是我们的应用；点 Wait、等 20 秒后再启动（应用已在前台），第二张截图才是上面这个正常页面。弹框是模拟器刚起来时 System UI 太忙，不是应用崩溃（`AndroidRuntime` 里没有 FATAL），但以后在 36 上装包前最好多等一会儿。
- 两台模拟器没有同时开，一台关掉（`adb emu kill`）再开另一台。

**这一步碰到的坑（P1 的人会再碰到）：**
1. **`flutter create` 会改写 `gui/.metadata`**：它把原来的 linux/macos/windows 三条迁移记录丢了，只留 android。我把原文件还原后手工加了一条 android 记录。它还会生成 `gui/test/widget_test.dart`（引用不存在的 `MyApp`），已删除。它也会改 `gui/pubspec.lock`，已还原。
2. **JDK。** `sdkmanager`/`avdmanager` 在 JDK 27 上正常。Gradle 9.1.0 不认 JDK 27（`flutter create` 末尾的提示就是这个），所以装了 `brew install openjdk@21`，之后所有 `flutter build` 都在命令前设 `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`。没有动 Flutter 全局配置。`brew install openjdk@21` 顺带升级了 8 个依赖库（brotli、fontconfig、glib、harfbuzz、jpeg-turbo、lz4、zstd、little-cms2）。
3. **下载非常慢，要绕代理。** 这台 Mac 的 TUN + fake-ip 代理让 `dl.google.com` 只有约 1–160 KB/s，Gradle 的 100+ MB 下载一直超时；直连物理网卡（DoH 解析 + 绑定 en0）能到 10–17 MB/s。做法：在 scratchpad 里起一个只监听 127.0.0.1 的小 CONNECT 代理（Python，DoH 解析真实 IP，socket 绑 en0），然后 `sdkmanager --proxy=http --proxy_host=127.0.0.1 --proxy_port=18123`，Gradle 用 `JAVA_TOOL_OPTIONS="-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=18123 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=18123 -Dhttp.nonProxyHosts=localhost|127.0.0.1"`。Maven Central（Cloudflare）走这条路也只有约 150 KB/s，首次 `flutter build apk` 总共用了约 40 分钟（含一次因代理空闲超时设置过短而断流重来）。依赖缓存好之后再编会快很多。`sdkmanager` 下载的是 SDK 本体 + 两个镜像 + NDK，约 11 GB 在 `~/Library/Android/sdk`。
4. **Flutter 生成的 `.gitignore` 忽略了 `gradlew`、`gradlew.bat`、`gradle-wrapper.jar`**；它们每次 `flutter build` 会重新生成，不进仓库。
5. AGP 在第一次构建时自己装了 build-tools 36.0.0 和 CMake 3.22.1，不用手动装。

**磁盘：** Android SDK 11 GB（含两个镜像、NDK），两个 AVD 1.6 GB，`~/.gradle` 2.8 GB，openjdk@21 331 MB；Rust target 和 cargo-ndk 很小。

**结论：过。** 空壳在 API 34（AOSP 14）和 API 36（Google APIs）两个 2560x1600 平板模拟器上都能装、能启动、能显示，没有崩溃。
## 2 `.so`
## 3 进程内 hub 和网络
## 4 进程内会话
## 5 键盘和触控板
## 6 语音
## 7 自己装自己
## 8 数字
## 探查里打的补丁（P1 的输入）

| 文件和位置 | 改了什么 | 为什么 | P1 里它属于哪个接口 |
|---|---|---|---|

## 规格要改的地方
