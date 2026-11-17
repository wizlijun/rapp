//! Linux process ownership, independent of data root, executable and port settings.
use std::io;
use std::os::linux::net::SocketAddrExt;
use std::os::unix::net::{SocketAddr, UnixListener};

pub fn acquire() -> io::Result<Option<UnixListener>> {
    // SAFETY: geteuid takes no pointers and cannot fail.
    let uid = unsafe { libc::geteuid() };
    bind(format!("com.rapp.service.{uid}").as_bytes())
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ownership_is_exclusive_and_released_on_drop() {
        let name = format!("rapp-service-test.{}", std::process::id());
        let first = bind(name.as_bytes()).unwrap().unwrap();
        assert!(bind(name.as_bytes()).unwrap().is_none());
        drop(first);
        assert!(bind(name.as_bytes()).unwrap().is_some());
    }
}
