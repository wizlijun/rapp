use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};

use crate::Fp;

const LOCK_POLL: Duration = Duration::from_millis(50);
/// A lock older than this was left by a crash and may be taken over.
const LOCK_STALE: Duration = Duration::from_secs(10);
/// A waiter polls until the holder finishes or the lock goes stale (10 s), plus a margin for the
/// takeover; only then does it give up.
const LOCK_WAIT: Duration = Duration::from_secs(12);

fn lock_age(lock: &Path) -> Option<Duration> {
    std::fs::metadata(lock).and_then(|m| m.modified()).ok()?.elapsed().ok()
}

/// Removes a crash-left lock. The lock is renamed to a unique name first, so of several waiters
/// exactly one gets it (the others see NotFound) and nobody can delete a lock someone else has
/// just created in its place. True when this caller removed a stale lock.
fn take_over_stale(lock: &Path) -> bool {
    if !lock.exists() || !lock_age(lock).is_some_and(|age| age > LOCK_STALE) {
        return false;
    }
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let mut name = lock.as_os_str().to_owned();
    name.push(format!(".stale.{}.{nanos}", std::process::id()));
    let taken = std::path::PathBuf::from(name);
    if std::fs::rename(lock, &taken).is_err() {
        return false;
    }
    // Between the check and the rename another waiter may have replaced the lock; if what we
    // hold is fresh, put it back (hard_link fails rather than overwrite a newer lock).
    if !lock_age(&taken).is_some_and(|age| age > LOCK_STALE) {
        let _ = std::fs::hard_link(&taken, lock);
        let _ = std::fs::remove_file(&taken);
        return false;
    }
    let _ = std::fs::remove_file(&taken);
    true
}

/// A device's self-signed P-256 certificate and key. Peers pin `fp`, not a CA.
pub struct Identity {
    pub cert: CertificateDer<'static>,
    pub key: PrivatePkcs8KeyDer<'static>,
    pub fp: Fp,
}

