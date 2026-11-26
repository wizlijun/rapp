//! A's clipboard in a session: the watcher that announces copies (`ClipboardWatcher.swift`,
//! `Server.swift:914-925`) and the paster that writes B's items and presses paste
//! (`Paster.swift`, `Server.swift:506-519`, `:929-936`).
//!
//! Threads. Swift reads and writes the pasteboard on the main queue and keeps the paste queue
//! and the clip store on the session queue. Here:
//! - the watcher is its own thread (`rapp-host clipboard`): every 0.3 s it reads the change
//!   count, decides with the store, reads the clipboard and the files' metadata, and posts the
//!   finished clip to the session thread, which numbers it and sends `clip`;
//! - the paster's platform work (snapshot, write, activate, wait for the front, paste key,
//!   restore) is one worker thread (`rapp-host paste`) taking jobs in order, which is what
//!   Swift's main queue gives; the queue of pastes, `PasteSession` and the replies stay on the
//!   session thread.
//! The store is shared with the side connections (`Arc<Mutex<TransferStore>>`).

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::cli::{TransferDirection, WorkerEvent};
use crate::clipboard::{
    clip_text, should_restore, ClipSource, PasteSession, FOLDER_UNSUPPORTED, MAX_CLIP_DATA, MAX_CLIP_FILES,
    MAX_CLIP_IMAGE, TOO_MANY_FILES,
};
use crate::clock::Clock;
use crate::platform::{ClipRead, ClipSnapshot, ClipboardOps, InputOps, LockOps, TargetOps};
use crate::protocol::{ClipFile, ClipInfo, ClipKind, Message, PasteSource};
use crate::run::Output;
use crate::transfers::{ClipPayload, ClipStore, FileRef, ReceivedItem, TransferStore, TRANSFER_MEMORY_LIMIT};

use super::input::fitted;
use super::session::{Session, Timer};
use super::{hold, Event, Shared};

/// How often the clipboard is read (`ClipboardWatcher.start`).
pub const CLIP_POLL_EVERY: f64 = 0.3;
/// After the paste key, the target gets this long to read the clipboard before B is answered
/// (`Paster.waitFrontmost`), and before an ending session restores it (`Paster.end`).
pub const PASTE_SETTLE: f64 = 0.15;
/// Waiting for the target to come to the front: this many more tries, this far apart.
pub const FRONTMOST_TRIES: u32 = 10;
pub const FRONTMOST_EVERY: f64 = 0.05;
/// The restore check runs this long after a paste finished (`restoreDelay + 0.05`).
pub const RESTORE_CHECK_AFTER: f64 = PasteSession::RESTORE_DELAY + 0.05;
/// Names and UTIs in a `clip` are cut to this many UTF-8 bytes (`fitted`'s default).
const CLIP_NAME_LIMIT: usize = 1024;

/// A transfer store several threads share.
pub type SharedStore = Arc<Mutex<TransferStore>>;

pub(crate) fn lock_store(s: &Mutex<TransferStore>) -> MutexGuard<'_, TransferStore> {
    s.lock().unwrap_or_else(|e| e.into_inner())
}

/// The clipboard parts of a running session.
pub(crate) struct ClipState {
    pub(crate) store: SharedStore,
    /// Set when the session ends: the watcher thread stops at its next tick.
    watch_stop: Arc<AtomicBool>,
    paster: Paster,
}

/// The session-thread half of Swift's `Paster`.
struct Paster {
    worker: Sender<PasteJob>,
    /// Set at the end: the worker stops what it is doing at the next step (Swift's `cancelled`).
    cancelled: Arc<AtomicBool>,
    pending: VecDeque<(u32, PasteSource)>,
    busy: bool,
    ended: bool,
    session: PasteSession,
    saved: bool,
    /// Inline text pastes still unanswered: their UTF-8 size, for the `transfer` event
    /// (`Server.inlinePastes`).
    inline: HashMap<u32, usize>,
}

