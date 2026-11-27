//! JSON lines: one message per `\n`-terminated UTF-8 line (spec §2.1).
//!
//! 64 KiB (`MAX_LINE`) is the default limit; callers that know a reply can be
//! much longer pass a larger limit to `read_line_max` / `read_json_max`.
//!
//! `read_line` reads byte by byte so it never consumes bytes past the newline:
//! after an `open` reply the same stream carries raw bytes.

use anyhow::{anyhow, bail, Result};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_LINE: usize = 64 * 1024;

/// Limit for the load reply with a full 720-point history (measured 75,125 bytes,
/// 99-103 bytes per point), with more than 2x headroom.
pub const HISTORY_LINE: usize = 256 * 1024;

/// A line passed the limit; the number is that limit.
#[derive(Debug)]
pub struct LineTooLong(pub usize);

impl std::fmt::Display for LineTooLong {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "line longer than {} bytes", self.0)
    }
}

impl std::error::Error for LineTooLong {}

/// `Ok(None)` on EOF before any byte.
pub async fn read_line<R: AsyncRead + Unpin>(r: &mut R) -> Result<Option<String>> {
    read_line_max(r, MAX_LINE).await
}

/// Like `read_line`, with a caller-chosen limit; too long is `LineTooLong(max)`.
pub async fn read_line_max<R: AsyncRead + Unpin>(r: &mut R, max: usize) -> Result<Option<String>> {
    let mut buf = Vec::new();
    let mut b = [0u8; 1];
    loop {
        if r.read(&mut b).await? == 0 {
            if buf.is_empty() {
                return Ok(None);
            }
            bail!("stream closed mid-line");
        }
        if b[0] == b'\n' {
            return Ok(Some(String::from_utf8(buf)?));
        }
        if buf.len() == max {
            return Err(anyhow::Error::new(LineTooLong(max)));
        }
        buf.push(b[0]);
    }
}

/// Reads one line and parses it; EOF is an error.
pub async fn read_json<R: AsyncRead + Unpin>(r: &mut R) -> Result<Value> {
    read_json_max(r, MAX_LINE).await
}

pub async fn read_json_max<R: AsyncRead + Unpin>(r: &mut R, max: usize) -> Result<Value> {
    let line = read_line_max(r, max)
        .await?
        .ok_or_else(|| anyhow!("stream closed"))?;
    Ok(serde_json::from_str(&line)?)
}

pub async fn write_json<W: AsyncWrite + Unpin, T: Serialize>(w: &mut W, v: &T) -> Result<()> {
    let mut b = serde_json::to_vec(v)?;
    b.push(b'\n');
    w.write_all(&b).await?;
    w.flush().await?;
    Ok(())
}

/// `{"ok":true, ...extra}`.
pub fn ok(extra: Value) -> Value {
    let mut v = json!({"ok": true});
    if let (Some(m), Value::Object(e)) = (v.as_object_mut(), extra) {
        m.extend(e);
    }
    v
}

pub fn err(msg: &str) -> Value {
    json!({"ok": false, "error": msg})
}

/// Turns a `{"ok":false,"error":e}` reply into `Err(e)`.
pub fn check(v: Value) -> Result<Value> {
    if v["ok"] == true {
        Ok(v)
    } else {
        bail!("{}", v["error"].as_str().unwrap_or("bad reply"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn reads_lines_without_overreading() {
        let mut r: &[u8] = b"{\"a\":1}\nRAW";
        assert_eq!(read_json(&mut r).await.unwrap(), json!({"a":1}));
        assert_eq!(r, b"RAW");
    }

    #[tokio::test]
    async fn eof_and_partial_lines() {
        let mut r: &[u8] = b"";
        assert_eq!(read_line(&mut r).await.unwrap(), None);
        let mut r: &[u8] = b"abc";
        assert!(read_line(&mut r).await.is_err());
    }

    #[tokio::test]
    async fn rejects_long_lines() {
        let long = vec![b'x'; MAX_LINE + 1];
        let mut r: &[u8] = &long;
        assert!(read_line(&mut r).await.is_err());
        let mut ok_line = vec![b'x'; MAX_LINE];
        ok_line.push(b'\n');
        let mut r: &[u8] = &ok_line;
        assert_eq!(read_line(&mut r).await.unwrap().unwrap().len(), MAX_LINE);
    }

    #[tokio::test]
    async fn read_line_max_takes_a_line_exactly_at_the_limit() {
        let mut b = vec![b'x'; 100];
        b.push(b'\n');
        assert_eq!(
            read_line_max(&mut b.as_slice(), 100)
                .await
                .unwrap()
                .unwrap()
                .len(),
            100
        );
    }

    #[tokio::test]
    async fn read_line_max_reports_line_too_long_with_its_limit() {
        let mut b = vec![b'x'; 101];
        b.push(b'\n');
        let e = read_line_max(&mut b.as_slice(), 100).await.unwrap_err();
        assert_eq!(e.downcast_ref::<LineTooLong>().map(|t| t.0), Some(100));
    }

    #[tokio::test]
    async fn read_line_still_stops_at_64k() {
        let mut b = vec![b'x'; MAX_LINE + 1];
        b.push(b'\n');
        let e = read_line(&mut b.as_slice()).await.unwrap_err();
        assert_eq!(e.downcast_ref::<LineTooLong>().map(|t| t.0), Some(MAX_LINE));
    }

    #[tokio::test]
    async fn writes_one_line() {
        let mut out = Vec::new();
        write_json(&mut out, &json!({"x":"y"})).await.unwrap();
        assert_eq!(out, b"{\"x\":\"y\"}\n");
    }

    #[test]
    fn ok_err_check() {
        assert_eq!(ok(json!({"id":"1"})), json!({"ok":true,"id":"1"}));
        assert_eq!(check(err("bad")).unwrap_err().to_string(), "bad");
        assert!(check(ok(json!({}))).is_ok());
    }
}
