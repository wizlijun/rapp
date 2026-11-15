//! The command line: `rapp share|unshare|hosts|pipe`.

pub const USAGE: &str = "\
rapp share [端口…] [--allow 设备,设备] [--raw] [--note 备注]
rapp unshare <端口>
rapp hosts
rapp pipe <名字> <端口>";

#[derive(Debug, PartialEq)]
pub enum Cmd {
    /// No ports: show the table.
    Share { ports: Vec<u16>, allow: Vec<String>, raw: bool, note: Option<String> },
    Unshare { port: u16 },
    Hosts,
    Pipe { to: String, port: u16 },
}

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
        other => Err(format!("不认识的命令：{other}")),
    }
}

fn share(args: &[String]) -> Result<Cmd, String> {
    let (mut ports, mut allow, mut raw, mut note) = (Vec::new(), Vec::new(), false, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--allow" => {
                let v = it.next().ok_or("--allow 后面要写设备")?;
                allow.extend(v.split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from));
            }
            "--note" => note = Some(it.next().ok_or("--note 后面要写备注")?.clone()),
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
    Ok(Cmd::Share { ports, allow, raw, note })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Cmd, String> {
        parse(&s.split_whitespace().map(String::from).collect::<Vec<_>>())
    }

    #[test]
    fn commands() {
        assert_eq!(p("share"), Ok(Cmd::Share { ports: vec![], allow: vec![], raw: false, note: None }));
        assert_eq!(p("share 8000 22"), Ok(Cmd::Share { ports: vec![8000, 22], allow: vec![], raw: false, note: None }));
        assert_eq!(
            p("share 8000 --allow mini,abababab --raw --note 模型"),
            Ok(Cmd::Share { ports: vec![8000], allow: vec!["mini".into(), "abababab".into()], raw: true, note: Some("模型".into()) })
        );
        assert_eq!(p("unshare 8000"), Ok(Cmd::Unshare { port: 8000 }));
        assert_eq!(p("hosts"), Ok(Cmd::Hosts));
        assert_eq!(p("pipe 123456789.rapp 22"), Ok(Cmd::Pipe { to: "123456789.rapp".into(), port: 22 }));
    }

    #[test]
    fn bad_input_says_what_is_wrong() {
        assert_eq!(p("share 0").unwrap_err(), "端口要在 1 到 65535 之间：0");
        assert_eq!(p("share 70000").unwrap_err(), "端口要在 1 到 65535 之间：70000");
        assert_eq!(p("share abc").unwrap_err(), "端口要在 1 到 65535 之间：abc");
        assert_eq!(p("share --allow").unwrap_err(), "--allow 后面要写设备");
        assert_eq!(p("unshare").unwrap_err(), "要写端口");
        assert_eq!(p("pipe gpu1").unwrap_err(), "要写名字和端口");
        assert_eq!(p("frobnicate").unwrap_err(), "不认识的命令：frobnicate");
    }
}
