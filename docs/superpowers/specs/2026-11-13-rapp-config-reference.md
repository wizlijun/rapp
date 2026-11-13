# rapp：配置规范总览（给 agent 自动改配置用）

日期：2026-11-13。状态：**现行**（用户 2026-11-13：「系统中所有类似个性化配置的地方，都作成文档规格现行，为 agent 自动做而友好。」）

这份是 rapp 所有可配置处的**唯一清单**：文件、环境变量、命令行参数。每一处写明：在哪、谁读、字段和取值、谁来改、改完怎么生效、有没有机密。agent 要改 rapp 的任何配置，先查这里；查不到的就是不该改的。

- 每个字段的来历以代码为准，表里给了代码位置。代码改了字段，**同一个提交里**改这份文档（§9）。
- 某一类配置有自己的编写规范时，这里只给入口，细则看那份：app 配置 → 《app 配置编写规范》（`2026-11-13-rapp-app-profile-authoring.md`）。

## 0. agent 改配置的通用规则

1. **先分清能不能改。** 每个文件标了「谁来改」：
   - **GUI**：优先让用户在 GUI 里改；agent 要改，就用 GUI 背后的同一条路（IPC 或 hub 命令），不直接写文件。
   - **手改**：agent 可以直接改文件，按 §0.3 的步骤。
   - **程序自管**：程序自己写的状态，**不要改**，只能读来排查问题。
2. **机密字段不打印、不编、不外传。** 标了「机密」的字段（口令、密钥、token、哈希），agent 读文件时不把值写进输出、日志、提交、对话；要新值时让程序生成，或者让用户自己填。这类字段的取值规则照写在表里，值不写。
3. **手改文件的步骤：**
   1. 先停掉读写这个文件的程序（表里的「谁读」），否则它下次保存会盖掉你的改动；
   2. 先备份成 `<文件>.bak`；
   3. 只改要改的字段，其余原样保留（未知字段也保留）；
   4. 用 `python3 -m json.tool <文件> >/dev/null` 确认 JSON 能解析；
   5. 权限保持 `0600`（`chmod 600`）；
   6. 再启动那个程序，看日志里没有报错。
4. **数据根目录**（下称 `$ROOT`，规格《数据目录》）：所有 rapp 数据都在这一个目录下。找法按顺序：环境变量 `RAPP_HOME` → 指针文件 `<旧配置目录>/data-root`（一行绝对路径）→ `~/rapp`（Windows `%USERPROFILE%\rapp`）。代码：`rust/net/src/config.rs:23-38`、`gui/lib/paths.dart:50-56`、`Sources/RappCore/DataPaths.swift:3-9`。
   - **旧配置目录**：macOS `~/Library/Application Support/rapp`，Linux `$XDG_CONFIG_HOME/rapp`（默认 `~/.config/rapp`），Windows `%APPDATA%\rapp`（`rust/net/src/config.rs:50-63`）。现在只用来放 `data-root` 指针，和作搬家的来源（只复制，旧文件原样留着）。
   - **目录树**：

     ```
     $ROOT/
       README.md  .gitignore
       shared/            所有设备共用（进 git）：apps.json  workspace.json
       devices/<id>/      每台设备一份，只由这台设备写（进 git）：device.json  gui.json
       agent/             用户和 agent 的内容（进 git），rapp 不动
       clipboard/         钉住的文字条目，一条一个 .md（进 git）
       files/             二进制，不进 git：transfers/（收发的文件）  clipboard/（钉住的图片和文件）
       local/             本机私有，不进 git，0700：service.json  hosts.json  ipc.token  update.json  ……（§3）
     ```
   - **进 git 的**：`shared/`、`devices/`、`agent/`、`clipboard/`、`README.md`、`.gitignore`。**不进 git 的**：`files/`、`local/`（写在 `.gitignore` 里）。rapp-service 在改动后 60 秒内合成一次提交（`rust/service/src/data.rs:41`）。
   - **机密只在 `local/`**。`shared/`、`devices/`、`agent/`、`clipboard/` 里不写口令、key、secret、token；agent 往这些目录写东西时也一样。
   - 路径函数：Rust `local`/`shared`/`device`/`files`（`rust/net/src/config.rs:79-93`），Dart `DataDir`（`gui/lib/paths.dart:60-72`）。
   - 文件先写临时文件再改名；机密文件权限 `0600`。
