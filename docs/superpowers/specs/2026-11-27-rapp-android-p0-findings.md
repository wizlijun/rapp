# rApp 安卓平板 P0 探查结果

规格：`2026-11-27-rapp-android-tablet-design.md` §14.1。计划：`../plans/2026-11-27-rapp-android-p0-probe.md`。日期 2026-11-27，八项都有结论。

三个目标：模拟器 34（AOSP 14）、模拟器 36（google_apis 16）、平板（实机，HONOR ROD2-W09，Android 16，MagicOS 10）。证据文件（`p0/*.txt`、截图）都在 scratchpad，不进仓库，探查结束时删掉；截图只用文字说明。

探查结束时：探查包从两个模拟器和平板上都卸掉（身份密钥和 relay 密钥随之删除）；拷出来的 relay 配置删掉；平板上唯一临时改过的设置（充电时保持唤醒）改回原值。所以下面所有「留给实机」「等用户」的项，都要等 P1 的第一个包装上以后再做，不在探查包上做。

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
| AVD | `rapp-p0-34`、`rapp-p0-36`：`pixel_tablet`，2560x1600，`hw.keyboard=yes`，`hw.ramSize=4096` |
| Gradle 设置 | `gui/android/gradle.properties` 里有 Flutter 模板加的 `android.newDsl=false`、`android.builtInKotlin=false`（AGP 9 的新 DSL 和内置 Kotlin 都关着）；P1 建工程时照留，升 AGP 时再看 |

**磁盘（探查结束时）：**
- Android SDK（`~/Library/Android/sdk`）11 GB：系统镜像 5.9、NDK 2.8、emulator 1.2、build-tools 0.37、platforms 0.26、cmdline-tools 0.16、cmake 0.09（GB）。
- 两个 AVD（`~/.android/avd`）11 GB。
- `~/.gradle` 3.3 GB。
- openjdk@21 约 331 MB；Rust 的安卓 target 和 cargo-ndk 很小。

工具和两个 AVD 都留着，给 P1 用。

## 总表

| # | 看什么 | 结论 | 没过的部分：走规格哪条退路，或留给实机哪一条 | 规格 |
|---|---|---|---|---|
| 1 | 工具和空壳 | **过**。两个模拟器都能装、能启动，截图里是 `rApp P0 shell`。36 上第一次截图撞上「System UI isn't responding」弹框，等一会儿再试正常 | — | §4.5 已改成装完的样子 |
| 2 | `.so` | **过**。九个名字都导出；四个 `LOAD` 段都是 `0x4000`；11.3 MB，strip 后 7.5 MB；依赖全部直接编过 | — | §6.2 已改：不用 `#[used] static`；闸的顺序和忘了 ack 的后果；hub-ffi 自己包 `catch_unwind` |
| 3 | 进程内 hub 和网络 | **过**。两个模拟器都起得来 hub、出接入引导；放进 relay 和 key、在设备页按 ID 加上这台 Mac 后在线；「默认」和「只有 IPv4」两种状态下 relay 都解析成 `::ffff:` 映射地址并连上 | relay 存的是 IPv4 字面地址，**域名解析没有拿到**；模拟器上没有全局 IPv6。两样都留给实机，在 P1 第一个包上做（§14.6 第 8、15 条） | §6.1 已改（库按名字传；`AI_V4MAPPED` 的问题不用回答）；§6.5 `systemOpen` 要安卓通道；§14.2 验收加「按 ID 添加」 |
| 4 | 进程内会话、节流 | **过，模拟器 36 的打字没过**。第 4 项的硬条件是会话通路（门禁两轮、画面、节流），36 上打字不在其中：少的字在 rApp 写作条里发送前就已经少了，在会话和 FFI 通路的上游；34 和平板（重打后）到齐，所以会话通路过，36 的打字归到规格 §14.6 第 11 条。门禁两轮（对照、慢速 200 ms）在模拟器 34、模拟器 36、平板上都过：慢速时 `p0 fps` 平均 4.4–4.7，traffic `frames` 平均 28.9–29.6；后 6 次减前 6 次的 PSS 是 −10.6 / −5.9 / −7.9 MB，都在 40 MB 以内。P0Moving 的动画面、颜色三台都对。TextEdit 打 `p0probe`：34 上到齐；平板上第一次在发送前也少了第二个 p，重打 `probe` 后到齐；**36 上重复 7 次，到齐 4 次、少字 3 次**（第 4 节「模拟器 36 打字重复测量」），有截图的 2 次在 rApp 的写作条里就已经少了。打字经写作条发出，这一点只凭截图。**对着 Mac 屏幕核对画面只在模拟器 34 上做过**（桌面会话）；其余都是单应用会话，因为桌面会话会把用户自己的会话顶掉。hub 读到超过 64 KiB 的回复行（`watch_load` 首行，Mac 服务起来约 52 分钟以后，量到的区间 51.5–55 分钟）就丢整条连接，会话跟着断；探查里绕过后会话撑过 250 s | 36 的少字：用真键盘和软键盘各打一段，留给实机（§14.6 第 11 条）。64 KiB 行上限：共用代码，main 上没修，记进 `tasks/todo.md`「安卓平板」，P1 接会话前修 | §6.2 规矩 1 已补 |
| 5 | 键盘和触控板 | **部分过**。过关条件（Ctrl+C/V 在空白区到得了 App，`isControlPressed` 为真）在 34、36 上**过**（`uinput`，内核级，`ctrl=1`）。**平板上没确认，等用户用真键盘按**：键到得了，但 `input keycombination` 发的字母 `metaState` 为 0，平板上 `uinput` 被拒，注入显示不了修饰键状态。36 上文本框有焦点、软键盘打开时 Ctrl+C/V/A/Z/X 都到、`ctrl=1`；36 上原先「到不了」是点在了文本框外，34 和平板的文本框没有重测。Meta 组合都被系统拿走。滚轮是 `PointerScrollEvent kind=mouse`，三台都有 | 平板的 Ctrl+C/V：蓝牙键盘的一分钟检查，在 P1 第一个包上做（§14.6 第 9 条）。触控板双指和捏合：模拟器上测不出，平板没有触控板（§14.6 第 9 条）。Ctrl+SPACE、文本框里单按字母：原因没查明（§14.6 第 14 条） | §14.6 第 9 条已改 |
| 6 | 语音 | **部分过**。三个目标按 §11 的规则手算都是「不能用」：34 没有识别器（规则 3，正是 34 的过关条件）；36 和平板的 `checkRecognitionSupport` 报 14（规则 4）。**哪里都没有拿到中文字**：36 在线识别收到 `ready`、`begin`、`error 7`（没检测到语音），设备上下载 `cmn-Hans-CN` 后报 `error 13`；分段的静音时长给 `Long` 时 36 的识别器拒绝，给 `int` 不再拒绝，但只来过一个空的 `segment`；平板六次按住说话（普通 ×3、分段 ×2、热词）都没有任何回调。分段结果、热词效果都没有拿到 | 按 U6 的退路：判成不能用，按钮不出现（§11 规则 3、4）。平板上真人对着平板说话：留给实机（§14.6 第 5、13 条） | §11 已改（语言标签、超时、异常、`int`、规则 4、找识别器）；「按下去没回调」的处理是建议 2 |
| 7 | 自己装自己 | **部分过**。两个模拟器过：`versionCode` 9001 → 9002；`canInstall` 起点是否，开开关后是；装完 App 被杀、没有自己重启；数据文件和开关都还在。`success` 回调没观察到（进程死了）。哈希不对的四个条件在 34 和平板上都过。**平板上没装完，等用户**：荣耀多出安全检测、「已了解…」勾选、锁屏密码三层，密码不能替用户输 | 平板上走完一遍、输锁屏密码：留给实机，在 P1 第一个包上做（§14.6 第 7、10 条） | §13.2 第 4 步已改（装完不重启）；荣耀三层是建议 1，「装完回到桌面」的提示是建议 3 |
| 8 | 数字 | **部分过**。三台装的 release 包 29.5 MB（29,544,999 字节），三个 `.so` 8.26 / 11.58 / 7.55 MB（MB = 10⁶ 字节）。PSS（MB = 1000 dumpsys KB）：模拟器 34 没会话 88.8、开着静态 2560×1600 桌面会话 220.4（这两项是在早一版的包上量的）；模拟器 36 没会话 89.1、静态单应用会话 158.6；平板没会话 209.0、静态单应用会话 445.7。release 动画面 30 s 平均 `p0 fps`：平板 26.1（屏幕 60 Hz），模拟器 34 26.0、模拟器 36 25.1（只作参考）。「静态」会话每秒仍到 3–7 帧，PSS 摆动大，平均数只作大概 | 强制走 relay 的帧率没量：留给实机（§14.6 第 12 条） | 不用改 |

## 1 工具和空壳

日期 2026-11-27。

**模拟器。** `pixel_tablet` 设备存在，直接用，没有替换。两个 AVD：`rapp-p0-34`（AOSP 14，不带 Google）、`rapp-p0-36`（Android 16，带 Google API）。`config.ini` 里改成 `hw.keyboard=yes`、`hw.ramSize=4096`（avdmanager 默认是 `no` 和 `2G`）。两个都是 2560x1600、横屏起来：`adb shell wm size` 都是 `Physical size: 2560x1600`；`ro.build.version.sdk` 分别是 34、36（release 14、16）；abi `arm64-v8a`。34 上没有任何带 google 的包；36 上有 `com.google.android.gms`。两个镜像都是 arm64，在 Apple 芯片上能起来。

**空壳。** `gui/lib/main_p0_shell.dart` 只显示 `rApp P0 shell` 和 `Platform.operatingSystemVersion`。`flutter build apk --debug -t lib/main_p0_shell.dart --target-platform android-arm64` 出 81 MB 的调试 APK。两个模拟器各装一次、用 `am start -n com.rapphub.rapp/.MainActivity` 启动、`screencap` 截图（图在 scratchpad，不进仓库）：
- API 34：白底，中间大字 `rApp P0 shell`，下面一行小字 `sdk_phone64_arm64-userdebug 14 UE1A.230829.036.A1 11228894 test-keys`；底部是平板的任务栏。`logcat -d -s flutter AndroidRuntime` 里只有两行 flutter 的 Impeller（OpenGLES）和 Dart VM service 信息，没有 FATAL。
- API 36：同样的页面，小字 `sdk_gphone64_arm64-userdebug 16 BE2A.250530.026.F3 13894323 dev-keys`；底部是手势条。`logcat` 没有 FATAL。**第一次截图（冷启动后立刻装、启动）截到的是系统弹的「System UI isn't responding」对话框**，不是本应用；点 Wait、等 20 秒后再启动（应用已在前台），第二张截图才是上面这个正常页面。弹框是模拟器刚起来时 System UI 太忙，不是应用崩溃（`AndroidRuntime` 里没有 FATAL），但以后在 36 上装包前最好多等一会儿。
- 两台模拟器没有同时开，一台关掉（`adb emu kill`）再开另一台。

**这一步碰到的坑（P1 的人会再碰到）：**
1. **`flutter create` 会改写 `gui/.metadata`**：它把原来的 linux/macos/windows 三条迁移记录丢了，只留 android。处理：原文件还原，再手工加一条 android 记录。它还会生成 `gui/test/widget_test.dart`（引用不存在的 `MyApp`），已删除。它也会改 `gui/pubspec.lock`，已还原。
2. **JDK。** `sdkmanager`/`avdmanager` 在 JDK 27 上正常。Gradle 9.1.0 不认 JDK 27（`flutter create` 末尾的提示就是这个），所以装了 `brew install openjdk@21`，之后所有 `flutter build` 都在命令前设 `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`。没有动 Flutter 全局配置。`brew install openjdk@21` 顺带升级了 8 个依赖库（brotli、fontconfig、glib、harfbuzz、jpeg-turbo、lz4、zstd、little-cms2）。
3. **下载非常慢，要绕代理（只在这台 Mac 上需要：它开着 TUN + fake-ip 代理；没有这种代理的机器直接下就行）。** 这台 Mac 的代理让 Google 的下载服务器只有约 1–160 KB/s，Gradle 的 100+ MB 下载一直超时；直连物理网卡（DoH 解析 + 绑定 en0）能到 10–17 MB/s。做法：在 scratchpad 里起一个只监听 127.0.0.1 的小 CONNECT 代理（Python，DoH 解析真实 IP，socket 绑 en0），然后 `sdkmanager --proxy=http --proxy_host=127.0.0.1 --proxy_port=18123`，Gradle 用 `JAVA_TOOL_OPTIONS="-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=18123 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=18123 -Dhttp.nonProxyHosts=localhost|127.0.0.1"`。Maven Central（Cloudflare）走这条路也只有约 150 KB/s，首次 `flutter build apk` 总共用了约 40 分钟（含一次因代理空闲超时设置过短而断流重来）。依赖缓存好之后再编会快很多。
4. **Flutter 生成的 `.gitignore` 忽略了 `gradlew`、`gradlew.bat`、`gradle-wrapper.jar`**；它们每次 `flutter build` 会重新生成，不进仓库。
5. AGP 在第一次构建时自己装了 build-tools 36.0.0 和 CMake 3.22.1，不用手动装。
6. **Gradle 设置。** Flutter 模板在 `gui/android/gradle.properties` 里加了 `android.newDsl=false`、`android.builtInKotlin=false`。P1 建工程时照留；以后升 AGP 时再看能不能去掉。

**用到的命令**（和计划第 1 项的命令一致；P1 照着来，`JAVA_HOME` 指 openjdk@21；这台 Mac 上 `sdkmanager` 另加上面第 3 条的 `--proxy` 参数）：

```bash
export ANDROID_HOME=~/Library/Android/sdk
SDKM=$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager
AVDM=$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager
yes | $SDKM --licenses
$SDKM "platforms;android-36" "ndk;28.2.13676358" "emulator" \
  "system-images;android-34;default;arm64-v8a" "system-images;android-36;google_apis;arm64-v8a"
~/.cargo/bin/rustup target add aarch64-linux-android
~/.cargo/bin/cargo install cargo-ndk --locked
$AVDM create avd -n rapp-p0-34 -k "system-images;android-34;default;arm64-v8a" -d pixel_tablet
$AVDM create avd -n rapp-p0-36 -k "system-images;android-36;google_apis;arm64-v8a" -d pixel_tablet
# 两个 config.ini：hw.keyboard=yes、hw.ramSize=4096；一次只开一台
$ANDROID_HOME/emulator/emulator -avd rapp-p0-34 -no-snapshot -no-boot-anim
~/development/flutter/bin/flutter create --platforms=android --org com.rapphub --project-name rapp gui
cd gui && ~/development/flutter/bin/flutter build apk --debug -t lib/main_p0_shell.dart --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.rapphub.rapp/.MainActivity
```

**磁盘：** 见文首「工具和镜像」。

**结论：过。** 空壳在 API 34（AOSP 14）和 API 36（Google APIs）两个 2560x1600 平板模拟器上都能装、能启动、能显示，没有崩溃。

## 2 `.so`

日期 2026-11-27。探查分支 `probe/android-p0`，提交 7b9c99c7（挪代码）、9f1e9ff1（新 crate）。

**会话进库。** `git mv` 把 `client-core/src/bin/rapp-session.rs` 挪成 `src/session/mod.rs`，`bin/session_output/mod.rs` → `src/session/output.rs`，`bin/session_trace/mod.rs` → `src/session/trace.rs`；只改了 `mod`/`use` 路径和可见性（`Output` 变 `pub`），`run` 的标准输入换成参数 `input: impl BufRead + Send + 'static`，新加 `pub fn serve(input, writer)`（就是原来 `main` 的几步）。`bin/rapp-session.rs` 只剩 `session::serve(BufReader::new(stdin()), stdout())`。`trace.rs` 读 `RAPP_STREAM_TRACE_DIR` 的那行没动。git 把 `mod.rs` 记成新增（因为原路径上又建了 bin 文件），另两个记成改名。
- `cargo test -p rapp-client-core` 挪之前 70 条（lib 7、bin rapp-session 11、client 44、host_wire 3、probe 5），挪之后 70 条（lib 18、bin 0、44、3、5），全过。`host_wire` 仍然起真的 `rapp-session` 子进程。

**`rapp-android-ffi`。** `rust/android-ffi`，`[lib] name = "rapp_android"`，`crate-type = ["cdylib"]`；依赖 `rapp-hub-ffi`、`rapp-client-core`（路径）、`libc` 0.2.191、`serde_json`（按计划加了，lib 里没用到，没有警告）；测试依赖 `flate2` 1.1.11。`rust/Cargo.toml` 只在 `members` 里加了 `"android-ffi"`，`Cargo.lock` 只多了这个 crate 的一段。
- 先写测试：`cargo test -p rapp-android-ffi` 编译失败（16 个错误，函数和 `Gate`/`GateWriter` 都不存在）。
- 实现后 4 条测试全过（约 0.32 s）：`gate_holds_the_next_packet_until_ack`、`close_releases_a_writer_stuck_on_the_gate`、`session_over_loopback_ends_with_kind_2_exactly_once`（kind 2 只来一次、在最后），外加 `close_on_an_unacked_frame_still_ends_with_kind_2_once`（帧没 ack 时 close，kind 2 仍只来一次且在最后，`send` 非 UTF-8 返回 -2）。故意改坏（帧不关闸、kind 2 发两次）四条全失败，再改回。之后又加了「发 kind 2 前等正在进行的 sink 调用做完」（见下），最终版连跑 4 次都过。
- `cargo test -p rapp-android-ffi -p rapp-client-core` 全过；`cargo clippy -p rapp-android-ffi -- -D warnings` 干净。加 `--all-targets` 时测试里有一处 `manual_c_str_literals`，已改成 `c"…"`，之后也干净。
- **和计划的一处不同：关闸在交给 sink 之前。** 计划写「等闸开 → 交给 sink → 是帧就关闸」。如果先交再关，Dart 可能在关闸之前就 ack 了，这个 ack 会丢、会话永远卡住。所以 `pass` 在同一把锁里等开、关闸，然后才调 sink。另外线程结束时先把闸作废并等正在进行的那次 sink 调用做完，再发 kind 2，保证 kind 2 之后不会再有回调。
- **最后一帧不 ack，会话就结束不了**（读代码和测试看到的行为）：闸关着时，`serve` 最后那条 `disconnected` 事件和 kind 2 都排在闸后面，要等 ack 或 `rapp_session_close` 才出来。所以 Dart 一侧（§6.3）每一帧都要 ack，丢掉的帧也要。
- **积压时多出一张旧帧**：`Output` 的写线程先从队列里取出下一个包（是帧就先展开、拷进包里），然后才卡在闸上。所以积压时 ack 之后先到的是这张已经拿出来的帧，然后才是最新的一张，和管道写满时一样，多一张过时的帧。量延迟时要算上这一张。
- **回调可能比 `rapp_session_open` 返回得早**：会话线程在 `open` 返回号码之前就可能用这个号码调 sink（事件，启动 JSON 不对时连 kind 2 都可能先到）。用 `NativeCallable.listener` 是排队投递，没问题，但 Dart 一侧不能假定先拿到号码再收消息。
- sink 收到的内存是 `libc::malloc` 来的，`rapp_session_free` 就是 `libc::free`。**每一帧会多拷一次**：`Output` 把画面展开进它自己的 `pixels`，再写给写入端，写入端把这些字节 `memcpy` 进 malloc 来的包（`android-ffi/src/lib.rs:117–121` 的 `Body::fill`）。2560×1600 时每帧约 16 MB（2560×1600×4 = 16,384,000 字节）。第 4 项量数字时算上这一次。对过 Flutter SDK：`NativeFinalizerFunction` 是 `Void Function(Pointer<Void> token)`，`asTypedList(len, finalizer:)` 不给 `token` 时用指针本身，和计划说的一致。

