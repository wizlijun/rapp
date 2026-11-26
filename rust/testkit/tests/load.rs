//! Device load (spec 2026-11-26 §10): `load` / `watch_load` between devices, and `load` / `load_all` /
//! `watch_load` on the local IPC.

mod common;

use common::*;
use quinn::{Connection, Endpoint};
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::{bi, BiStream};
use rapp_update::fake::FakeRunner;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

/// B, authenticated by password (the endpoint must outlive the connection).
async fn b(a: &TestService) -> (Endpoint, Connection) {
    let ep = b_endpoint();
    let (conn, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    assert_eq!(r["ok"], true, "{r}");
    (ep, conn)
}

/// `req` again until the reply is ok: the sampler's first tick may not have come yet.
async fn req_ok(conn: &Connection, v: Value) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = req(conn, v.clone()).await;
        if r["ok"] == true {
            return r;
        }
        assert_eq!(r, json!({"ok":false,"error":"no data"}), "only `no data` is waited out");
        assert!(tokio::time::Instant::now() < deadline, "never any data: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A service with no load sampling, as an older device answers.
async fn service_without_load(home: &Path, bins: &Path) -> rapp_service::Service {
    service_with_load(home, bins, None).await
}

/// A service whose load sampling is `load`.
async fn service_with_load(home: &Path, bins: &Path, load: Option<rapp_service::LoadOpts>) -> rapp_service::Service {
    rapp_service::Service::start(rapp_service::Opts {
        home: home.to_path_buf(),
        bin_dir: Some(bins.to_path_buf()),
        gui: None,
        lock_grace: Duration::from_secs(1),
        worker_idle: Duration::from_secs(60),
        log_dir: home.join("logs"),
        runner: Arc::new(FakeRunner::new()),
        update: None,
        data: None,
        advertise_lan: None,
        forward_sum_every: Duration::from_secs(600),
        forward_priority: rapp_conn::relay::FORWARD_PRIORITY,
        channels: true,
        pacing: true,
        map_ports: TEST_PORTS,
        own_ports: true,
        load,
    })
    .await
    .unwrap()
}

/// The share of the tightest readable disk in `r["disks"]`, as `rules.rs` counts it: free / 0.20, capped at 1.
fn disk_share(r: &Value) -> Option<f64> {
    r["disks"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|d| d["unreadable"] != true && d["total"].as_u64().unwrap_or(0) > 0)
        .map(|d| d["avail"].as_f64().unwrap() / d["total"].as_f64().unwrap())
        .reduce(f64::min)
        .map(|f| (f / 0.20).min(1.0))
}

/// `r` with what the test machine's real disks put in it taken out (ruling R1): `at` and `disks` overwritten,
/// `disk:*` / `inode:*` warnings dropped.
fn without_machine(mut r: Value) -> Value {
    r["at"] = json!(0);
    r["disks"] = json!([]);
    if let Some(ws) = r["warnings"].as_array_mut() {
        ws.retain(|w| {
            let item = w["item"].as_str().unwrap_or("");
            !item.starts_with("disk:") && !item.starts_with("inode:")
        });
    }
    r
}

/// What `fake_load()` gives, once the real disks are taken out; `headroom` / `tightest` follow those disks.
fn want_fake(r: &Value) -> Value {
    // fake_load: cpu 10% (share 0.9), memory 8 of 16 GB (0.5), heat normal (1). A tie goes to mem (before disk).
    let (headroom, tightest) = match disk_share(r) {
        Some(d) if d < 0.5 => ((d * 100.0).round() as u64, "disk"),
        _ => (50, "mem"),
    };
    json!({
        "ok": true, "at": 0, "headroom": headroom, "tightest": tightest, "term": true,
        "items": {
            "cpu": {"pct": 10.0, "cores": 8},
            "mem": {"total": 16_000_000_000u64, "avail": 8_000_000_000u64},
            "heat": {"level": "normal"}
        },
        "disks": [],
        "warnings": []
    })
}

async fn next(s: &mut BiStream) -> Value {
    tokio::time::timeout(WAIT, read_json(s)).await.expect("a watch line in time").unwrap()
}

#[tokio::test]
async fn load_answers_a_snapshot() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let r = req_ok(&conn, json!({"op":"load"})).await;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let at = r["at"].as_u64().unwrap();
    assert!(at + 60 > now && at <= now + 1, "at {at}, now {now}");
    assert!(r.get("history").is_none(), "{r}");
    assert!(r.get("top").is_none(), "{r}");
    assert!(r["disks"].is_array(), "{r}");
    assert_eq!(without_machine(r.clone()), want_fake(&r));
    // `top` is accepted; the first version has nothing to give for it.
    let r = req_ok(&conn, json!({"op":"load","top":true})).await;
    assert!(r.get("top").is_none(), "{r}");
    // `term` follows `term.json`: no terminals here once they are switched off.
    std::fs::write(a.home.path().join("term.json"), r#"{"allow":false}"#).unwrap();
    assert_eq!(req_ok(&conn, json!({"op":"load"})).await["term"], false);
    // Polled: a success is not logged.
    let h = ipc_once(&a.svc, a.home.path(), json!({"cmd":"history","limit":50})).await;
    assert!(!h.to_string().contains("\"load\""), "{h}");
    assert!(!std::fs::read_to_string(a.home.path().join("logs/service.log")).unwrap_or_default().contains("\"op\":\"load\""));
}

#[tokio::test]
async fn load_with_history() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let r = req_ok(&conn, json!({"op":"load","history":true})).await;
    let hist = r["history"].as_array().unwrap_or_else(|| panic!("no history: {r}"));
    assert!(!hist.is_empty(), "{r}");
    assert_eq!(hist.last().unwrap()["cpu"], json!(10.0), "{r}");
    assert_eq!(hist.last().unwrap()["mem"], json!(0.5), "{r}");
}

#[tokio::test]
async fn watch_load_streams_points() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    // Wait for data, so the stream's first line is not `no data`.
    req_ok(&conn, json!({"op":"load"})).await;
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"watch_load"})).await.unwrap();
    let first = next(&mut s).await;
    assert_eq!(first["ok"], true, "{first}");
    assert!(first["history"].as_array().is_some_and(|h| !h.is_empty()), "{first}");
    assert!(first.get("point").is_none(), "{first}");
    // `at` is in whole seconds and the fake samples every 200 ms: lines follow each other in order, and within a
    // couple of seconds `at` has gone up.
    let mut last = first["at"].as_u64().unwrap();
    let mut rose = 0;
    for _ in 0..30 {
        let line = next(&mut s).await;
        assert_eq!(line["ok"], true, "{line}");
        assert!(line.get("history").is_none(), "{line}");
        let at = line["point"]["at"].as_u64().unwrap_or_else(|| panic!("no point: {line}"));
        assert_eq!(line["at"], json!(at), "{line}");
        assert_eq!(line["point"]["cpu"], json!(10.0), "{line}");
        assert!(line["headroom"].is_u64(), "{line}");
        assert!(at >= last, "at went back: {last} → {at}");
        if at > last {
            rose += 1;
        }
        last = at;
        if rose == 2 {
            break;
        }
    }
    assert_eq!(rose, 2, "at never rose twice");
    // B's close ends the watch: the service closes its side.
    s.shutdown().await.unwrap();
    let mut rest = Vec::new();
    let read = tokio::time::timeout(WAIT, tokio::io::AsyncReadExt::read_to_end(&mut s, &mut rest)).await;
    assert!(read.is_ok(), "the watch did not end");
}

