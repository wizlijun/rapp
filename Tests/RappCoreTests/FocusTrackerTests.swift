import XCTest
@testable import RappCore

final class FocusTrackerTests: XCTestCase {
    typealias T = FocusTracker
    let win = CGSize(width: 1000, height: 800)
    let left = CGRect(x: 0, y: 0, width: 400, height: 800)
    let right = CGRect(x: 500, y: 0, width: 500, height: 800)

    /// Tracker on window 1 (1000x800, appeared long ago), started at t=0; the start actions are dropped.
    func started(size: CGSize? = nil, appeared: TimeInterval? = -10) -> T {
        let t = T()
        _ = t.window(id: 1, size: size ?? win, appeared: appeared, now: 0)
        _ = t.start(now: 0)
        return t
    }
    func pick(_ r: CGRect) -> Result<PanelPick, PanelMiss> { .success(PanelPick(rect: r, depth: 1, share: 0.5)) }
    func sends(_ a: [T.Action]) -> [T.Output] {
        a.compactMap { if case .send(let o) = $0 { return o }; return nil }
    }
    func queries(_ a: [T.Action]) -> [T.Query] {
        a.compactMap { if case .query(let q, _) = $0 { return q }; return nil }
    }
    func out(_ rects: [CGRect], _ cause: T.Cause, window: UInt32 = 1) -> T.Action {
        .send(T.Output(window: window, rects: rects, cause: cause))
    }
    /// Keyboard panel `r` delivered at `now` (the start query's result).
    @discardableResult
    func keyboard(_ t: T, _ r: Result<PanelPick, PanelMiss>, now: TimeInterval) -> [T.Action] {
        t.result(.keyboard, generation: t.generation, r, now: now)
    }
    /// 100x100 tiles of a 1000x800 window: 80 tiles in all.
    func tiles(cols: ClosedRange<Int>, rows: ClosedRange<Int>) -> [CGRect] {
        rows.flatMap { y in cols.map { x in CGRect(x: x * 100, y: y * 100, width: 100, height: 100) } }
    }
    func frame(_ changed: [CGRect], copy: CGRect? = nil, full: Bool = false) -> WindowTiles {
        WindowTiles(changed: changed, total: 80, copyBounds: copy, full: full)
    }

    // MARK: start, windows, whole-window cases (rule 7)

