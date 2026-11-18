use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::io::{BufRead, Read, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, SyncSender};
use std::time::{Duration, Instant};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

const RATE: usize = 16_000;
const MAX_SAMPLES: usize = RATE * 60;
const CHUNK: usize = RATE / 50; // 20 ms; bounded stop latency without retaining recordings.

pub fn emit(value: Value) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{value}");
    let _ = stdout.flush();
}

fn audible(audio: &[f32]) -> bool {
    audio.len() >= RATE / 10 && audio.chunks(CHUNK).any(|chunk| rms(chunk) > 0.004)
}

fn rms(audio: &[f32]) -> f32 {
    if audio.is_empty() {
        return 0.;
    }
    (audio.iter().map(|v| v * v).sum::<f32>() / audio.len() as f32).sqrt()
}

fn decode(ctx: &WhisperContext, language: &str, audio: &[f32]) -> Result<String> {
    if !audible(audio) {
        return Ok(String::new());
    }
    let mut state = ctx.create_state()?;
    let mut p = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    p.set_n_threads(
        std::thread::available_parallelism().map_or(2, |n| (n.get() / 2).clamp(1, 4)) as i32,
    );
    p.set_language(Some(language));
    p.set_translate(false);
    p.set_no_context(true);
    p.set_no_timestamps(true);
    p.set_print_special(false);
    p.set_print_progress(false);
    p.set_print_realtime(false);
    p.set_print_timestamps(false);
    state.full(p, audio)?;
    Ok(state
        .as_iter()
        .map(|s| s.to_string())
        .collect::<String>()
        .trim()
        .to_owned())
}

enum Event {
    Audio(Vec<f32>),
    End,
    Stop,
    Cancel,
    Decoded(usize, Result<String>),
}

struct Capture(Child);
impl Drop for Capture {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn read_audio(mut input: impl Read, tx: SyncSender<Event>) {
    let mut bytes = [0u8; CHUNK * 2];
    loop {
        let mut n = 0;
        while n < bytes.len() {
            match input.read(&mut bytes[n..]) {
                Ok(0) | Err(_) => break,
                Ok(read) => n += read,
            }
        }
        if n == 0 {
            break;
        }
        let samples = bytes[..n]
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.)
            .collect();
        if tx.send(Event::Audio(samples)).is_err() {
            return;
        }
    }
    let _ = tx.send(Event::End);
}

