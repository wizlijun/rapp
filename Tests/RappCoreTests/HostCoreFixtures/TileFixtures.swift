import XCTest
@testable import RappCore

/// `FrameEncoder` runs, recorded for `rust/host-core/tests/tile.rs`.
///
/// `tile-frames.bin`: the BGRA pictures the runs use, one record each (tag 1:
/// `u16 width, u16 height`, then the tightly packed BGRA deflated by a fresh
/// `DeflateStream`; the record number is the frame id). Rust quantizes them itself
/// and checks the result against the sample hash in each call record.
///
/// `tile-<mode>.bin` (one per mode) and `tile-settle.bin` hold runs, records in order:
/// - tag 10: a new run, fresh encoder and decoder: `u8 mode`, then the run's name (UTF-8).
/// - tag 11: an encode call: `u8 call` (0 `encode`, 1 `encodeSlices`), `u64 limit`,
///   `u64 firstLimit` (`UInt64.max` = `Int.max` / nil), `u32 frame id`, `u8 hasRegion`,
///   `f32 x, y, w, h`, `u8 withRaw`, `u64` FNV-1a of Swift's samples of the frame.
/// - tag 12: `reset()`. tag 13: `forceFull = true`. tag 14: `encodeSettle(limit:)`, `u32 limit`.
/// - After every tag 11 and tag 14, per slice returned: tag 1, the slice as in
///   `CrossFixtureTests` (`u8 mode, u16 w, u16 h, u8 flags, i32 dx, i32 dy, u32 n`, data);
///   tag 4, the slice's tile stream before deflate as `u32 length, u64 FNV-1a`; after a slice
///   with `end`, tag 2, Swift's decoded canvas as `u16 w, u16 h, u32 n, u64 FNV-1a`.
///   Then (tag 11 only) tag 5, `lastReport`: `f32 x, y, w, h, u32 width, u32 height, u8 full,
///   u32 n`, n × `u32` tile index, `u8 hasCopyBounds`, `u32 x, y, w, h`. Then tag 6, the state:
///   `u8 needsSettle, u8 lastEncodeDiverged, u8 lastEncodeAddedApproximation,
///   u32 lastTileCount, u32 slice count`.
/// - tag 3, last: `u32` number of tag 2 records.
final class TileFixtures: XCTestCase {
    enum Step {
        case frame(Int, CanvasRect?)
        case reset
        case forceFull
        /// One `encodeSettle` call.
        case settle(Int)
        /// `encodeSettle` until it returns nothing (the empty call is recorded too).
        case settleAll(Int)
    }

    struct Scene {
        var name: String
        var steps: [Step]
    }

    enum Way {
        case encode
        case slices(limit: Int, firstLimit: Int?)
        var name: String {
            switch self {
            case .encode: return "encode"
            case let .slices(l, f): return "slices \(l)/\(f.map(String.init) ?? "nil")"
            }
        }
    }

    static let modeNames = ["gray4", "color8", "color16", "duogray", "duocolor"]

    static func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// A w x h picture of random opaque colours.
    static func noise(_ w: Int, _ h: Int, seed: UInt64) -> [UInt8] {
        var rng = HostRNG(seed: seed)
        var px = [UInt8]()
        for _ in 0..<(w * h) { px += [UInt8(rng.int(0...255)), UInt8(rng.int(0...255)), UInt8(rng.int(0...255)), 255] }
        return px
    }

    static func picture(_ bgra: [UInt8], _ w: Int, _ h: Int) -> SceneFrame {
        SceneFrame(bgra: bgra, width: w, height: h, region: CanvasRect(x: 0, y: 0, w: Float(w), h: Float(h)))
    }

