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
        "rapp://localhost:1234/com.example.App?token=abc&mode=color16&fps=5&protocol=4",
        None,
    )
    .unwrap();
    let mut expected = vec![4, 3, 0, b'a', b'b', b'c', 15, 0];
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
        d.decode(2, 3, 2, true, &full).unwrap(),
        [0, 0, 255, 255].repeat(6)
    );
    let delta = compress(&mut z, &[1, 0, 0, 0, 0, 224, 7]);
    assert_eq!(
        d.decode(2, 3, 2, false, &delta).unwrap(),
        [0, 255, 0, 255].repeat(6)
    );
    let gray = compress(&mut self::z(), &[1, 0, 0, 0, 0, 15]);
    assert_eq!(d.decode(3, 1, 1, true, &gray).unwrap(), [255; 4]);
}
#[test]
fn full_frame_sent_as_slices_equals_the_unsliced_frame() {
    // 64 x 128 gray4 = two tiles: solid 1, solid 2.
    let whole = Decoder::default()
        .decode(0, 64, 128, true, &compress(&mut z(), &[2, 0, 0, 0, 0, 1, 1, 0, 0, 2]))
        .unwrap();
    let mut d = Decoder::default();
    let mut z = z();
    // First slice: full flag, top tile row only; the missing tile is zero until the next slice.
    let first = d
        .decode(0, 64, 128, true, &compress(&mut z, &[1, 0, 0, 0, 0, 1]))
        .unwrap();
    assert_eq!(&first[..64 * 64 * 4], &whole[..64 * 64 * 4]);
    assert_eq!(&first[64 * 64 * 4..], &bgra(0, 0).repeat(64 * 64)[..]);
    // Second slice: a delta carrying the rest, on the same zlib stream.
    let second = d
        .decode(0, 64, 128, false, &compress(&mut z, &[1, 0, 1, 0, 0, 2]))
        .unwrap();
    assert_eq!(second, whole);
}
#[test]
fn full_frame_with_too_many_tiles_is_rejected() {
    // One tile in the grid, a body claiming two.
    let body = [2, 0, 0, 0, 0, 1, 1, 0, 0, 2];
    assert!(Decoder::default()
        .decode(0, 64, 64, true, &compress(&mut z(), &body))
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
            .decode(0, 3, 2, true, &compress(&mut z(), &body))
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
        .decode(0, 65, 1, true, &compress(&mut z(), &body))
        .unwrap();
    assert_eq!(&image[..256], bgra(0, 1).repeat(64));
    assert_eq!(&image[256..], bgra(0, 15));
}
#[test]
fn duo_edge_subblocks() {
    // 17x1: first 16-pixel sub-block is alternating, last one is solid.
    let body = [1, 0, 0, 0, 3, 2, 0, 15, 0x55, 0x55, 1, 7];
    let image = Decoder::default()
        .decode(3, 17, 1, true, &compress(&mut z(), &body))
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
                .decode(0, 1, 1, true, &compress(&mut z(), &body))
                .is_err(),
            "{body:?}"
        );
    }
    let c = compress(&mut z(), &[1, 0, 0, 0, 0, 1]);
    assert!(Decoder::default().decode(0, 1, 1, false, &c).is_err());
    assert!(Decoder::default()
        .decode(0, 65535, 65535, true, &c)
        .is_err());
    assert!(Decoder::default()
        .decode(0, 1, 1, true, &c[..c.len() - 1])
        .is_err());
    assert!(Decoder::default()
        .decode(0, 1, 1, true, &compress(&mut z(), &vec![0; 10000]))
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
    assert_eq!(address.hello(1.)[5], 8);
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
        .decode_into(2, 4, 4, true, &full, &mut pixels)
        .unwrap();
    let pointer = pixels.as_ptr();
    assert_eq!(&pixels[..4], &[0, 0, 255, 255]);
    let delta = compress(&mut z, &[1, 0, 0, 0, 0, 224, 7]);
    decoder
        .decode_into(2, 4, 4, false, &delta, &mut pixels)
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
    assert!(Address::parse("rapp://host/?token=x&protocol=8", None).is_ok());
}

#[test]
fn reconnect_address_roundtrips_without_exposing_token() {
    for host in ["localhost", "127.0.0.1", "[::1]"] {
        for version in [4, 5, 6, 7, 8] {
            let original = Address::parse(&format!("rapp://{host}:1234/com.example.%E6%96%87?protocol={version}&mode=duocolor&fps=30"), Some("secret".into())).unwrap();
            let url = original.connect_url();
            assert!(!url.contains("secret"));
            let again = Address::parse(&url, Some(original.token.clone())).unwrap();
            assert_eq!(again.host, original.host);
            assert_eq!(again.app, original.app);
            assert_eq!(again.port, original.port);
            assert_eq!(again.hello(1.), original.hello(1.));
        }
    }
}

#[test]
fn frame_ack_bytes() {
    assert_eq!(frame_ack(300), packet(27, 300u16.to_le_bytes().to_vec()));
}
#[test]
fn stream_pinned_only_when_asked() {
    let old = stream(3, 1, 1., None);
    let mut payload = vec![3, 1];
    payload.extend(1f32.to_le_bytes());
    assert_eq!(old, packet(11, payload.clone()));
    payload.push(1);
    assert_eq!(stream(3, 1, 1., Some(true)), packet(11, payload.clone()));
    *payload.last_mut().unwrap() = 0;
    assert_eq!(stream(3, 1, 1., Some(false)), packet(11, payload));
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
fn parses_protocol_7() {
    assert_eq!(Address::parse("rapp://host/?token=x&protocol=7", None).unwrap().version, 7);
    assert!(Address::parse("rapp://host/?token=x&protocol=9", None).is_err());
}
