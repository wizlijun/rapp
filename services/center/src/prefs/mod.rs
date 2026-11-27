//! The quick-area settings every app shares: four documents (`phrases`, `keys`, `layout`,
//! `stars`), each replaced only from the version the writer last saw, and each device's own
//! usage counts. Its API is `api/prefs.md`.

use std::collections::BTreeMap;
use std::hash::{BuildHasher, Hasher};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::{Method, Request, Response, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use tokio::task::JoinHandle;

use crate::builtin::{Builtin, Fut};
use crate::entry::{now, reply, Body, Ctx};

/// The names of the documents.
pub const NAMES: [&str; 4] = ["phrases", "keys", "layout", "stars"];
/// The most a document's `data` (or a device's usage) may take, serialized.
pub const MAX_DATA: usize = 256 * 1024;
/// A body may be this much bigger than its `data` (`at`, `base`, the keys).
const MAX_BODY: usize = MAX_DATA + 4096;
/// A device's usage not received again for this long (seconds) is dropped.
pub const USAGE_KEEP: u64 = 90 * 86_400;
const EXPIRE_EVERY: Duration = Duration::from_secs(600);
const DEVICE_MAX: usize = 128;

/// One document, or one device's usage, as the apps see it. `at` is the writer's, in
/// milliseconds; the service never compares it with its own clock.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Doc {
    pub at: u64,
    pub data: Value,
}

impl Doc {
    /// What a missing document reads as.
    fn none() -> Doc {
        Doc { at: 0, data: Value::Null }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Usage {
    at: u64,
    data: Value,
    /// When the service received it (Unix seconds): what expiry goes by.
    put_at: u64,
}

/// Everything `prefs` keeps, as it is saved in `prefs.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Prefs {
    /// The service's identity: 16 lowercase hex characters, made once.
    store: String,
    #[serde(default)]
    docs: BTreeMap<String, Doc>,
    #[serde(default)]
    usage: BTreeMap<String, Usage>,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs::new()
    }
}

/// A fresh random store id, without another dependency: `RandomState` is seeded randomly per
/// process and differs for every instance, and the time and pid are hashed in on top.
fn new_store() -> String {
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    h.write_u32(std::process::id());
    format!("{:016x}", h.finish())
}

fn is_store(s: &str) -> bool {
    s.len() == 16 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

impl Prefs {
    pub fn new() -> Prefs {
        Prefs { store: new_store(), docs: BTreeMap::new(), usage: BTreeMap::new() }
    }

    /// Takes `data` when the stored `at` (0 when there is none) is `base`. Err: the stored one,
    /// as it reads.
    pub fn put(&mut self, name: &str, at: u64, base: u64, data: Value) -> Result<(), Doc> {
        let current = self.get(name);
        if current.at != base {
            return Err(current);
        }
        self.docs.insert(name.to_string(), Doc { at, data });
        Ok(())
    }

    /// Replaces `device`'s usage whatever its `at`; `now_secs` is when it was received.
    pub fn put_usage(&mut self, device: &str, at: u64, data: Value, now_secs: u64) {
        self.usage.insert(device.to_string(), Usage { at, data, put_at: now_secs });
    }

    /// Drops the usage of every device not received for more than [`USAGE_KEEP`]. Documents
    /// never expire. True when something went.
    pub fn expire(&mut self, now_secs: u64) -> bool {
        let before = self.usage.len();
        self.usage.retain(|_, u| now_secs.saturating_sub(u.put_at) <= USAGE_KEEP);
        self.usage.len() != before
    }

    /// One document; a missing one is `{"at":0,"data":null}`.
    pub fn get(&self, name: &str) -> Doc {
        self.docs.get(name).cloned().unwrap_or_else(Doc::none)
    }

    /// `GET /prefs/v1/all`: the store, each document there is, and `usage` when any device has one.
    pub fn all(&self) -> Value {
        let mut all = Map::new();
        all.insert("store".into(), json!(self.store));
        for (name, d) in &self.docs {
            all.insert(name.clone(), json!(d));
        }
        if !self.usage.is_empty() {
            let usage: Map<String, Value> =
                self.usage.iter().map(|(dev, u)| (dev.clone(), json!({"at": u.at, "data": u.data}))).collect();
            all.insert("usage".into(), Value::Object(usage));
        }
        Value::Object(all)
    }
}

pub(crate) struct PrefsBlock {
    prefs: Mutex<Prefs>,
}

impl PrefsBlock {
    pub(crate) fn new() -> PrefsBlock {
        PrefsBlock { prefs: Mutex::new(Prefs::new()) }
    }

    fn lock(&self) -> MutexGuard<'_, Prefs> {
        self.prefs.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Builtin for PrefsBlock {
    fn name(&self) -> &'static str {
        "prefs"
    }

    fn version(&self) -> u32 {
        1
    }

    fn file(&self) -> &'static str {
        "prefs.json"
    }

    fn handle<'a>(&'a self, cx: &'a Ctx, req: Request<Incoming>, rest: &'a str) -> Fut<'a> {
        Box::pin(self.route(cx, req, rest))
    }

    fn save(&self) -> serde_json::Result<Vec<u8>> {
        serde_json::to_vec(&*self.lock())
    }

    /// With what has expired since the save dropped.
    fn load(&self, bytes: &[u8]) -> Result<(), String> {
        let mut p = serde_json::from_slice::<Prefs>(bytes).map_err(|_| "parse".to_string())?;
        if !is_store(&p.store) || p.docs.keys().any(|n| !NAMES.contains(&n.as_str())) {
            return Err("parse".to_string());
        }
        p.expire(now());
        *self.lock() = p;
        Ok(())
    }

    /// Expires old usage every 10 minutes.
    fn spawn(self: Arc<Self>, cx: Ctx) -> Option<JoinHandle<()>> {
        Some(tokio::spawn(async move {
            let mut tick = tokio::time::interval(EXPIRE_EVERY);
            loop {
                tick.tick().await;
                if self.lock().expire(now()) {
                    cx.mark();
                }
            }
        }))
    }
}

