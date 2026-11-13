//! `probe <host:port> <key> [--wait]`: enrolls a throwaway device on a relay, pinning the relay's
//! fingerprint from the key, and prints the address the relay saw. With `--wait`, stays connected
//! and prints every push as one JSON line.

use std::net::ToSocketAddrs;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use rapp_wire::line::read_json;
use rapp_wire::msg::Req;
use rapp_wire::tls::{self, Expect};
use rapp_wire::{Identity, Key};
use serde_json::Value;
use tokio::io::BufReader;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let wait = args.iter().any(|a| a == "--wait");
    let pos: Vec<&String> = args.iter().filter(|a| *a != "--wait").collect();
    let [addr, key] = pos[..] else { bail!("usage: probe <host:port> <key> [--wait]") };
    let addr = addr.to_socket_addrs()?.next().with_context(|| format!("no address for {addr}"))?;
    let parsed: Key = key.parse()?;
    // A relay key is 32 bytes in base32: the first 16 are the relay fingerprint's prefix.
    let bytes = data_encoding::BASE32_NOPAD.decode(key.trim().to_ascii_uppercase().as_bytes())?;
    let pin: [u8; 16] = bytes.get(..16).filter(|_| bytes.len() == 32).context("not a relay key")?.try_into()?;

    let endpoint = quinn::Endpoint::client(if addr.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" }.parse()?)?;
    let cc = tls::client_config(&Identity::generate()?, tls::ALPN_RELAY, Expect::Pin(pin))?;
    let conn = endpoint.connect_with(cc, addr, tls::SNI)?.await.with_context(|| format!("handshake with {addr}"))?;

    let (mut send, recv) = conn.open_bi().await?;
    let join = data_encoding::HEXLOWER.encode(&parsed.join());
    let mut line = serde_json::to_vec(&Req::Enroll { join })?;
    line.push(b'\n');
    send.write_all(&line).await?;
    send.finish()?;
    let reply = read_json(&mut BufReader::new(recv), 64 * 1024).await?;
    if reply["ok"] != true {
        bail!("enroll refused: {}", reply["error"].as_str().unwrap_or("bad reply"));
    }
    println!("enrolled from {}", reply["from"].as_str().unwrap_or("?"));
    if !wait {
        conn.close(0u32.into(), b"probe");
        endpoint.wait_idle().await;
        return Ok(());
    }
    // Pushes: bidirectional ones (answered `ok`) and unidirectional ones (read whole).
    loop {
        tokio::select! {
            bi = conn.accept_bi() => {
                let Ok((mut send, recv)) = bi else { break };
                tokio::spawn(async move {
                    if let Ok(v) = read_json(&mut BufReader::new(recv), 8192).await {
                        println!("{v}");
                        let _ = send.write_all(b"{\"ok\":true}\n").await;
                        let _ = send.finish();
                    }
                });
            }
            uni = conn.accept_uni() => {
                let Ok(mut recv) = uni else { break };
                tokio::spawn(async move {
                    if let Ok(b) = recv.read_to_end(8192).await {
                        if let Ok(v) = serde_json::from_slice::<Value>(b.trim_ascii()) {
                            println!("{v}");
                        }
                    }
                });
            }
        }
    }
    // Let the last push print before the process ends.
    tokio::time::sleep(Duration::from_millis(200)).await;
    Ok(())
}
