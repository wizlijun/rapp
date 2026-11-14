//! The whole-path probe (spec 2026-11-14-rapp-network-status §3.3), the same rules as RappCore's PathProbe.
use rapp_client_core::probe::PathProbe;

#[test]
fn pings_at_once_then_every_ten_seconds() {
    let mut p = PathProbe::default();
    assert_eq!(p.tick(0.).0, Some(1));
    assert_eq!(p.pong(1, 0.08), Some(80));
    for s in 1..=9 {
        assert_eq!(p.tick(s as f64).0, None);
    }
    assert_eq!(p.tick(10.).0, Some(2));
}

#[test]
fn input_pings_every_two_seconds() {
    let mut p = PathProbe::default();
    p.tick(0.);
    p.pong(1, 0.05);
    p.input(1.);
    assert_eq!(p.tick(2.).0, Some(2));
    p.pong(2, 2.05);
    assert_eq!(p.tick(3.).0, None);
    assert_eq!(p.tick(4.).0, Some(3));
    p.pong(3, 4.05);
    assert_eq!(p.tick(6.).0, None);
    assert_eq!(p.tick(13.).0, None);
    assert_eq!(p.tick(14.).0, Some(4));
}

#[test]
fn two_unanswered_pings_are_stalled_and_anything_from_a_ends_it() {
    let mut p = PathProbe::default();
    p.tick(0.);
    p.pong(1, 0.05);
    assert_eq!(p.tick(10.).0, Some(2));
    assert_eq!(p.tick(11.).1, None);
    assert_eq!(p.tick(12.), (Some(3), None));
    assert_eq!(p.tick(14.).1, Some(true));
    assert_eq!(p.tick(16.).1, None);
    assert_eq!(p.received(16.5), Some(false));
    assert_eq!(p.received(16.6), None);
}

#[test]
fn frames_arriving_mean_the_link_is_up() {
    let mut p = PathProbe::default();
    p.tick(0.);
    for s in 1..=20 {
        assert_eq!(p.received(s as f64 - 0.5), None);
        assert_eq!(p.tick(s as f64).1, None);
    }
}

#[test]
fn an_old_pong_gives_no_round_trip() {
    let mut p = PathProbe::default();
    p.tick(0.);
    p.tick(2.);
    p.tick(4.);
    assert_eq!(p.pong(1, 4.5), None);
    assert_eq!(p.pong(3, 4.6), Some(600));
}
