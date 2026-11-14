//! Native menu structure matching the Mac client; all menu surfaces share one action state.
use super::{finish, Shared};
use gtk::{gio, glib, prelude::*};
use rapp_client_core::{geometry, protocol as p, stream};
use std::{
    cell::RefCell,
    rc::Rc,
    time::{Duration, Instant},
};

type HistoryEntry = (u32, Option<String>, bool);

#[derive(Clone)]
pub struct Controls {
    pub app_menu: gio::Menu,
    pub stream_menu: gio::Menu,
    group: gio::SimpleActionGroup,
    history_menu: gio::Menu,
    history: Rc<RefCell<Vec<HistoryEntry>>>,
}
fn radio(menu: &gio::Menu, label: &str, action: &str, value: &str) {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(Some(&format!("client.{action}")), Some(&value.to_variant()));
    menu.append_item(&item);
}
fn sync(group: &gio::SimpleActionGroup, state: &Shared) {
    let s = state.borrow();
    for (name, value) in [
        ("mode", s.mode.to_string()),
        ("density", s.density_choice.to_string()),
        ("fps", s.fps.to_string()),
        ("zoom", format!("{}", (s.zoom * 100.).round() as u32)),
    ] {
        if let Some(action) = group
            .lookup_action(name)
            .and_then(|a| a.downcast::<gio::SimpleAction>().ok())
        {
            action.set_state(&value.to_variant());
        }
    }
    if let Some(action) = group
        .lookup_action("move-top-left")
        .and_then(|a| a.downcast::<gio::SimpleAction>().ok())
    {
        action.set_enabled(s.ready && s.windows.iter().any(|w| w.kind <= 2));
    }
}
impl Controls {
    pub fn new(
        window: &gtk::ApplicationWindow,
        app: &gtk::Application,
        state: &Shared,
        area: &gtk::DrawingArea,
        viewport: &gtk::ScrolledWindow,
        json_mode: bool,
    ) -> Self {
        let group = gio::SimpleActionGroup::new();
        window.insert_action_group("client", Some(&group));
        for name in ["mode", "density", "fps", "zoom"] {
            let action = gio::SimpleAction::new_stateful(
                name,
                Some(glib::VariantTy::STRING),
                &"".to_variant(),
            );
            let weak = group.downgrade();
            let s = state.clone();
            let area = area.clone();
            action.connect_activate(move |_, value| {
                let Some(value) = value
                    .and_then(|v| v.str())
                    .and_then(|v| v.parse::<u32>().ok())
                else {
                    return;
                };
                {
                    let mut s = s.borrow_mut();
                    match name {
                        "mode" if [2, 3, 4].contains(&value) => s.mode = value as u8,
                        "density" if value <= 2 => s.density_choice = value,
                        "fps" if [1, 5, 15, 30].contains(&value) => s.fps = value as u8,
                        "zoom" if stream::ZOOMS.contains(&value) => s.zoom = value as f64 / 100.,
                        _ => return,
                    }
                    if name != "zoom" {
                        s.stream_pinned = true;
                    }
                    s.geometry_changed = Instant::now() - Duration::from_secs(1);
                }
                if let Some(group) = weak.upgrade() {
                    sync(&group, &s);
                }
                area.queue_draw();
            });
            group.add_action(&action);
        }
        for (name, preset) in [
            ("least-traffic", stream::LEAST_TRAFFIC),
            ("sharpest", stream::SHARPEST),
        ] {
            let action = gio::SimpleAction::new(name, None);
            let s = state.clone();
            let weak = group.downgrade();
            action.connect_activate(move |_, _| {
                {
                    let mut s = s.borrow_mut();
                    s.mode = preset.mode;
                    s.fps = preset.fps;
                    s.density_choice = preset.density;
                    s.stream_pinned = true;
                    s.geometry_changed = Instant::now() - Duration::from_secs(1);
                }
                if let Some(g) = weak.upgrade() {
                    sync(&g, &s);
                }
            });
            group.add_action(&action);
        }
        let quit = gio::SimpleAction::new("quit", None);
        let a = app.clone();
        let s = state.clone();
        quit.connect_activate(move |_, _| finish(&a, &s, json_mode, 0, "quit"));
        group.add_action(&quit);
        let move_action = gio::SimpleAction::new("move-top-left", None);
        let s = state.clone();
        move_action.connect_activate(move |_, _| {
            let s = s.borrow();
            let id = s
                .focused
                .filter(|id| s.windows.iter().any(|w| w.id == *id && w.kind <= 2))
                .or_else(|| s.windows.iter().find(|w| w.kind <= 2).map(|w| w.id));
            if let Some(id) = id {
                let slot = geometry::top_left_slot(&s.windows, id);
                let mut payload = id.to_le_bytes().to_vec();
                payload.extend(slot.to_le_bytes());
                payload.extend(slot.to_le_bytes());
                s.send(p::packet(16, payload));
                s.send(p::id_packet(14, id));
            }
        });
        group.add_action(&move_action);
        let fit = gio::SimpleAction::new("fit", None);
        let s = state.clone();
        let viewport = viewport.clone();
        let weak = group.downgrade();
        fit.connect_activate(move |_, _| {
            {
                let mut s = s.borrow_mut();
                s.zoom = geometry::fit(s.region, viewport.width() as f64, viewport.height() as f64)
                    .2
                    .clamp(0.01, 2.);
                s.geometry_changed = Instant::now() - Duration::from_secs(1);
            }
            if let Some(g) = weak.upgrade() {
                sync(&g, &s);
            }
        });
        group.add_action(&fit);
        let stream_menu = gio::Menu::new();
        let presets = gio::Menu::new();
        presets.append(
            Some("最省流（双色·灰度 + 自适应 + 1 fps）"),
            Some("client.least-traffic"),
        );
        presets.append(
            Some("最清晰（高彩 + 原画 + 15 fps）"),
            Some("client.sharpest"),
        );
        stream_menu.append_section(None, &presets);
        let modes = gio::Menu::new();
        for (label, value) in stream::MODES {
            radio(&modes, label, "mode", &value.to_string());
        }
        stream_menu.append_section(None, &modes);
        let density = gio::Menu::new();
        for (value, label) in stream::DENSITIES.iter().enumerate() {
            radio(&density, label, "density", &value.to_string());
        }
        stream_menu.append_section(None, &density);
        let fps = gio::Menu::new();
        for (label, value) in stream::FPS {
            radio(&fps, label, "fps", &value.to_string());
        }
        stream_menu.append_section(None, &fps);
        let history_menu = gio::Menu::new();
        history_menu.append(Some("（空）"), None);
        let history_section = gio::Menu::new();
        history_section.append_submenu(Some("远程剪贴板"), &history_menu);
        stream_menu.append_section(None, &history_section);
        let app_menu = gio::Menu::new();
        let session = gio::Menu::new();
        session.append(Some("断开连接 · Ctrl+Q"), Some("client.quit"));
        app_menu.append_section(None, &session);
        let view = gio::Menu::new();
        let zoom = gio::Menu::new();
        for value in stream::ZOOMS {
            radio(&zoom, &format!("{value}%"), "zoom", &value.to_string());
        }
        let fit_section = gio::Menu::new();
        fit_section.append(Some("适应窗口"), Some("client.fit"));
        zoom.append_section(None, &fit_section);
        view.append_submenu(Some("缩放"), &zoom);
        view.append(
            Some("把远端的这个窗口移到左上角"),
            Some("client.move-top-left"),
        );
        app_menu.append_section(None, &view);
        app_menu.append_section(None, &stream_menu);
        sync(&group, state);
        Self {
            app_menu,
            stream_menu,
            group,
            history_menu,
            history: Rc::new(RefCell::new(Vec::new())),
        }
    }
    pub fn sync(&self, state: &Shared) {
        sync(&self.group, state);
    }
    pub fn add_clip(
        &self,
        id: u32,
        text: Option<String>,
        truncated: bool,
        window: &gtk::ApplicationWindow,
    ) {
        let mut history = self.history.borrow_mut();
        for (id, _, _) in history.iter() {
            self.group.remove_action(&format!("clip{id}"));
        }
        if history.first().is_none_or(|entry| entry.0 != id) {
            history.insert(0, (id, text, truncated));
            history.truncate(20);
        }
        self.history_menu.remove_all();
        for (id, text, truncated) in history.iter() {
            let name = format!("clip{id}");
            let action = gio::SimpleAction::new(&name, None);
            let label = if let Some(text) = text {
                let summary = text.split_whitespace().collect::<Vec<_>>().join(" ");
                let preview: String = summary.chars().take(40).collect();
                format!(
                    "文字 · {}{}{}",
                    preview,
                    if summary.chars().count() > 40 {
                        "…"
                    } else {
                        ""
                    },
                    if *truncated {
                        "（内容截断，暂不支持下载）"
                    } else {
                        ""
                    }
                )
            } else {
                "图片/文件/数据（暂不支持下载）".into()
            };
            action.set_enabled(text.is_some() && !truncated);
            let text = text.clone();
            let clipboard = gtk::prelude::WidgetExt::display(window).clipboard();
            action.connect_activate(move |_, _| {
                if let Some(text) = &text {
                    clipboard.set_text(text);
                }
            });
            self.group.add_action(&action);
            self.history_menu
                .append(Some(&label), Some(&format!("client.{name}")));
        }
    }
}
