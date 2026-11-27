//! The clip history and the side-connection transfers, ported from
//! `Sources/RappCore/Transfers.swift` with `std::fs` in place of `FileManager`/`FileHandle`.
//!
//! One difference from Swift, by design (spec §6.7): an uploaded file's name goes through
//! Swift's `safeFileName` first and then `filename::portable_file_name`, so a name Windows
//! cannot create never reaches the file system.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use crate::cli::{TransferDirection, WorkerEvent};
use crate::clipboard::{safe_file_name, CHUNK_SIZE, MAX_SIDE_CONNECTIONS};
use crate::filename::{portable_file_name, unique_name};
use crate::protocol::{ClipInfo, ClipKind};

/// Suffix of an upload that has not finished yet.
pub const PART_SUFFIX: &str = ".rapp-part";
/// `TransferStore`'s default limit for an upload kept in memory (Swift: `256 << 20`).
pub const TRANSFER_MEMORY_LIMIT: usize = 256 << 20;

/// One file of a files clip, as it was when copied (`FileRef`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRef {
    pub path: PathBuf,
    pub size: u64,
    pub modified: SystemTime,
}

/// What a stored clip can hand out (`ClipPayload`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClipPayload {
    Inline,
    Bytes(Vec<u8>),
    Files(Vec<FileRef>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredClip {
    pub id: u32,
    pub info: ClipInfo,
    pub payload: ClipPayload,
}

/// A's per-session clipboard history: numbered from 1, newest 50 kept (`ClipStore`).
#[derive(Debug, Clone)]
pub struct ClipStore {
    last_change: i64,
    was_frontmost: bool,
    next_id: u32,
    clips: Vec<StoredClip>,
}

impl ClipStore {
    pub const CAPACITY: usize = 50;

    pub fn new(change_count: i64) -> Self {
        Self { last_change: change_count, was_frontmost: false, next_id: 1, clips: Vec::new() }
    }

    /// True when this change should be recorded. Always remembers `change_count` as seen.
    pub fn changed(&mut self, change_count: i64, target_frontmost: bool) -> bool {
        let is_new = change_count != self.last_change;
        self.last_change = change_count;
        // Frontmost at the previous tick too: a copy made elsewhere just before we came to
        // front is not ours.
        let stayed = self.was_frontmost && target_frontmost;
        self.was_frontmost = target_frontmost;
        is_new && stayed
    }

    pub fn note_own_write(&mut self, change_count: i64) {
        self.last_change = change_count;
    }

    /// Records a clip. The same text again (B echoing it back) returns the last entry.
    pub fn add(&mut self, info: ClipInfo, payload: ClipPayload) -> StoredClip {
        if matches!(info, ClipInfo::Text { .. }) {
            if let Some(last) = self.clips.last() {
                if last.info == info {
                    return last.clone();
                }
            }
        }
        let clip = StoredClip { id: self.next_id, info, payload };
        // Swift traps on overflow here; after 4 billion clips in one session wrapping is kinder.
        self.next_id = self.next_id.wrapping_add(1);
        self.clips.push(clip.clone());
        if self.clips.len() > Self::CAPACITY {
            let extra = self.clips.len() - Self::CAPACITY;
            self.clips.drain(..extra);
        }
        clip
    }

    pub fn clip(&self, id: u32) -> Option<&StoredClip> {
        self.clips.iter().find(|c| c.id == id)
    }
}

/// Why a fetch or put failed; `0` is the text sent to B (`TransferError`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferError(pub String);

impl TransferError {
    pub fn new(reason: &str) -> Self {
        TransferError(reason.to_string())
    }
}

impl std::fmt::Display for TransferError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for TransferError {}

enum FetchBody {
    Bytes(Vec<u8>),
    File(File),
}

/// Reads one clip file (or in-memory item) in chunks of at most `CHUNK_SIZE` (`FetchSource`).
pub struct FetchSource {
    pub total: u64,
    /// What to report once the last chunk has gone out.
    pub transfer: WorkerEvent,
    body: FetchBody,
    position: u64,
}

impl FetchSource {
    pub fn from_bytes(bytes: Vec<u8>, offset: u64, kind: ClipKind) -> Self {
        let total = bytes.len() as u64;
        FetchSource {
            total,
            transfer: WorkerEvent::Transfer { dir: TransferDirection::AToB, kind, bytes: total, name: None },
            body: FetchBody::Bytes(bytes),
            position: offset,
        }
    }

    /// Swift's `init(handle:total:offset:name:)`; a failed seek is an I/O error, which the
    /// side connection reports as `file changed`.
    pub fn from_file(mut file: File, total: u64, offset: u64, name: String) -> Result<Self, TransferError> {
        file.seek(SeekFrom::Start(offset)).map_err(|_| TransferError::new("file changed"))?;
        Ok(FetchSource {
            total,
            transfer: WorkerEvent::Transfer {
                dir: TransferDirection::AToB,
                kind: ClipKind::Files,
                bytes: total,
                name: Some(name),
            },
            body: FetchBody::File(file),
            position: offset,
        })
    }

    /// Next chunk, or `None` at the end. A file that ends early, or any read error, is
    /// `file changed` (Swift throws that, or an I/O error that `SideConnection` turns into it).
    pub fn next(&mut self) -> Result<Option<Vec<u8>>, TransferError> {
        if self.position >= self.total {
            return Ok(None);
        }
        let n = (CHUNK_SIZE as u64).min(self.total - self.position) as usize;
        let chunk = match &mut self.body {
            FetchBody::Bytes(bytes) => {
                let start = self.position as usize;
                bytes[start..start + n].to_vec()
            }
            FetchBody::File(file) => {
                let mut buf = Vec::with_capacity(n);
                Read::by_ref(file)
                    .take(n as u64)
                    .read_to_end(&mut buf)
                    .map_err(|_| TransferError::new("file changed"))?;
                if buf.is_empty() {
                    return Err(TransferError::new("file changed"));
                }
                buf
            }
        };
        self.position += chunk.len() as u64;
        Ok(Some(chunk))
    }
}

/// One finished upload (`ReceivedItem`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReceivedItem {
    Text(String),
    Image(Vec<u8>),
    Data { uti: String, bytes: Vec<u8> },
    File(PathBuf),
}

