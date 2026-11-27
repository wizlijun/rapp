#![cfg(unix)]
//! The shell hook in real shells: zsh, bash and fish started the way the holder starts them (`shell::install` +
//! `shell::launch`) in a pty of the test's own, with `HOME` a temporary directory holding known startup files. The
//! output is read back with the holder's own scanner. A shell that is not installed skips its tests with a note.

#[path = "common/pty.rs"]
mod pty;

use portable_pty::{native_pty_system, Child, CommandBuilder, PtySize};
use rapp_term::pty::ps::{Event, Scanner};
use rapp_term::pty::shell::{self, Report, Restore};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(15);
const MISSING: &str = "rApp：上次的环境";

/// The path of `name` when it is installed (a fixed path is taken as is), else a printed note and none.
fn shell_path(name: &str) -> Option<String> {
    let found = if name.starts_with('/') {
        Path::new(name).is_file().then(|| name.to_string())
    } else {
        ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
            .iter()
            .map(|d| format!("{d}/{name}"))
            .find(|p| Path::new(p).is_file())
    };
    if found.is_none() {
        eprintln!("note: {name} is not installed here; its test is skipped");
    }
    found
}

/// One shell in a pty, its output collected.
struct Sh {
    child: Box<dyn Child + Send + Sync>,
    writer: Box<dyn Write + Send>,
    out: Arc<Mutex<Vec<u8>>>,
    _master: Box<dyn portable_pty::MasterPty + Send>,
}

#[derive(Debug, Clone, PartialEq)]
enum Ev {
    R(Report),
    Prompt,
}

