import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

/// In memory, so the key store's logic runs without a Keychain.
final class MemoryStore: SecretStore {
    var items: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { items[account] }
    func write(_ data: Data, account: String) throws { items[account] = data }
    func delete(_ account: String) throws { items[account] = nil }
}

struct DeviceKeysTests {
    let store = MemoryStore()
    var keyStore: DeviceKeyStore { DeviceKeyStore(store: store, kind: .software) }

    @Test func createdKeysLoadAgainAndAreDeleted() throws {
        #expect(try keyStore.load() == nil)
        let created = try keyStore.create()
        #expect(try keyStore.load()?.bundle == created.bundle)
        #expect(try keyStore.loadOrCreate().bundle == created.bundle)
        try keyStore.delete()
        #expect(try keyStore.load() == nil)
        #expect(store.items.isEmpty)
    }

    @Test func aNewPairingGetsNewKeys() throws {
        let first = try keyStore.create()
        let second = try keyStore.create()
        #expect(first.bundle != second.bundle)
        #expect(try keyStore.load()?.bundle == second.bundle)
    }

    @Test func oneKeyWithoutTheOtherIsRefused() throws {
        _ = try keyStore.create()
        try store.delete(DeviceKeyStore.agreeAccount)
        #expect(throws: DeviceKeyStore.Failure.incomplete) { try keyStore.load() }
    }

    @Test func aLoadedKeySignsWhatTheProtocolVerifies() throws {
        _ = try keyStore.create()
        let keys = try #require(try keyStore.load())
        let message = PairingProof.tokenMessage(challenge: Data(repeating: 7, count: 32),
                                                channelId: Data(repeating: 1, count: 16), role: .phone)
        let signature = try keys.sign(message)
        #expect(signature.count == 64)
        #expect(PairingProof.verify(signature, of: message, by: try keys.bundle.signingKey))
    }

    @Test func aLoadedKeyAgreesWithTheDesktop() throws {
        _ = try keyStore.create()
        let keys = try #require(try keyStore.load())
        let desktop = P256.KeyAgreement.PrivateKey()
        let phoneSide = try keys.agree(with: desktop.publicKey)
        let desktopSide = try SessionKeys.rawBytes(of: desktop.sharedSecretFromKeyAgreement(with: keys.bundle.agreementKey))
        #expect(phoneSide == desktopSide && phoneSide.count == 32)
    }

    @Test func theSimulatorUsesSoftwareKeysAndADeviceTheSecureEnclave() {
        #if targetEnvironment(simulator)
        #expect(DeviceKeyStore.defaultKind == .software)
        #else
        #expect(DeviceKeyStore.defaultKind == .secureEnclave)
        #endif
    }

    @Test(.enabled(if: SecureEnclave.isAvailable, "Needs a device with a Secure Enclave"))
    func secureEnclaveKeysRoundTrip() throws {
        let keyStore = DeviceKeyStore(store: store, kind: .secureEnclave)
        let created = try keyStore.create()
        #expect(created.isInSecureEnclave)
        let loaded = try #require(try keyStore.load())
        #expect(loaded.bundle == created.bundle)
        let message = Data("snotra".utf8)
        #expect(PairingProof.verify(try loaded.sign(message), of: message, by: try loaded.bundle.signingKey))
    }
}

/// Whether the test host may use the Keychain at all (an unsigned CI build may not).
enum KeychainProbe {
    static let store = KeychainStore(service: "dev.snotra-ai.mobile.tests")

    static var isUsable: Bool {
        (try? store.write(Data([1]), account: "probe")) != nil && (try? store.delete("probe")) != nil
    }
}

/// The real Keychain, where the test host may use one.
@Suite(.enabled(if: KeychainProbe.isUsable, "Keychain not available to this test host"))
struct KeychainStoreTests {
    @Test func itemsAreKeptOnThisDeviceOnlyAndWhileUnlocked() throws {
        let store = KeychainProbe.store
        defer { try? store.delete("item") }
        try store.write(Data("one".utf8), account: "item")
        try store.write(Data("two".utf8), account: "item")
        #expect(try store.read("item") == Data("two".utf8))
        #expect(try store.accessibility(of: "item") == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try store.delete("item")
        #expect(try store.read("item") == nil)
    }
}
