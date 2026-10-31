import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

/// The phone's pairing against an in-memory relay that plays the desktop's answers.
@MainActor
struct PairingFlowTests {
    let relay = FakeRelay()
    let keyMemory = MemoryStore()
    let pairingMemory = MemoryStore()
    let desktopKeys = KeyBundle(sign: P256.Signing.PrivateKey().publicKey, agree: P256.KeyAgreement.PrivateKey().publicKey)
    let code = PairingCode(pairingId: "0111", secret: "EP9DZH4QPYT4HWW")
    let flow: PairingFlow

    init() throws {
        flow = PairingFlow(
            relays: [relay.endpoint], transport: relay,
            keyStore: DeviceKeyStore(store: keyMemory, kind: .software),
            pairingStore: PairingStore(store: pairingMemory),
            wordList: try .bundled())
        relay.answers["0111"] = .init(json: .object([
            "channelId": .string(relay.channelId.base64URLEncodedString),
            "desktopKeys": try desktopKeys.json,
            "expiresAt": .number(Date().timeIntervalSince1970 * 1000 + 300_000),
        ]))
        relay.answers["claim"] = .init(json: .object([
            "channelId": .string(relay.channelId.base64URLEncodedString),
            "token": .string("claim-token"),
        ]))
    }

    /// The claim the phone sent, as the relay received it.
    var claim: JSONValue? { Self.claim(in: relay) }
    var phoneKeys: KeyBundle? { Self.phoneKeys(in: relay) }

    nonisolated static func claim(in relay: FakeRelay) -> JSONValue? {
        relay.requests.first { $0.url!.lastPathComponent == "claim" }.flatMap { try? JSONValue(data: $0.httpBody!) }
    }

    nonisolated static func phoneKeys(in relay: FakeRelay) -> KeyBundle? {
        claim(in: relay)?["phoneKeys"].flatMap { try? KeyBundle(json: $0) }
    }

    func transcript(_ phoneKeys: KeyBundle) -> Data {
        PairingMAC.transcript(channelId: relay.channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys)
    }

