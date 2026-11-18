import Foundation
import XCTest
@testable import RappSession

/// Runs the shared case table `Tests/voice_key_gate.json` (the Dart twin reads the same file).
final class VoiceKeyGateTests: XCTestCase {
  private static let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("voice_key_gate.json")

  func testFixtureCases() throws {
    let data = try Data(contentsOf: Self.fixture)
    let cases = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    XCTAssertFalse(cases.isEmpty)
    for c in cases {
      let name = c["name"] as? String ?? "?"
      var gate = VoiceKeyGate(hotkey: c.keys.contains("hotkey") ? VoiceHotkey(json: c["hotkey"]) : .standard)
      let caseReady = c["ready"] as? Bool ?? true
      let steps = try XCTUnwrap(c["steps"] as? [[String: Any]], name)
      for (i, s) in steps.enumerated() {
        let label = "\(name) step \(i) (\(s["t"] ?? "?"): \(s["in"] ?? "?"))"
        let ms = try XCTUnwrap((s["t"] as? NSNumber)?.doubleValue, label)
        let input = try XCTUnwrap(Self.parseInput(s["in"] as? String ?? ""), label)
        let want = try XCTUnwrap(Self.parseOutput(s["out"] as? String ?? "", input: input), label)
        let got = gate.handle(input, at: ms / 1000, ready: s["ready"] as? Bool ?? caseReady)
        XCTAssertEqual(got, want, label)
      }
    }
  }

  func testHotkeyJson() {
    XCTAssertEqual(
      VoiceHotkey(json: ["kind": "hold_combo", "key_code": 49, "modifiers": 786432]),
      .holdCombo(49, [.control, .option]))
    XCTAssertEqual(VoiceHotkey(json: "off"), .off)
    XCTAssertEqual(VoiceHotkey(json: ["kind": "hold_modifier", "key_code": 0]), .standard)
    XCTAssertEqual(VoiceHotkey(json: ["kind": "hold_combo", "key_code": 12, "modifiers": 1 << 20]), .standard)
    XCTAssertEqual(VoiceHotkey(json: nil), .standard)
  }

  // MARK: - the fixture's mini-language

  private static let modifierWords: [String: KeyFlags] = [
    "shift": .shift, "ctrl": .control, "opt": .option, "cmd": .command, "fn": .function,
  ]

  private static func parseInput(_ text: String) -> VoiceGateInput? {
    let words = text.split(separator: " ").map(String.init)
    guard let head = words.first else { return nil }
    switch head {
    case "pointer": return words.count == 1 ? .pointer : nil
    case "scroll": return words.count == 1 ? .scroll : nil
    case "elapsed": return words.count == 1 ? .elapsed : nil
    case "resign": return words.count == 1 ? .resign : nil
    case "ended": return words.count == 1 ? .ended : nil
    case "up":
      guard words.count == 2, let code = UInt16(words[1]) else { return nil }
      return .up(code)
    case "down":
      guard words.count >= 2, let code = UInt16(words[1]) else { return nil }
      var flags: KeyFlags = []
      var isRepeat = false
      for w in words.dropFirst(2) {
        if w == "repeat" { isRepeat = true } else if let f = modifierWords[w] { flags.insert(f) } else { return nil }
      }
      return .down(code, flags, isRepeat: isRepeat)
    default: return nil
    }
  }

  private static func parseOutput(_ text: String, input: VoiceGateInput) -> VoiceGateStep? {
    var step = VoiceGateStep()
    switch input {
    case .pointer, .scroll: step.pass = true  // pointer and scroll always go on to A
    default: break
    }
    for w in text.split(separator: " ") {
      switch w {
      case "flush": step.flush = true
      case "pass": step.pass = true
      case "arm": step.arm = true
      case "swallow":
        switch input {
        case .down, .up: step.pass = false
        default: return nil  // swallow only describes key events
        }
      case "none": break
      default:
        guard let phase = VoiceKeyPhase(rawValue: String(w)) else { return nil }
        step.voice = phase
      }
    }
    return step
  }
}
