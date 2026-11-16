# 交接：端口分享改用本机端口（`localhost:<端口>`）

日期：2026-11-16（19:55 JST 写；20:10 更新：已提交，已并进 `main`）。写的人：Claude（这个会话到此为止）。

这份文档给接手的人或代理看。读完应该知道：东西在哪、做到哪一步、哪些验证过、哪些没有、下一步做什么。

---

## 1. 一句话

用户要求访问方不再用 `http://<id>.rapp:<端口>`，改成 `http://localhost:<本机端口>`（反馈文档 U151）。**代码、测试、文档都写完了，Rust 这边验证过，界面这边没有跑过测试。用户随后要求合并（U152："合并到 main 里"），已经提交并并进 `main`。**

- 用户的原话：`docs/superpowers/specs/2026-11-12-rapp-requirements-feedback.md` 的 U151。
- 设计：`docs/superpowers/specs/2026-11-16-rapp-port-sharing-local-ports-design.md`（状态：已实现，已并进 `main`）。
- 待办和真机检查单：`tasks/todo.md` 最后一节。

## 2. 东西在哪

| 什么 | 在哪 |
|---|---|
| 工作树 | `/Users/bruce/git/rapp/.claude/worktrees/port-map`（合并以后内容和 `main` 相同，可以收掉，见 §7 第 6 步） |
| 分支 | `feat/port-map`，起点是 `main` 的 `e6d0894`（release: 0.12.1） |
| 提交 | 三个，作者都是 `Claude <noreply@anthropic.com>`：`fda0f49`（服务、命令行、测试，15 个文件）、`f8db16c`（界面，6 个文件）、再一个文档提交（8 个文件，含这份文档） |
| `main` | 用 `--no-ff` 把 `feat/port-map` 合并进来了，合并提交 `3e6e43d` |
| 推送 | 没有 |

**关于这个工作树**：它是我从 Mac 上的 Linux 命令行环境里用 `git worktree add` 建的，建完把两处路径改成了 Mac 的路径（`.git/worktrees/port-map/gitdir` 和工作树里的 `.git` 文件），和仓库里别的工作树写法一样。我没有在 macOS 的 git 里验证过它。如果 `git worktree list` 里它不正常，在仓库根目录运行 `git worktree repair .claude/worktrees/port-map`。

## 3. 改了什么

### 新增

| 文件 | 是什么 |
|---|---|
| `rust/service/src/maps.rs` | 本机端口表：分配、监听、收回、存取（`local/maps.json`）。文件内有 12 条单元测试 |
| `rust/testkit/tests/maps.rs` | 端到端测试 10 条 |
| `docs/superpowers/specs/2026-11-16-rapp-port-sharing-local-ports-design.md` | 设计 |
| `docs/superpowers/plans/2026-11-16-port-sharing-local-ports-handoff.md` | 这份交接文档 |

### 改动

