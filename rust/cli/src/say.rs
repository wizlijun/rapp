//! What gets printed, as pure functions of the service's reply.

use serde_json::Value;

/// `s` without control characters: what another device sent (a name, an error text) is printed
/// through this, so it cannot move the cursor, colour the terminal or start a new line.
pub fn plain(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).collect()
}

/// Terminal columns of `s`: ASCII is one, everything else (Chinese) two.
fn width(s: &str) -> usize {
    s.chars().map(|c| if c.is_ascii() || c == '—' { 1 } else { 2 }).sum()
}

/// Pads every cell but the last of each row to its column's widest cell plus two spaces. A
/// row's last cell is not padded, so it does not widen its column either.
pub(crate) fn columns(rows: &[Vec<String>]) -> String {
    let n = rows.iter().map(Vec::len).max().unwrap_or(0);
    let padded = |r: &Vec<String>, i: usize| (i + 1 < r.len()).then(|| width(&r[i]));
    let widths: Vec<usize> = (0..n).map(|i| rows.iter().filter_map(|r| padded(r, i)).max().unwrap_or(0)).collect();
    let mut out = String::new();
    for row in rows {
        let last = row.len() - 1;
        let line: Vec<String> = row
            .iter()
            .enumerate()
            .map(|(i, c)| if i == last { c.clone() } else { format!("{c}{}", " ".repeat(widths[i] + 2 - width(c))) })
            .collect();
        out.push_str(line.concat().trim_end());
        out.push('\n');
    }
    out
}

/// The device names in a JSON array, each made `plain`: strings, or objects with a `name`.
fn names(list: &Value) -> Vec<String> {
    let name = |v: &Value| v.as_str().or_else(|| v["name"].as_str()).map(plain);
    list.as_array().map(|a| a.iter().filter_map(name).collect()).unwrap_or_default()
}

/// `s` as an address cell: the service gives an empty `addr` when no number in the range is
/// free, and then there is nothing to type, which the user is told in words.
fn address(s: &Value) -> Option<String> {
    s["addr"].as_str().filter(|a| !a.is_empty()).map(plain)
}

/// One `已分享：<port> → <address>` per port, with what the protocol is when it was detected;
/// right under it who the share is for when it is not for every device, then a warning. At the
/// end, that the other devices use the same address (the number is the same everywhere).
pub fn shared(reply: &Value) -> String {
    let mut out = String::new();
    let empty = Vec::new();
    let list = reply["shared"].as_array().unwrap_or(&empty);
    for s in list {
        match address(s) {
            Some(addr) if s["proto_auto"] == true => {
                out.push_str(&format!("已分享：{} → {addr}（探测到 {}）\n", s["port"], plain(s["proto"].as_str().unwrap_or(""))))
            }
            Some(addr) => out.push_str(&format!("已分享：{} → {addr}\n", s["port"])),
            None => out.push_str(&format!("已分享：{}（没有空的号）\n", s["port"])),
        }
        let allow = names(&s["allow"]);
        if !allow.is_empty() {
            out.push_str(&format!("只给：{}\n", allow.join("、")));
        }
        if let Some(w) = s["warn"].as_str() {
            out.push_str(w);
            out.push('\n');
        }
    }
    if list.iter().any(|s| address(s).is_some()) {
        out.push_str("在别的设备上也用这个地址\n");
    }
    out
}

/// The line for an error the service's `share` command can answer.
pub fn share_error(error: &str) -> String {
    let error = plain(error);
    match error.as_str() {
        "bad port" => "端口不对".into(),
        "limit" => "最多分享 64 个端口".into(),
        "bad allow" => "--allow 写得不对".into(),
        _ => {
            if let Some(x) = error.strip_prefix("unknown device: ") {
                format!("不认识设备：{x}")
            } else if let Some(x) = error.strip_prefix("ambiguous device: ") {
                format!("有不止一台设备叫 {x}，请写指纹的前 8 位")
            } else {
                format!("没有成功：{error}")
            }
        }
    }
}

fn relay_text(relay: &str) -> &'static str {
    match relay {
        "connected" => "已连接",
        "connecting" => "连接中",
        "error" => "出错",
        _ => "没有配置",
    }
}

