import Foundation
import Testing
@testable import SnotraMobile

struct EventStreamParserTests {
    func events(_ text: String, max: Int = EventStreamParser.defaultMaxEventBytes) throws -> [EventStreamParser.Event] {
        var parser = EventStreamParser(maxEventBytes: max)
        return try text.utf8.compactMap { try parser.feed($0) }
    }

    @Test func readsTheDatabasesEvents() throws {
        #expect(try events("event: put\ndata: {\"path\":\"/\",\"data\":1}\n\nevent: keep-alive\ndata: null\n\n") == [
            .init(type: "put", data: "{\"path\":\"/\",\"data\":1}"),
            .init(type: "keep-alive", data: "null"),
        ])
    }

    @Test func takesCRLFAndCommentsAndJoinsDataLines() throws {
        #expect(try events(": hello\r\nevent: patch\r\ndata: a\r\ndata:b\r\n\r\n") == [.init(type: "patch", data: "a\nb")])
    }

    @Test func anEventWithoutDataIsNoEvent() throws {
        #expect(try events("event: put\n\n").isEmpty)
        #expect(try events("data: x\n\n") == [.init(type: "message", data: "x")])
    }

    @Test func refusesAnEventPastTheLimit() {
        #expect(throws: EventStreamParser.Failure.eventTooLarge) { try events("data: \(String(repeating: "x", count: 40))\n", max: 32) }
        #expect(throws: EventStreamParser.Failure.eventTooLarge) {
            try events("data: \(String(repeating: "x", count: 20))\ndata: \(String(repeating: "x", count: 20))\n", max: 32)
        }
    }
}

struct JSONValueTests {
    let tree = JSONValue.object(["a": .object(["b": .number(1), "c": .number(2)]), "d": .string("x")])

    @Test func putReplacesAtThePath() {
        #expect(tree.applying(.number(5), at: "/a/b", merge: false)
            == .object(["a": .object(["b": .number(5), "c": .number(2)]), "d": .string("x")]))
        #expect(tree.applying(.object(["z": .bool(true)]), at: "/", merge: false) == .object(["z": .bool(true)]))
    }

    @Test func patchMergesTheChildren() {
        #expect(tree.applying(.object(["b": .null, "e": .number(3)]), at: "/a", merge: true)
            == .object(["a": .object(["c": .number(2), "e": .number(3)]), "d": .string("x")]))
    }

    @Test func nullsAndEmptyNodesVanish() {
        #expect(tree.applying(.null, at: "/a/b", merge: false).applying(.null, at: "/a/c", merge: false)
            == .object(["d": .string("x")]))
        #expect(tree.applying(.null, at: "/", merge: false) == .null)
        #expect(JSONValue.null.applying(.object(["e": .object([:])]), at: "/", merge: false) == .null)
    }

    @Test func roundTripsThroughJSON() throws {
        let value = JSONValue.object(["t": .bool(true), "n": .number(1.5), "s": .string("x"), "l": .array([.null])])
        #expect(try JSONValue(data: value.data()) == value)
    }
}

struct RelayErrorTests {
    @Test func theReasonWinsOverTheStatus() {
        #expect(RelayError(status: 404, reason: "not-found") == .notFound)
        #expect(RelayError(status: 400, reason: "busy") == .busy)
        #expect(RelayError(status: 429, reason: nil) == .rateLimited)
        #expect(RelayError(status: 503, reason: "something-new") == .unavailable)
        #expect(RelayError(status: 418, reason: nil) == .invalidResponse)
    }

    @Test func onlyTheRelaysAbsenceIsTransient() {
        #expect(RelayError.unreachable.isTransient)
        #expect(RelayError.unavailable.isTransient)
        #expect(!RelayError.notFound.isTransient)
        #expect(!RelayError.unauthorized.isTransient)
    }
}

struct RelayEndpointTests {
    @Test func aNodeURLKeepsTheEmulatorsNamespace() {
        let url = RelayEndpoint.emulator.databaseNodeURL(
            channelId: Data(repeating: 0xFF, count: 16), node: "presence/desktop", idToken: "t+1", silent: true)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.path == "/channels/_____________________w/presence/desktop.json")
        #expect(components.queryItems == [
            URLQueryItem(name: "ns", value: "snotra-ai-relay"),
            URLQueryItem(name: "auth", value: "t+1"),
            URLQueryItem(name: "print", value: "silent"),
        ])
    }
    let production = RelayEndpoint.production(apiKey: "AIzaTest", firebaseAppId: "1:123456789012:ios:0a1b2c")

    @Test func productionNamesItsRelayAndKnowsNoFixedAppCheckToken() {
        #expect(production.host == "relay.snotra-ai.dev")
        #expect(production.relayURL.appending(path: "challenges").absoluteString == "https://relay.snotra-ai.dev/v1/challenges")
        #expect(production.appCheckToken == nil)
        #expect(RelayEndpoint.emulator.appCheckURL("exchangeAppAttestAttestation") == nil)
    }

    @Test func aProductionNodeURLGoesToTheEuropeanInstance() {
        let url = production.databaseNodeURL(
            channelId: Data(repeating: 0xFF, count: 16), node: "phone/heartbeat", idToken: "t+1")
        #expect(url.absoluteString ==
            "https://snotra-ai-relay.europe-west1.firebasedatabase.app/channels/_____________________w/phone/heartbeat.json?auth=t+1")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.queryItems == [URLQueryItem(name: "auth", value: "t+1")])
    }

    @Test func identityToolkitCallsCarryTheAPIKey() {
        #expect(production.accountsURL("signInWithCustomToken").absoluteString ==
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=AIzaTest")
        #expect(RelayEndpoint.emulator.accountsURL("signInWithCustomToken").absoluteString ==
            "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=emulator-api-key")
    }

    @Test func appCheckCallsNameTheIOSApp() {
        let app = "https://firebaseappcheck.googleapis.com/v1/projects/snotra-ai/apps/1:123456789012:ios:0a1b2c"
        #expect(production.appCheckURL("generateAppAttestChallenge")?.absoluteString == app + ":generateAppAttestChallenge")
        #expect(production.appCheckURL("exchangeAppAttestAttestation")?.absoluteString == app + ":exchangeAppAttestAttestation")
        #expect(production.appCheckURL("exchangeAppAttestAssertion")?.absoluteString == app + ":exchangeAppAttestAssertion")
    }

    @Test func aRelayListOfProductionRefusesTheEmulatorsQRCode() throws {
        let hosts = Set([production].map(\.host))
        let code = PairingCode(pairingId: "0111", secret: "EP9DZH4QPYT4HWW")
        #expect(throws: PairingCode.Failure.unknownRelay) {
            try PairingCode.parse(qr: code.qrPayload(relayHost: RelayEndpoint.emulator.host), allowedHosts: hosts)
        }
        #expect(try PairingCode.parse(qr: code.qrPayload(relayHost: "relay.snotra-ai.dev"), allowedHosts: hosts).relayHost
            == "relay.snotra-ai.dev")
    }
}
