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
| 2 | `.so` | 过（九个名字都导出、四个 `LOAD` 段都是 `0x4000`、11.3 MB / strip 后 7.5 MB；依赖全部直接编过） | §6.2 小改：hub 的四个函数不用 `#[used] static` 就能导出 | 2026-11-27 |
| 3 | 进程内 hub 和网络 | 过（两个模拟器都起得来 hub、出接入引导；放进 relay 和 key、加上这台 Mac 后在线；默认和只有 IPv4 两种状态下 relay 都解析成 `::ffff:` 映射并连上。relay 是 IPv4 字面地址，域名解析没测到；真 IPv6 一半模拟器上测不了，留给实机） | §6.1 小改（`AI_V4MAPPED` 那个问题不用回答）；§6.5 的 `systemOpen` 要安卓通道；§14.6 加一条 | 2026-11-27 |
| 4 | 进程内会话、节流 | 过（门禁两轮在模拟器 34、模拟器 36、平板实机上都过：慢速 200 ms 时 `p0 fps` 平均 4.4–4.7，traffic `frames` 平均 28.9–29.6，后 6 次减前 6 次的 PSS 是 −10.6 / −5.9 / −7.9 MB（1 MB = 1000 dumpsys KB），都在 40 MB 以内；P0Moving 的动画面、颜色和 TextEdit 打字在 34、36、平板上都过，打字经写作条发出；**对着 Mac 屏幕核对画面只在模拟器 34 上做过**（桌面会话）；会话自己断的原因是 hub 的 64 KiB 行上限，探查里绕过后会话撑过 250 s） | 待定；hub 读到超过 64 KiB 的回复行（`watch_load` 首行）就丢整条连接，这段是 main 上的共用代码；会话因此断开只在探查的进程内会话里见过，桌面没测；绕过后，建流时首行已超上限（Mac 服务起来约 55 分钟以后）余力就到不了安卓控制端，早于这个时间建流就到得了 | 2026-11-27 |
| 5 | 键盘和触控板 | 部分过。计划里的过关条件（Ctrl+C/V 在空白区到得了 App，`isControlPressed` 为真）在 34、36 上**过**（`uinput`，内核级，`ctrl=1`）；**平板（实机）上这一项没做，等用户用真键盘按**：键到得了，但 `input keycombination` 的字母 `metaState` 为 0、平板上 `uinput` 被拒，注入显示不了修饰键状态，真机上的过关没有确认。文本框有焦点、软键盘打开时（36 上重做）Ctrl+C/V/A/Z/X 都到、`ctrl=1`；原先「到不了」是点歪了位置（没点进文本框），结论撤回，Ctrl+SPACE 和单按字母的现象原因没查明。Meta 组合都被系统拿走，到不了 App。滚轮 `PointerScrollEvent kind=mouse`，34、36、平板都有；触控板双指和捏合模拟器上测不出，平板上没触控板，留给实机 | §14.6 加第 9 条（已加，含用户的一分钟真键盘检查） | 2026-11-27 |
| 8 | 数字 | 过（大小只量了模拟器 34 的包，单位 MiB，1 MiB = 1,048,576 字节：APK 28.15；三个 `.so` 分别 7.88 / 11.04 / 7.18；34 上没开会话时 PSS 约 86.7 MiB，开着静态 2560×1600 桌面会话时 6 次平均约 215.2 MiB。Task 4G 的 PSS 单位是 MB = 1000 dumpsys KB：模拟器 36 没会话 89.1、静态单应用会话（TextEdit）158.6；平板没会话 209.0、静态单应用会话 445.7。release 动画面 30 s 平均 `p0 fps`：平板 26.1（屏幕 60 Hz）；模拟器 34 是 26.0、模拟器 36 是 25.1（模拟器，只作参考）。强制 relay 的 fps 没量） | 待定 | 2026-11-27 |

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

日期 2026-11-27。探查分支 `probe/android-p0`，提交 7b9c99c7（挪代码）、9f1e9ff1（新 crate）。

**会话进库。** `git mv` 把 `client-core/src/bin/rapp-session.rs` 挪成 `src/session/mod.rs`，`bin/session_output/mod.rs` → `src/session/output.rs`，`bin/session_trace/mod.rs` → `src/session/trace.rs`；只改了 `mod`/`use` 路径和可见性（`Output` 变 `pub`），`run` 的标准输入换成参数 `input: impl BufRead + Send + 'static`，新加 `pub fn serve(input, writer)`（就是原来 `main` 的几步）。`bin/rapp-session.rs` 只剩 `session::serve(BufReader::new(stdin()), stdout())`。`trace.rs` 读 `RAPP_STREAM_TRACE_DIR` 的那行没动。git 把 `mod.rs` 记成新增（因为原路径上又建了 bin 文件），另两个记成改名。
- `cargo test -p rapp-client-core` 挪之前 70 条（lib 7、bin rapp-session 11、client 44、host_wire 3、probe 5），挪之后 70 条（lib 18、bin 0、44、3、5），全过。`host_wire` 仍然起真的 `rapp-session` 子进程。