/// One job for the paste worker, in order.
enum PasteJob {
    Write { item: ReceivedItem, save: bool, seq: u32 },
    Restore { note_write: bool },
    /// The session ended: wait for the last paste key's settle time, restore, exit.
    End,
}

impl Session {
    /// Starts the watcher and the paster (`startClipboard`). `desktop`: no target app, so every
    /// copy counts and the paste key goes to whatever is in front.
    pub(crate) fn start_clipboard(&mut self, desktop: bool) {
        if self.clip.is_some() {
            return;
        }
        let Some(ops) = self.ops.as_ref() else { return };
        let clipboard = ops.clipboard.clone();
        let target = if desktop { None } else { Some(ops.target.clone()) };
        let input = ops.input.clone();
        let lock = self.lock.clone();
        let count = hold(&clipboard).change_count();
        let store: SharedStore = Arc::new(Mutex::new(TransferStore::new(
            ClipStore::new(count),
            self.inner.downloads.clone(),
            TRANSFER_MEMORY_LIMIT,
        )));
        // Side connections from now on find this store.
        *self.transfers_slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(store.clone());

        let watch_stop = Arc::new(AtomicBool::new(false));
        {
            let watch = Watcher {
                clipboard: clipboard.clone(),
                target: target.clone(),
                store: store.clone(),
                clock: self.inner.clock.clone(),
                out: self.inner.out.clone(),
                tx: self.tx.clone(),
                alive: self.alive.clone(),
                stop: watch_stop.clone(),
            };
            let _ = std::thread::Builder::new().name("rapp-host clipboard".into()).spawn(move || watch.run());
        }

        let (worker, jobs) = channel();
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let w = PasteWorker {
                clipboard,
                target,
                input,
                lock,
                store: store.clone(),
                clock: self.inner.clock.clone(),
                out: self.inner.out.clone(),
                tx: self.tx.clone(),
                cancelled: cancelled.clone(),
                last_paste_sent: None,
                last_own_change: i64::MIN,
                snapshot: None,
            };
            let _ = std::thread::Builder::new().name("rapp-host paste".into()).spawn(move || w.run(jobs));
        }
        self.clip = Some(ClipState {
            store,
            watch_stop,
            paster: Paster {
                worker,
                cancelled,
                pending: VecDeque::new(),
                busy: false,
                ended: false,
                session: PasteSession::new(),
                saved: false,
                inline: HashMap::new(),
            },
        });
    }

    /// The session is over: the watcher stops, the paster puts the clipboard back once the last
    /// paste key has had its moment (`Paster.end`, `clipWatcher.stop`, `transfers = nil`).
    pub(crate) fn stop_clipboard(&mut self) {
        if let Some(mut clip) = self.clip.take() {
            let p = &mut clip.paster;
            if !p.ended {
                p.ended = true;
                p.pending.clear();
                if p.saved {
                    p.saved = false;
                    p.session.restored();
                }
                p.cancelled.store(true, Ordering::SeqCst);
                let _ = p.worker.send(PasteJob::End);
            }
            clip.watch_stop.store(true, Ordering::SeqCst);
        }
        *self.transfers_slot.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// A copy the watcher read: numbered by the store and announced (`onClip`).
    fn clip_captured(&mut self, info: ClipInfo, payload: ClipPayload) {
        let Some(clip) = self.clip.as_ref() else { return };
        if self.ended {
            return;
        }
        let id = lock_store(&clip.store).clips.add(info.clone(), payload).id;
        let text_bytes = match &info {
            ClipInfo::Text { text, .. } => Some(text.len() as u64),
            _ => None,
        };
        self.send(Message::Clip { id, info });
        // Text goes inline; other kinds are reported when B fetches them.
        if let Some(bytes) = text_bytes {
            self.inner.out.emit(&WorkerEvent::Transfer {
                dir: TransferDirection::AToB,
                kind: ClipKind::Text,
                bytes,
                name: None,
            });
        }
    }

    /// `paste` (20), after the yield gate (`Server.swift:506-519`).
    pub(crate) fn paste(&mut self, seq: u32, source: PasteSource) {
        if self.clip.is_none() {
            // A desktop session on another screen has no clipboard; B must not wait for an answer.
            if self.desktop {
                self.send(Message::Pasted { seq, error: "no clipboard on this screen".to_string() });
            } else if self.announced.is_some() && self.capture.is_none() {
                // Waiting for the unlock: the app is not attached yet, but B still waits for this answer.
                self.send(Message::Pasted { seq, error: "远程电脑已锁屏，解锁后再发送".to_string() });
            }
            return;
        }
        self.focus_input(&Message::Paste { seq, source: source.clone() });
        let Some(clip) = self.clip.as_mut() else { return };
        let p = &mut clip.paster;
        if p.ended {
            return;
        }
        if let PasteSource::Text(text) = &source {
            p.inline.insert(seq, text.len());
        }
        p.pending.push_back((seq, source));
        self.paste_next();
    }

    /// Starts the next paste unless one is running (`Paster.next`).
    fn paste_next(&mut self) {
        loop {
            let now = self.now();
            let Some(clip) = self.clip.as_mut() else { return };
            let store = clip.store.clone();
            let p = &mut clip.paster;
            if p.busy || p.ended {
                return;
            }
            let Some((seq, source)) = p.pending.pop_front() else { return };
            let item = match source {
                PasteSource::Text(text) => Some(ReceivedItem::Text(text)),
                PasteSource::Item(id) => lock_store(&store).received(id),
            };
            let Some(item) = item else {
                self.paste_reply(seq, "not uploaded");
                continue;
            };
            p.busy = true;
            let save = p.session.paste_started(now);
            if save {
                p.saved = true;
            }
            let _ = p.worker.send(PasteJob::Write { item, save, seq });
            return;
        }
    }

    /// A paste's answer (Swift's `reply` closure, `Server.swift:929-936`).
    fn paste_reply(&mut self, seq: u32, error: &str) {
        if self.ended {
            return;
        }
        self.send(Message::Pasted { seq, error: error.to_string() });
        let inline = self.clip.as_mut().and_then(|c| c.paster.inline.remove(&seq));
        if let Some(bytes) = inline {
            if error.is_empty() {
                self.inner.out.emit(&WorkerEvent::Transfer {
                    dir: TransferDirection::BToA,
                    kind: ClipKind::Text,
                    bytes: bytes as u64,
                    name: None,
                });
            }
        }
    }

    /// The worker finished one paste (`Paster.finish`).
    fn paste_finished(&mut self, seq: u32, error: String) {
        let now = self.now();
        {
            let Some(clip) = self.clip.as_mut() else { return };
            let p = &mut clip.paster;
            if p.ended {
                return;
            }
            p.session.paste_finished(now);
            p.busy = false;
        }
        self.paste_reply(seq, &error);
        // One timer slot: a later finish moves the check to its own time, which is the only
        // check of Swift's several that can find the restore due.
        self.schedule(Timer::PasteRestore, RESTORE_CHECK_AFTER);
        self.paste_next();
    }

    /// `Timer::PasteRestore`: the burst of pastes is over; put the clipboard back.
    pub(crate) fn paste_restore_check(&mut self) {
        let now = self.now();
        let Some(clip) = self.clip.as_mut() else { return };
        let p = &mut clip.paster;
        if p.ended || !p.session.restore_due(now) {
            return;
        }
        p.saved = false;
        p.session.restored();
        let _ = p.worker.send(PasteJob::Restore { note_write: true });
    }
}

