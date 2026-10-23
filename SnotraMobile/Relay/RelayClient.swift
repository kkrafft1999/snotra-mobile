import Foundation

/// The phone's calls to the relay's endpoints (remote protocol §5) and to the
/// Identity Toolkit. Holds no state; every token it hands out lives in memory
/// only (§12 step 1).
struct RelayClient: Sendable {
    /// An ID token for the database and the endpoints, with the hour it lives (§12).
    struct Session: Equatable, Sendable {
        let idToken: String
        let expiresAt: Date
        /// The relay's clock minus the phone's, from the answers' `Date` header —
        /// so that a heartbeat's `lastSeen` is judged on the relay's time.
        let serverOffset: TimeInterval
    }

    /// The relay takes bodies up to 4 KiB (§5.1); its answers are smaller still.
    static let maxResponseBytes = 16 * 1024
    static let maxTokenChars = 8 * 1024
    /// The Identity Toolkit names no lifetime above an hour.
    static let maxTokenLifetime: TimeInterval = 3600

    /// Which App Check token a call carries: only `lookup` and `claim` are checked (§5.4, §5.5).
    enum AppCheckUse: Sendable {
        case none
        case reusable
        case limitedUse
    }

    let endpoint: RelayEndpoint
    let transport: any RelayTransport
    /// Shared across clients so that a reusable token lives on; the endpoint's own when nil.
    var appCheck: (any AppCheckProvider)?
    var now: @Sendable () -> Date = { Date() }

    /// §5.2: a challenge, as the bytes every proof signs.
    func challenge() async throws -> (text: String, bytes: Data) {
        let (answer, _) = try await call(endpoint.relayURL.appending(path: "challenges"), body: .object([:]))
        guard let text = answer["challenge"]?.stringValue, let bytes = Data(base64URL: text),
              (1...64).contains(bytes.count)
        else { throw RelayError.invalidResponse }
        return (text, bytes)
    }

    /// §5.9 and §12 step 1: challenge, signed proof, custom token, ID token.
    /// `sign` is the phone's long-term signing key, in the Secure Enclave on a device.
    func phoneSession(channelId: Data, sign: @Sendable (Data) throws -> Data) async throws -> Session {
        let challenge = try await challenge()
        let proof = try sign(PairingProof.tokenMessage(challenge: challenge.bytes, channelId: channelId, role: .phone))
        let (answer, serverDate) = try await call(endpoint.relayURL.appending(path: "tokens"), body: .object([
            "challenge": .string(challenge.text),
            "channelId": .string(channelId.base64URLEncodedString),
            "role": .string(PairingProof.Role.phone.rawValue),
            "proof": .string(proof.base64URLEncodedString),
        ]))
        guard let token = answer["token"]?.stringValue else { throw RelayError.invalidResponse }
        return try await signIn(customToken: token, serverDate: serverDate)
    }

    /// §5.1: the relay's custom token becomes an ID token through the Identity Toolkit.
    func signIn(customToken: String, serverDate: Date? = nil) async throws -> Session {
        guard !customToken.isEmpty, customToken.count <= Self.maxTokenChars else { throw RelayError.invalidResponse }
        let url = endpoint.accountsURL("signInWithCustomToken")
        let started = now()
        let (answer, _) = try await call(url, body: .object([
            "token": .string(customToken),
            "returnSecureToken": .bool(true),
        ]))
        guard let idToken = answer["idToken"]?.stringValue, !idToken.isEmpty, idToken.count <= Self.maxTokenChars
        else { throw RelayError.invalidResponse }
        // The lifetime comes in seconds, as a string; an hour when it does not.
        let seconds = answer["expiresIn"]?.stringValue.flatMap(TimeInterval.init) ?? Self.maxTokenLifetime
        let lifetime = seconds > 0 ? min(seconds, Self.maxTokenLifetime) : Self.maxTokenLifetime
        // The Identity Toolkit's clock is Google's, not the relay's; only the relay's answer sets the offset.
        let offset = serverDate.map { $0.timeIntervalSince(started) } ?? 0
        return Session(idToken: idToken, expiresAt: started.addingTimeInterval(lifetime), serverOffset: offset)
    }

    /// One JSON call with a small answer. Returns the answer — `.null` for an
    /// empty one, as `204` brings — and the server's `Date`.
    func call(_ url: URL, method: String = "POST", body: JSONValue? = .object([:]),
              bearer: String? = nil, appCheck: AppCheckUse = .none,
              headers: [String: String] = [:]) async throws -> (JSONValue, Date?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.data()
        }
        if appCheck != .none {
            let provider = self.appCheck ?? endpoint.appCheck.provider(for: endpoint, transport: transport)
            request.setValue(try await provider.token(limitedUse: appCheck == .limitedUse), forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        guard data.count <= Self.maxResponseBytes else { throw RelayError.invalidResponse }
        let answer = data.isEmpty ? JSONValue.null : ((try? JSONValue(data: data)) ?? .null)
        guard (200..<300).contains(response.statusCode) else {
            throw RelayError(status: response.statusCode, reason: answer["error"]?["reason"]?.stringValue)
        }
        if !data.isEmpty {
            guard case .object = answer else { throw RelayError.invalidResponse }
        }
        return (answer, Self.date(of: response))
    }

    static func date(of response: HTTPURLResponse) -> Date? {
        guard let header = response.value(forHTTPHeaderField: "Date") else { return nil }
        return httpDate.date(from: header)
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
