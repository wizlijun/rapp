//! Session-scoped side connections. No peer-supplied path is ever opened.
use anyhow::{bail, ensure, Context, Result};
use rapp_client_core::{
    protocol::{packet, string, Reader, VERSION},
    transfer::{safe_name, Copy},
};
use std::{
    collections::{HashMap, VecDeque},
    fs::{self, File, Metadata},
    io::{Read, Seek, SeekFrom, Write},
    net::{Shutdown, TcpStream},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

pub const CHUNK: usize = 256 * 1024;
const MEMORY: u64 = 256 * 1024 * 1024;
#[derive(Clone, Debug, PartialEq)]
struct UploadSpec {
    kind: u8,
    uti: String,
    name: String,
    total: u64,
}
struct Upload {
    spec: UploadSpec,
    part: tempfile::NamedTempFile,
    have: u64,
    complete: Option<Copy>,
}
struct Clip {
    id: u32,
    data: Copy,
    files: Vec<Metadata>,
}
struct Store {
    uploads: HashMap<u32, Arc<Mutex<Upload>>>,
    clips: VecDeque<Clip>,
    next: u32,
}
pub struct Transfers {
    store: Mutex<Store>,
    sockets: Mutex<HashMap<u64, TcpStream>>,
    cancelled: AtomicBool,
    directory: PathBuf,
}
impl Transfers {
    pub fn new(directory: PathBuf) -> Self {
        Self {
            store: Mutex::new(Store {
                uploads: HashMap::new(),
                clips: VecDeque::new(),
                next: 1,
            }),
            sockets: Mutex::new(HashMap::new()),
            cancelled: AtomicBool::new(false),
            directory,
        }
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        for socket in self.sockets.lock().unwrap().values() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
    fn check(&self) -> Result<()> {
        ensure!(!self.cancelled.load(Ordering::SeqCst), "session ended");
        Ok(())
    }
    pub fn received(&self, id: u32) -> Result<Copy> {
        self.check()?;
        let upload = self
            .store
            .lock()
            .unwrap()
            .uploads
            .get(&id)
            .cloned()
            .context("not uploaded")?;
        let upload = upload
            .try_lock()
            .map_err(|_| anyhow::anyhow!("not uploaded"))?;
        upload.complete.clone().context("not uploaded")
    }
    pub fn remember(&self, data: Copy) -> Result<Vec<u8>> {
        self.check()?;
        let mut files = vec![];
        if let Copy::Files(paths) = &data {
            ensure!(paths.len() <= 100, "too many clipboard files");
            for path in paths {
                let meta = fs::metadata(path)?;
                ensure!(meta.is_file(), "folders are not supported");
                files.push(meta);
            }
        }
        let mut store = self.store.lock().unwrap();
        let id = store.next;
        store.next = store
            .next
            .checked_add(1)
            .context("clipboard history exhausted")?;
        let mut p = id.to_le_bytes().to_vec();
        match &data {
            Copy::Text(text) => {
                let mut n = text.len().min(1024 * 1024);
                while !text.is_char_boundary(n) {
                    n -= 1;
                }
                p.extend([0, (n < text.len()) as u8]);
                p.extend((n as u32).to_le_bytes());
                p.extend(&text.as_bytes()[..n]);
            }
            Copy::Image(bytes) => {
                ensure!(bytes.len() <= 64 * 1024 * 1024, "clipboard image too large");
                ensure!(
                    bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes.len() >= 24,
                    "invalid PNG"
                );
                let w = u32::from_be_bytes(bytes[16..20].try_into()?);
                let h = u32::from_be_bytes(bytes[20..24].try_into()?);
                ensure!(
                    w > 0 && h > 0 && w <= 65535 && h <= 65535,
                    "invalid PNG dimensions"
                );
                p.push(1);
                p.extend((w as u16).to_le_bytes());
                p.extend((h as u16).to_le_bytes());
                p.extend((bytes.len() as u64).to_le_bytes());
            }
            Copy::Files(paths) => {
                p.push(2);
                p.extend((paths.len() as u16).to_le_bytes());
                for (path, meta) in paths.iter().zip(&files) {
                    string(
                        &mut p,
                        &path
                            .file_name()
                            .context("invalid file name")?
                            .to_string_lossy()
                            .chars()
                            .take(1024)
                            .collect::<String>(),
                    );
                    p.extend(meta.len().to_le_bytes());
                }
            }
            Copy::Data(uti, bytes) => {
                ensure!(
                    bytes.len() <= 64 * 1024 * 1024 && uti.len() <= 1024,
                    "clipboard data too large"
                );
                p.push(3);
                string(&mut p, uti);
                p.extend((bytes.len() as u64).to_le_bytes());
            }
        }
        store.clips.push_back(Clip { id, data, files });
        let size = |data: &Copy| -> usize {
            match data {
                Copy::Text(t) => t.len(),
                Copy::Image(b) | Copy::Data(_, b) => b.len(),
                Copy::Files(_) => 0,
            }
        };
        while store.clips.len() > 50
            || store
                .clips
                .iter()
                .map(|clip| size(&clip.data))
                .sum::<usize>()
                > 128 * 1024 * 1024
        {
            store.clips.pop_front();
        }
        Ok(packet(19, p))
    }
    pub fn side(
        self: &Arc<Self>,
        socket: &mut TcpStream,
        kind: u8,
        payload: &[u8],
        token: &str,
    ) -> Result<()> {
        let mut r = Reader::new(payload);
        ensure!(r.u8()? == VERSION, "protocol version mismatch");
        let supplied = r.string()?;
        ensure!(crate::wire::token_matches(&supplied, token), "bad token");
        self.check()?;
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        {
            let mut sockets = self.sockets.lock().unwrap();
            self.check()?;
            ensure!(sockets.len() < 4, "busy");
            sockets.insert(id, socket.try_clone()?);
        }
        let result = match kind {
            22 => self.fetch(socket, &mut r),
            23 => self.put(socket, &mut r),
            _ => bail!("invalid side connection"),
        };
        self.sockets.lock().unwrap().remove(&id);
        result
    }
    fn put(&self, socket: &mut TcpStream, r: &mut Reader<'_>) -> Result<()> {
        let id = r.u32()?;
        let spec = UploadSpec {
            kind: r.u8()?,
            uti: r.string()?,
            name: r.string()?,
            total: r.u64()?,
        };
        r.end()?;
        ensure!(
            spec.kind <= 3 && (spec.kind == 2 || spec.total <= MEMORY),
            "too large"
        );
        let upload = {
            let mut store = self.store.lock().unwrap();
            if let Some(old) = store.uploads.get(&id) {
                ensure!(
                    old.try_lock().map_err(|_| anyhow::anyhow!("busy"))?.spec == spec,
                    "upload metadata changed"
                );
                old.clone()
            } else {
                ensure!(store.uploads.len() < 1024, "too many uploads");
                if spec.kind != 2 {
                    let mut reserved = 0u64;
                    for old in store.uploads.values() {
                        let old = old.try_lock().map_err(|_| anyhow::anyhow!("busy"))?;
                        if old.spec.kind != 2 {
                            reserved += old.spec.total;
                        }
                    }
                    ensure!(
                        reserved + spec.total <= MEMORY,
                        "session upload memory limit reached"
                    );
                }
                fs::create_dir_all(&self.directory)?;
                let part = tempfile::Builder::new()
                    .prefix(".rapp-part-")
                    .tempfile_in(&self.directory)?;
                let upload = Arc::new(Mutex::new(Upload {
                    spec,
                    part,
                    have: 0,
                    complete: None,
                }));
                store.uploads.insert(id, upload.clone());
                upload
            }
        };
        let mut upload = upload.try_lock().map_err(|_| anyhow::anyhow!("busy"))?;
        socket.write_all(&packet(24, upload.have.to_le_bytes().to_vec()))?;
        while upload.have < upload.spec.total {
            self.check()?;
            let (kind, data) = read_packet(socket, CHUNK)?;
            ensure!(
                kind == 25
                    && !data.is_empty()
                    && data.len() as u64 <= upload.spec.total - upload.have,
                "invalid upload chunk"
            );
            let position = upload.have;
            upload.part.seek(SeekFrom::Start(position))?;
            upload.part.write_all(&data)?;
            upload.have += data.len() as u64;
        }
        self.check()?;
        if upload.complete.is_none() {
            upload.part.flush()?;
            let copy = if upload.spec.kind == 2 {
                let name = safe_name(&upload.spec.name);
                // hard_link is atomic and never overwrites a local file or follows a symlink.
                let mut n = 0;
                let path = loop {
                    let path = self.directory.join(if n == 0 {
                        name.clone()
                    } else {
                        format!("{n}-{name}")
                    });
                    match fs::hard_link(upload.part.path(), &path) {
                        Ok(()) => break path,
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                            n += 1;
                            ensure!(n < 10000, "too many duplicate names");
                        }
                        Err(e) => return Err(e.into()),
                    }
                };
                Copy::Files(vec![path])
            } else {
                upload.part.rewind()?;
                let mut bytes = vec![];
                upload.part.read_to_end(&mut bytes)?;
                match upload.spec.kind {
                    0 => Copy::Text(String::from_utf8(bytes)?),
                    1 => Copy::Image(bytes),
                    _ => Copy::Data(upload.spec.uti.clone(), bytes),
                }
            };
            upload.complete = Some(copy);
            crate::server::emit(
                serde_json::json!({"event":"transfer","dir":"bToA","kind":upload.spec.kind,"bytes":upload.have,"name":if upload.spec.kind == 2 { Some(safe_name(&upload.spec.name)) } else { None }}),
            );
        }
        // Publish the completed item before B can observe the acknowledgement
        // and immediately paste it on the main connection.
        drop(upload);
        socket.write_all(&packet(25, vec![]))?;
        Ok(())
    }
    fn fetch(&self, socket: &mut TcpStream, r: &mut Reader<'_>) -> Result<()> {
        let (id, index, offset) = (r.u32()?, r.u16()? as usize, r.u64()?);
        r.end()?;
        let (mut source, total): (Box<dyn Read>, u64) = {
            let store = self.store.lock().unwrap();
            let clip = store
                .clips
                .iter()
                .find(|c| c.id == id)
                .context("unknown clip")?;
            match &clip.data {
                Copy::Image(bytes) | Copy::Data(_, bytes) => {
                    ensure!(
                        index == 0 && offset <= bytes.len() as u64,
                        "invalid fetch offset"
                    );
                    (
                        Box::new(std::io::Cursor::new(bytes[offset as usize..].to_vec())),
                        bytes.len() as u64,
                    )
                }
                Copy::Files(paths) => {
                    let path = paths.get(index).context("unknown clip file")?;
                    let mut file = File::open(path)?;
                    let meta = file.metadata()?;
                    let original = &clip.files[index];
                    use std::os::unix::fs::MetadataExt;
                    ensure!(
                        meta.is_file()
                            && meta.len() == original.len()
                            && meta.dev() == original.dev()
                            && meta.ino() == original.ino()
                            && meta.mtime() == original.mtime()
                            && meta.mtime_nsec() == original.mtime_nsec(),
                        "file changed"
                    );
                    ensure!(offset <= meta.len(), "invalid fetch offset");
                    file.seek(SeekFrom::Start(offset))?;
                    (Box::new(file), meta.len())
                }
                _ => bail!("unknown clip"),
            }
        };
        socket.write_all(&packet(24, total.to_le_bytes().to_vec()))?;
        let mut remaining = total - offset;
        let mut bytes = vec![0; CHUNK];
        while remaining > 0 {
            self.check()?;
            let n = remaining.min(CHUNK as u64) as usize;
            source.read_exact(&mut bytes[..n]).context("file changed")?;
            socket.write_all(&packet(25, bytes[..n].to_vec()))?;
            remaining -= n as u64;
        }
        Ok(())
    }
}
pub fn read_packet(socket: &mut TcpStream, max: usize) -> Result<(u8, Vec<u8>)> {
    let mut h = [0; 5];
    socket.read_exact(&mut h)?;
    let n = u32::from_le_bytes(h[1..].try_into()?) as usize;
    ensure!(n <= max, "message too large");
    let mut bytes = vec![0; n];
    socket.read_exact(&mut bytes)?;
    Ok((h[0], bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rapp_client_core::{
        protocol::{read_message, Address, Incoming},
        transfer::{self, Cancel, Downloads},
    };
    use std::{net::TcpListener, time::Duration};
    fn server(store: Arc<Transfers>, connections: usize) -> (Address, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = Address {
            host: "127.0.0.1".into(),
            port: listener.local_addr().unwrap().port(),
            token: "test-token".into(),
            app: "".into(),
            mode: 2,
            fps: 15,
        };
        let thread = std::thread::spawn(move || {
            for _ in 0..connections {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                socket
                    .set_write_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let (kind, payload) = read_packet(&mut socket, 131100).unwrap();
                if let Err(e) = store.side(&mut socket, kind, &payload, "test-token") {
                    let _ = socket.write_all(&crate::wire::text_packet(3, &e.to_string()));
                }
            }
        });
        (address, thread)
    }
    #[test]
    fn real_client_uploads_text_files_data_and_fetches_history() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Transfers::new(root.path().join("received")));
        let data = Copy::Data("application/test".into(), vec![123; CHUNK + 57]);
        let clip = store.remember(data.clone()).unwrap();
        let (Incoming::Clipboard { id, info, .. }, _) = read_message(&mut &clip[..]).unwrap()
        else {
            panic!()
        };
        let (address, thread) = server(store.clone(), 4);
        transfer::upload(
            &address,
            1,
            &Copy::Text("中文\ntext".into()),
            &Cancel::default(),
            |_, _| {},
        )
        .unwrap();
        assert!(matches!(store.received(1).unwrap(), Copy::Text(s) if s == "中文\ntext"));
        transfer::upload(&address, 2, &data, &Cancel::default(), |_, _| {}).unwrap();
        let source = root.path().join("example.txt");
        fs::write(&source, b"test file").unwrap();
        transfer::upload(
            &address,
            3,
            &Copy::Files(vec![source]),
            &Cancel::default(),
            |_, _| {},
        )
        .unwrap();
        let Copy::Files(paths) = store.received(3).unwrap() else {
            panic!()
        };
        assert_eq!(fs::read(&paths[0]).unwrap(), b"test file");
        let result = Downloads::default()
            .fetch(
                &address,
                id,
                &info,
                None,
                &root.path().join("downloads"),
                &Cancel::default(),
                |_, _, _| {},
            )
            .unwrap();
        assert!(
            matches!(result, Copy::Data(u, b) if u == "application/test" && b == vec![123; CHUNK + 57])
        );
        thread.join().unwrap();
    }
    #[test]
    fn partial_upload_resumes_and_metadata_cannot_be_rebound() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Transfers::new(root.path().into()));
        let (address, thread) = server(store.clone(), 3);
        let mut request = vec![VERSION];
        string(&mut request, &address.token);
        request.extend(7u32.to_le_bytes());
        request.push(0);
        string(&mut request, "public.utf8-plain-text");
        string(&mut request, "");
        request.extend(6u64.to_le_bytes());
        let mut first = TcpStream::connect((&*address.host, address.port)).unwrap();
        first.write_all(&packet(23, request.clone())).unwrap();
        assert_eq!(read_packet(&mut first, 100).unwrap().1, 0u64.to_le_bytes());
        first.write_all(&packet(25, b"abc".to_vec())).unwrap();
        first.shutdown(Shutdown::Both).unwrap();
        let mut changed = TcpStream::connect((&*address.host, address.port)).unwrap();
        let mut mismatch = request.clone();
        let n = mismatch.len();
        mismatch[n - 8..].copy_from_slice(&7u64.to_le_bytes());
        changed.write_all(&packet(23, mismatch)).unwrap();
        assert_eq!(read_packet(&mut changed, 100).unwrap().0, 3);
        let mut resumed = TcpStream::connect((&*address.host, address.port)).unwrap();
        resumed.write_all(&packet(23, request)).unwrap();
        assert_eq!(
            read_packet(&mut resumed, 100).unwrap().1,
            3u64.to_le_bytes()
        );
        resumed.write_all(&packet(25, b"def".to_vec())).unwrap();
        assert_eq!(read_packet(&mut resumed, 100).unwrap(), (25, vec![]));
        assert!(matches!(store.received(7).unwrap(), Copy::Text(s) if s == "abcdef"));
        thread.join().unwrap();
        store.cancel();
        assert!(store.received(7).is_err());
    }
    #[test]
    fn download_rejects_changed_files_and_cancelled_sessions() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("source");
        fs::write(&path, b"original").unwrap();
        let store = Arc::new(Transfers::new(root.path().join("uploads")));
        store.remember(Copy::Files(vec![path.clone()])).unwrap();
        fs::write(path, b"changed size").unwrap();
        let (address, thread) = server(store.clone(), 1);
        let mut payload = vec![VERSION];
        string(&mut payload, &address.token);
        payload.extend(1u32.to_le_bytes());
        payload.extend(0u16.to_le_bytes());
        payload.extend(0u64.to_le_bytes());
        let mut socket = TcpStream::connect((&*address.host, address.port)).unwrap();
        socket.write_all(&packet(22, payload)).unwrap();
        let (kind, bytes) = read_packet(&mut socket, 100).unwrap();
        assert_eq!(kind, 3);
        assert!(Reader::new(&bytes)
            .string()
            .unwrap()
            .contains("file changed"));
        thread.join().unwrap();
    }
}
