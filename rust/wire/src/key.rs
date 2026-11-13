use std::fmt;
use std::str::FromStr;

use anyhow::{bail, Result};
use ring::digest::{digest, SHA256};
use ring::hkdf::{Salt, HKDF_SHA256};
use ring::rand::{SecureRandom, SystemRandom};

use crate::Fp;

/// Every key is shown with this in front, so it reads as a rapp key. No separator: the whole key
/// stays letters and digits and selects with one double-click. Parsing accepts it or not; the
/// body's fixed length (26 or 52) tells the two apart, since `rapp` is itself valid base32.
pub const PREFIX: &str = "rapp";

/// The shared secret a user types into a device, optionally prefixed by the 16-byte relay
/// fingerprint prefix it was issued for. No `Debug`/serde on purpose: never log it.
pub struct Key {
    pub relay: Option<[u8; 16]>,
    pub root: [u8; 16],
}

struct Len32;
impl ring::hkdf::KeyType for Len32 {
    fn len(&self) -> usize {
        32
    }
}

fn derive(root: &[u8; 16], label: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    Salt::new(HKDF_SHA256, &[]).extract(root).expand(&[label], Len32).unwrap().fill(&mut out).unwrap();
    out
}

fn random_root() -> [u8; 16] {
    let mut root = [0u8; 16];
    SystemRandom::new().fill(&mut root).expect("system RNG");
    root
}

impl Key {
    pub fn new_for_relay(relay_fp: &Fp) -> Key {
        Key { relay: Some(relay_fp.prefix16()), root: random_root() }
    }

    pub fn new_local() -> Key {
        Key { relay: None, root: random_root() }
    }

    pub fn join(&self) -> [u8; 32] {
        derive(&self.root, b"rapp join/1")
    }

    pub fn trust(&self) -> [u8; 32] {
        derive(&self.root, b"rapp trust/1")
    }

    pub fn matches_relay(&self, fp: &Fp) -> bool {
        self.relay == Some(fp.prefix16())
    }
}

pub fn join_hash(join: &[u8; 32]) -> String {
    data_encoding::HEXLOWER.encode(digest(&SHA256, join).as_ref())
}

impl fmt::Display for Key {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut bytes = Vec::with_capacity(32);
        if let Some(r) = &self.relay {
            bytes.extend_from_slice(r);
        }
        bytes.extend_from_slice(&self.root);
        f.write_str(PREFIX)?;
        f.write_str(&data_encoding::BASE32_NOPAD.encode(&bytes).to_ascii_lowercase())
    }
}

impl FromStr for Key {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Key> {
        let s = s.trim();
        let prefixed = matches!(s.len().checked_sub(PREFIX.len()), Some(26 | 52));
        let body = match s.get(..PREFIX.len()) {
            Some(p) if prefixed && p.eq_ignore_ascii_case(PREFIX) => &s[PREFIX.len()..],
            _ => s,
        };
        // BASE32_NOPAD rejects bad characters and non-zero trailing bits.
        let Ok(bytes) = data_encoding::BASE32_NOPAD.decode(body.to_ascii_uppercase().as_bytes()) else {
            bail!("not a valid key");
        };
        match bytes.len() {
            16 => Ok(Key { relay: None, root: bytes.try_into().unwrap() }),
            32 => Ok(Key { relay: Some(bytes[..16].try_into().unwrap()), root: bytes[16..].try_into().unwrap() }),
            _ => bail!("not a valid key"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Identity;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn text_roundtrip_both_kinds() {
        let fp = Identity::generate().unwrap().fp;
        let k = Key::new_for_relay(&fp);
        let s = k.to_string();
        assert_eq!(s.len(), 56);
        let body = s.strip_prefix("rapp").unwrap();
        assert!(body.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
        for text in [format!("  {}\n", s.to_uppercase()), body.to_string()] {
            let back: Key = text.parse().unwrap();
            assert_eq!(back.root, k.root);
            assert_eq!(back.relay, Some(fp.prefix16()));
            assert!(back.matches_relay(&fp));
        }
        let l = Key::new_local();
        assert_eq!(l.to_string().len(), 30);
        assert!(l.to_string().parse::<Key>().unwrap().relay.is_none());
    }

    #[test]
    fn bad_text_is_rejected() {
        let short = format!("rapp{}", "a".repeat(51));
        for s in ["", "abc", "0189", "rapp", "rapp-", &"a".repeat(51), &"a".repeat(53), &short] {
            assert!(s.parse::<Key>().is_err());
        }
    }

    #[test]
    fn join_and_trust_are_independent_and_deterministic() {
        let k = Key::new_local();
        assert_eq!(k.join(), k.join());
        assert_ne!(k.join(), k.trust());
        assert_ne!(Key::new_local().join(), k.join());
    }

    #[test]
    fn derivation_is_pinned() {
        let k = Key { relay: None, root: [7u8; 16] };
        assert_eq!(hex(&k.join()), "09b6a00150736777b66e774983ca98d26d59759ffc307ffa547837c72da54e1d");
        assert_eq!(hex(&k.trust()), "4965ba91bcafe05d0443ee3a151f2127db73fce6dffa927eff29e0e5424d11ee");
        assert_eq!(join_hash(&k.join()), "0c52152483a912303ea10b96adcec3a86805677f2ff52fbd47fece6154ab66bf");
        assert_eq!(k.to_string(), "rappa4dqobyha4dqobyha4dqobyha4");
    }

    #[test]
    fn wrong_relay_does_not_match() {
        let a = Identity::generate().unwrap().fp;
        let b = Identity::generate().unwrap().fp;
        assert!(!Key::new_for_relay(&a).matches_relay(&b));
    }
}
