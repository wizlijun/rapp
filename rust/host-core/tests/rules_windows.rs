//! Geometry, window table, view region, desktop, hit test and hint rules against the
//! Swift reference. Fixtures are written by
//! `Tests/RappCoreTests/HostCoreFixtures/WindowRuleFixtures.swift`; every case's `in` names
//! the function in `"fn"`, and `out` is what Swift returned.

mod common;
mod rules_common;

use common::raw_cases;
use rapp_host_core::desktop::{self, DesktopDisplay, DesktopTarget};
use rapp_host_core::geometry::{self, Point, Rect, Size};
use rapp_host_core::hints::{self, CoverNotices};
use rapp_host_core::hit_test::{top_window_owner, ScreenWindow};
use rapp_host_core::wintable;
use rules_common::*;
use serde::Deserialize;

#[test]
fn geometry_matches_swift() {
    let cases = raw_cases("geometry.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        match func(i) {
            "global_point" => {
                let got = geometry::global_point(arg(&i["x"]), arg(&i["y"]), arg(&i["frame"]));
                assert_eq!(got, arg::<Point>(&c.out), "{}", c.name);
            }
            "clamp_size" => {
                let got = geometry::clamp_size(arg(&i["requested"]), arg(&i["origin"]), arg(&i["screen"]));
                assert_eq!(got, arg::<Size>(&c.out), "{}", c.name);
            }
            "chunk_utf16" => {
                let s: String = arg(&i["s"]);
                let got = geometry::chunk_utf16(&s, arg(&i["max"]));
                assert_eq!(got, arg::<Vec<Vec<u16>>>(&c.out), "{}", c.name);
            }
            "window_size" => {
                let got = geometry::window_size(
                    arg(&i["content"]),
                    arg(&i["title_row"]),
                    arg(&i["origin"]),
                    arg(&i["screen"]),
                );
                assert_eq!(got, arg::<Size>(&c.out), "{}", c.name);
            }
            "window_title" => {
                let raw: Option<String> = arg(&i["raw"]);
                let app: Option<String> = arg(&i["app_name"]);
                let got = geometry::window_title(raw.as_deref(), app.as_deref());
                assert_eq!(got, arg::<String>(&c.out), "{}", c.name);
            }
            other => panic!("unknown fn {other} in {}", c.name),
        }
    }
}

#[test]
fn window_table_matches_swift() {
    let cases = raw_cases("wintable.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        let table = || infos(&arg::<Vec<JWindow>>(&i["windows"]));
        match func(i) {
            "demote_chromeless" => {
                let title: Option<String> = arg(&i["title"]);
                let got = wintable::demote_chromeless(
                    kind_from(arg(&i["kind"])),
                    arg(&i["close_button"]),
                    title.as_deref(),
                    arg(&i["size"]),
                );
                assert_eq!(kind_byte(got), arg::<u8>(&c.out), "{}", c.name);
            }
            "drop_stray_indicators" => {
                let got = jwindows(&wintable::drop_stray_indicators(table()));
                assert_eq!(got, arg::<Vec<JWindow>>(&c.out), "{}", c.name);
            }
            "promote_main_window" => {
                let got = jwindows(&wintable::promote_main_window(table()));
                assert_eq!(got, arg::<Vec<JWindow>>(&c.out), "{}", c.name);
            }
            "assign_parents" => {
                let got = jwindows(&wintable::assign_parents(table()));
                assert_eq!(got, arg::<Vec<JWindow>>(&c.out), "{}", c.name);
            }
            "drop_title_bar_accessories" => {
                let got = jwindows(&wintable::drop_title_bar_accessories(table()));
                assert_eq!(got, arg::<Vec<JWindow>>(&c.out), "{}", c.name);
            }
            "capture_region" => {
                let got = wintable::capture_region(&table(), arg(&i["display"])).map(|r| JRect::of(&r));
                assert_eq!(got, arg::<Option<JRect>>(&c.out), "{}", c.name);
            }
            "clamped_window_origin" => {
                let got = wintable::clamped_window_origin(
                    arg(&i["origin"]),
                    arg(&i["size"]),
                    arg(&i["title_bar"]),
                    arg(&i["canvas"]),
                );
                assert_eq!(got, arg::<Point>(&c.out), "{}", c.name);
            }
            "classification_is_final" => {
                let got = wintable::classification_is_final(
                    arg(&i["found_accessibility"]),
                    arg(&i["below_pop_up"]),
                    arg(&i["attempts"]),
                );
                assert_eq!(got, arg::<bool>(&c.out), "{}", c.name);
            }
            other => panic!("unknown fn {other} in {}", c.name),
        }
    }
}

