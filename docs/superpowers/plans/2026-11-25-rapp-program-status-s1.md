# 程序状态 S1（OSC 7501：在干活、在等你）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `rapp-term run` 回答 CLI 的 OSC 7501 探测、读出状态报告，随会话列表送到主控台：灯和一行字显示在干活、等确认、在提问、出错；`blocked` 的会话进“需要你”。

**Architecture:** 新文件 `rust/term/src/pty/ps.rs` 放三样纯逻辑（`Scanner` 扫字节流、`parse` 解析一条报告、`Records` 记录表），外加把它们串起来的 `Tracker`，它产出可序列化的快照 `Ps`。`pump_output` 在把输出写给窗口**之前**喂 `Tracker`：有探测就把固定回答送进 `shared.input`，快照变了就写进 `shared.ps`。`Status` 和 `TermRow` 各带一个可选的 `ps`，服务据此改未读规则，hub 原样转，主控台解析后改灯、改字、加一类“需要你”。

**Tech Stack:** Rust（`rapp-term` crate，新依赖 `base64 = "0.22"`），Flutter（`gui/`，flutter_test）。

**Spec:** `docs/superpowers/specs/2026-11-25-rapp-program-status-design.md`（下称“规格”）。本计划只做规格 §8 的 S1a、S1b、S1c。S2（事件）、S3（人点一下）、S4（自动回应）各自另写计划。P0 探查（规格 §9）是实机检查，不在这里写代码。

## Global Constraints

- 不改 CLI、不读 CLI 的文件、不装 hook、不改 CLI 的环境变量和配置（规格 PS2、§7.2 第 6 条）。
- rapp 往程序里写的只有一条固定的探测回答：`ESC ] 7501 ; ? ESC \`，即字节 `b"\x1b]7501;?\x1b\\"`（规格 §5.3）。报告里的内容从不回写。
- 限制常量照规范修订 0.4：整条序列 4096 字节；键 16；app 32；id 128（每段 32、最多 8 段）；msg 编码后 2732、解码后 2048；title 编码后 256、解码后 192；记录最多 256 条（规格 §2.1、§5.2）。
- 一块输出里最多答 64 次探测（规格 §5.3）。
- 列表里的 `msg` 最多 200 个字符（按 `char` 数，不按字节），超出截断并加 `…`（规格 §5.5）。
- `term.json` 加 `programStatus`，默认 `true`；为 `false` 时不答、不解析，伪终端两个方向的字节和现在逐字节相同（规格 §5.9、§11）。
- `msg` 和屏幕文字一样**不进日志**（规格 §5.10）。
- `LOCAL_V` 不加一；`Status.ps` 用 `#[serde(default, skip_serializing_if = "Option::is_none")]`（规格 §5.5）。
- 移植的代码在文件头写明出处和版权：gascity `Copyright (c) 2026 Gas City Contributors`（MIT，提交 `0997336456fe67f0315d9e41dabc7167e74c2fa9`），zellij `Copyright (c) 2020 Zellij contributors`（MIT，提交 `d73e7d5bf0ae58a13cee11ede9bab0fa141de7b6`）（规格 §2）。
- 不提交到 `main`。在 worktree 的分支 `feat/program-status-s1` 上做，做完把分支名交给 rapp-49 合并。
- Rust 改完跑 `cargo test --workspace --no-fail-fast`，不要只跑 `rapp-term`（testkit 里有断言会话行的测试）。Flutter 在 `~/development/flutter/bin/flutter`，不在 PATH 上；跑完测试把 `gui/pubspec.lock` 还原。

## Review Focus

