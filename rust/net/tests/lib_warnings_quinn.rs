//! A datagram the system refuses to send is swallowed by quinn-udp (the dial just times out);
//! with `forward_lib_warnings` the refusal is in the log.
use rapp_net::log::{forward_lib_warnings, Log};
use rapp_net::quic::{client_endpoint, connect, ALPN_PEER};
use std::time::Duration;

#[tokio::test]
async fn a_refused_send_is_in_the_log() {
    let dir = tempfile::tempdir().unwrap();
    forward_lib_warnings(Log::file(dir.path(), "hub.log"));
    // Bound to loopback, so a datagram to a public address cannot leave.
    let ep = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
    let r = connect(&ep, "192.0.2.1:9".parse().unwrap(), ALPN_PEER, Duration::from_millis(300)).await;
    assert!(r.is_err());
    let text = std::fs::read_to_string(dir.path().join("hub.log")).unwrap_or_default();
    assert!(
        text.lines().any(|l| l.contains(r#""ev":"lib""#) && l.contains("sendmsg error")),
        "{text}"
    );
}
