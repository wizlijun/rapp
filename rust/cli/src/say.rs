//! What gets printed, as pure functions of the service's reply.

use serde_json::Value;

/// `s` without control characters: what another device sent (a name, an error text) is printed
/// through this, so it cannot move the cursor, colour the terminal or start a new line.
fn plain(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).collect()
}

/// Terminal columns of `s`: ASCII is one, everything else (Chinese) two.
fn width(s: &str) -> usize {
    s.chars().map(|c| if c.is_ascii() { 1 } else { 2 }).sum()
}

/// Pads every cell but the last of each row to its column's widest cell plus two spaces.
fn columns(rows: &[Vec<String>]) -> String {
    let n = rows.iter().map(Vec::len).max().unwrap_or(0);
    let widths: Vec<usize> = (0..n).map(|i| rows.iter().filter_map(|r| r.get(i)).map(|c| width(c)).max().unwrap_or(0)).collect();
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

/// One `已分享：<url>` per port; right under it who the share is for when it is not for every
/// device, then a warning.
pub fn shared(reply: &Value) -> String {
    let mut out = String::new();
    let empty = Vec::new();
    for s in reply["shared"].as_array().unwrap_or(&empty) {
        out.push_str(&format!("已分享：{}\n", s["url"].as_str().unwrap_or("")));
        let allow = names(&s["allow"]);
        if !allow.is_empty() {
            out.push_str(&format!("只给：{}\n", allow.join("、")));
        }
        if let Some(w) = s["warn"].as_str() {
            out.push_str(w);
            out.push('\n');
        }
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

/// `rapp share` with no ports: this device's shares.
pub fn table(reply: &Value) -> String {
    let id = reply["id"].as_str().map(|id| format!("{id}.rapp")).unwrap_or_else(|| "（还没有 ID）".into());
    let out = format!("这台设备：{id}   中继：{}\n", relay_text(reply["relay"].as_str().unwrap_or("")));
    let shares = reply["shares"].as_array().filter(|s| !s.is_empty());
    let Some(shares) = shares else { return out + "（没有分享）\n" };
    let mut rows = vec![["端口", "状态", "只给", "地址"].map(String::from).to_vec()];
    for s in shares {
        rows.push(vec![
            s["port"].to_string(),
            if s["listening"] == true { "有服务在听" } else { "没有服务在听" }.into(),
            names(&s["allow"]).join(","),
            s["url"].as_str().unwrap_or("").into(),
        ]);
    }
    out + &columns(&rows)
}

/// `rapp hosts`: each known device with its ports, or what is wrong with it.
pub fn hosts(reply: &Value) -> String {
    let empty = Vec::new();
    let list = reply["hosts"].as_array().unwrap_or(&empty);
    if list.is_empty() {
        return "（没有主机）\n".into();
    }
    let rows: Vec<Vec<String>> = list
        .iter()
        .map(|h| {
            let what = match (h["error"].as_str(), h["shares"].as_array()) {
                (Some("offline"), _) => "不在线".to_string(),
                (Some("no key"), _) => "这台设备还没有填 key".to_string(),
                (Some(e), _) => format!("接不上：{}", plain(e)),
                (None, Some(s)) if !s.is_empty() => s.iter().map(|s| s["port"].to_string()).collect::<Vec<_>>().join("  "),
                (None, _) => "（没有分享）".to_string(),
            };
            vec![plain(h["name"].as_str().unwrap_or("")), format!("{}.rapp", plain(h["id"].as_str().unwrap_or(""))), what]
        })
        .collect();
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn shared_prints_the_address_and_the_warning() {
        let r = json!({"ok":true,"shared":[
            {"port":8000,"url":"http://123456789.rapp:8000"},
            {"port":22,"url":"http://123456789.rapp:22","warn":"分享这个端口，等于把这台机器能到的网络也交出去"}]});
        assert_eq!(
            shared(&r),
            "已分享：http://123456789.rapp:8000\n已分享：http://123456789.rapp:22\n分享这个端口，等于把这台机器能到的网络也交出去\n"
        );
    }

    #[test]
    fn shared_says_who_a_restricted_share_is_for() {
        let r = json!({"ok":true,"shared":[
            {"port":8000,"url":"http://123456789.rapp:8000","allow":["mini","abababab"]},
            {"port":22,"url":"http://123456789.rapp:22","allow":["mini"],"warn":"分享这个端口，等于把这台机器能到的网络也交出去"},
            {"port":8001,"url":"http://123456789.rapp:8001"},
            {"port":8002,"url":"http://123456789.rapp:8002","allow":[]}]});
        assert_eq!(
            shared(&r),
            "已分享：http://123456789.rapp:8000\n只给：mini、abababab\n\
             已分享：http://123456789.rapp:22\n只给：mini\n分享这个端口，等于把这台机器能到的网络也交出去\n\
             已分享：http://123456789.rapp:8001\n已分享：http://123456789.rapp:8002\n"
        );
    }

    // A name another device chose, or an error text it sent, must not drive the terminal.
    #[test]
    fn what_another_device_sent_is_printed_without_control_characters() {
        let evil = "mi\u{1b}[31mni\nroot\r\u{7}";
        let clean = "mi[31mniroot";
        assert_eq!(plain(evil), clean);
        assert_eq!(plain("书房 mini-2"), "书房 mini-2");

        let r = json!({"ok":true,"shared":[{"port":8000,"url":"http://123456789.rapp:8000","allow":[evil,"b"]}]});
        assert_eq!(shared(&r), format!("已分享：http://123456789.rapp:8000\n只给：{clean}、b\n"));

        let r = json!({"ok":true,"id":"123456789","relay":"connected","shares":[
            {"port":22,"allow":[{"fp":"ab","name":evil}],"url":"http://123456789.rapp:22","listening":true}]});
        let t = table(&r);
        assert!(t.lines().nth(2).unwrap().contains(clean), "{t:?}");
        assert_eq!((t.lines().count(), t.chars().filter(|c| c.is_control()).count()), (3, 3), "{t:?}");

        let r = json!({"ok":true,"hosts":[
            {"id":"123456789","name":evil,"shares":[{"port":8000}]},
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
        assert_eq!(table(&none), "这台设备：123456789.rapp   中继：已连接\n（没有分享）\n");
        let some = json!({"ok":true,"id":"123456789","relay":"connected","shares":[
            {"port":22,"allow":[{"fp":"ab","name":"mini"}],"url":"http://123456789.rapp:22","listening":true},
            {"port":8000,"url":"http://123456789.rapp:8000","listening":false}]});
        let t = table(&some);
        assert!(t.lines().nth(1).unwrap().starts_with("端口"));
        assert!(t.contains("有服务在听") && t.contains("没有服务在听") && t.contains("mini"));
        assert_eq!(t.lines().count(), 4);
    }

    #[test]
    fn relay_states_have_a_text_each() {
        for (relay, want) in [("connecting", "连接中"), ("error", "出错"), ("off", "没有配置")] {
            let r = json!({"id":"123456789","relay":relay,"shares":[]});
            assert!(table(&r).starts_with(&format!("这台设备：123456789.rapp   中继：{want}\n")), "{relay}");
        }
    }

    #[test]
    fn hosts_lists_devices_and_what_is_wrong() {
        let r = json!({"ok":true,"hosts":[
            {"id":"123456789","name":"gpu1","shares":[{"port":8000},{"port":22}]},
            {"id":"987654321","name":"mini","error":"offline"},
            {"id":"111111111","name":"书房","shares":[]}]});
        let t = hosts(&r);
        assert!(t.contains("gpu1") && t.contains("123456789.rapp") && t.contains("8000  22"));
        assert!(t.lines().any(|l| l.contains("mini") && l.contains("不在线")));
        assert!(t.lines().any(|l| l.contains("书房") && l.contains("（没有分享）")));
    }
}
