//! rapp-hub (spec §4) driven over its stdin/stdout JSON lines against a real
//! service with fake workers.

mod common;

use common::*;
use serde_json::{json, Value};
use std::time::Duration;

fn apps() -> Value {
    json!([{"app":"com.example.echo","name":"Echo"},{"app":"com.apple.Safari","name":"Safari"}])
}

/// `id@ip` for A: the only way to add a host.
fn at(a: &TestService) -> String {
    format!("{}@{}", a.id, a_addr(&a.svc))
}

/// Adds A's host to a fresh hub; returns the hub.
async fn hub_with_host(a: &TestService, home: &std::path::Path) -> Hub {
    let mut hub = Hub::start(home, a.bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":at(a),"password":PASSWORD,"req":1})).await;
    assert_eq!(r, json!({"event":"host_added","id":a.id,"name":"test-a","req":1}));
    hub
}

/// open → opened (bytes pass both ways, the fake client checks the echo) → close → closed.
async fn open_and_close(hub: &mut Hub, id: &str, path: &str) {
    let r = hub.call(json!({"cmd":"open","id":id,"app":"com.example.echo","req":"o"})).await;
    assert_eq!(r["event"], "opened", "{r}");
    assert_eq!((&r["id"], &r["app"], &r["path"], &r["req"]), (&json!(id), &json!("com.example.echo"), &json!(path), &json!("o")));
    let sid = r["sid"].clone();
    // Give the fake client time to finish its ping/echo before closing its stdin.
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"echo ok"}));
}

#[tokio::test]
async fn add_host_hosts_apps_open_close_remove() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;

    let saved: Value = serde_json::from_slice(&std::fs::read(home.path().join("hosts.json")).unwrap()).unwrap();
    assert_eq!(saved[0]["id"], a.id.as_str());
    assert_eq!(saved[0]["password"], PASSWORD);
    assert!(saved[0]["lan"].as_array().unwrap().iter().any(|l| l == &json!(a_addr(&a.svc).to_string())));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(home.path().join("hosts.json")).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    let r = hub.call(json!({"cmd":"hosts"})).await;
    let h = &r["hosts"][0];
    assert_eq!((r["hosts"].as_array().unwrap().len(), &h["id"], &h["name"]), (1, &json!(a.id), &json!("test-a")), "{r}");
    // A's LAN address reaches the GUI for 屏幕共享; the password never does.
    assert!(!h["lan"].as_array().unwrap().is_empty(), "{r}");
    assert!(h.get("password").is_none(), "{r}");
    let r = hub.call(json!({"cmd":"apps","id":a.id,"req":"x"})).await;
    let perms = json!({"screen_recording":true,"accessibility":true});
    assert_eq!(r, json!({"event":"apps","id":a.id,"path":"lan","apps":apps(),"permissions":perms,"req":"x"}));

    open_and_close(&mut hub, &a.id, "lan").await;
    // A's side of the session ends too.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let st = ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await;
        if st["sessions"] == json!([]) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "A session never ended: {st}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let r = hub.call(json!({"cmd":"close","sid":999,"req":2})).await;
    assert_eq!(r, json!({"event":"error","req":2,"error":"unknown sid"}));
    assert_eq!(hub.call(json!({"cmd":"remove_host","id":a.id})).await, json!({"event":"hosts","hosts":[]}));
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r, json!({"event":"error","error":"unknown host"}));
    assert_eq!(hub.finish().await, Vec::<Value>::new());
}

#[tokio::test]
async fn side_connection_gets_its_own_open_and_listener_closes_with_session() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    open_and_close(&mut hub, &a.id, "lan").await;
    let port: u16 = std::fs::read_to_string(a.bins.path().join("client.port")).unwrap().trim().parse().unwrap();
    assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_err(), "listener should be closed with the session");
    assert_eq!(hub.finish().await, Vec::<Value>::new());
}

