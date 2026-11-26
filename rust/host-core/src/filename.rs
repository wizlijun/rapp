//! File names that are safe on every file system the host writes to. `portable_file_name` is
//! new for Windows (spec §6.7) and has no Swift counterpart; `unique_name` is Swift's
//! `uniqueName(_:existing:)` (`Clipboard.swift:165`) with the set replaced by a lookup.
//!
//! Both are applied on every operating system, so the fake platform exercises them on the Mac.

/// Longest name kept, in UTF-16 code units (NTFS allows 255; the margin leaves room for
/// `unique_name`'s ` (n)` and the `.rapp-part` suffix).
pub const NAME_UNITS: usize = 200;

const RESERVED: [&str; 22] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2",
    "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

fn illegal(c: char) -> bool {
    (c as u32) < 0x20 || matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*')
}

fn strip_trailing(s: &mut String) {
    while s.ends_with('.') || s.ends_with(' ') {
        s.pop();
    }
}

/// `s` cut to at most `units` UTF-16 code units, never inside a character (so never between
/// the two halves of a surrogate pair).
fn cut_units(s: &str, units: usize) -> &str {
    let mut used = 0;
    for (i, c) in s.char_indices() {
        let n = c.len_utf16();
        if used + n > units {
            return &s[..i];
        }
        used += n;
    }
    s
}

/// A name Windows (and every other host) can create inside the transfer folder (spec §6.7):
///
/// 1. the last non-empty component after splitting on `/` and `\`;
/// 2. each of `< > : " / \ | ? *` and every character below U+0020 becomes `_`;
/// 3. trailing dots and spaces are stripped;
/// 4. a reserved device stem (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`; the part
///    before the first dot, ASCII case-insensitive) gets a `_` prefix;
/// 5. the result is cut to `NAME_UNITS` UTF-16 units, keeping the extension;
/// 6. an empty result, `.` or `..` becomes `file`.
pub fn portable_file_name(raw: &str) -> String {
    let last = raw.split(|c| c == '/' || c == '\\').filter(|p| !p.is_empty()).last().unwrap_or("");
    let mut name: String = last.chars().map(|c| if illegal(c) { '_' } else { c }).collect();
    strip_trailing(&mut name);

    let stem = name.split('.').next().unwrap_or("");
    if RESERVED.iter().any(|r| stem.eq_ignore_ascii_case(r)) {
        name.insert(0, '_');
    }

    if name.encode_utf16().count() > NAME_UNITS {
        // The extension is everything from the last dot, unless the dot is the first
        // character or the extension alone would not leave room for one stem character.
        let ext = match name.rfind('.') {
            Some(dot) if dot > 0 && name[dot..].encode_utf16().count() < NAME_UNITS => &name[dot..],
            _ => "",
        };
        let ext_units = ext.encode_utf16().count();
        let stem = &name[..name.len() - ext.len()];
        let kept = cut_units(stem, NAME_UNITS - ext_units);
        name = format!("{kept}{ext}");
        strip_trailing(&mut name);
    }

    if name.is_empty() || name == "." || name == ".." {
        return "file".to_string();
    }
    name
}

/// `"app.log"` → `"app (2).log"`, `"app (3).log"`, … until `exists` says no (Swift's
/// `uniqueName`). A dot at the very start does not begin an extension.
pub fn unique_name(name: &str, exists: &dyn Fn(&str) -> bool) -> String {
    if !exists(name) {
        return name.to_string();
    }
    let (base, ext) = match name.rfind('.') {
        Some(dot) if dot != 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    let mut n = 2u64;
    loop {
        let candidate = format!("{base} ({n}){ext}");
        if !exists(&candidate) {
            return candidate;
        }
        n += 1;
    }
}