**`rapp-android-ffi`。** `rust/android-ffi`，`[lib] name = "rapp_android"`，`crate-type = ["cdylib"]`；依赖 `rapp-hub-ffi`、`rapp-client-core`（路径）、`libc` 0.2.191、`serde_json`（按计划加了，lib 里没用到，没有警告）；测试依赖 `flate2` 1.1.11。`rust/Cargo.toml` 只在 `members` 里加了 `"android-ffi"`，`Cargo.lock` 只多了这个 crate 的一段。
- 先写测试：`cargo test -p rapp-android-ffi` 编译失败（16 个错误，函数和 `Gate`/`GateWriter` 都不存在）。
- 实现后 4 条测试全过（约 0.32 s）：计划里的三条，外加一条「帧没 ack 时 close，kind 2 仍只来一次且在最后，`send` 非 UTF-8 返回 -2」。故意改坏（帧不关闸、kind 2 发两次）四条全失败，再改回。之后又加了「发 kind 2 前等正在进行的 sink 调用做完」（见下），最终版连跑 4 次都过。
- `cargo test -p rapp-android-ffi -p rapp-client-core` 全过；`cargo clippy -p rapp-android-ffi -- -D warnings` 干净。加 `--all-targets` 时测试里有一处 `manual_c_str_literals`，已改成 `c"…"`，之后也干净。
- **和计划的一处不同：关闸在交给 sink 之前。** 计划写「等闸开 → 交给 sink → 是帧就关闸」。如果先交再关，Dart 可能在关闸之前就 ack 了，这个 ack 会丢、会话永远卡住。所以 `pass` 在同一把锁里等开、关闸，然后才调 sink。另外线程结束时先把闸作废并等正在进行的那次 sink 调用做完，再发 kind 2，保证 kind 2 之后不会再有回调。
- **最后一帧不 ack，会话就结束不了**（读代码和测试看到的行为）：闸关着时，`serve` 最后那条 `disconnected` 事件和 kind 2 都排在闸后面，要等 ack 或 `rapp_session_close` 才出来。所以 Dart 一侧（§6.3）每一帧都要 ack，丢掉的帧也要。
- **积压时多出一张旧帧**：`Output` 的写线程先从队列里取出下一个包（是帧就先展开、拷进包里），然后才卡在闸上。所以积压时 ack 之后先到的是这张已经拿出来的帧，然后才是最新的一张，和管道写满时一样，多一张过时的帧。第 4 项量延迟时要记住这一点。
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
- **坑：`adb install -r` 后卡在启动画面。** 34 上把第 1 节的空壳 APK 用 `install -r` 覆盖成正式 APK，启动后一直是启动画面，`logcat` 有 `E flutter: Could not prepare isolate`、`Could not create root isolate`、`Could not launch engine`，Dart 一行没跑。`adb uninstall com.rapphub.rapp` 再装就好了。修正轮（同日）在 34 上又碰到一次，这次前面多一行 `Can't load Kernel binary: Invalid kernel binary: Indicated size is invalid`，查到了原因：debug 包第一次启动时把 `kernel_blob.bin` 解到 `app_flutter/flutter_assets/`，那里的文件只有 8,388,608 字节（APK 里是 47,973,912），是上一轮解到一半模拟器就关了。删掉 `app_flutter/flutter_assets` 和 `app_flutter/res_timestamp-*` 再启动就好，不用卸载。只有 debug 包这样（release 包是 AOT，不解 kernel），P1 不用管。

**第 4 步：放进 relay 和 key。**
- 这台 Mac 的数据根是 `~/rapp`（没有 `RAPP_HOME`，没有指针文件）。`jq '{relay, key}' ~/rapp/local/service.json > <scratchpad>/p0-service.json`，`chmod 600`。
- **和计划不同：合并，不覆盖。** 模拟器上的 `service.json` 已经有 `ensureDeviceId` 写的 `id`，整个覆盖会丢掉它。做法：`run-as … cat` 拉下来，`jq -s '.[0] * .[1]'` 合上 relay 和 key，再 `run-as com.rapphub.rapp sh -c 'cat > /data/user/0/com.rapphub.rapp/files/rapp/local/service.json'` 写回（**要写绝对路径**，`sh -c` 里的相对路径不是应用目录，报 `No such file or directory`）。之后字段是 `id,key,relay`，0600。hub 认这个文件，没再改。
- **和计划不同：这台 Mac 不会自己出现。** 有了 relay 和 key 之后全景里只有「本机」、设备在线 1/1，`hub.log` 没有任何 relay 的行。hub 只探 `hosts.json` 里存过的主机；正常用法是在设备页「添加设备」填对方的 ID（`add_host` → `add_by_id`）。为了不让 ID 出现在界面和输入记录里，我没走界面，而是用 `jq '[{id: .id, name: "这台 Mac", password: ""}]' ~/rapp/local/service.json` 生成 `hosts.json` 写进 `files/rapp/local/`（0600），再冷启动。
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
| `dns.google` | none | `[::ffff:198.18.2.250]:443` |

- `getaddrinfo_v6` 四个都是 none，这是**代码本来的意思**，不是安卓的 C 库的毛病：它是 NAT64 那一支，只找「不是 v4 映射」的 IPv6 地址，映射地址一律丢掉（`quic.rs:338-339` 的注释：NAT64 上映射地址到不了）。所以对 IPv4 主机，在哪个平台上都是 none（`quic.rs:654` 的测试就断言 `getaddrinfo_v6("127.0.0.1","9") == None`）。这里另外也没有 AAAA 记录、没有合成的地址，所以四个都是 none。这次测不出 C 库对 `AI_V4MAPPED` 怎么处理。
- `resolve_for(dual)` 不靠它：先普通解析，有 IPv4 地址且有 IPv4 路由就自己拼 `::ffff:a.b.c.d`。计划里说的「按 IPv4 解析、自己拼 `::ffff:`」的那一支**本来就在 `resolve_for` 里**，安卓走的就是这一支，不用另加。
- `dns.google` 解析出 `198.18.2.250`：这是 Mac 上 TUN + fake-ip 代理的假地址（198.18.0.0/15），模拟器的 DNS 经 Mac 转发。不影响 relay（relay 是字面地址）。
- 换回正式包冷启动（强制 relay）：两台在两种状态下都是 `route … path:"relay" result:"ok"`、`presence online:true`，界面上这台 Mac 在线。「只有 IPv4」下连 `::1` 都没有，hub 的双栈 UDP 套接字照样连上了 relay。
- 日志证据（scratchpad，不进仓库，都已过过滤器）：「只有 IPv4」是 `p0/t3-hub-v4only-{34,36}.txt`；「默认」是修正轮补的 `p0/t3-hub-default-{34,36}.txt`——各自冷开机（`emulator -avd rapp-p0-3x -no-snapshot-load -no-audio`，36 开机后等 90 秒），确认 `/proc/sys/net/ipv6/conf/all/disable_ipv6` 是 0、`ip -o addr` 和上表「默认」一样，`adb install -r t3-main.apk`，`am start -W -n com.rapphub.rapp/.MainActivity`，等 25–40 秒，再 `run-as com.rapphub.rapp cat …/files/rapp/logs/hub.log | mask.sh`，从这次的 `hub_start` 起存下来。两份都是 `hub_start`、`ports`、`route path:"relay" result:"ok"`、`presence online:true`、`ports_asked answered:1`，`grep -c -E '"lvl":"(warn|error)"'` 都是 0。
- **双栈的真 IPv6 一半测不了**：「默认」状态没有全局 IPv6 地址，relay 也是 IPv4 字面地址。真 IPv6、只有 IPv6 的网络（NAT64，靠 `getaddrinfo_v6` 拿 DNS64 合成的 AAAA 那一支，这次没走到）留给实机，已加进规格 §14.6。

