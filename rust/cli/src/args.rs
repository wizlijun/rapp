//! The command line: `rapp share|unshare|hosts|pipe|term|update`.

pub const USAGE: &str = "\
rapp share [端口…] [--allow 设备,设备] [--raw] [--note 备注] [--proto http|https|tcp|ssh]
rapp unshare <端口>
rapp hosts
rapp pipe <名字> <端口>
rapp term restore [名字或序号…]
rapp term restore --list
rapp term restore --forget
（序号是 --list 里的；几个终端同名时，写名字就是全恢复）
rapp update [--yes] [--timeout 秒] [--json]      立即升级到最新版
rapp update check [--timeout 秒] [--json]       只检查（并下载），不装
rapp update status [--json]                     看升级状态
rapp update rollback [--timeout 秒] [--json]    回到上一版";

#[derive(Debug, PartialEq)]
pub enum Cmd {
    /// No ports (and then no options either): show the table.
    Share { ports: Vec<u16>, allow: Vec<String>, raw: bool, note: Option<String>, proto: Option<String> },
    Unshare { port: u16 },
    Hosts,
    Pipe { to: String, port: u16 },
    /// `rapp term restore`: no picks = all; `list` and `forget` stand alone.
    TermRestore { list: bool, forget: bool, picks: Vec<String> },
    Update { what: Upd, yes: bool, timeout: Option<u64>, json: bool },
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Upd {
    Install,
    Check,
    Status,
    Rollback,
}

/// The one line for a `--proto` that is missing or not a protocol the service knows: the
/// service would otherwise answer with an error in English, or guess.
const PROTO_ERROR: &str = "--proto 只能是 http、https、tcp、ssh";

fn port(s: &str) -> Result<u16, String> {
    s.parse::<u16>().ok().filter(|&p| p != 0).ok_or_else(|| format!("端口要在 1 到 65535 之间：{s}"))
}

/// Err carries the line to print (in Chinese) before the usage.
pub fn parse(args: &[String]) -> Result<Cmd, String> {
    let Some((name, rest)) = args.split_first() else { return Err("要写命令".into()) };
    match name.as_str() {
        "share" => share(rest),
        "unshare" => match rest {
            [] => Err("要写端口".into()),
            [p] => Ok(Cmd::Unshare { port: port(p)? }),
            [_, extra, ..] => Err(format!("多写了：{extra}")),
        },
        "hosts" => match rest {
            [] => Ok(Cmd::Hosts),
            [extra, ..] => Err(format!("多写了：{extra}")),
        },
        "pipe" => match rest {
            [] | [_] => Err("要写名字和端口".into()),
            [to, p] => Ok(Cmd::Pipe { to: to.clone(), port: port(p)? }),
            [_, _, extra, ..] => Err(format!("多写了：{extra}")),
        },
        "term" => match rest.split_first() {
            None => Err("要写 restore".into()),
            Some((c, rest)) if c == "restore" => term_restore(rest),
            Some((c, _)) => Err(format!("不认识的命令：term {c}")),
        },
        "update" => update(rest),
        other => Err(format!("不认识的命令：{other}")),
    }
}

fn term_restore(args: &[String]) -> Result<Cmd, String> {
    let (mut list, mut forget, mut picks) = (false, false, Vec::new());
    for a in args {
        match a.as_str() {
            "--list" => list = true,
            "--forget" => forget = true,
            flag if flag.starts_with("--") => return Err(format!("不认识的选项：{flag}")),
            p => picks.push(p.to_string()),
        }
    }
    if list && forget {
        return Err("--list 和 --forget 不能一起写".into());
    }
    // `--list` and `--forget` take no picks (forget clears all): the extra word is said, not dropped.
    if (list || forget) && !picks.is_empty() {
        return Err(format!("多写了：{}", picks[0]));
    }
    Ok(Cmd::TermRestore { list, forget, picks })
}

const TIMEOUT_ERROR: &str = "--timeout 后面要写秒数";

fn update(args: &[String]) -> Result<Cmd, String> {
    let (mut what, mut yes, mut timeout, mut json) = (None, false, None, false);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--yes" => yes = true,
            "--json" => json = true,
            "--timeout" => {
                let n = it.next().and_then(|v| v.parse::<u64>().ok()).filter(|&n| n >= 1).ok_or(TIMEOUT_ERROR)?;
                timeout = Some(n);
            }
            flag if flag.starts_with("--") => return Err(format!("不认识的选项：{flag}")),
            word if what.is_none() => {
                what = Some(match word {
                    "check" => Upd::Check,
                    "status" => Upd::Status,
                    "rollback" => Upd::Rollback,
                    _ => return Err(format!("不认识的命令：update {word}")),
                })
            }
            extra => return Err(format!("多写了：{extra}")),
        }
    }
    let what = what.unwrap_or(Upd::Install);
    if yes && what != Upd::Install {
        return Err("只有 rapp update 能用 --yes".into());
    }
    if timeout.is_some() && what == Upd::Status {
        return Err("rapp update status 不用 --timeout".into());
    }
    Ok(Cmd::Update { what, yes, timeout, json })
}

