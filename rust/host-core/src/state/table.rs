//! State rows with hold / release timing (spec §4.4; `StateRules/StateTable.swift`). Time is
//! injected; nothing here sleeps.

use std::collections::BTreeSet;

use super::rule_pack::{Condition, StateRow};
use crate::geometry::swift_min;

/// Whether `c` is true given the signals that hold. `Never` is false.
pub fn holds(c: &Condition, on: &BTreeSet<String>) -> bool {
    match c {
        Condition::Signal(s) => on.contains(s),
        Condition::Any(cs) => cs.iter().any(|c| holds(c, on)),
        Condition::All(cs) => cs.iter().all(|c| holds(c, on)),
        Condition::Not(c) => !holds(c, on),
        Condition::Never => false,
    }
}

/// Every signal name a condition mentions.
pub fn signals_in(c: &Condition) -> BTreeSet<String> {
    match c {
        Condition::Signal(s) => BTreeSet::from([s.clone()]),
        Condition::Any(cs) | Condition::All(cs) => {
            let mut out = BTreeSet::new();
            for c in cs {
                out.extend(signals_in(c));
            }
            out
        }
        Condition::Not(c) => signals_in(c),
        Condition::Never => BTreeSet::new(),
    }
}

/// Pack values are doubles: NaN and negatives count as 0; anything above this is capped.
pub const MAX_SECONDS: f64 = 3600.0;

/// Ordered rows; the first row (top down) that is in force wins.
/// A row not currently in force is entered once its condition has held for `hold` seconds.
/// The row in force is left only after its condition has been false for `release` seconds,
/// and a lower row cannot cut that short; a higher row preempts at once (once past its own hold).
#[derive(Debug, Clone)]
pub struct StateTable {
    rows: Vec<StateRow>,
    true_since: Vec<Option<f64>>,
    false_since: Vec<Option<f64>>,
    /// `None`: no table row in force (the idle fallback).
    current: Option<usize>,
}

fn seconds(x: f64) -> f64 {
    if x.is_nan() || x < 0.0 {
        0.0
    } else {
        swift_min(x, MAX_SECONDS)
    }
}

impl StateTable {
    pub fn new(rows: Vec<StateRow>) -> Self {
        let n = rows.len();
        StateTable { rows, true_since: vec![None; n], false_since: vec![None; n], current: None }
    }

    /// The row in force at `now`, given the signals that hold; `None` only when the table has
    /// no rows. With rows but none in force the result is a bare `idle` row.
    pub fn step(&mut self, on: &BTreeSet<String>, now: f64) -> Option<StateRow> {
        if self.rows.is_empty() {
            return None;
        }
        for i in 0..self.rows.len() {
            let row_on = self.rows[i].when.as_ref().map(|c| holds(c, on)).unwrap_or(true);
            if row_on {
                if self.true_since[i].is_none() {
                    self.true_since[i] = Some(now);
                }
                self.false_since[i] = None;
            } else {
                if self.false_since[i].is_none() {
                    self.false_since[i] = Some(now);
                }
                self.true_since[i] = None;
            }
        }
        for i in 0..self.rows.len() {
            let satisfied = if self.current == Some(i) {
                self.true_since[i].is_some()
                    || now - self.false_since[i].unwrap_or(now) < seconds(self.rows[i].release)
            } else {
                self.true_since[i].map(|t| now - t >= seconds(self.rows[i].hold)).unwrap_or(false)
            };
            if satisfied {
                self.current = Some(i);
                return Some(self.rows[i].clone());
            }
        }
        self.current = None;
        Some(StateRow::new("idle"))
    }
}
