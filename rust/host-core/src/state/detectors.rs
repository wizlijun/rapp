//! Signal detectors and the per-frame signal evaluator (`StateRules/Detectors.swift`).

use std::collections::{BTreeMap, BTreeSet, HashMap};

use unicode_segmentation::UnicodeSegmentation;

use super::regions::resolve_region_table;
use super::rule_image::{color_distance, hsl, Hsl, RuleImage, RuleRect, BLOB_CONTRAST};
use super::rule_pack::{range_contains, ColorRange, Detect, RegionRef, RulePack, SignalSpec};
use crate::geometry::{swift_max, swift_min};

// MARK: - Text

/// Reads the lines of text in one rect of a frame (OCR). The platform supplies it.
pub trait TextReader: Send {
    /// Lines recognised in `rect` of `image`. Runs on the engine's thread; may take tens of
    /// milliseconds.
    fn lines(&mut self, image: &RuleImage, rect: RuleRect) -> Vec<String>;
    /// False while the reader is still loading; text signals are skipped (not cached or
    /// throttled) until true.
    fn ready(&self) -> bool {
        true
    }
}

/// Text is read at most this often (seconds), and only when the region changed.
pub const TEXT_EVERY: f64 = 2.0;

/// Foundation's `CharacterSet.whitespacesAndNewlines`: general category Zs, U+0009, and the
/// newlines U+000A–U+000D, U+0085, U+2028, U+2029.
fn is_whitespace_or_newline(c: char) -> bool {
    matches!(
        c,
        '\u{9}'..='\u{D}'
            | '\u{20}'
            | '\u{85}'
            | '\u{A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
    )
}

/// Swift's `String.lowercased()`: each scalar's full lowercase mapping, with no context (no
/// final-sigma rule, unlike `str::to_lowercase`).
pub(crate) fn swift_lowercased(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        out.extend(c.to_lowercase());
    }
    out
}

/// The string in NFC. Swift's `==` and `<` on `String` and `Character` compare canonically
/// equivalent text as equal ("é" and "e\u{301}"); comparing the NFC forms does the same.
pub(crate) fn nfc(s: &str) -> String {
    icu_normalizer::ComposingNormalizerBorrowed::new_nfc().normalize(s).into_owned()
}

/// `Array(string)`: the string's Characters (extended grapheme clusters).
fn characters(s: &str) -> Vec<&str> {
    s.graphemes(true).collect()
}

/// `Character.isASCII`.
fn is_ascii_char(c: &str) -> bool {
    c.is_ascii()
}

/// `Character.isLetter || Character.isNumber`, judged on the first scalar: `isAlphabetic`, and
/// a numeric type (approximated by the general categories Nd/Nl/No; see the notes).
fn is_letter_or_number(c: &str) -> bool {
    c.chars().next().is_some_and(|f| f.is_alphabetic() || f.is_numeric())
}

/// `*` in a pattern is a wildcard and the whole line must match. Without `*`: an all-ASCII
/// pattern must appear as a whole word (neighbours are not letters or digits); anything else
/// (CJK) is a substring. Case-insensitive; lines are trimmed first.
pub fn text_matches(patterns: &[String], lines: &[String]) -> bool {
    let lowered: Vec<String> =
        lines.iter().map(|l| nfc(&swift_lowercased(l.trim_matches(is_whitespace_or_newline)))).collect();
    let ls: Vec<Vec<&str>> = lowered.iter().map(|l| characters(l)).collect();
    for p in patterns {
        let lp = nfc(&swift_lowercased(p));
        let pat = characters(&lp);
        if pat.is_empty() {
            continue;
        }
        let has_star = pat.contains(&"*");
        let ascii = pat.iter().all(|c| is_ascii_char(c));
        for l in &ls {
            if has_star {
                if glob_match(&pat, l) {
                    return true;
                }
            } else if ascii {
                if contains_word(l, &pat) {
                    return true;
                }
            } else if contains(l, &pat) {
                return true;
            }
        }
    }
    false
}