| 文件 | 改了什么 |
|---|---|
| `rust/service/src/lib.rs` | `mod maps`；`MAP_PORTS`；`Opts.map_ports`；启动时读表并恢复监听；停止时关掉 |
| `rust/service/src/state.rs` | `State.maps` |
| `rust/service/src/main.rs` | `Opts` 多一项 |
| `rust/service/src/pipe.rs` | `known_ids()`：区分"设备列表读不出来"和"列表是空的" |
| `rust/service/src/share_cmds.rs` | `shares`（带 `to`）给能用的分享建本机端口；回复里 `addr` 换成 localhost 的写法，多了 `local`，去掉 `url`；本机自己的分享地址是 `localhost:<原端口>` |
| `rust/service/src/ipc.rs` | `hosts` 的回复里每个分享带 `local` 和 `addr`；设备不在列表里时收回它的端口 |
| `rust/cli/src/say.rs` | `rapp hosts` 每个端口一行带地址；`rapp share` 不打印 `.rapp` 地址，结尾加一句去哪看；`rapp share`（不带端口）的表去掉"地址"一列；`columns()` 不再让一行的最后一格撑宽那一列 |
| `rust/testkit/tests/common/mod.rs`、`common/sharing.rs` | `start_service_ports()`、`without_local()` 两个测试用的帮手 |
| `rust/testkit/tests/forward.rs`、`share_set.rs`、`hub.rs`、`service.rs` | 跟着新的回复和输出改断言；`Opts` 多一项 |
| `gui/lib/shares.dart` | `SharesApi.rappNames` 去掉；`ShareRow.addr` 的说明 |
| `gui/lib/service_client.dart` | `ServiceStatus.rappNames` 去掉 |
| `gui/lib/ui/shares_section.dart` | "打开"在有地址时可用；去掉"还没有启用 .rapp 域名"那一行；没有地址时"复制"是灰的，显示"没有本机端口可用" |
| `gui/test/shares_test.dart`、`test/ui/shares_section_test.dart`、`test/ui/allow_dialog_test.dart` | 跟着改；新增两条界面测试 |
| `docs/superpowers/specs/2026-11-15-rapp-port-sharing-design.md` | 状态行下面加一段说明：地址在试另一种做法，§9 桌面入口搁置。**正文没有改** |
| `docs/superpowers/specs/2026-11-15-rapp-port-sharing-panel-design.md` | §6.2 开头加一段说明：§6.2、§6.3 被新设计换掉 |
| `docs/superpowers/specs/2026-11-13-rapp-config-reference.md` | 加 `local/maps.json` |
| `docs/superpowers/specs/2026-11-11-rapp-observability-design.md` | 加三个日志事件：`map_refused`、`map_port_taken`、`maps_unreadable` |
| `docs/superpowers/specs/2026-11-12-rapp-requirements-feedback.md` | U151 一行，修订一行 |
| `tasks/todo.md` | 末尾加一节 |

### 做法的要点（细节在设计文档）

- 本机端口范围 28000–28999，取最小的空闲端口；先连一下看有没有别的程序在答应，再在 `127.0.0.1` 和 `::1` 上监听。只监听回环地址。
- 面板读一台设备的分享表、或运行 `rapp hosts` 时，给能用的分享建端口，收回已经不能用的。
- 服务启动时按 `local/maps.json` 恢复监听，不用先打开面板。
- 每条连进来的连接走 `pipe::open`，和 `rapp pipe` 同一段代码。接不上就关掉连接，记 `map_refused`。

## 4. 验证过的

在 Mac 上的 Linux 命令行环境里（arm64，rustc 1.100，**不是 macOS**）：

| 项 | 结果 |
|---|---|
| `rapp-service` 单元测试 | 97 过，1 不过（见下） |
| 其中 `maps::` | 12 条全过 |
| `rapp-testkit --test maps` | 10 条全过 |
| `rapp-testkit --test share_set` | 18 条全过 |
| `rapp-testkit --test forward` | 65 条全过 |
| testkit 其余：`service` 51、`hub` 61、`hub_terms` 9、`term` 14、`update` 32、`netmon` 5、`key_change` 6、`route` 16、`weaknet` 4 | 全过 |
| `rapp-cli` | 10 条全过 |
| 工作区其余（`wire`、`conn`、`net`、`relay`、`hub`、`update`、`term`、`client-core`） | 除下面 2 条外全过 |
| `cargo clippy -p rapp-service -p rapp-cli -p rapp-testkit --all-targets` | 0 警告 |
| 改坏两处再跑（去掉"收回"、去掉"启动时恢复"） | `maps` 里对应的 3 条测试失败，说明测试管用 |

**这个环境里本来就不过的 3 条，和这次改动无关：**

- `rapp-service`：`data::tests::a_rebase_that_cannot_start_is_an_error_and_retried`。我动手之前在同一份代码上就不过。
- `rapp-term --test serve`：`open_without_shell_uses_the_default`、`open_runs_the_shell_as_a_login_shell`。在 `main`（`e6d0894`）上复现过。

没有跑的：`cc_compare`（1 条）和 `session_priority`（5 条），它们标了 `ignored`，是手动测量。`rapp-client-gtk` 没有编译（缺 gtk4）。

## 5. 没有验证的

