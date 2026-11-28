//! `set_service {id, name?, on?}`: asks a device to turn one of its services (today only `state`) on or off, or, with
//! no `on`, to say where it stands. The device's own `error` text (`unknown op` from an old device, `not supported`
//! for a password connection) is the command's error, which the GUI reads as it is.

use crate::Hub;
use anyhow::{Context, Result};
use rapp_net::msg::Op;
use serde_json::{json, Value};
use std::sync::Arc;

pub(crate) async fn command(hub: &Arc<Hub>, v: &Value) -> Result<Value> {
    let id = v.get("id").and_then(Value::as_str).context("missing id")?;
    let host = hub.host(id)?;
    let name = match v.get("name") {
        None | Some(Value::Null) => "state".to_string(),
        Some(Value::String(s)) => s.clone(),
        Some(_) => anyhow::bail!("bad name"),
    };
    let on = match v.get("on") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(b)) => Some(*b),
        Some(_) => anyhow::bail!("bad on"),
    };
    let (_, reply, _) = hub.request(&host, &Op::SetService { name, on }).await?;
    Ok(event(id, reply))
}

/// `no_lock {id, on?}`: asks a device to turn 不锁屏 on or off, or, with no `on`, where it stands. The device's
/// own `error` text travels in the reply.
pub(crate) async fn no_lock(hub: &Arc<Hub>, v: &Value) -> Result<Value> {
    let id = v.get("id").and_then(Value::as_str).context("missing id")?;
    let host = hub.host(id)?;
    let on = match v.get("on") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(b)) => Some(*b),
        Some(_) => anyhow::bail!("bad on"),
    };
    let (_, reply, _) = hub.request(&host, &Op::NoLock { on }).await?;
    Ok(json!({"event":"no_lock","id":id,"reply":reply}))
}

fn event(id: &str, reply: Value) -> Value {
    json!({"event":"service","id":id,"reply":reply})
}

#[cfg(test)]
mod tests {
    use super::event;
    use serde_json::json;

    #[test]
    fn the_reply_is_passed_on_whole() {
        assert_eq!(
            event("d1", json!({"ok":true,"on":true})),
            json!({"event":"service","id":"d1","reply":{"ok":true,"on":true}})
        );
    }
}
