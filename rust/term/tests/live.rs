mod common;

use rapp_term::runner::Runner;
use rapp_term::tmux::cmd;
use rapp_term::tmux::control::{Control, Event};
use rapp_term::tmux::Tmux;

#[tokio::test]
async fn version_is_at_least_3_2() {
    let Some(s) = common::Server::start() else { return };
    s.tmux().check().await.unwrap();
}

#[tokio::test]
async fn lists_sessions_with_awkward_names() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "我的 \"work\" it's", "-x", "100", "-y", "30"]);
    s.raw(&["new-session", "-d", "-s", "plain", "-x", "80", "-y", "24"]);
    let v = s.tmux().list().await.unwrap();
    assert_eq!(v.len(), 2);
    let w = v.iter().find(|p| p.session.contains("work")).unwrap();
    assert_eq!((w.session.as_str(), w.cols, w.rows), ("我的 \"work\" it's", 100, 30));
    assert!(w.session_id.starts_with('$') && w.pane.starts_with('%'));
}

#[tokio::test]
async fn no_server_is_an_empty_list_not_an_error() {
    if common::Server::start().is_none() {
        return;
    }
    let t = Tmux {
        runner: Runner::Local,
        bin: "tmux".into(),
        socket: Some(format!("rapp-term-test-none-{}", std::process::id())),
    };
    assert!(t.list().await.unwrap().is_empty());
}

#[tokio::test]
async fn captures_cjk_truecolor_and_cursor() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&[
        "new-session",
        "-d",
        "-s",
        "c",
        "-x",
        "100",
        "-y",
        "30",
        "printf '中文 日本語 \\033[38;2;255;100;0mtc\\033[0m \\033[1;4mbu\\033[0m\\n'; sleep 60",
    ]);
    common::settle().await;
    let pane = s.tmux().list().await.unwrap()[0].pane.clone();
    let sc = s.tmux().capture(&pane).await.unwrap();
    assert_eq!((sc.cols, sc.rows, sc.lines.len()), (100, 30, 30));
    assert!(sc.lines[0].starts_with("中文 日本語 \x1b[38;2;255;100;0mtc"));
    assert_eq!((sc.cx, sc.cy), (0, 1));
}

#[tokio::test]
async fn history_returns_lines_above_the_screen() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "h", "-x", "80", "-y", "5", "seq 1 40; sleep 60"]);
    common::settle().await;
    let pane = s.tmux().list().await.unwrap()[0].pane.clone();
    let h = s.tmux().history(&pane, 0, 10).await.unwrap();
    assert_eq!(h.len(), 10);
    assert_eq!(
        h.last().unwrap(),
        &s.tmux().capture(&pane).await.unwrap().lines[0].parse::<u32>().map(|n| (n - 1).to_string()).unwrap()
    );
}

#[tokio::test]
async fn history_ranges_are_empty_or_clamped() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "r", "-x", "80", "-y", "5", "seq 1 40; sleep 60"]);
    common::settle().await;
    let pane = s.tmux().list().await.unwrap()[0].pane.clone();
    let t = s.tmux();
    assert!(t.history(&pane, 0, 0).await.unwrap().is_empty());
    assert!(t.history(&pane, 5, 0).await.unwrap().is_empty());
    let size: u32 = s.raw(&["display-message", "-p", "-t", &pane, "#{history_size}"]).trim().parse().unwrap();
    assert_eq!(size, 36); // 40 numbers plus the cursor row, minus the 5 visible rows
    assert!(t.history(&pane, size, 10).await.unwrap().is_empty());
    assert!(t.history(&pane, size + 100, 10).await.unwrap().is_empty());
    let h = t.history(&pane, 31, 100).await.unwrap();
    assert_eq!(h.len(), 5);
    assert_eq!(h[0], "1");
    let all = t.history(&pane, 0, 1000).await.unwrap();
    assert_eq!((all.len(), all[0].as_str(), all[35].as_str()), (36, "1", "36"));
}

#[tokio::test]
async fn history_gives_at_most_2000_rows_at_a_time() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["set", "-g", "history-limit", "5000"]);
    s.raw(&["new-session", "-d", "-s", "l", "-x", "80", "-y", "5", "seq 1 3000; sleep 60"]);
    let pane = s.tmux().list().await.unwrap()[0].pane.clone();
    let end = std::time::Instant::now() + Duration::from_secs(5);
    while s.raw(&["display-message", "-p", "-t", &pane, "#{history_size}"]).trim().parse::<u32>().unwrap() < 2996 {
        assert!(std::time::Instant::now() < end, "the history did not fill");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let h = s.tmux().history(&pane, 0, u32::MAX).await.unwrap();
    // The 2000 rows nearest the screen: 2996 is the last one above it.
    assert_eq!((h.len(), h[0].as_str(), h[1999].as_str()), (2000, "997", "2996"));
}

