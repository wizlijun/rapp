//! `term.json`: whether terminal sessions are allowed, the local tmux, and the SSH targets.

use crate::id::valid_host;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// What every request says while terminal sessions are off.
pub const OFF: &str = "terminal sessions are off";
/// Why a `term.json` that cannot be used is refused (the reason never carries the file's content).
pub const INVALID: &str = "term.json is invalid";
/// The most targets in a `term.json`.
pub const MAX_TARGETS: usize = 32;

const MAX_NAME: usize = 64;
const MAX_TARGET: usize = 255;
const MAX_TMUX: usize = 1024;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct TermConfig {
    pub allow: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux: Option<String>,
    pub targets: Vec<Target>,
}

impl Default for TermConfig {
    fn default() -> TermConfig {
        TermConfig { allow: true, tmux: None, targets: Vec::new() }
    }
}

/// One machine reached over SSH: `target` is what is given to ssh, `name` what term ids call it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Target {
    pub name: String,
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tmux: Option<String>,
}

/// Read `path`. No file is the default; a file that cannot be read, is not JSON or does not pass `check` is an
/// error whose text says why and nothing of what the file holds.
pub fn load(path: &Path) -> Result<TermConfig, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(TermConfig::default()),
        Err(e) => return Err(format!("{INVALID}: cannot read it ({})", e.kind())),
    };
    // serde_json's own message can quote the offending value, so only its category is kept.
    let c: TermConfig =
        serde_json::from_str(&text).map_err(|e| format!("{INVALID}: not the expected JSON ({:?})", e.classify()))?;
    c.check().map_err(|e| format!("{INVALID}: {e}"))?;
    Ok(c)
}

impl TermConfig {
    pub fn check(&self) -> Result<(), String> {
        if self.targets.len() > MAX_TARGETS {
            return Err("too many targets".into());
        }
        if let Some(t) = &self.tmux {
            check_tmux(t)?;
        }
        for (i, t) in self.targets.iter().enumerate() {
            check_target(t)?;
            if self.targets[..i].iter().any(|o| o.name == t.name) {
                return Err("target names must be unique".into());
            }
        }
        Ok(())
    }

    pub fn target(&self, name: &str) -> Option<&Target> {
        self.targets.iter().find(|t| t.name == name)
    }

    /// The tmux of this machine.
    pub fn tmux_bin(&self) -> &str {
        self.tmux.as_deref().unwrap_or("tmux")
    }
}

fn check_tmux(t: &str) -> Result<(), String> {
    if t.is_empty() || t.starts_with('-') || t.chars().any(char::is_control) || t.len() > MAX_TMUX {
        return Err("invalid tmux path".into());
    }
    Ok(())
}

/// A target ssh cannot mistake for an option or split in two (the rules of `Runner::ssh`), a name a term id can
/// carry, and the length caps.
pub fn check_target(t: &Target) -> Result<(), String> {
    if !valid_host(&t.name) || t.name.len() > MAX_NAME {
        return Err("invalid target name".into());
    }
    let d = &t.target;
    let bad = d.is_empty() || d.starts_with('-') || d.chars().any(|c| c.is_whitespace() || c.is_control());
    if bad || d.len() > MAX_TARGET {
        return Err("invalid ssh target".into());
    }
    if let Some(m) = &t.tmux {
        check_tmux(m)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(text: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("term.json");
        std::fs::write(&p, text).unwrap();
        (d, p)
    }

    #[test]
    fn a_missing_file_is_the_default_and_the_default_allows() {
        let d = tempfile::tempdir().unwrap();
        let c = load(&d.path().join("term.json")).unwrap();
        assert_eq!(c, TermConfig { allow: true, tmux: None, targets: vec![] });
        assert_eq!(c.tmux_bin(), "tmux");
    }

    #[test]
    fn a_file_round_trips_and_unknown_fields_are_ignored() {
        let (_d, p) = write(
            r#"{"allow":false,"tmux":"/usr/local/bin/tmux","targets":[{"name":"gpu1","target":"me@gpu1","tmux":"/opt/homebrew/bin/tmux"}],"later":1}"#,
        );
        let c = load(&p).unwrap();
        assert!(!c.allow);
        assert_eq!(c.tmux_bin(), "/usr/local/bin/tmux");
        assert_eq!(c.target("gpu1").unwrap().tmux.as_deref(), Some("/opt/homebrew/bin/tmux"));
        assert!(c.target("gpu2").is_none());
        let out = serde_json::to_string(&c).unwrap();
        assert!(!out.contains("later"));
        assert_eq!(serde_json::from_str::<TermConfig>(&out).unwrap(), c);
    }

    #[test]
    fn bad_files_and_targets_are_refused() {
        let target = |name: &str, target: &str, tmux: Option<&str>| {
            let t = serde_json::json!({"name": name, "target": target, "tmux": tmux});
            serde_json::json!({ "targets": [t] }).to_string()
        };
        let mut files = vec!["{not json".to_string(), "[1]".to_string()];
        files.push(r#"{"targets":[{"name":"a","target":"x"},{"name":"a","target":"y"}]}"#.into());
        for n in ["", "a:b", "a b"] {
            files.push(target(n, "me@h", None));
        }
        files.push(target(&"n".repeat(65), "me@h", None));
        let long = "t".repeat(256);
        for t in ["", "-oProxyCommand=x", "a b", "a\tb", long.as_str()] {
            files.push(target("n", t, None));
        }
        let long = "/".repeat(1025);
        for m in ["", "-x", "a\nb", long.as_str()] {
            files.push(target("n", "me@h", Some(m)));
        }
        let many: Vec<_> = (0..33).map(|i| serde_json::json!({"name": format!("h{i}"), "target": "x"})).collect();
        let many = serde_json::json!({ "targets": many }).to_string();
        files.push(many.clone());
        for f in &files {
            let (_d, p) = write(f);
            let e = load(&p).expect_err(f);
            assert!(e.starts_with(INVALID), "{e}");
            assert!(!e.contains(f.as_str()), "{e}");
            assert!(!e.contains("ProxyCommand") && !e.contains("not json"), "{e}");
        }
        let (_d, p) = write(&many);
        assert!(load(&p).unwrap_err().contains("too many targets"));
        // The limits themselves are allowed.
        let ok = target(&"n".repeat(64), &"t".repeat(255), Some(&"/".repeat(1024)));
        assert!(load(&write(&ok).1).is_ok());
        let t = Target { name: "a:b".into(), target: "x".into(), tmux: None };
        assert!(check_target(&t).is_err());
    }
}