#[tokio::test]
async fn add_host_by_id_at_ip() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path());
    let at = format!("{}@{}", a.id, a_addr(&a.svc));

    let r = hub.call(json!({"cmd":"add_host","id":format!("987654321@{}", a_addr(&a.svc)),"password":PASSWORD,"req":1})).await;
    assert_eq!(r["event"], "error", "a different ID at that address is refused: {r}");
    let r = hub.call(json!({"cmd":"add_host","id":at,"password":"wrong","req":2})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert!(!home.path().join("hosts.json").exists());

    let r = hub.call(json!({"cmd":"add_host","id":at,"password":PASSWORD,"req":3})).await;
    assert_eq!(r, json!({"event":"host_added","id":a.id,"name":"test-a","req":3}));
    let saved: Value = serde_json::from_slice(&std::fs::read(home.path().join("hosts.json")).unwrap()).unwrap();
    assert_eq!(saved[0]["lan"], json!([a_addr(&a.svc).to_string()]));
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("lan"), &apps()), "{r}");
    open_and_close(&mut hub, &a.id, "lan").await;
    hub.finish().await;
}

#[tokio::test]
async fn add_host_errors_are_reported_and_nothing_saved() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":at(&a),"password":"wrong","req":7})).await;
    assert_eq!(r, json!({"event":"error","req":7,"error":format!("{}: bad password", a_addr(&a.svc))}));
    assert_eq!(hub.call(json!({"cmd":"hosts"})).await, json!({"event":"hosts","hosts":[]}));
    assert!(!home.path().join("hosts.json").exists());
    assert_eq!(hub.call(json!({"cmd":"nope","req":1})).await, json!({"event":"error","req":1,"error":"unknown cmd"}));
    hub.send(json!("garbage")).await;
    assert_eq!(hub.next().await["event"], "error");
    hub.finish().await;
}

#[tokio::test]
async fn stdin_eof_closes_open_sessions() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    assert_eq!(r["event"], "opened", "{r}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let rest = hub.finish().await;
    assert_eq!(rest, vec![json!({"event":"closed","sid":r["sid"],"reason":"echo ok"})]);
}

#[tokio::test]
async fn open_unknown_app_worker_failure_is_an_error() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    // An unlaunchable client wins resolution even when a real Linux client is
    // installed beside the test binaries or on PATH.
    let broken = tempfile::tempdir().unwrap();
    std::fs::write(broken.path().join(format!("rapp-client{}", std::env::consts::EXE_SUFFIX)), "invalid executable").unwrap();
    let mut hub2 = Hub::start(home.path(), broken.path());
    let r = hub2.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":3})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert_eq!(r["req"], 3);
    hub2.finish().await;
    assert_eq!(hub.call(json!({"cmd":"apps","id":"000"})).await["error"], "unknown host");
    hub.finish().await;
}

#[tokio::test]
async fn hub_log_records_route_session_and_client_stderr_without_secrets() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    assert_eq!(r["event"], "opened", "{r}");
    let sid = r["sid"].clone();
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await["event"], "closed");
    hub.finish().await;

    let log = |ev: &str| read_log(home.path(), "hub.log").into_iter().filter(|v| v["ev"] == ev).collect::<Vec<_>>();
    let start = &log("hub_start")[0];
    assert_eq!(start["lvl"], "info", "{start}");
    assert!(start["version"].is_string(), "{start}");
    let route = log("route");
    assert!(route.iter().any(|v| v["id"] == a.id.as_str() && v["path"] == "lan" && v["result"] == "ok"), "{route:?}");
    let opened = &log("opened")[0];
    assert_eq!(
        (&opened["sid"], &opened["id"], &opened["host_name"], &opened["app"], &opened["path"]),
        (&sid, &json!(a.id), &json!("test-a"), &json!("com.example.echo"), &json!("lan")),
        "{opened}"
    );
    let client = log("log");
    assert!(
        client.iter().any(|v| v["src"] == "client" && v["sid"] == sid && v["msg"] == "fake-rapp-client: connected"),
        "{client:?}"
    );
    let closed = &log("closed")[0];
    assert_eq!((&closed["sid"], &closed["id"], &closed["app"], &closed["reason"]), (&sid, &json!(a.id), &json!("com.example.echo"), &json!("echo ok")), "{closed}");
    assert!(closed["secs"].is_u64(), "{closed}");

    // B introduces itself by hostname: A's service log shows it (spec §2).
    let me = rapp_net::config::hostname();
    let started = wait_log(a.home.path(), "session_start", |v| v["app"] == "com.example.echo").await;
    assert_eq!(started["name"], me.as_str(), "{started}");

    let text = std::fs::read_to_string(home.path().join("logs").join("hub.log")).unwrap();
    assert!(!text.contains(PASSWORD), "password in hub.log:\n{text}");
}

