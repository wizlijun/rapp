# 端口分享：复用通道后开转发连接的耗时

日期：2026-11-16（本机），真机待做。计划：端口分享 第 1 步（下）：复用通道和会话优先 Task 6。规格：《端口分享设计》§5.2。基线：`2026-11-15-port-sharing-forward-baseline.md`。

## 量什么

工具和四行的含义同基线文档：`measure`（`rust/testkit/src/lib.rs`），`open_seq`、`open_par`、`first_byte`、`path`，中位数和第 95 百分位按最近秩取，单位毫秒。

和基线的区别：先 `pipe` 一次，让通道建好（旧式组是让访问方记下"这台是旧的"），再量。规格 §5.2 的要求：通道建好以后，每新开一条转发连接，额外的耗时不超过两台设备经 relay 的一个往返。

## 进程内（本机回环）

机器：Apple M5，macOS 27.0.1，测试配置（没优化）。提交 39bb41e 之上（分支 `feat/port-share-mux`）。

Run: `cd rust && cargo test -p rapp-testkit --test forward measure -- --nocapture`

```
open_seq    n=50   median     0.51 ms   p95     0.69 ms
open_par    n=50   median     1.08 ms   p95     1.24 ms
first_byte  n=50   median     0.31 ms   p95     0.48 ms
path        relay=100
```

基线（每条各握一次手）是 `open_seq` 2.41 ms、`open_par` 11.16 ms。回环上没有网络往返，量到的是 CPU 和调度：握手省掉以后 `open_seq` 约为原来的 1/5，`open_par` 约 1/10。

## 加了延迟（每单向 25 ms）

测试 `opening_over_the_channel_costs_one_round_trip`（`rust/testkit/tests/forward.rs`）。访问方 B 和 relay 之间过一个弱网代理（`weaknet::spawn_proxy`，`profiles/lan.json` 加 `delay_ms` 25、`seed` 1），每单向 25 ms，往返 50 ms；分享方 A 直连 relay，不加。两台经 relay 的一个往返约 50 ms。每组各起一套新的 relay、A、B，先 `pipe` 一次再量，`n=50`，`parallel=6`。

Run: `cd rust && cargo test -p rapp-testkit --test forward opening_over_the_channel -- --nocapture`

旧式（A 的 `channels=false`，B 退回每条一流，就是 1a 的路）：

```
open_seq    n=50   median   117.03 ms   p95   120.64 ms
open_par    n=50   median   140.46 ms   p95   144.27 ms
first_byte  n=50   median    56.14 ms   p95    57.63 ms
path        relay=100
```

通道：

```
open_seq    n=50   median    56.57 ms   p95    58.33 ms
open_par    n=50   median    57.13 ms   p95    59.13 ms
first_byte  n=50   median    56.42 ms   p95    58.14 ms
path        relay=100
```

| 项 | 旧式 | 通道 |
|---|---|---|
| `open_seq` 中位数 | 117.0 ms（约 2.3 个往返） | 56.6 ms（约 1.1 个往返） |
| `open_par` 中位数 | 140.5 ms | 57.1 ms |
| 倍数（`open_seq` 中位数 ÷ 50 ms） | 2.3 | 1.13 |

通道组 A 的日志里恰好一行 `channel`。连跑三遍都通过。通道比一个往返多出的约 6 ms 是本机的 CPU 和调度（回环上 `open_seq` 0.5 ms，加上两头的 TLS 记录和帧），不是第二个往返。

## 会话优先（§5.3）

进程内，经弱网代理，量分享方的 relay 连接上一条大转发对远程会话往返的影响。测试 `rust/testkit/tests/session_priority.rs`（`#[ignore]`）。机器同上（Apple M5，macOS 27.0.1），提交 5f7309f 之上加本测试。

Run: `cd rust && cargo test -p rapp-testkit --release --test session_priority session_latency -- --ignored --nocapture`（发布配置，约 86 s；没优化的配置里加密太慢，会先成为瓶颈）

做法：每组各起一套新的 relay、A（分享方）、B（访问方）。会话是另一个 B 身份的 relay 连接，开 `com.example.echo`，每 20 ms 写 16 字节、读回 16 字节，记往返。大转发是 A 上一个不停写的 TCP 服务，B 的 `pipe` 过去一直读（转发开始后先等 1 s 让下载爬升，再量 10 s）。每组先只跑会话 10 s（基线），再加上大转发跑 10 s。`wan`：A 的 relay 地址前放代理，`lan.json` 改成 `rate_kbps` 20000、`delay_ms` 15（单向）、`queue_ms` 100、`seed` 7；B 直连 relay。`lan`：不经代理。每种网络两组：A 的转发优先级为 `FORWARD_PRIORITY`（-1）和 0（关掉优先级）。

