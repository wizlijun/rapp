//! Address helpers: private-source check (LAN password fallback) and LAN addresses.

use std::net::{IpAddr, Ipv4Addr, UdpSocket};

/// Loopback, RFC 1918, link-local, CGNAT (Tailscale), IPv6 loopback / ULA / link-local.
pub fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback() || v4.is_private() || v4.is_link_local() || (o[0] == 100 && (o[1] & 0xc0) == 64)
        }
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => is_private(IpAddr::V4(v4)),
            None => {
                let s0 = v6.segments()[0];
                v6.is_loopback() || (s0 & 0xfe00) == 0xfc00 || (s0 & 0xffc0) == 0xfe80
            }
        },
    }
}

/// The primary IPv4: the source address the OS would use to reach the internet.
/// `connect` on UDP sends no packet.
pub fn primary_ipv4() -> Option<Ipv4Addr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("8.8.8.8:80").ok()?;
    match s.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_unspecified() && !ip.is_loopback() => Some(ip),
        _ => None,
    }
}

/// What A reports to the relay: primary IPv4 plus loopback, each with `port`.
pub fn lan_addrs(port: u16) -> Vec<String> {
    let mut v: Vec<String> = primary_ipv4().map(|ip| format!("{ip}:{port}")).into_iter().collect();
    v.push(format!("127.0.0.1:{port}"));
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> bool {
        is_private(s.parse().unwrap())
    }

    #[test]
    fn private_ranges() {
        for s in [
            "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.5",
            "169.254.1.1", "100.64.0.1", "100.127.255.255", "::1", "fd00::1", "fe80::1",
        ] {
            assert!(p(s), "{s} should be private");
        }
        for s in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "1.1.1.1", "2001:4860::8888", "::ffff:8.8.8.8"] {
            assert!(!p(s), "{s} should be public");
        }
        assert!(p("::ffff:192.168.1.1"));
    }

    #[test]
    fn lan_addrs_end_with_loopback() {
        let v = lan_addrs(21118);
        assert_eq!(v.last().unwrap(), "127.0.0.1:21118");
    }
}
