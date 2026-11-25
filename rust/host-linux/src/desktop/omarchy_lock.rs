//! Authenticate Omarchy's IPC peer before trusting its lock status. IPC carries
//! only a status query; passwords still go through the compositor to PAM.
use anyhow::{bail, ensure, Context, Result};
use std::{
    fs,
    io::{Read, Write},
    os::{
        fd::AsRawFd,
        unix::{fs::MetadataExt, net::UnixStream},
    },
    path::Path,
    time::{Duration, Instant},
};

const CONFIG: &[u8] = b"/usr/share/omarchy/shell";

fn session_matches(env: &[u8], display: &str, runtime: &str) -> bool {
    let value = |key: &[u8]| env.split(|c| *c == 0).find_map(|e| e.strip_prefix(key));
    value(b"WAYLAND_DISPLAY=") == Some(display.as_bytes())
        && value(b"XDG_RUNTIME_DIR=") == Some(runtime.as_bytes())
}

fn config_matches(cmdline: &[u8]) -> bool {
    let args: Vec<_> = cmdline
        .strip_suffix(&[0])
        .unwrap_or(cmdline)
        .split(|c| *c == 0)
        .collect();
    // Reject extra arguments, alternate configs and the generic Quickshell shell.
    matches!(args.as_slice(), [_, b"-n", b"-p", config] | [_, b"-p", config] if *config == CONFIG)
}

fn verified_peer(
    stream: &UnixStream,
    proc_root: &Path,
    display: &str,
    runtime: &str,
) -> Result<()> {
    let mut peer: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of_val(&peer) as libc::socklen_t;
    ensure!(
        unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut peer as *mut _ as *mut libc::c_void,
                &mut len,
            )
        } == 0
            && len as usize == std::mem::size_of_val(&peer),
        "cannot verify Omarchy IPC peer"
    );
    let uid = unsafe { libc::getuid() };
    ensure!(
        peer.uid == uid && peer.pid > 0,
        "Omarchy IPC belongs to another user"
    );
    let process = proc_root.join(peer.pid.to_string());
    ensure!(
        fs::metadata(&process)?.uid() == uid,
        "Omarchy process belongs to another user"
    );
    ensure!(
        fs::read_link(process.join("exe"))? == Path::new("/usr/bin/quickshell"),
        "not an Omarchy shell process"
    );
    ensure!(
        config_matches(&fs::read(process.join("cmdline"))?),
        "not the installed Omarchy shell configuration"
    );
    ensure!(
        session_matches(&fs::read(process.join("environ"))?, display, runtime),
        "Omarchy shell belongs to another Wayland session"
    );
    Ok(())
}

fn status(stream: &mut UnixStream) -> Result<serde_json::Value> {
    let deadline = Instant::now() + Duration::from_millis(500);
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    stream.write_all(b"lock\x1fstatus\x1e")?;
    let mut reply = Vec::new();
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .context("Omarchy lock status timed out")?;
        stream.set_read_timeout(Some(remaining))?;
        let mut byte = [0];
        stream
            .read_exact(&mut byte)
            .context("Omarchy lock status is unavailable")?;
        if byte[0] == 0x1e {
            break;
        }
        ensure!(reply.len() < 4096, "Omarchy lock status is too large");
        reply.push(byte[0]);
    }
    let json = reply
        .strip_prefix(b"OK\x1f")
        .context("Omarchy does not expose lock status")?;
    serde_json::from_slice(json).context("invalid Omarchy lock status")
}

fn ready(status: &serde_json::Value) -> Result<()> {
    ensure!(
        status["locked"] == true
            && status["requested"] == true
            && status["sessionLocked"] == true
            && status["secure"] == true,
        "Omarchy lock screen is not securely active"
    );
    ensure!(
        status["passwordPam"] == true,
        "Omarchy password authentication is unavailable"
    );
    ensure!(
        status["authenticating"] == false,
        "Omarchy is already authenticating; retry after it finishes"
    );
    Ok(())
}

fn shell_status() -> Result<serde_json::Value> {
    let display = std::env::var("WAYLAND_DISPLAY").context("no Wayland display")?;
    let runtime = std::env::var("XDG_RUNTIME_DIR").context("no session runtime directory")?;
    for entry in fs::read_dir(&runtime)?.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Some(id) = name
            .strip_prefix("omarchy-shell-")
            .and_then(|n| n.strip_suffix(".sock"))
        else {
            continue;
        };
        if id.len() != 16 || !id.bytes().all(|c| c.is_ascii_hexdigit()) {
            continue;
        }
        let Ok(mut stream) = UnixStream::connect(entry.path()) else {
            continue;
        };
        if verified_peer(&stream, Path::new("/proc"), &display, &runtime).is_err() {
            continue;
        }
        return status(&mut stream);
    }
    bail!("this session locker does not support verified remote password entry")
}

