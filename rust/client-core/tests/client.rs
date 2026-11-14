use flate2::{Compress, Compression, FlushCompress};
use rapp_client_core::{
    codec::{bgra, Decoder},
    geometry::*,
    protocol::*,
};
fn compress(z: &mut Compress, data: &[u8]) -> Vec<u8> {
    let mut output = vec![0; data.len() * 2 + 1024];
    let start = z.total_out();
    z.compress(data, &mut output, FlushCompress::Sync).unwrap();
    output.truncate((z.total_out() - start) as usize);
    output
}
fn z() -> Compress {
    Compress::new(Compression::default(), true)
}
#[test]
fn hello_matches_swift_wire_layout() {
    let a = Address::parse(
        "rapp://localhost:1234/com.example.App?token=abc&mode=color16&fps=5",
        None,
    )
    .unwrap();
    let mut expected = vec![9, 3, 0, b'a', b'b', b'c', 15, 0];
    expected.extend(b"com.example.App");
    expected.extend([2, 5, 0, 0, 128, 63]);
    assert_eq!(a.hello(1.), packet(1, expected));
    assert_eq!(
        key(8, 1 << 20, true),
        vec![6, 11, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0, 0, 0, 1]
    );
}
#[test]
fn address_validation_and_token_precedence() {
    let a = Address::parse("rapp://[::1]/?mode=duogray", Some("secret".into())).unwrap();
    assert_eq!(a.host, "::1");
    assert_eq!(a.token, "secret");
    assert_eq!(a.mode, 3);
    assert_eq!(
        Address::parse("rapp://a/?token=url", Some("env".into()))
            .unwrap()
            .token,
        "url"
    );
    for u in [
        "https://a/?token=a",
        "rapp://a/",
        "rapp://a/?token=a&fps=9",
        "rapp://a/?token=a&mode=bad",
        "rapp://a/a%2Fb?token=a",
        "rapp://a:0/?token=a",
    ] {
        assert!(Address::parse(u, None).is_err(), "{u}");
    }
}
#[test]
fn full_delta_dictionary_and_mode_reset() {
    let mut d = Decoder::default();
    let mut z = z();
    let full = compress(&mut z, &[1, 0, 0, 0, 0, 0, 248]);
    assert_eq!(
        d.decode(2, 3, 2, 7, 0, 0, &full).unwrap().unwrap(),
        [0, 0, 255, 255].repeat(6)
    );
    let delta = compress(&mut z, &[1, 0, 0, 0, 0, 224, 7]);
    assert_eq!(
        d.decode(2, 3, 2, 6, 0, 0, &delta).unwrap().unwrap(),
        [0, 255, 0, 255].repeat(6)
    );
    let gray = compress(&mut self::z(), &[1, 0, 0, 0, 0, 15]);
    assert_eq!(d.decode(3, 1, 1, 7, 0, 0, &gray).unwrap().unwrap(), [255; 4]);
}
#[test]
fn full_frame_sent_as_slices_equals_the_unsliced_frame() {
    // 64 x 128 gray4 = two tiles: solid 1, solid 2.
    let whole = Decoder::default()
        .decode(0, 64, 128, 7, 0, 0, &compress(&mut z(), &[2, 0, 0, 0, 0, 1, 1, 0, 0, 2]))
        .unwrap()
        .unwrap();
    let mut d = Decoder::default();
    let mut z = z();
    // First slice: full flag, top tile row only; the missing tile is zero until the next slice.
    let first = d
        .decode(0, 64, 128, 3, 0, 0, &compress(&mut z, &[1, 0, 0, 0, 0, 1]))
        .unwrap()
        .unwrap();
    assert_eq!(&first[..64 * 64 * 4], &whole[..64 * 64 * 4]);
    assert_eq!(&first[64 * 64 * 4..], &bgra(0, 0).repeat(64 * 64)[..]);
    // Second slice: a delta carrying the rest, on the same zlib stream.
    let second = d
        .decode(0, 64, 128, 4, 0, 0, &compress(&mut z, &[1, 0, 1, 0, 0, 2]))
        .unwrap()
        .unwrap();
    assert_eq!(second, whole);
}
#[test]
fn full_frame_with_too_many_tiles_is_rejected() {
    // One tile in the grid, a body claiming two.
    let body = [2, 0, 0, 0, 0, 1, 1, 0, 0, 2];
    assert!(Decoder::default()
        .decode(0, 64, 64, 7, 0, 0, &compress(&mut z(), &body))
        .is_err());
}
#[test]
fn palette_bits_and_row_padding() {
    for bits in [1, 2, 4] {
        let mut body = vec![1, 0, 0, 0, bits, 2, 0, 15];
        body.extend(match bits {
            1 => vec![0b01000000, 0b10100000],
            2 => vec![0b00010000, 0b01000100],
            _ => vec![0x01, 0, 0x10, 0x10],
        });
        let image = Decoder::default()
            .decode(0, 3, 2, 7, 0, 0, &compress(&mut z(), &body))
            .unwrap()
            .unwrap();
        assert_eq!(
            image,
            [
                bgra(0, 0),
                bgra(0, 15),
                bgra(0, 0),
                bgra(0, 15),
                bgra(0, 0),
                bgra(0, 15)
            ]
            .concat()
        );
    }
}
#[test]
fn raw_and_edge_tiles() {
    let body = [2, 0, 0, 0, 0, 1, 1, 0, 255, 15];
    let image = Decoder::default()
        .decode(0, 65, 1, 7, 0, 0, &compress(&mut z(), &body))
        .unwrap()
        .unwrap();
    assert_eq!(&image[..256], bgra(0, 1).repeat(64));
    assert_eq!(&image[256..], bgra(0, 15));
}
#[test]
fn duo_edge_subblocks() {
    // 17x1: first 16-pixel sub-block is alternating, last one is solid.
    let body = [1, 0, 0, 0, 3, 2, 0, 15, 0x55, 0x55, 1, 7];
    let image = Decoder::default()
        .decode(3, 17, 1, 7, 0, 0, &compress(&mut z(), &body))
        .unwrap()
        .unwrap();
    for i in 0..16 {
        assert_eq!(
            &image[i * 4..i * 4 + 4],
            bgra(3, if i % 2 == 0 { 0 } else { 15 })
        );
    }
    assert_eq!(&image[64..], bgra(3, 7));
}
#[test]
fn every_sample_mode_expands() {
    assert_eq!(bgra(1, 215), [255, 255, 255, 255]);
    assert_eq!(bgra(1, 216), [0, 0, 0, 255]);
    assert_eq!(bgra(1, 255), [255; 4]);
    assert_eq!(bgra(4, 31), [255, 0, 0, 255]);
    assert_eq!(bgra(0, 8), [136, 136, 136, 255]);
}
#[test]
fn malformed_frames_are_rejected_without_panics() {
    for body in [
        vec![],
        vec![1, 0, 1, 0, 0, 0],
        vec![1, 0, 0, 0, 77],
        vec![1, 0, 0, 0, 1, 0],
        vec![1, 0, 0, 0, 1, 1, 0, 0x80],
        vec![1, 0, 0, 0, 0, 1, 42],
    ] {
        assert!(
            Decoder::default()
                .decode(0, 1, 1, 7, 0, 0, &compress(&mut z(), &body))
                .is_err(),
            "{body:?}"
        );
    }
    let c = compress(&mut z(), &[1, 0, 0, 0, 0, 1]);
    assert!(Decoder::default().decode(0, 1, 1, 6, 0, 0, &c).is_err());
    assert!(Decoder::default()
        .decode(0, 65535, 65535, 7, 0, 0, &c)
        .is_err());
    assert!(Decoder::default()
        .decode(0, 1, 1, 7, 0, 0, &c[..c.len() - 1])
        .is_err());
    assert!(Decoder::default()
        .decode(0, 1, 1, 7, 0, 0, &compress(&mut z(), &vec![0; 10000]))
        .is_err());
}
fn window() -> Window {
    Window {
        id: 1,
        parent: 0,
        kind: 0,
        flags: 3,
        rect: Rect {
            x: 100.,
            y: 200.,
            w: 400.,
            h: 300.,
        },
        title_bar: 28.,
        title: "Document".into(),
    }
}
#[test]
fn aspect_fit_hit_test_popup_priority_and_letterboxing() {
    let r = window().rect;
    assert_eq!(
        canvas_point(r, 800., 800., 400., 400., false),
        Some((300., 350.))
    );
    assert_eq!(canvas_point(r, 800., 800., 0., 0., false), None);
    assert_eq!(
        canvas_point(r, 800., 800., 0., 0., true),
        Some((100., 200.))
    );
    let mut popup = window();
    popup.id = 2;
    popup.kind = 5;
    popup.rect.w = 50.;
    assert_eq!(hit(&[popup, window()], 110., 210.), Some((2, 10., 10.)));
    assert_eq!(hit(&[window()], 99., 210.), None);
}
#[test]
fn keyboard_map_matches_mac() {
    for (key, code) in [
        ('a', 0),
        ('c', 8),
        ('q', 12),
        ('1', 18),
        ('0', 29),
        ('l', 37),
        ('/', 44),
        ('.', 47),
    ] {
        assert_eq!(keycode(key as u32), Some(code));
    }
    assert_eq!(keycode(0xff51), Some(123));
    assert_eq!(keycode(0xffff), Some(117));
    assert_eq!(keycode(0xffe1), None);
}
#[test]
fn fragmented_wire_and_bad_lengths() {
    struct OneByte(std::io::Cursor<Vec<u8>>);
    impl std::io::Read for OneByte {
        fn read(&mut self, b: &mut [u8]) -> std::io::Result<usize> {
            let n = b.len().min(1);
            std::io::Read::read(&mut self.0, &mut b[..n])
        }
    }
    let bytes = packet(2, vec![1, 0, b'A', 0x20, 3, 0x58, 2]);
    assert!(matches!(
        read_message(&mut OneByte(std::io::Cursor::new(bytes)))
            .unwrap()
            .0,
        Incoming::Ready(_, 800, 600)
    ));
    assert!(read_message(&mut &vec![4, 255, 255, 255, 255][..]).is_err());
    assert!(decode(13, &[1, 0]).is_err());
    assert!(decode(3, &[1, 0, 255]).is_err());
    assert!(decode(3, &[0, 0, 1]).is_err());
}
#[test]
fn menu_and_window_validation() {
    let mut item = vec![];
    item.extend(1u32.to_le_bytes());
    item.extend(0u32.to_le_bytes());
    item.extend([0, 3]);
    for f in [100f32, 200., 400., 300., 28.] {
        item.extend(f.to_le_bytes());
    }
    string(&mut item, "文档");
    let mut table = vec![1, 0];
    table.extend(&item);
    assert!(matches!(decode(13,&table).unwrap(),Incoming::Windows(w) if w[0].title=="文档"));
    table[0] = 2;
    table.extend(&item);
    assert!(decode(13, &table).is_err());
    let mut menu = vec![1, 0];
    string(&mut menu, "File");
    menu.push(1);
    string(&mut menu, "");
    menu.push(0);
    menu.extend([0, 0]);
    assert!(matches!(decode(17,&menu).unwrap(),Incoming::Menus(m) if m.len()==1));
    assert_eq!(menu_pick(&[0, 2]), vec![18, 5, 0, 0, 0, 2, 0, 0, 2, 0]);
}

