import Foundation
import Security

public struct UnlockCredential: Codable, Equatable {
    public let password: String
    public let auto: Bool

    public init(password: String, auto: Bool) {
        self.password = password
        self.auto = auto
    }
}

/// Only OS status codes escape this boundary; neither passwords nor decoded data enter errors.
public enum UnlockStoreError: Error {
    case invalidCredential
    case keychain(OSStatus)
}

protocol UnlockKeychain {
    func read(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemUnlockKeychain: UnlockKeychain {
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// B's remembered system password, keyed by the remote device ID. No file or cloud copy.
/// Call on the runner's serial utility queue: Keychain may need user interaction.
public final class UnlockStore {
    private let keychain: UnlockKeychain

    public convenience init() { self.init(keychain: SystemUnlockKeychain()) }
    init(keychain: UnlockKeychain) { self.keychain = keychain }

    private func query(_ device: String) throws -> [String: Any] {
        guard !device.isEmpty else { throw UnlockStoreError.invalidCredential }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.rapp.rapp.system-password",
            kSecAttrAccount as String: device,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func read(device: String) throws -> UnlockCredential? {
        var q = try query(device)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.read(q)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw UnlockStoreError.keychain(status) }
        guard let data, let credential = try? JSONDecoder().decode(UnlockCredential.self, from: data),
              credential.password.utf8.count <= 1024 else { throw UnlockStoreError.invalidCredential }
        return credential
    }

    public func save(device: String, password: String, auto: Bool) throws {
        guard password.utf8.count <= 1024 else { throw UnlockStoreError.invalidCredential }
        let q = try query(device)
        let data = try JSONEncoder().encode(UnlockCredential(password: password, auto: auto))
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = keychain.update(q, attributes: attributes)
        if status == errSecItemNotFound {
            var item = q.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = keychain.add(item)
        }
        guard status == errSecSuccess else { throw UnlockStoreError.keychain(status) }
    }

    public func forget(device: String) throws {
        let status = keychain.delete(try query(device))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UnlockStoreError.keychain(status) }
    }
}
