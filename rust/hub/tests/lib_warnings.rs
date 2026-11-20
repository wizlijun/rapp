//! The hub's log carries quinn's warnings (a send the system refused, the endpoint driver
//! stopping): without them a dead socket after `net_changed` shows only as timeouts.

use rapp_hub::{Opts, UpgradeTimes};
use std::time::{Duration, Instant};

#[tokio::test]
async fn quinn_warnings_go_to_the_hub_log() {
    let home = tempfile::tempdir().unwrap();
    let logs = tempfile::tempdir().unwrap();
    let path = logs.path().join("hub.log");
    let opts = Opts {
        home: home.path().to_path_buf(),
        bin_dir: None,
        log: rapp_net::log::Log::file(logs.path(), "hub.log"),
        presence_every: None,
        upgrade: UpgradeTimes::default(),
        name: Some("Duo".into()),
        owns_access: true,
        embed_only: false,
        dual_stack: true,
        log_dir: None,
        map_ports: None,
    };
    let (cmd_r, _w) = tokio::io::duplex(1 << 16);
    let (_out_r, out_w) = tokio::io::duplex(1 << 16);
    tokio::spawn(rapp_hub::run(opts, cmd_r, out_w));
    let end = Instant::now() + Duration::from_secs(5);
    while !std::fs::read_to_string(&path).unwrap_or_default().contains("hub_start") {
        assert!(Instant::now() < end, "no hub_start");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tracing::warn!(target: "quinn_udp", "sendmsg error: Os {{ code: 65 }}");
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(
        text.lines().any(|l| l.contains(r#""ev":"lib""#) && l.contains("sendmsg error: Os { code: 65 }")),
        "{text}"
    );
}
