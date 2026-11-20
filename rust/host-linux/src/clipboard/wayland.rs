use super::*;
use std::{
    collections::HashMap,
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsFd, AsRawFd},
        unix::net::UnixStream,
    },
    time::Instant,
};
use wayland_client::{
    delegate_noop,
    protocol::{wl_registry, wl_seat},
    Connection, Dispatch, Proxy, QueueHandle,
};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1::{self, ZwlrDataControlDeviceV1 as Device},
    zwlr_data_control_manager_v1::ZwlrDataControlManagerV1 as Manager,
    zwlr_data_control_offer_v1::{self, ZwlrDataControlOfferV1 as Offer},
    zwlr_data_control_source_v1::{self, ZwlrDataControlSourceV1 as Source},
};
#[derive(Default)]
struct State {
    manager: Option<Manager>,
    seat: Option<wl_seat::WlSeat>,
    offers: HashMap<wayland_client::backend::ObjectId, (Offer, Vec<String>)>,
    selection: Option<Offer>,
    changed: bool,
    source: Option<Source>,
    data: Data,
}
pub(super) fn run(
    commands: mpsc::Receiver<Command>,
    events: mpsc::SyncSender<Copy>,
    mut scope: Scope,
) -> Result<()> {
    let conn = Connection::connect_to_env()?;
    let mut queue = conn.new_event_queue();
    let q = queue.handle();
    let mut state = State::default();
    conn.display().get_registry(&q, ());
    queue.roundtrip(&mut state)?;
    let device = state
        .manager
        .as_ref()
        .context("compositor does not expose clipboard data control")?
        .get_data_device(state.seat.as_ref().context("no Wayland seat")?, &q, ());
    queue.roundtrip(&mut state)?;
    state.changed = false;
    ready()?;
    let mut saved: Option<(Data, Instant)> = None;
    loop {
        queue.dispatch_pending(&mut state)?;
        match commands.try_recv() {
            Ok(Command::Set(data, reply)) => {
                let result = (|| -> Result<()> {
                    ensure!(scope.active(), "target not frontmost");
                    if saved.is_none() {
                        saved = Some((snapshot(&conn, &state)?, Instant::now()));
                    }
                    write(&conn, &q, &mut state, &device, data)?;
                    saved.as_mut().unwrap().1 = Instant::now();
                    Ok(())
                })();
                let _ = reply.send(result);
            }
            Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        if state.changed {
            state.changed = false;
            if state.source.is_none() {
                saved = None;
                let snapshot = if scope.allow_copy() {
                    snapshot(&conn, &state)
                } else {
                    Err(anyhow::anyhow!("target not frontmost"))
                };
                if let Ok(data) = snapshot {
                    let types: Vec<_> = data.iter().map(|(k, _)| k.clone()).collect();
                    if let Some(kind) = preferred(&types).filter(|_| scope.active()) {
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
            if state.source.is_some() {
                write(&conn, &q, &mut state, &device, saved.take().unwrap().0)?;
            } else {
                saved = None;
            }
        }
        conn.flush()?;
        scope.poll();
        if let Some(read) = queue.prepare_read() {
            let mut fd = libc::pollfd {
                fd: conn.as_fd().as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: one live connection fd, no other reader owns this event queue.
            if unsafe { libc::poll(&mut fd, 1, 20) } > 0 {
                read.read()?;
            }
        }
    }
    if state.source.is_some() {
        if let Some((data, _)) = saved {
            write(&conn, &q, &mut state, &device, data)?;
        }
        // Give a running clipboard manager a chance to retain restored data.
        let end = Instant::now() + Duration::from_millis(200);
        while Instant::now() < end {
            queue.dispatch_pending(&mut state)?;
            conn.flush()?;
            if let Some(read) = queue.prepare_read() {
                let mut fd = libc::pollfd {
                    fd: conn.as_fd().as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                if unsafe { libc::poll(&mut fd, 1, 20) } > 0 {
                    read.read()?;
                }
            }
        }
    }
    Ok(())
}
fn snapshot(conn: &Connection, state: &State) -> Result<Data> {
    let Some(offer) = &state.selection else {
        return Ok(vec![]);
    };
    let types = &state
        .offers
        .get(&offer.id())
        .context("clipboard changed")?
        .1;
    ensure!(!concealed(types), "clipboard contains concealed data");
    let end = Instant::now() + Duration::from_secs(3);
    let mut total = 0;
    let mut data = vec![];
    for kind in types.iter().take(32) {
        let (mut reader, writer) = UnixStream::pair()?;
        offer.receive(kind.clone(), writer.as_fd());
        conn.flush()?;
        drop(writer);
        let mut bytes = vec![];
        let mut buffer = [0; 65536];
        loop {
            let remaining = end.saturating_duration_since(Instant::now());
            ensure!(!remaining.is_zero(), "clipboard read timed out");
            reader.set_read_timeout(Some(remaining))?;
            let n = reader.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            total += n;
            ensure!(total <= LIMIT, "clipboard exceeds 64 MB");
            bytes.extend_from_slice(&buffer[..n]);
        }
        data.push((kind.clone(), bytes));
    }
    Ok(data)
}
fn write(
    conn: &Connection,
    q: &QueueHandle<State>,
    state: &mut State,
    device: &Device,
    data: Data,
) -> Result<()> {
    let source = state.manager.as_ref().unwrap().create_data_source(q, ());
    for (kind, _) in &data {
        source.offer(kind.clone());
    }
    if let Some(old) = state.source.take() {
        old.destroy();
    }
    state.data = data;
    device.set_selection(Some(&source));
    state.source = Some(source);
    state.changed = false;
    conn.flush()?;
    Ok(())
}
impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        s: &mut Self,
        r: &wl_registry::WlRegistry,
        e: wl_registry::Event,
        _: &(),
        _: &Connection,
        q: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = e
        {
            match interface.as_str() {
                "zwlr_data_control_manager_v1" => {
                    s.manager = Some(r.bind(name, version.min(2), q, ()))
                }
                "wl_seat" if s.seat.is_none() => s.seat = Some(r.bind(name, 1, q, ())),
                _ => {}
            }
        }
    }
}
impl Dispatch<Device, ()> for State {
    fn event(
        s: &mut Self,
        _: &Device,
        e: zwlr_data_control_device_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match e {
            zwlr_data_control_device_v1::Event::DataOffer { id } => {
                s.offers.insert(id.id(), (id, vec![]));
            }
            zwlr_data_control_device_v1::Event::Selection { id } => {
                if let Some(old) = s.selection.take() {
                    if let Some((old, _)) = s.offers.remove(&old.id()) {
                        old.destroy();
                    }
                }
                s.selection = id;
                s.changed = true;
            }
            zwlr_data_control_device_v1::Event::PrimarySelection { id: Some(id) } => {
                s.offers.remove(&id.id());
                id.destroy();
            }
            _ => {}
        }
    }
    wayland_client::event_created_child!(State, Device, [0 => (Offer, ())]);
}
impl Dispatch<Offer, ()> for State {
    fn event(
        s: &mut Self,
        offer: &Offer,
        e: zwlr_data_control_offer_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zwlr_data_control_offer_v1::Event::Offer { mime_type } = e {
            if let Some((_, types)) = s.offers.get_mut(&offer.id()) {
                if types.len() < 128 {
                    types.push(mime_type);
                }
            }
        }
    }
}
impl Dispatch<Source, ()> for State {
    fn event(
        s: &mut Self,
        source: &Source,
        e: zwlr_data_control_source_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match e {
            zwlr_data_control_source_v1::Event::Cancelled => {
                if s.source.as_ref() == Some(source) {
                    s.source = None;
                    s.data.clear();
                }
                source.destroy();
            }
            zwlr_data_control_source_v1::Event::Send { mime_type, fd } => {
                if s.source.as_ref() != Some(source) {
                    return;
                }
                if let Some((_, data)) = s.data.iter().find(|(k, _)| k == &mime_type) {
                    // A peer that stops reading must not wedge clipboard ownership forever.
                    let mut file = File::from(fd);
                    let raw = file.as_raw_fd();
                    unsafe {
                        let flags = libc::fcntl(raw, libc::F_GETFL);
                        libc::fcntl(raw, libc::F_SETFL, flags | libc::O_NONBLOCK);
                    }
                    let end = Instant::now() + Duration::from_secs(3);
                    let mut offset = 0;
                    while offset < data.len() && Instant::now() < end {
                        match file.write(&data[offset..]) {
                            Ok(0) => break,
                            Ok(n) => offset += n,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                let mut p = libc::pollfd {
                                    fd: raw,
                                    events: libc::POLLOUT,
                                    revents: 0,
                                };
                                unsafe {
                                    libc::poll(&mut p, 1, 20);
                                }
                            }
                            Err(_) => break,
                        }
                    }
                }
            }
            _ => {}
        }
    }
}
delegate_noop!(State: ignore wl_seat::WlSeat);
delegate_noop!(State: ignore Manager);
