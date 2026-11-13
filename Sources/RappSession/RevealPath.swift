import Foundation

/// The file to show in Finder for `path`, only if it is an existing item inside one of `roots`
/// (after `..` and symlinks are resolved); nil otherwise.
public func revealableURL(_ path: String, within roots: [URL]) -> URL? {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    for root in roots {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = url.pathComponents
        if parts.count >= base.count, Array(parts.prefix(base.count)) == base { return url }
    }
    return nil
}
