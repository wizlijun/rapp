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

hub 用到 `rapp_term` 的只有 `id::is_term`（`hub/src/lib.rs:394`，终端会话只能嵌入打开）和 `config::OFF`（`hub/src/terms.rs:11`）；安卓 app 只当控制端、`embed_only`，用不到本机终端和开窗口。另外 `net/src/quic.rs` 里有 `any(macos, ios)` 的分支（`sin6_len`、`AI_FLAGS`），安卓走非 Apple 那条（`AI_V4MAPPED|AI_ADDRCONFIG`），对的。

**还没看的：** 这个 `.so` 还没在模拟器里加载过（第 3、4 项做）。`trace.rs` 仍按进程号开 `worker-{pid}.log`，进程内多个会话会写同一个文件（P1 再处理）。hub-ffi 那四个函数本身没包 `catch_unwind`（现有代码，原样导出），hub 里一恐慌安卓进程就退出，见「规格要改的地方」。规格 §6.2 规矩 5（Windows 门禁上要编得过）P0 没验，探查分支不过那道门禁；P1 合并前在 Windows 机器上看。

**结论：过。** `.so` 编得出来，九个名字都在导出表里，四个 `LOAD` 段都按 `0x4000` 对齐，现有会话测试条数不变、全过。
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

- §6.2：说 hub 的四个函数可能要 `#[used] static` 才进 `.so` 的导出表。实测 `pub use rapp_hub_ffi::{…}` 就够了（第 2 节）。
- 带闸写入端的顺序：应是「等闸开、关闸（是帧时）、交给 sink」，不是「交给 sink 再关闸」，否则 ack 可能先到而丢掉（第 2 节）。
- §6.2 规矩 2（恐慌不能穿过 FFI）要落到 `rapp-hub-ffi` 自己身上：在它的四个 `extern "C"` 函数（`hub-ffi/src/lib.rs` 第 40、121、128、145 行）里包 `catch_unwind`，P1 做，iOS 一起受益。`rapp-android-ffi` 按规格只能 `pub use`、不能写同名转调，自己包不了。
- §6.2 规矩 1 已写「做成图片或决定丢掉之后就 ack」。补一句后果：忘了 ack（哪怕是丢掉的帧），会话就永远结束不了，`disconnected` 和 kind 2 都不会来（第 2 节）。
