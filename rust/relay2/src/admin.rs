//! The local admin socket (spec §6.5): `<data>/admin.sock`, mode 0600, one request line and one
//! reply line per connection. The server half runs inside the relay; `call` and `issue_key` are
//! the client half the subcommands use.
//!
//! A new key is made in the client process: only its join hash crosses the socket, so the root
//! of the key never reaches the relay process (§7.4).

use std::collections::HashSet;
use std::fmt;
use std::net::SocketAddr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use rapp_net::log::{Log, Lvl};
use rapp_wire::line::{err, ok, read_json, write_json};
use rapp_wire::msg::is_valid_id;
use rapp_wire::{join_hash, Fp, Key};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::BufReader;
use tokio::net::{UnixListener, UnixStream};

use crate::audit::Audit;
use crate::config::Enroll;
use crate::store::Registry;

const VERSION: &str = env!("CARGO_PKG_VERSION");

pub const SOCKET: &str = "admin.sock";

/// A request line longer than this is refused.
const MAX_REQUEST: usize = 8192;
/// The request line has to arrive within this.
const REQUEST_WAIT: Duration = Duration::from_secs(5);
/// A reply line may be long (`devices` lists every device).
const MAX_REPLY: usize = 4 << 20;
/// How long `call` waits for the whole exchange.
const CALL_WAIT: Duration = Duration::from_secs(10);

const BAD_REQUEST: &str = "bad request";
const NOT_FOUND: &str = "not found";

pub fn socket_path(data: &Path) -> PathBuf {
    data.join(SOCKET)
}

/// Nothing answers on the admin socket: it is missing, or connecting to it failed.
#[derive(Debug)]
pub struct NotRunning(pub PathBuf);

impl fmt::Display for NotRunning {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "relay 没在运行（{} 连不上）", self.0.display())
    }
}

impl std::error::Error for NotRunning {}

/// One request to the relay serving `data`, and its reply. A relay that is not running is a
/// `NotRunning` error.
pub async fn call(data: &Path, req: Value) -> Result<Value> {
    let path = socket_path(data);
    let st = UnixStream::connect(&path).await.map_err(|_| NotRunning(path.clone()))?;
    let exchange = async {
        let (r, mut w) = st.into_split();
        write_json(&mut w, &req).await?;
        read_json(&mut BufReader::new(r), MAX_REPLY).await
    };
    tokio::time::timeout(CALL_WAIT, exchange).await.context("no reply on the admin socket")?.context("admin reply")
}

/// What `key` (`rotate: false`) and `rotate-key` (`rotate: true`) do: makes a new key for the relay
/// serving `data` and stores its join hash there. `None`: a key was set before and `rotate` is
/// false (a key is shown only once).
pub async fn issue_key(data: &Path, rotate: bool) -> Result<Option<Key>> {
    let info = call(data, json!({"cmd": "info"})).await?;
    if info["ok"] != true {
        bail!("info: {}", info["error"]);
    }
    if !rotate && info["has_key"] == true {
        return Ok(None);
    }
    let fp: Fp = info["fp"].as_str().context("info: no fp")?.parse()?;
    let key = Key::new_for_relay(&fp);
    let v = call(data, json!({"cmd": "set_join", "hash": join_hash(&key.join()), "rotate": rotate})).await?;
    match v["error"].as_str() {
        _ if v["ok"] == true => Ok(Some(key)),
        Some("key exists") => Ok(None),
        _ => bail!("set_join: {}", v["error"]),
    }
}

/// What the admin commands need from the running relay.
pub(crate) trait Control: Send + Sync {
    fn registry(&self) -> &dyn Registry;
    fn audit(&self) -> &Audit;
    fn log(&self) -> &Log;
    /// Fingerprints with a live enrolled connection.
    fn online_fps(&self) -> HashSet<Fp>;
    fn enroll_open(&self) -> bool;
    fn set_enroll_open(&self, open: bool);
    /// Revokes and cuts off `fp` (audited there); false when nothing changed.
    fn revoke(&self, fp: &Fp) -> Result<bool>;
    /// Frees `id` in the registry and in the live table; the device it belonged to, if any.
    fn unbind(&self, id: &str) -> Result<Option<Fp>>;
}

