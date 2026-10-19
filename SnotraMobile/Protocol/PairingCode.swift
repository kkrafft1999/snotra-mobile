import CryptoKit
import Foundation

/// The code the desktop shows as a QR code and as a typed key (§4): a pairing id
/// of 4 symbols, a secret of 15 and a check symbol, in Crockford's base32.
struct PairingCode: Equatable, Sendable {
    enum Failure: String, Error, Sendable {
        case invalidSymbol = "invalid-symbol"
        case invalidLength = "invalid-length"
        case invalidCheck = "invalid-check"
        /// A scanned code that is not a `snotra-pair:` payload at all.
        case notAPairingCode = "not-a-pairing-code"
        /// A `snotra-pair:` payload of a protocol version this app does not speak.
        case unsupportedVersion = "protocol-unsupported"
        /// A QR code that names a relay the app does not ship with.
        case unknownRelay = "unknown-relay"
    }

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 20
    static let qrPrefix = "snotra-pair:v1/"
    private static let checkLabel = "snotra/v1 code-check"

    /// The twenty canonical symbols.
    let symbols: String

    /// Builds the code from its two parts, as the desktop does; adds the check symbol.
    init(pairingId: String, secret: String) {
        let body = pairingId + secret
        precondition(body.count == Self.length - 1 && body.allSatisfy(Self.alphabet.contains))
        symbols = body + String(Self.checkSymbol(for: body))
    }

    private init(canonical: String) {
        symbols = canonical
    }

    var pairingId: String { String(symbols.prefix(4)) }
    var secret: String { String(symbols.dropFirst(4).prefix(15)) }
    var check: String { String(symbols.suffix(1)) }

    /// The typed key: groups of four joined by `-`.
    var display: String {
        stride(from: 0, to: Self.length, by: 4).map { offset in
            let start = symbols.index(symbols.startIndex, offsetBy: offset)
            return String(symbols[start..<symbols.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// The MAC key `K`: the code's twenty ASCII bytes.
    var macKey: SymmetricKey { SymmetricKey(data: Data(symbols.utf8)) }

    func qrPayload(relayHost: String) -> String {
        Self.qrPrefix + relayHost + "/" + symbols
    }

    /// Reads what a person typed: ignores case, `-` and white space, reads `O` as
    /// `0` and `I` or `L` as `1`.
    static func parse(typed input: String) throws(Failure) -> PairingCode {
        var canonical = ""
        for character in input.uppercased() {
            switch character {
            case "-": continue
            case _ where character.isWhitespace: continue
            case "O": canonical.append("0")
            case "I", "L": canonical.append("1")
            case _ where alphabet.contains(character): canonical.append(character)
            default: throw .invalidSymbol
            }
        }
        guard canonical.count == length else { throw .invalidLength }
        guard checkSymbol(for: String(canonical.prefix(length - 1))) == canonical.last else {
            throw .invalidCheck
        }
        return PairingCode(canonical: canonical)
    }

    /// Reads a scanned QR payload. Only relay hosts in `allowedHosts` are accepted,
    /// so that a QR code cannot send the phone to a relay of somebody else's choosing.
    static func parse(qr payload: String, allowedHosts: Set<String>) throws(Failure)
        -> (relayHost: String, code: PairingCode) {
        guard payload.hasPrefix("snotra-pair:") else { throw .notAPairingCode }
        guard payload.hasPrefix(qrPrefix) else { throw .unsupportedVersion }
        let parts = payload.dropFirst(qrPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw .notAPairingCode }
        let host = String(parts[0])
        guard allowedHosts.contains(host) else { throw .unknownRelay }
        let symbols = String(parts[1])
        guard symbols.allSatisfy(alphabet.contains) else { throw .invalidSymbol }
        return (host, try parse(typed: symbols))
    }

    /// The top five bits of `SHA-256(lp(label) ‖ ascii(first 19 symbols))`.
    static func checkSymbol(for firstNineteen: String) -> Character {
        let digest = SHA256.hash(data: ProtocolBytes.lp(checkLabel) + Data(firstNineteen.utf8))
        return alphabet[Int(Array(digest)[0] >> 3)]
    }
}
