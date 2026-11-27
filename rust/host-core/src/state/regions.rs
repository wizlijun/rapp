//! Resolving a pack's regions on one frame (`StateRules/Regions.swift`).
//!
//! Never panics on pack numbers: numbers from a hostile pack are clamped to the image before
//! they become pixel indices.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use super::rule_image::{color_distance, RuleImage, RuleRect, BLOB_CONTRAST, REGION_CONTRAST};
use super::rule_pack::{
    range_contains, BlobSpec, BoxSpec, EdgeSpec, Length, Pick, RegionRef, RegionSpec, RulePack, Side, StripSpec,
};
use crate::geometry::{swift_max, swift_min};

/// Every region the pack names, resolved; a missing region has no entry. Single regions have
/// one rect. Swift's signature: `resolveRegions(_ pack: RulePack, in image: RuleImage)`
/// (Regions.swift:5).
pub fn resolve_regions(pack: &RulePack, image: &RuleImage) -> BTreeMap<String, Vec<RuleRect>> {
    resolve_region_table(&pack.regions, image)
}

/// The same walk over a bare region table. The resolver reads nothing of the pack but its
/// regions; `SignalEvaluator::evaluate` uses this to add its inline regions without cloning the
/// whole pack (Swift copies the pack, Detectors.swift:270-272).
pub(crate) fn resolve_region_table(
    regions: &BTreeMap<String, RegionSpec>,
    image: &RuleImage,
) -> BTreeMap<String, Vec<RuleRect>> {
    let mut resolver = RegionResolver::new(regions, image);
    let mut out = BTreeMap::new();
    // `pack.regions.keys.sorted()`: BTreeMap keys are already in byte order, which is
    // Swift's `String` `<` for these names (see the notes on non-ASCII names).
    for name in regions.keys() {
        if let Some(rects) = resolver.named(name) {
            if !rects.is_empty() {
                out.insert(name.clone(), rects);
            }
        }
    }
    out
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Hug {
    Low,
    High,
}

struct RegionResolver<'a> {
    regions: &'a BTreeMap<String, RegionSpec>,
    image: &'a RuleImage,
    cache: HashMap<String, Option<Vec<RuleRect>>>,
    /// Names being resolved, outermost first.
    stack: Vec<String>,
    /// Every region on a reference cycle; always resolves to `None`.
    cyclic: BTreeSet<String>,
}

const BLOB_LIMIT: usize = 512;

impl<'a> RegionResolver<'a> {
    fn new(regions: &'a BTreeMap<String, RegionSpec>, image: &'a RuleImage) -> Self {
        RegionResolver { regions, image, cache: HashMap::new(), stack: Vec::new(), cyclic: BTreeSet::new() }
    }

    fn whole(&self) -> RuleRect {
        RuleRect::new(0, 0, self.image.width as i64, self.image.height as i64)
    }

    fn named(&mut self, name: &str) -> Option<Vec<RuleRect>> {
        if self.cyclic.contains(name) {
            return None;
        }
        if let Some(hit) = self.cache.get(name) {
            return hit.clone();
        }
        let spec = self.regions.get(name)?;
        if let Some(at) = self.stack.iter().position(|s| s == name) {
            // Reached again while resolving: everything from there up is on the cycle.
            for s in &self.stack[at..] {
                self.cyclic.insert(s.clone());
            }
            return None;
        }
        self.stack.push(name.to_string());
        let r = self.resolve_spec(spec);
        self.stack.pop();
        if self.cyclic.contains(name) {
            return None;
        }
        self.cache.insert(name.to_string(), r.clone());
        r
    }

    fn resolve_ref(&mut self, r: &RegionRef) -> Option<Vec<RuleRect>> {
        match r {
            RegionRef::Named(n) => self.named(n),
            RegionRef::Inline(s) => self.resolve_spec(s),
        }
    }

    /// The container is the first rect of a reference; a missing `in` is the whole image.
    fn container(&mut self, r: Option<&RegionRef>) -> Option<RuleRect> {
        let Some(r) = r else { return Some(self.whole()) };
        let first = *self.resolve_ref(r)?.first()?;
        if first.w > 0 && first.h > 0 {
            Some(first)
        } else {
            None
        }
    }

