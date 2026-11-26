//! How a command ends (cli-update §5.4): one JSON object on stdout with `--json`, otherwise the
//! result on stdout and progress and errors on stderr; the exit code says which.

use serde_json::{json, Value};
use std::io::Write;

/// The exit code for an `error` code; unknown codes are a plain failure.
pub fn exit_code(error: &str) -> i32 {
    match error {
        "usage" => 2,
        "not_running" => 3,
        "offline" | "no_device" => 4,
        "timeout" => 5,
        "needs_confirm" => 6,
        "needs_admin" | "not_launchd" | "needs_reinstall" => 7,
        _ => 1,
    }
}

/// The JSON object a failure prints with `--json`.
pub fn error_json(code: &str, message: &str, page: Option<&str>) -> Value {
    json!({"ok": false, "error": code, "message": message, "page": page})
}

#[derive(Clone, Copy)]
pub struct Out {
    pub json: bool,
}

impl Out {
    /// A step on the way, for people watching (stderr); nothing with `--json`.
    pub fn progress(&self, line: &str) {
        if !self.json {
            eprintln!("{line}");
        }
    }

    /// Success: `{"ok":true,..v}` with `--json`, otherwise `line`.
    pub fn ok(&self, v: Value, line: &str) -> ! {
        if self.json {
            let mut o = json!({"ok": true});
            if let Value::Object(m) = v {
                o.as_object_mut().unwrap().extend(m);
            }
            println!("{o}");
        } else {
            println!("{line}");
        }
        let _ = std::io::stdout().flush();
        std::process::exit(0)
    }

    pub fn fail(&self, code: &str, message: &str, page: Option<&str>) -> ! {
        if self.json {
            println!("{}", error_json(code, message, page));
            let _ = std::io::stdout().flush();
        } else {
            match page {
                Some(p) => eprintln!("{message}\n{p}"),
                None => eprintln!("{message}"),
            }
        }
        std::process::exit(exit_code(code))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_map_to_exits() {
        for (code, n) in [
            ("failed", 1),
            ("busy", 1),
            ("still_open", 1),
            ("nothing_to_install", 1),
            ("no_previous", 1),
            ("usage", 2),
            ("not_running", 3),
            ("offline", 4),
            ("no_device", 4),
            ("timeout", 5),
            ("needs_confirm", 6),
            ("needs_admin", 7),
            ("not_launchd", 7),
            ("needs_reinstall", 7),
            ("whatever", 1),
        ] {
            assert_eq!(exit_code(code), n, "{code}");
        }
    }

    #[test]
    fn error_object_shape() {
        assert_eq!(
            error_json("timeout", "等了 1 秒还没好", None),
            json!({"ok": false, "error": "timeout", "message": "等了 1 秒还没好", "page": null})
        );
    }
}