// MARK: The watcher thread

struct Watcher {
    clipboard: Shared<dyn ClipboardOps>,
    /// `None` in a desktop session: every copy counts.
    target: Option<Shared<dyn TargetOps>>,
    store: SharedStore,
    clock: Arc<dyn Clock>,
    out: Arc<Output>,
    tx: Sender<Event>,
    alive: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
}

impl Watcher {
    fn stopped(&self) -> bool {
        self.stop.load(Ordering::SeqCst) || !self.alive.load(Ordering::SeqCst)
    }

    fn run(self) {
        loop {
            self.clock.sleep(CLIP_POLL_EVERY);
            if self.stopped() {
                return;
            }
            self.tick();
        }
    }

    /// `ClipboardWatcher.tick` and `read(changeCount:)`.
    fn tick(&self) {
        let count = hold(&self.clipboard).change_count();
        let frontmost = match &self.target {
            None => true,
            Some(t) => hold(t).frontmost(),
        };
        // Swift asks the store on the session queue; the store's own lock serves here.
        if !lock_store(&self.store).clips.changed(count, frontmost) {
            return;
        }
        let Some(read) = hold(&self.clipboard).read() else { return };
        if read.concealed {
            return;
        }
        let Some((info, payload)) = capture(&read, &|line: &str| self.out.log(line)) else { return };
        // Changed again while we read it: the next tick handles the newer copy.
        if hold(&self.clipboard).change_count() != count {
            return;
        }
        if self.stopped() {
            return;
        }
        Session::post(&self.tx, Box::new(move |s: &mut Session| s.clip_captured(info, payload)));
    }
}

