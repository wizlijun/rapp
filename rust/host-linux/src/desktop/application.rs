use anyhow::{ensure, Context, Result};
use rapp_client_core::protocol::Window;
use serde_json::{json, Value};

/// PID plus Linux process start time prevents a re-used PID changing the shared app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Application {
    pub pid: u32,
    start: u64,
}
impl Application {
    pub fn current(pid: u32) -> Result<Self> {
        ensure!(pid != 0, "invalid application PID");
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
        let tail = stat.rsplit_once(')').context("invalid process status")?.1;
        let start = tail
            .split_whitespace()
            .nth(19)
            .context("missing process start time")?
            .parse()?;
        Ok(Self { pid, start })
    }
    pub fn parse(app: &str) -> Result<Self> {
        let (pid, start) = app
            .strip_prefix("linux:")
            .context("unknown application")?
            .split_once(':')
            .context("invalid application identifier")?;
        let result = Self {
            pid: pid.parse()?,
            start: start.parse()?,
        };
        result.check()?;
        Ok(result)
    }
    pub fn check(&self) -> Result<()> {
        ensure!(Self::current(self.pid)? == *self, "application exited");
        Ok(())
    }
    pub fn id(&self) -> String {
        format!("linux:{}:{}", self.pid, self.start)
    }
    pub fn dismissable(&self) -> bool {
        use std::os::unix::fs::MetadataExt;
        let path = format!("/proc/{}", self.pid);
        if !std::fs::metadata(&path).is_ok_and(|m| m.uid() == unsafe { libc::getuid() }) {
            return false;
        }
        let Ok(exe) = std::fs::read_link(format!("{path}/exe")) else {
            return false;
        };
        let Some(name) = exe.file_name().and_then(|s| s.to_str()) else {
            return false;
        };
        let name = name.to_ascii_lowercase();
        ![
            "security",
            "auth",
            "password",
            "keychain",
            "keyring",
            "login",
            "permission",
            "privacy",
            "polkit",
            "pinentry",
            "lock",
        ]
        .iter()
        .any(|word| name.contains(word))
            && !["gnome-shell", "plasmashell", "kded6", "gdm", "sddm-greeter"]
                .contains(&name.as_str())
    }
}
#[derive(Clone)]
pub struct NativeWindow {
    pub window: Window,
    pub pid: u32,
    pub name: String,
    pub native_id: u64,
}
pub fn applications(windows: &[NativeWindow]) -> Vec<Value> {
    let mut seen = std::collections::HashSet::new();
    windows
        .iter()
        .filter_map(|window| {
            if !seen.insert(window.pid) {
                return None;
            }
            let app = Application::current(window.pid).ok()?;
            Some(json!({"app":app.id(), "name":window.name, "pid":app.pid}))
        })
        .collect()
}
