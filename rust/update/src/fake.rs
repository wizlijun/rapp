//! A scripted `Runner` for tests (this crate's and testkit's). Programs that were not
//! scripted fail with `NotFound`; renames are real unless told to fail.

use crate::runner::{Out, Runner};
use std::collections::HashMap;
use std::io;
use std::path::Path;
use std::sync::Mutex;

type Handler = Box<dyn Fn(&[String]) -> Out + Send + Sync>;

#[derive(Default)]
pub struct FakeRunner {
    handlers: HashMap<String, Handler>,
    calls: Mutex<Vec<(String, Vec<String>)>>,
    renames: Mutex<usize>,
    rename_failures: Mutex<Vec<(usize, io::Error)>>,
}

impl FakeRunner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Script `prog`. The handler may touch the filesystem, e.g. a fake curl writing its `-o` file.
    pub fn on(mut self, prog: &str, f: impl Fn(&[String]) -> Out + Send + Sync + 'static) -> Self {
        self.handlers.insert(prog.to_string(), Box::new(f));
        self
    }

    /// The `nth` rename (counting from 1) fails with `err` instead of renaming.
    pub fn rename_fails(self, nth: usize, err: io::Error) -> Self {
        self.rename_failures.lock().unwrap().push((nth, err));
        self
    }

    pub fn calls(&self) -> Vec<(String, Vec<String>)> {
        self.calls.lock().unwrap().clone()
    }
}

impl Runner for FakeRunner {
    fn run(&self, prog: &str, args: &[String]) -> io::Result<Out> {
        self.calls.lock().unwrap().push((prog.to_string(), args.to_vec()));
        match self.handlers.get(prog) {
            Some(f) => Ok(f(args)),
            None => Err(io::Error::from(io::ErrorKind::NotFound)),
        }
    }

    fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
        let n = {
            let mut c = self.renames.lock().unwrap();
            *c += 1;
            *c
        };
        let mut failures = self.rename_failures.lock().unwrap();
        if let Some(i) = failures.iter().position(|(k, _)| *k == n) {
            return Err(failures.remove(i).1);
        }
        drop(failures);
        std::fs::rename(from, to)
    }
}

/// The argument right after `flag`.
pub fn arg_after<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let i = args.iter().position(|a| a == flag)?;
    args.get(i + 1).map(String::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unscripted_program_is_not_found_and_calls_are_recorded() {
        let r = FakeRunner::new().on("/bin/echo", |a| Out::ok(a.join(" ")));
        let e = r.run("/bin/nope", &[]).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::NotFound);
        assert_eq!(r.run("/bin/echo", &["a".into(), "b".into()]).unwrap(), Out::ok("a b"));
        assert_eq!(r.calls().len(), 2);
        assert_eq!(r.calls()[1], ("/bin/echo".to_string(), vec!["a".to_string(), "b".to_string()]));
    }

    #[test]
    fn nth_rename_fails_others_are_real() {
        let d = tempfile::tempdir().unwrap();
        let (a, b, c) = (d.path().join("a"), d.path().join("b"), d.path().join("c"));
        std::fs::write(&a, "x").unwrap();
        let r = FakeRunner::new().rename_fails(2, io::Error::from(io::ErrorKind::PermissionDenied));
        r.rename(&a, &b).unwrap();
        assert_eq!(r.rename(&b, &c).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert!(b.exists());
        r.rename(&b, &c).unwrap();
        assert!(c.exists());
    }

    #[test]
    fn arg_after_finds_value() {
        let a: Vec<String> = ["-o", "/x", "-C", "-"].iter().map(|s| s.to_string()).collect();
        assert_eq!(arg_after(&a, "-o"), Some("/x"));
        assert_eq!(arg_after(&a, "-C"), Some("-"));
        assert_eq!(arg_after(&a, "-"), None);
        assert_eq!(arg_after(&a, "-z"), None);
    }
}
