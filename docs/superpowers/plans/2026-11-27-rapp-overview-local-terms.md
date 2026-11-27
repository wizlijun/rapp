# 总览本机列：终端卡片 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PC 总览本机列加一张「终端」卡片：列出本机的 rapp 终端，点一行把它的「终端」窗口切到前面，「新建」在「终端」app 里开一个能被其他设备同时打开的终端；有 rapp 终端时本机列自己展开。

**Architecture:** `rapp-term serve` 加 `front {term}` 请求，按 holder 的 tty 用 AppleScript 把「终端」的标签页切到前面。本机服务的控制通道加 `term_watch` / `term_open` / `term_front` 三条命令，转给 serve。GUI 的 `ServiceMonitor` 多开一条连接跟着 `term_watch`；`MainState` 放「新建」和「切到前面」两个动作；新组件 `LocalTerms` 放进本机列最上面；折叠规则多一个输入。

**Tech Stack:** Rust（rust/term、rust/service、rust/testkit），Flutter/Dart（gui/）。

**Spec:** `docs/superpowers/specs/2026-11-27-rapp-overview-local-terms-design.md`

## Global Constraints

- 不改设备之间的协议（`Op` 不加变体），只改本机 IPC 和 serve 的本地请求。
- 只列本机 serve 列出的、`host == null` 的 pty 终端；不接管不是 rapp 开的终端。
- 卡片只在有 `ServiceMonitor` 而且 `localTerms != null` 时出现；iOS 上 monitor 为 null，不出现。
- 灯不显示未读：`dead` → `Lamp.disconnected`；`ps.state` 为 `blocked` → `Lamp.waiting`，`working` → `Lamp.active`，`error` / `done` / `idle` → `Lamp.idle`；没有 `ps` → `Lamp.active`。
- 文案（逐字）：标题「终端」，按钮「新建」，空列表一行「用 rapp 开的终端，其他设备也能打开」，行尾「N 个在看」（`attached > 0`），找不到窗口 hint「没找到这个终端的窗口」，等待卡片「正在新建终端…」。
- 本机授权文案（逐字）：`macOS 弹出了授权框「“rApp”想要控制“终端”」：点「允许」（可能连着两个），点完再试一次`。
- 名字折行，不裁掉。
- 卡片用现有的 `SessionCard`（`gui/lib/ui/session_block.dart`），不另画一套。
- 不改版本号、不 push、不打 tag。flutter 在 `~/development/flutter/bin/flutter`，跑完要还原 `gui/pubspec.lock`。cargo 需要 `export PATH=$HOME/.cargo/bin:$PATH`。用 `/usr/bin/grep`。
- 新 worktree 跑完整 flutter 测试之前要先 `cd rust && cargo build --release -p rapp-client-core --bin rapp-session`。

## Review Focus

1. 连点两次「新建」：只开一个终端。等待卡片还在时，「新建」不能点（Task 4 测试）。
2. 文本终端关了又开：watch 回一行错误后卡片消失，折叠规则退回只看接入；重新打开后收到 `changed` 就重开 watch，卡片回来（Task 3 测试）。
3. 旧服务回答 `term_watch` 为 `unknown cmd`：卡片不出现，收到 `changed` 也不再问，直到重连（Task 3 测试）。
4. 列表里有 `host != null` 的行（经本机 ssh 开的远程终端）：不出现在卡片里（Task 5 测试）。
5. 「切到前面」时 macOS 正在等授权：立即给本机授权文案，不显示「没找到」（Task 4 测试）。

---

### Task 1: serve 的 `front` 请求

**Files:**
- Modify: `rust/term/src/serve.rs`（`Req` 枚举 :83；`handle` 的分派 :283 起；`#[cfg(test)] mod tests` :1161）
- Modify: `rust/term/src/pty/launch.rs`（`TERMINAL_TAB` 旁边加 `TERMINAL_FRONT` 和 `front`）
- Test: `rust/term/tests/serve.rs`；`rust/term/src/serve.rs` 内的 `req_parses_*` 单元测试

