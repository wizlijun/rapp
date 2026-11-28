//! The engine on its own, before it goes into the app (after voicekey's `wtl`):
//!   wxasr <model dir> a.wav [b.wav ...]   decode each file offline and time it
//!   wxasr <model dir> --live a.wav        push at real-time pace, print the partials (the app's pacing)
//!   wxasr --unpack pack.apk <model dir>   unpack the official speech pack
//! Wav files: 16 kHz, mono, 16-bit.
use rapp_speech_wx::{pack, Model, Session, Stream};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

fn wav(path: &str) -> Vec<i16> {
    hound::WavReader::open(path)
        .expect("open wav")
        .samples::<i16>()
        .map(|s| s.expect("wav sample"))
        .collect()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("usage: wxasr <model dir> a.wav ... | <model dir> --live a.wav | --unpack pack.apk <model dir>");
        std::process::exit(2);
    }
    if args[0] == "--unpack" {
        let t = Instant::now();
        pack::unpack(args[1].as_ref(), args[2].as_ref()).expect("unpack");
        println!("unpacked in {:.1}s", t.elapsed().as_secs_f64());
        return;
    }
    let t = Instant::now();
    let m = Arc::new(Model::load(args[0].as_ref()).expect("load model"));
    eprintln!("load {:.0}ms", t.elapsed().as_secs_f64() * 1e3);
    if args[1] == "--live" {
        let pcm = wav(&args[2]);
        let (tx, rx) = mpsc::channel::<Vec<i16>>();
        let t = Instant::now();
        let feed = std::thread::spawn(move || {
            for (i, c) in pcm.chunks(320).enumerate() {
                let due = Duration::from_millis(20 * i as u64);
                if let Some(wait) = due.checked_sub(t.elapsed()) {
                    std::thread::sleep(wait);
                }
                let _ = tx.send(c.to_vec());
            }
            Instant::now()
        });
        let mut s = Session::new(m);
        while let Ok(f) = rx.recv() {
            s.push(&f);
            while let Ok(f) = rx.try_recv() {
                s.push(&f);
            }
            if let Some(p) = s.partial() {
                println!("… {:.2}s {p}", t.elapsed().as_secs_f64());
            }
        }
        let text = s.finish();
        let end = feed.join().expect("feeder");
        println!(
            "FINAL +{:.0}ms after audio end ({:.2}s) {text}",
            end.elapsed().as_secs_f64() * 1e3,
            t.elapsed().as_secs_f64()
        );
        return;
    }
    for f in &args[1..] {
        let pcm = wav(f);
        let t = Instant::now();
        let mut s = Stream::new(m.clone());
        for c in pcm.chunks(320) {
            s.push(c);
        }
        let txt = s.finish();
        let name = std::path::Path::new(f)
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy();
        println!(
            "{name} audio {:.2}s {:.0}ms\t{txt}",
            pcm.len() as f64 / 16000.0,
            t.elapsed().as_secs_f64() * 1e3
        );
    }
}
