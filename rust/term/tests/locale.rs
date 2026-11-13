//! Its own test binary (one process, one test) so it may set the locale for everything it spawns.

mod common;

#[tokio::test]
async fn list_survives_a_c_locale() {
    std::env::set_var("LC_ALL", "C");
    std::env::set_var("LANG", "C");
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "我的 \"work\"", "-x", "100", "-y", "30"]);
    let v = s.tmux().list().await.unwrap();
    assert_eq!(v.len(), 1);
    assert_eq!(v[0].session, "我的 \"work\"");
}
