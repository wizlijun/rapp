//! `rapp load [设备…] [--top] [--json]` and `rapp load pick [--json]` (device-load §9): the
//! local service's IPC `load_all` says how much headroom each device has. The table and the
//! choice are pure functions of that reply. Everything another device sent goes through `plain`.

use crate::args::Cmd;
use crate::ipc::{self, Gone};
use crate::out::Out;
use crate::say::{columns, plain};
use serde_json::{json, Value};
use std::time::Duration;

const NOT_RUNNING: &str = "本机的 rApp 服务没有在运行";
const OLD: &str = "版本太旧，不支持";
/// Longer than the service's own wait for the other devices.
const CALL: Duration = Duration::from_secs(30);

pub async fn run(cmd: Cmd) {
    let (devices, top, json, pick) = match cmd {
        Cmd::Load { devices, top, json } => (devices, top, json, false),
        Cmd::LoadPick { json } => (vec![], false, json, true),
        _ => return,
    };
    let out = Out { json };
    let mut ask = json!({"cmd": "load_all"});
    if !devices.is_empty() {
        ask["devices"] = json!(devices);
    }
    if top {
        ask["top"] = json!(true);
    }
    let reply = match ipc::call(ask, CALL).await {
        Ok(r) => r,
        Err(Gone) => out.fail("not_running", NOT_RUNNING, None),
    };
    let reply = if reply["ok"] == true {
        reply
    } else if reply["error"].as_str().is_some_and(|e| e.contains("unknown")) {
        // A service from before this command: its own row says so.
        json!({"ok": true, "devices": [{"id": "", "name": "本机", "local": true, "error": "old version"}]})
    } else {
        out.fail("failed", &format!("没有成功：{}", plain(reply["error"].as_str().unwrap_or(""))), None)
    };
    if pick {
        match pick_of(&reply) {
            Some(p) => out.ok(p.clone(), &format!("{}（{}）：{}", text(&p["name"]), text(&p["id"]), text(&p["reason"]))),
            None => out.fail("no_device", "没有合适的设备", None),
        }
    }
    if reply["devices"].as_array().is_none_or(Vec::is_empty) {
        out.fail("failed", "没有这样的设备", None);
    }
    out.ok(json!({"devices": reply["devices"]}), table(&reply).trim_end());
}

fn text(v: &Value) -> String {
    plain(v.as_str().unwrap_or(""))
}

/// The share of a free fraction `f` (0..=1) as a cell, e.g. `剩 41%`.
fn left(f: f64) -> String {
    format!("剩 {:.0}%", (f * 100.0).clamp(0.0, 100.0))
}

fn pct_of(avail: &Value, total: &Value) -> Option<f64> {
    let (a, t) = (avail.as_f64()?, total.as_f64()?);
    (t > 0.0).then(|| a / t)
}

/// The tightest readable disk's free fraction.
fn disk_free(load: &Value) -> Option<f64> {
    load["disks"]
        .as_array()?
        .iter()
        .filter(|d| d["unreadable"] != true)
        .filter_map(|d| pct_of(&d["avail"], &d["total"]))
        .reduce(f64::min)
}

fn heat_word(level: &str) -> Option<&'static str> {
    Some(match level {
        "normal" => "正常",
        "hot" => "偏热",
        "serious" => "严重",
        "critical" => "危急",
        _ => return None,
    })
}

fn pct_cell(v: &Value) -> String {
    v.as_f64().map_or("—".into(), |p| format!("{p:.0}%"))
}

fn disk_cell(load: &Value) -> String {
    match disk_free(load) {
        Some(f) => left(f),
        None if load["disks"].as_array().is_some_and(|d| !d.is_empty()) => "读不到".into(),
        None => "—".into(),
    }
}

fn warnings_cell(load: &Value) -> String {
    let w: Vec<String> =
        load["warnings"].as_array().map(|a| a.iter().map(|w| text(&w["text"])).filter(|t| !t.is_empty()).collect()).unwrap_or_default();
    if w.is_empty() {
        "—".into()
    } else {
        w.join("；")
    }
}

