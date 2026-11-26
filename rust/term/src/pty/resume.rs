//! What a restored terminal pre-types: the command it was running, rewritten for programs that can take up where
//! they left off (`claude --continue`, `codex resume --last`). A prompt given on the old command line (a positional
//! word) is dropped, so it is not sent again. The rules are one table, to add programs to.

/// How one program takes up where it left off.
struct Resume {
    /// The program's name (the basename of the first word).
    prog: &'static str,
    /// How it resumes.
    how: How,
    /// The options that take the next word as their value (when written without `=`).
    value_options: &'static [&'static str],
}

enum How {
    /// Append this option, unless one of these (or `flag=…`) is already there.
    Append(&'static str, &'static [&'static str]),
    /// Insert these words after the program, unless its first argument is the first of them already.
    Sub(&'static [&'static str]),
}

const TABLE: &[Resume] = &[
    Resume {
        prog: "claude",
        how: How::Append("--continue", &["-c", "--continue", "-r", "--resume"]),
        value_options: &[
            "--model",
            "--permission-mode",
            "--add-dir",
            "--settings",
            "--mcp-config",
            "--append-system-prompt",
            "--allowedTools",
            "--disallowedTools",
            "--agent",
            "--fallback-model",
        ],
    },
    Resume {
        prog: "codex",
        how: How::Sub(&["resume", "--last"]),
        value_options: &[
            "-m",
            "--model",
            "-c",
            "--config",
            "-p",
            "--profile",
            "-s",
            "--sandbox",
            "-a",
            "--ask-for-approval",
            "-C",
            "--cd",
            "-i",
            "--image",
        ],
    },
];

/// The command as it is to be pre-typed (never with a line end: the user presses Enter).
pub fn prefill(cmd: &str) -> String {
    let words = split(cmd);
    let Some((first, args)) = words.split_first() else { return cmd.to_string() };
    let base = unquote(first);
    let base = base.rsplit('/').next().unwrap_or_default();
    let Some(r) = TABLE.iter().find(|r| r.prog == base) else { return cmd.to_string() };
    match r.how {
        How::Append(_, already) if args.iter().any(|w| is_one_of(w, already)) => return cmd.to_string(),
        How::Sub(sub) if args.first().is_some_and(|w| unquote(w) == sub[0]) => return cmd.to_string(),
        _ => {}
    }
    let mut out = vec![first.to_string()];
    if let How::Sub(sub) = r.how {
        out.extend(sub.iter().map(|w| w.to_string()));
    }
    let mut value_next = false;
    for w in args {
        if value_next {
            out.push(w.to_string());
            value_next = false;
            continue;
        }
        let bare = unquote(w);
        // After `--` the rest is the prompt.
        if bare == "--" {
            break;
        }
        if bare.starts_with('-') {
            value_next = r.value_options.contains(&bare.as_str());
            out.push(w.to_string());
        }
        // Any other word is a prompt: dropped.
    }
    if let How::Append(opt, _) = r.how {
        out.push(opt.to_string());
    }
    out.join(" ")
}

/// Whether the word is one of `flags`, alone or as `flag=value`.
fn is_one_of(word: &str, flags: &[&str]) -> bool {
    let bare = unquote(word);
    flags.iter().any(|f| bare == *f || bare.strip_prefix(f).is_some_and(|r| r.starts_with('=')))
}

/// The line's words as written (quotes kept), split on unquoted whitespace.
fn split(line: &str) -> Vec<&str> {
    let mut words = Vec::new();
    let (mut start, mut quote, mut escaped) = (None, None, false);
    for (i, c) in line.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match (quote, c) {
            (Some('\''), '\'') => quote = None,
            (Some('\''), _) => {}
            (_, '\\') => {
                escaped = true;
                start.get_or_insert(i);
            }
            (Some('"'), '"') => quote = None,
            (Some(_), _) => {}
            (None, '\'' | '"') => {
                quote = Some(c);
                start.get_or_insert(i);
            }
            (None, c) if c.is_whitespace() => {
                if let Some(s) = start.take() {
                    words.push(&line[s..i]);
                }
            }
            (None, _) => {
                start.get_or_insert(i);
            }
        }
    }
    if let Some(s) = start {
        words.push(&line[s..]);
    }
    words
}

/// A word with its quotes and backslashes taken out, to compare with a name.
fn unquote(word: &str) -> String {
    let mut out = String::new();
    let (mut quote, mut escaped) = (None, false);
    for c in word.chars() {
        if escaped {
            out.push(c);
            escaped = false;
            continue;
        }
        match (quote, c) {
            (Some('\''), '\'') | (Some('"'), '"') => quote = None,
            (Some('\''), _) => out.push(c),
            (_, '\\') => escaped = true,
            (Some(_), _) => out.push(c),
            (None, '\'' | '"') => quote = Some(c),
            (None, _) => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_gets_continue() {
        assert_eq!(prefill("claude --dangerously-skip-permissions"), "claude --dangerously-skip-permissions --continue");
        assert_eq!(prefill("claude"), "claude --continue");
    }

    #[test]
    fn claude_with_resume_untouched() {
        for c in ["claude -r", "claude --continue", "claude -c", "claude --resume abc 'x'", "claude --resume=abc"] {
            assert_eq!(prefill(c), c);
        }
    }

    #[test]
    fn claude_prompt_dropped() {
        assert_eq!(prefill("claude 'fix the bug'"), "claude --continue");
        assert_eq!(prefill("claude --model opus 'x'"), "claude --model opus --continue");
        assert_eq!(prefill("claude --model=opus \"fix it\" now"), "claude --model=opus --continue");
        assert_eq!(prefill("/usr/local/bin/claude -p hi"), "/usr/local/bin/claude -p --continue");
        // After `--` everything is the prompt.
        assert_eq!(prefill("claude --verbose -- --not-a-flag"), "claude --verbose --continue");
    }

    #[test]
    fn codex_resumes_last() {
        assert_eq!(prefill("codex -m o3 'hi'"), "codex resume --last -m o3");
        assert_eq!(prefill("codex"), "codex resume --last");
        assert_eq!(prefill("codex --sandbox workspace-write -a never fix"), "codex resume --last --sandbox workspace-write -a never");
        for c in ["codex resume --last", "codex resume abc"] {
            assert_eq!(prefill(c), c);
        }
    }

    #[test]
    fn quoted_words_stay_whole() {
        assert_eq!(prefill("claude --append-system-prompt 'be brief' 'go'"), "claude --append-system-prompt 'be brief' --continue");
        assert_eq!(prefill("claude a\\ b --verbose"), "claude --verbose --continue");
        assert_eq!(split("a 'b c' \"d e\"f g\\ h"), vec!["a", "'b c'", "\"d e\"f", "g\\ h"]);
    }

    #[test]
    fn others_unchanged() {
        for c in ["npm run dev", "python train.py --epochs 3", "", "vim 'a b'"] {
            assert_eq!(prefill(c), c);
        }
    }
}
