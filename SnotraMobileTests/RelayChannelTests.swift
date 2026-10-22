import Foundation
import Testing
@testable import SnotraMobile

struct RelayChannelTests {
    let relay = FakeRelay()
    let fast = RelayChannel.Timing(
        heartbeat: .milliseconds(50), desktopTimeout: 90, presenceCheck: .milliseconds(20),
        streamAttempts: 2, streamRetry: .milliseconds(10),
        reconnect: .milliseconds(20), reconnectCeiling: .milliseconds(40))

    var nowMs: Double { Date().timeIntervalSince1970 * 1000 }
    let meta = FakeRelay.put("/", #"{"status":"paired"}"#)

    func channel() -> (RelayChannel, EventLog) {
        let channel = RelayChannel(client: relay.client, channelId: relay.channelId, timing: fast, sign: relay.sign)
        return (channel, EventLog(channel))
    }

    @Test func followsTheFourNodesAndNeverTheChannel() async throws {
        relay.streams["meta"] = .init(text: meta)
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor(.connected(desktopOnline: false)))
        await channel.stop()

        let streamed = relay.requests.filter { $0.value(forHTTPHeaderField: "Accept") == "text/event-stream" }
        #expect(Set(streamed.map { FakeRelay.node(of: $0.url!) }) == Set(RelayChannel.followedNodes))
        #expect(streamed.allSatisfy { $0.url!.query!.contains("auth=id-custom-1") && $0.url!.query!.contains("ns=relay") })
        #expect(log.states.first == .connecting)
    }

    @Test func aFreshHeartbeatShowsTheDesktopOnlineAndAStaleOneOffline() async throws {
        relay.streams["meta"] = .init(text: meta)
        relay.streams["presence/desktop"] = .init(text: FakeRelay.put("/", #"{"lastSeen":\#(nowMs)}"#))
        var (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor(.connected(desktopOnline: true)))
        await channel.stop()

        relay.streams["presence/desktop"] = .init(text: FakeRelay.put("/", #"{"lastSeen":\#(nowMs - 91_000)}"#))
        (channel, log) = self.channel()
        await channel.start()
        #expect(await log.waitFor(.connected(desktopOnline: false)))
        #expect(!log.states.contains(.connected(desktopOnline: true)))
        await channel.stop()
    }

    @Test func theDesktopGoesOfflineWhenItsHeartbeatAges() async throws {
        var timing = fast
        timing.desktopTimeout = 0.2
        relay.streams["meta"] = .init(text: meta)
        relay.streams["presence/desktop"] = .init(text: FakeRelay.put("/", #"{"lastSeen":\#(nowMs)}"#))
        let channel = RelayChannel(client: relay.client, channelId: relay.channelId, timing: timing, sign: relay.sign)
        let log = EventLog(channel)
        await channel.start()
        #expect(await log.waitFor(.connected(desktopOnline: true)))
        #expect(await log.waitFor(.connected(desktopOnline: false)))
        await channel.stop()
    }

    @Test func thePhoneBeatsAndTakesItsPresenceDownOnStop() async throws {
        relay.streams["meta"] = .init(text: meta)
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor(.connected(desktopOnline: false)))
        try await Task.sleep(for: .milliseconds(120))
        await channel.stop()

        let presence = relay.requests.filter { FakeRelay.node(of: $0.url!) == "presence/phone" }
        let beats = presence.filter { $0.httpMethod == "PUT" }
        #expect(beats.count >= 2)
        #expect(try JSONValue(data: beats[0].httpBody!) == .object(["lastSeen": .serverTimestamp]))
        #expect(beats[0].url!.query!.contains("print=silent"))
        #expect(presence.last?.httpMethod == "DELETE")
    }

    @Test func passesOnMetaInboxAndHandshake() async throws {
        relay.streams["meta"] = .init(text: meta)
        relay.streams["to-phone"] = .init(text: FakeRelay.put("/", #"{"00000000000000aa":{"0000000000000001":{"c":"x","at":1}}}"#)
            + "event: patch\ndata: {\"path\":\"/00000000000000aa\",\"data\":{\"0000000000000002\":{\"c\":\"y\",\"at\":2}}}\n\n")
        relay.streams["handshake/desktop"] = .init(text: FakeRelay.put("/", "null"))
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor { $0 == .meta(.object(["status": .string("paired")])) })
        #expect(await log.waitFor { $0 == .desktopHandshake(.null) })
        #expect(await log.waitFor {
            guard case .inbox(let inbox) = $0, case .object(let envelopes) = inbox["00000000000000aa"] else { return false }
            return envelopes.count == 2
        })
        await channel.stop()
    }

    @Test func aMetaThatDisappearsEndsTheChannel() async throws {
        relay.streams["meta"] = .init(text: meta + FakeRelay.put("/", "null"))
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor(.ended))
        #expect(log.states == [.connecting, .connected(desktopOnline: false), .ended])
    }

    @Test func aChannelTheRelayNoLongerKnowsEnds() async throws {
        relay.answers["tokens"] = .init(status: 404, json: .object(["error": .object(["reason": .string("not-found")])]))
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor(.ended))
    }

    @Test func noRelayIsUnreachableAndTheChannelComesBack() async throws {
        relay.streams["meta"] = .init(text: meta)
        relay.setUnreachable(true)
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor(.unreachable))
        relay.setUnreachable(false)
        #expect(await log.waitFor(.connected(desktopOnline: false)))
        await channel.stop()
    }

    @Test func aStreamThatKeepsClosingIsGivenUp() async throws {
        relay.streams["meta"] = .init(text: meta)
        relay.streams["to-phone"] = .init(closes: true)
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor(.unreachable))
        await channel.stop()
    }

    @Test func aRevokedTokenIsRenewedAndTheStreamResumes() async throws {
        relay.streams["meta"] = .init(text: meta)
        relay.streams["to-phone"] = .init(text: "event: auth_revoked\ndata: credential is no longer valid\n\n")
        relay.laterStreams["to-phone"] = .init(text: FakeRelay.put("/", "null"))
        let (channel, log) = channel()
        await channel.start()
        #expect(await log.waitFor { $0 == .inbox(.null) })
        #expect(relay.tokensIssued == 2)
        let inbox = relay.requests.filter { FakeRelay.node(of: $0.url!) == "to-phone" }
        #expect(inbox.last!.url!.query!.contains("auth=id-custom-2"))
        await channel.stop()
    }
}
