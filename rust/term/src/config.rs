//! `term.json`: whether terminal sessions are allowed, whether program status (`programStatus`) is read, and whether
//! shells start through the shell hook (`shellHook`).
//! The `tmux` and `targets` of older versions are ignored.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// What every request says while terminal sessions are off.
pub const OFF: &str = "terminal sessions are off";
/// Why a `term.json` that cannot be used is refused (the reason never carries the file's content).
pub const INVALID: &str = "term.json is invalid";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct TermConfig {
    pub allow: bool,
    /// Answer the OSC 7501 probe and track program status.
    #[serde(rename = "programStatus")]
    pub program_status: bool,
    /// Start zsh, bash and fish through the shell hook, which reports the directory, venv and command.
    #[serde(rename = "shellHook")]
    pub shell_hook: bool,
}

impl Default for TermConfig {
    fn default() -> TermConfig {
        TermConfig { allow: true, program_status: true, shell_hook: true }
    }
}

/// The `term.json` next to the `term` directory.
pub fn beside(term_dir: &Path) -> PathBuf {
    term_dir.parent().unwrap_or(term_dir).join("term.json")
}

/// Read `path`. No file is the default; a file that cannot be read or is not JSON is an error whose text says why
/// and nothing of what the file holds.
pub fn load(path: &Path) -> Result<TermConfig, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(TermConfig::default()),
        Err(e) => return Err(format!("{INVALID}: cannot read it ({})", e.kind())),
    };
    // serde_json's own message can quote the offending value, so only its category is kept.
    serde_json::from_str(&text).map_err(|e| format!("{INVALID}: not the expected JSON ({:?})", e.classify()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn program_status_defaults_on_and_reads_camel_case() {
        assert!(TermConfig::default().program_status);
        let (_d, p) = write(r#"{"allow":true}"#);
        assert!(load(&p).unwrap().program_status);
        let (_d, p) = write(r#"{"programStatus":false}"#);
        let c = load(&p).unwrap();
        assert!(!c.program_status && c.allow);
    }

    #[test]
    fn config_shell_hook_defaults_on() {
        assert!(TermConfig::default().shell_hook);
        let (_d, p) = write(r#"{"allow":true}"#);
        assert!(load(&p).unwrap().shell_hook);
        let (_d, p) = write(r#"{"shellHook":false}"#);
        let c = load(&p).unwrap();
        assert!(!c.shell_hook && c.allow && c.program_status);
        assert!(serde_json::to_string(&c).unwrap().contains(r#""shellHook":false"#));
    }

    #[test]
    fn beside_is_next_to_the_term_dir() {
        assert_eq!(beside(Path::new("/r/local/term")), PathBuf::from("/r/local/term.json"));
    }

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
        assert_eq!(c, TermConfig { allow: true, program_status: true, shell_hook: true });
    }

    #[test]
    fn a_file_round_trips_and_unknown_fields_are_ignored() {
        let (_d, p) = write(r#"{"allow":false,"later":1}"#);
        let c = load(&p).unwrap();
        assert!(!c.allow);
        let out = serde_json::to_string(&c).unwrap();
        assert!(!out.contains("later"));
        assert_eq!(serde_json::from_str::<TermConfig>(&out).unwrap(), c);
    }

    #[test]
    fn old_fields_are_ignored() {
        let (_d, p) = write(r#"{"allow":true,"tmux":"/x","targets":[{"name":"g","target":"me@g"}]}"#);
        assert!(load(&p).unwrap().allow);
        // A target that used to be refused is just as unused now.
        let (_d, p) = write(r#"{"targets":[{"name":"a:b","target":"-oProxyCommand=x"}]}"#);
        assert!(load(&p).unwrap().allow);
    }

    #[test]
    fn bad_files_are_refused_without_quoting_them() {
        for f in ["{not json", "[1]", r#"{"allow":"yes"}"#] {
            let (_d, p) = write(f);
            let e = load(&p).expect_err(f);
            assert!(e.starts_with(INVALID), "{e}");
            assert!(!e.contains(f), "{e}");
        }
    }
}
