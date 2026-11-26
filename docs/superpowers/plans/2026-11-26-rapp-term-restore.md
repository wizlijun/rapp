# Text Terminal Restore + 新建 From the Last Terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a reboot (or closed windows) the user brings back their text terminals in one step — same name, directory, shell, venv/conda, last command typed in but not run — from rApp or `rapp term restore`; and every 新建 starts in the current or last text terminal's directory.

**Architecture:** `rapp-term run` (the holder) starts zsh/bash/fish through a small rapp shell-integration file that reports cwd/venv/conda at each prompt and each command line before it runs (private OSC 7502). The holder keeps a snapshot per terminal in `$ROOT/local/term/saved/<key>.json` (debounced, secrets filtered) and deletes it only when the user ended the terminal. `serve` lists restorable snapshots in the local `HostRow`, and gains `restore`, `forget` and `from:"last"`; restore reuses the open flow with `--restore <key>`, so the holder keeps the old key and the term id stays the same. The wire grows `Op::RestoreTerms`/`Op::ForgetTerms`; the hub grows `restore_terms`/`forget_terms`; the CLI grows `rapp term restore`; the GUI grows the 恢复 dialog and passes `from` on every 新建.

**Tech Stack:** Rust (tokio, portable_pty, serde, libc, base64), zsh/bash/fish scripts embedded with `include_str!`, Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-11-26-rapp-term-restore-design.md` — read §4 in full before any task; it is the authority. Where this plan changes a 【我定的】 detail of the spec it says so under "Plan decisions".

## Plan decisions (changes to the spec's own calls; update the spec in Task 10)

- **P1 — OSC 7502 passes through to the window**, like OSC 7501 does today. Terminal.app and the holder's `Emu` ignore unknown OSCs, so swallowing them buys nothing and would need an output filter. (Spec §4.2 said "holder 吞掉".)
- **P2 — OSC 7502 `state` payload is fields, not JSON:** `ESC ] 7502 ; state ; cwd=<b64> ; venv=<b64> ; conda=<b64> ; conda_name=<b64> BEL`, empty fields left out, each value standard base64 of the UTF-8 bytes. Shell scripts cannot JSON-escape paths reliably; base64 per field needs no escaping. `run` stays `ESC ] 7502 ; run ; <b64> BEL`.
- **P3 — the hook reports `state` only when it changed** since its last report (saves forks on every prompt), but writes `OSC 133;A` at every prompt.
- **P4 — zsh needs only `.zshenv`** (the Ghostty way): it restores `ZDOTDIR`, sources the user's `.zshenv`, and when interactive installs a one-shot `precmd` that runs after the user's `.zshrc` and adds the real hooks. zsh then reads the user's `.zprofile/.zshrc/.zlogin` from the user's own `ZDOTDIR` by itself.
- **P5 — the snapshot has no `app`:** `restore` takes `app` like `open` does (GUI: `prefs.termAppFor`; CLI: none → serve picks the first launcher).
- **P6 — input time:** `Shared` gains `input_at`, set on every keystroke/viewer input; `Status` gains `input` (Unix second, 0/absent for never). Not shared with CLI-update's `activity` event (that branch is unmerged).
- **P7 — Terminal.app's own window restore (spec §8)** is investigated and written down in Task 10; no mitigation is built in this plan.

## Global Constraints

- No protocol version bump; every new field is optional (`#[serde(default, skip_serializing_if…)]`). Old devices send no `saved` → GUI shows no 恢复.
- `cwd`, `cmd`, `venv`, `conda` never leave the device: not in `TermRow`, not in `HostRow.saved` (only `key,name,prog,saved,boot`), not in logs. `log_fields` for `restore_terms`/`forget_terms` records only `keys` count; `open_term` records `from` as `"last"`, `"term"` or nothing.
- Snapshot dir `$ROOT/local/term/saved/` 0700, files 0600, written temp-then-rename. Hook dir `$ROOT/local/term/shell/` 0700.
- Snapshot debounce 2 s; written at start and on change only; prune >30 days or beyond the 50 newest, never a live key's file.
- Command filter (spec §4.3, verbatim rules): strip leading `VAR=value` words; drop cmd (keep prog) if it has newline/control chars, is >1000 chars, or matches the secret table: option names containing `key`/`token`/`secret`/`password`/`passwd`/`auth`/`credential`; `-p` as an argument of `mysql`/`psql`; `Authorization:`; `Bearer `; `://user:pass@`; words starting `sk-`, `ghp_`, `gho_`, `github_pat_`, `xox`, `AKIA`, `eyJ`; any word of ≥32 chars all `[A-Za-z0-9_-]`.
- Prefill: written to the pty after the first `OSC 133;A`, or after 2 s without one; **never with `\r`/`\n`**.
- Snapshot deleted only on `End::Exited` and `shared.end` (结束终端/⌘W) and by `forget`/prune. External SIGHUP/TERM/INT/QUIT keeps it.
- Copy (verbatim): 「恢复」, 「恢复…」, 「上次没关的 N 个终端」, 「恢复上次的终端 · <设备名>」, 「全部清掉」, 「新建」, 「取消」, 「恢复所选」, 「rApp：上次的环境 <路径> 已不在，没有激活」, list rows `名字 · 程序（无则 —）· 多久以前` (「刚才」/「N 分钟前」/「N 小时前」/「N 天前」).
- Hooks only for shells rapp-term starts; the user's dotfiles are never edited; `ZDOTDIR`/`RAPP_ZDOTDIR`/`RAPP_RESTORE_*` are gone from the environment once the shell is up.
- Tests: `PATH=$HOME/.cargo/bin:$PATH cargo test --workspace --no-fail-fast`; `cargo clippy --workspace --all-targets -- -D warnings`; flutter at `~/development/flutter/bin` (`flutter test` in `gui/`), then `git checkout gui/pubspec.lock`. `grep` here is ugrep: use `/usr/bin/grep` or `git grep`. No `timeout` binary on this Mac.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A user's `precmd`/`PROMPT_COMMAND`/DEBUG trap already in place** (oh-my-zsh, starship, bash-preexec): ours must be added beside theirs, keep `$?` for their prompt, and in bash with an existing DEBUG trap ours steps back (state only, no `run`). → Task 2 tests `zsh_keeps_user_precmd_and_status`, `bash_existing_debug_trap_left_alone`.
2. **A terminal left idle for weeks while alive**: its snapshot is old by `saved` but must not be pruned, or the reboot loses it. → Task 3 test `prune_never_touches_live_keys`.
3. **A secret inside a command the user ran** (`KEY=x claude`, `curl -H 'Authorization: Bearer …'`, `--api-key=sk-…`): the file on disk must not contain it. → Task 3 test `secrets_never_reach_disk` (greps the written file bytes, not the struct).
4. **Restoring when the old directory, venv or shell is gone**: the terminal still opens (home dir / default shell), prints the 环境已不在 line once, never fails the whole restore. → Task 5 test `restore_with_missing_cwd_and_shell`, Task 2 test `restore_missing_venv_prints_once`.
5. **Two restores racing (GUI tap + `rapp term restore`, or a double tap)**: each key opens once. → Task 5 test `restore_skips_keys_that_came_alive`.

