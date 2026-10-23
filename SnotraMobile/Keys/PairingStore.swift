import Foundation

/// What the phone keeps of a finished pairing (concept §8): the relay, the
/// channel and the desktop's public keys. Its own keys stay in `DeviceKeyStore`.
struct PairingRecord: Codable, Equatable, Sendable {
    let relayHost: String
    let channelId: Data
    let desktopKeys: KeyBundle

    private enum CodingKeys: String, CodingKey { case relayHost, channelId, desktopKeys }

    init(relayHost: String, channelId: Data, desktopKeys: KeyBundle) {
        self.relayHost = relayHost
        self.channelId = channelId
        self.desktopKeys = desktopKeys
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relayHost = try container.decode(String.self, forKey: .relayHost)
        guard let channelId = Data(base64URL: try container.decode(String.self, forKey: .channelId)) else {
            throw DecodingError.dataCorruptedError(forKey: .channelId, in: container, debugDescription: "Not base64url")
        }
        self.channelId = channelId
        desktopKeys = try container.decode(KeyBundle.self, forKey: .desktopKeys)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(relayHost, forKey: .relayHost)
        try container.encode(channelId.base64URLEncodedString, forKey: .channelId)
        try container.encode(desktopKeys, forKey: .desktopKeys)
    }
}

/// The one pairing this phone has, in the Keychain, this device only (#27).
struct PairingStore {
    static let account = "pairing"

    let store: any SecretStore

    init(store: any SecretStore = KeychainStore(service: "dev.snotra-ai.mobile.pairing")) {
        self.store = store
    }

    func load() throws -> PairingRecord? {
        try store.read(Self.account).map { try JSONDecoder().decode(PairingRecord.self, from: $0) }
    }

    func save(_ record: PairingRecord) throws {
        try store.write(try JSONEncoder().encode(record), account: Self.account)
    }

    func delete() throws {
        try store.delete(Self.account)
    }
}
