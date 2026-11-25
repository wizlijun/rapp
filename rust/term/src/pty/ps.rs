//! OSC 7501 program-status scanner.
//!
//! The state machine is ported from gascity `internal/runtime/programstatus/scanner.go`
//! (MIT, Copyright (c) 2026 Gas City Contributors, commit
//! 0997336456fe67f0315d9e41dabc7167e74c2fa9), without the tmux passthrough
//! unwrapping: any DCS is skipped whole, up to its `ESC \`.

/// Longest accepted sequence, `ESC ]` and terminator included.
pub const MAX_SEQUENCE: usize = 4096;

const OSC_INTRO: usize = 2; // ESC ]
const BEL_LEN: usize = 1;
const ST_LEN: usize = 2; // ESC \
const MAX_BUFFER: usize = MAX_SEQUENCE - OSC_INTRO - BEL_LEN;
const P7501: &[u8] = b"7501;";
const P133A: &[u8] = b"133;A";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// `ESC ] 7501 ; ?`
    Probe,
    /// Text between `ESC ] 7501 ;` and the terminator.
    Report(String),
    /// `OSC 133;A`, a shell prompt start.
    Prompt,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
    Dcs,
    DcsEsc,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum Kind {
    #[default]
    Pending,
    Is7501,
    Prompt,
    Skip,
}

#[derive(Default)]
pub struct Scanner {
    state: State,
    kind: Kind,
    buf: Vec<u8>,
}

impl Scanner {
    pub fn feed(&mut self, bytes: &[u8], mut emit: impl FnMut(Event)) {
        for &c in bytes {
            self.step(c, &mut emit);
        }
    }

    fn step(&mut self, c: u8, emit: &mut impl FnMut(Event)) {
        match self.state {
            State::Ground => {
                if c == 0x1b {
                    self.state = State::Esc;
                }
            }
            State::Esc => self.escape(c),
            State::Osc => match c {
                0x07 => self.finish(BEL_LEN, emit),
                0x1b => self.state = State::OscEsc,
                0x18 | 0x1a => self.state = State::Ground,
                _ => self.osc_byte(c),
            },
            State::OscEsc => {
                if c == b'\\' {
                    self.finish(ST_LEN, emit);
                } else {
                    self.escape(c); // the interrupting escape starts anew
                }
            }
            State::Dcs => {
                if c == 0x1b {
                    self.state = State::DcsEsc;
                }
            }
            State::DcsEsc => {
                self.state = if c == b'\\' { State::Ground } else { State::Dcs };
            }
        }
    }

    fn escape(&mut self, c: u8) {
        match c {
            b']' => {
                self.state = State::Osc;
                self.kind = Kind::Pending;
                self.buf.clear();
            }
            b'P' => self.state = State::Dcs,
            0x1b => self.state = State::Esc,
            _ => self.state = State::Ground,
        }
    }

    fn osc_byte(&mut self, c: u8) {
        match self.kind {
            Kind::Skip | Kind::Prompt => return,
            Kind::Is7501 => {
                if self.buf.len() >= MAX_BUFFER {
                    self.kind = Kind::Skip;
                    self.buf.clear();
                } else {
                    self.buf.push(c);
                }
                return;
            }
            Kind::Pending => {}
        }
        self.buf.push(c);
        let b = self.buf.as_slice();
        if b == P7501 {
            self.kind = Kind::Is7501;
        } else if b == b"133;A;" {
            self.kind = Kind::Prompt;
        } else if !(P7501.starts_with(b) || P133A.starts_with(b)) {
            self.kind = Kind::Skip;
        }
    }

