//! Every tmux command rapp sends is built here, and only from the allowed verbs.

use crate::runner::sh_quote;

/// The only tmux commands rapp ever sends.
pub const VERBS: &[&str] = &[
    "list-panes",
    "capture-pane",
    "display-message",
    "send-keys",
    "load-buffer",
    "paste-buffer",
    "new-session",
    "refresh-client",
    "attach-session",
];

/// Format fields of one pane row, tab separated; `parse::panes` reads them in this order.
const PANE_FORMAT: &str = "#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_id}\t\
#{pane_index}\t#{pane_current_command}\t#{pane_dead}\t#{window_activity}\t#{session_attached}\t#{pane_width}\t\
#{pane_height}\t#{pane_title}";

/// Every pane of every session.
pub fn list_panes() -> Vec<String> {
    ["list-panes", "-a", "-F", PANE_FORMAT].map(String::from).to_vec()
}

/// Which window is current in its session: `<window_active> <window_id>` for every pane; `parse::current_windows`
/// reads it.
pub fn window_flags() -> Vec<String> {
    ["list-panes", "-a", "-F", "#{window_active} #{window_id}"].map(String::from).to_vec()
}

/// The visible screen of `pane`, with colour escapes.
pub fn capture(pane: &str) -> Vec<String> {
    ["capture-pane", "-e", "-p", "-t", pane].map(String::from).to_vec()
}

/// Cursor, alternate-screen flag and size of `pane`, space separated; `Screen::from_capture` reads it.
pub fn meta(pane: &str) -> Vec<String> {
    let f = "#{cursor_x} #{cursor_y} #{cursor_flag} #{alternate_on} #{pane_width} #{pane_height}";
    ["display-message", "-p", "-t", pane, f].map(String::from).to_vec()
}

/// How many rows of scrollback `pane` holds.
pub fn history_size(pane: &str) -> Vec<String> {
    ["display-message", "-p", "-t", pane, "#{history_size}"].map(String::from).to_vec()
}

/// `lines` rows of scrollback ending `before` rows above the visible screen.
pub fn history(pane: &str, before: u32, lines: u32) -> Vec<String> {
    let start = format!("-{}", before as u64 + lines as u64);
    let end = format!("-{}", before as u64 + 1);
    ["capture-pane", "-e", "-p", "-t", pane, "-S", &start, "-E", &end].map(String::from).to_vec()
}

/// Send named keys (tmux key names) to `pane`.
pub fn send_named(pane: &str, names: &[String]) -> Vec<String> {
    let mut v: Vec<String> = ["send-keys", "-t", pane].map(String::from).to_vec();
    v.extend(names.iter().cloned());
    v
}

/// Send raw bytes, each given as two hex digits, to `pane`.
pub fn send_hex(pane: &str, hex: &[String]) -> Vec<String> {
    let mut v: Vec<String> = ["send-keys", "-t", pane, "-H"].map(String::from).to_vec();
    v.extend(hex.iter().cloned());
    v
}

/// Load the named paste buffer from stdin.
pub fn load_buffer(name: &str) -> Vec<String> {
    ["load-buffer", "-b", name, "-"].map(String::from).to_vec()
}

/// Paste the named buffer into `pane` as a bracketed paste and delete the buffer.
pub fn paste_buffer(name: &str, pane: &str) -> Vec<String> {
    ["paste-buffer", "-p", "-d", "-b", name, "-t", pane].map(String::from).to_vec()
}

/// A control-mode client of the session `session_id`.
pub fn attach(session_id: &str) -> Vec<String> {
    ["-C", "attach-session", "-t", session_id].map(String::from).to_vec()
}

/// Set this control client's size.
pub fn set_size(cols: u16, rows: u16) -> Vec<String> {
    vec!["refresh-client".into(), "-C".into(), format!("{cols}x{rows}")]
}