截图（scratchpad，不进仓库）：`p0-t3-access-setup-{34,36}.png`（接入引导）、`p0-t3-online-{34,36}.png`（lan 在线）、`p0-t3-online-relay-{34,36}.png`、`p0-t3-online-v4only-{34,36}.png`、`p0-t3-resolve-{default,v4only}-{34,36}.png`。

**结论：过。** hub 在安卓进程里起得来、读得懂数据根、出接入引导；放进 relay 和 key、加上这台 Mac 后，两台模拟器在「默认」和「只有 IPv4」两种状态下都把 relay 解析成 `::ffff:` 映射地址并经 relay 连上。注意这台 Mac 存的 relay 是 IPv4 字面地址，**relay 的域名解析这次没测到**；真 IPv6 和只有 IPv6 的网络也留给实机。
## 4 进程内会话

**状态：过。** 门禁两轮（对照、慢速 200 ms）在模拟器 34、模拟器 36、平板实机上都做了，都过，见本节末「Task 4G」。**对着 Mac 屏幕核对画面只在模拟器 34 上做过**（续做 1 的 `p0/t4e-desktop-static-34.png`，桌面会话）；36 和平板只看了 P0Moving 的画面在动、颜色对，没有和 Mac 屏幕逐处对照。之后探查不再开桌面会话，因为用户正通过桌面会话在用这台 Mac。下面续做、续做 2 里写「没做」的，都由 Task 4G 补上了（强制 relay 的 fps 除外，按安排不量）。

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
- `slowNow` 每帧重新读（续做时加的，见下）。

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
| 会话稳定性 | **release 包里会话自己断**：三次里两次在 18 s、10 s 后断，安卓侧报 `host disconnected: failed to fill whole buffer`（`client-core/src/protocol.rs:352` 的 `read_exact` 读到 EOF），Mac 侧记 `session_end reason "connection lost"`。断之前那一秒 `p0 fps` 还有 14–15，不是闸卡住。点「重连」能连回来。第三次开了 91 s，是我 `am force-stop` 结束的。debug 包两次各开了 115 s、79 s，Mac 侧结束原因也记的是 `connection lost`，当时是不是我结束的没有记下来 | `p0/t4-textedit-disconnect-34.png` |

**第一次停下的原因：** 每次会话结束（自己断开也算），Mac 上的 rApp 都会在 10 s 后自动锁屏（`service.log` 里 `auto_lock`）。锁上以后要用户输入密码。另外，打开桌面会话会把另一台设备正开着的桌面会话顶掉（`session_end reason "taken over"`）。

### 续做（2026-11-27 下午，模拟器 34，无窗口模式 `emulator -avd rapp-p0-34 -no-window -no-audio`）

**会话自己断的原因（查清了）。** Mac 回 `watch_load` 的第一行带满 1 小时的历史（720 个点），超过 `rapp_net::line::MAX_LINE`（`rust/net/src/line.rs:11`，64 KiB），读行报 `line longer than 64 KiB`。`rust/hub/src/link.rs` 的 `request()` 把这当成连接坏了：缓存连接那支没有专门处理、落到 `forget`，新连接那支走 `forget_if_dead`。连接一丢，这条连接上的会话全断，安卓侧看到的就是 `failed to fill whole buffer`、Mac 侧是 `connection lost`。查法：debug 包加诊断日志（改动 `p0/t4d-diag.diff`），在 hub.log 里看到这行报错，紧跟着连接被丢、会话结束。

哪些是确定的：
- 回复行太长就丢连接，这段是 main 上的共用代码。探查分支岔出去以后，main 上 `rust/net`、`rust/hub` 没有新提交；回复实测 75,125 字节，上限 65,536（续做 2）。
- 连接丢了、会话跟着断，只在这个探查的进程内会话里见过。
- 桌面版的会话在自己的进程里、有自己的连接，那边什么都没测。

探查里的绕过（补丁表 `link.rs` 那行）：连接还开着、错误是 `line longer than` 时，只把错误交回去、记一行 `p0_keep_link`，不丢连接。绕过后 hub.log 里只有大约每分钟一行 `p0_keep_link`，没有反复重连。两次会话都撑过 250 s：桌面会话 256 s（被另一台设备顶掉才结束），单应用会话 251 s（我 `am force-stop` 结束）。**真修法应在 main 的共用代码里**：要么 `watch_load` 的首行别带那么多历史、或拆行，要么读行上限对这个回复放宽；不管哪种，「回复太长」都不该丢整条连接。

**绕过留下没修的：** 它只保住了连接，`watch_load` 照样失败，大约每分钟一次。余力（负载）数据要等真修法。

**更正（Task 4G）：** 上面原来写的「余力一直到不了安卓控制端」不对。首行的长短跟着 Mac 服务的运行时长涨：历史最多 720 个点（1 小时），点少的时候首行在上限以内，余力是到得了的。Task 4G 里 Mac 服务 08:02:39Z 起来，用 `scratchpad/tools/load-size.py`（只读连本机 IPC，发 `{"cmd":"load","history":true}`）量首行：08:54:10Z 是 65,477 字节、618 个点（还在 65,536 以内）；08:57:40Z 是 69,651 字节、660 个点（超了）。所以大约在服务起来 55 分钟以后才撞上限。`watch_load` 是一条流（`rust/hub/src/load.rs` 的 `follow`）：只有建流时的第一行带历史，之后每行只是一个点。所以看的是**建流那一刻**的历史长短：平板的 hub 在 08:3x 起来、那时首行还短，09:02:36Z 全景里仍看得到余力一行（`p0/t4g-tab-ov.png`，「内存 剩 27%」）；34、36 在 09:14–09:26Z 才连上，首行已超上限，看不到。结论：建流时 Mac 服务起来不到约 55 分钟，余力到得了、之后一直在；晚于这个时间建流就到不了，每分钟重试一次也一样失败，要等真修法。