#[test]
fn v5_clipboard_bounds_and_legacy_selection() {
    let address = Address::parse("rapp://host/?token=x", None).unwrap();
    assert_eq!(address.hello(1.)[5], 9);
    let text = "中文 clipboard";
    let mut payload = 1u32.to_le_bytes().to_vec();
    payload.extend([0, 0]);
    payload.extend((text.len() as u32).to_le_bytes());
    payload.extend(text.as_bytes());
    assert!(
        matches!(decode(19,&payload).unwrap(),Incoming::Clipboard{text:Some(t),truncated:false,..} if t==text)
    );
    payload[5] = 2;
    assert!(decode(19, &payload).is_err());
    payload[5] = 0;
    payload[6..10].copy_from_slice(&u32::MAX.to_le_bytes());
    assert!(decode(19, &payload).is_err());
    let image = [1, 0, 0, 0, 1, 32, 0, 32, 0, 100, 0, 0, 0, 0, 0, 0, 0];
    assert!(matches!(
        decode(19, &image).unwrap(),
        Incoming::Clipboard { text: None, .. }
    ));
}

#[test]
fn stream_policy_matches_mac_presets_density_and_deadband() {
    use rapp_client_core::stream::*;
    assert_eq!(
        LEAST_TRAFFIC,
        Choice {
            mode: 3,
            fps: 1,
            density: 1
        }
    );
    assert_eq!(
        SHARPEST,
        Choice {
            mode: 2,
            fps: 15,
            density: 2
        }
    );
    assert_eq!(MODES.map(|(_, mode)| mode), [3, 4, 2]);
    assert_eq!(capture_density(0.5, 2., 0), 0.5);
    assert_eq!(capture_density(0.5, 2., 1), 1.);
    assert_eq!(capture_density(0.5, 2., 2), 8.);
    assert_eq!(capture_density(0.001, 1., 1), 0.01);
    assert_eq!(capture_density(2., 8., 1), 8.);
    assert!(!changed(Some((3, 1, 0.1)), (3, 1, 0.1005)));
    assert!(changed(Some((3, 1, 0.1)), (3, 1, 0.102)));
    assert!(!changed(Some((2, 15, 4.)), (2, 15, 4.03)));
    assert!(changed(Some((2, 15, 4.)), (2, 15, 4.05)));
    assert!(changed(Some((2, 15, 4.)), (3, 15, 4.)));
    assert!(changed(Some((2, 15, 4.)), (2, 1, 4.)));
    assert_eq!(rate(0, 1.), "0 KB/s");
    assert_eq!(rate(1024, 1.), "1.0 KB/s");
    assert_eq!(rate(1024 * 1024, 1.), "1.0 MB/s");
}
#[test]
fn zoom_draw_and_input_use_the_same_point_mapping() {
    let r = window().rect;
    assert_eq!(zoom_placement(r, 800., 800., 0.5), (300., 325., 0.5));
    assert_eq!(
        zoom_point(r, 800., 800., 0.5, 400., 400., false),
        Some((300., 350.))
    );
    assert_eq!(zoom_point(r, 800., 800., 0.5, 200., 400., false), None);
    assert_eq!(
        zoom_point(r, 800., 800., 0.5, 200., 400., true),
        Some((100., 350.))
    );
}
#[test]
fn moving_remote_window_uses_unoccupied_mac_stack_slot() {
    let mut a = window();
    a.rect.x = 0.;
    a.rect.y = 30.;
    let mut b = a.clone();
    b.id = 2;
    b.rect.x = 28.;
    b.rect.y = 40.;
    assert_eq!(top_left_slot(&[a, b], 3), 56.);
}