#[tokio::test]
async fn control_runs_commands_and_reports_dirty_panes_in_any_window() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c", "-x", "100", "-y", "30"]);
    s.raw(&["new-window", "-d", "-t", "c"]);
    let panes = s.tmux().list().await.unwrap();
    let (ctl, _ev) = Control::attach(&s.tmux(), &panes[0].session_id).await.unwrap();
    let out = ctl.command(&cmd::meta(&panes[0].pane)).await.unwrap();
    assert_eq!(out.len(), 1);
    let e = ctl.command(&cmd::capture("%999")).await.unwrap_err(); // %error on the channel becomes Err
    assert!(e.to_string().contains("can't find pane"));
    s.raw(&["send-keys", "-t", &panes[1].pane, "echo hi", "Enter"]); // a pane in the second window
    let d = tokio::time::timeout(std::time::Duration::from_secs(2), ctl.dirty()).await.unwrap();
    assert!(d.contains(&panes[1].pane));
    ctl.detach().await;
}

#[tokio::test]
async fn control_reports_exit_when_the_session_is_killed() {
    // Review Focus 2
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c"]);
    let id = s.tmux().list().await.unwrap()[0].session_id.clone();
    let (_ctl, mut ev) = Control::attach(&s.tmux(), &id).await.unwrap();
    s.raw(&["kill-session", "-t", "c"]);
    let reason = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        loop {
            if let Some(Event::Exit(r)) = ev.recv().await {
                break r;
            }
        }
    })
    .await
    .unwrap();
    assert_ne!(reason, "connection closed"); // tmux's own %exit, not a dropped connection
}

#[tokio::test]
async fn control_client_does_not_resize_the_window() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c", "-x", "100", "-y", "30"]);
    let p = s.tmux().list().await.unwrap()[0].clone();
    let (ctl, _ev) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    let after = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((after.cols, after.rows), (p.cols, p.rows));
    ctl.detach().await;
}

#[tokio::test]
async fn control_replies_stay_with_their_commands_when_hooks_run() {
    // A hook makes tmux send its own blocks (flags 0) on the channel; they must not take a command's reply.
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "c"]);
    s.raw(&["set-hook", "-g", "after-display-message", "run-shell true"]);
    let id = s.tmux().list().await.unwrap()[0].session_id.clone();
    let (ctl, _ev) = Control::attach(&s.tmux(), &id).await.unwrap();
    for i in 0..20 {
        let out = ctl.command(&["display-message".into(), "-p".into(), format!("n{i}")]).await.unwrap();
        assert_eq!(out, [format!("n{i}")]);
    }
    ctl.detach().await;
}

#[tokio::test]
async fn types_cjk_and_named_keys() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "k", "-x", "80", "-y", "10", "cat"]);
    let t = s.tmux();
    let pane = t.list().await.unwrap()[0].pane.clone();
    t.send(cmd::send_hex(&pane, &rapp_term::keys::utf8_hex("你好 it's"))).await.unwrap();
    t.send(cmd::send_named(&pane, &["Enter".into()])).await.unwrap();
    common::settle().await;
    let sc = t.capture(&pane).await.unwrap();
    assert_eq!((sc.lines[0].as_str(), sc.lines[1].as_str()), ("你好 it's", "你好 it's"));
}

#[tokio::test]
async fn pastes_multiline_text_as_one_bracketed_paste_and_leaves_no_buffer() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "p", "-x", "80", "-y", "10", "printf '\\033[?2004h'; cat -v"]);
    common::settle().await;
    let t = s.tmux();
    let pane = t.list().await.unwrap()[0].pane.clone();
    t.paste(&pane, "第一行\n第二行 it's \"q\"", false).await.unwrap();
    common::settle().await;
    let sc = t.capture(&pane).await.unwrap();
    assert!(sc.lines[0].starts_with("^[[200~"));
    assert!(sc.lines.iter().any(|l| l.contains("^[[201~")));
    assert!(!s.raw(&["list-buffers"]).contains("rapp-"));
}

#[tokio::test]
async fn refuses_a_paste_over_one_mebibyte() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "p", "cat"]);
    let t = s.tmux();
    let pane = t.list().await.unwrap()[0].pane.clone();
    let e = t.paste(&pane, &"x".repeat(1_048_577), false).await.unwrap_err();
    assert_eq!(e.to_string(), "text is too long (1 MiB at most)");
}