1. **报告在任意字节处被切开**，包括正好切在 `ESC` 和 `\` 之间、切在 base64 中间：结果必须和整块喂一样。Task 1 加“逐字节喂”的测试。
2. **中文或 emoji 的 `msg` 超过 200 个字符**：截断后仍是合法 UTF-8，正好 200 个字符加 `…`。Task 3 加测试。
3. **一个程序一次吐出成百上千个探测**：最多答 64 次，不卡住输出。Task 4 加测试。
4. **主控台收到不认识的 `state`**（以后的规范版本，或者坏数据）：按没有 `ps` 处理，不崩，灯和字用现在的规则。Task 6 加测试。
5. **程序已经退出（`dead`）但最后的状态是 `blocked`**：不进“需要你”。Task 7 加测试。

---

## File Structure

| 文件 | 职责 |
|---|---|
| `rust/term/testdata/ps/*.bin`、`*.reads`、`README.md`（新） | gascity 的五份录制和它们的切分长度，注明出处 |
| `rust/term/src/pty/ps.rs`（新） | `Scanner`、`parse`、`Records`、`Tracker`、`Ps`，不碰仿真器 |
| `rust/term/src/pty/mod.rs` | `pub mod ps;`；`Shared.ps`；`status()` 带上 `ps` |
| `rust/term/src/pty/local.rs` | `Status.ps` |
| `rust/term/src/pty/holder.rs` | `pump_output` 喂 `Tracker`、答探测；`RunOpts.program_status` |
| `rust/term/src/config.rs` | `TermConfig.program_status`；`beside()` |
| `rust/term/src/main.rs` | 读 `term.json` 填 `RunOpts.program_status` |
| `rust/term/src/unread.rs` | `is_unread_ps` |
| `rust/term/src/list.rs`、`serve.rs` | `TermRow.ps`；`pty_rows` 用新规则 |
| `gui/lib/hub_client.dart` | `TermPs`；`TermRow.ps` |
| `gui/lib/ui/term_status.dart`（新） | 从 `devices_tab.dart` 挪来的 `termStatus`、`termLamp`，加上 `ps` 的字 |
| `gui/lib/ui/main_state.dart`、`needs_you.dart` | `NeedKind.terminal` 和它的“打开”按钮 |

---

### Task 1: 录制文件和 `Scanner`

**Files:**
- Create: `rust/term/testdata/ps/`（五份 `.bin` + `.reads`，`README.md`）
- Create: `rust/term/src/pty/ps.rs`
- Modify: `rust/term/src/pty/mod.rs:1-6`（加 `pub mod ps;`）

**Interfaces:**
- Produces:
  ```rust
  pub enum Event { Probe, Report(String), Prompt }   // Report 带的是 "ESC ] 7501 ;" 和结尾之间的正文
  #[derive(Default)] pub struct Scanner { .. }
  impl Scanner { pub fn feed(&mut self, bytes: &[u8], emit: impl FnMut(Event)); }
  pub const MAX_SEQUENCE: usize = 4096;
  ```
  测试辅助（`#[cfg(test)]`，Task 2 也用）：`fn capture(name: &str) -> (Vec<u8>, Vec<usize>)` 读 `testdata/ps/<name>.bin` 和 `.reads`（每行一个十进制长度，空白分隔），断言长度之和等于数据长度；`fn chunks(name) -> Vec<Vec<u8>>`。

- [ ] **Step 1: 拷录制文件**

```bash
R=$(mktemp -d) && cd "$R" && git init -q && git remote add origin https://github.com/gastownhall/gascity.git \
  && git fetch -q --depth 1 origin 0997336456fe67f0315d9e41dabc7167e74c2fa9 && git checkout -q FETCH_HEAD \
  && mkdir -p <worktree>/rust/term/testdata/ps \
  && cp internal/runtime/programstatus/testdata/{claude-turns,claude-children,claude-error,codex-turns,synthetic-split}.{bin,reads} <worktree>/rust/term/testdata/ps/
```

`README.md` 写：来自 gascity `internal/runtime/programstatus/testdata/`，提交号，MIT，版权行；`.reads` 是录制时每次读到的字节数。仓库根目录如有 `.gitattributes` 规则，确认 `*.bin` 按二进制处理（必要时在 `rust/term/testdata/ps/.gitattributes` 写 `*.bin binary`）。

- [ ] **Step 2: 写失败的测试**（`ps.rs` 的 `mod tests`）

```rust
fn events(chunks: &[&[u8]]) -> Vec<String> // 把事件写成 "probe" / "prompt" / "report:<正文>"

#[test] fn probe_with_bel_or_st() {
    assert_eq!(events(&[b"\x1b]7501;?\x07"]), ["probe"]);
    assert_eq!(events(&[b"\x1b]7501;?\x1b\\"]), ["probe"]);
}
#[test] fn report_body_and_prompt() {
    assert_eq!(events(&[b"a\x1b]7501;state=working\x07b\x1b]133;A\x07"]), ["report:state=working", "prompt"]);
    assert_eq!(events(&[b"\x1b]133;A;k=v\x1b\\"]), ["prompt"]);
}
#[test] fn every_split_gives_the_same_events() {
    let whole = b"x\x1b]7501;state=blocked:kind=question:msg=QWxsb3c=\x1b\\y\x1b]7501;?\x07";
    let want = events(&[whole]);
    for i in 0..=whole.len() { assert_eq!(events(&[&whole[..i], &whole[i..]]), want, "split at {i}"); }
    let bytes: Vec<&[u8]> = whole.chunks(1).collect();
    assert_eq!(events(&bytes), want);
}
#[test] fn esc_can_sub_abandon_a_sequence() {
    assert_eq!(events(&[b"\x1b]7501;state=working\x1b[0m\x1b]7501;?\x07"]), ["probe"]);
    assert_eq!(events(&[b"\x1b]7501;state=working\x18\x1b]7501;?\x07"]), ["probe"]);
    assert_eq!(events(&[b"\x1b]7501;state=working\x1a"]), Vec::<String>::new());
}
#[test] fn dcs_is_skipped_whole() {   // 不拆 tmux 包裹（规格 §5.2）
    assert_eq!(events(&[b"\x1bPtmux;\x1b\x1b]7501;?\x07\x1b\\\x1b]7501;?\x07"]), ["probe"]);
}
#[test] fn other_osc_is_ignored() { assert!(events(&[b"\x1b]0;title\x07\x1b]75010;x\x07\x1b]1337;?\x07"]).is_empty()); }
#[test] fn over_4096_bytes_is_dropped() {
    // 序列总长（含 ESC ] 和结尾）= 4096 留下，4097 丢掉
    let ok = format!("\x1b]7501;state=idle:x={}\x07", "a".repeat(4096 - 21));
    assert_eq!(ok.len(), 4096);
    assert_eq!(events(&[ok.as_bytes()]).len(), 1);
    let long = format!("\x1b]7501;state=idle:x={}\x07", "a".repeat(4096 - 20));
    assert!(events(&[long.as_bytes()]).is_empty());
    assert_eq!(events(&[long.as_bytes(), b"\x1b]7501;?\x07"]), ["probe"]); // 丢掉之后接着认
}
#[test] fn recordings_split_as_recorded_match_whole() {
    for name in ["claude-turns", "claude-children", "claude-error", "codex-turns", "synthetic-split"] {
        let (data, _) = capture(name);
        let split = chunks(name);
        let split: Vec<&[u8]> = split.iter().map(|c| c.as_slice()).collect();
        assert_eq!(events(&split), events(&[&data]), "{name}");
    }
}
#[test] fn recordings_probe_counts() {
    let probes = |n| events(&[&capture(n).0]).iter().filter(|e| *e == "probe").count();
    assert_eq!((probes("claude-turns"), probes("claude-error"), probes("codex-turns")), (1, 1, 0));
}
```

`over_4096_bytes_is_dropped` 里的长度按“`ESC ]` 2 字节 + 正文 + 结尾”算：先在测试里用 `assert_eq!(ok.len(), 4096)` 钉住，写错了会在第一次跑时暴露，按实际长度改填充数，不改上限。

- [ ] **Step 3: 跑测试，确认失败**

Run: `cargo test -p rapp-term ps::` — Expected: 编译失败（`Scanner` 不存在）。

- [ ] **Step 4: 实现 `Scanner`**

照 `gascity scanner.go:46-221` 的状态机移植，去掉 tmux 拆包那一层：`ESC P` 进入 DCS 后一直跳到 `ESC \`。状态：Ground、Esc、Osc、OscEsc、Dcs、DcsEsc；OSC 种类：Pending、Is7501、Prompt、Skip。缓冲只在 Is7501 时积累，超过 `MAX_SEQUENCE - 2 - 1` 字节就转 Skip；收尾时再按 `2 + 缓冲 + 结尾长度 > MAX_SEQUENCE` 判一次。正文是 `"?"` 发 `Probe`。文件头写 gascity 的出处和版权行（Global Constraints）。

- [ ] **Step 5: 跑测试，确认通过**

Run: `cargo test -p rapp-term ps::` — Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add rust/term/testdata/ps rust/term/src/pty/ps.rs rust/term/src/pty/mod.rs
git commit -m "feat(term): OSC 7501 scanner with gascity's recordings"
```

---

### Task 2: `parse` 和 `Records`

**Files:**
- Modify: `rust/term/src/pty/ps.rs`
- Modify: `rust/term/Cargo.toml`（`base64 = "0.22"`，锁文件里已有 0.22.1）

**Interfaces:**
- Consumes: Task 1 的 `Scanner`、`Event`、`capture`、`chunks`。
- Produces:
  ```rust
  #[derive(Clone, Copy, Debug, PartialEq, Eq)] pub enum State { Idle, Working, Done, Blocked, Error }
  impl State { pub fn as_str(self) -> &'static str; pub fn is_transient(self) -> bool /* Idle|Working|Blocked */; }
  #[derive(Clone, Debug, PartialEq)] pub struct Record {
      pub id: Option<String>, pub state: State, pub kind: Option<String> /* permission|question|auth，只在 Blocked */,
      pub app: Option<String>, pub title: Option<String>, pub msg: Option<String>, pub progress: Option<u8>,
  }
  #[derive(Clone, Debug, PartialEq)] pub enum Message { Set(Record), Clear { id: Option<String> } }
  pub fn parse(body: &str) -> Option<Message>;
  #[derive(Default)] pub struct Records { .. }
  impl Records {
      pub fn apply(&mut self, m: Message) -> bool;     // 变了返回 true
      pub fn drop_transient(&mut self) -> bool;
      pub fn deciding(&self) -> Option<Record>;        // app 为空时从父记录继承
      pub fn children(&self) -> usize;                 // id 不为空的记录数
  }
  ```

- [ ] **Step 1: 写失败的测试**

`parse` 的用例照 `zellij program_status.rs:359` 之后的单元测试和 `gascity parse_test.go` 改写，至少包括：

```rust
#[test] fn parse_basic() {
    let Some(Message::Set(r)) = parse("state=blocked:kind=permission:app=claude-code:msg=aGk=") else { panic!() };
    assert_eq!((r.state, r.kind.as_deref(), r.app.as_deref(), r.msg.as_deref()), (State::Blocked, Some("permission"), Some("claude-code"), Some("hi")));
    assert_eq!(parse("state=clear"), Some(Message::Clear { id: None }));
    assert_eq!(parse("state=clear:id=a/b"), Some(Message::Clear { id: Some("a/b".into()) }));
}
#[test] fn parse_tolerates() {
    // 不认识的键忽略；键重复取最后一个；缺 '=' 的对跳过；msg 不带填充也认
    assert_eq!(st(parse("zz=1:state=idle:state=done:junk")), State::Done);
    assert_eq!(msg(parse("state=done:msg=aGk")), Some("hi".into()));
    // kind 只在 blocked 时留；不认识的 kind 读成 None；progress 只在 working/blocked 时留，只认 0-100 的规范十进制
    assert_eq!(kind(parse("state=working:kind=permission")), None);
    assert_eq!(kind(parse("state=blocked:kind=weird")), None);
    assert_eq!(progress(parse("state=working:progress=42")), Some(42));
    for p in ["101", "042", "-1", "x"] { assert_eq!(progress(parse(&format!("state=working:progress={p}"))), None); }
    assert_eq!(progress(parse("state=done:progress=42")), None);
    // app 字符不合法就当没有（不丢整条）
    assert_eq!(app(parse("state=idle:app=a*b")), None);
}
#[test] fn parse_drops_whole() {   // 规范里每种“整条丢弃”各一条
    for body in [
        "kind=permission",                                   // 没有 state
        "state=sleeping",                                    // 不认识的 state
        "state=idle:id=",  "state=idle:id=a//b",  "state=idle:id=a*b",
        &format!("state=idle:id={}", "a".repeat(33)),        // 段超 32
        &format!("state=idle:id={}", vec!["a"; 9].join("/")),// 超 8 段
        &format!("state=idle:id={}", vec!["a".repeat(31); 5].join("/")), // 总长超 128
        &format!("state=idle:app={}", "a".repeat(33)),       // app 超 32 丢整条
        &format!("state=idle:{}=1", "a".repeat(17)),         // 键超 16
        "state=done:msg=a",                                  // base64 解不开（字符集合法、长度不对）
        "state=done:msg=Cg==",                               // 解出来是 "\n"，控制字符
        "state=done:msg=wp8=",                               // U+009F，C1 控制字符
        "state=done:msg=/w==",                               // 不是 UTF-8
    ] { assert_eq!(parse(body), None, "{body}"); }
}
#[test] fn parse_strips_invisible() {
    // U+200B、U+202E、U+FEFF 去掉（gascity parse.go:271-286 的那张表）
    assert_eq!(msg(parse("state=done:msg=YeKAi2LigK5j77u/")), Some("abc".into()));
}
```

`parse_drops_whole` 里 base64 那一条不用 `!` 这类字符：值的字符集是 `[A-Za-z0-9_.,+/=-]`，不合法的字符只会让那一对被跳过，整条不会丢。辅助函数 `st/msg/kind/progress/app` 从 `Option<Message>` 取 `Set` 里的字段。

`Records` 的用例：

```rust
#[test] fn records_rules() {
    let mut r = Records::default();
    r.apply(set("state=working:app=claude-code"));
    r.apply(set("state=working:id=a:title=dA=="));
    r.apply(set("state=blocked:id=a/b:kind=question"));
    let d = r.deciding().unwrap();                         // 子记录 blocked 顶上来，app 从根继承
    assert_eq!((d.state, d.id.as_deref(), d.app.as_deref()), (State::Blocked, Some("a/b"), Some("claude-code")));
    r.apply(Message::Clear { id: Some("a".into()) });      // 清这一枝
    assert_eq!((r.children(), r.deciding().unwrap().state), (0, State::Working));
    r.apply(set("state=error:id=x"));
    r.apply(set("state=done"));
    assert_eq!(r.deciding().unwrap().state, State::Error); // error 子记录高过 done 的根
    r.apply(set("state=working"));
    r.drop_transient();                                    // working、blocked、idle 丢掉，done、error 留着
    assert_eq!((r.deciding().unwrap().state, r.children()), (State::Error, 1));
    r.apply(Message::Clear { id: None });
    assert!(r.deciding().is_none());
}
#[test] fn records_cap_drops_least_recently_updated() {
    let mut r = Records::default();
    for i in 0..256 { r.apply(set(&format!("state=idle:id=c{i}"))); }
    r.apply(set("state=idle:id=c0"));                      // c0 刚更新过
    r.apply(set("state=idle:id=new"));                     // 满了：丢 c1
    assert_eq!(r.children(), 256);
    assert!(r.get("c1").is_none() && r.get("c0").is_some() && r.get("new").is_some());
}
```

`Records` 需要一个 `#[cfg(test)] fn get(&self, id: &str) -> Option<&Record>`。