    fn finish(&mut self, term_len: usize, emit: &mut impl FnMut(Event)) {
        self.state = State::Ground;
        match self.kind {
            Kind::Prompt => emit(Event::Prompt),
            Kind::Pending if self.buf == P133A => emit(Event::Prompt),
            Kind::Is7501 => {
                if OSC_INTRO + self.buf.len() + term_len > MAX_SEQUENCE {
                    return;
                }
                let body = &self.buf[P7501.len()..];
                if body == b"?" {
                    emit(Event::Probe);
                } else {
                    emit(Event::Report(String::from_utf8_lossy(body).into_owned()));
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
pub(crate) fn capture(name: &str) -> (Vec<u8>, Vec<usize>) {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/ps");
    let data = std::fs::read(dir.join(format!("{name}.bin"))).unwrap();
    let reads: Vec<usize> = std::fs::read_to_string(dir.join(format!("{name}.reads")))
        .unwrap()
        .split_whitespace()
        .map(|s| s.parse().unwrap())
        .collect();
    assert_eq!(reads.iter().sum::<usize>(), data.len(), "{name}");
    (data, reads)
}

#[cfg(test)]
pub(crate) fn chunks(name: &str) -> Vec<Vec<u8>> {
    let (data, reads) = capture(name);
    let mut at = 0;
    reads
        .iter()
        .map(|&n| {
            at += n;
            data[at - n..at].to_vec()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn events(chunks: &[&[u8]]) -> Vec<String> {
        let mut s = Scanner::default();
        let mut out = Vec::new();
        for c in chunks {
            s.feed(c, |e| {
                out.push(match e {
                    Event::Probe => "probe".to_string(),
                    Event::Prompt => "prompt".to_string(),
                    Event::Report(b) => format!("report:{b}"),
                })
            });
        }
        out
    }

    #[test]
    fn probe_with_bel_or_st() {
        assert_eq!(events(&[b"\x1b]7501;?\x07"]), ["probe"]);
        assert_eq!(events(&[b"\x1b]7501;?\x1b\\"]), ["probe"]);
    }

    #[test]
    fn report_body_and_prompt() {
        assert_eq!(
            events(&[b"a\x1b]7501;state=working\x07b\x1b]133;A\x07"]),
            ["report:state=working", "prompt"]
        );
        assert_eq!(events(&[b"\x1b]133;A;k=v\x1b\\"]), ["prompt"]);
    }

    #[test]
    fn every_split_gives_the_same_events() {
        let whole = b"x\x1b]7501;state=blocked:kind=question:msg=QWxsb3c=\x1b\\y\x1b]7501;?\x07";
        let want = events(&[whole]);
        assert_eq!(want.len(), 2);
        for i in 0..=whole.len() {
            assert_eq!(events(&[&whole[..i], &whole[i..]]), want, "split at {i}");
        }
        let bytes: Vec<&[u8]> = whole.chunks(1).collect();
        assert_eq!(events(&bytes), want);
    }

    #[test]
    fn esc_can_sub_abandon_a_sequence() {
        assert_eq!(events(&[b"\x1b]7501;state=working\x1b[0m\x1b]7501;?\x07"]), ["probe"]);
        assert_eq!(events(&[b"\x1b]7501;state=working\x18\x1b]7501;?\x07"]), ["probe"]);
        assert_eq!(events(&[b"\x1b]7501;state=working\x1a"]), Vec::<String>::new());
    }

    #[test]
    fn dcs_is_skipped_whole() {
        assert_eq!(
            events(&[b"\x1bPtmux;\x1b\x1b]7501;?\x07\x1b\\\x1b]7501;?\x07"]),
            ["probe"]
        );
    }

    #[test]
    fn other_osc_is_ignored() {
        assert!(events(&[b"\x1b]0;title\x07\x1b]75010;x\x07\x1b]1337;?\x07"]).is_empty());
    }

    #[test]
    fn over_4096_bytes_is_dropped() {
        let ok = format!("\x1b]7501;state=idle:x={}\x07", "a".repeat(4096 - 21));
        assert_eq!(ok.len(), 4096);
        assert_eq!(events(&[ok.as_bytes()]).len(), 1);
        let long = format!("\x1b]7501;state=idle:x={}\x07", "a".repeat(4096 - 20));
        assert!(events(&[long.as_bytes()]).is_empty());
        assert_eq!(events(&[long.as_bytes(), b"\x1b]7501;?\x07"]), ["probe"]);
        // an ST terminator is one byte longer, so 4095 of payload is already too long
        let st = format!("\x1b]7501;state=idle:x={}\x1b\\", "a".repeat(4096 - 21));
        assert!(events(&[st.as_bytes()]).is_empty());
    }

    #[test]
    fn recordings_split_as_recorded_match_whole() {
        for name in ["claude-turns", "claude-children", "claude-error", "codex-turns", "synthetic-split"] {
            let (data, _) = capture(name);
            let split = chunks(name);
            let split: Vec<&[u8]> = split.iter().map(|c| c.as_slice()).collect();
            assert_eq!(events(&split), events(&[&data]), "{name}");
        }
    }

    #[test]
    fn recordings_probe_counts() {
        let probes = |n| events(&[&capture(n).0]).iter().filter(|e| *e == "probe").count();
        assert_eq!((probes("claude-turns"), probes("claude-error"), probes("codex-turns")), (1, 1, 0));
        assert_eq!((probes("claude-children"), probes("synthetic-split")), (1, 2));
    }
}