#[tokio::test]
async fn an_empty_paste_is_a_no_op_and_with_enter_sends_only_enter() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "e", "-x", "80", "-y", "10", "cat"]);
    common::settle().await;
    let t = s.tmux();
    let pane = t.list().await.unwrap()[0].pane.clone();
    t.send(cmd::send_hex(&pane, &rapp_term::keys::utf8_hex("ab"))).await.unwrap();
    t.paste(&pane, "", false).await.unwrap();
    t.paste(&pane, "", true).await.unwrap();
    common::settle().await;
    let sc = t.capture(&pane).await.unwrap();
    assert_eq!((sc.lines[0].as_str(), sc.lines[1].as_str()), ("ab", "ab"));
    assert!(!s.raw(&["list-buffers"]).contains("rapp-"));
}

#[tokio::test]
async fn sizes_the_window_when_nobody_else_is_attached() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "z", "-x", "100", "-y", "30"]);
    let p = s.tmux().list().await.unwrap()[0].clone();
    let (ctl, _e) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    assert!(ctl.fit(&s.tmux(), &p.session_id, 140, 45, false).await.unwrap());
    let after = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((after.cols, after.rows), (140, 45));
    ctl.detach().await;
}

#[tokio::test]
async fn leaves_the_size_alone_when_someone_else_is_attached() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "z", "-x", "100", "-y", "30"]);
    let p = s.tmux().list().await.unwrap()[0].clone();
    // A person's terminal, 100x30: the window loses one row to its status line.
    let _real = s.attach_real("z", 100, 30);
    let (ctl, _e2) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    assert!(!ctl.fit(&s.tmux(), &p.session_id, 140, 45, false).await.unwrap());
    let same = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((same.cols, same.rows), (100, 29));
    // Forced, from a client attached after the real one (what a refit does): the size really changes.
    assert!(ctl.fit(&s.tmux(), &p.session_id, 140, 45, true).await.unwrap());
    let forced = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((forced.cols, forced.rows), (140, 45));
    ctl.detach().await;
}

#[tokio::test]
async fn new_session_runs_the_command_at_the_given_size() {
    let Some(s) = common::Server::start() else { return };
    s.tmux()
        .new_session("fix relay", &["sh".into(), "-c".into(), "echo \"it's up\"; sleep 60".into()], 118, 38)
        .await
        .unwrap();
    common::settle().await;
    let p = s.tmux().list().await.unwrap().into_iter().find(|p| p.session == "fix relay").unwrap();
    assert_eq!((p.cols, p.rows), (118, 38));
    assert_eq!(s.tmux().capture(&p.pane).await.unwrap().lines[0], "it's up");
}