/// A detached session running `command` (none: the default shell). The words go to tmux as one argument, each in
/// single quotes, which tmux hands to the shell: as separate arguments tmux would read an argument ending in `;` as
/// the start of another tmux command, and a first word like `-c` as one of its own options.
pub fn new_session(name: &str, cols: u16, rows: u16, command: &[String]) -> Vec<String> {
    let mut v: Vec<String> =
        ["new-session", "-d", "-s", name, "-x", &cols.to_string(), "-y", &rows.to_string()].map(String::from).to_vec();
    if !command.is_empty() {
        v.push("--".into());
        v.push(command.iter().map(|w| sh_quote(w)).collect::<Vec<_>>().join(" "));
    }
    v
}

/// One command as a line for a control-mode channel: each argument in single quotes.
pub fn channel_line(args: &[String]) -> anyhow::Result<String> {
    if args.iter().any(|a| a.contains(['\'', '\n', '\r'])) {
        anyhow::bail!("argument cannot be quoted for the control channel");
    }
    Ok(args.iter().map(|a| sh_quote(a)).collect::<Vec<_>>().join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_builder_uses_an_allowed_verb() {
        assert_eq!(
            VERBS,
            [
                "list-panes",
                "capture-pane",
                "display-message",
                "send-keys",
                "load-buffer",
                "paste-buffer",
                "new-session",
                "refresh-client",
                "attach-session"
            ]
        );
        assert_eq!(list_panes()[0], "list-panes");
        assert_eq!(window_flags(), ["list-panes", "-a", "-F", "#{window_active} #{window_id}"]);
        assert_eq!(attach("$3"), ["-C", "attach-session", "-t", "$3"]);
    }
    #[test]
    fn input_builders() {
        assert_eq!(send_named("%1", &["Enter".into()]), ["send-keys", "-t", "%1", "Enter"]);
        assert_eq!(send_hex("%1", &["61".into()]), ["send-keys", "-t", "%1", "-H", "61"]);
        assert_eq!(load_buffer("rapp-1-0"), ["load-buffer", "-b", "rapp-1-0", "-"]);
        assert_eq!(paste_buffer("rapp-1-0", "%1"), ["paste-buffer", "-p", "-d", "-b", "rapp-1-0", "-t", "%1"]);
    }
    #[test]
    fn size_and_new_session_builders() {
        assert_eq!(set_size(140, 45), ["refresh-client", "-C", "140x45"]);
        assert_eq!(
            new_session("a b", 118, 38, &["sh".into(), "-c".into(), "echo hi".into()]),
            ["new-session", "-d", "-s", "a b", "-x", "118", "-y", "38", "--", "'sh' '-c' 'echo hi'"]
        );
        assert_eq!(new_session("n", 80, 24, &[]).len(), 8);
    }
    #[test]
    fn a_new_sessions_command_is_one_shell_string_tmux_cannot_split_or_read_as_options() {
        // tmux takes an argument ending in `;` as a command separator and a leading `-x` as an option of its own.
        let v = new_session("g", 80, 24, &["-c".into(), "it's".into(), ";".into(), "rename-session".into()]);
        assert_eq!(v[8..], ["--", r"'-c' 'it'\''s' ';' 'rename-session'"]);
        assert!(!v.iter().any(|a| a == ";" || a.ends_with(';')));
    }
    #[test]
    fn history_range_counts_up_from_the_screen() {
        assert_eq!(history("%1", 0, 10)[5..], ["-S", "-10", "-E", "-1"].map(String::from)[..]);
        assert_eq!(history("%1", 20, 10)[5..], ["-S", "-30", "-E", "-21"].map(String::from)[..]);
    }
    #[test]
    fn channel_line_quotes_and_refuses_what_it_cannot_quote() {
        assert_eq!(
            channel_line(&["display-message".into(), "-p".into(), "#{cursor_x} #{cursor_y}".into()]).unwrap(),
            "'display-message' '-p' '#{cursor_x} #{cursor_y}'"
        );
        assert!(channel_line(&["send-keys".into(), "it's".into()]).is_err());
        assert!(channel_line(&["send-keys".into(), "a\nb".into()]).is_err());
    }
}
