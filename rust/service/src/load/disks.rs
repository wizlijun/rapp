//! Working disks: the disks that hold the paths this device is using, each read on its own so one hung mount
//! (a dead network share) cannot stall the others.

use super::sample::{Covered, Disk};
use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// (total, avail, (files, ffree)) of the file system holding `path`.
pub type Stat = (u64, u64, Option<(u64, u64)>);

/// The device id of `path` and the top directory of that file system: walks up while `st_dev` stays the same.
pub fn mount_of(path: &Path) -> Option<(u64, PathBuf)> {
    let dev = std::fs::metadata(path).ok()?.dev();
    let mut top = path.to_path_buf();
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

pub async fn read(paths: Vec<Covered>, wait: Duration) -> Vec<Disk> {
    read_with(paths, wait, statvfs).await
}

/// Groups `paths` by `st_dev` (a disk counts once) and reads each disk with `stat` in its own blocking task. A
/// disk that does not answer within `wait` is `unreadable` for this sample. A path that cannot be found at all
/// (a deleted directory) is left out.
pub async fn read_with<F>(paths: Vec<Covered>, wait: Duration, stat: F) -> Vec<Disk>
where
    F: Fn(&Path) -> Option<Stat> + Send + Sync + 'static,
{
    let stat = Arc::new(stat);
    // Where each path lives. A path whose own stat hangs becomes a disk of its own, unreadable.
    let mut located = tokio::task::JoinSet::new();
    for (i, c) in paths.iter().enumerate() {
        let p = PathBuf::from(&c.path);
        located.spawn(async move {
            let found = tokio::time::timeout(wait, tokio::task::spawn_blocking(move || mount_of(&p))).await;
            (i, found)
        });
    }
    let mut at: Vec<Option<(u64, PathBuf, bool)>> = vec![None; paths.len()];
    while let Some(Ok((i, found))) = located.join_next().await {
        at[i] = match found {
            Ok(Ok(Some((dev, mount)))) => Some((dev, mount, false)),
            Ok(_) => None,
            Err(_) => Some((u64::MAX - i as u64, PathBuf::from(&paths[i].path), true)),
        };
    }
    let mut disks: Vec<Disk> = vec![];
    let mut index: HashMap<u64, usize> = HashMap::new();
    for (c, loc) in paths.into_iter().zip(at) {
        let Some((dev, mount, hung)) = loc else { continue };
        match index.get(&dev) {
            Some(&n) => disks[n].paths.push(c),
            None => {
                index.insert(dev, disks.len());
                disks.push(Disk {
                    dev,
                    mount: mount.to_string_lossy().into_owned(),
                    total: 0,
                    avail: 0,
                    files: None,
                    paths: vec![c],
                    unreadable: hung,
                });
            }
        }
    }
    let mut reads = tokio::task::JoinSet::new();
    for (i, d) in disks.iter().enumerate().filter(|(_, d)| !d.unreadable) {
        let (mount, stat) = (PathBuf::from(&d.mount), stat.clone());
        reads.spawn(async move {
            let got = tokio::time::timeout(wait, tokio::task::spawn_blocking(move || stat(&mount))).await;
            (i, got)
        });
    }
    while let Some(Ok((i, got))) = reads.join_next().await {
        match got {
            Ok(Ok(Some((total, avail, files)))) => {
                (disks[i].total, disks[i].avail, disks[i].files) = (total, avail, files);
            }
            _ => disks[i].unreadable = true,
        }
    }
    disks
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
        let disks = read(vec![cov(&a), cov(&b)], Duration::from_secs(2)).await;
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
        let disks = read_with(vec![cov(root), cov(dev)], Duration::from_millis(100), move |p| {
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
}
