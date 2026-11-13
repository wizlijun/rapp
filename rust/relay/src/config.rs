//! Layered configuration: defaults <- `<data>/config.json` <- `RAPP_RELAY_*` environment.

use anyhow::{anyhow, bail, ensure, Context, Result};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
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
            listen: "0.0.0.0:22026".parse().unwrap(),
            enroll: Enroll::Open,
            log: LogLevel::Info,
            audit: AuditCfg::default(),
            metrics: None,
            limits: Limits::default(),
        }
    }
}

/// File values are kept as raw JSON and converted one by one so errors can name the item.
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileAudit {
    keep_days: Option<Value>,
    max_mb: Option<Value>,
    required: Option<Value>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileLimits {
    max_conns: Option<Value>,
    max_conns_per_ip: Option<Value>,
    max_streams: Option<Value>,
    max_relayed_per_device: Option<Value>,
    max_devices: Option<Value>,
    unenrolled_idle_secs: Option<Value>,
    enroll_per_ip_per_min: Option<Value>,
    max_line: Option<Value>,
    request_timeout_secs: Option<Value>,
    lock_after: Option<Value>,
    lock_max_secs: Option<Value>,
    connect_per_target_per_min: Option<Value>,
    relay_bps_per_stream: Option<Value>,
    relay_bps_total: Option<Value>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct FileConfig {
    listen: Option<Value>,
    enroll: Option<Value>,
    log: Option<Value>,
    audit: Option<Value>,
    metrics: Option<Value>,
    limits: Option<Value>,
}

/// Convert one raw file value to `T`; the error names the item (e.g. `limits.max_conns`).
fn conv<T: DeserializeOwned>(v: Option<Value>, item: &str) -> Result<Option<T>> {
    v.map(|v| serde_json::from_value(v).map_err(|e| anyhow!("config file: {item}: bad value: {e}"))).transpose()
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
            set(&mut c.listen, conv(f.listen, "listen")?);
            set(&mut c.enroll, conv(f.enroll, "enroll")?);
            set(&mut c.log, conv(f.log, "log")?);
            if let Some(m) = conv::<SocketAddr>(f.metrics, "metrics")? {
                check_loopback(m, "config file: metrics")?;
                c.metrics = Some(m);
            }
            if let Some(a) = conv::<FileAudit>(f.audit, "audit")? {
                set(&mut c.audit.keep_days, conv(a.keep_days, "audit.keep_days")?);
                set(&mut c.audit.max_mb, conv(a.max_mb, "audit.max_mb")?);
                set(&mut c.audit.required, conv(a.required, "audit.required")?);
            }
            if let Some(l) = conv::<FileLimits>(f.limits, "limits")? {
                macro_rules! file_limits {
                    ($($f:ident),* $(,)?) => {$(
                        set(&mut c.limits.$f, conv(l.$f, concat!("limits.", stringify!($f)))?);
                    )*};
                }
                file_limits!(
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
    check_positive(&c.limits)?;
    Ok(c)
}

/// Refuses a limit of 0 where 0 would silently refuse everything (0 means "off" only for
/// `lock_after`, `lock_max_secs` and the two `relay_bps_*`).
fn check_positive(l: &Limits) -> Result<()> {
    let items: [(&str, u64); 9] = [
        ("max_conns", l.max_conns as u64),
        ("max_conns_per_ip", l.max_conns_per_ip as u64),
        ("max_streams", l.max_streams.into()),
        ("max_relayed_per_device", l.max_relayed_per_device as u64),
        ("unenrolled_idle_secs", l.unenrolled_idle_secs),
        ("enroll_per_ip_per_min", l.enroll_per_ip_per_min.into()),
        ("max_line", l.max_line as u64),
        ("request_timeout_secs", l.request_timeout_secs),
        ("connect_per_target_per_min", l.connect_per_target_per_min.into()),
    ];
    for (name, v) in items {
        ensure!(v >= 1, "limits.{name}: must be at least 1");
    }
    Ok(())
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
        assert_eq!(c.listen.to_string(), "0.0.0.0:22026");
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
    fn zero_limits_that_would_refuse_everything_are_rejected() {
        let d = tempdir().unwrap();
        for item in [
            "max_conns",
            "max_conns_per_ip",
            "max_streams",
            "max_relayed_per_device",
            "unenrolled_idle_secs",
            "enroll_per_ip_per_min",
            "max_line",
            "request_timeout_secs",
            "connect_per_target_per_min",
        ] {
            let var = format!("RAPP_RELAY_LIMIT_{}", item.to_uppercase());
            let err = load(d.path(), &env_of(&[(var.as_str(), "0")])).unwrap_err();
            assert!(err.to_string().contains(&format!("limits.{item}")), "{item}: {err}");
        }
        // 0 is meaningful ("off") for these.
        let env = env_of(&[
            ("RAPP_RELAY_LIMIT_LOCK_AFTER", "0"),
            ("RAPP_RELAY_LIMIT_LOCK_MAX_SECS", "0"),
            ("RAPP_RELAY_LIMIT_RELAY_BPS_TOTAL", "0"),
            ("RAPP_RELAY_LIMIT_RELAY_BPS_PER_STREAM", "0"),
        ]);
        assert!(load(d.path(), &env).is_ok());
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
        for (body, item) in [
            (r#"{"enroll":"maybe"}"#, "enroll"),
            (r#"{"listen":"x"}"#, "listen"),
            (r#"{"limits":{"max_conns":"x"}}"#, "limits.max_conns"),
            (r#"{"audit":{"required":"yes"}}"#, "audit.required"),
            (r#"{"limits":5}"#, "limits"),
        ] {
            std::fs::write(d.path().join("config.json"), body).unwrap();
            let err = format!("{:#}", load(d.path(), &|_| None).unwrap_err());
            assert!(err.contains(item), "{body}: {err}");
        }
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