**慢速开关改成运行时读。** `ackedPackets` 加了 `slowNow`，每帧重新读；`FfiSession` 每秒用 libc 的 `__system_property_get` 读一次系统属性 `debug.rapp.p0_slow_ms`。这样同一个包、同一个会话里，`adb -s emulator-5554 shell setprop debug.rapp.p0_slow_ms 200` 和 `… 0` 就能在慢速和对照之间切换，不用重装、不用断会话（断会话会触发 Mac 自动锁屏）。日志在切换时打 `p0 slow=Nms`。新测试先红后绿：`p0/t4c-red.txt`、`p0/t4c-green.txt`。

**release 包（带绕过）上量到的：**

| 看什么 | 结果 | 证据（scratchpad，不进仓库） |
|---|---|---|
| 桌面会话有画面、和 Mac 一致、红蓝没反 | 有，和 Mac 一致，颜色对 | `p0/t4e-desktop-static-34.png` |
| 动的画面（Mac 上一个 Terminal 窗口每 30 ms 打一行时间，无声、没下载东西） | 画面跟着动；截图那一秒 `p0 fps=15` | `p0/t4e-moving-34.png` |
| 静态桌面会话时的 PSS | 见第 8 节 | `p0/t4e-static-34.txt` |

**门禁（第 6 步）：续做里没做，BLOCKED（后来由 Task 4G 做完，见本节末）。** 对照那一轮（`debug.rapp.p0_slow_ms=0`）开始后约 4 分钟，用户在另一台设备上把这台 Mac 的桌面会话拿回去了（Mac `service.log` 06:47:44Z `session_end reason "taken over"`），从第 10 个采样起 PSS 掉到约 95 MB。按规矩这一轮整轮作废（`p0/t4e-ctl-34.txt`，不引用里面的数），不拼接。桌面会话一次只能一个人开，用户正在用，再顶回去会打断用户，所以没再开。试过单应用会话（Terminal）代替：它跟着用户在 Mac 上聚焦的那个 Terminal 窗口走，`p0 fps` 只有 0–6，不是能控制的动画面，不能当门禁的画面源（`p0/t4e-term-34.png`、`p0/t4e-term-moving-34.png`）。慢速一轮、release 30 s 平均 fps、强制 relay 的 fps 都**没量**。

**界面上看到的问题（P1 留意）：** 会话断开后，画面中间的「重连 / 结束会话」框里，「结束会话」点了没反应，只能点左上角总览按钮离开。重现：模拟器 34、release 包，开一个单应用会话，让它断开（续做 1 里是会话自己断），在断开框里点「结束会话」（`adb -s emulator-5554 shell input tap` 点了几次），画面不变。同一个框里的「重连」是好的（续做 2 里 Mac 上的 app 退出后点「重连」，会话重新开了起来）。

**续做里的锁屏和顶掉次数：** 自动锁屏 1 次（06:27:40Z，绕过之前那次会话断开后）；我顶掉别人的桌面会话 2 次（06:27:16Z、06:43:28Z）；我的会话被别人顶掉 1 次（06:47:44Z）。

### 续做 2（2026-11-27 16:15 起，模拟器 34；画面源换成单应用会话）

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

**对照那一轮被打扰，作废。** 第 13、14 个采样之间（07:25:44–07:25:52Z），P0Moving 被激活了 5 次，大约每 2 s 一次，之前在前台的是 Finder。每次焦点都被我还给了 Finder。之后窗口离开了右下角，帧头从 `2560x1664` 变成 `2576x1680`。当时用户自己的桌面会话还开着，看样子是用户在点或拖这个窗口，我的「还焦点」和用户抢了 5 次。按规矩这一轮整轮作废（`p0/t4f-ctl-34.txt`，不引用里面的 PSS）。

随后改了 P0Moving：
- 激活前 1.5 s 内有点击或按键，或者鼠标还按着，就不还焦点；
- 重开时窗口放在用户拖到的位置。

**我造成了一次锁屏。** 重开 P0Moving 要先退出它，我的会话也随之结束（07:29:21Z `session_end reason "closed"`）。用户自己的两个会话已在 07:26:20Z 结束，Mac 上没有别的会话了，于是 10 s 后自动锁屏（07:29:32Z `auto_lock`）。之后在 34 上点「重连」，会话开了，但 Mac 侧记 `A is locked at start; waiting for unlock`，没有画面。

教训：只要 Mac 上没有别的会话，探查结束自己的会话就会锁屏。所以要重开画面源，得先开一个新会话再关旧的。

**没做**（Mac 锁着；除强制 relay 的 fps 外，后来都由 Task 4G 做完，见本节末）：
- 门禁两轮（对照、慢速 200 ms）；
- release 30 s 平均 fps；
- 强制 relay 的 fps；
- 模拟器 36 的画面、门禁和 TextEdit 打字。

**`watch_load` 的证据。** 用 `adb -s emulator-5554 root` 后执行 `adb -s emulator-5554 shell grep p0_keep_link /data/data/com.rapphub.rapp/files/rapp/logs/hub.log`，再过打码脚本，拿到的一行：

```
{"ts":"2026-11-27T07:21:52.834Z","err":"line longer than 64 KiB","ev":"p0_keep_link","lvl":"info","op":"watch_load"}
```

- 34 的 hub.log 里含 `line longer` 的行共 19 行，都是 `watch_load` 撞上的，大约每分钟一行：
  - 4 行 `p0_quiet_err` `"op":"WatchLoad"`：续做 1 的诊断包，绕过之前；
  - 10 行 `p0_keep_link` 不带 op：绕过后、加 op 之前的包；
  - 5 行 `p0_keep_link` `"op":"watch_load"`：这次的包。
- 回复有多大：在 Mac 上只读地连本机 IPC，发 `{"cmd":"load","history":true}`，首行回复 75,125 字节，里面 720 个历史点（每个约 100 字节），而上限 `MAX_LINE` 是 65,536（`p0/t4f-load-size.txt`）。
- 别的请求都没撞上。

**锁屏和顶掉次数（续做 2）：** 自动锁屏 1 次（07:29:32Z，我造成的，见上）；顶掉别人 0 次；被顶掉 0 次；和用户抢焦点 5 次（07:25:44–07:25:52Z，见上）。

### Task 4G（2026-11-27 17:33 起：模拟器 34、模拟器 36、平板实机）

