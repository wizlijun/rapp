//! Fetching the manifest and downloading the asset into the cache, resumably.

use crate::runner::{Runner, CURL, DF};
use crate::{canonical_version, parse_manifest, Manifest};
use sha2::{Digest, Sha256};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Download,
    Verify,
    Install,
    Restart,
}

impl Stage {
    pub fn as_str(self) -> &'static str {
        match self {
            Stage::Download => "download",
            Stage::Verify => "verify",
            Stage::Install => "install",
            Stage::Restart => "restart",
        }
    }
}

/// `reason` is a short fixed phrase or an exit code; never a URL, path or hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub stage: Stage,
    pub reason: String,
}

fn fail(stage: Stage, reason: impl Into<String>) -> Failure {
    Failure { stage, reason: reason.into() }
}

fn s(p: &Path) -> String {
    p.display().to_string()
}

/// HTTP status from curl's `-f` message ("returned error: 404"), never the URL.
/// curl 8.7 reports this as exit 56, older ones as 22.
fn http_status(stderr: &str) -> Option<u16> {
    let rest = stderr.split("returned error: ").nth(1)?;
    rest.split(|c: char| !c.is_ascii_digit()).next()?.parse().ok()
}

fn curl_reason(o: &crate::runner::Out) -> String {
    match http_status(&o.stderr) {
        Some(n) => format!("升级源返回 HTTP {n}"),
        None => format!("curl 退出码 {}", o.code),
    }
}

/// `Ok(None)`: the manifest has no asset for this platform. Errors never carry the URL.
pub fn fetch_manifest(r: &dyn Runner, url: &str, cache_dir: &Path) -> Result<Option<Manifest>, String> {
    std::fs::create_dir_all(cache_dir).map_err(|_| "建不了缓存目录".to_string())?;
    let tmp = cache_dir.join("latest.json.tmp");
    let _ = std::fs::remove_file(&tmp);
    let args: Vec<String> = ["-fsSL", "--proto-redir", "=https", "--max-time", "30", "--max-filesize", "65536", "-o"]
        .iter()
        .map(|a| a.to_string())
        .chain([s(&tmp), url.to_string()])
        .collect();
    let out = r.run(CURL, &args).map_err(|_| "无法运行 curl".to_string());
    let bytes = match out {
        Ok(o) if o.code == 0 => std::fs::read(&tmp).map_err(|_| "读不到 manifest".to_string()),
        Ok(o) if http_status(&o.stderr) == Some(404) => Err("最新的 Release 里没有 latest.json（404）".to_string()),
        Ok(o) => Err(curl_reason(&o)),
        Err(e) => Err(e),
    };
    let _ = std::fs::remove_file(&tmp);
    parse_manifest(&bytes?)
}

/// Available bytes on `dir`'s volume: column 4 of the last line of `df -k`.
pub fn free_bytes(r: &dyn Runner, dir: &Path) -> Option<u64> {
    let o = r.run(DF, &["-k".to_string(), s(dir)]).ok().filter(|o| o.code == 0)?;
    let line = o.stdout.lines().rev().find(|l| !l.trim().is_empty())?;
    line.split_whitespace().nth(3)?.parse::<u64>().ok()?.checked_mul(1024)
}

/// File names use the canonical `x.y.z`; anything unparseable becomes `invalid`, never a path.
fn name(v: &str) -> String {
    canonical_version(v).unwrap_or_else(|| "invalid".into())
}

pub fn part_path(dir: &Path, v: &str) -> PathBuf {
    dir.join(format!("rapp-{}.zip.part", name(v)))
}

pub fn zip_path(dir: &Path, v: &str) -> PathBuf {
    dir.join(format!("rapp-{}.zip", name(v)))
}

