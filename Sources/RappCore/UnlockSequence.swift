/// The lock-screen input sequence. Re-check immediately before each input step: the user may
/// unlock locally while we wait for the password field, or while a long password is being typed.
/// Platform event posting is injected so the cancellation boundaries can be tested without input.
public func typeUnlockPassword(_ password: String, isLocked: () -> Bool, wake: () -> Void,
                               wait: (UInt32) -> Void, typeChunk: ([UInt16]) -> Void, pressReturn: () -> Void) {
    guard isLocked() else { return }
    wake()
    wait(1_000_000)
    for chunk in chunkUTF16(password) {
        guard isLocked() else { return }
        typeChunk(chunk)
        wait(5_000)
    }
    wait(50_000)
    guard isLocked() else { return }
    pressReturn()
}
