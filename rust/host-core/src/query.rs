//! One-at-a-time query bookkeeping and deadlines (`Sources/RappCore/QueryCoalescer.swift`,
//! `Sources/RappCore/QueryDeadline.swift`).

use crate::focus::Query;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QueryKind {
    Keyboard,
    Pointer,
    Follow,
}

impl QueryKind {
    /// Swift's `allCases` order, which is also the order waiting jobs run in.
    pub const ALL: [QueryKind; 3] = [QueryKind::Keyboard, QueryKind::Pointer, QueryKind::Follow];

    fn slot(self) -> usize {
        match self {
            QueryKind::Keyboard => 0,
            QueryKind::Pointer => 1,
            QueryKind::Follow => 2,
        }
    }
}

impl Query {
    pub fn kind(&self) -> QueryKind {
        match self {
            Query::Keyboard => QueryKind::Keyboard,
            Query::Pointer(_) => QueryKind::Pointer,
            Query::Follow(_) => QueryKind::Follow,
        }
    }
}

/// Bookkeeping for a reader that runs one query at a time: while one runs, at most one more
/// waits per query kind, and a newer one replaces the waiting one of its kind. A pointer query
/// therefore never pushes out a waiting keyboard query, and a burst of scroll events leaves
/// one pointer query behind.
#[derive(Debug)]
pub struct QueryCoalescer<Job> {
    running: bool,
    pending: [Option<Job>; 3],
}

impl<Job> Default for QueryCoalescer<Job> {
    fn default() -> Self {
        QueryCoalescer::new()
    }
}

impl<Job> QueryCoalescer<Job> {
    pub fn new() -> Self {
        QueryCoalescer { running: false, pending: [None, None, None] }
    }

    /// The job to start now, or `None` when one is running (the job then waits in its slot).
    pub fn submit(&mut self, kind: QueryKind, job: Job) -> Option<Job> {
        if self.running {
            self.pending[kind.slot()] = Some(job);
            return None;
        }
        self.running = true;
        Some(job)
    }

    /// The running job is done: the next waiting job (keyboard, pointer, follow), or `None` when idle.
    pub fn finish(&mut self) -> Option<Job> {
        for kind in QueryKind::ALL {
            if let Some(job) = self.pending[kind.slot()].take() {
                return Some(job);
            }
        }
        self.running = false;
        None
    }
}

/// A fixed point in time a query must finish by; every accessibility call is given what is left of it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QueryDeadline {
    pub end: f64,
}

impl QueryDeadline {
    pub fn new(start: f64, budget: f64) -> Self {
        QueryDeadline { end: start + budget }
    }

    /// Seconds left for the next call, or `None` when nothing worth waiting for remains (under 1 ms).
    pub fn remaining(&self, now: f64) -> Option<f64> {
        let left = self.end - now;
        if left >= 0.001 {
            Some(left)
        } else {
            None
        }
    }

    pub fn expired(&self, now: f64) -> bool {
        self.remaining(now).is_none()
    }
}
