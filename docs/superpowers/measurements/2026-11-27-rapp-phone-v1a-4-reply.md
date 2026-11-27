# 手机 V1a 探查 4 的结论：不开视图往会话送字

规格：`docs/superpowers/specs/2026-11-27-rapp-iphone-v1-requirements.md` I2、I6、S4、V4、§17 第 3 条、§18 第 4 条；`program-status` 规格 §7.4.8、§7.4.9、§7.5；`ipad-duo` 规格 Z1–Z5。
计划：`docs/superpowers/plans/2026-11-27-rapp-phone-v1a-4-reply.md`。
探查代码在分支 `probe/phone-v1a-4`（不合入，留给 V1a 取用），最后一个提交 `1ddfbc5a`。

**一句话：能。** 加一条"回复"请求，字节直接进程序的输入，不经过视图，也不经过「窗口跟谁」。这样 A 的窗口大小不变，跟的人也不变；另一个正开着的人照常看到输出。代码、单测和端到端测试都证明了这一点。真机、真 Claude Code 没验过。

## 机器和版本

| 项 | 值 |
|---|---|
| 机器 | MacBook Pro，Apple M5，24 GB，macOS 27.0.1（26A434） |
| 代码 | main `5ff4c980`（rapp 0.15.68），rapp-term `PROTO=2`、本机套接字 `LOCAL_V=2`，macOS host `protocolVersion` 16 |
| 工具 | rustc 1.99.1，Debug 构建；测试程序用 `/usr/bin/python3` 3.9.6 和 `/bin/sh` |
| 测法 | 全在本机：自己的临时目录、自己的端口；relay 是测试里起的进程内 relay（`RelayRig`，127.0.0.1）。没碰正在跑的 rapp、用户的会话和 VPS 上的 relay |

**没有手机真机参与**。"手机"由 hub 代替。iOS 上的 hub 和桌面是同一份 Rust 代码，见 iPad P0 Q1。

## Q1 今天的输入路径：哪一步要视图，哪一步会改大小

**结论：打字必须先开视图，而开视图（带 fit）本身就会抢「窗口跟谁」、改 A 的窗口大小；之后每次打字还可能在 2 s 后把位子抢过来。**

```
GUI TermSessionPort
  └─ hub "open"（嵌一个终端）──► service 接线 ──► rapp-term serve 的 view
        └─ holder 本机套接字 op "view" ──► view::serve（一个"看的人"）
              ├─ viewers += 1
              ├─ In::View{cols,rows,fit}  ──► fit.view()   ← ① 第一个带 fit 的人坐上位子，要求改大小
              │                              fit 写 ESC[8;rows;colst 给 A 的窗口 ← ② A 的窗口变成 B 的大小
              └─ In::Key / In::Text ──► view.input()
                    ├─ shared.input.send(bytes) ──► pty ──► 程序
                    ├─ note_input()
                    └─ fit.input(conn)              ← ③ 过了 HANDOVER=2 s，打字的人抢到位子，再改大小
```

| 步 | 代码 | 要视图？ | 会改大小？ |
|---|---|---|---|
| GUI 开终端舞台发 `view`，`fit: prefs.termFit`（默认开），用舞台的 cols/rows | `gui/lib/term/term_stage.dart:484` `_flushView` | 是 | 是：① ② |
| 第一个带 fit 的人坐上位子并要求改大小 | `rust/term/src/pty/fit.rs:43` `view` | 是 | 是 |
| holder 给 A 的窗口写 `ESC[8;rows;colst` | `rust/term/src/pty/fit.rs:300` | — | 是 |
| 看的人打字：送进 pty，再 `fit.input(conn)` | `rust/term/src/pty/view.rs:213` `input` | 是 | 可能：③（`fit.rs:19` `HANDOVER = 2 s`） |
| pty 本身改大小 | 只在 A 的窗口发 SIGWINCH 时 | — | 跟着窗口 |
| A 本地键盘 | `holder.rs:738` `pump_keyboard`：`shared.input` + `note_input` | 否 | 否 |

