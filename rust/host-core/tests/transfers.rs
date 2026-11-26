//! Clip store, side slots and transfers against the Swift reference, replayed in a `tempfile`
//! folder. Fixtures are written by `Tests/RappCoreTests/HostCoreFixtures/ClipFixtures.swift`
//! (`clip-store.json`, `transfer-chunks.bin`); the step language is documented there
//! (`TransferTrace`).

mod common;
mod rules_common;

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use common::{fixture_records, hex, raw_cases, unhex, Reader};
use rapp_host_core::cli::WorkerEvent;
use rapp_host_core::clipboard::CHUNK_SIZE;
use rapp_host_core::transfers::*;
use rapp_host_core::{ClipFile, ClipInfo, ClipKind};
use rules_common::*;
use serde_json::{json, Value};

/// `HostRNG` (HostFixture.swift), so seeded inputs need not be stored.
struct HostRng(u64);

impl HostRng {
    fn new(seed: u64) -> Self {
        HostRng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1))
    }
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }
    fn bytes(&mut self, n: usize) -> Vec<u8> {
        (0..n).map(|_| self.next() as u8).collect()
    }
}

fn info_from(v: &Value) -> ClipInfo {
    match v["type"].as_str().expect("info type") {
        "text" => ClipInfo::Text { text: arg(&v["text"]), truncated: arg(&v["truncated"]) },
        "image" => ClipInfo::Image { width: arg(&v["width"]), height: arg(&v["height"]), bytes: arg(&v["bytes"]) },
        "files" => ClipInfo::Files(
            v["files"]
                .as_array()
                .expect("files")
                .iter()
                .map(|f| ClipFile { name: arg(&f["name"]), bytes: arg(&f["bytes"]) })
                .collect(),
        ),
        "data" => ClipInfo::Data { uti: arg(&v["uti"]), bytes: arg(&v["bytes"]) },
        "unsupported" => ClipInfo::Unsupported(arg(&v["text"])),
        other => panic!("info type {other}"),
    }
}

fn info_json(i: &ClipInfo) -> Value {
    match i {
        ClipInfo::Text { text, truncated } => json!({"type": "text", "text": text, "truncated": truncated}),
        ClipInfo::Image { width, height, bytes } => {
            json!({"type": "image", "width": width, "height": height, "bytes": bytes})
        }
        ClipInfo::Files(files) => json!({
            "type": "files",
            "files": files.iter().map(|f| json!({"name": f.name, "bytes": f.bytes})).collect::<Vec<_>>(),
        }),
        ClipInfo::Data { uti, bytes } => json!({"type": "data", "uti": uti, "bytes": bytes}),
        ClipInfo::Unsupported(t) => json!({"type": "unsupported", "text": t}),
    }
}

fn event_json(e: &WorkerEvent) -> Value {
    match e {
        WorkerEvent::Transfer { dir, kind, bytes, name } => {
            json!({"dir": dir.name(), "kind": *kind as u8, "bytes": bytes, "name": name})
        }
        _ => Value::Null,
    }
}

fn kind_from(v: &Value) -> ClipKind {
    ClipKind::from_byte(arg(v)).expect("clip kind")
}

// MARK: clip-store.json — clips and slots

#[test]
fn clip_store_matches_swift() {
    let cases = raw_cases("clip-store.json");
    assert!(!cases.is_empty());
    let mut kinds = (0, 0, 0);
    for c in cases {
        let steps: Vec<Value> = arg(&c.input["steps"]);
        let outs: Vec<Value> = arg(&c.out);
        assert_eq!(steps.len(), outs.len(), "{}", c.name);
        match func(&c.input) {
            "clips" => {
                kinds.0 += 1;
                let mut s = ClipStore::new(arg(&c.input["change"]));
                for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
                    let got = match step["op"].as_str().unwrap() {
                        "changed" => json!(s.changed(arg(&step["cc"]), arg(&step["front"]))),
                        "own" => {
                            s.note_own_write(arg(&step["cc"]));
                            Value::Null
                        }
                        "add" => json!(s.add(info_from(&step["info"]), ClipPayload::Inline).id),
                        "clip" => s.clip(arg(&step["id"])).map(|c| info_json(&c.info)).unwrap_or(Value::Null),
                        op => panic!("op {op}"),
                    };
                    assert_eq!(&got, want, "{} step {n}: {step}", c.name);
                }
            }
            "slots" => {
                kinds.1 += 1;
                let mut s = SideSlots::new(arg(&c.input["limit"]));
                for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
                    let got = match step["op"].as_str().unwrap() {
                        "take" => json!(s.take()),
                        _ => {
                            s.release();
                            Value::Null
                        }
                    };
                    assert_eq!(&got, want, "{} step {n}", c.name);
                }
            }
            "transfers" => {
                kinds.2 += 1;
                replay_transfers(&c.name, arg(&c.input["limit"]), &steps, &outs);
            }
            other => panic!("{}: fn {other}", c.name),
        }
    }
    assert!(kinds.0 > 0 && kinds.1 > 0 && kinds.2 > 0, "{kinds:?}");
}

