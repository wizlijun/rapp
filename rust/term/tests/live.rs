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
    let (other, _e1) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    other.command(&cmd::set_size(100, 30)).await.unwrap();
    let (ctl, _e2) = Control::attach(&s.tmux(), &p.session_id).await.unwrap();
    assert!(!ctl.fit(&s.tmux(), &p.session_id, 140, 45, false).await.unwrap());
    let same = s.tmux().list().await.unwrap()[0].clone();
    assert_eq!((same.cols, same.rows), (100, 30));
    assert!(ctl.fit(&s.tmux(), &p.session_id, 140, 45, true).await.unwrap());
    ctl.detach().await;
    other.detach().await;
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
    say(&mut p.w, In::Text { pane: pane.clone(), data: "a\nb".into(), enter: false }).await;
    assert_eq!(next(&mut p.lines).await, Out::Pasted { ok: true, error: None });
    say(&mut p.w, In::Text { pane: pane.clone(), data: "x".repeat(1_048_577), enter: false }).await;
    assert_eq!(
        next(&mut p.lines).await,
        Out::Pasted { ok: false, error: Some("text is too long (1 MiB at most)".into()) }
    );
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
    let activity = s.tmux().list().await.unwrap()[0].activity;
    assert!(unread.lock().unwrap().is_unread("u", activity, unix_now()));
    let mut p = pump(&s, "u", unread.clone());
    let (pane, _) = greeted(&mut p).await;
    say(&mut p.w, view(&pane, 80, 24)).await;
    assert!(matches!(next_not_panes(&mut p.lines).await, Out::Screen { .. }));
    assert!(!unread.lock().unwrap().is_unread("u", activity, unix_now()));
}
