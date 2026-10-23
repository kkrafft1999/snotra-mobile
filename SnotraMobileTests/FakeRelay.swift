import CryptoKit
import Foundation
@testable import SnotraMobile

/// A relay in memory: answers the endpoints and the Identity Toolkit, streams
/// the database's nodes from a script, and records every request.
final class FakeRelay: RelayTransport, @unchecked Sendable {
    struct Answer {
        var status = 200
        var json: JSONValue? = .object([:])
        var headers: [String: String] = [:]
    }

    struct Stream {
        var status = 200
        /// Sent as they are, then the stream stays open until the client lets it go.
        var text = ""
        var closes = false
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var tokenCount = 0

    let phoneKey = P256.Signing.PrivateKey()
    let channelId = Data(repeating: 7, count: 16)
    let endpoint = RelayEndpoint(
        host: "relay.test",
        relayURL: URL(string: "http://relay.test/v1")!,
        databaseURL: URL(string: "http://db.test/?ns=relay")!,
        identityToolkitURL: URL(string: "http://idp.test/v1")!,
        apiKey: "key",
        appCheckToken: "app-check")

    /// Overrides for an endpoint, by its last path component (`challenges`, `tokens`, …).
    var answers: [String: Answer] = [:]
    var unreachable = false
    /// A node's stream; nodes without one stay open and silent.
    var streams: [String: Stream] = [:]
    /// Each further stream of a node after the first, when it differs.
    var laterStreams: [String: Stream] = [:]
    /// Decides a node's stream when it is opened, after the requests before it — wins over the scripts above.
    var streamFor: (@Sendable (String) -> Stream?)?
    private var opened: [String: Int] = [:]

    var requests: [URLRequest] { lock.withLock { _requests } }
    var tokensIssued: Int { lock.withLock { tokenCount } }

    var client: RelayClient { RelayClient(endpoint: endpoint, transport: self) }

    var sign: @Sendable (Data) throws -> Data {
        { [phoneKey] message in try phoneKey.signature(for: message).rawRepresentation }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (answer, isUnreachable): (Answer, Bool) = lock.withLock {
            _requests.append(request)
            let name = request.url!.lastPathComponent
            if let answer = answers[name] { return (answer, unreachable) }
            switch name {
            case "challenges":
                return (Answer(json: .object(["challenge": .string(Data(repeating: 1, count: 32).base64URLEncodedString)])), unreachable)
            case "tokens":
                tokenCount += 1
                return (Answer(json: .object(["token": .string("custom-\(tokenCount)")])), unreachable)
            case "accounts:signInWithCustomToken":
                let body = try? JSONValue(data: request.httpBody ?? Data())
                let custom = body?["token"]?.stringValue ?? "?"
                return (Answer(json: .object(["idToken": .string("id-\(custom)"), "expiresIn": .string("3600")])), unreachable)
            default:
                return (Answer(status: 204, json: nil), unreachable)
            }
        }
        if isUnreachable { throw RelayError.unreachable }
        let data = try answer.json?.data() ?? Data()
        return (data, HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: answer.headers)!)
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, any Error>) {
        let node = Self.node(of: request.url!)
        let (scripted, provider): (Stream, (@Sendable (String) -> Stream?)?) = lock.withLock {
            _requests.append(request)
            let count = opened[node, default: 0]
            opened[node] = count + 1
            return ((count > 0 ? laterStreams[node] : nil) ?? streams[node] ?? Stream(), streamFor)
        }
        // Outside the lock: the provider may look at the requests.
        let script = provider?(node) ?? scripted
        if lock.withLock({ unreachable }) { throw RelayError.unreachable }
        let body = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in script.text.utf8 { continuation.yield(byte) }
            if script.closes { continuation.finish() }
        }
        return (HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: nil, headerFields: nil)!, body)
    }

    func setUnreachable(_ value: Bool) { lock.withLock { unreachable = value } }

    /// `meta`, `to-phone`, `handshake/desktop` … from a database URL.
    static func node(of url: URL) -> String {
        let parts = url.path.split(separator: "/")
        guard let channels = parts.firstIndex(of: "channels") else { return url.path }
        return parts[(channels + 2)...].joined(separator: "/").replacingOccurrences(of: ".json", with: "")
    }

    static func put(_ path: String, _ data: String) -> String {
        "event: put\ndata: {\"path\":\"\(path)\",\"data\":\(data)}\n\n"
    }
}

/// Everything a channel reports, read once from its single stream.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RelayChannel.Event] = []

    init(_ channel: RelayChannel) {
        Task { [self] in
            for await event in channel.events { lock.withLock { _events.append(event) } }
        }
    }

    var events: [RelayChannel.Event] { lock.withLock { _events } }
    var states: [RelayConnectionState] {
        events.compactMap { if case .state(let state) = $0 { state } else { nil } }
    }

    /// Generous, because it only bounds a wait that ends as soon as the event is
    /// there: a CI simulator can stall for seconds.
    static let patience: Double = 15

    /// Whether an event that matches shows up within the time.
    func waitFor(within seconds: Double = patience, _ matches: (RelayChannel.Event) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if events.contains(where: matches) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitFor(_ state: RelayConnectionState, within seconds: Double = patience) async -> Bool {
        await waitFor(within: seconds) { $0 == .state(state) }
    }
}
