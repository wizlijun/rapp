//! Bound stdout latency independently of the remote reader. Every compressed
//! delta is decoded, but only the newest complete canvas waits for the pipe.
use anyhow::{ensure, Result};
use std::{
    collections::VecDeque,
    io::{self, Write},
    sync::{Arc, Condvar, Mutex},
    thread::{self, JoinHandle},
};

const MAX_EVENTS: usize = 32;

enum Packet {
    Event(Vec<u8>),
    Frame([u8; 24], Vec<u8>),
}

#[derive(Default)]
struct State {
    pending: VecDeque<Packet>,
    recycled: Vec<u8>,
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

    pub fn frame(&self, header: [u8; 24], pixels: &mut Vec<u8>) -> Result<()> {
        let (mutex, wake) = &*self.0;
        let mut s = mutex.lock().unwrap();
        ensure!(!s.closing, "session output closed");
        let reuse = if let Some(i) = s
            .pending
            .iter()
            .position(|p| matches!(p, Packet::Frame(..)))
        {
            let Some(Packet::Frame(_, old)) = s.pending.remove(i) else {
                unreachable!()
            };
            old
        } else {
            std::mem::take(&mut s.recycled)
        };
        // Append after intervening metadata, never put a new canvas ahead of
        // the window table that describes it. Reuse the replaced allocation.
        let latest = std::mem::replace(pixels, reuse);
        s.pending.push_back(Packet::Frame(header, latest));
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
        s.recycled.clear();
        wake.notify_all();
        result
    }

    fn drain(&self, writer: &mut impl Write) -> io::Result<()> {
        let (mutex, wake) = &*self.0;
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
                Packet::Frame(header, pixels) => {
                    writer.write_all(&((pixels.len() + 25) as u32).to_le_bytes())?;
                    writer.write_all(&[1])?;
                    writer.write_all(&header)?;
                    writer.write_all(&pixels)?;
                    mutex.lock().unwrap().recycled = pixels;
                }
            }
            writer.flush()?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

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
        out.frame([1; 24], &mut vec![1; 4]).unwrap();
        wait.recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        for n in 2..100 {
            out.frame([n; 24], &mut vec![n; 4]).unwrap();
        }
        out.event(b"windows".to_vec()).unwrap();
        out.frame([100; 24], &mut vec![100; 4]).unwrap();
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
        assert_eq!(packets[0], [vec![1], vec![1; 28]].concat());
        assert_eq!(packets[1], [vec![0], b"windows".to_vec()].concat());
        assert_eq!(packets[2], [vec![1], vec![100; 28]].concat());
    }
}
