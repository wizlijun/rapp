//! A forward channel from a device over the relay (port-sharing 1b): the visitor's first request
//! on a relayed stream was `mux`; from then on the stream carries many substreams, each one an
//! ordinary request (`forward`, mostly), served as on any other path.

use crate::peer::serve_request;
use crate::state::{Peer, State};
use rapp_conn::mux::{Mux, Reader, Writer};
use rapp_conn::relay::Prio;
use rapp_conn::Pipe;
use rapp_net::line::{ok, write_json};
use rapp_net::log::Lvl;
use serde_json::json;
use std::sync::Arc;
use std::time::Instant;

/// Answers `mux` and serves the substreams until the channel ends. The caller has read the
/// request; the pipe is at its reply.
pub async fn serve(state: Arc<State>, mut pipe: Pipe, prio: Prio, peer: Peer) {
    // Forwarded traffic gives way to sessions on this device's relay connection.
    prio.set(state.forward_priority);
    if let Err(e) = write_json(&mut pipe, &ok(json!({}))).await {
        state.log.msg(Lvl::Warn, format!("{}: {e:#}", peer.addr));
        return;
    }
    let fp = peer.fp.as_ref().map(|f| f.to_string());
    let fields = |more: serde_json::Value| {
        let mut v = peer.fields(more);
        v["fp"] = json!(fp);
        v
    };
    state.log.event(Lvl::Info, "channel", fields(json!({})));
    let began = Instant::now();
    let (r, w) = tokio::io::split(pipe);
    let (mux, mut incoming) = Mux::server(Box::new(r) as Reader, Box::new(w) as Writer);
    while let Some(s) = incoming.next().await {
        let (state, peer) = (state.clone(), peer.clone());
        tokio::spawn(async move {
            if let Err(e) = serve_request(&state, Box::new(s), peer.clone()).await {
                state.log.msg(Lvl::Warn, format!("{}: {e:#}", peer.addr));
            }
        });
    }
    let reason = mux.reason().unwrap_or_else(|| "closed".to_string());
    let streams = mux.opened();
    state.log.event(
        Lvl::Info,
        "channel_end",
        fields(json!({"streams": streams, "reason": reason, "secs": began.elapsed().as_secs()})),
    );
}
