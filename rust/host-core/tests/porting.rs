//! `PORTING.md` against the Swift sources (plan B, Task 18): the digests are current, every
//! row names a real test, and every line of `Sources/rapp-host/` is mapped. Reads files only.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

const HOST_DIR: &str = "Sources/rapp-host";
const CORE_DIR: &str = "Sources/RappCore";

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The repository root (`rust/host-core` is two levels down).
fn repo() -> PathBuf {
    crate_dir().join("..").join("..")
}

fn porting() -> String {
    let path = crate_dir().join("PORTING.md");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn changed(path: &str, how: &str) -> String {
    format!("{path} changed{how}: check host-core against it, then update rust/host-core/PORTING.md")
}

/// The lines of the part headed `## {n}.`, up to the next `## ` heading.
fn part(text: &str, n: u32) -> Vec<&str> {
    let head = format!("## {n}.");
    let mut lines = text.lines().skip_while(|l| !l.starts_with(&head));
    assert!(lines.next().is_some(), "PORTING.md has no part {n}");
    lines.take_while(|l| !l.starts_with("## ")).collect()
}

fn files_under(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        .filter_map(Result::ok)
        .map(|e| e.path())
        .collect();
    entries.sort();
    for p in entries {
        // Finder's and editors' hidden files are not sources.
        if p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with('.')) {
            continue;
        }
        if p.is_dir() {
            files_under(&p, out);
        } else {
            out.push(p);
        }
    }
}

/// `p` relative to `root`, with `/` separators.
fn relative(root: &Path, p: &Path) -> String {
    p.strip_prefix(root)
        .unwrap_or_else(|_| panic!("{} is not under {}", p.display(), root.display()))
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("/")
}

/// Every file now in the two directories, as repository-relative paths.
fn swift_files() -> BTreeSet<String> {
    let root = repo();
    let mut found = Vec::new();
    for dir in [HOST_DIR, CORE_DIR] {
        files_under(&root.join(dir), &mut found);
    }
    found.iter().map(|p| relative(&root, p)).collect()
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// Part 3's fenced block: path → digest.
fn listed_digests(text: &str) -> BTreeMap<String, String> {
    let mut listed = BTreeMap::new();
    let mut inside = false;
    for line in part(text, 3) {
        if line.trim_start().starts_with("```") {
            if inside {
                break;
            }
            inside = true;
            continue;
        }
        if !inside || line.trim().is_empty() {
            continue;
        }
        let (digest, path) = line
            .split_once("  ")
            .unwrap_or_else(|| panic!("PORTING.md part 3: not `<sha256>  <path>`: {line:?}"));
        assert!(
            digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()),
            "PORTING.md part 3: bad digest in {line:?}"
        );
        let path = path.trim().to_string();
        assert!(listed.insert(path.clone(), digest.to_ascii_lowercase()).is_none(), "PORTING.md part 3 lists {path} twice");
    }
    assert!(inside, "PORTING.md part 3 has no fenced digest block");
    listed
}

/// One row of part 1.
struct Row {
    file: String,
    start: usize,
    end: usize,
    place: String,
    tests: Vec<(String, String)>,
    text: String,
}

/// The backticked spans of a cell.
fn spans(cell: &str) -> Vec<&str> {
    cell.split('`').skip(1).step_by(2).collect()
}