    /// The frames and the scenes, built once.
    static let library: (frames: [SceneFrame], scenes: [Scene], settleScenes: [Scene]) = {
        var frames = [SceneFrame]()
        func add(_ fs: [SceneFrame]) -> [Int] {
            let start = frames.count
            frames += fs
            return Array(start..<frames.count)
        }
        func own(_ ids: [Int]) -> [Step] { ids.map { .frame($0, frames[$0].region) } }
        var scenes = [Scene]()

        // Every scene kind, 160 x 120 to start with (resizes change the size).
        let every = add(ScrollScenes.frames(seed: 7, count: 15, kinds: [
            .terminalScroll, .webScroll(topBar: 30, sideBar: 50), .resize(edge: .left), .resize(edge: .right),
            .resize(edge: .top), .resize(edge: .bottom), .regionMove, .localChange, .scrollWhileMoving,
        ], size: (160, 120)))
        scenes.append(Scene(name: "every kind", steps: own(every)))

        // A first frame, the identical frame (nothing to send), a frame that changes
        // everywhere at the same region, then the same with no region (a big move).
        let first = add(ScrollScenes.frames(seed: 21, count: 1, kinds: [.terminalScroll], size: (160, 120)))[0]
        let other = add(ScrollScenes.frames(seed: 22, count: 1, kinds: [.localChange], size: (160, 120)))[0]
        let r0 = frames[first].region
        scenes.append(Scene(name: "still, then all new", steps: [
            .frame(first, r0), .frame(first, r0), .frame(other, r0), .frame(other, nil), .frame(other, nil),
        ]))

        // Density changes: half the points (full), back (full), 0.5 % wider (not full).
        scenes.append(Scene(name: "density", steps: [
            .frame(first, r0),
            .frame(first, CanvasRect(x: r0.x, y: r0.y, w: r0.w / 2, h: r0.h / 2)),
            .frame(first, r0),
            .frame(first, CanvasRect(x: r0.x + 0.4, y: r0.y, w: r0.w * 1.005, h: r0.h)),
        ]))

        // A terminal scroll played backwards: later slices copy rows earlier ones rewrote.
        let backwards = add(Array(ScrollScenes.frames(seed: 3, count: 5, kinds: [.terminalScroll], size: (160, 120)).reversed()))
        scenes.append(Scene(name: "terminal backwards", steps: own(backwards)))

        // Forward scrolls under fixed bars.
        let forward = add(ScrollScenes.frames(seed: 4, count: 6, kinds: [.terminalScroll, .webScroll(topBar: 24, sideBar: 40)],
                                              size: (200, 150)))
        scenes.append(Scene(name: "forward scroll", steps: own(forward)))

        // 1 x 1 canvases, then a move of the region.
        let white = add([TileFixtures.picture([255, 255, 255, 255], 1, 1)])[0]
        let black = add([TileFixtures.picture([0, 0, 0, 255], 1, 1)])[0]
        let one = CanvasRect(x: 0, y: 0, w: 1, h: 1), moved = CanvasRect(x: 5, y: 5, w: 1, h: 1)
        scenes.append(Scene(name: "1x1", steps: [
            .frame(white, one), .frame(black, one), .frame(black, one), .frame(black, moved), .frame(white, moved),
        ]))

        // 65 x 65: random colours, a changed patch, rows scrolled by 7, then the region moved.
        let base = TileFixtures.noise(65, 65, seed: 8)
        var patch = base
        var rng = HostRNG(seed: 9)
        for y in 20..<30 { for x in 30..<40 { for c in 0..<3 { patch[(y * 65 + x) * 4 + c] = UInt8(rng.int(0...255)) } } }
        let scrolled = Array(patch[(7 * 65 * 4)...]) + TileFixtures.noise(65, 7, seed: 10)
        let n65 = add([TileFixtures.picture(base, 65, 65), TileFixtures.picture(patch, 65, 65),
                       TileFixtures.picture(scrolled, 65, 65)])
        let r65 = CanvasRect(x: 0, y: 0, w: 65, h: 65)
        scenes.append(Scene(name: "65x65", steps: [
            .frame(n65[0], r65), .frame(n65[1], r65), .frame(n65[2], r65), .frame(n65[2], CanvasRect(x: 0, y: 3, w: 65, h: 65)),
            .frame(n65[0], CanvasRect(x: -2, y: 1, w: 65, h: 65)),
        ]))

        // reset() and forceFull between frames.
        let local = add(ScrollScenes.frames(seed: 12, count: 3, kinds: [.localChange], size: (160, 120)))
        let rl = frames[local[0]].region
        scenes.append(Scene(name: "reset and force full", steps: [
            .frame(local[0], rl), .frame(local[1], rl), .reset, .frame(local[1], rl), .frame(local[2], rl),
            .forceFull, .frame(local[2], rl), .frame(local[0], rl),
        ]))

        // Settle scenes (duo modes, raw given).
        var settleScenes = [Scene]()
        settleScenes.append(Scene(name: "every kind, settle all", steps: every.flatMap { [Step.frame($0, frames[$0].region), .settleAll(32768)] }))
        settleScenes.append(Scene(name: "every kind, one small settle per frame",
                                  steps: every.flatMap { [Step.frame($0, frames[$0].region), .settle(300)] } + [.settleAll(300)]))
        settleScenes.append(Scene(name: "scrolls, settle all 500",
                                  steps: (backwards + forward).flatMap { [Step.frame($0, frames[$0].region), .settleAll(500)] }))
        settleScenes.append(Scene(name: "settle edge cases", steps: [
            .settle(32768), .frame(every[0], frames[every[0]].region), .settle(32768),
            .frame(every[5], frames[every[5]].region), .forceFull, .settle(32768),
            .frame(every[6], frames[every[6]].region), .frame(every[8], frames[every[8]].region),
            .frame(every[14], frames[every[14]].region), .settleAll(1),
        ]))
        return (frames, scenes, settleScenes)
    }()

