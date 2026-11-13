//! JSON lines: one message per `\n`-terminated line, at most `MAX_LINE` bytes.
//!
//! `read_json` stops at the newline: bytes the `BufReader` already buffered after it stay
//! there, so the caller can keep reading the same reader or splice it.

use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_LINE: usize = 8192;

/// Reads one line (more than `max` bytes before the newline, EOF before it, or bad JSON: error).
/// Not cancel-safe: if the future is dropped (e.g. a timeout), part of a line may already be
/// consumed, so the stream must be reset, not read again.
pub async fn read_json<R: AsyncBufRead + Unpin>(r: &mut R, max: usize) -> Result<Value> {
    let mut line = Vec::new();
    loop {
        let buf = r.fill_buf().await?;
        if buf.is_empty() {
            bail!("stream closed mid-line");
        }
        let (body, used) = match buf.iter().position(|&b| b == b'\n') {
            Some(i) => (i, i + 1),
            None => (buf.len(), buf.len()),
        };
        if line.len() + body > max {
            bail!("line longer than {max} bytes");
        }
        line.extend_from_slice(&buf[..body]);
        let done = used > body;
        r.consume(used);
        if done {
            return serde_json::from_slice(&line).context("bad json line");
        }
    }
}

pub async fn write_json<W: AsyncWrite + Unpin, T: Serialize>(w: &mut W, v: &T) -> Result<()> {
    let mut b = serde_json::to_vec(v)?;
    b.push(b'\n');
    w.write_all(&b).await?;
    w.flush().await?;
    Ok(())
}

/// `{"ok":true, ...extra}` (`extra` is an object; anything else adds nothing; `ok` always wins).
pub fn ok(extra: Value) -> Value {
    let mut m = match extra {
        Value::Object(e) => e,
        _ => serde_json::Map::new(),
    };
    m.insert("ok".into(), Value::Bool(true));
    Value::Object(m)
}

pub fn err(msg: &str) -> Value {
    json!({"ok": false, "error": msg})
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, BufReader};

    #[tokio::test]
    async fn line_longer_than_8k_is_an_error() {
        let (mut w, r) = tokio::io::duplex(64 * 1024);
        w.write_all(&vec![b' '; MAX_LINE + 1]).await.unwrap();
        let mut r = BufReader::new(r);
        assert!(read_json(&mut r, MAX_LINE).await.is_err());
    }

    #[tokio::test]
    async fn line_of_exactly_max_bytes_is_fine() {
        let (mut w, r) = tokio::io::duplex(64 * 1024);
        let mut line = b"{\"a\":1}".to_vec();
        line.resize(MAX_LINE, b' ');
        line.push(b'\n');
        w.write_all(&line).await.unwrap();
        let mut r = BufReader::with_capacity(100, r);
        assert_eq!(read_json(&mut r, MAX_LINE).await.unwrap(), json!({"a":1}));
    }

    #[tokio::test]
    async fn truncated_line_is_an_error() {
        let (mut w, r) = tokio::io::duplex(1024);
        w.write_all(b"{\"a\":1").await.unwrap();
        drop(w);
        let mut r = BufReader::new(r);
        assert!(read_json(&mut r, MAX_LINE).await.is_err());
    }

    #[tokio::test]
    async fn not_json_is_an_error() {
        let (mut w, r) = tokio::io::duplex(1024);
        w.write_all(b"hello\n").await.unwrap();
        let mut r = BufReader::new(r);
        assert!(read_json(&mut r, MAX_LINE).await.is_err());
    }

    #[tokio::test]
    async fn bytes_after_the_line_stay_in_the_reader() {
        let (mut w, r) = tokio::io::duplex(1024);
        w.write_all(b"{\"a\":1}\n\x16\x03\x01tail").await.unwrap();
        drop(w);
        let mut r = BufReader::new(r);
        assert_eq!(read_json(&mut r, MAX_LINE).await.unwrap(), json!({"a":1}));
        let mut rest = Vec::new();
        r.read_to_end(&mut rest).await.unwrap();
        assert_eq!(rest, b"\x16\x03\x01tail");
    }

    #[tokio::test]
    async fn write_then_read_roundtrip_and_helpers() {
        let (mut w, r) = tokio::io::duplex(1024);
        write_json(&mut w, &ok(json!({"id":"123456789"}))).await.unwrap();
        write_json(&mut w, &err("offline")).await.unwrap();
        let mut r = BufReader::new(r);
        assert_eq!(read_json(&mut r, MAX_LINE).await.unwrap(), json!({"ok":true,"id":"123456789"}));
        assert_eq!(read_json(&mut r, MAX_LINE).await.unwrap(), json!({"ok":false,"error":"offline"}));
        assert_eq!(ok(json!({})), json!({"ok":true}));
        assert_eq!(ok(json!({"ok":false})), json!({"ok":true}));
    }
}