#[tokio::test]
async fn new_session_hands_every_command_word_to_the_program() {
    // A `;` word must reach the program (tmux would take it as a command separator), and a first word starting
    // with `-` must be the program (tmux would take it as one of its own options).
    let Some(s) = common::Server::start() else { return };
    let dir = tempfile::Builder::new().prefix("rt").tempdir_in("/tmp").unwrap();
    let out = dir.path().join("args");
    let probe = dir.path().join("-rapp-probe");
    std::fs::write(
        &probe,
        format!("#!/bin/sh\nfor a; do printf '%s\\n' \"$a\"; done > '{}'\nsleep 60\n", out.display()),
    )
    .unwrap();
    std::fs::set_permissions(&probe, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    // The fixture (not rapp) sets the server's shell to one that finds the probe: tmux gives a new pane the PATH of
    // the client that made it, so the server's environment cannot.
    let shell = dir.path().join("shell");
    std::fs::write(&shell, format!("#!/bin/sh\nPATH='{}':$PATH exec /bin/sh \"$@\"\n", dir.path().display())).unwrap();
    std::fs::set_permissions(&shell, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    s.raw(&["set", "-g", "default-shell", shell.to_str().unwrap()]);
    s.raw(&["new-session", "-d", "-s", "keep"]);
    let words = ["-rapp-probe", "a b", "it's", ";", "rename-session", "-t", "keep", "RENAMED"];
    let command: Vec<String> = words.iter().map(|w| w.to_string()).collect();
    s.tmux().new_session("g", &command, 80, 24).await.unwrap();
    let mut got = String::new();
    for _ in 0..50 {
        got = std::fs::read_to_string(&out).unwrap_or_default();
        if got.lines().count() == words.len() - 1 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert_eq!(got.lines().collect::<Vec<_>>(), words[1..]);
    let names: Vec<String> = s.tmux().list().await.unwrap().into_iter().map(|p| p.session).collect();
    assert!(names.contains(&"keep".to_string()) && !names.contains(&"RENAMED".to_string()), "{names:?}");
}

// ---- the session pump ----

use rapp_term::proto::{In, Out};
use rapp_term::session::{self, Opts};
use rapp_term::unread::Unread;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream};

type OutLines = tokio::io::Lines<BufReader<DuplexStream>>;

/// A running pump: what we write to it, what it writes back, and its result.
struct Pump {
    w: DuplexStream,
    lines: OutLines,
    done: tokio::task::JoinHandle<anyhow::Result<()>>,
}

fn pump(s: &common::Server, session: &str, unread: Arc<Mutex<Unread>>) -> Pump {
    let (w, from_us) = tokio::io::duplex(1 << 16);
    let (to_us, r) = tokio::io::duplex(1 << 16);
    let (t, name) = (s.tmux(), session.to_string());
    let done =
        tokio::spawn(
            async move { session::run(&t, &name, BufReader::new(from_us), to_us, unread, Opts::default()).await },
        );
    Pump { w, lines: BufReader::new(r).lines(), done }
}

fn fresh_unread() -> Arc<Mutex<Unread>> {
    Arc::new(Mutex::new(Unread::default()))
}

/// The next message, within 3 seconds.
async fn next(lines: &mut OutLines) -> Out {
    let l = tokio::time::timeout(Duration::from_secs(3), lines.next_line())
        .await
        .expect("no message within 3 seconds")
        .unwrap()
        .expect("the pump closed its output");
    serde_json::from_str(&l).unwrap()
}

/// The next message that is not a pane list (a resize can re-send the list at any time while viewing).
async fn next_not_panes(lines: &mut OutLines) -> Out {
    loop {
        match next(lines).await {
            Out::Panes { .. } => continue,
            m => return m,
        }
    }
}

/// Whatever arrives within `d`.
async fn drain_for(lines: &mut OutLines, d: Duration) -> Vec<Out> {
    let mut v = Vec::new();
    let end = tokio::time::Instant::now() + d;
    while let Ok(Ok(Some(l))) = tokio::time::timeout_at(end, lines.next_line()).await {
        v.push(serde_json::from_str(&l).unwrap());
    }
    v
}

async fn say(w: &mut DuplexStream, m: In) {
    let mut l = serde_json::to_string(&m).unwrap();
    l.push('\n');
    w.write_all(l.as_bytes()).await.unwrap();
}

/// Hello, then the pane list: the first pane's id, and the list.
async fn greeted(p: &mut Pump) -> (String, Vec<rapp_term::proto::Pane>) {
    assert_eq!(next(&mut p.lines).await, Out::Hello { v: 1, backend: "tmux".into() });
    let Out::Panes { panes } = next(&mut p.lines).await else { panic!("expected the pane list") };
    (panes[0].id.clone(), panes)
}

/// Lay a screen message's rows over `base`.
fn apply(base: &mut [String], lines: &[(u16, String)]) {
    for (i, l) in lines {
        base[*i as usize] = l.clone();
    }
}

fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

fn view(pane: &str, cols: u16, rows: u16) -> In {
    In::View { pane: Some(pane.to_string()), cols, rows }
}

#[tokio::test]
async fn view_type_ack_roundtrip() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "v", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let mut p = pump(&s, "v", fresh_unread());
    let (pane, panes) = greeted(&mut p).await;
    assert_eq!(panes.len(), 1);
    assert_eq!(panes[0].command, "cat");
    say(&mut p.w, view(&pane, 118, 38)).await;
    let Out::Screen { pane: sp, full, rev, cols, rows, more, lines, .. } = next_not_panes(&mut p.lines).await else {
        panic!("expected a screen")
    };
    // Nobody else is attached, so the viewer's size was applied.
    assert_eq!((sp.as_str(), full, rev, cols, rows, more), (pane.as_str(), true, 1, 118, 38, false));
    let mut shown = vec![String::new(); 38];
    apply(&mut shown, &lines);
    say(&mut p.w, In::Ack { rev: 1 }).await;
    say(&mut p.w, In::Type { pane: pane.clone(), text: "你好".into() }).await;
    say(&mut p.w, In::Keys { pane: pane.clone(), keys: vec!["Enter".into()] }).await;
    let mut want_rev = 2;
    while !(shown[0] == "你好" && shown[1] == "你好") {
        let Out::Screen { rev, full, more, lines, .. } = next_not_panes(&mut p.lines).await else {
            panic!("expected a screen")
        };
        assert_eq!((rev, full), (want_rev, false));
        apply(&mut shown, &lines);
        if more {
            continue;
        }
        // Nothing more comes until this one is acknowledged.
        let early = drain_for(&mut p.lines, Duration::from_millis(300)).await;
        assert!(!early.iter().any(|m| matches!(m, Out::Screen { .. })), "a screen came before the ack");
        say(&mut p.w, In::Ack { rev }).await;
        want_rev += 1;
    }
    assert_eq!((shown[0].as_str(), shown[1].as_str()), ("你好", "你好"));
    drop(p.w); // end of input: the pump detaches and returns Ok
    tokio::time::timeout(Duration::from_secs(3), p.done).await.unwrap().unwrap().unwrap();
}

#[tokio::test]
async fn text_is_pasted_and_acknowledged() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let mut p = pump(&s, "t", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, text(&pane, "a\nb", false, false)).await;
    assert_eq!(next(&mut p.lines).await, Out::Pasted { ok: true, error: None });
    // Over 1 MiB in all, in chunks that each fit a line: one answer, at the last chunk.
    let chunk = "x".repeat(64_000);
    for _ in 0..16 {
        say(&mut p.w, text(&pane, &chunk, false, true)).await;
    }
    say(&mut p.w, text(&pane, &chunk, false, false)).await;
    assert_eq!(
        next(&mut p.lines).await,
        Out::Pasted { ok: false, error: Some("text is too long (1 MiB at most)".into()) }
    );
    assert!(drain_for(&mut p.lines, Duration::from_millis(300)).await.is_empty());
}