/// One device's row: the name, then either the cells or what is wrong with the device.
fn row(d: &Value) -> Vec<String> {
    let mut name = text(&d["name"]);
    if d["local"] == true && name != "本机" {
        name.push_str("（本机）");
    }
    let Some(load) = d.get("load").filter(|l| l.is_object()) else {
        let note = match d["error"].as_str().unwrap_or("") {
            "offline" => "不在线".to_string(),
            "old version" => OLD.to_string(),
            "no data" => "暂无数据".to_string(),
            other => format!("读不到：{}", plain(other)),
        };
        return if d["error"] == "no data" {
            let mut r = vec![name];
            r.extend(std::iter::repeat_n("—".to_string(), 6));
            r.push(note);
            r
        } else {
            vec![name, note]
        };
    };
    let items = &load["items"];
    let heat = items["heat"]["level"].as_str().and_then(heat_word).unwrap_or("—");
    vec![
        name,
        load["headroom"].as_u64().map_or("—".into(), |h| h.to_string()),
        pct_cell(&items["cpu"]["pct"]),
        pct_cell(&items["gpu"]["pct"]),
        pct_of(&items["mem"]["avail"], &items["mem"]["total"]).map_or("—".into(), left),
        heat.into(),
        disk_cell(load),
        warnings_cell(load),
    ]
}

/// The table `rapp load` prints: a header row, then a row for every device.
pub fn table(reply: &Value) -> String {
    let head = ["设备", "余力", "CPU", "GPU", "内存", "热度", "最紧的盘", "警告"].map(String::from).to_vec();
    let mut rows = vec![head];
    rows.extend(reply["devices"].as_array().map(|a| a.iter().map(row).collect::<Vec<_>>()).unwrap_or_default());
    columns(&rows)
}

fn has_danger(load: &Value) -> bool {
    load["warnings"].as_array().is_some_and(|w| w.iter().any(|w| w["level"] == "danger"))
}

/// The device to start work on: has a `load`, can run terminals, no 危险 warning; the highest
/// headroom, then the lower CPU use (unknown counts as full), then the earlier in the list.
/// `{id, name, headroom, tightest, reason}`.
pub fn pick_of(reply: &Value) -> Option<Value> {
    let mut best: Option<(u64, f64, &Value)> = None;
    for d in reply["devices"].as_array()? {
        let load = &d["load"];
        let Some(h) = load["headroom"].as_u64().filter(|_| load.is_object() && load["term"] == true && !has_danger(load)) else {
            continue;
        };
        let cpu = load["items"]["cpu"]["pct"].as_f64().unwrap_or(100.0);
        if best.is_none_or(|(bh, bc, _)| h > bh || (h == bh && cpu < bc)) {
            best = Some((h, cpu, d));
        }
    }
    let (headroom, _, d) = best?;
    Some(json!({
        "id": d["id"], "name": text(&d["name"]), "headroom": headroom,
        "tightest": d["load"]["tightest"], "reason": reason(&d["load"]),
    }))
}

