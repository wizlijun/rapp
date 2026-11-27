//! Linux process ownership, independent of data root, executable and port settings.
//! Windows: a named mutex per logon session (`Local\com.rapp.service.<session>`, spec §5.3).
use std::io;
#[cfg(target_os = "linux")]
use std::os::linux::net::SocketAddrExt;
#[cfg(target_os = "linux")]
use std::os::unix::net::{SocketAddr, UnixListener};

#[cfg(target_os = "linux")]
pub fn acquire() -> io::Result<Option<UnixListener>> {
    // SAFETY: geteuid takes no pointers and cannot fail.
    let uid = unsafe { libc::geteuid() };
    bind(format!("com.rapp.service.{uid}").as_bytes())
}

#[cfg(target_os = "linux")]
fn bind(name: &[u8]) -> io::Result<Option<UnixListener>> {
    // Abstract sockets disappear even after SIGKILL; no stale PID/lock file to
    // unlink. UnixListener is CLOEXEC, so workers cannot inherit ownership.
    let address = SocketAddr::from_abstract_name(name)?;
    match UnixListener::bind_addr(&address) {
        Ok(listener) => Ok(Some(listener)),
        Err(e) if e.kind() == io::ErrorKind::AddrInUse => Ok(None),
        Err(e) => Err(e),
    }
}

/// One owner per logon session: the mutex dies with the process, even when it is killed.
#[cfg(windows)]
pub fn acquire() -> io::Result<Option<rapp_net::win::NamedMutex>> {
    use rapp_service::supervise::mutex_name;
    rapp_net::win::NamedMutex::acquire(&mutex_name(rapp_net::win::session_id(), false))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn ownership_is_exclusive_and_released_on_drop() {
        // A name of its own, so a service running on this machine does not get in the way.
        let name = format!(r"Local\rapp-service-test.{}", std::process::id());
        let acquire = || -> io::Result<_> { rapp_net::win::NamedMutex::acquire(&name) };
        let first = acquire().unwrap().unwrap();
        assert!(acquire().unwrap().is_none());
        drop(first);
        assert!(acquire().unwrap().is_some());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn ownership_is_exclusive_and_released_on_drop() {
        let name = format!("rapp-service-test.{}", std::process::id());
        let first = bind(name.as_bytes()).unwrap().unwrap();
        assert!(bind(name.as_bytes()).unwrap().is_none());
        drop(first);
        assert!(bind(name.as_bytes()).unwrap().is_some());
    }
}