**编 `.so`。** `cargo ndk --help` 里最低版本的参数是 `-P/--platform`。实际命令：

```bash
cd rust && ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358 \
  ~/.cargo/bin/cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi
```

第一次（冷编）退出码 0，墙钟 37.6 s，编了 157 个 crate，没有警告，没有哪个依赖编不过；最终版只重编本 crate，27.1 s。其中 ring 0.17.14、rustls 0.23.46、tokio 1.54.1、quinn 0.11.12、rcgen 0.14.10、if-addrs 0.15.0、portable-pty 0.9.0、alacritty_terminal 0.25.1 都直接编过，没换 feature、没加 `cfg`。

**导出表**（`llvm-nm -D --defined-only … | /usr/bin/grep ' T rapp_'`，最终提交 9f1e9ff1 的那一版）：

```
0000000000545a3c T rapp_hub_free_line
0000000000545a7c T rapp_hub_send
0000000000545e18 T rapp_hub_start
0000000000546a8c T rapp_hub_stop
00000000002d6ca8 T rapp_session_ack
00000000002d7144 T rapp_session_close
00000000002d76b0 T rapp_session_free
00000000002d76b4 T rapp_session_open
00000000002d7f34 T rapp_session_send
```

恰好九个，动态符号表里定义的符号也只有这九个。hub 的四个靠 `pub use rapp_hub_ffi::{…}` 就进了表，**不用** `#[used] static`。

**对齐**（`llvm-readelf -lW … | /usr/bin/grep LOAD`）：

```
LOAD 0x000000 0x0000000000000000 0x0000000000000000 0x1ee150 0x1ee150 R   0x4000
LOAD 0x1ee180 0x00000000001f2180 0x00000000001f2180 0x4fec20 0x4fec20 R E 0x4000
LOAD 0x6ecda0 0x00000000006f4da0 0x00000000006f4da0 0x02d6c8 0x02e260 RW  0x4000
LOAD 0x71a468 0x0000000000726468 0x0000000000726468 0x001fa8 0x002928 RW  0x4000
```

四个段都是 `0x4000`（16 KB 页）。

**大小和其他：** `ls -l` 11,265,848 字节（没 strip）；`llvm-strip` 后 7,457,536 字节（strip 的是 scratchpad 里的一份，仓库里那份没动；AGP 打包时会不会再 strip 没看）。`file`：ELF 64-bit LSB shared object, ARM aarch64。NEEDED 只有 `libdl.so`、`libm.so`、`libc.so`，不要 `libc++_shared.so`。没有 SONAME。`.note.android.ident` 是 API 34（`0x22`）、`r28c`、`13676358`。用的命令（`SO=target/aarch64-linux-android/release/librapp_android.so`，在 `rust/` 下）：

```bash
$BIN/llvm-strip -o <scratchpad>/stripped.so $SO && ls -l <scratchpad>/stripped.so
file $SO
$BIN/llvm-readelf -dW $SO | /usr/bin/grep -E 'NEEDED|SONAME'
$BIN/llvm-readelf -nW $SO
$BIN/llvm-readelf -x .note.android.ident $SO
```

**按 Linux 写的分支。** `cargo tree -p rapp-android-ffi --target aarch64-linux-android -e normal --prefix none | /usr/bin/grep '^rapp-' | sort -u` 列出：rapp-android-ffi、rapp-client-core、rapp-conn、rapp-hub、rapp-hub-ffi、rapp-net、rapp-ports、rapp-term、rapp-wire。安卓上 `target_os` 是 `"android"` 不是 `"linux"`，所以下面这些 Linux 分支在 `.so` 里都**没编进去**，走的是「既不是 macOS 也不是 Linux」的那条。`grep 'target_os = "linux"'` 只在 `term` 里有命中，hub、net、conn、ports、client-core、wire、hub-ffi 都没有：

| 文件和行 | 做什么 | 安卓走哪条 | 安卓要不要（P1 怎么改） |
|---|---|---|---|
| `term/src/pty/fg.rs:108,115,127,133,152,157,178,193` | 读 `/proc/{pid}/cmdline、comm、cwd、environ` 拿前台程序名、目录、启动信息 | 返回 `None` | 不要：安卓只当控制端，不开本机终端。不改 |
| `term/src/pty/fg.rs:226,242,253,271,280,287` | 只在测试里 | 不编 | 不相干 |
| `term/src/serve.rs:208` | Linux 上 `Worker.launchers` 为空，否则 `launch::launchers()` | 调 `launchers()`，见下 | 不要。不改 |
| `term/src/serve.rs:442` | Linux 上用 `spawn_blocking` 列可用的终端程序 | 直接调 | 不要。不改 |
| `term/src/pty/launch.rs:159` | `known()`：Linux 用 `LINUX_APPS`，否则 `["Terminal","iTerm"]` | **拿到 macOS 的名单** | 不要，但名单不对。P1 可以给安卓单独返回空 |
| `term/src/pty/launch.rs:164` | `launchers()`：Linux 查桌面环境、`systemd-run` | 走 `!cfg!(macos)` 返回空 | 不要。不改 |
| `term/src/pty/launch.rs:326,333` | 开终端窗口的命令：Linux `linux_command`，否则 `Command::new("open")` | **走 macOS 的 `open`**（安卓上会失败） | 不要。P1 给安卓直接返回错误，免得去执行 `open` |
| `term/tests/serve.rs:165,906` | 只在测试里 | 不编 | 不相干 |

hub 用到 `rapp_term` 的只有 `id::is_term`（`hub/src/lib.rs:394`，终端会话只能嵌入打开）和 `config::OFF`（`hub/src/terms.rs:11`）；安卓 app 只当控制端、`embed_only`，用不到本机终端和开窗口。另外 `net/src/quic.rs` 里有 `any(macos, ios)` 的分支（`sin6_len`、`AI_FLAGS`），安卓走非 Apple 那条：`AI_FLAGS = AI_V4MAPPED|AI_ADDRCONFIG`，`ai_family = AF_UNSPEC`（`quic.rs:315、324`），结果里只留不是 v4 映射的 IPv6 地址（`quic.rs:339`）。所以 C 库给不给映射地址都不影响结果，见第 3 节。

**还没看的：** 这个 `.so` 还没在模拟器里加载过（第 3、4 项做）。`trace.rs` 仍按进程号开 `worker-{pid}.log`，进程内多个会话会写同一个文件（P1 再处理）。hub-ffi 那四个函数本身没包 `catch_unwind`（现有代码，原样导出），hub 里一恐慌安卓进程就退出，见「规格要改的地方」。规格 §6.2 规矩 5（Windows 门禁上要编得过）P0 没验，探查分支不过那道门禁；P1 合并前在 Windows 机器上看。

**P1 接手时要改的（读代码看到的，探查里没改）：**
- `rapp_session_open` 先起线程、后把会话放进表（拿着表锁起线程，线程自己的移除会等这次放入），所以 sink 可能在 `open` 返回号码之前就被调。`open` 的文档注释要写明这一点。
- `serve` 恐慌时（`catch_unwind` 接住），它的输出写线程可能没被 join，线程漏掉。闸作废以后它不会再调 sink，但线程本身还在。
- `rapp_session_send` 恐慌时返回 -1，和「没有这个会话」混在一起，调用方分不出来。
- `serde_json` 写进了依赖，lib 里没用到，可以去掉。
- `rapp_session_close` 的注释说 kind 2「在返回之前」到，但它只等 2 s；线程更慢时 kind 2 在返回之后才到。注释要照实写。
- `gate_holds_the_next_packet_until_ack` 靠 `sleep(200 ms)` 判断「还卡着」，机器忙时可能误报。
- hub-ffi 的四个函数要自己包 `catch_unwind`（规格 §6.2 规矩 2 已改）。

**结论：过。** `.so` 编得出来，九个名字都在导出表里，四个 `LOAD` 段都按 `0x4000` 对齐，现有会话测试条数不变、全过。

## 3 进程内 hub 和网络

日期 2026-11-27。探查分支 `probe/android-p0`，提交 81ec88d9。两台模拟器先后各做一遍（`rapp-p0-34`、`rapp-p0-36`，一次只开一台，36 冷启动后等 90 秒再装）。relay 的主机、key、设备 id 在本页一律写成 `relay`、`KEY`、`ID`；看 `hub.log`、`logcat`、`ip` 输出时都先过一个替换这三样的过滤器。

**改了什么（详见文末补丁表）。**
- `hub_ffi.dart`：`FfiHubTransport.start` 加 `String? library`；`null` 时还是 `DynamicLibrary.process()`（iOS 不变），安卓传 `'librapp_android.so'`，用 `DynamicLibrary.open`。`_stopOffThread(library)` 在另一个 isolate 里按名字重新打开库（`DynamicLibrary` 传不过 `Isolate.run`）。
- `main.dart` 只加一行 `if (Platform.isAndroid) return mainAndroid();`。`main_android.dart` 从 `main_ios.dart` 抄：数据根 `<filesDir>/rapp`（Kotlin 通道 `rapp/android` 的 `paths` 给 `files`、`cache`），`ensureDeviceId(root, name: 'rApp P0 探查', os: 'android')`，hub 选项不变（hub-ffi 写死的 `owns_access`、`embed_only`、`dual_stack`、`map_ports`）。
- `MainActivity.kt`：`rapp/android` 通道（`paths`、`deviceName`）。清单加 `INTERNET`、`ACCESS_NETWORK_STATE`、`android:allowBackup="false"`。
- `rapp-android-ffi` 加 `rapp_p0_resolve(host, port)`（`catch_unwind` 包着，`rapp_hub_free_line` 释放），返回两行：`rapp_net::quic::getaddrinfo_v6` 的结果、`resolve_for(host:port, dual=true)` 的结果。为此 `rapp-net` 加了一行 `pub use sys::getaddrinfo_v6`。`cargo test -p rapp-android-ffi -p rapp-net` 全过（android-ffi 5 条），`clippy --all-targets -D warnings` 干净。
- `.so` 用 `scripts/p0-android-so.sh`（`cargo ndk -t arm64-v8a -P 34 build --release -p rapp-android-ffi`，拷进 `gui/android/app/src/main/jniLibs/arm64-v8a/`，该目录被 `.gitignore` 忽略）。导出表多了 `rapp_p0_resolve`，共 10 个。
- APK：`flutter build apk --debug --target-platform android-arm64`（JDK 21 + 本机代理，同第 1 节），113 MB。**AGP 打包时会 strip**：仓库里的 `.so` 11,375,704 字节，APK 里 `lib/arm64-v8a/librapp_android.so` 是 7,528,992 字节，`Stored`（不压缩）。第 2 节没看的那个问题答了。
- `flutter analyze` 无问题。`flutter test test/` 前后都是 3651 条：改之前 `+3630 ~18 -3`，改之后 `+3631 ~18 -2`。两次都挂 `linux_detach_test.dart` 的两条（本机原有）；改之前还挂了 `service_client_test.dart` 的「ServiceMonitor share…」，改之后过了，这条和本次改动无关（时好时坏）。

**第 3 步：hub 起来。**
- 两台都起来了：`hub.log` 只有 `hub_start`（version 0.15.58）、`ports`、`ports_asked` 三行 info；`logcat` 里没有 `hub 起不来`。`files/rapp/local/` 下生成 `device.crt`、`device.key`、只有 `id` 的 `service.json`（0600）。
- **第一次出的是全景，不是接入引导。** 原因：`PlatformCaps.forOs('android')` 落进桌面的默认项（`hasService`、`hasTray`……，`hubInProcess` 是 false），`MainWindow._needsAccess` 要 `caps.hubInProcess`。探查里在 `mainAndroid()` 开头写 `caps = const PlatformCaps(hubInProcess: true)` 绕过（没改 `platform_caps.dart`）。之后两台都出接入引导（「接入点」「key」「接入」）。
- **`stderr` 到不了 logcat。** `main_ios.dart` 的 `_log` 用 `stderr.writeln`，安卓上这些字一行也看不到，「`logcat -s flutter` 里没有 `hub 起不来`」这一条就验不了。改成 `debugPrint` 后出现在 `flutter` 标签下。
- **坑：`adb install -r` 后卡在启动画面。** 34 上把第 1 节的空壳 APK 用 `install -r` 覆盖成正式 APK，启动后一直是启动画面，`logcat` 有 `E flutter: Could not prepare isolate`、`Could not create root isolate`、`Could not launch engine`，Dart 一行没跑。`adb uninstall com.rapphub.rapp` 再装就好了。第二次在 34 上碰到时，前面多一行 `Can't load Kernel binary: Invalid kernel binary: Indicated size is invalid`，查到了原因：debug 包第一次启动时把 `kernel_blob.bin` 解到 `app_flutter/flutter_assets/`，那里的文件只有 8,388,608 字节（APK 里是 47,973,912），是上一次解到一半模拟器就关了。删掉 `app_flutter/flutter_assets` 和 `app_flutter/res_timestamp-*` 再启动就好，不用卸载。只有 debug 包这样（release 包是 AOT，不解 kernel）。P1 开发时在模拟器上碰到「卡在启动画面」，先看是不是这个：`kernel_blob.bin` 比 APK 里的小，就删掉这两样重启。

**第 4 步：放进 relay 和 key。**
- 这台 Mac 的数据根是 `~/rapp`（没有 `RAPP_HOME`，没有指针文件）。`jq '{relay, key}' ~/rapp/local/service.json > <scratchpad>/p0-service.json`，`chmod 600`。
- **和计划不同：合并，不覆盖。** 模拟器上的 `service.json` 已经有 `ensureDeviceId` 写的 `id`，整个覆盖会丢掉它。做法：`run-as … cat` 拉下来，`jq -s '.[0] * .[1]'` 合上 relay 和 key，再 `run-as com.rapphub.rapp sh -c 'cat > /data/user/0/com.rapphub.rapp/files/rapp/local/service.json'` 写回（**要写绝对路径**，`sh -c` 里的相对路径不是应用目录，报 `No such file or directory`）。之后字段是 `id,key,relay`，0600。hub 认这个文件，没再改。
- **和计划不同：这台 Mac 不会自己出现。** 有了 relay 和 key 之后全景里只有「本机」、设备在线 1/1，`hub.log` 没有任何 relay 的行。hub 只探 `hosts.json` 里存过的主机；正常用法是在设备页「添加设备」填对方的 ID（`add_host` → `add_by_id`）。为了不让 ID 出现在界面和输入记录里，探查没走界面，而是用 `jq '[{id: .id, name: "这台 Mac", password: ""}]' ~/rapp/local/service.json` 生成 `hosts.json` 写进 `files/rapp/local/`（0600），再冷启动。
- 结果（两台一样）：全景里「这台 Mac」在线（苹果标记、0.15.52、正在跑的会话、「打开应用」），设备在线 2/2；`hub.log` 有 `route … path:"lan" result:"ok"` 和 `presence … online:true`，`ports` 映射了这台 Mac 的两个共享端口（28000、28001）。模拟器经 `10.0.2.2` 的 NAT 能直接连到 Mac 的局域网地址，所以「自动」走的是 lan，没走 relay。
- 为了看 relay 那条路，把 `hosts.json` 里这台的 `route` 改成 `"relay"`（等于 hub 的 `set_route` 设成 relay）再冷启动：`route … path:"relay" result:"ok"`，`presence online:true`，界面同样在线。之后的网络测试都在强制 relay 下做。两台模拟器的 `hosts.json` 现在都留着 `route: relay`。
- 存下来的 `hub.log`（见第 5 步末尾）都没有 `warn`、`error` 行。lan 那次和强制 relay 第一次的日志当时没单独存，只在屏幕上看过。

**第 5 步：地址解析。**

这台 Mac 存的 relay 是「IPv4 字面地址:端口」，不是域名。

网络状态（两台一样，只有接口编号和临时地址不同）：

| | 「默认」（开机后的样子） | 「只有 IPv4」（`adb root && adb shell sysctl -w net.ipv6.conf.all.disable_ipv6=1`） |
|---|---|---|
| IPv4 | `eth0` 10.0.2.15、`wlan0` 10.0.2.16；默认路由 `via 10.0.2.2`（表 1015、1016） | 同左 |
| IPv6 地址 | 只有 `fec0::/64`（站内，已废弃的前缀）和 `fe80::`，**没有全局地址**；`lo` 有 `::1` | 全部没了，`lo` 的 `::1` 也没了 |
| IPv6 默认路由 | `ip -6 route` 主表是空的；`ip -6 route show table all` 里有 `default via fe80::2`（表 1015、1016） | 没有 |

命令：`adb shell ip -o addr`、`adb shell ip -6 route`、`adb shell ip -6 route show table all | grep default`、`adb shell ip -4 route show table all | grep default`。

解析结果（`--dart-define=P0_PAGE=resolve` 的包，端口 443；四种组合——34/36 × 默认/只有 IPv4——**完全一样**）：

