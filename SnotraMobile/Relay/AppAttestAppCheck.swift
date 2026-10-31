import CryptoKit
import DeviceCheck
import Foundation
import os

/// App Check tokens from App Attest, through App Check's REST API (#51). One
/// key per installation, attested once; every later token is an assertion
/// against the artifact the attestation brought back.
actor AppAttestAppCheck: AppCheckProvider {
    static let keyIdAccount = "app-attest.key-id"
    static let artifactAccount = "app-attest.artifact"
    /// A reusable token is replaced this long before it runs out.
    static let renewalMargin: TimeInterval = 5 * 60
    /// App Check's default, for an answer that names no lifetime.
    static let defaultLifetime: TimeInterval = 3600

    private let app: AppAttestApp
    /// The relay's API key and transport; its calls carry no App Check themselves.
    private let client: RelayClient
    private let service: any AppAttestService
    /// Next to the device keys, `WhenUnlockedThisDeviceOnly` like them.
    private let store: any SecretStore
    private let now: @Sendable () -> Date
    private var reusable: (token: String, expiresAt: Date)?

    init(app: AppAttestApp, client: RelayClient,
         service: any AppAttestService = DeviceAppAttest(),
         store: any SecretStore = KeychainStore(service: "dev.snotra-ai.mobile.keys"),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.app = app
        self.client = client
        self.service = service
        self.store = store
        self.now = now
    }

    func token(limitedUse: Bool) async throws -> String {
        guard service.isSupported else { throw AppCheckError.unsupported }
        if !limitedUse, let reusable, now() < reusable.expiresAt.addingTimeInterval(-Self.renewalMargin) {
            return reusable.token
        }
        let (token, lifetime) = try await exchange(limitedUse: limitedUse)
        if !limitedUse { reusable = (token, now().addingTimeInterval(lifetime)) }
        return token
    }

    /// An assertion while the key and its artifact hold; a new attestation once
    /// they don't — a key lost with a reinstall, an artifact App Check no longer takes.
    private func exchange(limitedUse: Bool) async throws -> (String, TimeInterval) {
        if let stored = try? store.read(Self.keyIdAccount), let keyId = String(data: stored, encoding: .utf8),
           let artifact = try? store.read(Self.artifactAccount) {
            do {
                return try await assert(keyId: keyId, artifact: artifact, limitedUse: limitedUse)
            } catch let error where Self.needsNewAttestation(error) {
                forget()
            }
        }
        return try await attest(limitedUse: limitedUse)
    }

    private func attest(limitedUse: Bool) async throws -> (String, TimeInterval) {
        let keyId = try await service.generateKey()
        let challenge = try await challenge()
        let attestation: Data
        do {
            attestation = try await service.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: challenge)))
        } catch is AppAttestKeyInvalid {
            throw AppCheckError.refused
        }
        let answer = try await refusedAsAppCheck {
            try await call("exchangeAppAttestAttestation", [
                "attestationStatement": .string(attestation.base64EncodedString()),
                "challenge": .string(challenge.base64EncodedString()),
                // App Attest's key ID is already the key's hash in base64, as App Check takes it.
                "keyId": .string(keyId),
                "limitedUse": .bool(limitedUse),
            ])
        }
        guard let artifact = answer["artifact"]?.stringValue.flatMap(Self.bytes), !artifact.isEmpty,
              let token = answer["appCheckToken"]
        else { throw RelayError.invalidResponse }
        let result = try Self.token(of: token)
        // A token is good even when the Keychain is not; the next one then attests anew.
        try? store.write(Data(keyId.utf8), account: Self.keyIdAccount)
        try? store.write(artifact, account: Self.artifactAccount)
        return result
    }

    private func assert(keyId: String, artifact: Data, limitedUse: Bool) async throws -> (String, TimeInterval) {
        let challenge = try await challenge()
        let assertion = try await service.generateAssertion(keyId, clientDataHash: Data(SHA256.hash(data: artifact + challenge)))
        let answer = try await call("exchangeAppAttestAssertion", [
            "artifact": .string(artifact.base64EncodedString()),
            "assertion": .string(assertion.base64EncodedString()),
            "challenge": .string(challenge.base64EncodedString()),
            "limitedUse": .bool(limitedUse),
        ])
        return try Self.token(of: answer)
    }

    private func challenge() async throws -> Data {
        let answer = try await call("generateAppAttestChallenge", [:])
        guard let challenge = answer["challenge"]?.stringValue.flatMap(Self.bytes), (1...1024).contains(challenge.count)
        else { throw RelayError.invalidResponse }
        return challenge
    }

    private func call(_ method: String, _ body: [String: JSONValue]) async throws -> JSONValue {
        var headers = ["X-Goog-Api-Key": client.endpoint.apiKey]
        // An API key restricted to iOS apps names the app it is good for.
        if let bundle = Bundle.main.bundleIdentifier { headers["X-Ios-Bundle-Identifier"] = bundle }
        return try await client.call(app.url(method), body: .object(body), headers: headers).0
    }

    private func forget() {
        try? store.delete(Self.keyIdAccount)
        try? store.delete(Self.artifactAccount)
        reusable = nil
    }

    private func refusedAsAppCheck<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as RelayError where Self.isRefusal(error) {
            throw AppCheckError.refused
        }
    }

    private static func needsNewAttestation(_ error: any Error) -> Bool {
        if error is AppAttestKeyInvalid { return true }
        if let error = error as? RelayError { return isRefusal(error) }
        return false
    }

    /// App Check answers an artifact or attestation it does not take with
    /// `400 INVALID_ARGUMENT`, `401` or `403 PERMISSION_DENIED`.
    private static func isRefusal(_ error: RelayError) -> Bool {
        [.invalidRequest, .unauthorized, .refused].contains(error)
    }

    /// `{ "token": …, "ttl": "3600s" }`.
    private static func token(of answer: JSONValue) throws -> (String, TimeInterval) {
        guard let token = answer["token"]?.stringValue, !token.isEmpty, token.count <= RelayClient.maxTokenChars
        else { throw RelayError.invalidResponse }
        let seconds = answer["ttl"]?.stringValue.flatMap { $0.hasSuffix("s") ? TimeInterval($0.dropLast()) : nil }
        return (token, seconds.flatMap { $0 > 0 ? $0 : nil } ?? defaultLifetime)
    }

    /// Protobuf's JSON gives bytes in standard base64; the URL-safe form is accepted too.
    private static func bytes(_ text: String) -> Data? {
        Data(base64Encoded: text) ?? Data(base64URL: text)
    }
}

/// The device's App Attest, behind a seam for tests.
protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Thrown when App Attest no longer knows the key — after a reinstall, say.
struct AppAttestKeyInvalid: Error {}

/// `DCAppAttestService`, its errors in the relay's terms. Never supported in the simulator.
struct DeviceAppAttest: AppAttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await mapped("generateKey") { try await DCAppAttestService.shared.generateKey() }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await mapped("attestKey") { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await mapped("generateAssertion") { try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
    }

    private func mapped<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as DCError {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            Logger.relay.error("""
                App Attest \(operation, privacy: .public) failed: DCError \(error.code.rawValue, privacy: .public), \
                underlying \(underlying?.domain ?? "none", privacy: .public) \(underlying?.code ?? 0, privacy: .public)
                """)
            throw Self.failure(of: error.code)
        }
    }

    /// Only what App Attest says about the key or the feature is about the app;
    /// anything else — `unknownSystemFailure` above all — is the device's own trouble.
    static func failure(of code: DCError.Code) -> any Error {
        switch code {
        case .featureUnsupported: return AppCheckError.unsupported
        case .invalidKey: return AppAttestKeyInvalid()
        case .serverUnavailable: return RelayError.unavailable
        default: return AppCheckError.deviceFailure
        }
    }
}