#[test]
fn expanded_buffer_is_reused_for_delta_frames() {
    let mut decoder = Decoder::default();
    let mut pixels = Vec::new();
    let mut z = Compress::new(Compression::default(), true);
    let full = compress(&mut z, &[1, 0, 0, 0, 0, 0, 248]);
    decoder
        .decode_into(2, 4, 4, 7, 0, 0, &full, &mut pixels)
        .unwrap();
    let pointer = pixels.as_ptr();
    assert_eq!(&pixels[..4], &[0, 0, 255, 255]);
    let delta = compress(&mut z, &[1, 0, 0, 0, 0, 224, 7]);
    decoder
        .decode_into(2, 4, 4, 6, 0, 0, &delta, &mut pixels)
        .unwrap();
    assert_eq!(pixels.as_ptr(), pointer);
    assert_eq!(&pixels[..4], &[0, 255, 0, 255]);
}

#[test]
fn v6_notifications_and_paste_confirmation_are_strict() {
    for by in ["", "客厅的 Mac"] {
        let mut payload = vec![];
        string(&mut payload, by);
        let wire = packet(26, payload.clone());
        assert!(matches!(read_message(&mut &wire[..]).unwrap().0,
            Incoming::InputBlocked(name) if name == by));
        payload.push(0);
        assert!(decode(26, &payload).is_err());
    }
    assert!(decode(26, &[1, 0]).is_err());
    assert!(decode(26, &[1, 0, 255]).is_err());
    let mut ack = 42u32.to_le_bytes().to_vec();
    string(&mut ack, "远端正在被 Mac 操作");
    assert!(
        matches!(decode(21, &ack).unwrap(), Incoming::Pasted {seq: 42, error} if error.contains("Mac"))
    );
    assert_eq!(
        takeover_notice("host says: taken over by Mac"),
        Some("这个窗口在 Mac 上打开了".into())
    );
    assert_eq!(
        takeover_notice("taken over"),
        Some("这个窗口在另一台设备上打开了".into())
    );
    assert_eq!(takeover_notice("busy"), None);
    assert_eq!(input_blocked_notice(""), "远端正在被另一台设备操作");
}