**Interfaces:**
- Produces: serve 请求 `{"op":"front","term":"term:pty:<name>"}`，回答只有三种：`{"ok":true}`、`{"error":"not-found"}`、`{"error":"consent"}`，Linux 上是 `{"error":"unsupported"}`。term.json 不可用时和别的请求一样，回答 `{"error":<cfg error>}`。
- Produces: `pub fn front(tty: &str, launch_with: Option<&Path>) -> Result<(), FrontRefused>`，其中 `pub enum FrontRefused { NotFound, Consent, Unsupported }`，`as_str()` 分别是 `"not-found"` / `"consent"` / `"unsupported"`。

- [ ] **Step 1: 写失败的测试**

`serve.rs` 单元测试：

```rust
#[test]
fn req_parses_front() {
    let r: Req = serde_json::from_str(r#"{"op":"front","term":"term:pty:ab"}"#).unwrap();
    assert!(matches!(r, Req::Front { ref term } if term == "term:pty:ab"), "{r:?}");
}
```

`tests/serve.rs`：加一个测试 launcher，`--front <tty>` 时把 tty 写进 `front.txt`，再按文件 `front-fail` 是否存在决定退出码 1 还是 0。然后写三个测试：

- `front_raises_the_holders_tty`
  - 用 `Window::start(&w.pty_dir(), &["--name","t","--","/bin/cat"])` 起一个 holder，`id_of` 取 id；
  - `ask({"op":"front","term":id})` == `[{"ok":true}]`；
  - `front.txt` 的内容 == `pty::wait_status(&dir,"t").await.tty.unwrap()`。
- `front_of_an_unknown_term_is_not_found`
  - `term:pty:nope`、一个不是 pty 的 id、一个带 host 的 id，三种都回答 `[{"error":"not-found"}]`；
  - 三种都不运行 launcher（`front.txt` 不存在）。