真实录制（照 `gascity golden_test.go`）：

```rust
fn trace(name: &str) -> Vec<String>  // 按 .reads 切分喂 Scanner → Probe 记 "probe"；Prompt 调 drop_transient 记 "prompt"；
                                     // Report 调 parse+apply，记 deciding 的 "state" 或 "state:kind"，没有记 "-"；parse 丢弃记 "dropped"
#[test] fn golden_claude_turns() {
    assert_eq!(trace("claude-turns"), ["probe","idle","working","blocked:permission","working","blocked:question","working",
        "done","working","done","working","idle","-","-","-"]);
}
#[test] fn golden_claude_msgs() {   // blocked 报告的 kind|msg
    assert_eq!(blocked_msgs("claude-turns"), ["permission|approve Bash: touch /tmp/osc7501x-work/claude-approved-marker",
        "question|answer: Which color do you prefer? (Red · Blue)"]);
}
#[test] fn golden_codex_turns() { assert_eq!(trace("codex-turns"), ["idle","working","blocked:permission","working","done","idle","-"]); }
#[test] fn golden_claude_error() {
    assert_eq!(trace("claude-error"), ["probe","idle","working","error","-","-","-"]);
    // error 那条的 msg 是 "API Error: 400 mock invalid_request_error"
}
#[test] fn golden_claude_children() { /* 子记录数的峰值是 2；最后 children()==0、deciding() 是 None */ }
#[test] fn golden_synthetic_split() { /* question 的 msg 是 "Allow `rm -rf build`?"；最后 deciding() 是 None */ }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cargo test -p rapp-term ps::` — Expected: 编译失败（`parse` 不存在）。