5. **试验用临时目录。** 在自己机器上验证配置时，设 `RAPP_HOME=<临时目录>`（它优先于指针，所有数据都落在那里），不碰用户真实的 `~/rapp` 和旧配置目录。设了 `RAPP_HOME` 后日志在 `$RAPP_HOME/local/logs`，不用另设。

## 1. 一览

| 文件 / 设置 | 在哪一侧 | 谁来改 | 机密 | 细则 |
|---|---|---|---|---|
| `$ROOT/local/service.json` | A（B 上的 hub 也读其中 relay/key） | GUI + 手改（部分字段） | 有 | §2.1 |
| `$ROOT/local/hosts.json` | B | GUI（经 hub） | 有 | §2.2 |
| `$ROOT/shared/workspace.json` | B | GUI，可手改 | 无 | §2.3 |
| `$ROOT/devices/<id>/gui.json` | B | GUI，可手改 | 无 | §2.4 |
| `$ROOT/shared/apps.json` | B | GUI，可手改 | 无 | §2.5 |
| `$ROOT/devices/<id>/device.json` | A / B | 程序自管（rapp-service 写，没有机密） | 无 | §2.6 |
| `<旧配置目录>/data-root` | A / B | GUI「更改位置…」写，可手改 | 无 | §2.7 |
| `$ROOT/clipboard/`、`$ROOT/files/clipboard/` | B | GUI 写，可手删 | 无（用户钉住的内容可能含私事） | §2.8 |
| `$ROOT/agent/` | — | 用户和 agent，rapp 不动 | 不放机密 | §2.9 |
| 程序自管的状态（`$ROOT/local/` 等） | A / B | 程序自管 | 部分有 | §3 |
| macOS 开机自启 | A | 安装包 / GUI | 无 | §4 |
| 新 relay（Docker） | relay | 运维手改 `config.json` 或环境变量 | 有（数据卷里的密钥） | §5.1 |
| 旧 relay（VPS，迁移结束后删除） | relay | 运维手改 | 有 | §5.2 |
| 环境变量 | 各侧 | 启动方 | 部分有 | §6 |
| 命令行参数 | 各程序 | 启动方 | 部分有 | §7 |
| 打包发布 | 构建机 | 发布脚本 | 有（签名身份） | §8 |

## 2. 用户可以改的配置

### 2.1 `$ROOT/local/service.json`（A 的主配置）

谁读：`rapp-service`，启动时读一次（`rust/service/src/config.rs:44`）；B 上的 `rapp-hub` 读其中的 `relay` 和 `key`（`rust/hub/src/lib.rs:72`）。第一次启动时自动补齐 `id`、`secret`、`password`、`name`。机密只在 `local/`，权限 `0600`，不进 git。旧版的 `service.json` 在旧配置目录里，第一次启动时复制过来（旧的留着）。

| 字段 | 类型 | 没写时 | 取值 | 谁改 | 机密 |
|---|---|---|---|---|---|
| `relay` | 字符串 | 不用中继 | 中继地址 `主机:端口`（端口一般 22026） | GUI（IPC `set_relay`） | |
| `key` | 字符串 | 无 | 和中继的 `--key` 一致 | GUI（IPC `set_relay`） | **机密** |
| `id` | 字符串 | 随机 9 位数字 | 9 位数字；改了就是另一台设备 | 不改 | |
| `secret` | 字符串 | 随机 32 位十六进制 | 设备在中继上的身份凭据 | 不改 | **机密** |
| `name` | 字符串 | 本机主机名 | 给人看的设备名 | 手改 | |
| `password` | 字符串 | 随机 | 连这台 A 用的口令（明文存放，GUI 要显示，规格 D8） | GUI（IPC `set_password`） | **机密** |
| `port` | 整数 | 22028（UDP） | 1–65535 | 手改 | |
| `ipc_port` | 整数 | 22029（TCP，只听 127.0.0.1） | 1–65535；改了 GUI 要能找到它 | 手改 | |
| `update_url` | 字符串 | 内置的 `latest.json` 地址 | 只收 `https://` | 手改 | |
| `auto_update` | 布尔 | `true` | 没人用时自己装新版 | GUI（IPC `set_update`） | |
| `check_updates` | 布尔 | `true` | 定时检查更新 | GUI（IPC `set_update`） | |