// MARK: clip-store.json — transfers

struct Replay {
    dir: tempfile::TempDir,
    store: TransferStore,
    sinks: HashMap<u32, Arc<Mutex<PutSink>>>,
    sources: HashMap<String, Vec<u8>>,
    clip_bytes: HashMap<u32, Vec<Vec<u8>>>,
    buffer: Vec<u8>,
}

impl Replay {
    fn uploads(&self) -> PathBuf {
        self.dir.path().join("uploads")
    }

    fn listing(&self) -> Value {
        let mut names: Vec<String> = fs::read_dir(self.uploads())
            .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        names.sort();
        json!(names)
    }

    fn write(&mut self, item: u32, bytes: &[u8]) -> Value {
        let Some(sink) = self.sinks.get(&item) else { return json!({"error": "no sink"}) };
        let mut s = sink.lock().unwrap();
        match s.write(bytes) {
            Ok(done) => json!({"done": done, "have": s.have()}),
            Err(e) => json!({"error": e.0}),
        }
    }
}

fn replay_transfers(name: &str, limit: usize, steps: &[Value], outs: &[Value]) {
    let dir = tempfile::tempdir().unwrap();
    let uploads = dir.path().join("uploads");
    let mut r = Replay {
        store: TransferStore::new(ClipStore::new(0), uploads.clone(), limit),
        dir,
        sinks: HashMap::new(),
        sources: HashMap::new(),
        clip_bytes: HashMap::new(),
        buffer: Vec::new(),
    };
    for (n, (step, want)) in steps.iter().zip(outs).enumerate() {
        let root = r.dir.path().to_path_buf();
        let got = match step["op"].as_str().unwrap() {
            "source" => {
                let bytes = HostRng::new(arg(&step["seed"])).bytes(arg(&step["size"]));
                let file: String = arg(&step["name"]);
                fs::write(root.join(&file), &bytes).unwrap();
                r.sources.insert(file, bytes);
                Value::Null
            }
            "append" => {
                let file: String = arg(&step["name"]);
                let bytes = unhex(step["hex"].as_str().unwrap());
                let mut f = fs::OpenOptions::new().append(true).open(root.join(&file)).unwrap();
                f.write_all(&bytes).unwrap();
                r.sources.entry(file).or_default().extend_from_slice(&bytes);
                Value::Null
            }
            "remove" => {
                fs::remove_file(root.join(step["name"].as_str().unwrap())).unwrap();
                Value::Null
            }
            "file_clip" => {
                let sources: Vec<String> = arg(&step["sources"]);
                let shown: Vec<String> = arg(&step["names"]);
                let refs: Vec<FileRef> = sources
                    .iter()
                    .map(|s| {
                        let path = root.join(s);
                        let meta = fs::metadata(&path).unwrap();
                        FileRef { path, size: meta.len(), modified: meta.modified().unwrap() }
                    })
                    .collect();
                let files = shown
                    .iter()
                    .enumerate()
                    .map(|(i, s)| ClipFile { name: s.clone(), bytes: refs[i.min(refs.len() - 1)].size })
                    .collect();
                let c = r.store.clips.add(ClipInfo::Files(files), ClipPayload::Files(refs));
                r.clip_bytes.insert(c.id, sources.iter().map(|s| r.sources.get(s).cloned().unwrap_or_default()).collect());
                json!(c.id)
            }
            "bytes_clip" => {
                let bytes = HostRng::new(arg(&step["seed"])).bytes(arg(&step["size"]));
                let c = r.store.clips.add(info_from(&step["info"]), ClipPayload::Bytes(bytes.clone()));
                r.clip_bytes.insert(c.id, vec![bytes]);
                json!(c.id)
            }
            "text_clip" => {
                let text: String = arg(&step["text"]);
                json!(r.store.clips.add(ClipInfo::Text { text, truncated: false }, ClipPayload::Inline).id)
            }
            "fetch" => {
                let (clip, file, offset): (u32, u16, u64) = (arg(&step["clip"]), arg(&step["file"]), arg(&step["offset"]));
                match r.store.fetch(clip, file, offset) {
                    Err(e) => json!({"error": e.0}),
                    Ok(mut source) => {
                        let mut lengths = Vec::new();
                        let mut got = Vec::new();
                        loop {
                            match source.next() {
                                Ok(Some(chunk)) => {
                                    assert!(chunk.len() <= CHUNK_SIZE);
                                    lengths.push(chunk.len());
                                    got.extend_from_slice(&chunk);
                                }
                                Ok(None) => break,
                                Err(e) => panic!("{name} step {n}: {e}"),
                            }
                        }
                        if let Some(all) = r.clip_bytes.get(&clip).and_then(|a| a.get(file as usize)) {
                            assert_eq!(hex(&got), hex(&all[offset as usize..]), "{name} step {n}: bytes");
                        }
                        json!({"total": source.total, "transfer": event_json(&source.transfer), "chunks": lengths, "position": offset})
                    }
                }
            }
            "data" => {
                r.buffer = HostRng::new(arg(&step["seed"])).bytes(arg(&step["size"]));
                Value::Null
            }
            "put" => {
                let item: u32 = arg(&step["item"]);
                let uti: String = arg(&step["uti"]);
                let file: String = arg(&step["name"]);
                match r.store.put(item, kind_from(&step["kind"]), &uti, &file, arg(&step["total"])) {
                    Err(e) => json!({"error": e.0}),
                    Ok(sink) => {
                        let out = {
                            let s = sink.lock().unwrap();
                            json!({"have": s.have(), "transfer": event_json(&s.transfer())})
                        };
                        r.sinks.insert(item, sink);
                        out
                    }
                }
            }
            "write" => {
                let (from, to): (usize, usize) = (arg(&step["from"]), arg(&step["to"]));
                let bytes = r.buffer[from..to].to_vec();
                r.write(arg(&step["item"]), &bytes)
            }
            "write_hex" => {
                let bytes = unhex(step["hex"].as_str().unwrap());
                r.write(arg(&step["item"]), &bytes)
            }
            "received" => match r.store.received(arg(&step["item"])) {
                None => Value::Null,
                Some(ReceivedItem::Text(t)) => json!({"text": t}),
                Some(ReceivedItem::Image(b)) => json!({"image": hex(&b)}),
                Some(ReceivedItem::Data { uti, bytes }) => json!({"data": hex(&bytes), "uti": uti}),
                Some(ReceivedItem::File(path)) => {
                    assert_eq!(path.parent(), Some(uploads.as_path()), "{name} step {n}");
                    json!({"file": path.file_name().unwrap().to_string_lossy()})
                }
            },
            "preexisting" => {
                fs::create_dir_all(&uploads).unwrap();
                fs::write(uploads.join(step["name"].as_str().unwrap()), step["text"].as_str().unwrap()).unwrap();
                Value::Null
            }
            "listing" => r.listing(),
            op => panic!("{name}: op {op}"),
        };
        assert_eq!(&got, want, "{name} step {n}: {step}");
    }
}

