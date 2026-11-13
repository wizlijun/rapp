use std::fmt;
use std::str::FromStr;

use anyhow::{anyhow, Result};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// SHA-256 of a certificate's SubjectPublicKeyInfo.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Fp(pub [u8; 32]);

impl Fp {
    pub fn of_cert(der: &[u8]) -> Result<Fp> {
        let (_, cert) = x509_parser::parse_x509_certificate(der).map_err(|e| anyhow!("parse certificate: {e}"))?;
        let d = ring::digest::digest(&ring::digest::SHA256, cert.public_key().raw);
        let mut out = [0u8; 32];
        out.copy_from_slice(d.as_ref());
        Ok(Fp(out))
    }

    /// First 8 hex digits, for run logs.
    pub fn short(&self) -> String {
        self.to_string()[..8].to_string()
    }

    pub fn prefix16(&self) -> [u8; 16] {
        let mut out = [0u8; 16];
        out.copy_from_slice(&self.0[..16]);
        out
    }
}

impl fmt::Display for Fp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&data_encoding::HEXLOWER.encode(&self.0))
    }
}

impl fmt::Debug for Fp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Fp({})", self.short())
    }
}

impl FromStr for Fp {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> Result<Fp> {
        let b = data_encoding::HEXLOWER_PERMISSIVE.decode(s.as_bytes()).map_err(|e| anyhow!("bad fingerprint: {e}"))?;
        let arr: [u8; 32] = b.try_into().map_err(|_| anyhow!("bad fingerprint: need 64 hex digits"))?;
        Ok(Fp(arr))
    }
}

impl Serialize for Fp {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Fp {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Fp, D::Error> {
        let s = String::deserialize(d)?;
        s.parse().map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Identity;

    #[test]
    fn fp_is_sha256_of_spki_not_of_whole_cert() {
        let id = Identity::generate().unwrap();
        let spki = x509_parser::parse_x509_certificate(&id.cert).unwrap().1.public_key().raw.to_vec();
        assert_eq!(id.fp.0.as_slice(), ring::digest::digest(&ring::digest::SHA256, &spki).as_ref());
        assert_eq!(Fp::of_cert(&id.cert).unwrap(), id.fp);
    }

    #[test]
    fn fp_text_roundtrip_and_short() {
        let fp = Identity::generate().unwrap().fp;
        let s = fp.to_string();
        assert_eq!(s.len(), 64);
        assert_eq!(s.parse::<Fp>().unwrap(), fp);
        assert_eq!(fp.short(), &s[..8]);
        assert!("zz".parse::<Fp>().is_err());
    }

    #[test]
    fn of_cert_rejects_garbage() {
        assert!(Fp::of_cert(b"not a cert").is_err());
    }

    #[test]
    fn fp_serde_is_hex_string_and_prefix16() {
        let fp = Identity::generate().unwrap().fp;
        let j = serde_json::to_string(&fp).unwrap();
        assert_eq!(j, format!("\"{fp}\""));
        assert_eq!(serde_json::from_str::<Fp>(&j).unwrap(), fp);
        assert_eq!(fp.prefix16(), fp.0[..16]);
    }
}