fn text(pane: &str, data: &str, enter: bool, more: bool) -> In {
    In::Text { pane: pane.to_string(), data: data.to_string(), enter, more }
}

#[tokio::test]
async fn a_paste_in_three_chunks_lands_whole_and_in_order() {
    let Some(s) = common::Server::start() else { return };
    let dir = tempfile::Builder::new().prefix("rt").tempdir_in("/tmp").unwrap();
    let out = dir.path().join("out");
    s.raw(&["new-session", "-d", "-s", "c", "-x", "80", "-y", "24", &format!("cat > '{}'", out.display())]);
    common::settle().await;
    let mut p = pump(&s, "c", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, text(&pane, "one\n", true, true)).await; // only the last chunk's enter counts
    say(&mut p.w, text(&pane, "two\n", false, true)).await;
    say(&mut p.w, text(&pane, "three", true, false)).await;
    assert_eq!(next(&mut p.lines).await, Out::Pasted { ok: true, error: None });
    assert!(drain_for(&mut p.lines, Duration::from_millis(300)).await.is_empty());
    let end = std::time::Instant::now() + Duration::from_secs(3);
    let got = loop {
        let got = std::fs::read_to_string(&out).unwrap_or_default();
        if got.ends_with("three\n") || std::time::Instant::now() > end {
            break got;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!(got, "one\ntwo\nthree\n");
}

#[tokio::test]
async fn an_over_limit_line_is_refused_and_viewing_goes_on() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "o", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let mut p = pump(&s, "o", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, In::Type { pane: pane.clone(), text: "y".repeat(70_000) }).await;
    assert_eq!(next(&mut p.lines).await, Out::Error { error: "bad message".into() });
    say(&mut p.w, view(&pane, 80, 24)).await;
    let Out::Screen { lines, .. } = next_not_panes(&mut p.lines).await else { panic!("expected a screen") };
    assert!(lines.iter().all(|(_, l)| !l.contains('y')), "the over-limit line was typed");
}

#[tokio::test]
async fn every_paste_is_answered_even_when_refused() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "a", "-x", "80", "-y", "24", "cat"]);
    s.raw(&["new-session", "-d", "-s", "o", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let other = s.tmux().list().await.unwrap().into_iter().find(|p| p.session == "o").unwrap().pane;
    let mut p = pump(&s, "a", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    let refused = |why: &str| Out::Pasted { ok: false, error: Some(why.into()) };
    // Another session's pane, in one chunk and in two.
    say(&mut p.w, text(&other, "x", false, false)).await;
    assert_eq!(next(&mut p.lines).await, refused("no such pane"));
    say(&mut p.w, text(&other, "x", false, true)).await;
    say(&mut p.w, text(&other, "x", false, false)).await;
    assert_eq!(next(&mut p.lines).await, refused("no such pane"));
    // A Text line that is not a message: alone, and as the middle chunk of a paste, which is then not made.
    p.w.write_all(format!("{{\"t\":\"text\",\"pane\":\"{pane}\"}}\n").as_bytes()).await.unwrap();
    assert_eq!(next(&mut p.lines).await, refused("bad message"));
    p.w.write_all(b"{\"t\":\"text\",\"data\":7}\n").await.unwrap();
    assert_eq!(next(&mut p.lines).await, refused("bad message"));
    say(&mut p.w, text(&pane, "first", false, true)).await;
    p.w.write_all(format!("{{\"t\":\"text\",\"pane\":\"{pane}\",\"more\":true}}\n").as_bytes()).await.unwrap();
    say(&mut p.w, text(&pane, "last", true, false)).await;
    assert_eq!(next(&mut p.lines).await, refused("bad message"));
    // A line over the limit may have been a chunk of any paste still coming: those are not made either.
    say(&mut p.w, text(&pane, "first", false, true)).await;
    p.w.write_all(format!("{}\n", "z".repeat(70_000)).as_bytes()).await.unwrap();
    assert_eq!(next(&mut p.lines).await, Out::Error { error: "bad message".into() });
    say(&mut p.w, text(&pane, "last", true, false)).await;
    assert_eq!(next(&mut p.lines).await, refused("bad message"));
    assert!(drain_for(&mut p.lines, Duration::from_millis(300)).await.is_empty());
    common::settle().await;
    let sc = s.tmux().capture(&pane).await.unwrap();
    assert_eq!((sc.cy, sc.lines[0].as_str()), (0, ""), "a refused paste reached the pane");
}

#[tokio::test]
async fn a_paste_that_fails_leaves_no_buffer() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "e", "-x", "80", "-y", "24", "cat"]);
    let t = s.tmux();
    // The buffer loads, then the paste finds no such pane.
    t.paste("%999", "x", false).await.unwrap_err();
    assert!(!s.raw(&["list-buffers"]).contains("rapp-"));
}

