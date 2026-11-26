//! Locking A's screen and typing the unlock password (`Sources/RappCore/ScreenLock.swift`).
//! Task 9 needs `LockOutcome` for `cli::lock_json`; Task 11 fills in the rest.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockOutcome {
    Locked,
    Already,
    Failed(String),
}
