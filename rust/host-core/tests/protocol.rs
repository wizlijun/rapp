//! The picture protocol checked against the Swift host's own bytes
//! (`Tests/RappCoreTests/HostCoreFixtures/ProtocolFixtures.swift`).

mod common;
use common::*;

use rapp_host_core::protocol::{disposition, Disposition, Message, MessageParser, DISPOSITION};
use serde::Deserialize;

/// Feeds `bytes` to one parser, the way `ProtocolFixtures.outcome` does: the first error
/// text, or (when nothing fails) every parsed message re-encoded, as hex.
fn outcome(bytes: &[u8]) -> RejectOut {
    let mut p = MessageParser::new();
    p.append(bytes);
    let mut again = Vec::new();
    loop {
        match p.next() {
            Ok(Some(m)) => again.extend_from_slice(&m.encoded()),
            Ok(None) => break,
            Err(e) => return RejectOut { error: Some(e.0), again: None },
        }
    }
    RejectOut { error: None, again: Some(hex(&again)) }
}

#[derive(Debug, Deserialize, PartialEq)]
struct RejectOut {
    error: Option<String>,
    again: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TypeCase {
    #[serde(rename = "type")]
    type_byte: u8,
    case: String,
}

#[test]
fn every_sample_decodes_and_reencodes_identically() {
    let records = fixture_records("protocol-messages.bin");
    assert!(!records.is_empty(), "protocol-messages.bin has no records");
    for (i, (tag, bytes)) in records.iter().enumerate() {
        assert_eq!(bytes[0], *tag, "record {i}: tag is not the type byte");
        let mut p = MessageParser::new();
        p.append(bytes);
        let m = p
            .next()
            .unwrap_or_else(|e| panic!("record {i} (type {tag}) is rejected: {}", e.0))
            .unwrap_or_else(|| panic!("record {i} (type {tag}) is incomplete"));
        assert_eq!(m.type_byte(), *tag, "record {i}: decoded to another type");
        assert_eq!(hex(&m.encoded()), hex(bytes), "record {i} ({}) re-encodes differently", m.case_name());
        assert!(matches!(p.next(), Ok(None)), "record {i}: bytes left in the parser");
        assert_eq!(p.buffered(), 0, "record {i}: the parser kept bytes");
        // The same body through `decode` directly.
        let again = Message::decode(*tag, &bytes[5..]).unwrap_or_else(|e| panic!("record {i}: decode: {}", e.0));
        assert_eq!(again.encoded(), *bytes, "record {i}: decode and parser disagree");
    }
}

#[test]
fn byte_at_a_time() {
    for (i, (tag, bytes)) in fixture_records("protocol-messages.bin").iter().enumerate() {
        let mut p = MessageParser::new();
        for (k, b) in bytes.iter().enumerate() {
            p.append(std::slice::from_ref(b));
            let got = p.next().unwrap_or_else(|e| panic!("record {i} (type {tag}) byte {k}: {}", e.0));
            if k + 1 < bytes.len() {
                assert!(got.is_none(), "record {i} (type {tag}): a message before byte {} of {}", k + 1, bytes.len());
            } else {
                let m = got.unwrap_or_else(|| panic!("record {i} (type {tag}): nothing after the last byte"));
                assert_eq!(m.encoded(), *bytes, "record {i}: byte-at-a-time decode differs");
            }
        }
    }
}

#[test]
fn all_samples_back_to_back() {
    let records = fixture_records("protocol-messages.bin");
    let mut stream = Vec::new();
    for (_, bytes) in &records {
        stream.extend_from_slice(bytes);
    }
    let mut p = MessageParser::new();
    p.append(&stream);
    let mut again = Vec::new();
    let mut n = 0;
    while let Some(m) = p.next().expect("a sample is rejected in a stream") {
        again.extend_from_slice(&m.encoded());
        n += 1;
    }
    assert_eq!(n, records.len());
    assert_eq!(again, stream);
}

#[test]
fn rejects_match_swift() {
    let cases: Vec<Case<String, RejectOut>> = cases("protocol-rejects.json");
    assert!(!cases.is_empty(), "protocol-rejects.json has no cases");
    let mut failures = Vec::new();
    for c in &cases {
        let got = outcome(&unhex(&c.input));
        if got != c.out {
            failures.push(format!("{}: Swift {:?}, Rust {:?}", c.name, short(&c.out), short(&got)));
        }
    }
    assert!(failures.is_empty(), "{} of {} cases differ:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

/// The outcome with a long re-encoding cut down, for a readable failure message.
fn short(o: &RejectOut) -> String {
    match (&o.error, &o.again) {
        (Some(e), _) => format!("error {e:?}"),
        (None, Some(h)) if h.len() > 80 => format!("accepted {}… ({} bytes)", &h[..80], h.len() / 2),
        (None, Some(h)) => format!("accepted {h}"),
        (None, None) => "nothing".into(),
    }
}

#[test]
fn disposition_covers_exactly_the_swift_types() {
    let cases: Vec<Case<serde_json::Value, Vec<TypeCase>>> = cases("protocol-types.json");
    assert_eq!(cases.len(), 1, "protocol-types.json holds one case");
    let swift: Vec<(u8, String)> = cases[0].out.iter().map(|t| (t.type_byte, t.case.clone())).collect();
    let mut ours: Vec<(u8, String)> = DISPOSITION.iter().map(|e| (e.0, e.1.to_string())).collect();
    ours.sort();
    assert_eq!(ours, swift, "DISPOSITION and the Swift message types differ");
    // Every other type byte is unknown, and the parser says so from the header.
    for t in 0..=255u8 {
        let known = swift.iter().any(|s| s.0 == t);
        assert_eq!(disposition(t).is_some(), known, "type {t}");
        let mut p = MessageParser::new();
        p.append(&[t, 0, 0, 0, 0]);
        let unknown = matches!(p.next(), Err(e) if e.0 == format!("unknown message type {t}"));
        assert_eq!(unknown, !known, "type {t}: the parser and the table disagree");
    }
}

#[test]
fn not_handled_is_exactly_17_18_28() {
    let mut not_handled: Vec<u8> =
        DISPOSITION.iter().filter(|e| e.2 == Disposition::NotHandled).map(|e| e.0).collect();
    not_handled.sort();
    assert_eq!(not_handled, vec![17, 18, 28]);
}

#[test]
fn oversized_length_allocates_nothing() {
    let mut p = MessageParser::new();
    p.append(&[25, 0xFF, 0xFF, 0xFF, 0xFF]);
    match p.next() {
        Err(e) => assert_eq!(e.0, "message too large (4294967295 bytes)"),
        Ok(m) => panic!("a 4 GiB header was not rejected: {m:?}"),
    }
    // The header alone decided it: the parser holds only those 5 bytes (Swift keeps the buffer).
    assert_eq!(p.buffered(), 5);
    // One byte over the limit, also from the header alone.
    let mut p = MessageParser::new();
    let over = (64u32 * 1024 * 1024 + 1).to_le_bytes();
    p.append(&[4, over[0], over[1], over[2], over[3]]);
    assert!(matches!(p.next(), Err(e) if e.0 == "message too large (67108865 bytes)"));
    // Exactly the limit waits for the body.
    let mut p = MessageParser::new();
    let at = (64u32 * 1024 * 1024).to_le_bytes();
    p.append(&[4, at[0], at[1], at[2], at[3]]);
    assert!(matches!(p.next(), Ok(None)));
}
