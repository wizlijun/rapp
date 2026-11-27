//! The connection-long zlib streams of the picture path, ported from
//! `Sources/RappCore/Deflate.swift`. Stock zlib through `libz-sys` (statically
//! linked): the stream must be copyable (`deflateCopy`) for
//! `compress_if_at_most`, which `flate2` cannot do.
//!
//! This is the only file in `host-core` with `unsafe`. Each `z_stream` lives in
//! a `Box` because zlib keeps a pointer back to it (Swift allocates it for the
//! same reason, Deflate.swift:12-17). The allocator functions are our own so
//! the struct is a valid Rust value from the start (`z_stream`'s `zalloc` and
//! `zfree` are non-nullable function pointers in `libz-sys`); they hand out
//! zeroed memory, as `calloc` would.
//!
//! Only `libz_sys::` types and plain integers are named here (no OS paths):
//! `c_int` is `i32` and `uInt` is `u32` on every target this crate builds for.

use crate::protocol::CodecError;
use libz_sys as z;
use std::alloc::{alloc_zeroed, dealloc, Layout};

/// Deflate.swift:11.
const ZLIB_BUFFER_SIZE: usize = 64 * 1024;

/// Bytes kept in front of each allocation to remember its size.
const HEADER: usize = 16;

unsafe extern "C" fn zalloc(_opaque: z::voidpf, items: z::uInt, size: z::uInt) -> z::voidpf {
    let Some(n) = (items as usize).checked_mul(size as usize).and_then(|n| n.checked_add(HEADER)) else {
        return std::ptr::null_mut();
    };
    let Ok(layout) = Layout::from_size_align(n, HEADER) else {
        return std::ptr::null_mut();
    };
    // SAFETY: `layout` has a non-zero size (at least HEADER).
    let p = unsafe { alloc_zeroed(layout) };
    if p.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: `p` is valid for `n >= HEADER` bytes and aligned to HEADER (>= align of usize).
    unsafe {
        (p as *mut usize).write(n);
        p.add(HEADER) as z::voidpf
    }
}

unsafe extern "C" fn zfree(_opaque: z::voidpf, address: z::voidpf) {
    if address.is_null() {
        return;
    }
    // SAFETY: `address` came from `zalloc`, so HEADER bytes before it hold the size
    // of an allocation made with this layout.
    unsafe {
        let p = (address as *mut u8).sub(HEADER);
        let n = (p as *const usize).read();
        dealloc(p, Layout::from_size_align_unchecked(n, HEADER));
    }
}

/// A fresh, not yet initialised stream (what Swift's `z_stream()` is, plus our allocators).
fn new_stream() -> Box<z::z_stream> {
    Box::new(z::z_stream {
        next_in: std::ptr::null_mut(),
        avail_in: 0,
        total_in: 0,
        next_out: std::ptr::null_mut(),
        avail_out: 0,
        total_out: 0,
        msg: std::ptr::null_mut(),
        state: std::ptr::null_mut(),
        zalloc,
        zfree,
        opaque: std::ptr::null_mut(),
        data_type: 0,
        adler: 0,
        reserved: 0,
    })
}

fn stream_size() -> i32 {
    std::mem::size_of::<z::z_stream>() as i32
}

/// A zlib deflate stream that lives for a whole connection. Every `compress`
/// call ends with a sync flush, so its output can be decompressed on its own,
/// while the dictionary built from earlier calls is kept for later ones.
pub struct DeflateStream {
    strm: Box<z::z_stream>,
}

// SAFETY: the stream owns its zlib state outright; nothing else points into it.
unsafe impl Send for DeflateStream {}

impl DeflateStream {
    /// Deflate.swift:26 (`level` defaults to 6 there; every caller passes 6).
    pub fn new(level: i32) -> Self {
        let mut strm = new_stream();
        // SAFETY: `strm` is a valid, boxed z_stream; the version string is zlib's own.
        let rc = unsafe { z::deflateInit_(&mut *strm, level, z::zlibVersion(), stream_size()) };
        assert!(rc == z::Z_OK, "deflateInit failed: {rc}");
        DeflateStream { strm }
    }

    pub fn compress(&mut self, input: &[u8]) -> Vec<u8> {
        run(&mut self.strm, input)
    }

