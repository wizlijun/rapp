//! Finding out what a shared port speaks, so that visitors are told the right address
//! (`tcp://`, `ssh -p`, ...) without the sharer having to say it (spec §3.5).

use crate::forward::{connect_local, local_addrs};
use crate::shares::Proto;
use rustls::pki_types::ServerName;
use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::Instant;

/// How long each step waits, for its connection and then for the reply: a service on loopback
/// answers far sooner, and a silent one must not keep the reply to `share` long (three steps).
pub const STEP_WAIT: Duration = Duration::from_millis(300);
/// The one request step 3 sends: read-only, and answered by any HTTP server, even one that
/// serves nothing at `/`.
const HEAD: &[u8] = b"HEAD / HTTP/1.0\r\nHost: localhost\r\n\r\n";

/// What `port` on this computer speaks; None when nothing accepts on it. Each step is a new
/// connection to `127.0.0.1:<port>`, then `[::1]:<port>` (where a forward would go), and waits
/// STEP_WAIT for its reply: a banner (`ssh`), a ServerHello (`https`), an HTTP reply (`http`),
/// or else `tcp`. The order matters: an SSH server speaks first, so step 1 sends nothing; a
/// TLS server would take the HTTP request of step 3 for garbage, so it is asked in TLS first.
pub async fn detect(port: u16) -> Option<Proto> {
    let addrs = local_addrs(port);
    let first = connect_local(&addrs, STEP_WAIT).await?;
    if ssh(first).await {
        return Some(Proto::Ssh);
    }
    // A later connect that fails (the service just stopped, or takes one client at a time)
    // only says this step is not it.
    if let Some(c) = connect_local(&addrs, STEP_WAIT).await {
        if https(c).await {
            return Some(Proto::Https);
        }
    }
    if let Some(c) = connect_local(&addrs, STEP_WAIT).await {
        if http(c).await {
            return Some(Proto::Http);
        }
    }
    Some(Proto::Tcp)
}

/// Step 1: sends nothing and waits for the service to speak first, as an SSH server does.
async fn ssh(mut c: TcpStream) -> bool {
    read_up_to(&mut c, 4).await.starts_with(b"SSH-")
}

/// Step 2: sends the first flight of a TLS handshake (server name `localhost`) and looks at the
/// first record back. A handshake record (0x16, version 3.x) whose message is a ServerHello
/// (type 2) is TLS; checking the type tells it from an echo service sending the ClientHello
/// (type 1) back. The handshake is never finished.
async fn https(mut c: TcpStream) -> bool {
    let name = ServerName::try_from("localhost").expect("a valid name");
    let Ok(mut tls) = rustls::ClientConnection::new(rapp_net::quic::probe_tls_config(), name) else { return false };
    let mut hello = Vec::new();
    if tls.write_tls(&mut hello).is_err() || c.write_all(&hello).await.is_err() {
        return false;
    }
    let got = read_up_to(&mut c, 6).await;
    got.len() == 6 && got[0] == 0x16 && got[1] == 0x03 && got[5] == 0x02
}

/// Step 3: a `HEAD /`; any HTTP server answers it, even with an error.
async fn http(mut c: TcpStream) -> bool {
    if c.write_all(HEAD).await.is_err() {
        return false;
    }
    read_up_to(&mut c, 5).await.starts_with(b"HTTP/")
}

/// Up to `n` bytes the other side sends within STEP_WAIT: fewer when it closes, fails or says
/// nothing more in time (a reply may come in more than one piece).
async fn read_up_to(c: &mut TcpStream, n: usize) -> Vec<u8> {
    let deadline = Instant::now() + STEP_WAIT;
    let mut got = vec![0u8; n];
    let mut have = 0;
    while have < n {
        match tokio::time::timeout_at(deadline, c.read(&mut got[have..])).await {
            Ok(Ok(k)) if k > 0 => have += k,
            _ => break,
        }
    }
    got.truncate(have);
    got
}

/// The ports detection has given an answer for in this run of the service. A port is detected
/// once: what listens on a port seldom changes, and probing it is not free for the service
/// (it sees three connections, two of them odd). A port nothing listened on is not in it, so
/// that it is detected once something does. Kept in memory only: a restart detects again.
#[derive(Default)]
pub struct Probed(Mutex<HashSet<u16>>);

impl Probed {
    /// Whether `port` was detected already.
    pub fn has(&self, port: u16) -> bool {
        self.0.lock().unwrap().contains(&port)
    }

    /// `port` was detected: later table reads leave it.
    pub fn mark(&self, port: u16) {
        self.0.lock().unwrap().insert(port);
    }

    /// `port` is to be detected again: it was shared again (perhaps because what listens on it
    /// changed) or unshared.
    pub fn forget(&self, port: u16) {
        self.0.lock().unwrap().remove(&port);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    /// A fake service on `127.0.0.1:0` that runs `serve` on every connection it accepts.
    async fn fake<F, Fut>(serve: F) -> u16
    where
        F: Fn(TcpStream) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send + 'static,
    {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((c, _)) = l.accept().await {
                tokio::spawn(serve(c));
            }
        });
        port
    }

    /// Reads once (what the prober sent, or its close), then writes `reply` and closes.
    async fn read_then(mut c: TcpStream, reply: &'static [u8]) {
        let mut buf = [0u8; 4096];
        let _ = c.read(&mut buf).await;
        let _ = c.write_all(reply).await;
        let _ = c.shutdown().await;
    }

    #[tokio::test]
    async fn an_ssh_banner_is_ssh() {
        let port = fake(|mut c| async move {
            let _ = c.write_all(b"SSH-2.0-test\r\n").await;
            let mut buf = [0u8; 64];
            let _ = c.read(&mut buf).await;
        })
        .await;
        assert_eq!(detect(port).await, Some(Proto::Ssh));
    }

    #[tokio::test]
    async fn a_server_hello_is_https() {
        let port = fake(|c| read_then(c, &[0x16, 0x03, 0x03, 0x00, 0x04, 0x02, 0, 0, 0])).await;
        assert_eq!(detect(port).await, Some(Proto::Https));
    }

    #[tokio::test]
    async fn an_http_reply_is_http() {
        let port = fake(|c| read_then(c, b"HTTP/1.1 400 Bad Request\r\n\r\n")).await;
        assert_eq!(detect(port).await, Some(Proto::Http));
    }

    #[tokio::test]
    async fn an_echo_service_is_tcp() {
        let port = fake(|mut c| async move {
            let (mut r, mut w) = c.split();
            let _ = tokio::io::copy(&mut r, &mut w).await;
        })
        .await;
        assert_eq!(detect(port).await, Some(Proto::Tcp));
    }

    #[tokio::test]
    async fn a_silent_service_is_tcp() {
        let port = fake(|mut c| async move {
            let mut buf = [0u8; 4096];
            while matches!(c.read(&mut buf).await, Ok(n) if n > 0) {}
        })
        .await;
        let began = Instant::now();
        assert_eq!(detect(port).await, Some(Proto::Tcp));
        assert!(began.elapsed() < Duration::from_millis(1500), "{:?}", began.elapsed());
    }

    #[tokio::test]
    async fn a_service_that_closes_at_once_is_tcp() {
        let port = fake(|c| async move { drop(c) }).await;
        assert_eq!(detect(port).await, Some(Proto::Tcp));
    }

    #[tokio::test]
    async fn nothing_listening_is_none() {
        let port = TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap().port();
        assert_eq!(detect(port).await, None);
    }
}