    final class Recorder {
        var items: [(tag: UInt8, payload: [UInt8])] = []
        var canvases = 0
        var settles = 0
        var copyFrames = 0
        var multiSlice = 0

        func run(mode: Mode, scene: Scene, way: Way, frames: [SceneFrame]) {
            items.append((tag: 10, payload: [mode.rawValue] + Array("\(scene.name), \(way.name)".utf8)))
            let enc = FrameEncoder(mode: mode)
            let dec = FrameDecoder(mode: mode)
            let mirror = InflateStream()
            func emit(_ slices: [FramePayload]) {
                for s in slices {
                    items.append((tag: 1, payload: [s.mode.rawValue] + HostFixture.u16(s.width) + HostFixture.u16(s.height)
                        + [s.flags.rawValue] + HostFixture.i32(s.dx) + HostFixture.i32(s.dy) + HostFixture.sized(s.data)))
                    if s.isFull { mirror.reset() }
                    let stream = try! mirror.decompress(s.data)
                    items.append((tag: 4, payload: HostFixture.u32(UInt32(stream.count)) + HostFixture.u64(TileFixtures.fnv(stream))))
                    _ = try! dec.decode(s)
                    if s.flags.contains(.end) {
                        items.append((tag: 2, payload: HostFixture.u16(UInt16(dec.width)) + HostFixture.u16(UInt16(dec.height))
                            + HostFixture.u32(UInt32(dec.samples.count)) + HostFixture.u64(TileFixtures.fnv(dec.samples))))
                        canvases += 1
                    }
                }
            }
            func state(_ count: Int) {
                items.append((tag: 6, payload: [enc.needsSettle ? 1 : 0, enc.lastEncodeDiverged ? 1 : 0,
                                                enc.lastEncodeAddedApproximation ? 1 : 0]
                    + HostFixture.u32(UInt32(enc.lastTileCount)) + HostFixture.u32(UInt32(count))))
            }
            func settle(_ limit: Int) -> Int {
                items.append((tag: 14, payload: HostFixture.u32(UInt32(limit))))
                let s = enc.encodeSettle(limit: limit)
                emit(s)
                state(s.count)
                if !s.isEmpty { settles += 1 }
                return s.count
            }
            for step in scene.steps {
                switch step {
                case let .frame(id, region):
                    let f = frames[id]
                    let samples = ScrollScenes.samples(f, mode: mode)
                    let r = region ?? CanvasRect(x: 0, y: 0, w: 0, h: 0)
                    var call: [UInt8]
                    switch way {
                    case .encode: call = [0] + HostFixture.u64(.max) + HostFixture.u64(.max)
                    case let .slices(l, fl): call = [1] + HostFixture.u64(UInt64(l)) + HostFixture.u64(fl.map { UInt64($0) } ?? .max)
                    }
                    call += HostFixture.u32(UInt32(id)) + [region == nil ? 0 : 1]
                    call += HostFixture.f32(r.x) + HostFixture.f32(r.y) + HostFixture.f32(r.w) + HostFixture.f32(r.h)
                    call += [1] + HostFixture.u64(TileFixtures.fnv(samples))
                    items.append((tag: 11, payload: call))
                    let slices: [FramePayload]
                    switch way {
                    case .encode:
                        slices = enc.encode(samples: samples, raw: f.bgra, width: f.width, height: f.height, region: region).map { [$0] } ?? []
                    case let .slices(l, fl):
                        slices = enc.encodeSlices(samples: samples, raw: f.bgra, width: f.width, height: f.height,
                                                  region: region, limit: l, firstLimit: fl)
                    }
                    if slices.first?.flags.contains(.copies) == true { copyFrames += 1 }
                    if slices.count > 1 { multiSlice += 1 }
                    emit(slices)
                    let rep = enc.lastReport!
                    var p = HostFixture.f32(rep.region.x) + HostFixture.f32(rep.region.y) + HostFixture.f32(rep.region.w)
                        + HostFixture.f32(rep.region.h)
                    p += HostFixture.u32(UInt32(rep.width)) + HostFixture.u32(UInt32(rep.height)) + [rep.full ? 1 : 0]
                    p += HostFixture.u32(UInt32(rep.changed.count)) + rep.changed.flatMap { HostFixture.u32(UInt32($0)) }
                    if let c = rep.copyBounds {
                        p += [1] + HostFixture.u32(UInt32(c.minX)) + HostFixture.u32(UInt32(c.minY))
                            + HostFixture.u32(UInt32(c.width)) + HostFixture.u32(UInt32(c.height))
                    } else {
                        p += [0] + HostFixture.u32(0) + HostFixture.u32(0) + HostFixture.u32(0) + HostFixture.u32(0)
                    }
                    items.append((tag: 5, payload: p))
                    state(slices.count)
                case .reset:
                    enc.reset()
                    items.append((tag: 12, payload: []))
                case .forceFull:
                    enc.forceFull = true
                    items.append((tag: 13, payload: []))
                case let .settle(limit):
                    _ = settle(limit)
                case let .settleAll(limit):
                    while settle(limit) > 0 {}
                }
            }
        }