生效：手改后要重启 `rapp-service`。macOS：`launchctl kickstart -k gui/$(id -u)/com.rapp.service`（这会断开正在连着的会话，先问用户）。agent 改 `shared/` 和自己设备的 `devices/<id>/` 里的文件时，注意 rapp-service 一分钟内会把改动提交进 git。

### 2.2 `$ROOT/local/hosts.json`（B 存下的 A 列表）

谁读写：`rapp-hub`（`rust/hub/src/hosts.rs:24`），GUI 通过 hub 的 `add_host`、`remove_host` 改（`rust/hub/src/lib.rs:174-203`）。

格式：数组，每项 `{"id": 字符串, "name": 字符串, "password": 字符串, "lan": [字符串]}`。`lan` 是 A 的局域网地址 `ip:端口`，没有时是 `[]`。没有中继时，在 GUI 里用 `id@ip` 的形式添加 A，hub 会把地址记进 `lan`。

| 字段 | 机密 |
|---|---|
| `password` | **机密**（明文，规格 D8） |

agent 规则：**不直接改这个文件**。加、删设备走 GUI 的设备页或 hub 的 `add_host` / `remove_host`；口令由用户自己填。

### 2.3 `$ROOT/shared/workspace.json`（常用和项目）

谁读写：GUI，启动时读（`gui/lib/ui/workspace_store.dart:107`），每次改动都写（`:125`）。在 `shared/` 里，各设备共用，进 git。读不出来时改名为 `workspace.json.bad`，从空白开始，提示「项目和常用没有读到，已从空白开始」。

```json
{
  "version": 1,
  "favorites": [{"device": "123456789", "bundle": "com.apple.Terminal", "name": "终端"}],
  "projects": [{"id": "p1", "name": "rapp", "members": [
    {"device": "123456789", "bundle": "com.apple.Terminal", "name": "终端", "task": "跑测试"}]}]
}
```

| 字段 | 含义 |
|---|---|
| `device` | A 的设备 id（9 位数字，同 `service.json` 的 `id`） |
| `bundle` | app 标识（macOS bundle id / Windows exe / Omarchy class） |
| `name` | 存下时 app 的显示名 |
| `task` | 用户自己写的任务名，可以空 |

生效：先退出 GUI 再手改，改完重新打开。没有机密。旧位置是旧 GUI 配置目录，会被复制过来。

### 2.4 `$ROOT/devices/<id>/gui.json`（界面偏好）

谁读写：GUI（`gui/lib/ui/prefs.dart:14,33`）。每台设备一份，`<id>` 是这台的设备 id（`local/service.json` 的 `id`）；还不知道 id 时不保存改动（`gui/lib/ui/main_state.dart:1101`），启动时从 `local/gui.json` 读（有的话，`gui/lib/main.dart:64`）。

| 字段 | 取值 | 没写时 |
|---|---|---|
| `theme` | `matrix`、`ironMan`、`westworld`、`avatar` | `matrix` |
| `start_fullscreen` | 布尔：启动时全屏沉浸 | `true` |

生效：退出 GUI 再改，重新打开生效。没有机密。

### 2.5 `$ROOT/shared/apps.json`（我的 app 配置）

格式和取值见《app 配置设计》§2，怎么写见《app 配置编写规范》。内置的一份在 `gui/assets/app_profiles.json`（随 GUI 发布，只在仓库里改；启动时由 `gui/lib/main.dart:82` 读出来）。没有机密。

谁读写：GUI，启动时读一次（`AppProfileStore.load`，`gui/lib/ui/app_profile_store.dart:57`），每次改动都写（`同文件:194`，临时文件 + 改名）。读不出来时改名为 `apps.json.bad`，从空白开始，提示「app 配置没有读到，已从空白开始」。GUI 里改它的入口：标签右键、串流菜单、设备页 ⋯、本机页「app 配置」。

