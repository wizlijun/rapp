import XCTest
@testable import RappCore

final class RuleRegionTests: XCTestCase {
    func genericChat() throws -> RulePack {
        try RulePack.decode(try RuleValue.parse(Data(genericChatJSON.utf8)))
    }
    func pack(_ regions: String) throws -> RulePack {
        try RulePack.decode(try RuleValue.parse(Data(#"{"format":"1.0","id":"t","regions":\#(regions)}"#.utf8)))
    }

    func testGenericChatRegionsOnASyntheticWindow() throws {
        let r = resolveRegions(try genericChat(), in: Canvas.chatWindow())
        XCTAssertEqual(r["sidebar"], [RuleRect(x: 0, y: 0, w: 240, h: 600)])
        XCTAssertEqual(r["main"], [RuleRect(x: 240, y: 0, w: 560, h: 600)])
        XCTAssertEqual(r["bottom"], [RuleRect(x: 240, y: 440, w: 560, h: 160)])
        XCTAssertEqual(r["tail"], [RuleRect(x: 240, y: 200, w: 560, h: 240)])
        XCTAssertEqual(r["button"], [RuleRect(x: 740, y: 520, w: 32, h: 32)])
        XCTAssertEqual(r["markers"]?.count, 3)
        XCTAssertEqual(r["markers"]?.map(\.y), [100, 140, 180])
    }

    func testNoSidebarMeansMainIsTheWholeWindow() throws {
        let r = resolveRegions(try genericChat(), in: Canvas.chatWindow(sidebar: false))
        XCTAssertNil(r["sidebar"]); XCTAssertNil(r["markers"])
        XCTAssertEqual(r["main"], [RuleRect(x: 0, y: 0, w: 800, h: 600)])
    }

    func testDarkThemeAndTwoTimesNarrowerWindow() throws {
        let r = resolveRegions(try genericChat(), in: Canvas.chatWindow(width: 400, dark: true))
        XCTAssertEqual(r["sidebar"], [RuleRect(x: 0, y: 0, w: 240, h: 600)])
        XCTAssertNotNil(r["button"])
    }

    func testBoxLengthsAndAnchors() throws {
        let p = try pack(#"""
        {"a":{"box":{"left":"25%","width":"50%"}},
         "b":{"box":{"left":10,"right":10,"top":10,"bottom":10}},
         "c":{"box":{"in":"b","bottom":0,"height":100}},
         "d":{"box":{"in":"b","above":"c","height":50}},
         "e":{"box":{"in":"nowhere"}},
         "f":{"box":{"in":"d"}},
         "loop1":{"box":{"in":"loop2"}},"loop2":{"box":{"in":"loop1"}}}
        """#)
        let r = resolveRegions(p, in: Canvas.solid(width: 400, height: 300))
        XCTAssertEqual(r["a"], [RuleRect(x: 100, y: 0, w: 200, h: 300)])
        XCTAssertEqual(r["b"], [RuleRect(x: 10, y: 10, w: 380, h: 280)])
        XCTAssertEqual(r["c"], [RuleRect(x: 10, y: 190, w: 380, h: 100)])
        XCTAssertEqual(r["d"], [RuleRect(x: 10, y: 140, w: 380, h: 50)])
        XCTAssertNil(r["e"]); XCTAssertEqual(r["f"], r["d"])
        XCTAssertNil(r["loop1"]); XCTAssertNil(r["loop2"])
    }

    func testSampleCropsAndScalesToPoints() {
        let src: [UInt8] = [1,0,0,255, 2,0,0,255, 3,0,0,255, 4,0,0,255,
                            5,0,0,255, 6,0,0,255, 7,0,0,255, 8,0,0,255]
        let img = src.withUnsafeBytes { RuleImage.sample(bgra: $0, width: 4, height: 2, bytesPerRow: 16,
                                                         crop: RuleRect(x: 0, y: 0, w: 4, h: 2), scale: 2) }
        XCTAssertEqual(img?.width, 2); XCTAssertEqual(img?.height, 1)
        XCTAssertEqual(img?.rgb(0, 0).b, 1); XCTAssertEqual(img?.rgb(1, 0).b, 3)
        XCTAssertNil(src.withUnsafeBytes { RuleImage.sample(bgra: $0, width: 4, height: 2, bytesPerRow: 16,
                                                            crop: RuleRect(x: 3, y: 0, w: 4, h: 2), scale: 2) })
        for bad in [0.0, -1, .nan, .infinity, 1e-320] {
            XCTAssertNil(src.withUnsafeBytes { RuleImage.sample(bgra: $0, width: 4, height: 2, bytesPerRow: 16,
                                                                crop: RuleRect(x: 0, y: 0, w: 4, h: 2), scale: bad) })
        }
    }

    func testEdgeFromEveryDirectionAndBadRanges() throws {
        var img = Canvas.solid(width: 400, height: 300)
        Canvas.fill(&img, RuleRect(x: 0, y: 0, w: 100, h: 300), (200, 200, 200))     // left band
        Canvas.fill(&img, RuleRect(x: 350, y: 0, w: 50, h: 300), (200, 200, 200))    // right band
        Canvas.fill(&img, RuleRect(x: 0, y: 250, w: 400, h: 50), (100, 100, 100))    // bottom band
        let p = try pack(#"""
        {"l":{"edge":{"from":"left","min":10,"max":300}},
         "r":{"edge":{"from":"right","min":10,"max":300}},
         "b":{"edge":{"from":"bottom","min":0,"max":200}},
         "none":{"edge":{"from":"left","min":150,"max":300}},
         "inverted":{"edge":{"from":"left","min":300,"max":10}}}
        """#)
        let r = resolveRegions(p, in: img)
        XCTAssertEqual(r["l"], [RuleRect(x: 0, y: 0, w: 100, h: 300)])
        XCTAssertEqual(r["r"], [RuleRect(x: 350, y: 0, w: 50, h: 300)])
        XCTAssertEqual(r["b"], [RuleRect(x: 0, y: 250, w: 400, h: 50)])
        XCTAssertNil(r["none"]); XCTAssertNil(r["inverted"])
    }

    func testBlobPicksSizesAndRoundness() throws {
        var img = Canvas.solid(width: 200, height: 100)
        Canvas.fill(&img, RuleRect(x: 10, y: 10, w: 20, h: 20), (0, 0, 0))      // square, 20x20
        Canvas.disc(&img, x: 60, y: 40, size: 24, (0, 0, 0))                    // round, 24
        Canvas.fill(&img, RuleRect(x: 120, y: 60, w: 40, h: 10), (0, 0, 0))     // wide bar
        Canvas.fill(&img, RuleRect(x: 190, y: 90, w: 2, h: 2), (0, 0, 0))       // speck
        let p = try pack(#"""
        {"all":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"all"}},
         "right":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"rightmost"}},
         "left":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"leftmost"}},
         "top":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"topmost"}},
         "bottom":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"bottommost"}},
         "big":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"largest"}},
         "round":{"blob":{"in":{"box":{}},"round":true,"size":[5,50],"pick":"all"}},
         "huge":{"blob":{"in":{"box":{}},"size":[60,90]}}}
        """#)
        let r = resolveRegions(p, in: img)
        XCTAssertEqual(r["all"]?.map(\.x), [10, 60, 120])
        XCTAssertEqual(r["right"]?.first?.x, 120)
        XCTAssertEqual(r["left"]?.first?.x, 10)
        XCTAssertEqual(r["top"]?.first?.x, 10)
        XCTAssertEqual(r["bottom"]?.first?.x, 120)
        XCTAssertEqual(r["big"]?.first?.x, 60)     // bounding box 24x24 beats the 40x10 bar
        XCTAssertEqual(r["round"]?.map(\.x), [10, 60])
        XCTAssertNil(r["huge"])
    }

    func testStripOfARegion() throws {
        let p = try pack(#"""
        {"a":{"box":{"left":100,"width":200}},
         "right":{"strip":{"of":"a","side":"right","width":40}},
         "left":{"strip":{"of":"a","side":"left","width":40}},
         "top":{"strip":{"of":"a","side":"top","width":10}},
         "bottom":{"strip":{"of":"a","side":"bottom","width":10}},
         "wide":{"strip":{"of":"a","side":"left","width":999}}}
        """#)
        let r = resolveRegions(p, in: Canvas.solid(width: 400, height: 300))
        XCTAssertEqual(r["right"], [RuleRect(x: 260, y: 0, w: 40, h: 300)])
        XCTAssertEqual(r["left"], [RuleRect(x: 100, y: 0, w: 40, h: 300)])
        XCTAssertEqual(r["top"], [RuleRect(x: 100, y: 0, w: 200, h: 10)])
        XCTAssertEqual(r["bottom"], [RuleRect(x: 100, y: 290, w: 200, h: 10)])
        XCTAssertEqual(r["wide"], [RuleRect(x: 100, y: 0, w: 200, h: 300)])
    }

    func testAbsurdNumbersResolveWithoutCrashing() throws {
        let p = try pack(#"""
        {"a":{"box":{"left":1e308,"width":1e308}},
         "b":{"box":{"left":-1e308,"right":-1e308}},
         "c":{"box":{"top":-1e308,"height":1e308}},
         "d":{"box":{"left":"1e308%","width":"-1e308%"}},
         "e":{"box":{"left":50,"right":400}},
         "f":{"edge":{"from":"left","min":1e308,"max":1e308}},
         "g":{"edge":{"from":"top","min":-1e308,"max":1e308}},
         "h":{"edge":{"from":"left","min":50,"max":10}},
         "i":{"strip":{"of":{"box":{}},"side":"left","width":1e308}},
         "j":{"strip":{"of":{"box":{}},"side":"left","width":-5}},
         "k":{"blob":{"in":"a","size":[-1e308,1e308]}}}
        """#)
        let r = resolveRegions(p, in: Canvas.solid(width: 100, height: 100))
        XCTAssertNil(r["a"]); XCTAssertNil(r["e"]); XCTAssertNil(r["f"]); XCTAssertNil(r["h"])
        XCTAssertNil(r["j"]); XCTAssertNil(r["k"])
        XCTAssertEqual(r["b"], [RuleRect(x: 0, y: 0, w: 100, h: 100)])
        XCTAssertNil(r["c"])   // -1e308 + 1e308 ends at the top edge: empty
        XCTAssertEqual(r["i"], [RuleRect(x: 0, y: 0, w: 100, h: 100)])
        XCTAssertNil(r["g"])   // solid image: no edge anywhere
    }

    func testRelationCyclesAreNilInEveryOrder() throws {
        // resolveRegions walks the names sorted, so each pack below enters its cycle from a different
        // member (or from a region that only depends on the cycle); all must give the same answer.
        let packs = [
            #"{"a":{"box":{"rightOf":"b"}},"b":{"box":{"rightOf":"a"}}}"#,
            #"{"b":{"box":{"rightOf":"a"}},"a":{"box":{"rightOf":"b"}},"0dep":{"box":{"rightOf":"a"}}}"#,
            #"{"x":{"box":{"rightOf":"z"}},"y":{"box":{"below":"x"}},"z":{"box":{"leftOf":"y"}}}"#,
            #"{"z":{"box":{"rightOf":"y"}},"y":{"box":{"below":"x"}},"x":{"box":{"leftOf":"z"}},"0in":{"box":{"in":"y"}}}"#,
        ]
        let img = Canvas.solid(width: 100, height: 100)
        for json in packs {
            let withOk = String(json.dropLast()) + #","ok":{"box":{"left":10,"width":20}}}"#
            let r = resolveRegions(try pack(withOk), in: img)
            XCTAssertEqual(Set(r.keys), ["ok"], json)
            XCTAssertEqual(r["ok"], [RuleRect(x: 10, y: 0, w: 20, h: 100)])
        }
    }

    func testHslAndDistance() {
        XCTAssertEqual(hsl(r: 255, g: 0, b: 0), HSL(h: 0, s: 100, l: 50))
        XCTAssertEqual(hsl(r: 0, g: 255, b: 0).h, 120, accuracy: 0.01)
        XCTAssertEqual(hsl(r: 0, g: 0, b: 255).h, 240, accuracy: 0.01)
        XCTAssertEqual(hsl(r: 128, g: 128, b: 128).s, 0)
        XCTAssertEqual(colorDistance((10, 20, 30), (15, 20, 10)), 20)
    }
}