/// 「余力 72，最紧的是内存（剩 41%）」, from one device's `load`.
pub fn reason(load: &Value) -> String {
    let head = match load["headroom"].as_u64() {
        Some(h) => format!("余力 {h}"),
        None => return "余力读不到".into(),
    };
    let items = &load["items"];
    let (label, detail) = match load["tightest"].as_str().unwrap_or("") {
        "cpu" => ("CPU", items["cpu"]["pct"].as_f64().map(|p| left(1.0 - p / 100.0))),
        "gpu" => ("GPU", items["gpu"]["pct"].as_f64().map(|p| left(1.0 - p / 100.0))),
        "mem" => ("内存", pct_of(&items["mem"]["avail"], &items["mem"]["total"]).map(left)),
        "disk" => ("磁盘", disk_free(load).map(left)),
        "heat" => ("热度", items["heat"]["level"].as_str().and_then(heat_word).map(String::from)),
        "battery" => (
            "电池",
            Some(if items["battery"]["plugged"] == true {
                "接着电源".to_string()
            } else {
                format!("电量 {}", pct_cell(&items["battery"]["pct"]))
            }),
        ),
        _ => return head,
    };
    match detail {
        Some(d) => format!("{head}，最紧的是{label}（{d}）"),
        None => format!("{head}，最紧的是{label}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = 1_000_000_000;

    fn dev(id: &str, name: &str, headroom: u64, cpu: f64, term: bool, warns: Value) -> Value {
        json!({"id": id, "name": name, "load": {
            "headroom": headroom, "tightest": "mem", "term": term,
            "items": {"cpu": {"pct": cpu, "cores": 8},
                      "mem": {"total": 16 * GB, "avail": 8 * GB},
                      "heat": {"level": "normal"}},
            "disks": [{"mount": "/", "total": 100 * GB, "avail": 30 * GB}],
            "warnings": warns}})
    }

    #[test]
    fn table_rows() {
        let mut local = dev("a1", "mini", 72, 42.0, true, json!([{"item":"disk:/","level":"warn","text":"磁盘约 40 分钟后写满"}]));
        local["local"] = json!(true);
        local["load"]["items"]["mem"] = json!({"total": 100 * GB, "avail": 41 * GB});
        local["load"]["items"]["gpu"] = json!({"pct": 7.0});
        local["load"]["items"]["heat"] = json!({"level": "hot"});
        let reply = json!({"ok": true, "devices": [
            local,
            {"id": "b2", "name": "gpu1", "error": "offline"},
            {"id": "c3", "name": "old", "error": "old version"},
            {"id": "d4", "name": "new", "error": "no data"},
        ]});
        let want = "\
设备        余力  CPU  GPU  内存    热度  最紧的盘  警告
mini（本机）  72    42%  7%   剩 41%  偏热  剩 30%    磁盘约 40 分钟后写满
gpu1        不在线
old         版本太旧，不支持
new         —     —    —    —       —     —         暂无数据
";
        // Compare cell by cell, so the test does not depend on the exact padding.
        let got = table(&reply);
        let cells = |s: &str| s.lines().map(|l| l.split_whitespace().map(String::from).collect::<Vec<_>>()).collect::<Vec<_>>();
        assert_eq!(cells(&got), cells(want), "{got}");
        assert!(got.lines().all(|l| l == l.trim_end()));
    }

    #[test]
    fn old_device_row() {
        let t = table(&json!({"devices": [{"id": "x", "name": "o", "error": "old version"}]}));
        assert_eq!(t.lines().nth(1).unwrap().split_whitespace().collect::<Vec<_>>(), ["o", "版本太旧，不支持"]);
    }

    #[test]
    fn control_characters_from_a_device_are_dropped() {
        let t = table(&json!({"devices": [{"id": "x", "name": "a\u{1b}[31mb", "error": "x\ny"}]}));
        assert!(!t.contains('\u{1b}'));
        assert_eq!(t.lines().count(), 2);
    }

    #[test]
    fn pick_skips_danger_and_no_term() {
        let danger = json!([{"item":"disk:/","level":"danger","text":"磁盘快满了"}]);
        let r = json!({"devices": [
            dev("a", "a", 90, 10.0, true, danger),
            dev("b", "b", 85, 10.0, false, json!([])),
            {"id": "c", "name": "c", "error": "offline"},
            dev("d", "d", 40, 10.0, true, json!([{"item":"cpu","level":"warn","text":"x"}])),
        ]});
        let p = pick_of(&r).unwrap();
        assert_eq!((p["id"].as_str(), p["headroom"].as_u64()), (Some("d"), Some(40)));
        assert_eq!(p["tightest"], "mem");
    }

    #[test]
    fn pick_tie_goes_to_lower_cpu() {
        let r = json!({"devices": [
            dev("a", "a", 60, 50.0, true, json!([])),
            dev("b", "b", 60, 20.0, true, json!([])),
            dev("c", "c", 60, 20.0, true, json!([])),
        ]});
        assert_eq!(pick_of(&r).unwrap()["id"], "b");
        // A missing cpu counts as full.
        let mut nocpu = dev("n", "n", 60, 0.0, true, json!([]));
        nocpu["load"]["items"].as_object_mut().unwrap().remove("cpu");
        let r = json!({"devices": [nocpu, dev("b", "b", 60, 99.0, true, json!([]))]});
        assert_eq!(pick_of(&r).unwrap()["id"], "b");
    }

    #[test]
    fn pick_none_is_none() {
        assert_eq!(pick_of(&json!({"devices": []})), None);
        assert_eq!(pick_of(&json!({"devices": [{"id":"a","name":"a","error":"old version"}]})), None);
        assert_eq!(pick_of(&json!({"devices": [dev("a", "a", 50, 1.0, false, json!([]))]})), None);
    }

    #[test]
    fn reason_reads_like_a_sentence() {
        let mut d = dev("a", "a", 72, 10.0, true, json!([]));
        d["load"]["items"]["mem"] = json!({"total": 100 * GB, "avail": 41 * GB});
        assert_eq!(reason(&d["load"]), "余力 72，最紧的是内存（剩 41%）");
        d["load"]["tightest"] = json!("disk");
        assert_eq!(reason(&d["load"]), "余力 72，最紧的是磁盘（剩 30%）");
        d["load"]["tightest"] = json!("cpu");
        assert_eq!(reason(&d["load"]), "余力 72，最紧的是CPU（剩 90%）");
        d["load"].as_object_mut().unwrap().remove("tightest");
        assert_eq!(reason(&d["load"]), "余力 72");
    }
}
