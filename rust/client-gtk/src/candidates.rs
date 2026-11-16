//! Optional Sumi presentation; GTK/Fcitx alone own preedit, selection and commits.
use gtk::{cairo, gio, glib, pango, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::{Rc, Weak},
    time::Duration,
};
#[path = "candidate_layout.rs"]
mod layout;
const SERVICE: &str = "org.fcitx.Fcitx5";
const PATH: &str = "/org/fcitx/Fcitx5/SumiCandidates";
const INTERFACE: &str = "org.fcitx.Fcitx.SumiCandidates1";
type Snapshot = (String, u64, Vec<(i32, String, String)>, i32, bool, bool);
thread_local! { static OWNER: RefCell<Weak<Panel>> = const { RefCell::new(Weak::new()) }; }

struct Connection {
    bus: gio::DBusConnection,
    _subscriptions: Vec<gio::SignalSubscription>,
}
impl Drop for Connection {
    fn drop(&mut self) {
        // This connection owns only this lease. Closing it also releases a late
        // successful SetActive reply, even when the ordinary release RPC failed.
        self.bus.close(None::<&gio::Cancellable>, |_| {});
    }
}

pub struct Panel {
    view: glib::WeakRef<gtk::TextView>,
    scroll: glib::WeakRef<gtk::ScrolledWindow>,
    row: gtk::DrawingArea,
    state: RefCell<layout::Epoch>,
    connection: RefCell<Option<Connection>>,
    connecting: RefCell<Option<gio::Cancellable>>,
    token: RefCell<String>,
    retry_at: Cell<i64>,
    entries: RefCell<Vec<(i32, String, String)>>,
    cursor: Cell<i32>,
    previous: Cell<bool>,
    next: Cell<bool>,
    requested: Cell<usize>,
    manual: Cell<bool>,
    action_pending: Cell<bool>,
    reserve: Cell<bool>,
    composing: Cell<bool>,
    page: RefCell<layout::Page>,
    pitch: Cell<f64>,
    gap: Cell<f64>,
    render_pending: Cell<i64>,
    empty_since: Cell<i64>,
    metrics: RefCell<String>,
    dirty: Cell<bool>,
}