#[test]
fn v8_input_source_is_strict_and_select_matches_host() {
    for (id, name, flag) in [
        ("com.apple.keylayout.ABC", "ABC", 1u8),
        ("p", "简体拼音", 0),
    ] {
        let mut payload = vec![];
        string(&mut payload, id);
        string(&mut payload, name);
        payload.push(flag);
        let wire = packet(29, payload.clone());
        assert!(matches!(read_message(&mut &wire[..]).unwrap().0,
            Incoming::InputSource { id: i, name: n, ascii } if i == id && n == name && ascii == (flag == 1)));
        payload.push(0);
        assert!(decode(29, &payload).is_err());
    }
    assert!(decode(29, &[1, 0, b'a', 1, 0, b'B', 2]).is_err());
    assert!(decode(29, &[1, 0, b'a', 1, 0, b'B']).is_err());
    assert_eq!(select_input(""), vec![30, 2, 0, 0, 0, 0, 0]);
    assert_eq!(select_input("a"), vec![30, 3, 0, 0, 0, 1, 0, b'a']);
}

#[test]
fn reconnect_address_roundtrips_without_exposing_token() {
    for host in ["localhost", "127.0.0.1", "[::1]"] {
        let original = Address::parse(&format!("rapp://{host}:1234/com.example.%E6%96%87?mode=duocolor&fps=30"), Some("secret".into())).unwrap();
        let url = original.connect_url();
        assert!(!url.contains("secret"));
        let again = Address::parse(&url, Some(original.token.clone())).unwrap();
        assert_eq!(again.host, original.host);
        assert_eq!(again.app, original.app);
        assert_eq!(again.port, original.port);
        assert_eq!(again.hello(1.), original.hello(1.));
    }
}