- [ ] **Step 3: 实现 `parse`**

照 `zellij program_status.rs:70-181` 和 `gascity parse.go:56-258`。base64 用 `base64::engine::GeneralPurpose`，`decode_padding_mode(DecodePaddingMode::Indifferent)`，字母表 STANDARD。先查编码长度再解码，再查解码长度；`std::str::from_utf8` 失败、含 C0（< 0x20）、DEL、C1（0x80–0x9F）就丢整条；再去掉 U+061C、U+200B–U+200F、U+202A–U+202E、U+2060–U+2069、U+FEFF。文件头加 zellij 的出处和版权行。

- [ ] **Step 4: 实现 `Records`**

照 `zellij program_status.rs:185-356`：`BTreeMap<String, (u64, Record)>`，键是 `id.unwrap_or_default()`，值里的 `u64` 是每次 `Set` 加一的序号；满 256 条且是新键时丢序号最小的那条。`deciding()`：根记录为准；任何子记录 `Blocked`（等级最高）或 `Error`（次之）且等级高过当前就顶上来。等级：Idle < Working < Done < Error < Blocked。不要 zellij 的 `working_since`、`worked`（用不到）。

- [ ] **Step 5: 跑测试，确认通过**

Run: `cargo test -p rapp-term ps::` — Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add rust/term/Cargo.toml Cargo.lock rust/term/src/pty/ps.rs
git commit -m "feat(term): parse OSC 7501 reports and keep zellij's record table"
```

---

### Task 3: `Tracker` 和快照 `Ps`；`Shared`、`Status` 带上 `ps`

**Files:**
- Modify: `rust/term/src/pty/ps.rs`
- Modify: `rust/term/src/pty/mod.rs:23-62`（`Shared.ps`、`status()`）
- Modify: `rust/term/src/pty/local.rs:95-112`（`Status.ps`）
- Modify: 所有构造 `Shared` 的地方：`holder.rs:96`、`holder.rs:440`（测试）、`view.rs:334`（测试）

**Interfaces:**
- Consumes: Task 2 的 `Scanner`、`parse`、`Records`、`State`。
- Produces:
  ```rust
  #[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
  pub struct Ps {
      pub state: String,                                     // idle | working | done | blocked | error
      #[serde(default, skip_serializing_if = "Option::is_none")] pub kind: Option<String>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub app: Option<String>,
      #[serde(default, skip_serializing_if = "Option::is_none")] pub msg: Option<String>,   // 最多 200 个 char，超了截断加 …
      #[serde(default, skip_serializing_if = "Option::is_none")] pub progress: Option<u8>,
      pub since: u64, pub stopped: u64, pub seq: u64,
  }
  pub const MSG_CHARS: usize = 200;
  pub struct Fed { pub probes: usize, pub changed: bool }
  #[derive(Default)] pub struct Tracker { .. }
  impl Tracker { pub fn feed(&mut self, bytes: &[u8], now: u64) -> Fed; pub fn ps(&self) -> Option<&Ps>; }
  // Shared:  pub ps: Mutex<Option<ps::Ps>>
  // Status:  #[serde(default, skip_serializing_if = "Option::is_none")] pub ps: Option<ps::Ps>
  ```

`Tracker::feed` 的规则（规格 §5.4、§5.5、§5.10）：

- 每个 `Report`：`parse` → `Records::apply`；每个 `Prompt`：`drop_transient`；每个 `Probe`：`probes += 1`。
- **每处理完一个事件**都看一次 `deciding()` 的状态：从 `Working` 或 `Blocked` 变成 `Done`、`Error`、`Idle` 时，`stopped = now`。逐事件看，是为了一块输出里同时有 `working` 和 `done` 时也记得住“停过”。
- **整块处理完**才生成一次快照：`deciding()` 为 `None` 时快照是 `None`；否则用它的 `state`、`kind`、`app`、`msg`（截断）、`progress` 拼快照。和上一份快照比，除去 `since`、`stopped`、`seq` 之外有任何不同就 `seq += 1`、`changed = true`；`state` 和上一份不同（或上一份是 `None`）时 `since = now`，否则沿用。`stopped` 变了也算 `changed`。`seq` 和 `stopped` 存在 `Tracker` 里，快照变成 `None` 再出现时接着往上加。

- [ ] **Step 1: 写失败的测试**

```rust
fn rep(body: &str) -> Vec<u8> { format!("\x1b]7501;{body}\x07").into_bytes() }

