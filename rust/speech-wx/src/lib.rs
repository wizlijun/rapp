//! Speech recognition with WeChat IME's offline model (wx offline ASR design, docs/superpowers/specs/
//! 2026-11-28-rapp-wx-offline-asr-design.md). The engine (`fbank`, `kernels`, `model`, `stream`, `xnet`, `pack`)
//! is voicekey's `crates/wtlocal`, copied unchanged; this file adds only [`Session`], which carries voicekey's
//! `LocalEngine` pacing rules over unchanged, and the C interface the app calls.
//!
//! The model directory holds the official speech pack's `.xnet` file and `dict.decoder.utf8.txt`; it lives on
//! the user's machine only, never in the repository or an install package.
// voicekey's files stay byte-for-byte as copied, so this repository's lints do not apply to them.
#[allow(clippy::all)]
#[rustfmt::skip]
mod fbank;
#[allow(clippy::all)]
#[rustfmt::skip]
mod kernels;
#[allow(clippy::all)]
#[rustfmt::skip]
mod model;
#[cfg(feature = "tool")]
#[allow(clippy::all)]
#[rustfmt::skip]
pub mod pack;
#[allow(clippy::all)]
#[rustfmt::skip]
mod stream;
#[allow(clippy::all)]
#[rustfmt::skip]
mod xnet;

pub use model::Model;
pub use stream::Stream;

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::ptr;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// voicekey `LocalEngine`: the least new audio between two partials (feature frames, 10 ms each); a partial
/// also waits at least three times as long as the last one took, so slow machines compute them less often.
const PARTIAL_EVERY: usize = 30;

/// One recording: the stream plus voicekey `LocalEngine`'s partial pacing and its "only when changed" rule.
pub struct Session {
    s: Stream,
    last: String,
    done: Instant,
    cost: Duration,
}

impl Session {
    pub fn new(m: Arc<Model>) -> Self {
        Session {
            s: Stream::new(m),
            last: String::new(),
            done: Instant::now(),
            cost: Duration::ZERO,
        }
    }

    /// 16 kHz mono samples.
    pub fn push(&mut self, pcm: &[i16]) {
        self.s.push(pcm);
    }

    /// A new partial when one is due by the pacing rules and differs from the last (and is not empty).
    /// voicekey asks after each batch of pushed audio; callers do the same.
    pub fn partial(&mut self) -> Option<String> {
        if self.s.fresh() < PARTIAL_EVERY || self.done.elapsed() < self.cost * 3 {
            return None;
        }
        let t0 = Instant::now();
        let t = self.s.partial();
        (self.done, self.cost) = (Instant::now(), t0.elapsed());
        if t.is_empty() || t == self.last {
            return None;
        }
        self.last = t.clone();
        Some(t)
    }

    pub fn finish(self) -> String {
        self.s.finish()
    }
}

// MARK: - C interface. Every pointer argument may be null (the call then does nothing or returns null).
// A handle is used from one thread at a time; the model may be shared by sessions on any thread.

fn into_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).map_or(ptr::null_mut(), CString::into_raw)
}

/// Loads the model in `dir` (UTF-8 path). Null on failure, with the reason in `*err` (free with
/// `wx_string_free`) when `err` is not null.
///
/// # Safety
/// `dir` is a NUL-terminated string or null; `err` is null or points to writable storage for one pointer.
#[no_mangle]
pub unsafe extern "C" fn wx_load(dir: *const c_char, err: *mut *mut c_char) -> *mut Arc<Model> {
    let fail = |e: String| {
        if !err.is_null() {
            *err = into_c(e);
        }
        ptr::null_mut()
    };
    if dir.is_null() {
        return fail("no model directory".into());
    }
    let dir = CStr::from_ptr(dir).to_string_lossy().into_owned();
    match catch_unwind(|| Model::load(Path::new(&dir))) {
        Ok(Ok(m)) => Box::into_raw(Box::new(Arc::new(m))),
        Ok(Err(e)) => fail(format!("{e:#}")),
        Err(_) => fail("model load panicked".into()),
    }
}

