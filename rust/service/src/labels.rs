//! Session labels (spec `2026-11-26-rapp-session-labels-design.md`): a title and a note the user gives a session on
//! this device, kept in `local/labels.json` so every client sees the same. Keyed by the session's `app` (a bundle id
//! or a terminal id). Asked for by B with `watch_labels` / `set_label` / `reset_label`, and by the local GUI over IPC
//! (`labels` / `set_label` / `reset_label`). Nothing of a label is ever logged.

use crate::peer::log_request;
use crate::state::{Peer, State};
use anyhow::Result;
use rapp_net::config::write_json;
use rapp_net::line::{err, ok, write_json as send};
use rapp_net::msg::Op;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::watch;

const FILE: &str = "labels.json";
/// Where an unreadable `labels.json` goes before the first write replaces it.
const BAD: &str = "labels.json.bad";
pub const TITLE_MAX: usize = 64;
pub const NOTE_MAX: usize = 200;
pub const LABELS_MAX: usize = 500;
/// The longest `app` key taken: a bundle id or a terminal id is far shorter.
const APP_MAX: usize = 256;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Label {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub note: String,
    /// When it was last changed (Unix seconds).
    #[serde(default)]
    pub at: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct Table {
    version: u32,
    rev: u64,
    labels: BTreeMap<String, Label>,
}

impl Default for Table {
    fn default() -> Table {
        Table { version: 1, rev: 0, labels: BTreeMap::new() }
    }
}

pub struct Labels {
    path: PathBuf,
    /// The table, and whether the file on disk is one `load` could not read (kept until the first write).
    table: Mutex<(Table, bool)>,
    /// The table's `rev`, for `watch_labels`.
    rev: watch::Sender<u64>,
}

/// A title as it is kept: one line, trimmed, at most `TITLE_MAX` characters; empty is allowed (the default title).
pub fn clean_title(s: &str) -> Result<String, String> {
    let t = s.trim();
    if t.chars().any(char::is_control) {
        return Err("标题只能是一行".into());
    }
    if t.chars().count() > TITLE_MAX {
        return Err(format!("标题最多 {TITLE_MAX} 个字"));
    }
    Ok(t.to_string())
}

/// A note as it is kept: line breaks and tabs become spaces, trimmed, at most `NOTE_MAX` characters.
pub fn clean_note(s: &str) -> Result<String, String> {
    let folded: String = s.chars().map(|c| if matches!(c, '\n' | '\r' | '\t') { ' ' } else { c }).collect();
    let t = folded.trim();
    if t.chars().any(char::is_control) {
        return Err("备注里有不能显示的字符".into());
    }
    if t.chars().count() > NOTE_MAX {
        return Err(format!("备注最多 {NOTE_MAX} 个字"));
    }
    Ok(t.to_string())
}

fn check_app(app: &str) -> Result<(), String> {
    if app.is_empty() || app.len() > APP_MAX || app.chars().any(char::is_control) {
        return Err("bad app".into());
    }
    Ok(())
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

impl Labels {
    /// `home` is the device's `local/`. A missing file is an empty table. So is an unreadable one; the second field
    /// then carries why, so the caller can log it. The file is left as it was until the first write, which first
    /// moves it to `labels.json.bad`.
    pub fn load(home: &Path) -> (Labels, Option<String>) {
        let path = home.join(FILE);
        let (table, why) = match std::fs::read(&path) {
            Ok(b) => match serde_json::from_slice::<Table>(&b) {
                Ok(t) => (t, None),
                Err(e) => (Table::default(), Some(e.to_string())),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (Table::default(), None),
            Err(e) => (Table::default(), Some(e.to_string())),
        };
        let bad = why.is_some();
        let rev = watch::channel(table.rev).0;
        (Labels { path, table: Mutex::new((table, bad)), rev }, why)
    }

    /// `{"rev": N, "labels": {app: {title, note, at}}}`.
    pub fn table(&self) -> Value {
        let t = &self.table.lock().unwrap().0;
        json!({"rev": t.rev, "labels": t.labels})
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.rev.subscribe()
    }

    /// Labels `app`; both empty (after cleaning) clears it. The table's new `rev`, or why not (in Chinese).
    pub fn set(&self, app: &str, title: &str, note: &str) -> Result<u64, String> {
        check_app(app)?;
        let (title, note) = (clean_title(title)?, clean_note(note)?);
        if title.is_empty() && note.is_empty() {
            return self.reset(app);
        }
        self.change(|labels| {
            if !labels.contains_key(app) && labels.len() >= LABELS_MAX {
                return Err(format!("标注已满 {LABELS_MAX} 条，先还原一些"));
            }
            let same = labels.get(app).is_some_and(|l| l.title == title && l.note == note);
            if !same {
                labels.insert(app.to_string(), Label { title, note, at: now() });
            }
            Ok(!same)
        })
    }

    /// Clears `app`'s label; none is not an error (the `rev` stays).
    pub fn reset(&self, app: &str) -> Result<u64, String> {
        check_app(app)?;
        self.change(|labels| Ok(labels.remove(app).is_some()))
    }

    /// Moves `from`'s label to `to` (a terminal opened again in its place); none is not an error.
    pub fn rename(&self, from: &str, to: &str) -> Result<u64, String> {
        check_app(to)?;
        self.change(|labels| match labels.remove(from) {
            Some(l) => {
                labels.insert(to.to_string(), Label { at: now(), ..l });
                Ok(true)
            }
            None => Ok(false),
        })
    }

    /// Applies `f` (true: it changed something) and, if it did, saves the table with the next `rev` and tells the
    /// watchers. Nothing changes when the save fails.
    fn change(&self, f: impl FnOnce(&mut BTreeMap<String, Label>) -> Result<bool, String>) -> Result<u64, String> {
        let mut guard = self.table.lock().unwrap();
        let mut next = guard.0.clone();
        if !f(&mut next.labels)? {
            return Ok(guard.0.rev);
        }
        next.rev += 1;
        if guard.1 {
            match std::fs::rename(&self.path, self.path.with_file_name(BAD)) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(format!("保存失败：{e}")),
                _ => guard.1 = false,
            }
        }
        write_json(&self.path, &next).map_err(|e| format!("保存失败：{e:#}"))?;
        let rev = next.rev;
        guard.0 = next;
        drop(guard);
        self.rev.send_replace(rev);
        Ok(rev)
    }
}

/// The IPC commands: `labels`, `set_label {app,title,note}`, `reset_label {app}`.
pub fn ipc(state: &State, cmd: &Value) -> Value {
    let app = cmd["app"].as_str().unwrap_or("");
    let r = match cmd["cmd"].as_str().unwrap_or("") {
        "labels" => return ok(state.labels.table()),
        "set_label" => state.labels.set(app, cmd["title"].as_str().unwrap_or(""), cmd["note"].as_str().unwrap_or("")),
        _ => state.labels.reset(app),
    };
    reply(state, r)
}

fn reply(state: &State, r: Result<u64, String>) -> Value {
    match r {
        Ok(rev) => {
            state.notify();
            ok(json!({"rev": rev}))
        }
        Err(e) => err(&e),
    }
}

/// The `request` line's fields: only the op, never the session, title or note.
fn log_fields(op: &Op) -> Value {
    match op {
        Op::WatchLabels => json!({"op": "watch_labels"}),
        Op::SetLabel { .. } => json!({"op": "set_label"}),
        Op::ResetLabel { .. } => json!({"op": "reset_label"}),
        _ => json!({}),
    }
}

/// One label request from B, logged as one `request` line.
pub async fn request<S: AsyncRead + AsyncWrite + Unpin + Send>(
    state: &Arc<State>,
    s: &mut S,
    peer: &Peer,
    op: Op,
) -> Result<()> {
    let what = log_fields(&op);
    let r = match op {
        Op::WatchLabels => return watch_labels(state, s, peer, what).await,
        Op::SetLabel { app, title, note } => reply(state, state.labels.set(&app, &title, &note)),
        Op::ResetLabel { app } => reply(state, state.labels.reset(&app)),
        _ => err("unknown op"),
    };
    log_request(state, peer, what, &r);
    send(s, &r).await?;
    s.shutdown().await?;
    Ok(())
}

/// The whole table now and after every change, until B closes the stream.
async fn watch_labels<S: AsyncRead + AsyncWrite + Unpin + Send>(
    state: &Arc<State>,
    s: &mut S,
    peer: &Peer,
    what: Value,
) -> Result<()> {
    let mut rev = state.labels.subscribe();
    rev.mark_unchanged();
    let first = ok(state.labels.table());
    log_request(state, peer, what, &first);
    send(s, &first).await?;
    let mut buf = [0u8; 256];
    loop {
        tokio::select! {
            // What B writes is ignored; its close ends the watch.
            n = s.read(&mut buf) => if !matches!(n, Ok(1..)) {
                break;
            },
            r = rev.changed() => {
                if r.is_err() || send(s, &ok(state.labels.table())).await.is_err() {
                    break;
                }
                rev.mark_unchanged();
            }
        }
    }
    let _ = s.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(d: &tempfile::TempDir) -> Labels {
        Labels::load(d.path()).0
    }

    fn get(l: &Labels, app: &str) -> Value {
        l.table()["labels"][app].clone()
    }

    #[test]
    fn missing_file_is_empty() {
        let d = tempfile::tempdir().unwrap();
        let (l, why) = Labels::load(d.path());
        assert!(why.is_none());
        assert_eq!(l.table(), json!({"rev": 0, "labels": {}}));
    }

    #[test]
    fn set_saves_and_load_reads_back() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        assert_eq!(l.set("term:pty:k", " 后端 API ", "改 hub").unwrap(), 1);
        let again = labels(&d);
        assert_eq!(get(&again, "term:pty:k")["title"], "后端 API");
        assert_eq!(get(&again, "term:pty:k")["note"], "改 hub");
        assert_eq!(again.table()["rev"], 1);
        let file: Value = serde_json::from_slice(&std::fs::read(d.path().join(FILE)).unwrap()).unwrap();
        assert_eq!(file["version"], 1);
    }

    #[test]
    fn both_empty_is_reset() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        l.set("a", "t", "").unwrap();
        assert_eq!(l.set("a", "  ", "\n").unwrap(), 2);
        assert!(get(&l, "a").is_null());
    }

    #[test]
    fn rev_goes_up_by_one_per_change_and_not_for_the_same() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        assert_eq!(l.set("a", "t", "").unwrap(), 1);
        assert_eq!(l.set("b", "", "n").unwrap(), 2);
        assert_eq!(l.set("b", "", "n").unwrap(), 2);
        assert_eq!(l.reset("a").unwrap(), 3);
    }

    #[test]
    fn reset_of_nothing_keeps_rev() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        assert_eq!(l.reset("a").unwrap(), 0);
        assert!(!d.path().join(FILE).exists());
    }

    #[test]
    fn title_rule() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        assert!(l.set("a", &"后".repeat(64), "").is_ok());
        assert_eq!(l.set("a", &"后".repeat(65), "").unwrap_err(), "标题最多 64 个字");
        assert_eq!(l.set("a", "两\n行", "").unwrap_err(), "标题只能是一行");
        assert_eq!(get(&l, "a")["title"], "后".repeat(64));
    }

    #[test]
    fn note_newlines_fold_to_spaces() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        l.set("a", "", "第一\n第二\r\n").unwrap();
        assert_eq!(get(&l, "a")["note"], "第一 第二");
    }

    #[test]
    fn note_over_200_refused() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        assert!(l.set("a", "", &"x".repeat(200)).is_ok());
        assert_eq!(l.set("a", "", &"x".repeat(201)).unwrap_err(), "备注最多 200 个字");
    }

    #[test]
    fn five_hundred_and_first_refused_but_edit_of_existing_ok() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        for i in 0..LABELS_MAX {
            l.change(|m| {
                m.insert(format!("app{i}"), Label { title: "t".into(), ..Label::default() });
                Ok(true)
            })
            .unwrap();
        }
        assert!(l.set("one-more", "t", "").unwrap_err().contains("500"));
        assert!(l.set("app1", "new", "").is_ok());
    }

    #[test]
    fn unreadable_file_moves_to_bad_on_first_write() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join(FILE), b"{not json").unwrap();
        let (l, why) = Labels::load(d.path());
        assert!(why.is_some());
        assert_eq!(l.table()["labels"], json!({}));
        l.set("a", "t", "").unwrap();
        assert_eq!(std::fs::read(d.path().join(BAD)).unwrap(), b"{not json");
        assert_eq!(get(&labels(&d), "a")["title"], "t");
    }

    #[test]
    fn rename_moves_the_label() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        l.set("term:pty:old", "后端", "n").unwrap();
        assert_eq!(l.rename("term:pty:old", "term:pty:new").unwrap(), 2);
        assert!(get(&l, "term:pty:old").is_null());
        assert_eq!(get(&l, "term:pty:new")["title"], "后端");
        assert_eq!(l.rename("term:pty:gone", "term:pty:x").unwrap(), 2);
    }

    #[test]
    fn bad_app_is_refused() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        assert!(l.set("", "t", "").is_err());
        assert!(l.set(&"a".repeat(300), "t", "").is_err());
    }

    #[test]
    fn a_change_wakes_the_watchers() {
        let d = tempfile::tempdir().unwrap();
        let l = labels(&d);
        let mut rx = l.subscribe();
        rx.mark_unchanged();
        l.set("a", "t", "").unwrap();
        assert!(rx.has_changed().unwrap());
        assert_eq!(*rx.borrow_and_update(), 1);
    }

    #[test]
    fn log_fields_carry_only_the_op() {
        let set = Op::SetLabel { app: "term:pty:secret".into(), title: "机密".into(), note: "备注".into() };
        assert_eq!(log_fields(&set), json!({"op": "set_label"}));
        assert_eq!(log_fields(&Op::ResetLabel { app: "term:pty:secret".into() }), json!({"op": "reset_label"}));
        assert_eq!(log_fields(&Op::WatchLabels), json!({"op": "watch_labels"}));
    }
}
