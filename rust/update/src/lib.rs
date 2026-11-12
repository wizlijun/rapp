//! Pure logic for rapp's online update: versions, manifest, cache and check rules.
//! Synchronous; callers run it inside `spawn_blocking`.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub mod apply;
pub mod fake;
pub mod fetch;
pub mod runner;

pub use apply::{
    bundle_version, clear_marker, designated, install, read_marker, verify, verify_local, write_marker, InstallError,
    Marker, Verified, MARKER,
};
pub use fetch::{download, fetch_manifest, free_bytes, part_path, sha256_file, zip_path, Failure, Stage};
pub use runner::{Out, Runner, SystemRunner};

pub const BUNDLE_ID: &str = "com.rapp.rapp";
pub const DEFAULT_URL: &str = "https://github.com/wizlijun/rapp-releases/releases/latest/download/latest.json";
pub const PLATFORM: &str = "macos-arm64";
pub const CHECK_EVERY_SECS: u64 = 20 * 3600;

/// `x.y.z` with an optional leading `v`. Anything else (suffixes, path characters, whitespace) is `None`.
pub fn parse_version(s: &str) -> Option<(u64, u64, u64)> {
    let s = s.strip_prefix('v').unwrap_or(s);
    let mut it = s.split('.');
    let mut next = || {
        let p = it.next()?;
        if p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        p.parse::<u64>().ok()
    };
    let v = (next()?, next()?, next()?);
    if it.next().is_some() {
        return None;
    }
    Some(v)
}

/// `x.y.z` rebuilt from the parsed numbers (`v0.05.0` → `0.5.0`): the only form used in file names.
pub fn canonical_version(s: &str) -> Option<String> {
    parse_version(s).map(|(a, b, c)| format!("{a}.{b}.{c}"))
}