async fn wait_for_file(path: &std::path::Path) {
    for _ in 0..150 {
        if path.exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("{} never appeared", path.display());
}

#[tokio::test]
async fn focus_reaches_the_client_and_unknown_sid_errors() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o"})).await;
    assert_eq!(r["event"], "opened", "{r}");
    let sid = r["sid"].clone();
    hub.send(json!({"cmd":"focus","sid":sid})).await;
    let f = a.bins.path().join("client.focus");
    wait_for_file(&f).await;
    assert_eq!(std::fs::read_to_string(&f).unwrap(), "focus\n");
    let e = hub.call(json!({"cmd":"focus","sid":999,"req":"f"})).await;
    assert_eq!(e, json!({"event":"error","error":"unknown sid","req":"f"}));
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"echo ok"}));
}

#[tokio::test]
async fn second_open_of_the_same_app_reuses_the_session() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r1 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o1"})).await;
    assert_eq!(r1["event"], "opened", "{r1}");
    let r2 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o2"})).await;
    assert_eq!(
        (r2["event"].clone(), r2["sid"].clone(), r2["reused"].clone(), r2["req"].clone(), r2["path"].clone()),
        (json!("opened"), r1["sid"].clone(), json!(true), json!("o2"), r1["path"].clone())
    );
    wait_for_file(&a.bins.path().join("client.focus")).await;
    // A saw one open only.
    let starts = log_events(a.home.path()).into_iter().filter(|v| v["ev"] == "session_start" && v["app"] == "com.example.echo" && v.get("side").is_none()).count();
    assert_eq!(starts, 1);
    let opened: Vec<Value> = read_log(home.path(), "hub.log").into_iter().filter(|v| v["ev"] == "opened").collect();
    assert_eq!(opened.len(), 2);
    assert_eq!(opened[1]["reused"], true);
    hub.send(json!({"cmd":"close","sid":r1["sid"]})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":r1["sid"],"reason":"echo ok"}));
}

#[tokio::test]
async fn embedded_opens_are_not_reused_by_the_hub() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (s1, _, t1) = embed_open(&mut hub, &a).await;
    let (s2, _, t2) = embed_open(&mut hub, &a).await;
    assert_ne!(s1, s2);
    // A standalone open does not reuse an embedded session either.
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o"})).await;
    assert_ne!(r["sid"], s1);
    assert_ne!(r["sid"], s2);
    assert!(r.get("reused").is_none(), "{r}");
    let text = std::fs::read_to_string(home.path().join("logs").join("hub.log")).unwrap();
    assert!(!text.contains(&t1) && !text.contains(&t2), "token in hub.log");
}

#[tokio::test]
async fn open_after_closed_gets_a_new_session() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r1 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o1"})).await;
    hub.send(json!({"cmd":"close","sid":r1["sid"]})).await;
    assert_eq!(hub.next().await["event"], "closed");
    let r2 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o2"})).await;
    assert_eq!(r2["event"], "opened", "{r2}");
    assert_ne!(r1["sid"], r2["sid"]);
    assert!(r2.get("reused").is_none(), "{r2}");
}

