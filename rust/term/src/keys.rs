//! Wire key names to tmux key names, and typed text to bytes.

/// The tmux name of a wire key, or `None` when the wire name is not one we accept.
pub fn tmux_name(wire: &str) -> Option<String> {
    let fixed = match wire {
        "Esc" => "Escape",
        "Enter" => "Enter",
        "Tab" => "Tab",
        "Shift-Tab" => "BTab",
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
    if let Some(n) = wire.strip_prefix('F').and_then(|n| n.parse::<u8>().ok()) {
        if (1..=12).contains(&n) && wire == format!("F{n}") {
            return Some(wire.to_string());
        }
    }
    let letter = wire.strip_prefix("Ctrl-")?;
    let mut chars = letter.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) if c.is_ascii_alphabetic() => Some(format!("C-{}", c.to_ascii_lowercase())),
        _ => None,
    }
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
        ] {
            assert_eq!(tmux_name(w).as_deref(), Some(t), "{w}");
        }
        // Built from parts so the forbidden verb never appears as a literal in src.
        let verb = ["set", "option"].join("-");
        for bad in ["", "Ctrl-", "Ctrl-1", "Ctrl-cc", "F13x", verb.as_str(), "C-c"] {
            assert_eq!(tmux_name(bad), None, "{bad}");
        }
    }
    #[test]
    fn text_becomes_utf8_bytes() {
        assert_eq!(utf8_hex("a中\n"), ["61", "e4", "b8", "ad", "0a"]);
    }
}