impl Identity {
    pub fn generate() -> Result<Identity> {
        let kp = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)?;
        let cert = rcgen::CertificateParams::new(vec!["rapp".to_string()])?.self_signed(&kp)?;
        Identity::from_parts(cert.der().to_vec(), kp.serialize_der())
    }

    /// Reads `<dir>/<stem>.key` and `<stem>.crt`; creates both (0600) unless both exist.
    pub fn load_or_create(dir: &Path, stem: &str) -> Result<Identity> {
        let (key_path, crt_path) = (dir.join(format!("{stem}.key")), dir.join(format!("{stem}.crt")));
        // Only a missing file means "create". Any other error (EACCES, EIO...) must not
        // silently replace an existing identity: that would change the fingerprint.
        let read = |p: &Path| match std::fs::read(p) {
            Ok(b) => Ok(Some(b)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e).with_context(|| format!("read {}", p.display())),
        };
        if let (Some(key), Some(crt)) = (read(&key_path)?, read(&crt_path)?) {
            return Identity::from_parts(crt, key).with_context(|| format!("load {}", crt_path.display()));
        }
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
        let lock = dir.join(format!("{stem}.lock"));
        let started = Instant::now();
        loop {
            match std::fs::OpenOptions::new().write(true).create_new(true).open(&lock) {
                Ok(_) => {
                    // Whoever got here first may have finished while we raced for the lock.
                    let made = (|| {
                        if let (Some(key), Some(crt)) = (read(&key_path)?, read(&crt_path)?) {
                            return Identity::from_parts(crt, key);
                        }
                        let id = Identity::generate()?;
                        // Certificate first: a reader that sees both files sees a finished pair.
                        rapp_net::config::write_private(&crt_path, &id.cert)?;
                        rapp_net::config::write_private(&key_path, id.key.secret_pkcs8_der())?;
                        Ok(id)
                    })();
                    let _ = std::fs::remove_file(&lock);
                    return made;
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e).with_context(|| format!("create {}", lock.display())),
            }
            if take_over_stale(&lock) {
                continue;
            }
            std::thread::sleep(LOCK_POLL);
            if let (Some(key), Some(crt)) = (read(&key_path)?, read(&crt_path)?) {
                return Identity::from_parts(crt, key).with_context(|| format!("load {}", crt_path.display()));
            }
            if started.elapsed() > LOCK_WAIT {
                anyhow::bail!("timed out waiting for another process to create {}", key_path.display());
            }
        }
    }

    fn from_parts(cert: Vec<u8>, key: Vec<u8>) -> Result<Identity> {
        let fp = Fp::of_cert(&cert)?;
        Ok(Identity { cert: CertificateDer::from(cert), key: PrivatePkcs8KeyDer::from(key), fp })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_or_create_is_stable_and_private() {
        let d = tempfile::tempdir().unwrap();
        let a = Identity::load_or_create(d.path(), "device").unwrap();
        let b = Identity::load_or_create(d.path(), "device").unwrap();
        assert_eq!(a.fp, b.fp);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(d.path().join("device.key")).unwrap().permissions().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn half_pair_is_regenerated() {
        let d = tempfile::tempdir().unwrap();
        let a = Identity::load_or_create(d.path(), "device").unwrap();
        std::fs::remove_file(d.path().join("device.crt")).unwrap();
        let b = Identity::load_or_create(d.path(), "device").unwrap();
        assert_ne!(a.fp, b.fp);
        assert_eq!(Identity::load_or_create(d.path(), "device").unwrap().fp, b.fp);
    }

    #[cfg(unix)]
    #[test]
    fn unreadable_key_is_an_error_not_a_regeneration() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let a = Identity::load_or_create(d.path(), "relay").unwrap();
        let key = d.path().join("relay.key");
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o000)).unwrap();
        let r = Identity::load_or_create(d.path(), "relay");
        let readable_anyway = std::fs::read(&key).is_ok(); // running as root
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
        if !readable_anyway {
            let msg = format!("{:#}", r.err().expect("must fail"));
            assert!(msg.contains(&key.display().to_string()), "{msg}");
        }
        assert_eq!(Identity::load_or_create(d.path(), "relay").unwrap().fp, a.fp);
    }

    #[test]
    fn concurrent_load_or_create_agrees() {
        let d = tempfile::tempdir().unwrap();
        let fps: Vec<_> = (0..8)
            .map(|_| {
                let dir = d.path().to_path_buf();
                std::thread::spawn(move || Identity::load_or_create(&dir, "device").unwrap().fp)
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();
        let after = Identity::load_or_create(d.path(), "device").unwrap().fp;
        assert!(fps.iter().all(|f| *f == after));
        assert!(!d.path().join("device.lock").exists());
    }

    fn old_lock(path: &Path) {
        let f = std::fs::File::create(path).unwrap();
        f.set_modified(std::time::SystemTime::now() - Duration::from_secs(60)).unwrap();
    }

    #[test]
    fn stale_lock_is_taken_over() {
        let d = tempfile::tempdir().unwrap();
        old_lock(&d.path().join("device.lock"));
        let a = Identity::load_or_create(d.path(), "device").unwrap();
        assert_eq!(Identity::load_or_create(d.path(), "device").unwrap().fp, a.fp);
        assert!(!d.path().join("device.lock").exists());
    }

    #[test]
    fn fresh_lock_is_not_taken_over() {
        let d = tempfile::tempdir().unwrap();
        let lock = d.path().join("device.lock");
        std::fs::File::create(&lock).unwrap();
        assert!(!take_over_stale(&lock));
        assert!(lock.exists());
    }

    #[test]
    fn stale_takeover_has_one_winner() {
        let d = tempfile::tempdir().unwrap();
        let lock = d.path().join("device.lock");
        old_lock(&lock);
        let wins: usize = (0..8)
            .map(|_| {
                let l = lock.clone();
                std::thread::spawn(move || take_over_stale(&l))
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap() as usize)
            .sum();
        assert_eq!(wins, 1);
        assert_eq!(std::fs::read_dir(d.path()).unwrap().count(), 0);
    }

    #[test]
    fn two_identities_differ() {
        assert_ne!(Identity::generate().unwrap().fp, Identity::generate().unwrap().fp);
    }
}
