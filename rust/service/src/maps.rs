//! Local ports for other devices' shares in the service: the table and its rules are
//! `rapp_ports`; a connection goes on through `pipe::open`, by the same road as `rapp pipe`
//! (LAN, direct or relay). The service listens for the whole system on a PC.

use crate::state::State;
use rapp_net::log::Log;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

pub use rapp_ports::{free, listen, Maps, COUNT, FIRST};

impl rapp_ports::Carrier for State {
    fn maps(&self) -> &Maps {
        &self.maps
    }

    fn log(&self) -> &Log {
        &self.log
    }

    async fn open(&self, id: &str, port: u16) -> Result<rapp_conn::Pipe, String> {
        crate::pipe::open(self, id, port).await.map(|(pipe, _)| pipe).map_err(|e| e.as_str().to_string())
    }
}

/// `rapp_ports::ensure_all` for the shares `(port, wanted)` of the device `id`, in the running
/// service: away from the numbers seen on other devices and this device's own.
pub async fn ensure_all(state: &Arc<State>, id: &str, wants: &[(u16, Option<u16>)]) -> Vec<Option<u16>> {
    let mine: Vec<u16> = state.shares.list().iter().filter_map(|s| s.local).collect();
    let mut avoid = state.numbers.seen();
    avoid.extend(&mine);
    let serve = serve(state);
    rapp_ports::ensure_all(&state.maps, id, wants, &avoid, &mine, &serve).await
}

/// The accept loop of a map's listener in the running service.
pub fn serve(state: &Arc<State>) -> impl Fn(TcpListener, u16) -> JoinHandle<()> {
    rapp_ports::serve(state.clone())
}
