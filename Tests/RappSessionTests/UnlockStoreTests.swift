import Foundation
import Security
import XCTest
@testable import RappSession

final class UnlockStoreTests: XCTestCase {
    func testCredentialLivesInLocalKeychainAndCanBeReplacedAndForgotten() throws {
        let keychain = FakeUnlockKeychain()
        let store = UnlockStore(keychain: keychain)
        XCTAssertNil(try store.read(device: "A"))
        try store.save(device: "A", password: "pässword", auto: true)
        XCTAssertEqual(try store.read(device: "A"), UnlockCredential(password: "pässword", auto: true))
        XCTAssertNil(try store.read(device: "B"))
        XCTAssertEqual(keychain.lastQuery[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(keychain.lastQuery[kSecAttrService as String] as? String, "com.rapp.rapp.system-password")
        XCTAssertEqual(keychain.lastAdded[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try store.save(device: "A", password: "replacement", auto: false)
        XCTAssertEqual(try store.read(device: "A"), UnlockCredential(password: "replacement", auto: false))
        try store.forget(device: "A")
        XCTAssertNil(try store.read(device: "A"))
        XCTAssertNoThrow(try store.forget(device: "A"))
    }

    func testInvalidOrFailedWritesAreNotSilentlyAccepted() throws {
        let keychain = FakeUnlockKeychain()
        let store = UnlockStore(keychain: keychain)
        XCTAssertThrowsError(try store.save(device: "A", password: String(repeating: "密", count: 342), auto: true))
        XCTAssertThrowsError(try store.save(device: "", password: "secret", auto: true))
        XCTAssertTrue(keychain.items.isEmpty)
        keychain.failure = errSecAuthFailed
        XCTAssertThrowsError(try store.save(device: "A", password: "secret", auto: true)) { error in
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
        XCTAssertThrowsError(try store.read(device: "A"))
        XCTAssertThrowsError(try store.forget(device: "A"))
    }
}

private final class FakeUnlockKeychain: UnlockKeychain {
    var items = [String: Data]()
    var lastQuery = [String: Any]()
    var lastAdded = [String: Any]()
    var failure: OSStatus?
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        lastQuery = query
        if let failure { return (failure, nil) }
        let data = items[query[kSecAttrAccount as String] as! String]
        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lastAdded = attributes
        if let failure { return failure }
        let account = attributes[kSecAttrAccount as String] as! String
        if items[account] != nil { return errSecDuplicateItem }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lastQuery = query
        if let failure { return failure }
        let account = query[kSecAttrAccount as String] as! String
        guard items[account] != nil else { return errSecItemNotFound }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lastQuery = query
        if let failure { return failure }
        return items.removeValue(forKey: query[kSecAttrAccount as String] as! String) == nil ? errSecItemNotFound : errSecSuccess
    }
}
