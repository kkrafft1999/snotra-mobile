import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

/// App Check through App Attest (#51), against a fake App Attest and App
/// Check's REST endpoints played by the fake relay.
struct AppAttestTests {
    let relay = FakeRelay()
    let service = FakeAppAttest()
    let store = LockedStore()
    let clock = TestClock()
    let app = AppAttestApp(project: "snotra-ai", appId: "app", baseURL: URL(string: "http://appcheck.test/v1")!)
    let challenge = Data(repeating: 5, count: 16)
    let artifact = Data(repeating: 6, count: 32)

    init() {
        relay.answers["app:generateAppAttestChallenge"] = .init(json: .object([
            "challenge": .string(challenge.base64EncodedString()), "ttl": .string("60s"),
        ]))
        relay.answers["app:exchangeAppAttestAttestation"] = .init(json: .object([
            "artifact": .string(artifact.base64EncodedString()),
            "appCheckToken": .object(["token": .string("attested"), "ttl": .string("3600s")]),
        ]))
        relay.answers["app:exchangeAppAttestAssertion"] = .init(json: .object([
            "token": .string("asserted"), "ttl": .string("3600s"),
        ]))
    }

    var appCheck: AppAttestAppCheck {
        AppAttestAppCheck(app: app, client: RelayClient(endpoint: relay.endpoint, transport: relay),
                          service: service, store: store, now: { [clock] in clock.now })
    }

    func calls(_ method: String) -> [URLRequest] {
        relay.requests.filter { $0.url!.lastPathComponent == "app:\(method)" }
    }

