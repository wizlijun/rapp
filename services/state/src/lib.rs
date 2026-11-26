//! rapp-state: a headless state-queue service. Listens on 127.0.0.1 only.

mod http;

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use tokio::net::TcpListener;

pub use http::serve;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub port: u16,
    /// `None` keeps everything in memory.
    pub data: Option<PathBuf>,
    pub keep_days: u64,
    pub keep_events: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config { port: 8102, data: None, keep_days: 7, keep_events: 1000 }
    }
}

pub fn parse_args(args: &[String]) -> Result<Config, String> {
    let mut cfg = Config::default();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--port" => {
                let v = it.next().ok_or("--port 后面要写端口")?;
                cfg.port = v.parse().map_err(|_| "--port 后面要写端口".to_string())?;
            }
            "--data" => {
                let v = it.next().ok_or("--data 后面要写目录")?;
                cfg.data = Some(PathBuf::from(v));
            }
            "--keep-days" => {
                let v = it.next().ok_or("--keep-days 要写正整数")?;
                cfg.keep_days = v.parse().ok().filter(|n| *n >= 1).ok_or("--keep-days 要写正整数")?;
            }
            "--keep-events" => {
                let v = it.next().ok_or("--keep-events 要写正整数")?;
                cfg.keep_events = v.parse().ok().filter(|n| *n >= 1).ok_or("--keep-events 要写正整数")?;
            }
            other => return Err(format!("不认识的参数：{other}")),
        }
    }
    Ok(cfg)
}

/// One JSON line on stderr: `{"at":<unix>,"event":"<name>",…}`. `fields` must be an object (or null).
pub fn log(event: &str, fields: Value) {
    let at = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let mut line = json!({"at": at, "event": event});
    if let (Some(l), Value::Object(f)) = (line.as_object_mut(), fields) {
        l.extend(f);
    }
    eprintln!("{line}");
}

pub async fn run(cfg: Config) -> anyhow::Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", cfg.port)).await?;
    log("listening", json!({"port": cfg.port}));
    serve(cfg, listener).await
}

/// Returns the process exit code: 2 for bad arguments, 1 when the service cannot start or stops.
pub async fn cli(args: Vec<String>) -> i32 {
    let cfg = match parse_args(&args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };
    let port = cfg.port;
    match run(cfg).await {
        Ok(()) => 0,
        Err(e) => {
            if let Some(io) = e.downcast_ref::<std::io::Error>() {
                eprintln!("{}", json!({"event": "bind_failed", "port": port, "error": format!("{:?}", io.kind())}));
            }
            eprintln!("rapp-state 起不来：{e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn args() {
        let a = |s: &str| parse_args(&s.split_whitespace().map(String::from).collect::<Vec<_>>());
        assert_eq!(a("").unwrap(), Config::default());
        assert_eq!(a("").unwrap().port, 8102);
        let c = a("--port 9000 --data /tmp/x --keep-days 3 --keep-events 10").unwrap();
        assert_eq!((c.port, c.data.as_deref(), c.keep_days, c.keep_events), (9000, Some(Path::new("/tmp/x")), 3, 10));
        assert_eq!(a("--port").unwrap_err(), "--port 后面要写端口");
        assert_eq!(a("--keep-days 0").unwrap_err(), "--keep-days 要写正整数");
        assert_eq!(a("--frob").unwrap_err(), "不认识的参数：--frob");
    }

    #[tokio::test]
    async fn bind_failure_exits_1() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        assert_eq!(cli(vec!["--port".into(), port.to_string()]).await, 1);
        assert_eq!(cli(vec!["--frob".into()]).await, 2);
    }
}
