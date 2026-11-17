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

pub fn ensure_running(state: &std::sync::Arc<State>) {
    // A service can start before graphical login. Refresh the current desktop
    // on the blocking pool, without delaying terminal or application traffic.
    #[cfg(target_os = "linux")]
    {
        let state = state.clone();
        tokio::task::spawn_blocking(move || {
            if gui_path(&state).is_none() { return; }
            let env = rapp_term::pty::launch::desktop_env();
            ensure_on_desktop(&state, &env);
        });
    }
    #[cfg(not(target_os = "linux"))]
    ensure_on_desktop(state, &Default::default());
}

fn ensure_on_desktop(state: &State, env: &std::collections::BTreeMap<String, String>) {
    let mut cm = state.cm.lock().unwrap();
    if cm.as_mut().is_some_and(|c| matches!(c.try_wait(), Ok(None))) {
        // On Linux the child may now also own the main window. Its process
        // being alive does not mean the connection-manager window is open.
        // Forward another --cm to GtkApplication and reap the short-lived
        // launcher, while retaining the original child for later reaping.
        #[cfg(target_os = "linux")]
        if let Some(mut launcher) = launch(state, env) {
            std::thread::spawn(move || { let _ = launcher.wait(); });
        }
        return;
    }
    *cm = launch(state, env);
}

fn launch(state: &State, env: &std::collections::BTreeMap<String, String>) -> Option<std::process::Child> {
    gui_path(state).and_then(|p| {
        Command::new(&p)
            .arg("--cm")
            .envs(env)
            .stdin(Stdio::null())
            .spawn()
            .map_err(|e| state.log.msg(rapp_net::log::Lvl::Warn, format!("start {} --cm: {e}", p.display())))
            .ok()
    })
}