impl Panel {
    pub fn composing(&self) -> bool {
        self.composing.get() || (self.state.borrow().accepted && !self.entries.borrow().is_empty())
    }
    pub fn wrap(view: &gtk::TextView, scroll: &gtk::ScrolledWindow) -> (gtk::Box, Rc<Self>) {
        let row = gtk::DrawingArea::new();
        row.set_focusable(false);
        row.set_visible(false);
        let box_ = gtk::Box::new(gtk::Orientation::Vertical, 0);
        box_.set_hexpand(true);
        box_.append(scroll);
        box_.append(&row);
        let panel = Rc::new(Self {
            view: view.downgrade(),
            scroll: scroll.downgrade(),
            row,
            state: RefCell::new(layout::Epoch::default()),
            connection: RefCell::new(None),
            connecting: RefCell::new(None),
            token: RefCell::new(String::new()),
            retry_at: Cell::new(0),
            entries: RefCell::new(vec![]),
            cursor: Cell::new(-1),
            previous: Cell::new(false),
            next: Cell::new(false),
            requested: Cell::new(0),
            manual: Cell::new(false),
            action_pending: Cell::new(false),
            reserve: Cell::new(false),
            composing: Cell::new(false),
            page: RefCell::new(layout::Page::default()),
            pitch: Cell::new(1.),
            gap: Cell::new(1.),
            render_pending: Cell::new(0),
            empty_since: Cell::new(0),
            metrics: RefCell::new(String::new()),
            dirty: Cell::new(true),
        });
        let weak = Rc::downgrade(&panel);
        panel.row.set_draw_func(move |_, cr, _, _| {
            if let Some(p) = weak.upgrade() {
                p.draw(cr);
                p.render_pending.set(0);
            }
        });
        let click = gtk::GestureClick::new();
        click.set_button(1);
        let weak = Rc::downgrade(&panel);
        click.connect_pressed(move |gesture, _, x, y| {
            if let Some(p) = weak.upgrade() {
                p.click(x, y);
            }
            gesture.set_state(gtk::EventSequenceState::Claimed);
        });
        panel.row.add_controller(click);
        let focus = gtk::EventControllerFocus::new();
        let weak = Rc::downgrade(&panel);
        focus.connect_leave(move |_| {
            if let Some(p) = weak.upgrade() {
                p.release();
            }
        });
        view.add_controller(focus);
        let weak = Rc::downgrade(&panel);
        view.connect_unmap(move |_| {
            if let Some(p) = weak.upgrade() {
                p.release();
            }
        });
        let weak = Rc::downgrade(&panel);
        view.connect_preedit_changed(move |_, text| {
            if let Some(p) = weak.upgrade() {
                p.composing.set(!text.is_empty());
            }
        });
        let weak = Rc::downgrade(&panel);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(p) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            p.tick();
            glib::ControlFlow::Continue
        });
        (box_, panel)
    }

    fn eligible(&self) -> bool {
        self.view.upgrade().is_some_and(|v| {
            v.is_mapped()
                && v.has_focus()
                && v.is_editable()
                && v.root()
                    .and_downcast::<gtk::Window>()
                    .is_some_and(|w| w.is_active())
                && v.width() as f64 >= self.minimum_width(&v)
                && self
                    .scroll
                    .upgrade()
                    .is_some_and(|s| s.height() as f64 >= self.pitch.get() + 12.)
        })
    }

    fn minimum_width(&self, view: &gtk::TextView) -> f64 {
        view.create_pango_layout(Some("1 中…    ‹  ›"))
            .pixel_size()
            .0 as f64
            + (view.left_margin() + view.right_margin()) as f64
    }

    fn programs(&self) -> Vec<String> {
        let mut names = Vec::new();
        if let Some(name) = glib::prgname().filter(|s| !s.is_empty()) {
            names.push(name.to_string());
        }
        if let Some(id) = self
            .view
            .upgrade()
            .and_then(|v| v.root())
            .and_downcast::<gtk::Window>()
            .and_then(|w| w.application())
            .and_then(|app| app.application_id())
        {
            names.push(id.to_string());
        }
        names.sort();
        names.dedup();
        names
    }

    fn tick(self: &Rc<Self>) {
        if !self.eligible() {
            self.release();
            return;
        }
        if self.reserve.get() && self.row.is_mapped() {
            let mut fits = self.row.height() as f64 >= self.pitch.get();
            let mut parent = self.row.parent();
            while let Some(widget) = parent {
                fits &= self.row.compute_bounds(&widget).is_some_and(|r| {
                    r.x() >= -0.5
                        && r.y() >= -0.5
                        && r.x() + r.width() <= widget.width() as f32 + 0.5
                        && r.y() + r.height() <= widget.height() as f32 + 0.5
                });
                parent = widget.parent();
            }
            if !fits {
                self.release();
                return;
            }
        }
        if self.render_pending.get() > 0
            && glib::monotonic_time() - self.render_pending.get() > 1_000_000
        {
            self.release();
            return;
        }
        if self
            .connection
            .borrow()
            .as_ref()
            .is_some_and(|c| c.bus.is_closed())
        {
            self.release();
        }
        self.refresh();
        if self.state.borrow().active
            || self.composing.get()
            || glib::monotonic_time() < self.retry_at.get()
        {
            return;
        }
        OWNER.with(|owner| {
            if let Some(old) = owner
                .borrow()
                .upgrade()
                .filter(|old| !Rc::ptr_eq(old, self))
            {
                old.release();
            }
            *owner.borrow_mut() = Rc::downgrade(self);
        });
        self.acquire();
    }

    fn acquire(self: &Rc<Self>) {
        let Ok(address) = std::env::var("DBUS_SESSION_BUS_ADDRESS") else {
            return;
        };
        if self.programs().is_empty() {
            return;
        }
        let generation = self.state.borrow_mut().reset(true);
        *self.token.borrow_mut() = format!(
            "rapp:{}:{}:{generation}",
            std::process::id(),
            glib::monotonic_time()
        );
        self.retry_at.set(glib::monotonic_time() + 1_500_000);
        let cancel = gio::Cancellable::new();
        *self.connecting.borrow_mut() = Some(cancel.clone());
        let deadline = cancel.clone();
        glib::timeout_add_local_once(Duration::from_secs(1), move || deadline.cancel());
        let weak = Rc::downgrade(self);
        gio::DBusConnection::for_address(
            &address,
            gio::DBusConnectionFlags::AUTHENTICATION_CLIENT
                | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
            None,
            Some(&cancel),
            move |result| {
                let Some(p) = weak.upgrade() else {
                    if let Ok(bus) = result {
                        bus.close(None::<&gio::Cancellable>, |_| {});
                    }
                    return;
                };
                if !p.state.borrow().current(generation) || !p.eligible() {
                    if let Ok(bus) = result {
                        bus.close(None::<&gio::Cancellable>, |_| {});
                    }
                    if p.state.borrow().current(generation) {
                        p.release();
                    }
                    return;
                }
                p.connecting.borrow_mut().take();
                match result {
                    Ok(bus) => p.connected(bus, generation),
                    Err(_) => p.release(),
                }
            },
        );
    }

    fn connected(self: &Rc<Self>, bus: gio::DBusConnection, generation: u64) {
        bus.set_exit_on_close(false);
        let mut subscriptions = Vec::new();
        let weak = Rc::downgrade(self);
        subscriptions.push(bus.subscribe_to_signal(
            Some(SERVICE),
            Some(INTERFACE),
            Some("Candidates"),
            Some(PATH),
            Some(&self.token.borrow()),
            gio::DBusSignalFlags::NONE,
            move |signal| {
                let Some(p) = weak.upgrade() else {
                    return;
                };
                let Some((token, serial, entries, cursor, previous, next)) =
                    signal.parameters.get::<Snapshot>()
                else {
                    p.release();
                    return;
                };
                if token != *p.token.borrow()
                    || !p.eligible()
                    || !p.state.borrow_mut().frame(generation, serial)
                {
                    return;
                }
                if !valid_entries(&entries) {
                    p.release();
                    return;
                }
                *p.entries.borrow_mut() = entries;
                p.cursor.set(cursor);
                p.previous.set(previous);
                p.next.set(next);
                p.manual.set(false);
                p.requested.set(0);
                p.action_pending.set(false);
                p.dirty.set(true);
                p.refresh();
            },
        ));
        let weak = Rc::downgrade(self);
        subscriptions.push(bus.subscribe_to_signal(
            Some(SERVICE),
            Some(INTERFACE),
            Some("Revoked"),
            Some(PATH),
            Some(&self.token.borrow()),
            gio::DBusSignalFlags::NONE,
            move |_| {
                if let Some(p) = weak
                    .upgrade()
                    .filter(|p| p.state.borrow().current(generation))
                {
                    p.release();
                }
            },
        ));
        let weak = Rc::downgrade(self);
        subscriptions.push(bus.subscribe_to_signal(
            Some("org.freedesktop.DBus"),
            Some("org.freedesktop.DBus"),
            Some("NameOwnerChanged"),
            Some("/org/freedesktop/DBus"),
            Some(SERVICE),
            gio::DBusSignalFlags::NONE,
            move |_| {
                if let Some(p) = weak
                    .upgrade()
                    .filter(|p| p.state.borrow().current(generation))
                {
                    p.release();
                }
            },
        ));
        *self.connection.borrow_mut() = Some(Connection {
            bus: bus.clone(),
            _subscriptions: subscriptions,
        });
        let weak = Rc::downgrade(self);
        bus.call(
            Some(SERVICE),
            PATH,
            INTERFACE,
            "SetActive",
            Some(&(self.token.borrow().clone(), self.programs(), true).to_variant()),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            1000,
            None::<&gio::Cancellable>,
            move |reply| {
                let Some(p) = weak
                    .upgrade()
                    .filter(|p| p.state.borrow().current(generation))
                else {
                    return;
                };
                if p.eligible()
                    && reply
                        .ok()
                        .and_then(|r| r.get::<(bool,)>())
                        .is_some_and(|r| r.0)
                {
                    p.state.borrow_mut().accepted = true;
                    p.dirty.set(true);
                    p.refresh();
                } else {
                    p.release();
                }
            },
        );
    }

    fn release(&self) {
        let was_active = self.state.borrow().active;
        self.state.borrow_mut().reset(false);
        if let Some(cancel) = self.connecting.borrow_mut().take() {
            cancel.cancel();
        }
        if let Some(connection) = self.connection.borrow_mut().take() {
            connection.bus.call(
                Some(SERVICE),
                PATH,
                INTERFACE,
                "SetActive",
                Some(&(self.token.borrow().clone(), self.programs(), false).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                1000,
                None::<&gio::Cancellable>,
                |_| {},
            );
            drop(connection);
        }
        self.entries.borrow_mut().clear();
        self.reserve.set(false);
        self.action_pending.set(false);
        self.render_pending.set(0);
        self.empty_since.set(0);
        self.dirty.set(true);
        self.row.set_visible(false);
        if was_active {
            self.retry_at.set(glib::monotonic_time() + 1_500_000);
        }
    }

    fn label(entry: &(i32, String, String)) -> String {
        let label = entry.1.trim_end().trim_end_matches('.');
        let word = entry.2.replace(['\n', '\r'], " ");
        if label.is_empty() {
            word
        } else {
            format!("{label}\u{2009}{word}")
        }
    }

    fn refresh(&self) {
        let Some(view) = self.view.upgrade() else {
            return;
        };
        let entries = self.entries.borrow();
        if !self.state.borrow().accepted {
            return;
        }
        if !entries.is_empty() && !self.reserve.replace(true) {
            self.render_pending.set(glib::monotonic_time());
        }
        if entries.is_empty() && view.buffer().char_count() == 0 && !self.composing.get() {
            // GTK can clear preedit before the corresponding commit arrives.
            if self.empty_since.get() == 0 {
                self.empty_since.set(glib::monotonic_time());
            } else if glib::monotonic_time() - self.empty_since.get() >= 100_000 {
                self.reserve.set(false);
            }
        } else {
            self.empty_since.set(0);
        }
        self.row.set_visible(self.reserve.get());
        let metrics = format!(
            "{}:{:?}:{}:{}:{}:{}:{}",
            view.width(),
            view.pango_context()
                .font_description()
                .map(|font| font.to_string()),
            view.color(),
            view.left_margin(),
            view.right_margin(),
            view.pixels_above_lines(),
            view.pixels_below_lines()
        );
        if !self.dirty.replace(false) && *self.metrics.borrow() == metrics {
            return;
        }
        *self.metrics.borrow_mut() = metrics;
        let pitch = view.create_pango_layout(Some("中Mg")).pixel_size().1 as f64
            + (view.pixels_above_lines() + view.pixels_below_lines()) as f64;
        self.pitch.set(pitch.max(1.));
        self.gap.set((pitch * 0.6).max(1.));
        let selected = if self.manual.get() {
            self.requested.get()
        } else {
            entries
                .iter()
                .position(|e| e.0 == self.cursor.get())
                .unwrap_or(0)
        };
        let widths: Vec<_> = entries
            .iter()
            .map(|e| {
                view.create_pango_layout(Some(&Self::label(e)))
                    .pixel_size()
                    .0 as f64
            })
            .collect();
        *self.page.borrow_mut() = layout::page(
            &widths,
            view.width() as f64 - (view.left_margin() + view.right_margin()) as f64 - pitch * 2.5,
            self.gap.get(),
            selected,
        );
        self.row.set_content_height((pitch + 6.).ceil() as i32);
        self.row.set_visible(self.reserve.get());
        self.row.queue_draw();
    }

    fn draw(&self, cr: &cairo::Context) {
        let Some(view) = self.view.upgrade() else {
            return;
        };
        let color = view.color();
        cr.set_source_rgba(
            color.red() as f64,
            color.green() as f64,
            color.blue() as f64,
            color.alpha() as f64,
        );
        let entries = self.entries.borrow();
        let page = self.page.borrow();
        let mut x = view.left_margin() as f64;
        for (position, width) in (page.start..page.end).zip(&page.widths) {
            let entry = &entries[position];
            let label = Self::label(entry);
            let text = view.create_pango_layout(Some(&label));
            text.set_width((width * pango::SCALE as f64) as i32);
            text.set_ellipsize(pango::EllipsizeMode::End);
            let attrs = pango::AttrList::new();
            let label_end = label
                .find('\u{2009}')
                .map(|i| i + '\u{2009}'.len_utf8())
                .unwrap_or(0) as u32;
            let mut hint = pango::AttrInt::new_foreground_alpha(42598);
            hint.set_end_index(label_end);
            attrs.insert(hint);
            if entry.0 == self.cursor.get() {
                let mut underline = pango::AttrInt::new_underline(pango::Underline::Single);
                underline.set_start_index(label_end);
                attrs.insert(underline);
            }
            text.set_attributes(Some(&attrs));
            cr.move_to(x, (self.pitch.get() - text.pixel_size().1 as f64) / 2.);
            show_layout(cr, &text);
            x += width + self.gap.get();
        }
        if page.start > 0 || page.end < entries.len() || self.previous.get() || self.next.get() {
            let text = view.create_pango_layout(Some("‹  ›"));
            cr.move_to(view.width() as f64 - self.pitch.get() * 2.5, 0.);
            show_layout(cr, &text);
        }
    }

    fn click(self: &Rc<Self>, x: f64, y: f64) {
        if !self.eligible()
            || !self.state.borrow().accepted
            || self.action_pending.get()
            || y < 0.
            || y > self.pitch.get()
        {
            return;
        }
        let Some(view) = self.view.upgrade() else {
            return;
        };
        let page = self.page.borrow();
        let mut left = view.left_margin() as f64;
        for (position, width) in (page.start..page.end).zip(&page.widths) {
            if x >= left && x < left + width {
                self.action(
                    "Select",
                    (
                        self.token.borrow().clone(),
                        self.state.borrow().serial,
                        self.entries.borrow()[position].0,
                    )
                        .to_variant(),
                );
                return;
            }
            left += width + self.gap.get();
        }
        let nav = view.width() as f64 - self.pitch.get() * 2.5;
        if x < nav {
            return;
        }
        let next = x >= nav + self.pitch.get() * 1.25;
        if next && page.end < self.entries.borrow().len() {
            self.requested.set(page.end);
        } else if !next && page.start > 0 {
            self.requested.set(page.start - 1);
        } else {
            if if next {
                self.next.get()
            } else {
                self.previous.get()
            } {
                self.action(
                    "Page",
                    (
                        self.token.borrow().clone(),
                        self.state.borrow().serial,
                        next,
                    )
                        .to_variant(),
                );
            }
            return;
        }
        drop(page);
        self.manual.set(true);
        self.dirty.set(true);
        self.refresh();
    }

    fn action(self: &Rc<Self>, method: &str, arguments: glib::Variant) {
        let Some(connection) = self.connection.borrow().as_ref().map(|c| c.bus.clone()) else {
            return;
        };
        self.action_pending.set(true);
        let generation = self.state.borrow().generation;
        let serial = self.state.borrow().serial;
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_secs(1), move || {
            if let Some(p) = weak
                .upgrade()
                .filter(|p| p.state.borrow().current(generation))
            {
                if p.action_pending.get() && p.state.borrow().serial == serial {
                    p.release();
                }
            }
        });
        let weak = Rc::downgrade(self);
        connection.call(
            Some(SERVICE),
            PATH,
            INTERFACE,
            method,
            Some(&arguments),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            1000,
            None::<&gio::Cancellable>,
            move |reply| {
                if let Some(p) = weak
                    .upgrade()
                    .filter(|p| p.state.borrow().current(generation))
                {
                    if reply.is_err() {
                        p.release();
                    }
                }
            },
        );
    }
}
impl Drop for Panel {
    fn drop(&mut self) {
        self.release();
    }
}