**怎么做的。**
- 包：probe `d2706c7e` 不带 `P0_PAGE` 的 release 包（`p0/t4g-release.apk`），三台都装的这一个。
- 平板：荣耀 ROD2-W09，Android 16，USB 连 Mac，没改任何设置。模拟器无窗口跑（`-no-window -no-audio`）。
- 画面源只用单应用会话，没开桌面会话：动画面是续做 2 的 P0Moving（`com.rapp.p0moving`），打字用 TextEdit 的一个空白文档。
- Mac 上的 rApp 先是 0.15.64，09:47:11Z 自己升到了 0.15.66（见下面「Mac 自动升级」）。门禁、30 s fps、平板的画面和打字、平板的两个 PSS 都是 0.15.64 时量的；模拟器 36 的打字和静态 PSS 是 0.15.66 时量的。

**A 画面和打字**

| 看什么 | 目标 | 结果 | 过不过 | 证据（scratchpad，不进仓库） |
|---|---|---|---|---|
| P0Moving 的动画面、颜色 | 模拟器 36 | 色块在动，颜色对。强制 relay 和局域网各看了一次 | 过 | `p0/t4g-moving-36-relay.png`、`p0/t4g-moving-36.png` |
| 同上 | 平板（实机） | 色块在动，颜色对，局域网 | 过 | `p0/t4g-moving-tab.png` |
| TextEdit 里打 `p0probe` | 模拟器 36 | 点文档会弹出写作条。`adb -s emulator-5554 shell input text 'p0probe'` 进了写作条，回车（keyevent 66）只在写作条里换行、不发送，点写作条的发送按钮才发到 Mac。用 osascript 读 Mac 上的文档，内容是 `p0probe` 加一个换行。截图里文档那行看起来是 `p0robe`，原因没查，以 Mac 上读到的为准 | 过 | `p0/t4g-p0probe-36.png` |
| 同上 | 平板（实机） | 见下一行。文档显示 `p0probe`，osascript 读到的也是 | 过 | `p0/t4g-p0probe-tab.png`、`p0/t4g-tab-x1.png` |

平板和模拟器不同：平板的输入法是荣耀拼音，`input text` 打进去的字母会被拼成候选（`p0/t4g-type-tab.png`–`t4g-type-tab5.png`）。绕法：先 `input text 'p0'`，再 `input text 'probe'`，keyevent 66 把原字母上屏，再一个 keyevent 66 把写作条里的字发到 Mac。真键盘、真用户打字没试。

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

平板和模拟器不同：平板的 PSS 高得多，门禁时 470–492 MB，模拟器 175–202 MB；对照轮平板的 fps 23.4，比两个模拟器（25.4、26.0）低一点。慢速轮三台表现一样。

**34 的第一轮对照作废。** 同一个 app 有两个控制端时，后开的会顶掉先开的（`session_end reason "taken over"`）。被顶掉的安卓控制端大约 2 分钟后会自己重连、再顶回去：平板 08:47:28Z 被 34 顶掉，08:49:36Z 回来，34 那轮因此被打断（`p0/t4g-ctl-34-void.txt`，不引用里面的数）。之后都先结束另一台上的会话，再开下一台。

**其他看到的。**
- 「rApp P0 探查」：设备名在探查包里写死，所以 34、36、平板在 relay 上是三台同名设备；Mac 的 `service.log` 里今天有 3 个不同的指纹都叫这个名字。
- Mac 很忙：跑的时候平板顶栏显示「这台 Mac CPU 持续 90% 以上」（92–93%）。
- 模拟器 36 上之前留下的路由是「中继（强制）」。在强制 relay 上看过一次画面后，我在 ⋯ 菜单里点「恢复自动选路」改回了自动；门禁和 30 s fps 都是自动（局域网）下量的。
- 会话结束后顶栏显示「P0 Moving 意外结束：closed」，其实是我从 ⋯ →「结束会话」→「再点一次确认」正常结束的。确认要在一两秒内点，晚了就失效。
- P0Moving 的日志在 09:01–09:02Z（门禁轮之后）有两次把焦点还给 `com.apple.loginwindow`，窗口位置没变。

**Mac 自动升级。** 09:47:09Z Mac 上的 rApp 下载了 0.15.66，09:47:11Z 服务停下，09:47:12Z 新版本起来（`update_applied` 0.15.64 → 0.15.66）。所有会话都以 `service stopped` 结束，包括我的 P0Moving 和 TextEdit，也包括几个不是我开的终端会话和一个桌面会话。所以 09:47:11Z–09:48:54Z 之间 Mac 上一个会话都没有，这不是我关的；Mac 没锁。36 上显示 `host disconnected: failed to fill whole buffer`。断开的卡片上点「结束会话」和「再点一次确认」都没用（和上面「界面上看到的问题」一样）；点「重连」，再从 ⋯ 结束就可以了。第一次在 36 上打字正赶上这次重启，丢了；重连后又打了一次（TextEdit 会话 09:48:54Z 开）。

**锁屏和顶掉次数（Task 4G）。**
- 自动锁屏 1 次，是最后一次关会话：09:55:14Z 关掉模拟器 36，09:55:44Z 它的 TextEdit 会话 `connection lost`，09:55:54Z `auto_lock`。这一次按安排接受。
- 中间没锁过。
- 顶掉别人 0 次；我自己两台之间互相顶掉 1 次（见上）；和用户抢焦点 0 次。

## 5 键盘和触控板

**探查页：** `gui/lib/p0/p0_pages.dart` 的 `KeysPage`，用 `--dart-define=P0_PAGE=keys` 构建（`p0-build.sh` 同第 1 节，多传这个参数）。上半屏是能聚焦的空白区（点一下取焦点），下半屏是文本框。`HardwareKeyboard.instance.addHandler` 把每个 `KeyEvent` 记成一行 `p0 key down|up|repeat physical=… logical=… ctrl=.. meta=.. alt=.. shift=..`；整页包在 `Listener` 里，`PointerSignalEvent` 和 `PointerPanZoomStart/Update/End` 记成 `p0 ptr …`。每行同时 `debugPrint`，所以 `adb logcat -d -s flutter | grep 'p0 key'`（或 `'p0 ptr'`）能看到。测试 `gui/test/p0_keys_test.dart` 过。