pub(crate) struct Ctx {
    pub data: PathBuf,
    pub fp: Fp,
    pub listen: SocketAddr,
    pub enroll_from_env: bool,
    pub relay: Arc<dyn Control>,
}

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
enum Cmd {
    Info,
    SetJoin {
        hash: String,
        #[serde(default)]
        rotate: bool,
    },
    Devices,
    Revoke {
        target: String,
    },
    Unbind {
        id: String,
    },
    Enroll {
        state: Enroll,
    },
}

/// The listening admin socket. Dropping it stops serving and removes the socket file.
pub(crate) struct Server {
    path: PathBuf,
    listener: Option<UnixListener>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl Server {
    /// Binds `<data>/admin.sock` (0600). A socket another relay answers on is an error; a file
    /// left behind by one that is gone is replaced.
    pub(crate) async fn bind(data: &Path) -> Result<Server> {
        let path = socket_path(data);
        if path.symlink_metadata().is_ok() {
            if UnixStream::connect(&path).await.is_ok() {
                bail!("another relay is using {}", path.display());
            }
            std::fs::remove_file(&path).with_context(|| format!("remove stale {}", path.display()))?;
        }
        let listener = UnixListener::bind(&path).with_context(|| format!("bind {}", path.display()))?;
        let server = Server { path, listener: Some(listener), task: None };
        std::fs::set_permissions(&server.path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("chmod {}", server.path.display()))?;
        Ok(server)
    }

    pub(crate) fn serve(&mut self, ctx: Ctx) {
        let Some(listener) = self.listener.take() else { return };
        let ctx = Arc::new(Handler { ctx, lock: Mutex::new(()) });
        self.task = Some(tokio::spawn(async move {
            while let Ok((st, _)) = listener.accept().await {
                tokio::spawn(connection(ctx.clone(), st));
            }
        }));
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(t) = self.task.take() {
            t.abort();
        }
        self.listener = None;
        let _ = std::fs::remove_file(&self.path);
    }
}

async fn connection(h: Arc<Handler>, st: UnixStream) {
    let (r, mut w) = st.into_split();
    let mut r = BufReader::new(r);
    let reply = match tokio::time::timeout(REQUEST_WAIT, read_json(&mut r, MAX_REQUEST)).await {
        Err(_) => return,
        Ok(Err(_)) => err(BAD_REQUEST),
        Ok(Ok(v)) => match serde_json::from_value::<Cmd>(v) {
            Ok(cmd) => h.handle(cmd),
            Err(_) => err(BAD_REQUEST),
        },
    };
    let _ = write_json(&mut w, &reply).await;
}

struct Handler {
    ctx: Ctx,
    /// One `set_join` or `enroll` at a time: each is a check-then-write.
    lock: Mutex<()>,
}

impl Handler {
    fn relay(&self) -> &dyn Control {
        &*self.ctx.relay
    }

    fn handle(&self, cmd: Cmd) -> Value {
        match cmd {
            Cmd::Info => self.info(),
            Cmd::SetJoin { hash, rotate } => self.set_join(&hash, rotate),
            Cmd::Devices => self.devices(),
            Cmd::Revoke { target } => self.revoke(&target),
            Cmd::Unbind { id } => self.unbind(&id),
            Cmd::Enroll { state } => self.enroll(state),
        }
    }

    /// Logs a failed write and turns it into the reply.
    fn failed(&self, what: &str, e: anyhow::Error) -> Value {
        let error = format!("{e:#}");
        self.relay().log().event(Lvl::Error, "admin_failed", json!({"cmd": what, "error": error}));
        err(&error)
    }

    fn info(&self) -> Value {
        let r = self.relay();
        ok(json!({
            "version": VERSION,
            "fp": self.ctx.fp.to_string(),
            "listen": self.ctx.listen.to_string(),
            "has_key": r.registry().join_hash().is_some(),
            "enroll": if r.enroll_open() { "open" } else { "closed" },
            "devices": r.registry().count(),
            "online": r.online_fps().len(),
        }))
    }

    fn set_join(&self, hash: &str, rotate: bool) -> Value {
        if hash.len() != 64 || !hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
            return err("bad hash");
        }
        let _one = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let reg = self.relay().registry();
        if !rotate && reg.join_hash().is_some() {
            return err("key exists");
        }
        if let Err(e) = reg.set_join_hash(hash) {
            return self.failed("set_join", e);
        }
        let ev = if rotate { "rotate_key" } else { "key" };
        self.relay().audit().event(ev, json!({"hash": &hash[..8]}), true);
        ok(json!({}))
    }

