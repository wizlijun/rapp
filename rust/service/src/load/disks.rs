//! Working disks: the disks that hold the paths this device is using, each read on its own so one hung mount
//! (a dead network share) cannot stall the others.

use super::sample::{Covered, Disk};
use std::collections::{HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// (total, avail, (files, ffree)) of the file system holding `path`.
pub type Stat = (u64, u64, Option<(u64, u64)>);

/// The device id of `path` and the top directory of that file system. The path is resolved first (a symlink
/// must not become the mount), then walked up while `st_dev` stays the same.
pub fn mount_of(path: &Path) -> Option<(u64, PathBuf)> {
    let path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let dev = std::fs::metadata(&path).ok()?.dev();
    let mut top = path;
    while let Some(parent) = top.parent() {
        match std::fs::metadata(parent) {
            Ok(m) if m.dev() == dev => top = parent.to_path_buf(),
            _ => break,
        }
    }
    Some((dev, top))
}

#[allow(clippy::unnecessary_cast)]
pub fn statvfs(path: &Path) -> Option<Stat> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
        return None;
    }
    let unit = s.f_frsize as u64;
    let files = (s.f_files as u64 > 0).then_some((s.f_files as u64, s.f_ffree as u64));
    Some((s.f_blocks as u64 * unit, s.f_bavail as u64 * unit, files))
}

type Locate = dyn Fn(&Path) -> Option<(u64, PathBuf)> + Send + Sync;

/// Removes its key from the in-flight set when the blocking call ends, however it ends.
struct Flight(Arc<Mutex<HashSet<String>>>, String);
impl Drop for Flight {
    fn drop(&mut self) {
        self.0.lock().unwrap().remove(&self.1);
    }
}

/// Reads the working disks. Keeps what must outlive one sample: which blocking calls are still stuck (a hung
/// mount gets one thread, not one per tick) and the last known identity of each path.
#[derive(Default)]
pub struct DiskReader {
    inflight: Arc<Mutex<HashSet<String>>>,
    idents: Mutex<HashMap<String, (u64, PathBuf)>>,
}

impl DiskReader {
    /// Runs `f` on a blocking thread unless a call with this `key` has not returned yet. None: skipped, or no
    /// answer within `wait`; the thread stays behind and frees `key` when it finally returns.
    async fn guarded<T: Send + 'static>(
        &self,
        key: String,
        wait: Duration,
        f: impl FnOnce() -> T + Send + 'static,
    ) -> Option<T> {
        if !self.inflight.lock().unwrap().insert(key.clone()) {
            return None;
        }
        let flight = Flight(self.inflight.clone(), key);
        let job = tokio::task::spawn_blocking(move || {
            let _flight = flight;
            f()
        });
        tokio::time::timeout(wait, job).await.ok()?.ok()
    }

    pub async fn read(&self, paths: Vec<Covered>, wait: Duration) -> Vec<Disk> {
        self.read_with(paths, wait, statvfs).await
    }

    pub async fn read_with<F>(&self, paths: Vec<Covered>, wait: Duration, stat: F) -> Vec<Disk>
    where
        F: Fn(&Path) -> Option<Stat> + Send + Sync + 'static,
    {
        self.read_using(paths, wait, mount_of, stat).await
    }

    /// Groups `paths` by `st_dev` (a disk counts once) and reads each disk in its own blocking task. A disk that
    /// does not answer within `wait` (or whose earlier call is still stuck) is `unreadable` for this sample and
    /// keeps its last known mount. A path that cannot be found at all (a deleted directory) is left out.
    pub async fn read_using<L, F>(&self, paths: Vec<Covered>, wait: Duration, locate: L, stat: F) -> Vec<Disk>
    where
        L: Fn(&Path) -> Option<(u64, PathBuf)> + Send + Sync + 'static,
        F: Fn(&Path) -> Option<Stat> + Send + Sync + 'static,
    {
        let (locate, stat): (Arc<Locate>, _) = (Arc::new(locate), Arc::new(stat));
        // Each distinct path string is located once; every `Covered` keeps its place in `paths`.
        let mut uniq: Vec<&str> = vec![];
        for c in &paths {
            if !uniq.contains(&c.path.as_str()) {
                uniq.push(&c.path);
            }
        }
        let mut located = Vec::new();
        for p in &uniq {
            let (pb, locate) = (PathBuf::from(p), locate.clone());
            located.push(self.guarded(format!("locate:{p}"), wait, move || locate(&pb)));
        }
        let located: HashMap<&str, _> = uniq.iter().copied().zip(futures_join(located).await).collect();
        let mut at: Vec<Option<(u64, PathBuf, bool)>> = Vec::with_capacity(paths.len());
        for c in &paths {
            let mut idents = self.idents.lock().unwrap();
            at.push(match located[c.path.as_str()].clone() {
                Some(Some((dev, mount))) => {
                    idents.insert(c.path.clone(), (dev, mount.clone()));
                    Some((dev, mount, false))
                }
                Some(None) => None,
                None => Some(match idents.get(&c.path) {
                    Some((dev, mount)) => (*dev, mount.clone(), true),
                    None => (synthetic_dev(&c.path), PathBuf::from(&c.path), true),
                }),
            });
        }
        let mut disks: Vec<Disk> = vec![];
        let mut index: HashMap<u64, usize> = HashMap::new();
        for (c, loc) in paths.into_iter().zip(at) {
            let Some((dev, mount, hung)) = loc else { continue };
            let n = *index.entry(dev).or_insert_with(|| {
                disks.push(Disk {
                    dev,
                    mount: mount.to_string_lossy().into_owned(),
                    total: 0,
                    avail: 0,
                    files: None,
                    paths: vec![],
                    unreadable: false,
                });
                disks.len() - 1
            });
            disks[n].paths.push(c);
            disks[n].unreadable |= hung;
        }
        let reads: Vec<_> = disks
            .iter()
            .map(|d| {
                let (mount, stat) = (PathBuf::from(&d.mount), stat.clone());
                let skip = d.unreadable;
                let key = format!("stat:{}", d.mount);
                async move {
                    if skip {
                        return None;
                    }
                    self.guarded(key, wait, move || stat(&mount)).await
                }
            })
            .collect();
        for (d, got) in disks.iter_mut().zip(futures_join(reads).await) {
            match got {
                Some(Some((total, avail, files))) => (d.total, d.avail, d.files) = (total, avail, files),
                _ => d.unreadable = true,
            }
        }
        disks
    }
}