    /// The desktop confirms with `macD`, computed from the keys the phone claimed with.
    func desktopConfirms(wrongMAC: Bool = false) {
        relay.streamFor = { [relay, code, desktopKeys] node in
            guard node == "meta", let phoneKeys = Self.phoneKeys(in: relay) else { return nil }
            let transcript = PairingMAC.transcript(channelId: relay.channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys)
            let mac = wrongMAC ? Data(repeating: 0, count: 32) : PairingMAC.desktop(code: code, transcript: transcript)
            return .init(text: FakeRelay.put("/", #"{"status":"pending"}"#)
                + FakeRelay.put("/", #"{"status":"paired","macD":"\#(mac.base64URLEncodedString)"}"#))
        }
    }

    func waitFor(_ matches: (PairingFlow.Step) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(EventLog.patience)
        while Date() < deadline {
            if matches(flow.step) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    var deletedChannel: Bool {
        relay.requests.contains {
            $0.httpMethod == "DELETE" && $0.url!.path.hasSuffix("/channels/\(relay.channelId.base64URLEncodedString)")
        }
    }

    @Test func aTypedKeyPairsAndThePairingIsKept() async throws {
        desktopConfirms()
        flow.submit(typed: code.display.lowercased())
        #expect(await waitFor { if case .paired = $0 { true } else { false } })

        let record = try #require(try PairingStore(store: pairingMemory).load())
        #expect(record == PairingRecord(relayHost: "relay.test", channelId: relay.channelId, desktopKeys: desktopKeys))
        let keys = try #require(try DeviceKeyStore(store: keyMemory, kind: .software).load())
        #expect(keys.bundle == phoneKeys)
        #expect(!deletedChannel)
    }

    @Test func theClaimCarriesMACPAndAProofOfThePhonesKey() async throws {
        desktopConfirms()
        flow.submit(typed: code.symbols)
        #expect(await waitFor { if case .paired = $0 { true } else { false } })

        let claim = try #require(claim), phoneKeys = try #require(phoneKeys)
        #expect(claim["macP"]?.stringValue == PairingMAC.phone(code: code, transcript: transcript(phoneKeys)).base64URLEncodedString)
        let challenge = try #require(claim["challenge"]?.stringValue.flatMap { Data(base64URL: $0) })
        let proof = try #require(claim["proof"]?.stringValue.flatMap { Data(base64URL: $0) })
        #expect(PairingProof.verify(proof, of: PairingProof.pairClaimMessage(
            challenge: challenge, channelId: relay.channelId, phoneKeys: phoneKeys), by: try phoneKeys.signingKey))
        let lookUp = try #require(relay.requests.first { $0.url!.lastPathComponent == "0111" })
        #expect(lookUp.httpMethod == "GET")
        #expect(lookUp.value(forHTTPHeaderField: "X-Firebase-AppCheck") == "app-check")
        // The code itself never leaves the phone (§4).
        #expect(!relay.requests.contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains(code.secret) })
    }

    @Test func theWordsShowWhileTheDesktopAsks() async throws {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", #"{"status":"pending"}"#))
        flow.submit(typed: code.symbols)
        #expect(await waitFor { if case .comparing = $0 { true } else { false } })
        guard case .comparing(let phrase) = flow.step, let phoneKeys else { return }
        #expect(phrase == SafetyPhrase(desktopKeys: desktopKeys, phoneKeys: phoneKeys, wordList: try .bundled()))
    }

    @Test func aWrongMACDDeletesTheChannelAndTheKeys() async throws {
        desktopConfirms(wrongMAC: true)
        flow.submit(typed: code.symbols)
        #expect(await waitFor { $0 == .failed(.notVerified) })
        #expect(deletedChannel)
        #expect(keyMemory.items.isEmpty)
        #expect(pairingMemory.items.isEmpty)
    }

    @Test func pairedWithoutMACDIsNotVerified() async throws {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", #"{"status":"paired"}"#))
        flow.submit(typed: code.symbols)
        #expect(await waitFor { $0 == .failed(.notVerified) })
        #expect(pairingMemory.items.isEmpty)
    }

    @Test func aChannelThatVanishesWasNotAllowed() async throws {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", #"{"status":"pending"}"#) + FakeRelay.put("/", "null"))
        flow.submit(typed: code.symbols)
        #expect(await waitFor { $0 == .failed(.notAllowed) })
        #expect(keyMemory.items.isEmpty)
    }

    @Test func anExpiredCodeStopsBeforeTheClaim() async throws {
        relay.answers["0111"] = .init(status: 404, json: .object(["error": .object(["reason": .string("not-found")])]))
        flow.submit(typed: code.symbols)
        #expect(await waitFor { $0 == .failed(.expired) })
        #expect(claim == nil)
        #expect(keyMemory.items.isEmpty)
    }

    @Test func noRelayIsUnreachable() async throws {
        relay.setUnreachable(true)
        flow.submit(typed: code.symbols)
        #expect(await waitFor { $0 == .failed(.unreachable) })
    }

    @Test func aRefusedClaimIsNotANetworkFailure() async throws {
        relay.answers["claim"] = .init(status: 401, json: .object([:]))
        flow.submit(typed: code.symbols)
        #expect(await waitFor { $0 == .failed(.relayRefused) })
        #expect(keyMemory.items.isEmpty)
    }

    @Test func aMistypedKeyIsRefusedBeforeAnythingIsSent() {
        flow.submit(typed: String(code.symbols.dropLast()) + (code.check == "0" ? "1" : "0"))
        #expect(flow.step == .failed(.invalidCode(.invalidCheck)))
        flow.retry()
        flow.submit(typed: "0111-EP9D")
        #expect(flow.step == .failed(.invalidCode(.invalidLength)))
        #expect(relay.requests.isEmpty)
    }

    @Test func aQRCodeMustNameAKnownRelay() async {
        flow.submit(scanned: code.qrPayload(relayHost: "evil.example"))
        #expect(flow.step == .failed(.unknownRelay))
        flow.retry()
        flow.submit(scanned: "https://example.com")
        #expect(flow.step == .failed(.invalidCode(.notAPairingCode)))
        flow.retry()
        desktopConfirms()
        flow.submit(scanned: code.qrPayload(relayHost: "relay.test"))
        #expect(await waitFor { if case .paired = $0 { true } else { false } })
        #expect(relay.requests.allSatisfy { !$0.url!.absoluteString.contains("evil") })
    }

    @Test func cancellingWhileComparingDeletesTheClaimedChannel() async throws {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", #"{"status":"pending"}"#))
        flow.submit(typed: code.symbols)
        #expect(await waitFor { if case .comparing = $0 { true } else { false } })
        await flow.cancel()
        #expect(flow.step == .entering)
        #expect(deletedChannel)
        #expect(keyMemory.items.isEmpty)
    }
}
