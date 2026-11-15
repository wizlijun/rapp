import Foundation

/// A cross-process mutex: an exclusive `flock` on a file, held while `body` runs.
public enum FileLock {
    public struct OpenFailed: Error { public let errno: Int32 }

    /// Creates the file and its directory when missing, blocks until the lock is free, runs `body`,
    /// then unlocks and closes, also when `body` throws.
    public static func exclusive<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw OpenFailed(errno: errno) }
        defer { close(fd) } // closing also drops the lock
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw OpenFailed(errno: errno) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
