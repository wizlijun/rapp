//! quinn and quinn-udp report what they swallow (a `sendmsg` error, the endpoint driver's I/O
//! error) through `tracing`; the hub's log has to see them. One test: the forwarder is
//! process-wide.
use rapp_net::log::{forward_lib_warnings, Log};
use serde_json::Value;
use std::path::Path;

fn lines(dir: &Path) -> Vec<Value> {
    std::fs::read_to_string(dir.join("hub.log"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn quinn_warnings_and_errors_reach_the_current_log() {
    let first = tempfile::tempdir().unwrap();
    forward_lib_warnings(Log::file(first.path(), "hub.log"));
    tracing::warn!(target: "quinn_udp", "sendmsg error: Os {{ code: 1 }}");
    tracing::error!(target: "quinn::endpoint", "I/O error: Socket is not connected");
    tracing::info!(target: "quinn_udp", "below warn");
    tracing::warn!(target: "rustls::conn", "not quinn");

    let got = lines(first.path());
    assert_eq!(got.len(), 2, "{got:?}");
    assert_eq!(got[0]["ev"], "lib");
    assert_eq!(got[0]["lvl"], "warn");
    assert_eq!(got[0]["target"], "quinn_udp");
    assert_eq!(got[0]["msg"], "sendmsg error: Os { code: 1 }");
    assert_eq!(got[1]["lvl"], "error");
    assert_eq!(got[1]["target"], "quinn::endpoint");
    assert_eq!(got[1]["msg"], "I/O error: Socket is not connected");

    // The in-process iOS hub can start again in the same process: the newest log takes over.
    let second = tempfile::tempdir().unwrap();
    forward_lib_warnings(Log::file(second.path(), "hub.log"));
    tracing::warn!(target: "quinn_udp", "sendmsg error: again");
    assert_eq!(lines(first.path()).len(), 2);
    let got = lines(second.path());
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0]["msg"], "sendmsg error: again");
}
