use super::*;
use gdk::glib;
use std::{cell::Cell, rc::Rc, time::Instant};

pub(super) fn run(
    commands: mpsc::Receiver<Command>,
    events: mpsc::SyncSender<Copy>,
    mut scope: Scope,
) -> Result<()> {
    let context = glib::MainContext::default();
    context.with_thread_default(|| -> Result<()> {
        let display = gdk::Display::open(std::env::var("DISPLAY").ok().as_deref())
            .context("cannot open X11 clipboard")?;
        let cb = display.clipboard();
        let guard = Targets::new()?;
        let changed = Rc::new(Cell::new(false));
        let flag = changed.clone();
        cb.connect_changed(move |cb| {
            if !cb.is_local() {
                flag.set(true);
            }
        });
        ready()?;
        let mut saved: Option<(Data, Instant)> = None;
        let mut last = None;
        while let Ok(()) = (|| -> std::result::Result<(), mpsc::TryRecvError> {
            while context.pending() {
                context.iteration(false);
            }
            match commands.try_recv() {
                Ok(Command::Set(data, reply)) => {
                    let result = (|| -> Result<()> {
                        ensure!(scope.active(), "target not frontmost");
                        if saved.is_none() {
                            guard.check(&context)?;
                            saved = Some((
                                context.block_on(glib::future_with_timeout(
                                    Duration::from_secs(3),
                                    snapshot(&cb),
                                ))??,
                                Instant::now(),
                            ));
                        }
                        write(&cb, &data)?;
                        saved.as_mut().unwrap().1 = Instant::now();
                        changed.set(false);
                        Ok(())
                    })();
                    let _ = reply.send(result);
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    return Err(mpsc::TryRecvError::Disconnected)
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
            if changed.replace(false) {
                saved = None;
                if scope.allow_copy() && guard.check(&context).is_ok() {
                    if let Ok(Ok(data)) = context.block_on(glib::future_with_timeout(
                        Duration::from_secs(3),
                        snapshot(&cb),
                    )) {
                        if last.as_ref() == Some(&data)
                            || cb.is_local()
                            || changed.get()
                            || !scope.active()
                            || guard.check(&context).is_err()
                        {
                            return Ok(());
                        }
                        last = Some(data.clone());
                        let types: Vec<_> = data.iter().map(|(k, _)| k.clone()).collect();
                        if let Some(kind) = preferred(&types) {
                            if let Some((_, bytes)) = data.iter().find(|(k, _)| k == kind) {
                                if let Ok(copy) = decode(kind, bytes.clone()) {
                                    let _ = events.try_send(copy);
                                }
                            }
                        }
                    }
                }
            }
            if saved
                .as_ref()
                .is_some_and(|(_, t)| t.elapsed() >= Duration::from_secs(2))
            {
                if cb.is_local() {
                    let _ = write(&cb, &saved.take().unwrap().0);
                } else {
                    saved = None;
                }
            }
            std::thread::sleep(Duration::from_millis(20));
            scope.poll();
            Ok(())
        })() {}
        if cb.is_local() {
            if let Some((data, _)) = saved {
                let _ = write(&cb, &data);
            }
        }
        // Let the desktop's clipboard manager retain the restored content on exit.
        let _ = context.block_on(glib::future_with_timeout(
            Duration::from_millis(200),
            cb.store_future(glib::Priority::DEFAULT),
        ));
        display.close();
        Ok(())
    })?
}

// GDK only exposes MIME formats. Password-manager X11 marker atoms are not
// necessarily MIME names, so inspect the native TARGETS before reading data.
struct Targets {
    conn: x11rb::rust_connection::RustConnection,
    window: u32,
    clipboard: u32,
    targets: u32,
    property: u32,
}
impl Targets {
    fn new() -> Result<Self> {
        use x11rb::{
            connection::Connection,
            protocol::xproto::{self, ConnectionExt},
        };
        let (conn, screen) = x11rb::connect(None)?;
        let window = conn.generate_id()?;
        conn.create_window(
            0,
            window,
            conn.setup().roots[screen].root,
            0,
            0,
            1,
            1,
            0,
            xproto::WindowClass::INPUT_ONLY,
            0,
            &xproto::CreateWindowAux::default(),
        )?
        .check()?;
        let atom =
            |name: &[u8]| -> Result<u32> { Ok(conn.intern_atom(false, name)?.reply()?.atom) };
        let (clipboard, targets, property) = (
            atom(b"CLIPBOARD")?,
            atom(b"TARGETS")?,
            atom(b"RAPP_CLIPBOARD_TARGETS")?,
        );
        Ok(Self {
            conn,
            window,
            clipboard,
            targets,
            property,
        })
    }
    fn check(&self, context: &glib::MainContext) -> Result<()> {
        use x11rb::{
            connection::Connection,
            protocol::{
                xproto::{AtomEnum, ConnectionExt},
                Event,
            },
        };
        if self
            .conn
            .get_selection_owner(self.clipboard)?
            .reply()?
            .owner
            == 0
        {
            return Ok(());
        }
        self.conn.convert_selection(
            self.window,
            self.clipboard,
            self.targets,
            self.property,
            0u32,
        )?;
        self.conn.flush()?;
        let end = Instant::now() + Duration::from_secs(1);
        loop {
            while context.pending() {
                context.iteration(false);
            }
            if let Some(Event::SelectionNotify(e)) = self.conn.poll_for_event()? {
                ensure!(e.property != 0, "clipboard formats unavailable");
                let value = self
                    .conn
                    .get_property(true, self.window, self.property, AtomEnum::ATOM, 0, 1024)?
                    .reply()?;
                let mut names = vec![];
                for atom in value.value32().context("invalid clipboard formats")? {
                    names.push(
                        String::from_utf8_lossy(&self.conn.get_atom_name(atom)?.reply()?.name)
                            .into_owned(),
                    );
                }
                ensure!(!concealed(&names), "clipboard contains concealed data");
                return Ok(());
            }
            ensure!(Instant::now() < end, "clipboard formats timed out");
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}
fn write(cb: &gdk::Clipboard, data: &Data) -> Result<()> {
    let providers: Vec<_> = data
        .iter()
        .map(|(k, b)| gdk::ContentProvider::for_bytes(k, &glib::Bytes::from_owned(b.clone())))
        .collect();
    if providers.is_empty() {
        cb.set_content(None::<&gdk::ContentProvider>)?;
    } else {
        cb.set_content(Some(&gdk::ContentProvider::new_union(&providers)))?;
    }
    Ok(())
}
async fn snapshot(cb: &gdk::Clipboard) -> Result<Data> {
    let types: Vec<_> = cb
        .formats()
        .mime_types()
        .iter()
        .map(|t| t.to_string())
        .collect();
    ensure!(!concealed(&types), "clipboard contains concealed data");
    let mut data = vec![];
    let mut total = 0;
    for kind in types
        .iter()
        .filter(|t| t.contains('/') || t.as_str() == "UTF8_STRING")
        .take(32)
    {
        let (stream, _) = cb
            .read_future(&[kind.as_str()], glib::Priority::DEFAULT)
            .await?;
        let mut bytes = vec![];
        loop {
            let b = stream
                .read_bytes_future(256 * 1024, glib::Priority::DEFAULT)
                .await?;
            if b.is_empty() {
                break;
            }
            total += b.len();
            ensure!(total <= LIMIT, "clipboard exceeds 64 MB");
            bytes.extend_from_slice(&b);
        }
        data.push((kind.clone(), bytes));
    }
    Ok(data)
}
