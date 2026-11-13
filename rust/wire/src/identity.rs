use std::path::Path;

use anyhow::{Context, Result};
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};

use crate::Fp;

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
        if let (Ok(key), Ok(crt)) = (std::fs::read(&key_path), std::fs::read(&crt_path)) {
            return Identity::from_parts(crt, key).with_context(|| format!("load {}", crt_path.display()));
        }
        let id = Identity::generate()?;
        rapp_net::config::write_private(&key_path, id.key.secret_pkcs8_der())?;
        rapp_net::config::write_private(&crt_path, &id.cert)?;
        Ok(id)
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

    #[test]
    fn two_identities_differ() {
        assert_ne!(Identity::generate().unwrap().fp, Identity::generate().unwrap().fp);
    }
}
