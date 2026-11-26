//! Starting a program (spec §8.2 rule 1): on Windows without a console window, so a service that
//! has no window never flashes one. Elsewhere exactly `Command::new`.

use std::ffi::OsStr;

/// `CREATE_NO_WINDOW`.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// `Command::new(program)`; on Windows also "no console window" (`CREATE_NO_WINDOW`).
pub fn command(program: impl AsRef<OsStr>) -> std::process::Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let mut c = std::process::Command::new(program);
        c.creation_flags(CREATE_NO_WINDOW);
        c
    }
    #[cfg(not(windows))]
    {
        std::process::Command::new(program)
    }
}

/// `tokio::process::Command::new(program)` with the same flags as `command`.
pub fn tokio_command(program: impl AsRef<OsStr>) -> tokio::process::Command {
    // `tokio::process::Command::new` is exactly this conversion of a `std` command.
    tokio::process::Command::from(command(program))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn child_has_no_console() {
        // The test binary runs only `probe` in a child started through `command`.
        let me = std::env::current_exe().unwrap();
        let out = command(me)
            .args(["--exact", "proc::tests::probe", "--nocapture", "--test-threads=1"])
            .env("RAPP_PROC_PROBE", "1")
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{stdout}");
        assert!(stdout.contains("console=false"), "{stdout}");
    }

    /// Not a test of its own: prints what `child_has_no_console` looks for when it is the child.
    #[cfg(windows)]
    #[test]
    fn probe() {
        if std::env::var_os("RAPP_PROC_PROBE").is_some() {
            println!("console={}", crate::win::has_console());
        }
    }

    #[test]
    fn tokio_command_keeps_program_and_arguments() {
        let mut c = tokio_command("rapp-zz-test");
        c.arg("a");
        assert_eq!(c.as_std().get_program(), "rapp-zz-test");
        assert_eq!(c.as_std().get_args().collect::<Vec<_>>(), ["a"]);
    }
}