#[tokio::test]
async fn paste_errors_never_name_tmux() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "e", "-x", "80", "-y", "24", "cat"]);
    let t = s.tmux();
    let e = t.paste("%999", "x", false).await.unwrap_err().to_string();
    assert!(!e.to_lowercase().contains("tmux"), "{e}");
    let missing = Tmux { bin: "/nonexistent/tmux".into(), ..s.tmux() };
    let e = missing.paste("%0", "x", false).await.unwrap_err().to_string();
    assert!(!e.to_lowercase().contains("tmux"), "{e}");
}

#[tokio::test]
async fn unknown_keys_send_nothing() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "k", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let mut p = pump(&s, "k", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, In::Keys { pane: pane.clone(), keys: vec!["Enter".into(), "set-option".into()] }).await;
    assert_eq!(next(&mut p.lines).await, Out::Error { error: "unknown key".into() });
    common::settle().await;
    let sc = s.tmux().capture(&pane).await.unwrap();
    assert_eq!(sc.cy, 0); // the Enter was not sent either
}

#[tokio::test]
async fn a_flood_without_acks_sends_one_screen_then_the_latest() {
    // Review Focus 3
    let Some(s) = common::Server::start() else { return };
    // The outer shell traps Ctrl-C with a handler (not an ignore, so the flooding child still dies of it) and
    // lives on, keeping the pane to capture.
    s.raw(&[
        "new-session",
        "-d",
        "-s",
        "f",
        "-x",
        "80",
        "-y",
        "24",
        "trap : INT; sh -c 'i=0; while :; do echo line $i; i=$((i+1)); done'; sleep 60",
    ]);
    common::settle().await;
    let mut p = pump(&s, "f", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, view(&pane, 80, 24)).await;
    let Out::Screen { rev, more, lines, .. } = next_not_panes(&mut p.lines).await else { panic!("expected a screen") };
    assert_eq!((rev, more), (1, false));
    let mut shown = vec![String::new(); 24];
    apply(&mut shown, &lines);
    let later = drain_for(&mut p.lines, Duration::from_millis(500)).await;
    assert!(!later.iter().any(|m| matches!(m, Out::Screen { .. })), "a second screen came without an ack");
    say(&mut p.w, In::Keys { pane: pane.clone(), keys: vec!["Ctrl-C".into()] }).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    let now = s.tmux().capture(&pane).await.unwrap();
    assert_ne!(shown, now.lines, "the flood went on after the first screen, so the latest differs from it");
    say(&mut p.w, In::Ack { rev: 1 }).await;
    let Out::Screen { rev, full, more, lines, cx, cy, .. } = next_not_panes(&mut p.lines).await else {
        panic!("expected a screen")
    };
    assert_eq!((rev, full, more), (2, false, false));
    apply(&mut shown, &lines);
    assert_eq!(shown, now.lines);
    assert_eq!((cx, cy), (now.cx, now.cy));
}

#[tokio::test]
async fn ends_cleanly_when_the_session_is_killed() {
    // Review Focus 2
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "e", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let mut p = pump(&s, "e", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, view(&pane, 80, 24)).await;
    assert!(matches!(next_not_panes(&mut p.lines).await, Out::Screen { .. }));
    s.raw(&["kill-session", "-t", "e"]);
    assert_eq!(next_not_panes(&mut p.lines).await, Out::Error { error: "session ended".into() });
    tokio::time::timeout(Duration::from_secs(3), p.done).await.unwrap().unwrap().unwrap();
}

#[tokio::test]
async fn missing_session_and_bad_lines() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "b", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let mut gone = pump(&s, "nope", fresh_unread());
    assert_eq!(next(&mut gone.lines).await, Out::Error { error: "no such session".into() });
    tokio::time::timeout(Duration::from_secs(3), gone.done).await.unwrap().unwrap().unwrap();

    let mut p = pump(&s, "b", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    p.w.write_all(b"not json\n").await.unwrap();
    assert_eq!(next(&mut p.lines).await, Out::Error { error: "bad message".into() });
    say(&mut p.w, view(&pane, 80, 24)).await;
    assert!(matches!(next_not_panes(&mut p.lines).await, Out::Screen { rev: 1, full: true, .. }));
}