判定规则（跑之前定的，写在测试文件头）：`wan` 下优先级 -1 那一组，和同组没有转发时相比，会话往返 p50 增加 ≤ 20 ms 且 p95 增加 ≤ 40 ms，算达标。

往返的单位是毫秒，增加 = 有转发 − 基线，"转发"是大转发那 10 s 的下载速率（Mbit/s）。

### 第 1 遍

| 网络 | 优先级 | 基线 p50/p95 | 有转发 p50/p95 | 增加 p50/p95 | 转发 Mbit/s | 判定 |
|---|---|---|---|---|---|---|
| lan | -1 | 0.2/0.3 | 6.1/7.7 | 5.9/7.4 | 899.4 | - |
| lan | 0 | 0.3/0.3 | 5.9/7.2 | 5.6/6.9 | 940.2 | - |
| wan | -1 | 34.3/35.9 | 113.9/131.0 | 79.5/95.1 | 19.5 | 不达标 |
| wan | 0 | 34.3/35.9 | 114.6/131.3 | 80.4/95.4 | 19.5 | - |

### 第 2 遍

| 网络 | 优先级 | 基线 p50/p95 | 有转发 p50/p95 | 增加 p50/p95 | 转发 Mbit/s | 判定 |
|---|---|---|---|---|---|---|
| lan | -1 | 0.3/0.3 | 5.6/7.0 | 5.3/6.7 | 961.0 | - |
| lan | 0 | 0.3/0.4 | 5.9/7.9 | 5.7/7.6 | 921.8 | - |
| wan | -1 | 34.5/36.0 | 114.4/131.4 | 79.9/95.4 | 19.5 | 不达标 |
| wan | 0 | 34.4/36.2 | 115.4/129.2 | 81.0/93.1 | 19.5 | - |

### 第 3 遍

| 网络 | 优先级 | 基线 p50/p95 | 有转发 p50/p95 | 增加 p50/p95 | 转发 Mbit/s | 判定 |
|---|---|---|---|---|---|---|
| lan | -1 | 0.5/0.7 | 5.5/6.8 | 5.0/6.2 | 984.9 | - |
| lan | 0 | 0.5/0.7 | 5.5/6.5 | 5.0/5.9 | 998.9 | - |
| wan | -1 | 34.5/36.0 | 114.6/131.0 | 80.1/95.0 | 19.5 | 不达标 |
| wan | 0 | 34.3/36.1 | 115.1/129.1 | 80.8/92.9 | 19.5 | - |

### 结论

**`wan` 下不达标，三遍一致。** 优先级 -1 时会话往返 p50 增加约 80 ms（规则 ≤ 20）、p95 增加约 95 ms（规则 ≤ 40）。

- **优先级管不管用：** 看不出差别。`wan` 下优先级 -1 和 0 两组增加量只差 1 ms 以内（p50 79.5–80.1 对 80.4–81.0，p95 95.0–95.4 对 92.9–95.4），在三遍之间的波动里。
- **增加量是不是瓶颈队列：** 是。增加量约 80 ms（p50）到 95 ms（p95），接近 `queue_ms` = 100 ms 的瓶颈队列被填满（尾丢弃前队列最多 100 ms，会话包平均排在中间偏后）。转发把 20 Mbit/s 的瓶颈跑满（19.5 Mbit/s），Cubic 把队列填起来，会话的包和转发的包在队列里一样排。这正是计划第 11 条说的：优先级只管 quinn 自己发送缓冲里谁先走，包发出去以后在路上的队列里管不到。
- `lan`（1 Gbit/s，延迟 1 ms，不经代理）两组都只增加约 5–6 ms，是本机 CPU 被转发占满造成的，不是网络排队；优先级同样看不出差别。

没有改阈值。限速（给转发定一个低于瓶颈的上限）或换拥塞控制（BBR 之类，见 `cc_compare.rs`）作为下一件事，要用户定；这一份都没做。

### 同一通道里的小连接

量的是同一条通道里，一条大转发旁边的一条小转发（比如一边 `curl` 一个大文件、一边开着 `ssh`）。通道是一条 relay 流、一条 QUIC 流；复用层自己每条子流最多缓 64 KiB，但 quinn 收下写进来的字节，直到这条流的流量窗口（relay 每条流 1 MiB，`rust/wire/src/tls.rs` 的 `SERVER_STREAM_WINDOW`）用满，所以小转发的帧可能排在最多约 1 MiB 已经交给 quinn 的大转发字节后面。