fn glob_match(p: &[&str], s: &[&str]) -> bool {
    let (mut pi, mut si, mut star, mut mark) = (0usize, 0usize, -1i64, 0usize);
    while si < s.len() {
        if pi < p.len() && p[pi] == "*" {
            star = pi as i64;
            mark = si;
            pi += 1;
        } else if pi < p.len() && p[pi] == s[si] {
            pi += 1;
            si += 1;
        } else if star >= 0 {
            pi = star as usize + 1;
            mark += 1;
            si = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == "*" {
        pi += 1;
    }
    pi == p.len()
}

fn contains(s: &[&str], p: &[&str]) -> bool {
    if p.len() > s.len() {
        return false;
    }
    (0..=(s.len() - p.len())).any(|i| s[i..i + p.len()] == *p)
}

fn contains_word(s: &[&str], p: &[&str]) -> bool {
    if p.len() > s.len() {
        return false;
    }
    for i in 0..=(s.len() - p.len()) {
        if s[i..i + p.len()] != *p {
            continue;
        }
        let before = i == 0 || !is_letter_or_number(s[i - 1]);
        let end = i + p.len();
        let after = end == s.len() || !is_letter_or_number(s[end]);
        if before && after {
            return true;
        }
    }
    false
}

// MARK: - Colour

impl ColorRange {
    pub fn contains(&self, c: Hsl) -> bool {
        if !self.hue_contains(c.h) {
            return false;
        }
        if let Some(s) = self.s {
            if !range_contains(s, c.s) {
                return false;
            }
        }
        if let Some(l) = self.l {
            if !range_contains(l, c.l) {
                return false;
            }
        }
        !(c.h.is_nan() || c.s.is_nan() || c.l.is_nan())
    }
}

// MARK: - Shape

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShapeName {
    Square,
    Dot,
    Ring,
    Arrow,
    Other,
    None,
}

impl ShapeName {
    pub fn raw(&self) -> &'static str {
        match self {
            ShapeName::Square => "square",
            ShapeName::Dot => "dot",
            ShapeName::Ring => "ring",
            ShapeName::Arrow => "arrow",
            ShapeName::Other => "other",
            ShapeName::None => "none",
        }
    }
}

type Rgb = (u8, u8, u8);

fn clip(r: RuleRect, image: &RuleImage) -> Option<RuleRect> {
    let x1 = r.x.checked_add(r.w).unwrap_or(i64::MAX);
    let y1 = r.y.checked_add(r.h).unwrap_or(i64::MAX);
    let x0 = swift_max(0, r.x);
    let y0 = swift_max(0, r.y);
    let ex = swift_min(image.width as i64, x1);
    let ey = swift_min(image.height as i64, y1);
    if !(r.w > 0 && r.h > 0 && ex > x0 && ey > y0) {
        return None;
    }
    Some(RuleRect::new(x0, y0, ex - x0, ey - y0))
}

fn median(mut a: Vec<u8>) -> u8 {
    a.sort_unstable();
    a[a.len() / 2]
}

/// Per-channel median of the 1-point ring around `r` (inside `r` when it touches the image
/// edge).
fn base_color(image: &RuleImage, r: RuleRect) -> Rgb {
    let interior = r.x > 0 && r.y > 0 && r.max_x() < image.width as i64 && r.max_y() < image.height as i64;
    let b = if interior { RuleRect::new(r.x - 1, r.y - 1, r.w + 2, r.h + 2) } else { r };
    let (mut rs, mut gs, mut bs) = (Vec::new(), Vec::new(), Vec::new());
    let mut add = |x: i64, y: i64| {
        let p = image.rgb(x, y);
        rs.push(p.0);
        gs.push(p.1);
        bs.push(p.2);
    };
    for x in b.x..b.max_x() {
        add(x, b.y);
        add(x, b.max_y() - 1);
    }
    // `stride(from:to:by: 1)` is empty when `to <= from`.
    let mut y = b.y + 1;
    while y < b.max_y() - 1 {
        add(b.x, y);
        add(b.max_x() - 1, y);
        y += 1;
    }
    (median(rs), median(gs), median(bs))
}

#[derive(Debug, Clone)]
struct Block {
    points: Vec<usize>,
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,
}

impl Block {
    fn w(&self) -> i64 {
        self.x1 - self.x0 + 1
    }
    fn h(&self) -> i64 {
        self.y1 - self.y0 + 1
    }
}

/// Largest 4-connected block of `mask` (a `gw` x `gh` grid); first found wins ties.
fn largest_block(mask: &[bool], gw: usize, gh: usize) -> Option<Block> {
    let mut seen = vec![false; mask.len()];
    let mut best: Option<Block> = None;
    let mut stack: Vec<usize> = Vec::new();
    for start in 0..mask.len() {
        if !(mask[start] && !seen[start]) {
            continue;
        }
        let (sx, sy) = ((start % gw) as i64, (start / gw) as i64);
        let mut blk = Block { points: Vec::new(), x0: sx, y0: sy, x1: sx, y1: sy };
        seen[start] = true;
        stack.push(start);
        while let Some(i) = stack.pop() {
            let x = i % gw;
            let y = i / gw;
            blk.points.push(i);
            blk.x0 = swift_min(blk.x0, x as i64);
            blk.x1 = swift_max(blk.x1, x as i64);
            blk.y0 = swift_min(blk.y0, y as i64);
            blk.y1 = swift_max(blk.y1, y as i64);
            if x > 0 && mask[i - 1] && !seen[i - 1] {
                seen[i - 1] = true;
                stack.push(i - 1);
            }
            if x + 1 < gw && mask[i + 1] && !seen[i + 1] {
                seen[i + 1] = true;
                stack.push(i + 1);
            }
            if y > 0 && mask[i - gw] && !seen[i - gw] {
                seen[i - gw] = true;
                stack.push(i - gw);
            }
            if y + 1 < gh && mask[i + gw] && !seen[i + gw] {
                seen[i + gw] = true;
                stack.push(i + gw);
            }
        }
        if best.as_ref().is_none_or(|b| blk.points.len() > b.points.len()) {
            best = Some(blk);
        }
    }
    best
}

fn median_color(image: &RuleImage, points: &[usize], gw: usize, ox: i64, oy: i64) -> Rgb {
    let mut rs = Vec::with_capacity(points.len());
    let mut gs = Vec::with_capacity(points.len());
    let mut bs = Vec::with_capacity(points.len());
    for &i in points {
        let p = image.rgb(ox + (i % gw) as i64, oy + (i / gw) as i64);
        rs.push(p.0);
        gs.push(p.1);
        bs.push(p.2);
    }
    (median(rs), median(gs), median(bs))
}

/// The enclosed hole of `c` is round (aspect 0.7...1.43, fill 0.6..<0.88) and at least half as
/// wide as `c`.
fn is_ring(c: &Block, gw: usize) -> bool {
    let w = c.w() as usize;
    let h = c.h() as usize;
    let mut in_c = vec![false; w * h];
    for &i in &c.points {
        in_c[((i / gw) as i64 - c.y0) as usize * w + ((i % gw) as i64 - c.x0) as usize] = true;
    }
    let mut outside = vec![false; w * h];
    let mut stack: Vec<usize> = Vec::new();
    let push = |x: usize, y: usize, outside: &mut Vec<bool>, stack: &mut Vec<usize>| {
        let i = y * w + x;
        if !in_c[i] && !outside[i] {
            outside[i] = true;
            stack.push(i);
        }
    };
    for x in 0..w {
        push(x, 0, &mut outside, &mut stack);
        push(x, h - 1, &mut outside, &mut stack);
    }
    for y in 0..h {
        push(0, y, &mut outside, &mut stack);
        push(w - 1, y, &mut outside, &mut stack);
    }
    while let Some(i) = stack.pop() {
        let x = i % w;
        let y = i / w;
        if x > 0 {
            push(x - 1, y, &mut outside, &mut stack);
        }
        if x + 1 < w {
            push(x + 1, y, &mut outside, &mut stack);
        }
        if y > 0 {
            push(x, y - 1, &mut outside, &mut stack);
        }
        if y + 1 < h {
            push(x, y + 1, &mut outside, &mut stack);
        }
    }
    let holes: Vec<bool> = (0..w * h).map(|i| !in_c[i] && !outside[i]).collect();
    let Some(hole) = largest_block(&holes, w, h) else { return false };
    let aspect = hole.w() as f64 / hole.h() as f64;
    let fill = hole.points.len() as f64 / (hole.w() * hole.h()) as f64;
    aspect >= 0.7 && aspect <= 1.43 && fill >= 0.6 && fill < 0.88 && hole.w() as f64 >= 0.5 * w as f64
}

/// The shape in `rect` and how sure the guess is.
pub fn shape(image: &RuleImage, rect: RuleRect) -> (ShapeName, f64) {
    let Some(r) = clip(rect, image) else { return (ShapeName::None, 0.0) };
    let base = base_color(image, r);
    let (rw, rh) = (r.w as usize, r.h as usize);
    let mut mask = vec![false; rw * rh];
    for y in 0..rh {
        for x in 0..rw {
            if color_distance(image.rgb(r.x + x as i64, r.y + y as i64), base) >= BLOB_CONTRAST {
                mask[y * rw + x] = true;
            }
        }
    }
    let Some(c) = largest_block(&mask, rw, rh) else { return (ShapeName::None, 0.0) };

    let mut k = c.clone();
    let mut gw = rw;
    // Container: a big block with a different-coloured thing inside it; judge the inside.
    // A ring (round hole, thin wall) is not a container: its hole is the page showing through.
    let c_is_ring = is_ring(&c, rw);
    if !c_is_ring && c.w() as f64 >= 0.75 * r.w as f64 && c.h() as f64 >= 0.75 * r.h as f64 {
        let ix = (0.2 * c.w() as f64).round() as i64;
        let iy = (0.2 * c.h() as f64).round() as i64;
        let iw = c.w() - 2 * ix;
        let ih = c.h() - 2 * iy;
        if iw > 0 && ih > 0 {
            let bg = median_color(image, &c.points, rw, r.x, r.y);
            let (iwu, ihu) = (iw as usize, ih as usize);
            let mut inner = vec![false; iwu * ihu];
            let mut n = 0i64;
            for y in 0..ihu {
                for x in 0..iwu {
                    let px = image.rgb(r.x + c.x0 + ix + x as i64, r.y + c.y0 + iy + y as i64);
                    if color_distance(px, bg) >= BLOB_CONTRAST {
                        inner[y * iwu + x] = true;
                        n += 1;
                    }
                }
            }
            if n as f64 >= 0.04 * (iw * ih) as f64 {
                if let Some(b) = largest_block(&inner, iwu, ihu) {
                    k = b;
                    gw = iwu;
                }
            }
        }
    }
    let w = k.w();
    let h = k.h();
    let fill = k.points.len() as f64 / (w * h) as f64;
    let aspect = w as f64 / h as f64;
    if !(aspect >= 0.7 && aspect <= 1.43) {
        return (ShapeName::Other, 0.0);
    }
    let centre = ((k.y0 + h / 2) * gw as i64 + (k.x0 + w / 2)) as usize;
    if fill < 0.6 && !k.points.contains(&centre) {
        return (ShapeName::Ring, 1.0 - fill);
    }
    if fill >= 0.88 {
        return (ShapeName::Square, fill);
    }
    if fill >= 0.6 {
        return (ShapeName::Dot, 1.0 - (fill - 0.785).abs() / 0.785);
    }
    (ShapeName::Arrow, 1.0 - fill)
}

/// The colour of the foreground in `rect`: the mean of the pixels that stand out from the
/// edge colour, or of the whole rect when none does.
pub fn foreground_color(image: &RuleImage, rect: RuleRect) -> Option<Hsl> {
    let r = clip(rect, image)?;
    let base = base_color(image, r);
    let (mut fr, mut fg, mut fb, mut fnn, mut ar, mut ag, mut ab) = (0i64, 0i64, 0i64, 0i64, 0i64, 0i64, 0i64);
    for y in r.y..r.max_y() {
        for x in r.x..r.max_x() {
            let p = image.rgb(x, y);
            ar += p.0 as i64;
            ag += p.1 as i64;
            ab += p.2 as i64;
            if color_distance(p, base) >= BLOB_CONTRAST {
                fr += p.0 as i64;
                fg += p.1 as i64;
                fb += p.2 as i64;
                fnn += 1;
            }
        }
    }
    if fnn > 0 {
        return Some(hsl((fr / fnn) as u8, (fg / fnn) as u8, (fb / fnn) as u8));
    }
    let n = r.w * r.h;
    Some(hsl((ar / n) as u8, (ag / n) as u8, (ab / n) as u8))
}

// MARK: - Thumbnails

/// Box-averaged grey thumbnail of `r` (clipped), at most `max_dim` on a side.
fn thumbnail(image: &RuleImage, r: RuleRect, max_dim: i64) -> (i64, i64, Vec<u8>) {
    let tw = swift_min(r.w, max_dim);
    let th = swift_min(r.h, max_dim);
    let cells = (tw * th) as usize;
    let mut sum = vec![0i64; cells];
    let mut cnt = vec![0i64; cells];
    let px = &image.pixels;
    for y in 0..r.h {
        let row = (y * th / r.h) * tw;
        let mut i = (((r.y + y) * image.width as i64 + r.x) * 4) as usize;
        for x in 0..r.w {
            let cell = (row + x * tw / r.w) as usize;
            sum[cell] += (px[i + 2] as i64 * 77 + px[i + 1] as i64 * 150 + px[i] as i64 * 29) >> 8;
            cnt[cell] += 1;
            i += 4;
        }
    }
    let v = (0..cells).map(|j| (sum[j] / swift_max(1, cnt[j])) as u8).collect();
    (tw, th, v)
}

const FNV_OFFSET: u64 = 14695981039346656037;
const FNV_PRIME: u64 = 1099511628211;

fn fnv(hash: &mut u64, bytes: &[u8]) {
    for &b in bytes {
        *hash = (*hash ^ b as u64).wrapping_mul(FNV_PRIME);
    }
}

/// `UInt8(truncatingIfNeeded:)` of the rect's size, low byte first.
fn size_bytes(r: RuleRect) -> [u8; 4] {
    [r.w as u8, (r.w >> 8) as u8, r.h as u8, (r.h >> 8) as u8]
}

// MARK: - Evaluation

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SignalResult {
    pub holds: bool,
    /// Only for count signals.
    pub count: Option<i64>,
}

#[derive(Debug, Clone)]
struct Shot {
    at: f64,
    rw: i64,
    rh: i64,
    #[allow(dead_code)] // kept as Swift keeps it
    w: i64,
    #[allow(dead_code)]
    h: i64,
    v: Vec<u8>,
}

#[derive(Debug, Clone)]
struct TextState {
    digest: u64,
    lines: Vec<Vec<String>>,
    at: f64,
}

/// A frameless tick keeps a motion signal's last result this long after the last frame
/// (capture sends changed frames only, so a 1 fps feed has a frame every second); after that
/// no frame means no change.
const MOTION_KEEP: f64 = 1.5;
const HISTORY_SECONDS: f64 = 3.0;
const MOTION_DIFF: i64 = 16;
/// The key an inline signal region is resolved under.
const INLINE_PREFIX: &str = "\u{0}sig:";

/// Evaluates every signal of a pack for one frame. Keeps the history motion and text need.
pub struct SignalEvaluator {
    caps: BTreeSet<String>,
    text: Option<Box<dyn TextReader>>,
    last: BTreeMap<String, SignalResult>,
    last_frame_at: Option<f64>,
    /// signal -> per rect index -> recent thumbnails
    motion: HashMap<String, Vec<Vec<Shot>>>,
    texts: HashMap<String, TextState>,
    /// One round's OCR results by rect: signals reading the same rect with an unchanged digest
    /// share a call.
    shared: HashMap<RuleRect, (u64, Vec<String>)>,
}

impl SignalEvaluator {
    pub fn new(caps: BTreeSet<String>, text: Option<Box<dyn TextReader>>) -> Self {
        SignalEvaluator {
            caps,
            text,
            last: BTreeMap::new(),
            last_frame_at: None,
            motion: HashMap::new(),
            texts: HashMap::new(),
            shared: HashMap::new(),
        }
    }

    /// Pack or variants changed.
    pub fn reset(&mut self) {
        self.last.clear();
        self.motion.clear();
        self.texts.clear();
        self.last_frame_at = None;
    }

    /// `image == None`: no new frame since the last call, so earlier results stand; `motion`
    /// too while the last frame is at most `MOTION_KEEP` old, then it is false.
    pub fn evaluate(
        &mut self,
        pack: &RulePack,
        regions: &BTreeMap<String, Vec<RuleRect>>,
        image: Option<&RuleImage>,
        now: f64,
    ) -> BTreeMap<String, SignalResult> {
        let mut regions = regions.clone();
        if image.is_some() {
            self.last_frame_at = Some(now);
        }
        let recent = self.last_frame_at.map(|t| now - t <= MOTION_KEEP).unwrap_or(false);
        // signal -> inline region key
        let mut keys: BTreeMap<String, String> = BTreeMap::new();
        if let Some(image) = image {
            let mut p_regions = pack.regions.clone();
            for (name, s) in &pack.signals {
                if let Some(RegionRef::Inline(spec)) = &s.region {
                    let key = format!("{INLINE_PREFIX}{name}");
                    p_regions.insert(key.clone(), (**spec).clone());
                    keys.insert(name.clone(), key);
                }
            }
            if !keys.is_empty() {
                for (k, v) in resolve_region_table(&p_regions, image) {
                    if k.starts_with(INLINE_PREFIX) {
                        regions.insert(k, v);
                    }
                }
            }
        }
        let mut out = BTreeMap::new();
        self.shared.clear();
        for (name, sig) in &pack.signals {
            let usable = sig.usable && sig.needs.is_subset(&self.caps);
            let has_motion = sig.detects.iter().any(|d| matches!(d, Detect::Motion { .. }));
            if !usable {
                out.insert(name.clone(), SignalResult { holds: false, count: None });
                continue;
            }
            let Some(image) = image else {
                if has_motion && !recent {
                    let count = if self.last.get(name).and_then(|r| r.count).is_none() { None } else { Some(0) };
                    out.insert(name.clone(), SignalResult { holds: false, count });
                } else {
                    let r = self.last.get(name).copied().unwrap_or(SignalResult { holds: false, count: None });
                    out.insert(name.clone(), r);
                }
                continue;
            };
            let rects: Vec<RuleRect> = match &sig.region {
                Some(RegionRef::Named(n)) => regions.get(n).cloned().unwrap_or_default(),
                Some(RegionRef::Inline(_)) => keys.get(name).and_then(|k| regions.get(k)).cloned().unwrap_or_default(),
                None => Vec::new(),
            };
            if rects.is_empty() {
                out.insert(name.clone(), SignalResult { holds: false, count: None });
                self.motion.remove(name);
                self.texts.remove(name);
                continue;
            }
            let r = self.evaluate_signal(name, sig, &rects, image, now);
            out.insert(name.clone(), r);
        }
        self.last = out.clone();
        out
    }

    fn evaluate_signal(&mut self, name: &str, sig: &SignalSpec, rects: &[RuleRect], image: &RuleImage, now: f64) -> SignalResult {
        let clipped: Vec<Option<RuleRect>> = rects.iter().map(|r| clip(*r, image)).collect();
        let mut hit: Vec<bool> = clipped.iter().map(|c| c.is_some()).collect();
        for d in &sig.detects {
            match d {
                Detect::Present => {}
                Detect::Shape(want, min) => {
                    for i in 0..rects.len() {
                        if hit[i] {
                            let s = shape(image, clipped[i].expect("hit implies clipped"));
                            hit[i] = s.0.raw() == want && s.1 >= *min;
                        }
                    }
                }
                Detect::Color(range) => {
                    for i in 0..rects.len() {
                        if hit[i] {
                            hit[i] = foreground_color(image, clipped[i].expect("hit implies clipped"))
                                .map(|c| range.contains(c))
                                .unwrap_or(false);
                        }
                    }
                }
                Detect::Motion { window, min } => {
                    let m = self.motion_hits(name, &clipped, image, now, *window, *min);
                    for i in 0..rects.len() {
                        hit[i] = hit[i] && m[i];
                    }
                }
                Detect::Text(patterns) => {
                    let lines = self.read_text(name, &clipped, image, now);
                    for i in 0..rects.len() {
                        if hit[i] {
                            hit[i] = text_matches(patterns, &lines[i]);
                        }
                    }
                }
            }
        }
        let n = hit.iter().filter(|h| **h).count() as i64;
        SignalResult { holds: n >= 1, count: if sig.count { Some(n) } else { None } }
    }

    fn motion_hits(
        &mut self,
        name: &str,
        rects: &[Option<RuleRect>],
        image: &RuleImage,
        now: f64,
        window: f64,
        min: f64,
    ) -> Vec<bool> {
        let mut hist = self.motion.get(name).cloned().unwrap_or_default();
        hist.truncate(rects.len());
        while hist.len() < rects.len() {
            hist.push(Vec::new());
        }
        let mut out = vec![false; rects.len()];
        for i in 0..rects.len() {
            let Some(r) = rects[i] else {
                hist[i] = Vec::new();
                continue;
            };
            let cur = thumbnail(image, r, 16);
            let mut shots: Vec<Shot> =
                hist[i].iter().filter(|s| now - s.at <= HISTORY_SECONDS && s.at <= now).cloned().collect();
            if let Some(f) = shots.first() {
                if f.rw != r.w || f.rh != r.h {
                    shots.clear();
                }
            }
            // Newest shot at least `window` old, else the oldest one.
            let reference = shots.iter().rev().find(|s| now - s.at >= window).or(shots.first());
            if let Some(reference) = reference {
                let mut changed = 0i64;
                for j in 0..cur.2.len() {
                    if (cur.2[j] as i64 - reference.v[j] as i64).abs() >= MOTION_DIFF {
                        changed += 1;
                    }
                }
                out[i] = changed > 0 && changed as f64 / cur.2.len() as f64 >= min;
            }
            shots.push(Shot { at: now, rw: r.w, rh: r.h, w: cur.0, h: cur.1, v: cur.2 });
            hist[i] = shots;
        }
        self.motion.insert(name.to_string(), hist);
        out
    }

    fn read_text(&mut self, name: &str, rects: &[Option<RuleRect>], image: &RuleImage, now: f64) -> Vec<Vec<String>> {
        let mut digest = FNV_OFFSET;
        fnv(&mut digest, &[rects.len() as u8]);
        for r in rects {
            let Some(r) = r else {
                fnv(&mut digest, &[0]);
                continue;
            };
            let t = thumbnail(image, *r, 32);
            fnv(&mut digest, &size_bytes(*r));
            fnv(&mut digest, &t.2);
        }
        // Swift's `text?.ready == false`: only a present reader that is not ready.
        if self.text.as_ref().is_some_and(|t| !t.ready()) {
            return vec![Vec::new(); rects.len()];
        }
        if let Some(prev) = self.texts.get(name) {
            if prev.lines.len() == rects.len() && (prev.digest == digest || now - prev.at < TEXT_EVERY) {
                return prev.lines.clone();
            }
        }
        let Some(text) = self.text.as_mut() else { return vec![Vec::new(); rects.len()] };
        let mut lines: Vec<Vec<String>> = Vec::with_capacity(rects.len());
        for r in rects {
            let Some(r) = *r else {
                lines.push(Vec::new());
                continue;
            };
            let mut d = FNV_OFFSET;
            fnv(&mut d, &size_bytes(r));
            fnv(&mut d, &thumbnail(image, r, 32).2);
            if let Some(hit) = self.shared.get(&r) {
                if hit.0 == d {
                    lines.push(hit.1.clone());
                    continue;
                }
            }
            let l = text.lines(image, r);
            self.shared.insert(r, (d, l.clone()));
            lines.push(l);
        }
        self.texts.insert(name.to_string(), TextState { digest, lines: lines.clone(), at: now });
        lines
    }
}
