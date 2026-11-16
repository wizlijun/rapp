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
}
