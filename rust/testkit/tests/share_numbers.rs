//! Port sharing, global ports (task 2): the sharer listens on its share numbers and says them
//! (with the protocol) to its own IPC and to other devices.

mod common;
use common::sharing::*;
use common::*;

use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

async fn ipc(s: &TestService, cmd: Value) -> Value {
    ipc_once(&s.svc, s.home.path(), cmd).await
}

/// The own `shares` row of `port`.
async fn row(a: &TestService, port: u16) -> Value {
    let r = ipc(a, json!({"cmd":"shares"})).await;
    assert_eq!(r["ok"], true, "{r}");
    r["shares"].as_array().unwrap().iter().find(|s| s["port"] == port).cloned().unwrap_or(Value::Null)
}

fn saved(home: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(home.join("shares.json")).unwrap()).unwrap()
}

/// Writes `data` to `127.0.0.1:<local>`, finishes writing, and reads to the end.
async fn through(local: u16, data: &[u8]) -> Vec<u8> {
    let mut c = TcpStream::connect(("127.0.0.1", local)).await.expect("the number accepts");
    c.write_all(data).await.unwrap();
    c.shutdown().await.unwrap();
    let mut got = Vec::new();
    tokio::time::timeout(WAIT, c.read_to_end(&mut got)).await.expect("ends in time").unwrap();
    got
}

async fn refuses(local: u16) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while TcpStream::connect(("127.0.0.1", local)).await.is_ok() {
        assert!(tokio::time::Instant::now() < deadline, "{local} still accepts");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A sharer with `shares` in its table, numbering from `first` (ten numbers), once every share
/// that can has its number (the numbering of an old table runs just after start).
async fn numbered(shares: Value, first: u16) -> (TestService, rapp_wire::Key) {
    let count = shares.as_array().unwrap().len();
    let (a, key) = start_sharing_ports(|home| share_file(home, shares), (first, 10)).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let r = ipc(&a, json!({"cmd":"shares"})).await;
        let n = r["shares"].as_array().unwrap().iter().filter(|s| s["local"].is_number()).count();
        if n == count {
            return (a, key);
        }
        assert!(tokio::time::Instant::now() < deadline, "never numbered: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn a_share_gets_a_number_and_the_sharer_listens_on_it() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([{"port": port}]), 29500).await;
    let r = row(&a, port).await;
    assert_eq!((&r["local"], &r["addr"]), (&json!(29500), &json!("tcp://localhost:29500")), "{r}");
    assert_eq!(through(29500, b"hi").await, b"hi");
    assert_eq!(saved(a.home.path())[0]["local"], 29500);
}

#[tokio::test]
async fn a_new_share_gets_the_next_number() {
    let (first, _e1) = echo().await;
    let (second, _e2) = echo().await;
    let (a, _) = numbered(json!([{"port": first}]), 29510).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[second]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let s = &r["shared"][0];
    assert_eq!(
        (&s["local"], &s["proto"], &s["proto_auto"], &s["addr"]),
        (&json!(29511), &json!("tcp"), &json!(true), &json!("tcp://localhost:29511")),
        "{r}"
    );
    assert_eq!(through(29511, b"x").await, b"x");
}

#[tokio::test]
async fn list_shares_and_shares_carry_the_number_and_protocol() {
    let (port, _echo) = echo().await;
    let (a, key) = numbered(json!([{"port": port}]), 29520).await;
    let b = visitor();
    let (r, ..) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!((&r["shares"][0]["local"], &r["shares"][0]["proto"]), (&json!(29520), &json!("tcp")), "{r}");
    let (r, ..) = ask(&a, &key, &b, json!({"op":"shares"})).await;
    let s = &r["shares"][0];
    assert_eq!((&s["local"], &s["proto"], &s["proto_auto"]), (&json!(29520), &json!("tcp"), &json!(true)), "{r}");
}

#[tokio::test]
async fn a_proto_given_is_kept() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([]), 29530).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[port],"proto":"tcp"})).await;
    let s = &r["shared"][0];
    assert_eq!((&s["addr"], &s["proto_auto"]), (&json!("tcp://localhost:29530"), &json!(false)), "{r}");
    let r = ipc(&a, json!({"cmd":"share","ports":[port],"note":"n"})).await;
    assert_eq!(r["shared"][0]["proto"], "tcp", "{r}");
    let r = ipc(&a, json!({"cmd":"share","ports":[port],"proto":"ftp"})).await;
    assert_eq!(r, json!({"ok":false,"error":"bad proto"}));
}