fn valid_entries(entries: &[(i32, String, String)]) -> bool {
    let mut indices = std::collections::HashSet::new();
    entries.len() <= 512
        && entries.iter().all(|(index, label, text)| {
            *index >= 0 && indices.insert(*index) && label.len() <= 32768 && text.len() <= 32768
        })
        && entries
            .iter()
            .map(|(_, label, text)| label.len() + text.len() + 16)
            .sum::<usize>()
            <= 256 * 1024
}

fn show_layout(cr: &cairo::Context, layout: &pango::Layout) {
    use glib::translate::ToGlibPtr;
    unsafe {
        pango_cairo_show_layout(cr.to_raw_none(), layout.to_glib_none().0);
    }
}
#[link(name = "pangocairo-1.0")]
unsafe extern "C" {
    fn pango_cairo_show_layout(cr: *mut cairo::ffi::cairo_t, layout: *mut pango::ffi::PangoLayout);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn snapshot_limits_reject_duplicate_ids_and_oversized_lists_or_text() {
        assert!(valid_entries(&[(17, "1".into(), "你好".into())]));
        assert!(!valid_entries(&[
            (17, "1".into(), "a".into()),
            (17, "2".into(), "b".into())
        ]));
        assert!(!valid_entries(&[(1, String::new(), "x".repeat(32769))]));
        assert!(!valid_entries(
            &(0..513)
                .map(|i| (i, String::new(), "a".into()))
                .collect::<Vec<_>>()
        ));
        assert!(!valid_entries(
            &(0..10)
                .map(|i| (i, String::new(), "x".repeat(32768)))
                .collect::<Vec<_>>()
        ));
    }

    fn until(check: impl Fn() -> bool) {
        let end = Instant::now() + Duration::from_secs(5);
        while !check() {
            assert!(
                Instant::now() < end,
                "isolated GTK/DBus condition timed out"
            );
            while glib::MainContext::default().pending() {
                glib::MainContext::default().iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn settle() {
        let end = Instant::now() + Duration::from_millis(150);
        until(|| Instant::now() > end);
    }

    #[test]
    #[ignore = "requires private dbus-run-session and GTK4 Broadway; never uses the desktop bus"]
    fn isolated_candidates_render_select_release_and_ignore_stale_signal() {
        assert_eq!(
            std::env::var("RAPP_CANDIDATE_TEST_PRIVATE_BUS").as_deref(),
            Ok("1")
        );
        assert_eq!(std::env::var("GDK_BACKEND").as_deref(), Ok("broadway"));
        gtk::init().unwrap();
        glib::set_prgname(Some("rapp-candidates-test"));
        let bus = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>).unwrap();
        let owned = Rc::new(Cell::new(false));
        let o = owned.clone();
        let name = gio::bus_own_name_on_connection(
            &bus,
            SERVICE,
            gio::BusNameOwnerFlags::NONE,
            move |_, _| o.set(true),
            |_, _| {},
        );
        until(|| owned.get());
        let info = gio::DBusNodeInfo::for_xml(r#"<node><interface name="org.fcitx.Fcitx.SumiCandidates1">
            <method name="SetActive"><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="b" direction="in"/><arg type="b" direction="out"/></method>
            <method name="Select"><arg type="s" direction="in"/><arg type="t" direction="in"/><arg type="i" direction="in"/></method>
            <method name="Page"><arg type="s" direction="in"/><arg type="t" direction="in"/><arg type="b" direction="in"/></method>
            <signal name="Candidates"><arg type="s"/><arg type="t"/><arg type="a(iss)"/><arg type="i"/><arg type="b"/><arg type="b"/></signal>
            <signal name="Revoked"><arg type="s"/></signal>
        </interface></node>"#).unwrap();
        let owner = Rc::new(RefCell::new(None::<(String, String)>));
        let selected = Rc::new(RefCell::new(None));
        let owner_call = owner.clone();
        let selected_call = selected.clone();
        let registration = bus
            .register_object(PATH, &info.interfaces()[0])
            .method_call(move |_, sender, _, _, method, args, invocation| {
                eprintln!("private mock method {method}");
                match method {
                    "SetActive" => {
                        let (token, programs, active) =
                            args.get::<(String, Vec<String>, bool)>().unwrap();
                        assert!(!programs.is_empty());
                        if active {
                            *owner_call.borrow_mut() = Some((sender.unwrap().to_string(), token));
                        }
                        invocation.return_value(Some(&(true,).to_variant()));
                    }
                    "Select" => {
                        *selected_call.borrow_mut() = args.get::<(String, u64, i32)>();
                        invocation.return_value(None);
                    }
                    _ => invocation.return_value(None),
                }
            })
            .build()
            .unwrap();
        let window = gtk::Window::builder()
            .default_width(480)
            .default_height(180)
            .build();
        let view = gtk::TextView::new();
        view.buffer().set_text("unchanged draft");
        let scroll = gtk::ScrolledWindow::builder()
            .min_content_height(70)
            .child(&view)
            .build();
        let (box_, panel) = Panel::wrap(&view, &scroll);
        let sibling = gtk::Entry::new();
        box_.append(&sibling);
        window.set_child(Some(&box_));
        window.present();
        view.grab_focus();
        settle();
        eprintln!(
            "private window: active={} mapped={} focus={} size={}x{}, scroll={} eligible={}",
            window.is_active(),
            view.is_mapped(),
            view.has_focus(),
            view.width(),
            view.height(),
            scroll.height(),
            panel.eligible()
        );
        until(|| panel.state.borrow().accepted);
        eprintln!("private lease accepted");
        let (destination, token) = owner.borrow().clone().unwrap();
        let emit = |serial: u64, text: &str| {
            let entries = vec![(23i32, "2.".to_string(), text.to_string())];
            bus.emit_signal(
                Some(&destination),
                PATH,
                INTERFACE,
                "Candidates",
                Some(&(token.clone(), serial, entries, 23i32, false, false).to_variant()),
            )
            .unwrap();
        };
        emit(1, "你好");
        settle();
        eprintln!("private row: active={} accepted={} serial={} mapped={} render_pending={} entries={} bounds={:?}", panel.state.borrow().active, panel.state.borrow().accepted, panel.state.borrow().serial, panel.row.is_mapped(), panel.render_pending.get(), panel.entries.borrow().len(), panel.row.compute_bounds(&window));
        until(|| {
            panel.row.is_mapped()
                && panel.state.borrow().serial == 1
                && panel.render_pending.get() == 0
        });
        assert_eq!(panel.page.borrow().end, 1);
        // Exercise the same transparent Pango painter as the actual mapped row.
        let mut image = cairo::ImageSurface::create(cairo::Format::ARgb32, 480, 80).unwrap();
        {
            let cr = cairo::Context::new(&image).unwrap();
            panel.draw(&cr);
        }
        assert!(image
            .data()
            .unwrap()
            .iter()
            .skip(3)
            .step_by(4)
            .any(|a| *a != 0));
        assert!(image
            .data()
            .unwrap()
            .iter()
            .skip(3)
            .step_by(4)
            .any(|a| *a == 0));
        let controllers = panel.row.observe_controllers();
        let click = (0..controllers.n_items())
            .find_map(|i| controllers.item(i).and_downcast::<gtk::GestureClick>())
            .unwrap();
        click.emit_by_name::<()>("pressed", &[&1i32, &5f64, &5f64]);
        until(|| selected.borrow().is_some());
        assert_eq!(*selected.borrow(), Some((token.clone(), 1, 23)));
        assert_eq!(
            view.buffer().text(
                &view.buffer().start_iter(),
                &view.buffer().end_iter(),
                false
            ),
            "unchanged draft"
        );
        emit(1, "stale");
        settle();
        assert_eq!(panel.entries.borrow()[0].2, "你好");
        // Empty candidate snapshots retain the already allocated row while the
        // shared draft is nonempty, without moving its text viewport or selection.
        let allocation = scroll.compute_bounds(&window);
        bus.emit_signal(
            Some(&destination),
            PATH,
            INTERFACE,
            "Candidates",
            Some(
                &(
                    token.clone(),
                    2u64,
                    Vec::<(i32, String, String)>::new(),
                    -1i32,
                    false,
                    false,
                )
                    .to_variant(),
            ),
        )
        .unwrap();
        until(|| panel.state.borrow().serial == 2);
        settle();
        assert!(panel.reserve.get());
        assert!(panel.row.is_mapped());
        assert_eq!(scroll.compute_bounds(&window), allocation);
        sibling.grab_focus();
        until(|| !panel.state.borrow().active && !panel.row.is_visible());
        emit(3, "after focus left");
        settle();
        assert!(panel.entries.borrow().is_empty());
        assert!(!panel.reserve.get());
        until(|| {
            bus.call_sync(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "NameHasOwner",
                Some(&(destination.clone(),).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                1000,
                None::<&gio::Cancellable>,
            )
            .unwrap()
            .get::<(bool,)>()
                == Some((false,))
        });
        view.grab_focus();
        until(|| panel.state.borrow().accepted);
        assert_ne!(panel.token.borrow().as_str(), token);
        // Losing the service must release this generation, not leave an empty
        // custom panel owning the input engine's presentation callback.
        gio::bus_unown_name(name);
        until(|| !panel.state.borrow().active);
        assert!(!panel.reserve.get());
        window.close();
        drop(panel);
        settle();
        bus.unregister_object(registration).unwrap();
    }
}
