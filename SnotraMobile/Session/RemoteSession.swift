import CryptoKit
import Foundation

/// The encrypted session with the desktop on top of the channel (spec §13–§17):
/// the handshake, the session keys, the envelopes both ways with the order
/// rule, and JSON-RPC inside them. It holds nothing but what the session needs
/// in memory; the ephemeral key is gone once the keys are derived.
///
/// The channel's events come in through `receive(_:)`; what the session writes
/// goes out through `write`, the channel's own write.
actor RemoteSession {
    enum Status: Equatable, Sendable {
        /// No session, and none underway: the desktop is not there yet, or it closed the last one.
        case idle
        case handshaking
        /// `session.hello` was answered; requests may go out.
        case ready(SessionHello.Welcome)
        /// Three handshakes within a minute failed (§16); the phone stops trying by itself.
        case failed
        /// No version both sides speak: the app is older than the desktop, or the other way round.
        case incompatible(updateApp: Bool)
    }

    enum Event: Equatable, Sendable {
        case status(Status)
        /// An event from the desktop (remote-interface.md §8.2), in order.
        case notification(method: String, params: JSONValue)
    }

    struct Timing: Sendable {
        /// How long handshake 2 and the answer to `session.hello` may take together.
        var handshake: Duration = .seconds(10)
        /// How long a gap in the desktop's envelopes may stay open (§16).
        var gap: Duration = .seconds(5)
        /// How long a request waits for its answer, and for a session to stand first.
        var call: Duration = .seconds(20)
        /// The pause before the next handshake after a failed one.
        var retry: Duration = .seconds(1)
        var failureLimit = 3
        var failureWindow: TimeInterval = 60
        /// A session's longest life (§15).
        var lifetime: TimeInterval = 24 * 60 * 60
    }

    typealias Write = @Sendable (_ node: String, _ method: String, _ body: JSONValue?) async throws -> Void

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let channelId: Data
    private let desktopKeys: KeyBundle
    private let phoneKeys: KeyBundle
    private let agree: @Sendable (P256.KeyAgreement.PublicKey) throws -> Data
    private let write: Write
    private let timing: Timing
    private let locale: String
    private let version: String
    private let now: @Sendable () -> Date

    private(set) var status: Status = .idle
    private var desktopOnline = false
    /// `handshake/desktop` as last streamed; nil until its stream has said anything.
    private var desktopAnswer: JSONValue?
    private var wantsHandshake = false

    /// Handshake 1 written and not answered yet.
    private struct Offer {
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        /// The desktop's record when the offer went out: an answer is a record that differs from it.
        let before: JSONValue
    }
    private var offer: Offer?

    private struct Live {
        let keys: SessionKeys
        let startedAt: Date
        var out: UInt64 = 0
        var window = ReceiveWindow<Data>()
        /// Counters of the desktop's envelopes already taken in, so a stream that repeats the inbox adds nothing.
        var seen: Set<UInt64> = []
        var welcomed = false
    }
    private var live: Live?
    /// Grows with every handshake; work started for an older one does nothing.
    private var generation = 0
    private var failures: [Date] = []
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    /// Envelopes in the inbox whose delete has gone out.
    private var deleting: Set<String> = []
    private var outbox: Task<Void, Never>?
    private var gapTimer: Task<Void, Never>?
    private var stopped = false

    init(channelId: Data, desktopKeys: KeyBundle, phoneKeys: KeyBundle,
         timing: Timing = Timing(), locale: String = SessionHello.appLocale, version: String = SessionHello.appVersion,
         now: @escaping @Sendable () -> Date = Date.init,
         agree: @escaping @Sendable (P256.KeyAgreement.PublicKey) throws -> Data,
         write: @escaping Write) {
        self.channelId = channelId
        self.desktopKeys = desktopKeys
        self.phoneKeys = phoneKeys
        self.timing = timing
        self.locale = locale
        self.version = version
        self.now = now
        self.agree = agree
        self.write = write
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    func stop() {
        guard !stopped else { return }
        endSession()
        stopped = true
        continuation.finish()
    }

    /// One event of the channel.
    func receive(_ event: RelayChannel.Event) {
        guard !stopped else { return }
        switch event {
        case .state(.connected(let online)):
            let cameBack = online && !desktopOnline
            desktopOnline = online
            if cameBack {
                // §12 step 4: after connecting, and whenever the desktop's presence comes back.
                failures = []
                if case .incompatible = status {} else { begin() }
            } else if !online {
                endSession()
                publish(.idle)
            }
        case .state:
            // The streams are being opened again; what they said before no longer counts.
            desktopOnline = false
            desktopAnswer = nil
            endSession()
            publish(.idle)
        case .desktopHandshake(let record):
            desktopAnswer = record
            if offer != nil {
                takeAnswer()
            } else if wantsHandshake {
                begin()
            }
        case .inbox(let tree):
            takeInbox(tree)
        case .meta:
            break
        }
    }

    /// A request to the desktop; waits for a session to stand when there is none yet.
    func call(_ method: String, _ params: JSONValue = .object([:])) async throws(RemoteCallError) -> JSONValue {
        let deadline = ContinuousClock.now + timing.call
        if let live, live.welcomed, now().timeIntervalSince(live.startedAt) >= timing.lifetime || live.out >= 1 << 32 {
            begin()
        }
        while true {
            if case .ready = status, live?.welcomed == true { break }
            switch status {
            case .failed, .incompatible: throw .notConnected
            case .idle where desktopOnline && offer == nil && !wantsHandshake: begin()
            default: break
            }
            guard ContinuousClock.now < deadline, !stopped else { throw .notConnected }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await request(method, params)
    }

    // MARK: - Handshake (§13, §14)

    private func begin() {
        guard !stopped, desktopOnline else { return }
        guard let before = desktopAnswer else {
            // Its stream has not said yet what the desktop's record holds; an old answer must not pass for a new one.
            wantsHandshake = true
            return
        }
        wantsHandshake = false
        endSession()
        generation += 1
        let attempt = generation
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        offer = Offer(ephemeral: ephemeral, before: before)
        publish(.handshaking)
        let record = JSONValue.object([
            "v": .array(Handshake.supportedVersions.map { .number(Double($0)) }),
            "e": .string(ephemeral.publicKey.rawRepresentation.base64URLEncodedString),
        ])
        Task { [write] in
            do {
                try await write("handshake/phone", "PUT", record)
            } catch {
                self.failed(attempt)
            }
        }
        Task { [timing] in
            try? await Task.sleep(for: timing.handshake)
            self.handshakeTimedOut(attempt)
        }
    }

    private func takeAnswer() {
        guard let offer, let record = desktopAnswer, record != offer.before, record != .null,
              let json = try? record.data(), let answer = try? Handshake.decodeAnswer(json)
        else { return }
        self.offer = nil
        switch answer {
        case .unsupported(let desktopVersions):
            endSession()
            publish(.incompatible(updateApp: (desktopVersions.max() ?? 0) > (Handshake.supportedVersions.max() ?? 0)))
        case .accepted(let version, let desktopEphemeral):
            guard Handshake.supportedVersions.contains(version),
                  let keys = try? derive(offer.ephemeral, version: version, desktopEphemeral: desktopEphemeral)
            else { return failed(generation) }
            live = Live(keys: keys, startedAt: now())
            hello(generation)
        }
    }

    private func derive(_ ephemeral: Curve25519.KeyAgreement.PrivateKey, version: UInt8, desktopEphemeral: Data) throws -> SessionKeys {
        let staticShared = try agree(desktopKeys.agreementKey)
        let ephemeralShared = SessionKeys.rawBytes(of: try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: desktopEphemeral)))
        let th = Handshake.transcriptHash(
            channelId: channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys,
            offered: Handshake.supportedVersions, phoneEphemeral: ephemeral.publicKey.rawRepresentation,
            chosen: version, desktopEphemeral: desktopEphemeral)
        return SessionKeys(staticShared: staticShared, ephemeralShared: ephemeralShared, transcriptHash: th)
    }

    /// Key confirmation (§14): the first envelope, and the connection it mints (§17).
    private func hello(_ attempt: Int) {
        Task {
            do throws(RemoteCallError) {
                let result = try await self.request("session.hello", SessionHello.params(locale: locale, version: version))
                self.welcomed(result, attempt)
            } catch {
                self.helloRefused(error, attempt)
            }
        }
    }

    private func welcomed(_ result: JSONValue, _ attempt: Int) {
        guard attempt == generation, live != nil, let welcome = try? result.decoded(as: SessionHello.Welcome.self)
        else { return failed(attempt) }
        live?.welcomed = true
        failures = []
        publish(.ready(welcome))
    }

    private func helloRefused(_ error: RemoteCallError, _ attempt: Int) {
        guard attempt == generation else { return }
        if error.reason == "protocol-unsupported" {
            endSession()
            // The desktop speaks a version the app does not know yet — or only older ones.
            publish(.incompatible(updateApp: true))
        } else {
            failed(attempt)
        }
    }

    private func handshakeTimedOut(_ attempt: Int) {
        guard attempt == generation, live?.welcomed != true, status == .handshaking else { return }
        failed(attempt)
    }

    /// *Starting over* (§16): the session ends and a new handshake follows,
    /// unless three have failed within a minute.
    private func failed(_ attempt: Int) {
        guard attempt == generation, !stopped else { return }
        endSession()
        let moment = now()
        failures = failures.filter { moment.timeIntervalSince($0) < timing.failureWindow } + [moment]
        if failures.count >= timing.failureLimit {
            publish(.failed)
            return
        }
        publish(.handshaking)
        Task { [timing] in
            try? await Task.sleep(for: timing.retry)
            self.retry(attempt)
        }
    }

    private func retry(_ attempt: Int) {
        guard attempt == generation, live == nil, offer == nil else { return }
        begin()
    }

    private func endSession() {
        offer = nil
        live = nil
        gapTimer?.cancel()
        gapTimer = nil
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: RemoteCallError.sessionEnded) }
    }

    // MARK: - Requests and envelopes (§15, §17)

    private func request(_ method: String, _ params: JSONValue) async throws(RemoteCallError) -> JSONValue {
        guard var session = live else { throw .notConnected }
        let id = nextId
        nextId += 1
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params,
        ])
        let counter = session.out
        let sealed: Data
        do {
            sealed = try Envelope.seal(try message.data(), keys: session.keys, direction: .toDesktop, counter: counter)
        } catch {
            throw .malformedAnswer
        }
        session.out += 1
        live = session
        send(sealed, sid: session.keys.sidHex, counter: counter, attempt: generation)
        do {
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { [timing] in
                    try? await Task.sleep(for: timing.call)
                    self.timedOut(id)
                }
            }
        } catch let error as RemoteCallError {
            throw error
        } catch {
            throw .sessionEnded
        }
    }

    /// Envelopes go out one after the other, in the order of their counters.
    private func send(_ sealed: Data, sid: String, counter: UInt64, attempt: Int) {
        let previous = outbox
        let node = "to-desktop/\(sid)/" + String(format: "%016llx", counter)
        let record = JSONValue.object(["c": .string(sealed.base64URLEncodedString), "at": .serverTimestamp])
        outbox = Task { [write] in
            await previous?.value
            do {
                try await write(node, "PUT", record)
            } catch {
                // A lost envelope leaves a gap the desktop will not wait out; start over at once.
                self.failed(attempt)
            }
        }
    }

    private func timedOut(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: RemoteCallError.timedOut)
    }

    /// The whole inbox `to-phone` as streamed (§15): `{ sid: { counter: { c, at } } }`.
    private func takeInbox(_ tree: JSONValue) {
        guard case .object(let sessions) = tree else {
            deleting = []
            return
        }
        var present: Set<String> = []
        for (sid, envelopes) in sessions {
            guard case .object(let records) = envelopes else { continue }
            for key in records.keys { present.insert("to-phone/\(sid)/\(key)") }
            guard sid == live?.keys.sidHex else {
                // Another session's: it ended, or it never stood. Nothing in it can be opened.
                for key in records.keys { remove("to-phone/\(sid)/\(key)") }
                continue
            }
            let ordered = records.compactMap { key, record in UInt64(key, radix: 16).map { ($0, key, record) } }
                .sorted { $0.0 < $1.0 }
            for (counter, key, record) in ordered {
                guard var session = live, session.keys.sidHex == sid, !session.seen.contains(counter) else { continue }
                session.seen.insert(counter)
                live = session
                take(record, counter: counter, node: "to-phone/\(sid)/\(key)")
            }
        }
        deleting.formIntersection(present)
    }

    private func take(_ record: JSONValue, counter: UInt64, node: String) {
        guard var session = live else { return }
        guard let sealed = record["c"]?.stringValue.flatMap(Data.init(base64URL:)),
              let plaintext = try? Envelope.open(sealed, keys: session.keys, direction: .toPhone, counter: counter)
        else {
            // §16: a tag that does not verify.
            remove(node)
            return failed(generation)
        }
        let outcome = session.window.receive(counter: counter, message: plaintext)
        live = session
        switch outcome {
        case .deliver(let messages):
            remove(node)
            if !session.window.hasGap { gapTimer?.cancel(); gapTimer = nil }
            for (counter, message) in messages {
                if counter != messages.first?.counter, let sid = live?.keys.sidHex {
                    remove("to-phone/\(sid)/" + String(format: "%016llx", counter))
                }
                handle(message)
            }
        case .hold:
            guard gapTimer == nil else { return }
            let attempt = generation
            gapTimer = Task { [timing] in
                try? await Task.sleep(for: timing.gap)
                guard !Task.isCancelled else { return }
                self.gapNotFilled(attempt)
            }
        case .drop:
            remove(node)
        case .startOver:
            remove(node)
            failed(generation)
        }
    }

    private func gapNotFilled(_ attempt: Int) {
        guard attempt == generation, live?.window.hasGap == true else { return }
        failed(attempt)
    }

    /// Deleted after reading (§15); once per envelope, whatever the stream repeats.
    private func remove(_ node: String) {
        guard deleting.insert(node).inserted else { return }
        Task { [write] in try? await write(node, "DELETE", nil) }
    }

    private func handle(_ plaintext: Data) {
        guard let message = try? JSONValue(data: plaintext) else { return }
        if let id = message["id"]?.numberValue, message["method"] == nil {
            guard let continuation = pending.removeValue(forKey: Int(id)) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: RemoteCallError(rpcError: error))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        guard let method = message["method"]?.stringValue else { return }
        let params = message["params"] ?? .object([:])
        if method == "session.closing" {
            // The desktop ends this session. Unless it is gone for good, a new one follows.
            let attempt = generation
            endSession()
            publish(.idle)
            if params["reason"]?.stringValue != "unpaired" {
                Task { [timing] in
                    try? await Task.sleep(for: timing.retry)
                    self.retry(attempt)
                }
            }
        }
        continuation.yield(.notification(method: method, params: params))
    }

    private func publish(_ next: Status) {
        guard next != status else { return }
        status = next
        continuation.yield(.status(next))
    }
}
