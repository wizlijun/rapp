//! Hashing, hex and randomness helpers (spec §2.1).

use rand::{Rng, RngCore};

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) || !s.is_ascii() {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

pub fn random_hex(nbytes: usize) -> String {
    let mut b = vec![0u8; nbytes];
    rand::rng().fill_bytes(&mut b);
    hex(&b)
}

/// Constant-time string comparison (length is not secret).
pub fn ct_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// 8-character alphanumeric password (spec §3).
pub fn random_password() -> String {
    const CHARS: &[u8] = b"abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::rng();
    (0..8).map(|_| CHARS[rng.random_range(0..CHARS.len())] as char).collect()
}

/// 9 decimal digits, first digit not 0 (spec §2.1).
pub fn random_id() -> String {
    rand::rng().random_range(100_000_000u32..=999_999_999).to_string()
}

pub fn is_valid_id(id: &str) -> bool {
    id.len() == 9 && id.bytes().all(|c| c.is_ascii_digit()) && !id.starts_with('0')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_roundtrip() {
        assert_eq!(hex(&[0x00, 0xab, 0xff]), "00abff");
        assert_eq!(unhex("00abff"), Some(vec![0x00, 0xab, 0xff]));
        assert_eq!(unhex("0g"), None);
        assert_eq!(unhex("abc"), None);
        assert_eq!(random_hex(16).len(), 32);
    }

    #[test]
    fn ct_eq_compares() {
        assert!(ct_eq("abc", "abc"));
        assert!(!ct_eq("abc", "abd"));
        assert!(!ct_eq("abc", "abcd"));
    }

    #[test]
    fn ids_and_passwords() {
        for _ in 0..100 {
            assert!(is_valid_id(&random_id()));
            let p = random_password();
            assert_eq!(p.len(), 8);
            assert!(p.chars().all(|c| c.is_ascii_alphanumeric()));
        }
        assert!(!is_valid_id("012345678"));
        assert!(!is_valid_id("12345678"));
        assert!(!is_valid_id("12345678a"));
    }
}