/// Lowercase hex, read in chunks.
pub fn sha256_file(p: &Path) -> io::Result<String> {
    let mut f = std::fs::File::open(p)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

fn sha_matches(p: &Path, want: &str) -> io::Result<bool> {
    Ok(sha256_file(p)?.eq_ignore_ascii_case(want))
}

fn len_of(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

/// Downloads into `<dir>/rapp-<v>.zip.part` (resuming), checks size and sha256, then renames
/// to `.zip`. Returns the zip and the bytes fetched by this call. Progress is the `.part` size.
pub fn download(r: &dyn Runner, dir: &Path, m: &Manifest) -> Result<(PathBuf, u64), Failure> {
    let d = Stage::Download;
    let v = canonical_version(&m.version).ok_or_else(|| fail(d, "版本号无法解析"))?;
    let a = &m.asset;
    std::fs::create_dir_all(dir).map_err(|_| fail(d, "建不了缓存目录"))?;
    let zip = zip_path(dir, &v);
    if zip.exists() {
        if sha_matches(&zip, &a.sha256).unwrap_or(false) {
            return Ok((zip, 0));
        }
        let _ = std::fs::remove_file(&zip);
    }
    let free = free_bytes(r, dir).ok_or_else(|| fail(d, "读不到可用空间"))?;
    if free < a.size.saturating_mul(3) {
        return Err(fail(d, "可用空间不够"));
    }
    let part = part_path(dir, &v);
    let mut before = len_of(&part);
    if before > a.size {
        std::fs::remove_file(&part).map_err(|_| fail(d, "删不掉旧的下载文件"))?;
        before = 0;
    }
    if before < a.size {
        let args: Vec<String> = [
            "-fL",
            "--proto-redir",
            "=https",
            "--retry",
            "3",
            "-C",
            "-",
            "--speed-limit",
            "1024",
            "--speed-time",
            "60",
            "-o",
        ]
        .iter()
        .map(|a| a.to_string())
        .chain([s(&part), a.url.clone()])
        .collect();
        let o = r.run(CURL, &args).map_err(|_| fail(d, "无法运行 curl"))?;
        if o.code != 0 {
            if o.code == 33 {
                let _ = std::fs::remove_file(&part);
            }
            return Err(fail(d, curl_reason(&o)));
        }
    }
    let after = len_of(&part);
    if after != a.size {
        if after > a.size {
            let _ = std::fs::remove_file(&part);
        }
        return Err(fail(d, "大小不对"));
    }
    if !sha_matches(&part, &a.sha256).map_err(|_| fail(d, "读不了下载的文件"))? {
        let _ = std::fs::remove_file(&part);
        return Err(fail(d, "sha256 不对"));
    }
    std::fs::rename(&part, &zip).map_err(|_| fail(d, "下载完了但改名失败"))?;
    Ok((zip, after.saturating_sub(before)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{arg_after, FakeRunner};
    use crate::runner::{Out, SystemRunner, CURL, DF};
    use crate::{Asset, Manifest};
    use sha2::{Digest, Sha256};
    use std::io::{Read, Write};
    use std::sync::Arc;

    const SAMPLE: &str = r#"{"version":"0.5.0","published_at":"2026-11-20T08:00:00Z","notes":"一句话说明，GUI 原样显示",
      "assets":{"macos-arm64":{"url":"https://github.com/wizlijun/rapp/releases/download/v0.5.0/rapp-0.5.0-macos-arm64.zip",
      "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","size":31457280}}}"#;
    const DF_PLENTY: &str =
        "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 1000000 50 900000 1% /\n";

    fn data() -> Vec<u8> {
        (0..5000u32).map(|i| (i * 7 % 251) as u8).collect()
    }

    fn hex(b: &[u8]) -> String {
        Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
    }

    fn manifest(version: &str, url: &str, d: &[u8]) -> Manifest {
        Manifest {
            version: version.into(),
            published_at: None,
            notes: None,
            asset: Asset { url: url.into(), sha256: hex(d), size: d.len() as u64 },
        }
    }

    fn has(args: &[String], s: &str) -> bool {
        args.iter().any(|a| a == s)
    }

    fn curl_calls(r: &FakeRunner) -> Vec<Vec<String>> {
        r.calls().into_iter().filter(|(p, _)| p == CURL).map(|(_, a)| a).collect()
    }

    /// A fake curl that appends `body` to its `-o` file, after `check` sees the args.
    fn appending_curl(body: Vec<u8>, check: impl Fn(&[String]) + Send + Sync + 'static) -> FakeRunner {
        FakeRunner::new().on(DF, |_| Out::ok(DF_PLENTY)).on(CURL, move |a| {
            check(a);
            let mut f =
                std::fs::OpenOptions::new().create(true).append(true).open(arg_after(a, "-o").unwrap()).unwrap();
            f.write_all(&body).unwrap();
            Out::ok("")
        })
    }

    #[test]
    fn fetch_manifest_uses_fixed_flags() {
        let d = tempfile::tempdir().unwrap();
        let r = FakeRunner::new().on(CURL, |a| {
            std::fs::write(arg_after(a, "-o").unwrap(), SAMPLE).unwrap();
            Out::ok("")
        });
        let m = fetch_manifest(&r, "https://x/latest.json", d.path()).unwrap().unwrap();
        assert_eq!(m.version, "0.5.0");
        let a = &curl_calls(&r)[0];
        for f in ["-fsSL", "--max-time", "30", "--max-filesize", "65536", "--proto-redir", "=https"] {
            assert!(has(a, f), "{f} missing from {a:?}");
        }
        assert_eq!(arg_after(a, "--max-time"), Some("30"));
        assert_eq!(arg_after(a, "--max-filesize"), Some("65536"));
        assert_eq!(arg_after(a, "--proto-redir"), Some("=https"));
        assert!(!has(a, "--proto"));
        assert_eq!(a.last().map(String::as_str), Some("https://x/latest.json"));
        assert!(!d.path().join("latest.json.tmp").exists());
    }

    #[test]
    fn fetch_failure_reason_has_no_url() {
        let d = tempfile::tempdir().unwrap();
        let r = FakeRunner::new()
            .on(CURL, |_| Out::fail(22, "The requested URL returned error: 404 https://x/latest.json?token=1"));
        let e = fetch_manifest(&r, "https://x/latest.json?token=1", d.path()).unwrap_err();
        assert_eq!(e, "最新的 Release 里没有 latest.json（404）");
        assert!(!e.contains("http"));
    }

    #[test]
    fn curl_56_with_http_404_reads_as_missing_manifest() {
        let d = tempfile::tempdir().unwrap();
        let r = FakeRunner::new().on(CURL, |_| Out::fail(56, "curl: (56) The requested URL returned error: 404"));
        let e = fetch_manifest(&r, "https://x/latest.json", d.path()).unwrap_err();
        assert_eq!(e, "最新的 Release 里没有 latest.json（404）");
    }

    #[test]
    fn other_http_error_names_the_status_only() {
        let d = tempfile::tempdir().unwrap();
        let r = FakeRunner::new().on(CURL, |_| Out::fail(56, "curl: (56) The requested URL returned error: 503 https://x/"));
        let e = fetch_manifest(&r, "https://x/latest.json", d.path()).unwrap_err();
        assert_eq!(e, "升级源返回 HTTP 503");
    }

    #[test]
    fn download_http_404_names_the_status_only() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let r = FakeRunner::new()
            .on(DF, |_| Out::ok(DF_PLENTY))
            .on(CURL, |_| Out::fail(56, "curl: (56) The requested URL returned error: 404 https://x/a.zip"));
        let f = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap_err();
        assert_eq!(f.reason, "升级源返回 HTTP 404");
    }

    #[test]
    fn manifest_version_is_canonical_in_file_names() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(part_path(d.path(), "v0.05.0"), d.path().join("rapp-0.5.0.zip.part"));
        assert_eq!(zip_path(d.path(), "v0.05.0"), d.path().join("rapp-0.5.0.zip"));
        let body = data();
        let want = d.path().join("rapp-0.5.0.zip.part");
        let r = appending_curl(body.clone(), move |a| assert_eq!(arg_after(a, "-o"), want.to_str()));
        let (zip, _) = download(&r, d.path(), &manifest("v0.05.0", "https://x/a.zip", &body)).unwrap();
        assert_eq!(zip, d.path().join("rapp-0.5.0.zip"));
    }

    #[test]
    fn bad_sha_deletes_part_and_fails() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let r = appending_curl(vec![0u8; body.len()], |_| {});
        let m = manifest("0.5.0", "https://x/a.zip", &body);
        let f = download(&r, d.path(), &m).unwrap_err();
        assert_eq!(f, Failure { stage: Stage::Download, reason: "sha256 不对".into() });
        assert!(!part_path(d.path(), "0.5.0").exists());
        assert!(!zip_path(d.path(), "0.5.0").exists());
    }

    #[test]
    fn wrong_size_is_rejected() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let r = appending_curl(body[..body.len() - 1].to_vec(), |_| {});
        let f = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap_err();
        assert_eq!(f, Failure { stage: Stage::Download, reason: "大小不对".into() });
        assert!(part_path(d.path(), "0.5.0").exists());
    }

    #[test]
    fn partial_part_resumes_with_c_dash() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let half = body.len() / 2;
        std::fs::write(part_path(d.path(), "0.5.0"), &body[..half]).unwrap();
        let r = appending_curl(body[half..].to_vec(), |a| {
            assert_eq!(arg_after(a, "-C"), Some("-"));
            for f in ["-fL", "--retry", "--speed-limit", "--speed-time", "--proto-redir"] {
                assert!(has(a, f), "{f} missing from {a:?}");
            }
            assert_eq!(arg_after(a, "--proto-redir"), Some("=https"));
            assert_eq!(arg_after(a, "--retry"), Some("3"));
            assert_eq!(arg_after(a, "--speed-limit"), Some("1024"));
            assert_eq!(arg_after(a, "--speed-time"), Some("60"));
            assert!(!has(a, "--proto"));
        });
        let (zip, bytes) = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap();
        assert_eq!(bytes, (body.len() - half) as u64);
        assert_eq!(zip, zip_path(d.path(), "0.5.0"));
        assert_eq!(sha256_file(&zip).unwrap(), hex(&body));
        assert!(!part_path(d.path(), "0.5.0").exists());
    }

    #[test]
    fn full_part_skips_curl() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        std::fs::write(part_path(d.path(), "0.5.0"), &body).unwrap();
        let r = appending_curl(vec![], |_| {});
        let (zip, bytes) = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap();
        assert_eq!(bytes, 0);
        assert!(zip.exists());
        assert!(curl_calls(&r).is_empty());
    }

    #[test]
    fn existing_good_zip_is_reused() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        std::fs::write(zip_path(d.path(), "0.5.0"), &body).unwrap();
        let r = appending_curl(vec![], |_| {});
        let (zip, bytes) = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap();
        assert_eq!((zip, bytes), (zip_path(d.path(), "0.5.0"), 0));
        assert!(curl_calls(&r).is_empty());
    }

    #[test]
    fn oversized_part_is_deleted() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let part = part_path(d.path(), "0.5.0");
        std::fs::write(&part, [body.as_slice(), b"extra"].concat()).unwrap();
        let p = part.clone();
        let r = appending_curl(body.clone(), move |_| assert!(!p.exists(), ".part should be gone before curl"));
        download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap();
        assert_eq!(curl_calls(&r).len(), 1);
    }

    #[test]
    fn curl_33_deletes_part() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let part = part_path(d.path(), "0.5.0");
        std::fs::write(&part, &body[..10]).unwrap();
        let r = FakeRunner::new().on(DF, |_| Out::ok(DF_PLENTY)).on(CURL, |_| Out::fail(33, "range"));
        let f = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap_err();
        assert_eq!(f, Failure { stage: Stage::Download, reason: "curl 退出码 33".into() });
        assert!(!part.exists());
    }

    #[test]
    fn other_curl_failure_keeps_part_and_hides_url() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let part = part_path(d.path(), "0.5.0");
        std::fs::write(&part, &body[..10]).unwrap();
        let r =
            FakeRunner::new().on(DF, |_| Out::ok(DF_PLENTY)).on(CURL, |_| Out::fail(28, "https://x/a.zip timed out"));
        let f = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap_err();
        assert_eq!(f.reason, "curl 退出码 28");
        assert!(part.exists());
    }

    #[test]
    fn not_enough_space_does_not_download() {
        let d = tempfile::tempdir().unwrap();
        let body = data();
        let r = FakeRunner::new()
            .on(DF, |_| {
                Out::ok("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 100 50 10 50% /")
            })
            .on(CURL, |_| Out::ok(""));
        let f = download(&r, d.path(), &manifest("0.5.0", "https://x/a.zip", &body)).unwrap_err();
        assert_eq!(f.stage, Stage::Download);
        assert!(f.reason.starts_with("可用空间不够"), "{}", f.reason);
        assert!(curl_calls(&r).is_empty());
    }

    #[test]
    fn free_bytes_reads_available_column() {
        let d = tempfile::tempdir().unwrap();
        let r = FakeRunner::new().on(DF, |_| Out::ok(DF_PLENTY));
        assert_eq!(free_bytes(&r, d.path()), Some(900000 * 1024));
        assert_eq!(free_bytes(&FakeRunner::new().on(DF, |_| Out::fail(1, "")), d.path()), None);
        assert_eq!(free_bytes(&FakeRunner::new(), d.path()), None);
    }

    #[test]
    fn stage_names() {
        let s: Vec<&str> =
            [Stage::Download, Stage::Verify, Stage::Install, Stage::Restart].iter().map(|s| s.as_str()).collect();
        assert_eq!(s, ["download", "verify", "install", "restart"]);
    }

    /// Serves `body` on 127.0.0.1, honouring `Range: bytes=N-`; reports each Range header it saw.
    fn serve(body: Vec<u8>) -> (u16, std::sync::mpsc::Receiver<Option<String>>) {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let (tx, rx) = std::sync::mpsc::channel();
        let body = Arc::new(body);
        std::thread::spawn(move || {
            for s in l.incoming() {
                let Ok(mut s) = s else { return };
                let mut req = Vec::new();
                let mut b = [0u8; 1024];
                while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                    match s.read(&mut b) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => req.extend_from_slice(&b[..n]),
                    }
                }
                let req = String::from_utf8_lossy(&req).into_owned();
                let range = req
                    .lines()
                    .find_map(|l| l.split_once(':').filter(|(k, _)| k.eq_ignore_ascii_case("range")))
                    .map(|(_, v)| v.trim().to_string());
                let start = range
                    .as_deref()
                    .and_then(|r| r.strip_prefix("bytes="))
                    .and_then(|r| r.strip_suffix('-'))
                    .and_then(|n| n.parse::<usize>().ok())
                    .unwrap_or(0);
                let _ = tx.send(range);
                let rest = &body[start.min(body.len())..];
                let head = if start > 0 {
                    format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                        rest.len(),
                        start,
                        body.len() - 1,
                        body.len()
                    )
                } else {
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", rest.len())
                };
                let _ = s.write_all(head.as_bytes());
                let _ = s.write_all(rest);
            }
        });
        (port, rx)
    }

    #[test]
    fn real_curl_resumes_from_local_server() {
        if !Path::new(CURL).exists() {
            eprintln!("skip: {CURL} not found");
            return;
        }
        let d = tempfile::tempdir().unwrap();
        let body: Vec<u8> = (0..4000u32).map(|i| (i * 13 % 256) as u8).collect();
        std::fs::write(part_path(d.path(), "0.5.0"), &body[..1000]).unwrap();
        let (port, rx) = serve(body.clone());
        let m = manifest("0.5.0", &format!("http://127.0.0.1:{port}/a.zip"), &body);
        let (zip, bytes) = download(&SystemRunner, d.path(), &m).unwrap();
        assert_eq!(bytes, 3000);
        assert_eq!(sha256_file(&zip).unwrap(), hex(&body));
        let range = rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap();
        assert_eq!(range.as_deref(), Some("bytes=1000-"));
    }
}
