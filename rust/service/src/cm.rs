//! Starts `rapp --cm` when a session begins and it is not running (spec §3).
//! GUI lookup: `RAPP_GUI` (passed in as `State::gui`) → `rapp` next to the service.
//! Missing GUI is silently skipped.

use crate::state::State;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn gui_path(state: &State) -> Option<PathBuf> {
    let own = || std::env::current_exe().ok()?.parent().map(|d| d.join(format!("rapp{}", std::env::consts::EXE_SUFFIX)));
    state.gui.clone().or_else(own).filter(|p| p.is_file())
}

pub fn ensure_running(state: &State) {
    let mut cm = state.cm.lock().unwrap();
    if cm.as_mut().is_some_and(|c| matches!(c.try_wait(), Ok(None))) {
        return;
    }
    *cm = gui_path(state).and_then(|p| {
        Command::new(&p)
            .arg("--cm")
            .stdin(Stdio::null())
            .spawn()
            .map_err(|e| state.log.msg(rapp_net::log::Lvl::Warn, format!("start {} --cm: {e}", p.display())))
            .ok()
    });
}