生效：在 GUI 里改，马上对已开的会话生效（窗口规则、输入区、发送后）；画面（串流档位）只对新开的会话生效，已开的会话保持自己的选择（R10）。手改文件要退出 GUI 再改、重新打开才生效（同 §2.3）。

### 2.6 `$ROOT/devices/<id>/device.json`（这台设备是什么）

程序自管，**不要改**，只读。rapp-service 写（`rust/service/src/data.rs:373-383`），内容 `{"id","name","os","version"}`，给别的设备和 agent 看这台是什么。没有口令和地址，没有机密。内容没变就不重写。

### 2.7 `<旧配置目录>/data-root`（数据根目录指针）

一行绝对路径，指向 `$ROOT`。GUI 设置页「数据目录」的「更改位置…」写它（`gui/lib/data_relocate.dart:37-64`），「改回默认」删它；读它的代码见 §0.4。手改也行：只写一行绝对路径（不是绝对路径就当没有）。`RAPP_HOME` 设了就优先于它。改完要重启 `rapp-service`（先问用户）。它必须在 `$ROOT` 外面，所以放在旧配置目录里。没有机密。

### 2.8 `$ROOT/clipboard/` 和 `$ROOT/files/clipboard/`（钉住的剪贴板）

只有用户在 GUI 里「钉住」的条目才写盘，没钉住的只在内存里。文字：`clipboard/<时间>-<短标题>.md`，一条一个，进 git；图片和文件：`files/clipboard/`，不进 git。GUI 启动时读回来（`gui/lib/ui/pin_files.dart:37`），取消钉住就删这条的文件（`:77`）。agent 手删文件 = 取消钉住，下次 GUI 启动时生效；git 历史里还留着。不要往里写机密，不要把内容或标题抄进日志。

### 2.9 `$ROOT/agent/`（agent 的上下文）

用户和 agent 的目录，进 git，rapp 只建目录和 `agent/README.md`（指向这份文档），里面的内容不动。agent 可以在这里放自己的笔记和上下文，但不放机密。

## 3. 程序自管的状态（不要改）

| 文件 | 在哪 | 是什么 | 机密 |
|---|---|---|---|
| `$ROOT/local/ipc.token` | A、B | GUI 连本机 service 用的 token，每次启动重新生成（`rust/service/src/lib.rs:105`） | **机密** |
| `$ROOT/local/update.json` | A | 最近查到的版本、上次检查时间、用户按过「不装」的版本（`rust/service/src/update.rs:133`）。「不装」走 IPC `update_dismiss` | |
| `$ROOT/local/update-applied.json` | A | 上次升级的记录，用于回滚和授权提示（`rust/update/src/apply.rs:10`） | |
| `$ROOT/local/previous/` | A | 升级前的旧版，用于回滚（`rust/service/src/update.rs:136`） | |
| `$ROOT/local/last-dr` | A | 上次运行时的签名要求（一个字符串），升级时对照用（`rust/service/src/update.rs:242`） | |
| `$ROOT/local/sync.json` | A | rapp-service 写的 git 状态：`git`（`missing`、`local`、`synced`、`conflict`、`error`）、`last_commit`、`last_sync`、`error`（不含远端地址里的口令）；GUI 读（`rust/service/src/data.rs:49-55`） | |
| `$ROOT/local/migrated-from` | A、B | 搬家时写的旧目录路径，只是记录（`rust/net/src/datadir.rs:12`） | |
| `$ROOT/local/pin-hint-shown` | B | 「钉住会进 git 历史」的提示已经显示过的标记，没有内容（`gui/lib/ui/pin_files.dart:10`）。删掉它，下次钉住时会再提示 | |
| `~/Library/Caches/rapp/update` | A（macOS） | 升级包下载缓存 | |
| `$ROOT/local/permission-guide-shown` | A | 授权引导已经显示过的标记，没有内容（`gui/lib/pages/permissions_panel.dart:140`）。删掉它，下次启动会再引导一次 | |
| 日志 `service.log`、`hub.log`、`launchd.log` | A、B | 目录：`RAPP_LOG_DIR`，否则设了 `RAPP_HOME` 时 `$RAPP_HOME/local/logs`，否则 macOS `~/Library/Logs/rapp`、Linux `$XDG_STATE_HOME/rapp`（`rust/net/src/log.rs:236`）。日志不跟着指针搬，不进 git。内容规则见可观测性规格：不记口令、token、剪贴板和打字内容 | |

