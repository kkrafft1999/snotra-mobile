import Foundation

/// What the phone knows about its connection to the desktop, for the screens
/// of #36 to show.
enum RelayConnectionState: Equatable, Sendable {
    /// Getting a token and opening the streams; nothing is known yet.
    case connecting
    /// The channel stands. Whether the desktop is there comes from its heartbeat.
    case connected(desktopOnline: Bool)
    /// The relay did not answer; the channel keeps trying.
    case unreachable
    /// The channel is gone — removed, replaced by a new pairing, or never there.
    /// Nothing comes of trying again; it takes a new pairing.
    case ended
}

/// Part 2 of the protocol from the phone's side (§12), over the database's
/// REST interface: a token, the four nodes the phone follows, the phone's
/// heartbeat and the desktop's presence. One channel per connection — the app
/// starts one when it comes to the foreground and stops it when it leaves.
actor RelayChannel {
    struct Timing: Sendable {
        /// §12 step 3 (snotra#1227): the phone writes its presence this often.
        var heartbeat: Duration = .seconds(30)
        /// The desktop counts as gone once its `lastSeen` is older than this.
        var desktopTimeout: TimeInterval = 90
        var presenceCheck: Duration = .seconds(5)
        /// An ID token is renewed this long before it runs out, never sooner than the floor.
        var renewMargin: TimeInterval = 5 * 60
        var renewFloor: TimeInterval = 30
        /// A stream that fails this often in a row, without one good connection between, is given up.
        var streamAttempts = 3
        var streamRetry: Duration = .seconds(1)
        /// After the relay could not be reached: the first wait, doubled up to the ceiling.
        var reconnect: Duration = .seconds(2)
        var reconnectCeiling: Duration = .seconds(30)
    }

    enum Event: Equatable, Sendable {
        case state(RelayConnectionState)
        /// The channel's `meta` (§5.10) each time it changes.
        case meta(JSONValue)
        /// The phone's inbox `to-phone`, all envelopes still in it (§15).
        case inbox(JSONValue)
        /// The desktop's half of the handshake (§13), `.null` while there is none.
        case desktopHandshake(JSONValue)
    }

    /// The nodes the phone follows (§12 step 2) — never the channel itself.
    static let followedNodes = ["meta", "to-phone", "handshake/desktop", "presence/desktop"]
    /// The inbox may hold envelopes of up to 256 KiB plaintext each, several in its first `put`.
    static let inboxMaxEventBytes = 4 * 1024 * 1024

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let client: RelayClient
    private let channelId: Data
    private let sign: @Sendable (Data) throws -> Data
    private let timing: Timing

    private var session: RelayClient.Session?
    private var renewal: Task<RelayClient.Session, any Error>?
    private var running: Task<Void, Never>?
    private var state: RelayConnectionState?
    private var metaSeen = false
    private var desktopLastSeen: Double?
    private var stopped = false

    /// A `meta` that is gone, or a relay that no longer gives this channel a token.
    private struct Ended: Error {}

    init(client: RelayClient, channelId: Data, timing: Timing = Timing(), sign: @escaping @Sendable (Data) throws -> Data) {
        self.client = client
        self.channelId = channelId
        self.timing = timing
        self.sign = sign
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    func start() {
        guard running == nil, !stopped else { return }
        running = Task { await run() }
    }

    /// Ends the connection and takes the phone's presence down with it.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        running?.cancel()
        await running?.value
        if let session, session.expiresAt > client.now() {
            try? await send(node: "presence/phone", method: "DELETE", body: nil, idToken: session.idToken)
        }
        session = nil
        continuation.finish()
    }

    /// One write under the channel (`print=silent`); a refused token is renewed once.
    func write(_ node: String, method: String, body: JSONValue?) async throws {
        for attempt in 0..<2 {
            guard !stopped else { throw RelayError.unauthorized }
            let used = try await currentToken()
            do {
                try await send(node: node, method: method, body: body, idToken: used)
                return
            } catch RelayError.unauthorized where attempt == 0 {
                _ = try await renew(after: used)
            }
        }
        throw RelayError.unauthorized
    }

    // MARK: - The connection

    private func run() async {
        var wait = timing.reconnect
        while !Task.isCancelled, !stopped {
            if state != .unreachable { publish(.connecting) }
            do {
                session = try await client.phoneSession(channelId: channelId, sign: sign)
                wait = timing.reconnect
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for node in Self.followedNodes {
                        group.addTask { try await self.follow(node) }
                    }
                    group.addTask { try await self.beat() }
                    group.addTask { try await self.watchDesktop() }
                    group.addTask { try await self.keepTokenFresh() }
                    // None of them returns while the channel stands; the first to throw ends the others.
                    try await group.next()
                }
            } catch is CancellationError {
                return
            } catch is Ended {
                end()
                return
            } catch RelayError.notFound, RelayError.refused {
                // §5.9: no token for a channel the relay no longer knows, or for a key it no longer holds.
                end()
                return
            } catch {
                if Task.isCancelled || stopped { return }
                metaSeen = false
                publish(.unreachable)
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, timing.reconnectCeiling)
            }
        }
    }

    private func end() {
        stopped = true
        session = nil
        publish(.ended)
        continuation.finish()
    }

    /// Streams one node until the channel ends; throws `.unreachable` once the
    /// stream has failed `streamAttempts` times in a row.
    private func follow(_ node: String) async throws {
        var failures = 0
        var tree = JSONValue.null
        while true {
            try Task.checkCancellation()
            if failures >= timing.streamAttempts { throw RelayError.unreachable }
            if failures > 0 { try await Task.sleep(for: timing.streamRetry) }
            let used = try await currentToken()
            var request = URLRequest(url: client.endpoint.databaseNodeURL(channelId: channelId, node: node, idToken: used))
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                let (response, body) = try await client.transport.stream(request)
                switch response.statusCode {
                case 200: break
                case 401:
                    _ = try await renew(after: used)
                    failures += 1
                    continue
                default:
                    throw RelayError(status: response.statusCode, reason: nil)
                }
                var parser = EventStreamParser(
                    maxEventBytes: node == "to-phone" ? Self.inboxMaxEventBytes : EventStreamParser.defaultMaxEventBytes)
                streaming: for try await byte in body {
                    guard let event = try parser.feed(byte) else { continue }
                    switch event.type {
                    case "put", "patch":
                        // A stream counts as a good connection once it delivers; one that opens and closes does not.
                        failures = 0
                        guard let change = try? JSONValue(data: Data(event.data.utf8)),
                              let path = change["path"]?.stringValue
                        // An event that is no JSON changes nothing; the next full put repairs the copy.
                        else { continue }
                        tree = tree.applying(change["data"] ?? .null, at: path, merge: event.type == "patch")
                        try received(tree, at: node)
                    case "cancel":
                        // The rules took the read away: the channel went, or its status left `paired`.
                        if node == "meta" { throw Ended() }
                        break streaming
                    case "auth_revoked":
                        _ = try await renew(after: used)
                        break streaming
                    default:
                        // keep-alive
                        failures = 0
                    }
                }
                // The stream ended; open it again.
                failures += 1
            } catch let error as RelayError where error.isTransient || error == .invalidResponse {
                failures += 1
            } catch is EventStreamParser.Failure {
                failures += 1
            }
        }
    }

    private func received(_ tree: JSONValue, at node: String) throws {
        switch node {
        case "meta":
            // §5.10: a `meta` that disappears means cancelled, denied, expired or removed.
            guard tree != .null else { throw Ended() }
            metaSeen = true
            continuation.yield(.meta(tree))
            judgeDesktop()
        case "to-phone":
            continuation.yield(.inbox(tree))
        case "handshake/desktop":
            continuation.yield(.desktopHandshake(tree))
        case "presence/desktop":
            desktopLastSeen = tree["lastSeen"]?.numberValue
            judgeDesktop()
        default:
            break
        }
    }

    /// The phone's heartbeat (§12 step 3, snotra#1227). A beat that does not
    /// land is no reason to drop the connection; the next one tries again.
    private func beat() async throws {
        while true {
            try Task.checkCancellation()
            try? await write("presence/phone", method: "PUT", body: .object(["lastSeen": .serverTimestamp]))
            try await Task.sleep(for: timing.heartbeat)
        }
    }

    /// The desktop's heartbeat ages without an event, so its presence is judged on a clock too.
    private func watchDesktop() async throws {
        while true {
            try await Task.sleep(for: timing.presenceCheck)
            judgeDesktop()
        }
    }

    private func keepTokenFresh() async throws {
        while true {
            guard let session else { throw RelayError.unauthorized }
            let due = session.expiresAt.timeIntervalSince(client.now()) - timing.renewMargin
            try await Task.sleep(for: .seconds(max(due, timing.renewFloor)))
            _ = try await renew(after: session.idToken)
        }
    }

    private func judgeDesktop() {
        guard metaSeen else { return }
        publish(.connected(desktopOnline: isDesktopOnline))
    }

    private var isDesktopOnline: Bool {
        guard let desktopLastSeen else { return false }
        let relayNow = client.now().addingTimeInterval(session?.serverOffset ?? 0).timeIntervalSince1970 * 1000
        return relayNow - desktopLastSeen <= timing.desktopTimeout * 1000
    }

    private func publish(_ next: RelayConnectionState) {
        guard next != state else { return }
        state = next
        continuation.yield(.state(next))
    }

    // MARK: - Tokens

    private func currentToken() async throws -> String {
        if let session, session.expiresAt > client.now() { return session.idToken }
        return try await renew(after: session?.idToken).idToken
    }

    /// One renewal at a time, whichever stream notices first; a stream that
    /// already holds a newer token than the one it used gets that one.
    private func renew(after used: String?) async throws -> RelayClient.Session {
        if let session, session.idToken != used { return session }
        if let renewal { return try await renewal.value }
        let task = Task { [client, channelId, sign] in
            try await client.phoneSession(channelId: channelId, sign: sign)
        }
        renewal = task
        defer { renewal = nil }
        let fresh = try await task.value
        session = fresh
        return fresh
    }

    private func send(node: String, method: String, body: JSONValue?, idToken: String) async throws {
        var request = URLRequest(url: client.endpoint.databaseNodeURL(
            channelId: channelId, node: node, idToken: idToken, silent: true))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.data()
        }
        let (_, response) = try await client.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw RelayError(status: response.statusCode, reason: nil)
        }
    }
}
