//! Every external program the update goes through, behind one trait so tests can fake them.

use std::io;
use std::path::Path;
use std::process::{Command, Stdio};

pub const CURL: &str = "/usr/bin/curl";
pub const DITTO: &str = "/usr/bin/ditto";
pub const CODESIGN: &str = "/usr/bin/codesign";
pub const PLUTIL: &str = "/usr/bin/plutil";
pub const TCCUTIL: &str = "/usr/bin/tccutil";
pub const OPEN: &str = "/usr/bin/open";
pub const PS: &str = "/bin/ps";
pub const DF: &str = "/bin/df";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Out {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Out {
    pub fn ok(stdout: impl Into<String>) -> Self {
        Out { code: 0, stdout: stdout.into(), stderr: String::new() }
    }

    pub fn fail(code: i32, stderr: impl Into<String>) -> Self {
        Out { code, stdout: String::new(), stderr: stderr.into() }
    }
}

pub trait Runner: Send + Sync {
    fn run(&self, prog: &str, args: &[String]) -> io::Result<Out>;

    fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
        std::fs::rename(from, to)
    }
}

/// Runs the real programs, stdin closed. A signal-killed child reports code -1.
pub struct SystemRunner;

impl Runner for SystemRunner {
    fn run(&self, prog: &str, args: &[String]) -> io::Result<Out> {
        let o = Command::new(prog).args(args).stdin(Stdio::null()).output()?;
        Ok(Out {
            code: o.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
        })
    }
}
