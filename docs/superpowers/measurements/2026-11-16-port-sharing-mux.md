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

待 Task 7 填。

## 真机测量（待做）

步骤同基线文档的"真机测量（待做）"：两台都跑这一版的 `rapp-service`，访问方在 `rust/` 下跑 `cargo run --release -p rapp-testkit --bin measure-forward -- --to <分享方的 ID> --port 9000`（对着回声服务），另外两台各 `ping -c 20 <relay 的主机>`。**先 `pipe` 一次**（或丢掉前几条）再看数。倍数 = `open_seq` 中位数 ÷ 两台经 relay 的一个往返，要不超过 1。`path` 应该只有 `relay=100`。

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