impl Sh {
    /// `command` started through the hook in `hook_root` (its `shell/` installed there), with `home` as `HOME`.
    fn start(command: &[&str], hook_root: &Path, home: &Path, zdotdir: Option<&str>, restore: Option<&Restore>) -> Sh {
        let hook = shell::install(hook_root).unwrap();
        let command: Vec<String> = command.iter().map(|s| s.to_string()).collect();
        let l = shell::launch(&command, &hook, zdotdir, restore).expect("a hooked shell");
        static OPEN: Mutex<()> = Mutex::new(());
        let pair = {
            let _one = OPEN.lock().unwrap_or_else(|e| e.into_inner());
            native_pty_system().openpty(PtySize { rows: 30, cols: 200, pixel_width: 0, pixel_height: 0 }).unwrap()
        };
        let mut cmd = CommandBuilder::new(&command[0]);
        cmd.args(&l.args);
        cmd.env_clear();
        cmd.env("HOME", home);
        cmd.env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
        cmd.env("TERM", "xterm-256color");
        cmd.env("LANG", "en_US.UTF-8");
        // As in Terminal.app: macOS's /etc/bashrc and /etc/zshrc then add prompt hooks of their own.
        cmd.env("TERM_PROGRAM", "Apple_Terminal");
        cmd.env("TERM_SESSION_ID", "w0t0p0:ABC");
        cmd.env("USER", std::env::var("USER").unwrap_or_else(|_| "u".into()));
        for (k, v) in &l.set {
            cmd.env(k, v);
        }
        for k in &l.unset {
            cmd.env_remove(k);
        }
        cmd.cwd(home);
        let child = pair.slave.spawn_command(cmd).unwrap();
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().unwrap();
        let writer = pair.master.take_writer().unwrap();
        let out = Arc::new(Mutex::new(Vec::new()));
        let sink = out.clone();
        std::thread::spawn(move || {
            let mut b = [0u8; 8192];
            loop {
                match reader.read(&mut b) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => sink.lock().unwrap().extend_from_slice(&b[..n]),
                }
            }
        });
        Sh { child, writer, out, _master: pair.master }
    }

    fn output(&self) -> String {
        String::from_utf8_lossy(&self.out.lock().unwrap()).into_owned()
    }

    fn events(&self) -> Vec<Ev> {
        let mut sc = Scanner::default();
        let mut got = Vec::new();
        sc.feed(&self.out.lock().unwrap(), |e| match e {
            Event::Shell(r) => got.push(Ev::R(r)),
            Event::Prompt => got.push(Ev::Prompt),
            _ => {}
        });
        got
    }

    /// Waits until `f` holds for the events so far.
    fn wait(&self, what: &str, f: impl Fn(&[Ev]) -> bool) -> Vec<Ev> {
        let end = Instant::now() + WAIT;
        loop {
            let ev = self.events();
            if f(&ev) {
                return ev;
            }
            assert!(Instant::now() < end, "never saw {what}: {ev:?}\noutput: {:?}", self.output());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The output without its OSC sequences: what the user sees. Counting in it is safe, where the raw output's
    /// `cwd=<base64>` could hold the very text counted (a home path that encodes to `…U1…`).
    fn visible(&self) -> String {
        strip_osc(&self.output())
    }

    /// Waits until the visible output shows `text`; that output.
    fn wait_output(&self, text: &str) -> String {
        let end = Instant::now() + WAIT;
        loop {
            let o = self.visible();
            if o.contains(text) {
                return o;
            }
            assert!(Instant::now() < end, "never saw {text:?}: {o:?}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn prompts(&self) -> usize {
        self.events().iter().filter(|e| **e == Ev::Prompt).count()
    }

    /// Waits for the `n`th prompt.
    fn wait_prompt(&self, n: usize) {
        self.wait(&format!("prompt {n}"), |ev| ev.iter().filter(|e| **e == Ev::Prompt).count() >= n);
    }

    /// Types `line` and a return at the next prompt, then waits for the prompt after it.
    fn run(&mut self, line: &str) {
        let n = self.prompts().max(1);
        self.wait_prompt(n);
        self.writer.write_all(line.as_bytes()).unwrap();
        self.writer.write_all(b"\r").unwrap();
        self.writer.flush().unwrap();
        self.wait_prompt(n + 1);
    }
}

impl Drop for Sh {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn states(ev: &[Ev]) -> Vec<(Option<String>, Option<String>)> {
    ev.iter()
        .filter_map(|e| match e {
            Ev::R(Report::State { cwd, venv, .. }) => Some((cwd.clone(), venv.clone())),
            _ => None,
        })
        .collect()
}

fn runs(ev: &[Ev]) -> Vec<String> {
    ev.iter()
        .filter_map(|e| match e {
            Ev::R(Report::Run(c)) => Some(c.clone()),
            _ => None,
        })
        .collect()
}

/// A home with these files in it.
/// `s` without its OSC sequences (`ESC ]` up to a BEL or `ESC \\`); an unfinished one is dropped to the end.
fn strip_osc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(at) = rest.find("\x1b]") {
        out.push_str(&rest[..at]);
        let body = &rest[at + 2..];
        let end = [body.find('\x07').map(|i| i + 1), body.find("\x1b\\").map(|i| i + 2)].into_iter().flatten().min();
        rest = end.map_or("", |e| &body[e..]);
    }
    out.push_str(rest);
    out
}

#[test]
fn strip_osc_keeps_only_what_shows() {
    let raw = "a\x1b]7502;state;cwd=xU1x\x07b\x1b]7;file://h/U1\x1b\\c\x1b]133;A";
    assert_eq!(strip_osc(raw), "abc");
    assert_eq!(strip_osc("plain U1"), "plain U1");
}

fn home(files: &[(&str, &str)]) -> tempfile::TempDir {
    let d = tempfile::tempdir().unwrap();
    for (name, body) in files {
        let p = d.path().join(name);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, body).unwrap();
    }
    d
}

fn is_tmp(cwd: &Option<String>) -> bool {
    matches!(cwd.as_deref(), Some("/tmp" | "/private/tmp"))
}

#[test]
fn zsh_reports_cwd_and_venv() {
    let Some(zsh) = shell_path("zsh") else { return };
    let (h, root) = (home(&[(".zshrc", "PS1='%# '\n")]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&zsh, "-l"], root.path(), h.path(), None, None);
    let first = sh.wait("the first state", |ev| !states(ev).is_empty());
    let home_dir = h.path().canonicalize().unwrap();
    let (cwd, venv) = states(&first)[0].clone();
    assert_eq!(cwd.map(|c| Path::new(&c).canonicalize().unwrap()), Some(home_dir));
    assert_eq!(venv, None);
    sh.run("export VIRTUAL_ENV=/x/v; cd /tmp");
    let ev = sh.wait("the new state", |ev| states(ev).iter().any(|(c, v)| is_tmp(c) && v.as_deref() == Some("/x/v")));
    // Only changes are reported: a command that changes nothing brings a prompt and no state.
    let before = states(&ev).len();
    sh.run("true");
    assert_eq!(states(&sh.events()).len(), before, "{:?}", sh.events());
}

#[test]
fn zsh_reports_run_then_prompt() {
    let Some(zsh) = shell_path("zsh") else { return };
    let (h, root) = (home(&[(".zshrc", "PS1='%# '\n")]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&zsh, "-l"], root.path(), h.path(), None, None);
    sh.run("sleep 0.2");
    let ev = sh.events();
    let at = ev.iter().position(|e| *e == Ev::R(Report::Run("sleep 0.2".into()))).unwrap_or_else(|| panic!("{ev:?}"));
    assert!(ev[at..].contains(&Ev::Prompt), "{ev:?}");
}

#[test]
fn zsh_nested_sees_user_zdotdir() {
    let Some(zsh) = shell_path("zsh") else { return };
    let line = r#"echo "[${ZDOTDIR-unset}][${RAPP_ZDOTDIR-unset}]""#;
    let (h, root) = (home(&[(".zshrc", "PS1='%# '\nMARK=home\n"), ("z/.zshrc", "PS1='%# '\nMARK=z\n")]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&zsh, "-l"], root.path(), h.path(), None, None);
    sh.run(line);
    sh.wait_output("[unset][unset]");
    sh.run("echo M=$MARK");
    sh.wait_output("M=home");

    let z = h.path().join("z");
    let z = z.to_str().unwrap();
    let mut sh = Sh::start(&[&zsh, "-l"], root.path(), h.path(), Some(z), None);
    sh.run(line);
    sh.wait_output(&format!("[{z}][unset]"));
    // The user's own ZDOTDIR is where zsh read the .zshrc from.
    sh.run("echo M=$MARK");
    sh.wait_output("M=z");
    // A zsh started inside sees no trace of the hook.
    sh.run(r#"zsh -c 'echo "N[${RAPP_ZDOTDIR-unset}][$+functions[_rapp_precmd]]"'"#);
    sh.wait_output("N[unset][0]");
}

#[test]
fn zsh_keeps_user_precmd_and_status() {
    let Some(zsh) = shell_path("zsh") else { return };
    // A precmd function, a hook added the oh-my-zsh way, and the status in the prompt itself.
    let rc = "PS1='S%?%# '\nprecmd() { print -n \"U$?\" }\nautoload -Uz add-zsh-hook\n_u() { print -n \"H$?\" }\nadd-zsh-hook precmd _u\n";
    let (h, root) = (home(&[(".zshrc", rc)]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&zsh, "-l"], root.path(), h.path(), None, None);
    sh.run("false");
    sh.wait_output("U1");
    sh.wait_output("H1");
    sh.wait_output("S1");
    sh.run("false");
    // Counted in what shows (a cwd's base64 may hold "U1"), once both hooks of the second prompt printed: ours may
    // mark the prompt before theirs runs.
    let counts = |o: &str| (o.matches("U1").count(), o.matches("H1").count());
    let end = Instant::now() + WAIT;
    while counts(&sh.visible()) < (2, 2) {
        assert!(Instant::now() < end, "{:?}", sh.output());
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(200));
    let out = sh.visible();
    assert_eq!(counts(&out), (2, 2), "{out:?}");
    // Ours is still there beside theirs, on later prompts too.
    sh.run("cd /");
    let ev = sh.wait("state for /", |ev| states(ev).iter().any(|(c, _)| c.as_deref() == Some("/")));
    assert!(ev.iter().filter(|e| **e == Ev::Prompt).count() >= 3, "{ev:?}");
    assert!(runs(&ev).contains(&"false".to_string()), "{ev:?}");
}

fn bash_shells() -> Vec<String> {
    ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"].into_iter().filter_map(shell_path).collect()
}

#[test]
fn bash_reports_whole_line() {
    for bash in bash_shells() {
        let (h, root) = (home(&[(".bash_profile", "PS1='$ '\n")]), tempfile::tempdir().unwrap());
        let mut sh = Sh::start(&[&bash, "-l"], root.path(), h.path(), None, None);
        sh.run("echo a | cat");
        sh.run("cd /tmp");
        // An empty line runs nothing: no run report for it.
        sh.run("");
        let ev = sh.wait("state for /tmp", |ev| states(ev).iter().any(|(c, _)| is_tmp(c)));
        assert_eq!(runs(&ev), ["echo a | cat", "cd /tmp"], "{bash}: {ev:?}");
        let at = ev.iter().position(|e| *e == Ev::R(Report::Run("echo a | cat".into()))).unwrap();
        assert!(ev[at..].contains(&Ev::Prompt), "{bash}: {ev:?}");
    }
}

#[test]
fn bash_never_reports_a_line_kept_out_of_history() {
    for bash in bash_shells() {
        // A leading space (or a HISTIGNORE pattern) keeps the line out of the history, so it is a secret: no run
        // report at all.
        let cases = [
            ("HISTCONTROL=ignorespace", " echo secret"),
            ("HISTCONTROL=ignoreboth", " echo secret"),
            ("HISTCONTROL=erasedups:ignorespace", " echo secret"),
            ("HISTIGNORE='*secret*'", "echo secret"),
        ];
        for (ctl, secret) in cases {
            let rc = format!("PS1='$ '\n{ctl}\n");
            let (h, root) = (home(&[(".bash_profile", rc.as_str())]), tempfile::tempdir().unwrap());
            let mut sh = Sh::start(&[&bash, "-l"], root.path(), h.path(), None, None);
            sh.run("echo a | cat");
            sh.run(secret);
            sh.run("echo ok");
            let ev = sh.events();
            assert_eq!(runs(&ev), ["echo a | cat", "echo ok"], "{bash} {ctl}: {ev:?}");
        }
    }
}

#[test]
fn zsh_never_reports_a_line_kept_out_of_history() {
    let Some(zsh) = shell_path("zsh") else { return };
    let (h, root) = (home(&[(".zshrc", "PS1='%# '\nsetopt HIST_IGNORE_SPACE\n")]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&zsh, "-l"], root.path(), h.path(), None, None);
    sh.run(" echo secret");
    sh.run("echo ok");
    let ev = sh.events();
    assert_eq!(runs(&ev), ["echo ok"], "{ev:?}");
    // Without the option the line goes into the history, and so into the report.
    let (h, root) = (home(&[(".zshrc", "PS1='%# '\n")]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&zsh, "-l"], root.path(), h.path(), None, None);
    sh.run(" echo spaced");
    let ev = sh.events();
    assert_eq!(runs(&ev), [" echo spaced"], "{ev:?}");
}

#[test]
fn fish_never_reports_a_line_starting_with_a_space() {
    let Some(fish) = shell_path("fish") else { return };
    let (h, root) = (home(&[(".config/fish/config.fish", "function fish_prompt; echo -n '> '; end\n")]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&fish, "-l"], root.path(), h.path(), None, None);
    sh.run(" echo secret");
    sh.run("echo ok");
    let ev = sh.events();
    assert_eq!(runs(&ev), ["echo ok"], "{ev:?}");
}

#[test]
fn bash_existing_debug_trap_left_alone() {
    for bash in bash_shells() {
        let (h, root) = (home(&[(".bash_profile", "PS1='$ '\ntrap 'X=1' DEBUG\n")]), tempfile::tempdir().unwrap());
        let mut sh = Sh::start(&[&bash, "-l"], root.path(), h.path(), None, None);
        sh.run("trap -p DEBUG");
        sh.wait_output("trap -- 'X=1' DEBUG");
        sh.run("cd /tmp");
        let ev = sh.wait("state for /tmp", |ev| states(ev).iter().any(|(c, _)| is_tmp(c)));
        assert!(runs(&ev).is_empty(), "{bash}: {ev:?}");
        // Each state report says no runs come, so the holder looks at the program in front instead.
        let norun: Vec<bool> = ev.iter().filter_map(|e| match e { Ev::R(Report::State { norun, .. }) => Some(*norun), _ => None }).collect();
        assert!(!norun.is_empty() && norun.iter().all(|n| *n), "{bash}: {ev:?}");
    }
}

#[test]
fn bash_hooked_says_nothing_of_norun() {
    for bash in bash_shells() {
        let (h, root) = (home(&[(".bash_profile", "PS1='$ '\n")]), tempfile::tempdir().unwrap());
        let mut sh = Sh::start(&[&bash, "-l"], root.path(), h.path(), None, None);
        sh.run("cd /tmp");
        let ev = sh.wait("state for /tmp", |ev| states(ev).iter().any(|(c, _)| is_tmp(c)));
        assert!(!ev.iter().any(|e| matches!(e, Ev::R(Report::State { norun: true, .. }))), "{bash}: {ev:?}");
        assert!(!sh.output().contains("norun="), "{bash}");
    }
}

#[test]
fn bash_reads_login_files() {
    for bash in bash_shells() {
        let (h, root) = (home(&[(".bash_profile", "PS1='$ '\nexport MARK=1\n"), (".bashrc", "RC=1\n")]), tempfile::tempdir().unwrap());
        let mut sh = Sh::start(&[&bash, "-l"], root.path(), h.path(), None, None);
        sh.run("echo M$MARK R$RC L${RAPP_BASH_LOGIN-gone}");
        // A login shell reads .bash_profile only, as bash itself does.
        sh.wait_output("M1 R Lgone");
    }
}

#[test]
fn bash_without_login_reads_bashrc() {
    for bash in bash_shells() {
        let (h, root) = (home(&[(".bash_profile", "export MARK=1\n"), (".bashrc", "PS1='$ '\nRC=1\n")]), tempfile::tempdir().unwrap());
        let mut sh = Sh::start(&[&bash], root.path(), h.path(), None, None);
        sh.run("echo M$MARK R$RC");
        sh.wait_output("M R1");
    }
}

#[test]
fn bash_keeps_user_prompt_command_and_status() {
    for bash in bash_shells() {
        let rc = "PS1='$ '\nPROMPT_COMMAND='printf \"U$?\"'\n";
        let (h, root) = (home(&[(".bash_profile", rc)]), tempfile::tempdir().unwrap());
        let mut sh = Sh::start(&[&bash, "-l"], root.path(), h.path(), None, None);
        sh.run("false");
        sh.wait_output("U1");
        let ev = sh.events();
        assert_eq!(runs(&ev), ["false"], "{bash}: {ev:?}");
    }
}

#[test]
fn fish_reports_state_and_run() {
    let Some(fish) = shell_path("fish") else { return };
    let (h, root) = (home(&[(".config/fish/config.fish", "function fish_prompt; echo -n '> '; end\n")]), tempfile::tempdir().unwrap());
    let mut sh = Sh::start(&[&fish, "-l"], root.path(), h.path(), None, None);
    sh.run("set -gx VIRTUAL_ENV /x/v; cd /tmp");
    let ev = sh.wait("the new state", |ev| states(ev).iter().any(|(c, v)| is_tmp(c) && v.as_deref() == Some("/x/v")));
    assert!(runs(&ev).contains(&"set -gx VIRTUAL_ENV /x/v; cd /tmp".to_string()), "{ev:?}");
}

/// The hooked shells installed here, each with the startup file that sets a plain prompt.
fn all_shells() -> Vec<(String, &'static str, &'static str)> {
    let mut v = Vec::new();
    if let Some(z) = shell_path("zsh") {
        v.push((z, ".zshrc", "PS1='%# '\n"));
    }
    for b in bash_shells() {
        v.push((b, ".bash_profile", "PS1='$ '\n"));
    }
    if let Some(f) = shell_path("fish") {
        v.push((f, ".config/fish/config.fish", "function fish_prompt; echo -n '> '; end\n"));
    }
    v
}

#[test]
fn restore_missing_venv_prints_once() {
    for (shell, rc, body) in all_shells() {
        let (h, root) = (home(&[(rc, body)]), tempfile::tempdir().unwrap());
        let r = Restore { venv: Some("/nope".into()), conda: Some("/nope2".into()) };
        let mut sh = Sh::start(&[&shell, "-l"], root.path(), h.path(), None, Some(&r));
        let gone = if shell.ends_with("fish") { "echo V(set -q RAPP_RESTORE_VENV; or echo gone)" } else { "echo V${RAPP_RESTORE_VENV-gone}" };
        sh.run(gone);
        let out = sh.wait_output("Vgone");
        let venv = "rApp：上次的环境 /nope 已不在，没有激活";
        let conda = "rApp：上次的环境 /nope2 已不在，没有激活";
        assert_eq!(out.matches(venv).count(), 1, "{shell}: {out:?}");
        assert_eq!(out.matches(conda).count(), 1, "{shell}: {out:?}");
        // Conda first, the venv second.
        assert!(out.find(conda) < out.find(venv), "{shell}: {out:?}");
        assert_eq!(out.matches(MISSING).count(), 2, "{shell}: {out:?}");
    }
}

#[test]
fn restore_activates_venv() {
    for (shell, rc, body) in all_shells() {
        let (h, root) = (home(&[(rc, body)]), tempfile::tempdir().unwrap());
        let v: PathBuf = h.path().join("v");
        let vs = v.to_str().unwrap().to_string();
        std::fs::create_dir_all(v.join("bin")).unwrap();
        std::fs::write(v.join("bin/activate"), format!("export VIRTUAL_ENV='{vs}'\n")).unwrap();
        std::fs::write(v.join("bin/activate.fish"), format!("set -gx VIRTUAL_ENV '{vs}'\n")).unwrap();
        let r = Restore { venv: Some(vs.clone()), conda: None };
        let sh = Sh::start(&[&shell, "-l"], root.path(), h.path(), None, Some(&r));
        let ev = sh.wait("the first state", |ev| !states(ev).is_empty());
        assert_eq!(states(&ev)[0].1.as_deref(), Some(vs.as_str()), "{shell}: {ev:?}");
        assert!(!sh.output().contains(MISSING), "{shell}: {:?}", sh.output());
    }
}

// The holder itself: `rapp-term run` starts the shell through the hook unless term.json turns it off.

fn holder_env(h: &Path) -> Vec<(&'static str, String)> {
    vec![("HOME", h.display().to_string()), ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin".into()), ("TERM", "xterm-256color".into())]
}

/// Taken out of the holder's environment, so a ZDOTDIR or hook variable set where the tests run changes nothing.
const SEALED: [&str; 5] = ["ZDOTDIR", "RAPP_ZDOTDIR", "RAPP_BASH_LOGIN", "RAPP_RESTORE_VENV", "RAPP_RESTORE_CONDA"];

#[test]
fn the_holder_starts_zsh_through_the_hook() {
    let Some(zsh) = shell_path("zsh") else { return };
    let d = pty::short_dir();
    let term = d.path().join("t");
    let h = home(&[(".zshrc", "PS1='%# '\n")]);
    let env = holder_env(h.path());
    let mut w = pty::Window::start_env(&term, &["--", &zsh, "-l"], &env, &SEALED);
    w.wait_output("\x1b]7502;state;cwd=");
    w.type_in(b"echo \"[${ZDOTDIR-unset}]\"\r");
    w.wait_output("[unset]");
    let shell_dir = term.join("shell");
    assert!(shell_dir.join("zsh/.zshenv").is_file() && term.join("saved").is_dir());
}

#[test]
fn shell_hook_off_starts_the_shell_plain() {
    let Some(zsh) = shell_path("zsh") else { return };
    let d = pty::short_dir();
    let term = d.path().join("t");
    std::fs::write(d.path().join("term.json"), r#"{"shellHook":false}"#).unwrap();
    let h = home(&[(".zshrc", "PS1='%# '\n")]);
    let env = holder_env(h.path());
    let mut w = pty::Window::start_env(&term, &["--", &zsh, "-l"], &env, &SEALED);
    w.type_in(b"echo D$((1+1))\r");
    w.wait_output("D2");
    assert!(!w.output().contains("\x1b]7502;"), "{:?}", w.output());
}
