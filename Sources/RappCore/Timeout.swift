import Foundation

public struct TimeoutError: Error {
    public init() {}
}

/// Runs `operation`, giving up after `seconds` with `TimeoutError`.
///
/// Deliberately not a task group: a group waits for every child before it
/// returns, so a system call that ignores cancellation would hold it forever.
/// Here the operation runs in its own task; if it never finishes it is simply
/// left behind and its late result is ignored.
public func withTimeout<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
    let done = NSLock()
    var finished = false
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        func finish(_ result: Result<T, Error>) {
            let first: Bool = done.withLock {
                defer { finished = true }
                return !finished
            }
            if first { continuation.resume(with: result) }
        }
        let work = Task {
            do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            finish(.failure(TimeoutError()))
            work.cancel()
        }
    }
}
