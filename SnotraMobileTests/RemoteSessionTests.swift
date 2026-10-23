import Foundation
import Testing
@testable import SnotraMobile

struct RemoteSessionTests {
    let desktop = FakeDesktop()
    let fast = RemoteSession.Timing(
        handshake: .milliseconds(300), gap: .milliseconds(150), call: .seconds(5), retry: .milliseconds(10))

    /// A session whose channel stands with the desktop online and its handshake stream read.
    func connected(timing: RemoteSession.Timing? = nil) async -> (RemoteSession, SessionLog) {
        let session = await desktop.makeSession(timing: timing ?? fast)
        let log = SessionLog(session)
        await session.receive(.state(.connected(desktopOnline: true)))
        await session.receive(.desktopHandshake(.null))
        return (session, log)
    }

    @Test func waitsForTheDesktopsHandshakeRecordBeforeOffering() async throws {
        let session = await desktop.makeSession(timing: fast)
        let log = SessionLog(session)
        await session.receive(.state(.connected(desktopOnline: true)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await desktop.handshakes == 0)

        await session.receive(.desktopHandshake(.null))
        #expect(await log.waitForReady())
        #expect(await desktop.handshakes == 1)
        await session.stop()
    }

    @Test func helloIsTheFirstEnvelopeAndConfirmsTheKeys() async throws {
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        #expect(log.statuses.first == .handshaking)
        #expect(log.statuses.last == .ready(.init(protocolVersion: 1, connectionId: "connection-1",
                                                  methods: ["workspaces.list", "chats.list"])))

        let hello = try #require(await desktop.requests.first)
        #expect(hello.method == "session.hello")
        #expect(hello.params["protocol"] == .array([1]))
        #expect(hello.params["client"]?["name"] == "Snotra for iPhone")
        #expect(hello.params["locale"] == "de")
        let sid = try #require(await desktop.sid)
        #expect(await desktop.counters[sid] == [0])
        await session.stop()
    }

    @Test func aRequestGetsItsAnswerAndTheEnvelopesAreDeleted() async throws {
        await desktop.set { method, params in
            switch method {
            case "session.hello": .result(.object(["protocol": 1, "connectionId": "c", "methods": .array([])]))
            case "chats.list": .result(.object(["asked": params["workspaceId"] ?? .null]))
            default: .error(reason: "unknown-method")
            }
        }
        let (session, log) = await connected()
        #expect(await log.waitForReady())

        let answer = try await session.call("chats.list", .object(["workspaceId": "w1"]))
        #expect(answer == .object(["asked": "w1"]))
        let sid = try #require(await desktop.sid)
        #expect(await desktop.counters[sid] == [0, 1])
        // Deleted after reading (§15): the answers to hello and to the request.
        #expect(await desktop.deleted == ["to-phone/\(sid)/0000000000000000", "to-phone/\(sid)/0000000000000001"])
        await session.stop()
    }

    @Test func aRefusalComesBackWithItsReasonAndWhy() async throws {
        await desktop.set { method, _ in
            method == "session.hello"
                ? .result(.object(["protocol": 1, "connectionId": "c", "methods": .array([])]))
                : .error(reason: "busy", why: "running")
        }
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        await #expect(throws: RemoteCallError.desktop(code: -32002, reason: "busy", message: "Worded: busy", why: "running")) {
            try await session.call("workspace.activate", .object(["workspaceId": "w1"]))
        }
        await session.stop()
    }

    @Test func eventsArriveInTheOrderOfTheirCounters() async throws {
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        await desktop.notifySwapped(("state", .object([:])), ("chat.updated", .object([:])))
        #expect(await log.waitFor { _ in log.notifications.count == 2 })
        #expect(log.notifications == ["state", "chat.updated"])
        await session.stop()
    }

    @Test func aGapThatStaysOpenStartsOver() async throws {
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        await desktop.notifyLeavingAGap("state", .object([:]))
        // §16: the gap is not filled within its time, so the phone starts a new handshake.
        #expect(await log.waitForReady(count: 2))
        #expect(await desktop.handshakes == 2)
        #expect(log.notifications.isEmpty)
        await session.stop()
    }

    @Test func anEnvelopeThatDoesNotOpenStartsOver() async throws {
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        let firstSid = try #require(await desktop.sid)
        await desktop.sendTampered()
        #expect(await log.waitForReady(count: 2))
        #expect(await desktop.handshakes == 2)
        #expect(await desktop.sid != firstSid)
        await session.stop()
    }

    @Test func aStaleAnswerIsNotTakenForTheNewOne() async throws {
        await desktop.set(answersHandshakes: false)
        let session = await desktop.makeSession(timing: fast)
        let log = SessionLog(session)
        // Handshake 2 of an earlier session is still in the desktop's record.
        let stale = JSONValue.object(["v": 1, "e": .string(Data(repeating: 5, count: 32).base64URLEncodedString)])
        await session.receive(.state(.connected(desktopOnline: true)))
        await session.receive(.desktopHandshake(stale))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await desktop.handshakes == 1)
        #expect(await desktop.requests.isEmpty)
        #expect(log.statuses == [.handshaking])
        await session.stop()
    }

    @Test func threeFailedHandshakesWithinAMinuteStop() async throws {
        await desktop.set(answersHandshakes: false)
        let (session, log) = await connected()
        #expect(await log.waitFor(.failed))
        #expect(await desktop.handshakes == 3)
        await #expect(throws: RemoteCallError.notConnected) { try await session.call("workspaces.list") }
        await session.stop()
    }

    @Test func noSharedVersionAsksForAnUpdate() async throws {
        await desktop.set(versions: [2])
        let (session, log) = await connected()
        #expect(await log.waitFor(.incompatible(updateApp: true)))
        #expect(await desktop.requests.isEmpty)
        await session.stop()
    }

    @Test func aDesktopThatGoesOfflineEndsTheSessionAndAnOpenRequest() async throws {
        await desktop.set { method, _ in
            method == "session.hello"
                ? .result(.object(["protocol": 1, "connectionId": "c", "methods": .array([])]))
                : .silence
        }
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        let answer = Task { try await session.call("workspaces.list") }
        try await Task.sleep(for: .milliseconds(50))
        await session.receive(.state(.connected(desktopOnline: false)))
        await #expect(throws: RemoteCallError.sessionEnded) { try await answer.value }
        #expect(await session.status == .idle)

        // Back again: a new handshake (§12 step 4).
        await session.receive(.state(.connected(desktopOnline: true)))
        #expect(await log.waitForReady(count: 2))
        await session.stop()
    }

    @Test func theDesktopClosingTheSessionLeadsToANewOne() async throws {
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        await desktop.notify("session.closing", .object(["reason": "idle"]))
        #expect(await log.waitForReady(count: 2))
        #expect(log.statuses.contains(.idle))
        await session.stop()
    }

    @Test func envelopesOfAnotherSessionAreDeletedUnread() async throws {
        let (session, log) = await connected()
        #expect(await log.waitForReady())
        let sid = try #require(await desktop.sid)
        await session.receive(.inbox(.object([
            sid: .null,
            "00000000000000aa": .object(["0000000000000000": .object(["c": "AAAA", "at": 0])]),
        ])))
        #expect(await log.waitFor { _ in true })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await desktop.deleted.contains("to-phone/00000000000000aa/0000000000000000"))
        #expect(log.statuses.filter { $0 == .handshaking }.count == 1)
        await session.stop()
    }
}