#[tokio::test]
async fn load_is_unknown_without_load_opts() {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    let svc = service_without_load(home.path(), bins.path()).await;
    let a = TestService { id: String::new(), svc, home, bins };
    let (_ep, conn) = b(&a).await;
    for op in [json!({"op":"load"}), json!({"op":"load","history":true}), json!({"op":"watch_load"})] {
        assert_eq!(req(&conn, op.clone()).await, json!({"ok":false,"error":"unknown op"}), "{op}");
    }
    assert_eq!(req(&conn, json!({"op":"list_apps"})).await["ok"], true);
    // The local IPC says the same.
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"load"})).await;
    assert_eq!(r, json!({"ok":false,"error":"unknown op"}));
}

/// `load_all` again until every row has `load` or an error other than `no data`.
async fn load_all(svc: &rapp_service::Service, home: &Path, cmd: Value) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = ipc_once(svc, home, cmd.clone()).await;
        assert_eq!(r["ok"], true, "{r}");
        if r["devices"].as_array().unwrap().iter().all(|d| d["error"] != "no data") {
            return r;
        }
        assert!(tokio::time::Instant::now() < deadline, "never any data: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn ipc_load_all_lists_local_first() {
    let a = service().await;
    assert!(!a.home.path().join("hosts.json").exists());
    let r = load_all(&a.svc, a.home.path(), json!({"cmd":"load_all"})).await;
    let devices = r["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 1, "{r}");
    let me = &devices[0];
    assert_eq!((&me["id"], &me["name"], &me["local"]), (&json!(a.id), &json!("test-a"), &json!(true)), "{r}");
    let load = &me["load"];
    assert!(load.get("ok").is_none(), "{r}");
    let mut with_ok = load.clone();
    with_ok["ok"] = json!(true);
    assert_eq!(without_machine(with_ok.clone()), want_fake(&with_ok));
    // The local device matches its own name or id, in any case; nothing else matches.
    let r = load_all(&a.svc, a.home.path(), json!({"cmd":"load_all","devices":["TEST-A"]})).await;
    assert_eq!(r["devices"].as_array().unwrap().len(), 1, "{r}");
    let r = load_all(&a.svc, a.home.path(), json!({"cmd":"load_all","devices":[a.id]})).await;
    assert_eq!(r["devices"].as_array().unwrap().len(), 1, "{r}");
    let r = load_all(&a.svc, a.home.path(), json!({"cmd":"load_all","devices":["other"]})).await;
    assert_eq!(r, json!({"ok":true,"devices":[]}));
    // The IPC `load` is the device request's reply (there is data by now: `load_all` waited for it).
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"load","history":true})).await;
    assert!(r["history"].as_array().is_some_and(|h| !h.is_empty()), "{r}");
    let mut plain = r.clone();
    plain.as_object_mut().unwrap().remove("history");
    assert_eq!(without_machine(plain.clone()), want_fake(&plain));
    // Polled: none of it is in the access history.
    let h = ipc_once(&a.svc, a.home.path(), json!({"cmd":"history","limit":50})).await;
    assert_eq!(h["events"], json!([]), "{h}");
}