pub(super) fn verify() -> Result<()> {
    ready(&shell_status()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    #[ignore = "requires a running Omarchy shell; read-only status query"]
    fn native_omarchy_status_verifies_the_actual_peer() {
        let state = shell_status().unwrap();
        assert!(state["secure"].is_boolean());
        assert!(state["passwordPam"].is_boolean());
        if state["secure"] == false {
            assert!(ready(&state)
                .unwrap_err()
                .to_string()
                .contains("not securely active"));
        }
    }

    #[test]
    fn unresponsive_shell_times_out() {
        let (mut client, _server) = UnixStream::pair().unwrap();
        let start = Instant::now();
        assert!(status(&mut client).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn rejects_other_configs_and_sessions() {
        assert!(config_matches(
            b"quickshell\0-n\0-p\0/usr/share/omarchy/shell\0"
        ));
        for cmd in [
            b"quickshell\0".as_slice(),
            b"quickshell\0-n\0-p\0/tmp/shell\0",
            b"quickshell\0-n\0-p\0/usr/share/omarchy/shell\0-p\0/tmp/shell\0",
        ] {
            assert!(!config_matches(cmd));
        }
        let env = b"WAYLAND_DISPLAY=wayland-1\0XDG_RUNTIME_DIR=/run/user/1000\0";
        assert!(session_matches(env, "wayland-1", "/run/user/1000"));
        assert!(!session_matches(env, "wayland-2", "/run/user/1000"));
        assert!(!session_matches(env, "wayland-1", "/run/user/1001"));
    }

    #[test]
    fn requires_secure_password_ready_lock() {
        let good = json!({"locked":true,"requested":true,"sessionLocked":true,"secure":true,"passwordPam":true,"authenticating":false});
        ready(&good).unwrap();
        for key in [
            "locked",
            "requested",
            "sessionLocked",
            "secure",
            "passwordPam",
            "authenticating",
        ] {
            let mut bad = good.clone();
            bad[key] = json!(!good[key].as_bool().unwrap());
            assert!(ready(&bad).is_err(), "{key}");
            bad.as_object_mut().unwrap().remove(key);
            assert!(ready(&bad).is_err(), "missing {key}");
        }
    }

    #[test]
    fn reads_only_complete_bounded_status_replies() {
        for (reply, ok) in [
            (b"OK\x1f{\"locked\":true}\x1e".to_vec(), true),
            (b"OK\x1f{}".to_vec(), false),
            (b"SKIP\x1e".to_vec(), false),
            (b"OK\x1fnot json\x1e".to_vec(), false),
            (vec![b'x'; 4097], false),
        ] {
            let (mut client, mut server) = UnixStream::pair().unwrap();
            let thread = std::thread::spawn(move || {
                let mut query = [0; 12];
                server.read_exact(&mut query).unwrap();
                assert_eq!(&query, b"lock\x1fstatus\x1e");
                server.write_all(&reply).unwrap();
            });
            assert_eq!(status(&mut client).is_ok(), ok);
            thread.join().unwrap();
        }
    }

    #[test]
    fn binds_socket_to_peer_executable_config_and_session() {
        let (client, _server) = UnixStream::pair().unwrap();
        let root = tempfile::tempdir().unwrap();
        let process = root.path().join(std::process::id().to_string());
        fs::create_dir(&process).unwrap();
        std::os::unix::fs::symlink("/usr/bin/quickshell", process.join("exe")).unwrap();
        fs::write(
            process.join("cmdline"),
            b"quickshell\0-n\0-p\0/usr/share/omarchy/shell\0",
        )
        .unwrap();
        fs::write(
            process.join("environ"),
            b"WAYLAND_DISPLAY=wayland-1\0XDG_RUNTIME_DIR=/run/user/1000\0",
        )
        .unwrap();
        verified_peer(&client, root.path(), "wayland-1", "/run/user/1000").unwrap();
        assert!(verified_peer(&client, root.path(), "wayland-2", "/run/user/1000").is_err());
        fs::remove_file(process.join("exe")).unwrap();
        std::os::unix::fs::symlink("/usr/bin/other", process.join("exe")).unwrap();
        assert!(verified_peer(&client, root.path(), "wayland-1", "/run/user/1000").is_err());
    }
}
