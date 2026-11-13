mod common;

use rapp_term::runner::Runner;
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