    fn resolve_spec(&mut self, spec: &RegionSpec) -> Option<Vec<RuleRect>> {
        let rects = match spec {
            RegionSpec::Box(b) => self.box_region(b).map(|r| vec![r]),
            RegionSpec::Edge(e) => self.edge(e).map(|r| vec![r]),
            RegionSpec::Blob(b) => self.blob(b),
            RegionSpec::Strip(s) => self.strip(s).map(|r| vec![r]),
            RegionSpec::Unknown => None,
        };
        match rects {
            Some(r) if !r.is_empty() => Some(r),
            _ => None,
        }
    }

    // MARK: box

    fn box_region(&mut self, b: &BoxSpec) -> Option<RuleRect> {
        let c = self.container(b.inside.as_ref())?;
        let mut min_x = c.x as f64;
        let mut max_x = c.max_x() as f64;
        let mut min_y = c.y as f64;
        let mut max_y = c.max_y() as f64;
        let mut hug_x = Hug::Low;
        let mut hug_y = Hug::Low;
        // A constraint pointing at a region that cannot be found does not count (spec §6.1).
        // A target on a cycle poisons this region too (not found, but not ignorable).
        let target = |this: &mut Self, n: &Option<String>| -> (Option<RuleRect>, bool) {
            let Some(n) = n else { return (None, false) };
            let r = this.named(n).and_then(|v| v.first().copied());
            (r, this.cyclic.contains(n.as_str()))
        };
        let rel = [
            target(self, &b.right_of),
            target(self, &b.left_of),
            target(self, &b.below),
            target(self, &b.above),
        ];
        if rel.iter().any(|t| t.1) {
            return None;
        }
        if let Some(r) = rel[0].0 {
            min_x = swift_max(min_x, r.max_x() as f64);
            hug_x = Hug::Low;
        }
        if let Some(r) = rel[1].0 {
            max_x = swift_min(max_x, r.x as f64);
            hug_x = Hug::High;
        }
        if let Some(r) = rel[2].0 {
            min_y = swift_max(min_y, r.max_y() as f64);
            hug_y = Hug::Low;
        }
        if let Some(r) = rel[3].0 {
            max_y = swift_min(max_y, r.y as f64);
            hug_y = Hug::High;
        }
        if !(max_x > min_x && max_y > min_y) {
            return None;
        }
        let xs = solve(min_x, max_x, b.left, b.right, b.width, hug_x)?;
        let ys = solve(min_y, max_y, b.top, b.bottom, b.height, hug_y)?;
        let x0 = swift_max(xs.0, min_x);
        let x1 = swift_min(xs.1, max_x);
        let y0 = swift_max(ys.0, min_y);
        let y1 = swift_min(ys.1, max_y);
        if !(x1 > x0 && y1 > y0) {
            return None;
        }
        // x0...x1 are within the container, so the conversions are in range.
        let rx0 = x0.round() as i64;
        let rx1 = x1.round() as i64;
        let ry0 = y0.round() as i64;
        let ry1 = y1.round() as i64;
        if !(rx1 > rx0 && ry1 > ry0) {
            return None;
        }
        Some(RuleRect::new(rx0, ry0, rx1 - rx0, ry1 - ry0))
    }

    // MARK: edge

    fn edge(&mut self, e: &EdgeSpec) -> Option<RuleRect> {
        let c = self.container(e.inside.as_ref())?;
        if e.min.is_nan() || e.max.is_nan() || !(e.min <= e.max) {
            return None;
        }
        let horizontal = e.from == Side::Left || e.from == Side::Right;
        // How far we can scan.
        let length = if horizontal { c.w } else { c.h };
        if !(e.max >= 0.0 && e.min < length as f64) {
            return None;
        }
        let lo = swift_max(0.0, e.min).floor() as i64;
        let hi = swift_min((length - 1) as f64, e.max).floor() as i64;
        if hi <= lo {
            return None;
        }
        // `d` is the distance from the starting side.
        let position = |d: i64| -> i64 {
            match e.from {
                Side::Left => c.x + d,
                Side::Right => c.max_x() - 1 - d,
                Side::Top => c.y + d,
                Side::Bottom => c.max_y() - 1 - d,
            }
        };
        let reference = self.signature(c, horizontal, position(lo));
        for d in (lo + 1)..=hi {
            if color_distance(self.signature(c, horizontal, position(d)), reference) >= REGION_CONTRAST {
                return Some(match e.from {
                    Side::Left => RuleRect::new(c.x, c.y, d, c.h),
                    Side::Right => RuleRect::new(c.max_x() - d, c.y, d, c.h),
                    Side::Top => RuleRect::new(c.x, c.y, c.w, d),
                    Side::Bottom => RuleRect::new(c.x, c.max_y() - d, c.w, d),
                });
            }
        }
        None
    }