**三个目标：** 模拟器 34（Android 14）、模拟器 36（Android 16）、平板（HONOR ROD2-W09，Android 16，MagicOS 10；`dumpsys input` 里有蓝牙的 MISTEL-1 键盘和鼠标，所以这台机器上外接键盘是常态；下面所有行仍然是「注入」，不是用户手按的）。

**两种注入，结果不一样，先看这个：**

- `adb shell input keycombination 113 31`（CTRL_LEFT + C）：这个命令发出的字母键事件 `metaState` 是 0。Flutter 先收到 Ctrl 按下（`ctrl=1`），随后一个 Ctrl 抬起，再收到字母键，此时 `ctrl=0`；物理键 ID 是 `0x11000000xx` 这种「Key with ID」，不是 HID 用法码。那个「Ctrl 抬起」查了引擎源码：Android 嵌入层 `KeyEmbedderResponder.java` 的 `synchronizePressingKey`（由 `handleEventImpl` 对每个修饰键调用）以**事件自带的 `getMetaState()`** 为准，记录里 Ctrl 还按着而事件的 `metaState` 说没按，就在字母键之前合成一个 Ctrl 抬起事件（该函数开头注释：让修饰键状态与「真实状态」一致）。所以看到的现象和源码一致；这是读源码得出的，没有用别的办法单独验证。结论：`keycombination` 的字母键行 `ctrl=0` 是注入工具的限制，不能当作「平台丢了修饰键」，也不能当作「真键盘会这样」。
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
| Meta 单按 | 34、36、平板（实机） | 没到（App 里没有 `Meta` 的行） | 34：回桌面；36：启动器搜索框弹出并拿走窗口焦点；平板：回桌面（我随后重新拉起 App） |

**文本框有焦点时（修复 1 重做；原先的行作废）：**

原先文本框那几行**没有按任务书的条件做**：软键盘从头到尾没开（`mInputShown=false`），而且在 36 上点的位置落在文本框上方的空隙里，文本框并没有拿到焦点（34 和平板用的是同一个点击公式，没有逐台核对）。那几行「Ctrl+字母到不了 `HardwareKeyboard`」的结论撤回，其中「改用 `Shortcuts`/`Actions`」的建议也一并删除（`HardwareKeyboard` 的处理器先于焦点树，事件到不了处理器，`Shortcuts` 也看不到，这个建议本身不成立）。

重做在 36 上（`uinput` 虚拟键盘；`settings put secure show_ime_with_hard_keyboard 1`，只在模拟器上设；点在文本框里，`dumpsys input_method` 确认 `mInputShown=true`，截图里软键盘在）。每步单独注入，逐步读 `p0 key`（证据 `p0/t5f-e36-text-order.txt`）：

| 步骤 | 结果 |
|---|---|
| 1 只按 Ctrl | 到：`Control Left` 按下 `ctrl=1`，抬起 `ctrl=0` |
| 2 Ctrl + C | 到：`Key C` 按下 `ctrl=1`，抬起 |
| 3 Ctrl + SPACE | 只到 `Control Left`，空格没到（输入法拿走，和平板上空白区的现象一样） |
| 4 Ctrl + C（再按） | 到，`ctrl=1` |
| 5 单按 c（无 Ctrl） | 没有 `p0 key` 行，文本框里也看不到字（原因没查；大概是输入法接走了，没有验证） |
| 6 Ctrl + C（再按） | 到，`ctrl=1` |
| 7 Ctrl + V、8 Ctrl + A、9 Ctrl + Z、10 Ctrl + X | 各自都到，`ctrl=1` |

结论：软键盘打开、文本框有焦点时，`uinput` 注入的 Ctrl+C/V/A/Z/X 都到了 `HardwareKeyboard` 的处理器，`ctrl=1`；上面的顺序（Ctrl 单按、Ctrl+SPACE、单按字母之后）没有影响。「先发一个普通键」这一步在这台 36 上用不着（步骤 5、6 已经是「普通键之后再 Ctrl+C」，照常到）。

原先「一行都没有」的现象能复现，条件是点在文本框外的空隙里（`p0/t5f-e36-text-miss.txt`：点 y=770，Ctrl+C、Ctrl+V 都没有任何 `p0 key` 行，包括 `Control Left`）。为什么那种状态下连 Ctrl 单独的事件都没有、而当时 Ctrl+SPACE、Ctrl+ENTER 却到了，**原因没查明**。

没做到的部分：平板和 34 上的文本框没有重做（平板不用 `uinput`，也不改它的设置；真键盘按键是否到文本框，留给实机真键盘复测）。「原因没查明，留给实机真键盘复测」适用于 Ctrl+SPACE、单按字母这两处。

**过关判定（规格 §14.1）：** Ctrl+C 和 Ctrl+V 在焦点于空白区时到得了 App，并且 `isControlPressed` 为真：

- 34、36：**过**（`uinput`，内核级，修饰键状态是真的）。这是计划里的过关条件，两个模拟器都满足。
- 平板（实机）：**没做，等用户（要用真键盘按）**。键到得了 App（`Control Left` 和字母都到），但 `keycombination` 发的字母 `metaState` 为 0，平板上 `uinput` 又被权限层拒绝（没有 root），所以注入没法显示修饰键状态。**真机上的这一项过关没有得到确认。**用户的一分钟检查：把配对的蓝牙键盘接上，打开探查包的 keys 页（已装在平板上），在空白区点一下，按 Ctrl+C、Ctrl+V，读屏幕上的行：字母行 `ctrl=1` 为过。已写进规格 §14.6 第 9 条。
- 没有为此换设计。

**Meta 几行（规格 U8）：** 三个目标上 Meta 的组合都到不了 App（系统先拿走了），所以 `_remoteKey` 里 `isMetaPressed` 丢弃的那条路径在这里根本走不到。保留着不碍事。

**给 P1 的一行：** 如果真键盘上字母键到达时没有修饰键状态（`isControlPressed` 为假），App 该怎么办，现在没有证据，等上面那个真键盘检查的结果再定；在那之前不要为此写任何绕过逻辑。

**在这个镜像上测的时候踩到的坑（P1 写测试脚本时有用）：**

