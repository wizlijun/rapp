//! v13 sends macOS virtual key codes. Linux shortcuts map Command to Control;
//! macOS Control maps to Super, matching the inverse mapping in Linux clients.
pub fn evdev(mac: u16) -> Option<u32> {
    Some(match mac {
        0 => 30,
        1 => 31,
        2 => 32,
        3 => 33,
        4 => 35,
        5 => 34,
        6 => 44,
        7 => 45,
        8 => 46,
        9 => 47,
        11 => 48,
        12 => 16,
        13 => 17,
        14 => 18,
        15 => 19,
        16 => 21,
        17 => 20,
        18 => 2,
        19 => 3,
        20 => 4,
        21 => 5,
        22 => 7,
        23 => 6,
        24 => 13,
        25 => 10,
        26 => 8,
        27 => 12,
        28 => 9,
        29 => 11,
        30 => 27,
        31 => 24,
        32 => 22,
        33 => 26,
        34 => 23,
        35 => 25,
        36 => 28,
        37 => 38,
        38 => 36,
        39 => 40,
        40 => 37,
        41 => 39,
        42 => 43,
        43 => 51,
        44 => 53,
        45 => 49,
        46 => 50,
        47 => 52,
        48 => 15,
        49 => 57,
        50 => 41,
        51 => 14,
        53 => 1,
        54 => 97,
        55 => 29,
        56 => 42,
        57 => 58,
        58 => 56,
        59 => 125,
        60 => 54,
        61 => 100,
        62 => 126,
        65 => 83,
        67 => 55,
        69 => 78,
        71 => 69,
        75 => 98,
        76 => 96,
        78 => 74,
        81 => 117,
        82 => 82,
        83 => 79,
        84 => 80,
        85 => 81,
        86 => 75,
        87 => 76,
        88 => 77,
        89 => 71,
        91 => 72,
        92 => 73,
        96 => 63,
        97 => 64,
        98 => 65,
        99 => 61,
        100 => 66,
        101 => 67,
        103 => 87,
        109 => 68,
        111 => 88,
        115 => 102,
        116 => 104,
        117 => 111,
        119 => 107,
        121 => 109,
        118 => 62,
        122 => 59,
        123 => 105,
        124 => 106,
        125 => 108,
        126 => 103,
        120 => 60,
        _ => return None,
    })
}
/// XKB masks for the default evdev/US keymap: Shift, Control, Mod1, Mod4.
pub fn xkb_mods(flags: u64) -> u32 {
    ((flags & (1 << 17) != 0) as u32)
        | (((flags & (1 << 20) != 0) as u32) << 2)
        | (((flags & (1 << 19) != 0) as u32) << 3)
        | (((flags & (1 << 18) != 0) as u32) << 6)
}
pub const MODIFIERS: [(u64, u32); 4] =
    [(1 << 17, 42), (1 << 20, 29), (1 << 19, 56), (1 << 18, 125)];

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shortcuts_and_navigation_map_in_both_client_directions() {
        assert_eq!(evdev(8), Some(46)); // C
        assert_eq!(evdev(36), Some(28));
        assert_eq!(evdev(123), Some(105));
        assert_eq!(xkb_mods(1 << 20), 4); // Cmd-C -> Ctrl-C
        assert_eq!(xkb_mods(1 << 18), 64); // Linux client's Super -> wire Control
        assert_eq!(evdev(65535), None);
    }
}
