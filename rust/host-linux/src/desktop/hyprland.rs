//! Hyprland's local IPC supplies geometry; pixels come only from toplevel export.
use super::application::{Application, NativeWindow};
use anyhow::{ensure, Context, Result};
use rapp_client_core::protocol::{Rect, Window};
use serde_json::Value;
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    time::Duration,
};
pub fn request(command: &str) -> Result<Vec<u8>> {
    let signature =
        std::env::var("HYPRLAND_INSTANCE_SIGNATURE").context("Hyprland IPC is unavailable")?;
    ensure!(
        !signature.is_empty()
            && signature
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-'),
        "invalid Hyprland instance"
    );
    let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").context("no runtime directory")?)
        .join("hypr")
        .join(signature)
        .join(".socket.sock");
    let mut socket = UnixStream::connect(path)?;
    socket.set_read_timeout(Some(Duration::from_millis(500)))?;
    socket.set_write_timeout(Some(Duration::from_millis(500)))?;
    socket.write_all(command.as_bytes())?;
    let mut out = vec![];
    socket.take(1024 * 1024 + 1).read_to_end(&mut out)?;
    ensure!(out.len() <= 1024 * 1024, "Hyprland response too large");
    Ok(out)
}
pub fn windows() -> Result<Vec<NativeWindow>> {
    parse_windows(&serde_json::from_slice(&request("j/clients")?)?)
}
pub fn active_window_is_terminal() -> bool {
    request("j/activewindow")
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .is_some_and(|value| is_terminal_window(&value))
}
pub(crate) fn is_terminal_window(value: &Value) -> bool {
    if value["tags"]
        .as_array()
        .is_some_and(|tags| {
            tags.iter().any(|tag| {
                tag.as_str()
                    .is_some_and(|t| t.trim_end_matches('*') == "terminal")
            })
        })
    {
        return true;
    }
    ["class", "initialClass"].iter().any(|key| {
        value[*key]
            .as_str()
            .is_some_and(super::is_terminal_class)
    })
}
pub fn pointer_cover(x: f32, y: f32, selected_pid: u32) -> Result<Option<super::Cover>> {
    // Layer-shell overlays (launchers, notifications, authentication prompts)
    // are not in j/clients and must never receive an app session's click.
    let layers: Value = serde_json::from_slice(&request("j/layers")?)?;
    for monitor in layers.as_object().context("invalid layer list")?.values() {
        for level in ["3", "2"] {
            for layer in monitor["levels"][level]
                .as_array()
                .into_iter()
                .flatten()
                .rev()
            {
                let number = |key: &str| layer[key].as_f64().unwrap_or(0.) as f32;
                if x >= number("x")
                    && y >= number("y")
                    && x < number("x") + number("w")
                    && y < number("y") + number("h")
                {
                    let address = layer["address"]
                        .as_str()
                        .unwrap_or("")
                        .trim_start_matches("0x");
                    let id = u64::from_str_radix(address, 16).unwrap_or(u32::MAX as u64) as u32;
                    return Ok(Some(super::Cover {
                        id: id.max(1),
                        name: layer["namespace"]
                            .as_str()
                            .unwrap_or("Desktop overlay")
                            .chars()
                            .take(200)
                            .collect(),
                        app: None,
                    }));
                }
            }
        }
    }
    let monitors: Value = serde_json::from_slice(&request("j/monitors")?)?;
    let visible: std::collections::HashSet<_> = monitors
        .as_array()
        .context("invalid monitor list")?
        .iter()
        .flat_map(|m| {
            [
                m["activeWorkspace"]["id"].as_i64(),
                m["specialWorkspace"]["id"].as_i64(),
            ]
        })
        .flatten()
        .filter(|id| *id != 0)
        .collect();
    let clients: Value = serde_json::from_slice(&request("j/clients")?)?;
    let visible_clients = Value::Array(
        clients
            .as_array()
            .context("invalid clients")?
            .iter()
            .filter(|v| {
                v["pinned"] == true
                    || v["workspace"]["id"]
                        .as_i64()
                        .is_some_and(|id| visible.contains(&id))
            })
            .cloned()
            .collect(),
    );
    let covering = parse_windows(&visible_clients)?
        .into_iter()
        .rev()
        .find(|w| {
            let r = w.window.rect;
            x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
        });
    Ok(covering
        .filter(|w| w.pid != selected_pid)
        .map(|w| super::Cover {
            id: w.window.id,
            name: w.name,
            app: Application::current(w.pid)
                .ok()
                .filter(Application::dismissable),
        }))
}
fn parse_windows(value: &Value) -> Result<Vec<NativeWindow>> {
    let mut windows = vec![];
    let mut ids = std::collections::HashSet::new();
    let mut clients: Vec<_> = value
        .as_array()
        .context("invalid Hyprland clients")?
        .iter()
        .take(1024)
        .collect();
    clients.sort_by_key(|v| std::cmp::Reverse(v["focusHistoryID"].as_i64().unwrap_or(i64::MAX)));
    for v in clients {
        if v["mapped"] != true || v["hidden"] == true {
            continue;
        }
        let address = v["address"].as_str().context("missing window address")?;
        let native_id = u64::from_str_radix(
            address
                .strip_prefix("0x")
                .context("invalid window address")?,
            16,
        )?;
        let id = native_id as u32;
        ensure!(id != 0 && ids.insert(id), "ambiguous window identifiers");
        let pair = |key: &str| -> Result<(f32, f32)> {
            let a = v[key].as_array().context("invalid window geometry")?;
            ensure!(a.len() == 2, "invalid window geometry");
            let x = a[0].as_f64().context("invalid window geometry")? as f32;
            let y = a[1].as_f64().context("invalid window geometry")? as f32;
            ensure!(x.is_finite() && y.is_finite(), "invalid window geometry");
            Ok((x, y))
        };
        let (x, y) = pair("at")?;
        let (w, h) = pair("size")?;
        if w <= 0. || h <= 0. {
            continue;
        }
        let pid = v["pid"]
            .as_u64()
            .filter(|p| *p > 0 && *p <= u32::MAX as u64)
            .context("invalid window process")? as u32;
        windows.push(NativeWindow {
            native_id,
            pid,
            name: v["class"]
                .as_str()
                .unwrap_or("Application")
                .chars()
                .take(1024)
                .collect(),
            window: Window {
                id,
                parent: 0,
                kind: 0,
                flags: 1 | if v["focusHistoryID"] == 0 { 2 } else { 0 },
                rect: Rect { x, y, w, h },
                title_bar: 0.,
                title: v["title"]
                    .as_str()
                    .unwrap_or("")
                    .chars()
                    .take(200)
                    .collect(),
            },
        });
    }
    Ok(windows)
}
pub fn dispatch(
    app: &Application,
    id: u32,
    operation: &str,
    geometry: Option<(i32, i32)>,
) -> Result<()> {
    app.check()?;
    let window = windows()?
        .into_iter()
        .find(|w| w.pid == app.pid && w.window.id == id)
        .context("window does not belong to this application")?;
    let address = format!("address:0x{:x}", window.native_id);
    if operation == "movewindowpixel" {
        if let Some((x, y)) = geometry {
            let monitors: Value = serde_json::from_slice(&request("j/monitors")?)?;
            for monitor in monitors.as_array().context("invalid monitors")? {
                let scale = monitor["scale"].as_f64().unwrap_or(1.).max(0.1);
                let (mut w, mut h) = (
                    monitor["width"].as_f64().unwrap_or(0.) / scale,
                    monitor["height"].as_f64().unwrap_or(0.) / scale,
                );
                if monitor["transform"].as_u64().unwrap_or(0) % 2 == 1 {
                    std::mem::swap(&mut w, &mut h);
                }
                let (mx, my) = (
                    monitor["x"].as_f64().unwrap_or(0.),
                    monitor["y"].as_f64().unwrap_or(0.),
                );
                let contains = |x: f64, y: f64| x >= mx && y >= my && x < mx + w && y < my + h;
                if contains(x as f64, y as f64)
                    && !contains(window.window.rect.x as f64, window.window.rect.y as f64)
                {
                    if let Some(workspace) = monitor["activeWorkspace"]["id"]
                        .as_i64()
                        .filter(|id| *id > 0)
                    {
                        ensure!(
                            request(&format!(
                                "/dispatch movetoworkspacesilent {workspace},{address}"
                            ))?
                            .starts_with(b"ok"),
                            "cannot move window to destination display"
                        );
                    }
                }
            }
        }
    }
    if matches!(operation, "movewindowpixel" | "resizewindowpixel") {
        ensure!(
            request(&format!("/dispatch setfloating {address}"))?.starts_with(b"ok"),
            "cannot float application window"
        );
    }
    let command = if let Some((x, y)) = geometry {
        format!("/dispatch {operation} exact {x} {y},{address}")
    } else {
        format!("/dispatch {operation} {address}")
    };
    ensure!(
        request(&command)?.starts_with(b"ok"),
        "window operation was rejected"
    );
    // Hyprland resizes a floating window about its center. v14 resize keeps
    // the content origin, like the macOS/X11 hosts.
    if operation == "resizewindowpixel" {
        ensure!(
            request(&format!(
                "/dispatch movewindowpixel exact {} {},{address}",
                window.window.rect.x.round() as i32,
                window.window.rect.y.round() as i32
            ))?
            .starts_with(b"ok"),
            "cannot preserve resized window origin"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn identifies_terminal_windows_by_tag_and_class() {
        assert!(is_terminal_window(&json!({
            "class": "custom-tui",
            "tags": ["omarchy-floating-workspace", "terminal*"]
        })));
        assert!(is_terminal_window(&json!({
            "class": "custom-tui",
            "tags": ["terminal"]
        })));
        for class in [
            "foot",
            "org.codeberg.dnkl.foot",
            "Alacritty",
            "kitty",
            "com.mitchellh.ghostty",
            "wezterm",
            "org.omarchy.btop",
            "TUI.float",
            "gnome-terminal-server",
            "konsole",
        ] {
            assert!(
                is_terminal_window(&json!({"class": class, "tags": []})),
                "expected terminal class: {class}"
            );
            assert!(
                is_terminal_window(&json!({"class": "", "initialClass": class})),
                "expected terminal initialClass: {class}"
            );
        }
        for class in ["notemd", "com.rapp.rapp", "firefox", "chromium", "org.gnome.Nautilus", ""] {
            assert!(
                !is_terminal_window(&json!({"class": class, "tags": ["transparent-window*"]})),
                "unexpected terminal class: {class}"
            );
        }
        assert!(!is_terminal_window(&json!({})));
    }
}
