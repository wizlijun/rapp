use std::sync::Arc;

use rapp_conn::{e2e_accept, e2e_connect, hello_server, read_welcome, send_hello, Facts, Me, Paired, Pipe};
use rapp_net::line::{read_json, read_line, write_json};
use rapp_wire::{Fp, Identity, Key};
use serde_json::json;
use tokio::io::{duplex, AsyncWriteExt};

const A_ID: &str = "123456789";

struct Rig {
    a: Identity,
    b: Identity,
    ap: Pipe,
    af: Facts,
    bp: Pipe,
    bf: Facts,
}

async fn rig() -> Rig {
    let (a, b) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let (x, y) = duplex(64 * 1024);
    let (acc, con) = tokio::join!(e2e_accept(x, &a), e2e_connect(y, &b));
    let ((ap, af), (bp, bf)) = (acc.unwrap(), con.unwrap());
    assert_eq!((af.peer, bf.peer), (b.fp, a.fp));
    assert_eq!(af.ekm, bf.ekm);
    Rig { a, b, ap, af, bp, bf }
}

fn me<'a>(id: &'a str, name: &'a str, key: Option<&'a Key>) -> Me<'a> {
    Me { id, name, key }
}

#[tokio::test]
async fn same_key_trusts_and_pairs() {
    let mut r = rig().await;
    let key = Key::new_local();
    let home = tempfile::tempdir().unwrap();
    let paired = Paired::load(home.path()).unwrap();
    send_hello(&mut r.bp, &r.bf, &me("", "bee", Some(&key))).await.unwrap();
    write_json(&mut r.bp, &json!({"op": "ping"})).await.unwrap();
    let g = hello_server(&mut r.ap, &r.af, &me(A_ID, "ay", Some(&key)), &paired).await.unwrap();
    assert!(g.newly);
    assert_eq!((g.name.as_str(), g.fp), ("bee", r.b.fp));
    assert_eq!(read_json(&mut r.ap).await.unwrap()["op"], "ping");
    let acc = read_welcome(&mut r.bp, &r.bf, Some(&key), A_ID, None).await.unwrap();
    assert_eq!((acc.id.as_str(), acc.name.as_str(), acc.fp, acc.changed), (A_ID, "ay", r.a.fp, false));
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(home.path().join("paired.json")).unwrap()).unwrap();
    assert_eq!(v[0]["fp"], r.b.fp.to_string());
    assert_eq!(v[0]["name"], "bee");
}

#[tokio::test]
async fn different_keys_refuse() {
    let mut r = rig().await;
    let (ka, kb) = (Key::new_local(), Key::new_local());
    let home = tempfile::tempdir().unwrap();
    let paired = Paired::load(home.path()).unwrap();
    send_hello(&mut r.bp, &r.bf, &me("", "bee", Some(&kb))).await.unwrap();
    let e = hello_server(&mut r.ap, &r.af, &me(A_ID, "ay", Some(&ka)), &paired).await.err().unwrap();
    assert_eq!(e.to_string(), "not trusted");
    let e = read_welcome(&mut r.bp, &r.bf, Some(&kb), A_ID, None).await.err().unwrap();
    assert_eq!(e.to_string(), "not trusted");
    assert!(!paired.contains(&r.b.fp));
    assert!(!home.path().join("paired.json").exists());
}

#[tokio::test]
async fn known_fp_needs_no_key() {
    let mut r = rig().await;
    let home = tempfile::tempdir().unwrap();
    let paired = Paired::load(home.path()).unwrap();
    paired.add(&r.b.fp, "bee").unwrap();
    send_hello(&mut r.bp, &r.bf, &me("", "bee", None)).await.unwrap();
    let g = hello_server(&mut r.ap, &r.af, &me(A_ID, "ay", None), &paired).await.unwrap();
    assert!(!g.newly);
    let acc = read_welcome(&mut r.bp, &r.bf, None, A_ID, Some(&r.a.fp)).await.unwrap();
    assert!(!acc.changed);
}

