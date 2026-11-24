import Foundation

/// Hold-to-talk on the stage picture: which key starts the voice input, and the pure state machine
/// that decides, event by event, whether the hotkey is being held for voice and what still goes
/// on to A. The rules are pinned by the shared case table `Tests/voice_key_gate.json`, which the
/// Dart twin runs too. No timers here: the caller schedules `.elapsed` when a step says `arm`.

/// Key codes of the modifier keys (⌘ 54/55, ⇧ 56/60, ⇪ 57, ⌥ 58/61, ⌃ 59/62, fn 63).
public let voiceModifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

/// Modifier keys a `hold_modifier` hotkey may use (every modifier except caps lock).
let voiceHoldModifierCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

/// Whether `code` held with `mods` may be a `hold_combo` hotkey: a non-modifier key other than
/// Esc (53) and Tab (48), with at least one of ⌃ ⌥ ⌘, and not one of rApp's own shortcuts
/// (⌃⌘ anything, ⌘Q, ⌃↩).
public func acceptsCombo(_ code: UInt16, _ mods: KeyFlags) -> Bool {
    if voiceModifierCodes.contains(code) || code == 53 || code == 48 { return false }
    if mods.intersection([.control, .option, .command]).isEmpty { return false }
    if mods.contains([.control, .command]) { return false }
    let m = mods.intersection([.control, .option, .shift, .command])
    if m == [.command] && code == 12 { return false }
    if m == [.control] && (code == 36 || code == 76) { return false }
    return true
}

public enum VoiceHotkey: Equatable {
    /// Long press of one modifier key, alone.
    case holdModifier(UInt16)
    /// A key held with exactly these modifiers (within ⌃ ⌥ ⇧ ⌘); starts at once.
    case holdCombo(UInt16, KeyFlags)
    case off

    /// Long press of Right Option.
    public static let standard = VoiceHotkey.holdModifier(61)

    /// Parses the value gui.json stores: `"off"`, `{"kind":"hold_modifier","key_code":61}` or
    /// `{"kind":"hold_combo","key_code":49,"modifiers":786432}`. Anything invalid or missing
    /// gives `.standard`.
    public init(json: Any?) {
        if let s = json as? String, s == "off" { self = .off; return }
        guard let d = json as? [String: Any], let kind = d["kind"] as? String,
              let raw = d["key_code"] as? Int, let code = UInt16(exactly: raw)
        else { self = .standard; return }
        switch kind {
        case "hold_modifier" where voiceHoldModifierCodes.contains(code):
            self = .holdModifier(code)
        case "hold_combo":
            guard let rawMods = d["modifiers"] as? Int, rawMods >= 0 else {
                self = .standard; return
            }
            let mods = KeyFlags(rawValue: UInt64(rawMods)).intersection([.control, .option, .shift, .command])
            self = acceptsCombo(code, mods) ? .holdCombo(code, mods) : .standard
        default:
            self = .standard
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .holdModifier(let c), .holdCombo(let c, _): return c
        case .off: return nil
        }
    }
}

public enum VoiceKeyPhase: String { case start, release, cancel, edit }

public enum VoiceGateInput: Equatable {
    case down(UInt16, KeyFlags, isRepeat: Bool), up(UInt16), pointer, scroll, elapsed, resign, ended
}

public struct VoiceGateStep: Equatable {
    /// Send the held hotkey down to A first (it was swallowed while pending).
    public var flush = false
    /// This event goes on to A (pointer and scroll always do).
    public var pass = false
    /// Feed `.elapsed` in `VoiceKeyGate.holdDelay` seconds.
    public var arm = false
    public var voice: VoiceKeyPhase?
    public init(flush: Bool = false, pass: Bool = false, arm: Bool = false, voice: VoiceKeyPhase? = nil) {
        self.flush = flush; self.pass = pass; self.arm = arm; self.voice = voice
    }
}

public struct VoiceKeyGate {
    /// How long a `hold_modifier` hotkey must be held before recording starts.
    public static let holdDelay = 0.3

    public private(set) var hotkey: VoiceHotkey

    private enum State: Equatable {
        case idle
        /// The hotkey modifier is down and swallowed; a long enough hold starts recording.
        case pending(since: Double)
        case recording
        /// Recording was cancelled, sent to the editor or ended: everything is swallowed until
        /// the hotkey itself is released.
        case decided
    }

    private var state = State.idle
    /// Keys the gate has seen go down and not yet come up.
    private var down: Set<UInt16> = []
    /// Keys whose down was swallowed, so their up is swallowed too.
    private var swallowed: Set<UInt16> = []

    public init(hotkey: VoiceHotkey = .standard) { self.hotkey = hotkey }

    public var recording: Bool { state == .recording }

