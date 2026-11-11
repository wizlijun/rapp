//! `open` / `close` (spec §4): an `open` stream to A, a local TCP listener, and a
//! `rapp-client` spliced to it. `closed` carries the client's exit reason.

use crate::hosts::Host;
use crate::Hub;
use anyhow::{bail, Context, Result};
use rapp_net::log::{pipe_lines, Lvl};
use rapp_net::msg::Op;
use rapp_net::quic::{splice, BiStream};
use serde_json::{json, Value};
use std::process::Stdio;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::{Child, Command};
use tokio::task::JoinSet;

const ACCEPT_WAIT: Duration = Duration::from_secs(10);

impl Hub {
    pub async fn open(self: &Arc<Self>, id: &str, app: &str, req: &Option<Value>) -> Result<()> {
        let client = rapp_net::bins::find("rapp-client", self.bin_dir.as_deref()).context("rapp-client not found")?;
        let host = self.host(id)?;
        let (stream, reply, path) = self.request(&host, &Op::Open { app: app.into(), side: false }).await?;
        let token = reply["token"].as_str().context("no worker token")?;

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        // Taken before the client starts so its stderr lines carry it (a failed start leaves a gap).
        let sid = self.next_sid.fetch_add(1, Ordering::Relaxed) + 1;
        let mut child = Command::new(&client)
            .arg(format!("rapp://127.0.0.1:{port}/?mode=color16"))
            .args(["--token-env", "RAPP_TOKEN", "--json"])
            .env("RAPP_TOKEN", token)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("start {}", client.display()))?;
        if let Some(stderr) = child.stderr.take() {
            pipe_lines(self.log.clone(), stderr, json!({"src":"client","sid":sid}));
        }
        // Taken first: `Child::wait` closes stdin, which would end the client.
        let stdin = child.stdin.take();
        let tcp = tokio::select! {
            r = tokio::time::timeout(ACCEPT_WAIT, listener.accept()) => match r {
                Ok(Ok((tcp, _))) => tcp,
                _ => bail!("rapp-client did not connect"),
            },
            st = child.wait() => bail!("rapp-client exited before connecting ({})", exit_text(st)),
        };
        tcp.set_nodelay(true)?;

        // One task owns the client's stdin. Closing = dropping the sender: it drains what is
        // queued, then ends and drops stdin, so the client sees EOF.
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        if let Some(mut stdin) = stdin {
            tokio::spawn(async move {
                while let Some(l) = rx.recv().await {
                    if stdin.write_all(l.as_bytes()).await.is_err() {
                        break;
                    }
                }
            });
        }
        self.sessions.lock().unwrap().insert(sid, Some(tx));
        let mut opened = json!({"sid":sid,"id":id,"app":app,"path":path});
        if let Some(name) = self.hosts.get(id).map(|h| h.name).filter(|n| !n.is_empty()) {
            opened["host_name"] = name.into();
        }
        self.log.event(Lvl::Info, "opened", opened);
        self.emit(json!({"event":"opened","sid":sid,"id":id,"app":app,"path":path}), req).await;
        tokio::spawn(self.clone().run(sid, child, tcp, stream, listener, host, app.to_string(), Instant::now()));
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn run(
        self: Arc<Self>,
        sid: u64,
        mut child: Child,
        mut tcp: TcpStream,
        mut stream: BiStream,
        listener: TcpListener,
        host: Host,
        app: String,
        since: Instant,
    ) {
        let id = host.id.clone();
        let app_name = app.clone();
        let stdout = child.stdout.take();
        let reason = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout?).lines();
            let mut reason = None;
            while let Ok(Some(l)) = lines.next_line().await {
                if let Ok(v) = serde_json::from_str::<Value>(&l) {
                    if v["event"] == "exit" {
                        reason = v["reason"].as_str().map(str::to_string);
                    }
                }
            }
            reason
        });
        let pipe = tokio::spawn(async move {
            let _ = splice(&mut tcp, &mut stream).await;
        });
        // Side connections (file transfers): each gets its own `open` and splice.
        let hub = self.clone();
        let side = tokio::spawn(async move {
            let mut conns = JoinSet::new();
            loop {
                let Ok((mut tcp, _)) = listener.accept().await else { break };
                let _ = tcp.set_nodelay(true);
                let (hub, host, app) = (hub.clone(), host.clone(), app.clone());
                conns.spawn(async move {
                    match hub.request(&host, &Op::Open { app, side: true }).await {
                        Ok((mut stream, _, _)) => {
                            let _ = splice(&mut tcp, &mut stream).await;
                        }
                        Err(e) => hub.log.msg(Lvl::Warn, format_args!("side connection: {e:#}")),
                    }
                });
            }
        });
        let mut kill = self.kill.subscribe();
        let killed = async move {
            let _ = kill.wait_for(|k| *k).await;
        };
        let status = tokio::select! {
            st = child.wait() => st,
            _ = killed => {
                let _ = child.start_kill();
                child.wait().await
            }
        };
        pipe.abort();
        // Aborting the accept task drops the listener and its JoinSet (aborting the splices).
        side.abort();
        let _ = side.await;
        let reason = reason.await.ok().flatten().unwrap_or_else(|| exit_text(status));
        let secs = since.elapsed().as_secs();
        self.log.event(Lvl::Info, "closed", json!({"sid":sid,"id":id,"app":app_name,"secs":secs,"reason":reason}));
        self.emit(json!({"event":"closed","sid":sid,"reason":reason}), &None).await;
        self.sessions.lock().unwrap().remove(&sid);
    }

    /// Closes the client's stdin; `closed` follows when it exits.
    pub fn close(&self, sid: u64) -> Result<()> {
        match self.sessions.lock().unwrap().get_mut(&sid) {
            Some(tx) => {
                tx.take();
                Ok(())
            }
            None => bail!("unknown sid"),
        }
    }

    /// Asks the client to raise its windows (`{"cmd":"focus"}` on its stdin).
    pub fn focus(&self, sid: u64) -> Result<()> {
        match self.sessions.lock().unwrap().get(&sid) {
            Some(Some(tx)) => {
                let _ = tx.send("{\"cmd\":\"focus\"}\n".into());
                Ok(())
            }
            _ => bail!("unknown sid"),
        }
    }

    /// stdin EOF: close every client, wait up to 5 s, then kill the rest.
    pub async fn close_all(&self) {
        for tx in self.sessions.lock().unwrap().values_mut() {
            tx.take();
        }
        if !self.wait_sessions_done(Duration::from_secs(5)).await {
            let _ = self.kill.send(true);
            self.wait_sessions_done(Duration::from_secs(2)).await;
        }
    }

    async fn wait_sessions_done(&self, limit: Duration) -> bool {
        let deadline = tokio::time::Instant::now() + limit;
        while !self.sessions.lock().unwrap().is_empty() {
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        true
    }
}

fn exit_text(st: std::io::Result<std::process::ExitStatus>) -> String {
    match st {
        Ok(s) => s.code().map_or_else(|| "killed".to_string(), |c| format!("exit code {c}")),
        Err(e) => e.to_string(),
    }
}
