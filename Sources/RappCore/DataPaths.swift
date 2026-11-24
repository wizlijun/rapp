import Foundation

/// Where rApp keeps its data. Same rules as the Rust side (`home_from`): `RAPP_HOME`,
/// then the first line of the `data-root` pointer file (absolute paths only), then `~/rapp`.
/// An empty environment value counts as unset.
public enum DataPaths {
    public static func root(env: [String: String], home: URL, read: (URL) -> String? = DataPaths.readFile) -> URL {
        if let h = env["RAPP_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        let pointer = home.appendingPathComponent("Library/Application Support/rapp/data-root")
        if let text = read(pointer) {
            let line = (text.components(separatedBy: .newlines).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("/") { return URL(fileURLWithPath: line, isDirectory: true) }
        }
        return home.appendingPathComponent("rapp", isDirectory: true)
    }

    /// Received and downloaded files: `RAPP_DOWNLOADS` (non-empty), else `<root>/files/transfers`.
    public static func transfers(env: [String: String], home: URL, read: (URL) -> String? = DataPaths.readFile) -> URL {
        if let d = env["RAPP_DOWNLOADS"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return root(env: env, home: home, read: read).appendingPathComponent("files/transfers", isDirectory: true)
    }

    /// Machine-local lock for typing the unlock password, next to the `data-root` pointer (never in the synced data dir).
    public static func unlockLockFile(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/rapp/unlock.lock")
    }

    public static func readFile(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// `transfers` for this process.
    public static func currentTransfers() -> URL {
        #if os(macOS)
        return transfers(env: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
        #else
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/传输", isDirectory: true)
        #endif
    }
}
