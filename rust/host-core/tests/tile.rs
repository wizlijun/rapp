//! The tile encoder against Swift's `FrameEncoder` (`TileFixtures.swift`).
//!
//! `tile-frames.bin` holds the BGRA pictures; `tile-<mode>.bin` and
//! `tile-settle.bin` hold runs of encoder calls and what Swift returned for each
//! (record layout in `TileFixtures.swift`). Every run is replayed on a Rust
//! `FrameEncoder`; the Swift slices also go through the client's decoder.

mod common;
use common::*;

use rapp_client_core::codec::Decoder;
use rapp_host_core::deflate::InflateStream;
use rapp_host_core::protocol::{CanvasRect, FramePayload, Mode};
use rapp_host_core::quantize::quantize;
use rapp_host_core::tile::FrameEncoder;

/// FNV-1a, as `TileFixtures.fnv`.
fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01B3);
    }
    h
}

struct Picture {
    width: usize,
    height: usize,
    bgra: Vec<u8>,
}

fn pictures() -> Vec<Picture> {
    fixture_records("tile-frames.bin")
        .into_iter()
        .enumerate()
        .map(|(id, (tag, p))| {
            assert_eq!(tag, 1, "tile-frames.bin record {id}: bad tag");
            let mut r = Reader::new(&p);
            let width = r.u16() as usize;
            let height = r.u16() as usize;
            let bgra = InflateStream::new().decompress(r.rest(), usize::MAX).expect("frame inflates");
            assert_eq!(bgra.len(), width * height * 4, "frame {id}: BGRA size");
            Picture { width, height, bgra }
        })
        .collect()
}

/// The slice in the fixture's tag 1 layout.
fn slice_record(s: &FramePayload) -> Vec<u8> {
    let mut v = vec![s.mode as u8];
    v.extend_from_slice(&s.width.to_le_bytes());
    v.extend_from_slice(&s.height.to_le_bytes());
    v.push(s.flags.0);
    v.extend_from_slice(&s.dx.to_le_bytes());
    v.extend_from_slice(&s.dy.to_le_bytes());
    v.extend_from_slice(&(s.data.len() as u32).to_le_bytes());
    v.extend_from_slice(&s.data);
    v
}

/// What went wrong, by the test that reports it.
#[derive(Default)]
struct Failures {
    /// Slices, tile streams, the encoder state and the encoder's canvas model.
    frames: Vec<String>,
    /// `last_report`.
    reports: Vec<String>,
    /// The client decoder fed Swift's slices, against Swift's decoder.
    decoder: Vec<String>,
    /// Calls replayed (tag 11 and tag 14).
    calls: usize,
}

impl Failures {
    fn push(list: &mut Vec<String>, at: &str, what: String) {
        // Keep the first failures readable; a desync makes everything after it differ.
        if list.len() < 40 {
            list.push(format!("{at}: {what}"));
        } else if list.len() == 40 {
            list.push("…".into());
        }
    }
}