- 36 上 Meta 单按会让启动器弹出搜索覆盖层，并**拿走窗口焦点**；之后注入的键全落到搜索框里（屏幕上能看到 `ccc`）。每个组合前要 `am force-stop` 启动器或按 BACK 并点一下 App 取回焦点，用 `dumpsys window | grep mCurrentFocus`（多块显示时有几行，有一行是 `null`，要看全部）确认焦点在 `com.rapphub.rapp`。
- 平板上刚点完取焦点后，第一批 `keycombination` 有时一个字都不到 App；先发一个普通键（探查里用 `KEYCODE_SHIFT_RIGHT`）再发组合，之后就稳了。原因没查。
- 平板的显示是横的 3000×1920，`wm size` 却报 1920×3000；点击坐标要用截图的 PNG 尺寸。模拟器 36 同理：横向 2560×1600，文本框在屏幕约 y=880，不是屏幕的 48% 处。

**滚轮和触控板（修复 1：`Listener` 改成 `HitTestBehavior.translucent` 后重测，探查包是 probe `a20bdbf9` 的 keys 页）：**

| 项 | 镜像 | Flutter 收到的 | 来源 |
|---|---|---|---|
| 鼠标滚轮竖向滚一格 | 36、平板（实机） | `p0 ptr scroll kind=mouse delta=-0.0,192.0`，即 `PointerScrollEvent`，`kind` 是 mouse | 注入（`adb shell input mouse scroll <x> <y> --axis VSCROLL,-3`）；36 上复测还是一样 |
| 鼠标滚轮 | 36 | 同上：`uinput` 虚拟鼠标滚轮 +3 得 `delta=-0.0,-192.0`，-3 得 `delta=-0.0,192.0` | `uinput` 虚拟鼠标 |
| 鼠标滚轮 | 34 | 同上：+3 得 `delta=-0.0,-192.0`，-3 得 `delta=-0.0,192.0`（`input` 没有 `scroll` 子命令，所以用 `uinput` 虚拟鼠标；证据 `p0/t5f-e34-ptr.txt`） | `uinput` 虚拟鼠标 |
| 触控板双指滚动 | 34、36 | 改成 `translucent` 后复测，仍然没收到任何 `p0 ptr`。`uinput` 虚拟触控板系统认了（`dumpsys input`：`Classes: TOUCH \| TOUCH_MT \| TOUCHPAD \| EXTERNAL`），Flutter 没有事件 | 注入。**模拟器上测不了，留给实机** |
| 触控板捏合 | 34、36 | 同上，没有任何事件 | 注入。**模拟器上测不了，留给实机** |
| 触控板双指滚动、捏合 | 平板（实机） | 没做，等用户：平板上不能用 `uinput`；这台机器上也没有触控板（`dumpsys input` 里只有蓝牙鼠标、键盘和触摸屏） | 没做 |

触控板这一项，修复 1 里又试了一次（`translucent` 之后，36 和 34 各一次，两指同向滚动和两指张开），还是没有事件。不排除是我的事件序列不对；结论只是「这种方式没测出来」。§14.6 第 9 条已加，要在有触控板的实机上看 Flutter 收到 `PointerPanZoom*` 还是 `PointerScrollEvent`。

## 6 语音
## 7 自己装自己
## 8 数字

**状态：过。** release 30 s fps、模拟器 36、平板实机由 Task 4G 补上了，见本节末「Task 4G」；强制 relay 的 fps 按安排不量。大小只量了模拟器 34 的 release 包（续做时重编的带绕过的包，和上午那个差 1,072 字节，都是 `librapp_android.so` 多出来的）。

- release APK：`flutter build apk --release --target-platform android-arm64`，大小 29,522,135 字节（28.15 MiB）。本节 MiB = 1,048,576 字节；`dumpsys meminfo` 的 KB 是 1,024 字节。
- `unzip -lv` 看三个 `.so`（都是 Stored，不压缩）：

  | `.so` | 字节 |
  |---|---:|
  | `libapp.so` | 8,258,448 |
  | `libflutter.so` | 11,579,920 |
  | `librapp_android.so` | 7,530,064 |

- 测 PSS 用 `adb -s emulator-5554 shell dumpsys meminfo com.rapphub.rapp | grep 'TOTAL PSS'`，每 10 s 一次共 6 次（`scratchpad/tools/sample.sh <out> 6 10`）。
- 没开会话、停在总览页（`am force-stop` 后重新启动、等 40 s）：89633、89512、88344、87640、87684、89900 KB，平均 88786 KB（约 86.7 MiB）。上午那个包同样量法：平均 90862 KB。证据 `p0/t4e-nosession-34.txt`（文件里的 `p0 fps` 行是 force-stop 之前那个进程留在 logcat 里的，不算）、`p0/t4-pss-nosession-34.txt`。
- 开着静态 2560×1600 桌面会话（路由自动，局域网）：191609、323376、193956、192720、226652、193968 KB，平均 220380 KB（约 215.2 MiB）。6 次里有两次尖峰（323376、226652），其余 4 次 191609–193968 KB（约 187.1–189.4 MiB）。证据 `p0/t4e-static-34.txt`。
- release 动画面 30 s 平均 `p0 fps`（模拟器，只作参考）：续做 2 时**没量**，原因见第 4 节续做 2：对照那一轮被打扰作废，之后 Mac 锁了屏。作废那一轮里单秒的 `p0 fps` 是 21–29（帧 2560×1664），只能算看到过，不算量过。Task 4G 量了，见本节末。强制走 relay 的 fps：**没量**（Task 4G 也按安排不量）。
- 续做 2 的包（fps 行带帧大小、超长行日志带 op）：`p0/t4f-release.apk` 29,544,999 字节；`libapp.so` 8,258,448、`libflutter.so` 11,579,920、`librapp_android.so` 7,552,928 字节（都是 Stored）。证据 `p0/t4f-sizes.txt`。
- 大小证据 `p0/t4e-sizes.txt`。

### Task 4G