---

### Task 1: OSC 7502 scanning + shell state in the holder

**Files:**
- Create: `rust/term/src/pty/shell.rs` (report parsing, `ShellState`, hook launch; hook files come in Task 2)
- Modify: `rust/term/src/pty/ps.rs` (new `Kind::Is7502`, `Event::Shell`), `rust/term/src/pty/mod.rs` (`Shared.shell`, `Shared.input_at`, `Shared.dirty`; `pub mod shell;`), `rust/term/src/pty/holder.rs` (`pump_output` routes `Event::Shell`; input time), `rust/term/src/pty/view.rs:217` (input time), `rust/term/src/pty/local.rs` (`Status.input`)
- Test: in-module `#[cfg(test)]` of `shell.rs`, `ps.rs`, `holder.rs`

**Interfaces:**
- Produces:
  - `pub enum Report { State { cwd: Option<String>, venv: Option<String>, conda: Option<String>, conda_name: Option<String> }, Run(String) }`
  - `pub fn parse_report(body: &[u8]) -> Option<Report>` — `body` is what follows `7502;` up to the terminator.
  - `#[derive(Default, Clone, PartialEq, Debug)] pub struct ShellState { pub hooked: bool, pub cwd: Option<String>, pub venv: Option<String>, pub conda: Option<String>, pub conda_name: Option<String>, pub running: Option<String>, pub pending: Option<String> }` — `hooked` true after the first 7502 report; `running` is the raw command line between `run` and the next prompt; `pending` is the restored command still waiting for the user (Task 4).
  - `impl ShellState { pub fn apply(&mut self, r: Report); pub fn prompt(&mut self) }` — `apply(Run(c))` sets `running = Some(c)` and clears `pending`; `apply(State{..})` replaces the four env fields (and sets `hooked`); `prompt()` clears `running` only when `hooked`.
  - `Event::Shell(Report)` from the scanner.
  - `Shared { shell: Mutex<ShellState>, input_at: AtomicU64, dirty: watch::Sender<u64> }` — `dirty` is bumped whenever anything a snapshot holds changes (shell state, name, fg cwd/prog).
  - `Status.input: u64` (`#[serde(default, skip_serializing_if = "is_zero")]`), filled from `input_at`.

- [ ] **Step 1: Write failing tests** in `shell.rs`/`ps.rs`:
  - `state_report_parses_fields`: `parse_report(b"state;cwd=L1VzZXJzL2I=;venv=")` → `State{cwd: Some("/Users/b"), venv: None, ..}` (empty field = none).
  - `run_report_parses`: `b"run;Y2xhdWRlIC1j"` → `Run("claude -c")`.
  - `bad_base64_and_unknown_kind_are_none`: `b"run;!!!"`, `b"weird;x"`, `b"state;cwd=/plain"` → `None`.
  - `report_split_across_chunks`: scanner fed `b"\x1b]7502;run;Y2xh"` then `b"dWRl\x07"` yields exactly one `Event::Shell(Run("claude"))`.
  - `overlong_report_is_skipped`: a 7502 body longer than `MAX_SEQUENCE` (4096) yields no event and the scanner recovers for the next `\x1b]133;A\x07` (→ `Event::Prompt`).
  - `prompt_clears_running_only_when_hooked`; `run_clears_pending`.
  - In `holder.rs` tests: `a_7502_report_updates_shared_shell_and_bumps_dirty` (feed via `pump_output` helper like `a_report_updates_shared_ps`), `input_moves_input_at`.
- [ ] **Step 2: Run** `cd rust && cargo test -p rapp-term shell:: ps:: holder::` — expect compile errors / FAIL.
- [ ] **Step 3: Implement.** In `ps.rs` add `const P7502: &[u8] = b"7502;"` next to `P7501` and recognise it the same way; base64 via the workspace `base64` crate (`STANDARD`, add to `rust/term/Cargo.toml` if not there). `pump_output` handles `Event::Shell(r)` by `shared.shell.lock().apply(r)` + bump `dirty`, and `Event::Prompt` additionally calls `shell.prompt()`; it keeps passing all bytes to the window (P1). Set `input_at = now()` where keyboard bytes are sent (`pump_keyboard`, holder.rs:446) and in `View::input` (view.rs:217). Also bump `dirty` where `fg` prog/cwd changes (`probe_fg`) and where a rename is applied.
- [ ] **Step 4: Run** the same tests — PASS; then `cargo test -p rapp-term` — all PASS (`off_means_byte_for_byte_today` must stay green: output bytes unchanged).
- [ ] **Step 5: Commit** `feat(term): holder reads OSC 7502 shell reports and keeps input time`.

### Task 2: Shell integration files + starting shells through them

