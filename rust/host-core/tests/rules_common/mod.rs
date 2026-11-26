//! Typed mirrors of the protocol types as the rule fixtures write them, so a fixture
//! value can be turned into a `rapp_host_core` value and back for an exact comparison.
//! Shared by the `rules_*` tests (`mod rules_common;`).
#![allow(dead_code)]

use rapp_host_core::{CanvasRect, WindowInfo, WindowKind};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One typed argument or result out of a case's `in` / `out` value.
pub fn arg<T: DeserializeOwned>(v: &Value) -> T {
    serde_json::from_value(v.clone()).unwrap_or_else(|e| panic!("fixture value {v} does not fit: {e}"))
}

/// The `fn` a case calls.
pub fn func(input: &Value) -> &str {
    input["fn"].as_str().expect("case without \"fn\"")
}

/// `CanvasRect` as written by `HostFixture.rect(_:)`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct JRect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl JRect {
    pub fn canvas(self) -> CanvasRect {
        CanvasRect { x: self.x, y: self.y, w: self.w, h: self.h }
    }
    pub fn of(r: &CanvasRect) -> JRect {
        JRect { x: r.x, y: r.y, w: r.w, h: r.h }
    }
}

pub fn kind_from(b: u8) -> WindowKind {
    match b {
        0 => WindowKind::Normal,
        1 => WindowKind::Dialog,
        2 => WindowKind::Floating,
        3 => WindowKind::Sheet,
        4 => WindowKind::Popover,
        5 => WindowKind::Menu,
        6 => WindowKind::Tooltip,
        _ => panic!("window kind {b}"),
    }
}

pub fn kind_byte(k: WindowKind) -> u8 {
    match k {
        WindowKind::Normal => 0,
        WindowKind::Dialog => 1,
        WindowKind::Floating => 2,
        WindowKind::Sheet => 3,
        WindowKind::Popover => 4,
        WindowKind::Menu => 5,
        WindowKind::Tooltip => 6,
    }
}

/// `WindowInfo` as the generators write it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JWindow {
    pub id: u32,
    pub parent: u32,
    pub kind: u8,
    pub resizable: bool,
    pub focused: bool,
    pub rect: JRect,
    pub title_bar: f32,
    pub title: String,
}

impl JWindow {
    pub fn info(&self) -> WindowInfo {
        WindowInfo {
            id: self.id,
            parent: self.parent,
            kind: kind_from(self.kind),
            resizable: self.resizable,
            focused: self.focused,
            rect: self.rect.canvas(),
            title_bar: self.title_bar,
            title: self.title.clone(),
        }
    }
    pub fn of(w: &WindowInfo) -> JWindow {
        JWindow {
            id: w.id,
            parent: w.parent,
            kind: kind_byte(w.kind),
            resizable: w.resizable,
            focused: w.focused,
            rect: JRect::of(&w.rect),
            title_bar: w.title_bar,
            title: w.title.clone(),
        }
    }
}

pub fn infos(w: &[JWindow]) -> Vec<WindowInfo> {
    w.iter().map(JWindow::info).collect()
}

pub fn jwindows(w: &[WindowInfo]) -> Vec<JWindow> {
    w.iter().map(JWindow::of).collect()
}

/// A view as `{"window": n, "rect": {…}}`, or null.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct JView {
    pub window: u32,
    pub rect: JRect,
}

impl JView {
    pub fn pair(self) -> (u32, CanvasRect) {
        (self.window, self.rect.canvas())
    }
    pub fn of(v: &(u32, CanvasRect)) -> JView {
        JView { window: v.0, rect: JRect::of(&v.1) }
    }
}