    /// The setting changes (关, 恢复默认 or a new key recorded) while keys may be held. A real change
    /// starts over: a hold of the old key is no hold any more, and its up never reaches the hotkey
    /// rules, so a recording is cancelled here (or it would end in `decided`, swallowing every key
    /// with no hotkey up to return it). Held and swallowed keys are kept, so the old key's up stays
    /// away from A. The caller drops its hold timer and the held down. Setting the same hotkey does
    /// nothing.
    public mutating func setHotkey(_ new: VoiceHotkey) -> VoiceGateStep {
        guard new != hotkey else { return VoiceGateStep() }
        hotkey = new
        let wasRecording = state == .recording
        state = .idle
        return VoiceGateStep(voice: wasRecording ? .cancel : nil)
    }

    public mutating func handle(_ input: VoiceGateInput, at seconds: Double, ready: Bool) -> VoiceGateStep {
        switch input {
        case let .down(code, flags, isRepeat):
            // A key already held whose down reached A: a swallowed repeat must not swallow its up
            // too, or A keeps it down (a key held before a combo start).
            let reachedA = down.contains(code) && !swallowed.contains(code)
            swallowed.remove(code)
            let step = keyDown(code, flags, isRepeat: isRepeat, at: seconds, ready: ready)
            down.insert(code)
            if step.flush { flushHotkey() }
            if !step.pass && !reachedA { swallowed.insert(code) }
            return step
        case let .up(code):
            let wasSwallowed = swallowed.remove(code) != nil
            down.remove(code)
            var step = VoiceGateStep(pass: !wasSwallowed)
            guard code == hotkey.keyCode else { return step }
            switch state {
            case .idle: break
            case .pending:
                step = VoiceGateStep(flush: true, pass: true)  // a tap: A gets the down and the up
            case .recording:
                step = VoiceGateStep(voice: .release)
            case .decided:
                step = VoiceGateStep()
            }
            state = .idle
            return step
        case .pointer, .scroll:
            var step = VoiceGateStep(pass: true)
            switch state {
            case .pending:
                step.flush = true
                flushHotkey()
                state = .idle
            case .recording where input == .pointer:
                step.voice = .cancel
                state = .decided
            default: break
            }
            return step
        case .elapsed:
            guard case let .pending(since) = state, seconds - since >= Self.holdDelay else { return VoiceGateStep() }
            state = .recording
            return VoiceGateStep(voice: .start)
        case .resign:
            // A loses the keyboard: forget what is held (its ups may never come), but keep the
            // swallowed codes so the hotkey's eventual up still stays away from A.
            let wasRecording = state == .recording
            state = .idle
            down.removeAll()
            return VoiceGateStep(voice: wasRecording ? .cancel : nil)
        case .ended:
            if state == .recording { state = .decided }
            return VoiceGateStep()
        }
    }

    /// The step for a key down; `down` and `swallowed` are updated by the caller.
    private mutating func keyDown(_ code: UInt16, _ flags: KeyFlags, isRepeat: Bool,
                                  at seconds: Double, ready: Bool) -> VoiceGateStep {
        switch state {
        case .idle:
            switch hotkey {
            case .holdModifier(let key):
                guard code == key, !isRepeat, ready, !othersDown(key, flags) else { return VoiceGateStep(pass: true) }
                state = .pending(since: seconds)
                return VoiceGateStep(arm: true)
            case let .holdCombo(key, mods):
                guard code == key, !isRepeat, ready,
                      flags.intersection([.control, .option, .shift, .command]) == mods
                else { return VoiceGateStep(pass: true) }
                state = .recording
                return VoiceGateStep(voice: .start)
            case .off:
                return VoiceGateStep(pass: true)
            }
        case .pending:
            if code == hotkey.keyCode { return VoiceGateStep() }  // a repeat of the held key
            state = .idle  // anything else pressed with the hotkey: it was a modifier for A
            return VoiceGateStep(flush: true, pass: true)
        case .recording:
            if code == 53 { state = .decided; return VoiceGateStep(voice: .cancel) }
            if code == 48 { state = .decided; return VoiceGateStep(voice: .edit) }
            return VoiceGateStep()
        case .decided:
            return VoiceGateStep()
        }
    }

    /// The held hotkey down goes to A after all, so its up must reach A too.
    private mutating func flushHotkey() {
        if let key = hotkey.keyCode { swallowed.remove(key) }
    }

    /// Whether anything besides the hotkey modifier itself is held.
    private func othersDown(_ key: UInt16, _ flags: KeyFlags) -> Bool {
        if !down.subtracting([key]).isEmpty { return true }
        let own: KeyFlags
        switch key {
        case 58, 61: own = .option
        case 59, 62: own = .control
        case 56, 60: own = .shift
        case 54, 55: own = .command
        case 63: own = .function
        default: own = []
        }
        return !flags.intersection([.control, .option, .shift, .command, .function]).subtracting(own).isEmpty
    }
}