#[tokio::test]
async fn reconnect_open_is_never_reused() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r1 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":"o1"})).await;
    let r2 = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","reconnect":true,"req":"o2"})).await;
    assert_ne!(r1["sid"], r2["sid"]);
    assert!(r2.get("reused").is_none(), "{r2}");
}

/// Plays the GUI side of an embedded session: token line, `ok`, then an echoed `word`.
async fn gui_connect(port: u64, token: &str, word: &str) -> tokio::net::TcpStream {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", port as u16)).await.unwrap();
    tcp.write_all(format!("{token}\n").as_bytes()).await.unwrap();
    let mut line = String::new();
    let mut r = BufReader::new(&mut tcp);
    r.read_line(&mut line).await.unwrap();
    assert_eq!(line, "ok\n");
    line.clear();
    r.get_mut().write_all(format!("{word}\n").as_bytes()).await.unwrap();
    r.read_line(&mut line).await.unwrap();
    assert_eq!(line, format!("{word}\n"));
    tcp
}

async fn embed_open(hub: &mut Hub, a: &TestService) -> (Value, u64, String) {
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","embed":true,"req":"o"})).await;
    assert_eq!(r["event"], "opened", "{r}");
    let (port, token) = (r["port"].as_u64().unwrap(), r["token"].as_str().unwrap().to_string());
    (r["sid"].clone(), port, token)
}

#[tokio::test]
async fn embed_open_returns_port_and_token_and_spawns_no_client() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, port, token) = embed_open(&mut hub, &a).await;
    let tcp = gui_connect(port, &token, "ping").await;
    assert!(!a.bins.path().join("client.port").exists(), "no rapp-client was started");
    drop(tcp);
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"connection closed"}));
    hub.finish().await;
    let text = std::fs::read_to_string(home.path().join("logs").join("hub.log")).unwrap();
    assert!(!text.contains(&token), "token in hub.log:\n{text}");
    let opened = read_log(home.path(), "hub.log").into_iter().find(|v| v["ev"] == "opened").unwrap();
    assert_eq!(opened["sid"], sid, "{opened}");
}

#[tokio::test]
async fn embed_close_command_ends_with_quit() {
    use tokio::io::AsyncReadExt;
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, port, token) = embed_open(&mut hub, &a).await;
    let mut tcp = gui_connect(port, &token, "ping").await;
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"quit"}));
    let mut rest = Vec::new();
    tokio::time::timeout(WAIT, tcp.read_to_end(&mut rest)).await.expect("EOF in time").unwrap();
    hub.finish().await;
}

#[tokio::test]
async fn embed_side_connection_gets_its_own_open() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, port, token) = embed_open(&mut hub, &a).await;
    let _main = gui_connect(port, &token, "ping").await;
    let _side = gui_connect(port, &token, "side").await;
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"quit"}));
    hub.finish().await;
}

#[tokio::test]
async fn embed_without_connect_reports_gui_did_not_connect() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, _, _) = embed_open(&mut hub, &a).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"GUI did not connect"}));
    let closed = read_log(home.path(), "hub.log").into_iter().find(|v| v["ev"] == "closed").unwrap();
    assert_eq!(closed["reason"], "GUI did not connect", "{closed}");
    hub.finish().await;
}