**Files:**
- Create: `rust/term/src/pty/hook/zshenv` (installed as `shell/zsh/.zshenv`), `rust/term/src/pty/hook/rapp.zsh`, `rust/term/src/pty/hook/rapp.bash`, `rust/term/src/pty/hook/rapp.fish`
- Modify: `rust/term/src/pty/shell.rs` (install + launch), `rust/term/src/pty/local.rs` (`ensure_dirs` adds `saved/`, `shell/`), `rust/term/src/config.rs` (`shell_hook`), `rust/term/src/main.rs` (`RunOpts.shell_hook`), `rust/term/src/pty/holder.rs` (apply `Launch` to the `CommandBuilder`)
- Test: `rust/term/tests/shell_hook.rs` (real shells; each test skips with a printed note when that shell is not installed)

**Interfaces:**
- Consumes: `Report`, `parse_report` (Task 1).
- Produces:
  - `pub const HOOK_V: u32 = 1;` and `pub fn install(term_dir: &Path) -> std::io::Result<PathBuf>` — writes the four files under `<term_dir>/shell/` when `shell/.v` is not `HOOK_V`, returns the `shell/` dir.
  - `pub struct Launch { pub args: Vec<String>, pub set: Vec<(String, String)>, pub unset: Vec<String> }`
  - `pub fn launch(command: &[String], hook_dir: &Path, env_zdotdir: Option<&str>, restore: Option<&Restore>) -> Option<Launch>` — `command` is `[shell, "-l"]` or `[shell]`; `None` (no hook) for any other shell basename or extra args. `pub struct Restore { pub venv: Option<String>, pub conda: Option<String> }` (filled in Task 4; `None` here).
  - `TermConfig.shell_hook: bool`, JSON `"shellHook"`, default `true`; `RunOpts.shell_hook: bool`.

How each shell is started (the `Launch` per basename):

| shell | args | env |
|---|---|---|
| `zsh` | unchanged (`-l`) | `ZDOTDIR=<hook>/zsh`; `RAPP_ZDOTDIR=<old>` only when `ZDOTDIR` was set |
| `bash` | `--init-file <hook>/rapp.bash -i` (drop `-l`; bash refuses `--init-file` for login shells) | `RAPP_BASH_LOGIN=1` |
| `fish` | `-l -C "source '<hook>/rapp.fish'"` (path quoted for fish) | — |
| restore (Task 4) | — | `RAPP_RESTORE_VENV`, `RAPP_RESTORE_CONDA` when present |

