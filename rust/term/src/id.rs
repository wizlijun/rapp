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
