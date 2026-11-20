use anyhow::{ensure, Context, Result};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::Duration,
};
use x11rb::{
    connection::Connection,
    protocol::{
        xkb::{self, ConnectionExt as _},
        xproto::{self, ConnectionExt as _},
    },
};
#[derive(Clone, PartialEq, Debug)]
pub struct Keyboard {
    pub names: [String; 5],
    pub group: u32,
    pub locked: u32,
}
impl Keyboard {
    pub fn from_json(value: &serde_json::Value) -> Result<Self> {
        let names = ["rules", "model", "layout", "variant", "options"]
            .map(|key| value[key].as_str().unwrap_or("").to_owned());
        ensure!(
            names.iter().all(|s| s.len() <= 4096 && !s.contains('\0')),
            "invalid keyboard rules"
        );
        Ok(Self {
            names,
            group: value["active_layout_index"].as_u64().unwrap_or(0).min(3) as u32,
            locked: if value["capsLock"] == true { 2 } else { 0 }
                | if value["numLock"] == true { 16 } else { 0 },
        })
    }
    pub fn keymap(&self) -> Result<String> {
        use std::ffi::{c_char, c_void, CStr, CString};
        #[repr(C)]
        struct Names {
            fields: [*const c_char; 5],
        }
        #[link(name = "xkbcommon")]
        unsafe extern "C" {
            fn xkb_context_new(flags: u32) -> *mut c_void;
            fn xkb_context_unref(ctx: *mut c_void);
            fn xkb_keymap_new_from_names(
                ctx: *mut c_void,
                names: *const Names,
                flags: u32,
            ) -> *mut c_void;
            fn xkb_keymap_get_as_string(map: *mut c_void, format: u32) -> *mut c_char;
            fn xkb_keymap_unref(map: *mut c_void);
        }
        let values: Vec<_> = self
            .names
            .iter()
            .map(|s| CString::new(s.as_str()))
            .collect::<std::result::Result<_, _>>()?;
        let names = Names {
            fields: std::array::from_fn(|i| values[i].as_ptr()),
        };
        // Every pointer remains valid for this synchronous call. Each returned
        // reference/allocation is released before returning, including errors.
        unsafe {
            let ctx = xkb_context_new(0);
            ensure!(!ctx.is_null(), "cannot create XKB context");
            let map = xkb_keymap_new_from_names(ctx, &names, 0);
            xkb_context_unref(ctx);
            ensure!(!map.is_null(), "cannot compile keyboard layout");
            let text = xkb_keymap_get_as_string(map, 1);
            xkb_keymap_unref(map);
            ensure!(!text.is_null(), "cannot serialize keyboard layout");
            let result = CStr::from_ptr(text).to_string_lossy().into_owned();
            libc::free(text.cast());
            Ok(result)
        }
    }
}
#[derive(Clone, PartialEq, Debug)]
pub struct Source {
    pub id: String,
    pub name: String,
    pub ascii: bool,
    pub keyboard: Option<Keyboard>,
}
pub struct InputSources {
    commands: mpsc::SyncSender<String>,
    events: mpsc::Receiver<Result<Source>>,
    stop: Arc<AtomicBool>,
}
impl InputSources {
    pub fn start() -> Self {
        let (commands, rx) = mpsc::sync_channel::<String>(8);
        let (tx, events) = mpsc::sync_channel(8);
        let stop = Arc::new(AtomicBool::new(false));
        let cancelled = stop.clone();
        std::thread::spawn(move || {
            let mut previous = None;
            loop {
                if cancelled.load(Ordering::Relaxed) {
                    break;
                }
                if let Ok(source) = current() {
                    if previous.as_ref() != Some(&source) {
                        previous = Some(source.clone());
                        let _ = tx.try_send(Ok(source));
                    }
                }
                match rx.recv_timeout(Duration::from_millis(750)) {
                    Ok(id) if !cancelled.load(Ordering::Relaxed) => {
                        let result = select(&id).and_then(|_| current());
                        if let Ok(source) = &result {
                            previous = Some(source.clone());
                        }
                        let _ = tx.try_send(result);
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    _ => break,
                }
            }
        });
        Self {
            commands,
            events,
            stop,
        }
    }
    pub fn select(&self, id: String) -> Result<()> {
        self.commands
            .try_send(id)
            .map_err(|_| anyhow::anyhow!("input source helper busy"))
    }
    pub fn next(&self) -> Option<Result<Source>> {
        self.events.try_recv().ok()
    }
}
impl Drop for InputSources {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}
fn running(name: &str) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::read_dir("/proc").is_ok_and(|entries| {
        entries.flatten().any(|entry| {
            entry
                .metadata()
                .is_ok_and(|m| m.uid() == unsafe { libc::getuid() })
                && std::fs::read_to_string(entry.path().join("comm"))
                    .is_ok_and(|s| s.trim() == name)
                && same_session(&entry.path())
        })
    })
}
fn same_session(path: &std::path::Path) -> bool {
    let Ok(bytes) = std::fs::read(path.join("environ")) else {
        return false;
    };
    let value = |key: &str| {
        bytes
            .split(|b| *b == 0)
            .find_map(|line| line.strip_prefix(format!("{key}=").as_bytes()))
    };
    if let Ok(bus) = std::env::var("DBUS_SESSION_BUS_ADDRESS") {
        if let Some(other) = value("DBUS_SESSION_BUS_ADDRESS") {
            return other == bus.as_bytes();
        }
    }
    [
        "XDG_RUNTIME_DIR",
        if wayland() {
            "WAYLAND_DISPLAY"
        } else {
            "DISPLAY"
        },
    ]
    .iter()
    .all(|key| std::env::var(key).is_ok_and(|ours| value(key) == Some(ours.as_bytes())))
}
fn output(bin: &str, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8(crate::server::command(bin, args, None)?)?
        .trim()
        .to_owned())
}
fn latin(layout: &str) -> bool {
    [
        "us", "gb", "de", "fr", "es", "it", "pt", "br", "ca", "au", "nz", "nl", "be", "ch", "at",
        "dk", "no", "se", "fi", "is", "ie", "pl", "cz", "sk", "hu", "ro", "tr",
    ]
    .contains(&layout.split(['-', ':', '(']).next().unwrap_or(""))
}
fn wayland() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some_and(|v| !v.is_empty())
}
pub fn hypr_keyboard() -> Result<serde_json::Value> {
    let value: serde_json::Value =
        serde_json::from_slice(&crate::desktop::hyprland::request("j/devices")?)?;
    let keyboards = value["keyboards"].as_array().context("no keyboard")?;
    let physical = |k: &&serde_json::Value| {
        !k["name"]
            .as_str()
            .unwrap_or("")
            .contains("virtual-keyboard")
    };
    keyboards
        .iter()
        .filter(physical)
        .find(|k| k["main"] == true)
        .or_else(|| keyboards.iter().find(physical))
        .cloned()
        .context("no keyboard")
}
fn x11() -> Result<(x11rb::rust_connection::RustConnection, Vec<String>, u8)> {
    let (conn, screen) = x11rb::connect(None)?;
    conn.xkb_use_extension(1, 0)?.reply()?;
    let atom = conn.intern_atom(false, b"_XKB_RULES_NAMES")?.reply()?.atom;
    let property = conn
        .get_property(
            false,
            conn.setup().roots[screen].root,
            atom,
            xproto::AtomEnum::STRING,
            0,
            4096,
        )?
        .reply()?;
    let layouts = String::from_utf8_lossy(&property.value)
        .split('\0')
        .nth(2)
        .unwrap_or("us")
        .split(',')
        .map(str::to_owned)
        .collect();
    let group = u8::from(
        conn.xkb_get_state(xkb::ID::USE_CORE_KBD.into())?
            .reply()?
            .group,
    );
    Ok((conn, layouts, group))
}
fn current() -> Result<Source> {
    let mut source = current_source()?;
    if wayland() {
        source.keyboard = hypr_keyboard()
            .ok()
            .and_then(|value| Keyboard::from_json(&value).ok());
    }
    Ok(source)
}
fn current_source() -> Result<Source> {
    if running("fcitx5") {
        let state = output("fcitx5-remote", &[])?;
        if state == "2" {
            let im = output("fcitx5-remote", &["-n"])?;
            ensure!(!im.is_empty(), "no active input method");
            return Ok(Source {
                id: format!("fcitx5:{im}"),
                ascii: im.strip_prefix("keyboard-").is_some_and(latin),
                name: im,
                keyboard: None,
            });
        }
    } else if running("ibus-daemon") {
        let im = output("ibus", &["engine"])?;
        ensure!(!im.is_empty(), "no active input method");
        return Ok(Source {
            id: format!("ibus:{im}"),
            ascii: im.strip_prefix("xkb:").is_some_and(latin),
            name: im,
            keyboard: None,
        });
    }
    let (index, name, layout) = if wayland() {
        let keyboard = hypr_keyboard()?;
        let index = keyboard["active_layout_index"].as_u64().unwrap_or(0) as u8;
        let layout = keyboard["layout"]
            .as_str()
            .unwrap_or("")
            .split(',')
            .nth(index as usize)
            .unwrap_or("")
            .to_owned();
        (
            index,
            keyboard["active_keymap"]
                .as_str()
                .unwrap_or(&layout)
                .to_owned(),
            layout,
        )
    } else {
        let (_, layouts, index) = x11()?;
        let layout = layouts
            .get(index as usize)
            .cloned()
            .context("unknown keyboard group")?;
        (index, layout.clone(), layout)
    };
    Ok(Source {
        id: format!("xkb:{index}"),
        name,
        ascii: latin(&layout),
        keyboard: None,
    })
}
fn select(id: &str) -> Result<()> {
    ensure!(
        id.len() <= 1024 && !id.chars().any(char::is_control),
        "invalid input source"
    );
    if let Some(im) = id.strip_prefix("fcitx5:") {
        ensure!(running("fcitx5"), "Fcitx5 is not running");
        output("fcitx5-remote", &["-s", im])?;
        return Ok(());
    }
    if let Some(im) = id.strip_prefix("ibus:") {
        ensure!(running("ibus-daemon"), "IBus is not running");
        output("ibus", &["engine", im])?;
        return Ok(());
    }
    if running("fcitx5") {
        output("fcitx5-remote", &["-c"])?;
    }
    if running("ibus-daemon") && id.is_empty() {
        output("ibus", &["engine", "xkb:us::eng"])?;
        return Ok(());
    }
    let layouts = if wayland() {
        hypr_keyboard()?["layout"]
            .as_str()
            .unwrap_or("")
            .split(',')
            .map(str::to_owned)
            .collect::<Vec<_>>()
    } else {
        x11()?.1
    };
    let index = if id.is_empty() {
        layouts
            .iter()
            .position(|s| latin(s))
            .context("no ASCII keyboard layout is configured")?
    } else {
        id.strip_prefix("xkb:")
            .context("unknown input source")?
            .parse::<usize>()?
    };
    ensure!(index < layouts.len() && index < 4, "unknown keyboard group");
    if wayland() {
        ensure!(
            crate::desktop::hyprland::request(&format!("/switchxkblayout all {index}"))?
                .starts_with(b"ok"),
            "keyboard layout switch failed"
        );
    } else {
        let (conn, _, _) = x11()?;
        conn.xkb_latch_lock_state(
            xkb::ID::USE_CORE_KBD.into(),
            xproto::ModMask::default(),
            xproto::ModMask::default(),
            true,
            (index as u8).into(),
            xproto::ModMask::default(),
            false,
            0,
        )?
        .check()?;
        conn.flush()?;
    }
    Ok(())
}
