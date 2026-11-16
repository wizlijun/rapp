//! Wire key names to the bytes written into a pty.

use crate::pty::grid::Modes;

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
/// Grammar: `[Ctrl-][Alt-][Shift-]<base>`, each prefix at most once and in that order. Any named key takes any
/// modifier, and a single character is accepted too. Keys with a CSI form carry the modifiers as the xterm
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

#[cfg(test)]
mod tests {
    use super::*;

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
        // Every named wire key, alone and with Ctrl-/Alt-/Shift-.
        let names = [
            "Esc",
            "Enter",
            "Tab",
            "Space",
            "Backspace",
            "Delete",
            "Up",
            "Down",
            "Left",
            "Right",
            "Home",
            "End",
            "PageUp",
            "PageDown",
            "F1",
            "F5",
            "F12",
        ];
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
}