    func body(_ request: URLRequest) throws -> JSONValue {
        try JSONValue(data: #require(request.httpBody))
    }

    @Test func theFirstTokenAttestsAFreshKey() async throws {
        let token = try await appCheck.token(limitedUse: false)
        #expect(token == "attested")

        #expect(service.attested == [FakeAppAttest.Call(keyId: "key-1", clientDataHash: Data(SHA256.hash(data: challenge)))])
        let exchange = try #require(calls("exchangeAppAttestAttestation").first)
        #expect(exchange.url!.path == "/v1/projects/snotra-ai/apps/app:exchangeAppAttestAttestation")
        #expect(exchange.value(forHTTPHeaderField: "X-Goog-Api-Key") == "key")
        #expect(exchange.value(forHTTPHeaderField: "X-Firebase-AppCheck") == nil)
        let sent = try body(exchange)
        #expect(sent["keyId"] == .string("key-1"))
        #expect(sent["challenge"] == .string(challenge.base64EncodedString()))
        #expect(sent["attestationStatement"] == .string(Data("attestation-key-1".utf8).base64EncodedString()))
        #expect(sent["limitedUse"] == .bool(false))
        #expect(store.read(AppAttestAppCheck.keyIdAccount) == Data("key-1".utf8))
        #expect(store.read(AppAttestAppCheck.artifactAccount) == artifact)
    }

    @Test func aLaterTokenIsAnAssertionWithoutAttestingAgain() async throws {
        store.write(Data("key-0".utf8), account: AppAttestAppCheck.keyIdAccount)
        store.write(artifact, account: AppAttestAppCheck.artifactAccount)

        let token = try await appCheck.token(limitedUse: false)
        #expect(token == "asserted")
        #expect(service.attested.isEmpty)
        #expect(service.asserted == [FakeAppAttest.Call(keyId: "key-0", clientDataHash: Data(SHA256.hash(data: artifact + challenge)))])
        let sent = try body(try #require(calls("exchangeAppAttestAssertion").first))
        #expect(sent["artifact"] == .string(artifact.base64EncodedString()))
        #expect(sent["assertion"] == .string(Data("assertion-key-0".utf8).base64EncodedString()))
        #expect(sent["challenge"] == .string(challenge.base64EncodedString()))
    }

    @Test func aClaimGetsALimitedUseTokenEveryTime() async throws {
        let appCheck = self.appCheck
        _ = try await appCheck.token(limitedUse: true)
        _ = try await appCheck.token(limitedUse: true)

        #expect(try body(try #require(calls("exchangeAppAttestAttestation").first))["limitedUse"] == .bool(true))
        let assertions = calls("exchangeAppAttestAssertion")
        #expect(assertions.count == 1)
        #expect(try body(assertions[0])["limitedUse"] == .bool(true))
    }

    @Test func aReusableTokenServesUntilShortlyBeforeItRunsOut() async throws {
        let appCheck = self.appCheck
        _ = try await appCheck.token(limitedUse: false)
        clock.advance(by: 3600 - AppAttestAppCheck.renewalMargin - 1)
        _ = try await appCheck.token(limitedUse: false)
        #expect(calls("generateAppAttestChallenge").count == 1)

        clock.advance(by: 2)
        #expect(try await appCheck.token(limitedUse: false) == "asserted")
        #expect(calls("generateAppAttestChallenge").count == 2)
    }

    @Test func aRefusedAttestationKeepsNothing() async throws {
        relay.answers["app:exchangeAppAttestAttestation"] = .init(status: 403, json: .object([
            "error": .object(["code": .number(403), "status": .string("PERMISSION_DENIED")]),
        ]))
        await #expect(throws: AppCheckError.refused) { try await appCheck.token(limitedUse: false) }
        #expect(store.read(AppAttestAppCheck.keyIdAccount) == nil)
        #expect(store.read(AppAttestAppCheck.artifactAccount) == nil)
    }

    @Test func anArtifactAppCheckNoLongerTakesLeadsToANewAttestation() async throws {
        store.write(Data("key-0".utf8), account: AppAttestAppCheck.keyIdAccount)
        store.write(artifact, account: AppAttestAppCheck.artifactAccount)
        relay.answers["app:exchangeAppAttestAssertion"] = .init(status: 403, json: .object([:]))

        #expect(try await appCheck.token(limitedUse: false) == "attested")
        #expect(service.attested.map(\.keyId) == ["key-1"])
        #expect(store.read(AppAttestAppCheck.keyIdAccount) == Data("key-1".utf8))
    }

    @Test func aKeyLostWithAReinstallLeadsToANewAttestation() async throws {
        store.write(Data("key-0".utf8), account: AppAttestAppCheck.keyIdAccount)
        store.write(artifact, account: AppAttestAppCheck.artifactAccount)
        service.invalidKeys = ["key-0"]

        #expect(try await appCheck.token(limitedUse: false) == "attested")
        #expect(calls("exchangeAppAttestAssertion").isEmpty)
    }

    @Test func aDeviceWithoutAppAttestAsksNothing() async throws {
        service.isSupported = false
        await #expect(throws: AppCheckError.unsupported) { try await appCheck.token(limitedUse: false) }
        #expect(relay.requests.isEmpty)
    }

    @Test func aTransientFailureKeepsTheKey() async throws {
        store.write(Data("key-0".utf8), account: AppAttestAppCheck.keyIdAccount)
        store.write(artifact, account: AppAttestAppCheck.artifactAccount)
        relay.answers["app:exchangeAppAttestAssertion"] = .init(status: 503, json: .object([:]))

        await #expect(throws: RelayError.unavailable) { try await appCheck.token(limitedUse: false) }
        #expect(service.attested.isEmpty)
        #expect(store.read(AppAttestAppCheck.artifactAccount) == artifact)
    }

    @MainActor @Test func pairingOnADeviceWithoutAppAttestSaysSo() async throws {
        service.isSupported = false
        let appCheck = self.appCheck
        let flow = PairingFlow(
            relays: [relay.endpoint], transport: relay,
            keyStore: DeviceKeyStore(store: MemoryStore(), kind: .software),
            pairingStore: PairingStore(store: MemoryStore()),
            wordList: try .bundled(),
            appCheck: { _ in appCheck })
        flow.submit(typed: PairingCode(pairingId: "0111", secret: "EP9DZH4QPYT4HWW").symbols)
        for _ in 0..<200 where flow.step == .claiming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(flow.step == .failed(.deviceUnsupported))
        #expect(relay.requests.isEmpty)
    }
}

/// App Attest in memory: keys `key-1`, `key-2` …, attestations and assertions that name their key.
final class FakeAppAttest: AppAttestService, @unchecked Sendable {
    struct Call: Equatable {
        let keyId: String
        let clientDataHash: Data
    }

    private let lock = NSLock()
    private var _isSupported = true
    private var keys = 0
    private var _attested: [Call] = []
    private var _asserted: [Call] = []
    private var _invalidKeys: Set<String> = []

    var isSupported: Bool {
        get { lock.withLock { _isSupported } }
        set { lock.withLock { _isSupported = newValue } }
    }
    var invalidKeys: Set<String> {
        get { lock.withLock { _invalidKeys } }
        set { lock.withLock { _invalidKeys = newValue } }
    }
    var attested: [Call] { lock.withLock { _attested } }
    var asserted: [Call] { lock.withLock { _asserted } }

    func generateKey() async throws -> String {
        lock.withLock { keys += 1; return "key-\(keys)" }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if _invalidKeys.contains(keyId) { throw AppAttestKeyInvalid() }
            _attested.append(Call(keyId: keyId, clientDataHash: clientDataHash))
            return Data("attestation-\(keyId)".utf8)
        }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if _invalidKeys.contains(keyId) { throw AppAttestKeyInvalid() }
            _asserted.append(Call(keyId: keyId, clientDataHash: clientDataHash))
            return Data("assertion-\(keyId)".utf8)
        }
    }
}

/// A secret store the tests can look into while the provider holds it.
final class LockedStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(_ account: String) -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, account: String) { lock.withLock { items[account] = data } }
    func delete(_ account: String) { lock.withLock { items[account] = nil } }
}

/// Hands out `reusable-n` and `limited-n`, and records which was asked for.
final class RecordingAppCheck: AppCheckProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [Bool] = []

    var requested: [Bool] { lock.withLock { _requested } }

    func token(limitedUse: Bool) async throws -> String {
        lock.withLock {
            _requested.append(limitedUse)
            return "\(limitedUse ? "limited" : "reusable")-\(_requested.count)"
        }
    }
}
