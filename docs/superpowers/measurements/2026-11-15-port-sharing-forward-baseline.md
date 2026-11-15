# 端口分享：经 relay 每条转发各握一次手的耗时（基线）

日期：2026-11-15（本机），真机待做。计划：《端口分享 第 1 步（上）：底座》Task 10（`docs/superpowers/plans/2026-11-15-port-sharing-1a-base.md`）。规格：《端口分享设计》§5.2。

这一版里，经 relay 的每条转发连接各自是一条 relay 流，各自做一次端到端 TLS 握手（计划"计划定的"第 2 条）。这份记下它有多慢，给下一份计划（复用通道）当基线。

## 量什么

工具：`measure-forward`（`rust/testkit/src/bin/measure_forward.rs`，核心在 `rust/testkit/src/lib.rs` 的 `measure`）。在访问方那台机器上跑，经本机服务 IPC 的 `pipe` 命令开转发，对着分享方的一个回声端口。

| 行 | 量什么 |
|---|---|
| `open_seq` | 一条一条地开 `n` 条转发，每条从发 `pipe` 命令到收到 `{"ok":true}`；每条量完 `first_byte` 就关掉，再开下一条 |
| `open_par` | 再开 `n` 条，每轮同时开 `parallel` 条，每条的同一段时间；一轮的全部开着，等这一轮都开完才关 |
| `first_byte` | `open_seq` 的每条：收到 `ok` 以后写 1 个字节，到读回 1 个字节 |
| `path` | 两种开法加起来，每条走的路（`lan`、`direct`、`relay`）各多少条 |

中位数和第 95 百分位都按最近秩取，单位毫秒。

按代码数，经 relay 的一条 `open_seq` 包括：在已有的 relay 连接上开一条 relay 流；里面一次 TLS 1.3 握手（一个端到端往返）；hello 和 `forward` 一起发，等 welcome 和回复（又一个端到端往返）；分享方连自己的 `127.0.0.1:端口`。relay 的 `connect`（问对方在哪）不在里面：问过一次，`FOUND_KEEP`（30 秒）内的请求直接开 relay 流（`rust/conn/src/dial.rs:40`）。所以每 30 秒有一条要多问一次 relay，并试 relay 给的局域网地址（一起拨，最多等 `DIRECT_WAIT` 1 秒）。这一条只影响 p95，不影响中位数。

## 进程内（本机回环）

机器：Apple M5，macOS 27.0.1。提交 70ae54e（分支 `feat/port-share-base`），测试配置（没优化）。

Run: `cd rust && cargo test -p rapp-testkit --test forward measure -- --nocapture`

测试 `measure_the_forward_over_the_relay`（`rust/testkit/tests/forward.rs:1203`）在本机起一个 relay 和两台服务，都在回环上。分享方不报局域网地址，所以全走 relay。relay 的 `connect_per_target_per_min` 调到 1000。`n=50`，`parallel=6`。

```
open_seq    n=50   median     2.41 ms   p95     4.90 ms
open_par    n=50   median    11.16 ms   p95    11.40 ms
first_byte  n=50   median     0.44 ms   p95     0.53 ms
path        relay=100
```

这只是回环：没有网络往返，量到的是 CPU 和本机调度。它只能说明两件事：经 relay 的代码路径是通的；路上没有额外的固定等待（没有哪一步在睡、在等超时）。它说明不了真机上有多慢。`open_par` 比 `open_seq` 慢，是 6 条的握手挤在同一时间算，回环上看不出网络的事。

## 真机测量（待做）

条件：分享方在 NAT 后面，和访问方不在同一个局域网；访问方经真的 relay。两台都跑这一版的 `rapp-service`，`service.json` 里填同一个 relay 和同一把 key。

1. 分享方：起一个回声服务，分享它。

   ```
   python3 -c "import socketserver as s
   class H(s.BaseRequestHandler):
       def handle(self):
           while d := self.request.recv(65536): self.request.sendall(d)
   s.ThreadingTCPServer(('127.0.0.1', 9000), H).serve_forever()" &
   cd rust && cargo run --release -p rapp-cli -- share 9000
   ```

   记下打印的 `已分享：http://<ID>.rapp:9000` 里的 ID。

2. 访问方：在仓库的 `rust/` 下跑。

   ```
   cargo run --release -p rapp-testkit --bin measure-forward -- --to <分享方的 ID> --port 9000
   ```

   参数：`--to <ID>`（必填，写 `<ID>` 或 `<ID>.rapp`）、`--port <端口>`（必填，必须是回声服务）、`--n <条数>`（默认 50）、`--parallel <同时开几条>`（默认 6）。它从本机的 `local/` 读 `ipc.token` 和 `service.json` 的 `ipc_port`（没有就是 22029）；`local/` 照服务的找法（`RAPP_HOME`、`data-root` 指针、`~/rapp`），设了 `RAPP_LOCAL` 就直接用它。打印四行；`path` 应该只有 `relay=100`，有 `lan` 或 `direct` 说明没走 relay，这次不算。

3. 同时量两个往返：在访问方和分享方上各跑一次 `ping -c 20 <relay 的主机>`，记 `avg`。两台设备经 relay 的一个往返，约等于这两个数相加。

| 项 | 值 |
|---|---|
| 日期、提交 | |
| 访问方：机器、网络 | |
| 分享方：机器、网络（NAT 的样子） | |
| relay：在哪 | |
| 访问方 → relay，ping avg | |
| 分享方 → relay，ping avg | |
| 两台经 relay 的一个往返（上面两个相加） | |

```
open_seq    n=     median          ms   p95          ms
open_par    n=     median          ms   p95          ms
first_byte  n=     median          ms   p95          ms
path
```

## 给下一份计划的

规格 §5.2 的要求：一对设备之间经 relay 只建一条长开的加密通道；通道建好以后，每新开一条转发连接，额外的耗时不超过两台设备经 relay 的一个往返。

这一版没有通道，每条都握一次手。`open_seq` 的中位数除以"两台经 relay 的一个往返"，就是下一份计划要消掉的倍数：复用通道做完，这个倍数要不超过 1（`first_byte` 本来就要一个往返，不算在额外里）。

| 项 | 值 |
|---|---|
| `open_seq` 中位数 | 待真机 |
| 两台经 relay 的一个往返 | 待真机 |
| 倍数（前者除以后者） | 待真机 |
| 按代码估 | 约 2（TLS 握手一个往返，hello 加 `forward` 一个往返） |

同时看 `open_par`：网页一打开就是几十条连接一起开。下一份计划的验收也要量同时开的情况，不能只看一条一条地开。
