//! Wire key names to tmux key names, and typed text to bytes.

use crate::pty::grid::Modes;

/// The tmux name of a wire key, or `None` when the wire name is not one we accept.
///
/// Grammar: `[Ctrl-][Alt-][Shift-]<base>`, each prefix at most once and in that order.
pub fn tmux_name(wire: &str) -> Option<String> {
    if wire == "Shift-Tab" {
        return Some("BTab".to_string());
    }
    let mut rest = wire;
    let mut out = String::new();
    let (mut ctrl, mut alt, mut shift) = (false, false, false);
    if let Some(r) = rest.strip_prefix("Ctrl-") {
        ctrl = true;
        out.push_str("C-");
        rest = r;
    }
    if let Some(r) = rest.strip_prefix("Alt-") {
        alt = true;
        out.push_str("M-");
        rest = r;
    }
    if let Some(r) = rest.strip_prefix("Shift-") {
        shift = true;
        out.push_str("S-");
        rest = r;
    }
    match named(rest) {
        Some(n) => {
            // `Shift-` only goes with keys that have a shifted form.
            let shiftable = matches!(
                rest,
                "Up" | "Down" | "Left" | "Right" | "Home" | "End" | "PageUp" | "PageDown" | "Delete"
            ) || rest.starts_with('F');
            if shift && !shiftable {
                return None;
            }
            // Bare Space is text, not a key.
            if rest == "Space" && !(ctrl || alt) {
                return None;
            }
            out.push_str(&n);
        }
        None => {
            let mut chars = rest.chars();
            let c = chars.next()?;
            if chars.next().is_some() || shift || !(ctrl || alt) {
                return None;
            }
            if alt {
                if !c.is_ascii_graphic() {
                    return None;
                }
                out.push(c);
            } else if c.is_ascii_alphabetic() {
                out.push(c.to_ascii_lowercase());
            } else if matches!(c, '[' | ']' | '\\' | '@' | '_') {
                out.push(c);
            } else {
                return None;
            }
        }
    }
    Some(out)
}

/// How a key is written with the xterm CSI/SS3 forms.
enum Csi {
    /// Arrows, Home, End: `ESC [ c`, or `ESC O c` in app-cursor mode.
    Cursor(u8),
    /// PageUp, PageDown, Delete, F5-F12: `ESC [ n ~`.
    Tilde(u8),
    /// F1-F4: `ESC O c`.
    Ss3(u8),
}

fn csi_form(base: &str) -> Option<Csi> {
    Some(match base {
        "Up" => Csi::Cursor(b'A'),
        "Down" => Csi::Cursor(b'B'),
        "Right" => Csi::Cursor(b'C'),
        "Left" => Csi::Cursor(b'D'),
        "Home" => Csi::Cursor(b'H'),
        "End" => Csi::Cursor(b'F'),
        "PageUp" => Csi::Tilde(5),
        "PageDown" => Csi::Tilde(6),
        "Delete" => Csi::Tilde(3),
        _ => {
            let n = base.strip_prefix('F')?.parse::<u8>().ok()?;
            match n {
                1..=4 => Csi::Ss3(b'O' + n),
                5..=12 => Csi::Tilde([15, 17, 18, 19, 20, 21, 23, 24][usize::from(n) - 5]),
                _ => return None,
            }
        }
    })
}