/// What a clipboard holds as a clip (`ClipboardWatcher.capture`). File metadata is read here,
/// on the watcher thread.
pub(crate) fn capture(read: &ClipRead, log: &dyn Fn(&str)) -> Option<(ClipInfo, ClipPayload)> {
    match &read.source {
        ClipSource::None => None,
        ClipSource::Files => capture_files(&read.files),
        ClipSource::Image => {
            let png = read.image_png.as_ref()?;
            let (width, height) = png_size(png)?;
            if png.len() >= MAX_CLIP_IMAGE {
                log(&format!("clipboard image is too large to keep ({} bytes)", png.len()));
                return None;
            }
            let info = ClipInfo::Image { width: clamp_u16(width), height: clamp_u16(height), bytes: png.len() as u64 };
            Some((info, ClipPayload::Bytes(png.clone())))
        }
        ClipSource::Text => {
            let s = read.text.as_ref()?;
            if s.is_empty() {
                return None;
            }
            let (text, truncated) = clip_text(s);
            Some((ClipInfo::Text { text, truncated }, ClipPayload::Inline))
        }
        ClipSource::Data { uti } => {
            let data = read.data.as_ref()?;
            if data.len() >= MAX_CLIP_DATA {
                log(&format!("clipboard data {uti} is too large to keep ({} bytes)", data.len()));
                return None;
            }
            let info = ClipInfo::Data { uti: fitted(uti, CLIP_NAME_LIMIT), bytes: data.len() as u64 };
            Some((info, ClipPayload::Bytes(data.clone())))
        }
    }
}

/// `captureFiles`: more than `MAX_CLIP_FILES` or any folder is announced as unsupported; a
/// file whose metadata cannot be read drops the whole clip.
fn capture_files(files: &[FileRef]) -> Option<(ClipInfo, ClipPayload)> {
    if files.is_empty() {
        return None;
    }
    if files.len() > MAX_CLIP_FILES {
        return Some((ClipInfo::Unsupported(TOO_MANY_FILES.to_string()), ClipPayload::Inline));
    }
    let mut refs = Vec::with_capacity(files.len());
    for f in files {
        let meta = std::fs::metadata(&f.path).ok()?;
        let modified = meta.modified().ok()?;
        if meta.is_dir() {
            return Some((ClipInfo::Unsupported(FOLDER_UNSUPPORTED.to_string()), ClipPayload::Inline));
        }
        refs.push(FileRef { path: f.path.clone(), size: meta.len(), modified });
    }
    let list = refs
        .iter()
        .map(|r| ClipFile {
            name: fitted(&r.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(), CLIP_NAME_LIMIT),
            bytes: r.size,
        })
        .collect();
    Some((ClipInfo::Files(list), ClipPayload::Files(refs)))
}

