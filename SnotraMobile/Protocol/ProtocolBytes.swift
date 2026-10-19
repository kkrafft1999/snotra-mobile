import Foundation

/// The byte conventions of the remote protocol (Snotra `docs/remote-protocol.md` §2).
enum ProtocolBytes {
    /// `u16(n)`: two bytes, big-endian.
    static func u16(_ value: Int) -> Data {
        precondition((0...Int(UInt16.max)).contains(value), "u16 out of range: \(value)")
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// `u64be(n)`: eight bytes, big-endian.
    static func u64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// `lp(x) = u16(len(x)) ‖ x`, used for every variable-length part of anything
    /// hashed, signed or MACed.
    static func lp(_ bytes: Data) -> Data {
        u16(bytes.count) + bytes
    }

    /// `lp` over UTF-8 text, as for labels and roles.
    static func lp(_ text: String) -> Data {
        lp(Data(text.utf8))
    }
}

extension Data {
    /// Decodes base64url without padding (RFC 4648 §5); nil for anything else.
    init?(base64URL text: String) {
        guard !text.contains("="), !text.contains("+"), !text.contains("/") else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    /// Base64url without padding — binary values inside JSON.
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lower-case hex, as the protocol writes `sid` in paths.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