#[tokio::test]
async fn viewing_marks_the_session_seen() {
    let Some(s) = common::Server::start() else { return };
    let unread = Arc::new(Mutex::new(Unread::new(unix_now() - 100)));
    s.raw(&["new-session", "-d", "-s", "u", "-x", "80", "-y", "24", "echo hi; sleep 60"]);
    tokio::time::sleep(Duration::from_secs(4)).await; // output, then more than 3 quiet seconds
                                                      // Unread state is kept by session id, which a rename does not change.
    let one = s.tmux().list().await.unwrap()[0].clone();
    let (sid, activity) = (one.session_id, one.activity);
    assert!(unread.lock().unwrap().is_unread(&sid, activity, unix_now()));
    let mut p = pump(&s, "u", unread.clone());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, view(&pane, 80, 24)).await;
    assert!(matches!(next_not_panes(&mut p.lines).await, Out::Screen { .. }));
    assert!(!unread.lock().unwrap().is_unread(&sid, activity, unix_now()));
}

#[tokio::test]
async fn only_this_sessions_panes_take_input() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "a", "-x", "80", "-y", "24", "cat"]);
    s.raw(&["new-session", "-d", "-s", "o", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let other = s.tmux().list().await.unwrap().into_iter().find(|p| p.session == "o").unwrap().pane;
    let mut p = pump(&s, "a", fresh_unread());
    greeted(&mut p).await;
    // Another session's pane by id, and by a name tmux would take as a target: neither gets anything.
    say(&mut p.w, In::Keys { pane: other.clone(), keys: vec!["Enter".into()] }).await;
    assert_eq!(next(&mut p.lines).await, Out::Error { error: "no such pane".into() });
    say(&mut p.w, In::Type { pane: "o".into(), text: "x".into() }).await;
    assert_eq!(next_not_panes(&mut p.lines).await, Out::Error { error: "no such pane".into() });
    say(&mut p.w, view(&other, 80, 24)).await;
    assert_eq!(next_not_panes(&mut p.lines).await, Out::Error { error: "no such pane".into() });
    common::settle().await;
    let sc = s.tmux().capture(&other).await.unwrap();
    assert_eq!((sc.cy, sc.lines[0].as_str()), (0, ""));
    // A pane made in this session after the pump started is found by listing again.
    s.raw(&["split-window", "-d", "-t", "a", "cat"]);
    common::settle().await;
    let new = s.tmux().list().await.unwrap().into_iter().find(|q| q.session == "a" && q.pane_index == 1).unwrap().pane;
    say(&mut p.w, In::Type { pane: new.clone(), text: "hi".into() }).await;
    let got = drain_for(&mut p.lines, Duration::from_millis(500)).await;
    assert!(!got.iter().any(|m| matches!(m, Out::Error { .. })), "{got:?}");
    assert!(got.iter().any(|m| matches!(m, Out::Panes { panes } if panes.len() == 2)));
    assert_eq!(s.tmux().capture(&new).await.unwrap().lines[0], "hi");
}

/// Read and acknowledge screens until one is `cols` x `rows`; an error on the way fails the test.
async fn screen_at(p: &mut Pump, cols: u16, rows: u16, within: Duration) {
    let end = tokio::time::Instant::now() + within;
    loop {
        let left = end.saturating_duration_since(tokio::time::Instant::now());
        let l = tokio::time::timeout(left, p.lines.next_line())
            .await
            .unwrap_or_else(|_| panic!("no {cols}x{rows} screen in time"))
            .unwrap()
            .expect("the pump closed its output");
        match serde_json::from_str::<Out>(&l).unwrap() {
            Out::Screen { rev, cols: c, rows: r, .. } => {
                say(&mut p.w, In::Ack { rev }).await;
                if (c, r) == (cols, rows) {
                    return;
                }
            }
            Out::Error { error } => panic!("error: {error}"),
            _ => {}
        }
    }
}

async fn window_size(s: &common::Server) -> (u16, u16) {
    let p = s.tmux().list().await.unwrap()[0].clone();
    (p.cols, p.rows)
}

#[tokio::test]
async fn refit_takes_the_size_though_a_real_client_attached_later() {
    // Under the default `window-size latest`, a client that attached after rapp's wins the size; a refit must
    // still take.
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "r", "-x", "100", "-y", "30", "cat"]);
    common::settle().await;
    let mut p = pump(&s, "r", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, view(&pane, 60, 20)).await;
    screen_at(&mut p, 60, 20, Duration::from_secs(3)).await;
    let _real = s.attach_real("r", 120, 40);
    common::settle().await;
    assert_eq!(window_size(&s).await, (120, 39));
    say(&mut p.w, In::Refit { pane: pane.clone(), cols: 150, rows: 50 }).await;
    screen_at(&mut p, 150, 50, Duration::from_secs(3)).await;
    assert_eq!(window_size(&s).await, (150, 50));
}