pub fn run() -> Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        emit(json!({"version":env!("CARGO_PKG_VERSION"),"backend":"whisper.cpp","local":true}));
        return Ok(());
    }
    // A bounded startup message. The GUI supplies only a model path and its system language.
    let mut line = String::new();
    std::io::stdin().lock().take(65_536).read_line(&mut line)?;
    ensure!(line.len() < 65_536, "startup message too long");
    let start: Value = serde_json::from_str(&line)?;
    let model = start["model"].as_str().context("missing model")?;
    let language = start["language"]
        .as_str()
        .context("missing language")?
        .to_owned();
    if whisper_rs::get_lang_id(&language).is_none() {
        emit(json!({"event":"error","code":"language"}));
        return Ok(());
    }
    let mut options = WhisperContextParameters::default();
    options.use_gpu(false); // A portable package must not depend on the build machine's GPU.
    let ctx = WhisperContext::new_with_params(model, options)?;
    let (tx, rx) = mpsc::sync_channel::<Event>(64);
    let (jobs, work) = mpsc::sync_channel::<Vec<f32>>(1);
    let results = tx.clone();
    std::thread::spawn(move || {
        for audio in work {
            let size = audio.len();
            let result = decode(&ctx, &language, &audio);
            if results.send(Event::Decoded(size, result)).is_err() {
                break;
            }
        }
    });
    let commands = tx.clone();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut input = stdin.lock();
        loop {
            let mut line = String::new();
            if input.by_ref().take(4096).read_line(&mut line).unwrap_or(0) == 0
                || line.len() >= 4096
            {
                let _ = commands.send(Event::Cancel);
                break;
            }
            let event = match serde_json::from_str::<Value>(&line)
                .ok()
                .as_ref()
                .and_then(|v| v["cmd"].as_str())
            {
                Some("stop") => Event::Stop,
                _ => Event::Cancel,
            };
            if commands.send(event).is_err() {
                break;
            }
        }
    });

    // Explicit fixture mode permits real model tests without accessing any microphone.
    let fixture = start["pcm_path"].as_str();
    let mut capture = if let Some(path) = fixture {
        let input = std::fs::File::open(path)?;
        let audio = tx.clone();
        std::thread::spawn(move || read_audio(input, audio));
        None
    } else {
        let mut cmd = Command::new("parec");
        cmd.args([
            "--raw",
            "--format=s16le",
            "--rate=16000",
            "--channels=1",
            "--client-name=rapp",
            "--stream-name=Voice input",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
        let parent = std::process::id() as libc::pid_t;
        // SAFETY: only async-signal-safe libc calls between fork and exec. A killed/crashed
        // worker must never leave a microphone recorder behind.
        unsafe {
            cmd.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    libc::_exit(1);
                }
                Ok(())
            });
        }
        let mut child = Capture(cmd.spawn().context("start PulseAudio capture")?);
        let output = child.0.stdout.take().context("capture pipe")?;
        let audio = tx.clone();
        std::thread::spawn(move || read_audio(output, audio));
        Some(child)
    };
    drop(tx);
    let mut audio = Vec::new();
    let mut ready = false;
    let mut finishing = false;
    let mut decoding = false;
    let mut last_decode = 0;
    let mut last_level = Instant::now();
    let mut last_text = String::new();
    loop {
        let event = match rx.recv_timeout(Duration::from_secs(if ready { 90 } else { 8 })) {
            Ok(event) => event,
            Err(_) => bail!("speech worker timed out"),
        };
        match event {
            Event::Cancel => return Ok(()),
            Event::Audio(samples) if !finishing => {
                if !ready {
                    ready = true;
                    emit(json!({"event":"ready"}));
                }
                if last_level.elapsed() >= Duration::from_millis(80) {
                    emit(json!({"event":"level","value":(rms(&samples) * 8.).min(1.)}));
                    last_level = Instant::now();
                }
                let keep = samples.len().min(MAX_SAMPLES - audio.len());
                audio.extend_from_slice(&samples[..keep]);
                if audio.len() == MAX_SAMPLES {
                    finishing = true;
                    capture.take();
                }
            }
            Event::Audio(_) => {}
            Event::End if fixture.is_some() => {
                finishing = true;
            }
            Event::End if !finishing => bail!("microphone capture ended"),
            Event::End => {}
            Event::Stop => {
                finishing = true;
                capture.take();
            }
            Event::Decoded(size, result) => {
                decoding = false;
                last_decode = size;
                last_text = result?;
                if !finishing {
                    emit(json!({"event":"partial","text":last_text}));
                }
            }
        }
        if !decoding && finishing && (last_decode == audio.len() || !audible(&audio)) {
            emit(json!({"event":"final","text":if audible(&audio) { &last_text } else { "" }}));
            return Ok(());
        }
        if !decoding && (finishing || (fixture.is_none() && audio.len() >= last_decode + RATE * 2))
        {
            jobs.send(audio.clone())?;
            decoding = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn silence_and_clicks_do_not_trigger_recognition() {
        assert!(!audible(&vec![0.; RATE]));
        assert!(!audible(&vec![0.001; RATE]));
        assert!(!audible(&vec![0.4; 100]));
        assert!(audible(&vec![0.1; RATE / 4]));
    }
    #[test]
    fn pcm_chunks_preserve_signed_samples_and_eof() {
        let (tx, rx) = mpsc::sync_channel(4);
        read_audio(&[0, 128, 0, 0, 255, 127][..], tx);
        let Event::Audio(audio) = rx.recv().unwrap() else {
            panic!()
        };
        assert_eq!(audio, vec![-1., 0., 32767. / 32768.]);
        assert!(matches!(rx.recv().unwrap(), Event::End));
    }
}