| 主机 | `getaddrinfo_v6`（`AF_UNSPEC`，`AI_V4MAPPED\|AI_ADDRCONFIG`，只留非映射的 IPv6） | `resolve_for(dual)` |
|---|---|---|
| relay | none | `::ffff:` 映射 |
| `1.1.1.1` | none | `[::ffff:1.1.1.1]:443` |
| `localhost` | none | `[::ffff:127.0.0.1]:443` |
| `dns.google` | none | `[::ffff:198.18.x.x]:443` |

- `getaddrinfo_v6` 四个都是 none，这是**代码本来的意思**，不是安卓的 C 库的毛病：它是 NAT64 那一支，只找「不是 v4 映射」的 IPv6 地址，映射地址一律丢掉（`quic.rs:338-339` 的注释：NAT64 上映射地址到不了）。所以对 IPv4 主机，在哪个平台上都是 none（`quic.rs:654` 的测试就断言 `getaddrinfo_v6("127.0.0.1","9") == None`）。这里另外也没有 AAAA 记录、没有合成的地址，所以四个都是 none。这次测不出 C 库对 `AI_V4MAPPED` 怎么处理。
- `resolve_for(dual)` 不靠它：先普通解析，有 IPv4 地址且有 IPv4 路由就自己拼 `::ffff:a.b.c.d`。计划里说的「按 IPv4 解析、自己拼 `::ffff:`」的那一支**本来就在 `resolve_for` 里**，安卓走的就是这一支，不用另加。
- `dns.google` 解析出 `198.18.x.x`：这是 Mac 上 TUN + fake-ip 代理的假地址（198.18.0.0/15），模拟器的 DNS 经 Mac 转发。不影响 relay（relay 是字面地址）。
- 换回正式包冷启动（强制 relay）：两台在两种状态下都是 `route … path:"relay" result:"ok"`、`presence online:true`，界面上这台 Mac 在线。「只有 IPv4」下连 `::1` 都没有，hub 的双栈 UDP 套接字照样连上了 relay。
- 日志证据（scratchpad，不进仓库，都已过过滤器）：「只有 IPv4」是 `p0/t3-hub-v4only-{34,36}.txt`；「默认」是 `p0/t3-hub-default-{34,36}.txt`——各自冷开机（`emulator -avd rapp-p0-3x -no-snapshot-load -no-audio`，36 开机后等 90 秒），确认 `/proc/sys/net/ipv6/conf/all/disable_ipv6` 是 0、`ip -o addr` 和上表「默认」一样，`adb install -r t3-main.apk`，`am start -W -n com.rapphub.rapp/.MainActivity`，等 25–40 秒，再 `run-as com.rapphub.rapp cat …/files/rapp/logs/hub.log | mask.sh`，从这次的 `hub_start` 起存下来。两份都是 `hub_start`、`ports`、`route path:"relay" result:"ok"`、`presence online:true`、`ports_asked answered:1`，`grep -c -E '"lvl":"(warn|error)"'` 都是 0。
- **双栈的真 IPv6 一半测不了**：「默认」状态没有全局 IPv6 地址，relay 也是 IPv4 字面地址。真 IPv6、只有 IPv6 的网络（NAT64，靠 `getaddrinfo_v6` 拿 DNS64 合成的 AAAA 那一支，这次没走到）留给实机，已加进规格 §14.6。

截图（scratchpad，不进仓库）：`p0-t3-access-setup-{34,36}.png`（接入引导）、`p0-t3-online-{34,36}.png`（lan 在线）、`p0-t3-online-relay-{34,36}.png`、`p0-t3-online-v4only-{34,36}.png`、`p0-t3-resolve-{default,v4only}-{34,36}.png`。

**结论：过。** hub 在安卓进程里起得来、读得懂数据根、出接入引导；放进 relay 和 key、加上这台 Mac 后，两台模拟器在「默认」和「只有 IPv4」两种状态下都把 relay 解析成 `::ffff:` 映射地址并经 relay 连上。注意这台 Mac 存的 relay 是 IPv4 字面地址，**relay 的域名解析没有拿到**；真 IPv6 和只有 IPv6 的网络也留给实机（规格 §14.6 第 8、15 条）。

**P1 接手时要改的（读代码看到的）：**
- `rust/net/src/quic.rs:271` 的注释写「Only the iOS hub uses them」，现在安卓也用，要改。
- `gui/lib/p0/p0_pages.dart:61` 的 `relayHost` 遇到没加方括号的 IPv6 字面地址，会在最后一个冒号处截断。只在探查页里用，P1 不带过去。
- `rust/android-ffi/src/lib.rs:371` 的 `anyhow_text` 只是包了一层 `to_string`，可以直接用 `to_string`。只在探查函数 `rapp_p0_resolve` 里用。
- 能力表里安卓的 `systemOpen` 先留 false：它的四处用法（`main_window.dart:43`、`term_stage.dart:50`、`local_section.dart:43`、`data_section.dart:54`）都走 `iosChannel`，安卓上没有这个通道。探查的 `main_android.dart` 也是这样设的（见「探查里打的补丁」）。

## 4 进程内会话

**状态：过，模拟器 36 的打字没过。** 第 4 项的硬条件是会话通路，36 上打字不在其中：少的字在写作条里发送前就已经少了，在会话和 FFI 通路的上游；34 和平板（重打后）到齐，所以会话通路过，36 的打字归到规格 §14.6 第 11 条。 门禁两轮（对照、慢速 200 ms）在模拟器 34、模拟器 36、平板上都过，见本节「第四次测量」。36 上 TextEdit 打 `p0probe` 不稳：先后 7 次（`input text` 4 次，其中 1 次打的是 `a1abba`；逐键 3 次）里 3 次少一个字符（`p0robe`、`pprobe`），逐键输入也少，不只是 `adb shell input text`；有截图的几次，少的字在写作条里就没有了；34 上到齐；平板上第一次 `input text 'p0probe'` 在发送前也少了第二个 p，退格后重打 `probe` 才到齐。**对着 Mac 屏幕核对画面只在模拟器 34 上做过**（第二次测量的 `p0/t4e-desktop-static-34.png`，桌面会话）；36 和平板只看了 P0Moving 的画面在动、颜色对，没有和 Mac 屏幕逐处对照。到 Mac 的会话从第三次测量起都是单应用会话：桌面会话一次只能一个人开，开了会把用户自己正在用的桌面会话顶掉。强制 relay 的 fps 四次测量都没量。

本节有四次测量：第一次（模拟器 34，桌面会话和单应用会话）、第二次（模拟器 34，查会话为什么断、加绕过）、第三次（模拟器 34，画面源换成 P0Moving）、第四次（模拟器 34、模拟器 36、平板，门禁和打字），外加模拟器 36 的打字重复测量。

做法：`gui/lib/embed/session_ffi.dart`（新）接 `rapp-android-ffi` 的 `rapp_session_open/send/ack/close/free`。帧包用 `asTypedList(finalizer: rapp_session_free)` 零拷贝交给 Dart。`ackedPackets` 是 `async*`：交出一个帧包，等 `slow`，再 `ack`。这样消费方暂停时不 ack，Rust 的闸也就不放下一帧。`SessionWorker.ffi` 和 `LinuxSessionPort.ffi` 是这两个共用文件里新加的构造函数，旧路径不动。`main_android.dart` 用 `LinuxSessionPort.ffi('librapp_android.so', downloads: () => '<数据根>/files/transfers', slow: P0_SLOW_MS)`。日志每秒打一行 `p0 fps=N`，traffic 事件打 `p0 traffic frames=N`。

FFI 会话的生命周期（照代码写，行号是 `probe/android-p0` 分支上的）：
- 第一次 `send` 带的是 start JSON，用它调 `rapp_session_open`。返回的 id 是 0 就算失败：打一行 `p0 rapp_session_open failed`，会话当场结束，`exitCode` 是 -1。之后的 `send` 走 `rapp_session_send`。Dart 侧开始关或会话已结束后再 `send`，直接丢掉（`session_ffi.dart:180-198`）。
- Dart 侧开始关（`_closing`）或包流已关之后才到的包，当场用 `rapp_session_free` 还回去，不交给 Dart（`session_ffi.dart:132-136`）。其余的包零拷贝交出，由 finalizer 还。
- 开成功的会话只在收到 kind 2 时结束：关 `NativeCallable`、关包流、`exitCode` 和 `inputDone` 完成，`exitCode` 固定是 0（`session_ffi.dart:128-130`、`142-150`）。`close()` 自己不结束会话：它在 `Isolate.run` 里调 `rapp_session_close`（最多阻塞 2 s），然后等的还是 kind 2（`session_ffi.dart:201-210`）。当场结束、`exitCode` 为 -1 的只有两种：open 失败，和 open 之前就 `close()`。
- `inputDone` 的意思和子进程路径不一样。子进程路径是 stdin 关掉时完成（`session_worker.dart:44`，`process.stdin.done`）；FFI 路径是会话结束（kind 2）时才完成（`session_ffi.dart:124`），而且从不带错误完成。所以 `LinuxSessionPort` 挂在 `inputDone.catchError` 上的 `session worker stopped`（`linux_session_port.dart:585-587`）在安卓上不会触发。
- `LinuxSessionPort` 关会话时先 `closeInput()`（就是 `FfiSession.close()`），再起一个 2 s 定时器去 `kill`，`exitCode` 完成时取消（`linux_session_port.dart:1476-1482`）。`_FfiSessionWorker` 的 `kill` 只是再调一次 `close()`（`session_worker.dart:152`）；这时 `_closing` 已经是 true，`close()` 直接返回，什么也不做。`pid` 返回的是会话 id（`session_worker.dart:156`）。
- ack 由消费方要下一个包来驱动。`ackedPackets` 是 `async*`：`yield` 一个帧包后，要等消费方拿到这个包、而且没暂停，生成器才往下走，等 `slow`，再 `ack`（`session_ffi.dart:19-31`；id 为 0 时不调 `rapp_session_ack`，`:152-154`）。`LinuxSessionPort` 的读循环是 `await for`（`linux_session_port.dart:1249`），循环体跑完之前不要下一个包。帧包的循环体是同步调 `queueFrame`（`:1252`），所以帧包的 ack 在 `queueFrame` 返回、循环要下一个包时发出；循环体只在部分事件包上 `await`（`menus`、`nativeWindows`，`:1310`、`:1319`）。消费方取消订阅时不 ack，包流的 `onCancel` 调 `close()`（`session_ffi.dart:93`）。

单元测试（`gui/test/session_ffi_test.dart`，4 个）：
- ack 顺序；
- 消费方暂停时不 ack；
- `slow` 生效；
- `slowNow` 每帧重新读（见下「慢速开关改成运行时读」）。

先红后绿（`flutter test test/session_ffi_test.dart`）。

`LinuxSessionPort` 在安卓上**没打补丁就跑起来了**。它几处只对 Linux 有意义的地方在安卓上都是空转，见补丁表最后几行：
- `rapp/linux` 通道：`MissingPluginException` 已被接住；
- `xdg-open`：`ProcessException` 已被接住；
- `RAPP_STREAM_TRACE_DIR` 环境变量。

实测（模拟器 34，路由自动，界面显示「局域网」）：

| 看什么 | 结果 | 证据（scratchpad，不进仓库） |
|---|---|---|
| 桌面会话有画面、和 Mac 屏幕一致、红蓝没反 | 有。debug 包 `p0 fps` 14–29；release 包 `p0 fps` 10–15，traffic `frames` 13–51 | `p0/t4-desktop-34.png`（debug）、`p0/t4-desktop-release-34.png`（release，截到时已断开，画面停在最后一帧） |
| 单应用会话打字 | 过，但不是直接打进文稿：`adb shell input tap 1200 700` 后 `adb shell input text 'p0probe'` 进的是 rApp 自己的写作条。按回车（`adb shell input keyevent 66`）后发到 Mac，TextEdit 文稿里出现 `p0probe`，标题变成 Edited。之后没存盘就关掉了 | `p0/t4-type-34.png`（字在写作条）、`p0/t4-type2-34.png`、`p0/t4-p0probe-34.png`（字在文稿里） |
| 会话稳定性 | **release 包里会话自己断**：三次里两次在 18 s、10 s 后断，安卓侧报 `host disconnected: failed to fill whole buffer`（`client-core/src/protocol.rs:352` 的 `read_exact` 读到 EOF），Mac 侧记 `session_end reason "connection lost"`。断之前那一秒 `p0 fps` 还有 14–15，不是闸卡住。点「重连」能连回来。第三次开了 91 s，由探查方 `am force-stop` 结束。debug 包两次各开了 115 s、79 s，Mac 侧结束原因也记的是 `connection lost`，当时是不是探查方结束的没有记下来 | `p0/t4-textedit-disconnect-34.png` |

**第一次测量停在这里的原因：** 每次会话结束（自己断开也算），Mac 上的 rApp 都会在 10 s 后自动锁屏（`service.log` 里 `auto_lock`）。锁上以后要用户输入密码。另外，打开桌面会话会把另一台设备正开着的桌面会话顶掉（`session_end reason "taken over"`）。

### 第二次测量（2026-11-27 下午，模拟器 34，无窗口模式 `emulator -avd rapp-p0-34 -no-window -no-audio`）

**会话自己断的原因（查清了）。** Mac 回 `watch_load` 的第一行带满 1 小时的历史（720 个点），超过 `rapp_net::line::MAX_LINE`（`rust/net/src/line.rs:11`，64 KiB），读行报 `line longer than 64 KiB`。`rust/hub/src/link.rs` 的 `request()` 把这当成连接坏了：缓存连接那支没有专门处理、落到 `forget`，新连接那支走 `forget_if_dead`。连接一丢，这条连接上的会话全断，安卓侧看到的就是 `failed to fill whole buffer`、Mac 侧是 `connection lost`。查法：debug 包加诊断日志（改动 `p0/t4d-diag.diff`），在 hub.log 里看到这行报错，紧跟着连接被丢、会话结束。

哪些是确定的：
- 回复行太长就丢连接，这段是 main 上的共用代码。探查分支岔出去以后，main 上 `rust/net`、`rust/hub` 没有新提交；回复实测 75,125 字节，上限 65,536（第三次测量）。
- 连接丢了、会话跟着断，只在这个探查的进程内会话里见过。
- 桌面版的会话在自己的进程里、有自己的连接，那边什么都没测。

探查里的绕过（补丁表 `link.rs` 那行）：连接还开着、错误是 `line longer than` 时，只把错误交回去、记一行 `p0_keep_link`，不丢连接。绕过后 hub.log 里只有大约每分钟一行 `p0_keep_link`，没有反复重连。两次会话都撑过 250 s：桌面会话 256 s（被另一台设备顶掉才结束），单应用会话 251 s（由探查方 `am force-stop` 结束）。**真修法应在 main 的共用代码里**：要么 `watch_load` 的首行别带那么多历史、或拆行，要么读行上限对这个回复放宽；不管哪种，「回复太长」都不该丢整条连接。

**绕过留下没修的：** 它只保住了连接；首行超上限时 `watch_load` 照样失败，大约每分钟重试一次。余力（负载）数据要等真修法。

**余力什么时候到得了。** 首行的长短跟着 Mac 服务的运行时长涨：历史最多 720 个点（1 小时），点少的时候首行在上限以内，余力是到得了的。第四次测量时 Mac 服务 08:02:39Z 起来，用 `scratchpad/tools/load-size.py`（只读连本机 IPC，发 `{"cmd":"load","history":true}`）量首行：08:54:10Z 是 65,477 字节、618 个点（还在 65,536 以内）；08:57:40Z 是 69,651 字节、660 个点（超了）（`p0/t4g-load-size.txt`，事后从终端输出抄下来的）。算一下：08:54:10Z 离服务起来 3,091 s（51.5 分钟）、618 个点，08:57:40Z 离起来 3,301 s（55.0 分钟）、660 个点，都是每 5.00 s 一个点；两次之间每多一个点多 4,174 / 42 ≈ 99 字节（按两份原始记录各自的点算，每点约 100 和约 103 字节；所以每点在 99–103 字节之间），所以 619 个点就约 65,576 字节、超过 65,536。撞上限大约在服务起来 **52 分钟**（约 619–620 个点），量到的能确定的区间是 51.5–55 分钟。历史存在服务进程的内存里（`rust/service/src/load/rules.rs` 的 `ring: VecDeque`，最多 `KEEP = 720` 个），Mac 服务一重启历史就清空、这 52 分钟从头算：09:47:12Z Mac rApp 自动升级（见下面「Mac 自动升级」）就是一次重启（这条是读代码得出的，重启后没再量首行）。`watch_load` 是一条流：只有建流时的第一行带历史，之后每行只是一个点（**读代码推断**：hub 一侧 `rust/hub/src/load.rs` 的 `follow` 先交第一行再循环读；service 一侧 `rust/service/src/load/serve.rs:59` 注释写第一行是回复，之后每个采样一行。没在新起的服务上实测过）。所以看的是**建流那一刻**的历史长短：平板的 hub 在 08:3x 起来、那时首行还短，09:02:36Z 全景里仍看得到余力一行（`p0/t4g-tab-ov.png`，「内存 剩 27%」）；34、36 在 09:14–09:26Z 才连上，首行已超上限，看不到。结论：建流时 Mac 服务起来不到约 52 分钟，余力到得了、之后一直在；晚于这个时间建流就到不了，每分钟重试一次也一样失败，要等真修法。

**慢速开关改成运行时读。** `ackedPackets` 加了 `slowNow`，每帧重新读；`FfiSession` 每秒用 libc 的 `__system_property_get` 读一次系统属性 `debug.rapp.p0_slow_ms`。这样同一个包、同一个会话里，`adb -s <目标> shell setprop debug.rapp.p0_slow_ms 200` 和 `… 0` 就能在慢速和对照之间切换，不用重装、不用断会话（断会话会触发 Mac 自动锁屏）。日志在切换时打 `p0 slow=Nms`。新测试先红后绿：`p0/t4c-red.txt`、`p0/t4c-green.txt`。

**release 包（带绕过）上量到的：**

