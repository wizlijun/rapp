mod common;

use rapp_term::pty::grid::Emu;

/// Sample bytes: CJK, emoji, a combining mark, colours, a blank with a background, a wrapped row.
fn sample() -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice("中文日本語 😀 e\u{301}x\r\n".as_bytes());
    b.extend_from_slice(b"\x1b[1;31mred\x1b[0m \x1b[38;5;200midx\x1b[0m \x1b[48;2;1;2;3mtrue\x1b[0m\r\n");
    b.extend_from_slice(b"pad\x1b[44m     \x1b[0m\r\n");
    b.extend_from_slice("日".repeat(45).as_bytes());
    b.extend_from_slice(b"\r\n");
    b.extend_from_slice("x".repeat(100).as_bytes());
    b.extend_from_slice(b"\r\nend");
    b
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let mut v = vec![("sample".to_string(), sample())];
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    if let Ok(rd) = std::fs::read_dir(dir) {
        let mut paths: Vec<_> =
            rd.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "bin")).collect();
        paths.sort();
        for p in paths {
            v.push((p.display().to_string(), std::fs::read(&p).unwrap()));
        }
    }
    v
}

/// Drop CSI and OSC sequences (`screen::strip_escapes` is private to the crate).
fn strip_escapes(s: &str) -> String {
    let mut out = String::new();
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('[') => {
                for c in it.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(c) = it.next() {
                    if c == '\x07' || (c == '\x1b' && it.next() == Some('\\')) {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

#[test]
fn text_matches_tmux_capture() {
    let Some(s) = common::Server::start() else { return };
    let dir = tempfile::tempdir().unwrap();
    for (n, (name, bytes)) in fixtures().into_iter().enumerate() {
        let file = dir.path().join(format!("in{n}.bin"));
        std::fs::write(&file, &bytes).unwrap();
        let session = format!("g{n}");
        let cmd = format!("cat '{}'; sleep 600", file.display());
        s.raw(&["new-session", "-d", "-s", &session, "-x", "80", "-y", "24", &cmd]);
        // `cat` has no prompt in front of it, so the pane's rows are the emulator's rows; wait for it to print
        let end = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut text = String::new();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(150));
            let cur = s.raw(&["capture-pane", "-p", "-e", "-t", &session]);
            let done = cur == text && !cur.trim().is_empty();
            text = cur;
            if done || std::time::Instant::now() > end {
                break;
            }
        }
        let cursor = s.raw(&["display-message", "-p", "-t", &session, "#{cursor_x} #{cursor_y}"]);
        let mut e = Emu::new(80, 24);
        e.feed(&bytes);
        let scr = e.screen();
        let mine: Vec<String> = scr.lines.iter().map(|l| strip_escapes(l).trim_end().to_string()).collect();
        let mut theirs: Vec<String> = text.split('\n').map(|l| strip_escapes(l).trim_end().to_string()).collect();
        theirs.resize(24, String::new());
        assert_eq!(mine, theirs, "rows of {name}");
        assert_eq!(format!("{} {}", scr.cx, scr.cy), cursor.trim(), "cursor of {name}");
        s.raw(&["kill-session", "-t", &session]);
    }
}