#[tokio::test]
async fn note_logs_detach_and_attach() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, port, token) = embed_open(&mut hub, &a).await;
    let _tcp = gui_connect(port, &token, "ping").await;
    hub.send(json!({"cmd":"note","sid":sid,"what":"detach","windows":2})).await;
    hub.send(json!({"cmd":"note","sid":sid,"what":"attach","windows":2})).await;
    let e = hub.call(json!({"cmd":"note","sid":999,"what":"detach","windows":1,"req":"n"})).await;
    assert_eq!(e, json!({"event":"error","error":"unknown sid","req":"n"}));
    let e = hub.call(json!({"cmd":"note","sid":sid,"what":"x","windows":1,"req":"m"})).await;
    assert_eq!(e, json!({"event":"error","error":"bad note","req":"m"}));
    let e = hub.call(json!({"cmd":"note","sid":sid,"what":"attach"})).await;
    assert_eq!(e, json!({"event":"error","error":"bad note"}));
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await["event"], "closed");
    hub.finish().await;
    let log = |ev: &str| read_log(home.path(), "hub.log").into_iter().filter(|v| v["ev"] == ev).collect::<Vec<_>>();
    let (d, at) = (log("detach"), log("attach"));
    assert_eq!((d.len(), at.len()), (1, 1), "{d:?} {at:?}");
    assert_eq!((&d[0]["windows"], &d[0]["sid"]), (&json!(2), &sid), "{:?}", d[0]);
    assert_eq!(at[0]["sid"], sid);
}

#[tokio::test]
async fn embed_close_before_connect_ends_with_quit() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, _, _) = embed_open(&mut hub, &a).await;
    hub.send(json!({"cmd":"close","sid":sid})).await;
    let ev = tokio::time::timeout(Duration::from_secs(3), hub.next()).await.expect("closed well before ACCEPT_WAIT");
    assert_eq!(ev, json!({"event":"closed","sid":sid,"reason":"quit"}));
    hub.finish().await;
}

#[tokio::test]
async fn embed_wrong_token_closes_the_session() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, port, _) = embed_open(&mut hub, &a).await;
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", port as u16)).await.unwrap();
    tcp.write_all(b"wrong-token\n").await.unwrap();
    // A rejects it ("bad token") and hangs up; like the real GUI, hang up once told.
    let mut line = String::new();
    tokio::io::BufReader::new(&mut tcp).read_line(&mut line).await.unwrap();
    assert_eq!(line, "bad token\n");
    drop(tcp);
    let ev = tokio::time::timeout(Duration::from_secs(5), hub.next()).await.expect("closed in time");
    assert_eq!(ev, json!({"event":"closed","sid":sid,"reason":"connection closed"}));
    hub.finish().await;
}

// ---- S3: close reason, reconnect flag, presence ----

#[tokio::test]
async fn embed_close_with_user_reason() {
    use tokio::io::AsyncReadExt;
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, port, token) = embed_open(&mut hub, &a).await;
    let mut tcp = gui_connect(port, &token, "ping").await;
    hub.send(json!({"cmd":"close","sid":sid,"reason":"user"})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"user"}));
    let mut rest = Vec::new();
    tokio::time::timeout(WAIT, tcp.read_to_end(&mut rest)).await.expect("EOF in time").unwrap();
    hub.finish().await;
    let closed = read_log(home.path(), "hub.log").into_iter().find(|v| v["ev"] == "closed").unwrap();
    assert_eq!(closed["reason"], "user", "{closed}");
}

#[tokio::test]
async fn close_with_bad_reason_is_an_error() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (sid, port, token) = embed_open(&mut hub, &a).await;
    let _tcp = gui_connect(port, &token, "ping").await;
    let r = hub.call(json!({"cmd":"close","sid":sid,"reason":"nope"})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert!(r["error"].as_str().unwrap().contains("bad reason"), "{r}");
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"quit"}));
    hub.finish().await;
}

#[tokio::test]
async fn reconnect_open_is_logged() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let (_sid, _, _) = embed_open(&mut hub, &a).await;
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","embed":true,"reconnect":true})).await;
    assert_eq!(r["event"], "opened", "{r}");
    assert!(r.get("reconnect").is_none(), "{r}");
    hub.finish().await;
    let opened: Vec<Value> = read_log(home.path(), "hub.log").into_iter().filter(|v| v["ev"] == "opened").collect();
    assert_eq!(opened.len(), 2, "{opened:?}");
    assert!(opened[0].get("reconnect").is_none(), "{}", opened[0]);
    assert_eq!(opened[1]["reconnect"], true, "{}", opened[1]);
}