- `front_that_finds_no_tab_is_not_found`
  - 有 `front-fail` 文件时回答 `[{"error":"not-found"}]`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-term front`
Expected: 编译失败（没有 `Req::Front`），或者这几个测试 FAIL。

- [ ] **Step 3: 实现**

- `Req::Front { term: String }`。
- 分派：按 `cfg` 先判错。用 `TermId::parse` 解析，只认 `backend == PTY && host.is_none()`。用 `self.pty_statuses().await` 里 `is_session(s,&id.name)` 的那条取 `tty`，空的算没有。没有 → `not-found`。有就 `spawn_blocking(move || launch::front(&tty, with))`。
- `launch::front` 的规则：
  - 有 `launch_with`：跑 `<launch_with> --front <tty>`，用 `bounded_command` 限 10 s。成功 → `Ok`，其他 → `NotFound`。
  - 没有 `launch_with`：
    - Linux → `Unsupported`；
    - macOS 先看 `super::consent::asking()`，为真 → `Consent`；
    - 否则 `osascript -e TERMINAL_FRONT <tty>`，用 `bounded_command` 限 10 s，输出 trim 后是 `front` → `Ok`，其他 → `NotFound`。
- `TERMINAL_FRONT`：Terminal 没在运行就回答 `none`。遍历 `windows` / `tabs`，找 `tty of t is <tty>`；找到后取消最小化，`set selected of t to true`，`set index of w to 1`，`activate`，回答 `front`。找不到回答 `none`。写法照 `TERMINAL_TAB` 里按 tty 找的那段。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-term front && cargo test -p rapp-term --test serve`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add rust/term && git commit -m "feat(term): serve front — raise a holder's Terminal tab by its tty"
```

### Task 2: 本机服务的 `term_watch` / `term_open` / `term_front`

**Files:**
- Modify: `rust/service/src/ipc.rs`（命令分派，`term_saved` 旁 :115；跟随循环 `if watching` :142）
- Modify: `rust/service/src/term.rs`（加 `pub(crate) async fn follow_local<S>(state, s) -> Result<()>`，复用 `watch_local`）
- Modify: `rust/testkit/src/bin/fake-rapp-term.rs`（加 `front` 请求）
- Test: `rust/testkit/tests/term.rs`

**Interfaces:**
- Consumes: Task 1 的 serve `front` 请求和它的回答。
- Produces: 本机 IPC 命令：
  - `{"cmd":"term_open","app":S,"shell"?:S,"from"?:S}` → `{"ok":true,"id":S}` 或 `{"ok":false,"error":S}`，等待 `ASK_WAIT`（30 s）；
  - `{"cmd":"term_front","term":S}` → `{"ok":true}` 或 `{"ok":false,"error":"not-found"|"consent"|"unsupported"|…}`；
  - `{"cmd":"term_watch"}` → 占住这条连接。每次列表变化写一行 `{"ok":true,"terms":[…],"hosts":[…]}`。终端关闭或 serve 出错时写一行 `{"ok":false,"error":S}`，然后关闭连接。

- [ ] **Step 1: 写失败的测试**

先给 fake-rapp-term 加 `front`：记日志 `front {req}`，term 为 `term:pty:gone` 时回答 `{"error":"not-found"}`，其他回答 `{"ok":true}`。在 `tests/term.rs` 里写：

- `local_term_open_reaches_the_worker`：`ipc_once(... {"cmd":"term_open","app":"Terminal","from":"last"})`，回答的 `ok` 为 true，`id` 为 `"term:pty:opened"`。`term_requests(bins,"open")` 只有一条，`from` 为 `"last"`，`app` 为 `"Terminal"`。
- `local_term_front_reaches_the_worker`：`term:pty:a` → `ok` 为 true；`term:pty:gone` → `{"ok":false,"error":"not-found"}`。`service.log` 里没有 `term:pty:a`。
- `local_term_watch_pushes_changes_then_ends_when_off`：
  - `Ipc::open` 以后发 `{"cmd":"term_watch"}`，第一行 `ok` 为 true，并且带 `terms`；
  - `add_row(home,"x")` 以后的一行里有 `term:pty:x`；
  - 把 term.json 写成 `{"allow":false}` 以后，有一行 `ok` 为 false，然后 `next()` 是 `Null`。
- `local_term_commands_with_terminals_off_are_refused`：terminals 关闭时，`term_open` / `term_front` 都回答 `ok` 为 false，error 是 `terminal sessions are off`，而且不启动 worker（照 `with_terminals_off_nothing_starts` 的判断）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd rust && cargo test -p rapp-testkit --test term local_term`
Expected: FAIL（`unknown cmd`）

- [ ] **Step 3: 实现**

- `term_open` / `term_front` 用现有的 `crate::term::local(state, &json!({"op":"open",…}), ASK_WAIT)` 和 `{"op":"front","term":…}`（等待 15 s）。`shell` / `from` 缺省就不带上。
- `term_watch` 照 `watch_load` 的做法设一个标志，然后 `continue`。循环结束后调 `crate::term::follow_local`：
  - 用 `watch_local` 拿到列表，每一行加上 `"ok":true` 写出去；
  - `Err` 时写 `err(...)` 一行再返回；客户端断开也返回。
- 本机命令不写 `request` 日志，和 `term_saved` / `term_restore` 一样（见 Rulings）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd rust && cargo test -p rapp-testkit --test term && cargo test -p rapp-service`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add rust/service rust/testkit && git commit -m "feat(service): local term_watch / term_open / term_front"
```

### Task 3: `ServiceMonitor.localTerms`、`termOpen`、`termFront`

**Files:**
- Modify: `gui/lib/hub_client.dart`（把 `_termList` 公开成 `TermList termListFromJson(Map<String, dynamic> m, String id)`，原来的调用改用它）
- Modify: `gui/lib/service_client.dart`（`ServiceMonitor`，照 `_watchLoad` :388 的做法）
- Test: `gui/test/service_client_test.dart`（假服务加 `termLines`，照 `loadLines` 的做法）

