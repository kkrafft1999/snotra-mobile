import CryptoKit
import Foundation

/// One side's two long-term public keys (§3): P-256 for signing and for key
/// agreement, each as the uncompressed SEC1 point `0x04 ‖ X ‖ Y`.
struct KeyBundle: Equatable, Sendable {
    enum InvalidKey: Error { case notAnUncompressedP256Point }

    let sign: Data
    let agree: Data

    init(sign: Data, agree: Data) throws(InvalidKey) {
        guard Self.isPoint(sign), Self.isPoint(agree) else { throw .notAnUncompressedP256Point }
        self.sign = sign
        self.agree = agree
    }

    init(sign: P256.Signing.PublicKey, agree: P256.KeyAgreement.PublicKey) {
        self.sign = sign.x963Representation
        self.agree = agree.x963Representation
    }

    /// `KB = lp(sign) ‖ lp(agree)`.
    var bytes: Data {
        ProtocolBytes.lp(sign) + ProtocolBytes.lp(agree)
    }

    var signingKey: P256.Signing.PublicKey {
        get throws { try P256.Signing.PublicKey(x963Representation: sign) }
    }

    var agreementKey: P256.KeyAgreement.PublicKey {
        get throws { try P256.KeyAgreement.PublicKey(x963Representation: agree) }
    }

    private static func isPoint(_ bytes: Data) -> Bool {
        bytes.count == 65 && bytes.first == 0x04
            && (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil
    }
}

extension KeyBundle: Codable {
    private enum CodingKeys: String, CodingKey { case sign, agree }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let sign = Data(base64URL: try container.decode(String.self, forKey: .sign)),
              let agree = Data(base64URL: try container.decode(String.self, forKey: .agree))
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Key is not base64url"))
        }
        try self.init(sign: sign, agree: agree)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sign.base64URLEncodedString, forKey: .sign)
        try container.encode(agree.base64URLEncodedString, forKey: .agree)
    }
}