    /// Compresses `input` like `compress` when the output is at most `limit`
    /// bytes. Otherwise the stream is left as it was and the flag is false; the
    /// data is then the output that would have been sent (only its size matters:
    /// TileCodec.swift:269 scales the next try by it). Deflate.swift:41-56.
    pub fn compress_if_at_most(&mut self, input: &[u8], limit: usize) -> (bool, Vec<u8>) {
        let mut trial = new_stream();
        // SAFETY: both are valid boxed streams; `self.strm` is initialised. deflateCopy
        // overwrites the whole of `trial` before allocating its state.
        let rc = unsafe { z::deflateCopy(&mut *trial, &mut *self.strm) };
        assert!(rc == z::Z_OK, "deflateCopy failed: {rc}");
        let data = run(&mut trial, input);
        if data.len() > limit {
            // SAFETY: `trial` was initialised by deflateCopy and is ended once.
            unsafe { z::deflateEnd(&mut *trial) };
            return (false, data);
        }
        let old = std::mem::replace(&mut self.strm, trial);
        end_deflate(old);
        (true, data)
    }

    /// Drops the dictionary. The peer's `InflateStream` must be reset at the same point.
    pub fn reset(&mut self) {
        // SAFETY: the stream is initialised.
        unsafe { z::deflateReset(&mut *self.strm) };
    }
}

// Boxed on purpose: zlib keeps a pointer back to the stream, so it never moves until ended.
#[allow(clippy::boxed_local)]
fn end_deflate(mut strm: Box<z::z_stream>) {
    // SAFETY: an initialised deflate stream, ended once, then dropped.
    unsafe { z::deflateEnd(&mut *strm) };
}

impl Drop for DeflateStream {
    fn drop(&mut self) {
        // SAFETY: the stream is initialised and ended only here.
        unsafe { z::deflateEnd(&mut *self.strm) };
    }
}

/// Deflate.swift:58-79: feed everything, `Z_SYNC_FLUSH`, and keep draining while
/// the 64 KiB buffer comes back full. The return code is ignored, as in Swift.
fn run(strm: &mut z::z_stream, input: &[u8]) -> Vec<u8> {
    let mut output = Vec::new();
    let mut buffer = vec![0u8; ZLIB_BUFFER_SIZE];
    strm.next_in = input.as_ptr() as *mut u8;
    strm.avail_in = input.len() as z::uInt;
    loop {
        strm.next_out = buffer.as_mut_ptr();
        strm.avail_out = buffer.len() as z::uInt;
        // SAFETY: next_in/avail_in describe `input` (zlib only reads it) and
        // next_out/avail_out describe `buffer`; both outlive the call.
        unsafe { z::deflate(strm, z::Z_SYNC_FLUSH) };
        let produced = buffer.len() - strm.avail_out as usize;
        output.extend_from_slice(&buffer[..produced]);
        if produced != buffer.len() {
            break;
        }
    }
    strm.next_in = std::ptr::null_mut();
    strm.avail_in = 0;
    strm.next_out = std::ptr::null_mut();
    strm.avail_out = 0;
    output
}

/// The receiving side of `DeflateStream` (Deflate.swift:88-145).
pub struct InflateStream {
    strm: Box<z::z_stream>,
}

// SAFETY: as for DeflateStream.
unsafe impl Send for InflateStream {}

impl Default for InflateStream {
    fn default() -> Self {
        Self::new()
    }
}

impl InflateStream {
    pub fn new() -> Self {
        let mut strm = new_stream();
        // SAFETY: a valid boxed z_stream with next_in null and avail_in 0.
        let rc = unsafe { z::inflateInit_(&mut *strm, z::zlibVersion(), stream_size()) };
        assert!(rc == z::Z_OK, "inflateInit failed: {rc}");
        InflateStream { strm }
    }

    /// Fails once the output would grow past `limit` bytes, so a small
    /// compressed input cannot make the receiver allocate without bound.
    /// Swift's default limit is `Int.max`; pass `usize::MAX` for it.
    pub fn decompress(&mut self, input: &[u8], limit: usize) -> Result<Vec<u8>, CodecError> {
        let strm = &mut *self.strm;
        let mut output = Vec::new();
        let mut too_large = false;
        let mut buffer = vec![0u8; ZLIB_BUFFER_SIZE];
        let mut failure = z::Z_OK;
        strm.next_in = input.as_ptr() as *mut u8;
        strm.avail_in = input.len() as z::uInt;
        loop {
            strm.next_out = buffer.as_mut_ptr();
            strm.avail_out = buffer.len() as z::uInt;
            // SAFETY: as in `run`.
            let rc = unsafe { z::inflate(strm, z::Z_SYNC_FLUSH) };
            let produced = buffer.len() - strm.avail_out as usize;
            if produced > limit.saturating_sub(output.len()) {
                too_large = true;
                break;
            }
            output.extend_from_slice(&buffer[..produced]);
            let filled = produced == buffer.len();
            // Z_BUF_ERROR only means "nothing more to do with this input".
            if rc != z::Z_OK && rc != z::Z_BUF_ERROR && rc != z::Z_STREAM_END {
                failure = rc;
                break;
            }
            if !filled {
                break;
            }
        }
        strm.next_in = std::ptr::null_mut();
        strm.avail_in = 0;
        strm.next_out = std::ptr::null_mut();
        strm.avail_out = 0;
        if too_large {
            return Err(CodecError::new("decompressed data is larger than the frame allows"));
        }
        if failure != z::Z_OK {
            return Err(CodecError::new(format!("inflate failed (zlib error {failure})")));
        }
        Ok(output)
    }