| 看什么 | 结果 | 证据（scratchpad，不进仓库） |
|---|---|---|
| 桌面会话有画面、和 Mac 一致、红蓝没反 | 有，和 Mac 一致，颜色对 | `p0/t4e-desktop-static-34.png` |
| 动的画面（Mac 上一个 Terminal 窗口每 30 ms 打一行时间，无声、没下载东西） | 画面跟着动；截图那一秒 `p0 fps=15` | `p0/t4e-moving-34.png` |
| 静态桌面会话时的 PSS | 见第 8 节 | `p0/t4e-static-34.txt` |

**门禁：这一次没做完（第四次测量做完了，见本节末）。** 对照那一轮（`debug.rapp.p0_slow_ms=0`）开始后约 4 分钟，用户在另一台设备上把这台 Mac 的桌面会话拿回去了（Mac `service.log` 06:47:44Z `session_end reason "taken over"`），从第 10 个采样起 PSS 掉到约 95 MB。按规矩这一轮整轮作废（`p0/t4e-ctl-34.txt`，不引用里面的数），不拼接。桌面会话一次只能一个人开，用户正在用，再顶回去会打断用户，所以没再开。试过单应用会话（Terminal）代替：它跟着用户在 Mac 上聚焦的那个 Terminal 窗口走，`p0 fps` 只有 0–6，不是能控制的动画面，不能当门禁的画面源（`p0/t4e-term-34.png`、`p0/t4e-term-moving-34.png`）。这一次慢速一轮、release 30 s 平均 fps、强制 relay 的 fps 都**没量**。

**界面上看到的问题（P1 留意）：** 会话断开后，画面中间的「重连 / 结束会话」框里，「结束会话」点了没反应，只能点左上角总览按钮离开。重现：模拟器 34、release 包，开一个单应用会话，让它断开（第二次测量里是会话自己断），在断开框里点「结束会话」（`adb -s <目标> shell input tap` 点了几次），画面不变。同一个框里的「重连」是好的（第三次测量里 Mac 上的 app 退出后点「重连」，会话重新开了起来）。第四次测量里 36 上也一样（见下「Mac 自动升级」）。Mac 锁着时，会话里显示「远程电脑已锁屏：输入系统密码」；探查里没用过这个输入。

**第二次测量的锁屏和顶掉次数：** 自动锁屏 1 次（06:27:40Z，绕过之前那次会话断开后）；探查会话顶掉别人的桌面会话 2 次（06:27:16Z、06:43:28Z）；探查会话被别人顶掉 1 次（06:47:44Z）。

### 第三次测量（2026-11-27 16:15 起，模拟器 34；画面源换成单应用会话）

**画面源。** 自己编的 AppKit app（源码和包都在 scratchpad 的 `moving/`，不进仓库）：
- bundle id `com.rapp.p0moving`，常规激活策略；
- 内容 1280×800 pt（这台 Mac 是 2 倍屏，即 2560×1600 px）；
- 60 Hz 定时器每帧重画（5 条移动的色块加一个计数），自己的日志每秒记 `draws=60`；
- 无声，没下载任何东西；
- 编法 `swiftc -O main.swift -o P0Moving.app/Contents/MacOS/P0Moving && codesign -f -s - P0Moving.app`，用 `open -g -a P0Moving.app` 启动，窗口完全在屏幕里。

在模拟器 34 的总览页「打开应用 ▾」框里，在「其他 app 的包名」一栏输入 `com.rapp.p0moving`，点「打开」，单应用会话就开了。Mac 上没出现任何授权框，也没顶掉任何会话（`service.log` 07:18:30Z `session_start`）。画面见 `p0/t4f-moving-34.png`。

| 看什么 | 结果 | 证据（scratchpad，不进仓库） |
|---|---|---|
| 会话实际送来的帧大小（帧头里的宽、高） | `2560x1664`：1600 px 内容加 64 px（32 pt）标题栏。窗口被挪过之后是 `2576x1680`（见下） | logcat `p0 fps=… size=…`，`p0/t4f-ctl-34.txt` |
| 动画面下 `p0 fps`（`debug.rapp.p0_slow_ms=0`，路由自动，局域网） | 每秒 21–29；traffic `frames` 每秒 22–34。这不是 30 s 平均，见下面「没做」 | 同上 |
| hub.log 里的超长行 | 见下面 `watch_load` 一段 | `p0/t4f-keep-link-34.txt`（已打码） |

**开会话会抢焦点。** rapp-host 开单应用会话时调 `app.activate()`（`Sources/rapp-host/WindowCapture.swift:60`），会把被抓的 app 带到前台。P0Moving 收到激活后把焦点还给之前在前台的 app，并把窗口放到最后。抓图不受影响，因为过滤器只含这个 app 的窗口。开会话时还了 1 次焦点。

**对照那一轮被打扰，作废。** 第 13、14 个采样之间（07:25:44–07:25:52Z），P0Moving 被激活了 5 次，大约每 2 s 一次，之前在前台的是 Finder。每次焦点都被探查脚本还给了 Finder。之后窗口离开了右下角，帧头从 `2560x1664` 变成 `2576x1680`。当时用户自己的桌面会话还开着，看样子是用户在点或拖这个窗口，探查脚本的「还焦点」和用户抢了 5 次。按规矩这一轮整轮作废（`p0/t4f-ctl-34.txt`，不引用里面的 PSS）。

随后改了 P0Moving：
- 激活前 1.5 s 内有点击或按键，或者鼠标还按着，就不还焦点；
- 重开时窗口放在用户拖到的位置。

**探查造成了一次锁屏。** 重开 P0Moving 要先退出它，探查会话也随之结束（07:29:21Z `session_end reason "closed"`）。用户自己的两个会话已在 07:26:20Z 结束，Mac 上没有别的会话了，于是 10 s 后自动锁屏（07:29:32Z `auto_lock`）。之后在 34 上点「重连」，会话开了，但 Mac 侧记 `A is locked at start; waiting for unlock`，没有画面。

教训：只要 Mac 上没有别的会话，探查结束自己的会话就会锁屏。所以要重开画面源，得先开一个新会话再关旧的。

**这一次没做**（Mac 锁着；除强制 relay 的 fps 外，第四次测量都做了；36 的打字做了但不稳，见第四次测量）：
- 门禁两轮（对照、慢速 200 ms）；
- release 30 s 平均 fps；
- 强制 relay 的 fps；
- 模拟器 36 的画面、门禁和 TextEdit 打字。

**`watch_load` 的证据。** 用 `adb -s <目标> root` 后执行 `adb -s <目标> shell grep p0_keep_link /data/data/com.rapphub.rapp/files/rapp/logs/hub.log`，再过打码脚本，拿到的一行：

```
{"ts":"2026-11-27T07:21:52.834Z","err":"line longer than 64 KiB","ev":"p0_keep_link","lvl":"info","op":"watch_load"}
```

- 34 的 hub.log 里含 `line longer` 的行共 19 行，都是 `watch_load` 撞上的，大约每分钟一行：
  - 4 行 `p0_quiet_err` `"op":"WatchLoad"`：第二次测量的诊断包，绕过之前；
  - 10 行 `p0_keep_link` 不带 op：绕过后、加 op 之前的包；
  - 5 行 `p0_keep_link` `"op":"watch_load"`：这次的包。
- 回复有多大：在 Mac 上只读地连本机 IPC，发 `{"cmd":"load","history":true}`，首行回复 75,125 字节，里面 720 个历史点（每个约 100 字节；各次量的在 99–103 字节之间），而上限 `MAX_LINE` 是 65,536（`p0/t4f-load-size.txt`）。
- 别的请求都没撞上。

**第三次测量的锁屏和顶掉次数：** 自动锁屏 1 次（07:29:32Z，探查造成的，见上）；顶掉别人 0 次；被顶掉 0 次；和用户抢焦点 5 次（07:25:44–07:25:52Z，见上）。

### 第四次测量（2026-11-27，模拟器 34、模拟器 36、平板；时间见各表，UTC）

**怎么做的。**
- 包：probe `d2706c7e` 不带 `P0_PAGE` 的 release 包（`p0/t4g-release.apk`），三台都装的这一个。
- 平板：荣耀 ROD2-W09，Android 16，USB 连 Mac。只临时改过「充电时保持唤醒」，探查结束时改回原值；别的设置没改。模拟器无窗口跑（`-no-window -no-audio`）。
- 画面源只用单应用会话，没开桌面会话：动画面是第三次测量的 P0Moving（`com.rapp.p0moving`），打字用 TextEdit 的一个空白文档。
- Mac 上的 rApp 先是 0.15.64，09:47:11Z 自己升到了 0.15.66（见下面「Mac 自动升级」）。门禁、30 s fps、平板的画面和打字、平板的两个 PSS 都是 0.15.64 时量的；模拟器 36 的打字和静态 PSS 是 0.15.66 时量的。

**A 画面和打字**

| 看什么 | 目标 | 结果 | 过不过 | 证据（scratchpad，不进仓库） |
|---|---|---|---|---|
| P0Moving 的动画面、颜色 | 模拟器 36 | 色块在动，颜色对。强制 relay 和局域网各看了一次 | 过 | `p0/t4g-moving-36-relay.png`、`p0/t4g-moving-36.png` |
| 同上 | 平板（实机） | 色块在动，颜色对，局域网 | 过 | `p0/t4g-moving-tab.png` |
| TextEdit 里打 `p0probe` | 模拟器 36 | 点文档会弹出写作条。`adb -s <目标> shell input text 'p0probe'` 进了写作条，回车（keyevent 66）只在写作条里换行、不发送，点写作条的发送按钮才发到 Mac。字到了 Mac 的文档里，但**少了第二个 p**：osascript 读回来是 `p0robe` 加一个换行（`od -c`：`p 0 r o b e \n`），截图里文档那行也是 `p0robe`，两者一致。少的这个字是在 `input text` 送键、写作条收字、还是发到 Mac 这几段里丢的，没查明（经过见表下） | 没过（少一个字符；重复测量见表下） | `p0/t4g-p0probe-36.png` |
| 同上 | 平板（实机） | 要绕开拼音输入法，经过见表下。文档显示 `p0probe`，osascript 读到的也是 | 过（第一次少一个 p，退格重打后到齐） | `p0/t4g-p0probe-tab.png`、`p0/t4g-tab-x1.png` |

**模拟器 36 打字的经过（UTC）。**
- 09:43:14Z 用 osascript 把文档清空。09:46:14Z 在 36 上开 TextEdit 单应用会话。
- 第一次：09:46:42Z 点文档（`input tap 1200 700`），`input text 'p0probe'`，3 s 后截图、读文档；09:47:13Z keyevent 66，读回来只有换行（空文档）；09:47:36Z 点发送按钮，09:47:51Z 起每 5 s 读一次共 6 次，都是空的。这一次正赶上 09:47:11Z Mac 服务重启（下面「Mac 自动升级」），没到 Mac。这一次写作条里是什么没有留证据：据做测量时的记录，截图文件被后面的截图覆盖了，这一点没有别的证据。
- 09:48:54Z 点「重连」，TextEdit 会话重新开起来。
- 第二次（唯一到了 Mac 的一次）：09:49:18Z 点文档，等 1.5 s，`input text 'p0probe'`，等 1 s，点发送按钮，之后每 2 s 读一次文档，09:49:24Z 读到 `p0robe` 加换行；读完才截图，就是现在的 `p0/t4g-p0probe-36.png`，显示 `p0robe`。截图和读回来的是同一次，不是画面慢了一帧。
- 第二次没在点发送前截写作条，所以不知道写作条里是不是已经少了 p。
- 不重做：要开到 Mac 的会话，而 Mac 现在锁着。

**模拟器 36 打字重复测量（UTC 2026-11-27，局域网，TextEdit 单应用会话，空白文档）。** 每次的做法：点文档，输入，keyevent 66，点写作条的发送按钮，用 osascript 读文档并经 `od -c` 保存。读回来的末尾是 `\n \n \n` 三个换行。已知的来源：osascript 读文档自己带一个换行（清空后读回来是单独一个 `\n`），keyevent 66 在写作条里换一行；第三个换行从哪来没查明。上面「第二次」那次没按 keyevent 66，读回来只有一个换行，和这个说法不矛盾。输入法状态：A 第 2 次起，输入时 `mInputShown=true`、输入前 `false`；A 第 1 次文件里只记了一个 `false`（发送之后）；`show_ime_with_hard_keyboard` 是 1。没改任何设置。各项依据：脚本 `tools/t4t-run.sh` 里的点击坐标（`1200 400`）、发送按钮坐标（`1945 791`）和文本证据里的起止时间（10:53:38Z–10:54:44Z）只覆盖 A 第 2 次起；A 第 1 次点文档用的是 `input tap 1200 700`、点发送按钮，这两点只来自当时敲的命令，没有文本记录，没有起止时间；release 包来自装的 `t4g-release.apk`，「局域网」是截图上会话栏的标注。

| 组 | 命令 | 次数 | 到齐 | 少字的几次读回来是 |
|---|---|---|---|---|
| A | `adb -s <目标> shell input text 'p0probe'` | 3 | 2 | 第 1 次 `p 0 r o b e`（少第二个 p）。发送前的截图 `t4t-a1-typed.png`，写作条里已经是 `p0robe` |
| B | `adb -s <目标> shell input keyevent KEYCODE_P KEYCODE_0 KEYCODE_P KEYCODE_R KEYCODE_O KEYCODE_B KEYCODE_E`（逐键） | 3 | 1 | 第 2、3 次都是 `p p r o b e`（少 `0`）；第 2 次发送前截图 `t4t-e36-b2-typed.png` 上，写作条里已经是 `pprobe`，输入法候选栏有 `pprobe`、`p0robe`（只凭这张截图）；第 3 次没有截图 |
| C | `adb -s <目标> shell input text 'a1abba'` | 1 | 1 | 没少：`a 1 a b b a` |

结论只到这里：
- 少字不止出在 `adb shell input text`：逐键输入 3 次里也少了 2 次。
- 有截图的两次（A 第 1 次、B 第 2 次），少的字在发送前的写作条里就已经没有；B 第 3 次没有截图，不知道少在哪一段。这两次里没发现发到 Mac 这一段再丢字。
- 少的是 `0` 或第二个 `p`，不是固定位置，也不是每次都少。`a1abba` 只有 1 次，不能说它不少。
- 用的是 `adb` 注入，不是真键盘，真键盘会不会少字没测。34 和平板上的那几次没有重复。
- 原因没查明：可能在 `adb` 注入本身、写作条收字或模拟器输入法（B 第 2 次候选栏里有 `p0robe`、`pprobe`），这几段没有分开测。
- 不是 Mac 那边挡了输入：Mac 的日志里这段时间有两行 `input_blocked`，都在 A 第 3 次里（10:53:49Z、10:53:56Z，用户当时在 Mac 上操作），而 A 第 3 次是到齐的。少字的几次都不在这两个时刻：会话 10:52:47Z 开起来到 10:53:49Z 之间没有 `input_blocked`，B 组里也没有。

证据：`p0/t4t-e36-a1.txt`、`t4t-e36-a2.txt`、`t4t-e36-a3.txt`、`t4t-e36-b1.txt`、`t4t-e36-b2.txt`、`t4t-e36-b3.txt`、`t4t-e36-c1.txt`（读回来的 `od -c`、`mInputShown`、`show_ime_with_hard_keyboard`、起止时间）；截图 `t4t-a1-typed.png`、`t4t-a1-enter.png`、`t4t-e36-b2-typed.png` 等。

平板和模拟器不同：平板的输入法是荣耀拼音，`input text` 打进去的字母会被拼成候选。经过：
- 第一次 `input text 'p0probe'`：写作条里是 `p0`，拼音候选栏是 `robe`，**这里也少了第二个 p**，还没发送、和 Mac 无关（`p0/t4g-type-tab.png`）。
- 用退格（keyevent 67）清掉拼音、留下 `p0`（`t4g-type-tab4.png`），再 `input text 'probe'`。
- 第一个 keyevent 66：拼音输入法把原字母 `probe` 上屏到写作条，写作条变成 `p0probe`，不发送（`t4g-type-tab5.png`）。
- 第二个 keyevent 66：写作条里的 `p0probe` 发到 Mac，osascript 读回来是 `p0probe`（`t4g-p0probe-tab.png`）。
- 和 36 不一样：36 上 keyevent 66 只在写作条里换行，要点发送按钮；34 和平板上回车直接发送（34 见本节第一张表的「单应用会话打字」行）。为什么不一样没查。
- 两台都是 `p0` 后面那个 p 没了，34 上（第 4 节前面）同样的 `input text 'p0probe'` 没少字。真键盘、真用户打字没试。

**B 门禁。**
- 命令：每台用 `adb -s <目标> shell setprop debug.rapp.p0_slow_ms 0`（对照）或 `200`（慢速），等 30 s，再每 10 s 取一次 `dumpsys meminfo com.rapphub.rapp` 的 `TOTAL PSS` 和最后几行 `p0 fps`、`p0 traffic`，共 18 次（`scratchpad/tools/gate-run.sh`，里面调 `sample.sh <out> 18 10`）。fps 和 frames 的平均取 18 次采样里记下的 54 个秒。
- 单位：MB = 1000 个 dumpsys KB（dumpsys 的 KB 是 1,024 字节）。
- 过的条件：慢速一轮 `p0 fps` 约 5、`frames` 明显更大，**并且**后 6 次 PSS 平均减前 6 次平均小于 40 MB。
- 画面源都是 P0Moving，帧头一直是 `2576x1680`；P0Moving 自己的日志每秒 `draws=60`，窗口位置 `587,183,1280x832` 没变，这几轮里没有焦点被抢。
- 三台、六轮，都过；慢速一轮结束后都 `setprop … 0` 改回来了。