1. **界面的改动和测试一次都没有跑过。** 那个环境装不了 Flutter。Dart 的改动我只对着 diff 读过一遍。
2. macOS 上的 Rust 测试。
3. macOS：别的程序在"所有地址"上监听同一个端口时，rapp 能不能认出来并跳过。代码里的做法是先连一下再监听，只在 Linux 上测过。
4. Windows。
5. 真实的服务（Jupyter、Ollama、Vite、MCP 服务器、sshd）经本机端口用起来怎么样；`Host: localhost:<端口>` 能不能让它们不改配置就用。
6. 浏览器、curl 对 `localhost` 先连 `::1` 还是 `127.0.0.1`。两个都监听了，应该都行，没有实测。

## 6. 没收尾的

代码这边没有。文档这边有一件：

**Project 里的副本只同步了两份。** 这份交接文档（`claude/rapp-port-sharing-local-ports-handoff.md`）和设计文档（`claude/rapp-port-sharing-local-ports-design.md`）已经在 Project 里。下面三份在 Project 里还是这次改动之前的内容，它们在仓库里各只多了一小段说明：

- `claude/rapp-port-sharing-design.md`（主规格，状态行下面多一段）
- `claude/rapp-port-sharing-panel-design.md`（§6.2 开头多一段）
- `claude/rapp-requirements-feedback.md`（多 U151 一行、修订一行）

**这次会话里出过的一个岔子，已经处理：** 我替换 `rust/service/src/ipc.rs` 的 `hosts` 函数时，把 `pipe` 函数上方的一行文档注释一起删掉了。已经补回去，补完后重新跑过 clippy（0 警告）和 `--test maps`（10 条过）。这次改动里 `ipc.rs` 只删掉了一行，就是 `hosts` 里被换掉的那一行。

## 7. 下一步，按顺序

1. 在 Mac 上跑界面：
   ```
   cd /Users/bruce/git/rapp/gui
   flutter analyze
   flutter test test/shares_test.dart test/ui/shares_section_test.dart test/ui/allow_dialog_test.dart
   flutter test
   ```
   最可能出问题的地方：`test/ui/shares_section_test.dart` 里新加的两条（"open works with nothing to switch on first"、"a share with no address on this computer cannot be opened or copied"），以及有没有别处还在用已经删掉的 `rappNames`（我搜过 `gui/lib` 和 `gui/test`，没有）。
2. 在 Mac 上跑 Rust：
   ```
   cd /Users/bruce/git/rapp/rust
   cargo test -p rapp-service maps::
   cargo test -p rapp-testkit --test maps --test share_set --test forward
   cargo test -p rapp-cli
   cargo clippy -p rapp-service -p rapp-cli -p rapp-testkit --all-targets
   ```
3. 真机检查（`tasks/todo.md` 末尾那一节的"未经实机验证"）。
4. **用户已经要求合并（U152），代码在 `main` 上了。合并不等于验证过：** 上面第 1 到 3 步都还没有做，发版之前要做完。
   - 界面或真机出了问题要退回：`git revert -m 1 3e6e43d`。
   - 没有问题：按 §8 改主规格的正文。
5. 把 §6 列的三份 Project 副本补上。
6. 工作树和分支可以收掉了：`git worktree remove .claude/worktrees/port-map`、`git branch -d feat/port-map`。我没有删。

## 8. 这个做法定下来以后还要改的

主规格 `2026-11-15-rapp-port-sharing-design.md` 现在只在状态行下面加了一段说明，正文还是 `.rapp` 域名的写法。定下来以后要改：

- §2 用户看到的：地址、`rapp share` 的输出。
- §4.2 威胁表：T7 的范围变了（本机端口没有 token）；T9 在这条路上没有了；加上"所有 `localhost:<端口>` 共用 cookie"。
- §9 桌面入口：搁置或删除。
- §10 HTTP 适配：`Host` 已经是 `localhost:<端口>`，这一节还要不要、要多少，等真机试过再定。§10.3 的两条检查如果要做，位置从分享方挪到访问方的本机端口上。
- §15 分期：第 4 步（桌面入口）、第 6 步（https）大概不需要了；第 2 步（名字）还有没有用要重新想，名字现在只在 `rapp pipe` 和显示里用。
- §16 没有验证的：第 1 到 7 条在这条路上不存在。