#[tokio::test]
async fn a_share_number_another_program_has_on_the_sharer_stays() {
    let (port, _echo) = echo().await;
    let theirs = std::net::TcpListener::bind(("127.0.0.1", 29540)).unwrap();
    let (a, _) = numbered(json!([{"port": port, "local": 29540}]), 29540).await;
    let r = row(&a, port).await;
    assert_eq!((&r["taken"], &r["local"]), (&json!(true), &json!(29540)), "{r}");
    drop(theirs);
    let r = row(&a, port).await;
    assert!(r.get("taken").is_none(), "{r}");
    assert_eq!(through(29540, b"back").await, b"back");
}

#[tokio::test]
async fn unshare_closes_the_number() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([{"port": port}]), 29545).await;
    assert_eq!(through(29545, b"x").await, b"x");
    let r = ipc(&a, json!({"cmd":"unshare","port":port})).await;
    assert_eq!(r["was"], true, "{r}");
    refuses(29545).await;
}

#[tokio::test]
async fn a_share_with_no_number_left_has_no_address() {
    let (port, _echo) = echo().await;
    let _theirs = std::net::TcpListener::bind(("127.0.0.1", 29550)).unwrap();
    let (a, _) = start_sharing_ports(|_| {}, (29550, 1)).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[port]})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["shared"][0]["addr"], "", "{r}");
    assert!(r["shared"][0].get("local").is_none(), "{r}");
    let r = row(&a, port).await;
    assert_eq!(r["addr"], "", "{r}");
    assert!(r.get("local").is_none(), "{r}");
}

#[tokio::test]
async fn an_old_table_is_numbered_at_start() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([{"port": port}]), 29560).await;
    // Done by a task after start, with no hosts.json to ask.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let r = row(&a, port).await;
        if r["local"] == 29560 {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "never numbered: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(through(29560, b"x").await, b"x");
}

