//! Opening a terminal window on this machine that runs `rapp-term run`: the `.command` file, which terminal
//! programs there are, and how the file is handed to one.

use anyhow::{bail, Context};
use std::path::Path;
use std::process::{Command, Stdio};

/// `s` in single quotes for `sh`.
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The content of a `.command` file that runs `bin run` in `dir` for `ticket`, with `shell` as a login shell.
pub fn command_file(bin: &Path, dir: &Path, ticket: &str, shell: &str) -> String {
    format!(
        "#!/bin/sh\nexec {} run --dir {} --ticket {} -- {} -l\n",
        quote(&bin.to_string_lossy()),
        quote(&dir.to_string_lossy()),
        quote(ticket),
        quote(shell)
    )
}

/// The terminal programs this machine can open a window with: on macOS Terminal, and iTerm when it is installed.
pub fn launchers() -> Vec<String> {
    if !cfg!(target_os = "macos") {
        return Vec::new();
    }
    let mut v = vec!["Terminal".to_string()];
    let iterm = Command::new("open")
        .args(["-Ra", "iTerm"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if iterm.is_ok_and(|s| s.success()) {
        v.push("iTerm".into());
    }
    v
}

/// Open `file` with the terminal program `app`; or, for tests, run `launch_with app file`.
pub fn open(app: &str, file: &Path, launch_with: Option<&Path>) -> anyhow::Result<()> {
    let mut c = match launch_with {
        Some(p) => {
            let mut c = Command::new(p);
            c.arg(app).arg(file);
            c
        }
        None => {
            let mut c = Command::new("open");
            c.arg("-a").arg(app).arg(file);
            c
        }
    };
    let status = c
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("cannot start the program that opens the window")?;
    if !status.success() {
        bail!("the program that opens the window failed");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_command_file_runs_the_shell_as_a_login_shell() {
        let f = command_file(Path::new("/A pp/rapp-term"), Path::new("/r/local/term"), "t1", "/opt/my shells/fish");
        assert_eq!(
            f,
            "#!/bin/sh\nexec '/A pp/rapp-term' run --dir '/r/local/term' --ticket 't1' -- '/opt/my shells/fish' -l\n"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_always_has_terminal() {
        assert_eq!(launchers()[0], "Terminal");
    }
}