        func finish() -> [UInt8] {
            items.append((tag: 3, payload: HostFixture.u32(UInt32(canvases))))
            return HostFixture.records(items)
        }
    }

    static let ways: [Way] = [.encode, .slices(limit: 32768, firstLimit: 8192), .slices(limit: 600, firstLimit: 300)]

    func testFrames() {
        let items = Self.library.frames.map { f -> (tag: UInt8, payload: [UInt8]) in
            (tag: 1, payload: HostFixture.u16(UInt16(f.width)) + HostFixture.u16(UInt16(f.height)) + DeflateStream(level: 6).compress(f.bgra))
        }
        HostFixture.check("tile-frames.bin", HostFixture.records(items))
    }

    func testModes() {
        let lib = Self.library
        for mode in Mode.allCases {
            let rec = Recorder()
            for scene in lib.scenes {
                for way in Self.ways { rec.run(mode: mode, scene: scene, way: way, frames: lib.frames) }
            }
            XCTAssertGreaterThan(rec.copyFrames, 0, "\(mode): no frame with copy tiles")
            XCTAssertGreaterThan(rec.multiSlice, 0, "\(mode): no frame of several slices")
            HostFixture.check("tile-\(Self.modeNames[Int(mode.rawValue)]).bin", rec.finish())
        }
    }

    func testSettle() {
        let lib = Self.library
        let rec = Recorder()
        for mode in [Mode.duogray, .duocolor] {
            for scene in lib.settleScenes {
                for way in [Way.slices(limit: 32768, firstLimit: 8192), .slices(limit: 600, firstLimit: 300)] {
                    rec.run(mode: mode, scene: scene, way: way, frames: lib.frames)
                }
            }
        }
        XCTAssertGreaterThan(rec.settles, 0, "no settle frame")
        HostFixture.check("tile-settle.bin", rec.finish())
    }
}