#[tokio::test]
async fn an_old_table_avoids_the_numbers_of_devices_online_at_start() {
    let (theirs, _e1) = echo().await;
    let (mine, _e2) = echo().await;
    // B does not listen on its numbers (one machine), so A can tell only by asking B.
    let (b, key) = start_sharing_opts(|home| share_file(home, json!([{"port": theirs}])), (29570, 10), false, None).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    while row(&b, theirs).await["local"] != 29570 {
        assert!(tokio::time::Instant::now() < deadline, "B never numbered");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let hosts = json!([{"id": b.id, "name": "b", "lan": [a_addr(&b.svc).to_string()]}]);
    let (a, _) = start_sharing_opts(
        |home| {
            share_file(home, json!([{"port": mine}]));
            std::fs::write(home.join("hosts.json"), hosts.to_string()).unwrap();
        },
        (29570, 10),
        true,
        Some(key),
    )
    .await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let r = row(&a, mine).await;
        if r["local"].is_number() {
            assert_eq!(r["local"], 29571, "{r}");
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "A never numbered: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

// Task 3: visitors take the share number, or yield and say so. The sharer here does not listen
// on its numbers (`own_ports` off), so that its visitors on the same machine can take them.

/// A visitor trusting `key` that knows `a` by its LAN address and gives ports from `first`
/// (ten): the same range as the sharer's, as on real devices.
async fn visiting(first: u16, key: &rapp_wire::Key, a: &TestService) -> TestService {
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    let key = key.to_string().parse().unwrap();
    let write = |home: &Path| std::fs::write(home.join("hosts.json"), hosts.to_string()).unwrap();
    start_sharing_opts(write, (first, 10), true, Some(key)).await.0
}

/// A sharer of `port` on the number `first`, not listening on it itself.
async fn sharer_on(port: u16, first: u16) -> (TestService, rapp_wire::Key) {
    start_sharing_opts(|home| share_file(home, json!([{"port": port, "local": first}])), (first, 10), false, None).await
}

/// `b`'s `shares` of `a`: the whole reply, after checking it is ok.
async fn table_of(b: &TestService, a: &TestService) -> Value {
    let r = ipc(b, json!({"cmd":"shares","to":a.id})).await;
    assert_eq!(r["ok"], true, "{r}");
    r
}

/// `b`'s `shares` of `a`: the row of `port`.
async fn their_row(b: &TestService, a: &TestService, port: u16) -> Value {
    let r = table_of(b, a).await;
    r["shares"].as_array().unwrap().iter().find(|s| s["port"] == port).cloned().unwrap_or(Value::Null)
}

/// `b`'s `hosts`: the item of `port` of `a`.
async fn hosts_item(b: &TestService, a: &TestService, port: u16) -> Value {
    let r = ipc(b, json!({"cmd":"hosts"})).await;
    let h = r["hosts"].as_array().unwrap().iter().find(|h| h["id"] == a.id.as_str()).cloned().unwrap_or(Value::Null);
    h["shares"].as_array().into_iter().flatten().find(|s| s["port"] == port).cloned().unwrap_or(Value::Null)
}

#[tokio::test]
async fn a_visitor_uses_the_share_number_and_a_second_one_yields() {
    let (port, _echo) = echo().await;
    let (a, key) = sharer_on(port, 29600).await;
    let b = visiting(29600, &key, &a).await;
    let c = visiting(29600, &key, &a).await;
    let r = table_of(&b, &a).await;
    assert_eq!(r["old"], false, "{r}");
    let s = &r["shares"][0];
    assert_eq!((&s["local"], &s["addr"], &s["proto"], &s["proto_auto"]), (&json!(29600), &json!("tcp://localhost:29600"), &json!("tcp"), &json!(true)), "{r}");
    assert!(s.get("wanted").is_none(), "{r}");
    assert_eq!(through(29600, b"hi").await, b"hi");
    let s = their_row(&c, &a, port).await;
    assert_eq!((&s["local"], &s["wanted"], &s["addr"]), (&json!(29601), &json!(29600), &json!("tcp://localhost:29601")), "{s}");
    assert_eq!(through(29601, b"too").await, b"too");
}

#[tokio::test]
async fn the_yielded_visitor_moves_back() {
    let (port, _echo) = echo().await;
    let (a, key) = sharer_on(port, 29610).await;
    let b = visiting(29610, &key, &a).await;
    let c = visiting(29610, &key, &a).await;
    assert_eq!(their_row(&b, &a, port).await["local"], 29610);
    assert_eq!(their_row(&c, &a, port).await["wanted"], 29610);
    b.svc.stop();
    refuses(29610).await;
    let s = their_row(&c, &a, port).await;
    assert_eq!((&s["local"], &s["addr"]), (&json!(29610), &json!("tcp://localhost:29610")), "{s}");
    assert!(s.get("wanted").is_none(), "{s}");
    assert_eq!(through(29610, b"back").await, b"back");
    refuses(29611).await;
}

#[tokio::test]
async fn hosts_carries_the_number_and_the_yield() {
    let (port, _echo) = echo().await;
    let (a, key) = sharer_on(port, 29620).await;
    let b = visiting(29620, &key, &a).await;
    let c = visiting(29620, &key, &a).await;
    let s = hosts_item(&b, &a, port).await;
    assert_eq!(
        s,
        json!({"port": port, "proto": "http", "proto_auto": true, "web": true, "local": 29620, "addr": "http://localhost:29620"})
    );
    let s = hosts_item(&c, &a, port).await;
    assert_eq!((&s["local"], &s["wanted"], &s["addr"]), (&json!(29621), &json!(29620), &json!("http://localhost:29621")), "{s}");
    assert_eq!(through(29621, b"x").await, b"x");
}

#[tokio::test]
async fn an_old_sharer_still_works() {
    let (port, _echo) = echo().await;
    // In the (0, 0) range the sharer has no number to give, like a sharer from before numbers.
    let (a, key) = start_sharing_opts(|home| share_file(home, json!([{"port": port}])), (0, 0), false, None).await;
    let b = visiting(29630, &key, &a).await;
    let r = table_of(&b, &a).await;
    let s = &r["shares"][0];
    assert_eq!((&s["local"], &s["addr"]), (&json!(29630), &json!("tcp://localhost:29630")), "{r}");
    assert!(s.get("wanted").is_none(), "{r}");
    assert_eq!(through(29630, b"old").await, b"old");
    let s = hosts_item(&b, &a, port).await;
    assert_eq!(s["local"], 29630, "{s}");
    assert!(s.get("wanted").is_none(), "{s}");
}

/// A server that writes `data: <n>\n\n` every 100 ms to every connection, like an SSE stream.
async fn ticking() -> (u16, tokio::task::JoinHandle<()>) {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let task = tokio::spawn(async move {
        while let Ok((mut c, _)) = l.accept().await {
            let _ = c.set_nodelay(true);
            tokio::spawn(async move {
                for n in 0u64.. {
                    if c.write_all(format!("data: {n}\n\n").as_bytes()).await.is_err() {
                        return;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            });
        }
    });
    (port, task)
}

/// Reads the events of `127.0.0.1:<local>` for `within` from the first one: the longest gap between two of them,
/// and how many came.
async fn longest_gap(local: u16, within: Duration) -> (Duration, usize) {
    let mut c = TcpStream::connect(("127.0.0.1", local)).await.expect("accepts");
    c.write_all(b"GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n").await.unwrap();
    let (mut buf, mut n, mut last, mut worst) = (Vec::new(), 0usize, None::<tokio::time::Instant>, Duration::ZERO);
    let mut chunk = [0u8; 4096];
    let mut end = None;
    loop {
        let now = tokio::time::Instant::now();
        if end.is_some_and(|e| now >= e) {
            return (worst, n);
        }
        let wait = end.map_or(WAIT, |e: tokio::time::Instant| e - now);
        let got = match tokio::time::timeout(wait, c.read(&mut chunk)).await {
            Ok(r) => r.unwrap(),
            Err(_) => return (worst, n),
        };
        assert!(got > 0, "the stream ended");
        buf.extend_from_slice(&chunk[..got]);
        let at = tokio::time::Instant::now();
        while let Some(i) = buf.windows(2).position(|w| w == b"\n\n") {
            buf.drain(..i + 2);
            if let Some(l) = last {
                worst = worst.max(at - l);
            } else {
                // The gaps are counted from the first event: the road is set up before it.
                end = Some(at + within);
            }
            (last, n) = (Some(at), n + 1);
        }
    }
}

#[tokio::test]
async fn long_lived_streams_are_not_held_back() {
    let (port, _ticks) = ticking().await;
    let (a, key) = sharer_on(port, 29640).await;
    let b = visiting(29640, &key, &a).await;
    assert_eq!(their_row(&b, &a, port).await["local"], 29640);
    // A second sharer of the same server that listens on its own number.
    let (own, _) = numbered(json!([{"port": port}]), 29650).await;
    assert_eq!(row(&own, port).await["local"], 29650);
    let within = Duration::from_secs(3);
    let (visited, at_home) = tokio::join!(longest_gap(29640, within), longest_gap(29650, within));
    for (what, (gap, n)) in [("through the visitor's map", visited), ("on the sharer's own number", at_home)] {
        assert!(n >= 25, "{what}: only {n} events");
        assert!(gap <= Duration::from_millis(200), "{what}: a gap of {gap:?}");
    }
}

/// A share number outside the visitor's own range is not taken (it could be a port the user's
/// own servers need) and not shown as wanted: the visitor maps the share as for a sharer from
/// before numbers, in its own range.
#[tokio::test]
async fn a_number_outside_the_visitors_range_is_ignored() {
    let (port, _echo) = echo().await;
    let (a, key) = sharer_on(port, 29700).await;
    let b = visiting(29710, &key, &a).await;
    let s = their_row(&b, &a, port).await;
    assert_eq!((&s["local"], &s["addr"]), (&json!(29710), &json!("tcp://localhost:29710")), "{s}");
    assert!(s.get("wanted").is_none(), "{s}");
    let s = hosts_item(&b, &a, port).await;
    assert_eq!((&s["local"], &s["addr"]), (&json!(29710), &json!("tcp://localhost:29710")), "{s}");
    assert!(s.get("wanted").is_none(), "{s}");
    assert_eq!(through(29710, b"x").await, b"x");
    refuses(29700).await;
}

// Task 4: two sharers on one number — the larger ID moves. Both sharers have `own_ports` off
// (one machine), so both are numbered `first` before they know each other.

/// Two sharers of `first` (ten numbers) that share a key: `(larger ID, smaller ID)`, each with
/// its echo kept alive. Neither knows the other yet.
async fn clashing(first: u16) -> (TestService, TestService, rapp_wire::Key, Vec<tokio::task::JoinHandle<()>>) {
    let (p1, e1) = echo().await;
    let (p2, e2) = echo().await;
    let (x, key) = start_sharing_opts(|home| share_file(home, json!([{"port": p1}])), (first, 10), false, None).await;
    let y = start_sharing_opts(|home| share_file(home, json!([{"port": p2}])), (first, 10), false, Some(key.to_string().parse().unwrap())).await.0;
    for (s, p) in [(&x, p1), (&y, p2)] {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
        while row(s, p).await["local"] != first {
            assert!(tokio::time::Instant::now() < deadline, "never numbered");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
    let larger = |a: &str, b: &str| a.parse::<u64>().unwrap() > b.parse::<u64>().unwrap();
    let (l, s) = if larger(&x.id, &y.id) { (x, y) } else { (y, x) };
    (l, s, key, vec![e1, e2])
}

/// Each of `a` and `b` knows the other, as `name`, by its LAN address.
fn introduce(a: &TestService, an: &str, b: &TestService, bn: &str) {
    for (me, other, name) in [(a, b, bn), (b, a, an)] {
        let hosts = json!([{"id": other.id, "name": name, "lan": [a_addr(&other.svc).to_string()]}]);
        std::fs::write(me.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    }
}

/// The own row of whichever share of `t` has `port`, after `t` has read `other`'s table.
async fn read(t: &TestService, other: &TestService) {
    table_of(t, other).await;
}

/// The only own share of `t`.
async fn only(t: &TestService) -> Value {
    let r = ipc(t, json!({"cmd":"shares"})).await;
    r["shares"][0].clone()
}

#[tokio::test]
async fn two_sharers_on_one_number_the_larger_id_moves() {
    let (l, s, _key, _echoes) = clashing(29720).await;
    introduce(&l, "larger", &s, "smaller");
    read(&l, &s).await;
    read(&s, &l).await;
    let r = only(&l).await;
    assert_eq!(r["local"], 29721, "{r}");
    assert_eq!(r["renumbered"], json!({"from": 29720, "with": "smaller"}), "{r}");
    let r = only(&s).await;
    assert_eq!(r["local"], 29720, "{r}");
    assert!(r.get("renumbered").is_none(), "{r}");
}

#[tokio::test]
async fn a_bare_share_clears_the_notice() {
    let (l, s, _key, _echoes) = clashing(29730).await;
    introduce(&l, "larger", &s, "smaller");
    read(&l, &s).await;
    let r = only(&l).await;
    assert_eq!(r["renumbered"], json!({"from": 29730, "with": "smaller"}), "{r}");
    let port = r["port"].clone();
    let r = ipc(&l, json!({"cmd":"share","ports":[port]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let r = only(&l).await;
    assert!(r.get("renumbered").is_none(), "{r}");
    assert_eq!(r["local"], 29731, "{r}");
}

#[tokio::test]
async fn the_visitor_follows_a_renumbered_share() {
    let (l, s, key, _echoes) = clashing(29740).await;
    let c = visiting(29740, &key, &l).await;
    let lport = only(&l).await["port"].as_u64().unwrap() as u16;
    assert_eq!(their_row(&c, &l, lport).await["local"], 29740);
    introduce(&l, "larger", &s, "smaller");
    // C keeps knowing only L.
    let hosts = json!([{"id": l.id, "name": "a", "lan": [a_addr(&l.svc).to_string()]}]);
    std::fs::write(c.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    // Only L reads: were S to read L's table too, S would map L's share onto 29741 on this one
    // machine, and C could not take it.
    read(&l, &s).await;
    assert_eq!(only(&l).await["local"], 29741);
    let r = their_row(&c, &l, lport).await;
    assert_eq!((&r["local"], &r["addr"]), (&json!(29741), &json!("tcp://localhost:29741")), "{r}");
    assert!(r.get("wanted").is_none(), "{r}");
    refuses(29740).await;
}

// Task 5: the protocol of a share is detected when it is shared, and again when its port starts
// accepting later.

/// An HTTP service on `127.0.0.1:<port>` that answers every request `HTTP/1.0 200 OK`; the flag
/// says it was sent a `HEAD /`, which only detection sends.
async fn http_on(port: u16) -> (std::sync::Arc<std::sync::atomic::AtomicBool>, tokio::task::JoinHandle<()>) {
    use std::sync::atomic::{AtomicBool, Ordering};
    let l = tokio::net::TcpListener::bind(("127.0.0.1", port)).await.unwrap();
    let headed = std::sync::Arc::new(AtomicBool::new(false));
    let seen = headed.clone();
    let task = tokio::spawn(async move {
        while let Ok((mut c, _)) = l.accept().await {
            let seen = seen.clone();
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                if let Ok(n) = c.read(&mut buf).await {
                    if buf[..n].starts_with(b"HEAD / ") {
                        seen.store(true, Ordering::SeqCst);
                    }
                }
                let _ = c.write_all(b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n").await;
                let _ = c.shutdown().await;
            });
        }
    });
    (headed, task)
}

#[tokio::test]
async fn a_share_of_an_echo_is_detected_as_tcp() {
    let (port, _echo) = echo().await;
    let (a, _) = start_sharing_opts(|_| {}, (29750, 5), false, None).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[port]})).await;
    let s = &r["shared"][0];
    assert_eq!(
        (&s["local"], &s["proto"], &s["proto_auto"], &s["addr"]),
        (&json!(29750), &json!("tcp"), &json!(true), &json!("tcp://localhost:29750")),
        "{r}"
    );
    assert_eq!(row(&a, port).await["proto"], "tcp");

    // Nothing listens on 29758 yet: the guess stays, and the port is probed again once it accepts.
    let r = ipc(&a, json!({"cmd":"share","ports":[29758]})).await;
    let s = &r["shared"][0];
    assert_eq!((&s["proto"], &s["proto_auto"], &s["addr"]), (&json!("http"), &json!(true), &json!("http://localhost:29751")), "{r}");
    let (headed, _http) = http_on(29758).await;
    let r = row(&a, 29758).await;
    assert_eq!((&r["proto"], &r["listening"]), (&json!("http"), &json!(true)), "{r}");
    assert!(headed.load(std::sync::atomic::Ordering::SeqCst), "never probed");
}