    /// Per-channel median of the pixels of one column (or row) between 10% and 90% of its
    /// length, every 4th.
    fn signature(&self, c: RuleRect, horizontal: bool, pos: i64) -> (u8, u8, u8) {
        let len = if horizontal { c.h } else { c.w };
        let start = if horizontal { c.y } else { c.x };
        let from = len / 10;
        let to = swift_max(from, len * 9 / 10);
        let (mut rs, mut gs, mut bs) = (Vec::new(), Vec::new(), Vec::new());
        let mut i = from;
        loop {
            let p = start + swift_min(i, len - 1);
            let px = if horizontal { self.image.rgb(pos, p) } else { self.image.rgb(p, pos) };
            rs.push(px.0);
            gs.push(px.1);
            bs.push(px.2);
            i += 4;
            if i > to {
                break;
            }
        }
        (median(rs), median(gs), median(bs))
    }

    // MARK: blob

    fn blob(&mut self, b: &BlobSpec) -> Option<Vec<RuleRect>> {
        let c = self.container(Some(&b.inside))?;
        let image = self.image;
        // Background: the most common colour at 4 bits per channel (mean of that bin).
        let mut count = vec![0i64; 4096];
        let mut sum = vec![(0i64, 0i64, 0i64); 4096];
        for y in c.y..c.max_y() {
            for x in c.x..c.max_x() {
                let p = image.rgb(x, y);
                let k = ((p.0 >> 4) as usize) << 8 | ((p.1 >> 4) as usize) << 4 | (p.2 >> 4) as usize;
                count[k] += 1;
                sum[k].0 += p.0 as i64;
                sum[k].1 += p.1 as i64;
                sum[k].2 += p.2 as i64;
            }
        }
        let mut best = 0usize;
        for k in 1..4096 {
            if count[k] > count[best] {
                best = k;
            }
        }
        let n = count[best];
        // `n` is never 0: the container has at least one pixel. Swift traps on a zero
        // divisor, and so does this.
        let bg = ((sum[best].0 / n) as u8, (sum[best].1 / n) as u8, (sum[best].2 / n) as u8);

        let cw = c.w as usize;
        let ch = c.h as usize;
        let mut seen = vec![false; cw * ch];
        let mut found: Vec<RuleRect> = Vec::new();
        let mut stack: Vec<usize> = Vec::new();
        let mut blobs = 0usize;
        'scan: for y in 0..ch {
            for x in 0..cw {
                let idx = y * cw + x;
                if seen[idx] {
                    continue;
                }
                let p = image.rgb(c.x + x as i64, c.y + y as i64);
                if color_distance(p, bg) < BLOB_CONTRAST {
                    seen[idx] = true;
                    continue;
                }
                if blobs >= BLOB_LIMIT {
                    break 'scan;
                }
                blobs += 1;
                let (mut x0, mut x1, mut y0, mut y1) = (x as i64, x as i64, y as i64, y as i64);
                seen[idx] = true;
                stack.push(idx);
                while let Some(i) = stack.pop() {
                    let cx = (i % cw) as i64;
                    let cy = (i / cw) as i64;
                    x0 = swift_min(x0, cx);
                    x1 = swift_max(x1, cx);
                    y0 = swift_min(y0, cy);
                    y1 = swift_max(y1, cy);
                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                        if !(nx >= 0 && ny >= 0 && nx < c.w && ny < c.h) {
                            continue;
                        }
                        let j = (ny * c.w + nx) as usize;
                        if seen[j] {
                            continue;
                        }
                        seen[j] = true;
                        if color_distance(image.rgb(c.x + nx, c.y + ny), bg) >= BLOB_CONTRAST {
                            stack.push(j);
                        }
                    }
                }
                let w = x1 - x0 + 1;
                let h = y1 - y0 + 1;
                if !(range_contains(b.size, w as f64) && range_contains(b.size, h as f64)) {
                    continue;
                }
                if b.round {
                    let r = w as f64 / h as f64;
                    if !(0.75..=1.33).contains(&r) {
                        continue;
                    }
                }
                found.push(RuleRect::new(c.x + x0, c.y + y0, w, h));
            }
        }
        if found.is_empty() {
            return None;
        }
        Some(match b.pick {
            Pick::All => {
                // Stable, as Swift's `sort` is in practice.
                found.sort_by_key(|a| (a.y, a.x));
                found
            }
            Pick::Rightmost => vec![first_max_by(&found, |a, b| (a.max_x(), -a.y) < (b.max_x(), -b.y))],
            Pick::Leftmost => vec![first_min_by(&found, |a, b| (a.x, a.y) < (b.x, b.y))],
            Pick::Topmost => vec![first_min_by(&found, |a, b| (a.y, a.x) < (b.y, b.x))],
            Pick::Bottommost => vec![first_max_by(&found, |a, b| (a.max_y(), -a.x) < (b.max_y(), -b.x))],
            Pick::Largest => vec![first_max_by(&found, |a, b| a.w * a.h < b.w * b.h)],
        })
    }

    // MARK: strip

    fn strip(&mut self, s: &StripSpec) -> Option<RuleRect> {
        let c = self.container(Some(&s.of))?;
        // NaN fails `> 0`.
        if !(s.width > 0.0) {
            return None;
        }
        let horizontal = s.side == Side::Left || s.side == Side::Right;
        let w = swift_min(s.width, (if horizontal { c.w } else { c.h }) as f64).round() as i64;
        if w <= 0 {
            return None;
        }
        Some(match s.side {
            Side::Left => RuleRect::new(c.x, c.y, w, c.h),
            Side::Right => RuleRect::new(c.max_x() - w, c.y, w, c.h),
            Side::Top => RuleRect::new(c.x, c.y, c.w, w),
            Side::Bottom => RuleRect::new(c.x, c.max_y() - w, c.w, w),
        })
    }
}

