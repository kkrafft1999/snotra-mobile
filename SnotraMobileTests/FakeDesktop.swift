import CryptoKit
import Foundation
@testable import SnotraMobile

/// The desktop's half of the session (spec §13–§17), played in memory with
/// software keys: it answers handshake 1, opens the phone's envelopes and
/// answers each request through `reply`. It stands in for the relay as well —
/// what the session writes lands here, and what the desktop sends goes back
/// to the session as the channel would stream it.
actor FakeDesktop {
    enum Reply: Sendable {
        case result(JSONValue)
        case error(reason: String, why: String? = nil)
        /// No answer at all.
        case silence
    }

    let channelId = Data(repeating: 9, count: 16)
    let desktopAgree = P256.KeyAgreement.PrivateKey()
    let phoneAgree = P256.KeyAgreement.PrivateKey()
    let desktopKeys: KeyBundle
    let phoneKeys: KeyBundle

    /// The versions the desktop speaks.
    var versions: [UInt8] = [1]
    var answersHandshakes = true
    var reply: @Sendable (String, JSONValue) -> Reply = { method, _ in
        method == "session.hello"
            ? .result(.object(["protocol": 1, "connectionId": "connection-1", "methods": .array(["workspaces.list", "chats.list"])]))
            : .result(.object([:]))
    }

    private(set) var handshakes = 0
    private(set) var requests: [(method: String, params: JSONValue)] = []
    /// The counters of the phone's envelopes, per session, in the order they arrived.
    private(set) var counters: [String: [UInt64]] = [:]
    private(set) var deleted: [String] = []
    private var session: RemoteSession?
    private var keys: SessionKeys?
    private var out: UInt64 = 0
    private var inbox: [String: [String: JSONValue]] = [:]

    init() {
        desktopKeys = KeyBundle(sign: P256.Signing.PrivateKey().publicKey, agree: desktopAgree.publicKey)
        phoneKeys = KeyBundle(sign: P256.Signing.PrivateKey().publicKey, agree: phoneAgree.publicKey)
    }

    func makeSession(timing: RemoteSession.Timing) -> RemoteSession {
        let session = RemoteSession(
            channelId: channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys, timing: timing,
            locale: "de", version: "0.1.0",
            agree: { [phoneAgree] in SessionKeys.rawBytes(of: try phoneAgree.sharedSecretFromKeyAgreement(with: $0)) },
            write: { [weak self] node, method, body in try await self?.write(node, method, body) })
        self.session = session
        return session
    }

    func set(reply: @escaping @Sendable (String, JSONValue) -> Reply) { self.reply = reply }
    func set(versions: [UInt8]) { self.versions = versions }
    func set(answersHandshakes: Bool) { self.answersHandshakes = answersHandshakes }

    var sid: String? { keys?.sidHex }

    // MARK: - What the phone writes

    func write(_ node: String, _ method: String, _ body: JSONValue?) async throws {
        if node == "handshake/phone" {
            handshakes += 1
            guard answersHandshakes, let body else { return }
            await session?.receive(.desktopHandshake(try answer(body)))
        } else if node.hasPrefix("to-desktop/"), method == "PUT", let body {
            try await take(node, body)
        } else if node.hasPrefix("to-phone/"), method == "DELETE" {
            deleted.append(node)
            let parts = node.split(separator: "/").map(String.init)
            inbox[parts[1]]?[parts[2]] = nil
            if inbox[parts[1]]?.isEmpty == true { inbox[parts[1]] = nil }
        }
    }

    /// Handshake 2 (§13), and the desktop's session keys (§14).
    private func answer(_ offer: JSONValue) throws -> JSONValue {
        guard case .array(let list) = offer["v"], let e = offer["e"]?.stringValue.flatMap(Data.init(base64URL:)) else {
            throw RelayError.invalidResponse
        }
        let offered = list.compactMap { $0.numberValue.map { UInt8($0) } }
        guard let chosen = Handshake.chosenVersion(offered: offered, spoken: versions) else {
            return .object(["error": "protocol-unsupported", "v": .array(versions.map { .number(Double($0)) })])
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ss = SessionKeys.rawBytes(of: try desktopAgree.sharedSecretFromKeyAgreement(with: phoneKeys.agreementKey))
        let ee = SessionKeys.rawBytes(of: try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: e)))
        let th = Handshake.transcriptHash(
            channelId: channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys, offered: offered,
            phoneEphemeral: e, chosen: chosen, desktopEphemeral: ephemeral.publicKey.rawRepresentation)
        keys = SessionKeys(staticShared: ss, ephemeralShared: ee, transcriptHash: th)
        out = 0
        return .object(["v": .number(Double(chosen)), "e": .string(ephemeral.publicKey.rawRepresentation.base64URLEncodedString)])
    }

    private func take(_ node: String, _ record: JSONValue) async throws {
        let parts = node.split(separator: "/").map(String.init)
        guard let keys, parts[1] == keys.sidHex, let counter = UInt64(parts[2], radix: 16),
              let sealed = record["c"]?.stringValue.flatMap(Data.init(base64URL:))
        else { return }
        counters[parts[1], default: []].append(counter)
        let message = try JSONValue(data: Envelope.open(sealed, keys: keys, direction: .toDesktop, counter: counter))
        let method = message["method"]?.stringValue ?? "", params = message["params"] ?? .null
        requests.append((method, params))
        let id = message["id"] ?? .null
        switch reply(method, params) {
        case .result(let result):
            await send(.object(["jsonrpc": "2.0", "id": id, "result": result]))
        case .error(let reason, let why):
            var data: [String: JSONValue] = ["reason": .string(reason)]
            if let why { data["why"] = .string(why) }
            await send(.object(["jsonrpc": "2.0", "id": id,
                                "error": .object(["code": -32002, "message": .string("Worded: \(reason)"), "data": .object(data)])]))
        case .silence:
            break
        }
    }

    // MARK: - What the desktop sends

    /// One message into the phone's inbox under the next counter.
    func send(_ message: JSONValue) async {
        guard let sealed = seal(message) else { return }
        await deliver([sealed])
    }

    func notify(_ method: String, _ params: JSONValue) async {
        await send(.object(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    /// Two events, the second one streamed first.
    func notifySwapped(_ first: (String, JSONValue), _ second: (String, JSONValue)) async {
        guard let one = seal(.object(["jsonrpc": "2.0", "method": .string(first.0), "params": first.1])),
              let two = seal(.object(["jsonrpc": "2.0", "method": .string(second.0), "params": second.1]))
        else { return }
        await deliver([two])
        await deliver([one])
    }

    /// An event under the counter after next, so that a gap stays open.
    func notifyLeavingAGap(_ method: String, _ params: JSONValue) async {
        out += 1
        await send(.object(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    /// An envelope whose tag cannot verify (§16).
    func sendTampered() async {
        guard let keys else { return }
        let counter = out
        out += 1
        let record = JSONValue.object(["c": .string(Data(repeating: 0xAB, count: 40).base64URLEncodedString), "at": 0])
        inbox[keys.sidHex, default: [:]][String(format: "%016llx", counter)] = record
        await session?.receive(.inbox(tree))
    }

    private func seal(_ message: JSONValue) -> (sid: String, key: String, record: JSONValue)? {
        guard let keys, let data = try? message.data(),
              let sealed = try? Envelope.seal(data, keys: keys, direction: .toPhone, counter: out)
        else { return nil }
        defer { out += 1 }
        return (keys.sidHex, String(format: "%016llx", out),
                .object(["c": .string(sealed.base64URLEncodedString), "at": 0]))
    }

    private func deliver(_ envelopes: [(sid: String, key: String, record: JSONValue)]) async {
        for envelope in envelopes { inbox[envelope.sid, default: [:]][envelope.key] = envelope.record }
        await session?.receive(.inbox(tree))
    }

    private var tree: JSONValue {
        inbox.isEmpty ? .null : .object(inbox.mapValues { .object($0) })
    }
}

/// Everything a session reports, read once from its single stream.
final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RemoteSession.Event] = []

    init(_ session: RemoteSession) {
        Task { [self] in
            for await event in session.events { lock.withLock { _events.append(event) } }
        }
    }

    var events: [RemoteSession.Event] { lock.withLock { _events } }
    var statuses: [RemoteSession.Status] {
        events.compactMap { if case .status(let status) = $0 { status } else { nil } }
    }
    var notifications: [String] {
        events.compactMap { if case .notification(let method, _) = $0 { method } else { nil } }
    }

    func waitFor(within seconds: Double = EventLog.patience, _ matches: @escaping ([RemoteSession.Event]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if matches(events) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitForReady(count: Int = 1) async -> Bool {
        await waitFor { events in
            events.filter { if case .status(.ready) = $0 { true } else { false } }.count >= count
        }
    }

    func waitFor(_ status: RemoteSession.Status) async -> Bool {
        await waitFor { $0.contains(.status(status)) }
    }
}
