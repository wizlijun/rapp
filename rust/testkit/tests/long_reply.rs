//! rapp-hub: a reply longer than the line limit fails that one request and keeps the cached link.

mod common;
use common::*;

use quinn::Endpoint;
use rapp_conn::relay::RelayConn;
use rapp_conn::Pipe;
use rapp_net::line::read_json;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// A device on `rig` with an ID and identity of its own, trusting the relay's key: lookups are
/// answered, and each relayed stream is handed to `serve` with its number (from 0) on a task of
/// its own. Its ID, the streams so far, and what keeps it on the relay. (Copied from forward.rs.)
async fn fake_on_relay<F, Fut>(
    rig: &RelayRig,
    serve: F,
) -> (String, Arc<AtomicUsize>, (Endpoint, RelayConn))
where
    F: Fn(usize, Pipe, FakeA) -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    let id = "876543219".to_string();
    let me = Arc::new(rapp_wire::Identity::generate().unwrap());
    let (ep, conn) = relay_conn(rig, &me, &rig.key).await;
    conn.register(&id, &[]).await.unwrap();
    let streams = Arc::new(AtomicUsize::new(0));
    let (pushes, n, key) = (
        conn.clone(),
        streams.clone(),
        Arc::new(rapp_wire::Key {
            relay: rig.key.relay,
            root: rig.key.root,
        }),
    );
    let fake = FakeA {
        id: id.clone(),
        me,
        key,
    };
    tokio::spawn(async move {
        loop {
            match pushes.next_push().await {
                Ok(rapp_conn::relay::Pushed::Incoming { mut reply, .. }) => {
                    let _ = reply.write_all(b"{\"ok\":true}\n").await;
                    let _ = reply.flush().await;
                }
                Ok(rapp_conn::relay::Pushed::Relayed { stream, .. }) => {
                    tokio::spawn(serve(
                        n.fetch_add(1, Ordering::SeqCst),
                        stream,
                        fake.clone(),
                    ));
                }
                Ok(rapp_conn::relay::Pushed::Closed { .. }) | Err(_) => return,
                Ok(_) => {}
            }
        }
    });
    (id, streams, (ep, conn))
}

#[derive(Clone)]
struct FakeA {
    id: String,
    me: Arc<rapp_wire::Identity>,
    key: Arc<rapp_wire::Key>,
}

impl FakeA {
    /// TLS and the hello on a relayed stream, as A answers them, and the request read.
    async fn asked(&self, stream: Pipe) -> (Pipe, Value) {
        let (mut pipe, facts) = rapp_conn::e2e_accept(stream, &self.me).await.unwrap();
        let home = tempfile::tempdir().unwrap();
        let hello = rapp_conn::Me {
            id: &self.id,
            name: "fake-a",
            key: Some(&self.key),
        };
        rapp_conn::hello_server(
            &mut pipe,
            &facts,
            &hello,
            &rapp_conn::Paired::empty(home.path()),
        )
        .await
        .unwrap();
        let op = read_json(&mut pipe).await.unwrap();
        (pipe, op)
    }
}

/// Sends `cmd` and returns the event that answers its `req` (path events are kept aside by `Hub`).
async fn answer(hub: &mut Hub, cmd: Value) -> Value {
    hub.send(cmd.clone()).await;
    loop {
        let r = hub.next().await;
        if r["req"] == cmd["req"] {
            return r;
        }
    }
}

#[tokio::test]
async fn a_too_long_reply_keeps_the_cached_link() {
    let rig = RelayRig::start().await;
    // Each request gets one line {"ok":true,"events":[]}; a logs request with q=long gets a 70 KiB field too.
    let (id, streams, _on_relay) = fake_on_relay(&rig, |_, stream, fake| async move {
        let (mut pipe, op) = fake.asked(stream).await;
        let mut r = json!({"ok": true, "events": []});
        if op["q"] == "long" {
            r["pad"] = json!("x".repeat(70 * 1024));
        }
        let _ = rapp_net::line::write_json(&mut pipe, &r).await;
        let mut rest = Vec::new();
        let _ = pipe.read_to_end(&mut rest).await;
    })
    .await;
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let mut hub = Hub::start(home.path(), bins.path());
    assert_eq!(
        answer(&mut hub, json!({"cmd":"add_host","id":id,"req":1})).await["event"],
        "host_added"
    );
    assert_eq!(
        answer(&mut hub, json!({"cmd":"logs","id":id,"req":2})).await["event"],
        "logs"
    );
    hub.wait_path(&id, "relay").await;
    let before = streams.load(Ordering::SeqCst);
    let r = answer(&mut hub, json!({"cmd":"logs","id":id,"q":"long","req":3})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert!(
        r["error"]
            .as_str()
            .unwrap_or_default()
            .contains("line longer than 65536 bytes"),
        "{r}"
    );
    let r = answer(&mut hub, json!({"cmd":"logs","id":id,"req":4})).await;
    assert_eq!(r["event"], "logs", "{r}");
    // Two requests, two streams: the long reply did not make the hub forget the link and reconnect.
    assert_eq!(streams.load(Ordering::SeqCst), before + 2);
    assert!(
        !hub.take_paths().iter().any(|p| p["id"] == id),
        "the link was dropped and re-made"
    );
    hub.finish().await;
}