fn not_found() -> Response<Body> {
    reply(StatusCode::NOT_FOUND, json!({"error": "not found"}))
}

fn not_allowed() -> Response<Body> {
    reply(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "method not allowed"}))
}

fn bad() -> Response<Body> {
    reply(StatusCode::BAD_REQUEST, json!({"error": "bad request"}))
}

fn too_large() -> Response<Body> {
    reply(StatusCode::PAYLOAD_TOO_LARGE, json!({"error": "too large"}))
}

fn no_content() -> Response<Body> {
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .body(Full::new(Bytes::new()).boxed())
        .expect("static response parts are valid")
}

/// Why a body is refused.
enum Refused {
    Bad,
    TooLarge,
}

impl Refused {
    fn reply(self) -> Response<Body> {
        match self {
            Refused::Bad => bad(),
            Refused::TooLarge => too_large(),
        }
    }
}

/// A body's `at`, `base` (when `with_base`, else 0) and `data`.
async fn read_body(req: Request<Incoming>, with_base: bool) -> Result<(u64, u64, Value), Refused> {
    let body = match Limited::new(req.into_body(), MAX_BODY).collect().await {
        Ok(b) => b.to_bytes(),
        Err(_) => return Err(Refused::TooLarge),
    };
    let Ok(Value::Object(mut v)) = serde_json::from_slice::<Value>(&body) else { return Err(Refused::Bad) };
    let at = v.get("at").and_then(Value::as_u64).ok_or(Refused::Bad)?;
    let base = if with_base { v.get("base").and_then(Value::as_u64).ok_or(Refused::Bad)? } else { 0 };
    let data = v.remove("data").ok_or(Refused::Bad)?;
    let size = serde_json::to_vec(&data).map_or(usize::MAX, |b| b.len());
    if size > MAX_DATA {
        return Err(Refused::TooLarge);
    }
    Ok((at, base, data))
}

impl PrefsBlock {
    async fn route(&self, cx: &Ctx, req: Request<Incoming>, rest: &str) -> Response<Body> {
        let Some(path) = rest.strip_prefix("/v1/") else { return not_found() };
        if let Some(device) = path.strip_prefix("usage/") {
            if req.method() != Method::PUT {
                return not_allowed();
            }
            return self.put_usage(cx, device, req).await;
        }
        if path == "all" {
            if req.method() != Method::GET {
                return not_allowed();
            }
            return reply(StatusCode::OK, self.lock().all());
        }
        let Some(&name) = NAMES.iter().find(|n| **n == path) else { return not_found() };
        match *req.method() {
            Method::GET => reply(StatusCode::OK, json!(self.lock().get(name))),
            Method::PUT => self.put_doc(cx, name, req).await,
            _ => not_allowed(),
        }
    }

