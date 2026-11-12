/// How many announced device names a host keeps (R2).
public let peerNamesKept = 16

/// The device names rapp-service announced on stdin, by the peer port of its connection to this worker (R2).
/// Holds the newest `peerNamesKept`; naming a port again makes it the newest.
public struct PeerNames {
    private var entries: [(port: UInt16, name: String)] = []

    public init() {}

    public var count: Int { entries.count }

    public mutating func set(_ name: String, for port: UInt16) {
        entries.removeAll { $0.port == port }
        entries.append((port, name))
        if entries.count > peerNamesKept { entries.removeFirst(entries.count - peerNamesKept) }
    }

    /// The name announced for `port`; nil when none was (the device is shown without a name).
    public subscript(port: UInt16) -> String? {
        entries.last { $0.port == port }?.name
    }
}
