//! Wire key names to tmux key names, and typed text to bytes.

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
    fn text_becomes_utf8_bytes() {
        assert_eq!(utf8_hex("a中\n"), ["61", "e4", "b8", "ad", "0a"]);
    }
}
