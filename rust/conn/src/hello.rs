//! The first line on a device connection: who is asking, and the proof that both hold the same key.

use anyhow::{bail, Result};
use rapp_net::line::{check as reply_ok, err, ok, read_json, write_json};
use rapp_wire::{Fp, Key};
use serde_json::{json, Value};

use crate::proof::{check, proof, Facts};
use crate::{Paired, Pipe};

/// Who we are, as told to the other side.
pub struct Me<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub key: Option<&'a Key>,
}

pub struct Accepted {
    pub id: String,
    pub name: String,
    pub fp: Fp,
    /// The fingerprint differs from the one stored for this host.
    pub changed: bool,
}

pub struct Greeted {
    pub name: String,
    pub fp: Fp,
    /// The device was not in `paired.json` and was added on the strength of the proof.
    pub newly: bool,
}

/// B's first line. Written without waiting for the reply, so the request can follow at once.
pub async fn send_hello(s: &mut Pipe, f: &Facts, me: &Me<'_>) -> Result<()> {
    let mut v = json!({"op": "hello", "name": me.name});
    if let Some(k) = me.key {
        v["proof"] = proof(&k.trust(), f).into();
    }
    write_json(s, &v).await
}

/// B reads A's reply to the hello.
pub async fn read_welcome(
    s: &mut Pipe,
    f: &Facts,
    key: Option<&Key>,
    want_id: &str,
    known: Option<&Fp>,
) -> Result<Accepted> {
    let v = reply_ok(read_json(s).await?)?;
    let id = v["id"].as_str().unwrap_or("").to_string();
    if id != want_id {
        bail!("not trusted");
    }
    let known_ok = known == Some(&f.peer);
    let proof_ok = match (key, v["proof"].as_str()) {
        (Some(k), Some(p)) => check(&k.trust(), f, p),
        _ => false,
    };
    if !known_ok && !proof_ok {
        bail!(if known.is_some() { "host key mismatch" } else { "not trusted" });
    }
    Ok(Accepted {
        id,
        name: v["name"].as_str().unwrap_or("").to_string(),
        fp: f.peer,
        changed: !known_ok && known.is_some(),
    })
}

/// A reads B's hello and answers. On failure it has already replied `not trusted`.
pub async fn hello_server(s: &mut Pipe, f: &Facts, me: &Me<'_>, paired: &Paired) -> Result<Greeted> {
    let v = read_json(s).await?;
    let known = paired.contains(&f.peer);
    let proof_ok = match (me.key, v["proof"].as_str()) {
        (Some(k), Some(p)) => check(&k.trust(), f, p),
        _ => false,
    };
    if v["op"] != "hello" || !(known || proof_ok) {
        let _ = write_json(s, &err("not trusted")).await;
        bail!("not trusted");
    }
    let name = v["name"].as_str().unwrap_or("").to_string();
    let newly = !known;
    if newly {
        paired.add(&f.peer, &name)?;
    }
    let mut reply = json!({"id": me.id, "name": me.name});
    if let Some(k) = me.key {
        reply["proof"] = Value::String(proof(&k.trust(), f));
    }
    write_json(s, &ok(reply)).await?;
    Ok(Greeted { name, fp: f.peer, newly })
}
