//! The fixture harness itself: `harness.bin` and `harness.json` come from
//! `HarnessFixtures.swift` and prove the two sides read and write the formats alike.

mod common;
use common::*;

#[test]
fn records_round_trip() {
    let bytes = fixture("harness.bin");
    let recs = records(&bytes);
    let tags: Vec<u8> = recs.iter().map(|r| r.0).collect();
    assert_eq!(tags, [1, 2, 255]);
    assert_eq!(recs[0].1, &[] as &[u8]);
    assert_eq!(recs[1].1, &[0xDE, 0xAD]);
    let long: Vec<u8> = (0..70_000u32).map(|i| (i % 251) as u8).collect();
    assert_eq!(recs[2].1, &long[..]);
}

#[test]
fn cases_round_trip() {
    let cases: Vec<Case<Vec<f32>, (i64, String)>> = cases("harness.json");
    assert_eq!(cases.len(), 1);
    let case = &cases[0];
    assert_eq!(case.name, "floats");
    // Swift writes each Float as the Double of the same value; reading it back as
    // f32 gives exactly the Float again.
    assert_eq!(case.input, vec![0.1f32, 1.0, 16_777_216.0]);
    assert_eq!(case.out, (-3, "桌面 · é🇨🇳".to_string()));
}