#[test] fn tracker_snapshot_since_stopped_seq() {
    let mut t = Tracker::default();
    assert!(!t.feed(b"plain text", 100).changed);
    assert!(t.ps().is_none());
    let f = t.feed(&rep("state=working:app=codex"), 100);
    assert!(f.changed);
    assert_eq!(t.ps().map(|p| (p.state.as_str(), p.since, p.stopped, p.seq)), Some(("working", 100, 0, 1)));
    assert!(!t.feed(&rep("state=working:app=codex"), 105).changed);            // 一样的报告不算变
    t.feed(&rep("state=blocked:kind=permission:app=codex"), 110);
    assert_eq!(t.ps().map(|p| (p.kind.as_deref(), p.since, p.seq)), Some((Some("permission"), 110, 2)));
    t.feed(&rep("state=done:app=codex"), 120);
    assert_eq!(t.ps().map(|p| (p.since, p.stopped, p.seq)), Some((120, 120, 3)));
}
#[test] fn tracker_one_chunk_working_then_done_still_stops() {
    let mut t = Tracker::default();
    let mut b = rep("state=working"); b.extend(rep("state=done"));
    t.feed(&b, 50);
    assert_eq!(t.ps().map(|p| (p.state.as_str(), p.stopped, p.seq)), Some(("done", 50, 1)));  // 合并后只加一次 seq
}
#[test] fn tracker_idle_at_start_is_not_a_stop() {
    let mut t = Tracker::default();
    t.feed(&rep("state=idle"), 10);
    assert_eq!(t.ps().unwrap().stopped, 0);
}
#[test] fn tracker_counts_probes_and_clear_empties() {
    let mut t = Tracker::default();
    assert_eq!(t.feed(b"\x1b]7501;?\x07\x1b]7501;?\x1b\\", 1).probes, 2);
    t.feed(&rep("state=working"), 2);
    t.feed(&rep("state=clear"), 3);
    assert!(t.ps().is_none());
    t.feed(&rep("state=working"), 4);
    assert_eq!(t.ps().unwrap().seq, 3);                                          // seq 接着加
}
#[test] fn tracker_prompt_drops_blocked() {
    let mut t = Tracker::default();
    t.feed(&rep("state=blocked:kind=question"), 1);
    t.feed(b"\x1b]133;A\x07", 2);
    assert!(t.ps().is_none());
}
#[test] fn msg_is_cut_to_200_chars() {    // Review Focus 2
    let mut t = Tracker::default();
    let long = "问".repeat(150) + &"😀".repeat(150);
    t.feed(&rep(&format!("state=done:msg={}", b64(&long))), 1);
    let m = t.ps().unwrap().msg.clone().unwrap();
    assert_eq!(m.chars().count(), 201);
    assert!(m.ends_with('…') && m.starts_with(&"问".repeat(150)));
}
#[test] fn status_without_ps_reads_and_unknown_fields_are_ignored() {   // 新旧两边谁先升级都不坏
    let old = r#"{"v":2,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":7}"#;
    assert_eq!(serde_json::from_str::<Status>(old).unwrap().ps, None);
    let newer = r#"{"v":2,"name":"a","command":"sh","cols":80,"rows":24,"activity":1,"viewers":0,"pid":7,"ps":{"state":"done","since":1,"stopped":1,"seq":1},"later":true}"#;
    assert_eq!(serde_json::from_str::<Status>(newer).unwrap().ps.unwrap().state, "done");
}
```

`msg_is_cut_to_200_chars` 的 `msg` 原文是 150 + 150 = 300 个字符、900 字节，编码后 1200 字节，在 2732 和 2048 的限制之内。`b64` 是测试里用 `base64` STANDARD 编码的小辅助。最后一个测试放在 `local.rs` 的测试里。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cargo test -p rapp-term ps:: local::` — Expected: 编译失败（`Tracker` 不存在）。

- [ ] **Step 3: 实现 `Ps`、`Tracker`；`Shared.ps`、`Status.ps`、`status()` 带上 `self.ps` 的克隆；三处构造 `Shared` 的地方加 `ps: Mutex::new(None)`**

- [ ] **Step 4: 跑测试，确认通过**

Run: `cargo test -p rapp-term` — Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add rust/term/src
git commit -m "feat(term): program status snapshot on Status"
```

---

### Task 4: `pump_output` 答探测、更新状态；`programStatus` 开关

**Files:**
- Modify: `rust/term/src/pty/holder.rs:43-52`（`RunOpts`）、`:150`（起线程处）、`:265-293`（`pump_output`）、`:425-`（测试）
- Modify: `rust/term/src/config.rs:11-21`
- Modify: `rust/term/src/main.rs:136-142`

**Interfaces:**
- Consumes: Task 3 的 `Tracker`、`Fed`、`Shared.ps`。
- Produces:
  ```rust
  pub const PROBE_REPLY: &[u8] = b"\x1b]7501;?\x1b\\";   // ps.rs
  pub const MAX_REPLIES: usize = 64;                     // ps.rs
  // RunOpts: pub program_status: bool
  // TermConfig: #[serde(rename = "programStatus")] pub program_status: bool   （默认 true）
  pub fn beside(term_dir: &Path) -> PathBuf               // config.rs：term 目录旁边的 term.json，即 term_dir.parent()/term.json
  fn pump_output<W: Write>(pty, window, shared, drained, feed, tracker: Option<Tracker>)
  ```

`pump_output` 每块输出的顺序（规格 §5.1，gascity `relay/doc.go:10-20`）：

1. `tracker` 有时先 `feed(&b[..n], now())`；`probes > 0` 就把 `PROBE_REPLY` 重复 `min(probes, MAX_REPLIES)` 次拼成**一个** `Vec` 送进 `shared.input`；`changed` 就把 `tracker.ps().cloned()` 写进 `shared.ps`。
2. 写给窗口（现有）。
3. `guarded` 喂仿真器（现有）。
4. `activity`、`rev`（现有，每块一次，所以状态变化也只通知一次）。

`Tracker` 在 `pump_output` 自己的线程里，不进 `guarded`，仿真器 panic 不影响它。“排着队的回答最多 64 条”在这里落成“一块输出里最多答 64 次”【计划定的】：`shared.input` 是无界通道，数不出还没写进伪终端的条数；每块 64 KiB 的输出最多带出 64 × 9 字节的回答，程序再怎么只发探测不读输入，队列的增长也被输出量压住。

- [ ] **Step 1: 写失败的测试**（`holder.rs` 的 `mod tests`；测试辅助 `shared()` 改成同时返回 input 的接收端）

```rust
/// 窗口每次被写之前，先把 input 里已经有的东西记成 "reply"，再记 "window"。
struct Ordered { rx: mpsc::UnboundedReceiver<Vec<u8>>, log: Vec<String> }
impl Write for Ordered { /* write: while let Ok(v) = rx.try_recv() { log.push(format!("reply:{}", v.len())) }; log.push("window"); Ok(len) */ }