## 4. macOS 开机自启：`~/Library/LaunchAgents/com.rapp.service.plist`

两处会写：安装包（`scripts/pkg/postinstall`）和 GUI（`gui/lib/service_control.dart:76`，app 挪了位置时重写）。内容：Label `com.rapp.service`；运行 `rapp-service`；日志到 `launchd.log`；`RunAtLoad`、`KeepAlive` 都是 `true`。GUI 写的版本在设了 `RAPP_HOME` 时会把它带进去。

agent 规则：不手改；要换启动参数就改上面两处模板，**两处一起改**。

## 5. 中继（VPS）

### 5.1 新 relay（`rapp-relay2`，Docker 镜像）

规格：《rapp relay 设计》（`2026-11-13-rapp-relay-design.md`）§10、§12。代码：`rust/relay2/src/config.rs`。什么都不配也能跑：启动容器、挂上数据卷、放行端口即可。没有任何机密通过配置传给 relay（key 由 relay 自己生成，用 `key` 命令显示一次）。

**配置项。** 来源三个，后面盖过前面：默认值 → 数据卷里的 `config.json`（可以没有）→ 环境变量。改了要重启才生效。文件里嵌套写（`{"audit":{"keep_days":7},"limits":{"max_conns":100}}`），环境变量是扁平的。

| 配置项 | 环境变量 | 默认 | 意思 |
|---|---|---|---|
| `listen` | `RAPP_RELAY_LISTEN` | `0.0.0.0:22026` | 监听的地址和端口（UDP） |
| `enroll` | `RAPP_RELAY_ENROLL` | `open` | `open` 接受新设备入网；`closed` 不接受 |
| `log` | `RAPP_RELAY_LOG` | `info` | 运行日志的级别：`info` 或 `debug` |
| `audit.keep_days` | `RAPP_RELAY_AUDIT_KEEP_DAYS` | `180` | 审计日志留多少天 |
| `audit.max_mb` | `RAPP_RELAY_AUDIT_MAX_MB` | `256` | 审计日志总共最多占多少 MB |
| `audit.required` | `RAPP_RELAY_AUDIT_REQUIRED` | `false` | 审计写不进去时，是否拒绝新的入网、牵线和中继（环境变量取 `true`/`false`/`1`/`0`） |
| `metrics` | `RAPP_RELAY_METRICS` | 关 | 指标接口的地址，如 `127.0.0.1:9116`。只收本机回环地址，别的地址拒绝启动 |
| `limits.max_conns` | `RAPP_RELAY_LIMIT_MAX_CONNS` | `4096` | 总连接数 |
| `limits.max_conns_per_ip` | `RAPP_RELAY_LIMIT_MAX_CONNS_PER_IP` | `16` | 每个来源地址的连接数 |
| `limits.max_streams` | `RAPP_RELAY_LIMIT_MAX_STREAMS` | `128` | 每条连接的并发流 |
| `limits.max_relayed_per_device` | `RAPP_RELAY_LIMIT_MAX_RELAYED_PER_DEVICE` | `32` | 每台设备同时被中继的流 |
| `limits.max_devices` | `RAPP_RELAY_LIMIT_MAX_DEVICES` | `1024` | 入网设备数 |
| `limits.unenrolled_idle_secs` | `RAPP_RELAY_LIMIT_UNENROLLED_IDLE_SECS` | `10` | 没入网的连接，连上以后多少秒内没入网就断；入网失败（口令错、锁定、限速等）也立刻断开这条连接，要重试得重新连 |
| `limits.enroll_per_ip_per_min` | `RAPP_RELAY_LIMIT_ENROLL_PER_IP_PER_MIN` | `10` | 没入网的连接，每个来源地址每分钟几次 |
| `limits.max_line` | `RAPP_RELAY_LIMIT_MAX_LINE` | `8192` | 一行请求最长多少字节（规格 §9.2 的 8 KiB） |
| `limits.request_timeout_secs` | `RAPP_RELAY_LIMIT_REQUEST_TIMEOUT_SECS` | `10` | 请求行多少秒内要收完，超时重置这条流 |
| `limits.lock_after` | `RAPP_RELAY_LIMIT_LOCK_AFTER` | `5` | 入网失败、`connect` 失败连续几次以后开始退避 |
| `limits.lock_max_secs` | `RAPP_RELAY_LIMIT_LOCK_MAX_SECS` | `300` | 退避最长等多少秒（第 n 次失败等 `min(2^(n-lock_after), lock_max_secs)` 秒） |
| `limits.connect_per_target_per_min` | `RAPP_RELAY_LIMIT_CONNECT_PER_TARGET_PER_MIN` | `60` | 每个目标 ID 每分钟最多被请求牵线几次，超了回 `limit`，不锁 |
| `limits.relay_bps_per_stream` | `RAPP_RELAY_LIMIT_RELAY_BPS_PER_STREAM` | `0` | 每条中继流的带宽上限，字节/秒；`0` 不限 |
| `limits.relay_bps_total` | `RAPP_RELAY_LIMIT_RELAY_BPS_TOTAL` | `0` | 中继总带宽上限，字节/秒；`0` 不限 |