/// A PNG's pixel size from its IHDR chunk; `None` when the bytes are not a PNG (Swift's
/// `NSBitmapImageRep(data:)` failing). The platform converts other image formats to PNG.
pub(crate) fn png_size(png: &[u8]) -> Option<(u32, u32)> {
    const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
    if png.len() < 24 || png[..8] != SIGNATURE || &png[12..16] != b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes([png[16], png[17], png[18], png[19]]);
    let height = u32::from_be_bytes([png[20], png[21], png[22], png[23]]);
    Some((width, height))
}

/// `UInt16(clamping:)`.
fn clamp_u16(v: u32) -> u16 {
    v.min(u32::from(u16::MAX)) as u16
}

// MARK: The paste worker thread

struct PasteWorker {
    clipboard: Shared<dyn ClipboardOps>,
    /// `None` in a desktop session: the paste key goes to whatever is in front.
    target: Option<Shared<dyn TargetOps>>,
    input: Shared<dyn InputOps>,
    lock: Shared<dyn LockOps>,
    store: SharedStore,
    clock: Arc<dyn Clock>,
    out: Arc<Output>,
    tx: Sender<Event>,
    cancelled: Arc<AtomicBool>,
    last_paste_sent: Option<f64>,
    /// The change count after the last write this paster made (`lastOwnChange`).
    last_own_change: i64,
    snapshot: Option<ClipSnapshot>,
}

impl PasteWorker {
    fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    fn run(mut self, jobs: Receiver<PasteJob>) {
        while let Ok(job) = jobs.recv() {
            match job {
                PasteJob::Write { item, save, seq } => self.write(&item, save, seq),
                PasteJob::Restore { note_write } => self.restore(note_write),
                PasteJob::End => {
                    // The target reads the clipboard shortly after the paste key; let it, before restoring.
                    if let Some(sent) = self.last_paste_sent {
                        let wait = sent + PASTE_SETTLE - self.clock.now();
                        if wait > 0.0 {
                            self.clock.sleep(wait);
                        }
                    }
                    self.restore(false);
                    return;
                }
            }
        }
        // The session dropped its sender without `End` (it never ends that way): restore anyway.
        self.restore(false);
    }

    fn finish(&self, seq: u32, error: &str) {
        let error = error.to_string();
        Session::post(&self.tx, Box::new(move |s: &mut Session| s.paste_finished(seq, error)));
    }

    /// The watcher reads the change count first and asks the store second; the paster writes
    /// with the store held and notes the write before letting go. So the watcher either sees
    /// the old count or finds the write already noted, and never announces A's own write as a
    /// copy (`noteOwnWrite`; Swift gets the same from doing both on the main queue).
    fn note_own_write(&self, store: &mut TransferStore, count: i64) {
        if !self.cancelled() {
            store.clips.note_own_write(count);
        }
    }

    /// `Paster.write`: save once per burst, write, bring the target to the front, wait for it.
    fn write(&mut self, item: &ReceivedItem, save: bool, seq: u32) {
        if self.cancelled() {
            return;
        }
        if save {
            self.snapshot = hold(&self.clipboard).snapshot();
            if self.snapshot.is_none() {
                // The platform declines a snapshot above 64 MiB (`maxSnapshotBytes`).
                self.out.log("clipboard too large to save; it will not be restored");
            }
        }
        let written = {
            let mut store = lock_store(&self.store);
            let result = hold(&self.clipboard).write(item);
            if let Ok(count) = result {
                self.note_own_write(&mut store, count);
            }
            result
        };
        let count = match written {
            Ok(count) => count,
            Err(e) => {
                self.out.log(&format!("clipboard write failed: {e}"));
                self.finish(seq, "clipboard write failed");
                return;
            }
        };
        self.last_own_change = count;
        if let Some(t) = &self.target {
            hold(t).activate();
        }
        self.wait_frontmost(seq);
    }

