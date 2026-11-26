//! Session steps that later tasks of plan B fill in. Each task moves its items out of this
//! file into its own module and deletes them here; Task 17 deletes the file.
//!
//! What stays until then: the session answers hello, ping and the window table, and drops
//! the commands below without acting on them.

use crate::protocol::Password;

use super::session::Session;

impl Session {
    // Task 17: unlock.
    pub(crate) fn unlock(&mut self, _password: Password) {}
}