规则：

- 配置里出现不认识的项，或者值不合法：relay 拒绝启动，并说明是哪一项。写错一个字不会被悄悄忽略。除 `lock_after`、`lock_max_secs`、`relay_bps_per_stream`、`relay_bps_total`（`0` 表示不限或不退避）以外，数字限额都不能小于 `1`。
- 启动时把生效的配置记一行，运行日志和审计日志（`relay_start`）各一份。
- 命令行参数只有 `--data`（数据目录，默认 `/data`）和子命令：`key`、`rotate-key`、`devices`、`revoke <ID|指纹>`、`unbind <ID>`、`enroll open|closed`、`audit [--since <N>d|<N>h] [--id <ID>] [--event <名字>]`、`check`、`--version`。不带子命令就是运行 relay。
- `enroll open|closed` 命令立刻生效，并且只把 `enroll` 这一项写进 `<数据目录>/config.json`（文件里其余的项不动；没有文件就新建，权限 0600），所以重启后还在。如果 relay 是带着环境变量 `RAPP_RELAY_ENROLL` 启动的，重启后环境变量会盖过它，命令会打印一行警告。写文件失败时，开关已经生效，回复是 `applied but not saved: <原因>`。`revoke` 也一样：登记簿写不进去（比如磁盘满）时，吊销照样生效、设备被断开，回复是 `applied but not saved: <原因>`，审计里那行 `revoke` 带 `saved: false`，relay 停止时会再写一次。

**数据卷 `/data`**（规格 §10.2）。文件 0600，目录 0700。备份整个数据卷；最要紧的是 `relay.key` 和 `devices.json`。

| 文件 | 是什么 | 丢了会怎样 | 机密 |
|---|---|---|---|
| `relay.key`、`relay.crt` | relay 自己的密钥和证书 | 所有设备上的 key 都对不上了，要换 key | **机密**（`relay.key`） |
| `join` | 入网口令的哈希 | 没法入网新设备，换 key 即可；已入网的不受影响 | **机密**（哈希） |
| `devices.json` | 登记簿：指纹、ID、租户、入网时间、是否吊销 | 设备要重新入网；ID 的归属丢失 | |
| `config.json` | 配置（可以没有） | 回到默认值 | |
| `audit/` | 审计日志，`YYYY-MM-DD.jsonl`，一天一个 | 审计记录没了，不影响运行 | |
| `admin.sock` | 管理命令用的套接字 | 重启后重建 | |

agent 规则：不改 `relay.key`、`join`、`devices.json`（程序自管；要吊销、解绑用 `revoke`、`unbind` 命令）；`config.json` 可以手改，改前停 relay，改后启动，看运行日志里有没有报哪一项不合法（不合法会拒绝启动）。

**Docker 部署**（规格 §12；文件在 `docker/relay/`，构建用 `scripts/build-relay-image.sh`）。发布物只有一个 Docker 镜像：