#[tokio::test]
async fn ipc_watch_load_takes_over_the_connection() {
    let a = service().await;
    load_all(&a.svc, a.home.path(), json!({"cmd":"load_all"})).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    ipc.send(json!({"cmd":"watch_load"})).await;
    let first = ipc.next().await;
    assert_eq!(first["ok"], true, "{first}");
    assert!(first["history"].as_array().is_some_and(|h| !h.is_empty()), "{first}");
    let line = ipc.next().await;
    assert_eq!(line["ok"], true, "{line}");
    assert!(line["point"]["at"].is_u64(), "{line}");
    // From here the connection only carries the stream: a command gets no reply, just more lines.
    ipc.send(json!({"cmd":"status"})).await;
    for _ in 0..3 {
        let line = ipc.next().await;
        assert!(line.get("point").is_some(), "{line}");
    }
}

#[tokio::test]
async fn ipc_load_all_marks_old_device() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let old = service_on_relay_with(&rig.addr, &rig.key, Some(vec![]), |o| o.load = None).await;
    let new = a_on_relay(&rig, Some(vec![])).await;
    let mut ipc = Ipc::open(&old.svc, old.home.path()).await;
    wait_status(&mut ipc, |s| s["relay"] == "connected").await;
    let hosts = json!([
        {"id": old.id, "name": "Old", "lan": [a_addr(&old.svc).to_string()]},
        {"id": new.id, "name": "New", "lan": [a_addr(&new.svc).to_string()]},
        // In hosts.json, but nothing there answers.
        {"id": "999999999", "name": "Gone", "lan": ["127.0.0.1:1"]},
    ]);
    std::fs::write(a.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    let r = load_all(&a.svc, a.home.path(), json!({"cmd":"load_all"})).await;
    let devices = r["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 4, "{r}");
    assert_eq!((&devices[0]["id"], &devices[0]["local"]), (&json!(a.id), &json!(true)), "{r}");
    assert!(devices[0]["load"]["headroom"].is_u64(), "{r}");
    assert_eq!(devices[1], json!({"id": old.id, "name": "Old", "error": "old version"}), "{r}");
    assert_eq!((&devices[2]["id"], &devices[2]["name"]), (&json!(new.id), &json!("New")), "{r}");
    assert!(devices[2].get("local").is_none() && devices[2].get("error").is_none(), "{r}");
    assert!(devices[2]["load"].get("ok").is_none(), "{r}");
    assert_eq!(devices[2]["load"]["items"]["cpu"]["pct"], json!(10.0), "{r}");
    assert_eq!(devices[3]["id"], "999999999", "{r}");
    assert!(devices[3]["error"].is_string() && devices[3]["error"] != "old version", "{r}");
    // `devices` keeps the ones named, by id or name, in any case.
    let r = load_all(&a.svc, a.home.path(), json!({"cmd":"load_all","devices":["old", new.id]})).await;
    let ids: Vec<&Value> = r["devices"].as_array().unwrap().iter().map(|d| &d["id"]).collect();
    assert_eq!(ids, vec![&json!(old.id), &json!(new.id)], "{r}");
}

/// `fake_load()`'s machine, whose first sample takes `first` (later ones are at once).
fn slow_first_load(first: Duration) -> rapp_service::LoadOpts {
    use rapp_service::load::{Cpu, Heat, HeatLevel, Mem, Sample, Sampler};
    struct Slow(Option<Duration>);
    impl Sampler for Slow {
        fn sample(&mut self) -> Sample {
            if let Some(d) = self.0.take() {
                std::thread::sleep(d);
            }
            let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
            Sample {
                at,
                cpu: Some(Cpu { pct: 10.0, cores: 8, load1: None }),
                mem: Some(Mem { total: 16_000_000_000, avail: 8_000_000_000, swap_used: None, pressure: None }),
                heat: Some(Heat { level: HeatLevel::Normal, celsius: None }),
                ..Default::default()
            }
        }
    }
    rapp_service::LoadOpts {
        every: Duration::from_millis(200),
        sampler: Arc::new(move || Box::new(Slow(Some(first)))),
        disk_wait: Duration::from_secs(2),
    }
}

#[tokio::test]
async fn watch_load_waits_for_the_first_sample() {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    let svc = service_with_load(home.path(), bins.path(), Some(slow_first_load(Duration::from_secs(3)))).await;
    let a = TestService { id: String::new(), svc, home, bins };
    let (_ep, conn) = b(&a).await;
    // No sample yet: the one-shot `load` says so.
    assert_eq!(req(&conn, json!({"op":"load"})).await, json!({"ok":false,"error":"no data"}));
    let mut watch = bi(conn.open_bi().await.unwrap());
    write_json(&mut watch, &json!({"op":"watch_load"})).await.unwrap();
    // A watch closed while it waits ends at once, with nothing written.
    let mut gone = bi(conn.open_bi().await.unwrap());
    write_json(&mut gone, &json!({"op":"watch_load"})).await.unwrap();
    let began = std::time::Instant::now();
    gone.shutdown().await.unwrap();
    let mut rest = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), tokio::io::AsyncReadExt::read_to_end(&mut gone, &mut rest))
        .await
        .expect("a watch closed while waiting ends")
        .unwrap();
    assert!(rest.is_empty(), "{}", String::from_utf8_lossy(&rest));
    assert!(began.elapsed() < Duration::from_secs(2), "{:?}", began.elapsed());
    assert_eq!(req(&conn, json!({"op":"load"})).await, json!({"ok":false,"error":"no data"}), "the sample came too soon");
    // The open one's first line is the snapshot with history, once the sample is there.
    let first = next(&mut watch).await;
    assert_eq!(first["ok"], true, "{first}");
    assert!(first["history"].as_array().is_some_and(|h| !h.is_empty()), "{first}");
    assert_eq!(first["items"]["cpu"]["pct"], json!(10.0), "{first}");
    let line = next(&mut watch).await;
    assert!(line["point"]["at"].is_u64(), "{line}");
}