/// True only when both parse and `latest > current`.
pub fn is_newer(latest: &str, current: &str) -> bool {
    match (parse_version(latest), parse_version(current)) {
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub version: String,
    pub published_at: Option<String>,
    pub notes: Option<String>,
    pub asset: Asset,
}

#[derive(Deserialize)]
struct RawManifest {
    version: Option<String>,
    published_at: Option<String>,
    notes: Option<String>,
    #[serde(default)]
    assets: std::collections::HashMap<String, serde_json::Value>,
}

#[derive(Deserialize)]
struct RawAsset {
    url: Option<String>,
    sha256: Option<String>,
    size: Option<u64>,
}

/// `Ok(None)` when the manifest has no asset for this platform.
pub fn parse_manifest(bytes: &[u8]) -> Result<Option<Manifest>, String> {
    let raw: RawManifest = serde_json::from_slice(bytes).map_err(|_| "manifest 不是有效的 JSON".to_string())?;
    let version = raw.version.ok_or("manifest 缺少 version")?;
    if parse_version(&version).is_none() {
        return Err("manifest 的版本号无法解析".into());
    }
    let Some(a) = raw.assets.get(PLATFORM) else { return Ok(None) };
    let a: RawAsset = serde_json::from_value(a.clone()).map_err(|_| "manifest 的 asset 格式不对".to_string())?;
    let url = a.url.ok_or("manifest 缺少 asset url")?;
    let sha256 = a.sha256.ok_or("manifest 缺少 sha256")?;
    let size = a.size.ok_or("manifest 缺少 size")?;
    if !url.starts_with("https://") {
        return Err("asset url 不是 https".into());
    }
    if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("sha256 不是 64 位十六进制".into());
    }
    if size == 0 {
        return Err("size 不能为 0".into());
    }
    Ok(Some(Manifest { version, published_at: raw.published_at, notes: raw.notes, asset: Asset { url, sha256, size } }))
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Cache {
    pub latest_version: Option<String>,
    pub last_checked_at: Option<u64>,
    pub dismissed_version: Option<String>,
}

/// Never fails: a missing or corrupt file is an empty cache.
pub fn load_cache(path: &Path) -> Cache {
    rapp_net::config::read_json::<Cache>(path).ok().flatten().unwrap_or_default()
}

pub fn save_cache(path: &Path, c: &Cache) -> std::io::Result<()> {
    rapp_net::config::write_json(path, c).map_err(|e| std::io::Error::other(e.to_string()))
}

pub fn should_check(c: &Cache, now: u64) -> bool {
    match c.last_checked_at {
        None => true,
        Some(last) => now < last || now - last >= CHECK_EVERY_SECS,
    }
}

/// The version to offer: newer than `current` and not dismissed.
pub fn offer(c: &Cache, current: &str) -> Option<String> {
    let latest = c.latest_version.as_deref()?;
    if !is_newer(latest, current) || c.dismissed_version.as_deref() == Some(latest) {
        return None;
    }
    Some(latest.to_string())
}

/// `<x>.app` when `exe` is `<x>.app/Contents/MacOS/<name>`.
pub fn bundle_of(exe: &Path) -> Option<PathBuf> {
    let macos = exe.parent()?;
    if macos.file_name()? != "MacOS" {
        return None;
    }
    let contents = macos.parent()?;
    if contents.file_name()? != "Contents" {
        return None;
    }
    let app = contents.parent()?;
    if app.extension()? != "app" {
        return None;
    }
    Some(app.to_path_buf())
}

/// The designated requirement from `codesign -d -r-` output.
pub fn parse_dr(codesign_output: &str) -> Option<String> {
    codesign_output.lines().find_map(|l| l.split_once("designated => ").map(|(_, r)| r.trim().to_string()))
}

/// Ad-hoc signatures pin to a `cdhash`, which changes on every build.
pub fn is_cdhash_requirement(dr: &str) -> bool {
    dr.trim_start().starts_with("cdhash H\"")
}

/// GitHub asset URLs map to their release page; anything else is returned as is.
pub fn release_page(asset_url: &str) -> String {
    if let Some(rest) = asset_url.strip_prefix("https://github.com/") {
        let p: Vec<&str> = rest.split('/').collect();
        if p.len() == 6
            && p[2] == "releases"
            && p[3] == "download"
            && !p[0].is_empty()
            && !p[1].is_empty()
            && !p[4].is_empty()
        {
            return format!("https://github.com/{}/{}/releases/tag/{}", p[0], p[1], p[4]);
        }
    }
    asset_url.to_string()
}

pub fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn manifest(extra: &str) -> String {
        format!(
            r#"{{"version":"0.5.0","published_at":"2026-11-20T08:00:00Z","notes":"一句话说明，GUI 原样显示","extra":1,
            "assets":{{"macos-arm64":{{"url":"https://github.com/wizlijun/rapp-releases/releases/download/v0.5.0/rapp-0.5.0-macos-arm64.zip",
            "sha256":"{SHA}","size":31457280{extra}}}}}}}"#
        )
    }

    #[test]
    fn is_newer_compares_numerically() {
        assert!(is_newer("0.10.0", "0.9.9"));
        assert!(is_newer("1.0.0", "0.99.99"));
        assert!(is_newer("v0.5.0", "0.4.1"));
        assert!(!is_newer("0.4.1", "0.4.1"));
        assert!(!is_newer("0.4.0", "0.4.1"));
    }

    #[test]
    fn bad_or_suffixed_versions_are_not_newer() {
        for v in ["0.5.0-beta", "0.5", "", "0.5.0.1", "x.y.z"] {
            assert!(!is_newer(v, "0.4.1"), "{v}");
        }
        assert!(!is_newer("0.5.0", "dev"));
    }

    #[test]
    fn canonical_version_strips_prefix_and_zeros() {
        assert_eq!(canonical_version("v0.05.0").as_deref(), Some("0.5.0"));
        assert_eq!(canonical_version("0.5.0").as_deref(), Some("0.5.0"));
        assert_eq!(canonical_version("../0.5.0"), None);
    }

    #[test]
    fn version_with_path_chars_is_rejected() {
        for v in ["../0.5.0", "0.5.0/..", "0.5.0\n"] {
            assert_eq!(parse_version(v), None, "{v:?}");
        }
    }

    #[test]
    fn manifest_full_roundtrip() {
        let m = parse_manifest(manifest("").as_bytes()).unwrap().unwrap();
        assert_eq!(m.version, "0.5.0");
        assert_eq!(m.asset.size, 31457280);
        assert_eq!(m.asset.sha256, SHA);
        assert_eq!(m.published_at.as_deref(), Some("2026-11-20T08:00:00Z"));
        assert_eq!(m.notes.as_deref(), Some("一句话说明，GUI 原样显示"));
    }

    #[test]
    fn manifest_without_platform_is_none() {
        let j = format!(
            r#"{{"version":"0.5.0","assets":{{"windows-x64":{{"url":"https://x/y.zip","sha256":"{SHA}","size":1}}}}}}"#
        );
        assert_eq!(parse_manifest(j.as_bytes()), Ok(None));
    }

    #[test]
    fn manifest_missing_fields_is_err() {
        let ok = manifest("");
        let cases = [
            ok.replace(r#""version":"0.5.0","#, ""),
            ok.replace(&format!(r#""sha256":"{SHA}","#), ""),
            ok.replace(r#""size":31457280"#, r#""x":0"#),
            ok.replace(SHA, &SHA[..63]),
            ok.replace("https://github.com", "http://github.com"),
            ok.replace("31457280", "0"),
            "{x".to_string(),
        ];
        for c in cases {
            assert!(parse_manifest(c.as_bytes()).is_err(), "{c}");
        }
    }

    #[test]
    fn cache_missing_or_corrupt_checks_now() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("update.json");
        assert_eq!(load_cache(&p), Cache::default());
        assert!(should_check(&load_cache(&p), 100));
        std::fs::write(&p, "{x").unwrap();
        assert_eq!(load_cache(&p), Cache::default());
        assert!(should_check(&load_cache(&p), 100));
    }

    #[test]
    fn twenty_hour_rule() {
        let last = 1_000_000;
        let c = Cache { last_checked_at: Some(last), ..Default::default() };
        assert!(!should_check(&c, last + 20 * 3600 - 1));
        assert!(should_check(&c, last + 20 * 3600));
        assert!(should_check(&c, last - 5));
    }

    #[test]
    fn dismissed_only_hides_that_version() {
        let mut c = Cache {
            latest_version: Some("0.5.0".into()),
            dismissed_version: Some("0.5.0".into()),
            ..Default::default()
        };
        assert_eq!(offer(&c, "0.4.1"), None);
        c.latest_version = Some("0.5.1".into());
        assert_eq!(offer(&c, "0.4.1"), Some("0.5.1".into()));
        c.latest_version = Some("0.4.1".into());
        assert_eq!(offer(&c, "0.4.1"), None);
    }

    #[test]
    fn cache_save_load_roundtrip() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("update.json");
        let c = Cache {
            latest_version: Some("0.5.0".into()),
            last_checked_at: Some(42),
            dismissed_version: Some("0.4.9".into()),
        };
        save_cache(&p, &c).unwrap();
        assert_eq!(load_cache(&p), c);
        assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn bundle_of_only_inside_app() {
        assert_eq!(
            bundle_of(Path::new("/Applications/rapp.app/Contents/MacOS/rapp-service")),
            Some(PathBuf::from("/Applications/rapp.app"))
        );
        assert_eq!(bundle_of(Path::new("/x/rust/target/debug/rapp-service")), None);
        assert_eq!(bundle_of(Path::new("/x/rapp/Contents/MacOS/rapp-service")), None);
    }

    #[test]
    fn parse_dr_and_cdhash() {
        let dr = parse_dr("Executable=/x\ndesignated => cdhash H\"dee3c9\"\n").unwrap();
        assert!(is_cdhash_requirement(&dr));
        let dr = parse_dr("designated => identifier \"com.rapp.rapp\" and certificate leaf[subject.CN] = \"Apple Development: a (B)\"\n")
            .unwrap();
        assert!(!is_cdhash_requirement(&dr));
        assert_eq!(parse_dr("Executable=/x\n"), None);
    }

    #[test]
    fn release_page_from_github_asset() {
        assert_eq!(
            release_page(
                "https://github.com/wizlijun/rapp-releases/releases/download/v0.5.0/rapp-0.5.0-macos-arm64.zip"
            ),
            "https://github.com/wizlijun/rapp-releases/releases/tag/v0.5.0"
        );
        assert_eq!(release_page("https://vps.example/rapp/x.zip"), "https://vps.example/rapp/x.zip");
    }
}