| 项 | 定法 |
|---|---|
| 基础镜像 | `alpine:3.23.8`，固定到多架构索引摘要 `sha256:469c9ea4…9971eb2`；编译阶段 `rust:1.99.1-alpine3.23` |
| 镜像里有什么 | Alpine 的基础层，加 `/usr/local/bin/rapp-relay` 一个静态链接的程序（`cargo --profile relay`）。不装任何别的包 |
| 架构 | 同一个镜像标签下带 x86_64 和 arm64 两种（`--multi`）。本机（arm64）已构建并通过冒烟检查 |
| 怎么构建 | 多阶段：第一阶段编译，第二阶段只把程序拷进干净的 Alpine |
| 大小 | arm64 实测：镜像 5,756,325 字节，`docker save \| gzip` 后 5,742,894 字节（目标 10 MB 以内） |
| 运行身份 | uid 10001；compose 里根文件系统只读、`cap_drop: [ALL]`、`no-new-privileges` |
| 数据 | 只挂一个卷 `/data`（镜像里属 10001，权限 0700） |
| 网络 | 主机网络模式。relay 靠"看到的对端地址"做限速和打洞，别的网络模式可能把地址改写掉。来源地址要在 Linux VPS 上实测（待做） |
| 健康检查 | 镜像自带，每 30 秒跑一次 `rapp-relay check` |
| 升级 | `docker compose pull && docker compose up -d` |
| 镜像标签 | 每个版本一个固定标签，另有跟随小版本的标签。compose 示例里写固定标签 |
| 发布到哪里 | `ghcr.io/wizlijun/rapp-relay` |

relay 只能跑在 Linux 主机上（Mac 和 Windows 上的 Docker 在虚拟机里，看不到真实来源地址）。开发和测试时可以直接运行编译出来的程序，那不是发布物。

**日志和审计**：运行日志写标准错误，由 Docker 收集（`relay_start`、`stats` 等事件，见可观测性规格 §4.2）；审计日志写 `/data/audit/`，同时带标记写一份到标准错误，事件表见规格 §11.1。

### 5.2 旧 relay，迁移结束后删除

两个 relay 并行到设备迁移完（规格 §13.2）；下面这些在那之后一起删。

| 东西 | 位置 | 内容 | 机密 |
|---|---|---|---|
| systemd 单元 | `/etc/systemd/system/rapp-relay.service`（模板 `scripts/rapp-relay.service`） | 从 `/etc/rapp-relay.env` 读 `RAPP_RELAY_KEY`；运行 `rapp-relay --key ${RAPP_RELAY_KEY} --listen 0.0.0.0:22026 --db /var/lib/rapp-relay/relay.json`；`DynamicUser`；总是重启 | |
| `/etc/rapp-relay.env` | VPS | 一行 `RAPP_RELAY_KEY=…`，和各设备 `service.json` 的 `key` 一致 | **机密** |
| `relay.json` | `/var/lib/rapp-relay/` | 中继自管：每个设备 id 的 `secret_hash`、`pw_salt`、`pw_hash`、`name`（`rust/relay/src/db.rs`）。不要改 | **机密**（哈希） |

中继是唯一的门禁（规格 D8），改它前先问用户；登录 VPS 也要用户同意。升级中继用 `scripts/upgrade-relay.sh`。改 key 后，所有设备的 `key` 都要跟着改，否则都连不上。

## 6. 环境变量