/// Stable across samples, and apart from real device ids (top bit set).
fn synthetic_dev(path: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut h);
    h.finish() | (1 << 63)
}

/// Polls the futures together; the results come back in order.
async fn futures_join<T>(fs: Vec<impl std::future::Future<Output = T>>) -> Vec<T> {
    let mut out: Vec<Option<T>> = fs.iter().map(|_| None).collect();
    let mut set = Vec::new();
    for f in fs {
        set.push(Box::pin(f));
    }
    std::future::poll_fn(|cx| {
        let mut pending = false;
        for (slot, f) in out.iter_mut().zip(set.iter_mut()) {
            if slot.is_none() {
                match f.as_mut().poll(cx) {
                    std::task::Poll::Ready(v) => *slot = Some(v),
                    std::task::Poll::Pending => pending = true,
                }
            }
        }
        if pending { std::task::Poll::Pending } else { std::task::Poll::Ready(()) }
    })
    .await;
    out.into_iter().map(|v| v.expect("polled to ready")).collect()
}

#[cfg(test)]
mod tests {
    use super::super::sample::CoverKind;
    use super::*;

    fn cov(path: &Path) -> Covered {
        Covered { kind: CoverKind::Data, path: path.to_string_lossy().into_owned(), term: None }
    }

    #[tokio::test]
    async fn same_disk_counts_once() {
        let dir = tempfile::tempdir().unwrap();
        let (a, b) = (dir.path().join("a"), dir.path().join("b"));
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        let disks = DiskReader::default().read(vec![cov(&a), cov(&b)], Duration::from_secs(2)).await;
        assert_eq!(disks.len(), 1, "{disks:?}");
        assert_eq!(disks[0].paths.len(), 2);
        assert!(!disks[0].unreadable && disks[0].total > 0);
    }

    #[tokio::test]
    async fn hung_disk_is_unreadable_and_others_still_come() {
        // "/" and "/dev" are different file systems on macOS and Linux.
        let (root, dev) = (Path::new("/"), Path::new("/dev"));
        let (r, d) = (mount_of(root).unwrap(), mount_of(dev).unwrap());
        assert_ne!(r.0, d.0, "test needs two file systems");
        let hang = d.1.clone();
        let t0 = std::time::Instant::now();
        let disks = DiskReader::default()
            .read_with(vec![cov(root), cov(dev)], Duration::from_millis(100), move |p| {
                if p == hang {
                    std::thread::sleep(Duration::from_secs(2));
                }
                statvfs(p)
            })
            .await;
        assert!(t0.elapsed() < Duration::from_secs(1), "{:?}", t0.elapsed());
        assert_eq!(disks.len(), 2);
        let by = |dev_id: u64| disks.iter().find(|x| x.dev == dev_id).unwrap();
        assert!(by(d.0).unreadable);
        assert!(!by(r.0).unreadable && by(r.0).total > 0);
    }