#[test] fn the_probe_answer_is_queued_before_the_window_sees_the_probe() {
    // 程序一口气发 “7501 探测 + 设备属性查询”；外层窗口的回答只能排在后面（gascity bridge_test.go:115）
    let (sh, rx) = shared_with_input(30, 4);
    let window = Mutex::new(Window::new(Ordered { rx, log: vec![] }));
    let (tx, _d) = oneshot::channel();
    pump_output(Chunks(VecDeque::from([&b"\x1b]7501;?\x07\x1b[c"[..]])), &window, &sh, tx, Emu::feed, Some(Tracker::default()));
    assert_eq!(window.lock().unwrap().get_ref().log, ["reply:9", "window"]);
}
#[test] fn a_report_updates_shared_ps() {
    let (sh, _rx) = shared_with_input(30, 4);
    /* 喂 b"\x1b]7501;state=blocked:kind=permission:app=claude-code\x07" → sh.status().ps 的 state 是 "blocked"、kind 是 Some("permission") */
}
#[test] fn a_flood_of_probes_gets_64_answers() {             // Review Focus 3
    let flood: &'static [u8] = Box::leak(b"\x1b]7501;?\x07".repeat(1000).into_boxed_slice());
    /* 喂一块 flood → rx 里正好一条，长度 64 * 9 */
}
#[test] fn status_keeps_updating_when_the_emulator_panics() {
    /* feed 闭包对每块都 panic；喂一块报告 working → sh.status().ps 的 state 是 "working" */
}
#[test] fn off_means_byte_for_byte_today() {
    let (sh, mut rx) = shared_with_input(30, 4);
    let window = Mutex::new(Window::new(Vec::new()));
    let (tx, _d) = oneshot::channel();
    let bytes: &[u8] = b"\x1b]7501;?\x07\x1b]7501;state=working\x07hi";
    pump_output(Chunks(VecDeque::from([bytes])), &window, &sh, tx, Emu::feed, None);
    assert_eq!(window.lock().unwrap().get_ref().as_slice(), bytes);
    assert!(rx.try_recv().is_err() && sh.status().ps.is_none());
}
```

`config.rs` 的测试：

```rust
#[test] fn program_status_defaults_on_and_reads_camel_case() {
    assert!(TermConfig::default().program_status);
    // 只写了 allow 的旧文件 → program_status 是 true；{"programStatus":false} → false，allow 仍是 true
}
#[test] fn beside_is_next_to_the_term_dir() { assert_eq!(beside(Path::new("/r/local/term")), PathBuf::from("/r/local/term.json")); }
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cargo test -p rapp-term holder:: config::` — Expected: 编译失败。

- [ ] **Step 3: 实现**

- `pump_output` 加参数 `tracker: Option<Tracker>`，按上面的顺序处理。`holder.rs:150` 传 `opts.program_status.then(Tracker::default)`。
- `TermConfig` 加字段，`Default` 里是 `true`。
- `main.rs` 填 `program_status: config::load(&config::beside(&dir)).map(|c| c.program_status).unwrap_or(true)`（`dir` 先算出来再放进 `RunOpts`）。文件坏了按默认开【计划定的】：坏文件时 `serve` 已经拒绝所有终端请求，使用者看得到，用不着这里再关。`run` 只在启动时读一次，改了开关对新开的会话生效。
- 更新 `holder.rs` 文件头那句 “It answers none of the program's terminal queries (the window does)”：改成除了 OSC 7501 探测（`programStatus` 开着时由 `run` 回答）以外都由窗口回答。

- [ ] **Step 4: 跑测试，确认通过**

Run: `cargo test -p rapp-term` — Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add rust/term/src
git commit -m "feat(term): run answers the OSC 7501 probe and tracks program status"
```

---

### Task 5: 服务：`TermRow.ps` 和新的未读规则

**Files:**
- Modify: `rust/term/src/unread.rs`
- Modify: `rust/term/src/list.rs:7-17`
- Modify: `rust/term/src/serve.rs:529-546`（`pty_rows`）、`:754`（tmux 行，`ps: None`）
- Modify: `rust/testkit/src/bin/fake-rapp-term.rs:100` 只在 testkit 的断言因此失败时才改
- Modify: `docs/superpowers/specs/2026-11-11-rapp-platform-design.md:242`（`TermRow` 的字段说明加 `ps`）

**Interfaces:**
- Consumes: Task 3 的 `Ps`、`Status.ps`。
- Produces:
  ```rust
  impl Unread { pub fn is_unread_ps(&self, session_id: &str, ps: &Ps, now: u64) -> bool; }
  // TermRow: #[serde(skip_serializing_if = "Option::is_none")] pub ps: Option<Ps>
  ```

规则（规格 §5.6）：`working` → 否；`blocked` → 是（看过也是）；`done`、`error`、`idle` → `ps.stopped > max(started, 上次看过)`，不等 3 秒安静；其他字符串按 `working` 处理（不会出现，`parse` 已经丢了不认识的状态）。`pty_rows` 里 `s.ps` 有就用 `is_unread_ps`，没有用原来的 `is_unread`；`ps` 原样放进行里。

- [ ] **Step 1: 写失败的测试**（`unread.rs`，规格 §5.6 那张表一行一条）

```rust
fn ps(state: &str, stopped: u64) -> Ps { Ps { state: state.into(), kind: None, app: None, msg: None, progress: None, since: 0, stopped, seq: 1 } }
#[test] fn with_ps_working_is_never_unread() { assert!(!Unread::new(1000).is_unread_ps("w", &ps("working", 1050), 9999)); }
#[test] fn with_ps_blocked_is_unread_even_when_seen() {
    let mut u = Unread::new(1000); u.seen("w", 2000);
    assert!(u.is_unread_ps("w", &ps("blocked", 0), 2001));
}
#[test] fn with_ps_a_stop_after_the_last_look_is_unread_at_once() {
    let mut u = Unread::new(1000);
    for s in ["done", "error", "idle"] {
        assert!(u.is_unread_ps("w", &ps(s, 1050), 1050), "{s}");       // 不等 3 秒
        assert!(!u.is_unread_ps("w", &ps(s, 990), 1050), "{s}");       // 服务启动之前停的不算
        assert!(!u.is_unread_ps("w", &ps(s, 0), 1050), "{s}");         // 没停过
    }
    u.seen("w", 1060);
    assert!(!u.is_unread_ps("w", &ps("done", 1050), 1100));
    assert!(u.is_unread_ps("w", &ps("done", 1070), 1070));
}
```

`serve.rs` 的测试：给 `pty_rows` 一个带 `ps: Some(blocked)`、`activity` 是刚才的 `Status`，断言行里 `unread == true` 且 `ps` 原样在；序列化后的 JSON 里有 `"ps":{"state":"blocked",…}`；`ps: None` 的行序列化后没有 `ps` 这个键。

- [ ] **Step 2: 跑测试，确认失败**

Run: `cargo test -p rapp-term unread:: serve::` — Expected: 编译失败。

- [ ] **Step 3: 实现 `is_unread_ps`、`TermRow.ps`、`pty_rows`；tmux 行填 `ps: None`；改平台设计第 242 行**

- [ ] **Step 4: 跑全工作区测试和 clippy**

Run: `cargo test --workspace --no-fail-fast`，再 `cargo clippy --workspace --all-targets -- -D warnings`
Expected: 全部通过。`rapp-term` 的伪终端测试在机器忙时偶尔超时（已知的负载抖动），单独重跑那一条通过即可。

- [ ] **Step 5: Commit**

```bash
git add rust docs/superpowers/specs/2026-11-11-rapp-platform-design.md
git commit -m "feat(term): session rows carry program status; unread follows it"
```

---

### Task 6: 主控台：解析 `ps`，改灯和那一行字

