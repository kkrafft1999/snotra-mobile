import Foundation

/// Why a request to the desktop came back without a result.
enum RemoteCallError: Error, Equatable, Sendable {
    /// The desktop's answer (remote-interface.md §6.3): `reason` is the stable
    /// part, `message` already worded in the connection's language, `why` the
    /// detail some refusals carry (`workspace.activate`'s `busy`).
    case desktop(code: Int, reason: String, message: String, why: String?)
    /// No session stands, and none came up in time.
    case notConnected
    /// The session ended before the answer came.
    case sessionEnded
    /// The desktop did not answer in time.
    case timedOut
    /// The answer was not the shape the method promises.
    case malformedAnswer

    var reason: String? {
        if case .desktop(_, let reason, _, _) = self { reason } else { nil }
    }

    /// The error object of a JSON-RPC answer.
    init(rpcError error: JSONValue) {
        self = .desktop(
            code: error["code"]?.numberValue.map { Int($0) } ?? -32603,
            reason: error["data"]?["reason"]?.stringValue ?? "internal",
            message: error["message"]?.stringValue ?? "",
            why: error["data"]?["why"]?.stringValue)
    }
}

/// `session.hello` (remote-interface.md §8.1), the first message of every session.
enum SessionHello {
    static let protocolVersions: [Int] = [1]
    static let clientName = "Snotra for iPhone"

    static func params(locale: String, version: String) -> JSONValue {
        .object([
            "protocol": .array(protocolVersions.map { .number(Double($0)) }),
            "client": .object(["name": .string(clientName), "version": .string(String(version.prefix(32)))]),
            "locale": .string(locale),
            // The cards of the chats the phone follows, answered with *allow once* or *deny* (§7.4).
            // `knowledge-cards`: this app shows a card about a knowledge file in full
            // (snotra#1319); without it the desktop lets the phone only deny one.
            "capabilities": .array([.string("approvals"), .string("knowledge-cards")]),
        ])
    }

    /// `en` or `de`, whichever the app shows itself in.
    static var appLocale: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true ? "de" : "en"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// What the desktop says about this connection.
    struct Welcome: Decodable, Equatable, Sendable {
        let protocolVersion: Int
        let connectionId: String
        let methods: [String]

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol", connectionId, methods
        }
    }
}

extension JSONValue {
    /// A `Decodable` from this value, through its JSON.
    func decoded<T: Decodable>(as type: T.Type) throws(RemoteCallError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data())
        } catch {
            throw .malformedAnswer
        }
    }
}
