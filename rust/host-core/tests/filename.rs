//! `portable_file_name` (spec §6.7, plan B Review Focus 4): new for Windows, so the table is
//! literal, not a Swift fixture. The put tests run the whole upload path in a `tempfile`
//! folder and check that nothing lands outside it.

use std::fs;
use std::path::Path;

use rapp_host_core::filename::{portable_file_name, unique_name, NAME_UNITS};
use rapp_host_core::transfers::{ClipStore, ReceivedItem, TransferStore, TRANSFER_MEMORY_LIMIT};
use rapp_host_core::ClipKind;

fn long_png() -> String {
    "a".repeat(296) + ".png"
}

fn table() -> Vec<(String, String)> {
    let mut rows: Vec<(String, String)> = [
        ("..\\x", "x"),
        ("a/b", "b"),
        ("CON", "_CON"),
        ("nul.txt", "_nul.txt"),
        ("x.", "x"),
        ("x ", "x"),
        ("", "file"),
        ("..", "file"),
        ("a<b>.txt", "a_b_.txt"),
        // Beyond the plan's table.
        (".", "file"),
        ("com1", "_com1"),
        ("LPT9.log", "_LPT9.log"),
        ("COM0", "COM0"),
        ("CONSOLE", "CONSOLE"),
        ("aux.tar.gz", "_aux.tar.gz"),
        ("a|b?c*d\"e", "a_b_c_d_e"),
        ("tab\there", "tab_here"),
        ("C:\\Users\\x\\报告.pdf", "报告.pdf"),
        ("dir\\", "dir"),
        ("name. . .", "name"),
        ("报告.pdf", "报告.pdf"),
    ]
    .iter()
    .map(|(a, b)| (a.to_string(), b.to_string()))
    .collect();
    rows.push((long_png(), "a".repeat(196) + ".png"));
    rows
}

#[test]
fn portable_names_follow_the_table() {
    for (raw, want) in table() {
        assert_eq!(portable_file_name(&raw), want, "{raw:?}");
    }
}

#[test]
fn long_names_keep_the_extension_and_never_split_a_surrogate_pair() {
    let got = portable_file_name(&long_png());
    assert_eq!(got.encode_utf16().count(), NAME_UNITS);
    assert!(got.ends_with(".png"));

    // 150 emoji are 300 UTF-16 units; the cut must fall between two of them.
    let emoji = "😀".repeat(150) + ".txt";
    let got = portable_file_name(&emoji);
    assert!(got.encode_utf16().count() <= NAME_UNITS);
    assert!(got.ends_with(".txt"));
    assert_eq!(got, "😀".repeat(98) + ".txt");

    // No extension: the whole name is cut.
    let plain = "b".repeat(300);
    assert_eq!(portable_file_name(&plain), "b".repeat(NAME_UNITS));
}

#[test]
fn portable_names_are_stable() {
    for (raw, _) in table() {
        let once = portable_file_name(&raw);
        assert_eq!(portable_file_name(&once), once, "{raw:?}");
    }
}

#[test]
fn unique_name_numbers_before_the_extension() {
    let taken = ["app.log", "app (2).log"];
    assert_eq!(unique_name("app.log", &|n| taken.contains(&n)), "app (3).log");
    assert_eq!(unique_name("README", &|n| n == "README"), "README (2)");
    assert_eq!(unique_name(".bashrc", &|n| n == ".bashrc"), ".bashrc (2)");
    assert_eq!(unique_name("free.txt", &|_| false), "free.txt");
}

fn canonical(p: &Path) -> std::path::PathBuf {
    fs::canonicalize(p).unwrap()
}

/// Every upload of a file ends up as exactly one new file inside the transfer folder.
#[test]
fn put_never_leaves_the_transfer_dir() {
    let dir = tempfile::tempdir().unwrap();
    let uploads = dir.path().join("files").join("transfers");
    fs::create_dir_all(&uploads).unwrap();
    let mut store = TransferStore::new(ClipStore::new(0), uploads.clone(), TRANSFER_MEMORY_LIMIT);
    let root = canonical(&uploads);
    let mut item = 0u32;
    for (raw, _) in table() {
        item += 1;
        let before = fs::read_dir(&uploads).unwrap().count();
        let sink = store.put(item, ClipKind::Files, "", &raw, 3).unwrap();
        assert!(sink.lock().unwrap().write(&[1, 2, 3]).unwrap(), "{raw:?}");
        let after: Vec<_> = fs::read_dir(&uploads).unwrap().flatten().collect();
        assert_eq!(after.len(), before + 1, "{raw:?}: exactly one new file");
        assert!(!after.iter().any(|e| e.file_name().to_string_lossy().ends_with(".rapp-part")), "{raw:?}");
        match store.received(item) {
            Some(ReceivedItem::File(path)) => {
                let p = canonical(&path);
                assert!(p.starts_with(&root), "{raw:?} went to {}", p.display());
                assert_eq!(p.parent(), Some(root.as_path()), "{raw:?}");
            }
            other => panic!("{raw:?}: {other:?}"),
        }
    }
    // Nothing was written next to the transfer folder.
    let siblings: Vec<_> = fs::read_dir(dir.path()).unwrap().flatten().map(|e| e.file_name()).collect();
    assert_eq!(siblings, vec![std::ffi::OsString::from("files")]);
}

#[test]
fn second_file_with_same_name_gets_a_suffix() {
    let dir = tempfile::tempdir().unwrap();
    let uploads = dir.path().join("uploads");
    let mut store = TransferStore::new(ClipStore::new(0), uploads.clone(), TRANSFER_MEMORY_LIMIT);
    for item in 1..=3u32 {
        let sink = store.put(item, ClipKind::Files, "", "CON.txt", 1).unwrap();
        assert!(sink.lock().unwrap().write(&[item as u8]).unwrap());
    }
    let names: Vec<String> = (1..=3)
        .map(|i| match store.received(i) {
            Some(ReceivedItem::File(p)) => p.file_name().unwrap().to_string_lossy().into_owned(),
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(names, ["_CON.txt", "_CON (2).txt", "_CON (3).txt"]);
    assert_eq!(fs::read(uploads.join("_CON (3).txt")).unwrap(), [3]);
}
