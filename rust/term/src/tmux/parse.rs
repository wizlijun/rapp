//! Pure parsers for tmux output.

use super::PaneInfo;

/// `tmux 3.4` -> (3, 4); also `3.2a` and `next-3.5`.
pub fn version(s: &str) -> Option<(u32, u32)> {
    let v = s.trim().strip_prefix("tmux ")?.trim();
    let v = v.strip_prefix("next-").unwrap_or(v);
    let (major, rest) = v.split_once('.')?;
    let minor: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    Some((major.parse().ok()?, minor.parse().ok()?))
}

/// Rows produced by `cmd::list_panes`; rows that do not parse are skipped.
pub fn panes(s: &str) -> Vec<PaneInfo> {
    s.lines().filter_map(pane).collect()
}

fn pane(line: &str) -> Option<PaneInfo> {
    let f: Vec<&str> = line.splitn(14, '\t').collect();
    if f.len() != 14 {
        return None;
    }
    Some(PaneInfo {
        session_id: f[0].to_string(),
        session: f[1].to_string(),
        window_id: f[2].to_string(),
        window_index: f[3].parse().ok()?,
        window: f[4].to_string(),
        pane: f[5].to_string(),
        pane_index: f[6].parse().ok()?,
        command: f[7].to_string(),
        dead: f[8] == "1",
        activity: f[9].parse().ok()?,
        attached: f[10].parse().ok()?,
        cols: f[11].parse().ok()?,
        rows: f[12].parse().ok()?,
        title: f[13].to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_versions() {
        assert_eq!(version("tmux 3.4"), Some((3, 4)));
        assert_eq!(version("tmux 3.2a"), Some((3, 2)));
        assert_eq!(version("tmux next-3.5"), Some((3, 5)));
        assert_eq!(version("screen 4.9"), None);
    }
    #[test]
    fn parses_pane_rows_and_skips_broken_ones() {
        let row = "$3\t我的 \"work\"\t@7\t1\tmain win\t%12\t0\tclaude\t0\t1794592454\t2\t212\t58\ttitle with spaces";
        let v = panes(&format!("{row}\nbroken line\n"));
        assert_eq!(v.len(), 1);
        assert_eq!(
            (v[0].session_id.as_str(), v[0].session.as_str(), v[0].pane.as_str()),
            ("$3", "我的 \"work\"", "%12")
        );
        assert_eq!((v[0].attached, v[0].activity, v[0].cols, v[0].rows, v[0].dead), (2, 1794592454, 212, 58, false));
    }
}