// MARK: transfer-chunks.bin

#[test]
fn transfer_chunks_match_swift() {
    let records = fixture_records("transfer-chunks.bin");
    assert!(!records.is_empty());
    let (tag, header) = &records[0];
    assert_eq!(*tag, 0);
    let mut h = Reader::new(header);
    let seed = h.u64();
    let size = h.u64() as usize;
    let data = HostRng::new(seed).bytes(size);
    assert_eq!(h.sized(), &data[..64], "HostRng mirror, head");
    assert_eq!(h.sized(), &data[size - 64..], "HostRng mirror, tail");

    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("big.bin");
    fs::write(&src, &data).unwrap();
    let meta = fs::metadata(&src).unwrap();
    let mut store = TransferStore::new(ClipStore::new(0), dir.path().join("uploads"), TRANSFER_MEMORY_LIMIT);
    let clip = store.clips.add(
        ClipInfo::Files(vec![ClipFile { name: "big.bin".into(), bytes: size as u64 }]),
        ClipPayload::Files(vec![FileRef { path: src.clone(), size: size as u64, modified: meta.modified().unwrap() }]),
    );

    for (tag, start) in [(1u8, 0u64), (2u8, 300_000u64)] {
        let want: Vec<(u64, u32)> = records
            .iter()
            .filter(|(t, _)| *t == tag)
            .map(|(_, p)| {
                let mut r = Reader::new(p);
                (r.u64(), r.u32())
            })
            .collect();
        let mut source = store.fetch(clip.id, 0, start).unwrap();
        let mut got = Vec::new();
        let mut position = start;
        while let Some(chunk) = source.next().unwrap() {
            assert_eq!(chunk, &data[position as usize..position as usize + chunk.len()]);
            got.push((position, chunk.len() as u32));
            position += chunk.len() as u64;
        }
        assert_eq!(got, want, "fetch from {start}");
    }

    let uploads = dir.path().join("uploads");
    let sink = store.put(1, ClipKind::Files, "", "big.bin", size as u64).unwrap();
    let want: Vec<(u64, bool, u64, String)> = records
        .iter()
        .filter(|(t, _)| *t == 3)
        .map(|(_, p)| {
            let mut r = Reader::new(p);
            (r.u64(), r.u8() == 1, r.u64(), String::from_utf8(r.sized().to_vec()).unwrap())
        })
        .collect();
    let mut got = Vec::new();
    for chunk in data.chunks(CHUNK_SIZE) {
        let mut s = sink.lock().unwrap();
        let done = s.write(chunk).unwrap();
        let parts = part_files(&uploads);
        let (part_name, part_size) = match parts.first() {
            Some(p) => (p.clone(), fs::metadata(uploads.join(p)).map(|m| m.len()).unwrap_or(u64::MAX)),
            None => (String::new(), u64::MAX),
        };
        got.push((s.have(), done, part_size, part_name));
    }
    assert_eq!(got, want);

    let (_, last) = records.iter().find(|(t, _)| *t == 4).expect("final record");
    let mut r = Reader::new(last);
    let final_name = String::from_utf8(r.sized().to_vec()).unwrap();
    let final_size = r.u64();
    match store.received(1) {
        Some(ReceivedItem::File(path)) => {
            assert_eq!(path.file_name().unwrap().to_string_lossy(), final_name);
            assert_eq!(fs::metadata(&path).unwrap().len(), final_size);
            assert_eq!(fs::read(&path).unwrap(), data);
        }
        other => panic!("not received: {other:?}"),
    }
}

fn part_files(dir: &Path) -> Vec<String> {
    let mut parts: Vec<String> = fs::read_dir(dir)
        .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    parts.retain(|n| n.ends_with(PART_SUFFIX));
    parts.sort();
    parts
}

// MARK: literal checks

#[test]
fn transfer_dir_prefers_rapp_downloads() {
    let root = Path::new("/data");
    let set = |v: &'static str| move |k: &str| (k == "RAPP_DOWNLOADS").then(|| v.to_string());
    assert_eq!(transfer_dir(&set("/d"), root), PathBuf::from("/d"));
    assert_eq!(transfer_dir(&set(""), root), root.join("files").join("transfers"));
    assert_eq!(transfer_dir(&|_| None, root), root.join("files").join("transfers"));
}

#[test]
fn memory_limit_default_is_swifts() {
    assert_eq!(TRANSFER_MEMORY_LIMIT, 256 << 20);
    assert_eq!(ClipStore::CAPACITY, 50);
}
