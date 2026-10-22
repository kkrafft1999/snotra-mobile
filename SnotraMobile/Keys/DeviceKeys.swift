import CryptoKit
import Foundation
import Security

/// The phone's long-term identity (remote protocol §3): a P-256 key to sign and
/// one to agree, in the Secure Enclave. Their private halves never leave it.
struct DeviceKeys {
    fileprivate enum Keys {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey, SecureEnclave.P256.KeyAgreement.PrivateKey)
        /// The simulator has no Secure Enclave; there, and only there, the keys are software keys.
        case software(P256.Signing.PrivateKey, P256.KeyAgreement.PrivateKey)
    }

    fileprivate let keys: Keys

    var bundle: KeyBundle {
        switch keys {
        case .secureEnclave(let sign, let agree): KeyBundle(sign: sign.publicKey, agree: agree.publicKey)
        case .software(let sign, let agree): KeyBundle(sign: sign.publicKey, agree: agree.publicKey)
        }
    }

    var isInSecureEnclave: Bool {
        if case .secureEnclave = keys { true } else { false }
    }

    /// ECDSA over SHA-256 in P1363 form, 64 bytes, as every proof to the relay needs (§5).
    func sign(_ message: Data) throws -> Data {
        switch keys {
        case .secureEnclave(let sign, _): try sign.signature(for: message).rawRepresentation
        case .software(let sign, _): try sign.signature(for: message).rawRepresentation
        }
    }

    /// The static P-256 agreement with the desktop's agree key: `ss` of §14, raw.
    func agree(with desktopKey: P256.KeyAgreement.PublicKey) throws -> Data {
        switch keys {
        case .secureEnclave(_, let agree): SessionKeys.rawBytes(of: try agree.sharedSecretFromKeyAgreement(with: desktopKey))
        case .software(_, let agree): SessionKeys.rawBytes(of: try agree.sharedSecretFromKeyAgreement(with: desktopKey))
        }
    }
}

/// Creates, keeps and deletes the phone's keys. What is stored is the Secure
/// Enclave's encrypted `dataRepresentation` of each key — usable only by this
/// device's Secure Enclave — in a store that keeps it this device only.
struct DeviceKeyStore {
    enum Kind {
        case secureEnclave
        case software
    }

    enum Failure: Error, Equatable {
        case secureEnclaveUnavailable
        /// One key without the other: a broken identity, to be deleted and paired again.
        case incomplete
    }

    static let signAccount = "device-key.sign"
    static let agreeAccount = "device-key.agree"

    /// The Secure Enclave on a device, software keys in the simulator.
    static var defaultKind: Kind {
        #if targetEnvironment(simulator)
        .software
        #else
        .secureEnclave
        #endif
    }

    let store: any SecretStore
    let kind: Kind

    init(store: any SecretStore = KeychainStore(service: "dev.snotra-ai.mobile.keys"), kind: Kind = defaultKind) {
        self.store = store
        self.kind = kind
    }

    /// The stored keys, or nil when the phone has none yet.
    func load() throws -> DeviceKeys? {
        let sign = try store.read(Self.signAccount), agree = try store.read(Self.agreeAccount)
        switch (sign, agree) {
        case (nil, nil):
            return nil
        case (let sign?, let agree?):
            switch kind {
            case .secureEnclave:
                return DeviceKeys(keys: .secureEnclave(
                    try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: sign),
                    try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: agree)))
            case .software:
                return DeviceKeys(keys: .software(
                    try P256.Signing.PrivateKey(rawRepresentation: sign),
                    try P256.KeyAgreement.PrivateKey(rawRepresentation: agree)))
            }
        default:
            throw Failure.incomplete
        }
    }

    /// Creates a fresh pair and replaces whatever was stored — once per pairing.
    func create() throws -> DeviceKeys {
        let keys: DeviceKeys
        let sign: Data, agree: Data
        switch kind {
        case .secureEnclave:
            guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
            let access = try Self.accessControl()
            let signKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            let agreeKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            keys = DeviceKeys(keys: .secureEnclave(signKey, agreeKey))
            (sign, agree) = (signKey.dataRepresentation, agreeKey.dataRepresentation)
        case .software:
            let signKey = P256.Signing.PrivateKey(), agreeKey = P256.KeyAgreement.PrivateKey()
            keys = DeviceKeys(keys: .software(signKey, agreeKey))
            (sign, agree) = (signKey.rawRepresentation, agreeKey.rawRepresentation)
        }
        try delete()
        try store.write(sign, account: Self.signAccount)
        try store.write(agree, account: Self.agreeAccount)
        return keys
    }

    func loadOrCreate() throws -> DeviceKeys {
        try load() ?? create()
    }

    /// For *Disconnect*, a removed phone or a wrong `MAC_D`: the identity is gone,
    /// and a new pairing starts with new keys.
    func delete() throws {
        try store.delete(Self.signAccount)
        try store.delete(Self.agreeAccount)
    }

    /// Usable only while the phone is unlocked, and only on this device.
    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        return access
    }
}