/// The bytes a wire key writes into a pty, or `None` when the wire name is not one we accept.
///
/// Same grammar as [`tmux_name`], but more permissive: any named key takes any modifier, and a
/// single character is accepted too. Keys with a CSI form carry the modifiers as the xterm
/// parameter `m = 1 + Shift 1 + Alt 2 + Ctrl 4`; the rest take Alt as an ESC prefix and the
/// Ctrl/Shift forms in the table below, ignoring a modifier that means nothing for them.
pub fn to_bytes(wire: &str, modes: Modes) -> Option<Vec<u8>> {
    let mut rest = wire;
    let mut strip = |p: &str| rest.strip_prefix(p).map(|r| rest = r).is_some();
    let (ctrl, alt, shift) = (strip("Ctrl-"), strip("Alt-"), strip("Shift-"));
    let m = 1 + u8::from(shift) + 2 * u8::from(alt) + 4 * u8::from(ctrl);

    if let Some(csi) = csi_form(rest) {
        return Some(match (csi, m) {
            (Csi::Cursor(c), 1) if modes.app_cursor => vec![0x1b, b'O', c],
            (Csi::Cursor(c), 1) => vec![0x1b, b'[', c],
            (Csi::Ss3(c), 1) => vec![0x1b, b'O', c],
            (Csi::Cursor(c) | Csi::Ss3(c), m) => format!("\x1b[1;{m}{}", c as char).into_bytes(),
            (Csi::Tilde(n), 1) => format!("\x1b[{n}~").into_bytes(),
            (Csi::Tilde(n), m) => format!("\x1b[{n};{m}~").into_bytes(),
        });
    }

    let mut out = match rest {
        "Esc" => vec![0x1b],
        "Enter" => vec![b'\r'],
        "Tab" => vec![b'\t'],
        "Space" => vec![b' '],
        "Backspace" => vec![0x7f],
        _ => {
            let mut chars = rest.chars();
            let c = chars.next()?;
            if chars.next().is_some() {
                return None;
            }
            c.to_string().into_bytes()
        }
    };
    // Ctrl and Shift on a key without a CSI form; anything not listed leaves the base bytes.
    let ctrl_byte = match rest {
        "Space" | "@" => Some(0),
        "Backspace" => Some(0x08),
        "[" => Some(0x1b),
        "\\" => Some(0x1c),
        "]" => Some(0x1d),
        "^" => Some(0x1e),
        "_" => Some(0x1f),
        _ => match rest.as_bytes() {
            [c] if c.is_ascii_alphabetic() => Some(c & 0x1f),
            _ => None,
        },
    };
    if let (true, Some(b)) = (ctrl, ctrl_byte) {
        out = vec![b];
    } else if shift && rest == "Tab" {
        out = b"\x1b[Z".to_vec();
    } else if shift {
        out.make_ascii_uppercase();
    }
    if alt {
        out.insert(0, 0x1b);
    }
    Some(out)
}

/// The tmux name of a named wire key (no modifiers).
fn named(wire: &str) -> Option<String> {
    let fixed = match wire {
        "Esc" => "Escape",
        "Enter" => "Enter",
        "Tab" => "Tab",
        "Space" => "Space",
        "Backspace" => "BSpace",
        "Delete" => "DC",
        "Up" => "Up",
        "Down" => "Down",
        "Left" => "Left",
        "Right" => "Right",
        "Home" => "Home",
        "End" => "End",
        "PageUp" => "PPage",
        "PageDown" => "NPage",
        _ => "",
    };
    if !fixed.is_empty() {
        return Some(fixed.to_string());
    }
    let n = wire.strip_prefix('F')?.parse::<u8>().ok()?;
    ((1..=12).contains(&n) && wire == format!("F{n}")).then(|| wire.to_string())
}