| 目标 | 轮 | 时间（UTC） | 前 6 次 PSS 平均 | 后 6 次平均 | 后减前 | `p0 fps` 平均 | traffic `frames` 平均 | 过不过 | 证据 |
|---|---|---|---:|---:|---:|---:|---:|---|---|
| 平板（实机） | 对照 0 ms | 08:53:23–08:56:57 | 488.4 MB | 492.2 MB | +3.8 MB | 23.4 | 25.0 | — | `p0/t4g-ctl-tab.txt` |
| 平板（实机） | 慢速 200 ms | 08:57:34–09:01:07 | 481.6 MB | 470.9 MB | −10.6 MB | 4.4 | 28.9 | 过 | `p0/t4g-slow-tab.txt` |
| 模拟器 34 | 对照 0 ms | 09:15:53–09:19:16 | 202.4 MB | 175.8 MB | −26.7 MB | 25.4 | 29.7 | — | `p0/t4g-ctl-34.txt` |
| 模拟器 34 | 慢速 200 ms | 09:19:16–09:22:40 | 186.7 MB | 180.8 MB | −5.9 MB | 4.7 | 29.6 | 过 | `p0/t4g-slow-34.txt` |
| 模拟器 36 | 对照 0 ms | 09:30:40–09:34:07 | 192.1 MB | 194.2 MB | +2.0 MB | 26.0 | 29.8 | — | `p0/t4g-ctl-36.txt` |
| 模拟器 36 | 慢速 200 ms | 09:34:07–09:37:34 | 182.9 MB | 175.0 MB | −7.9 MB | 4.6 | 29.5 | 过 | `p0/t4g-slow-36.txt` |

平板和模拟器不同：平板的 PSS 高得多，门禁时 470–492 MB，模拟器 175–202 MB；对照轮平板的 fps 平均 23.4，比两个模拟器（25.4、26.0）低，但**不说明平板画得慢**：
- `p0/t4g-ctl-tab.txt` 第 3–5 次采样（第 22–45 行，08:54:17–08:54:40Z）的 9 秒里 `p0 fps` 是 5、3、2、4、5、9、8、8、12，同一时间 traffic `frames` 也只有 4、3、2、6、3、8、7、9、9：是 Mac 那边来的帧少了，不是平板画不过来。
- 前两次采样是 24–29，第 6–18 次是 22–30。去掉第 3–5 次，其余 45 秒平均 26.9。
- 平板单独量的 30 s fps 是 26.1（第 8 节），和模拟器差不多。
- 那 9 秒为什么来的帧少没查。同一时间 08:54:10Z 在 Mac 上跑过一次量 `watch_load` 首行的脚本，这只是时间上碰巧挨着，没证实有关系。

慢速轮三台表现一样。

**34 的第一轮对照作废。** 同一个 app 有两个控制端时，后开的会顶掉先开的（`session_end reason "taken over"`）。被顶掉的安卓控制端大约 2 分钟后会自己重连、再顶回去：平板 08:47:28Z 被 34 顶掉，08:49:36Z 回来，34 那轮因此被打断（`p0/t4g-ctl-34-void.txt`，不引用里面的数）。之后都先结束另一台上的会话，再开下一台。

**其他看到的。**
- 「rApp P0 探查」：设备名在探查包里写死，所以 34、36、平板在 relay 上是三台同名设备；Mac 的 `service.log` 里今天有 3 个不同的指纹都叫这个名字。
- Mac 很忙：跑的时候平板顶栏显示「这台 Mac CPU 持续 90% 以上」（92–93%）。
- 模拟器 36 上之前留下的路由是「中继（强制）」。在强制 relay 上看过一次画面后，在 ⋯ 菜单里点「恢复自动选路」改回了自动；门禁和 30 s fps 都是自动（局域网）下量的。
- 会话结束后顶栏显示「P0 Moving 意外结束：closed」，其实是从 ⋯ →「结束会话」→「再点一次确认」正常结束的。确认要在一两秒内点，晚了就失效。
- P0Moving 的日志在 09:01–09:02Z（门禁轮之后）有两次把焦点还给 `com.apple.loginwindow`，窗口位置没变。

**Mac 自动升级。** 09:47:09Z Mac 上的 rApp 下载了 0.15.66，09:47:11Z 服务停下，09:47:12Z 新版本起来（`update_applied` 0.15.64 → 0.15.66）。所有会话都以 `service stopped` 结束，包括探查的 P0Moving 和 TextEdit，也包括几个不是探查开的终端会话和一个桌面会话。所以 09:47:11Z–09:48:54Z 之间 Mac 上一个会话都没有，这不是探查关的；Mac 没锁。36 上显示 `host disconnected: failed to fill whole buffer`。断开的卡片上点「结束会话」和「再点一次确认」都没用（和上面「界面上看到的问题」一样）；点「重连」，再从 ⋯ 结束就可以了。第一次在 36 上打字正赶上这次重启，丢了；重连后又打了一次（TextEdit 会话 09:48:54Z 开），这次到了 Mac，但收到的是 `p0robe`（见上面「模拟器 36 打字的经过」）。

**第四次测量的锁屏和顶掉次数。**
- 自动锁屏 1 次，是最后一次关会话：09:55:14Z 关掉模拟器 36，09:55:44Z 它的 TextEdit 会话 `connection lost`，09:55:54Z `auto_lock`。这是测量收尾时关会话引起的，测量已做完。
- 中间没锁过。
- 顶掉别人 0 次；探查的两台之间互相顶掉 1 次（见上）；和用户抢焦点 0 次。

**P1 接手时要改的（读代码看到的，探查里没改）：**
- `watch_load` 首行超过 64 KiB：探查的绕过 `keeps_link`（`rust/hub/src/link.rs:983`）是按错误文字 `line longer than` 判断的，不能带进 main。真修法在共用代码里：这条回复放宽或去掉读行上限，或者首行分块发；不管哪种，回复太长都不该丢整条连接。已记进 `tasks/todo.md`「安卓平板」。
- 回车在写作条里：模拟器 36 上 keyevent 66 只在写作条里换行，要点发送按钮才发；34 和平板上回车直接发。P1 做外接键盘时，两边都要试回车是发送还是换行。
- `gui/test/session_ffi_test.dart` 靠 40 ms、80 ms 的真等待判断先后，机器忙时可能误报；改用 `fake_async`。
- `FfiSession` 本身没有测试（现在只测了 `ackedPackets`）。
- `_FfiSessionWorker` 先把 pid 存成 0，再用 getter 改成会话 id（`gui/lib/embed/session_worker.dart:152`、`:156`），直接传 id 就行。
- `LinuxSessionPort` 的 `_ffiLibrary`、`_ffiSlow`（`gui/lib/embed/linux_session_port.dart:62-66`）只在构造时赋值，可以是 `final`。
- `p0SlowFromProperty` 每秒重新打开一次 `libc.so`（`gui/lib/embed/session_ffi.dart:42`）。探查用的，P1 不带过去。
- `_traffic` 跳过大于 200 字节的包（`gui/lib/embed/session_ffi.dart:172`），traffic 事件变长就数不到。探查用的，P1 不带过去。
- hub-ffi 的四个函数要自己包 `catch_unwind`（见第 2 节）。

## 5 键盘和触控板

**探查页：** `gui/lib/p0/p0_pages.dart` 的 `KeysPage`，用 `--dart-define=P0_PAGE=keys` 构建（`p0-build.sh` 同第 1 节，多传这个参数）。上半屏是能聚焦的空白区（点一下取焦点），下半屏是文本框。`HardwareKeyboard.instance.addHandler` 把每个 `KeyEvent` 记成一行 `p0 key down|up|repeat physical=… logical=… ctrl=.. meta=.. alt=.. shift=..`；整页包在 `Listener` 里，`PointerSignalEvent` 和 `PointerPanZoomStart/Update/End` 记成 `p0 ptr …`。每行同时 `debugPrint`，所以 `adb logcat -d -s flutter | grep 'p0 key'`（或 `'p0 ptr'`）能看到。测试 `gui/test/p0_keys_test.dart` 过。

**三个目标：** 模拟器 34（Android 14）、模拟器 36（Android 16）、平板（HONOR ROD2-W09，Android 16，MagicOS 10；`dumpsys input` 里有蓝牙的 MISTEL-1 键盘和鼠标，所以这台机器上外接键盘是常态；下面所有行仍然是「注入」，不是用户手按的）。

**两种注入，结果不一样，先看这个：**

- `adb shell input keycombination 113 31`（CTRL_LEFT + C）：这个命令发出的字母键事件 `metaState` 是 0。Flutter 先收到 Ctrl 按下（`ctrl=1`），随后一个 Ctrl 抬起，再收到字母键，此时 `ctrl=0`；物理键 ID 是 `0x11000000xx` 这种「Key with ID」，不是 HID 用法码。那个「Ctrl 抬起」查了引擎源码：Android 嵌入层 `KeyEmbedderResponder.java` 的 `synchronizePressingKey`（由 `handleEventImpl` 对每个修饰键调用）以**事件自带的 `getMetaState()`** 为准，记录里 Ctrl 还按着而事件的 `metaState` 说没按，会合成一个 Ctrl 抬起事件（该函数开头注释：让修饰键状态与「真实状态」一致）。这一条只读了源码，没有跟踪运行：合成事件发生在字母键之前，是从看到的事件顺序和源码对上推断的，没有单独验证。结论：`keycombination` 的字母键行 `ctrl=0` 是注入工具的限制，不能当作「平台丢了修饰键」，也不能当作「真键盘会这样」。
- `adb shell uinput`（只在模拟器上用）：注册一个虚拟键盘，发内核级的 `EV_KEY`，修饰键状态是真的，物理键是 HID 用法码（`Key C(0x70006)`）。命令格式是一行行 JSON：`register`（`configuration` 里类型 100 = 事件类型、101 = 键码，键码是 Linux 的：LEFTCTRL 29、LEFTMETA 125、C 46…）、`delay`、`inject`（字段名是 `events`，不是 `data`）。**平板上不用 `uinput`**（权限层拒绝，没试别的办法），所以平板上的「ctrl=1」只能靠真键盘，见下。

**结果（每个键单列；「平板（实机）」是真机，其余两台是模拟器；全部是注入，不是用户手按的）：**

空白区（上半屏取焦点）：

| 组合 | 34 | 36 | 平板（实机） |
|---|---|---|---|
| Ctrl + C | 到，`ctrl=1`（`uinput`） | 到，`ctrl=1` | 到：`Control Left` 按下 `ctrl=1`，字母 `ctrl=0`（`keycombination` 的限制） |
| Ctrl + V | 到，`ctrl=1` | 到，`ctrl=1` | 同上，字母 `ctrl=0` |
| Ctrl + X | 到，`ctrl=1` | 到，`ctrl=1` | 同上，字母 `ctrl=0` |
| Ctrl + Z | 到，`ctrl=1` | 到，`ctrl=1` | 同上，字母 `ctrl=0` |
| Ctrl + A | 到，`ctrl=1` | 到，`ctrl=1` | 同上，字母 `ctrl=0` |
| Ctrl + T | 到，`ctrl=1` | 到，`ctrl=1` | 同上，字母 `ctrl=0` |
| Ctrl + W | 到，`ctrl=1` | 到，`ctrl=1` | 同上，字母 `ctrl=0` |
| Ctrl + TAB | 到，`ctrl=1` | 到，`ctrl=1` | 到（`Control Left` 然后 `Tab`，`ctrl=0`）；第二次注入时输入法出来了 |
| Ctrl + SPACE | 到，`ctrl=1` | 到，`ctrl=1` | 只到 `Control Left`，空格没到；输入法弹出（系统拿走 Ctrl+空格切输入法） |
| Ctrl + ENTER | 到，`ctrl=1` | 到，`ctrl=1` | 到（`Control Left`、`Enter`，`ctrl=0`） |

Meta 组合和 Meta 单按（空白区、文本框一样）：

| 组合 | 镜像 | App 收到 | 系统做了什么 |
|---|---|---|---|
| Meta + C | 34 | 没到 | 启动器的应用抽屉（「Search apps」）打开，App 退到后面（`topResumedActivity` 是 `QuickstepLauncher`，截图为证）。更早几次跑时前台是权限弹窗或添加账号，那是前一个组合留下的焦点漂移，不是 Meta+C 本身 |
| Meta + C | 36 | 没到 | 日历打开 |
| Meta + C | 平板（实机） | 没到 | 联系人打开（荣耀系统快捷键） |
| Meta + TAB、Meta + ENTER | 34、36、平板（实机） | 没到 | 回到桌面（启动器在前台）；34 上 Meta + TAB 复测也是启动器在前台 |
| Meta 单按 | 34、36、平板（实机） | 没到（App 里没有 `Meta` 的行） | 34：回桌面；36：启动器搜索框弹出并拿走窗口焦点；平板：回桌面（随后重新拉起 App） |

**文本框有焦点时（只在 36 上测）：**

第一次测文本框时，软键盘从头到尾没开（`mInputShown=false`），而且在 36 上点的位置落在文本框上方的空隙里，文本框并没有拿到焦点（34 和平板用的是同一个点击公式，没有逐台核对）。那次的结果不算，下面是 36 上按条件测的；34 和平板的文本框没有再测。另外，「改用 `Shortcuts`/`Actions`」这个办法不成立：`HardwareKeyboard` 的处理器先于焦点树，事件到不了处理器，`Shortcuts` 也看不到。

36 上的这一次（`uinput` 虚拟键盘；`settings put secure show_ime_with_hard_keyboard 1`，只在模拟器上设；点在文本框里，`dumpsys input_method` 确认 `mInputShown=true`，截图里软键盘在）。每步单独注入，逐步读 `p0 key`（证据 `p0/t5f-e36-text-order.txt`）：

| 步骤 | 结果 |
|---|---|
| 1 只按 Ctrl | 到：`Control Left` 按下 `ctrl=1`，抬起 `ctrl=0` |
| 2 Ctrl + C | 到：`Key C` 按下 `ctrl=1`，抬起 |
| 3 Ctrl + SPACE | 只到 `Control Left`，空格没到（输入法拿走，和平板上空白区的现象一样） |
| 4 Ctrl + C（再按） | 到，`ctrl=1` |
| 5 单按 c（无 Ctrl） | 没有 `p0 key` 行；文本框里也看不到字（这一点只凭截图）。原因没查；大概是输入法接走了，没有验证 |
| 6 Ctrl + C（再按） | 到，`ctrl=1` |
| 7 Ctrl + V、8 Ctrl + A、9 Ctrl + Z、10 Ctrl + X | 各自都到，`ctrl=1` |

结论：软键盘打开、文本框有焦点时，`uinput` 注入的 Ctrl+C/V/A/Z/X 都到了 `HardwareKeyboard` 的处理器，`ctrl=1`；上面的顺序（Ctrl 单按、Ctrl+SPACE、单按字母之后）没有影响。「先发一个普通键」这一步在这台 36 上用不着（步骤 5、6 已经是「普通键之后再 Ctrl+C」，照常到）。

第一次测文本框时「一行都没有」的现象能复现，条件是点在文本框外的空隙里（`p0/t5f-e36-text-miss.txt`：点 y=770，Ctrl+C、Ctrl+V 都没有任何 `p0 key` 行，包括 `Control Left`）。为什么那种状态下连 Ctrl 单独的事件都没有、而当时 Ctrl+SPACE、Ctrl+ENTER 却到了，**原因没查明**。

没做到的部分：平板和 34 上的文本框没有再测（平板不用 `uinput`，也不改它的设置；真键盘按键是否到文本框，留给实机真键盘检查，规格 §14.6 第 9、14 条）。Ctrl+SPACE、单按字母这两处原因没查明，同一次检查里看。

**过关判定（规格 §14.1）：** Ctrl+C 和 Ctrl+V 在焦点于空白区时到得了 App，并且 `isControlPressed` 为真：

- 34、36：**过**（`uinput`，内核级，修饰键状态是真的）。这是计划里的过关条件，两个模拟器都满足。
- 平板（实机）：**没做，等用户（要用真键盘按）**。键到得了 App（`Control Left` 和字母都到），但 `keycombination` 发的字母 `metaState` 为 0，平板上 `uinput` 又被权限层拒绝（没有 root），所以注入没法显示修饰键状态。**真机上的这一项过关没有得到确认。**用户的一分钟检查：把配对的蓝牙键盘接上，在 App 里有焦点的空白处点一下，按 Ctrl+C、Ctrl+V，看 `isControlPressed`：字母键到达时为真即过。探查包已从平板上卸掉，这项检查在 P1 的第一个包上做（P1 的包里要留一个能读出这一行的地方，比如日志）。已写进规格 §14.6 第 9 条。
- 没有为此换设计。

**Meta 几行（规格 U8）：** 三个目标上 Meta 的组合都到不了 App（系统先拿走了），所以 `_remoteKey` 里 `isMetaPressed` 丢弃的那条路径在这里根本走不到。保留着不碍事。

**给 P1 的一行：** 如果真键盘上字母键到达时没有修饰键状态（`isControlPressed` 为假），App 该怎么办，现在没有证据，等上面那个真键盘检查的结果再定；在那之前不要为此写任何绕过逻辑。

**在这个镜像上测的时候踩到的坑（P1 写测试脚本时有用）：**

- 36 上 Meta 单按会让启动器弹出搜索覆盖层，并**拿走窗口焦点**；之后注入的键全落到搜索框里（屏幕上能看到 `ccc`）。每个组合前要 `am force-stop` 启动器或按 BACK 并点一下 App 取回焦点，用 `dumpsys window | grep mCurrentFocus`（多块显示时有几行，有一行是 `null`，要看全部）确认焦点在 `com.rapphub.rapp`。
- 平板上刚点完取焦点后，第一批 `keycombination` 有时一个字都不到 App；先发一个普通键（探查里用 `KEYCODE_SHIFT_RIGHT`）再发组合，之后就稳了。原因没查。
- 平板的显示是横的 3000×1920，`wm size` 却报 1920×3000；点击坐标要用截图的 PNG 尺寸。模拟器 36 同理：横向 2560×1600，文本框在屏幕约 y=880，不是屏幕的 48% 处。

**滚轮和触控板（`Listener` 是 `HitTestBehavior.translucent`，空白处的事件也收；探查包是 probe `a20bdbf9` 的 keys 页）：**

