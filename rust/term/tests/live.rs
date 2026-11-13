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