大小没重量（三台装的都是 `p0/t4g-release.apk`）。**本小节的 MB = 1000 个 dumpsys KB**（dumpsys 的 KB 是 1,024 字节），和本节上面的 MiB 不同。

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
| `gui/android/app/src/main/AndroidManifest.xml` | `INTERNET`、`ACCESS_NETWORK_STATE`、`allowBackup="false"` | 连网；身份密钥不进备份 | §6.4 Kotlin 壳的清单（还差 `dataExtractionRules`、网络安全配置） |
| `gui/lib/embed/session_ffi.dart` `ackedPackets(slowNow:)`、`p0SlowFromProperty()`、`FfiSession._readSlow()`、`_count` 里的 `_size` | ack 前的等待每帧读 `slowNow()`；每秒从系统属性 `debug.rapp.p0_slow_ms` 读一次（`__system_property_get`）；属性没设或不是数字时用 `main_android.dart` 的 `P0_SLOW_MS`。`p0 fps` 行带上帧头里的宽高（`size=WxH`） | 同一个会话里切换慢速和对照，不断会话（断了 Mac 会自动锁屏） | 不进 P1（探查用）；ack 本身属于 §6.3 `SessionLink` |
| `rust/hub/src/link.rs` `request()` 两处 + 新函数 `keeps_link`、`op_name` | 连接还开着、错误是 `line longer than` 时只交回错误、记 `p0_keep_link`（带请求名 `op`），不 `forget` / `forget_if_dead` | `watch_load` 首行超 64 KiB 时 hub 丢整条连接（第 4 节续做）。丢连接这段是所有平台共用的 hub 代码；会话因此全断只在探查的进程内会话里见过，桌面没测 | 不属于 §6.3 的任何安卓接口，**不进 P1，真修法在 main**（共用的 hub：`rust/hub`、`rust/net`、service 的 `watch_load` 回复）。撞上的只有 `watch_load`，首行 75,125 字节（第 4 节续做 2）。绕过之后，建流时 `watch_load` 首行若已超上限（Mac 服务起来约 55 分钟以后，历史点超过约 620 个），就约每分钟失败一次，余力到不了安卓控制端；建流时历史还短就到得了、之后一直在（第 4 节「更正」）。要等真修法 |
| `rust/net/src/quic.rs` `pub use sys::getaddrinfo_v6;` | 公开给探查函数 | `rapp_p0_resolve` 要单独看这一支 | 不进 P1（探查用） |
| `rust/android-ffi` `rapp_p0_resolve`；`Cargo.toml` 加 `rapp-net`、`tokio` | 返回 `getaddrinfo_v6` 和 `resolve_for(dual)` 两行 | 第 3 项的解析探查 | 不进 P1（探查用） |
| `gui/lib/p0/p0_pages.dart` | `P0_PAGE=resolve` 页；`P0_PAGE=keys` 页（`KeysPage`、`formatKeyEvent`、`formatPointerEvent`）；`speech`、`install` 占位 | 探查页 | 不进 P1 |
| `gui/test/p0_keys_test.dart`（新） | 两个测试：键行里有 `ctrl=1 meta=0 …`；指针行 `scroll`、`panzoom-end`，按下事件返回 null | `keys` 页的格式化函数 | 不进 P1 |
| `scripts/p0-android-so.sh` | `cargo ndk` 出 `.so`、拷进 `jniLibs` | 每次改 Rust 后重编 | P1 的构建脚本（`build-android.sh` 之类） |

## 规格要改的地方

- §6.2：说 hub 的四个函数可能要 `#[used] static` 才进 `.so` 的导出表。实测 `pub use rapp_hub_ffi::{…}` 就够了（第 2 节）。
- 带闸写入端的顺序：应是「等闸开、关闸（是帧时）、交给 sink」，不是「交给 sink 再关闸」，否则 ack 可能先到而丢掉（第 2 节）。
- §6.2 规矩 2（恐慌不能穿过 FFI）要落到 `rapp-hub-ffi` 自己身上：在它的四个 `extern "C"` 函数（`hub-ffi/src/lib.rs` 第 40、121、128、145 行）里包 `catch_unwind`，P1 做，iOS 一起受益。`rapp-android-ffi` 按规格只能 `pub use`、不能写同名转调，自己包不了。
- §6.2 规矩 1 已写「做成图片或决定丢掉之后就 ack」。补一句后果：忘了 ack（哪怕是丢掉的帧），会话就永远结束不了，`disconnected` 和 kind 2 都不会来（第 2 节）。
- §6.1：「构造时传入库」改成「入口传库名，`null` 是 `process()`」：`DynamicLibrary` 传不进 `Isolate.run`，`_stopOffThread` 只能按名字重新打开（第 3 节）。
- §6.1「安卓的 C 库对 `AI_V4MAPPED` 的支持不确定」这个问题**不用回答**：三个 `mod sys` 里的 `getaddrinfo_v6` 都不会返回映射地址（unix 用 `AF_UNSPEC` 调 `getaddrinfo`、丢掉映射地址；Windows 用 `to_socket_addrs`、同样丢掉；其他平台直接 `None`），映射地址只由 `resolve_for` 自己用 `mapped()` 拼，安卓就走这一支，不用另加（第 3 节）。这次也没测出 bionic 对 `AI_V4MAPPED` 怎么处理。真正要实机回答的是：只有 IPv6 的网络（NAT64/DNS64）上，`getaddrinfo_v6` 能不能拿到合成的地址（§14.6 第 8 条）。
- §6.5：`'android'` 那一项写了 `systemOpen: true`，但 `systemOpen` 的四处用法（`main_window.dart:43`、`term_stage.dart:50`、`local_section.dart:43`、`data_section.dart:54`）都走 `iosChannel`。要么给安卓接一个通道，要么先不开。
- 接入引导之后：放进 relay 和 key，主机不会自己出现，要在设备页按 ID 添加（和 iPad 一样）。§14 的验收步骤里「看到这台 Mac 在线」之前要写上这一步（第 3 节）。
- §14.6 加一条：双栈的真 IPv6（全局地址、只有 IPv6 的网络）模拟器上测不了，实机上连一次 relay（已加）。
- §14.6 第 9 条（已加）：触控板双指滚动、捏合在模拟器上测不了；平板上 Ctrl+C/V 的 `isControlPressed` 要用户用真键盘按一次（P0 里平板只能注入，没证实）。文本框里的 Ctrl 快捷键：软键盘打开时 36 上到得了 `HardwareKeyboard`（第 5 节），先前「到不了」的说法已撤回。
- 安卓入口的日志不能用 `stderr`（logcat 看不到），用 `debugPrint` 或写文件。
