//! The `prefs` builtin: the quick-area settings every app shares (`api/prefs.md`).

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::{get, post, put, recv, request, start, unix_now, watch};
use rapp_center::prefs::{Prefs, USAGE_KEEP};
use rapp_center::{serve, serve_with_log, Config, Log};
use serde_json::{json, Value};
use tokio::net::TcpListener;

const NONE: fn() -> Value = || json!({"at":0,"data":null});

fn is_store(v: &Value) -> bool {
    v.as_str().is_some_and(|s| s.len() == 16 && s.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')))
}

fn doc(at: u64, base: u64, data: Value) -> String {
    json!({"at": at, "base": base, "data": data}).to_string()
}

#[tokio::test]
async fn routes_list_prefs_v1() {
    let addr = start(Config::default()).await;
    let routes = get(addr, "/v1/routes").await.1;
    assert!(routes["routes"].as_array().unwrap().contains(&json!({"name":"prefs","kind":"builtin","v":1})), "{routes}");
}

#[tokio::test]
async fn all_has_a_16_hex_store_and_no_docs_at_first() {
    let addr = start(Config::default()).await;
    let (c, all) = get(addr, "/prefs/v1/all").await;
    assert_eq!(c, 200);
    assert!(is_store(&all["store"]), "{all}");
    assert_eq!(all.as_object().unwrap().len(), 1, "{all}");
    for name in ["phrases", "keys", "layout", "stars"] {
        assert_eq!(get(addr, &format!("/prefs/v1/{name}")).await, (200, NONE()), "{name}");
    }
}

#[tokio::test]
async fn put_with_right_base_is_204_then_get_returns_it() {
    let addr = start(Config::default()).await;
    let data = json!([{"id":"a","text":"hi"}]);
    assert_eq!(put(addr, "/prefs/v1/phrases", &doc(5, 0, data.clone())).await, (204, None));
    assert_eq!(get(addr, "/prefs/v1/phrases").await, (200, json!({"at":5,"data":data})));
    assert_eq!(put(addr, "/prefs/v1/phrases", &doc(9, 5, json!([]))).await, (204, None));
    assert_eq!(put(addr, "/prefs/v1/layout", &doc(3, 0, json!({"rows":[]}))).await, (204, None));
    let all = get(addr, "/prefs/v1/all").await.1;
    assert_eq!(all["phrases"], json!({"at":9,"data":[]}));
    assert_eq!(all["layout"], json!({"at":3,"data":{"rows":[]}}));
    assert!(all.get("keys").is_none() && all.get("stars").is_none() && all.get("usage").is_none(), "{all}");
}

#[tokio::test]
async fn put_with_stale_base_is_409_with_current_doc() {
    let addr = start(Config::default()).await;
    assert_eq!(put(addr, "/prefs/v1/keys", &doc(5, 0, json!(["a"]))).await.0, 204);
    assert_eq!(put(addr, "/prefs/v1/keys", &doc(6, 0, json!(["b"]))).await, (409, Some(json!({"at":5,"data":["a"]}))));
    assert_eq!(put(addr, "/prefs/v1/keys", &doc(6, 4, json!(["b"]))).await, (409, Some(json!({"at":5,"data":["a"]}))));
    assert_eq!(get(addr, "/prefs/v1/keys").await.1, json!({"at":5,"data":["a"]}));
    assert_eq!(put(addr, "/prefs/v1/keys", &doc(6, 5, json!(["b"]))).await.0, 204);
}

#[tokio::test]
async fn put_on_missing_with_nonzero_base_is_409_at_zero() {
    let addr = start(Config::default()).await;
    assert_eq!(put(addr, "/prefs/v1/stars", &doc(7, 3, json!(["x"]))).await, (409, Some(NONE())));
    assert_eq!(get(addr, "/prefs/v1/stars").await.1, NONE());
}

#[tokio::test]
async fn unknown_name_is_404_bad_body_400_wrong_method_405() {
    let addr = start(Config::default()).await;
    let nf = (404, json!({"error":"not found"}));
    for p in ["/prefs/v1/nope", "/prefs/v1/", "/prefs/v1/usage", "/prefs/v1/all/x", "/prefs/v1/phrases/x", "/prefs/v2/all", "/PREFS/v1/all"] {
        assert_eq!(get(addr, p).await, nf, "{p}");
    }
    assert_eq!(put(addr, "/prefs/v1/nope", &doc(1, 0, json!(1))).await, (404, Some(json!({"error":"not found"}))));
    assert_eq!(put(addr, "/prefs/v1/all", &doc(1, 0, json!(1))).await.0, 405);
    let bad = (400, Some(json!({"error":"bad request"})));
    for body in ["", "not json", "[]", r#"{"at":1,"base":0}"#, r#"{"at":1,"data":1}"#, r#"{"base":0,"data":1}"#,
        r#"{"at":-1,"base":0,"data":1}"#, r#"{"at":1.5,"base":0,"data":1}"#, r#"{"at":"1","base":0,"data":1}"#] {
        assert_eq!(put(addr, "/prefs/v1/phrases", body).await, bad, "{body}");
    }
    for body in ["not json", r#"{"data":1}"#, r#"{"at":1}"#] {
        assert_eq!(put(addr, "/prefs/v1/usage/dev1", body).await, bad, "{body}");
    }
    assert_eq!(put(addr, "/prefs/v1/usage/", r#"{"at":1,"data":1}"#).await, bad);
    assert_eq!(put(addr, &format!("/prefs/v1/usage/{}", "d".repeat(129)), r#"{"at":1,"data":1}"#).await, bad);
    assert_eq!(get(addr, "/prefs/v1/phrases").await, (200, NONE()));
    let na = json!({"error":"method not allowed"});
    assert_eq!(post(addr, "/prefs/v1/phrases", "").await, (405, na.clone()));
    assert_eq!(request(addr, "DELETE", "/prefs/v1/keys", "").await, (405, na.clone()));
    assert_eq!(post(addr, "/prefs/v1/all", "").await, (405, na.clone()));
    assert_eq!(get(addr, "/prefs/v1/usage/dev1").await, (405, na));
}

#[tokio::test]
async fn data_over_256k_is_413() {
    let addr = start(Config::default()).await;
    let too_large = (413, Some(json!({"error":"too large"})));
    // Serialized with its quotes, this is 2 bytes over; the body still fits the read limit.
    let just_over = json!("x".repeat(256 * 1024));
    assert_eq!(put(addr, "/prefs/v1/phrases", &doc(1, 0, just_over)).await, too_large);
    assert_eq!(put(addr, "/prefs/v1/usage/dev1", &json!({"at":1,"data":"x".repeat(256 * 1024)}).to_string()).await, too_large);
    // A body far over the read limit.
    assert_eq!(put(addr, "/prefs/v1/keys", &doc(1, 0, json!("x".repeat(400 * 1024)))).await, too_large);
    let just_fits = json!("x".repeat(256 * 1024 - 2));
    assert_eq!(put(addr, "/prefs/v1/stars", &doc(1, 0, just_fits.clone())).await, (204, None));
    assert_eq!(get(addr, "/prefs/v1/phrases").await.1, NONE());
    assert_eq!(get(addr, "/prefs/v1/stars").await.1["data"], just_fits);
}

#[tokio::test]
async fn usage_replaces_per_device() {
    let addr = start(Config::default()).await;
    let body = |at: u64, data: Value| json!({"at": at, "data": data}).to_string();
    assert_eq!(put(addr, "/prefs/v1/usage/dev1", &body(5, json!({"a":{"2026-11-27":2}}))).await, (204, None));
    assert_eq!(put(addr, "/prefs/v1/usage/dev2", &body(4, json!({"b":{"2026-11-27":1}}))).await, (204, None));
    // Always taken, even with an older `at`: each device writes only its own.
    assert_eq!(put(addr, "/prefs/v1/usage/dev1", &body(3, json!({"c":{"2026-11-26":7}}))).await, (204, None));
    let all = get(addr, "/prefs/v1/all").await.1;
    assert_eq!(
        all["usage"],
        json!({"dev1":{"at":3,"data":{"c":{"2026-11-26":7}}},"dev2":{"at":4,"data":{"b":{"2026-11-27":1}}}})
    );
}

#[tokio::test]
async fn watch_pushes_prefs_and_usage() {
    let addr = start(Config::default()).await;
    let mut w = watch(addr).await;
    assert_eq!(recv(&mut w).await, json!({"what":"hello"}));
    assert_eq!(put(addr, "/prefs/v1/layout", &doc(2, 0, json!({"rows":[["a"]]}))).await.0, 204);
    assert_eq!(recv(&mut w).await, json!({"what":"prefs.layout","doc":{"at":2,"data":{"rows":[["a"]]}}}));
    assert_eq!(put(addr, "/prefs/v1/usage/dev1", r#"{"at":8,"data":{"a":{"2026-11-27":1}}}"#).await.0, 204);
    assert_eq!(recv(&mut w).await, json!({"what":"prefs.usage","device":"dev1","doc":{"at":8,"data":{"a":{"2026-11-27":1}}}}));
    // A refused put pushes nothing; the next push is the next accepted one.
    assert_eq!(put(addr, "/prefs/v1/layout", &doc(3, 0, json!({}))).await.0, 409);
    assert_eq!(put(addr, "/prefs/v1/stars", &doc(4, 0, json!(["a"]))).await.0, 204);
    assert_eq!(recv(&mut w).await, json!({"what":"prefs.stars","doc":{"at":4,"data":["a"]}}));
}

fn data_cfg(d: &tempfile::TempDir) -> Config {
    Config { data: Some(d.path().join("data")), ..Config::default() }
}

/// Runs a service on `cfg` until `f` is done, then waits for its save and stops it.
async fn run_and_save<F: std::future::Future<Output = ()>>(cfg: Config, f: impl FnOnce(std::net::SocketAddr) -> F) {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let task = tokio::spawn(serve(cfg, l));
    f(addr).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    task.abort();
    let _ = task.await;
}

#[tokio::test]
async fn prefs_and_store_survive_restart_with_data_dir() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("data/prefs.json");
    // What prefs.json holds once it holds `want`, polled for 10 s (a save comes 1 s after a change; a loaded gate is slower).
    let saved = |want: fn(&Value) -> bool| {
        let path = path.clone();
        async move {
            for _ in 0..100 {
                if let Some(v) = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
                    if want(&v) {
                        return v;
                    }
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            panic!("prefs.json never got there: {:?}", std::fs::read_to_string(&path));
        }
    };
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let task = tokio::spawn(serve(data_cfg(&d), l));
    // Past the start's own save, so only a PUT can bring the next one.
    saved(|v| v["store"].is_string()).await;
    assert_eq!(put(addr, "/prefs/v1/phrases", &doc(5, 0, json!(["a"]))).await.0, 204);
    saved(|v| v["docs"]["phrases"]["at"] == 5).await;
    assert_eq!(put(addr, "/prefs/v1/usage/dev1", r#"{"at":8,"data":{"a":{}}}"#).await.0, 204);
    saved(|v| v["usage"]["dev1"]["at"] == 8).await;
    task.abort();
    let _ = task.await;
    let file: Value = serde_json::from_slice(&std::fs::read(d.path().join("data/prefs.json")).unwrap()).unwrap();
    assert!(is_store(&file["store"]), "{file}");
    assert_eq!(file["docs"], json!({"phrases":{"at":5,"data":["a"]}}));
    let put_at = file["usage"]["dev1"]["put_at"].as_u64().unwrap();
    assert!(put_at.abs_diff(unix_now()) < 60, "{file}");
    assert!(d.path().join("data/state.json").exists());
    let addr = start(data_cfg(&d)).await;
    let all = get(addr, "/prefs/v1/all").await.1;
    assert_eq!(all["store"], file["store"]);
    assert_eq!(all["phrases"], json!({"at":5,"data":["a"]}));
    assert_eq!(all["usage"], json!({"dev1":{"at":8,"data":{"a":{}}}}));
    // And the stored doc still guards its base.
    assert_eq!(put(addr, "/prefs/v1/phrases", &doc(6, 0, json!([]))).await.0, 409);
}

/// `memory.rs` checks that nothing is written without a data directory, prefs included.
#[tokio::test]
async fn memory_mode_writes_no_prefs_file_and_store_changes_per_start() {
    let a = start(Config::default()).await;
    let b = start(Config::default()).await;
    let (sa, sb) = (get(a, "/prefs/v1/all").await.1["store"].clone(), get(b, "/prefs/v1/all").await.1["store"].clone());
    assert!(is_store(&sa) && is_store(&sb));
    assert_ne!(sa, sb);
    assert_eq!(put(a, "/prefs/v1/phrases", &doc(1, 0, json!([]))).await.0, 204);
    assert_eq!(get(b, "/prefs/v1/phrases").await.1, NONE());
}

#[tokio::test]
async fn a_bad_prefs_file_is_moved_aside_and_state_still_loads() {
    let d = tempfile::tempdir().unwrap();
    let cfg = Config { keep_days: 100_000, ..data_cfg(&d) };
    let samples = include_str!("../api/samples/term-events.ndjson");
    run_and_save(cfg.clone(), |addr| async move {
        assert_eq!(post(addr, "/v1/events", samples).await.0, 204);
        assert_eq!(put(addr, "/prefs/v1/keys", &doc(5, 0, json!(["a"]))).await.0, 204);
    })
    .await;
    let dir = d.path().join("data");
    let old_store = serde_json::from_slice::<Value>(&std::fs::read(dir.join("prefs.json")).unwrap()).unwrap()["store"].clone();
    std::fs::write(dir.join("prefs.json"), "{not json").unwrap();
    let lines: Arc<Mutex<Vec<Value>>> = Arc::default();
    let sink = lines.clone();
    let log = Log::new(move |v| sink.lock().unwrap().push(v.clone()));
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve_with_log(cfg, l, log));
    assert_eq!(get(addr, "/v1/state").await.1["queued"], 4);
    let all = get(addr, "/prefs/v1/all").await.1;
    assert!(is_store(&all["store"]) && all["store"] != old_store, "{all}");
    assert!(all.get("keys").is_none(), "{all}");
    assert_eq!(std::fs::read(dir.join("prefs.json.bad")).unwrap(), b"{not json");
    let failed: Vec<Value> = lines.lock().unwrap().iter().filter(|v| v["event"] == "load_failed").cloned().collect();
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert_eq!(failed[0]["kind"], "parse");
    // A fresh file is saved in its place.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let file: Value = serde_json::from_slice(&std::fs::read(dir.join("prefs.json")).unwrap()).unwrap();
    assert_eq!(file["store"], all["store"]);
}

#[test]
fn usage_older_than_90_days_by_receive_time_is_dropped() {
    let day = 86_400;
    assert_eq!(USAGE_KEEP, 90 * day);
    let t0 = 1_000 * day;
    let mut p = Prefs::new();
    // `at` is the app's: only when the service received it counts.
    p.put_usage("old", u64::MAX, json!({"a":{}}), t0);
    p.put_usage("edge", 0, json!({"b":{}}), t0 + 10 * day);
    p.put_usage("new", 0, json!({"c":{}}), t0 + 80 * day);
    p.expire(t0 + 90 * day);
    assert_eq!(p.all()["usage"].as_object().unwrap().keys().collect::<Vec<_>>(), ["edge", "new", "old"]);
    p.expire(t0 + 90 * day + 1);
    assert_eq!(p.all()["usage"].as_object().unwrap().keys().collect::<Vec<_>>(), ["edge", "new"]);
    p.expire(t0 + 100 * day + 1);
    assert_eq!(p.all()["usage"].as_object().unwrap().keys().collect::<Vec<_>>(), ["new"]);
    p.expire(t0 + 200 * day);
    assert!(p.all().get("usage").is_none());
    // Documents never expire.
    assert_eq!(p.put("phrases", 1, 0, json!([])), Ok(()));
    p.expire(u64::MAX);
    assert_eq!(p.all()["phrases"], json!({"at":1,"data":[]}));
}