**Interfaces:**
- Consumes: Task 2 的三条 IPC 命令。
- Produces:
  - `TermList? ServiceMonitor.localTerms`：null 表示没有或不可用，id 固定为 `'local'`；
  - `Future<String> termOpen({String? shell, required String app, String? from})`：返回新终端 id，失败抛 `ServiceException`；
  - `Future<void> termFront(String term)`：失败抛 `ServiceException(error)`；
  - `static const termFrontNotFound = 'not-found'`、`termFrontConsent = 'consent'`。

- [ ] **Step 1: 写失败的测试**（在 `group('ServiceMonitor')` 里）

- `term_watch fills localTerms from its own connection and follows each line`：两行 termLines，第二行多一个 `term:pty:b`。`localTerms!.terms.map((r)=>r.id)` 先是 `['term:pty:a']`，再变成 `['term:pty:a','term:pty:b']`。收到的 `term_watch` 命令是 `{'cmd':'term_watch'}`。
- `a term_watch that ends with an error clears localTerms and is opened again on changed`：
  - 第一次连接回一行列表，再回 `{"ok":false,"error":"terminal sessions are off"}` 并关闭 → `localTerms == null`；
  - 推一个 `{"event":"changed"}` 以后，`term_watch` 被再问一次，列表回来；
  - 5 秒内的第二个 `changed` 不再问（用 `fakeAsync`，或者给 monitor 一个可注入的 `rewatchGap`，测试里设成 `Duration.zero` 和 1 h 各验一次）。
- `an old service's unknown cmd is not asked again until reconnect`：`term_watch` 回 `unknown cmd` → `localTerms == null`；推 `changed` 以后，`term_watch` 收到的次数还是 1。
- `termOpen and termFront send the right json`：
  - `termOpen(app:'Terminal', from:'last')` 发出 `{'cmd':'term_open','app':'Terminal','from':'last'}`，返回 `'term:pty:n'`；
  - `termFront('term:pty:a')` 发出 `{'cmd':'term_front','term':'term:pty:a'}`；
  - 回答为 `{'ok':false,'error':'not-found'}` 时抛 `ServiceException`，`message == 'not-found'`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/service_client_test.dart`
Expected: FAIL（没有 `localTerms`）

- [ ] **Step 3: 实现**

- 在 `_watchLoad` 旁边加 `_watchTerms(token)`，和它一起开。
- 状态机只有三种：
  - `watching`；
  - `ended`：收到错误或连接断开。在 `refresh()` 收到的 `changed` 里重开，距上次开至少 `rewatchGap`（默认 5 s）；
  - `old`：收到 `unknown cmd`。等 monitor 重连（`_gen` 变）才清掉。
- `localTerms` 变化时 `notifyListeners`。`termOpen` / `termFront` 走 `_remoteRequest`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/service_client_test.dart test/hub_client_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui && git commit -m "feat(gui): ServiceMonitor follows this machine's terminals"
```

### Task 4: `MainState` 的动作和折叠规则

**Files:**
- Modify: `gui/lib/ui/main_state.dart`：
  - `localColumnOpen` :1181；
  - 在 `openText` :3807 旁边加本机动作；
  - 在 `newTermWords` :3792 旁边加 `localTermWords`；
  - `consentError` :3760 也认本机。
- Modify: `gui/lib/ui/overview.dart`（`_LocalFold` :301 把 `terms:` 传进去）
- Test: `gui/test/ui/local_terms_state_test.dart`（新文件，用 `fakes.dart` 的 MainState 构造方式，`monitor` 用一个可以设 `localTerms`、记下 `termOpen` / `termFront` 调用的假 monitor）

**Interfaces:**
- Consumes: Task 3 的 `localTerms`、`termOpen`、`termFront`。
- Produces:
  - `bool localColumnOpen({required bool inbound, bool terms = false})`，等于 `localColumnPick ?? (inbound || terms)`；
  - `Future<void> newLocalTerm()`；
  - `Future<void> frontLocalTerm(String term)`；
  - `bool get newLocalTermBusy`（等待中为真）；
  - `static String localTermWords(Object e)`；
  - `static List<TermRow> localTermRows(TermList? l)`：只留 `host == null`；
  - `static Lamp localTermLamp(TermRow r)`：规则见 Global Constraints。

- [ ] **Step 1: 写失败的测试**

