//! The session table row: one per terminal session, for the list and the watch stream.

use serde::Serialize;

/// One session as the list shows it.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct TermRow {
    pub id: String,
    pub host: Option<String>,
    pub name: String,
    pub command: String,
    pub panes: usize,
    pub attached: u32,
    pub activity: u64,
    pub dead: bool,
    pub unread: bool,
    /// What the program says about itself (OSC 7501); none when it says nothing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ps: Option<crate::pty::ps::Ps>,
    /// The title the program set (OSC 0/1/2); none when it set none or the session was named by hand.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// The foreground program's name; none when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fg: Option<String>,
    /// Whether the foreground program is the shell the holder started; none when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell: Option<bool>,
    /// Whether the session takes a reply with no view open; false for a run that predates it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub reply: bool,
}