#[tokio::test]
async fn a_refit_that_cannot_take_says_so() {
    // Under `window-size smallest` a real 80x24 client keeps the window from growing.
    let Some(s) = common::Server::start() else { return };
    s.raw(&["set", "-g", "window-size", "smallest"]);
    s.raw(&["new-session", "-d", "-s", "n", "-x", "80", "-y", "24", "cat"]);
    common::settle().await;
    let _real = s.attach_real("n", 80, 24);
    let mut p = pump(&s, "n", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, view(&pane, 80, 23)).await;
    screen_at(&mut p, 80, 23, Duration::from_secs(3)).await;
    say(&mut p.w, In::Refit { pane: pane.clone(), cols: 150, rows: 50 }).await;
    let got = drain_for(&mut p.lines, Duration::from_secs(2)).await;
    assert!(got.contains(&Out::Error { error: "could not resize".into() }), "{got:?}");
}

#[tokio::test]
async fn gives_its_size_up_to_a_real_client_that_attaches_later() {
    // Under `window-size smallest` the size rapp set would box in a person's bigger terminal.
    let Some(s) = common::Server::start() else { return };
    s.raw(&["set", "-g", "window-size", "smallest"]);
    s.raw(&["new-session", "-d", "-s", "g", "-x", "100", "-y", "30", "cat"]);
    common::settle().await;
    let mut p = pump(&s, "g", fresh_unread());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, view(&pane, 60, 20)).await;
    screen_at(&mut p, 60, 20, Duration::from_secs(3)).await;
    assert_eq!(window_size(&s).await, (60, 20));
    let _real = s.attach_real("g", 120, 40);
    // The poll (every 2 seconds) sees the other client and lets go; the viewer gets the screen at its new size.
    screen_at(&mut p, 120, 39, Duration::from_secs(6)).await;
    assert_eq!(window_size(&s).await, (120, 39));
}

// ---- ssh ----

/// The tmux the ssh test made on the far host: a private server whose sessions are ended through the same runner
/// when this is dropped, even if the test failed.
struct RemoteFixture {
    runner: Runner,
    socket: String,
    sessions: Vec<String>,
}

impl RemoteFixture {
    /// A tmux command on the far host's private server, sent by the test itself (not through `cmd.rs`).
    fn raw(&self, args: &[&str]) -> std::process::Output {
        let mut full: Vec<String> = ["-L", &self.socket, "-f", "/dev/null"].map(String::from).to_vec();
        full.extend(args.iter().map(|a| a.to_string()));
        let argv = self.runner.argv("tmux", &full);
        std::process::Command::new(&argv[0]).args(&argv[1..]).output().unwrap()
    }
}

impl Drop for RemoteFixture {
    fn drop(&mut self) {
        // With its last session gone the private server exits on its own.
        for name in &self.sessions {
            let _ = self.raw(&["kill-session", "-t", name]);
        }
    }
}

#[tokio::test]
async fn ssh_runner_lists_and_captures() {
    let Ok(dest) = std::env::var("RAPP_TERM_TEST_SSH") else {
        eprintln!("skipped: set RAPP_TERM_TEST_SSH=<destination> to run the ssh test");
        return;
    };
    // A short control directory: ssh's control socket path must fit a unix socket address.
    let ctl = tempfile::Builder::new().prefix("rt").tempdir_in("/tmp").unwrap();
    let runner = Runner::ssh(&dest, ctl.path()).unwrap();
    let pid = std::process::id();
    let socket = format!("rapp-term-test-{pid}-ssh");
    let (boot, name) = (format!("boot-{pid}"), format!("rapp ssh {pid}"));
    let mut fx = RemoteFixture { runner: runner.clone(), socket: socket.clone(), sessions: vec![boot.clone()] };
    // Start the private server without any config, as the local test servers are.
    let o = fx.raw(&["new-session", "-d", "-s", &boot]);
    assert!(o.status.success(), "could not start tmux on {dest}: {}", String::from_utf8_lossy(&o.stderr).trim());
    fx.sessions.push(name.clone());

    let t = Tmux { runner, bin: "tmux".into(), socket: Some(socket) };
    t.check().await.unwrap();
    t.new_session(&name, &["sh".into(), "-c".into(), "echo rapp-ssh-ok; sleep 60".into()], 90, 20).await.unwrap();
    common::settle().await;
    let p = t.list().await.unwrap().into_iter().find(|p| p.session == name).expect("the new session is listed");
    assert_eq!((p.cols, p.rows), (90, 20));
    assert_eq!(t.capture(&p.pane).await.unwrap().lines[0], "rapp-ssh-ok");
    drop(fx);
}
