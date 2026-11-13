//! Native windows for the standalone client. All share the existing decoder,
//! socket, stream settings and composer draft; popups stay with their parent.
use super::{editor::Editor, finish, geometry, p, Shared};
use gtk::{gdk, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::Rc,
    time::Duration,
};
// Create parents before children even when the host lists the topmost child first.
fn parent_order(mut pending: Vec<p::Window>) -> Vec<p::Window> {
    pending.reverse();
    let mut ordered = Vec::with_capacity(pending.len());
    while !pending.is_empty() {
        let Some(i) = pending
            .iter()
            .position(|w| !pending.iter().any(|other| other.id == w.parent))
        else {
            break;
        };
        ordered.push(pending.remove(i));
    }
    ordered
}
struct View {
    shell: gtk::Widget,
    area: gtk::DrawingArea,
    popup: bool,
}
pub struct Windows {
    views: HashMap<u32, View>,
    app: gtk::Application,
    state: Shared,
    editor: Editor,
    json: bool,
    main: gtk::ApplicationWindow,
    zoom: f64,
}
impl Windows {
    pub fn new(
        app: &gtk::Application,
        state: &Shared,
        editor: &Editor,
        main: &gtk::ApplicationWindow,
        json: bool,
    ) -> Self {
        Self {
            views: HashMap::new(),
            app: app.clone(),
            state: state.clone(),
            editor: editor.clone(),
            json,
            main: main.clone(),
            zoom: state.borrow().zoom,
        }
    }
    pub fn sync(&mut self) {
        let table = parent_order(self.state.borrow().windows.clone());
        // Popovers must be unparented before their parent window is destroyed.
        for popup in [true, false] {
            let gone: Vec<_> = self
                .views
                .iter()
                .filter(|(id, v)| v.popup == popup && !table.iter().any(|w| w.id == **id))
                .map(|(id, _)| *id)
                .collect();
            for id in gone {
                self.remove(id);
            }
        }
        for popup in [false, true] {
            for remote in table.iter().filter(|w| (w.kind >= 3) == popup) {
                if !self.views.contains_key(&remote.id) {
                    let parent = if popup {
                        self.views.get(&remote.parent).map(|v| v.area.clone())
                    } else {
                        None
                    };
                    if popup && parent.is_none() {
                        continue;
                    }
                    let area = gtk::DrawingArea::builder()
                        .focusable(true)
                        .hexpand(true)
                        .vexpand(true)
                        .build();
                    let shell: gtk::Widget = if let Some(parent) = parent {
                        let pop = gtk::Popover::builder()
                            .has_arrow(false)
                            .autohide(false)
                            .child(&area)
                            .build();
                        pop.set_parent(&parent);
                        pop.upcast()
                    } else {
                        let win = gtk::ApplicationWindow::builder()
                            .application(&self.app)
                            .title(&remote.title)
                            .default_width((remote.rect.w as i32).clamp(240, 1200))
                            .default_height((remote.rect.h as i32 + 120).clamp(240, 900))
                            .build();
                        let focused_state = self.state.clone();
                        let focused_id = remote.id;
                        win.connect_is_active_notify(move |w| {
                            if w.is_active() {
                                let mut s = focused_state.borrow_mut();
                                s.focused = Some(focused_id);
                                s.send(p::id_packet(14, focused_id));
                            }
                        });
                        let root = gtk::Box::new(gtk::Orientation::Vertical, 4);
                        root.append(&area);
                        root.append(&self.editor.new_chips());
                        let input = gtk::Box::new(gtk::Orientation::Horizontal, 4);
                        let editor = gtk::TextView::with_buffer(&self.editor.buffer());
                        editor.set_wrap_mode(gtk::WrapMode::WordChar);
                        editor.set_height_request(60);
                        editor.set_hexpand(true);
                        let scroll = gtk::ScrolledWindow::builder()
                            .min_content_height(60)
                            .max_content_height(150)
                            .hexpand(true)
                            .child(&editor)
                            .build();
                        input.append(&scroll);
                        let draft = self.editor.clone();
                        editor.connect_paste_clipboard(move |v| {
                            v.stop_signal_emission_by_name("paste-clipboard");
                            draft.paste();
                        });
                        let composing = Rc::new(Cell::new(false));
                        let c = composing.clone();
                        editor.connect_preedit_changed(move |_, text| c.set(!text.is_empty()));
                        let key = gtk::EventControllerKey::new();
                        key.set_propagation_phase(gtk::PropagationPhase::Capture);
                        let draft = self.editor.clone();
                        let state = self.state.clone();
                        key.connect_key_pressed(move |_, k, _, m| {
                            if !composing.get()
                                && matches!(k, gdk::Key::Return | gdk::Key::KP_Enter)
                                && !m.contains(gdk::ModifierType::SHIFT_MASK)
                            {
                                draft.emit_activate();
                                return glib::Propagation::Stop;
                            }
                            if m.contains(gdk::ModifierType::CONTROL_MASK)
                                && k.to_lower() == gdk::Key::v
                            {
                                return glib::Propagation::Proceed;
                            }
                            if !composing.get()
                                && draft.text().is_empty()
                                && state.borrow().ready
                                && !m.intersects(
                                    gdk::ModifierType::SUPER_MASK | gdk::ModifierType::META_MASK,
                                )
                                && (m.contains(gdk::ModifierType::CONTROL_MASK)
                                    || matches!(
                                        k,
                                        gdk::Key::Tab
                                            | gdk::Key::Left
                                            | gdk::Key::Right
                                            | gdk::Key::Up
                                            | gdk::Key::Down
                                            | gdk::Key::Escape
                                            | gdk::Key::BackSpace
                                    ))
                            {
                                use glib::translate::IntoGlib;
                                if let Some(code) = geometry::keycode(k.to_lower().into_glib()) {
                                    state.borrow().send(p::key(code, flags(m), true));
                                    state.borrow().send(p::key(code, flags(m), false));
                                    return glib::Propagation::Stop;
                                }
                            }
                            glib::Propagation::Proceed
                        });
                        editor.add_controller(key);
                        let send = gtk::Button::with_label("发送");
                        let draft = self.editor.clone();
                        send.connect_clicked(move |_| draft.emit_activate());
                        input.append(&send);
                        let attach = gtk::Button::with_label("附件");
                        let draft = self.editor.clone();
                        let window = win.clone();
                        attach.connect_clicked(move |_| draft.attach(&window));
                        input.append(&attach);
                        let tools = gtk::Button::with_label("菜单 / 剪贴板");
                        let main = self.main.clone();
                        tools.connect_clicked(move |_| main.present());
                        input.append(&tools);
                        root.append(&input);
                        let error = gtk::Label::new(None);
                        error.set_wrap(true);
                        self.editor
                            .error_label()
                            .bind_property("label", &error, "label")
                            .sync_create()
                            .build();
                        root.append(&error);
                        win.set_child(Some(&root));
                        let app = self.app.clone();
                        let s = self.state.clone();
                        let json = self.json;
                        win.connect_close_request(move |_| {
                            finish(&app, &s, json, 0, "quit");
                            glib::Propagation::Proceed
                        });
                        win.present();
                        win.upcast()
                    };
                    install(
                        &area,
                        &shell,
                        &self.state,
                        remote.id,
                        &self.editor,
                        self.json,
                    );
                    self.views.insert(remote.id, View { shell, area, popup });
                }
                let v = &self.views[&remote.id];
                if let Ok(win) = v.shell.clone().downcast::<gtk::Window>() {
                    win.set_title(Some(&remote.title));
                    win.set_resizable(remote.flags & 1 != 0);
                }
                if let Ok(pop) = v.shell.clone().downcast::<gtk::Popover>() {
                    if let Some(parent) = table.iter().find(|w| w.id == remote.parent) {
                        let z = self.state.borrow().zoom;
                        pop.set_pointing_to(Some(&gdk::Rectangle::new(
                            ((remote.rect.x - parent.rect.x + remote.rect.w / 2.) as f64 * z)
                                as i32,
                            ((remote.rect.y - parent.rect.y - parent.title_bar) as f64 * z) as i32,
                            1,
                            1,
                        )));
                        v.area.set_size_request(
                            (remote.rect.w as f64 * z) as i32,
                            ((remote.rect.h - remote.title_bar) as f64 * z) as i32,
                        );
                        pop.popup();
                    }
                }
            }
        }
        self.redraw();
    }
    pub fn update_zoom(&mut self) {
        let z = self.state.borrow().zoom;
        if (self.zoom - z).abs() < 0.001 {
            return;
        }
        self.zoom = z;
        for remote in &self.state.borrow().windows {
            if let Some(v) = self.views.get(&remote.id) {
                if let Ok(w) = v.shell.clone().downcast::<gtk::Window>() {
                    w.set_default_size(
                        (remote.rect.w as f64 * z).round() as i32,
                        ((remote.rect.h - remote.title_bar) as f64 * z).round() as i32 + 120,
                    );
                }
            }
        }
        self.sync();
    }
    pub fn redraw(&self) {
        for v in self.views.values() {
            v.area.queue_draw();
        }
    }
    fn remove(&mut self, id: u32) {
        if let Some(v) = self.views.remove(&id) {
            if let Ok(pop) = v.shell.clone().downcast::<gtk::Popover>() {
                pop.unparent();
            } else if let Ok(win) = v.shell.downcast::<gtk::Window>() {
                win.destroy();
            }
        }
    }
}
impl Drop for Windows {
    fn drop(&mut self) {
        for popup in [true, false] {
            let ids: Vec<_> = self
                .views
                .iter()
                .filter(|(_, v)| v.popup == popup)
                .map(|(id, _)| *id)
                .collect();
            for id in ids {
                self.remove(id);
            }
        }
    }
}
fn remote_point(
    s: &Shared,
    id: u32,
    area: &gtk::DrawingArea,
    x: f64,
    y: f64,
) -> Option<(f32, f32)> {
    let s = s.borrow();
    let w = s.windows.iter().find(|w| w.id == id)?;
    let content = p::Rect {
        x: 0.,
        y: w.title_bar,
        w: w.rect.w,
        h: w.rect.h - w.title_bar,
    };
    let (ox, oy, z) = geometry::fit(content, area.width() as f64, area.height() as f64);
    Some((
        ((x - ox) / z).clamp(0., w.rect.w as f64) as f32,
        (((y - oy) / z) + w.title_bar as f64).clamp(w.title_bar as f64, w.rect.h as f64) as f32,
    ))
}
fn install(
    area: &gtk::DrawingArea,
    shell: &gtk::Widget,
    state: &Shared,
    id: u32,
    editor: &Editor,
    json: bool,
) {
    let s = state.clone();
    area.set_draw_func(move |_, cr, width, height| {
        cr.set_source_rgb(0.03, 0.03, 0.04);
        let _ = cr.paint();
        let s = s.borrow();
        let Some(w) = s.windows.iter().find(|w| w.id == id) else {
            return;
        };
        let Some(surface) = &s.surface else { return };
        let z =
            (width as f64 / w.rect.w as f64).min(height as f64 / (w.rect.h - w.title_bar) as f64);
        let _ = cr.save();
        cr.translate(
            (width as f64 - w.rect.w as f64 * z) / 2.,
            (height as f64 - (w.rect.h - w.title_bar) as f64 * z) / 2.,
        );
        cr.rectangle(
            0.,
            0.,
            w.rect.w as f64 * z,
            (w.rect.h - w.title_bar) as f64 * z,
        );
        cr.clip();
        cr.scale(z, z);
        cr.translate(
            (s.region.x - w.rect.x) as f64,
            (s.region.y - w.rect.y - w.title_bar) as f64,
        );
        cr.scale(
            s.region.w as f64 / surface.width() as f64,
            s.region.h as f64 / surface.height() as f64,
        );
        let _ = cr.set_source_surface(surface, 0., 0.);
        let _ = cr.paint();
        let _ = cr.restore();
    });
    let pointer = Rc::new(Cell::new((0., 0.)));
    let pressed = Rc::new(Cell::new(None::<(u8, u8)>));
    let click = gtk::GestureClick::new();
    click.set_button(0);
    let s = state.clone();
    let a = area.clone();
    let p = pressed.clone();
    click.connect_pressed(move |g, n, x, y| {
        if !s.borrow().ready {
            return;
        }
        let button = match g.current_button() {
            1 => 0,
            3 => 1,
            _ => return,
        };
        a.grab_focus();
        let point = remote_point(&s, id, &a, x, y);
        if let Some((x, y)) = point {
            let mut s = s.borrow_mut();
            s.focused = Some(id);
            s.send(p::id_packet(14, id));
            s.send(p::mouse(0, button, id, x, y, n.clamp(1, 3) as u8));
            p.set(Some((button, n.clamp(1, 3) as u8)));
            g.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    let s = state.clone();
    let a = area.clone();
    let p = pressed.clone();
    click.connect_released(move |_, _, x, y| {
        if let (Some((b, n)), Some((x, y))) = (p.take(), remote_point(&s, id, &a, x, y)) {
            s.borrow().send(p::mouse(1, b, id, x, y, n));
        }
    });
    area.add_controller(click);
    let motion = gtk::EventControllerMotion::new();
    let s = state.clone();
    let a = area.clone();
    let p = pressed.clone();
    let pos = pointer.clone();
    motion.connect_motion(move |_, x, y| {
        pos.set((x, y));
        if !s.borrow().ready {
            return;
        }
        if let Some((x, y)) = remote_point(&s, id, &a, x, y) {
            let (kind, b, n) = p.get().map(|(b, n)| (2, b, n)).unwrap_or((3, 0, 1));
            s.borrow().send(p::mouse(kind, b, id, x, y, n));
        }
    });
    area.add_controller(motion);
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
    let s = state.clone();
    let a = area.clone();
    scroll.connect_scroll(move |_, dx, dy| {
        let (x, y) = pointer.get();
        if let Some((x, y)) = remote_point(&s, id, &a, x, y) {
            s.borrow()
                .send(p::scroll(id, x, y, (-dx * 10.) as f32, (-dy * 10.) as f32));
        }
        glib::Propagation::Stop
    });
    area.add_controller(scroll);
    let held = Rc::new(RefCell::new(HashMap::new()));
    let key = gtk::EventControllerKey::new();
    let s = state.clone();
    let keys = held.clone();
    let key_shell = shell.clone();
    key.connect_key_pressed(move |_, k, hardware, mods| {
        if !s.borrow().ready
            || mods.intersects(gdk::ModifierType::SUPER_MASK | gdk::ModifierType::META_MASK)
        {
            return glib::Propagation::Proceed;
        }
        if let Ok(window) = key_shell.clone().downcast::<gtk::Window>() {
            if k == gdk::Key::F11 {
                if window.is_fullscreen() {
                    window.unfullscreen();
                } else {
                    window.fullscreen();
                }
                return glib::Propagation::Stop;
            }
            if mods.contains(gdk::ModifierType::CONTROL_MASK) && k.to_lower() == gdk::Key::q {
                if let Some(app) = window.application() {
                    finish(&app, &s, json, 0, "quit");
                }
                return glib::Propagation::Stop;
            }
        }
        use glib::translate::IntoGlib;
        let code = geometry::keycode(k.to_lower().into_glib());
        if let Some(code) = code {
            keys.borrow_mut().insert(hardware, code);
            s.borrow().send(p::key(code, flags(mods), true));
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    let s = state.clone();
    let keys = held.clone();
    key.connect_key_released(move |_, _, hardware, mods| {
        if let Some(code) = keys.borrow_mut().remove(&hardware) {
            s.borrow().send(p::key(code, flags(mods), false));
        }
    });
    area.add_controller(key);
    let focus = gtk::EventControllerFocus::new();
    let s = state.clone();
    focus.connect_leave(move |_| {
        for (_, code) in held.borrow_mut().drain() {
            s.borrow().send(p::key(code, 0, false));
        }
    });
    let s = state.clone();
    focus.connect_enter(move |_| {
        let mut s = s.borrow_mut();
        s.focused = Some(id);
        s.send(p::id_packet(14, id));
    });
    area.add_controller(focus);
    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    let editor = editor.clone();
    drop.connect_drop(move |_, value, _, _| {
        if let Ok(files) = value.get::<gdk::FileList>() {
            editor.insert(rapp_client_core::transfer::Copy::Files(
                files.files().iter().filter_map(|f| f.path()).collect(),
            ));
            true
        } else {
            false
        }
    });
    area.add_controller(drop);
    if shell.is::<gtk::Window>() {
        let timer: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
        let old = Rc::new(Cell::new((0, 0)));
        let s = state.clone();
        area.connect_resize(move |_, w, h| {
            let before = old.replace((w, h));
            if before == (0, 0) || before == (w, h) {
                return;
            }
            let mut pending = timer.borrow_mut();
            if let Some(t) = pending.take() {
                t.remove();
            }
            let s = s.clone();
            let timer = timer.clone();
            *pending = Some(glib::timeout_add_local_once(
                Duration::from_millis(200),
                move || {
                    timer.borrow_mut().take();
                    let s = s.borrow();
                    if !s.ready {
                        return;
                    }
                    if let Some(remote) = s.windows.iter().find(|x| x.id == id && x.flags & 1 != 0)
                    {
                        let mut b = id.to_le_bytes().to_vec();
                        b.extend(((w as f64 / s.zoom).clamp(1., 65535.) as u16).to_le_bytes());
                        b.extend(
                            ((h as f64 / s.zoom + remote.title_bar as f64).clamp(1., 65535.)
                                as u16)
                                .to_le_bytes(),
                        );
                        s.send(p::packet(9, b));
                    }
                },
            ));
        });
    }
}
fn flags(mods: gdk::ModifierType) -> u64 {
    (if mods.contains(gdk::ModifierType::CONTROL_MASK) {
        1 << 20
    } else {
        0
    }) | (if mods.contains(gdk::ModifierType::SHIFT_MASK) {
        1 << 17
    } else {
        0
    }) | (if mods.contains(gdk::ModifierType::ALT_MASK) {
        1 << 19
    } else {
        0
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn window(id: u32, parent: u32) -> p::Window {
        p::Window {
            id,
            parent,
            kind: if parent == 0 { 0 } else { 4 },
            flags: 0,
            rect: p::Rect {
                x: 0.,
                y: 0.,
                w: 100.,
                h: 100.,
            },
            title_bar: 0.,
            title: String::new(),
        }
    }
    #[test]
    fn topmost_nested_popup_is_created_after_its_ancestors() {
        let ordered = parent_order(vec![window(4, 3), window(3, 1), window(2, 0), window(1, 0)]);
        assert_eq!(
            ordered.iter().map(|w| w.id).collect::<Vec<_>>(),
            vec![1, 2, 3, 4]
        );
    }
    #[test]
    fn cyclic_parent_chain_does_not_prevent_independent_windows() {
        let ordered = parent_order(vec![window(1, 2), window(2, 1), window(3, 0)]);
        assert_eq!(ordered.iter().map(|w| w.id).collect::<Vec<_>>(), vec![3]);
    }
}