/// Receives one uploaded item: in memory for text, image and data, a `.rapp-part` file for
/// files (`PutSink`).
pub struct PutSink {
    have: u64,
    pub total: u64,
    kind: ClipKind,
    uti: String,
    name: String,
    memory: bool,
    buffer: Vec<u8>,
    file: Option<File>,
    part: Option<PathBuf>,
    uploads: PathBuf,
    safe_name: String,
    final_path: Option<PathBuf>,
}

impl PutSink {
    pub fn new(kind: ClipKind, uti: &str, name: &str, total: u64, uploads: &Path) -> Result<Self, TransferError> {
        let safe_name = portable_file_name(&safe_file_name(name));
        let memory = kind != ClipKind::Files;
        let mut sink = PutSink {
            have: 0,
            total,
            kind,
            uti: uti.to_string(),
            name: name.to_string(),
            memory,
            buffer: Vec::new(),
            file: None,
            part: None,
            uploads: uploads.to_path_buf(),
            safe_name,
            final_path: None,
        };
        if !memory {
            Self::ensure_dir(uploads)?;
            let existing = Self::existing(uploads, None);
            let part_name = unique_name(&sink.safe_name, &|n| existing.contains(n)) + PART_SUFFIX;
            let part = uploads.join(part_name);
            // `FileManager.createFile(atPath:contents: nil)` creates or empties the file.
            let file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&part)
                .map_err(|_| TransferError::new("write failed"))?;
            sink.part = Some(part);
            sink.file = Some(file);
            if total == 0 {
                if let Err(e) = sink.finish() {
                    sink.discard();
                    return Err(e);
                }
            }
        }
        Ok(sink)
    }

    pub fn have(&self) -> u64 {
        self.have
    }

    pub fn kind(&self) -> ClipKind {
        self.kind
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Where the file went once complete (`finalURL`).
    pub fn final_path(&self) -> Option<&Path> {
        self.final_path.as_deref()
    }

    /// The part file while the upload is open.
    pub fn part_path(&self) -> Option<&Path> {
        self.part.as_deref()
    }

    /// What to report once the item is complete: files by the name saved in the uploads folder.
    pub fn transfer(&self) -> WorkerEvent {
        let saved = if self.kind == ClipKind::Files {
            Some(
                self.final_path
                    .as_ref()
                    .and_then(|p| p.file_name())
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| self.safe_name.clone()),
            )
        } else {
            None
        };
        WorkerEvent::Transfer { dir: TransferDirection::BToA, kind: self.kind, bytes: self.total, name: saved }
    }

    fn ensure_dir(dir: &Path) -> Result<(), TransferError> {
        fs::create_dir_all(dir).map_err(|_| TransferError::new("write failed"))
    }

    /// Names in `dir`; a `<name>.rapp-part` also reserves `<name>`. `excluding` is one part
    /// file's own name. An unreadable folder is empty, as Swift's `try?` makes it.
    fn existing(dir: &Path, excluding: Option<&str>) -> HashSet<String> {
        let mut names = HashSet::new();
        let Ok(entries) = fs::read_dir(dir) else { return names };
        for entry in entries.flatten() {
            let n = entry.file_name().to_string_lossy().into_owned();
            if Some(n.as_str()) == excluding {
                continue;
            }
            if let Some(stripped) = n.strip_suffix(PART_SUFFIX) {
                names.insert(stripped.to_string());
            }
            names.insert(n);
        }
        names
    }

    pub fn is_complete(&self) -> bool {
        self.have == self.total
    }

    /// The finished item, or `None` while bytes are still missing.
    pub fn received(&self) -> Option<ReceivedItem> {
        if !self.is_complete() {
            return None;
        }
        match self.kind {
            ClipKind::Text => Some(ReceivedItem::Text(String::from_utf8_lossy(&self.buffer).into_owned())),
            ClipKind::Image => Some(ReceivedItem::Image(self.buffer.clone())),
            ClipKind::Data => Some(ReceivedItem::Data { uti: self.uti.clone(), bytes: self.buffer.clone() }),
            ClipKind::Files => self.final_path.clone().map(ReceivedItem::File),
            ClipKind::Unsupported => None,
        }
    }

    /// Appends bytes; true once everything has arrived (a file is then renamed to its final name).
    pub fn write(&mut self, bytes: &[u8]) -> Result<bool, TransferError> {
        let new_have = self.have + bytes.len() as u64;
        if new_have > self.total {
            return Err(TransferError::new("too large"));
        }
        if self.memory {
            self.buffer.extend_from_slice(bytes);
        } else if let Some(file) = self.file.as_mut() {
            let (have, total) = (self.have, self.total);
            let result = (|| -> io::Result<()> {
                // The file position is `have`, whatever a failed write left behind.
                file.seek(SeekFrom::Start(have))?;
                file.write_all(bytes)?;
                if new_have == total {
                    file.set_len(total)?;
                }
                Ok(())
            })();
            result.map_err(|e| Self::write_error(&e))?;
            if new_have == self.total {
                // Not complete until renamed; a retry rewrites this chunk.
                self.finish()?;
            }
        }
        self.have = new_have;
        Ok(self.have == self.total)
    }

    fn finish(&mut self) -> Result<(), TransferError> {
        let Some(part) = self.part.clone() else { return Ok(()) };
        let own = part.file_name().map(|n| n.to_string_lossy().into_owned());
        let existing = Self::existing(&self.uploads, own.as_deref());
        let target = self.uploads.join(unique_name(&self.safe_name, &|n| existing.contains(n)));
        // `FileManager.moveItem` refuses an existing destination; `fs::rename` would replace it.
        if fs::symlink_metadata(&target).is_ok() {
            return Err(TransferError::new("write failed"));
        }
        fs::rename(&part, &target).map_err(|_| TransferError::new("write failed"))?;
        self.file = None;
        self.final_path = Some(target);
        Ok(())
    }

    /// Closes the file and removes the part file of an unfinished upload.
    pub fn discard(&mut self) {
        self.file = None;
        if self.final_path.is_none() {
            if let Some(part) = &self.part {
                let _ = fs::remove_file(part);
            }
        }
    }

    /// Swift maps `ENOSPC` / `NSFileWriteOutOfSpaceError` to `disk full`, anything else to
    /// `write failed`.
    fn write_error(error: &io::Error) -> TransferError {
        if error.kind() == io::ErrorKind::StorageFull {
            TransferError::new("disk full")
        } else {
            TransferError::new("write failed")
        }
    }
}

