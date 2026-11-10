//! JSON lines: one message per `\n`-terminated UTF-8 line, at most 64 KiB (spec §2.1).
//!
//! `read_line` reads byte by byte so it never consumes bytes past the newline:
//! after an `open` reply the same stream carries raw bytes.

use anyhow::{anyhow, bail, Result};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_LINE: usize = 64 * 1024;

/// `Ok(None)` on EOF before any byte.
pub async fn read_line<R: AsyncRead + Unpin>(r: &mut R) -> Result<Option<String>> {
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
        if buf.len() == MAX_LINE {
            bail!("line longer than 64 KiB");
        }
        buf.push(b[0]);
    }
}

/// Reads one line and parses it; EOF is an error.
pub async fn read_json<R: AsyncRead + Unpin>(r: &mut R) -> Result<Value> {
    let line = read_line(r).await?.ok_or_else(|| anyhow!("stream closed"))?;
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
