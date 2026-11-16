//! Native multiline composer and typed clipboard bridge (GTK4 / Wayland / X11).
use gtk::{gdk, gio, glib, prelude::*};
use rapp_client_core::transfer::{Copy, MEMORY_LIMIT};
use std::{
    cell::{Cell, RefCell},
    ops::Deref,
    path::PathBuf,
    rc::Rc,
};
type Activate = Box<dyn Fn(&Editor)>;
#[derive(Clone)]
pub struct Editor(Rc<Inner>);
struct Inner {
    view: gtk::TextView,
    pub chips: gtk::Box,
    extra_chips: RefCell<Vec<glib::WeakRef<gtk::Box>>>,
    error: gtk::Label,
    blocks: RefCell<Vec<(u32, Copy)>>,
    next: Cell<u32>,
    activate: RefCell<Vec<Activate>>,
    preedit: Rc<Cell<bool>>,
}
impl Deref for Editor {
    type Target = gtk::TextView;
    fn deref(&self) -> &Self::Target {
        &self.0.view
    }
}
impl Editor {
    pub fn new() -> Self {
        let view = gtk::TextView::new();
        view.set_wrap_mode(gtk::WrapMode::WordChar);
        view.set_top_margin(6);
        view.set_bottom_margin(6);
        view.set_height_request(60);
        let preedit = Rc::new(Cell::new(false));
        let active = preedit.clone();
        view.connect_preedit_changed(move |_, s| active.set(!s.is_empty()));
        let e = Self(Rc::new(Inner {
            view,
            chips: gtk::Box::new(gtk::Orientation::Horizontal, 4),
            extra_chips: RefCell::new(vec![]),
            error: gtk::Label::new(None),
            blocks: RefCell::new(vec![]),
            next: Cell::new(0x80000000),
            activate: RefCell::new(vec![]),
            preedit,
        }));
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&e.0);
        keys.connect_key_pressed(move |_, key, _, mods| {
            if let Some(inner) = weak.upgrade() {
                let e = Editor(inner);
                if !e.0.preedit.get()
                    && matches!(key, gdk::Key::Return | gdk::Key::KP_Enter)
                    && !mods.contains(gdk::ModifierType::SHIFT_MASK)
                {
                    e.emit_activate();
                    return glib::Propagation::Stop;
                }
            }
            glib::Propagation::Proceed
        });
        e.add_controller(keys);
        let weak = Rc::downgrade(&e.0);
        e.connect_paste_clipboard(move |view| {
            view.stop_signal_emission_by_name("paste-clipboard");
            if let Some(e) = weak.upgrade() {
                Editor(e).paste();
            }
        });
        let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
        let weak = Rc::downgrade(&e.0);
        drop.connect_drop(move |_, value, _, _| {
            if let (Some(e), Ok(files)) = (weak.upgrade(), value.get::<gdk::FileList>()) {
                Editor(e).insert(Copy::Files(
                    files.files().iter().filter_map(|f| f.path()).collect(),
                ));
                true
            } else {
                false
            }
        });
        e.add_controller(drop);
        e
    }
    pub fn text(&self) -> glib::GString {
        let b = self.buffer();
        b.text(&b.start_iter(), &b.end_iter(), false)
    }
    pub fn set_text(&self, s: &str) {
        self.buffer().set_text(s);
    }
    pub fn connect_activate(&self, f: impl Fn(&Editor) + 'static) {
        self.0.activate.borrow_mut().push(Box::new(f));
    }
    pub fn emit_activate(&self) {
        for f in self.0.activate.borrow().iter() {
            f(self);
        }
    }
    pub fn connect_changed(&self, f: impl Fn(&Editor) + 'static) {
        let weak = Rc::downgrade(&self.0);
        self.buffer().connect_changed(move |_| {
            if let Some(e) = weak.upgrade() {
                f(&Editor(e));
            }
        });
    }
    pub fn preedit(&self) -> Rc<Cell<bool>> {
        self.0.preedit.clone()
    }
    pub fn chips(&self) -> gtk::Box {
        self.0.chips.clone()
    }
    pub fn snapshot(&self) -> std::collections::VecDeque<(Option<u32>, Copy)> {
        let mut pieces: std::collections::VecDeque<_> = self
            .0
            .blocks
            .borrow()
            .iter()
            .map(|(id, c)| (Some(*id), c.clone()))
            .collect();
        let text = self.text().to_string();
        if !text.is_empty() {
            pieces.push_back((None, Copy::Text(text)));
        }
        pieces
    }
    pub fn has_content(&self) -> bool {
        !self.text().is_empty() || !self.0.blocks.borrow().is_empty()
    }
    pub fn remove(&self, id: u32) {
        self.0.blocks.borrow_mut().retain(|(n, _)| *n != id);
        self.refresh();
    }
    pub fn set_error(&self, message: &str) {
        self.0.error.set_text(message);
        self.0.error.set_visible(!message.is_empty());
    }
    pub fn error_label(&self) -> gtk::Label {
        self.0.error.clone()
    }
    pub fn new_chips(&self) -> gtk::Box {
        let chips = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        self.0.extra_chips.borrow_mut().push(chips.downgrade());
        self.refresh();
        chips
    }
    fn refresh(&self) {
        self.0
            .extra_chips
            .borrow_mut()
            .retain(|w| w.upgrade().is_some());
        let mut boxes = vec![self.0.chips.clone()];
        boxes.extend(
            self.0
                .extra_chips
                .borrow()
                .iter()
                .filter_map(|w| w.upgrade()),
        );
        for chips in boxes {
            while let Some(c) = chips.first_child() {
                chips.remove(&c);
            }

            for (id, copy) in self.0.blocks.borrow().iter() {
                let label = match copy {
                    Copy::Text(t) => format!("文字 · {} 行", t.lines().count()),
                    Copy::Image(_) => "图片".into(),
                    Copy::Data(u, _) => format!("数据 {u}"),
                    Copy::Files(p) => p[0]
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned(),
                };
                let button = gtk::Button::with_label(&format!("{label} ×"));
                let weak = Rc::downgrade(&self.0);
                let id = *id;
                button.connect_clicked(move |_| {
                    if let Some(e) = weak.upgrade() {
                        Editor(e).remove(id);
                    }
                });
                chips.append(&button);
            }
        }
    }
    pub fn insert(&self, copy: Copy) {
        self.set_error("");
        if let Copy::Text(t) = &copy {
            if t.chars().count() < 800 && t.split('\n').count() < 10 {
                self.buffer().insert_at_cursor(t);
                return;
            }
        }
        let copies = match copy {
            Copy::Files(paths) => {
                if paths.iter().any(|p| !p.is_file()) {
                    self.set_error("只支持普通文件，文件夹或不存在的文件未添加");
                }
                paths
                    .into_iter()
                    .filter(|p| p.is_file())
                    .map(|p| Copy::Files(vec![p]))
                    .collect()
            }
            other => vec![other],
        };
        for c in copies {
            let n = self.0.next.get();
            if n == u32::MAX {
                return;
            }
            self.0.next.set(n + 1);
            self.0.blocks.borrow_mut().push((n, c));
        }
        self.refresh();
    }
    pub fn attach(&self, window: &gtk::ApplicationWindow) {
        let e = self.clone();
        let w = window.clone();
        glib::spawn_future_local(async move {
            if let Ok(files) = gtk::FileDialog::builder()
                .title("添加附件")
                .build()
                .open_multiple_future(Some(&w))
                .await
            {
                let paths = files
                    .iter::<gio::File>()
                    .filter_map(|f| f.ok()?.path())
                    .collect();
                e.insert(Copy::Files(paths));
            }
        });
    }
    pub fn paste(&self) {
        let e = self.clone();
        let cb = self.display().clipboard();
        glib::spawn_future_local(async move {
            match read_clipboard(&cb).await {
                Ok(copy) => e.insert(copy),
                Err(error) => e.set_error(&format!("粘贴没成功：{error}")),
            }
        });
    }
}
pub fn mime(uti: &str) -> &str {
    match uti {
        "public.png" => "image/png",
        "public.tiff" => "image/tiff",
        "com.adobe.pdf" => "application/pdf",
        "public.html" => "text/html",
        "public.rtf" => "text/rtf",
        other => other,
    }
}
fn uti(mime: &str) -> &str {
    match mime {
        "image/png" => "public.png",
        "image/tiff" => "public.tiff",
        "application/pdf" => "com.adobe.pdf",
        "text/html" => "public.html",
        "text/rtf" => "public.rtf",
        other => other,
    }
}
pub fn write_clipboard(cb: &gdk::Clipboard, copy: &Copy) -> anyhow::Result<()> {
    match copy {
        Copy::Text(t) => cb.set_text(t),
        Copy::Files(paths) => {
            anyhow::ensure!(paths.iter().all(|p| p.is_file()), "文件已不存在");
            let files: Vec<_> = paths.iter().map(gio::File::for_path).collect();
            cb.set_content(Some(&gdk::ContentProvider::for_value(
                &gdk::FileList::from_array(&files).to_value(),
            )))?;
        }
        Copy::Image(b) => {
            cb.set_content(Some(&gdk::ContentProvider::for_bytes(
                "image/png",
                &glib::Bytes::from_owned(b.clone()),
            )))?;
        }
        Copy::Data(u, b) => {
            cb.set_content(Some(&gdk::ContentProvider::for_bytes(
                mime(u),
                &glib::Bytes::from_owned(b.clone()),
            )))?;
        }
    }
    Ok(())
}
async fn read_clipboard(cb: &gdk::Clipboard) -> anyhow::Result<Copy> {
    let formats = cb.formats();
    if formats.contains_type(gdk::FileList::static_type()) {
        let v = cb
            .read_value_future(gdk::FileList::static_type(), glib::Priority::DEFAULT)
            .await?;
        let files = v.get::<gdk::FileList>()?;
        return Ok(Copy::Files(
            files
                .files()
                .iter()
                .filter_map(|f| f.path())
                .collect::<Vec<PathBuf>>(),
        ));
    }
    if formats.contains_type(gdk::Texture::static_type()) || formats.contain_mime_type("image/png")
    {
        if let Some(texture) = cb.read_texture_future().await? {
            let bytes = texture.save_to_png_bytes();
            anyhow::ensure!(bytes.len() as u64 <= MEMORY_LIMIT, "图片超过 256 MB");
            return Ok(Copy::Image(bytes.as_ref().to_vec()));
        }
    }
    if let Ok(Some(t)) = cb.read_text_future().await {
        anyhow::ensure!(t.len() as u64 <= MEMORY_LIMIT, "文字超过 256 MB");
        return Ok(Copy::Text(t.into()));
    }
    let types = formats.mime_types();
    let name = types.first().ok_or_else(|| anyhow::anyhow!("剪贴板为空"))?;
    let (stream, kind) = cb
        .read_future(&[name.as_str()], glib::Priority::DEFAULT)
        .await?;
    let mut data = vec![];
    loop {
        let bytes = stream
            .read_bytes_future(256 * 1024, glib::Priority::DEFAULT)
            .await?;
        if bytes.is_empty() {
            break;
        }
        anyhow::ensure!(
            data.len() as u64 + bytes.len() as u64 <= MEMORY_LIMIT,
            "数据超过 256 MB"
        );
        data.extend_from_slice(&bytes);
    }
    Ok(Copy::Data(uti(kind.as_str()).into(), data))
}