测试 `small_forward_beside_a_bulk_one`（同一个文件，`#[ignore]`）。`wan` 配置同上（A 的 relay 地址前放代理，20 Mbit/s、单向 15 ms、`queue_ms` 100、`seed` 7），A 的转发优先级 `FORWARD_PRIORITY`。A 分享一个回声端口和上面那个不停写的服务；B 先 `pipe` 到回声端口，每 20 ms 写 16 字节、读回 16 字节，单独量 10 s；再 `pipe` 到不停写的服务一直读（同一条通道，测试断言 A 只记了一行 `channel`），等 1 s 让下载爬升，再量 10 s。只记数，不判定（跑之前写在测试文件头）：规格没给同一通道里两条转发之间的要求。机器同上，提交 86e0a46 之上加本测试。

Run: `cd rust && cargo test -p rapp-testkit --release --test session_priority small_forward -- --ignored --nocapture`（约 25 s）

往返的单位是毫秒，增加 = 有大转发 − 单独，"大转发"是那 10 s 的下载速率（Mbit/s）。

| 遍 | 网络 | 单独 p50/p95 | 有大转发 p50/p95 | 增加 p50/p95 | 大转发 Mbit/s |
|---|---|---|---|---|---|
| 1 | wan | 34.5/36.1 | 218.2/310.0 | 183.7/273.9 | 19.5 |
| 2 | wan | 34.7/36.4 | 218.5/220.2 | 183.8/183.9 | 19.5 |
| 3 | wan | 34.8/36.4 | 218.4/220.0 | 183.6/183.5 | 19.5 |

三遍的 p50 一致：有大转发时小转发的往返约 218 ms，增加约 184 ms，是同样配置下会话增加量（约 80 ms，上面的表）的两倍多。会话那 80 ms 是路上瓶颈队列；小转发还要多排约 100 ms，排在同一条 QUIC 流里大转发已经交出去的字节后面（上限是流的窗口 1 MiB，20 Mbit/s 下约 420 ms）。第 1 遍的 p95 310 ms 是开头一段更长的排队，后两遍没有。

### 已知的限制

- **一条通道的总吞吐。** 通道是一条 QUIC 流，在途的字节最多一个流窗口（1 MiB），所以一对设备之间所有转发加起来最多约每个往返 1 MiB：往返 100 ms 时约 80 Mbit/s，往返 200 ms 时约 40 Mbit/s。1a 是每条转发各一条流、各 1 MiB；1b 把它们放进一条，几条大转发同时跑时总和不再随条数增加。上面 `wan` 的瓶颈是 20 Mbit/s，量不到这个上限。
- **严格优先级可能触发 `DEAD_AFTER`。** quinn 的优先级是严格的：分享方的 relay 连接上会话一直有东西要发，通道就一个字节都发不出去，连 `PONG` 也不发。会话连续占满 30 s，访问方 `DEAD_AFTER` 到了就把通道关掉（原因 `dead`），上面开着的转发（比如 `ssh`）一起断。只记下，没改代码；会话一直占满 relay 连接 30 s 不常见（画面有变化时才发），但大画面持续变化时可能。

小连接排在大转发后面、一条通道的吞吐上限，和上面会话的不达标是同一件待用户定的事（限速或换拥塞控制）：在复用层给每条子流（或整条通道）限速，也能缓解这两条。

### 真机测量（待做）

分享方在 relay 上分享一个大文件的 http 服务（如 `python3 -m http.server`）。访问方一边开着到分享方的远程会话，看 `[stats]` 的画面延迟，一边 `curl -o /dev/null http://<ID>.rapp:<端口>/<大文件>`。记有无下载时画面延迟的中位数和第 95 百分位，对照流畅串流规格的目标（中位数/第 95 百分位 ≤ 60/100 ms）。

## 真机测量（待做）

步骤同基线文档的"真机测量（待做）"：两台都跑这一版的 `rapp-service`，访问方在 `rust/` 下跑 `cargo run --release -p rapp-testkit --bin measure-forward -- --to <分享方的 ID> --port 9000`（对着回声服务），另外两台各 `ping -c 20 <relay 的主机>`。**先 `pipe` 一次**（或丢掉前几条）再看数。倍数 = `open_seq` 中位数 ÷ 两台经 relay 的一个往返，要不超过 1.5，和测试 `opening_over_the_channel_costs_one_round_trip` 的判定一样：规格要的是"额外不超过一个往返"，开一条要等的就是这一个往返，再给两头的处理（TLS 记录、帧、调度）留半个往返；进程内量到的是 1.13。`path` 应该只有 `relay=100`。

| 项 | 值 |
|---|---|
| 日期、提交 | |
| 访问方：机器、网络 | |
| 分享方：机器、网络（NAT 的样子） | |
| relay：在哪 | |
| 两台经 relay 的一个往返 | |

```
open_seq    n=     median          ms   p95          ms
open_par    n=     median          ms   p95          ms
first_byte  n=     median          ms   p95          ms
path
```

| 项 | 值 |
|---|---|
| 倍数（`open_seq` 中位数 ÷ 一个往返） | 待真机 |