#[test]
fn frame_ack_bytes() {
    assert_eq!(frame_ack(300), packet(27, 300u16.to_le_bytes().to_vec()));
}
#[test]
fn stream_always_carries_pinned() {
    let mut payload = vec![3, 1];
    payload.extend(1f32.to_le_bytes());
    payload.push(1);
    assert_eq!(stream(3, 1, 1., true), packet(11, payload.clone()));
    *payload.last_mut().unwrap() = 0;
    assert_eq!(stream(3, 1, 1., false), packet(11, payload));
}
#[test]
fn decodes_weak_strictly() {
    assert!(matches!(decode(28, &[1]).unwrap(), Incoming::Weak(true)));
    assert!(matches!(decode(28, &[0]).unwrap(), Incoming::Weak(false)));
    assert!(decode(28, &[2]).is_err());
    assert!(decode(28, &[]).is_err());
    assert!(decode(28, &[1, 0]).is_err());
}
#[test]
fn hello_announces_version_9() {
    let a = Address::parse("rapp://host/?token=x", None).unwrap();
    assert_eq!(a.hello(1.)[5], 9);
}

mod v9 {
    use super::{compress, z};
    use flate2::Compress;
    use rapp_client_core::codec::{Decoder, COPIES, END, FULL, START};

    fn raw(index: u16, samples: &[u8]) -> Vec<u8> {
        [&index.to_le_bytes()[..], &[255], samples].concat()
    }
    fn solid(index: u16, v: u8) -> Vec<u8> {
        [&index.to_le_bytes()[..], &[0, v]].concat()
    }
    fn copy(index: u16, sx: u16, sy: u16) -> Vec<u8> {
        [&index.to_le_bytes()[..], &[5], &sx.to_le_bytes(), &sy.to_le_bytes()].concat()
    }
    fn body(tiles: &[Vec<u8>]) -> Vec<u8> {
        [&(tiles.len() as u16).to_le_bytes()[..], &tiles.concat()].concat()
    }
    /// One gray4 slice of a w x h canvas.
    fn slice(z: &mut Compress, d: &mut Decoder, w: usize, h: usize, flags: u8, mv: (i32, i32), tiles: &[Vec<u8>])
        -> anyhow::Result<Option<Vec<u8>>> {
        d.decode(0, w, h, flags, mv.0, mv.1, &compress(z, &body(tiles)))
    }
    /// A decoder holding a 128x64 canvas: tile 0 all 3, tile 1 all 5.
    fn two_tiles() -> (Decoder, Compress) {
        let (mut d, mut z) = (Decoder::default(), z());
        slice(&mut z, &mut d, 128, 64, FULL | START | END, (0, 0), &[solid(0, 3), solid(1, 5)]).unwrap();
        (d, z)
    }