/// How long ago, in words: 刚才 under a minute, then minutes, hours, days.
fn age(saved: u64, now: u64) -> String {
    let d = now.saturating_sub(saved);
    match d {
        0..=59 => "刚才".into(),
        60..=3599 => format!("{} 分钟前", d / 60),
        3600..=86399 => format!("{} 小时前", d / 3600),
        _ => format!("{} 天前", d / 86400),
    }
}

/// `rapp term restore --list`: what can be restored, in the order the picks number it.
pub fn saved_table(r: &Value, now: u64) -> String {
    let Some(list) = r["saved"].as_array().filter(|l| !l.is_empty()) else { return "没有可以恢复的终端\n".into() };
    let mut rows = vec![["序号", "名字", "程序", "多久以前", "目录"].map(String::from).to_vec()];
    for (i, s) in list.iter().enumerate() {
        rows.push(vec![
            (i + 1).to_string(),
            plain(s["name"].as_str().unwrap_or("")),
            s["prog"].as_str().map(plain).filter(|p| !p.is_empty()).unwrap_or_else(|| "—".into()),
            age(s["saved"].as_u64().unwrap_or(0), now),
            s["cwd"].as_str().map(plain).filter(|p| !p.is_empty()).unwrap_or_else(|| "—".into()),
        ]);
    }
    columns(&rows)
}

/// The keys the picks stand for, in `saved` order's terms: a number is a 1-based place in the list, anything
/// else an exact name (every terminal with that name). No picks = all. Err is the line to print.
pub fn pick_keys(r: &Value, picks: &[String]) -> Result<Vec<String>, String> {
    let list = r["saved"].as_array().cloned().unwrap_or_default();
    let key = |s: &Value| s["key"].as_str().unwrap_or("").to_string();
    if picks.is_empty() {
        return Ok(list.iter().map(key).collect());
    }
    let mut keys: Vec<String> = Vec::new();
    for p in picks {
        let hit: Vec<String> = if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) {
            p.parse::<usize>().ok().and_then(|n| n.checked_sub(1)).and_then(|i| list.get(i)).map(key).into_iter().collect()
        } else {
            list.iter().filter(|s| s["name"].as_str() == Some(p)).map(key).collect()
        };
        if hit.is_empty() {
            return Err(format!("没有这个终端：{p}"));
        }
        for k in hit {
            if !keys.contains(&k) {
                keys.push(k);
            }
        }
    }
    Ok(keys)
}

/// What `restore` ended with: the line, and whether it is a failure.
pub fn restored(r: &Value) -> (String, bool) {
    let n = r["ids"].as_array().map_or(0, Vec::len);
    match r["error"].as_str() {
        Some(e) => (format!("恢复到第 {} 个时停下了：{}", n + 1, plain(e)), true),
        None => (format!("已恢复 {n} 个终端"), false),
    }
}

/// `rapp share` with no ports: this device's shares.
pub fn table(reply: &Value) -> String {
    let id = reply["id"].as_str().map(plain).unwrap_or_else(|| "（还没有 ID）".into());
    let out = format!("这台设备：{id}   中继：{}\n", relay_text(reply["relay"].as_str().unwrap_or("")));
    let shares = reply["shares"].as_array().filter(|s| !s.is_empty());
    let Some(shares) = shares else { return out + "（没有分享）\n" };
    let mut rows = vec![["端口", "地址", "状态", "只给"].map(String::from).to_vec()];
    // What goes on the line under a row: a share whose number is not the one it should be says so.
    let mut notes: Vec<Option<String>> = vec![None];
    for s in shares {
        rows.push(vec![
            s["port"].to_string(),
            address(s).unwrap_or_else(|| "没有空的号".into()),
            if s["listening"] == true { "有服务在听" } else { "没有服务在听" }.into(),
            names(&s["allow"]).join(","),
        ]);
        // Both notices name the share's number: one with none (the range had none left) has neither.
        let local = s["local"].as_u64();
        notes.push(match (local, s.get("renumbered").filter(|r| r.is_object())) {
            (Some(local), _) if s["taken"] == true => {
                Some(format!("本机上 {local} 被别的程序占着，本机请用 localhost:{}", s["port"]))
            }
            (Some(local), Some(r)) => Some(format!("{} 和 {} 撞了，换成 {local}", r["from"], plain(r["with"].as_str().unwrap_or("")))),
            _ => None,
        });
    }
    let mut text = String::new();
    for (line, note) in columns(&rows).lines().zip(notes) {
        text.push_str(line);
        text.push('\n');
        if let Some(n) = note {
            text.push_str(&n);
            text.push('\n');
        }
    }
    out + &text
}

