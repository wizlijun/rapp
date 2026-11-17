//! Bound stdout latency independently of the remote reader. Every compressed
//! delta is decoded, but only the newest compact canvas waits for the pipe.
//! BGRA expansion happens here, after coalescing, never in the network reader.
use anyhow::{ensure, Result};
use rapp_client_core::codec::{DecodedCanvas, Decoder};
use std::{
    collections::VecDeque,
    io::{self, Write},
    sync::{Arc, Condvar, Mutex},
    thread::{self, JoinHandle},
};

const MAX_EVENTS: usize = 32;

enum Packet {
    Event(Vec<u8>),
    Frame([u8; 24], DecodedCanvas, u64),
}

#[derive(Default)]
struct State {
    pending: VecDeque<Packet>,
    recycled: DecodedCanvas,
    closing: bool,
}

#[derive(Clone, Default)]
pub(super) struct Output(Arc<(Mutex<State>, Condvar)>);

impl Output {
    pub fn spawn(writer: impl Write + Send + 'static) -> (Self, JoinHandle<io::Result<()>>) {
        let out = Self::default();
        let sender = out.clone();
        let thread = thread::spawn(move || sender.write_loop(writer));
        (out, thread)
    }

    pub fn event(&self, bytes: Vec<u8>) -> Result<()> {
        let (mutex, wake) = &*self.0;
        let mut s = mutex.lock().unwrap();
        // Metadata stays ordered and bounded too. Normal frame backpressure
        // never stops the network reader or hides a remote error behind frames.
        while !s.closing && s.pending.len() >= MAX_EVENTS {
            s = wake.wait(s).unwrap();
        }
        ensure!(!s.closing, "session output closed");
        s.pending.push_back(Packet::Event(bytes));
        wake.notify_all();
        Ok(())
    }

    pub fn frame(&self, header: [u8; 24], decoder: &Decoder, sequence: u64) -> Result<()> {
        let (mutex, wake) = &*self.0;
        let mut s = mutex.lock().unwrap();
        ensure!(!s.closing, "session output closed");
        let mut canvas = if let Some(i) = s
            .pending
            .iter()
            .position(|p| matches!(p, Packet::Frame(..)))
        {
            let Some(Packet::Frame(_, old, _)) = s.pending.remove(i) else {
                unreachable!()
            };
            old
        } else {
            std::mem::take(&mut s.recycled)
        };
        // Append after intervening metadata, never put a new canvas ahead of
        // the window table that describes it. Reuse the replaced allocation.
        decoder.snapshot_into(&mut canvas);
        s.pending.push_back(Packet::Frame(header, canvas, sequence));
        wake.notify_all();
        Ok(())
    }

    pub fn finish(&self) {
        let (mutex, wake) = &*self.0;
        mutex.lock().unwrap().closing = true;
        wake.notify_all();
    }

    fn write_loop(&self, mut writer: impl Write) -> io::Result<()> {
        let result = self.drain(&mut writer);
        let (mutex, wake) = &*self.0;
        let mut s = mutex.lock().unwrap();
        s.closing = true;
        s.pending.clear();
        s.recycled = DecodedCanvas::default();
        wake.notify_all();
        result
    }

    fn drain(&self, writer: &mut impl Write) -> io::Result<()> {
        let (mutex, wake) = &*self.0;
        let mut pixels = Vec::new();
        let mut output = 0u64;
        loop {
            let packet = {
                let mut s = mutex.lock().unwrap();
                while s.pending.is_empty() && !s.closing {
                    s = wake.wait(s).unwrap();
                }
                let Some(packet) = s.pending.pop_front() else {
                    return Ok(());
                };
                wake.notify_all();
                packet
            };
            match packet {
                Packet::Event(bytes) => {
                    writer.write_all(&((bytes.len() + 1) as u32).to_le_bytes())?;
                    writer.write_all(&[0])?;
                    writer.write_all(&bytes)?;
                }
                Packet::Frame(header, canvas, sequence) => {
                    output += 1;
                    crate::session_trace::record("expand-start", format_args!("frame={sequence} output={output}"));
                    // The reader can continue applying/acknowledging deltas and
                    // replacing its pending snapshot during conversion and I/O.
                    canvas.expand_into(&mut pixels);
                    crate::session_trace::record("write-start", format_args!("frame={sequence} output={output}"));
                    writer.write_all(&((pixels.len() + 25) as u32).to_le_bytes())?;
                    writer.write_all(&[1])?;
                    writer.write_all(&header)?;
                    writer.write_all(&pixels)?;
                    crate::session_trace::record("write-end", format_args!("frame={sequence} output={output}"));
                    mutex.lock().unwrap().recycled = canvas;
                }
            }
            writer.flush()?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{write::ZlibEncoder, Compression};
    use std::sync::mpsc;

    fn decoder(value: u16) -> Decoder {
        let mut z = ZlibEncoder::new(Vec::new(), Compression::fast());
        z.write_all(&[1, 0, 0, 0, 0]).unwrap();
        z.write_all(&value.to_le_bytes()).unwrap();
        z.flush().unwrap();
        let mut d = Decoder::default();
        assert!(d.apply(2, 1, 1, 7, 0, 0, z.get_ref()).unwrap());
        d
    }

    struct GatedWriter {
        entered: Option<mpsc::SyncSender<()>>,
        release: mpsc::Receiver<()>,
        bytes: Arc<Mutex<Vec<u8>>>,
    }
    impl Write for GatedWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            if let Some(entered) = self.entered.take() {
                entered.send(()).unwrap();
                self.release.recv().unwrap();
            }
            self.bytes.lock().unwrap().extend(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn stalled_pipe_keeps_one_latest_frame_after_its_metadata() {
        let (entered, wait) = mpsc::sync_channel(1);
        let (release, gate) = mpsc::channel();
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (out, writer) = Output::spawn(GatedWriter {
            entered: Some(entered),
            release: gate,
            bytes: bytes.clone(),
        });
        out.frame([1; 24], &decoder(0xf800), 1).unwrap();
        wait.recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        for n in 2..100 {
            out.frame([n; 24], &decoder(n.into()), n.into()).unwrap();
        }
        out.event(b"windows".to_vec()).unwrap();
        out.frame([100; 24], &decoder(0x07e0), 100).unwrap();
        assert_eq!(out.0 .0.lock().unwrap().pending.len(), 2);
        out.finish();
        release.send(()).unwrap();
        writer.join().unwrap().unwrap();
        let bytes = bytes.lock().unwrap();
        let mut at = 0;
        let mut packets = Vec::new();
        while at < bytes.len() {
            let n = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
            packets.push(bytes[at + 4..at + 4 + n].to_vec());
            at += n + 4;
        }
        assert_eq!(packets.len(), 3);
        assert_eq!(packets[0], [vec![1], vec![1; 24], vec![0, 0, 255, 255]].concat());
        assert_eq!(packets[1], [vec![0], b"windows".to_vec()].concat());
        assert_eq!(packets[2], [vec![1], vec![100; 24], vec![0, 255, 0, 255]].concat());
    }
}