fn share(args: &[String]) -> Result<Cmd, String> {
    let (mut ports, mut allow, mut raw, mut note, mut proto) = (Vec::new(), Vec::new(), false, None, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--allow" => {
                let v = it.next().ok_or("--allow 后面要写设备")?;
                let names: Vec<String> = v.split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect();
                // An empty list would be dropped and widen the share to every device.
                if names.is_empty() {
                    return Err("--allow 后面要写设备".into());
                }
                allow.extend(names);
            }
            "--note" => note = Some(it.next().ok_or("--note 后面要写备注")?.clone()),
            "--proto" => {
                let v = it.next().ok_or(PROTO_ERROR)?;
                if !["http", "https", "tcp", "ssh"].contains(&v.as_str()) {
                    return Err(PROTO_ERROR.into());
                }
                proto = Some(v.clone());
            }
            "--raw" => raw = true,
            flag if flag.starts_with("--") => return Err(format!("不认识的选项：{flag}")),
            p => {
                let p = port(p)?;
                if !ports.contains(&p) {
                    ports.push(p);
                }
            }
        }
    }
    // An option says how to share a port; with none it would be dropped and the table shown.
    if ports.is_empty() && (!allow.is_empty() || raw || note.is_some() || proto.is_some()) {
        return Err("要写端口".into());
    }
    Ok(Cmd::Share { ports, allow, raw, note, proto })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Cmd, String> {
        parse(&s.split_whitespace().map(String::from).collect::<Vec<_>>())
    }

    #[test]
    fn commands() {
        assert_eq!(p("share"), Ok(Cmd::Share { ports: vec![], allow: vec![], raw: false, note: None, proto: None }));
        assert_eq!(p("share 8000 22"), Ok(Cmd::Share { ports: vec![8000, 22], allow: vec![], raw: false, note: None, proto: None }));
        assert_eq!(
            p("share 8000 --allow mini,abababab --raw --note 模型"),
            Ok(Cmd::Share { ports: vec![8000], allow: vec!["mini".into(), "abababab".into()], raw: true, note: Some("模型".into()), proto: None })
        );
        assert_eq!(
            p("share 8007 --proto tcp"),
            Ok(Cmd::Share { ports: vec![8007], allow: vec![], raw: false, note: None, proto: Some("tcp".into()) })
        );
        assert_eq!(p("unshare 8000"), Ok(Cmd::Unshare { port: 8000 }));
        assert_eq!(p("hosts"), Ok(Cmd::Hosts));
        assert_eq!(p("pipe 123456789.rapp 22"), Ok(Cmd::Pipe { to: "123456789.rapp".into(), port: 22 }));
    }

    #[test]
    fn term_restore_forms() {
        let r = |list, forget, picks: &[&str]| Ok(Cmd::TermRestore { list, forget, picks: picks.iter().map(|s| s.to_string()).collect() });
        assert_eq!(p("term restore"), r(false, false, &[]));
        assert_eq!(p("term restore --list"), r(true, false, &[]));
        assert_eq!(p("term restore --forget"), r(false, true, &[]));
        assert_eq!(p("term restore train 2"), r(false, false, &["train", "2"]));
        assert_eq!(p("term restore --list x").unwrap_err(), "多写了：x");
        assert_eq!(p("term restore --forget x").unwrap_err(), "多写了：x");
        assert_eq!(p("term").unwrap_err(), "要写 restore");
        assert!(p("term restore --list --forget").is_err());
        assert_eq!(p("term restore --bogus").unwrap_err(), "不认识的选项：--bogus");
        assert_eq!(p("term frob").unwrap_err(), "不认识的命令：term frob");
    }

    #[test]
    fn bad_input_says_what_is_wrong() {
        assert_eq!(p("share 0").unwrap_err(), "端口要在 1 到 65535 之间：0");
        assert_eq!(p("share 70000").unwrap_err(), "端口要在 1 到 65535 之间：70000");
        assert_eq!(p("share abc").unwrap_err(), "端口要在 1 到 65535 之间：abc");
        assert_eq!(p("share --allow").unwrap_err(), "--allow 后面要写设备");
        assert_eq!(p("share 8000 --allow ,").unwrap_err(), "--allow 后面要写设备");
        assert_eq!(p("share 8000 --allow  , ").unwrap_err(), "--allow 后面要写设备");
        // Arguments that `split_whitespace` cannot make: an empty one, and one of blanks and commas.
        for bad in ["", " , "] {
            let args: Vec<String> = ["share", "8000", "--allow", bad].map(String::from).to_vec();
            assert_eq!(parse(&args).unwrap_err(), "--allow 后面要写设备", "{bad:?}");
        }
        assert_eq!(p("share 8007 --proto ftp").unwrap_err(), "--proto 只能是 http、https、tcp、ssh");
        assert_eq!(p("share 8007 --proto").unwrap_err(), "--proto 只能是 http、https、tcp、ssh");
        assert_eq!(p("share --proto tcp").unwrap_err(), "要写端口");
        assert_eq!(p("unshare").unwrap_err(), "要写端口");
        // An option says how to share a port: without a port it would be dropped and the table shown.
        for bad in ["share --allow mini", "share --raw", "share --note x", "share --allow mini,abababab --raw --note x"] {
            assert_eq!(p(bad).unwrap_err(), "要写端口", "{bad}");
        }
        assert_eq!(p("pipe gpu1").unwrap_err(), "要写名字和端口");
        assert_eq!(p("frobnicate").unwrap_err(), "不认识的命令：frobnicate");
    }

    #[test]
    fn update_commands() {
        let u = |what, yes, timeout, json| Ok(Cmd::Update { what, yes, timeout, json });
        assert_eq!(p("update"), u(Upd::Install, false, None, false));
        assert_eq!(p("update --yes --timeout 30 --json"), u(Upd::Install, true, Some(30), true));
        assert_eq!(p("update check --json"), u(Upd::Check, false, None, true));
        assert_eq!(p("update --json check"), u(Upd::Check, false, None, true));
        assert_eq!(p("update status"), u(Upd::Status, false, None, false));
        assert_eq!(p("update rollback --timeout 5"), u(Upd::Rollback, false, Some(5), false));
        assert_eq!(p("update status --timeout 3").unwrap_err(), "rapp update status 不用 --timeout");
        assert_eq!(p("update check --yes").unwrap_err(), "只有 rapp update 能用 --yes");
        assert_eq!(p("update rollback --yes").unwrap_err(), "只有 rapp update 能用 --yes");
        for bad in ["update --timeout 0", "update --timeout x", "update --timeout", "update --timeout -3"] {
            assert_eq!(p(bad).unwrap_err(), "--timeout 后面要写秒数", "{bad}");
        }
        assert_eq!(p("update now").unwrap_err(), "不认识的命令：update now");
        assert_eq!(p("update check status").unwrap_err(), "多写了：status");
        assert_eq!(p("update --force").unwrap_err(), "不认识的选项：--force");
    }
}