fn rows(text: &str) -> Vec<Row> {
    let mut out = Vec::new();
    for line in part(text, 1) {
        let line = line.trim();
        if !line.starts_with("| `Sources/rapp-host/") {
            continue;
        }
        let cells: Vec<&str> = line.trim_matches('|').split('|').map(str::trim).collect();
        assert_eq!(cells.len(), 4, "PORTING.md part 1: a row needs four columns: {line}");
        let swift = cells[0].trim_matches('`');
        let (file, range) = swift.rsplit_once(':').unwrap_or_else(|| panic!("no line range in {swift:?}"));
        let (a, b) = range.split_once('-').unwrap_or_else(|| panic!("range is not a-b in {swift:?}"));
        let start: usize = a.parse().unwrap_or_else(|_| panic!("bad start line in {swift:?}"));
        let end: usize = b.parse().unwrap_or_else(|_| panic!("bad end line in {swift:?}"));
        assert!(start >= 1 && start <= end, "empty or backwards range in {swift:?}");
        let tests = spans(cells[3])
            .into_iter()
            .map(|s| {
                let (f, n) = s.split_once("::").unwrap_or_else(|| panic!("test is not file::name: {s:?} in {line}"));
                (f.to_string(), n.to_string())
            })
            .collect();
        out.push(Row { file: file.to_string(), start, end, place: cells[2].to_string(), tests, text: line.to_string() });
    }
    assert!(!out.is_empty(), "PORTING.md part 1 has no rows");
    out
}

/// The text of `<file>.rs` in host-core's or testkit's tests, if it exists.
fn test_file(name: &str) -> Option<String> {
    let rust = crate_dir().join("..");
    [rust.join("host-core").join("tests"), rust.join("testkit").join("tests")]
        .iter()
        .find_map(|dir| fs::read_to_string(dir.join(format!("{name}.rs"))).ok())
}

#[test]
fn swift_digests_are_current() {
    let text = porting();
    let listed = listed_digests(&text);
    let now = swift_files();
    let root = repo();
    let mut problems = Vec::new();
    for (path, digest) in &listed {
        if !now.contains(path) {
            problems.push(changed(path, " (removed)"));
            continue;
        }
        let bytes = fs::read(root.join(path)).unwrap_or_else(|e| panic!("read {path}: {e}"));
        if sha256_hex(&bytes) != *digest {
            problems.push(changed(path, ""));
        }
    }
    for path in &now {
        if !listed.contains_key(path) {
            problems.push(changed(path, " (added)"));
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn every_row_names_a_real_test() {
    let text = porting();
    let mut problems = Vec::new();
    for row in rows(&text) {
        if row.tests.is_empty() {
            if !(row.place.contains("platform:") || row.place.contains("not on Windows")) {
                problems.push(format!("no test, and not a platform or not-on-Windows row: {}", row.text));
            }
            continue;
        }
        for (file, name) in &row.tests {
            match test_file(file) {
                None => problems.push(format!("no tests/{file}.rs for `{file}::{name}`: {}", row.text)),
                Some(source) => {
                    if !source.contains(&format!("fn {name}(")) {
                        problems.push(format!("tests/{file}.rs has no fn {name}: {}", row.text));
                    }
                }
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

/// `a-b` runs of the unmapped (false) lines, 1-based.
fn gaps(covered: &[bool]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < covered.len() {
        if covered[i] {
            i += 1;
            continue;
        }
        let start = i;
        while i < covered.len() && !covered[i] {
            i += 1;
        }
        out.push(format!("{}-{}", start + 1, i));
    }
    out
}

#[test]
fn every_swift_host_line_is_mapped() {
    let text = porting();
    let rows = rows(&text);
    let root = repo();
    let host: Vec<String> = swift_files().into_iter().filter(|p| p.starts_with(&format!("{HOST_DIR}/"))).collect();
    assert!(!host.is_empty(), "no files under {HOST_DIR}");
    let mut problems = Vec::new();
    for row in &rows {
        if !host.contains(&row.file) {
            problems.push(format!("row names a file not in {HOST_DIR}: {}", row.text));
        }
    }
    for path in &host {
        let source = fs::read_to_string(root.join(path)).unwrap_or_else(|e| panic!("read {path}: {e}"));
        let lines = source.lines().count();
        let mut covered = vec![false; lines];
        for row in rows.iter().filter(|r| r.file == *path) {
            if row.end > lines {
                problems.push(format!("{path} has {lines} lines; row goes to {}: {}", row.end, row.text));
            }
            for n in row.start..=row.end.min(lines) {
                covered[n - 1] = true;
            }
        }
        let missing = gaps(&covered);
        if !missing.is_empty() {
            problems.push(format!("{path}: lines not mapped: {}", missing.join(", ")));
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}