/// Serves fetches from the clip store and collects uploads (`TransferStore`). Swift uses it
/// from one queue; the side connections here share a sink through `Arc<Mutex<_>>`.
pub struct TransferStore {
    pub clips: ClipStore,
    uploads: PathBuf,
    memory_limit: usize,
    sinks: HashMap<u32, Arc<Mutex<PutSink>>>,
}

impl TransferStore {
    pub fn new(clips: ClipStore, uploads: PathBuf, memory_limit: usize) -> Self {
        Self { clips, uploads, memory_limit, sinks: HashMap::new() }
    }

    pub fn uploads(&self) -> &Path {
        &self.uploads
    }

    pub fn fetch(&self, clip: u32, file: u16, offset: u64) -> Result<FetchSource, TransferError> {
        let unknown = || TransferError::new("unknown clip");
        let changed = || TransferError::new("file changed");
        let stored = self.clips.clip(clip).ok_or_else(unknown)?;
        match (&stored.info, &stored.payload) {
            (ClipInfo::Image { .. }, ClipPayload::Bytes(b)) | (ClipInfo::Data { .. }, ClipPayload::Bytes(b)) => {
                if file != 0 || offset > b.len() as u64 {
                    return Err(unknown());
                }
                let kind = if matches!(stored.info, ClipInfo::Image { .. }) { ClipKind::Image } else { ClipKind::Data };
                Ok(FetchSource::from_bytes(b.clone(), offset, kind))
            }
            (ClipInfo::Files(files), ClipPayload::Files(refs)) => {
                let index = file as usize;
                let r = refs.get(index).ok_or_else(unknown)?;
                let meta = fs::metadata(&r.path).map_err(|_| changed())?;
                let modified = meta.modified().map_err(|_| changed())?;
                if meta.len() != r.size || modified != r.modified {
                    return Err(changed());
                }
                if offset > r.size {
                    return Err(unknown());
                }
                let handle = File::open(&r.path).map_err(|_| changed())?;
                let name = match files.get(index) {
                    Some(f) => f.name.clone(),
                    None => r.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                };
                FetchSource::from_file(handle, r.size, offset, name)
            }
            _ => Err(unknown()),
        }
    }

