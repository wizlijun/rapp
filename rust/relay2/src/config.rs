//! Layered configuration: defaults <- `<data>/config.json` <- `RAPP_RELAY_*` environment.

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::Path;
use std::str::FromStr;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Enroll {
    Open,
    Closed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Info,
    Debug,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct AuditCfg {
    pub keep_days: u32,
    pub max_mb: u64,
    pub required: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Limits {
    pub max_conns: usize,
    pub max_conns_per_ip: usize,
    pub max_streams: u32,
    pub max_relayed_per_device: usize,
    pub max_devices: usize,
    pub unenrolled_idle_secs: u64,
    pub enroll_per_ip_per_min: u32,
    pub max_line: usize,
    pub request_timeout_secs: u64,
    pub lock_after: u32,
    pub lock_max_secs: u64,
    pub connect_per_target_per_min: u32,
    /// 0 means unlimited.
    pub relay_bps_per_stream: u64,
    /// 0 means unlimited.
    pub relay_bps_total: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Config {
    pub listen: SocketAddr,
    pub enroll: Enroll,
    pub log: LogLevel,
    pub audit: AuditCfg,
    pub metrics: Option<SocketAddr>,
    pub limits: Limits,
}

impl Default for AuditCfg {
    fn default() -> Self {
        AuditCfg { keep_days: 180, max_mb: 256, required: false }
    }
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_conns: 4096,
            max_conns_per_ip: 16,
            max_streams: 128,
            max_relayed_per_device: 32,
            max_devices: 1024,
            unenrolled_idle_secs: 10,
            enroll_per_ip_per_min: 10,
            max_line: 8192,
            request_timeout_secs: 10,
            lock_after: 5,
            lock_max_secs: 300,
            connect_per_target_per_min: 60,
            relay_bps_per_stream: 0,
            relay_bps_total: 0,
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Config {
            listen: "0.0.0.0:21116".parse().unwrap(),
            enroll: Enroll::Open,
            log: LogLevel::Info,
            audit: AuditCfg::default(),
            metrics: None,
            limits: Limits::default(),
        }
    }
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileAudit {
    keep_days: Option<u32>,
    max_mb: Option<u64>,
    required: Option<bool>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileLimits {
    max_conns: Option<usize>,
    max_conns_per_ip: Option<usize>,
    max_streams: Option<u32>,
    max_relayed_per_device: Option<usize>,
    max_devices: Option<usize>,
    unenrolled_idle_secs: Option<u64>,
    enroll_per_ip_per_min: Option<u32>,
    max_line: Option<usize>,
    request_timeout_secs: Option<u64>,
    lock_after: Option<u32>,
    lock_max_secs: Option<u64>,
    connect_per_target_per_min: Option<u32>,
    relay_bps_per_stream: Option<u64>,
    relay_bps_total: Option<u64>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileConfig {
    listen: Option<SocketAddr>,
    enroll: Option<Enroll>,
    log: Option<LogLevel>,
    audit: Option<FileAudit>,
    metrics: Option<SocketAddr>,
    limits: Option<FileLimits>,
}

fn set<T>(dst: &mut T, v: Option<T>) {
    if let Some(v) = v {
        *dst = v;
    }
}

fn check_loopback(addr: SocketAddr, what: &str) -> Result<()> {
    if !addr.ip().is_loopback() {
        bail!("{what}: {addr} is not a loopback address");
    }
    Ok(())
}

type Env<'a> = &'a dyn Fn(&str) -> Option<String>;

/// Parse environment variable `name` if set; the error names the variable.
fn env_parse<T: FromStr>(env: Env, name: &str, out: &mut T) -> Result<()>
where
    T::Err: std::fmt::Display,
{
    if let Some(v) = env(name) {
        *out = v.trim().parse().map_err(|e| anyhow!("{name}: bad value {v:?}: {e}"))?;
    }
    Ok(())
}

fn env_enum<T: Copy>(env: Env, name: &str, choices: &[(&str, T)], out: &mut T) -> Result<()> {
    if let Some(v) = env(name) {
        let v = v.trim();
        match choices.iter().find(|(k, _)| *k == v) {
            Some((_, t)) => *out = *t,
            None => {
                let all: Vec<&str> = choices.iter().map(|(k, _)| *k).collect();
                bail!("{name}: bad value {v:?}, expected one of {}", all.join(", "));
            }
        }
    }
    Ok(())
}

pub fn load(data: &Path, env: &dyn Fn(&str) -> Option<String>) -> Result<Config> {
    let mut c = Config::default();

    // File layer.
    let path = data.join("config.json");
    match std::fs::read_to_string(&path) {
        Ok(text) => {
            let f: FileConfig =
                serde_json::from_str(&text).with_context(|| format!("config file {}", path.display()))?;
            set(&mut c.listen, f.listen);
            set(&mut c.enroll, f.enroll);
            set(&mut c.log, f.log);
            if let Some(m) = f.metrics {
                check_loopback(m, "config file: metrics")?;
                c.metrics = Some(m);
            }
            if let Some(a) = f.audit {
                set(&mut c.audit.keep_days, a.keep_days);
                set(&mut c.audit.max_mb, a.max_mb);
                set(&mut c.audit.required, a.required);
            }
            if let Some(l) = f.limits {
                let d = &mut c.limits;
                set(&mut d.max_conns, l.max_conns);
                set(&mut d.max_conns_per_ip, l.max_conns_per_ip);
                set(&mut d.max_streams, l.max_streams);
                set(&mut d.max_relayed_per_device, l.max_relayed_per_device);
                set(&mut d.max_devices, l.max_devices);
                set(&mut d.unenrolled_idle_secs, l.unenrolled_idle_secs);
                set(&mut d.enroll_per_ip_per_min, l.enroll_per_ip_per_min);
                set(&mut d.max_line, l.max_line);
                set(&mut d.request_timeout_secs, l.request_timeout_secs);
                set(&mut d.lock_after, l.lock_after);
                set(&mut d.lock_max_secs, l.lock_max_secs);
                set(&mut d.connect_per_target_per_min, l.connect_per_target_per_min);
                set(&mut d.relay_bps_per_stream, l.relay_bps_per_stream);
                set(&mut d.relay_bps_total, l.relay_bps_total);
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    }

    // Environment layer.
    env_parse(env, "RAPP_RELAY_LISTEN", &mut c.listen)?;
    env_enum(env, "RAPP_RELAY_ENROLL", &[("open", Enroll::Open), ("closed", Enroll::Closed)], &mut c.enroll)?;
    env_enum(env, "RAPP_RELAY_LOG", &[("info", LogLevel::Info), ("debug", LogLevel::Debug)], &mut c.log)?;
    env_parse(env, "RAPP_RELAY_AUDIT_KEEP_DAYS", &mut c.audit.keep_days)?;
    env_parse(env, "RAPP_RELAY_AUDIT_MAX_MB", &mut c.audit.max_mb)?;
    let bools = [("true", true), ("false", false), ("1", true), ("0", false)];
    env_enum(env, "RAPP_RELAY_AUDIT_REQUIRED", &bools, &mut c.audit.required)?;
    if let Some(v) = env("RAPP_RELAY_METRICS") {
        let m: SocketAddr = v.trim().parse().map_err(|e| anyhow!("RAPP_RELAY_METRICS: bad value {v:?}: {e}"))?;
        check_loopback(m, "RAPP_RELAY_METRICS")?;
        c.metrics = Some(m);
    }
    macro_rules! limits_env {
        ($($f:ident),* $(,)?) => {$(
            env_parse(env, &concat!("RAPP_RELAY_LIMIT_", stringify!($f)).to_uppercase(), &mut c.limits.$f)?;
        )*};
    }
    limits_env!(
        max_conns,
        max_conns_per_ip,
        max_streams,
        max_relayed_per_device,
        max_devices,
        unenrolled_idle_secs,
        enroll_per_ip_per_min,
        max_line,
        request_timeout_secs,
        lock_after,
        lock_max_secs,
        connect_per_target_per_min,
        relay_bps_per_stream,
        relay_bps_total,
    );
    Ok(c)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn env_of<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |k| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string())
    }

    #[test]
    fn defaults_without_file_or_env() {
        let d = tempdir().unwrap();
        let c = load(d.path(), &|_| None).unwrap();
        assert_eq!(c, Config::default());
        assert_eq!(c.listen.to_string(), "0.0.0.0:21116");
        assert_eq!(c.limits.max_streams, 128);
        assert_eq!(c.audit.keep_days, 180);
        let l = &c.limits;
        assert_eq!((l.max_conns, l.max_conns_per_ip, l.max_relayed_per_device, l.max_devices), (4096, 16, 32, 1024));
        assert_eq!(
            (l.unenrolled_idle_secs, l.enroll_per_ip_per_min, l.max_line, l.request_timeout_secs),
            (10, 10, 8192, 10)
        );
        assert_eq!(
            (l.lock_after, l.lock_max_secs, l.connect_per_target_per_min, l.relay_bps_per_stream, l.relay_bps_total),
            (5, 300, 60, 0, 0)
        );
    }

    #[test]
    fn env_overrides_file_overrides_default() {
        let d = tempdir().unwrap();
        std::fs::write(d.path().join("config.json"), r#"{"listen":"0.0.0.0:1","audit":{"keep_days":7}}"#).unwrap();
        let c = load(d.path(), &env_of(&[("RAPP_RELAY_LISTEN", "0.0.0.0:2")])).unwrap();
        assert_eq!(c.listen.port(), 2);
        assert_eq!(c.audit.keep_days, 7);
        assert_eq!(c.audit.max_mb, 256);
    }

    #[test]
    fn env_sets_limits_and_flags() {
        let d = tempdir().unwrap();
        let e = env_of(&[
            ("RAPP_RELAY_LIMIT_MAX_CONNS", "5"),
            ("RAPP_RELAY_LIMIT_RELAY_BPS_TOTAL", "1000"),
            ("RAPP_RELAY_AUDIT_REQUIRED", "true"),
            ("RAPP_RELAY_ENROLL", "closed"),
            ("RAPP_RELAY_LOG", "debug"),
            ("RAPP_RELAY_METRICS", "127.0.0.1:9116"),
        ]);
        let c = load(d.path(), &e).unwrap();
        assert_eq!((c.limits.max_conns, c.limits.relay_bps_total), (5, 1000));
        assert!(c.audit.required);
        assert_eq!((c.enroll, c.log), (Enroll::Closed, LogLevel::Debug));
        assert_eq!(c.metrics, Some("127.0.0.1:9116".parse().unwrap()));
        let err = load(d.path(), &env_of(&[("RAPP_RELAY_LIMIT_MAX_CONNS", "x")])).unwrap_err();
        assert!(err.to_string().contains("RAPP_RELAY_LIMIT_MAX_CONNS"));
    }

    #[test]
    fn file_sets_enums_and_limits() {
        let d = tempdir().unwrap();
        std::fs::write(
            d.path().join("config.json"),
            r#"{"enroll":"closed","log":"debug","metrics":"127.0.0.1:1","limits":{"max_line":100}}"#,
        )
        .unwrap();
        let c = load(d.path(), &|_| None).unwrap();
        assert_eq!((c.enroll, c.log, c.limits.max_line), (Enroll::Closed, LogLevel::Debug, 100));
        assert!(c.metrics.is_some());
    }

    #[test]
    fn unknown_key_in_file_refuses_to_start_and_names_it() {
        let d = tempdir().unwrap();
        for (body, key) in [
            (r#"{"lisen":"x"}"#, "lisen"),
            (r#"{"limits":{"max_conn":1}}"#, "max_conn"),
            (r#"{"audit":{"keep":1}}"#, "keep"),
        ] {
            std::fs::write(d.path().join("config.json"), body).unwrap();
            let err = format!("{:#}", load(d.path(), &|_| None).unwrap_err());
            assert!(err.contains(key), "{err}");
        }
    }

    #[test]
    fn malformed_file_is_an_error() {
        let d = tempdir().unwrap();
        std::fs::write(d.path().join("config.json"), "{").unwrap();
        assert!(load(d.path(), &|_| None).is_err());
    }

    #[test]
    fn bad_value_names_the_item() {
        let d = tempdir().unwrap();
        let err = load(d.path(), &env_of(&[("RAPP_RELAY_ENROLL", "maybe")])).unwrap_err();
        assert!(err.to_string().contains("RAPP_RELAY_ENROLL"), "{err}");
        std::fs::write(d.path().join("config.json"), r#"{"enroll":"maybe"}"#).unwrap();
        let err = format!("{:#}", load(d.path(), &|_| None).unwrap_err());
        assert!(err.contains("maybe"), "{err}");
    }

    #[test]
    fn metrics_must_be_loopback() {
        let d = tempdir().unwrap();
        let err = load(d.path(), &env_of(&[("RAPP_RELAY_METRICS", "0.0.0.0:9116")])).unwrap_err();
        assert!(err.to_string().contains("RAPP_RELAY_METRICS"));
        std::fs::write(d.path().join("config.json"), r#"{"metrics":"0.0.0.0:9116"}"#).unwrap();
        assert!(load(d.path(), &|_| None).is_err());
    }

    #[test]
    fn effective_config_serializes_without_secrets() {
        let v = serde_json::to_value(Config::default()).unwrap();
        let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(|s| s.as_str()).collect();
        keys.sort();
        assert_eq!(keys, ["audit", "enroll", "limits", "listen", "log", "metrics"]);
    }
}
