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
}