/// # Safety
/// `model` is null or came from `wx_load` and was not freed. Sessions keep their own reference.
#[no_mangle]
pub unsafe extern "C" fn wx_model_free(model: *mut Arc<Model>) {
    if !model.is_null() {
        drop(Box::from_raw(model));
    }
}

/// Starts a recording on `model`.
///
/// # Safety
/// `model` is null or a live handle from `wx_load`.
#[no_mangle]
pub unsafe extern "C" fn wx_stream_new(model: *const Arc<Model>) -> *mut Session {
    match model.as_ref() {
        Some(m) => Box::into_raw(Box::new(Session::new(m.clone()))),
        None => ptr::null_mut(),
    }
}

/// Feeds `n` samples: 16 kHz, mono, 16-bit.
///
/// # Safety
/// `stream` is null or a live handle from `wx_stream_new`; `pcm` points to `n` samples (or `n` is 0).
#[no_mangle]
pub unsafe extern "C" fn wx_push(stream: *mut Session, pcm: *const i16, n: usize) {
    let Some(s) = stream.as_mut() else { return };
    if pcm.is_null() || n == 0 {
        return;
    }
    let pcm = std::slice::from_raw_parts(pcm, n);
    let _ = catch_unwind(AssertUnwindSafe(|| s.push(pcm)));
}

/// The new partial text (UTF-8, free with `wx_string_free`), or null when none is due or it has not changed.
///
/// # Safety
/// `stream` is null or a live handle from `wx_stream_new`.
#[no_mangle]
pub unsafe extern "C" fn wx_partial(stream: *mut Session) -> *mut c_char {
    let Some(s) = stream.as_mut() else {
        return ptr::null_mut();
    };
    match catch_unwind(AssertUnwindSafe(|| s.partial())) {
        Ok(Some(t)) => into_c(t),
        _ => ptr::null_mut(),
    }
}

/// Ends the recording: frees `stream` and returns the final text (UTF-8, free with `wx_string_free`;
/// null only if decoding failed).
///
/// # Safety
/// `stream` is null or a live handle from `wx_stream_new`; it must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn wx_finish(stream: *mut Session) -> *mut c_char {
    if stream.is_null() {
        return ptr::null_mut();
    }
    let s = Box::from_raw(stream);
    match catch_unwind(AssertUnwindSafe(|| s.finish())) {
        Ok(t) => into_c(t),
        Err(_) => ptr::null_mut(),
    }
}

/// Drops a recording without decoding it (a cancel).
///
/// # Safety
/// `stream` is null or a live handle from `wx_stream_new`; it must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn wx_stream_free(stream: *mut Session) {
    if !stream.is_null() {
        drop(Box::from_raw(stream));
    }
}

/// # Safety
/// `s` is null or a string this library returned, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn wx_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_reports_why_it_failed() {
        let dir = CString::new("/nonexistent/wx-asr").unwrap();
        let mut err = ptr::null_mut();
        let m = unsafe { wx_load(dir.as_ptr(), &mut err) };
        assert!(m.is_null());
        assert!(!err.is_null());
        let why = unsafe { CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        assert!(!why.is_empty());
        unsafe { wx_string_free(err) };
    }

    #[test]
    fn null_handles_are_harmless() {
        unsafe {
            assert!(wx_load(ptr::null(), ptr::null_mut()).is_null());
            assert!(wx_stream_new(ptr::null()).is_null());
            wx_push(ptr::null_mut(), ptr::null(), 0);
            assert!(wx_partial(ptr::null_mut()).is_null());
            assert!(wx_finish(ptr::null_mut()).is_null());
            wx_stream_free(ptr::null_mut());
            wx_model_free(ptr::null_mut());
            wx_string_free(ptr::null_mut());
        }
    }
}
