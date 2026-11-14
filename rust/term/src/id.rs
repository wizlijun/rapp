//! The `term:` id: `term:<backend>[@<host>]:<name>`. This is the only place it is parsed or built.

use std::fmt;

use anyhow::{bail, Result};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TermId {
    pub backend: String,
    pub host: Option<String>,
    pub name: String,
}

impl TermId {
    pub fn parse(s: &str) -> Result<TermId> {
        let Some(rest) = s.strip_prefix("term:") else { bail!("not a term: id") };
        // The name is everything after the second colon and may itself contain colons.
        let Some((head, name)) = rest.split_once(':') else { bail!("term: id has no name") };
        if name.is_empty() {
            bail!("term: id has an empty name");
        }
        let (backend, host) = match head.split_once('@') {
            Some((b, h)) => (b, Some(h)),
            None => (head, None),
        };
        if backend.is_empty() || !backend.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit()) {
            bail!("term: id has a bad backend");
        }
        if let Some(h) = host {
            if h.is_empty() || !h.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')) {
                bail!("term: id has a bad host");
            }
        }
        Ok(TermId { backend: backend.to_string(), host: host.map(str::to_string), name: name.to_string() })
    }
}

/// Whether `s` is a term id by its prefix: `term:` and something after it.
pub fn is_term(s: &str) -> bool {
    s.strip_prefix("term:").is_some_and(|r| !r.is_empty())
}

/// Whether `name` can be the host of a term id and read back the same: `a:b` would parse, but as host `a` and a
/// name starting `b:`.
pub fn valid_host(name: &str) -> bool {
    let id = TermId { backend: "tmux".into(), host: Some(name.to_string()), name: "-".into() };
    matches!(TermId::parse(&id.to_string()), Ok(t) if t.host.as_deref() == Some(name))
}

/// A session name tmux keeps as given on every version: tmux before 3.5 turns `:` and `.` into `_`, so they are
/// turned here; empty names and control characters are refused.
pub fn session_name(s: &str) -> Option<String> {
    if s.is_empty() || s.chars().any(char::is_control) {
        return None;
    }
    Some(s.replace([':', '.'], "_"))
}

/// The default name of a new session: the last path part of the command's program.
pub fn default_name(program: &str) -> &str {
    program.rsplit('/').next().unwrap_or(program)
}

impl fmt::Display for TermId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.host {
            Some(h) => write!(f, "term:{}@{}:{}", self.backend, h, self.name),
            None => write!(f, "term:{}:{}", self.backend, self.name),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_prints() {
        let t = TermId::parse("term:tmux:work").unwrap();
        assert_eq!((t.backend.as_str(), t.host.as_deref(), t.name.as_str()), ("tmux", None, "work"));
        let t = TermId::parse("term:tmux@gpu1:训练 run:2").unwrap();
        assert_eq!((t.host.as_deref(), t.name.as_str()), (Some("gpu1"), "训练 run:2"));
        assert_eq!(t.to_string(), "term:tmux@gpu1:训练 run:2");
    }

    #[test]
    fn term_prefix_and_host_names() {
        assert!(is_term("term:tmux:work") && !is_term("com.apple.Safari") && !is_term("term"));
        assert!(valid_host("gpu1") && valid_host("gpu-1.lab"));
        assert!(!valid_host("") && !valid_host("a:b") && !valid_host("a b") && !valid_host("a@b"));
    }

    #[test]
    fn sessions_and_programs_are_named() {
        assert_eq!(session_name("cli demo").as_deref(), Some("cli demo"));
        assert_eq!(session_name("py3.11:x").as_deref(), Some("py3_11_x"));
        assert_eq!(session_name(""), None);
        assert_eq!(session_name("a\nb"), None);
        assert_eq!((default_name("/usr/local/bin/claude"), default_name("cat")), ("claude", "cat"));
    }

    #[test]
    fn rejects_malformed() {
        for bad in [
            "tmux:work",
            "term:",
            "term::x",
            "term:tmux:",
            "term:TMUX:x",
            "term:tmux@:x",
            "term:tmux@a b:x",
            "com.apple.Safari",
        ] {
            assert!(TermId::parse(bad).is_err(), "{bad}");
        }
    }
}
