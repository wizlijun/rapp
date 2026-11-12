use crate::protocol::{Rect, Window};
/// Aspect fit a remote region into a widget, including centered letterboxing.
pub fn fit(r: Rect, w: f64, h: f64) -> (f64, f64, f64) {
    let z = (w / r.w as f64).min(h / r.h as f64).max(0.000001);
    ((w - r.w as f64 * z) / 2., (h - r.h as f64 * z) / 2., z)
}
pub fn canvas_point(r: Rect, w: f64, h: f64, x: f64, y: f64, clamp: bool) -> Option<(f32, f32)> {
    let (ox, oy, z) = fit(r, w, h);
    let x = (x - ox) / z;
    let y = (y - oy) / z;
    if !clamp && (x < 0. || y < 0. || x >= r.w as f64 || y >= r.h as f64) {
        return None;
    }
    Some((
        r.x + x.clamp(0., r.w as f64) as f32,
        r.y + y.clamp(0., r.h as f64) as f32,
    ))
}
/// Table order is front-to-back, including popup windows. Coordinates are window points.
pub fn hit(windows: &[Window], x: f32, y: f32) -> Option<(u32, f32, f32)> {
    windows
        .iter()
        .find(|w| {
            x >= w.rect.x && y >= w.rect.y && x < w.rect.x + w.rect.w && y < w.rect.y + w.rect.h
        })
        .map(|w| (w.id, x - w.rect.x, y - w.rect.y))
}
/// X11/GDK keyvals to macOS virtual key codes (protocol uses Mac keycodes on all hosts).
pub fn keycode(key: u32) -> Option<u16> {
    let c = char::from_u32(key)?.to_ascii_lowercase();
    let letters = "asdfhgzxcv\0bqwerty123465=97-80]ou[ip\rlj'k;\\,/nm.";
    if c != '\0' {
        if let Some(i) = letters.chars().position(|v| v == c) {
            return Some(i as u16);
        }
    }
    Some(match key {
        0xff0d | 0xff8d => 36,
        0xff09 | 0xfe20 => 48,
        0x20 => 49,
        0x60 => 50,
        0xff08 => 51,
        0xff1b => 53,
        0xff50 => 115,
        0xff55 => 116,
        0xffff => 117,
        0xff57 => 119,
        0xff56 => 121,
        0xff51 => 123,
        0xff53 => 124,
        0xff54 => 125,
        0xff52 => 126,
        0xffbe => 122,
        0xffbf => 120,
        0xffc0 => 99,
        0xffc1 => 118,
        0xffc2 => 96,
        0xffc3 => 97,
        0xffc4 => 98,
        0xffc5 => 100,
        0xffc6 => 101,
        0xffc7 => 109,
        0xffc8 => 103,
        0xffc9 => 111,
        _ => return None,
    })
}

/// Actual point zoom (Mac: 50–200%), centered in a larger viewport.
/// The GTK drawing area requests at least region * zoom, and scrolls when it does not fit.
pub fn zoom_placement(r: Rect, w: f64, h: f64, zoom: f64) -> (f64, f64, f64) {
    (
        (w - r.w as f64 * zoom).max(0.) / 2.,
        (h - r.h as f64 * zoom).max(0.) / 2.,
        zoom,
    )
}
pub fn zoom_point(
    r: Rect,
    w: f64,
    h: f64,
    zoom: f64,
    x: f64,
    y: f64,
    clamp: bool,
) -> Option<(f32, f32)> {
    let (ox, oy, z) = zoom_placement(r, w, h, zoom);
    let x = (x - ox) / z;
    let y = (y - oy) / z;
    if !clamp && (x < 0. || y < 0. || x >= r.w as f64 || y >= r.h as f64) {
        return None;
    }
    Some((
        r.x + x.clamp(0., r.w as f64) as f32,
        r.y + y.clamp(0., r.h as f64) as f32,
    ))
}
pub fn top_left_slot(windows: &[Window], id: u32) -> f32 {
    let mut slot = 0f32;
    while windows.iter().any(|w| {
        w.id != id
            && w.kind <= 2
            && (w.rect.x - slot).abs() < 14.
            && (w.rect.y.max(40.) - slot.max(40.)).abs() < 14.
    }) {
        slot += 28.;
    }
    slot
}