- `the local column opens for a running rapp terminal`：`localColumnOpen(inbound:false, terms:true)` 为 true；手动 `openLocalColumn(false)` 以后为 false。
- `newLocalTerm opens in the Terminal app with from last and opens no in-app view`：
  - 假 monitor 的 `localTerms` 带 hosts `[{host:null, launchers:['Terminal','iTerm']}]`；
  - 调用以后，`termOpen` 收到 `app:'Terminal', from:'last'`；
  - `state.current` 不变，没有新会话。
- `a second 新建 while the first waits opens nothing more`：`termOpen` 用一个 Completer 卡住，连调两次，`termOpen` 只被调一次，等待中 `newLocalTermBusy` 为 true。
- `frontLocalTerm that finds no window says so`：`termFront` 抛 `ServiceException('not-found')`，hint 为「没找到这个终端的窗口」。
- `macOS asking shows the local consent words`：
  - `termFront` 抛 `ServiceException('consent')` → hint 为本机授权文案（逐字见 Global Constraints）；
  - `termOpen` 抛带 `whether rApp may control Terminal` 的 `ServiceException` → 同一句。
- `localTermLamp ignores unread`：`unread:true`、没有 ps → `Lamp.active`；`ps.state=='blocked'` → `Lamp.waiting`；`dead` → `Lamp.disconnected`。
- `localTermRows drops rows from other hosts`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/local_terms_state_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**

- `newLocalTerm`：
  - 已经在等就直接返回；
  - launchers 取 `localTerms` 里 `host == null` 那条 `HostRow` 的 `launchers`，为空就 `say('这台设备没有可用的终端窗口')`；
  - `app = prefs.termAppFor('local', launchers)`；
  - 用 `waits.run('正在新建终端…', …, detail: '本机', words: localTermWords, asks: consentError)` 包住 `monitor!.termOpen(app: app, from: 'last')`；
  - 失败的提示交给 waits。
- `frontLocalTerm`：`monitor!.termFront(term)`，失败时 `say(localTermWords(e))`。
- `localTermWords`：
  - `ServiceException` 的 message 是 `not-found` → 找不到的文案；
  - `consent`，或者 `isConsentAsk(message)` 为真 → 本机授权文案；
  - 其他就是 message 本身；
  - 不是 `ServiceException` 的交给 `newTermWords`。
