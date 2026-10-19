import CryptoKit
import Foundation

/// The two handshake records (§13). Neither is signed: authentication comes
/// from the long-term agreement inside the key derivation (§14).
enum Handshake {
    /// The protocol versions this app speaks, in the order it prefers them.
    static let supportedVersions: [UInt8] = [1]

    /// Handshake 1, written by the phone to `/channels/{id}/handshake/phone`.
    struct Offer: Codable, Equatable, Sendable {
        let v: [UInt8]
        let e: String

        init(versions: [UInt8] = Handshake.supportedVersions, ephemeral: Curve25519.KeyAgreement.PublicKey) {
            v = versions
            e = ephemeral.rawRepresentation.base64URLEncodedString
        }
    }

    /// Handshake 2, written by the desktop to `/channels/{id}/handshake/desktop`:
    /// the version chosen and its ephemeral key, or `protocol-unsupported` with
    /// the versions it speaks.
    enum Answer: Equatable, Sendable {
        case accepted(version: UInt8, ephemeral: Data)
        case unsupported(desktopVersions: [UInt8])
    }

    static func decodeAnswer(_ json: Data) throws -> Answer {
        struct Record: Decodable {
            let error: String?
            let v: Version
            let e: String?
            enum Version: Decodable {
                case one(UInt8), many([UInt8])
                init(from decoder: any Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let value = try? container.decode(UInt8.self) { self = .one(value) }
                    else { self = .many(try container.decode([UInt8].self)) }
                }
            }
        }
        let record = try JSONDecoder().decode(Record.self, from: json)
        switch (record.error, record.v, record.e.flatMap(Data.init(base64URL:))) {
        case ("protocol-unsupported", .many(let versions), _):
            return .unsupported(desktopVersions: versions)
        case (nil, .one(let version), .some(let ephemeral)) where ephemeral.count == 32:
            return .accepted(version: version, ephemeral: ephemeral)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a handshake answer"))
        }
    }

    /// The answer the desktop gives (here for the vectors and a future reference
    /// test): the highest version both speak, or `nil` for `protocol-unsupported`.
    static func chosenVersion(offered: [UInt8], spoken: [UInt8] = supportedVersions) -> UInt8? {
        offered.filter(spoken.contains).max()
    }

    /// `th = SHA-256(lp(label) ‖ lp(channelId) ‖ KB_D ‖ KB_P ‖ lp(offered) ‖ lp(e_P) ‖ u8(chosen) ‖ lp(e_D))`.
    static func transcriptHash(
        channelId: Data, desktopKeys: KeyBundle, phoneKeys: KeyBundle,
        offered: [UInt8], phoneEphemeral: Data, chosen: UInt8, desktopEphemeral: Data
    ) -> Data {
        var input = ProtocolBytes.lp("snotra/v1 handshake") + ProtocolBytes.lp(channelId)
        input += desktopKeys.bytes + phoneKeys.bytes
        input += ProtocolBytes.lp(Data(offered)) + ProtocolBytes.lp(phoneEphemeral)
        input += Data([chosen]) + ProtocolBytes.lp(desktopEphemeral)
        return Data(SHA256.hash(data: input))
    }
}

/// What both sides derive from a handshake (§14).
struct SessionKeys: Sendable {
    let toDesktop: SymmetricKey
    let toPhone: SymmetricKey
    /// The first 8 bytes of `th`; its 16 hex digits name the session in paths.
    let sid: Data

    var sidHex: String { sid.hexString }

    /// `okm = HKDF-SHA256(ikm = ss ‖ ee, salt = th, info = lp(label), L = 64)`.
    /// `staticShared` is the P-256 agreement of the long-term keys — on the phone
    /// it comes from the Secure Enclave, so it is passed in rather than computed here.
    init(staticShared: Data, ephemeralShared: Data, transcriptHash: Data) {
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: staticShared + ephemeralShared),
            salt: transcriptHash,
            info: ProtocolBytes.lp("snotra/v1 session"),
            outputByteCount: 64
        ).withUnsafeBytes { Data($0) }
        toDesktop = SymmetricKey(data: okm.prefix(32))
        toPhone = SymmetricKey(data: okm.suffix(32))
        sid = Data(transcriptHash.prefix(8))
    }

    /// The x-coordinate of an ECDH or X25519 agreement, as raw bytes.
    static func rawBytes(of secret: SharedSecret) -> Data {
        secret.withUnsafeBytes { Data($0) }
    }
}