/// One axis of a box. Returns `None` on NaN. Infinite numbers pass through and are clipped by
/// the caller.
fn solve(lo: f64, hi: f64, near: Option<Length>, far: Option<Length>, size: Option<Length>, hug: Hug) -> Option<(f64, f64)> {
    let span = hi - lo;
    let v = |l: Option<Length>| -> Option<f64> {
        match l {
            Some(Length::Points(p)) => Some(p),
            Some(Length::Percent(p)) => Some(p * span / 100.0),
            None => None,
        }
    };
    let (n, f, s) = (v(near), v(far), v(size));
    if [n, f, s].iter().any(|x| x.is_some_and(f64::is_nan)) {
        return None;
    }
    Some(match (n, f, s) {
        (Some(n), Some(f), _) => (lo + n, hi - f),
        (Some(n), None, Some(s)) => (lo + n, lo + n + s),
        (None, Some(f), Some(s)) => (hi - f - s, hi - f),
        (None, None, Some(s)) => {
            if hug == Hug::Low {
                (lo, lo + s)
            } else {
                (hi - s, hi)
            }
        }
        (Some(n), None, None) => (lo + n, hi),
        (None, Some(f), None) => (lo, hi - f),
        (None, None, None) => (lo, hi),
    })
}

fn median(mut a: Vec<u8>) -> u8 {
    a.sort_unstable();
    a[a.len() / 2]
}

/// Swift's `max(by:)`: the first element no later element is "greater than"; it replaces the
/// running maximum only when `less(current, next)`. `items` is not empty.
pub(crate) fn first_max_by<T: Copy>(items: &[T], less: impl Fn(&T, &T) -> bool) -> T {
    let mut best = items[0];
    for e in &items[1..] {
        if less(&best, e) {
            best = *e;
        }
    }
    best
}

/// Swift's `min(by:)`: replaces the running minimum only when `less(next, current)`.
pub(crate) fn first_min_by<T: Copy>(items: &[T], less: impl Fn(&T, &T) -> bool) -> T {
    let mut best = items[0];
    for e in &items[1..] {
        if less(e, &best) {
            best = *e;
        }
    }
    best
}