    pub fn reset(&mut self) {
        // SAFETY: the stream is initialised.
        unsafe { z::inflateReset(&mut *self.strm) };
    }
}

impl Drop for InflateStream {
    fn drop(&mut self) {
        // SAFETY: the stream is initialised and ended only here.
        unsafe { z::inflateEnd(&mut *self.strm) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// DeflateTests.swift:4-14 (`pseudoRandom`).
    fn pseudo_random(count: usize, seed: u32) -> Vec<u8> {
        let mut state = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
        (0..count)
            .map(|_| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (state >> 24) as u8
            })
            .collect()
    }

    #[test]
    fn round_trip_across_chunks() {
        let a = pseudo_random(4096, 1);
        let b = pseudo_random(100, 2);
        let mut d = DeflateStream::new(6);
        let mut i = InflateStream::new();
        assert_eq!(i.decompress(&d.compress(&a), usize::MAX).unwrap(), a);
        assert_eq!(i.decompress(&d.compress(&b), usize::MAX).unwrap(), b);
    }

    #[test]
    fn decompress_stops_at_limit() {
        let bomb = DeflateStream::new(6).compress(&vec![0u8; 200 << 20]);
        let e = InflateStream::new().decompress(&bomb, 1 << 20).unwrap_err();
        assert_eq!(e.0, "decompressed data is larger than the frame allows");
        let small = pseudo_random(1000, 3);
        let packed = DeflateStream::new(6).compress(&small);
        assert_eq!(InflateStream::new().decompress(&packed, 1000).unwrap(), small);
    }

    #[test]
    fn compress_if_at_most_commits_only_when_it_fits() {
        let a = pseudo_random(4096, 1);
        let b = pseudo_random(3000, 2);
        let mut d = DeflateStream::new(6);
        let mut i = InflateStream::new();
        let mut reference = DeflateStream::new(6);
        assert_eq!(i.decompress(&d.compress(&a), usize::MAX).unwrap(), a);
        reference.compress(&a);
        let (fits, over) = d.compress_if_at_most(&b, 100);
        assert!(!fits);
        assert!(over.len() > 100);
        let (fits, data) = d.compress_if_at_most(&a, 8192);
        assert!(fits);
        assert_eq!(data, reference.compress(&a));
        assert_eq!(i.decompress(&data, usize::MAX).unwrap(), a);
        assert_eq!(i.decompress(&d.compress(&b), usize::MAX).unwrap(), b);
    }

    #[test]
    fn context_is_kept_between_calls() {
        let a = pseudo_random(4096, 1);
        let mut d = DeflateStream::new(6);
        let first = d.compress(&a);
        let second = d.compress(&a);
        assert!(second.len() < first.len() / 4);
    }

    #[test]
    fn reset_starts_fresh() {
        let a = pseudo_random(4096, 1);
        let mut d = DeflateStream::new(6);
        let mut i = InflateStream::new();
        i.decompress(&d.compress(&a), usize::MAX).unwrap();
        d.reset();
        i.reset();
        assert_eq!(i.decompress(&d.compress(&a), usize::MAX).unwrap(), a);
    }

    #[test]
    fn garbage_fails() {
        assert!(InflateStream::new().decompress(&[1, 2, 3, 4, 5], usize::MAX).is_err());
    }

    #[test]
    fn large_input_round_trips() {
        let a = pseudo_random(300_000, 7);
        let mut d = DeflateStream::new(6);
        let mut i = InflateStream::new();
        assert_eq!(i.decompress(&d.compress(&a), usize::MAX).unwrap(), a);
    }

    #[test]
    fn empty_input_round_trips() {
        let mut d = DeflateStream::new(6);
        let mut i = InflateStream::new();
        assert_eq!(i.decompress(&d.compress(&[]), usize::MAX).unwrap(), Vec::<u8>::new());
    }
}