    func testStartQueriesKeyboardAndSendsWhole() {
        let t = T()
        XCTAssertEqual(t.window(id: 1, size: win, appeared: -10, now: 0), [])
        XCTAssertEqual(t.start(now: 0), [.query(.keyboard, generation: t.generation), out([], .on)])
    }
    func testClickQueriesAtOnce() {
        let t = started()
        XCTAssertEqual(t.pointer(.click, at: CGPoint(x: 700, y: 400), now: 1),
                       [.query(.pointer(CGPoint(x: 700, y: 400)), generation: t.generation)])
        XCTAssertEqual(t.tick(now: 1.1), [])
        XCTAssertEqual(t.tick(now: 1.2), [.query(.keyboard, generation: t.generation)])
        XCTAssertEqual(t.tick(now: 1.3), [])
        XCTAssertEqual(t.result(.pointer(CGPoint(x: 700, y: 400)), generation: t.generation, pick(right), now: 1.3),
                       [out([right], .click)])
    }
    func testMoveAcrossDoesNotQuery() {
        let t = started()
        var all: [T.Action] = []
        for i in 0...10 {
            let now = 1 + Double(i) * 0.1
            all += t.pointer(.move, at: CGPoint(x: Double(i) * 95, y: 400), now: now)
            all += t.tick(now: now + 0.05)
        }
        all += t.tick(now: 2.3)
        XCTAssertEqual(queries(all), [])
    }
    func testHoverAfterHalfSecondOnce() {
        let t = started()
        let p = CGPoint(x: 700, y: 400)
        XCTAssertEqual(t.pointer(.move, at: p, now: 1), [])
        XCTAssertEqual(t.tick(now: 1.4), [])
        XCTAssertEqual(t.tick(now: 1.5), [.query(.pointer(p), generation: t.generation)])
        XCTAssertEqual(t.tick(now: 1.6), [])
        XCTAssertEqual(t.tick(now: 3), [])
        XCTAssertEqual(t.result(.pointer(p), generation: t.generation, pick(right), now: 3),
                       [out([right], .hover)])
    }
    func testNoQueryInsideCurrentPointerPanel() {
        let t = started()
        _ = t.pointer(.click, at: CGPoint(x: 700, y: 400), now: 1)
        _ = t.result(.pointer(CGPoint(x: 700, y: 400)), generation: t.generation, pick(right), now: 1)
        _ = t.tick(now: 1.2)
        XCTAssertEqual(t.pointer(.click, at: CGPoint(x: 800, y: 100), now: 2), [])
        XCTAssertEqual(t.pointer(.scroll, at: CGPoint(x: 600, y: 600), now: 2.1), [])
        XCTAssertEqual(t.pointer(.drag, at: CGPoint(x: 610, y: 600), now: 2.15), [])
        XCTAssertEqual(t.tick(now: 2.3), [.query(.keyboard, generation: t.generation)])   // the click's recheck
        XCTAssertEqual(t.pointer(.move, at: CGPoint(x: 900, y: 700), now: 3), [])
        XCTAssertEqual(t.tick(now: 3.6), [])
        XCTAssertEqual(t.pointer(.click, at: CGPoint(x: 100, y: 100), now: 4),
                       [.query(.pointer(CGPoint(x: 100, y: 100)), generation: t.generation)])
    }
    func testPointerMissKeepsPanel() {
        let t = started()
        _ = t.result(.pointer(CGPoint(x: 700, y: 400)), generation: t.generation, pick(right), now: 1)
        XCTAssertEqual(t.result(.pointer(CGPoint(x: 100, y: 100)), generation: t.generation, .failure(.small), now: 2), [])
        XCTAssertEqual(t.pointerPanel, right)
        XCTAssertEqual(t.pointerMiss, .small)
    }
    func testEmptyKeyboardUsesPointerOnly() {
        let t = started()
        XCTAssertEqual(keyboard(t, .failure(.small), now: 0.5), [])
        XCTAssertNil(t.keyboardPanel)
        XCTAssertEqual(t.keyboardMiss, .small)
        _ = t.pointer(.click, at: CGPoint(x: 700, y: 400), now: 1)
        XCTAssertEqual(t.result(.pointer(CGPoint(x: 700, y: 400)), generation: t.generation, pick(right), now: 1),
                       [out([right], .click)])
    }
    func testKeyboardMissClearsPanel() {
        let t = started()
        XCTAssertEqual(keyboard(t, pick(left), now: 1), [out([left], .on)])
        _ = t.keyboardChanged(now: 2)
        XCTAssertEqual(keyboard(t, .failure(.large), now: 2), [out([], .notify)])
        XCTAssertNil(t.keyboardPanel)
    }
    func testUnionOver85IsWhole() {
        let t = started()
        let kb = CGRect(x: 0, y: 0, width: 600, height: 800)
        XCTAssertEqual(keyboard(t, pick(kb), now: 1), [out([kb], .on)])
        _ = t.pointer(.click, at: CGPoint(x: 900, y: 400), now: 2)
        // Bounding box of (0,0,600,800) and (500,0,500,800) is the whole window.
        XCTAssertEqual(t.result(.pointer(CGPoint(x: 900, y: 400)), generation: t.generation, pick(right), now: 2),
                       [out([], .click)])
    }
    func testContainedRectDropped() {
        let t = started()
        XCTAssertEqual(keyboard(t, pick(right), now: 1), [out([right], .on)])
        let inner = CGRect(x: 600, y: 100, width: 300, height: 300)
        _ = t.pointer(.click, at: CGPoint(x: 200, y: 100), now: 2)
        XCTAssertEqual(t.result(.pointer(CGPoint(x: 200, y: 100)), generation: t.generation, pick(inner), now: 2), [])
    }
    func testTwoPanelsSent() {
        let t = started()
        _ = keyboard(t, pick(left), now: 1)
        let mid = CGRect(x: 400, y: 0, width: 300, height: 400)
        _ = t.pointer(.click, at: CGPoint(x: 500, y: 100), now: 2)
        XCTAssertEqual(t.result(.pointer(CGPoint(x: 500, y: 100)), generation: t.generation, pick(mid), now: 2),
                       [out([left, mid], .click)])
    }
    func testSmallWindowWhole() {
        let t = T()
        _ = t.window(id: 1, size: CGSize(width: 479, height: 800), appeared: -10, now: 0)
        XCTAssertEqual(sends(t.start(now: 0)), [T.Output(window: 1, rects: [], cause: .on)])
        XCTAssertEqual(keyboard(t, pick(CGRect(x: 0, y: 0, width: 300, height: 800)), now: 1), [])
        XCTAssertEqual(t.tick(now: 2), [])
        let short = started(size: CGSize(width: 1000, height: 319))
        XCTAssertEqual(keyboard(short, pick(CGRect(x: 0, y: 0, width: 400, height: 319)), now: 1), [])
    }
    func testFirstTwoSecondsWhole() {
        let t = T()
        _ = t.window(id: 1, size: win, appeared: 0, now: 0)
        XCTAssertEqual(sends(t.start(now: 0)), [T.Output(window: 1, rects: [], cause: .on)])
        XCTAssertEqual(keyboard(t, pick(left), now: 0.5), [])
        XCTAssertEqual(t.tick(now: 1.9), [])
        XCTAssertEqual(t.tick(now: 2.0), [out([left], .on)])
        XCTAssertEqual(t.tick(now: 2.1), [])
    }
    func testLockedWhole() {
        let t = started()
        _ = keyboard(t, pick(left), now: 1)
        XCTAssertEqual(t.locked(true, now: 2), [out([], .lock)])
        XCTAssertEqual(t.locked(false, now: 3), [out([left], .lock)])
    }
    func testLockedBeforeStart() {
        let t = T()
        _ = t.window(id: 1, size: win, appeared: -10, now: 0)
        XCTAssertEqual(t.locked(true, now: 0), [])
        _ = t.start(now: 0)
        XCTAssertEqual(keyboard(t, pick(left), now: 1), [])
    }
    func testNoWindowWhole() {
        let t = started()
        _ = keyboard(t, pick(left), now: 1)
        XCTAssertEqual(t.window(id: nil, size: .zero, appeared: nil, now: 2), [out([], .window, window: 0)])
        XCTAssertEqual(t.pointer(.click, at: CGPoint(x: 10, y: 10), now: 3), [])
        XCTAssertEqual(t.keyboardChanged(now: 3), [])
        XCTAssertEqual(t.tick(now: 4), [])
        let none = T()
        XCTAssertEqual(none.start(now: 0), [out([], .on, window: 0)])
    }
    func testNewWindowRequeriesAndResets() {
        let t = started()
        _ = keyboard(t, pick(left), now: 1)
        let g = t.generation
        XCTAssertEqual(t.window(id: 2, size: win, appeared: -10, now: 2),
                       [.query(.keyboard, generation: g + 1), out([], .window, window: 2)])
        XCTAssertNil(t.keyboardPanel)
        XCTAssertEqual(t.window(id: 2, size: win, appeared: -10, now: 3), [])
        XCTAssertEqual(t.generation, g + 1)
    }
    func testThrottleKeepsLast() {
        let t = started()   // whole sent at t=0
        let a = CGRect(x: 0, y: 0, width: 400, height: 800), b = CGRect(x: 0, y: 0, width: 500, height: 800)
        XCTAssertEqual(keyboard(t, pick(a), now: 0.1), [])
        _ = t.keyboardChanged(now: 0.2)
        XCTAssertEqual(keyboard(t, pick(b), now: 0.2), [])
        XCTAssertEqual(t.tick(now: 0.25), [])
        XCTAssertEqual(t.tick(now: 0.3), [out([b], .notify)])
        XCTAssertEqual(t.tick(now: 0.4), [])
    }
    func testUnchangedNotSent() {
        let t = started()
        XCTAssertEqual(keyboard(t, pick(left), now: 1), [out([left], .on)])
        XCTAssertEqual(t.keyboardChanged(now: 2), [.query(.keyboard, generation: t.generation)])
        XCTAssertEqual(keyboard(t, pick(left), now: 2), [])
        XCTAssertEqual(t.tick(now: 3), [])
    }