#[test]
fn view_region_matches_swift() {
    let cases = raw_cases("view.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        match func(i) {
            "view_region" => {
                let view: Option<JView> = arg(&i["view"]);
                let table = infos(&arg::<Vec<JWindow>>(&i["windows"]));
                let got = wintable::view_region(view.map(JView::pair), &table, arg(&i["display"]));
                assert_eq!(got.map(|r| JRect::of(&r)), arg::<Option<JRect>>(&c.out), "{}", c.name);
            }
            "view_for" => {
                let rect: JRect = arg(&i["rect"]);
                let got = wintable::view_for(arg(&i["window"]), rect.canvas());
                assert_eq!(got.as_ref().map(JView::of), arg::<Option<JView>>(&c.out), "{}", c.name);
            }
            "region_change" => {
                let view: Option<JView> = arg(&i["view"]);
                let current: Option<JRect> = arg(&i["current"]);
                let table = infos(&arg::<Vec<JWindow>>(&i["windows"]));
                let got = wintable::region_change(
                    view.map(JView::pair),
                    &table,
                    arg(&i["display"]),
                    current.map(JRect::canvas),
                );
                assert_eq!(got.map(|r| JRect::of(&r)), arg::<Option<JRect>>(&c.out), "{}", c.name);
            }
            other => panic!("unknown fn {other} in {}", c.name),
        }
    }
}

#[derive(Debug, Deserialize)]
struct JDisplay {
    id: u32,
    name: String,
    main: bool,
    frame: Rect,
}

impl JDisplay {
    fn display(&self) -> DesktopDisplay {
        DesktopDisplay { id: self.id, name: self.name.clone(), main: self.main, frame: self.frame }
    }
}