What the files do (bodies are the implementer's; these are the rules):
- `zshenv`: if `RAPP_ZDOTDIR` is set, `ZDOTDIR=$RAPP_ZDOTDIR`, else `unset ZDOTDIR`; `unset RAPP_ZDOTDIR`; source `${ZDOTDIR:-$HOME}/.zshenv` if readable; if `[[ -o interactive ]]`, source `rapp.zsh` (path from `${${(%):-%x}:A:h}/../rapp.zsh`).
- `rapp.zsh`: defines `_rapp_init` added with `add-zsh-hook precmd`; on its first call it removes itself, does the restore activation (below), then adds `_rapp_precmd` (precmd) and `_rapp_preexec` (preexec) with `add-zsh-hook`. `_rapp_precmd` saves `$?` first and returns it; emits `state` only when `$PWD/$VIRTUAL_ENV/$CONDA_PREFIX/$CONDA_DEFAULT_ENV` differ from last time (P3), then `printf '\e]133;A\a'`. `_rapp_preexec` emits `run` with `$1`. Every body runs with errors silenced (`{ … } 2>/dev/null`) and never `exit`s.
- `rapp.bash`: when `RAPP_BASH_LOGIN=1`, unset it and source like a login shell: `/etc/profile`, then the first readable of `~/.bash_profile`, `~/.bash_login`, `~/.profile`. Then append our function to `PROMPT_COMMAND` (string form, works on 3.2 and 5.x), keeping the user's. `run` via a DEBUG trap **only if `trap -p DEBUG` is empty**: fires once per prompt (a flag set at the end of our prompt function), reports `history 1` with the number stripped, falling back to `$BASH_COMMAND` when history is off.
- `rapp.fish`: `--on-event fish_prompt` function (state + 133;A), `--on-event fish_preexec` function (`run` with `$argv[1]`), restore activation using `activate.fish`.
- Restore activation (all three): if `RAPP_RESTORE_CONDA` set: if the dir exists and `conda` is a command/function, `conda activate "$RAPP_RESTORE_CONDA"`, else print `rApp：上次的环境 <路径> 已不在，没有激活`. Then same for `RAPP_RESTORE_VENV` with `<venv>/bin/activate` (fish: `activate.fish`). Conda first, venv second. Unset both variables.
- base64 in scripts: `printf %s "$v" | base64 | tr -d '\n'` (macOS and GNU).

- [ ] **Step 1: Write failing tests.** Unit (in `shell.rs`): `zsh_launch_sets_zdotdir_and_keeps_old`, `zsh_launch_without_old_zdotdir_sets_no_rapp_zdotdir`, `bash_launch_drops_login_flag`, `fish_launch_quotes_path`, `other_shells_and_commands_get_no_hook` (`sh -l`, `nu`, `["zsh","-c","x"]`, `["claude"]`), `install_rewrites_on_version_change`, `config_shell_hook_defaults_on` (in `config.rs`, plus `{"shellHook":false}` parses off).
  Integration `tests/shell_hook.rs` — run the shell under a pty (use `portable_pty` as `tests/pty.rs` does) with `HOME` pointed at a temp dir holding a known `.zshrc`/`.bash_profile`/`config.fish`, collect output, parse with `rapp_term::pty::shell::parse_report`:
  - `zsh_reports_cwd_and_venv`: type `cd /tmp && VIRTUAL_ENV=/x/venv true\r`… (simpler: `export VIRTUAL_ENV=/x/v; cd /tmp\r`) → a later `state` has `cwd=/tmp` (or `/private/tmp`) and `venv=/x/v`.
  - `zsh_reports_run_then_prompt`: `sleep 0.2\r` → `Run("sleep 0.2")` then a `133;A`.
  - `zsh_nested_sees_user_zdotdir`: with `ZDOTDIR` unset at launch, `echo "[${ZDOTDIR-unset}][${RAPP_ZDOTDIR-unset}]"\r` prints `[unset][unset]`; with `ZDOTDIR=/z` prints `[/z][unset]`.
  - `zsh_keeps_user_precmd_and_status`: user `.zshrc` defines `precmd() { print -n "U$?" }`; `false\r` → output has `U1` and our 7502/133 sequence too.
  - `bash_reports_whole_line`: `echo a | cat\r` → `Run("echo a | cat")` (spec §8: confirm on `/bin/bash` 3.2 and, if present, `/opt/homebrew/bin/bash`).
  - `bash_existing_debug_trap_left_alone`: user `.bash_profile` sets `trap 'X=1' DEBUG` → `trap -p DEBUG` after start still shows `X=1`; `state` reports still arrive.
  - `bash_reads_login_files`: `.bash_profile` exports `MARK=1` → `echo $MARK` prints `1`.
  - `fish_reports_state_and_run`.
  - `restore_missing_venv_prints_once`: launch with `Restore{venv: Some("/nope")}` → the line `rApp：上次的环境 /nope 已不在，没有激活` appears exactly once; `echo ${RAPP_RESTORE_VENV-gone}` prints `gone`.
  - `restore_activates_venv`: make `<tmp>/v/bin/activate` that exports `VIRTUAL_ENV=<tmp>/v` → first `state` has that venv.
- [ ] **Step 2: Run** `cargo test -p rapp-term --test shell_hook` and the unit tests — FAIL.
- [ ] **Step 3: Implement** the four files, `install`, `launch`, config field, `ensure_dirs` additions; in `holder::run`, when `opts.shell_hook`, call `install(&opts.dir)` and apply `launch(...)` to the `CommandBuilder` (`cmd.args`, `cmd.env`, `cmd.env_remove`); an install error just means no hook.
- [ ] **Step 4: Run** the tests — PASS; then the whole `cargo test -p rapp-term` — PASS.
- [ ] **Step 5: Commit** `feat(term): zsh/bash/fish shell integration reports dir, venv and command`.

### Task 3: Snapshot file — contents, secret filter, write, delete, list, prune

**Files:**
- Create: `rust/term/src/pty/saved.rs`
- Modify: `rust/term/src/pty/mod.rs` (`pub mod saved;`)
- Test: in-module tests of `saved.rs`

**Interfaces:**
- Consumes: `ShellState` (Task 1).
- Produces:
  - `#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)] pub struct Snapshot { pub v: u32 /* 1 */, pub key: String, pub name: String, pub named: bool, pub shell: String, pub cwd: Option<String>, pub venv: Option<String>, pub conda: Option<String>, pub conda_name: Option<String>, pub cmd: Option<String>, pub prog: Option<String>, pub started: u64, pub saved: u64 }` (all `Option`s `skip_serializing_if = "Option::is_none"`, `#[serde(default)]` on everything but `v`/`key`).
  - `pub fn clean_cmd(raw: &str) -> (Option<String>, Option<String>)` → `(cmd, prog)`: strip leading assignments, then apply every rule of the Global Constraints; `prog` is the basename of the first remaining word (none for an empty line).
  - `pub fn path(term_dir: &Path, key: &str) -> PathBuf` (`saved/<key>.json`); `pub fn write(term_dir: &Path, s: &Snapshot) -> std::io::Result<()>` (temp file 0600 in `saved/`, rename); `pub fn read(term_dir: &Path, key: &str) -> Option<Snapshot>` (bad/missing → None); `pub fn remove(term_dir: &Path, key: &str)`.
  - `pub fn restorable(term_dir: &Path, live: &HashSet<String>, now: u64) -> Vec<Snapshot>` — reads `saved/*.json` whose key is not live, deletes those with `saved` older than 30 days and, of the non-live ones, all beyond the 50 newest by `saved`; returns the rest sorted by `started` ascending. Files whose name is not a 16-hex key or that do not parse are deleted.
  - `pub fn boot_time() -> Option<u64>` — macOS `sysctl kern.boottime` (`libc::sysctlbyname`), Linux `btime` from `/proc/stat`.
  - `pub fn key_ok(key: &str) -> bool` — 16 lowercase hex (used by holder and serve to refuse paths like `../x`).

- [ ] **Step 1: Write failing tests:**
  - `clean_cmd_strips_assignments`: `"KEY=xx FOO='a b' claude --model x"` → `(Some("claude --model x"), Some("claude"))`.
  - `clean_cmd_drops_and_keeps_prog` table — each of these gives `(None, Some(prog))`: `"claude --api-key x"`, `"tool --token=x"`, `"mysql -u r -p"`, `"psql -p 5432 -U x"`(—`-p` after psql counts, by the rule), `"curl -H 'Authorization: Bearer abc' u"`, `"git clone https://u:p@h/r"`, `"x sk-abc"`, `"x ghp_abc"`, `"x github_pat_1"`, `"x xoxb-1"`, `"x AKIAABC"`, `"x eyJhbGci"`, `"x " + "a".repeat(32)`, `"a\nb"`, `"a\x1bb"`, 1001-char line.
  - `clean_cmd_keeps_ordinary_lines`: `"npm run dev"`, `"python train.py --epochs 3"`, `"cd ~/git/x"`, a 31-char word.
  - `secrets_never_reach_disk`: build a `Snapshot` with `cmd` from `clean_cmd("KEY=s3cr3tvalue claude --api-key sk-zzz")`, `write`, read the file bytes: contain neither `s3cr3tvalue` nor `sk-`; file mode `0o600`, dir `0o700`.
  - `write_is_atomic_and_read_roundtrips`; `read_bad_json_is_none`.
  - `restorable_excludes_live_keys`, `prune_over_30_days`, `prune_keeps_50_newest`, `prune_never_touches_live_keys` (a live key's 40-day-old file survives), `restorable_sorted_by_started`, `junk_files_removed` (`saved/notakey.json`, `saved/<key>.json` with `{`).
  - `key_ok_rejects_paths`: `"../../etc"`, `"ABCDEF0123456789"`, 15 chars → false.
- [ ] **Step 2: Run** `cargo test -p rapp-term saved::` — FAIL.
- [ ] **Step 3: Implement** `saved.rs`. The secret table is one `const` list of rules checked word by word (`shell_words`-style split is not needed: split on whitespace, trim quotes `'"` around words, check `=` both halves for option names).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(term): terminal snapshots with a secret filter, pruning and boot time`.

### Task 4: Holder keeps its snapshot, deletes it when the user ends it, and `--restore <key>`

**Files:**
- Modify: `rust/term/src/pty/holder.rs` (snapshot task; `End` split; restore start + prefill), `rust/term/src/main.rs` (`--restore` option, usage line), `rust/term/src/pty/shell.rs` (`Restore` filled), `rust/term/src/pty/fg.rs` (fallback B: argv/env of the foreground process)
- Create: `rust/term/src/pty/resume.rs` (prefill rewrite table)
- Test: in-module tests; `rust/term/tests/pty.rs` (end-to-end holder)

**Interfaces:**
- Consumes: `Snapshot`, `saved::{write, read, remove, key_ok, clean_cmd}` (Task 3); `ShellState`, `Shared.dirty`, `launch(.., restore)` (Tasks 1–2).
- Produces:
  - `RunOpts.restore: Option<String>`; CLI `rapp-term run … [--restore KEY] …` (refused unless `key_ok`).
  - `enum End { Exited(i32), Ended, Signal(i32) }` — `Ended` is `shared.end`; it stops the child like `Signal(SIGHUP)` does today, then removes the snapshot. `Exited` removes it too. `Signal` keeps it.
  - `pub fn snapshot_of(shared: &Shared, shell_path: &str, started: u64, now: u64) -> Snapshot` — cwd: hooked → `shell.cwd`, else `fg.cwd`; cmd/prog: `pending` (kept as is, already clean) else `clean_cmd(running)` else fallback B (fg not the shell → `clean_cmd(argv.join(" "))`); venv/conda: hooked → shell state, else fallback B env of the foreground process when it is not the shell, else none.
  - `pub fn prefill(cmd: &str) -> String` in `resume.rs` — a per-program table `{prog, resume, value_options}`. Words after the program: a word starting with `-` is kept; a word right after a listed value option (written without `=`) is kept as its value; any other word is a prompt and dropped. Then `claude`: append ` --continue` unless `-c`, `--continue`, `-r` or `--resume` is present (value options `--model`, `--permission-mode`, `--add-dir`, `--settings`, `--mcp-config`, `--append-system-prompt`, `--allowedTools`, `--disallowedTools`, `--agent`, `--fallback-model`); `codex`: becomes `codex resume --last` + the kept options (value options `-m`, `--model`, `-c`, `--config`, `-p`, `--profile`, `-s`, `--sandbox`, `-a`, `--ask-for-approval`, `-C`, `--cd`, `-i`, `--image`); a codex line already starting `codex resume` is unchanged; any other program unchanged.
  - `fg::launch_info(pid: i32) -> Option<(Vec<String>, Vec<(String, String)>)>` — argv and only the env entries `VIRTUAL_ENV`, `CONDA_PREFIX`, `CONDA_DEFAULT_ENV` (macOS `KERN_PROCARGS2`, Linux `/proc/<pid>/cmdline` + `environ`).

Restore start, in order (spec §4.5): read `saved/<key>.json` (none → start as a normal new holder with a new key); if the key is already live in `local::scan` → new key; else `meta.key = key`, base name = snapshot name, `named` = snapshot `named` (still through `pick_name`); `shell.pending = snapshot.cmd` (prefill computed from it); `Restore { venv, conda }` passed to `launch`; after the first `Event::Prompt` or 2 s, `shared.input.send(prefill(cmd).into_bytes())` — no newline; `pending` stays until the first `run` report or the shell exits (Task 1's `apply(Run)` clears it). The snapshot task starts with the restored `started`.

Snapshot task: `tokio::spawn` that writes once at start, then loops on `dirty.subscribe().changed()`, and after each change waits until 2 s pass with no further change (`tokio::time::sleep` reset on change), builds `snapshot_of`, writes it only if it differs from the last written ignoring `saved`. On `End::Exited`/`End::Ended` the task is aborted before `saved::remove`.

- [ ] **Step 1: Write failing tests:**
  - `resume.rs`: `claude_gets_continue` (`"claude --dangerously-skip-permissions"` → `"claude --dangerously-skip-permissions --continue"`), `claude_with_resume_untouched` (`"claude -r"`, `"claude --continue"`), `claude_prompt_dropped` (`"claude 'fix the bug'"` → `"claude --continue"`; `"claude --model opus 'x'"` → `"claude --model opus --continue"`), `codex_resumes_last` (`"codex -m o3 'hi'"` → `"codex resume --last -m o3"`), `others_unchanged` (`"npm run dev"`).
  - `holder.rs`: `ended_and_exited_remove_the_snapshot_signals_keep_it` — table over `End::{Exited(0), Ended, Signal(SIGHUP), Signal(SIGTERM)}` → removed/removed/kept/kept, via the function that finishes a run (extract `fn finish_snapshot(end: &End, dir: &Path, key: &str)`).
  - `snapshot_of_prefers_hook_state_over_fg`, `snapshot_of_pending_wins_until_run`, `snapshot_of_fallback_reads_foreground_argv` (fg not shell, stubbed `launch_info`), `snapshot_of_shell_idle_has_no_cmd`.
  - `tests/pty.rs` (real holder, `--dir` temp, zsh): `holder_writes_snapshot_with_cwd` (`cd /tmp\r`, wait ≤5 s for `saved/*.json` with `cwd` ending `/tmp`); `exit_removes_snapshot` (`exit\r`); `sighup_keeps_snapshot`; `restore_reuses_key_and_prefills_without_running` — write a snapshot `{key: K, name: "work", cmd: "echo RAN"}`, start `run --restore K`, assert status `key == K`, `name == "work"`, the screen (via a viewer or `Emu` text in status) shows `echo RAN` on the prompt line and the output never contains a line `RAN` alone within 3 s; `restore_unknown_key_starts_fresh`.
  - `main.rs`: `restore_option_parses_and_rejects_bad_keys`.
- [ ] **Step 2: Run** `cargo test -p rapp-term` — new tests FAIL.
- [ ] **Step 3: Implement** as above. Usage line becomes `rapp-term run [--name N] [--cwd DIR] [--dir DIR] [--ticket T] [--restore KEY] [-- COMMAND...]`.
- [ ] **Step 4: Run** `cargo test -p rapp-term` — PASS (run twice; `tests/pty.rs` is load-flaky, memory gotcha).
- [ ] **Step 5: Commit** `feat(term): holder keeps a snapshot and can start as a restored terminal`.

### Task 5: serve — `saved` in the host row, `restore`, `forget`, `from: "last"`

**Files:**
- Modify: `rust/term/src/serve.rs` (`Req`, `HostRow`, `hosts`, `open`, new `restore`/`forget`/`saved_local`), `rust/term/src/pty/launch.rs` (`command_file` gets `restore: Option<&str>`)
- Test: `serve.rs` tests, `rust/term/tests/serve.rs`

**Interfaces:**
- Consumes: `saved::{restorable, remove, boot_time, key_ok, Snapshot}` (Task 3); `Status.input` (Task 1); holder `--restore` (Task 4).
- Produces:
  - `Req::Restore { #[serde(default)] keys: Vec<String>, #[serde(default)] app: Option<String> }` (`"op":"restore"`; empty keys = all restorable) → reply `{"ok":true,"ids":[term ids in order]}`, or on the first failure `{"error":<words>,"ids":[opened so far]}`.
  - `Req::Forget { #[serde(default)] keys: Vec<String> }` (empty = all restorable) → `{"ok":true,"forgot":N}`.
  - `Req::Saved` (`"op":"saved"`, **local-only**: the service never forwards it from a peer, Task 6) → `{"ok":true,"saved":[{key,name,prog,cmd,cwd,saved,boot}]}` for the CLI's `--list`.
  - `#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)] pub struct SavedRow { pub key: String, pub name: String, #[serde(skip_serializing_if = "Option::is_none")] pub prog: Option<String>, pub saved: u64, pub boot: bool }`; `HostRow.saved: Vec<SavedRow>` (`#[serde(default, skip_serializing_if = "Vec::is_empty")]`).
  - `fn hosts(&self, live: &[Status]) -> Vec<HostRow>` (live keys excluded from `saved`; `boot = snapshot.saved < boot_time`, false when the boot time is unknown).
  - `launch::command_file(bin, dir, ticket, shell, cwd, restore: Option<&str>)` — `--restore <key>` before `--cwd`.

Rules:
- `from: Some("last")` in `open`: the live holder with the largest `input` (ties/absent → largest `activity`) is the source (cwd, tty; shell only when the request has none — already `shell.or(source.shell)`); no live holder → the newest restorable snapshot's `cwd` if `is_dir`, no tty, default shell; nothing → home. Any other non-id `from` → home, as today.
- `restore`: under the existing `opening` lock *per terminal* (so a 新建 can interleave but never two opens at once); re-read `restorable` right before each key and skip keys that became live (Review Focus 5); keys failing `key_ok` are skipped; order by `started`; each one: shell = snapshot shell if it is in `installed_shells` / executable, else default; cwd = snapshot cwd if `is_dir`; tty = the previous restored holder's tty (so they become tabs of one window; first: none); `app` = request app if it is a launcher, else the first launcher; wait for the holder like `open` does (`wait_for`); stop at the first error.
- `forget`: `saved::remove` each given restorable key (live keys refused silently).
- `restore`/`forget`/`saved` obey the same `self.config()` gate as `open` (terms off → the usual off error).

- [ ] **Step 1: Write failing tests** (`serve.rs` unit + `tests/serve.rs` with the fake launcher `launch_with` and `shells_with` hooks already used there):
  - `req_parses_restore_forget_saved` (`{"op":"restore"}` → empty keys, no app; `{"op":"restore","keys":["…"],"app":"Terminal"}`).
  - `host_row_saved_is_optional`: a `HostRow` with no saved serialises without `saved`; an old JSON without it deserialises.
  - `hosts_lists_restorable_without_cwd`: a snapshot with cwd `/secret/dir` → the serialised list JSON does not contain `secret`.
  - `boot_flag_from_boot_time` (inject boot time through a `ServeOpts.boot_with: Option<fn() -> Option<u64>>` hook, same pattern as `shells_with`).
  - `open_from_last_picks_most_recent_input`; `open_from_last_falls_back_to_newest_snapshot_cwd`; `open_from_last_with_nothing_opens_home`; `open_with_shell_and_from_uses_request_shell_and_source_cwd`.
  - `restore_opens_in_started_order_as_tabs` (fake launcher records command files: 2nd file has the 1st holder's tty; each has `--restore <key>`).
  - `restore_with_missing_cwd_and_shell` (no `--cwd`, default shell).
  - `restore_stops_at_first_failure` (fake launcher fails the 2nd → `error` + `ids` of the 1st only; the 3rd snapshot still on disk).
  - `restore_skips_keys_that_came_alive`.
  - `forget_removes_only_restorable`.
  - `command_file_with_restore` in `launch.rs`: `… run --dir … --ticket t --restore 0123456789abcdef --cwd … -- /bin/zsh -l`, quoted like the others.
- [ ] **Step 2: Run** `cargo test -p rapp-term serve` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cargo test -p rapp-term` — PASS.
- [ ] **Step 5: Commit** `feat(term): serve lists, restores and forgets saved terminals; open from the last one`.

### Task 6: Wire, service and hub — `restore_terms`, `forget_terms`

**Files:**
- Modify: `rust/net/src/msg.rs` (Op), `rust/service/src/term.rs` (`request`, `log_fields`, make `ask` `pub(crate)`), `rust/service/src/peer.rs:221` (allow-list), `rust/service/src/relay_link.rs:369` (session count), `rust/hub/src/terms.rs` (`command`, `event`), `rust/hub/src/lib.rs:433` (cmd list), `rust/hub/src/link.rs:127-138` (`reply_wait`, `repeatable`), testkit fixtures if a test lists every op
- Test: the files' own test modules; `rust/testkit`

**Interfaces:**
- Consumes: serve's `restore`/`forget` replies (Task 5).
- Produces:
  - `Op::RestoreTerms { #[serde(default)] keys: Vec<String>, #[serde(default, skip_serializing_if = "Option::is_none")] app: Option<String> }` → `"op":"restore_terms"`; `Op::ForgetTerms { #[serde(default)] keys: Vec<String> }` → `"op":"forget_terms"`.
  - service forwards them as serve's `{"op":"restore","keys","app"}` / `{"op":"forget","keys"}`; `log_fields`: `{"keys": n}` only; `open_term`'s `from` logged as `"last"` / `"term"` / absent.
  - hub cmds `restore_terms {id, keys, app}` → event `{"event":"terms_restored","id","terms":[ids]}`; `forget_terms {id, keys}` → `{"event":"terms_forgotten","id"}`. The hub does not refresh lists itself; the GUI asks for `terms` afterwards, as `endTerm` does.
  - `repeatable` false for `RestoreTerms` (it opens windows) — `ForgetTerms` stays repeatable; `reply_wait(RestoreTerms{keys})` = `OPEN_TERM_WAIT * keys.len().max(1)`.
  - `RestoreTerms` counts as a session in `relay_link.rs` like `OpenTerm`.

- [ ] **Step 1: Write failing tests:** `msg.rs` `restore_and_forget_terms_roundtrip` (`{"op":"restore_terms","keys":["k"],"app":"Terminal"}` ⇄ value; `{"op":"restore_terms"}` → empty keys, no app); `service/src/term.rs` `restore_terms_forwarded_and_logged_without_keys_values` (log has `keys: 1`, no key string), `open_term_logs_from_kind`; `link.rs` `restore_terms_is_not_repeatable_and_waits_per_key`; `peer.rs`/testkit: a peer `restore_terms` request reaches serve (existing peer term tests show how); a peer `{"op":"saved"}` is `unknown op` (it is no `Op`).
- [ ] **Step 2: Run** `cargo test --workspace --no-fail-fast` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cargo test --workspace --no-fail-fast` and `cargo clippy --workspace --all-targets -- -D warnings` — PASS.
- [ ] **Step 5: Commit** `feat: restore_terms and forget_terms from the hub to the host's serve`.

### Task 7: CLI — `rapp term restore`

**Files:**
- Modify: `rust/cli/src/args.rs` (`Cmd::TermRestore`, usage), `rust/cli/src/main.rs` (dispatch), `rust/cli/src/say.rs` (list text), `rust/service/src/ipc.rs:56-86` (`term_saved`, `term_restore`, `term_forget`)
- Test: `args.rs`, `say.rs` tests; `service/src/ipc.rs` test if the module has them

**Interfaces:**
- Consumes: serve `saved`/`restore`/`forget` (Task 5) through `crate::term::ask`.
- Produces:
  - `Cmd::TermRestore { list: bool, forget: bool, picks: Vec<String> }`; usage lines `rapp term restore [名字或序号…]`, `rapp term restore --list`, `rapp term restore --forget`.
  - IPC: `{"cmd":"term_saved"}` → serve `saved` reply; `{"cmd":"term_restore","keys":[…]}` → serve `restore` (no app: first launcher); `{"cmd":"term_forget"}` → serve `forget` all. Local IPC only.
  - `say::saved_table(r: &Value, now: u64) -> String` — columns `序号  名字  程序  多久以前  目录`; `prog` none → `—`; age words as in Global Constraints; empty → `没有可以恢复的终端`.

Picks: each pick is a 1-based number from `--list` order (by `started`) or an exact name; unknown pick → exit 2 with `没有这个终端：<pick>`; the CLI resolves picks to keys with a `term_saved` call first. Outcomes printed: `已恢复 N 个终端`; on error `恢复到第 N 个时停下了：<words>` and exit 1; `--forget` → `已清掉 N 个`.

- [ ] **Step 1: Write failing tests:** `args.rs` `term_restore_forms` (`term restore` → all; `--list`; `--forget`; `rapp train 2`; `--list x` → Err `多写了：x`; `term` alone → Err `要写 restore`; `--list --forget` → Err); `say.rs` `saved_table_shows_dirs_and_dashes`, `saved_table_empty`, `ages_in_chinese` (59 s → 刚才, 5 min → 5 分钟前, 2 h → 2 小时前, 3 d → 3 天前).
- [ ] **Step 2: Run** `cargo test -p rapp-cli` (crate name as in `rust/cli/Cargo.toml`) — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cargo test --workspace --no-fail-fast` — PASS.
- [ ] **Step 5: Commit** `feat(cli): rapp term restore`.

### Task 8: GUI — 新建 from the current/last terminal

**Files:**
- Modify: `gui/lib/ui/main_state.dart` (last viewed term per device; `newTermSource`; 新建 at ~2836 passes it), `gui/lib/ui/devices_tab.dart:506-513` (`_openShell` passes it)
- Test: `gui/test/ui/terms_entry_test.dart` or a new `gui/test/ui/new_term_from_test.dart`

**Interfaces:**
- Produces: `String newTermSource(String device)` on `MainState` — (1) the current stage session's term id when it is a text terminal of `device` that is still in `termLists[device]`; (2) else the last text terminal of `device` this run showed on stage and still listed (in-memory `Map<String, String> _lastTerm`, updated wherever the current session changes — `select`/the `current` setter path near `main_state.dart:1219-1240`); (3) else `'last'`.
- `openText(id, shell: …, from: newTermSource(id))` at both 新建 sites. ⌘T (`newTermFrom`) unchanged.

- [ ] **Step 1: Write failing tests:** `new_term_uses_current_stage_term`, `new_term_uses_last_viewed_when_stage_elsewhere`, `new_term_last_viewed_gone_sends_last`, `new_term_from_devices_tab_keeps_button_shell` (fake hub records `open_term` with `shell:/bin/bash` **and** `from`).
- [ ] **Step 2: Run** `cd gui && ~/development/flutter/bin/flutter test test/ui/new_term_from_test.dart` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test` (all) — PASS; `git checkout gui/pubspec.lock`.
- [ ] **Step 5: Commit** `feat(gui): 新建 opens in the current or last text terminal's directory`.

### Task 9: GUI — 恢复 button, dialog and devices row

**Files:**
- Modify: `gui/lib/hub_client.dart` (`TermHost.saved`, parse, `restoreTerms`, `forgetTerms`), `gui/lib/ui/main_state.dart` (`favoriteVerb`, `openFavorite`, `restoreSaved`, `forgetSaved`), `gui/lib/ui/overview.dart:347` (verb), `gui/lib/ui/devices_tab.dart` (row in the terminal group)
- Create: `gui/lib/ui/term_restore_dialog.dart`
- Test: `gui/test/hub_client_test.dart` (or where `_termList` is tested), `gui/test/ui/term_restore_test.dart`, `gui/test/ui/devices_tab_test.dart`, `gui/test/ui/overview_test.dart`

**Interfaces:**
- Consumes: `restore_terms`/`forget_terms` hub cmds and `terms_restored`/`terms_forgotten` events (Task 6); `HostRow.saved` (Task 5); `newTermSource` (Task 8).
- Produces:
  - `class TermSaved { const TermSaved(this.key, this.name, {this.prog, this.saved = 0, this.boot = false}); final String key, name; final String? prog; final int saved; final bool boot; }`; `TermHost.saved: List<TermSaved>` (default `const []`, rows without a string `key`/`name` dropped).
  - `HubClient.restoreTerms(String id, List<String> keys, {required String app}) → Future<List<String>>` (term ids); `HubClient.forgetTerms(String id, List<String> keys) → Future<void>`; both refresh `terms(id)` afterwards like `endTerm`.
  - `String favoriteVerb(AppRef f)` replacing `favoriteCreates`: 终端 entry → 「打开」 when `_restoresTerms` (0.15.33), else 「恢复」 when the device has no live text terminal and some `saved` row has `boot: true`, else 「新建」 when `_termsNewTargetOf` is `NewText`, else 「打开」; other tiles 「打开」.
  - `Future<void> showTermRestore(BuildContext, MainState, String device)` in the dialog file; `MainState.restoreSaved(String device, List<String> keys)` (opens via the hub, `openOrSwitch` each returned id with the first selected, hint `已恢复 N 个终端`; on error the hint is `newTermWords(e)` and the list refreshes) and `MainState.forgetSaved(String device, List<String> keys)`.
- Dialog: title 「恢复上次的终端 · <设备名>」; one checkbox row per saved, sorted as sent; boot rows checked, others not; row text `名字  程序或—  多久以前` (no directory); buttons in order 「全部清掉」「新建」「取消」「恢复所选」; 「恢复所选」 disabled with nothing checked; 「新建」 closes and runs the 新建 path (Task 8); 「全部清掉」 forgets every listed key.
- Devices row: in the terminal group, when `saved` is non-empty: 「上次没关的 N 个终端」 + button 「恢复…」 → the dialog.

- [ ] **Step 1: Write failing tests:** `term_list_parses_saved` (and an old host row → `saved` empty); `favorite_verb_orders_open_restore_new` (unopened live → 打开; none live + boot saved → 恢复; only non-boot saved → 新建); `dialog_checks_boot_rows_only`, `dialog_shows_no_directory` (no `cwd` in the model at all — assert the widget tree has no text containing `/`), `restore_selected_sends_keys_and_app`, `restore_failure_shows_hint_and_keeps_rest`, `forget_all_sends_every_key`, `devices_row_shows_count_and_opens_dialog`, `no_saved_no_row`.
- [ ] **Step 2: Run** `flutter test test/ui/term_restore_test.dart …` — FAIL.
- [ ] **Step 3: Implement.** Age words: put a shared `String agoWords(Duration)` (「刚才」/「N 分钟前」/「N 小时前」/「N 天前」) next to the dialog; `projects.dart:90` has a similar variant with 离开 — leave it.
- [ ] **Step 4: Run** `flutter test` — PASS; `flutter analyze` — no new issues; `git checkout gui/pubspec.lock`.
- [ ] **Step 5: Commit** `feat(gui): restore last session's text terminals`.

### Task 10: Terminal.app restore check, spec update, todo, gates

**Files:**
- Modify: `docs/superpowers/specs/2026-11-26-rapp-term-restore-design.md` (§4.2/§4.3/§4.5/§8 per Plan decisions P1–P7 and the findings below), `tasks/todo.md` (new section)

- [ ] **Step 1: Terminal.app check (spec §8, P7).** On this Mac: `defaults read com.apple.Terminal NSQuitAlwaysKeepsWindows` and System Settings ▸ 桌面与程序坞 ▸ 「退出应用时关闭窗口」; open a rapp text terminal via the built holder (`rapp-term run` from a `.command`), quit Terminal with ⌘Q, reopen it: does the tab come back, and as what (a plain shell in the same dir, or re-running the `.command`)? Write the observed result and the cheapest mitigation idea into spec §8; do not build the mitigation.
- [ ] **Step 2: Spec update.** Replace the changed 【我定的】 lines with P1–P6 (mark them 【计划里改的】).
- [ ] **Step 3: todo.md.** Add `## 文本终端恢复（规格：docs/superpowers/specs/2026-11-26-rapp-term-restore-design.md，计划：docs/superpowers/plans/2026-11-26-rapp-term-restore.md）` with unchecked items for spec §7 checks 1–12 (copied, renumbered in order) and the Task 1–9 deliverables checked.
- [ ] **Step 4: Gates.** `cd rust && PATH=$HOME/.cargo/bin:$PATH cargo test --workspace --no-fail-fast`; `cargo clippy --workspace --all-targets -- -D warnings`; `cd gui && ~/development/flutter/bin/flutter test && ~/development/flutter/bin/flutter analyze`; `git checkout gui/pubspec.lock`. All green; any load-flaky `tests/pty.rs` failure is re-run once and named in the hand-off if it repeats.
- [ ] **Step 5: Commit** `docs: term restore findings, plan decisions and real-machine checks`.
