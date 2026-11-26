//! What the platform answers about opening a session (spec §6.1). Task 9 creates this file
//! with these two types only; Task 13 adds the platform traits.

/// Why a session cannot show a screen, or the app it asked for is missing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenError {
    /// No display is attached.
    NoDisplay,
    /// The owner's desktop is not on this machine's screen (disconnected remote session, or switched away).
    SessionDisconnected,
    /// No signed-in desktop.
    NotInteractive,
    /// Someone other than the owner is signed in on this machine's screen.
    OtherUser,
    /// The app id given is not installed.
    NotFound(String),
    /// Any other failure, as text.
    Other(String),
}

impl OpenError {
    /// The fixed text the client and service match on (spec §6.1). `NotFound` is spec §6.4's
    /// `<id> not found`, not the Swift host's "no app with bundle id … is installed"
    /// (`Sources/rapp-host/WindowCapture.swift:55`), which plan B names; see the draft notes.
    pub fn reason(&self) -> String {
        match self {
            OpenError::NoDisplay => "no display".to_string(),
            OpenError::SessionDisconnected => "session disconnected".to_string(),
            OpenError::NotInteractive => "not interactive".to_string(),
            OpenError::OtherUser => "other user".to_string(),
            OpenError::NotFound(app) => format!("{app} not found"),
            OpenError::Other(text) => text.clone(),
        }
    }
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.reason())
    }
}

impl std::error::Error for OpenError {}

/// What `check` and `list-apps` report (spec §6.1): `screen_recording` is whether a picture can
/// be shown, `accessibility` is always true on Windows, `applications` is whether single-app
/// sessions can be opened (false for the pre-login instance), `error` the reason no picture can be shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permissions {
    pub screen_recording: bool,
    pub accessibility: bool,
    pub platform: String,
    pub applications: bool,
    pub error: Option<OpenError>,
}
