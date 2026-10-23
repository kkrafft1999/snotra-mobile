import Foundation
import Testing
@testable import SnotraMobile

/// The approval cards (remote-interface.md §7.4, §8.1 `ApprovalRequest`,
/// §8.2 `approval.request` / `approval.resolved`): their states in the
/// transcript, and the answer behind Face ID.
struct ApprovalTranscriptTests {
    static let card = JSONValue.object([
        "requestId": "a-42", "chatId": "c1", "tool": "run_command", "riskClasses": .array(["shell"]),
        "targets": .array([.object(["path": "scripts/release.sh", "kind": "file", "exists": true, "sensitive": false])]),
        "reason": "Runs a shell command in the workspace.", "checkpoint": "tool",
        "preview": .object(["kind": "shell", "text": "npm run release", "truncated": false, "masked": false]),
        "options": .array(["allow-once", "deny"]),
    ])

    func running() -> ChatTranscript {
        var chat = ChatTranscript(chatId: "c1", state: .running)
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "Let me release it."]))
        return chat
    }

    @Test func aCardDecodesWhatTheDesktopShows() throws {
        let request = try Self.card.decoded(as: ApprovalRequest.self)
        #expect(request.requestId == "a-42")
        #expect(request.tool == "run_command")
        #expect(request.targets == [.init(path: "scripts/release.sh")])
        #expect(request.preview == .init(text: "npm run release"))
        #expect(request.offers(.allowOnce) && request.offers(.deny))
        #expect(request.sandboxPaths == nil)
    }

    @Test func aSandboxCardAllowsTheFirstScopeOfEachPlace() throws {
        let request = try JSONValue.object([
            "requestId": "a-1", "chatId": "c1", "tool": "run_command", "checkpoint": "sandbox", "options": .array(["allow-once", "deny"]),
            "sandbox": .object(["entries": .array([
                .object(["kind": "read", "target": "/etc/hosts", "count": 1, "folder": false, "allow": .array(["/etc/hosts", "/etc"])]),
                .object(["kind": "write", "target": "build/out", "count": 2, "folder": true, "allow": .array(["build"])]),
            ])]),
        ]).decoded(as: ApprovalRequest.self)
        #expect(request.sandboxPaths == ["/etc/hosts", "build"])
    }

    @Test func aCardThatOffersNothingCannotBeAnswered() throws {
        let request = try JSONValue.object(["requestId": "a-1", "chatId": "c1", "tool": "write_file"]).decoded(as: ApprovalRequest.self)
        #expect(!request.offers(.allowOnce) && !request.offers(.deny))
    }

    @Test func aRequestOpensACardAndTheChatWaits() {
        var chat = running()
        chat.apply("approval.request", Self.card)
        #expect(chat.openApprovals.map(\.requestId) == ["a-42"])
        #expect(chat.state == .needsApproval)
        #expect(chat.isRunning)
    }

    @Test func aCardOfAnotherChatIsNotThisOnes() {
        var chat = running()
        var other = Self.card
        if case .object(var map) = other { map["chatId"] = "c2"; other = .object(map) }
        chat.apply("approval.request", other)
        #expect(chat.approvals.isEmpty)
    }

    @Test func answeredAtTheDesktopTheCardTurnsIntoANote() {
        var chat = running()
        chat.apply("approval.request", Self.card)
        chat.apply("approval.resolved", .object([
            "requestId": "a-42", "chatId": "c1", "response": "allow-once", "invalidated": false, "reason": .null,
            "by": .object(["kind": "desktop", "client": ""]),
        ]))
        #expect(chat.openApprovals.isEmpty)
        #expect(chat.approvals.first?.outcome == ApprovalOutcome(kind: .allowed, by: .desktop))
        #expect(chat.state == .running)
    }

    @Test func eachSettlementHasItsNote() {
        let cases: [(JSONValue, ApprovalOutcome)] = [
            (.object(["response": "deny", "invalidated": false, "by": .object(["kind": "desktop"])]), .init(kind: .denied, by: .desktop)),
            (.object(["response": "allow-once", "invalidated": false, "by": .object(["kind": "relay", "client": "Snotra for iPhone"])]),
             .init(kind: .allowed, by: .thisPhone)),
            (.object(["response": "deny", "invalidated": false, "by": .object(["kind": "local", "client": "snotra-cli"])]),
             .init(kind: .denied, by: .other("snotra-cli"))),
            (.object(["response": .null, "invalidated": false, "reason": "no_approval_ui"]), .init(kind: .expired, by: nil)),
            (.object(["response": "allow-once", "invalidated": true, "reason": "policy-changed"]), .init(kind: .expired, by: nil)),
        ]
        for (params, outcome) in cases {
            #expect(ApprovalOutcome(resolved: params) == outcome)
        }
    }

    @Test func theSameRequestTwiceIsOneCard() {
        var chat = running()
        chat.apply("approval.request", Self.card)
        chat.apply("approval.request", Self.card)
        #expect(chat.approvals.count == 1)
    }

    @Test func theOpenedChatBringsItsOpenCards() throws {
        let chat = try ChatTranscript(opened: .object([
            "chatId": "c1", "title": "Release", "state": "needs-approval", "messages": .array([]),
            "pendingApprovals": .array([Self.card]),
        ]))
        #expect(chat.openApprovals.map(\.requestId) == ["a-42"])
        #expect(chat.state == .needsApproval)
    }

    @Test func aCardGoneFromTheDesktopWhileAwayIsClosed() throws {
        var chat = running()
        chat.apply("approval.request", Self.card)
        chat.reloaded(try ChatTranscript(opened: .object([
            "chatId": "c1", "state": "running", "messages": .array([]), "pendingApprovals": .array([]),
        ])))
        #expect(chat.openApprovals.isEmpty)
        #expect(chat.approvals.first?.outcome == ApprovalOutcome(kind: .closed, by: nil))
    }

    @Test func theNotesGoOnceTheTurnIsOver() throws {
        var chat = running()
        chat.apply("approval.request", Self.card)
        chat.answered("a-42", .allowed)
        #expect(chat.approvals.first?.outcome == ApprovalOutcome(kind: .allowed, by: .thisPhone))
        chat.reloaded(try ChatTranscript(opened: .object(["chatId": "c1", "state": "idle", "messages": .array([])])))
        #expect(chat.approvals.isEmpty)
    }

    @Test func aLateResolvedKeepsThePhonesOwnAnswer() {
        var chat = running()
        chat.apply("approval.request", Self.card)
        chat.answered("a-42", .denied)
        chat.apply("approval.resolved", .object(["requestId": "a-42", "chatId": "c1", "response": "deny", "invalidated": false]))
        #expect(chat.approvals.first?.outcome == ApprovalOutcome(kind: .denied, by: .thisPhone))
    }
}

