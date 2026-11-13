//! Prepare an acknowledged text paste. Call off the UI thread: long text uses
//! a separate TCP connection, never the image stream or the input writer.
use crate::protocol::{self as p, Address, Reader};
use anyhow::{ensure, Context, Result};
use std::{
    io::{Read, Write},
    net::{TcpStream, ToSocketAddrs},
    time::{Duration, Instant},
};

pub fn prepare_paste(address: &Address, seq: u32, text: &str) -> Result<Vec<u8>> {
    ensure!(text.len() <= 1024 * 1024, "文字超过 1 MB");
    let mut paste = seq.to_le_bytes().to_vec();
    if text.len() < 60_000 {
        paste.push(0);
        p::string(&mut paste, text);
    } else {
        upload(address, seq, text.as_bytes())?;
        paste.push(1);
        paste.extend(seq.to_le_bytes());
    }
    Ok(p::packet(20, paste))
}

fn upload(address: &Address, item: u32, bytes: &[u8]) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut socket = None;
    for addr in (address.host.as_str(), address.port).to_socket_addrs()? {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        if let Ok(s) = TcpStream::connect_timeout(&addr, left) {
            socket = Some(s);
            break;
        }
    }
    let mut socket = socket.context("无法连接上传端口")?;
    socket.set_read_timeout(Some(Duration::from_secs(15)))?;
    socket.set_write_timeout(Some(Duration::from_secs(15)))?;
    let mut put = vec![address.version];
    p::string(&mut put, &address.token);
    put.extend(item.to_le_bytes());
    put.push(0);
    p::string(&mut put, "public.utf8-plain-text");
    p::string(&mut put, "");
    put.extend((bytes.len() as u64).to_le_bytes());
    socket.write_all(&p::packet(23, put))?;
    let (kind, body) = response(&mut socket)?;
    ensure!(kind == 24, "缺少上传起始响应");
    let offset = Reader::new(&body).u64()?;
    ensure!(offset <= bytes.len() as u64, "无效的上传偏移");
    for chunk in bytes[offset as usize..].chunks(256 * 1024) {
        socket.write_all(&p::packet(25, chunk.to_vec()))?;
    }
    let (kind, _) = response(&mut socket)?;
    ensure!(kind == 25, "缺少上传完成确认");
    Ok(())
}

fn response(socket: &mut TcpStream) -> Result<(u8, Vec<u8>)> {
    let mut h = [0; 5];
    socket.read_exact(&mut h)?;
    let n = u32::from_le_bytes(h[1..].try_into()?) as usize;
    ensure!(
        matches!((h[0], n), (24, 8) | (25, 0) | (3, 2..=65537)),
        "无效的上传响应"
    );
    let mut body = vec![0; n];
    socket.read_exact(&mut body)?;
    if h[0] == 3 {
        let mut reader = Reader::new(&body);
        let reason = reader.string()?;
        reader.end()?;
        anyhow::bail!("{reason}");
    }
    Ok((h[0], body))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    #[test]
    fn text_paste_is_inline_until_wire_limit_then_waits_for_upload_ack() {
        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = Address::parse(
            &format!(
                "rapp://127.0.0.1:{}/?token=test",
                server.local_addr().unwrap().port()
            ),
            None,
        )
        .unwrap();
        let short = prepare_paste(&address, 7, "中文").unwrap();
        assert_eq!(
            short,
            p::packet(
                20,
                [
                    7u32.to_le_bytes().to_vec(),
                    vec![0, 6, 0],
                    "中文".as_bytes().to_vec()
                ]
                .concat()
            )
        );
        let data = "汉".repeat(100_000);
        let expected = data.as_bytes().to_vec();
        let host = std::thread::spawn(move || {
            let (mut s, _) = server.accept().unwrap();
            s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            fn packet(s: &mut TcpStream) -> (u8, Vec<u8>) {
                let mut h = [0; 5];
                s.read_exact(&mut h).unwrap();
                let mut b = vec![0; u32::from_le_bytes(h[1..].try_into().unwrap()) as usize];
                s.read_exact(&mut b).unwrap();
                (h[0], b)
            }
            let (kind, put) = packet(&mut s);
            assert_eq!(kind, 23);
            let mut r = Reader::new(&put);
            assert_eq!(r.u8().unwrap(), 7);
            assert_eq!(r.string().unwrap(), "test");
            assert_eq!(r.u32().unwrap(), 8);
            assert_eq!(r.u8().unwrap(), 0);
            assert_eq!(r.string().unwrap(), "public.utf8-plain-text");
            assert_eq!(r.string().unwrap(), "");
            assert_eq!(r.u64().unwrap(), expected.len() as u64);
            r.end().unwrap();
            s.write_all(&p::packet(24, 13u64.to_le_bytes().to_vec()))
                .unwrap();
            let mut received = vec![];
            while received.len() < expected.len() - 13 {
                let (kind, b) = packet(&mut s);
                assert_eq!(kind, 25);
                assert!(b.len() <= 256 * 1024);
                received.extend(b);
            }
            assert_eq!(received, expected[13..]);
            s.write_all(&p::packet(25, vec![])).unwrap();
        });
        assert_eq!(
            prepare_paste(&address, 8, &data).unwrap(),
            p::packet(
                20,
                [
                    8u32.to_le_bytes().to_vec(),
                    vec![1],
                    8u32.to_le_bytes().to_vec()
                ]
                .concat()
            )
        );
        host.join().unwrap();
    }
}
