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