    fn devices(&self) -> Value {
        let online = self.relay().online_fps();
        let list: Vec<Value> = self
            .relay()
            .registry()
            .list()
            .into_iter()
            .map(|d| {
                json!({
                    "fp": d.fp.to_string(),
                    "id": d.id,
                    "enrolled_at": d.enrolled_at,
                    "last_seen": d.last_seen,
                    "revoked": d.revoked,
                    "online": online.contains(&d.fp),
                })
            })
            .collect();
        ok(json!({"devices": list}))
    }

    fn revoke(&self, target: &str) -> Value {
        let fp = match resolve(self.relay().registry(), target) {
            Ok(fp) => fp,
            Err(e) => return err(e),
        };
        // Already revoked (false) is fine: the device is out either way.
        match self.relay().revoke(&fp) {
            Ok(_) => ok(json!({"fp": fp.to_string()})),
            Err(e) => self.failed("revoke", e),
        }
    }

    fn unbind(&self, id: &str) -> Value {
        if !is_valid_id(id) {
            return err(NOT_FOUND);
        }
        match self.relay().unbind(id) {
            Ok(Some(fp)) => {
                self.relay().audit().event("unbind", json!({"id": id, "fp": fp.to_string()}), true);
                ok(json!({}))
            }
            Ok(None) => err(NOT_FOUND),
            Err(e) => self.failed("unbind", e),
        }
    }

    /// Applies the state first, then saves it to `config.json`: closing enrollment must work even
    /// when the file cannot be written (a read-only volume, say). A failed save is reported, but
    /// the running relay keeps the new state.
    fn enroll(&self, state: Enroll) -> Value {
        let _one = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let open = state == Enroll::Open;
        self.relay().set_enroll_open(open);
        let ev = if open { "enroll_open" } else { "enroll_close" };
        self.relay().audit().event(ev, json!({}), true);
        if let Err(e) = persist_enroll(&self.ctx.data, state) {
            return self.failed("enroll", e.context("applied but not saved"));
        }
        ok(json!({"env_overrides": self.ctx.enroll_from_env}))
    }
}

/// A `revoke` target: an ID (9 digits), or a fingerprint or a prefix of one (8 to 64 hex digits,
/// either case) that matches exactly one device. Anything else names no device: `not found`.
fn resolve(reg: &dyn Registry, target: &str) -> Result<Fp, &'static str> {
    let t = target.trim();
    if is_valid_id(t) {
        return reg.by_id(t).map(|d| d.fp).ok_or(NOT_FOUND);
    }
    let prefix = t.to_ascii_lowercase();
    if !(8..=64).contains(&prefix.len()) || !prefix.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(NOT_FOUND);
    }
    let mut found = reg.list().into_iter().map(|d| d.fp).filter(|fp| fp.to_string().starts_with(&prefix));
    match (found.next(), found.next()) {
        (Some(fp), None) => Ok(fp),
        (None, _) => Err(NOT_FOUND),
        (Some(_), Some(_)) => Err("ambiguous"),
    }
}

/// Sets `enroll` in `<data>/config.json` and leaves every other item as it was. A missing file
/// is created (0600); an existing one keeps its mode.
fn persist_enroll(data: &Path, state: Enroll) -> Result<()> {
    let path = data.join("config.json");
    let (mut v, mode) = match std::fs::read(&path) {
        Ok(b) => {
            let v: Value = serde_json::from_slice(&b).with_context(|| format!("parse {}", path.display()))?;
            (v, Some(std::fs::metadata(&path)?.permissions().mode() & 0o777))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (json!({}), None),
        Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
    };
    let Value::Object(items) = &mut v else { bail!("{} is not a JSON object", path.display()) };
    items.insert("enroll".into(), serde_json::to_value(state)?);
    let mut bytes = serde_json::to_vec_pretty(&v)?;
    bytes.push(b'\n');
    rapp_net::config::write_private(&path, &bytes)?;
    if let Some(mode) = mode.filter(|m| *m != 0o600) {
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
            .with_context(|| format!("chmod {}", path.display()))?;
    }
    Ok(())
}