**Files:**
- Modify: `gui/lib/hub_client.dart:122-134`（`TermRow`）、`:171-181`（`_termList`）
- Create: `gui/lib/ui/term_status.dart`（把 `devices_tab.dart:646-662` 的 `termStatus`、`termLamp` 挪过来）
- Modify: `gui/lib/ui/devices_tab.dart`（删掉这两个函数，改成 import）
- Modify: `gui/test/ui/devices_tab_test.dart:720-731`（import 新文件）
- Test: `gui/test/hub_client_test.dart`、`gui/test/ui/term_status_test.dart`（新）

**Interfaces:**
- Produces:
  ```dart
  class TermPs {
    const TermPs(this.state, {this.kind, this.app, this.msg, this.progress, this.since = 0, this.stopped = 0, this.seq = 0});
    final String state; final String? kind, app, msg; final int? progress; final int since, stopped, seq;
  }
  // TermRow 构造函数末尾加命名参数 {this.ps}；final TermPs? ps;   原有的位置参数调用不用改
  TermPs? termPs(Object? v);              // hub_client.dart：不是 Map、或 state 不是这五个之一，返回 null
  String termStatus(TermRow r, int nowSecs);
  Lamp termLamp(TermRow r, int nowSecs);
  String termAskWord(TermPs ps);          // blocked 的那行字：“等确认 · approve …”
  ```

字和灯（规格 §5.7；“在干活”这个词【计划定的】，规格只写了百分比）：

| 条件（从上往下，先中先用） | `termStatus` | `termLamp` |
|---|---|---|
| `dead` | `已退出` | `disconnected` |
| `ps.state == blocked` | `termAskWord`：`kind` 是 `permission`/`question`/`auth` 分别为 `等确认`/`在提问`/`要登录`，其他为 `在等你`；有 `msg` 时加 ` · $msg` | `waiting` |
| `ps.state == working` | 有 `progress`：`在干活 · 42%`；没有：`在干活` | `active` |
| `ps.state == error` | 有 `msg`：`出错 · $msg`；没有：`出错` | `unread` 时 `waiting`，否则 `idle` |
| `ps.state` 是 `done` 或 `idle` | 现有规则（`未读` 或几分钟没动静） | `unread` 时 `waiting`，否则 `idle` |
| 没有 `ps` | 现有规则 | 现有规则 |

规格写的“出错用错误色”这一版不做【计划定的】：`Lamp` 没有错误色的那一种，加一种要动灯的整套样式；先用字表达，记进 todo。

- [ ] **Step 1: 写失败的测试**

`hub_client_test.dart`：一条 `terms` 事件，行里带 `"ps":{"state":"blocked","kind":"permission","msg":"approve Bash: ls","since":5,"stopped":0,"seq":3}` → `TermRow.ps` 各字段对上；不带 `ps` → `null`；`"ps":{"state":"sleeping"}` 和 `"ps":"x"` → `null`（Review Focus 4）。

`term_status_test.dart`：

```dart
TermRow row({TermPs? ps, bool unread = false, bool dead = false, int ago = 5}) =>
    TermRow('term:pty:w', 'w', 'sh', null, 1, 1, 1000 - ago, dead, unread, ps: ps);
test('blocked', () {
  expect(termStatus(row(ps: const TermPs('blocked', kind: 'permission', msg: 'approve Bash: ls')), 1000), '等确认 · approve Bash: ls');
  expect(termStatus(row(ps: const TermPs('blocked', kind: 'question')), 1000), '在提问');
  expect(termStatus(row(ps: const TermPs('blocked', kind: 'auth')), 1000), '要登录');
  expect(termStatus(row(ps: const TermPs('blocked')), 1000), '在等你');
  expect(termLamp(row(ps: const TermPs('blocked')), 1000), Lamp.waiting);
});
test('working ignores quiet time', () {
  expect(termStatus(row(ps: const TermPs('working'), ago: 900), 1000), '在干活');
  expect(termStatus(row(ps: const TermPs('working', progress: 42)), 1000), '在干活 · 42%');
  expect(termLamp(row(ps: const TermPs('working'), ago: 900), 1000), Lamp.active);
});
test('error, done, idle', () {
  expect(termStatus(row(ps: const TermPs('error', msg: 'API Error: 400')), 1000), '出错 · API Error: 400');
  expect(termStatus(row(ps: const TermPs('done'), unread: true), 1000), '未读');
  expect(termLamp(row(ps: const TermPs('done'), unread: true), 1000), Lamp.waiting);
  expect(termLamp(row(ps: const TermPs('idle'), ago: 1), 1000), Lamp.idle);
});
test('dead wins', () => expect(termStatus(row(ps: const TermPs('blocked'), dead: true), 1000), '已退出'));
```

- [ ] **Step 2: 跑测试，确认失败**

Run（在 `gui/`）：`~/development/flutter/bin/flutter test test/hub_client_test.dart test/ui/term_status_test.dart` — Expected: 编译失败（`TermPs` 不存在）。

- [ ] **Step 3: 实现**

`termPs` 只认五个状态；`progress` 只收 0–100 的整数，否则当没有。`_TermRow` 里显示 `termStatus` 的 `Text` 确认是 `maxLines: 1` 加省略号（`msg` 最长 200 个字符）。`msg` 只当纯文字显示（规格 §5.7）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `~/development/flutter/bin/flutter test test/hub_client_test.dart test/ui/term_status_test.dart test/ui/devices_tab_test.dart`，再 `~/development/flutter/bin/flutter analyze`
Expected: 全部通过，analyze 没有新的问题。然后 `git checkout gui/pubspec.lock`。