    #[test]
    fn move_header_shifts_canvas() {
        let (mut d, mut z) = (Decoder::default(), z());
        let old: Vec<u8> = (0..64).map(|i| i % 16).collect();
        slice(&mut z, &mut d, 8, 8, FULL | START | END, (0, 0), &[raw(0, &old)]).unwrap();
        assert_eq!(d.samples_le(), old);
        slice(&mut z, &mut d, 10, 6, START | END, (2, -1), &[]).unwrap();
        assert_eq!((d.width, d.height), (10, 6));
        let got = d.samples_le();
        for y in 0..6i32 {
            for x in 0..10i32 {
                let (ox, oy) = (x + 2, y - 1);
                let want = if ox < 8 && (0..8).contains(&oy) { old[(oy * 8 + ox) as usize] } else { 0 };
                assert_eq!(got[(y * 10 + x) as usize], want, "({x},{y})");
            }
        }
    }

    #[test]
    fn copy_tile_reads_reference_not_partial_frame() {
        let (mut d, mut z) = two_tiles();
        slice(&mut z, &mut d, 128, 64, START | COPIES, (0, 0), &[solid(0, 9)]).unwrap();
        slice(&mut z, &mut d, 128, 64, END, (0, 0), &[copy(1, 0, 0)]).unwrap();
        let s = d.samples_le();
        assert_eq!((s[63], s[64], s[127]), (9, 3, 3));
    }

    #[test]
    fn bad_frames_are_rejected() {
        type Case = fn(&mut Decoder, &mut Compress) -> anyhow::Result<Option<Vec<u8>>>;
        let cases: [(&str, Case); 8] = [
            ("copy without copies flag", |d, z| slice(z, d, 128, 64, START | END, (0, 0), &[copy(1, 0, 0)])),
            ("copy source outside", |d, z| slice(z, d, 128, 64, START | END | COPIES, (0, 0), &[copy(1, 65, 0)])),
            ("unknown flag bits", |d, z| slice(z, d, 128, 64, 0x10 | START | END, (0, 0), &[])),
            ("full without start", |d, z| slice(z, d, 128, 64, FULL | END, (0, 0), &[])),
            ("copies without start", |d, z| {
                slice(z, d, 128, 64, START, (0, 0), &[]).unwrap();
                slice(z, d, 128, 64, END | COPIES, (0, 0), &[])
            }),
            ("slice without open frame", |d, z| slice(z, d, 128, 64, END, (0, 0), &[])),
            ("delta start while open", |d, z| {
                slice(z, d, 128, 64, START, (0, 0), &[]).unwrap();
                slice(z, d, 128, 64, START | END, (0, 0), &[])
            }),
            ("size change inside a frame", |d, z| {
                slice(z, d, 128, 64, START, (0, 0), &[]).unwrap();
                slice(z, d, 64, 64, END, (0, 0), &[])
            }),
        ];
        for (name, case) in cases {
            let (mut d, mut z) = two_tiles();
            assert!(case(&mut d, &mut z).is_err(), "{name}");
        }
    }

    #[test]
    fn full_frame_may_interrupt_open_frame() {
        let (mut d, mut z) = two_tiles();
        slice(&mut z, &mut d, 128, 64, START, (0, 0), &[]).unwrap();
        let mut z2 = super::z();
        let shown = slice(&mut z2, &mut d, 128, 64, FULL | START | END, (0, 0), &[solid(0, 1), solid(1, 1)]);
        assert!(shown.unwrap().is_some());
        assert_eq!(d.samples_le()[0], 1);
    }

    #[test]
    fn extreme_offsets_give_blank_canvas() {
        let extremes = [(i32::MAX, 0), (i32::MIN, 0), (0, i32::MAX), (0, i32::MIN), (i32::MIN, i32::MIN), (i32::MAX, i32::MAX)];
        for mv in extremes {
            let (mut d, mut z) = two_tiles();
            slice(&mut z, &mut d, 128, 64, START | END, mv, &[]).unwrap();
            assert_eq!(d.samples_le(), vec![0; 128 * 64], "{mv:?}");
        }
        let (mut d, mut z) = two_tiles();
        slice(&mut z, &mut d, 128, 64, START | END, (i32::MAX, 0), &[solid(1, 7)]).unwrap();
        let s = d.samples_le();
        assert_eq!((s[0], s[64]), (0, 7));
    }

