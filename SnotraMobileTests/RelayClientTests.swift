import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

struct RelayClientTests {
    let relay = FakeRelay()

    @Test func aTokenIsProvedWithThePhonesKey() async throws {
        let session = try await relay.client.phoneSession(channelId: relay.channelId, sign: relay.sign)
        #expect(session.idToken == "id-custom-1")

        let calls = relay.requests
        #expect(calls.map { $0.url!.lastPathComponent } == ["challenges", "tokens", "accounts:signInWithCustomToken"])
        let tokens = try JSONValue(data: calls[1].httpBody!)
        #expect(tokens["role"] == .string("phone"))
        #expect(tokens["channelId"] == .string(relay.channelId.base64URLEncodedString))
        let challenge = Data(base64URL: tokens["challenge"]!.stringValue!)!
        let proof = Data(base64URL: tokens["proof"]!.stringValue!)!
        #expect(PairingProof.verify(
            proof, of: PairingProof.tokenMessage(challenge: challenge, channelId: relay.channelId, role: .phone),
            by: relay.phoneKey.publicKey))
    }

    @Test func onlyLookUpAndClaimCarryAppCheck() async throws {
        _ = try await relay.client.phoneSession(channelId: relay.channelId, sign: relay.sign)
        let calls = relay.requests
        #expect(calls.allSatisfy { $0.value(forHTTPHeaderField: "X-Firebase-AppCheck") == nil })
        #expect(calls[2].url!.query == "key=key")
    }

    @Test func theClaimTakesALimitedUseTokenAndTheLookUpAReusableOne() async throws {
        let appCheck = RecordingAppCheck()
        let client = RelayClient(endpoint: relay.endpoint, transport: relay, appCheck: appCheck)
        relay.answers["0111"] = .init(json: .object([
            "channelId": .string(relay.channelId.base64URLEncodedString),
            "desktopKeys": try KeyBundle(sign: P256.Signing.PrivateKey().publicKey,
                                         agree: P256.KeyAgreement.PrivateKey().publicKey).json,
            "expiresAt": .number(1),
        ]))
        relay.answers["claim"] = .init(json: .object([
            "channelId": .string(relay.channelId.base64URLEncodedString), "token": .string("custom"),
        ]))
        let phoneKeys = KeyBundle(sign: relay.phoneKey.publicKey, agree: P256.KeyAgreement.PrivateKey().publicKey)
        _ = try await client.lookUp(pairingId: "0111")
        _ = try await client.claim(pairingId: "0111", channelId: relay.channelId, phoneKeys: phoneKeys,
                                   macP: Data(repeating: 0, count: 32), sign: relay.sign)

        #expect(appCheck.requested == [false, true])
        let carried = relay.requests.map { ($0.url!.lastPathComponent, $0.value(forHTTPHeaderField: "X-Firebase-AppCheck")) }
        #expect(carried.filter { $0.1 != nil }.map(\.0) == ["0111", "claim"])
        #expect(carried.compactMap(\.1) == ["reusable-1", "limited-2"])
    }

    @Test func theTokensLifetimeIsCappedAtAnHour() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        relay.answers["accounts:signInWithCustomToken"] = .init(json: .object([
            "idToken": .string("id"), "expiresIn": .string("86400"),
        ]))
        var client = relay.client
        client.now = { now }
        let session = try await client.signIn(customToken: "custom")
        #expect(session.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func theRelaysClockComesFromItsDateHeader() async throws {
        let now = Date(timeIntervalSince1970: 1_761_134_400) // Wed, 22 Oct 2025 12:00:00 GMT
        relay.answers["tokens"] = .init(json: .object(["token": .string("custom")]),
                                        headers: ["Date": "Wed, 22 Oct 2025 12:00:42 GMT"])
        var client = relay.client
        client.now = { now }
        let session = try await client.phoneSession(channelId: relay.channelId, sign: relay.sign)
        #expect(session.serverOffset == 42)
    }

    @Test func anErrorBodyBecomesItsReason() async {
        relay.answers["tokens"] = .init(status: 404, json: .object(["error": .object(["reason": .string("not-found")])]))
        await #expect(throws: RelayError.notFound) {
            try await relay.client.phoneSession(channelId: relay.channelId, sign: relay.sign)
        }
    }

    @Test func anAnswerWithoutATokenIsRefused() async {
        relay.answers["tokens"] = .init(json: .object(["token": .number(1)]))
        await #expect(throws: RelayError.invalidResponse) {
            try await relay.client.phoneSession(channelId: relay.channelId, sign: relay.sign)
        }
        relay.answers["challenges"] = .init(json: .object(["challenge": .string("")]))
        await #expect(throws: RelayError.invalidResponse) { try await relay.client.challenge() }
    }

    @Test func noNetworkIsUnreachable() async {
        relay.setUnreachable(true)
        await #expect(throws: RelayError.unreachable) { try await relay.client.challenge() }
    }
}