#[tokio::test]
async fn a_broken_term_json_does_not_fill_the_log() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    req_ok(&conn, json!({"op":"load"})).await;
    std::fs::write(a.home.path().join("term.json"), "{not json").unwrap();
    for _ in 0..5 {
        assert_eq!(req_ok(&conn, json!({"op":"load"})).await["term"], false);
        let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"load"})).await;
        assert_eq!(r["term"], false, "{r}");
    }
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"watch_load"})).await.unwrap();
    for _ in 0..5 {
        assert_eq!(next(&mut s).await["term"], false);
    }
    // A terminal request still reports it: its warning, then its `request` line. The log folds identical lines in
    // a row into a `repeat` line, written before the next different one; so had the load path warned too, there
    // would be a `repeat` line (or more warnings) in between.
    assert_eq!(req(&conn, json!({"op":"list_terms"})).await, json!({"ok":false,"error":"term.json is invalid"}));
    let home = a.home.path();
    wait_log(home, "request", |v| v["op"] == "list_terms").await;
    let evs = log_events(home);
    let warned: Vec<usize> = (0..evs.len())
        .filter(|&i| evs[i]["msg"].as_str().is_some_and(|m| m.contains("not the expected JSON")))
        .collect();
    assert_eq!(warned.len(), 1, "{evs:#?}");
    let after = &evs[warned[0] + 1];
    assert_eq!((&after["ev"], &after["op"]), (&json!("request"), &json!("list_terms")), "{evs:#?}");
}