/// A presence hub with `a` added (presence events that race the reply are skipped).
async fn presence_hub(a: &TestService, home: &std::path::Path) -> Hub {
    let mut hub = Hub::start_with_presence(home, a.bins.path(), Duration::from_millis(200));
    hub.send(json!({"cmd":"add_host","id":at(a),"password":PASSWORD,"req":1})).await;
    loop {
        let r = hub.next().await;
        if r["event"] == "presence" {
            continue;
        }
        assert_eq!(r["event"], "host_added", "{r}");
        return hub;
    }
}

async fn next_presence(hub: &mut Hub, id: &str, online: bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = tokio::time::timeout_at(deadline, hub.next()).await.expect("presence in time");
        assert_ne!(r["event"], "error", "{r}");
        if r == json!({"event":"presence","id":id,"online":online}) {
            return;
        }
    }
}

#[tokio::test]
async fn presence_reports_online_then_offline() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    next_presence(&mut hub, &a.id, true).await;
    a.svc.stop();
    next_presence(&mut hub, &a.id, false).await;
}

#[tokio::test]
async fn ping_is_answered_and_not_logged() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    next_presence(&mut hub, &a.id, true).await;
    next_presence(&mut hub, &a.id, true).await;
    let text = std::fs::read_to_string(a.home.path().join("logs").join("service.log")).expect("service.log exists");
    assert!(!text.is_empty(), "service.log is empty");
    assert!(!text.contains("\"ping\""), "ping in A's log:\n{text}");
    assert!(!text.contains("list_apps"), "list_apps in A's log:\n{text}");
    // hub.log: exactly one presence line (the first observation), however many ticks ran.
    let n = read_log(home.path(), "hub.log").iter().filter(|v| v["ev"] == "presence").count();
    assert_eq!(n, 1, "{:?}", read_log(home.path(), "hub.log"));
}

#[tokio::test]
async fn offline_probe_writes_one_line_per_change_not_per_tick() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    next_presence(&mut hub, &a.id, true).await;
    let before = read_log(home.path(), "hub.log").len();
    a.svc.stop();
    next_presence(&mut hub, &a.id, false).await;
    // Several more offline ticks.
    for _ in 0..3 {
        next_presence(&mut hub, &a.id, false).await;
    }
    let lines = read_log(home.path(), "hub.log");
    let new: Vec<&Value> = lines.iter().skip(before).collect();
    assert_eq!(new.len(), 1, "{new:?}");
    assert_eq!((&new[0]["ev"], &new[0]["id"], &new[0]["online"]), (&json!("presence"), &json!(a.id), &json!(false)));
    for v in &lines {
        assert!(v["ev"] != "route" || v["result"] == "ok", "failed route line: {v}");
        assert!(!v.to_string().contains("reconnecting"), "{v}");
    }
}

#[tokio::test]
async fn stale_password_stops_probing_and_does_not_lock_the_user_out() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let saved = json!([{"id":a.id,"name":"test-a","password":"stale-pass","lan":[a_addr(&a.svc).to_string()]}]);
    rapp_net::config::write_json(&home.path().join("hosts.json"), &saved).unwrap();
    let mut hub = Hub::start_with_presence(home.path(), a.bins.path(), Duration::from_millis(200));
    next_presence(&mut hub, &a.id, false).await;
    // Enough ticks to show the probe stopped: A would log an auth_fail per tick otherwise.
    tokio::time::sleep(Duration::from_millis(2500)).await;
    let r = hub.call(json!({"cmd":"add_host","id":at(&a),"password":PASSWORD,"req":9})).await;
    assert_eq!(r, json!({"event":"host_added","id":a.id,"name":"test-a","req":9}));
    next_presence(&mut hub, &a.id, true).await;
}