#[derive(Debug, PartialEq, Deserialize)]
struct JOrdered {
    id: u32,
    name: String,
    main: bool,
    frame: Rect,
    width: i64,
    height: i64,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum JTarget {
    Main,
    Display { id: u32 },
}

#[derive(Debug, PartialEq, Deserialize)]
struct JEntryDisplay {
    id: String,
    name: String,
    main: bool,
    width: i64,
    height: i64,
}

#[derive(Debug, PartialEq, Deserialize)]
struct JEntry {
    app: String,
    name: String,
    displays: Vec<JEntryDisplay>,
}

#[test]
fn desktop_matches_swift() {
    let cases = raw_cases("desktop.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        let displays = || arg::<Vec<JDisplay>>(&i["displays"]).iter().map(JDisplay::display).collect::<Vec<_>>();
        match func(i) {
            "desktop_target" => {
                let app: String = arg(&i["app"]);
                let got = desktop::desktop_target(&app).map(|t| match t {
                    DesktopTarget::Main => JTarget::Main,
                    DesktopTarget::Display(id) => JTarget::Display { id },
                });
                assert_eq!(got, arg::<Option<JTarget>>(&c.out), "{}", c.name);
            }
            "ordered_displays" => {
                let got: Vec<JOrdered> = desktop::ordered_displays(displays())
                    .into_iter()
                    .map(|d| JOrdered {
                        id: d.id,
                        width: d.width(),
                        height: d.height(),
                        name: d.name,
                        main: d.main,
                        frame: d.frame,
                    })
                    .collect();
                assert_eq!(got, arg::<Vec<JOrdered>>(&c.out), "{}", c.name);
            }
            "desktop_title" => {
                let computer: String = arg(&i["computer"]);
                let got = desktop::desktop_title(&computer, arg(&i["number"]));
                assert_eq!(got, arg::<String>(&c.out), "{}", c.name);
            }
            "desktop_table" => {
                let title: String = arg(&i["title"]);
                let got = jwindows(&desktop::desktop_table(arg(&i["width"]), arg(&i["height"]), &title));
                assert_eq!(got, arg::<Vec<JWindow>>(&c.out), "{}", c.name);
            }
            "desktop_entry" => {
                let got: Option<JEntry> = desktop::desktop_entry(&displays()).map(|v| arg(&v));
                assert_eq!(got, arg::<Option<JEntry>>(&c.out), "{}", c.name);
            }
            other => panic!("unknown fn {other} in {}", c.name),
        }
    }
}

#[derive(Debug, Deserialize)]
struct JScreenWindow {
    pid: i32,
    name: String,
    layer: i64,
    alpha: f64,
    frame: Rect,
}

#[derive(Debug, PartialEq, Deserialize)]
struct JOwner {
    pid: i32,
    name: String,
    calls: u32,
}

#[test]
fn hit_test_matches_swift() {
    let cases = raw_cases("hit-test.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        assert_eq!(func(i), "top_window_owner", "{}", c.name);
        let windows: Vec<ScreenWindow> = arg::<Vec<JScreenWindow>>(&i["windows"])
            .into_iter()
            .map(|w| ScreenWindow { pid: w.pid, name: w.name, layer: w.layer, alpha: w.alpha, frame: w.frame })
            .collect();
        let hit: Option<i32> = arg(&i["hit"]);
        let mut calls = 0u32;
        let mut ask = || {
            calls += 1;
            hit
        };
        let displays: Vec<Rect> = arg(&i["displays"]);
        let (pid, name) = top_window_owner(arg(&i["point"]), &windows, arg(&i["dock_pid"]), &displays, &mut ask);
        assert_eq!(JOwner { pid, name, calls }, arg::<JOwner>(&c.out), "{}", c.name);
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
enum CoverStep {
    Send { pid: i32, now: f64 },
    Reported { pid: i32, dismissable: bool, point: Point },
    Point { pid: i32 },
    Forget { pid: i32 },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
enum CoverOut {
    Sent { value: bool },
    Point { value: Option<Point> },
    Done,
}

#[test]
fn hints_match_swift() {
    let cases = raw_cases("hints.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        match func(i) {
            "cover_notices" => {
                let mut notices = CoverNotices::new(arg(&i["every"]));
                let steps: Vec<CoverStep> = arg(&i["steps"]);
                let got: Vec<CoverOut> = steps
                    .into_iter()
                    .map(|s| match s {
                        CoverStep::Send { pid, now } => CoverOut::Sent { value: notices.should_send(pid, now) },
                        CoverStep::Reported { pid, dismissable, point } => {
                            notices.reported(pid, dismissable, point);
                            CoverOut::Done
                        }
                        CoverStep::Point { pid } => CoverOut::Point { value: notices.dismiss_point(pid) },
                        CoverStep::Forget { pid } => {
                            notices.forget(pid);
                            CoverOut::Done
                        }
                    })
                    .collect();
                assert_eq!(got, arg::<Vec<CoverOut>>(&c.out), "{}", c.name);
            }
            "cover_dismissable" => {
                let id: Option<String> = arg(&i["bundle_id"]);
                let got = hints::cover_dismissable(id.as_deref(), arg(&i["regular"]));
                assert_eq!(got, arg::<bool>(&c.out), "{}", c.name);
            }
            "app_opened_worth_telling" => {
                let id: Option<String> = arg(&i["bundle_id"]);
                let got = hints::app_opened_worth_telling(
                    id.as_deref(),
                    arg(&i["pid"]),
                    arg(&i["regular"]),
                    arg(&i["session_pid"]),
                    arg(&i["own_pid"]),
                    arg(&i["since_input"]),
                );
                assert_eq!(got, arg::<bool>(&c.out), "{}", c.name);
            }
            "is_secure_field" => {
                let role: Option<String> = arg(&i["role"]);
                let subrole: Option<String> = arg(&i["subrole"]);
                let got = hints::is_secure_field(role.as_deref(), subrole.as_deref());
                assert_eq!(got, arg::<bool>(&c.out), "{}", c.name);
            }
            other => panic!("unknown fn {other} in {}", c.name),
        }
    }
}

#[test]
fn opens_things_is_presses_typing_and_key_downs() {
    use rapp_host_core::{Message, MouseButton, MouseKind};
    let mouse = |kind| Message::Mouse { kind, button: MouseButton::Left, window: 1, x: 0.0, y: 0.0, click_count: 1 };
    assert!(hints::opens_things(&Message::Text("a".into())));
    assert!(hints::opens_things(&Message::Key { key_code: 36, modifiers: 0, down: true }));
    assert!(!hints::opens_things(&Message::Key { key_code: 36, modifiers: 0, down: false }));
    assert!(hints::opens_things(&mouse(MouseKind::Down)));
    assert!(hints::opens_things(&mouse(MouseKind::Up)));
    assert!(!hints::opens_things(&mouse(MouseKind::Move)));
    assert!(!hints::opens_things(&mouse(MouseKind::Drag)));
    assert!(!hints::opens_things(&Message::Scroll { window: 1, x: 0.0, y: 0.0, dx: 0.0, dy: 1.0 }));
}
