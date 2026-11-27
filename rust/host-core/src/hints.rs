//! Host hints of protocol v13: `covered`, `appOpened`, `secureFocus`
//! (`Sources/RappCore/HostHints.swift`).

use crate::geometry::Point;
use crate::protocol::{Message, MouseKind};
use std::collections::HashMap;

/// What the host remembers of the `covered` notices it sent: one per covering owner per few
/// seconds, and where each dismissable one was, so a `dismissCover` acts only on a window
/// this session reported.
#[derive(Debug, Clone)]
pub struct CoverNotices {
    pub every: f64,
    sent_at: HashMap<i32, f64>,
    points: HashMap<i32, Point>,
}

impl Default for CoverNotices {
    fn default() -> Self {
        CoverNotices::new(5.0)
    }
}

impl CoverNotices {
    pub fn new(every: f64) -> Self {
        CoverNotices { every, sent_at: HashMap::new(), points: HashMap::new() }
    }

    /// Whether a notice for `pid` goes now; true records it as sent.
    pub fn should_send(&mut self, pid: i32, now: f64) -> bool {
        if let Some(last) = self.sent_at.get(&pid) {
            if now - last < self.every {
                return false;
            }
        }
        self.sent_at.insert(pid, now);
        true
    }

    /// The notice for `pid` went, about a press at `point`; only a dismissable one can be dismissed.
    pub fn reported(&mut self, pid: i32, dismissable: bool, point: Point) {
        if dismissable {
            self.points.insert(pid, point);
        } else {
            self.points.remove(&pid);
        }
    }

    /// Where the dismissable cover of `pid` was pressed; `None` when none was reported.
    pub fn dismiss_point(&self, pid: i32) -> Option<Point> {
        self.points.get(&pid).copied()
    }

    pub fn forget(&mut self, pid: i32) {
        self.points.remove(&pid);
    }
}

/// System prompts the host never closes for B.
const PROTECTED_COVERS: [&str; 8] = [
    "com.apple.securityagent",
    "com.apple.loginwindow",
    "com.apple.coreservices.uiagent",
    "com.apple.usernotificationcenter",
    "com.apple.localauthentication.uiagent",
    "com.apple.accessibility.universalaccessauthwarn",
    "com.apple.coreauthui",
    "com.apple.screensaver.engine",
];

/// Words in a bundle id that mark it as a prompt the host must not close, whoever made it.
const PROTECTED_WORDS: [&str; 7] = ["security", "auth", "password", "keychain", "login", "permission", "privacy"];

/// Whether the host may close a covering window of this owner on B's request: a
/// notification banner, or an ordinary window of a regular app (HostHints.swift).
pub fn cover_dismissable(bundle_id: Option<&str>, regular: bool) -> bool {
    let Some(id) = bundle_id.map(|b| b.to_lowercase()) else { return false };
    if id.is_empty() {
        return false;
    }
    if PROTECTED_COVERS.contains(&id.as_str()) || PROTECTED_WORDS.iter().any(|w| id.contains(w)) {
        return false;
    }
    if id == "com.apple.notificationcenterui" {
        return true;
    }
    regular
}

/// How soon after this session's input another app's activation is taken for one the input opened.
pub const APP_OPENED_WINDOW: f64 = 2.0;

/// Processes that come to the front without being "an app the click opened".
const NOT_OPENED_APPS: [&str; 10] = [
    "com.rapp.rapp",
    "com.apple.dock",
    "com.apple.loginwindow",
    "com.apple.systemuiserver",
    "com.apple.securityagent",
    "com.apple.notificationcenterui",
    "com.apple.controlcenter",
    "com.apple.spotlight",
    "com.apple.coreservices.uiagent",
    "com.apple.windowmanager",
];

/// Whether an activation is worth an `appOpened`: another regular app came to the front
/// within `APP_OPENED_WINDOW` of this session's last input (`since_input`, None when none).
pub fn app_opened_worth_telling(
    bundle_id: Option<&str>,
    pid: i32,
    regular: bool,
    session_pid: i32,
    own_pid: i32,
    since_input: Option<f64>,
) -> bool {
    if !regular || pid == session_pid || pid == own_pid {
        return false;
    }
    let Some(id) = bundle_id else { return false };
    if id.is_empty() || NOT_OPENED_APPS.contains(&id.to_lowercase().as_str()) {
        return false;
    }
    let Some(since) = since_input else { return false };
    (0.0..=APP_OPENED_WINDOW).contains(&since)
}

/// Whether a focused element is a password field. Only its role and subrole are looked at,
/// never its contents.
pub fn is_secure_field(_role: Option<&str>, subrole: Option<&str>) -> bool {
    subrole == Some("AXSecureTextField")
}

/// Input that may open another app on A (a click, a typed shortcut, Return): the clock for
/// `appOpened` starts from it. Hovering, dragging and scrolling never do (`Message.opensThings`).
pub fn opens_things(message: &Message) -> bool {
    match message {
        Message::Text(_) => true,
        Message::Key { down, .. } => *down,
        Message::Mouse { kind, .. } => matches!(kind, MouseKind::Down | MouseKind::Up),
        _ => false,
    }
}