| 项 | 镜像 | Flutter 收到的 | 来源 |
|---|---|---|---|
| 鼠标滚轮竖向滚一格 | 36、平板（实机） | `p0 ptr scroll kind=mouse delta=-0.0,192.0`，即 `PointerScrollEvent`，`kind` 是 mouse | 注入（`adb shell input mouse scroll <x> <y> --axis VSCROLL,-3`）；36 上复测还是一样 |
| 鼠标滚轮 | 36 | 同上：`uinput` 虚拟鼠标滚轮 +3 得 `delta=-0.0,-192.0`，-3 得 `delta=-0.0,192.0` | `uinput` 虚拟鼠标 |
| 鼠标滚轮 | 34 | 同上：+3 得 `delta=-0.0,-192.0`，-3 得 `delta=-0.0,192.0`（`input` 没有 `scroll` 子命令，所以用 `uinput` 虚拟鼠标；证据 `p0/t5f-e34-ptr.txt`） | `uinput` 虚拟鼠标 |
| 触控板双指滚动 | 34、36 | 没收到任何 `p0 ptr`（`translucent` 前后各试过）。`uinput` 虚拟触控板系统认了（`dumpsys input`：`Classes: TOUCH \| TOUCH_MT \| TOUCHPAD \| EXTERNAL`），Flutter 没有事件 | 注入。**模拟器上测不了，留给实机** |
| 触控板捏合 | 34、36 | 同上，没有任何事件 | 注入。**模拟器上测不了，留给实机** |
| 触控板双指滚动、捏合 | 平板（实机） | 没做，等用户：平板上不能用 `uinput`；这台机器上也没有触控板（`dumpsys input` 里只有蓝牙鼠标、键盘和触摸屏） | 没做 |

触控板这一项，`translucent` 之后 36 和 34 各试了一次（两指同向滚动和两指张开），还是没有事件。不排除是注入的事件序列不对；结论只是「这种方式没测出来」。§14.6 第 9 条已加，要在有触控板的实机上看 Flutter 收到 `PointerPanZoom*` 还是 `PointerScrollEvent`。

## 6 语音

通道 `rapp/p0speech`（Kotlin）：`probe`、`support {onDevice}`、`start {onDevice,segmented,hotwords,lang}`、`stop`、`download`（`SpeechRecognizer.triggerModelDownload(intent)`，intent 是 `ACTION_RECOGNIZE_SPEECH` + `EXTRA_LANGUAGE`），事件 `start`、`ready`、`begin`、`partial`、`segment`、`segmentsEnd`、`final`、`error {code}`、`end`；每个事件带 `inst`（识别器实例号）、`run`、`rms`（`onRmsChanged` 回调次数）、`rmsMax`（最大 rmsdB）。页面 `P0_PAGE=speech`。三个目标：模拟器 34（Android 14，AOSP）、模拟器 36（Android 16，google_apis）、平板（实机，荣耀，Android 16）。原始证据在 `p0/t6-*.txt`、`p0/t6f-*.txt`（`probe` 和 `support` 的原样回答、每次说话的事件序列）和 `p0/t6f-*-log.txt`（打码后的系统日志摘录）。`inst` 是 9 位数时打码脚本会把它换成 `ID`，所以这类事件只能按先后判断是不是同一个实例。

### 6.1 原样回答和「能不能用」

`probe` 另带了 `services`（所有声明了 `android.speech.RecognitionService` 的服务）和 `sdk`，规格要的三项是 `available`、`onDevice`、`service`。

| | 模拟器 34 | 模拟器 36 | 平板（实机） |
|---|---|---|---|
| `probe` | `{available: false, onDevice: false, service: null, services: [], sdk: 34}` | `{available: true, onDevice: true, service: com.google.android.tts/…GoogleTTSRecognitionService, services: [com.google.android.as/…AiAiSpeechRecognitionService, com.google.android.tts/…GoogleTTSRecognitionService], sdk: 36}` | `{available: true, onDevice: false, service: com.hihonor.magicvoice/.voiceui.service.MagicVoiceRecognitionService, services: [com.hihonor.magicvoice/…MagicVoiceRecognitionService], sdk: 36}` |
| `support` `onDevice=true` | `{error: java.lang.UnsupportedOperationException: On-device recognition is not available}`（`createOnDeviceSpeechRecognizer` 抛异常，不是错误码） | `{installed: [en-US], pending: [], supported: [de-DE, es-ES, fr-FR, it-IT, en-AU, en-GB, en-IE, en-SG, ja-JP, de-AT, de-BE, de-CH, en-CA, en-IN, es-US, fr-BE, fr-CA, fr-CH, hi-IN, id-ID, it-CH, ko-KR, pt-BR, th-TH, cmn-Hans-CN, cmn-Hant-TW, pl-PL, ru-RU, tr-TR, vi-VN], online: []}` | 同 34：`UnsupportedOperationException: On-device recognition is not available` |
| `support` `onDevice=false` | `{error: timeout 10s}`（没有识别服务，回调一直不来，页面 10 秒后自己放弃） | `{error: 14}` | `{error: 14}` |
| 按规格 §11 四条规则手算 | 规则 1、2 都不成，落到规则 3 | 规则 1 不成（`installed` 只有 `en-US`）；规则 2 靠的在线 `support` 报 14，规则 4 | 规则 1 不成（`onDevice` 假）；规则 2 靠的在线 `support` 报 14，规则 4 |
| 结论 | 不能用 | 不能用 | 不能用 |
| 过关 | 过（34 要求「不能用」） | 照实记：不能用 | 照实记：不能用 |

在线路径的 `support` 报 14：36 和平板上都是，34 没有识别服务所以没回调。36 的 `supported` 里中文写作 `cmn-Hans-CN`（简体）和 `cmn-Hant-TW`，没有 `zh-CN`；就算装了，规则 1 里「说中文（`zh-CN`）已装好」的字符串比较也会对不上。

### 6.2 说话

麦克风：36 用 `adb emu avd hostmicon`，`say -v Tingting` 在 Mac 上读，Mac 输出音量 47、未静音，没动；平板自己的麦克风听 Mac 的扬声器，`adb shell input swipe` 按住按钮 14 秒。普通一段说「今天下午三点开会」；分段说两句，中间停 3 秒；热词说「打开 rApp」。每次都先 `am force-stop` 再重新打开页面；除了普通 3（它先调了 `support`，`support` 自己会建一个识别器再销毁，日志 `t6f-tab-plain3support-log.txt` 里有它的 `Connection to speech recognition service lost, but no #startListening has been invoked yet`），每次说话只用一个识别器。探查页没有单独的 `rms` 事件（计划里列了）：`onRmsChanged` 只计数，次数和最大值放在 `ready`/`begin`/`error`/`end` 等事件上。

「第一轮」指最早的一批运行（`p0/t6-*`，没有 `rms` 计数，36 的几次是在 Mac 锁屏时跑的）；「第一次测量」指分段值还是 `Long` 的那一版（`p0/t6f-*`）；「第二次测量」指改成 `int` 的那一版（`p0/t6g-*`）。

**分段的请求，两次测量的结果。** 参考页的原话：「Optional string to enable segmented session mode of the specified type, which can be EXTRA_AUDIO_SOURCE, EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS or EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS.」「When setting this extra, make sure the extra used as the string value here is also set in the same intent with proper value.」所以 `EXTRA_SEGMENTED_SESSION` 的值是另一个 extra 的名字，同一个 intent 里还要给那个 extra 设值。

- 值给 `2000L`（`Long`）：36 的识别器**拒绝了**。`t6g-e36-seg-long-log.txt` 里的原样日志：`W Bundle : Key android.speech.extras.SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS expected Integer but value was a java.lang.Long.  The default value 0 was returned.`，调用栈经过 `Intent.getIntExtra` 和 `GoogleTTSRecognitionService.onStartListening`，接着 `E RecognitionServiceInten: EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS is not set with positive value; ignoring EXTRA_SEGMENTED_SESSION`。也就是说这个识别器按 `int` 读这个 extra。第一次测量里 36 的分段那次是在这个状态下跑的（热词那次 `segmented` 是假，没带分段，它的日志 `t6f-e36-hot-log.txt` 里没有 `W Bundle` 行，也没有 `ignoring EXTRA_SEGMENTED_SESSION`），`p0/t6f-e36-seg-log.txt` 里只有栈帧和最后一行 `E`，没有 `W Bundle` 那一行标题。
- 值给 `2000`（`int`）：`p0/t6g-e36-seg-log.txt` 里没有 `W Bundle` 类型警告，也没有 `ignoring EXTRA_SEGMENTED_SESSION`：36 的识别器接受了这个请求。事件（`p0/t6g-e36-seg.txt`）：`ready`、`begin`，松手后来了一个 `segment`（`text: []`，空），然后 `error 7`、`end`；`rms` 只有 1 次、最大 -2.0，声音没有确认进入识别器。所以「请求被接受」有日志为证；「分段结果能收到」没有：唯一的 `segment` 是空的，没有文字。
- 平板上同样的 `int` 请求（`p0/t6g-tab-seg.txt`、`-log.txt`）：和之前一样，`start` 之后没有任何回调，保存下来的日志只留了语音相关的行（其余系统行滤掉了），所以「没有 `W Bundle` 行」说明不了什么；平板的识别服务没有给第三方回调，所以不能说它接受或拒绝。

热词用 `EXTRA_BIASING_STRINGS`（字符串列表）。

**模拟器 36**（第一次测量，Mac 未锁屏，每次说话前用 `tools/locked` 查过，这一条没有保存的文件；`RECORD_AUDIO` 用 `pm grant` 授予）：

| 次 | 设置 | 事件顺序 | 文字 |
|---|---|---|---|
| 普通一段 | 在线，`zh-CN` | `ready`（`rms` 0，`rmsMax` -1000）、从 `start` 事件起约 0.86 s 后 `begin`、松手（`up`）后 0.26 s `error 7`（`NO_MATCH`）、`end`；`end` 上 `rms` 5、`rmsMax` 10.0。日志摘录：`#onResults empty final recognition results`、`no speech - erroring`、`agsa_transcription_NO_SPEECH_DETECTED`（`p0/t6f-e36-plain-log.txt`） | 没有（没有 `partial`、`final`） |
| 分段（`Long`，被拒绝） | 见上 | `ready`、`begin`、`error 7`、`end`，没有 `segment`；`rms` 只有 1 次、最大 -2.0 | 没有 |
| 热词 | `EXTRA_BIASING_STRINGS=[rApp]` | `ready`、`begin`、`error 7`、`end`；`rms` 只有 1 次、最大 -2.0，声音没确认进入，热词效果**没测** | 没有 |
| 设备上、`cmn-Hans-CN` | 先点 `download` 触发语言包下载，再勾「设备上」「cmn-Hans-CN」按住 | `start` 后 0.04 s 就 `error 13`（日志 `agsa_transcription_LANGUAGE_PACK_ERROR`），`end`；之后又来一个 `ready`，松手时 `error 5`，日志有 `#stopListening called with no preceding #startListening - ignoring`（`p0/t6f-e36-ondevice-cmn-log.txt`） | 没有 |

下载这一步：当时在屏幕上看到「Download 普通话 (中国大陆) update」对话框、52.97 MB，点了 Download；日志里看到过 `onEndTriggerModelDownload(): success`；这两处没有留文字证据（屏幕只有截图 `p0/t6f-e36-download.png`，日志没存）。下载之后再查 `support`（`p0/t6f-e36-support-after-download.txt`）：`installed` 仍是 `[en-US]`，`pending: [cmn-Hans-CN]`。语言包为什么没就绪，没查明。

第二次测量（36，20:18:29–20:20:12；Mac 未锁屏：Mac 的服务日志 `t6-mac-lock-times.txt` 里 20:16:14 解锁、20:22:40 才自动锁上（该文件里的时间戳是 UTC，和本行的钟点不是同一个计法），每次也用 `tools/locked` 查过）。两次在线运行（分段 `int`、普通一段）的 `rms` 都只有 1 次、停在 -2.0，包括和第一次测量普通一段设置相同的那次（那次是 5 次、最大 10.0）：Mac 没锁，这两次声音却没进识别器，原因不明，没有查出来。设备上那次不一样：`start` 后约 0.12 s 就 `error 13`，没有 `ready`，`rms` 0，没开始收音。请求是否被接受只看日志，不依赖声音：
- 分段 `int`：见上，请求被接受，`rms` 1 次 -2.0，没有声音进入的证据。
- 设备上 `cmn-Hans-CN`：`error 13`、`end`，之后没有 `ready`，松手时没有 `error 5`，日志里也没有 `no preceding #startListening`（`p0/t6g-e36-ondevice-cmn.txt`、`-log.txt`）：`stop` 改成只在会话还在时才调 `stopListening` 以后，`error 5` 不再出现。`error 5` 的原因：`stop` 在会话已经结束后又调了 `stopListening()`，是探查页自己引起的，不是识别器的行为。
- 普通一段又跑了一次（`p0/t6g-e36-plain.txt`）：`rms` 1 次 -2.0，`error 7`，同样没有声音进入的证据。

36 上没有拿到任何中文字。第一次测量里普通一段 `rms` 5 次、最大 10.0，识别器给的是「没有检测到语音」；其余在线的几次（第一次测量的分段、热词，第二次测量的分段、普通一段）`rms` 都停在 -2.0，不能当成「分段/热词没效果」的证据。第一轮（Mac 当时锁屏、没有 `rms`）的 36 结果不再引用。

**平板（实机）**（按规则是「不能用」，仍照要求试了；没有同意书、登录、下载或密码界面，这一条只靠截图，没有别的证据）：

| 次 | 设置 | 事件顺序 | 文字 |
|---|---|---|---|
| 普通 1 | 没调 `support`，按住 14 s | `start` 之后一个回调都没来：没有 `ready`、`begin`、`error`、`end`，`rms` 没有。日志摘录：`SpeechRecognitionManagerServiceImpl: Client … has opened 1 sessions`，`AppOpsControllerImpl: onActiveChanged(…, com.hihonor.magicvoice, true …)`，`PrivacyItemController: updatePrivacyList: (microphone, com.hihonor.magicvoice …)`（`p0/t6f-tab-plain1-log.txt`） | 没有 |
| 普通 2 | 没调 `support` | 同普通 1 | 没有 |
| 普通 3 | 先调了 `support`（两条回答同 6.1），再按住 | 同普通 1 | 没有 |
| 分段（`Long`） | 第一次测量 | 同普通 1 | 没有 |
| 热词 | `[rApp]` | 同普通 1 | 没有 |
| 分段（`int`） | 第二次测量 | 同普通 1 | 没有 |

六次都是 `force-stop` 后重开，结果一样：没有任何回调。第一轮平板上出现过的 `error 11`，之后没有再出现；第一轮的写法是先 `destroy` 再创建，之后改成复用，是否就是这一差别引起，没有单独验证。静默与 `support` 调不调无关（普通 1、2 没调，普通 3 调了）。平板的系统日志只证明：系统记了「客户端打开 1 个会话」，`com.hihonor.magicvoice` 在使用麦克风；没有证据显示它为什么不回调。分段、热词在平板上没有结果，无法判断是否生效。

### 6.3 P1 要知道的

- 判「能不能用」的调用：`SpeechRecognizer.isRecognitionAvailable(context)`、`isOnDeviceRecognitionAvailable(context)`（API 33）、`checkRecognitionSupport(intent, executor, RecognitionSupportCallback)`，intent 是 `ACTION_RECOGNIZE_SPEECH` + `EXTRA_LANGUAGE`。在线识别器用 `createSpeechRecognizer(context)`，设备上的用 `createOnDeviceSpeechRecognizer(context)`（没有设备上识别器时抛 `UnsupportedOperationException`，要 try/catch）。
- `checkRecognitionSupport` 在没有识别服务时回调**一直不来**，要自己加超时（探查用了 10 秒）。
- 清单要 `RECORD_AUDIO` 和 `<queries><intent><action android:name="android.speech.RecognitionService"/></intent></queries>`（探查里加了，没做不加的对比）。
- 默认识别服务的包名：探查里读了 `Settings.Secure` 的 `voice_recognition_service`，两个有识别服务的目标上都是 `包名/类名`。这是没写进文档的隐藏键，P1 不用它；P1 用 `packageManager.queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)` 找识别服务（规格 §11 已改）。
- `start` 的 intent：`ACTION_RECOGNIZE_SPEECH`，`EXTRA_LANGUAGE_MODEL = LANGUAGE_MODEL_FREE_FORM`、`EXTRA_LANGUAGE`、`EXTRA_PARTIAL_RESULTS = true`；热词（API 33）`EXTRA_BIASING_STRINGS`。
- 分段：`EXTRA_SEGMENTED_SESSION` 的值写 `EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS`，同一 intent 里再用 `putExtra(…, 2000)` 给 `int`，**不能给 `Long`**：36 的 Google 识别器按 `int` 读，给 `Long` 会读成 0 并忽略分段（原样日志见 6.2）。给 `int` 时 36 的识别器接受（日志里没有拒绝），但还没有收到过带文字的 `segment`（只有一个空的），所以「识别器支持分段」没有确证；P1 要在能出字的机器上再验，`segment` 不来时按规格走「一段结束手还按着就立刻开下一段」。
- 热词 `EXTRA_BIASING_STRINGS`：没报错，效果没测（`rms` 停在 -2.0）。
- 识别器的建法（**没有被任何一次保存的运行验证过**）：本探查的写法是一种模式一个 `SpeechRecognizer`、复用、开始前 `cancel()`、只在 `error 11` 时销毁重建；每次运行都是新进程里的 `run: 1`，也没有出现过 `error 11`，销毁重建那条路径没跑过；复用那条至多在一次运行里走到过：`download` 会建好设备上识别器却不增加 `run`，之后同一次页面里的设备上 `start` 走的是复用分支（先 `cancel()`），很可能就是第一次测量的设备上 `cmn-Hans-CN` 那次，它的事件顺序怪（先 `error`、`end`，然后才 `ready`）。所以复用这个设计没有验证过，P1 不要照抄。
- 探查页的一个缺口，P1 不要照抄：`run`、`rms` 次数、`rmsMax` 是在回调到达时从页面的全局变量里读的，不是开始时捕获的；复用同一个识别器时，上一轮迟到的回调会被算进新一轮。`listening` 标志也是一个全局变量，不是每次运行、每个识别器各一个：上一轮迟到的回调可能把它清掉，新一轮的 `stop` 就跳过 `stopListening()`；`startListening` 抛异常时它会一直是 `true`；`download` 改了 `current` 却不动它。
- 探查页的其他缺口（读代码看到的，P1 不要照抄）：
  - `support`：先设了 10 s 超时，`checkRecognitionSupport` 之后再抛异常时，`catch` 里又回一次，同一个调用可能回两次。
  - `support` 的 intent 只带了 `EXTRA_LANGUAGE`（`zh-CN`），没带 `EXTRA_LANGUAGE_MODEL`；`start` 的 intent 带了。P1 两处一样带上。
  - `onEndOfSegmentedSession` 发单独的 `segmentsEnd`，再发 `end`（`MainActivity.kt:250`）。P1 照这样：分段结束是单独的事件，不要用带占位文字的 `final` 顶替。
  - 没有麦克风权限时，`start` 弹出权限请求、回 `permission-requested` 就结束了；用户同意后要再按一次。P1 要让这个回答走 `error` 事件或明确的结果，不要让 Dart 一侧以为录音已经开始。
  - `gui/test/p0_speech_test.dart` 只测了 Dart 一侧的原样转发。Kotlin 一侧的计数、识别器复用没有测试，也没有「按下 → `start`、松开 → `stop`」的测试。