所以要改大小的不是"送字"，而是"送字必须经过的那个视图"。A 本地键盘那条路本来就不碰 fit，回复只要走它的路就行。

## Q2 不开视图的最小路径

**结论：做出来了。窗口大小不变，跟的人不变，看的人数不变，另一个开着的人照常看到输出。**

新路径（探查分支上）：

```
手机 hub  cmd "reply_term" {id, term, seq?, text?, enter?, keys?}
  └─ Op::ReplyTerm（rapp-net msg.rs，新的设备间消息）── LAN 直连 / relay ──►
A service term.rs request() ──► peer.rs 放行表 ──► rapp-term serve Req::Reply
  └─ holder 本机套接字 op "reply" ──► pty::reply::apply()
        ├─ 拼字节：text（程序要求时包成 bracketed paste）→ enter（\r）→ keys（keys::to_bytes，与视图同一张表）
        ├─ 持 shared.ps 锁：核对 seq（见 Q3）
        ├─ shared.input.send(bytes) ──► pty ──► 程序       ← 和 A 本地键盘同一个口
        └─ note_input()
        （不 join fit、不 view、不 fit.input、viewers 不加、serve 不记 inputs/activity）
```

| 测试 | 做法 | 结果 |
|---|---|---|
| `term/tests/reply.rs` `a_reply_reaches_the_program_without_a_resize_or_a_new_seat` | Mac 上一个视图以 90×20 坐上位子；等 2.2 s（过了交接时间）；回复 `hello`+回车 | 程序收到；窗口输出里 `ESC[8;` **只出现 1 次**（Mac 那次）；状态 cols/rows 不变，viewers=1；Mac 的视图看到 `hello`；Mac 下一次发 80×18 立刻被跟随，位子还在它手上 |
| 同上 `a_reply_with_no_viewer_at_all_never_resizes` | 没人看，回复 `y`+`Enter` | 程序收到；窗口输出里**没有** `ESC[8;`；viewers=0 |
| `pty/reply.rs` 单测 `a_reply_never_touches_fit_or_viewers` | 直接查 fit 的状态 | 回复后 `fit.take()==None`，原来的人再发尺寸立刻生效 |
| `term/tests/serve.rs` `reply_reaches_the_program_with_no_view` | 经 `rapp-term serve` 的 Req::Reply | ok + 程序收到；没有 `ESC[8;`；送的字不进日志 |
| `testkit/tests/probe_reply.rs`（真 `rapp-term run`，hub→service→serve→holder） | LAN 和 relay 各 40 次 + 1 次过期 seq | 全部送到；窗口输出里没有 `ESC[8;`；A 的 service.log 只有 `reply_term` 和"有没有字、几个键"，没有内容、没有会话 id |

改动的范围（都在探查分支上）：`rust/net/src/msg.rs`、`rust/service/src/{term,peer}.rs`、`rust/hub/src/{lib,link,terms}.rs`、`rust/term/src/{serve.rs,pty/{reply,local,holder,mod}.rs}`。macOS host（Swift）和 Windows 不用改。`rapp-term run`（holder）要新版，详见 Q5。

## Q3 seq 放在哪核对、拒绝说什么、seq 没变而状态已变的窗口

**结论：在 holder 里核对，持着 `shared.ps` 锁直到字节入队。拒绝原因只有两个：`changed`（附当前 seq）和 `typed`。"状态变了、seq 没变"的窗口 rapp 关不掉，只能缩小。**