@MainActor
struct ApprovalAnswerTests {
    final class Presence: UserPresence, @unchecked Sendable {
        var canConfirm = true
        var confirms = true
        var asked: [String] = []

        func confirm(_ reason: String) async -> Bool {
            asked.append(reason)
            return confirms
        }
    }

    let presence = Presence()
    var calls: [(method: String, params: JSONValue)] { box.calls }
    let box = Box()

    final class Box {
        var calls: [(method: String, params: JSONValue)] = []
        var respond: Result<JSONValue, RemoteCallError> = .success(.object(["response": "allow-once"]))
        var opened = JSONValue.object(["chatId": "c1", "state": "needs-approval", "messages": .array([]),
                                       "pendingApprovals": .array([ApprovalTranscriptTests.card])])
    }

    func model() async -> ChatModel {
        let chat = ChatModel(chatId: "c1", workspaceId: "w1", presence: presence) { [box] method, params throws(RemoteCallError) in
            box.calls.append((method, params))
            switch method {
            case "chat.open": return box.opened
            case "approval.respond": return try box.respond.get()
            default: return .object([:])
            }
        }
        await chat.open()
        return chat
    }

    @Test func allowingAsksForFaceIDFirst() async {
        let chat = await model()
        #expect(await chat.respond(to: "a-42", .allowOnce) == nil)
        #expect(presence.asked.count == 1)
        #expect(calls.last?.method == "approval.respond")
        #expect(calls.last?.params == .object(["requestId": "a-42", "response": "allow-once"]))
        #expect(chat.transcript.approvals.first?.outcome == ApprovalOutcome(kind: .allowed, by: .thisPhone))
        #expect(chat.transcript.state == .running)
    }

    @Test func withoutFaceIDNothingIsAllowed() async {
        let chat = await model()
        presence.confirms = false
        #expect(await chat.respond(to: "a-42", .allowOnce) == .notConfirmed)
        #expect(!calls.contains { $0.method == "approval.respond" })
        #expect(chat.transcript.openApprovals.count == 1)
    }

