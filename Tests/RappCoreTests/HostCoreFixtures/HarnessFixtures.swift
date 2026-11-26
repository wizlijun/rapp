import XCTest
@testable import RappCore

/// The fixture formats themselves (read by `rust/host-core/tests/harness.rs`).
final class HarnessFixtures: XCTestCase {
    func testHarnessRecords() {
        let long = (0..<70_000).map { UInt8($0 % 251) }
        HostFixture.check("harness.bin", HostFixture.records([
            (tag: 1, payload: []),
            (tag: 2, payload: [0xDE, 0xAD]),
            (tag: 255, payload: long),
        ]))
    }

    func testHarnessCases() {
        let input: [Float] = [0.1, 1.0, 16_777_216.0]
        HostFixture.check("harness.json", HostFixture.cases([
            ["name": "floats", "in": input.map(HostFixture.f), "out": [-3, "桌面 · é🇨🇳"] as [Any]],
        ]))
    }
}
