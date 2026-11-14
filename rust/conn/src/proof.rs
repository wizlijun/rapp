//! The key-trust proof: HMAC over what this TLS handshake produced, so a proof cannot be
//! replayed on another connection or forwarded by a man in the middle.

use ring::hmac;
use rapp_wire::Fp;

pub const EXPORTER_LABEL: &[u8] = b"EXPORTER-rapp-proof/1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Client,
    Server,
}

/// What one side knows about a finished handshake.
#[derive(Clone, Debug)]
pub struct Facts {
    pub ekm: [u8; 32],
    pub me: Fp,
    pub peer: Fp,
    pub role: Role,
}

fn message(ekm: &[u8; 32], client: &Fp, server: &Fp, role: Role) -> Vec<u8> {
    let mut m = Vec::with_capacity(12 + 32 * 3 + 6);
    m.extend_from_slice(b"rapp proof/1");
    m.extend_from_slice(ekm);
    m.extend_from_slice(&client.0);
    m.extend_from_slice(&server.0);
    m.extend_from_slice(if role == Role::Client { b"client" } else { b"server" });
    m
}

/// The fingerprints in the order the proof wants: client first.
fn ordered(f: &Facts) -> (&Fp, &Fp) {
    match f.role {
        Role::Client => (&f.me, &f.peer),
        Role::Server => (&f.peer, &f.me),
    }
}

/// This side's proof: 64 lowercase hex digits.
pub fn proof(trust: &[u8; 32], f: &Facts) -> String {
    let (c, s) = ordered(f);
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, trust), &message(&f.ekm, c, s, f.role));
    data_encoding::HEXLOWER.encode(tag.as_ref())
}

/// Whether `theirs` is the other side's proof for this handshake.
pub fn check(trust: &[u8; 32], f: &Facts, theirs: &str) -> bool {
    let Ok(tag) = data_encoding::HEXLOWER_PERMISSIVE.decode(theirs.as_bytes()) else { return false };
    let (c, s) = ordered(f);
    let other = if f.role == Role::Client { Role::Server } else { Role::Client };
    hmac::verify(&hmac::Key::new(hmac::HMAC_SHA256, trust), &message(&f.ekm, c, s, other), &tag).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(role: Role) -> Facts {
        let (c, s) = (Fp([2; 32]), Fp([3; 32]));
        let (me, peer) = if role == Role::Client { (c, s) } else { (s, c) };
        Facts { ekm: [1; 32], me, peer, role }
    }

    #[test]
    fn proof_is_pinned() {
        let t = [7u8; 32];
        let p = proof(&t, &facts(Role::Client));
        assert_eq!(p, "ef5359ea3415205ec501d25fb180a5d7833028adf9742e8deed5f847a9cdc7cc");
        assert_ne!(p, proof(&t, &facts(Role::Server)));
        let mut f = facts(Role::Client);
        f.ekm[0] ^= 1;
        assert_ne!(p, proof(&t, &f));
        let mut f = facts(Role::Client);
        f.me.0[0] ^= 1;
        assert_ne!(p, proof(&t, &f));
        let mut f = facts(Role::Client);
        f.peer.0[31] ^= 1;
        assert_ne!(p, proof(&t, &f));
        assert_ne!(p, proof(&[8u8; 32], &facts(Role::Client)));
    }

    #[test]
    fn each_side_checks_the_others_proof() {
        let t = [7u8; 32];
        let (c, s) = (facts(Role::Client), facts(Role::Server));
        assert!(check(&t, &s, &proof(&t, &c)));
        assert!(check(&t, &c, &proof(&t, &s)));
        // a side's own proof is not the other side's
        assert!(!check(&t, &c, &proof(&t, &c)));
        assert!(!check(&[8u8; 32], &s, &proof(&t, &c)));
        assert!(!check(&t, &s, "zz"));
        assert!(!check(&t, &s, ""));
    }
}
