//! Shared helpers for the fixture tests. The fixtures under `tests/fixtures/`
//! are written by the Swift generators in `Tests/RappCoreTests/HostCoreFixtures/`
//! (`RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'`); never edit them by hand.
//!
//! Formats (see `HostFixture.swift`):
//! - `.bin`: records one after another, each `u8 tag, u32 LE length, payload`.
//! - `.json`: an array of `{"name": …, "in": …, "out": …}` cases.
#![allow(dead_code)]

use serde::de::DeserializeOwned;
use serde::Deserialize;
use std::path::PathBuf;

pub fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

/// The bytes of one fixture file; panics with the generator command when it is missing.
pub fn fixture(name: &str) -> Vec<u8> {
    let path = fixture_path(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "fixture {} is missing ({e}); generate it with \
             RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'",
            path.display()
        )
    })
}

/// Splits a `.bin` fixture into `(tag, payload)` records. Panics on a truncated record.
pub fn records(bytes: &[u8]) -> Vec<(u8, &[u8])> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < bytes.len() {
        assert!(pos + 5 <= bytes.len(), "truncated record header at byte {pos}");
        let tag = bytes[pos];
        let len = u32::from_le_bytes(bytes[pos + 1..pos + 5].try_into().unwrap()) as usize;
        pos += 5;
        assert!(pos + len <= bytes.len(), "truncated record (tag {tag}, {len} bytes) at byte {pos}");
        out.push((tag, &bytes[pos..pos + len]));
        pos += len;
    }
    out
}

/// The records of a named `.bin` fixture, owned.
pub fn fixture_records(name: &str) -> Vec<(u8, Vec<u8>)> {
    records(&fixture(name)).into_iter().map(|(t, p)| (t, p.to_vec())).collect()
}

/// One case of a `.json` fixture.
#[derive(Debug, Deserialize)]
pub struct Case<I, O> {
    pub name: String,
    #[serde(rename = "in")]
    pub input: I,
    pub out: O,
}

/// The cases of a named `.json` fixture.
pub fn cases<I: DeserializeOwned, O: DeserializeOwned>(name: &str) -> Vec<Case<I, O>> {
    let bytes = fixture(name);
    serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("fixture {name} is not valid case JSON: {e}"))
}

/// The cases of a named `.json` fixture as untyped values, for fixtures whose
/// cases differ in shape (traces with several event kinds).
pub fn raw_cases(name: &str) -> Vec<Case<serde_json::Value, serde_json::Value>> {
    cases(name)
}

/// Lower- or upper-case hex to bytes. Panics on bad input.
pub fn unhex(s: &str) -> Vec<u8> {
    assert!(s.len() % 2 == 0, "odd hex length");
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("bad hex")).collect()
}

/// Bytes to lower-case hex.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn le_u16(b: &[u8]) -> u16 {
    u16::from_le_bytes(b[..2].try_into().unwrap())
}
pub fn le_u32(b: &[u8]) -> u32 {
    u32::from_le_bytes(b[..4].try_into().unwrap())
}
pub fn le_u64(b: &[u8]) -> u64 {
    u64::from_le_bytes(b[..8].try_into().unwrap())
}

/// A cursor over one record's payload. Every read panics when the payload is too short.
pub struct Reader<'a> {
    pub bytes: &'a [u8],
    pub pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Reader { bytes, pos: 0 }
    }
    pub fn bytes(&mut self, n: usize) -> &'a [u8] {
        assert!(self.pos + n <= self.bytes.len(), "record is shorter than expected");
        let out = &self.bytes[self.pos..self.pos + n];
        self.pos += n;
        out
    }
    pub fn u8(&mut self) -> u8 {
        self.bytes(1)[0]
    }
    pub fn u16(&mut self) -> u16 {
        le_u16(self.bytes(2))
    }
    pub fn u32(&mut self) -> u32 {
        le_u32(self.bytes(4))
    }
    pub fn u64(&mut self) -> u64 {
        le_u64(self.bytes(8))
    }
    pub fn i32(&mut self) -> i32 {
        self.u32() as i32
    }
    pub fn f32(&mut self) -> f32 {
        f32::from_bits(self.u32())
    }
    pub fn f64(&mut self) -> f64 {
        f64::from_bits(self.u64())
    }
    /// A `u32` length, then that many bytes.
    pub fn sized(&mut self) -> &'a [u8] {
        let n = self.u32() as usize;
        self.bytes(n)
    }
    pub fn rest(&mut self) -> &'a [u8] {
        let out = &self.bytes[self.pos..];
        self.pos = self.bytes.len();
        out
    }
    pub fn done(&self) -> bool {
        self.pos == self.bytes.len()
    }
}