    @Test func withoutAPasscodeNothingIsAllowed() async {
        let chat = await model()
        presence.canConfirm = false
        #expect(await chat.respond(to: "a-42", .allowOnce) == .noPasscode)
        #expect(presence.asked.isEmpty)
        #expect(!calls.contains { $0.method == "approval.respond" })
    }

    @Test func denyingGoesOutAtOnce() async {
        box.respond = .success(.object(["response": "deny"]))
        let chat = await model()
        #expect(await chat.respond(to: "a-42", .deny) == nil)
        #expect(presence.asked.isEmpty)
        #expect(calls.last?.params == .object(["requestId": "a-42", "response": "deny"]))
        #expect(chat.transcript.approvals.first?.outcome == ApprovalOutcome(kind: .denied, by: .thisPhone))
    }

    @Test func aSandboxCardSendsTheScopesItShowed() async {
        box.opened = .object(["chatId": "c1", "state": "needs-approval", "messages": .array([]), "pendingApprovals": .array([.object([
            "requestId": "a-7", "chatId": "c1", "tool": "run_command", "checkpoint": "sandbox", "options": .array(["allow-once", "deny"]),
            "sandbox": .object(["entries": .array([.object(["kind": "write", "target": "build/out", "allow": .array(["build/out", "build"])])])]),
        ])])])
        let chat = await model()
        #expect(await chat.respond(to: "a-7", .allowOnce) == nil)
        #expect(calls.last?.params["sandboxPaths"] == .array(["build/out"]))
    }

    @Test func aCardSettledElsewhereReadsTheChatAgain() async {
        box.respond = .failure(.desktop(code: -32002, reason: "not-found", message: "", why: nil))
        let chat = await model()
        box.opened = .object(["chatId": "c1", "state": "running", "messages": .array([]), "pendingApprovals": .array([])])
        #expect(await chat.respond(to: "a-42", .deny) == .gone)
        #expect(calls.last?.method == "chat.open")
        #expect(chat.transcript.openApprovals.isEmpty)
        #expect(chat.transcript.approvals.first?.outcome == ApprovalOutcome(kind: .closed, by: nil))
    }

    @Test func eachRefusalToAnswerHasItsNote() async {
        let chat = await model()
        box.respond = .failure(.desktop(code: -32001, reason: "refused", message: "", why: nil))
        #expect(await chat.respond(to: "a-42", .deny) == .refused)
        box.respond = .failure(.timedOut)
        #expect(await chat.respond(to: "a-42", .deny) == .notDelivered)
        #expect(chat.transcript.openApprovals.count == 1)
    }

    @Test func anAnswerTheCardDoesNotOfferIsNotSent() async {
        box.opened = .object(["chatId": "c1", "state": "needs-approval", "messages": .array([]), "pendingApprovals": .array([.object([
            "requestId": "a-9", "chatId": "c1", "tool": "write_file", "options": .array(["deny"]),
        ])])])
        let chat = await model()
        #expect(await chat.respond(to: "a-9", .allowOnce) == nil)
        #expect(!calls.contains { $0.method == "approval.respond" })
    }

    @Test func theMirrorHandsAChatItsCards() async {
        let mirror = DesktopMirror { [box] method, params throws(RemoteCallError) in
            box.calls.append((method, params))
            return method == "chat.open" ? .object(["chatId": "c1", "state": "running", "messages": .array([])]) : .object([:])
        }
        let chat = mirror.chat(ChatRoute(chatId: "c1", workspaceId: "w1"))
        mirror.attach(chat)
        await chat.open()
        await mirror.apply("approval.request", ApprovalTranscriptTests.card)
        #expect(chat.transcript.openApprovals.map(\.requestId) == ["a-42"])
        await mirror.apply("approval.resolved", .object(["requestId": "a-42", "chatId": "c1", "response": "deny", "invalidated": false,
                                                        "by": .object(["kind": "desktop"])]))
        #expect(chat.transcript.approvals.first?.outcome == ApprovalOutcome(kind: .denied, by: .desktop))
    }

    @Test func helloAsksForTheCards() {
        let params = SessionHello.params(locale: "en", version: "1.0")
        #expect(params["capabilities"] == .array(["approvals"]))
    }
}