| 变量 | 哪一侧 | 含义 | 没设时 | 机密 |
|---|---|---|---|---|
| `RAPP_HOME` | A、B、GUI | 数据根目录 `$ROOT`，优先于指针文件（`rust/net/src/config.rs:30`） | 指针文件，再 `~/rapp`（§0.4） | |
| `RAPP_LOG_DIR` | A、B、GUI | 日志目录 | 见 §3 日志 | |
| `RAPP_BIN_DIR` | A、B、GUI | 辅助程序（rapp-host、rapp-client 等）所在目录 | 当前程序所在目录，再找 PATH | |
| `RAPP_GUI` | A | `--cm` 连接窗口用的 GUI 路径 | 无 | |
| `RAPP_FORCE_PATH` | B | 强制走 `relay`、`direct` 或 `lan` | 自动选 | |
| `RAPP_DOWNLOADS` | A、B（A：`rapp-host` 收上传；B：GUI 嵌入会话下载，`gui/macos/Runner/SessionPlugin.swift:47`） | 收发文件的目录（`Sources/RappCore/DataPaths.swift:18-21`） | `$ROOT/files/transfers`（旧版是 `~/Downloads/rapp`，那里的文件不会搬） | |
| `RAPP_TOKEN` | 内部 | service / hub 传给子进程的会话 token，不要自己设 | — | **机密** |
| `RAPP_RELAY_KEY` | VPS（旧 relay，迁移结束后删除） | 中继密钥，见 §5.2 | — | **机密** |
| `RAPP_RELAY_*` | 新 relay | 配置项的环境变量形式，全表见 §5.1 | 见 §5.1 | 无（没有机密经环境变量传入） |

## 7. 命令行参数

| 程序 | 参数 | 谁来传 |
|---|---|---|
| `rapp-relay`（旧 relay，迁移结束后删除） | `--key`（必填，机密）、`--listen`（默认 `0.0.0.0:22026`）、`--db`（默认 `relay.json`）、`--debug`、`--version` | systemd 单元（§5.2） |
| `rapp-relay2`（新 relay） | `--data <目录>`（默认 `/data`）；子命令见 §5.1 | Docker / 运维 |
| `rapp-service`、`rapp-hub` | 不收参数（给了就以退出码 2 退出）；只看 §6 的环境变量 | launchd / GUI |
| `rapp-host` | `serve --app <标识> --token-env <变量> --port <端口>（默认 47800，0=随机）--bind <地址> --json`；`list-apps`；`check [--prompt]`；`version [--json]` | rapp-service（`Sources/RappCore/WorkerCLI.swift:97`） |
| `rapp-client`（Swift、GTK） | `[connect] rapp://… [--token-env <变量>] [--json]`；`version [--json]` | rapp-hub |
| `rapp-session` | 不收参数，从标准输入读 JSON 命令 | GUI |

agent 规则：`rapp-host`、`rapp-client`、`rapp-session` 是由上面的程序拉起的，一般不用手动跑；测试时只用自己起的实例，端口用临时端口，不用 47800、21116–21119、22026–22029。

## 8. 打包发布（构建机）

| 设置 | 含义 | 机密 |
|---|---|---|
| `RAPP_SIGN_APP` | 给 app 签名的身份名 | 身份名本身不是机密；签名用的私钥在钥匙串里，不导出 |
| `RAPP_SIGN_PKG` | 给 pkg 签名的身份名 | 同上 |
| `RAPP_NOTARY_PROFILE` | 公证用的钥匙串配置名，默认 `rapp-notary` | 同上 |
| `RAPP_ALLOW_ADHOC` | 允许不签名（ad-hoc）打包 | |
| `RAPP_RELEASE_BASE` | `latest.json` 里下载地址的前缀 | |
| `RAPP_RELEASE_NOTES` | 写进 `latest.json` 的更新说明 | |
| `RAPP_VERSION`（Linux `--dart-define`） | 版本标签，默认「开发版」 | |

`dist/latest.json`（升级清单，`scripts/package-macos.sh` 生成）：`version`（必填）、`published_at`、`notes`、`assets["macos-arm64"] = {url（只收 https）, sha256（64 位十六进制）, size（大于 0）}`。由脚本生成，不手写。

测试专用的变量（`RAPP_E2E_BUNDLE`、`RAPP_FIXTURE_TOKEN`、`RAPP_BENCH_*`）只在 `scripts/*.py` 里用，不算配置。

## 9. 维护这份文档

- 加、改、删任何配置文件的字段、环境变量、命令行参数时，在**同一个提交**里改这份文档对应的表；代码评审时没改文档算没做完。
- 新加一类用户会改的配置（像 app 配置这样），除了在这里登记一行，还要写一份它自己的编写规范：值不值得配、取值怎么选、格式、例子、自查表——照《app 配置编写规范》的写法。
- 表里的代码位置写到文件和行号；行号漂了就顺手更新。