    // MARK: rule 5: follow

    /// Keyboard panel = left; click at (100,100) inside it at t=1 (the pointer query lands in left too).
    func clicked() -> T {
        let t = started()
        _ = keyboard(t, pick(left), now: 0.5)
        _ = t.pointer(.click, at: CGPoint(x: 100, y: 100), now: 1)
        _ = t.result(.pointer(CGPoint(x: 100, y: 100)), generation: t.generation, pick(left), now: 1)
        return t
    }
    func testFollowWithinOneSecond() {
        let t = clicked()
        // 10 tiles outside the focus (cols 5...9, rows 0...1), plus tiles inside `left`, which do not count.
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 0...1) + tiles(cols: 0...3, rows: 0...7)), now: 1.3), [])
        // The same 10 again: still 10 distinct, not > 12.
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 0...1)), now: 1.4), [])
        // 3 new ones: 13 distinct > 80 * 0.15 -> follow at the centre of (500,0)-(1000,300).
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...7, rows: 2...2)), now: 1.5),
                       [.query(.follow(CGPoint(x: 750, y: 150)), generation: t.generation)])
        // Once per action.
        XCTAssertEqual(t.frame(frame(tiles(cols: 4...9, rows: 3...7)), now: 1.6), [])
        let f = CGRect(x: 500, y: 0, width: 300, height: 400)   // with left: 80% box
        XCTAssertEqual(t.result(.follow(CGPoint(x: 750, y: 150)), generation: t.generation, pick(f), now: 1.7),
                       [out([left, f], .follow)])
        XCTAssertEqual(t.followPanel, f)
    }
    func testNoFollowAfterOneSecond() {
        let t = clicked()
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 2.1), [])
    }
    func testNoFollowWithoutAction() {
        let t = started()
        _ = keyboard(t, pick(left), now: 0.5)
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1), [])
    }
    func testNoFollowWhileWhole() {
        let t = started()   // keyboard not back yet: whole
        _ = t.key(now: 1)
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2), [])
    }
    func testKeyArmsFollowAndRechecks() {
        let t = started()
        _ = keyboard(t, pick(left), now: 0.5)
        XCTAssertEqual(t.key(now: 1), [])
        XCTAssertEqual(t.tick(now: 1.2), [.query(.keyboard, generation: t.generation)])
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.3),
                       [.query(.follow(CGPoint(x: 750, y: 400)), generation: t.generation)])
    }
    func testScrollAndMoveDoNotArmFollow() {
        let t = started()
        _ = keyboard(t, pick(left), now: 0.5)
        _ = t.pointer(.scroll, at: CGPoint(x: 100, y: 100), now: 1)
        _ = t.pointer(.move, at: CGPoint(x: 120, y: 100), now: 1.1)
        _ = t.pointer(.drag, at: CGPoint(x: 130, y: 100), now: 1.15)
        XCTAssertEqual(queries(t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2))
                        .filter { if case .follow = $0 { return true }; return false }, [])
    }
    func testNextClickClearsFollow() {
        let t = clicked()
        _ = t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2)
        let f = CGRect(x: 500, y: 0, width: 300, height: 400)   // with left: 80% box
        XCTAssertEqual(t.result(.follow(CGPoint(x: 750, y: 400)), generation: t.generation, pick(f), now: 1.3),
                       [out([left, f], .follow)])
        XCTAssertEqual(t.pointer(.click, at: CGPoint(x: 100, y: 200), now: 2), [out([left], .click)])
        XCTAssertNil(t.followPanel)
        // A late answer to the old follow query is dropped.
        XCTAssertEqual(t.result(.follow(CGPoint(x: 750, y: 400)), generation: t.generation, pick(f), now: 2.1), [])
        // The new click re-arms follow.
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 4...7)), now: 2.5),
                       [.query(.follow(CGPoint(x: 750, y: 600)), generation: t.generation)])
    }
    func testFullFrameNeverFollows() {
        let t = clicked()
        XCTAssertEqual(t.frame(frame(tiles(cols: 0...9, rows: 0...7), full: true), now: 1.2), [])
        // The full frame's tiles were not counted: 10 more are not enough.
        XCTAssertEqual(t.frame(frame(tiles(cols: 5...9, rows: 0...1)), now: 1.3), [])
    }

    // MARK: rule 6: copy tiles

    func testCopyBoundsWhenBlocked() {
        let t = started()
        XCTAssertEqual(keyboard(t, .failure(.blocked), now: 0.5), [])
        let copy = CGRect(x: 300, y: 0, width: 600, height: 800)
        XCTAssertEqual(t.frame(frame([], copy: copy), now: 1), [out([copy], .scroll)])
        // A frame without copies keeps the last copy box.
        XCTAssertEqual(t.frame(frame([]), now: 2), [])
        // Pointer blocked too: still the copy box.
        _ = t.pointer(.click, at: CGPoint(x: 10, y: 10), now: 3)
        XCTAssertEqual(t.result(.pointer(CGPoint(x: 10, y: 10)), generation: t.generation, .failure(.blocked), now: 3), [])
        XCTAssertEqual(t.tick(now: 4), [.query(.keyboard, generation: t.generation)])   // recheck only, no send
    }
    func testNoCopyFallbackWhenSmallOrLarge() {
        let copy = CGRect(x: 300, y: 0, width: 600, height: 800)
        let small = started()
        _ = keyboard(small, .failure(.small), now: 0.5)
        XCTAssertEqual(small.frame(frame([], copy: copy), now: 1), [])
        let large = started()
        _ = keyboard(large, .failure(.blocked), now: 0.5)
        _ = large.pointer(.click, at: CGPoint(x: 10, y: 10), now: 0.6)
        _ = large.result(.pointer(CGPoint(x: 10, y: 10)), generation: large.generation, .failure(.large), now: 0.6)
        XCTAssertEqual(large.frame(frame([], copy: copy), now: 1), [])
        XCTAssertEqual(large.tick(now: 2), [.query(.keyboard, generation: large.generation)])   // recheck only
    }
    func testCopyBoundsBelowThresholdWhole() {
        let t = started()
        _ = keyboard(t, .failure(.blocked), now: 0.5)
        XCTAssertEqual(t.frame(frame([], copy: CGRect(x: 0, y: 0, width: 100, height: 100)), now: 1), [])
        XCTAssertEqual(t.frame(frame([], copy: CGRect(x: 0, y: 0, width: 950, height: 800)), now: 2), [])
        XCTAssertEqual(t.tick(now: 3), [])
    }

    // MARK: review focus

    func testStaleResultAfterWindowChangeDropped() {
        let t = started()
        let old = t.generation
        _ = t.window(id: 2, size: win, appeared: -10, now: 1)
        XCTAssertEqual(t.result(.keyboard, generation: old, pick(left), now: 2), [])
        XCTAssertNil(t.keyboardPanel)
        XCTAssertEqual(t.tick(now: 3), [])
        _ = t.window(id: 2, size: CGSize(width: 900, height: 800), appeared: -10, now: 4)
        XCTAssertEqual(t.generation, old + 2)
    }
    func testOutputClippedToWindow() {
        let t = started()
        let p = CGRect(x: 600, y: 0, width: 400, height: 800)
        XCTAssertEqual(keyboard(t, pick(p), now: 1), [out([p], .on)])
        let narrow = CGSize(width: 800, height: 800)
        XCTAssertEqual(t.window(id: 1, size: narrow, appeared: -10, now: 2),
                       [.query(.keyboard, generation: t.generation), out([], .resize)])
        // Even a pick wider than the window never leaves it.
        XCTAssertEqual(keyboard(t, pick(p), now: 3), [out([CGRect(x: 600, y: 0, width: 200, height: 800)], .resize)])
    }
    func testRectsRoundedOutward() {
        let t = started()
        let r = CGRect(x: 0.4, y: 10.6, width: 300.2, height: 400.1)
        XCTAssertEqual(keyboard(t, pick(r), now: 1), [out([CGRect(x: 0, y: 10, width: 301, height: 401)], .on)])
        let t2 = started()
        let edge = CGRect(x: 600.5, y: 0.5, width: 399.8, height: 799.8)
        XCTAssertEqual(keyboard(t2, pick(edge), now: 1), [out([CGRect(x: 600, y: 0, width: 400, height: 800)], .on)])
    }
}