#[tokio::test]
async fn removing_a_host_during_a_probe_keeps_it_removed() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let saved = json!([{"id":a.id,"name":"old-name","password":PASSWORD,"lan":[a_addr(&a.svc).to_string()]}]);
    rapp_net::config::write_json(&home.path().join("hosts.json"), &saved).unwrap();
    let mut hub = Hub::start_with_presence(home.path(), a.bins.path(), Duration::from_millis(200));
    // The first probe starts immediately; remove while it is connecting.
    hub.send(json!({"cmd":"remove_host","id":a.id})).await;
    tokio::time::sleep(Duration::from_millis(1000)).await;
    let saved: Value = serde_json::from_slice(&std::fs::read(home.path().join("hosts.json")).unwrap()).unwrap();
    assert_eq!(saved, json!([]));
    let r = hub.call(json!({"cmd":"hosts"})).await;
    assert_eq!(r, json!({"event":"hosts","hosts":[]}));
}

#[tokio::test]
async fn no_presence_without_interval() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let hub = hub_with_host(&a, home.path()).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let rest = hub.finish().await;
    assert!(rest.iter().all(|e| e["event"] != "presence"), "{rest:?}");
}

#[tokio::test]
async fn lan_stale_password_probe_logs_one_auth_fail_on_a() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let saved = json!([{"id":a.id,"name":"test-a","password":"stale-pass","lan":[a_addr(&a.svc).to_string()]}]);
    rapp_net::config::write_json(&home.path().join("hosts.json"), &saved).unwrap();
    let mut hub = Hub::start_with_presence(home.path(), a.bins.path(), Duration::from_millis(200));
    next_presence(&mut hub, &a.id, false).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    // Identical consecutive lines collapse into one plus a `repeat` count, so add the counts up.
    a.svc.stop();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let log = read_log(a.home.path(), "service.log");
    let fails: u64 = log
        .iter()
        .map(|v| match v["ev"].as_str() {
            Some("auth_fail") => 1,
            Some("repeat") => v["repeat"].as_u64().unwrap_or(0),
            _ => 0,
        })
        .sum();
    assert_eq!(fails, 1, "{log:?}");
}

// ---- a host that goes away and comes back on the same address ----

/// An A whose service can be dropped (freeing its port) and started again on that port.
struct LanA {
    home: tempfile::TempDir,
    bins: tempfile::TempDir,
    id: String,
    addr: std::net::SocketAddr,
    svc: Option<rapp_service::Service>,
}

impl LanA {
    async fn start() -> LanA {
        let a = service(None).await;
        let addr = a_addr(&a.svc);
        LanA { home: a.home, bins: a.bins, id: a.id, addr, svc: Some(a.svc) }
    }

    fn stop(&mut self) {
        if let Some(svc) = self.svc.take() {
            svc.stop();
        }
    }