面板增补 `2026-11-15-rapp-port-sharing-panel-design.md` 的 §6.2、§6.3 同样只加了说明，正文没有改。

## 9. 我替用户定的，还没有得到确认

1. 端口范围 28000–28999，取最小的空闲端口。
2. 列出来就监听，不用先点一下；重启后自动恢复。
3. 地址写 `localhost`，不写 `127.0.0.1`。
4. 22 显示 `ssh -p <端口> localhost`，其他一律按网页给地址。
5. `rapp share` 结尾那句话是我写的："在别的设备上用：打开 rapp 的设备面板，或运行 rapp hosts，看那台设备上的地址"。
6. 面板上"没有本机端口可用"这几个字是我写的。
7. 本机自己分享的端口，地址是 `localhost:<原端口>`。
8. 桌面入口搁置而不是删除。
9. 这一轮不做 HTTP 检查，转发失败时不给说明页（浏览器看到的是连接被重置）。

## 10. 已经告诉用户的代价

- 地址不好记，每台访问的设备上端口号不同，不能把地址发给另一台设备用。和最初"容易记住"的要求相反。
- 本机端口上没有 token，这台电脑上的其他用户和程序都能连。
- 浏览器里的恶意网页能向 `localhost:<端口>` 发请求；主规格 §10.3 的检查没有做。
- 所有 `localhost:<端口>` 共用一份 cookie。

## 11. 接手时容易踩的地方

- **不在设备列表里的设备**：用 IPC `shares` 带 `to` 直接问一个不在 `hosts.json` 里的 ID，也会给它建本机端口；但服务重启时这些端口会被收回（启动时只保留列表里的设备）。面板只会问列表里的设备，所以正常用不到，写测试时要注意（`testkit/tests/maps.rs` 里的 `a_and_b` 会先写 `hosts.json`）。
- **设备从列表里删掉后**，它的本机端口要等运行 `rapp hosts` 或服务重启才收回。面板不调用 `hosts`。
- **测试用的端口**：`maps.rs` 里每条测试有自己的一段端口（单元测试 29100–29229，端到端 29300–29379），这样能同时跑。新加测试要另取一段。别的测试文件用默认范围 28000 起，断言里不能写死端口号（用 `without_local()` 或从回复里读）。
- **"不含本机"的字样**：本机自己的分享如果"只给"别的设备，面板上会显示"（不含本机）"，但地址和"打开"是有的（在本机上它本来就连得到）。这是原来就有的写法，这次没有动，看着有点怪。
- **Windows 上"打开"**：`gui/lib/term/term_stage.dart` 的 `openUrl` 只有 macOS 和 Linux 两个分支。原来就这样，这次没有动。
- **rustfmt**：仓库没有 `rustfmt.toml`，代码行宽超过默认值，不要整文件跑 `cargo fmt`。
- **提交的作者**：之前我做的提交都是 `Claude <noreply@anthropic.com>`，因为那个环境里读不到用户的 git 身份，历史里又有两个身份（`lijun2`、`wizlijun`）。用户还没有说要用哪一个。

## 12. 端口分享这条线上别的没做完的事

这些不是这次改动的内容，是我知道的范围内还开着的：

- `feat/port-share-base` 上最初的 22 个提交，作者是 Claude，用户没有回答要不要改成自己的身份。它们后来是怎么并进 `main` 的我没有查。
- 第 0 步的验证（`.rapp` 解析）有一个分支 `probe/port-sharing-0`。结果我没有读。如果本机端口的做法定下来，这一步的结论就不重要了。
- 主规格第 2 步（名字）、第 3 步（服务器 key）、第 5 步（HTTP 适配）、第 7 步（平板的内置浏览器）都没有做。
- "企业使用具体指谁"用户一直没有回答。
- `.superpowers/sdd/port-share/` 和 `.superpowers/_probe_2`（都不进 git）里有我早先传文件留下的临时文件，用户没有说要不要删。