    type Gate = Arc<(Mutex<bool>, std::sync::Condvar)>;
    fn wait_open(g: &Gate) {
        let mut open = g.0.lock().unwrap();
        while !*open {
            open = g.1.wait(open).unwrap();
        }
    }

    #[tokio::test]
    async fn a_stuck_disk_gets_one_thread_not_one_per_read() {
        let dev = Path::new("/dev");
        let hang = mount_of(dev).unwrap().1;
        let gate: Gate = Default::default();
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let reader = DiskReader::default();
        let stat = {
            let (gate, calls, hang) = (gate.clone(), calls.clone(), hang.clone());
            move |p: &Path| {
                if p == hang {
                    calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    wait_open(&gate);
                }
                statvfs(p)
            }
        };
        let stat = Arc::new(stat);
        for _ in 0..5 {
            let s = stat.clone();
            let disks = reader.read_with(vec![cov(dev)], Duration::from_millis(50), move |p| s(p)).await;
            assert_eq!(disks.len(), 1);
            assert!(disks[0].unreadable);
        }
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        *gate.0.lock().unwrap() = true;
        gate.1.notify_all();
        let t0 = std::time::Instant::now();
        while !reader.inflight.lock().unwrap().is_empty() && t0.elapsed() < Duration::from_secs(2) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let s = stat.clone();
        let disks = reader.read_with(vec![cov(dev)], Duration::from_secs(1), move |p| s(p)).await;
        assert!(!disks[0].unreadable, "{disks:?}");
    }

    #[tokio::test]
    async fn a_hung_path_keeps_its_real_mount() {
        let dir = tempfile::tempdir().unwrap();
        let reader = DiskReader::default();
        let first = reader.read(vec![cov(dir.path())], Duration::from_secs(1)).await;
        assert!(!first[0].unreadable);
        let hang = |_: &Path| -> Option<(u64, PathBuf)> {
            std::thread::sleep(Duration::from_secs(2));
            None
        };
        let again = reader.read_using(vec![cov(dir.path())], Duration::from_millis(50), hang, statvfs).await;
        assert_eq!(again.len(), 1);
        assert!(again[0].unreadable);
        assert_eq!(again[0].mount, first[0].mount);
        assert_eq!(again[0].dev, first[0].dev);
    }

    #[tokio::test]
    async fn the_same_path_twice_is_one_healthy_disk() {
        let dir = tempfile::tempdir().unwrap();
        let mut two = cov(dir.path());
        two.kind = CoverKind::Term;
        two.term = Some("pty/1".into());
        let disks = DiskReader::default().read(vec![cov(dir.path()), two], Duration::from_secs(1)).await;
        assert_eq!(disks.len(), 1);
        assert!(!disks[0].unreadable, "{disks:?}");
        assert_eq!(disks[0].paths.len(), 2);
    }

    #[tokio::test]
    async fn a_symlink_across_file_systems_is_the_target() {
        let dir = tempfile::tempdir().unwrap();
        let link = dir.path().join("dev");
        std::os::unix::fs::symlink("/dev", &link).unwrap();
        let alone = DiskReader::default().read(vec![cov(Path::new("/dev"))], Duration::from_secs(1)).await;
        let via = DiskReader::default().read(vec![cov(&link)], Duration::from_secs(1)).await;
        assert_eq!(via[0].mount, alone[0].mount);
        assert_eq!(via[0].dev, alone[0].dev);
    }

    #[tokio::test]
    async fn a_symlink_does_not_change_the_mount() {
        let dir = tempfile::tempdir().unwrap();
        let (real, link) = (dir.path().join("real"), dir.path().join("link"));
        std::fs::create_dir_all(&real).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let alone = DiskReader::default().read(vec![cov(&real)], Duration::from_secs(1)).await;
        for order in [vec![cov(&link), cov(&real)], vec![cov(&real), cov(&link)]] {
            let both = DiskReader::default().read(order, Duration::from_secs(1)).await;
            assert_eq!(both.len(), 1);
            assert_eq!(both[0].mount, alone[0].mount);
        }
    }
}