    /// Back on the same port, with the same saved id; retries while the old socket lets go.
    async fn restart(&mut self) {
        let path = self.home.path().join("service.json");
        let mut cfg: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        cfg["port"] = json!(self.addr.port());
        rapp_net::config::write_json(&path, &cfg).unwrap();
        let deadline = tokio::time::Instant::now() + WAIT;
        loop {
            let opts = rapp_service::Opts {
                home: self.home.path().to_path_buf(),
                bin_dir: Some(self.bins.path().to_path_buf()),
                gui: None,
                worker_idle: Duration::from_secs(60),
                log_dir: self.home.path().join("logs"),
                runner: std::sync::Arc::new(rapp_update::fake::FakeRunner::new()),
                update: None,
                data: None,
            };
            match rapp_service::Service::start(opts).await {
                Ok(s) => {
                    self.svc = Some(s);
                    return;
                }
                Err(e) => assert!(tokio::time::Instant::now() < deadline, "restart on {}: {e:#}", self.addr),
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}

#[tokio::test]
async fn host_goes_offline_and_comes_back() {
    let mut a = LanA::start().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start_with_presence(home.path(), a.bins.path(), Duration::from_millis(200));
    hub.send(json!({"cmd":"add_host","id":format!("{}@{}", a.id, a.addr),"password":PASSWORD,"req":1})).await;
    next_presence(&mut hub, &a.id, true).await;

    a.stop();
    next_presence(&mut hub, &a.id, false).await;
    for _ in 0..3 {
        next_presence(&mut hub, &a.id, false).await; // still probing: not halted
    }
    a.restart().await;
    next_presence(&mut hub, &a.id, true).await;
    // Offline ticks wrote no failed route lines.
    for v in read_log(home.path(), "hub.log") {
        assert!(v["ev"] != "route" || v["result"] == "ok", "failed route line: {v}");
    }
    hub.finish().await;
}

#[tokio::test]
async fn bare_id_is_refused_and_nothing_saved() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":a.id,"password":PASSWORD,"req":1})).await;
    assert_eq!(r, json!({"event":"error","error":"id@ip required","req":1}));
    assert!(!home.path().join("hosts.json").exists());
}

#[tokio::test]
async fn host_saved_by_an_old_version_still_connects_over_lan() {
    // hosts.json as a relay-era hub wrote it: ID, name, password and A's LAN addresses.
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let saved = json!([{"id":a.id,"name":"test-a","password":PASSWORD,"lan":[a_addr(&a.svc).to_string()]}]);
    rapp_net::config::write_json(&home.path().join("hosts.json"), &saved).unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path());
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("lan"), &apps()), "{r}");
    hub.finish().await;
}

#[tokio::test]
async fn presence_reports_a_host_without_addresses_as_offline_quietly() {
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    let saved = json!([{"id":"123456789","name":"old","password":"pw","lan":[]}]);
    rapp_net::config::write_json(&home.path().join("hosts.json"), &saved).unwrap();
    let mut hub = Hub::start_with_presence(home.path(), bins.path(), Duration::from_millis(200));
    // Several ticks: it is offline each time, never halted.
    for _ in 0..4 {
        next_presence(&mut hub, "123456789", false).await;
    }
    let lines = read_log(home.path(), "hub.log");
    let presence = lines.iter().filter(|v| v["ev"] == "presence").count();
    assert_eq!(presence, 1, "one line for the first observation, not one per tick: {lines:?}");
    for v in &lines {
        assert!(v["ev"] != "route" && v["lvl"] != "warn", "log spam: {v}");
    }
    hub.finish().await;
}

#[tokio::test]
async fn saved_host_without_addresses_says_so() {
    // hosts.json from before: a bare-ID host the relay never gave LAN addresses for.
    let home = tempfile::tempdir().unwrap();
    std::fs::write(
        home.path().join("hosts.json"),
        r#"[{"id":"123456789","name":"old","password":"pw","lan":[]}]"#,
    )
    .unwrap();
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    let r = hub.call(json!({"cmd":"apps","id":"123456789","req":1})).await;
    assert_eq!(r, json!({"event":"error","error":"no address: add the host again as id@ip","req":1}));
}

#[tokio::test]
async fn set_home_reads_hosts_from_the_new_dir() {
    let a = service(None).await;
    let (home1, home2) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    rapp_net::config::write_json(
        &home2.path().join("hosts.json"),
        &json!([{"id":"111111111","name":"n","password":"p","lan":[]}]),
    )
    .unwrap();
    let mut hub = Hub::start(home1.path(), a.bins.path());
    let r = hub.call(json!({"cmd":"set_home","dir":home2.path(),"req":1})).await;
    assert_eq!(r, json!({"event":"home_set","req":1}));
    let r = hub.call(json!({"cmd":"hosts"})).await;
    assert_eq!(r["hosts"], json!([{"id":"111111111","name":"n"}]));
    assert!(!r.to_string().contains("\"p\""));
    hub.finish().await;
}