fn replay(name: &str, pictures: &[Picture]) -> Failures {
    let mut f = Failures::default();
    let records = fixture_records(name);
    assert!(matches!(records.last(), Some((3, _))), "{name}: no final canvas count");
    let mut run = String::from("(before any run)");
    let mut enc: Option<FrameEncoder> = None;
    let mut dec = Decoder::default();
    let mut mode = Mode::Gray4;
    let mut samples_cache: Vec<Option<Vec<u8>>> = Vec::new();
    // The Rust result of the current call, and the slice the next tag 1 / tag 4 is about.
    let mut got: Vec<FramePayload> = Vec::new();
    let mut slice = 0usize;
    let mut call = 0usize;
    let mut canvases = 0u32;
    let mut decoder_dead = false;

    for (n, (tag, p)) in records.iter().enumerate() {
        let at = format!("{name} record {n} ({run}, call {call}, slice {slice})");
        let mut r = Reader::new(p);
        match *tag {
            10 => {
                mode = Mode::from_byte(r.u8()).expect("mode");
                run = String::from_utf8_lossy(r.rest()).into_owned();
                enc = Some(FrameEncoder::new(mode));
                dec = Decoder::default();
                decoder_dead = false;
                samples_cache = (0..pictures.len()).map(|_| None).collect();
                got.clear();
                call = 0;
            }
            11 => {
                let e = enc.as_mut().expect("call before a run");
                let kind = r.u8();
                let limit = r.u64();
                let first_limit = r.u64();
                let id = r.u32() as usize;
                let has_region = r.u8() == 1;
                let region = CanvasRect::new(r.f32(), r.f32(), r.f32(), r.f32());
                let with_raw = r.u8() == 1;
                let sample_hash = r.u64();
                let pic = &pictures[id];
                let samples = samples_cache[id]
                    .get_or_insert_with(|| quantize(&pic.bgra, pic.width, pic.height, pic.width * 4, mode))
                    .clone();
                if fnv(&samples) != sample_hash {
                    Failures::push(&mut f.frames, &at, format!("frame {id}: quantized samples differ from Swift's"));
                }
                let raw = with_raw.then_some(pic.bgra.as_slice());
                let region = has_region.then_some(region);
                let to_usize = |v: u64| if v == u64::MAX { usize::MAX } else { v as usize };
                got = if kind == 0 {
                    e.encode(&samples, raw, pic.width, pic.height, region).into_iter().collect()
                } else {
                    let fl = (first_limit != u64::MAX).then_some(first_limit as usize);
                    e.encode_slices(&samples, raw, pic.width, pic.height, region, to_usize(limit), fl)
                };
                slice = 0;
                call += 1;
                f.calls += 1;
            }
            12 => enc.as_mut().expect("reset before a run").reset(),
            13 => enc.as_mut().expect("forceFull before a run").force_full = true,
            14 => {
                let e = enc.as_mut().expect("settle before a run");
                got = e.encode_settle(r.u32() as usize);
                slice = 0;
                call += 1;
                f.calls += 1;
            }
            1 => {
                let expected: &[u8] = p;
                match got.get(slice) {
                    None => Failures::push(&mut f.frames, &at, "Swift has a slice more".into()),
                    Some(s) => {
                        let mine = slice_record(s);
                        if mine != expected {
                            let first = mine.iter().zip(expected.iter()).position(|(a, b)| a != b);
                            Failures::push(
                                &mut f.frames,
                                &at,
                                format!(
                                    "slice differs: {} bytes vs Swift {}, first difference at {first:?} \
                                     (header: Rust {:?} / Swift {:?})",
                                    mine.len(),
                                    expected.len(),
                                    &mine[..mine.len().min(18)],
                                    &expected[..expected.len().min(18)]
                                ),
                            );
                        }
                    }
                }
                // Swift's slice into the client's decoder.
                if !decoder_dead {
                    let m = r.u8();
                    let w = r.u16() as usize;
                    let h = r.u16() as usize;
                    let flags = r.u8();
                    let dx = r.i32();
                    let dy = r.i32();
                    let data = r.sized();
                    if let Err(err) = dec.apply(m, w, h, flags, dx, dy, data) {
                        Failures::push(&mut f.decoder, &at, format!("client decoder rejects Swift's slice: {err}"));
                        decoder_dead = true;
                    }
                }
            }
            4 => {
                let len = r.u32() as usize;
                let hash = r.u64();
                let e = enc.as_ref().expect("stream before a run");
                match e.last_tile_streams().get(slice) {
                    None => Failures::push(&mut f.frames, &at, "no Rust tile stream for this slice".into()),
                    Some(s) if s.len() != len || fnv(s) != hash => Failures::push(
                        &mut f.frames,
                        &at,
                        format!("tile stream differs: {} bytes vs Swift {len}", s.len()),
                    ),
                    Some(_) => {}
                }
                slice += 1;
            }
            2 => {
                canvases += 1;
                let w = r.u16() as usize;
                let h = r.u16() as usize;
                let count = r.u32() as usize;
                let hash = r.u64();
                if !decoder_dead {
                    let s = dec.samples_le();
                    if (dec.width, dec.height) != (w, h) || s.len() != count || fnv(&s) != hash {
                        Failures::push(
                            &mut f.decoder,
                            &at,
                            format!(
                                "client canvas {}x{} ({} bytes) differs from Swift's {w}x{h} ({count} bytes)",
                                dec.width,
                                dec.height,
                                s.len()
                            ),
                        );
                    }
                }
                // The encoder's model is the canvas the client has after the frame.
                let e = enc.as_ref().expect("canvas before a run");
                let model = e.model();
                if model.len() != count || fnv(model) != hash {
                    Failures::push(
                        &mut f.frames,
                        &at,
                        format!("encoder model ({} bytes) differs from Swift's canvas ({count} bytes)", model.len()),
                    );
                }
            }
            5 => {
                let e = enc.as_ref().expect("report before a run");
                let region = CanvasRect::new(r.f32(), r.f32(), r.f32(), r.f32());
                let width = r.u32() as usize;
                let height = r.u32() as usize;
                let full = r.u8() == 1;
                let n = r.u32() as usize;
                let changed: Vec<usize> = (0..n).map(|_| r.u32() as usize).collect();
                let has_copy = r.u8() == 1;
                let copy = [r.u32(), r.u32(), r.u32(), r.u32()];
                let Some(rep) = e.last_report() else {
                    Failures::push(&mut f.reports, &at, "Rust has no report".into());
                    continue;
                };
                let bits = |c: &CanvasRect| [c.x.to_bits(), c.y.to_bits(), c.w.to_bits(), c.h.to_bits()];
                if bits(&rep.region) != bits(&region) {
                    Failures::push(&mut f.reports, &at, format!("region {:?} vs Swift {region:?}", rep.region));
                }
                if (rep.width, rep.height, rep.full) != (width, height, full) {
                    Failures::push(
                        &mut f.reports,
                        &at,
                        format!("{}x{} full {} vs Swift {width}x{height} full {full}", rep.width, rep.height, rep.full),
                    );
                }
                if rep.changed != changed {
                    Failures::push(
                        &mut f.reports,
                        &at,
                        format!("changed tiles {:?} vs Swift {changed:?}", rep.changed),
                    );
                }
                let mine = rep.copy_bounds.as_ref().map(|c| [c.x as u32, c.y as u32, c.width as u32, c.height as u32]);
                let swift = has_copy.then_some(copy);
                if mine != swift {
                    Failures::push(&mut f.reports, &at, format!("copy bounds {mine:?} vs Swift {swift:?}"));
                }
            }
            6 => {
                let e = enc.as_ref().expect("state before a run");
                let needs_settle = r.u8() == 1;
                let diverged = r.u8() == 1;
                let added = r.u8() == 1;
                let tiles = r.u32() as usize;
                let count = r.u32() as usize;
                let mine = (
                    e.needs_settle(),
                    e.last_encode_diverged(),
                    e.last_encode_added_approximation(),
                    e.last_tile_count(),
                    got.len(),
                );
                let swift = (needs_settle, diverged, added, tiles, count);
                if mine != swift {
                    Failures::push(
                        &mut f.frames,
                        &at,
                        format!(
                            "state (needs_settle, diverged, added_approximation, last_tile_count, slices) \
                             {mine:?} vs Swift {swift:?}"
                        ),
                    );
                }
            }
            3 => {
                let expected = r.u32();
                assert_eq!(canvases, expected, "{name}: canvas records counted {canvases}, Swift says {expected}");
            }
            t => panic!("{at}: unknown record tag {t}"),
        }
    }
    assert!(f.calls > 0, "{name}: no calls");
    f
}