    /// A sink for upload `item`. The same item with the same kind, name and size again (a
    /// retried side connection) gets the sink it already has; anything else replaces it.
    pub fn put(
        &mut self,
        item: u32,
        kind: ClipKind,
        uti: &str,
        name: &str,
        total: u64,
    ) -> Result<Arc<Mutex<PutSink>>, TransferError> {
        if kind == ClipKind::Unsupported {
            return Err(TransferError::new("not supported"));
        }
        if let Some(old) = self.sinks.get(&item).cloned() {
            {
                let mut o = old.lock().unwrap_or_else(|p| p.into_inner());
                if o.kind == kind && o.name == name && o.total == total {
                    drop(o);
                    return Ok(old);
                }
                o.discard();
            }
            self.sinks.remove(&item);
        }
        if kind != ClipKind::Files && total > self.memory_limit as u64 {
            return Err(TransferError::new("too large"));
        }
        let sink = Arc::new(Mutex::new(PutSink::new(kind, uti, name, total, &self.uploads)?));
        self.sinks.insert(item, sink.clone());
        Ok(sink)
    }

    pub fn received(&self, item: u32) -> Option<ReceivedItem> {
        self.sinks.get(&item).and_then(|s| s.lock().unwrap_or_else(|p| p.into_inner()).received())
    }
}

/// Counts concurrent side connections (`SideSlots`).
#[derive(Debug, Clone)]
pub struct SideSlots {
    limit: usize,
    used: usize,
}

impl Default for SideSlots {
    fn default() -> Self {
        Self::new(MAX_SIDE_CONNECTIONS)
    }
}

impl SideSlots {
    pub fn new(limit: usize) -> Self {
        Self { limit, used: 0 }
    }

    pub fn take(&mut self) -> bool {
        if self.used >= self.limit {
            return false;
        }
        self.used += 1;
        true
    }

    pub fn release(&mut self) {
        self.used = self.used.saturating_sub(1);
    }
}

/// Received and downloaded files: `RAPP_DOWNLOADS` when set and non-empty, else
/// `<data root>/files/transfers` (`DataPaths.transfers`).
pub fn transfer_dir(env: &dyn Fn(&str) -> Option<String>, data_root: &Path) -> PathBuf {
    match env("RAPP_DOWNLOADS") {
        Some(d) if !d.is_empty() => PathBuf::from(d),
        _ => data_root.join("files").join("transfers"),
    }
}