- **放哪：** holder（`pty/reply.rs` `apply`）。只有它同时拿着最新的 `Ps` 和输入口；serve 和 service 看到的 seq 都是读快照时的旧值。核对和 `input.send` 在同一把 `shared.ps` 锁里，所以输出泵不能在核对之后、送出之前改掉快照。
- **拒绝：**

  | 情况 | holder 回 | 送了字？ |
  |---|---|---|
  | 带 seq，但会话没有状态 | `{"error":"changed","seq":null}` | 否 |
  | seq 对不上 | `{"error":"changed","seq":<当前>,"state":<当前>}` | 否 |
  | seq 对得上，但这个状态开始以后有人打过字（`input_at >= since`） | `{"error":"typed","seq":<当前>}` | 否 |
  | 不带 seq | 不核对，直接送 | 是 |
  | 文字太长（> 3000 字节）、未知的键、空 | `too long` / `unknown key` / `empty` | 否 |

  实测（`a_reply_for_an_old_seq_is_refused`）：程序报 blocked → 错的 seq 回 `changed`，程序没收到 → 对的 seq，程序收到 `y` 并报 working，seq 变大 → 再用老 seq 回 `changed`。`typing_on_the_mac_first_refuses_the_phone_s_reply`：Mac 上先敲了一个字（没回车），手机再回，得到 `typed`。
- **seq 从哪来：** `Ps.seq`（`pty/ps.rs`）。state、kind、app、msg、progress 或 stopped 一变就加 1；`since` 是这个状态开始的 Unix 秒。手机从 `terms` 列表每一行的 `ps` 里拿到 seq。
- **关不掉的窗口：** `ps` 只来自程序自己的 OSC 7501 报告。程序界面已经换了、下一次报告还没到的这段时间里，seq 不变。最坏的例子：同一个程序连问两个一样的 blocked 问题，中间没报 working，两次的 seq 一样。rapp 判断不出手机点的是第一个还是第二个。`typed` 保护能挡住"有人在 Mac 上先回答了"这种最常见的情况，因为回答本身就是打字；第一次回复也算打字，所以手机连点两下，第二下会被拒成 `typed`。
- **`typed` 的坑：**
  - `input_at` 是秒级：问题出现的同一秒里打的字也算"之后"，会多拒一次。
  - A 的窗口发来的焦点报告（`CSI I` / `CSI O`，程序开了 focus 模式才有）走 `pump_keyboard`，也会刷新 `input_at`。在 Mac 上切一下窗口，就可能让手机的回复被拒成 `typed`。
  - 这两种都是"多拒"，不会"错送"。
- **探查里没做好的：** serve 把 holder 的拒绝转成一句话往上传，`seq` 丢了。hub 最后给出的是 `{"event":"error","error":"changed"}`。正式做时应把当前 seq 和 state 一路带回手机，让卡片就地刷新。

## Q4 来回多久

**结论：A 本机这一段约 0.1–0.2 ms；hub 到程序，LAN 回环中位约 0.9 ms，进程内 relay 回环中位约 3.1 ms，最慢 6.9 ms。真实网络没量，应当约等于一次网络往返。**

| 段 | 方法 | n | 中位 | 最慢 |
|---|---|---|---|---|
| holder 本机套接字 → 程序读到这一行 | `term/tests/reply.rs` `measure_reply_to_program_latency`（ignored，手跑）；python 记 `time_ns` | 50 ×3 | 188 / 56 / 191 µs | 4.2 / 1.3 / 4.1 ms |
| hub 发 `reply_term` → A 上程序读到（LAN，回环） | `testkit/tests/probe_reply.rs` `reply_term_over_lan` | 40 ×3 | 0.96 / 0.94 / 0.89 ms | 1.51 / 1.14 / 1.32 ms |
| 同上，hub 收到回答 | 同上 | 40 ×3 | 1.20 / 1.17 / 1.10 ms | 2.00 / 1.48 / 1.65 ms |
| hub 发 → A 上程序读到（relay，进程内回环） | `reply_term_over_the_relay`；A 只登记一个死的 LAN 地址，路径确认是 `relay` | 40 ×3 | 3.03 / 3.15 / 3.10 ms | 6.88 / 5.37 / 3.52 ms |
| 同上，hub 收到回答 | 同上 | 40 ×3 | 3.33 / 3.47 / 3.38 ms | 7.25 / 6.23 / 3.85 ms |

