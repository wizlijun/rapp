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

/// A session name fit for a term id and a socket name: `:` and `.` are turned into `_`; empty names and control
/// characters are refused.
pub fn session_name(s: &str) -> Option<String> {
    if s.is_empty() || s.chars().any(char::is_control) {
        return None;
    }
    Some(s.replace([':', '.'], "_"))
}

/// The most characters a session name has.
pub const NAME_MAX: usize = 64;

/// A name a session can be renamed to: trimmed, not empty, without control characters, at most `NAME_MAX`
/// characters. Duplicates are fine: the id is the key, not the name.
pub fn clean_name(s: &str) -> Option<String> {
    let t = s.trim();
    if t.is_empty() || t.chars().any(char::is_control) || t.chars().count() > NAME_MAX {
        return None;
    }
    Some(t.to_string())
}

/// The default name of a new session: the last path part of the command's first word (`claude --resume` and
/// `/usr/local/bin/claude -c` are both `claude`); `shell` when that is empty.
pub fn default_name(command: &str) -> &str {
    let program = command.split_whitespace().next().unwrap_or_default();
    match program.rsplit('/').next() {
        Some(n) if !n.is_empty() => n,
        _ => "shell",
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
        let t = TermId::parse("term:pty:work").unwrap();
        assert_eq!((t.backend.as_str(), t.host.as_deref(), t.name.as_str()), ("pty", None, "work"));
        let t = TermId::parse("term:pty@gpu1:训练 run:2").unwrap();
        assert_eq!((t.host.as_deref(), t.name.as_str()), (Some("gpu1"), "训练 run:2"));
        assert_eq!(t.to_string(), "term:pty@gpu1:训练 run:2");
    }

    #[test]
    fn term_prefix() {
        assert!(is_term("term:pty:work") && !is_term("com.apple.Safari") && !is_term("term"));
    }

    #[test]
    fn a_rename_is_trimmed_and_bounded() {
        assert_eq!(clean_name("  后端 ").as_deref(), Some("后端"));
        assert_eq!(clean_name("a:b.c").as_deref(), Some("a:b.c"));
        assert_eq!((clean_name(""), clean_name("  "), clean_name("a\u{7}"), clean_name("a\nb")), (None, None, None, None));
        assert!(clean_name(&"x".repeat(64)).is_some() && clean_name(&"x".repeat(65)).is_none());
        // 64 characters, more than 64 bytes.
        assert!(clean_name(&"后".repeat(64)).is_some() && clean_name(&"后".repeat(65)).is_none());
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
    fn a_command_lines_default_name_is_its_first_words_last_path_part() {
        assert_eq!(default_name("claude --resume"), "claude");
        assert_eq!(default_name("/usr/local/bin/claude -c"), "claude");
        assert_eq!(default_name("  cd ~/x && claude"), "cd");
        assert_eq!(default_name("./run.sh\targ"), "run.sh");
        // Nothing to name it by: `shell`, never an empty (invalid) name.
        for blank in ["", "  ", "/", "a/ b"] {
            assert!(session_name(default_name(blank)).is_some(), "{blank:?}");
        }
        assert_eq!(default_name("  "), "shell");
    }

    #[test]
    fn rejects_malformed() {
        for bad in [
            "pty:work",
            "term:",
            "term::x",
            "term:pty:",
            "term:PTY:x",
            "term:pty@:x",
            "term:pty@a b:x",
            "com.apple.Safari",
        ] {
            assert!(TermId::parse(bad).is_err(), "{bad}");
        }
    }
}
