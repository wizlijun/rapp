//! Clipboard side connections shared by native Linux clients. Files are streamed,
//! memory payloads are capped, and cancellation interrupts the active socket.
use crate::protocol::{self as p, Address, Reader};
use anyhow::{bail, ensure, Context, Result};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    net::{Shutdown, TcpStream, ToSocketAddrs},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
pub const MEMORY_LIMIT: u64 = 256 * 1024 * 1024;
const CHUNK: usize = 256 * 1024;
#[derive(Clone, Debug)]
pub enum Copy {
    Text(String),
    Image(Vec<u8>),
    Data(String, Vec<u8>),
    Files(Vec<PathBuf>),
}
#[derive(Clone, Default)]
pub struct Cancel(Arc<CancelState>);
#[derive(Default)]
struct CancelState {
    cancelled: AtomicBool,
    socket: Mutex<Option<TcpStream>>,
}
impl Cancel {
    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Relaxed);
        if let Some(s) = self.0.socket.lock().unwrap().as_ref() {
            let _ = s.shutdown(Shutdown::Both);
        }
    }
    pub fn check(&self) -> Result<()> {
        ensure!(!self.0.cancelled.load(Ordering::Relaxed), "已取消");
        Ok(())
    }
    fn connect(&self, a: &Address) -> Result<TcpStream> {
        self.check()?;
        for addr in (a.host.as_str(), a.port).to_socket_addrs()? {
            if let Ok(s) = TcpStream::connect_timeout(&addr, Duration::from_secs(8)) {
                s.set_read_timeout(Some(Duration::from_secs(15)))?;
                s.set_write_timeout(Some(Duration::from_secs(15)))?;
                *self.0.socket.lock().unwrap() = Some(s.try_clone()?);
                self.check()?;
                return Ok(s);
            }
        }
        bail!("无法连接传输端口")
    }
    fn disconnect(&self) {
        if let Some(s) = self.0.socket.lock().unwrap().take() {
            let _ = s.shutdown(Shutdown::Both);
        }
    }
}
impl Drop for CancelState {
    fn drop(&mut self) {
        if let Some(s) = self.socket.get_mut().unwrap().take() {
            let _ = s.shutdown(Shutdown::Both);
        }
    }
}
fn response(s: &mut TcpStream) -> Result<(u8, Vec<u8>)> {
    let mut h = [0; 5];
    s.read_exact(&mut h)?;
    let n = u32::from_le_bytes(h[1..].try_into()?) as usize;
    ensure!(
        matches!((h[0], n), (24, 8) | (25, 0..=CHUNK) | (3, 2..=65537)),
        "无效的传输响应"
    );
    let mut b = vec![0; n];
    s.read_exact(&mut b)?;
    if h[0] == 3 {
        let mut r = Reader::new(&b);
        let error = r.string()?;
        r.end()?;
        bail!("A: {error}");
    }
    Ok((h[0], b))
}
fn retry<T>(cancel: &Cancel, mut f: impl FnMut() -> Result<T>) -> Result<T> {
    for attempt in 0..4 {
        cancel.check()?;
        let result = f();
        cancel.disconnect();
        cancel.check()?;
        match result {
            Ok(v) => return Ok(v),
            Err(e) => {
                // Only retry transport errors; a refusal or malformed packet is final.
                if attempt == 3 || e.downcast_ref::<std::io::Error>().is_none() {
                    return Err(e);
                }
                for _ in 0..(10 << attempt) {
                    cancel.check()?;
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        }
    }
    unreachable!()
}
pub fn upload(
    a: &Address,
    item: u32,
    copy: &Copy,
    cancel: &Cancel,
    progress: impl Fn(u64, u64),
) -> Result<()> {
    let (kind, uti, name, bytes, path) = match copy {
        Copy::Text(t) => (0, "public.utf8-plain-text", "", Some(t.as_bytes()), None),
        Copy::Image(b) => (1, "public.png", "", Some(b.as_slice()), None),
        Copy::Data(u, b) => (3, u.as_str(), "", Some(b.as_slice()), None),
        Copy::Files(paths) => {
            ensure!(paths.len() == 1, "每个附件必须是一个文件");
            let p = &paths[0];
            (
                2,
                "public.file-url",
                p.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
                None,
                Some(p),
            )
        }
    };
    ensure!(uti.len() <= 65535 && name.len() <= 65535, "附件名称过长");
    let mut file = path.map(File::open).transpose()?;
    let total = if let Some(f) = &file {
        ensure!(f.metadata()?.is_file(), "文件夹不支持");
        f.metadata()?.len()
    } else {
        bytes.unwrap().len() as u64
    };
    ensure!(kind == 2 || total <= MEMORY_LIMIT, "这一项超过 256 MB");
    retry(cancel, || {
        let mut s = cancel.connect(a)?;
        let mut put = vec![a.version];
        p::string(&mut put, &a.token);
        put.extend(item.to_le_bytes());
        put.push(kind);
        p::string(&mut put, uti);
        p::string(&mut put, name);
        put.extend(total.to_le_bytes());
        s.write_all(&p::packet(23, put))?;
        let (kind, b) = response(&mut s)?;
        ensure!(kind == 24, "缺少上传起始响应");
        let mut sent = Reader::new(&b).u64()?;
        ensure!(sent <= total, "无效的上传偏移");
        if let Some(f) = &mut file {
            f.seek(SeekFrom::Start(sent))?;
        }
        progress(sent, total);
        let mut buffer = vec![0; CHUNK];
        while sent < total {
            cancel.check()?;
            let n = (total - sent).min(CHUNK as u64) as usize;
            let data = if let Some(f) = &mut file {
                f.read_exact(&mut buffer[..n])?;
                &buffer[..n]
            } else {
                &bytes.unwrap()[sent as usize..sent as usize + n]
            };
            s.write_all(&p::packet(25, data.to_vec()))?;
            sent += n as u64;
            progress(sent, total);
        }
        let (kind, b) = response(&mut s)?;
        ensure!(kind == 25 && b.is_empty(), "缺少上传完成确认");
        Ok(())
    })
}
pub fn safe_name(raw: &str) -> String {
    let normalized = raw.replace('\\', "/");
    let s = normalized.rsplit('/').next().unwrap_or("");
    let s: String = s.chars().filter(|c| !c.is_control() && *c != ':').collect();
    let s = s.trim_start_matches('.');
    if s.is_empty() {
        "file".into()
    } else {
        s.into()
    }
}
fn unique(root: &Path, name: &str) -> PathBuf {
    let name = safe_name(name);
    let p = Path::new(&name);
    let base = p.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = p
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| format!(".{s}"))
        .unwrap_or_default();
    for n in 1.. {
        let path = root.join(if n == 1 {
            name.clone()
        } else {
            format!("{base} ({n}){ext}")
        });
        if !path.exists() && !PathBuf::from(format!("{}.rapp-part", path.display())).exists() {
            return path;
        }
    }
    unreachable!()
}
#[derive(Clone, Default)]
pub struct Downloads(Arc<Mutex<HashMap<(u32, u16), PathBuf>>>);
impl Downloads {
    #[allow(clippy::too_many_arguments)]
    pub fn fetch(
        &self,
        a: &Address,
        id: u32,
        info: &Value,
        text: Option<String>,
        root: &Path,
        cancel: &Cancel,
        progress: impl Fn(&str, u64, u64),
    ) -> Result<Copy> {
        match info["kind"].as_str().unwrap_or("unsupported") {
            "text" => Ok(Copy::Text(text.unwrap_or_default())),
            "files" => {
                let mut paths = vec![];
                let files = info["files"].as_array().context("无效的文件列表")?;
                for (i, f) in files.iter().enumerate() {
                    let name = f["name"].as_str().unwrap_or("file");
                    let total = f["bytes"].as_u64().context("无效的文件大小")?;
                    fs::create_dir_all(root)?;
                    let path = self
                        .0
                        .lock()
                        .unwrap()
                        .entry((id, i as u16))
                        .or_insert_with(|| unique(root, name))
                        .clone();
                    // Completed files can be reused when retrying a later file in the same clip.
                    if path.is_file() && fs::metadata(&path)?.len() == total {
                        paths.push(path);
                        continue;
                    }
                    let part = PathBuf::from(format!("{}.rapp-part", path.display()));
                    let mut file = OpenOptions::new()
                        .create(true)
                        .truncate(false)
                        .read(true)
                        .write(true)
                        .open(&part)?;
                    let mut done = file.metadata()?.len();
                    if done > total {
                        file.set_len(0)?;
                        done = 0;
                    }
                    file.seek(SeekFrom::Start(done))?;
                    receive(
                        a,
                        id,
                        i as u16,
                        total,
                        &mut done,
                        cancel,
                        |b| {
                            file.write_all(b)?;
                            Ok(())
                        },
                        |d, t| progress(name, d, t),
                    )?;
                    drop(file);
                    let final_path = if path.exists() {
                        unique(root, name)
                    } else {
                        path
                    };
                    fs::rename(&part, &final_path)?;
                    self.0
                        .lock()
                        .unwrap()
                        .insert((id, i as u16), final_path.clone());
                    paths.push(final_path);
                }
                Ok(Copy::Files(paths))
            }
            kind @ ("image" | "data") => {
                let total = info["bytes"].as_u64().context("无效的数据大小")?;
                ensure!(total <= MEMORY_LIMIT, "这一项超过 256 MB");
                let mut data = vec![];
                let mut done = 0;
                receive(
                    a,
                    id,
                    0,
                    total,
                    &mut done,
                    cancel,
                    |b| {
                        data.extend_from_slice(b);
                        Ok(())
                    },
                    |d, t| progress(if kind == "image" { "图片" } else { "数据" }, d, t),
                )?;
                if kind == "image" {
                    Ok(Copy::Image(data))
                } else {
                    Ok(Copy::Data(
                        info["uti"].as_str().unwrap_or("public.data").into(),
                        data,
                    ))
                }
            }
            _ => bail!("{}", info["label"].as_str().unwrap_or("不支持这一项")),
        }
    }
}
#[allow(clippy::too_many_arguments)]
fn receive(
    a: &Address,
    id: u32,
    index: u16,
    total: u64,
    done: &mut u64,
    cancel: &Cancel,
    mut append: impl FnMut(&[u8]) -> Result<()>,
    progress: impl Fn(u64, u64),
) -> Result<()> {
    retry(cancel, || {
        let mut s = cancel.connect(a)?;
        let mut fetch = vec![a.version];
        p::string(&mut fetch, &a.token);
        fetch.extend(id.to_le_bytes());
        fetch.extend(index.to_le_bytes());
        fetch.extend(done.to_le_bytes());
        s.write_all(&p::packet(22, fetch))?;
        let (kind, b) = response(&mut s)?;
        ensure!(
            kind == 24 && Reader::new(&b).u64()? == total,
            "远端文件已改变，请重新复制"
        );
        progress(*done, total);
        while *done < total {
            cancel.check()?;
            let (kind, b) = response(&mut s)?;
            ensure!(
                kind == 25 && !b.is_empty() && b.len() as u64 <= total - *done,
                "无效的下载数据"
            );
            append(&b)?;
            *done += b.len() as u64;
            progress(*done, total);
        }
        Ok(())
    })
}
pub fn paste_item(seq: u32, item: u32) -> Vec<u8> {
    let mut b = seq.to_le_bytes().to_vec();
    b.push(1);
    b.extend(item.to_le_bytes());
    p::packet(20, b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{net::TcpListener, thread};
    fn host() -> (TcpListener, Address) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let a = Address::parse(
            &format!(
                "rapp://127.0.0.1:{}/?token=test",
                l.local_addr().unwrap().port()
            ),
            None,
        )
        .unwrap();
        (l, a)
    }
    fn packet(s: &mut TcpStream) -> (u8, Vec<u8>) {
        let mut h = [0; 5];
        s.read_exact(&mut h).unwrap();
        let mut b = vec![0; u32::from_le_bytes(h[1..].try_into().unwrap()) as usize];
        s.read_exact(&mut b).unwrap();
        (h[0], b)
    }
    #[test]
    fn upload_resumes_in_bounded_chunks_and_waits_for_ack() {
        let (l, a) = host();
        let payload = vec![42; 700_000];
        let server = thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let (k, b) = packet(&mut s);
            assert_eq!(k, 23);
            let mut r = Reader::new(&b);
            assert_eq!(r.u8().unwrap(), 6);
            assert_eq!(r.string().unwrap(), "test");
            assert_eq!(r.u32().unwrap(), 123);
            assert_eq!(r.u8().unwrap(), 3);
            assert_eq!(r.string().unwrap(), "application/x-test");
            assert_eq!(r.string().unwrap(), "");
            assert_eq!(r.u64().unwrap(), 700_000);
            r.end().unwrap();
            s.write_all(&p::packet(24, 19u64.to_le_bytes().to_vec()))
                .unwrap();
            let mut received = 19;
            while received < 700_000 {
                let (k, b) = packet(&mut s);
                assert_eq!(k, 25);
                assert!(b.len() <= CHUNK);
                assert!(b.iter().all(|b| *b == 42));
                received += b.len();
            }
            assert_eq!(received, 700_000);
            s.write_all(&p::packet(25, vec![])).unwrap();
        });
        upload(
            &a,
            123,
            &Copy::Data("application/x-test".into(), payload),
            &Cancel::default(),
            |_, _| {},
        )
        .unwrap();
        server.join().unwrap();
    }
    #[test]
    fn download_recovers_after_transport_loss_without_overwriting_files() {
        let (l, a) = host();
        let dir =
            std::env::temp_dir().join(format!("rapp-transfer-{}-{}", std::process::id(), a.port));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("test.txt"), "keep").unwrap();
        let server = thread::spawn(move || {
            for offset in [0u64, 3] {
                let (mut s, _) = l.accept().unwrap();
                let (k, b) = packet(&mut s);
                assert_eq!(k, 22);
                assert_eq!(
                    u64::from_le_bytes(b[b.len() - 8..].try_into().unwrap()),
                    offset
                );
                s.write_all(&p::packet(24, 6u64.to_le_bytes().to_vec()))
                    .unwrap();
                s.write_all(&p::packet(
                    25,
                    if offset == 0 {
                        b"abc".to_vec()
                    } else {
                        b"def".to_vec()
                    },
                ))
                .unwrap();
            }
        });
        let info = json!({"kind":"files","files":[{"name":"../../test.txt","bytes":6}]});
        let downloads = Downloads::default();
        let Copy::Files(files) = downloads
            .fetch(&a, 9, &info, None, &dir, &Cancel::default(), |_, _, _| {})
            .unwrap()
        else {
            panic!()
        };
        server.join().unwrap();
        assert_eq!(files[0].parent().unwrap(), dir);
        assert_eq!(fs::read(&files[0]).unwrap(), b"abcdef");
        assert_eq!(fs::read(dir.join("test.txt")).unwrap(), b"keep");
        // Cached data remains usable after the server has gone away.
        assert!(downloads
            .fetch(&a, 9, &info, None, &dir, &Cancel::default(), |_, _, _| {})
            .is_ok());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn cancelled_and_oversized_transfers_do_not_connect() {
        let (l, a) = host();
        drop(l);
        let c = Cancel::default();
        c.cancel();
        assert!(upload(&a, 1, &Copy::Text("a".into()), &c, |_, _| {})
            .unwrap_err()
            .to_string()
            .contains("取消"));
        let e = Downloads::default()
            .fetch(
                &a,
                1,
                &json!({"kind":"image","bytes":MEMORY_LIMIT+1}),
                None,
                Path::new("/unused"),
                &Cancel::default(),
                |_, _, _| {},
            )
            .unwrap_err();
        assert!(e.to_string().contains("256 MB"));
        assert_eq!(safe_name("../..\\..\\report.txt"), "report.txt");
        assert_eq!(safe_name(".."), "file");
    }
    #[test]
    fn malformed_download_cannot_exceed_advertised_size() {
        let (l, a) = host();
        let server = thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            packet(&mut s);
            s.write_all(&p::packet(24, 2u64.to_le_bytes().to_vec()))
                .unwrap();
            s.write_all(&p::packet(25, vec![1, 2, 3])).unwrap();
        });
        assert!(Downloads::default()
            .fetch(
                &a,
                1,
                &json!({"kind":"image","bytes":2}),
                None,
                Path::new("/unused"),
                &Cancel::default(),
                |_, _, _| {}
            )
            .is_err());
        server.join().unwrap();
    }
}
