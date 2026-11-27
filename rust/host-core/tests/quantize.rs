//! The quantiser against Swift's output (`QuantizeFixtures.swift`).

mod common;
use common::*;

use rapp_host_core::protocol::Mode;
use rapp_host_core::quantize::quantize;

#[test]
fn quantize_matches_swift() {
    let records = fixture_records("quantize.bin");
    assert!(!records.is_empty() && records.len().is_multiple_of(2), "quantize.bin holds input/output pairs");
    let mut failures = Vec::new();
    for (n, pair) in records.chunks(2).enumerate() {
        let (in_tag, input) = &pair[0];
        let (out_tag, expected) = &pair[1];
        assert_eq!((*in_tag, *out_tag), (1, 2), "pair {n}: bad tags");
        let mut r = Reader::new(input);
        let mode = Mode::from_byte(r.u8()).expect("mode");
        let width = r.u16() as usize;
        let height = r.u16() as usize;
        let bytes_per_row = r.u32() as usize;
        let bgra = r.rest();
        let got = quantize(bgra, width, height, bytes_per_row, mode);
        if got != *expected {
            let at = got.iter().zip(expected.iter()).position(|(a, b)| a != b);
            failures.push(format!(
                "pair {n}: {} {width}x{height} (row {bytes_per_row}): {} bytes vs Swift {}, first difference at {at:?}",
                mode.name(),
                got.len(),
                expected.len()
            ));
        }
    }
    assert!(failures.is_empty(), "{} pictures differ:\n{}", failures.len(), failures.join("\n"));
}
