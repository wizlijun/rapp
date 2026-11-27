//! The entry's own paths: health, the routes list, and each builtin under its prefix.

mod common;

use std::net::SocketAddr;

use common::{get, post, put, request, start, unix_now};
use rapp_center::Config;
use serde_json::{json, Value};

/// Two states of session `s` on device `aa`, dated now.
async fn post_sample(addr: SocketAddr) {
    let t = unix_now();
    let ev = |n: u64| json!({"v":1,"fp":"aa","epoch":"e","n":n,"at":t,"t":"state","session":"s","state":"working","seq":n}).to_string();
    assert_eq!(post(addr, "/v1/events", &format!("{}\n{}\n", ev(1), ev(2))).await, (204, Value::Null));
}

#[tokio::test]
async fn health_is_v2_and_says_it_has_routes() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/health").await, (200, json!({"name":"rapp-state","service":"rapp-center","v":2,"routes":true})));
}

#[tokio::test]
async fn routes_lists_the_builtins() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/routes").await, (200, json!({"routes":[{"name":"state","kind":"builtin","v":1},{"name":"prefs","kind":"builtin","v":1}]})));
    assert_eq!(request(addr, "POST", "/v1/routes", "").await.0, 405);
}

#[tokio::test]
async fn aliased_paths_answer_like_the_root() {
    let addr = start(Config::default()).await;
    post_sample(addr).await;
    assert_eq!(get(addr, "/state/v1/state").await, get(addr, "/v1/state").await);
    assert_eq!(get(addr, "/state/v1/queue?limit=1").await, get(addr, "/v1/queue?limit=1").await);
    assert_eq!(put(addr, "/state/v1/desk/aa", r#"{"sessions":[{"id":"111111111","app":"x"}]}"#).await.0, 204);
    assert_eq!(get(addr, "/v1/state").await.1["desks"][0]["fp"], "aa");
    assert_eq!(put(addr, "/state/v1/seen", r#"{"eid":"nope"}"#).await.0, put(addr, "/v1/seen", r#"{"eid":"nope"}"#).await.0);
    assert_eq!(request(addr, "POST", "/state/v1/events", "not json\n").await.0, request(addr, "POST", "/v1/events", "not json\n").await.0);
}

#[tokio::test]
async fn odd_paths_are_404() {
    let addr = start(Config::default()).await;
    for p in ["/state", "/state/", "/state/v1/watch", "/state/v1/health", "/STATE/v1/state", "/nope/v1/x", "//v1/state", "/v1/nope"] {
        assert_eq!(get(addr, p).await, (404, json!({"error":"not found"})), "{p}");
    }
}
