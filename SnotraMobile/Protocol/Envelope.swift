import CryptoKit
import Foundation

/// One JSON-RPC message in the channel, sealed with ChaCha20-Poly1305 (§15).
enum Envelope {
    enum Direction: String, Sendable {
        case toDesktop = "to-desktop"
        case toPhone = "to-phone"
    }

    enum Failure: Error, Equatable {
        case tooLarge
        case doesNotOpen
    }

    /// At most 256 KiB of plaintext per envelope.
    static let maxPlaintext = 256 * 1024

    /// `0x00000000 ‖ u64be(counter)`.
    static func nonce(counter: UInt64) -> Data {
        Data(count: 4) + ProtocolBytes.u64(counter)
    }

    /// `lp(label) ‖ lp(sid) ‖ lp(direction) ‖ u64be(counter)`, `sid` as its 8 raw bytes.
    static func associatedData(sid: Data, direction: Direction, counter: UInt64) -> Data {
        ProtocolBytes.lp("snotra/v1 envelope") + ProtocolBytes.lp(sid)
            + ProtocolBytes.lp(direction.rawValue) + ProtocolBytes.u64(counter)
    }

    /// `/channels/{channelId}/{direction}/{sid}/{counter}`, the counter as 16 hex
    /// digits so that the keys sort as numbers.
    static func path(channelId: Data, direction: Direction, sid: Data, counter: UInt64) -> String {
        "/channels/\(channelId.base64URLEncodedString)/\(direction.rawValue)/\(sid.hexString)/"
            + String(format: "%016llx", counter)
    }

    /// The record's `c`: ciphertext ‖ 16-byte tag.
    static func seal(_ plaintext: Data, keys: SessionKeys, direction: Direction, counter: UInt64)
        throws -> Data {
        guard plaintext.count <= maxPlaintext else { throw Failure.tooLarge }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key(keys, direction),
            nonce: ChaChaPoly.Nonce(data: nonce(counter: counter)),
            authenticating: associatedData(sid: keys.sid, direction: direction, counter: counter)
        )
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, keys: SessionKeys, direction: Direction, counter: UInt64)
        throws(Failure) -> Data {
        do {
            guard sealed.count >= 16 else { throw Failure.doesNotOpen }
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce(counter: counter)),
                ciphertext: sealed.dropLast(16),
                tag: sealed.suffix(16)
            )
            let plaintext = try ChaChaPoly.open(
                box, using: key(keys, direction),
                authenticating: associatedData(sid: keys.sid, direction: direction, counter: counter)
            )
            guard plaintext.count <= maxPlaintext else { throw Failure.tooLarge }
            return plaintext
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .doesNotOpen
        }
    }

    private static func key(_ keys: SessionKeys, _ direction: Direction) -> SymmetricKey {
        direction == .toDesktop ? keys.toDesktop : keys.toPhone
    }
}

/// The receiver's order rule (§16): per session and direction, the next counter
/// it expects from the other side, and the envelopes it holds until a gap fills.
/// The five-second limit on a gap belongs to the caller, which owns the clock.
struct ReceiveWindow<Message> {
    enum Outcome {
        /// Deliver these messages, in order.
        case deliver([(counter: UInt64, message: Message)])
        /// Held until the gap before it fills.
        case hold
        /// A replay: already delivered or already held.
        case drop
        /// Too far ahead: end the session; the phone starts a new handshake.
        case startOver
    }

    static var holdWindow: UInt64 { 32 }

    private(set) var next: UInt64 = 0
    private var held: [UInt64: Message] = [:]

    var hasGap: Bool { !held.isEmpty }

    mutating func receive(counter: UInt64, message: Message) -> Outcome {
        if counter < next || held[counter] != nil { return .drop }
        if counter > next + Self.holdWindow { return .startOver }
        guard counter == next else {
            held[counter] = message
            return .hold
        }
        var delivered = [(counter: counter, message: message)]
        next += 1
        while let following = held.removeValue(forKey: next) {
            delivered.append((counter: next, message: following))
            next += 1
        }
        return .deliver(delivered)
    }
}