/// `rapp hosts`: each known device with its ports and where each is reached on this computer
/// (one line per port), or what is wrong with it.
pub fn hosts(reply: &Value) -> String {
    let empty = Vec::new();
    let list = reply["hosts"].as_array().unwrap_or(&empty);
    if list.is_empty() {
        return "（没有主机）\n".into();
    }
    let mut rows: Vec<Vec<String>> = Vec::new();
    for h in list {
        let mut who = vec![plain(h["name"].as_str().unwrap_or("")), plain(h["id"].as_str().unwrap_or(""))];
        let what = match (h["error"].as_str(), h["shares"].as_array()) {
            (Some("offline"), _) => "不在线".to_string(),
            (Some("no key"), _) => "这台设备还没有填 key".to_string(),
            (Some(e), _) => format!("接不上：{}", plain(e)),
            (None, Some(shares)) if !shares.is_empty() => {
                for s in shares {
                    let addr = s["addr"].as_str().map(plain).unwrap_or_else(|| "（没有本机端口可用）".into());
                    // The device is named on its first line only.
                    let mut row = std::mem::replace(&mut who, vec![String::new(), String::new()]);
                    row.extend([s["port"].to_string(), addr]);
                    // This device yielded: its address is not the share number.
                    if let Some(w) = s["wanted"].as_u64() {
                        row.push(format!("这台上是 {}（{w} 被占）", s["local"]));
                    }
                    rows.push(row);
                }
                continue;
            }
            (None, _) => "（没有分享）".to_string(),
        };
        who.push(what);
        rows.push(who);
    }
    columns(&rows)
}

/// Why `pipe` to `to` (the name as written, with or without `.rapp`) failed.
pub fn pipe_error(to: &str, port: u16, error: &str) -> String {
    let to = to.strip_suffix(".rapp").unwrap_or(to);
    match error {
        "not shared" => format!("{to} 没有分享 {port}。在 {to} 上运行 rapp share {port}"),
        "not allowed" => format!("{to} 的 {port} 没有分享给这台设备"),
        "offline" => format!("{to} 不在线"),
        "refused" => format!("{to} 的 {port} 上没有服务在听"),
        "unknown name" => format!("不认识 {to}。现在只能写 9 位的设备 ID"),
        "no key" => "这台设备还没有填 key".into(),
        other => format!("接不上 {to} 的 {port}：{}", plain(other)),
    }
}

fn ago(secs: u64) -> String {
    match secs {
        0..=59 => "刚才".into(),
        60..=3599 => format!("{} 分钟前", secs / 60),
        3600..=86399 => format!("{} 小时前", secs / 3600),
        _ => format!("{} 天前", secs / 86400),
    }
}

/// The reply of the IPC `state` command, one line per thing that is there to say.
pub fn state(r: &Value) -> String {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    state_at(r, now)
}