fn mode_files() -> Vec<String> {
    Mode::ALL.iter().map(|m| format!("tile-{}.bin", m.name())).collect()
}

fn report(what: &str, lists: Vec<(String, Vec<String>)>) {
    let bad: Vec<String> = lists
        .into_iter()
        .filter(|(_, l)| !l.is_empty())
        .map(|(name, l)| format!("{name}:\n  {}", l.join("\n  ")))
        .collect();
    assert!(bad.is_empty(), "{what} differ from Swift:\n{}", bad.join("\n"));
}

#[test]
fn frames_match_swift() {
    let pics = pictures();
    let lists = mode_files().into_iter().map(|n| {
        let f = replay(&n, &pics);
        (n, f.frames)
    });
    report("slices, tile streams or encoder state", lists.collect());
}

#[test]
fn reports_match_swift() {
    let pics = pictures();
    let lists = mode_files().into_iter().map(|n| {
        let f = replay(&n, &pics);
        (n, f.reports)
    });
    report("encode reports", lists.collect());
}

#[test]
fn settle_matches_swift() {
    let pics = pictures();
    let name = "tile-settle.bin".to_string();
    let f = replay(&name, &pics);
    report(
        "settle runs",
        vec![(format!("{name} frames"), f.frames), (format!("{name} reports"), f.reports)],
    );
}

#[test]
fn decoder_agrees() {
    let pics = pictures();
    let mut lists = Vec::new();
    for n in mode_files().into_iter().chain(["tile-settle.bin".to_string()]) {
        let f = replay(&n, &pics);
        lists.push((n, f.decoder));
    }
    report("client-decoded canvases", lists);
}
