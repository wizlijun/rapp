//! Address helpers: private-source check (LAN password fallback), LAN addresses
//! and the `id@ip[:port]` host form (spec §2.3).

use crate::crypto::is_valid_id;
use anyhow::{bail, Context, Result};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};

/// A's peer port unless `service.json` says otherwise.
pub const DEFAULT_PEER_PORT: u16 = 22028;

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
        IpAddr::V4(ip) if usable_ipv4(ip) => Some(ip),
        _ => None,
    }
}

/// An address another machine could reach us on: not loopback, link-local or
/// unspecified, and not 198.18.0.0/15 (benchmarking range that Clash/Surge-style
/// TUN proxies hand out as fake IPs; with one on, it is also the "primary").
pub fn usable_ipv4(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    !ip.is_loopback() && !ip.is_link_local() && !ip.is_unspecified() && !(a == 198 && (b & 0xfe) == 18)
}

/// Every IPv4 of this machine (Wi-Fi, Ethernet, Tailscale…), primary first;
/// only [`usable_ipv4`] ones.
pub fn local_ipv4s() -> Vec<Ipv4Addr> {
    let mut v: Vec<Ipv4Addr> = primary_ipv4().into_iter().collect();
    for i in if_addrs::get_if_addrs().unwrap_or_default() {
        if let IpAddr::V4(ip) = i.ip() {
            if usable_ipv4(ip) && !v.contains(&ip) {
                v.push(ip);
            }
        }
    }
    v
}

/// Every usable IPv4 of this machine as `ip:port`, primary first (what a device tells the relay).
pub fn lan_addrs(port: u16) -> Vec<String> {
    local_ipv4s().into_iter().map(|ip| format!("{ip}:{port}")).collect()
}

/// `id@ip`, with `:port` only when it is not the default.
pub fn at_address(id: &str, ip: Ipv4Addr, port: u16) -> String {
    if port == DEFAULT_PEER_PORT {
        format!("{id}@{ip}")
    } else {
        format!("{id}@{ip}:{port}")
    }
}

/// `id` or `id@ip[:port]` → (id, `Some("ip:port")` for the second form).
pub fn split_host_ref(s: &str) -> Result<(String, Option<String>)> {
    let s = s.trim();
    let (id, addr) = match s.split_once('@') {
        None => (s, None),
        Some((id, rest)) => {
            let addr: SocketAddr = match rest.parse::<IpAddr>() {
                Ok(ip) => SocketAddr::new(ip, DEFAULT_PEER_PORT),
                Err(_) => rest.parse().with_context(|| format!("bad address {rest:?}, want ip or ip:port"))?,
            };
            if addr.port() == 0 {
                bail!("bad port in {rest:?}");
            }
            (id, Some(addr.to_string()))
        }
    };
    if !is_valid_id(id) {
        bail!("bad id {id:?}, want 9 digits");
    }
    Ok((id.to_string(), addr))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> bool {
        is_private(s.parse().unwrap())
    }

    #[test]
    fn id_at_address_formats_and_parses() {
        let ip = |s: &str| s.parse().unwrap();
        assert_eq!(at_address("123456789", ip("192.168.1.5"), DEFAULT_PEER_PORT), "123456789@192.168.1.5");
        assert_eq!(at_address("123456789", ip("10.0.0.2"), 4000), "123456789@10.0.0.2:4000");
        let some = |a: &str| Some(a.to_string());
        assert_eq!(split_host_ref("123456789").unwrap(), ("123456789".into(), None));
        assert_eq!(split_host_ref(" 123456789@192.168.1.5 ").unwrap(), ("123456789".into(), some("192.168.1.5:22028")));
        assert_eq!(split_host_ref("123456789@10.0.0.2:4000").unwrap(), ("123456789".into(), some("10.0.0.2:4000")));
        for bad in ["12345", "12345@1.2.3.4", "123456789@", "123456789@host", "123456789@1.2.3.4:x", "123456789@1.2.3.4:0"] {
            assert!(split_host_ref(bad).is_err(), "{bad} should be rejected");
        }
    }

    #[test]
    fn local_ipv4s_skip_loopback_and_repeat_nothing() {
        let v = local_ipv4s();
        assert!(v.iter().all(|&ip| usable_ipv4(ip)), "{v:?}");
        let mut d = v.clone();
        d.dedup();
        assert_eq!(d.len(), v.len());
        if let Some(p) = primary_ipv4() {
            assert_eq!(v.first(), Some(&p), "primary first");
        }
    }

    #[test]
    fn proxy_fake_ips_are_not_advertised() {
        let u = |s: &str| usable_ipv4(s.parse().unwrap());
        for s in ["10.17.0.235", "192.168.2.1", "172.16.0.1", "100.64.0.1", "8.8.8.8"] {
            assert!(u(s), "{s} should be advertised");
        }
        // 198.18.0.0/15: benchmarking range, used by Clash/Surge-style TUN fake IPs.
        for s in ["198.18.0.1", "198.19.255.254", "127.0.0.1", "169.254.91.221", "0.0.0.0"] {
            assert!(!u(s), "{s} should not be advertised");
        }
        assert!(u("198.20.0.1") && u("198.17.255.255"));
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
}