#[tokio::test]
async fn mitm_cannot_forward_proofs() {
    let key = Key::new_local();
    let (a, b, m) = (Identity::generate().unwrap(), Identity::generate().unwrap(), Arc::new(Identity::generate().unwrap()));
    let (b_io, m_in) = duplex(64 * 1024);
    let (m_out, a_io) = duplex(64 * 1024);
    let (acc, con, mitm_up) = tokio::join!(e2e_accept(a_io, &a), e2e_connect(b_io, &b), async {
        tokio::join!(e2e_accept(m_in, &m), e2e_connect(m_out, &m))
    });
    let ((mut ap, af), (mut bp, bf)) = (acc.unwrap(), con.unwrap());
    let ((mut m_b, _), (mut m_a, _)) = (mitm_up.0.unwrap(), mitm_up.1.unwrap());
    // the two real endpoints see different handshakes
    assert_ne!(af.ekm, bf.ekm);
    assert_eq!((af.peer, bf.peer), (m.fp, m.fp));

    let home = tempfile::tempdir().unwrap();
    let paired = Paired::load(home.path()).unwrap();
    send_hello(&mut bp, &bf, &me("", "bee", Some(&key))).await.unwrap();
    // the man in the middle forwards every line unchanged
    let fwd = async {
        let hello = read_line(&mut m_b).await.unwrap().unwrap();
        m_a.write_all(format!("{hello}\n").as_bytes()).await.unwrap();
        m_a.flush().await.unwrap();
        if let Some(reply) = read_line(&mut m_a).await.unwrap() {
            m_b.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
            m_b.flush().await.unwrap();
        }
    };
    let a_me = me(A_ID, "ay", Some(&key));
    let (e, _) = tokio::join!(hello_server(&mut ap, &af, &a_me, &paired), fwd);
    assert_eq!(e.err().unwrap().to_string(), "not trusted");
    let e = read_welcome(&mut bp, &bf, Some(&key), A_ID, None).await.err().unwrap();
    assert_eq!(e.to_string(), "not trusted");
    assert!(!paired.contains(&m.fp) && !paired.contains(&b.fp));
    assert!(!home.path().join("paired.json").exists());
}

#[tokio::test]
async fn same_hello_passes_without_a_man_in_the_middle() {
    // Control for the test above: with no man in the middle the very same hello is accepted.
    let mut r = rig().await;
    let key = Key::new_local();
    let home = tempfile::tempdir().unwrap();
    let paired = Paired::load(home.path()).unwrap();
    send_hello(&mut r.bp, &r.bf, &me("", "bee", Some(&key))).await.unwrap();
    assert!(hello_server(&mut r.ap, &r.af, &me(A_ID, "ay", Some(&key)), &paired).await.is_ok());
}

#[tokio::test]
async fn wrong_id_is_refused() {
    let mut r = rig().await;
    let key = Key::new_local();
    let home = tempfile::tempdir().unwrap();
    let paired = Paired::load(home.path()).unwrap();
    send_hello(&mut r.bp, &r.bf, &me("", "bee", Some(&key))).await.unwrap();
    hello_server(&mut r.ap, &r.af, &me(A_ID, "ay", Some(&key)), &paired).await.unwrap();
    let e = read_welcome(&mut r.bp, &r.bf, Some(&key), "987654321", None).await.err().unwrap();
    assert_eq!(e.to_string(), "not trusted");
}

#[tokio::test]
async fn changed_fp_with_good_proof() {
    let key = Key::new_local();
    let other = Fp([9; 32]);
    for with_key in [true, false] {
        let mut r = rig().await;
        let home = tempfile::tempdir().unwrap();
        let paired = Paired::load(home.path()).unwrap();
        let bk = with_key.then_some(&key);
        send_hello(&mut r.bp, &r.bf, &me("", "bee", Some(&key))).await.unwrap();
        hello_server(&mut r.ap, &r.af, &me(A_ID, "ay", Some(&key)), &paired).await.unwrap();
        let res = read_welcome(&mut r.bp, &r.bf, bk, A_ID, Some(&other)).await;
        if with_key {
            let acc = res.unwrap();
            assert!(acc.changed);
            assert_eq!(acc.fp, r.a.fp);
        } else {
            assert_eq!(res.err().unwrap().to_string(), "host key mismatch");
        }
    }
}