- 每次之间隔 50 ms；第一次（建路径）不算。
- hub 的回答总在程序读到之后到。也就是说，手机收到"已送到"时，字确实已经进了程序。
- 手跑：

  ```
  cargo build -p rapp-term
  RAPP_REAL_TERM=$PWD/target/debug/rapp-term cargo test -p rapp-testkit --test probe_reply -- --ignored --nocapture --test-threads=1
  ```

## Q5 老版本的识别（I6）

**结论：拒绝的路两层都有，老版本不会误送；但要"老版本不显示按钮"，得事先知道，需要加一个能力标记。**

- **事后（发了才知道）：**
  - 老 A 的 service 不认 `reply_term`：`peer.rs` `serve_value` 解析不出这个 Op，落到 `_ => err("unknown op")`。每个请求一条流，所以只是这条流收到拒绝，连接不会断。
  - 新 service、老 holder（会话是用老 `rapp-term run` 开的）：holder 回 `{"error":"unsupported"}`，serve 换成 `OLD_RUN_REPLY`，告诉人"这个会话是老版本开的，到 A 上回"。
  - 两种情况都不送字。
- **事先（按钮显示前）：** A 在 `apps` 事件里已经带上 `version`（`CARGO_PKG_VERSION`）和 `capabilities`（`service/src/workers.rs:91`，现在有 graphical / terminal / ports，Linux 另有 desktop / applications）。两种做法：
  1. 加 `capabilities.reply: true`。只有新 service 会带，手机没看到就不显示按钮。推荐这种：不依赖版本号的比较，Windows 和 Linux 各自打开时也只需要这一处。
  2. 手机比 `version >= 首个支持的版本`。不用改 A，但要写死版本号，Linux 的补丁号也会穿插进来。
- **还要按会话分：** 同一台新 A 上，老 holder 开的会话也回不了。holder 的状态（`Status`）没有版本字段，探查没加。可行的办法有两个：手机收到 `OLD_RUN_REPLY` 后把这个会话的按钮换成"到 A 上回"；或者在 `Status` 里加一个 holder 能力位。
- **都不用涨协议号：** `reply_term` 是新增的 Op，老的一端遇到它是拒绝，不会断连。holder 的本机套接字里 `op:"reply"` 也是新增，`LOCAL_V` 不用变。

## Q6 手机进后台、锁屏

**没验过。** 这需要手机真机。从代码看：`reply_term` 是一次请求一次回答，hub 不重发（`link.rs` 的 `repeatable()` 已经排除了 `ReplyTerm`，见 C13）。所以如果在途中被挂起，可能的结果只有两种：送到了但手机没收到回答，或者根本没送出去。不会送两次。回到前台后，手机应当重新拉一次 `terms`，用新的 seq 刷新卡片，不要自动重发。

## 过关判定（验收第 3 条：手机点「允许」，A 的终端大小不变）

**能过。** 这条路径从结构上就不碰 fit 和视图，测试也证明窗口输出里没有改大小的序列、cols/rows 不变、跟的人不变。真 Claude Code、真手机上的一次实机确认没做。

## 没验过的

- 手机真机：iOS 上的 hub、进后台、锁屏（Q6）。
- 真实网络上的 relay（只量了进程内回环 relay）。VPS 不能碰。
- 真 Claude Code / Codex 的权限提示：测试用的是自己写的 sh 脚本，它报 OSC 7501 blocked 后读一行。真程序的提示要哪几个键、是不是 raw 模式下读单键，都没验。
- 焦点报告让 `typed` 误拒（Q3）：只是读代码得出的，没复现。
- Windows、Linux 上的 holder：只在 macOS 上跑过。

## 对规格的影响

- **§7.4.8 "按键由跑 CLI 的那一端照 app 配置换成字节"：现在做不到。** app 配置（`gui/assets/app_profiles.json`）只在 GUI（B 端）里有，里面也还没有"回复"用的键。A 端的 service 和 rapp-term 都没有 app 配置。要照规格做，A 端得带上 app 配置；不然就由手机把「允许 / 拒绝」换成键再发（探查的接口两种都支持：`text` + `enter` + `keys`）。**这件事要用户定**，见下。
- **S4（回复不算输入次数）：** 探查里回复不进 serve 的 `inputs` 计数，也不发 activity 事件，和规格一致。但回复会刷新 holder 的 `input_at`，这是 `typed` 保护要用的。
- **I6：** 规格说老版本不显示按钮。要做到，需要 Q5 的能力标记，也就是设备间多一个字段。另外按会话还有一层"老 holder"，规格里没写。
- **新增设备间消息 `reply_term`：** 规格里如果写的是"不加协议消息"，这一条就要改。