- [ ] **Step 5: Commit**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): terminal rows show program status"
```

---

### Task 7: 主控台：`blocked` 的会话进“需要你”

**Files:**
- Modify: `gui/lib/ui/main_state.dart:68-79`（`NeedKind`、`NeedItem`）、`:1049-1061`（`needs`）
- Modify: `gui/lib/ui/needs_you.dart:39-48`（按钮的灯）、`:144-170`（`_row`）
- Test: `gui/test/ui/main_state_test.dart`、`gui/test/ui/top_bar_test.dart` 或 needs 现有的 widget 测试所在文件

**Interfaces:**
- Consumes: Task 6 的 `TermRow.ps`、`termAskWord`、`termDisplayName`（已有）。
- Produces:
  ```dart
  enum NeedKind { session, device, terminal }
  // NeedItem 加命名参数 {this.device, this.title}；final String? device, title;
  //   terminal：target = 会话 id，device = 设备 id，title = termDisplayName(name, host)
  ```

规则（规格 §5.6 的补充一条）：

- `hub.termLists` 里每台设备每一行，`!dead && ps?.state == 'blocked'` 就出一条 `NeedItem(NeedKind.terminal, …)`。文字：`'$title @ ${deviceName(device)}：${termAskWord(ps)}'`。
- 排序用的 `seq`：`_termNeedSeq.putIfAbsent('$device\n$id\n${ps.seq}', () => ++_seq)`，`_termNeedSeq` 是 `main_state` 里新加的 `Map<String, int>`。同一次提问的先后不变，新的一次提问排到最前。
- 离开 `blocked` 或行没了，这条自己消失（`needs` 每次现算）。
- `_row`：`terminal` 是 `RappButton.accent`，key `need-open-${n.target}`，字 `打开`，`hubUsable` 时可点：`state.openOrSwitch(n.device!, n.target, n.title!)` 后 `state.closeCorner()`。
- `_button`：有 `session` 时灯和边框照旧；没有 `session` 但有 `terminal` 时灯用 `Lamp.waiting`、边框用 `t.accent`；都没有时照旧。

- [ ] **Step 1: 写失败的测试**

`main_state_test.dart`（`hub.termLists` 的写法照 `overview_test.dart:448`）：

```dart
test('a blocked terminal is in needs until it is not', () {
  // 设备 m1 有两行：a 是 blocked/permission，b 是 working
  st.hub!.termLists['m1'] = TermList('m1', terms: [
    TermRow('term:pty:a', 'a', 'claude', null, 1, 0, 0, false, false, ps: const TermPs('blocked', kind: 'permission', msg: 'approve Bash: ls', seq: 3)),
    TermRow('term:pty:b', 'b', 'codex', null, 1, 0, 0, false, false, ps: const TermPs('working', seq: 1)),
  ]);
  final n = st.needs.single;
  expect((n.kind, n.target, n.device, n.title), (NeedKind.terminal, 'term:pty:a', 'm1', 'a'));
  expect(n.text, endsWith('等确认 · approve Bash: ls'));
  st.hub!.termLists['m1'] = TermList('m1', terms: [
    TermRow('term:pty:a', 'a', 'claude', null, 1, 0, 0, false, false, ps: const TermPs('working', seq: 4)),
  ]);
  expect(st.needs, isEmpty);
});
test('a dead session that was blocked is not in needs', () {   // Review Focus 5
  st.hub!.termLists['m1'] = TermList('m1', terms: [
    TermRow('term:pty:a', 'a', 'claude', null, 1, 0, 0, true, false, ps: const TermPs('blocked')),
  ]);
  expect(st.needs, isEmpty);
});
test('a new ask comes first; the same ask keeps its place', () {
  /* 先让 a blocked（seq 3），再让 b blocked（seq 1）→ needs 的顺序是 b、a；
     a 的 ps 不变再取一次 needs，顺序不变；a 变成 seq 5 的 blocked → a 排到最前 */
});
```

needs 弹层的 widget 测试：一条 terminal 的需要 → 有 `Key('need-open-term:pty:a')`，字是“打开”；点它 → 调到 `openOrSwitch('m1', 'term:pty:a', 'a')`（用现有测试里截住打开动作的办法），弹层关上。

- [ ] **Step 2: 跑测试，确认失败**

Run: `~/development/flutter/bin/flutter test test/ui/main_state_test.dart` — Expected: 编译失败（`NeedKind.terminal` 不存在）。

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试，确认通过**

Run: `~/development/flutter/bin/flutter test`（全量），再 `~/development/flutter/bin/flutter analyze`
Expected: 全部通过。然后 `git checkout gui/pubspec.lock`。

- [ ] **Step 5: Commit**

```bash
git add gui/lib gui/test
git commit -m "feat(gui): a terminal waiting for you is in 需要你"
```

---

### Task 8: 文档、致谢、实机检查清单

**Files:**
- Modify: `docs/superpowers/specs/2026-11-16-rapp-text-terminal-design.md`（§4.1 `run`：答 7501 探测、带 `ps`；§7 输入：探测的回答也走输入队列）
- Modify: `docs/superpowers/specs/2026-11-14-rapp-terminal-sessions-design.md`（§12 状态：有 7501 时的未读和“需要你”；§18 第 2 条标为已由程序状态规格回答）
- Modify: `docs/superpowers/specs/2026-11-13-rapp-config-reference.md:~180`（`term.json` 加 `programStatus`：默认 `true`，`run` 启动时读一次，坏文件按默认）
- Modify: `docs/superpowers/specs/2026-11-13-rapp-product-decisions.md`、`2026-11-13-rapp-spec-roadmap.md`（记 PS1–PS6、“自动回应是功能，默认关，责任在使用者”、“不做伪装和绕过”；路线图加程序状态规格和这份计划，S2–S4 待写计划）
- Modify: `README.md:76`（Acknowledgments 加 gascity 和 zellij：名字、链接、MIT、移植了什么；“A 上的前提”加 Claude Code ≥ 2.1.295、Codex ≥ 0.163.0、agy ≥ 1.4.0 才有状态）
- Modify: `tasks/todo.md`（实机检查）

README 的“合规使用”一节放到 S4 的计划里写（规格 §7.8），S1 不往 CLI 里送任何输入。

- [ ] **Step 1: 改上面的文档**

- [ ] **Step 2: `tasks/todo.md` 加程序状态 S1 的实机检查**，照规格 §8、§9：

1. `rapp-term run -- claude`：Claude Code 开始报状态；会话列表里看得到“在干活”。
2. 让 Claude Code 跑一条要确认的命令：不点开会话，设备页那一行是“等确认 · approve Bash: …”，“需要你”多一条，点“打开”进到会话；看过以后不清，回了才清。
3. 同时开三个会话各跑一个 CLI：不点开就看得出哪个在等确认；Agent 安静思考时不亮未读。
4. Codex：等确认时是“等确认”（没有 `msg`）。
5. agy（P0 第 1、2 条）：答了探测以后报不报、结尾是什么、`msg` 里是什么。
6. 外层是 iTerm2 ≥ 3.7.5 或 kitty ≥ 0.50.0 时，程序收到两次探测回答有没有副作用（P0 第 3 条）。
7. Claude Code 的 `done` 和 `idle` 各在什么时候出现，回合结束是否正好亮一次未读（P0 第 5 条）。
8. `term.json` 写 `{"programStatus": false}` 后新开的会话：和现在完全一样，没有状态。
9. 错误色没做，`error` 只靠“出错 · …”的字（Task 6）。

- [ ] **Step 3: 最后整体验证**

Run: `cargo test --workspace --no-fail-fast`、`cargo clippy --workspace --all-targets -- -D warnings`、在 `gui/` 跑 `~/development/flutter/bin/flutter test` 和 `flutter analyze`，然后 `git checkout gui/pubspec.lock`。
Expected: 全部通过。

- [ ] **Step 4: Commit**

```bash
git add docs README.md tasks/todo.md
git commit -m "docs: program status S1 in the specs, README credits and real-machine checks"
```

完成后把分支 `feat/program-status-s1` 交给 rapp-49 合并（不要自己合进 `main`）。