- 看到的错误码，及在哪些保存的文件里、已知的原因（文件名按 grep 核过）：
  - 14（`ERROR_CANNOT_CHECK_SUPPORT`，`support` 在线路径）：第一轮（36、平板：`t6-e36-probe-support.txt`、`t6-tab-probe-support.txt`、`t6-tab-support.txt`）和第一次测量（`t6f-e36-support-after-download.txt`、`t6f-tab-plain3support.txt`）；第二次测量没有调 `support`，没有证据。
  - 7（`ERROR_NO_MATCH`）：36 上在线识别，第一轮、第一次测量、第二次测量都有；日志里是 `NO_SPEECH_DETECTED`（`t6f-e36-plain-log.txt`）。
  - 13（`ERROR_LANGUAGE_UNAVAILABLE`，日志里叫 `LANGUAGE_PACK_ERROR`）：36 设备上 `cmn-Hans-CN`，下载之后（第一次、第二次测量）；语言包为什么没就绪没查明。
  - 12（`ERROR_LANGUAGE_NOT_SUPPORTED`）：只在第一轮见过（36 设备上，`t6-e36-ondevice.txt`），当时中文包还没下，原因没查实；之后没再试，没有日志摘录。
  - 11（`ERROR_SERVER_DISCONNECTED`）：只在第一轮见过，36（`t6-e36-hotwords.txt`）和平板（`t6-tab-plain2.txt`）都有；当时的探查页在创建前先 `destroy`，可能就是原因，之后的两次测量没有再出现，没验证。
  - 5（`ERROR_CLIENT`）：第一轮 36（`t6-e36-ondevice.txt`、`t6-e36-hotwords.txt`）和第一次测量 36 设备上（`t6f-e36-ondevice-cmn.txt`）都出现过；第一次测量那次，日志里有 `stopListening called with no preceding #startListening`，说明是探查页的 `stop` 在会话已结束后又调了 `stopListening()`，是页面自己引起的；第一轮的两次原因没查。加了 `listening` 判断之后，第二次测量没再出现（那次只有 `error 13` 后直接松手，没有别的事件）。
- 识别时的时间（第一次测量，36，普通一段、分段、热词三次；`ready`、`begin` 从 `start` 事件起算，`error 7` 从松手 `up` 起算）：`ready` 0.027–0.038 s（从 `start -> started` 那行算是 0.026–0.037 s），`begin` 0.86–0.91 s，`error 7` 0.26–0.80 s；从按下 `down` 算 `ready` 约 0.029–0.041 s；没有结果，没有可量的首字时间。
- 国行平板（荣耀）：`probe` 有识别服务，`onDevice` 假，`support` 报 14，识别没有任何回调（六次）。规格 §11 原来写的「国行平板上多半走到第 3 条」不准确：这台平板按手算走的是规则 4（`support` 报 14），结论同样是不能用（规格 §11 已改）。

## 7 自己装自己

做法：探查页 `install` 显示本包 `versionCode` 和 `canInstall`；「下载并安装」从 `http://127.0.0.1:8765/app.apk` 下到 `<cache>/update/rapp.apk`，对 `app.sha256` 里的 SHA-256，对上才调 `installApk`（`PackageInstaller` 会话，系统要确认就把确认界面拉起来，结果以 `install` 事件回到页面）。调用写法：`PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)`，`createSession`、写入后 `session.commit(PendingIntent.getBroadcast(this, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender)`；`FLAG_MUTABLE` 不能省，安装器要往这个 intent 里填 extras。接收器 `registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)`（API 33 起，低版本用不带标志的重载）。收到 `PackageInstaller.STATUS_PENDING_USER_ACTION`（-1）时，取 `Intent.EXTRA_INTENT`，加 `Intent.FLAG_ACTIVITY_NEW_TASK` 后 `startActivity`；`STATUS_SUCCESS`（0）回 `success`，`STATUS_FAILURE_ABORTED`（3）回 `cancelled`，其余回 `failure`。「去设置」打开本包的「安装未知应用」页。两个包都是调试包：`p0-old.apk` 是 `versionCode` 9001，`app.apk` 是 9002（`flutter build apk --build-number`）。本机 `python3 -m http.server 8765 --bind 127.0.0.1`，`adb reverse tcp:8765 tcp:8765`。证据在 `p0/t7-*`。

### 结果（三台）

| 目标 | 过关线：`versionCode` 9001 → 9002 | 结论 |
|---|---|---|
| 模拟器 34（Android 14，AOSP） | 9001 → **9002** | **过** |
| 模拟器 36（Android 16，google_apis） | 9001 → **9002** | **过** |
| 平板（实机，HONOR ROD2-W09，Android 16，MagicOS 10） | 停在 9001 | **没装完**：装的最后一步要输入锁屏密码，不能替用户输；留给实机，在 P1 第一个包上做（规格 §14.6 第 10 条） |

### 7.1 干净安装、开开关、装

| 目标 | 动作 | 系统显示（原话） | 测到的值 | 过没过 |
|---|---|---|---|---|
| 模拟器 34 | `adb uninstall`，装 `p0-old.apk`，启动 | 页面：`versionCode: 9001`、`canInstall: 否` | `dumpsys` 里 `versionCode=9001`；`appops get … REQUEST_INSTALL_PACKAGES` = `No operations. Default mode: default` | 是 |
| 模拟器 34 | 点「去设置」 | 打开的是 rApp 那一页，标题 `Install unknown apps`，开关 `Allow from this source`，下面写 `Your phone and personal data are more vulnerable to attack by unknown apps…`（这几句是当时从界面树读出来的，没存成文本文件，证据里只有截图 `t7-e34-2-settings.png`） | — | 是（就是本包那一页） |
| 模拟器 34 | 点开关，返回 | 返回后页面立刻刷成 `canInstall: 是`（页面回前台时重读） | `appops` = `REQUEST_INSTALL_PACKAGES: allow` | 是：`canInstall` 从否翻成是 |
| 模拟器 34 | 点「下载并安装」，系统确认 | 对话框 `Do you want to update this app?`，按钮 `CANCEL` / `UPDATE`（不是「安装」：同包名的升级，不弹权限清单） | 页面先收到 `pending`（code -1，`STATUS_PENDING_USER_ACTION`） | — |
| 模拟器 34 | 先点 `CANCEL` 试一次 | 页面收到 `cancelled`，code 3（`STATUS_FAILURE_ABORTED`），message `INSTALL_FAILED_ABORTED: User rejected permissions`；这一遍之后没有列缓存；缓存里 `rapp.apk` 的存在只在后面那次成功安装之后列过（`t7-e34-step2.txt`） | `t7-e34-cancel-event.txt` | 取消这条路通 |
| 模拟器 34 | 再下载，点 `UPDATE` | 对话框消失，桌面出现，App 不在 | 2 秒后 `pidof` 为空，之后 12 秒一直空；`versionCode=9002` | **过** |
| 模拟器 36 | 同上，`canInstall` 起点也是 `否`；设置页标题 `Install unknown apps`，开关 `Allow from this source`，说明文字同 34（同样是当时从界面树读的，文本文件里没有，只有截图 `t7-e36-2-settings.png`） | 开开关后 `appops` = `allow`，页面 `canInstall: 是` | 对话框 `Do you want to update this app?`，`Cancel` / `Update`。文本证据：`t7-e36-confirm-screen.txt` 里抓到的系统界面只有这个更新确认框，没有别的界面，也没有 Play Protect 的。截图 `t7-e36-4-confirm.png` 是另一份证据，里面也只有这个框。没有专门去查 Play Protect | 是 |
| 模拟器 36 | 点 `Update` | 桌面（Nexus Launcher），App 不在 | `pidof` 空 12 秒；`versionCode=9002` | **过** |
| 平板（实机） | `adb install p0-old.apk`（不弹任何东西），启动 | 页面 `versionCode: 9001`、`canInstall: 否` | `appops` = `No operations. Default mode: default` | 是 |
| 平板 | 点「去设置」 | 标题 `安装外部来源应用`，行 `rapp 版本 0.15.58`，开关行 `允许安装应用`，说明 `设备和个人数据更容易受到从未知来源获取应用的攻击。对于因使用这些应用而造成的设备损坏或数据丢失，您同意自行承担全部责任。` | — | 是（本包那一页） |
| 平板 | 开开关 | 点**文字行不起作用**，要点右边的开关本身（0.15.58 那页行里的开关节点在 `uiautomator` 里没有文字）；开后没有二次弹框 | `appops` = `REQUEST_INSTALL_PACKAGES: allow`；返回后页面 `canInstall: 是` | 是 |
| 平板 | 点「下载并安装」 | 先是荣耀自己的安装页，`rapp 版本 0.15.58 来自“rapp”`，转圈 `安全检测中…`，底部提示 `外部来源应用检查需要联网并启用系统管家，帮助识别潜在风险`（只是提示，没去改设置）；几秒后变成橙色警告 `未经荣耀安全审核 / 该应用未上架，未经荣耀应用市场安全审核，请谨慎安装。`，有一个未勾的选项 `已了解此应用未经荣耀应用市场检测，可能存在风险。`、一个 `用过该应用的还喜欢`、`取消`、`继续安装`（截图里是灰的，勾选项之前；只看了截图，没抓文本）（右上角一个设置齿轮，没动） | 页面收到 `pending` | — |
| 平板 | 勾选项，点 `继续安装` | 弹出系统的验证框：`输入锁屏密码继续安装应用`，输入区提示 `密码共 6 位`，只有一个 `取消` | 这时 `versionCode` 仍 9001，`pidof` 不变 | **没装完**：不输密码，点了 `取消` |
| 平板 | `取消` 回到荣耀安装页，再点 `取消` | 回到探查页 | 页面收到 `cancelled`，code 3，message 同 34（`INSTALL_FAILED_ABORTED: User rejected permissions`）；`versionCode=9001`，标记文件还在 | 取消这条路通 |

留给实机的：探查结束时探查包已从平板卸掉，这一遍在 P1 第一个包上做（规格 §14.6 第 10 条）：在平板上走一遍「下载并安装 → 勾 `已了解…` → `继续安装` → 输锁屏密码」，看 `versionCode` 变新、App 是被杀还是自己起来。

平板上的「安装外部来源应用」开关是这次测的时候打开的；卸掉探查包后这项授权跟着没了（`appops` 回到默认），P1 第一个包要重新打开。

### 7.2 装完之后 App 怎么样了（不作过关线）

| 目标 | 装完 | pid 前 → 后 | 用户看到什么 | 标记文件（装前 `run-as` 写在 `files/`） | 缓存里的包 |
|---|---|---|---|---|---|
| 模拟器 34 | **被杀，没有自己重启**，`dumpsys notification` 里没有本包的通知（计数 0，`t7-e34-step2.txt`），没有看到「打开」提示 | 2159 → 无（点图标后新起 2720） | 确认框一消失就回到桌面；要点桌面图标才回来，页面显示 `versionCode: 9002`、`canInstall: 是`（开关没丢） | **在**，内容 `marker-9001` | **还在**，`rapp.apk` 91156353 字节 |
| 模拟器 36 | 被杀，没有自己重启；「打开」通知**没查** | 6424 → 无（点图标后 6843） | 桌面，要点图标 | **在** | **还在** |
| 平板 | 没装成，没测 | 12426，没变 | — | 没动，在 | 没装成，所以还在 |

`install` 事件：`success` **没有观察到，而且从页面上观察不了**：点 `UPDATE` 后 2 秒内进程就没了，页面的日志只在内存里，随进程一起丢；重开后日志是空的，这说明不了回调到没到过。所以「装成」不能靠这个回调判断，要靠重开后读到的新 `versionCode`（回调到不到都一样）。看到过的只有 `pending`（要用户确认）和用户取消时的 `cancelled`（code 3）。

### 7.3 哈希不对的那一遍

`app.sha256` 改成 64 个 `0`，在 9001 的包里点「下载并安装」。四个条件：

| 目标 | 页面报校验失败 | 系统确认界面没出现 | `<cache>/update/rapp.apk` 被删 | `versionCode` 还是 9001 |
|---|---|---|---|---|
| 模拟器 34 | 是：`p0 install error 校验失败：期望 0000…（64 个 0），实际 46c800c1…` | 是（前台还是本 App） | 是（`ls` 目录为空，`total 0`） | 是 |
| 平板（实机） | 是，同样一行 | 是 | 是（`total 0`） | 是 |
| 模拟器 36 | 没测（36 上只测了正常安装） | — | — | — |

文件是下载完、算完哈希、不对就立刻删，不留给安装器。

### 7.4 各台多出来的界面

- 模拟器 34、36：只有一个系统确认框（`Do you want to update this app?`）。36 上抓到的系统界面只有这一个确认框，没看到别的，也没专门查 Play Protect。注意这是**同包升级**；全新安装的确认框没测，会多一份权限清单。
- 平板（荣耀）：开关页之后多出**三层**：① 荣耀安装页的 `安全检测中…`（要联网并启用系统管家，否则底部提示上面那句）；② 橙色警告 `未经荣耀安全审核` 加一个必须勾的 `已了解…`，`继续安装` 看截图是勾之前灰、勾了之后可点（只看了截图）；③ `输入锁屏密码继续安装应用`（6 位密码）。这三层只在这台机器、这个 MagicOS 版本上、走了一遍时见过，「每次装都出现」没验证。
- 平板上没有「上传或扫描」的提示。

### 7.5 P1 要做的（从这些现象来）

1. **装完不会自己回来，成功回调也靠不住（没观察到，页面观察不了）。** 用户点系统的确认后，App 立刻被杀。「更新」按钮旁要不要提前说一句、怎么说，见建议 3。更新器不能指望装完在原进程里做事。
2. **判断是否装成功：下次启动读自己的 `versionCode`**，和启动前存下的「正在升到 y」比。比对上就清状态、删缓存的包。`installApk` 的 `pending`、`cancelled` 事件可以用来把「正在安装」状态退回「有新版本」。
3. **装完缓存里的包还在**（91 MB）：下一次启动要删 `cacheDir/update/`；校验失败这一支已经删了。
4. **进程被杀时一份状态要先落盘**（正在装、目标版本），因为进程回不来做收尾。
5. 数据在：标记文件在 `files/` 里，升级后还在，开关也还在，无需迁移。
6. **`canInstall` 要在回前台时重读**：用户开了开关回来，页面用 `AppLifecycleState.resumed` 刷新就够，不需要轮询。
7. **平板上还会有荣耀的三层界面**（见 7.4）：「更新」前要不要提示、怎么提示，见建议 1；没有锁屏密码的机器是什么样没测。
8. 清单要有 `REQUEST_INSTALL_PACKAGES` 和网络安全配置（探查里已写好）。这两样在正式包里也生效，不只是调试包。网络安全配置只对 `localhost`、`127.0.0.1` 放行明文：探查里给的是本机文件服务，P1 里给的是本机的 AI 整理（规格 §6.4）；P1 里真正的下载走 https，不要把明文放开到别的地址。
9. 探查代码里的缺口（读代码看到的，P1 不要照抄）：
   - 接安装结果的广播接收器在 `configureFlutterEngine` 里注册、`onDestroy` 里注销，只跟着 Activity 活。P1 放进清单里的接收器或一个服务。
   - `installApk` 里 `openWrite` 或 `copyTo` 抛异常时，没有 `abandon()` 安装会话。
   - 91 MB 的拷贝在 UI 线程上做。
   - Dart 的 `HttpClient` 没设超时。
   - 下载出错时，没先关 `sink` 就删文件。
   - 哈希已对上、`install()` 却抛异常时，文件留着不删。
   - 测试只有哈希对和哈希不对两种；没有测非 200、下载中断、`install()` 抛异常。

### 7.6 和规格 §13.2 第 4 步

规格原来写「装完 App 被系统重启」。两个模拟器上看到的是：App 被杀，**没有**重启，也没有提示，要用户点图标。已把规格里这句改成观察到的样子（平板没验证到这一步）（规格 §13.2、§14.1 第 7 条已改）。

## 8 数字

**状态：部分过。** 大小、PSS、release 30 s fps 都量了；没量的只有强制走 relay 的 fps，留给实机（规格 §14.6 第 12 条）。

**本节的 MB：** 文件大小 MB = 10⁶ 字节；PSS 的 MB = 1000 个 `dumpsys meminfo` 的 KB（dumpsys 的 KB 是 1,024 字节）。

### 大小

三台最后装的是同一个 release 包 `p0/t4g-release.apk`，29,544,999 字节（29.5 MB）。它和 `p0/t4f-release.apk` 一样大，`.so` 的大小取自 `p0/t4f-sizes.txt`（`unzip -lv`，都是 Stored，不压缩）：

| `.so` | 字节 | MB |
|---|---:|---:|
| `libapp.so` | 8,258,448 | 8.26 |
| `libflutter.so` | 11,579,920 | 11.58 |
| `librapp_android.so` | 7,552,928 | 7.55 |

构建命令：`flutter build apk --release --target-platform android-arm64`。这个包带 hub 64 KiB 的绕过（第 4 节），fps 行带帧大小，超长行日志带请求名。

早一版的包（`p0/t4e-release.apk`，下面模拟器 34 的 PSS 是在它上面量的）：29,522,135 字节，`librapp_android.so` 7,530,064 字节，另两个 `.so` 一样（`p0/t4e-sizes.txt`）。

### 模拟器 34 上的 PSS（早一版的包）

