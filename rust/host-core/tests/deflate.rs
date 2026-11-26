//! The deflate stream replays the Swift script (`DeflateFixtures.swift`) byte for byte.

mod common;
use common::*;

use rapp_host_core::deflate::{DeflateStream, InflateStream};

#[test]
fn script_matches_swift() {
    let records = fixture_records("deflate.bin");
    assert!(!records.is_empty(), "deflate.bin has no records");
    let mut stream = DeflateStream::new(6);
    // The receiving side, kept in step: every output Swift sent must inflate to its input.
    let mut inflate = InflateStream::new();
    let mut i = 0;
    let mut step = 0;
    while i < records.len() {
        let (tag, payload) = &records[i];
        match tag {
            1 => {
                let (out_tag, expected) = &records[i + 1];
                assert_eq!(*out_tag, 2, "step {step}: a compress input not followed by its output");
                let got = stream.compress(payload);
                assert_eq!(
                    got.len(),
                    expected.len(),
                    "step {step}: compress of {} bytes: Rust {} bytes, Swift {}",
                    payload.len(),
                    got.len(),
                    expected.len()
                );
                assert_eq!(hex(&got), hex(expected), "step {step}: compress output differs");
                assert_eq!(inflate.decompress(expected, usize::MAX).expect("inflate"), *payload, "step {step}");
                i += 2;
            }
            3 => {
                let (out_tag, expected) = &records[i + 1];
                assert_eq!(*out_tag, 4, "step {step}: a trial not followed by its result");
                let limit = le_u32(payload) as usize;
                let input = &payload[4..];
                let (fits, data) = stream.compress_if_at_most(input, limit);
                assert_eq!(fits as u8, expected[0], "step {step}: trial of {} bytes at limit {limit}", input.len());
                assert_eq!(hex(&data), hex(&expected[1..]), "step {step}: trial output differs");
                if fits {
                    assert_eq!(inflate.decompress(&data, usize::MAX).expect("inflate"), input, "step {step}");
                }
                i += 2;
            }
            5 => {
                assert!(payload.is_empty(), "step {step}: reset carries a payload");
                stream.reset();
                inflate.reset();
                i += 1;
            }
            t => panic!("step {step}: unexpected tag {t}"),
        }
        step += 1;
    }
}

#[test]
fn reset_repeats_the_first_output() {
    let records = fixture_records("deflate.bin");
    // The first compress output and the first one after the first reset (both of the same input).
    let first = &records[1].1;
    let reset_at = records.iter().position(|r| r.0 == 5).expect("the script resets");
    assert_eq!(records[reset_at + 1].0, 1);
    assert_eq!(records[reset_at + 1].1, records[0].1, "the script compresses the first input after reset");
    assert_eq!(&records[reset_at + 2].1, first);
}
