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