    async fn put_doc(&self, cx: &Ctx, name: &str, req: Request<Incoming>) -> Response<Body> {
        let (at, base, data) = match read_body(req, true).await {
            Ok(b) => b,
            Err(r) => return r.reply(),
        };
        let result = {
            let mut p = self.lock();
            let r = p.put(name, at, base, data);
            if r.is_ok() {
                cx.publish([json!({"what": format!("prefs.{name}"), "doc": p.get(name)})]);
            }
            r
        };
        match result {
            Ok(()) => {
                cx.mark();
                cx.log.emit("prefs", json!({"doc": name}));
                no_content()
            }
            Err(current) => reply(StatusCode::CONFLICT, json!(current)),
        }
    }

    async fn put_usage(&self, cx: &Ctx, device: &str, req: Request<Incoming>) -> Response<Body> {
        if device.is_empty() || device.contains('/') || device.chars().count() > DEVICE_MAX {
            return bad();
        }
        let (at, _, data) = match read_body(req, false).await {
            Ok(b) => b,
            Err(r) => return r.reply(),
        };
        {
            let mut p = self.lock();
            let doc = Doc { at, data: data.clone() };
            p.put_usage(device, at, data, now());
            cx.publish([json!({"what": "prefs.usage", "device": device, "doc": doc})]);
        }
        cx.mark();
        cx.log.emit("prefs", json!({"doc": "usage"}));
        no_content()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_and_loaded_are_the_same() {
        let b = PrefsBlock::new();
        {
            let mut p = b.lock();
            p.put("phrases", 3, 0, json!(["a"])).unwrap();
            p.put_usage("dev1", 9, json!({"a":{}}), now());
        }
        let saved = b.save().unwrap();
        let v: Value = serde_json::from_slice(&saved).unwrap();
        assert_eq!(v["docs"], json!({"phrases":{"at":3,"data":["a"]}}));
        assert_eq!((v["usage"]["dev1"]["at"].as_u64(), v["usage"]["dev1"]["data"].clone()), (Some(9), json!({"a":{}})));
        assert!(v["usage"]["dev1"]["put_at"].is_u64());
        let c = PrefsBlock::new();
        assert_ne!(c.lock().store, b.lock().store);
        assert_eq!(c.load(&saved), Ok(()));
        assert_eq!(*c.lock(), *b.lock());
    }

    #[test]
    fn loading_drops_expired_usage() {
        let mut p = Prefs::new();
        p.put_usage("old", 1, json!({}), 1);
        p.put_usage("new", 1, json!({}), now());
        let b = PrefsBlock::new();
        assert_eq!(b.load(&serde_json::to_vec(&p).unwrap()), Ok(()));
        assert_eq!(b.lock().usage.keys().collect::<Vec<_>>(), ["new"]);
    }

    #[test]
    fn a_broken_file_does_not_load() {
        let b = PrefsBlock::new();
        let before = b.lock().clone();
        for bad in [
            &b"{not json"[..],
            br#"{"store":"XYZ","docs":{},"usage":{}}"#,
            br#"{"store":"0123456789abcdef","docs":{"nope":{"at":1,"data":1}},"usage":{}}"#,
            br#"{"docs":{},"usage":{}}"#,
        ] {
            assert_eq!(b.load(bad), Err("parse".to_string()));
        }
        assert_eq!(*b.lock(), before);
        assert_eq!(b.load(br#"{"store":"0123456789abcdef","docs":{},"usage":{}}"#), Ok(()));
        assert_eq!(b.lock().all(), json!({"store":"0123456789abcdef"}));
    }

    #[test]
    fn store_ids_are_16_lowercase_hex_and_differ() {
        let (a, b) = (new_store(), new_store());
        assert!(is_store(&a) && is_store(&b), "{a} {b}");
        assert_ne!(a, b);
    }

    #[test]
    fn the_samples_are_what_the_service_gives() {
        let lines: Vec<Value> = include_str!("../../api/samples/prefs.ndjson")
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        let mut p = Prefs::new();
        p.store = lines[0]["store"].as_str().unwrap().to_string();
        for name in NAMES {
            let d = &lines[0][name];
            p.put(name, d["at"].as_u64().unwrap(), 0, d["data"].clone()).unwrap();
        }
        for (dev, u) in lines[0]["usage"].as_object().unwrap() {
            p.put_usage(dev, u["at"].as_u64().unwrap(), u["data"].clone(), now());
        }
        assert_eq!(p.all(), lines[0]);
        assert!(lines[1..].iter().all(|l| l["what"].as_str().is_some_and(|w| w.starts_with("prefs."))));
        assert_eq!(lines[1], json!({"what":"prefs.phrases","doc": p.get("phrases")}));
    }
}