fn state_at(r: &Value, now: u64) -> String {
    let mut out = String::new();
    // A missing number is said in words, never as `null`.
    let port = r["port"].as_u64().map_or("端口不明".to_string(), |p| format!("端口 {p}"));
    if r["on"] != true {
        out.push_str("中心服务：没开\n");
    } else if r["running"] == true {
        let share = r["share"].as_u64().map_or("没有分享".to_string(), |n| format!("分享号 {n}"));
        out.push_str(&format!("中心服务：开着，{port}，{share}\n"));
    } else {
        out.push_str(&format!("中心服务：开着，{port}，没有起来：{}\n", plain(r["error"].as_str().unwrap_or("原因不明"))));
    }
    let st = &r["stored"];
    if st.is_object() {
        let mut line = format!("  存着 {} 台设备、{} 个会话、{} 条队列", st["devices"], st["sessions"], st["queued"]);
        if let Some(at) = st["last"]["at"].as_u64() {
            let who = st["last"]["device"].as_str().map(plain).filter(|w| !w.is_empty());
            line.push_str(&format!("；最近一次收到{}的，{}", who.map(|w| format!(" {w} ")).unwrap_or_default(), ago(now.saturating_sub(at))));
        }
        out.push_str(&line);
        out.push('\n');
    }
    let sinks: Vec<String> = r["sinks"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|s| {
                    let who = if s["local"] == true { "本机的".to_string() } else { format!("{} 的", plain(s["id"].as_str().unwrap_or(""))) };
                    let mark = if s["chosen"] == true { "（在用）" } else { "" };
                    format!("{who} {}{mark}", s["port"])
                })
                .collect()
        })
        .unwrap_or_default();
    if !sinks.is_empty() {
        out.push_str(&format!("网里的中心服务：{}\n", sinks.join("，")));
    }
    let o = &r["outbox"];
    let cached = &o["cached"];
    if o["dest"].is_null() {
        out.push_str("发件箱：没在发（网里没有中心服务）\n");
    } else if o["active"] == true && o["up"] == true {
        out.push_str(&format!("发件箱：在发，缓存 {cached} 条，已发 {} 条\n", o["sent"]));
    } else if o["active"] == true {
        out.push_str(&format!("发件箱：连不上，缓存 {cached} 条\n"));
    } else {
        // A service is known but the pump is not running yet.
        out.push_str(&format!("发件箱：还没开始发，缓存 {cached} 条\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn saved_table_shows_dirs_and_dashes() {
        let r = json!({"ok":true,"saved":[
            {"key":"a","name":"train","prog":"claude","saved":1000,"cwd":"/Users/b/proj"},
            {"key":"b","name":"zsh","saved":1000}]});
        assert_eq!(
            saved_table(&r, 1000 + 300),
            "序号  名字   程序    多久以前  目录\n1     train  claude  5 分钟前  /Users/b/proj\n2     zsh    —       5 分钟前  —\n"
        );
    }

    #[test]
    fn saved_table_empty() {
        assert_eq!(saved_table(&json!({"ok":true,"saved":[]}), 5), "没有可以恢复的终端\n");
    }

    #[test]
    fn ages_in_chinese() {
        assert_eq!(age(0, 59), "刚才");
        assert_eq!(age(0, 300), "5 分钟前");
        assert_eq!(age(0, 7200), "2 小时前");
        assert_eq!(age(0, 3 * 86400), "3 天前");
        assert_eq!(age(100, 50), "刚才");
    }

    #[test]
    fn picks_resolve_by_number_or_name() {
        let r = json!({"saved":[{"key":"a","name":"train"},{"key":"b","name":"x"},{"key":"c","name":"x"}]});
        let p = |v: &[&str]| pick_keys(&r, &v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(p(&[]), Ok(vec!["a".into(), "b".into(), "c".into()]));
        assert_eq!(p(&["train", "2"]), Ok(vec!["a".into(), "b".into()]));
        assert_eq!(p(&["x", "3"]), Ok(vec!["b".into(), "c".into()]));
        assert_eq!(p(&["4"]), Err("没有这个终端：4".into()));
        assert_eq!(p(&["0"]), Err("没有这个终端：0".into()));
        assert_eq!(p(&["nope"]), Err("没有这个终端：nope".into()));
    }

    #[test]
    fn restore_outcomes() {
        assert_eq!(restored(&json!({"ok":true,"ids":["1","2"]})), ("已恢复 2 个终端".into(), false));
        assert_eq!(restored(&json!({"error":"busy","ids":["1"]})), ("恢复到第 2 个时停下了：busy".into(), true));
    }

    #[test]
    fn shared_prints_the_address_with_the_protocol_and_the_warning() {
        let r = json!({"ok":true,"shared":[
            {"port":8007,"local":28000,"proto":"http","proto_auto":true,"addr":"http://localhost:28000"},
            {"port":22,"local":28001,"proto":"ssh","proto_auto":true,"addr":"ssh -p 28001 localhost",
             "warn":"分享这个端口，等于把这台机器能到的网络也交出去"}]});
        assert_eq!(
            shared(&r),
            "已分享：8007 → http://localhost:28000（探测到 http）\n\
             已分享：22 → ssh -p 28001 localhost（探测到 ssh）\n\
             分享这个端口，等于把这台机器能到的网络也交出去\n\
             在别的设备上也用这个地址\n"
        );
        assert_eq!(shared(&json!({"ok":true,"shared":[]})), "");
        let chosen = json!({"ok":true,"shared":[
            {"port":8007,"local":28000,"proto":"tcp","proto_auto":false,"addr":"tcp://localhost:28000"}]});
        assert_eq!(shared(&chosen), "已分享：8007 → tcp://localhost:28000\n在别的设备上也用这个地址\n");
        let none = json!({"ok":true,"shared":[{"port":8007,"proto":"http","proto_auto":true,"addr":""}]});
        assert_eq!(shared(&none), "已分享：8007（没有空的号）\n");
        assert!(!shared(&r).contains(".rapp"));
    }

    #[test]
    fn shared_says_who_a_restricted_share_is_for() {
        let r = json!({"ok":true,"shared":[
            {"port":8000,"addr":"http://localhost:28000","proto_auto":true,"proto":"http","allow":["mini","abababab"]},
            {"port":22,"addr":"ssh -p 28001 localhost","proto_auto":false,"proto":"ssh","allow":["mini"],"warn":"分享这个端口，等于把这台机器能到的网络也交出去"},
            {"port":8001,"addr":"http://localhost:28002","proto_auto":false,"proto":"http"},
            {"port":8002,"addr":"","allow":[]}]});
        assert_eq!(
            shared(&r),
            "已分享：8000 → http://localhost:28000（探测到 http）\n只给：mini、abababab\n\
             已分享：22 → ssh -p 28001 localhost\n只给：mini\n分享这个端口，等于把这台机器能到的网络也交出去\n\
             已分享：8001 → http://localhost:28002\n已分享：8002（没有空的号）\n在别的设备上也用这个地址\n"
        );
    }

    // A name another device chose, or an error text it sent, must not drive the terminal.
    #[test]
    fn what_another_device_sent_is_printed_without_control_characters() {
        let evil = "mi\u{1b}[31mni\nroot\r\u{7}";
        let clean = "mi[31mniroot";
        assert_eq!(plain(evil), clean);
        assert_eq!(plain("书房 mini-2"), "书房 mini-2");

        let r = json!({"ok":true,"shared":[{"port":8000,"addr":"http://localhost:28000","proto_auto":false,"allow":[evil,"b"]}]});
        assert_eq!(shared(&r), format!("已分享：8000 → http://localhost:28000\n只给：{clean}、b\n在别的设备上也用这个地址\n"));

        let r = json!({"ok":true,"id":"123456789","relay":"connected","shares":[
            {"port":22,"allow":[{"fp":"ab","name":evil}],"addr":"ssh -p 28000 localhost","listening":true}]});
        let t = table(&r);
        assert!(t.lines().nth(2).unwrap().contains(clean), "{t:?}");
        assert_eq!((t.lines().count(), t.chars().filter(|c| c.is_control()).count()), (3, 3), "{t:?}");

        let r = json!({"ok":true,"hosts":[
            {"id":"123456789","name":evil,"shares":[{"port":8000,"local":28000,"addr":"http://localhost:28000"}]},
            {"id":"987654321","name":"b","error":evil}]});
        let t = hosts(&r);
        assert!(t.lines().next().unwrap().starts_with(clean), "{t:?}");
        assert!(t.lines().nth(1).unwrap().ends_with(&format!("接不上：{clean}")), "{t:?}");
        assert_eq!((t.lines().count(), t.chars().filter(|c| c.is_control()).count()), (2, 2), "{t:?}");

        assert_eq!(pipe_error("123456789", 22, evil), format!("接不上 123456789 的 22：{clean}"));
        assert_eq!(share_error(evil), format!("没有成功：{clean}"));
        assert_eq!(share_error(&format!("unknown device: {evil}")), format!("不认识设备：{clean}"));
    }

    #[test]
    fn share_errors_are_one_line_each() {
        assert_eq!(share_error("bad port"), "端口不对");
        assert_eq!(share_error("limit"), "最多分享 64 个端口");
        assert_eq!(share_error("unknown device: mini"), "不认识设备：mini");
        assert_eq!(share_error("ambiguous device: ab"), "有不止一台设备叫 ab，请写指纹的前 8 位");
        assert_eq!(share_error("bad allow"), "--allow 写得不对");
        assert_eq!(share_error("disk full"), "没有成功：disk full");
    }

    #[test]
    fn pipe_errors_say_the_next_step() {
        assert_eq!(pipe_error("123456789.rapp", 8000, "not shared"), "123456789 没有分享 8000。在 123456789 上运行 rapp share 8000");
        assert_eq!(pipe_error("123456789", 8000, "not allowed"), "123456789 的 8000 没有分享给这台设备");
        assert_eq!(pipe_error("123456789", 8000, "offline"), "123456789 不在线");
        assert_eq!(pipe_error("123456789", 8000, "refused"), "123456789 的 8000 上没有服务在听");
        assert_eq!(pipe_error("gpu1", 22, "unknown name"), "不认识 gpu1。现在只能写 9 位的设备 ID");
        assert_eq!(pipe_error("123456789", 22, "no key"), "这台设备还没有填 key");
        assert_eq!(pipe_error("123456789", 22, "boom"), "接不上 123456789 的 22：boom");
    }

    #[test]
    fn table_with_and_without_shares() {
        let none = json!({"ok":true,"id":"123456789","relay":"connected","shares":[]});
        assert_eq!(table(&none), "这台设备：123456789   中继：已连接\n（没有分享）\n");
        let some = json!({"ok":true,"id":"123456789","relay":"connected","shares":[
            {"port":22,"allow":[{"fp":"ab","name":"mini"}],"addr":"ssh -p 28001 localhost","listening":true},
            {"port":8000,"addr":"http://localhost:28000","listening":false},
            {"port":9000,"addr":"","listening":false}]});
        assert_eq!(
            table(&some),
            "这台设备：123456789   中继：已连接\n\
             端口  地址                    状态          只给\n\
             22    ssh -p 28001 localhost  有服务在听    mini\n\
             8000  http://localhost:28000  没有服务在听\n\
             9000  没有空的号              没有服务在听\n"
        );
    }

    #[test]
    fn table_says_when_a_number_is_taken_or_was_changed() {
        let r = json!({"ok":true,"id":"123456789","relay":"connected","shares":[
            {"port":8007,"addr":"http://localhost:28000","listening":true,"local":28000,"taken":true},
            {"port":8008,"addr":"http://localhost:28003","listening":true,"local":28003,"renumbered":{"from":28000,"with":"Mini"}},
            {"port":8009,"addr":"http://localhost:28004","listening":true}]});
        assert_eq!(
            table(&r),
            "这台设备：123456789   中继：已连接\n\
             端口  地址                    状态        只给\n\
             8007  http://localhost:28000  有服务在听\n\
             本机上 28000 被别的程序占着，本机请用 localhost:8007\n\
             8008  http://localhost:28003  有服务在听\n\
             28000 和 Mini 撞了，换成 28003\n\
             8009  http://localhost:28004  有服务在听\n"
        );
    }

    /// A share with no number here (the range had none) has no notice: not "0", not "null".
    #[test]
    fn a_notice_needs_a_number() {
        let r = json!({"ok":true,"id":"123456789","relay":"connected","shares":[
            {"port":8007,"listening":true,"taken":true},
            {"port":8008,"listening":true,"renumbered":{"from":28000,"with":"Mini"}}]});
        assert_eq!(
            table(&r),
            "这台设备：123456789   中继：已连接\n\
             端口  地址        状态        只给\n\
             8007  没有空的号  有服务在听\n\
             8008  没有空的号  有服务在听\n"
        );
    }

    #[test]
    fn relay_states_have_a_text_each() {
        for (relay, want) in [("connecting", "连接中"), ("error", "出错"), ("off", "没有配置")] {
            let r = json!({"id":"123456789","relay":relay,"shares":[]});
            assert!(table(&r).starts_with(&format!("这台设备：123456789   中继：{want}\n")), "{relay}");
        }
    }

    #[test]
    fn hosts_lists_devices_and_what_is_wrong() {
        let r = json!({"ok":true,"hosts":[
            {"id":"123456789","name":"gpu1","shares":[
                {"port":8000,"local":28000,"addr":"http://localhost:28000"},
                {"port":22,"local":28001,"addr":"ssh -p 28001 localhost"},
                {"port":9000},
                {"port":8001,"local":28003,"addr":"http://localhost:28003","wanted":28002}]},
            {"id":"987654321","name":"mini","error":"offline"},
            {"id":"111111111","name":"书房","shares":[]}]});
        assert_eq!(
            hosts(&r),
            "gpu1  123456789  8000  http://localhost:28000\n\
             \x20                22    ssh -p 28001 localhost\n\
             \x20                9000  （没有本机端口可用）\n\
             \x20                8001  http://localhost:28003  这台上是 28003（28002 被占）\n\
             mini  987654321  不在线\n\
             书房  111111111  （没有分享）\n"
        );
    }

    #[test]
    fn state_says_what_runs() {
        let now = 1_000_000;
        let base = json!({"ok": true, "on": true, "port": 8102, "share": 28003, "running": true, "error": null,
            "stored": {"devices": 3, "sessions": 5, "queued": 120, "last": {"device": "mac", "at": now - 150}},
            "sinks": [{"id": "123456789", "port": 8102, "local": false, "chosen": true}, {"id": "me", "port": 8102, "local": true, "chosen": false}],
            "outbox": {"active": true, "cached": 0, "sent": 42, "dropped": 0, "refused": 0, "last_ok": 1, "up": true, "dest": {"id": "123456789", "port": 8102}}});
        assert_eq!(
            state_at(&base, now),
            "中心服务：开着，端口 8102，分享号 28003\n  存着 3 台设备、5 个会话、120 条队列；最近一次收到 mac 的，2 分钟前\n网里的中心服务：123456789 的 8102（在用），本机的 8102\n发件箱：在发，缓存 0 条，已发 42 条\n"
        );
        let down = json!({"on": true, "port": 8102, "share": null, "running": false, "error": "端口 8102 被占用", "stored": null, "sinks": [],
            "outbox": {"active": true, "cached": 17, "sent": 0, "up": false, "dest": {"local": 8102}}});
        assert_eq!(state_at(&down, now), "中心服务：开着，端口 8102，没有起来：端口 8102 被占用\n发件箱：连不上，缓存 17 条\n");
        let off = json!({"on": false, "port": 8102, "share": null, "running": false, "error": null, "stored": null, "sinks": [],
            "outbox": {"active": false, "cached": 0, "sent": 0, "up": false, "dest": null}});
        assert_eq!(state_at(&off, now), "中心服务：没开\n发件箱：没在发（网里没有中心服务）\n");
        let unshared = json!({"on": true, "port": 8102, "share": null, "running": true, "error": null, "stored": null, "sinks": [],
            "outbox": {"active": false, "cached": 0, "sent": 0, "up": false, "dest": null}});
        assert_eq!(state_at(&unshared, now), "中心服务：开着，端口 8102，没有分享\n发件箱：没在发（网里没有中心服务）\n");
        let no_port = json!({"on": true, "port": null, "share": null, "running": false, "error": null, "stored": null, "sinks": [],
            "outbox": {"dest": null}});
        assert_eq!(state_at(&no_port, now), "中心服务：开着，端口不明，没有起来：原因不明\n发件箱：没在发（网里没有中心服务）\n");
        assert_eq!([ago(10), ago(7200), ago(172800)], ["刚才", "2 小时前", "2 天前"]);
    }
}
