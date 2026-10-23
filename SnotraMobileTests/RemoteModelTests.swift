import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

/// The pairing's end, from either side, against the in-memory relay.
@MainActor
struct RemoteModelTests {
    let relay = FakeRelay()
    let keyMemory = MemoryStore()
    let pairingMemory = MemoryStore()
    let model: RemoteModel

    init() throws {
        let keyStore = DeviceKeyStore(store: keyMemory, kind: .software)
        _ = try keyStore.create()
        let desktopKeys = KeyBundle(sign: P256.Signing.PrivateKey().publicKey, agree: P256.KeyAgreement.PrivateKey().publicKey)
        try PairingStore(store: pairingMemory).save(
            PairingRecord(relayHost: relay.endpoint.host, channelId: relay.channelId, desktopKeys: desktopKeys))
        var timing = RelayChannel.Timing()
        timing.reconnect = .milliseconds(20)
        model = RemoteModel(relays: [relay.endpoint], transport: relay, keyStore: keyStore,
                            pairingStore: PairingStore(store: pairingMemory), timing: timing)
        model.reload()
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(EventLog.patience)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    var deletedChannel: Bool {
        relay.requests.contains {
            $0.httpMethod == "DELETE" && $0.url!.path.hasSuffix("/channels/\(relay.channelId.base64URLEncodedString)")
        }
    }

    var forgotten: Bool { model.pairing == nil && keyMemory.items.isEmpty && pairingMemory.items.isEmpty }

    @Test func theForegroundConnectsAndTheBackgroundLetsGo() async {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", #"{"status":"paired"}"#))
        model.activate()
        #expect(await waitFor { model.connection == .connected(desktopOnline: false) })
        await model.deactivate()
        #expect(model.connection == nil)
        #expect(relay.requests.last { FakeRelay.node(of: $0.url!) == "presence/phone" }?.httpMethod == "DELETE")
        #expect(model.pairing != nil)
    }

    @Test func disconnectDeletesTheChannelAndForgetsThePairing() async {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", #"{"status":"paired"}"#))
        model.activate()
        await model.unpair()
        #expect(deletedChannel)
        let delete = relay.requests.first {
            $0.httpMethod == "DELETE" && $0.url!.path.contains("/channels/")
        }
        #expect(delete?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer id-") == true)
        #expect(forgotten)
        #expect(model.notice == nil)
        #expect(model.connection == nil)
    }

    @Test func disconnectWithoutARelayStillForgets() async {
        relay.setUnreachable(true)
        await model.unpair()
        #expect(forgotten)
    }

    @Test func aChannelRemovedAtTheDesktopEndsThePairing() async {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", #"{"status":"paired"}"#) + FakeRelay.put("/", "null"))
        model.activate()
        #expect(await waitFor { model.notice == .removedAtDesktop })
        #expect(forgotten)
        #expect(!deletedChannel)
    }

    @Test func aChannelTheRelayNoLongerKnowsEndsThePairing() async {
        relay.answers["tokens"] = .init(status: 404, json: .object(["error": .object(["reason": .string("not-found")])]))
        model.activate()
        #expect(await waitFor { model.notice == .removedAtDesktop })
        #expect(forgotten)
    }

    @Test func aNewPairingClearsTheNotice() async throws {
        relay.streams["meta"] = .init(text: FakeRelay.put("/", "null"))
        model.activate()
        #expect(await waitFor { model.notice == .removedAtDesktop })
        try PairingStore(store: pairingMemory).save(
            PairingRecord(relayHost: relay.endpoint.host, channelId: relay.channelId,
                          desktopKeys: KeyBundle(sign: P256.Signing.PrivateKey().publicKey, agree: P256.KeyAgreement.PrivateKey().publicKey)))
        model.reload()
        #expect(model.notice == nil)
        #expect(model.pairing != nil)
    }
}
