import Foundation
import Security

/// Where the app keeps small secrets by name. The Keychain in the app, memory in tests.
protocol SecretStore {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(_ account: String) throws
}

/// Generic-password items in the Keychain, all `WhenUnlockedThisDeviceOnly`
/// (concept §8): never in iCloud Keychain, never in a backup, unreadable while
/// the phone is locked.
struct KeychainStore: SecretStore {
    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    let service: String

    func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case let status: throw Failure(status: status)
        }
    }

    func write(_ data: Data, account: String) throws {
        try delete(account)
        var item = baseQuery(account)
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// The accessibility class an item was stored with, for tests.
    func accessibility(of account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Failure(status: status) }
        return (result as? [CFString: Any])?[kSecAttrAccessible] as? String
    }

    private func baseQuery(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
    }
}