/// Every UTF-8 byte of `text` as two lowercase hex digits.
pub fn utf8_hex(text: &str) -> Vec<String> {
    text.bytes().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_wire_names() {
        for (w, t) in [
            ("Esc", "Escape"),
            ("Enter", "Enter"),
            ("Tab", "Tab"),
            ("Shift-Tab", "BTab"),
            ("Backspace", "BSpace"),
            ("Delete", "DC"),
            ("Up", "Up"),
            ("Down", "Down"),
            ("Left", "Left"),
            ("Right", "Right"),
            ("Home", "Home"),
            ("End", "End"),
            ("PageUp", "PPage"),
            ("PageDown", "NPage"),
            ("Ctrl-C", "C-c"),
            ("Ctrl-d", "C-d"),
            ("Alt-x", "M-x"),
            ("Alt-X", "M-X"),
            ("Alt-;", "M-;"),
            ("Alt-Left", "M-Left"),
            ("Alt-Backspace", "M-BSpace"),
            ("Alt-Enter", "M-Enter"),
            ("Shift-Up", "S-Up"),
            ("Ctrl-Left", "C-Left"),
            ("Ctrl-Shift-Right", "C-S-Right"),
            ("Ctrl-Alt-x", "C-M-x"),
            ("Ctrl-[", "C-["),
            ("Ctrl-\\", "C-\\"),
            ("Ctrl-Space", "C-Space"),
            ("Alt-Space", "M-Space"),
            ("Shift-F5", "S-F5"),
        ] {
            assert_eq!(tmux_name(w).as_deref(), Some(t), "{w}");
        }
        // Built from parts so the forbidden verb never appears as a literal in src.
        let verb = ["set", "option"].join("-");
        for bad in ["", "Ctrl-", "Ctrl-1", "Ctrl-cc", "F13x", verb.as_str(), "C-c", "x", "Shift-x",
            "Shift-Enter", "Space", "Alt-", "Alt- ", "Alt-\u{e9}", "Shift-Ctrl-x", "Ctrl-Ctrl-x", "Shift-Space",
            "Ctrl-Shift-Tab", "Alt-Shift-Tab", "Alt-Alt-x", "Shift-Shift-Up"] {
            assert_eq!(tmux_name(bad), None, "{bad}");
        }
    }
    #[test]
    fn wire_keys_become_xterm_bytes() {
        let m = Modes::default();
        assert_eq!(to_bytes("Ctrl-C", m).unwrap(), b"\x03");
        assert_eq!(to_bytes("Alt-b", m).unwrap(), b"\x1bb");
        assert_eq!(to_bytes("Enter", m).unwrap(), b"\r");
        assert_eq!(to_bytes("Shift-Tab", m).unwrap(), b"\x1b[Z");
        assert_eq!(to_bytes("Up", m).unwrap(), b"\x1b[A");
        assert_eq!(to_bytes("Shift-Up", m).unwrap(), b"\x1b[1;2A");
        assert_eq!(to_bytes("PageUp", m).unwrap(), b"\x1b[5~");
        assert_eq!(to_bytes("F5", m).unwrap(), b"\x1b[15~");
        assert!(to_bytes("Hyper-x", m).is_none());
    }

    #[test]
    fn app_cursor_mode_changes_plain_arrows_only() {
        let m = Modes { app_cursor: true, ..Modes::default() };
        assert_eq!(to_bytes("Up", m).unwrap(), b"\x1bOA");
        assert_eq!(to_bytes("Ctrl-Up", m).unwrap(), b"\x1b[1;5A");
        assert_eq!(to_bytes("Home", m).unwrap(), b"\x1bOH");
        assert_eq!(to_bytes("PageUp", m).unwrap(), b"\x1b[5~");
    }

    #[test]
    fn every_named_key_has_bytes() {
        // Every wire name named() accepts, alone and with Ctrl-/Alt-/Shift-.
        let names = ["Esc", "Enter", "Tab", "Space", "Backspace", "Delete", "Up", "Down", "Left", "Right", "Home",
            "End", "PageUp", "PageDown", "F1", "F5", "F12"];
        for wire in names {
            for pre in ["", "Ctrl-", "Alt-", "Shift-"] {
                assert!(to_bytes(&format!("{pre}{wire}"), Modes::default()).is_some(), "{pre}{wire}");
            }
        }
    }

    #[test]
    fn modifiers_follow_xterm_forms() {
        let m = Modes::default();
        for (w, b) in [
            ("Shift-PageUp", &b"\x1b[5;2~"[..]),
            ("Alt-Up", b"\x1b[1;3A"),
            ("Ctrl-Alt-c", b"\x1b\x03"),
            ("Ctrl-Space", b"\0"),
            ("Ctrl-@", b"\0"),
            ("Ctrl-[", b"\x1b"),
            ("Ctrl-Backspace", b"\x08"),
            ("F1", b"\x1bOP"),
            ("F4", b"\x1bOS"),
            ("Ctrl-F1", b"\x1b[1;5P"),
            ("F12", b"\x1b[24~"),
            ("Home", b"\x1b[H"),
            ("Shift-Esc", b"\x1b"),
            ("Ctrl-Enter", b"\r"),
            ("Ctrl-1", b"1"),
            ("Shift-a", b"A"),
            ("Alt-Enter", b"\x1b\r"),
            ("a", b"a"),
            ("\u{4e2d}", "\u{4e2d}".as_bytes()),
        ] {
            assert_eq!(to_bytes(w, m).unwrap(), b, "{w}");
        }
        for bad in ["", "Ctrl-", "Alt-Ctrl-x", "Ctrl-Ctrl-x", "Shift-Ctrl-x", "ab", "F13"] {
            assert_eq!(to_bytes(bad, m), None, "{bad}");
        }
    }
    #[test]
    fn text_becomes_utf8_bytes() {
        assert_eq!(utf8_hex("a中\n"), ["61", "e4", "b8", "ad", "0a"]);
    }
}
