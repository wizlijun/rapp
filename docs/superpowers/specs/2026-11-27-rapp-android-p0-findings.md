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
| 4 | 进程内会话、节流 | 没测完（34 上画面、颜色和打字都过，打字经写作条发出；release 包会话会自己断；门禁那步慢 Dart 量内存没做，因为 Mac 被 rApp 自动锁屏；36 没做） | 待定 | 2026-11-27 |
| 8 | 数字 | 部分（APK 28.2 MiB；三个 `.so` 分别 8.3 / 11.6 / 7.5 MB；没开会话时 PSS 约 88.7 MiB；带会话的 PSS 和 fps 没量） | 待定 | 2026-11-27 |

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

**状态：没测完，停在第 6 步（慢 Dart 量内存）之前。** 只在模拟器 34 上做了；36 没做。

做法：`gui/lib/embed/session_ffi.dart`（新）接 `rapp-android-ffi` 的 `rapp_session_open/send/ack/close/free`。帧包用 `asTypedList(finalizer: rapp_session_free)` 零拷贝交给 Dart。`ackedPackets` 是 `async*`：交出一个帧包，等 `slow`，再 `ack`。这样消费方暂停时不 ack，Rust 的闸也就不放下一帧。`SessionWorker.ffi` 和 `LinuxSessionPort.ffi` 是这两个共用文件里新加的构造函数，旧路径不动。`main_android.dart` 用 `LinuxSessionPort.ffi('librapp_android.so', downloads: () => '<数据根>/files/transfers', slow: P0_SLOW_MS)`。日志每秒打一行 `p0 fps=N`，traffic 事件打 `p0 traffic frames=N`。

单元测试（`gui/test/session_ffi_test.dart`，3 个）：
- ack 顺序；
- 消费方暂停时不 ack；
- `slow` 生效。

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

**卡住的原因：** 每次会话结束（自己断开也算），Mac 上的 rApp 都会在 10 s 后自动锁屏（`service.log` 里 `auto_lock`，今天共 5 次）。锁上以后要用户输入密码，所以第 6 步需要的「A 上有动的画面」做不了。另外，打开桌面会话会把另一台设备正开着的桌面会话顶掉（`session_end reason "taken over"`）。

## 5 键盘和触控板
## 6 语音
## 7 自己装自己
## 8 数字

**状态：部分。** 只有模拟器 34 的 release 包；带会话的 PSS 和 release fps 还没量。

- release APK：`flutter build apk --release --target-platform android-arm64`，大小 29,521,063 字节（28.2 MiB）。
- `unzip -lv` 看三个 `.so`（都是 Stored，不压缩）：

  | `.so` | 字节 |
  |---|---:|
  | `libapp.so` | 8,258,448 |
  | `libflutter.so` | 11,579,920 |
  | `librapp_android.so` | 7,528,992 |

- 没开会话时的 TOTAL PSS：停在总览页，`adb shell dumpsys meminfo com.rapphub.rapp | grep -E 'TOTAL( PSS)?:?'`，每 10 s 一次共 6 次，得到 90115、92059、89568、90355、91183、91892 KB，平均 90862 KB（约 88.7 MiB）。证据：`p0/t4-sizes.txt`、`p0/t4-pss-nosession-34.txt`。
- 开着静态 2560×1600 桌面会话时的 PSS、release `p0 fps`（模拟器，只作参考）：**没量**，原因见第 4 节。

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
| `rust/net/src/quic.rs` `pub use sys::getaddrinfo_v6;` | 公开给探查函数 | `rapp_p0_resolve` 要单独看这一支 | 不进 P1（探查用） |
| `rust/android-ffi` `rapp_p0_resolve`；`Cargo.toml` 加 `rapp-net`、`tokio` | 返回 `getaddrinfo_v6` 和 `resolve_for(dual)` 两行 | 第 3 项的解析探查 | 不进 P1（探查用） |
| `gui/lib/p0/p0_pages.dart` | `P0_PAGE=resolve` 页；`keys`、`speech`、`install` 占位 | 探查页 | 不进 P1 |
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
- 安卓入口的日志不能用 `stderr`（logcat 看不到），用 `debugPrint` 或写文件。
