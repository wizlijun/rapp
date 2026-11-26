//! OSC 7502 shell reports: what the hook scripts say about the shell (directory, virtual environments, the command
//! being run), and the state the holder keeps from them.

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;

/// One decoded OSC 7502 report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Report {
    State { cwd: Option<String>, venv: Option<String>, conda: Option<String>, conda_name: Option<String> },
    Run(String),
}

fn b64(s: &[u8]) -> Option<String> {
    String::from_utf8(STANDARD.decode(s).ok()?).ok()
}

/// Parses what follows `7502;` up to the terminator: `state;cwd=<b64>;venv=<b64>;...` or `run;<b64>`.
pub fn parse_report(body: &[u8]) -> Option<Report> {
    let (kind, rest) = match body.iter().position(|&c| c == b';') {
        Some(i) => (&body[..i], &body[i + 1..]),
        None => (body, &body[body.len()..]),
    };
    match kind {
        b"run" => b64(rest).map(Report::Run),
        b"state" => {
            let (mut cwd, mut venv, mut conda, mut conda_name) = (None, None, None, None);
            for field in rest.split(|&c| c == b';').filter(|f| !f.is_empty()) {
                let i = field.iter().position(|&c| c == b'=')?;
                let (k, v) = (&field[..i], &field[i + 1..]);
                let value = if v.is_empty() { None } else { Some(b64(v)?) };
                match k {
                    b"cwd" => cwd = value,
                    b"venv" => venv = value,
                    b"conda" => conda = value,
                    b"conda_name" => conda_name = value,
                    _ => {}
                }
            }
            Some(Report::State { cwd, venv, conda, conda_name })
        }
        _ => None,
    }
}

/// What the holder knows about the shell it runs.
#[derive(Default, Clone, PartialEq, Debug)]
pub struct ShellState {
    /// True after the first 7502 report: the hook is in place.
    pub hooked: bool,
    pub cwd: Option<String>,
    pub venv: Option<String>,
    pub conda: Option<String>,
    pub conda_name: Option<String>,
    /// The raw command line between `run` and the next prompt.
    pub running: Option<String>,
    /// The restored command still waiting for the user.
    pub pending: Option<String>,
}

impl ShellState {
    pub fn apply(&mut self, r: Report) {
        self.hooked = true;
        match r {
            Report::Run(c) => {
                self.running = Some(c);
                self.pending = None;
            }
            Report::State { cwd, venv, conda, conda_name } => {
                self.cwd = cwd;
                self.venv = venv;
                self.conda = conda;
                self.conda_name = conda_name;
            }
        }
    }

    /// A prompt was drawn: whatever ran is done. Only meaningful once the hook reports.
    pub fn prompt(&mut self) {
        if self.hooked {
            self.running = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_report_parses_fields() {
        assert_eq!(
            parse_report(b"state;cwd=L1VzZXJzL2I=;venv="),
            Some(Report::State { cwd: Some("/Users/b".into()), venv: None, conda: None, conda_name: None })
        );
    }

    #[test]
    fn run_report_parses() {
        assert_eq!(parse_report(b"run;Y2xhdWRlIC1j"), Some(Report::Run("claude -c".into())));
    }

    #[test]
    fn bad_base64_and_unknown_kind_are_none() {
        assert_eq!(parse_report(b"run;!!!"), None);
        assert_eq!(parse_report(b"weird;x"), None);
        assert_eq!(parse_report(b"state;cwd=/plain"), None);
    }

    #[test]
    fn prompt_clears_running_only_when_hooked() {
        let mut s = ShellState { running: Some("x".into()), ..Default::default() };
        s.prompt();
        assert_eq!(s.running.as_deref(), Some("x"));
        s.apply(Report::State { cwd: None, venv: None, conda: None, conda_name: None });
        assert!(s.hooked);
        s.prompt();
        assert_eq!(s.running, None);
    }

    #[test]
    fn run_clears_pending() {
        let mut s = ShellState { pending: Some("claude -c".into()), ..Default::default() };
        s.apply(Report::Run("ls".into()));
        assert_eq!((s.pending, s.running.as_deref()), (None, Some("ls")));
    }
}