- `consentError` 改成：`HubException` 或者 `ServiceException`，并且 `isConsentAsk(message)`，或者 message 是 `consent`。
- `_LocalFold` 传 `terms: localTermRows(monitor?.localTerms).isNotEmpty`。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/local_terms_state_test.dart test/ui/overview_test.dart test/ui/wait_card_test.dart test/ui/new_term_from_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui && git commit -m "feat(gui): local terminal actions and the fold rule's new input"
```

### Task 5: `LocalTerms` 卡片放进本机列

**Files:**
- Create: `gui/lib/ui/local_terms.dart`
- Modify: `gui/lib/ui/overview.dart`（`_Column` :426 那个 `Column` 的最前面，只在 `id == null && monitor?.localTerms != null` 时）
- Modify: `tasks/todo.md`（新加一节「总览本机列：终端卡片（feat/overview-local-terms）」，写实机检查 ①–⑧）
- Test: `gui/test/ui/local_terms_test.dart`；`gui/test/ui/overview_test.dart`（`_Mon` 加 `localTerms`）

**Interfaces:**
- Consumes: Task 4 的 `localTermRows`、`localTermLamp`、`newLocalTerm`、`frontLocalTerm`、`newLocalTermBusy`、`localColumnOpen(terms:)`。
- Produces: `class LocalTerms extends StatelessWidget`，构造参数 `{required List<TermRow> rows, required VoidCallback? onNew, required void Function(String term)? onFront}`。`onFront` 为 null（Linux）时，行不可点。key 为 `local-terms`、`local-terms-new`、`local-term-<id>`。

- [ ] **Step 1: 写失败的测试**

`local_terms_test.dart`：

- `lists each terminal with its name and who is watching`：两行，`attached: 0` 和 `2`，能找到 `termDisplayName` 的名字和「2 个在看」，只有一个「个在看」。
- `an empty list says why to open here`：能找到「用 rapp 开的终端，其他设备也能打开」和「新建」。
- `tapping a row fronts it; tapping 新建 opens one`：回调分别收到 id、被调一次。
- `with no onFront the rows are not buttons`：点行，没有回调被调。
- `a long name wraps`：120px 宽、很长的名字，`tester.takeException()` 为 null，`Text` 的 `softWrap` 为真，没有 `TextOverflow.ellipsis`。
- `新建 is disabled while it waits`：`onNew: null` 时按钮不可点。

`overview_test.dart`：

- `the local column opens itself while a rapp terminal runs`：`_Mon.localTerms` 有一行 → 本机列展开，能找到 `local-terms`；清空以后折回 `column-local-folded`。
- `rows from other hosts are not shown and do not open the column`：只有 `host: 'srv'` 的行 → 本机列还是折着。
- `no card without terminal support`：`localTerms == null` → 展开后找不到 `local-terms`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd gui && ~/development/flutter/bin/flutter test test/ui/local_terms_test.dart test/ui/overview_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**

- 标题行：左边「终端」（和「连上的服务」的小标题同样式），右边「新建」（`RappButton.secondary`，紧凑）。
- 下面每行一个 `SessionCard`：
  - `frameKey: Key('local-term-<id>')`；
  - `lamp` 用 `localTermLamp`；
  - `title` 用 `termDisplayName(r.shown, r.host)`；
  - `second` 是程序状态的字（`programWord(ps)`，没有就是「在运行」）；
  - `trailing` 是「N 个在看」；
  - `onTap` 是 `onFront`。
- 标题要能折行：如果 `SessionCard` 的 title 是单行，就给它加一个 `titleWrap` 参数（默认不变），而不是另写一个卡片。
- Overview 传入：
  - `onNew`：`state.newLocalTermBusy` 时为 null；
  - `onFront`：`defaultTargetPlatform == TargetPlatform.macOS` 时是 `state.frontLocalTerm`，否则为 null。
- `tasks/todo.md` 实机检查：
  - ① 新建开在「终端」app；
  - ② 新终端出现在卡片里；
  - ③ 别的设备能同时打开它，行尾显示「1 个在看」；
  - ④ 点一行切到对应的标签页（包括最小化的窗口）；
  - ⑤ 第一次授权的提示；
  - ⑥ 关掉再打开文本终端以后卡片回来；
  - ⑦ 有终端时本机列自己展开，全部退出后折回；
  - ⑧ Linux 上行不可点，新建可用。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`
Expected: analyze 没有问题；全部 PASS

- [ ] **Step 5: 提交**

```bash
git checkout gui/pubspec.lock 2>/dev/null; git add gui tasks/todo.md && git commit -m "feat(overview): 本机列「终端」卡片"
```

### 收尾：全量门禁

- [ ] Run: `cd rust && cargo test --workspace --no-fail-fast && cargo clippy --workspace --all-targets -- -D warnings`
  Expected: PASS
- [ ] Run: `cd gui && ~/development/flutter/bin/flutter analyze && ~/development/flutter/bin/flutter test`
  Expected: PASS；跑完还原 `gui/pubspec.lock`。

## Rulings（写计划时定的）

- 本机授权文案用「点「允许」（可能连着两个），点完再试一次」，不用规格里的「点「好」以后再新建一次」：远程那句已经在真机上验过，按钮叫「允许」；而且这句话也给「切到前面」用，所以不说「新建」。
- watch 的每一行加 `"ok":true`，和 `watch_load` 一样，GUI 用同一套判断。
- 本机 IPC 的终端命令不写 `request` 日志，和现有的 `term_saved` / `term_restore` 一致：日志里本来就不该有 term id 和名字，本机命令也没有对端可记。
- 本机终端 app 的偏好键用 `'local'`：现在没有设置本机终端 app 的界面，实际取到的就是 launchers 的第一个（macOS 上是「终端」）。
