//! Windows: `rapp` with no subcommand (or `--cm`, `--background`) starts the interface, `rapp-gui.exe` (spec §5.1).
//! The interface sits beside this program in its version directory; a `rapp.exe` outside one (the `bin` directory
//! on PATH) finds it through `<install>\current`, which names the version directory. Pure functions, tested
//! everywhere, only called on Windows.

use std::path::{Path, PathBuf};

/// The interface's file name.
const GUI: &str = "rapp-gui.exe";
/// What every version directory's name starts with.
const PREFIX: &str = "app-";

/// `Some(args for the interface)` when `argv` is empty or its first word is `--cm` or `--background`.
pub fn launch_args(argv: &[String]) -> Option<Vec<String>> {
    match argv.first().map(String::as_str) {
        None => Some(Vec::new()),
        Some("--cm" | "--background") => Some(argv.to_vec()),
        Some(_) => None,
    }
}

/// The version directory name written in `current`, or None when the text is not exactly one
/// directory name starting with `app-`.
pub fn version_dir_name(current_text: &str) -> Option<&str> {
    let t = current_text.strip_prefix('\u{feff}').unwrap_or(current_text).trim();
    let one_name = !t.contains("..") && !t.chars().any(|c| matches!(c, '\\' | '/' | ':') || c.is_control());
    (one_name && t.len() > PREFIX.len() && t.starts_with(PREFIX)).then_some(t)
}

/// Where `rapp-gui.exe` is: beside `own_exe` if it exists there, else `<own dir>\..\<current>\rapp-gui.exe`.
/// `exists` and `read` are the file system, passed in for tests.
pub fn gui_exe(own_exe: &Path, exists: &dyn Fn(&Path) -> bool, read: &dyn Fn(&Path) -> Option<String>) -> Result<PathBuf, PathBuf> {
    let dir = own_exe.parent().unwrap_or(Path::new(""));
    let beside = dir.join(GUI);
    if exists(&beside) {
        return Ok(beside);
    }
    let inst = dir.parent().unwrap_or(dir);
    let current = inst.join("current");
    let Some(name) = read(&current).as_deref().and_then(version_dir_name).map(str::to_string) else {
        return Err(current);
    };
    let gui = inst.join(name).join(GUI);
    if exists(&gui) {
        Ok(gui)
    } else {
        Err(gui)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    #[test]
    fn which_arguments_start_the_interface() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(launch_args(&s(&[])), Some(vec![]));
        assert_eq!(launch_args(&s(&["--cm"])), Some(s(&["--cm"])));
        assert_eq!(launch_args(&s(&["--background"])), Some(s(&["--background"])));
        assert_eq!(launch_args(&s(&["share", "3000"])), None);
        assert_eq!(launch_args(&s(&["--version"])), None);
        assert_eq!(launch_args(&s(&["--help"])), None);
    }

    #[test]
    fn current_is_one_directory_name() {
        assert_eq!(version_dir_name("app-0.16.3"), Some("app-0.16.3"));
        assert_eq!(version_dir_name("\u{feff}app-0.16.3 \r\n"), Some("app-0.16.3"));
        for bad in ["", "\r\n", "0.16.3", r"app-1\..\..\x", "app-1/x", r"C:\x", r"..\app-1", "app-", "app-1\napp-2"] {
            assert_eq!(version_dir_name(bad), None, "{bad:?}");
        }
    }

    /// A file system of these files (path → contents).
    fn fs(files: &[(&Path, &str)]) -> (HashSet<PathBuf>, HashMap<PathBuf, String>) {
        let set = files.iter().map(|(p, _)| p.to_path_buf()).collect();
        let map = files.iter().map(|(p, c)| (p.to_path_buf(), c.to_string())).collect();
        (set, map)
    }

    fn find(own: &Path, files: &[(&Path, &str)]) -> Result<PathBuf, PathBuf> {
        let (set, map) = fs(files);
        gui_exe(own, &|p| set.contains(p), &|p| map.get(p).cloned())
    }

    #[test]
    fn finds_the_interface() {
        // A user name with a space and non-ASCII letters: nothing may split or re-encode the path.
        let inst = std::env::temp_dir().join("张 三").join("rapp");
        let app = |n: &str| inst.join(n);

        let own = app("app-1").join("rapp-cli.exe");
        let gui1 = app("app-1").join(GUI);
        assert_eq!(find(&own, &[(&gui1, "")]), Ok(gui1));

        let own = app("bin").join("rapp.exe");
        let current = inst.join("current");
        let gui2 = app("app-2").join(GUI);
        assert_eq!(find(&own, &[(&current, "app-2\r\n"), (&gui2, "")]), Ok(gui2.clone()));

        assert_eq!(find(&own, &[(&gui2, "")]), Err(current.clone()));
        assert_eq!(find(&own, &[(&current, "..\\x"), (&gui2, "")]), Err(current.clone()));
        assert_eq!(find(&own, &[(&current, "app-3")]), Err(app("app-3").join(GUI)));
    }
}