## 给下一期的话

- **推荐的设计：**
  - 分层：手机 GUI → hub cmd `reply_term` → `Op::ReplyTerm`（rapp-net）→ A service（`term.rs` 接请求，`peer.rs` 放行）→ `rapp-term serve` `Req::Reply` → holder 本机 op `reply` → `shared.input`。
  - 要改的 crate：rapp-net、rapp-service、rapp-hub、rapp-term，再加 GUI。不改 Swift host，不涨协议号。
  - 可以直接从 `probe/phone-v1a-4` 摘代码。
- **常量：**
  - `MAX_TEXT = 3000` 字节（本机套接字一行最长 4096）；
  - 本机请求等待 `STATUS_WAIT = 500 ms`；
  - `HANDOVER = 2 s`（视图打字抢位子的时间，回复不受它影响）。
- **接口：**

  ```
  hub cmd:  {"cmd":"reply_term","id":<A>,"term":"term:pty:<key>","seq":<u64>?,"text":<str>?,"enter":<bool>?,"keys":[<键名>]?,"req":..}
  成功:     {"event":"term_replied","id":<A>,"term":..,"req":..}
  失败:     {"event":"error","error":"changed"|"typed"|"too long"|"unknown key"|"empty"|<OLD_RUN_REPLY>|<NO_TEXT_TERMINAL>|<TERM_BUSY>,"req":..}
  ```

  键名与视图同一张表（`term/src/keys.rs`）：`Esc`，不是 `Escape`。
- **坑：**
  1. 拒绝时要把当前 seq 和 state 一路带回去（探查在 serve 那层丢了）。
  2. hub 绝不能重发 `reply_term`，`repeatable()` 里要排除它，并加测试守住。
  3. 日志只记"有没有字、几个键"，不记内容和会话 id（探查已这样做，并有测试）。
  4. 文字要按程序的 bracketed paste 模式包起来，回车单独发，不要把 `\r` 放进 paste 里。
  5. `typed` 是秒级，并且会被焦点报告触发：只会多拒，不会错送。要不要留，见下。
  6. testkit 里的假 `rapp-term` 不认 `reply`，端到端测试要像 `probe_reply.rs` 那样换成真的 `rapp-term`。

## 要用户定的

1. **加设备间消息 `reply_term`，并在 `capabilities` 里加 `reply: true`。** 这是新的协议消息，不涨协议号；老版本遇到它会拒绝，不会断连。不加的话，手机只能开视图打字，而开视图会改 A 的窗口大小，验收第 3 条就过不了。
2. **「允许 / 拒绝」换成键这件事放在哪一端。**
   - (a) 手机按 GUI 已有的 app 配置把它换成键再发：现在就能做，但 A 上的 CLI 升级、改了键时，要靠手机端的配置跟上。
   - (b) A 端带 app 配置，自己换：和规格 §7.4.8 一致，但 service 或 rapp-term 要多一份配置。
3. **留不留 `typed` 保护。** 它挡住"Mac 上已经回答了，手机又回一次"。代价是秒级精度和焦点报告会多拒，被拒时用户要再点一次。
4. **老 holder 开的会话怎么显示：** 手机收到"老版本"的拒绝后改成"到 A 上回"，还是在会话状态里加一个能力位，事先就不显示按钮。
5. **实机确认验收第 3 条：** 在 A 上用真 Claude Code 弹一个权限提示，B 开着终端舞台，手机点「允许」，看 A 的窗口大小和 B 的画面有没有变。这一步需要手机真机和真 CLI。