    #[test]
    fn error_leaves_decoder_needing_a_full_frame() {
        let (mut d, mut z) = two_tiles();
        assert!(d.decode(0, 128, 64, START | END, 1, 0, &[1, 2, 3]).is_err());
        assert_eq!(d.width, 0);
        assert!(slice(&mut z, &mut d, 128, 64, START | END, (0, 0), &[solid(0, 1)]).is_err());
        let mut z2 = super::z();
        slice(&mut z2, &mut d, 128, 64, FULL | START | END, (0, 0), &[solid(0, 2), solid(1, 4)]).unwrap();
        let s = d.samples_le();
        assert_eq!((s[0], s[64]), (2, 4));
    }

    #[test]
    fn display_timing() {
        let (mut d, mut z) = (Decoder::default(), z());
        let show = |d: &mut Decoder, z: &mut Compress, w, flags, mv, tiles: &[Vec<u8>]| {
            slice(z, d, w, 64, flags, mv, tiles).unwrap().is_some()
        };
        // The session's first full frame shows slice by slice.
        assert!(show(&mut d, &mut z, 128, FULL | START, (0, 0), &[solid(0, 3)]));
        assert!(show(&mut d, &mut z, 128, END, (0, 0), &[solid(1, 3)]));
        // Later full frames wait for the last slice.
        let mut z2 = self::z();
        assert!(!show(&mut d, &mut z2, 128, FULL | START, (0, 0), &[solid(0, 4)]));
        assert!(show(&mut d, &mut z2, 128, END, (0, 0), &[solid(1, 4)]));
        // Plain deltas show every slice.
        assert!(show(&mut d, &mut z2, 128, START, (0, 0), &[solid(0, 5)]));
        assert!(show(&mut d, &mut z2, 128, END, (0, 0), &[solid(1, 5)]));
        // Moves wait for the last slice.
        assert!(!show(&mut d, &mut z2, 128, START, (0, 3), &[solid(0, 6)]));
        assert!(show(&mut d, &mut z2, 128, END, (0, 0), &[solid(1, 6)]));
        assert!(!show(&mut d, &mut z2, 64, START, (0, 0), &[solid(0, 7)]));
        assert!(show(&mut d, &mut z2, 64, END, (0, 0), &[]));
        assert!(show(&mut d, &mut z2, 64, START | END, (0, 0), &[solid(0, 8)]));
    }
}

/// The stream written by Swift's `CrossFixtureTests`: slices, each frame end followed by the canvas Swift got.
#[test]
fn scroll_copy_fixture_matches_swift() {
    let bytes = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/scroll-copy.bin")).unwrap();
    let mut rest = &bytes[..];
    fn take<'a>(rest: &mut &'a [u8], n: usize) -> &'a [u8] {
        let (head, tail) = rest.split_at(n);
        *rest = tail;
        head
    }
    let int = |b: &[u8]| b.iter().rev().fold(0u64, |a, x| a << 8 | *x as u64);
    let mut d = Decoder::default();
    let mut canvases = 0;
    let mut counted = false;
    while !rest.is_empty() {
        match take(&mut rest, 1)[0] {
            1 => {
                let mode = take(&mut rest, 1)[0];
                let (w, h) = (int(take(&mut rest, 2)) as usize, int(take(&mut rest, 2)) as usize);
                let flags = take(&mut rest, 1)[0];
                let (dx, dy) = (int(take(&mut rest, 4)) as u32 as i32, int(take(&mut rest, 4)) as u32 as i32);
                let n = int(take(&mut rest, 4)) as usize;
                d.decode(mode, w, h, flags, dx, dy, take(&mut rest, n)).unwrap();
            }
            2 => {
                let (w, h) = (int(take(&mut rest, 2)) as usize, int(take(&mut rest, 2)) as usize);
                let n = int(take(&mut rest, 4)) as usize;
                assert_eq!((d.width, d.height), (w, h), "canvas #{canvases}");
                assert!(d.samples_le() == take(&mut rest, n), "canvas #{canvases} differs");
                canvases += 1;
            }
            3 => {
                assert_eq!(int(take(&mut rest, 4)) as usize, canvases, "canvas count record");
                assert!(rest.is_empty(), "data after the count record");
                counted = true;
            }
            tag => panic!("bad record tag {tag}"),
        }
    }
    assert!(counted && canvases > 15);
}
