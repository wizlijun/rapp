//! A builtin: one service inside `rapp-center`, under its own prefix (`/<name>/v1/…`), with its own
//! file in the data directory. Adding one is a line in [`table`].

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use hyper::body::Incoming;
use hyper::{Request, Response};
use tokio::task::JoinHandle;

use crate::entry::{Body, Ctx};
use crate::state::StateBlock;
use crate::Config;

pub(crate) type Fut<'a> = Pin<Box<dyn Future<Output = Response<Body>> + Send + 'a>>;

pub(crate) trait Builtin: Send + Sync + 'static {
    /// Its prefix, and its `name` in `/v1/routes`.
    fn name(&self) -> &'static str;
    /// The version of its API, in `/v1/routes`.
    fn version(&self) -> u32;
    /// Its own file in the data directory, such as `"state.json"`.
    fn file(&self) -> &'static str;
    /// `rest` starts with `/v1/`: `/state/v1/queue` comes as `/v1/queue`, the old paths at the
    /// root as they are.
    fn handle<'a>(&'a self, cx: &'a Ctx, req: Request<Incoming>, rest: &'a str) -> Fut<'a>;
    /// All of it, serialized for its file (under its own lock).
    fn save(&self) -> serde_json::Result<Vec<u8>>;
    /// Takes back what [`Builtin::save`] wrote. Err: why (a kind, never the contents).
    fn load(&self, bytes: &[u8]) -> Result<(), String>;
    /// Its own background work, ended with the service. None by default.
    fn spawn(self: Arc<Self>, _cx: Ctx) -> Option<JoinHandle<()>> {
        None
    }
}

/// Every builtin, in the order `/v1/routes` lists them.
pub(crate) fn table(cfg: &Config) -> Vec<Arc<dyn Builtin>> {
    vec![Arc::new(StateBlock::new(cfg.keep_days, cfg.keep_events))]
}