    /// `Paster.waitFrontmost`: up to 10 more tries 50 ms apart.
    fn wait_frontmost(&mut self, seq: u32) {
        let mut tries = FRONTMOST_TRIES;
        loop {
            if self.cancelled() {
                return;
            }
            let front = match &self.target {
                None => true,
                Some(t) => hold(t).frontmost(),
            };
            if front {
                self.last_paste_sent = Some(self.clock.now());
                hold(&self.input).paste_key();
                self.clock.sleep(PASTE_SETTLE);
                // Swift answers even when the session ended meanwhile; the session drops it then.
                self.finish(seq, "");
                return;
            }
            if tries == 0 {
                let error = if hold(&self.lock).locked() { "screen locked" } else { "target not frontmost" };
                self.finish(seq, error);
                return;
            }
            tries -= 1;
            self.clock.sleep(FRONTMOST_EVERY);
        }
    }

    /// `restoreOnMain`: puts the saved clipboard back unless something else wrote since.
    fn restore(&mut self, note_write: bool) {
        let Some(snapshot) = self.snapshot.take() else { return };
        let current = hold(&self.clipboard).change_count();
        // Something else (a copy on A) wrote since our paste: leave it alone.
        if !should_restore(self.last_own_change, current) {
            return;
        }
        let restored = {
            let mut store = lock_store(&self.store);
            let restored = hold(&self.clipboard).restore(snapshot);
            if let (Some(count), true) = (restored, note_write) {
                self.note_own_write(&mut store, count);
            }
            restored
        };
        if let Some(count) = restored {
            self.last_own_change = count;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn read(source: ClipSource) -> ClipRead {
        ClipRead { source, text: None, image_png: None, files: Vec::new(), data: None, concealed: false }
    }

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut p = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13];
        p.extend(b"IHDR");
        p.extend(width.to_be_bytes());
        p.extend(height.to_be_bytes());
        p.extend([8, 6, 0, 0, 0]);
        p
    }

    #[test]
    fn png_size_reads_ihdr() {
        assert_eq!(png_size(&png(640, 70000)), Some((640, 70000)));
        assert_eq!(png_size(b"not a png at all, not at all"), None);
    }

    #[test]
    fn image_size_is_clamped() {
        let mut r = read(ClipSource::Image);
        r.image_png = Some(png(640, 70000));
        let (info, _) = capture(&r, &|_| {}).unwrap();
        assert_eq!(info, ClipInfo::Image { width: 640, height: u16::MAX, bytes: r.image_png.unwrap().len() as u64 });
    }

    #[test]
    fn empty_text_is_not_a_clip() {
        let mut r = read(ClipSource::Text);
        r.text = Some(String::new());
        assert!(capture(&r, &|_| {}).is_none());
    }

    #[test]
    fn too_many_files_and_folders_are_unsupported() {
        let dir = std::env::temp_dir();
        let one = FileRef { path: dir.clone(), size: 0, modified: std::time::UNIX_EPOCH };
        let mut r = read(ClipSource::Files);
        r.files = vec![one.clone()];
        assert_eq!(capture(&r, &|_| {}).unwrap().0, ClipInfo::Unsupported(FOLDER_UNSUPPORTED.to_string()));
        r.files = vec![one; MAX_CLIP_FILES + 1];
        assert_eq!(capture(&r, &|_| {}).unwrap().0, ClipInfo::Unsupported(TOO_MANY_FILES.to_string()));
        // A file that is gone drops the clip.
        r.files =
            vec![FileRef { path: PathBuf::from("/no/such/rapp/file"), size: 0, modified: std::time::UNIX_EPOCH }];
        assert!(capture(&r, &|_| {}).is_none());
    }

    #[test]
    fn large_data_is_logged_not_kept() {
        let mut r = read(ClipSource::Data { uti: "com.example.big".into() });
        r.data = Some(vec![0; MAX_CLIP_DATA]);
        let lines = std::cell::RefCell::new(Vec::new());
        assert!(capture(&r, &|l: &str| lines.borrow_mut().push(l.to_string())).is_none());
        assert_eq!(lines.into_inner(), [format!("clipboard data com.example.big is too large to keep ({MAX_CLIP_DATA} bytes)")]);
    }
}
