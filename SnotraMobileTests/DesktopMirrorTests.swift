import Foundation
import Testing
@testable import SnotraMobile

@MainActor
struct DesktopMirrorTests {
    /// The requests the mirror made, and the answers it is given.
    final class Desk {
        var calls: [(String, JSONValue)] = []
        var answers: [String: Result<JSONValue, RemoteCallError>] = [
            "workspaces.list": .success(.object(["workspaces": .array([
                .object(["workspaceId": "w1", "name": "snotra", "active": true]),
                .object(["workspaceId": "w2", "name": "website", "active": false]),
            ])])),
            "chats.list": .success(.object(["chats": .array([
                .object(["chatId": "c1", "title": "Release notes", "updatedAt": 1_760_000_000_000, "messageCount": 3, "state": "running"]),
                .object(["chatId": "c2", "title": "Sandbox", "updatedAt": 1_759_000_000_000, "messageCount": 1, "state": "later-state"]),
            ])])),
            "workspace.activate": .success(.object(["workspaceId": "w2"])),
        ]
    }

    let desk = Desk()

    func mirror() -> DesktopMirror {
        DesktopMirror { [desk] method, params throws(RemoteCallError) in
            desk.calls.append((method, params))
            return try (desk.answers[method] ?? .failure(.desktop(code: -32601, reason: "unknown-method", message: "", why: nil))).get()
        }
    }

    @Test func aNewSessionReadsTheWorkspaces() async {
        let mirror = mirror()
        await mirror.sessionStarted()
        guard case .loaded(let workspaces) = mirror.workspaces else { Issue.record("not loaded"); return }
        #expect(workspaces.map(\.name) == ["snotra", "website"])
        #expect(mirror.activeWorkspaceId == "w1")
    }

    @Test func theChatsOfAWorkspaceAreAskedForByItsId() async throws {
        let mirror = mirror()
        await mirror.sessionStarted()
        await mirror.refreshChats("w2")
        #expect(desk.calls.last?.0 == "chats.list")
        #expect(desk.calls.last?.1["workspaceId"] == "w2")
        guard case .loaded(let chats) = mirror.chats["w2"] else { Issue.record("not loaded"); return }
        #expect(chats.map(\.title) == ["Release notes", "Sandbox"])
        #expect(chats[0].updated == Date(timeIntervalSince1970: 1_760_000_000))
        // A state this app does not know is shown as idle.
        #expect(mirror.state(of: chats[1]) == .idle)
        #expect(mirror.state(of: chats[0]) == .running)
    }

    @Test func theDesktopsStateMovesTheActiveWorkspaceAndTheRunningChats() async throws {
        let mirror = mirror()
        await mirror.sessionStarted()
        await mirror.refreshChats("w1")
        await mirror.apply("state", .object([
            "activeWorkspaceId": "w2",
            "running": .array([.object(["chatId": "c2", "workspaceId": "w1", "state": "needs-approval"])]),
            "busy": true,
        ]))
        #expect(mirror.activeWorkspaceId == "w2")
        guard case .loaded(let chats) = mirror.chats["w1"] else { Issue.record("not loaded"); return }
        #expect(mirror.state(of: chats[0]) == .idle)
        #expect(mirror.state(of: chats[1]) == .needsApproval)

        await mirror.apply("state", .object(["activeWorkspaceId": .null, "running": .array([]), "busy": false]))
        #expect(mirror.activeWorkspaceId == nil)
    }

    @Test func switchingMarksTheWorkspaceActive() async {
        let mirror = mirror()
        await mirror.sessionStarted()
        #expect(await mirror.activate("w2") == nil)
        #expect(desk.calls.last?.1 == .object(["workspaceId": "w2"]))
        #expect(mirror.activeWorkspaceId == "w2")
        #expect(mirror.switching == nil)
    }

    @Test func eachRefusalToSwitchHasItsOwnNote() async {
        let mirror = mirror()
        await mirror.sessionStarted()
        let refusals: [(RemoteCallError, DesktopMirror.SwitchRefusal)] = [
            (.desktop(code: -32003, reason: "busy", message: "", why: "running"), .running),
            (.desktop(code: -32003, reason: "busy", message: "", why: "unsaved-changes"), .unsavedChanges),
            (.desktop(code: -32003, reason: "busy", message: "", why: nil), .other),
            (.desktop(code: -32002, reason: "not-found", message: "", why: nil), .notAvailable),
            (.timedOut, .other),
        ]
        for (error, refusal) in refusals {
            desk.answers["workspace.activate"] = .failure(error)
            #expect(await mirror.activate("w2") == refusal)
        }
        #expect(mirror.activeWorkspaceId == "w1")
    }

    @Test func aWorkspaceNoLongerOpenToThePhoneDropsItsChats() async {
        let mirror = mirror()
        await mirror.sessionStarted()
        await mirror.refreshChats("w2")
        desk.answers["workspaces.list"] = .success(.object(["workspaces": .array([
            .object(["workspaceId": "w1", "name": "snotra", "active": true]),
        ])]))
        desk.answers["chats.list"] = .failure(.desktop(code: -32002, reason: "not-found", message: "", why: nil))
        await mirror.refreshChats("w2")
        #expect(mirror.chats["w2"] == nil)
        #expect(mirror.workspace("w2") == nil)
    }

    @Test func aFailedRefreshKeepsWhatIsShown() async {
        let mirror = mirror()
        await mirror.sessionStarted()
        desk.answers["workspaces.list"] = .failure(.timedOut)
        await mirror.refreshWorkspaces()
        #expect(mirror.workspace("w1") != nil)

        let empty = DesktopMirror { _, _ throws(RemoteCallError) in throw .timedOut }
        await empty.refreshWorkspaces()
        #expect(empty.workspaces == .failed(.timedOut))
    }

    @Test func aNewTitleReachesTheList() async {
        let mirror = mirror()
        await mirror.sessionStarted()
        await mirror.refreshChats("w1")
        await mirror.apply("chat.updated", .object(["chatId": "c2", "title": "Sandbox and git push"]))
        guard case .loaded(let chats) = mirror.chats["w1"] else { Issue.record("not loaded"); return }
        #expect(chats[1].title == "Sandbox and git push")
    }
}
