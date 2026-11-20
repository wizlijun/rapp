//! AT-SPI metadata and menu actions run in a bounded, session-scoped helper.
//! Password detection reads roles only; neither text contents nor values are queried.
use anyhow::{Context, Result};
use gdk::glib;
use serde_json::{json, Value};
use std::{
    ffi::{c_char, c_int, c_void, CStr},
    io::{Read, Write},
    process::{Child, ChildStdin, Command, Stdio},
    ptr::NonNull,
    sync::mpsc,
    time::{Duration, Instant},
};

pub struct Accessibility {
    child: Child,
    input: Option<ChildStdin>,
    events: mpsc::Receiver<Value>,
}
impl Accessibility {
    pub fn start() -> Result<Self> {
        let mut child = Command::new(std::env::current_exe()?)
            .arg("--internal-accessibility")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let input = child.stdin.take();
        use std::os::fd::AsRawFd;
        let fd = input.as_ref().unwrap().as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::last_os_error().into());
        }
        let mut output = child.stdout.take().unwrap();
        let (tx, events) = mpsc::sync_channel(4);
        std::thread::spawn(move || {
            while let Ok(value) = read(&mut output) {
                let _ = tx.try_send(value);
            }
        });
        Ok(Self {
            child,
            input,
            events,
        })
    }
    pub fn send(&mut self, value: &Value) -> Result<()> {
        write(
            self.input.as_mut().context("accessibility helper closed")?,
            value,
        )
    }
    pub fn next(&self) -> Option<Value> {
        self.events.try_recv().ok()
    }
}
impl Drop for Accessibility {
    fn drop(&mut self) {
        self.input.take();
        let end = Instant::now() + Duration::from_millis(600);
        while Instant::now() < end {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn write(output: &mut impl Write, value: &Value) -> Result<()> {
    output.write_all(&rapp_client_core::protocol::packet(
        60,
        serde_json::to_vec(value)?,
    ))?;
    output.flush()?;
    Ok(())
}
fn read(input: &mut impl Read) -> Result<Value> {
    let mut h = [0; 5];
    input.read_exact(&mut h)?;
    let n = u32::from_le_bytes(h[1..].try_into()?) as usize;
    anyhow::ensure!(
        h[0] == 60 && n <= 1024 * 1024,
        "invalid accessibility message"
    );
    let mut bytes = vec![0; n];
    input.read_exact(&mut bytes)?;
    Ok(serde_json::from_slice(&bytes)?)
}

#[repr(C)]
struct Bounds {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
}
type Error = *mut *mut glib::ffi::GError;
#[link(name = "atspi")]
unsafe extern "C" {
    fn atspi_init() -> c_int;
    fn atspi_set_timeout(timeout: c_int, startup: c_int);
    fn atspi_get_desktop(index: c_int) -> *mut c_void;
    fn atspi_accessible_get_child_count(node: *mut c_void, error: Error) -> c_int;
    fn atspi_accessible_get_child_at_index(
        node: *mut c_void,
        index: c_int,
        error: Error,
    ) -> *mut c_void;
    fn atspi_accessible_get_process_id(node: *mut c_void, error: Error) -> u32;
    fn atspi_accessible_get_role(node: *mut c_void, error: Error) -> u32;
    fn atspi_accessible_get_name(node: *mut c_void, error: Error) -> *mut c_char;
    fn atspi_accessible_get_state_set(node: *mut c_void) -> *mut c_void;
    fn atspi_state_set_contains(set: *mut c_void, state: u32) -> c_int;
    fn atspi_accessible_clear_cache(node: *mut c_void);
    fn atspi_accessible_get_component_iface(node: *mut c_void) -> *mut c_void;
    fn atspi_component_get_extents(node: *mut c_void, coordinate: u32, error: Error)
        -> *mut Bounds;
    fn atspi_accessible_get_text_iface(node: *mut c_void) -> *mut c_void;
    fn atspi_text_get_caret_offset(node: *mut c_void, error: Error) -> c_int;
    fn atspi_text_get_character_extents(
        node: *mut c_void,
        offset: c_int,
        coordinate: u32,
        error: Error,
    ) -> *mut Bounds;
    fn atspi_accessible_get_action_iface(node: *mut c_void) -> *mut c_void;
    fn atspi_action_get_n_actions(node: *mut c_void, error: Error) -> c_int;
    fn atspi_action_get_key_binding(node: *mut c_void, index: c_int, error: Error) -> *mut c_char;
    fn atspi_action_do_action(node: *mut c_void, index: c_int, error: Error) -> c_int;
    fn atspi_event_get_type() -> glib::ffi::GType;
    fn atspi_event_listener_new(
        callback: unsafe extern "C" fn(*mut FocusEvent, *mut c_void),
        data: *mut c_void,
        destroy: Option<unsafe extern "C" fn(*mut c_void)>,
    ) -> *mut c_void;
    fn atspi_event_listener_register(
        listener: *mut c_void,
        kind: *const c_char,
        error: Error,
    ) -> c_int;
}
// Only the public prefix of AtspiEvent is inspected; g_boxed_free owns the full event.
#[repr(C)]
struct FocusEvent {
    kind: *mut c_char,
    source: *mut c_void,
    detail1: c_int,
    detail2: c_int,
}
type Focused = std::cell::RefCell<Option<Node>>;
unsafe extern "C" fn focus_event(event: *mut FocusEvent, data: *mut c_void) {
    unsafe {
        if let (Some(event), Some(focused)) = (event.as_ref(), (data as *const Focused).as_ref()) {
            if event.detail1 != 0 && !event.source.is_null() {
                let reference = glib::gobject_ffi::g_object_ref(event.source.cast());
                *focused.borrow_mut() = Node::owned(reference.cast());
            } else if focused
                .borrow()
                .as_ref()
                .is_some_and(|n| n.ptr() == event.source)
            {
                focused.borrow_mut().take();
            }
        }
        glib::gobject_ffi::g_boxed_free(atspi_event_get_type(), event.cast());
    }
}
/// All AT-SPI getters used here return a full GObject reference (Atspi-2.0.gir).
struct Node(NonNull<c_void>);
impl Node {
    fn owned(pointer: *mut c_void) -> Option<Self> {
        NonNull::new(pointer).map(Self)
    }
    fn ptr(&self) -> *mut c_void {
        self.0.as_ptr()
    }
    fn role(&self) -> u32 {
        unsafe { atspi_accessible_get_role(self.ptr(), std::ptr::null_mut()) }
    }
    fn state(&self, flag: u32) -> bool {
        Node::owned(unsafe { atspi_accessible_get_state_set(self.ptr()) })
            .is_some_and(|set| unsafe { atspi_state_set_contains(set.ptr(), flag) } != 0)
    }
    fn children(&self, end: Instant) -> Vec<Node> {
        let count = unsafe { atspi_accessible_get_child_count(self.ptr(), std::ptr::null_mut()) }
            .clamp(0, 128);
        (0..count)
            .take_while(|_| Instant::now() < end)
            .filter_map(|i| {
                Node::owned(unsafe {
                    atspi_accessible_get_child_at_index(self.ptr(), i, std::ptr::null_mut())
                })
            })
            .collect()
    }
    fn name(&self) -> String {
        let value = unsafe { atspi_accessible_get_name(self.ptr(), std::ptr::null_mut()) };
        if value.is_null() {
            return String::new();
        }
        let result = unsafe { CStr::from_ptr(value) }
            .to_string_lossy()
            .chars()
            .take(200)
            .collect();
        unsafe {
            glib::ffi::g_free(value.cast());
        }
        result
    }
    fn shortcut(&self) -> (String, u8) {
        let Some(action) = Node::owned(unsafe { atspi_accessible_get_action_iface(self.ptr()) })
        else {
            return (String::new(), 0);
        };
        let raw = unsafe { atspi_action_get_key_binding(action.ptr(), 0, std::ptr::null_mut()) };
        if raw.is_null() {
            return (String::new(), 0);
        }
        let binding = unsafe { CStr::from_ptr(raw) }
            .to_string_lossy()
            .into_owned();
        unsafe {
            glib::ffi::g_free(raw.cast());
        }
        shortcut(binding.split(';').nth(2).unwrap_or(""))
    }
    fn bounds(&self) -> Option<Value> {
        let component = Node::owned(unsafe { atspi_accessible_get_component_iface(self.ptr()) })?;
        bounds(unsafe { atspi_component_get_extents(component.ptr(), 1, std::ptr::null_mut()) })
    }
    fn caret(&self) -> Option<Value> {
        if self.role() == 40 {
            return None;
        }
        let text = Node::owned(unsafe { atspi_accessible_get_text_iface(self.ptr()) })?;
        let offset = unsafe { atspi_text_get_caret_offset(text.ptr(), std::ptr::null_mut()) };
        if offset < 0 {
            return None;
        }
        bounds(unsafe {
            atspi_text_get_character_extents(text.ptr(), offset, 1, std::ptr::null_mut())
        })
    }
}
impl Drop for Node {
    fn drop(&mut self) {
        unsafe {
            glib::gobject_ffi::g_object_unref(self.ptr().cast());
        }
    }
}
fn bounds(pointer: *mut Bounds) -> Option<Value> {
    let b = unsafe { pointer.as_ref() }?;
    let result = (b.width >= 0
        && b.height > 0
        && b.x.unsigned_abs() < 100000
        && b.y.unsigned_abs() < 100000)
        .then(|| json!({"x":b.x,"y":b.y,"w":b.width.max(1),"h":b.height}));
    unsafe {
        glib::ffi::g_free(pointer.cast());
    }
    result
}
struct MenuItem {
    node: Node,
    title: String,
    children: Vec<MenuItem>,
    flags: u8,
    key: String,
    modifiers: u8,
}
impl MenuItem {
    fn json(&self) -> Value {
        json!({"title":self.title,"flags":self.flags,"key":self.key,"modifiers":self.modifiers,"children":self.children.iter().map(Self::json).collect::<Vec<_>>()})
    }
}
fn menu(node: Node, depth: usize, left: &mut usize, end: Instant) -> Option<MenuItem> {
    if depth > 6 || *left == 0 || Instant::now() >= end {
        return None;
    }
    *left -= 1;
    let title = node.name();
    let flags = (if node.state(8) { 1 } else { 0 })
        | (if node.state(4) { 2 } else { 0 })
        | (if node.role() == 50 { 4 } else { 0 });
    let (key, modifiers) = node.shortcut();
    let children = node
        .children(end)
        .into_iter()
        .filter(|n| matches!(n.role(), 8 | 33 | 35 | 41 | 45 | 50))
        .filter_map(|n| menu(n, depth + 1, left, end))
        .collect();
    Some(MenuItem {
        node,
        title,
        children,
        flags,
        key,
        modifiers,
    })
}
fn shortcut(mut text: &str) -> (String, u8) {
    let mut flags = 0;
    while let Some(tail) = text.strip_prefix('<') {
        let Some((name, rest)) = tail.split_once('>') else {
            return (String::new(), 0);
        };
        flags |= match name.to_ascii_lowercase().as_str() {
            "shift" => 1,
            "control" | "ctrl" | "primary" => 2,
            "alt" | "mod1" => 4,
            "meta" | "super" => 8,
            _ => return (String::new(), 0),
        };
        text = rest;
    }
    (
        text.chars().filter(|c| !c.is_control()).take(32).collect(),
        flags,
    )
}
fn inspect(pid: u32, focused: &Focused) -> (bool, Vec<Value>, Vec<MenuItem>) {
    let end = Instant::now() + Duration::from_millis(350);
    let mut secure = false;
    let mut rects = vec![];
    let mut menus = vec![];
    let mut menu_roots = vec![];
    // Focus events avoid repeatedly scanning a large application tree. Clone the
    // reference before any IPC, which can dispatch another event reentrantly.
    let focus = focused.borrow().as_ref().and_then(|n| {
        Node::owned(unsafe { glib::gobject_ffi::g_object_ref(n.ptr().cast()).cast() })
    });
    if let Some(node) = focus {
        unsafe {
            atspi_accessible_clear_cache(node.ptr());
        }
        if unsafe { atspi_accessible_get_process_id(node.ptr(), std::ptr::null_mut()) } == pid
            && node.state(12)
        {
            secure = node.role() == 40;
            if let Some(rect) = node.bounds() {
                rects.push(rect);
            }
            if !secure {
                if let Some(caret) = node.caret() {
                    rects.push(caret);
                }
            }
        }
    }
    let Some(desktop) = Node::owned(unsafe { atspi_get_desktop(0) }) else {
        return (secure, rects, menus);
    };
    let app = desktop
        .children(end)
        .into_iter()
        .find(|n| unsafe { atspi_accessible_get_process_id(n.ptr(), std::ptr::null_mut()) } == pid);
    let Some(app) = app else {
        return (secure, rects, menus);
    };
    unsafe {
        atspi_accessible_clear_cache(app.ptr());
    }
    let mut queue = std::collections::VecDeque::from([(app, 0)]);
    let mut visits = 0;
    while let Some((node, depth)) = queue.pop_front() {
        if Instant::now() >= end || visits >= 1024 {
            break;
        }
        visits += 1;
        unsafe {
            atspi_accessible_clear_cache(node.ptr());
        }
        if rects.is_empty() && !secure && node.state(12) {
            secure |= node.role() == 40;
            if let Some(rect) = node.bounds() {
                rects.push(rect);
            }
            if !secure {
                if let Some(caret) = node.caret() {
                    rects.push(caret);
                }
            }
        }
        if node.role() == 34 {
            menu_roots.push(node);
        } else if depth < 32 && node.role() != 40 {
            for child in node.children(end) {
                queue.push_back((child, depth + 1));
            }
        }
    }
    let end = Instant::now() + Duration::from_millis(350);
    let mut left = 500;
    for root in menu_roots {
        menus.extend(
            root.children(end)
                .into_iter()
                .filter_map(|n| menu(n, 1, &mut left, end)),
        );
    }
    rects.truncate(3);
    (secure, rects, menus)
}
pub fn run_child() -> Result<()> {
    // This process owns its GLib context and all AT-SPI references.
    unsafe {
        atspi_set_timeout(75, 250);
    }
    let initialized = unsafe { atspi_init() } == 0;
    let mut focused: Box<Focused> = Box::default();
    let _listener = if initialized {
        let listener = Node::owned(unsafe {
            atspi_event_listener_new(focus_event, (&mut *focused as *mut Focused).cast(), None)
        });
        if let Some(listener) = &listener {
            unsafe {
                atspi_event_listener_register(
                    listener.ptr(),
                    c"object:state-changed:focused".as_ptr(),
                    std::ptr::null_mut(),
                );
            }
        }
        listener
    } else {
        None
    };
    let (tx, commands) = mpsc::sync_channel(16);
    std::thread::spawn(move || {
        let mut input = std::io::stdin();
        while let Ok(value) = read(&mut input) {
            if tx.send(value).is_err() {
                break;
            }
        }
    });
    let context = glib::MainContext::default();
    let mut target = Value::Null;
    let mut menus: Vec<MenuItem> = vec![];
    let mut previous = Value::Null;
    let mut next = Instant::now();
    loop {
        while context.pending() {
            context.iteration(false);
        }
        loop {
            match commands.try_recv() {
                Ok(value) if value["cmd"] == "target" => {
                    target = value["target"].clone();
                    menus.clear();
                    previous = Value::Null;
                    next = Instant::now();
                }
                Ok(value) if value["cmd"] == "menu" && value["target"] == target => {
                    if let Some(path) = value["path"]
                        .as_array()
                        .filter(|p| !p.is_empty() && p.len() <= 6)
                    {
                        let mut items = &menus;
                        let mut picked = None;
                        for index in path {
                            let Some(item) = index.as_u64().and_then(|i| items.get(i as usize))
                            else {
                                picked = None;
                                break;
                            };
                            picked = Some(item);
                            items = &item.children;
                        }
                        if let Some(item) =
                            picked.filter(|i| i.node.state(8) && i.node.name() == i.title)
                        {
                            if let Some(action) = Node::owned(unsafe {
                                atspi_accessible_get_action_iface(item.node.ptr())
                            }) {
                                if unsafe {
                                    atspi_action_get_n_actions(action.ptr(), std::ptr::null_mut())
                                } > 0
                                {
                                    unsafe {
                                        atspi_action_do_action(
                                            action.ptr(),
                                            0,
                                            std::ptr::null_mut(),
                                        );
                                    }
                                }
                            }
                        }
                    }
                }
                Ok(_) => {}
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
            }
        }
        if Instant::now() >= next {
            let pid = target["pid"].as_u64().unwrap_or(0) as u32;
            let (secure, rects, next_menus) = if initialized && pid > 0 {
                inspect(pid, &focused)
            } else {
                (false, vec![], vec![])
            };
            menus = next_menus;
            let value = json!({"target":target,"secure":secure,"rects":rects,"menus":menus.iter().map(MenuItem::json).collect::<Vec<_>>()});
            if value != previous {
                write(&mut std::io::stdout(), &value)?;
                previous = value;
            }
            next = Instant::now() + Duration::from_millis(250);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
