//! Focus pane rules 3-8 as a pure state machine (`Sources/RappCore/FocusTracker.swift`).
//!
//! The host feeds it input, window-table changes, query results and per-frame tiles, ticks
//! it every 0.1 s, and carries out the actions it returns. All time comes in as `now`; there
//! are no clocks here. Rects are window points. An output of `[]` means the whole window is
//! the focus.

use super::pane::{panel, PanelMiss, PanelPick, WindowTiles, MAX_SHARE};
use crate::geometry::{union_opt, Point, Rect, Size};
use std::collections::HashSet;

/// Why an output was sent. `name` is Swift's raw value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Cause {
    On,
    Key,
    Click,
    Scroll,
    Hover,
    Follow,
    Notify,
    Resize,
    Window,
    Lock,
}

impl Cause {
    pub fn name(self) -> &'static str {
        match self {
            Cause::On => "on",
            Cause::Key => "key",
            Cause::Click => "click",
            Cause::Scroll => "scroll",
            Cause::Hover => "hover",
            Cause::Follow => "follow",
            Cause::Notify => "notify",
            Cause::Resize => "resize",
            Cause::Window => "window",
            Cause::Lock => "lock",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Query {
    Keyboard,
    Pointer(Point),
    Follow(Point),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Output {
    pub window: u32,
    /// `[]` = whole window.
    pub rects: Vec<Rect>,
    pub cause: Cause,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// The query and the generation its answer must carry.
    Query(Query, i64),
    Send(Output),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pointer {
    Click,
    Drag,
    Scroll,
    Move,
}

pub const HOVER_DELAY: f64 = 0.5;
pub const KEY_RECHECK: f64 = 0.2;
pub const FOLLOW_WINDOW: f64 = 1.0;
pub const FOLLOW_SHARE: f64 = 0.15;
pub const SEND_INTERVAL: f64 = 0.3;
pub const SETTLE: f64 = 2.0;
pub const MIN_WINDOW: Size = Size::new(480.0, 320.0);
/// Slack for comparing elapsed times built from decimal steps (1.2 - 1 < 0.2 in doubles).
const EPSILON: f64 = 1e-6;

/// A tile as Swift's `TileKey` hashes it: min x, min y, width, height. `+ 0.0` folds -0
/// into 0, as `CGFloat`'s `Hashable` does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct TileKey([u64; 4]);

impl TileKey {
    fn of(r: &Rect) -> TileKey {
        TileKey([
            (r.min_x() + 0.0).to_bits(),
            (r.min_y() + 0.0).to_bits(),
            (r.w() + 0.0).to_bits(),
            (r.h() + 0.0).to_bits(),
        ])
    }
}

#[derive(Debug, Clone)]
pub struct FocusTracker {
    generation: i64,
    keyboard_panel: Option<Rect>,
    keyboard_miss: Option<PanelMiss>,
    pointer_panel: Option<Rect>,
    pointer_miss: Option<PanelMiss>,
    follow_panel: Option<Rect>,

    started: bool,
    window_id: Option<u32>,
    size: Size,
    appeared: Option<f64>,
    is_locked: bool,

    keyboard_cause: Cause,
    pointer_cause: Cause,
    recheck_at: Option<f64>,
    recheck_cause: Cause,
    hover: Option<(Point, f64)>,
    last_pointer: Option<Point>,
    copy_bounds: Option<Rect>,

    action_at: Option<f64>,
    follow_tiles: HashSet<TileKey>,
    /// `None` is Swift's `CGRect.null`.
    follow_box: Option<Rect>,
    follow_asked: Option<Point>,

    last_cause: Cause,
    sent: Option<Output>,
    sent_at: Option<f64>,
}

impl Default for FocusTracker {
    fn default() -> Self {
        FocusTracker::new()
    }
}

impl FocusTracker {
    pub fn new() -> FocusTracker {
        FocusTracker {
            generation: 0,
            keyboard_panel: None,
            keyboard_miss: None,
            pointer_panel: None,
            pointer_miss: None,
            follow_panel: None,
            started: false,
            window_id: None,
            size: Size::new(0.0, 0.0),
            appeared: None,
            is_locked: false,
            keyboard_cause: Cause::On,
            pointer_cause: Cause::Click,
            recheck_at: None,
            recheck_cause: Cause::Key,
            hover: None,
            last_pointer: None,
            copy_bounds: None,
            action_at: None,
            follow_tiles: HashSet::new(),
            follow_box: None,
            follow_asked: None,
            last_cause: Cause::On,
            sent: None,
            sent_at: None,
        }
    }

    /// Bumped when the focused window or its size changes; results of an older generation are dropped.
    pub fn generation(&self) -> i64 {
        self.generation
    }
    pub fn keyboard_panel(&self) -> Option<Rect> {
        self.keyboard_panel
    }
    pub fn keyboard_miss(&self) -> Option<PanelMiss> {
        self.keyboard_miss
    }
    pub fn pointer_panel(&self) -> Option<Rect> {
        self.pointer_panel
    }
    /// Reason of the last pointer query when it failed; `None` after a success or before any query.
    pub fn pointer_miss(&self) -> Option<PanelMiss> {
        self.pointer_miss
    }
    pub fn follow_panel(&self) -> Option<Rect> {
        self.follow_panel
    }

    // MARK: inputs

    pub fn start(&mut self, now: f64) -> Vec<Action> {
        self.started = true;
        let mut actions = self.query_keyboard(Cause::On);
        actions.extend(self.update(Cause::On, now));
        actions
    }

    pub fn window(&mut self, id: Option<u32>, size: Size, appeared: Option<f64>, now: f64) -> Vec<Action> {
        self.appeared = appeared;
        if id == self.window_id && size == self.size {
            return if self.started { self.update(self.last_cause, now) } else { Vec::new() };
        }
        let resized = id.is_some() && id == self.window_id;
        self.window_id = id;
        self.size = size;
        self.generation += 1;
        // Any resize makes every panel rect stale: drop them all, show the whole window, and ask
        // the keyboard and the last pointer point again (rules 3, 4). Positions and timers stay;
        // a new window starts from nothing.
        if resized {
            self.drop_panels();
        } else {
            self.reset_window_state();
        }
        let cause = if resized { Cause::Resize } else { Cause::Window };
        if !self.started {
            return Vec::new();
        }
        let mut actions = self.query_keyboard(cause);
        if resized {
            if let Some(p) = self.last_pointer {
                if Rect::new(0.0, 0.0, size.width, size.height).contains_point(p) {
                    actions.extend(self.query_pointer(p, Cause::Resize));
                }
            }
            // B clears on the size change; send the whole window now, past the throttle, so A's
            // last-sent output never claims old rects are showing.
            self.sent = None;
            self.sent_at = None;
        }
        actions.extend(self.update(cause, now));
        actions
    }

    pub fn locked(&mut self, on: bool, now: f64) -> Vec<Action> {
        self.is_locked = on;
        if self.started {
            self.update(Cause::Lock, now)
        } else {
            Vec::new()
        }
    }

    pub fn pointer(&mut self, kind: Pointer, at: Point, now: f64) -> Vec<Action> {
        if !self.active() {
            return Vec::new();
        }
        self.last_pointer = Some(at);
        if kind == Pointer::Move {
            self.hover = Some((at, now));
            return Vec::new();
        }
        self.hover = None;
        let cause = if kind == Pointer::Scroll { Cause::Scroll } else { Cause::Click };
        let mut actions = if self.in_pointer_panel(at) { Vec::new() } else { self.query_pointer(at, cause) };
        if kind == Pointer::Click {
            actions.extend(self.arm_action(Cause::Click, now));
        }
        actions
    }

    pub fn key(&mut self, now: f64) -> Vec<Action> {
        if !self.active() {
            return Vec::new();
        }
        self.arm_action(Cause::Key, now)
    }

    pub fn keyboard_changed(&mut self, _now: f64) -> Vec<Action> {
        if !self.active() {
            return Vec::new();
        }
        self.query_keyboard(Cause::Notify)
    }

    pub fn result(&mut self, q: Query, generation: i64, r: Result<PanelPick, PanelMiss>, now: f64) -> Vec<Action> {
        if !self.started || generation != self.generation || self.window_id.is_none() {
            return Vec::new();
        }
        match q {
            Query::Keyboard => {
                match r {
                    Ok(p) => {
                        self.keyboard_panel = Some(p.rect);
                        self.keyboard_miss = None;
                    }
                    Err(m) => {
                        self.keyboard_panel = None;
                        self.keyboard_miss = Some(m);
                    }
                }
                self.update(self.keyboard_cause, now)
            }
            Query::Pointer(_) => {
                match r {
                    Ok(p) => {
                        self.pointer_panel = Some(p.rect);
                        self.pointer_miss = None;
                    }
                    Err(m) => self.pointer_miss = Some(m),
                }
                self.update(self.pointer_cause, now)
            }
            Query::Follow(p) => {
                if Some(p) != self.follow_asked {
                    return Vec::new();
                }
                self.follow_asked = None;
                let Ok(pick) = r else { return Vec::new() };
                self.follow_panel = Some(pick.rect);
                self.update(Cause::Follow, now)
            }
        }
    }

    pub fn frame(&mut self, t: &WindowTiles, now: f64) -> Vec<Action> {
        if !self.active() {
            return Vec::new();
        }
        let mut actions = Vec::new();
        if let Some(c) = t.copy_bounds {
            if !c.is_empty() {
                self.copy_bounds = Some(c);
                if self.copy_fallback_applies() {
                    actions.extend(self.update(Cause::Scroll, now));
                }
            }
        }
        actions.extend(self.follow(t, now));
        actions
    }

    pub fn tick(&mut self, now: f64) -> Vec<Action> {
        if !self.started {
            return Vec::new();
        }
        let mut actions = Vec::new();
        if let Some(at) = self.recheck_at {
            if reached(at, now) {
                self.recheck_at = None;
                actions.extend(self.query_keyboard(self.recheck_cause));
            }
        }
        if let Some((point, at)) = self.hover {
            if reached(at + HOVER_DELAY, now) {
                self.hover = None;
                if !self.in_pointer_panel(point) {
                    actions.extend(self.query_pointer(point, Cause::Hover));
                }
            }
        }
        if let Some(a) = self.action_at {
            if !within(a, FOLLOW_WINDOW, now) {
                self.action_at = None;
            }
        }
        actions.extend(self.flush(now));
        actions
    }

    // MARK: state

    fn active(&self) -> bool {
        self.started && self.window_id.is_some()
    }

    fn reset_window_state(&mut self) {
        self.drop_panels();
        self.action_at = None;
        self.hover = None;
        self.recheck_at = None;
        self.last_pointer = None;
    }

    /// Forgets every rect that belongs to the old window geometry.
    fn drop_panels(&mut self) {
        self.keyboard_panel = None;
        self.keyboard_miss = None;
        self.pointer_panel = None;
        self.pointer_miss = None;
        self.follow_panel = None;
        self.follow_asked = None;
        self.follow_tiles.clear();
        self.follow_box = None;
        self.copy_bounds = None;
    }

    fn query_keyboard(&mut self, cause: Cause) -> Vec<Action> {
        if self.window_id.is_none() {
            return Vec::new();
        }
        self.keyboard_cause = cause;
        vec![Action::Query(Query::Keyboard, self.generation)]
    }

    fn query_pointer(&mut self, p: Point, cause: Cause) -> Vec<Action> {
        self.pointer_cause = cause;
        vec![Action::Query(Query::Pointer(p), self.generation)]
    }

    fn in_pointer_panel(&self, p: Point) -> bool {
        self.pointer_panel.map_or(false, |r| r.contains_point(p))
    }

    /// A click or key: recheck the keyboard in 0.2 s, clear the follow panel and watch the next second.
    fn arm_action(&mut self, cause: Cause, now: f64) -> Vec<Action> {
        if self.recheck_at.is_none() {
            self.recheck_at = Some(now + KEY_RECHECK);
            self.recheck_cause = cause;
        }
        self.action_at = Some(now);
        self.follow_tiles.clear();
        self.follow_box = None;
        self.follow_panel = None;
        self.follow_asked = None;
        self.update(cause, now)
    }

    // MARK: rule 5

    fn follow(&mut self, t: &WindowTiles, now: f64) -> Vec<Action> {
        let Some(a) = self.action_at else { return Vec::new() };
        if self.follow_asked.is_some() {
            return Vec::new();
        }
        if !within(a, FOLLOW_WINDOW, now) {
            self.action_at = None;
            return Vec::new();
        }
        let focus = self.rects(now);
        if t.full || focus.is_empty() || !(t.total > 0) {
            return Vec::new();
        }
        for tile in &t.changed {
            let c = Point::new(tile.mid_x(), tile.mid_y());
            if focus.iter().any(|f| f.contains_point(c)) {
                continue;
            }
            if self.follow_tiles.insert(TileKey::of(tile)) {
                self.follow_box = union_opt(self.follow_box, Some(*tile));
            }
        }
        if !((self.follow_tiles.len() as f64) > (t.total as f64) * FOLLOW_SHARE) {
            return Vec::new();
        }
        self.action_at = None;
        // Never null here: at least one tile went into the box.
        let b = self.follow_box.unwrap_or(Rect::ZERO);
        let c = Point::new(b.mid_x(), b.mid_y());
        self.follow_asked = Some(c);
        vec![Action::Query(Query::Follow(c), self.generation)]
    }

    // MARK: rule 6

    fn copy_fallback_applies(&self) -> bool {
        self.keyboard_miss == Some(PanelMiss::Blocked)
            && self.pointer_panel.is_none()
            && (self.pointer_miss.is_none() || self.pointer_miss == Some(PanelMiss::Blocked))
    }

    fn copy_panel(&self) -> Option<Rect> {
        if !self.copy_fallback_applies() {
            return None;
        }
        let c = self.copy_bounds?;
        panel(&[c], self.size).ok().map(|p| p.rect)
    }

    // MARK: output (rules 7, 8)

    /// The focus rects now; `[]` = whole window.
    fn rects(&self, now: f64) -> Vec<Rect> {
        if self.window_id.is_none()
            || self.is_locked
            || !(self.size.width >= MIN_WINDOW.width && self.size.height >= MIN_WINDOW.height)
        {
            return Vec::new();
        }
        if let Some(a) = self.appeared {
            if !reached(a + SETTLE, now) {
                return Vec::new();
            }
        }
        // At most 3: the copy panel only stands in when keyboard and pointer panels are both empty.
        let raw: Vec<Rect> = [self.keyboard_panel, self.pointer_panel, self.follow_panel, self.copy_panel()]
            .into_iter()
            .flatten()
            .collect();
        let bounds = Rect::new(0.0, 0.0, self.size.width, self.size.height);
        let out: Vec<Rect> = drop_contained(&raw)
            .into_iter()
            .filter_map(|r| {
                let i = round_out(&r).intersection(&bounds)?;
                if i.is_empty() {
                    None
                } else {
                    Some(i)
                }
            })
            .collect();
        let Some(first) = out.first() else { return Vec::new() };
        let bx = out[1..].iter().fold(*first, |acc, r| acc.union(r));
        if bx.w() * bx.h() >= MAX_SHARE * (self.size.width * self.size.height) {
            return Vec::new();
        }
        out
    }

    fn update(&mut self, cause: Cause, now: f64) -> Vec<Action> {
        self.last_cause = cause;
        self.flush(now)
    }

    /// Sends the current output when it differs from the last one sent and 0.3 s have passed.
    fn flush(&mut self, now: f64) -> Vec<Action> {
        let out = Output { window: self.window_id.unwrap_or(0), rects: self.rects(now), cause: self.last_cause };
        if let Some(s) = &self.sent {
            if s.window == out.window && s.rects == out.rects {
                return Vec::new();
            }
        }
        if let Some(at) = self.sent_at {
            if !reached(at + SEND_INTERVAL, now) {
                return Vec::new();
            }
        }
        self.sent = Some(out.clone());
        self.sent_at = Some(now);
        vec![Action::Send(out)]
    }
}

fn reached(deadline: f64, now: f64) -> bool {
    now >= deadline - EPSILON
}

fn within(start: f64, span: f64, now: f64) -> bool {
    now - start <= span + EPSILON
}

/// Drops rects inside another one (of two equal rects the first stays).
pub(crate) fn drop_contained(rs: &[Rect]) -> Vec<Rect> {
    rs.iter()
        .enumerate()
        .filter(|(i, r)| !rs.iter().enumerate().any(|(j, o)| j != *i && o.contains_rect(r) && (o != *r || j < *i)))
        .map(|(_, r)| *r)
        .collect()
}

pub(crate) fn round_out(r: &Rect) -> Rect {
    let x = r.min_x().floor();
    let y = r.min_y().floor();
    Rect::new(x, y, r.max_x().ceil() - x, r.max_y().ceil() - y)
}