- 命令：`adb -s <目标> shell dumpsys meminfo com.rapphub.rapp | grep 'TOTAL PSS'`，每 10 s 一次共 6 次（`scratchpad/tools/sample.sh <out> 6 10`）。
- 没开会话、停在总览页（`am force-stop` 后重新启动、等 40 s）：89633、89512、88344、87640、87684、89900 KB，平均 88786 KB（88.8 MB）。不带绕过的包同样量法：平均 90862 KB（90.9 MB）。证据 `p0/t4e-nosession-34.txt`（文件里的 `p0 fps` 行是 force-stop 之前那个进程留在 logcat 里的，不算）、`p0/t4-pss-nosession-34.txt`。
- 开着静态 2560×1600 桌面会话（路由自动，局域网）：191609、323376、193956、192720、226652、193968 KB，平均 220380 KB（220.4 MB）。6 次里有两次尖峰（323376、226652），其余 4 次 191609–193968 KB（191.6–194.0 MB）。证据 `p0/t4e-static-34.txt`。

### 三台的 fps 和 PSS

三台装的都是上面那个 release 包 `p0/t4g-release.apk`。

**release 动画面 30 s 平均 `p0 fps`。**
- 条件：`debug.rapp.p0_slow_ms=0`，P0Moving，帧 `2576x1680`，路由自动（局域网）。
- 命令：`scratchpad/tools/fps30.sh <out>`：先 `adb -s <目标> logcat -c`，等 31 s，取最新的 30 行 `p0 fps`（每秒一行）和 30 行 `p0 traffic`，过打码脚本后求平均。
- Mac 上的 rApp 是 0.15.64，Mac CPU 持续 90% 以上。

| 目标 | 平均 | 最小–最大 | traffic `frames` 平均 | 证据 |
|---|---:|---|---:|---|
| 平板（实机） | 26.1 | 20–32 | 28.1 | `p0/t4g-fps30-tab.txt` |
| 模拟器 34（模拟器，只作参考） | 26.0 | 21–30 | 29.7 | `p0/t4g-fps30-34.txt` |
| 模拟器 36（模拟器，只作参考） | 25.1 | 19–29 | 29.8 | `p0/t4g-fps30-36.txt` |

**平板的屏幕刷新率。** `adb -s <平板> shell dumpsys display`：主屏可选 60 / 90 / 120 / 144 Hz，量的时候在 60 Hz；另有一个 PC 模式的显示（display 2）是 144 Hz。

**PSS。**
- 命令：`adb -s <目标> shell dumpsys meminfo com.rapphub.rapp` 取 `TOTAL PSS`，每 10 s 一次共 6 次（`scratchpad/tools/sample.sh <out> 6 10`）。
- **静态 PSS 是单应用会话（TextEdit，文档不动）的**，和上面模拟器 34 那个 2560×1600 桌面会话的 PSS 不是一回事，不能直接比。
- 「静态」不是没有帧：文档不动时每秒仍到几帧，采样时记下的 `p0 fps` 在 36 上是 4–6，平板上是 3–7。6 次之间摆动也大：36 是 140.2–173.3 MB，平板是 415.9–463.4 MB。平均数只作大概。

| 目标 | 情形 | 6 次（KB） | 平均 | 证据 |
|---|---|---|---:|---|
| 模拟器 36 | 没会话：刚装上、启动后停在总览，等了约 70 s | 90043、90194、87464、88180、88960、89900 | 89.1 MB | `p0/t4g-pss-none-36.txt` |
| 模拟器 36 | 静态单应用会话（帧 `2576x1392`；Mac rApp 0.15.66） | 140299、173271、160203、168619、140214、169154 | 158.6 MB | `p0/t4g-pss-static-36.txt` |
| 平板（实机） | 没会话：`am force-stop` 后重新启动，等 40 s，总览显示 0 个活动 | 209366、209334、209658、208402、208006、209182 | 209.0 MB | `p0/t4g-pss-none-tab.txt`、`p0/t4g-tab-none.png` |
| 平板（实机） | 静态单应用会话（帧 `2416x1376`） | 463356、415890、427250、447434、459566、460954 | 445.7 MB | `p0/t4g-pss-static-tab.txt` |

平板和模拟器不同：平板的 PSS 是模拟器 36 的好几倍：没会话时 209.0 对 89.1 MB（约 2.3 倍），静态单应用会话时 445.7 对 158.6 MB（约 2.8 倍）。30 s fps 三台差不多。

## 探查里打的补丁（P1 的输入）

| 文件和位置 | 改了什么 | 为什么 | P1 里它属于哪个接口 |
|---|---|---|---|
| `gui/lib/hub_ffi.dart` `_open`、`_Lib(lib)`、`_stopOffThread(library)`、`start(library:)` | 库由入口传名字，`null` = `DynamicLibrary.process()` | 安卓的 hub 在 `librapp_android.so` 里；`DynamicLibrary` 传不进 `Isolate.run`，所以传名字 | §6.1 `FfiHubTransport`（可以原样留下） |
| `gui/lib/main.dart:40` | `if (Platform.isAndroid) return mainAndroid();` | 安卓入口 | 入口分流（原样留下） |
| `gui/lib/main_android.dart` 整个文件 | 从 `main_ios.dart` 抄，去掉 Rime、等网络、`BackgroundWatch`、`FoldFullscreen`；`fullscreen: const NoFullscreen()`；没有 `localOs`、`localIme` | 最小能跑的安卓入口 | `main_android.dart`（§6.3、§6.4 一带）；和 `main_ios.dart` 的共用部分 P1 抽（§15.3） |
| `main_android.dart` 开头 `caps = const PlatformCaps(hubInProcess: true)` | 旁路能力表 | `forOs('android')` 落进桌面默认，不出接入引导；`systemOpen` 留 false，因为它走 `iosChannel` | §6.5 `PlatformCaps.forOs` 的 `'android'` 项；`systemOpen` 要先接安卓通道 |
| `main_android.dart` `port = LinuxSessionPort.ffi('librapp_android.so', downloads: () => '<数据根>/files/transfers', slow: P0_SLOW_MS)` | 第 3 项时留空，第 4 项接上；`P0_SLOW_MS` 是探查用的慢 Dart 开关 | 第 4 项 | §6.3 安卓的 `SessionPort`（`P0_SLOW_MS` 不进 P1） |
| `gui/lib/embed/session_ffi.dart`（新） | `FfiSession`：`NativeCallable.listener` 收包，帧零拷贝（`asTypedList` + `rapp_session_free` finalizer），`ackedPackets` 在下一次取包时 ack；`close` 放进 `Isolate.run`（最多阻塞 2 s）；`p0 fps` / `p0 traffic` 日志 | 进程内会话，不起子进程 | §6.3 `SessionLink`（日志不进 P1） |
| `gui/lib/embed/session_worker.dart` `SessionWorker.ffi` + `_FfiSessionWorker` | 新加的构造函数，把 `FfiSession` 包成 `SessionWorker`；`pid` 返回会话 id | `LinuxSessionPort` 只认 `SessionWorker` | §6.3 `SessionLink` |
| `gui/lib/embed/linux_session_port.dart` `LinuxSessionPort.ffi` | 新加的构造函数：`executable = ''`，`init` 不查可执行文件，`start` 用 `SessionWorker.ffi` | 安卓没有 `rapp-session` 可执行文件 | §6.3 `SessionLink`（怎么起会话）；其余留在 `SessionHost` |
| `linux_session_port.dart` 里没改、安卓上空转的：`rapp/linux` 通道（`init`、剪贴板、detach 的 `nativeFrame` / `nativeWindows` / `focus`），`reveal` 的 `xdg-open`，`_traceStream` 读 `RAPP_STREAM_TRACE_DIR`，`downloads` 默认值读 `Platform.environment` | 没改。异常都已被接住；`downloads` 由入口传 | 第 4 项桌面会话不需要它们 | §6.3 `SessionHost`：P1 给安卓换成安卓通道（剪贴板、打开文件），去掉 detach 和 trace |
| `main_android.dart` `_log` 用 `debugPrint` | 不用 `stderr.writeln` | 安卓上 stderr 到不了 logcat | 安卓入口的日志（或写文件） |
| `gui/android/.../MainActivity.kt` | `rapp/android` 通道：`paths`（`filesDir`、`cacheDir`）、`deviceName`（写死 `rApp P0 探查`） | 数据根和设备名 | 安卓平台通道；`deviceName` P1 取真名（`Settings.Global.DEVICE_NAME` 之类） |
| `gui/android/app/src/main/AndroidManifest.xml` | `INTERNET`、`ACCESS_NETWORK_STATE`、`allowBackup="false"` | 连网；身份密钥不进备份 | §6.4 Kotlin 壳的清单（留下；还差 `dataExtractionRules`） |
| `gui/lib/embed/session_ffi.dart` `ackedPackets(slowNow:)`、`p0SlowFromProperty()`、`FfiSession._readSlow()`、`_count` 里的 `_size` | ack 前的等待每帧读 `slowNow()`；每秒从系统属性 `debug.rapp.p0_slow_ms` 读一次（`__system_property_get`）；属性没设或不是数字时用 `main_android.dart` 的 `P0_SLOW_MS`。`p0 fps` 行带上帧头里的宽高（`size=WxH`） | 同一个会话里切换慢速和对照，不断会话（断了 Mac 会自动锁屏） | 不进 P1（探查用）；ack 本身属于 §6.3 `SessionLink` |
| `rust/hub/src/link.rs` `request()` 两处 + 新函数 `keeps_link`、`op_name` | 连接还开着、错误是 `line longer than` 时只交回错误、记 `p0_keep_link`（带请求名 `op`），不 `forget` / `forget_if_dead` | `watch_load` 首行超 64 KiB 时 hub 丢整条连接（第 4 节第二次测量）。丢连接这段是所有平台共用的 hub 代码；会话因此全断只在探查的进程内会话里见过，桌面没测 | 不属于 §6.3 的任何安卓接口，**不进 P1，真修法在 main**（共用的 hub：`rust/hub`、`rust/net`、service 的 `watch_load` 回复）。撞上的只有 `watch_load`，首行 75,125 字节（第 4 节第三次测量）。绕过之后，建流时 `watch_load` 首行若已超上限（Mac 服务起来约 52 分钟以后，历史点超过约 619 个；服务重启后从头算），就约每分钟失败一次，余力到不了安卓控制端；建流时历史还短就到得了、之后一直在（第 4 节「余力什么时候到得了」）。要等真修法，记在 `tasks/todo.md`「安卓平板」 |
| `rust/net/src/quic.rs` `pub use sys::getaddrinfo_v6;` | 公开给探查函数 | `rapp_p0_resolve` 要单独看这一支 | 不进 P1（探查用） |
| `rust/android-ffi` `rapp_p0_resolve`；`Cargo.toml` 加 `rapp-net`、`tokio` | 返回 `getaddrinfo_v6` 和 `resolve_for(dual)` 两行 | 第 3 项的解析探查 | 不进 P1（探查用） |
| `gui/lib/p0/p0_pages.dart` | `P0_PAGE=resolve` 页；`P0_PAGE=keys` 页（`KeysPage`、`formatKeyEvent`、`formatPointerEvent`）；`P0_PAGE=speech` 页（`SpeechPage`）；`P0_PAGE=install` 页（`InstallPage`） | 探查页 | 页面不进 P1 |
| `p0_pages.dart` `p0DownloadAndInstall` | 下载到 `<cache>/update/rapp.apk`，对 SHA-256，对上才调 `install`；出错或不对就删文件 | 第 7 项 | P1 更新器的下载、校验一段可以从这里改起；第 7 节 7.5 第 9 条列的缺口要补 |
| `gui/android/.../MainActivity.kt` 安装部分 | `canInstall`、`openInstallSettings`、`installApk`（`PackageInstaller` 会话）、`versionInfo`；系统结果以 `install` 事件回 Dart：`pending`、`success`、`cancelled`、`failure` | 第 7 项 | §13.2 更新器的安卓通道（留下；接收器要挪出 Activity，见 7.5 第 9 条） |
| `gui/android/app/src/main/AndroidManifest.xml` `REQUEST_INSTALL_PACKAGES`、`android:networkSecurityConfig` | 自己装自己的权限；网络安全配置 | 第 7 项 | 两样都留下（规格 §6.4）。网络安全配置只放行 `localhost`、`127.0.0.1` 的明文，正式包里也生效 |
| `gui/android/app/src/main/res/xml/network_security_config.xml`（新） | 只对 `localhost`、`127.0.0.1` 放行明文 | 第 7 项探查从本机 http 下载 | 留下：P1 里本机的 AI 整理（`localhost:28001`）要它（规格 §6.4）；真正的下载走 https |
| `gui/test/p0_install_test.dart`（新） | 两个测试：哈希对就调 `install`、传文件路径；哈希不对不调 `install`、文件被删 | `p0DownloadAndInstall` | 跟着下载、校验那段进 P1，再补非 200、下载中断、`install` 抛异常 |
| `gui/android/.../MainActivity.kt` 语音部分 | `rapp/p0speech` 通道：`probe`、`support`、`start`、`stop`；每种模式一个识别器、复用；事件带实例号和 `rms` 计数 | 第 6 项 | §11 的安卓语音通道可以从这里改起；第 6 节 6.3 列的缺口要补；实例号、`rms` 计数是探查用的 |
| `AndroidManifest.xml` `RECORD_AUDIO`、`<queries>`（`android.speech.RecognitionService`） | 录音权限；Android 11 起不声明就看不到识别服务 | 第 6 项 | 留下（规格 §6.4 已写） |
| `gui/test/p0_speech_test.dart`（新） | Dart 一侧原样转发通道的回答和事件 | `SpeechPage` 的通道 | 不进 P1；P1 的语音要有 Kotlin 一侧的测试 |
| `gui/test/session_ffi_test.dart`（新） | 四个测试：每帧 ack 一次且只在取下一包时；暂停的消费者不 ack；慢速时 ack 前先等；`slowNow` 每帧重读 | `FfiSession` 的 ack | ack 那两个进 P1，改用 `fake_async`；慢速那两个是探查用的 |
| `gui/android/gradle.properties` | Flutter 模板生成的 `android.newDsl=false`、`android.builtInKotlin=false`，没改 | 模板这样出（第 1 节） | 留下，跟着 Flutter 模板走 |
| `gui/test/p0_keys_test.dart`（新） | 两个测试：键行里有 `ctrl=1 meta=0 …`；指针行 `scroll`、`panzoom-end`，按下事件返回 null | `keys` 页的格式化函数 | 不进 P1 |
| `scripts/p0-android-so.sh` | `cargo ndk` 出 `.so`、拷进 `jniLibs` | 每次改 Rust 后重编 | P1 的构建脚本（`build-android.sh` 之类） |

## 规格要改的地方

不碰 U1–U8、也不改用户看到的东西的，已直接改进规格，改过的段落末尾标了（P0 结果 §n）：

- §4.5：改成装完的样子：各工具的版本、两个镜像和 AVD、Rust 目标、磁盘；`gui/android/` 只在探查分支上（第 1 节）。
- §6.1：库由入口按名字传，`null` 是 `process()`；`AI_V4MAPPED` 的问题不用回答，安卓不用单独一支（第 3 节）。
- §6.2：规矩 1 补上写入端的顺序（等闸开、关闸、交给 sink）和忘了 ack 的后果；规矩 2 写明 `rapp-hub-ffi` 自己包 `catch_unwind`；`pub use` 就进导出表，不用 `#[used]` 静态量（第 2 节）。
- §6.4：清单加 `<queries>`（识别服务）；网络安全配置和安装权限在正式包里也生效；日志用 `debugPrint` 或写文件，不用 `stderr`（第 3、6、7 节）。
- §6.5：`systemOpen` 的四处用法都走 `iosChannel`，先给安卓接通道再开这一位（第 3 节）。
- §11：中文按语言前缀认（`cmn-Hans-CN`）；用 `queryIntentServices` 找识别服务；`checkRecognitionSupport` 加超时；挡住 `UnsupportedOperationException`；查和开始用同样的 intent；分段静音时长给 `int`；分段结束是单独事件；`error 12`、`13` 走现有的错误处理；「多半走到第 3 条」改成平板走的是第 4 条（第 6 节）。
- §13.2 第 4 步：装完 App 被杀、不会自己重启，成败看下次启动的 `versionCode`；先落盘、删缓存的包；接收器不跟着 Activity；出错 `abandon()`；拷贝不在 UI 线程（第 7 节）。
- §14.1 第 7 项：过关线改成「装上（App 被杀，用户再点图标）」（第 7 节）。
- §14.2 验收：「全景看到设备」之前加「在设备页按 ID 添加主机」（第 3 节）。
- §14.6：第 7 条改了，检查改在 P1 第一个包上做；新加第 8–15 条：平板走完自己装自己、打字少字、强制 relay 帧率、真人说话、文本框里的真键盘、relay 域名解析（第 3–8 节）。

改用户看到的东西的，没改规格，等用户定：

1. 建议 1：§13.2 的更新流程和「更新」旁的文案，为厂商多出的确认留位置：荣耀平板上要过安全检测、勾「已了解此应用未经荣耀应用市场检测，可能存在风险。」、再输锁屏密码，更新前先告诉用户「会让你勾一项、再输锁屏密码」；原因：平板上点「下载并安装」之后多出这三层，最后一层是 `输入锁屏密码继续安装应用`（第 7 节 7.4），而规格现在只写了系统弹一个确认；不改的后果：用户以为点一下就更新，中途看到橙色的「未经荣耀安全审核」和密码框，会以为出错或不敢继续，更新停在半路。
2. 建议 2：§11 加一条：按下语音按钮后几秒内（比如 3 s）既没有 `ready` 也没有 `begin`，这一次就当失败结束，给一句提示（比如「这台设备的语音识别没有回应，请用输入法上的语音键」），并记下来，下次启动时判成不能用、按钮不出现；原因：平板有默认识别器（`com.hihonor.magicvoice`），六次按住说话一个回调都没有（第 6 节）；只靠 `checkRecognitionSupport` 判断，遇到说支持却不回调的识别器就会漏过去；也不能改成「有默认识别器就按能用」，这台平板正是反例；只有这一个样本；不改的后果：在这样的机器上按钮出现、按了没反应，正是 U6 要避免的「按了没反应的按钮」。
3. 建议 3：§13.2 在「更新」按钮旁写一句「装完会回到桌面，请再打开 rApp」；原因：装成的两台模拟器上，用户点系统的确认后 App 立刻被杀，不会自己起来，也没看到「打开」提示（第 7 节 7.2）；不改的后果：用户点完更新只看到桌面，以为 App 崩了或更新失败。
