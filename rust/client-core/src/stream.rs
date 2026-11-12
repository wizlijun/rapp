//! Menu labels and stream policy shared with the macOS StreamMenu/Geometry implementation.
pub const MODES: [(&str, u8); 3] = [
    ("双色·灰度（文本优化）", 3),
    ("双色·彩色", 4),
    ("高彩（图像优化）", 2),
];
pub const DENSITIES: [&str; 3] = ["省流 1x", "自适应", "原画"];
pub const FPS: [(&str, u8); 4] = [
    ("1 fps", 1),
    ("5 fps", 5),
    ("15 fps", 15),
    ("30 fps（看视频）", 30),
];
pub const ZOOMS: [u32; 6] = [50, 75, 100, 125, 150, 200];
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Choice {
    pub mode: u8,
    pub fps: u8,
    pub density: u32,
}
pub const LEAST_TRAFFIC: Choice = Choice {
    mode: 3,
    fps: 1,
    density: 1,
};
pub const SHARPEST: Choice = Choice {
    mode: 2,
    fps: 15,
    density: 2,
};
pub fn capture_density(zoom: f64, backing: f64, choice: u32) -> f32 {
    if choice == 2 {
        return 8.;
    }
    let d = if choice == 0 { zoom } else { zoom * backing };
    if !d.is_finite() {
        return 1.;
    }
    d.clamp(0.01, 8.) as f32
}
pub fn changed(old: Option<(u8, u8, f32)>, next: (u8, u8, f32)) -> bool {
    old.is_none_or(|old| {
        old.0 != next.0 || old.1 != next.1 || (old.2 - next.2).abs() > old.2 * 0.01
    })
}
pub fn rate(bytes: u64, seconds: f64) -> String {
    if bytes == 0 {
        return "0 KB/s".into();
    }
    let kb = bytes as f64 / 1024. / seconds.max(0.001);
    if kb >= 1000. {
        format!("{:.1} MB/s", kb / 1024.)
    } else {
        format!("{kb:.1} KB/s")
    }
}
