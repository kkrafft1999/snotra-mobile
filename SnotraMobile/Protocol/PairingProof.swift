import CryptoKit
import Foundation

/// The messages each side signs to prove a call to the relay (§5), and the
/// signature format: ECDSA P-256 over SHA-256, IEEE P1363 `r ‖ s`, 64 bytes.
enum PairingProof {
    enum Role: String, Sendable {
        case desktop
        case phone
    }

    /// The desktop's proof when it opens a pairing (§5.3).
    static func pairOpenMessage(challenge: Data, desktopKeys: KeyBundle) -> Data {
        ProtocolBytes.lp("snotra/v1 pair-open") + ProtocolBytes.lp(challenge) + desktopKeys.bytes
    }

    /// The phone's proof when it claims a pairing (§5.5).
    static func pairClaimMessage(challenge: Data, channelId: Data, phoneKeys: KeyBundle) -> Data {
        ProtocolBytes.lp("snotra/v1 pair-claim") + ProtocolBytes.lp(challenge)
            + ProtocolBytes.lp(channelId) + phoneKeys.bytes
    }

    /// Either side's proof for a token (§5.9).
    static func tokenMessage(challenge: Data, channelId: Data, role: Role) -> Data {
        ProtocolBytes.lp("snotra/v1 token") + ProtocolBytes.lp(challenge)
            + ProtocolBytes.lp(channelId) + ProtocolBytes.lp(role.rawValue)
    }

    static func sign(_ message: Data, with key: P256.Signing.PrivateKey) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }

    static func verify(_ signature: Data, of message: Data, by key: P256.Signing.PublicKey) -> Bool {
        guard signature.count == 64,
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return key.isValidSignature(parsed, for: message)
    }
}
