import Foundation
import Testing
@testable import SnotraMobile

@MainActor
struct ChatModelTests {
    /// The desktop's answers by method, and every request made.
    final class Desk {
        var calls: [(method: String, params: JSONValue)] = []
        var answers: [String: [Result<JSONValue, RemoteCallError>]] = [:]
        var opened: JSONValue = .object(["chatId": "c1", "title": "Notes", "state": "idle", "messages": .array([
            .object(["messageId": "m0", "role": "user", "text": "Hi"]),
        ])])

        /// The next answer for a method; the last one stays.
        func answer(_ method: String) -> Result<JSONValue, RemoteCallError> {
            if method == "chat.open", answers[method] == nil { return .success(opened) }
            guard var queue = answers[method], let next = queue.first else { return .success(.object([:])) }
            if queue.count > 1 { queue.removeFirst(); answers[method] = queue }
            return next
        }
    }

    let desk = Desk()

    func model(isNew: Bool = false) -> ChatModel {
        ChatModel(chatId: "c1", workspaceId: "w1", isNew: isNew) { [desk] method, params throws(RemoteCallError) in
            desk.calls.append((method, params))
            return try desk.answer(method).get()
        }
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(EventLog.patience)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func openingReadsTheLatestPage() async {
        let chat = model()
        await chat.open()
        #expect(chat.loading == .loaded)
        #expect(chat.transcript.title == "Notes")
        #expect(desk.calls.first?.method == "chat.open")
        #expect(desk.calls.first?.params["chatId"] == "c1")
    }

    @Test func sendingShowsTheQuestionAndAResendStartsNothingTwice() async {
        let chat = model()
        await chat.open()
        desk.answers["message.send"] = [.failure(.timedOut), .success(.object(["runId": "r1", "messageId": "m1"]))]
        #expect(await chat.send("  Tell me more  ") == .notDelivered)
        #expect(await chat.send("Tell me more") == nil)
        let sends = desk.calls.filter { $0.method == "message.send" }
        #expect(sends.count == 2)
        #expect(sends[0].params["text"] == "Tell me more")
        // The same message again: the same id, so the desktop answers again and starts nothing.
        #expect(sends[0].params["clientMessageId"] == sends[1].params["clientMessageId"])
        #expect(chat.transcript.messages.last?.messageId == "m1")
        #expect(chat.transcript.isRunning)
    }

    @Test func theComposerEmptiesAsTheMessageGoesOutAndARefusalBringsItBack() async {
        /// The draft as the desktop's call sees it.
        final class Probe { weak var chat: ChatModel?; var drafts: [String] = [] }
        let probe = Probe()
        let chat = ChatModel(chatId: "c1", workspaceId: "w1") { [desk] method, params throws(RemoteCallError) in
            if method == "message.send" { probe.drafts.append(probe.chat?.draft ?? "?") }
            desk.calls.append((method, params))
            return try desk.answer(method).get()
        }
        probe.chat = chat
        await chat.open()
        desk.answers["message.send"] = [.failure(.timedOut), .success(.object(["runId": "r1", "messageId": "m1"]))]

        chat.draft = "Tell me more"
        #expect(await chat.sendDraft() == .notDelivered)
        #expect(chat.draft == "Tell me more")
        #expect(await chat.sendDraft() == nil)
        #expect(chat.draft == "")
        #expect(probe.drafts == ["", ""])
    }

    @Test func aRefusedMessageLeavesWhatWasTypedMeanwhile() async {
        let chat = ChatModel(chatId: "c1", workspaceId: "w1") { method, _ throws(RemoteCallError) in
            guard method == "message.send" else { return .object([:]) }
            try? await Task.sleep(for: .milliseconds(100))
            throw .timedOut
        }
        chat.draft = "First"
        async let refusal = chat.sendDraft()
        #expect(await waitFor { chat.sending })
        chat.draft = "Second"
        #expect(await refusal == .notDelivered)
        #expect(chat.draft == "Second")
    }

    @Test func anEmptyDraftSendsNothing() async {
        let chat = model()
        chat.draft = "  \n "
        #expect(await chat.sendDraft() == nil)
        #expect(chat.draft == "  \n ")
        #expect(!desk.calls.contains { $0.method == "message.send" })
    }

    @Test func eachRefusalToSendHasItsNote() async {
        let chat = model()
        await chat.open()
        let cases: [(String, ChatModel.SendRefusal)] = [
            ("refused", .otherWorkspace), ("busy", .busy), ("too-large", .tooLong), ("unavailable", .noProvider), ("internal", .notDelivered),
        ]
        for (reason, refusal) in cases {
            desk.answers["message.send"] = [.failure(.desktop(code: -32001, reason: reason, message: "", why: nil))]
            #expect(await chat.send("Text \(reason)") == refusal)
        }
        #expect(chat.transcript.messages.count == 1)
    }

    @Test func aNewChatIsOpenedOnceItsFirstQuestionIsSaved() async {
        let chat = model(isNew: true)
        await chat.open()
        #expect(desk.calls.isEmpty)
        let notFound = RemoteCallError.desktop(code: -32002, reason: "not-found", message: "", why: nil)
        desk.answers["chat.open"] = [.failure(notFound), .failure(notFound), .success(.object([
            "chatId": "c1", "title": "", "state": "running", "messages": .array([.object(["messageId": "m0", "role": "user", "text": "Hello"])]),
        ]))]
        desk.answers["message.send"] = [.success(.object(["runId": "r1", "messageId": "m0"]))]
        #expect(await chat.send("Hello") == nil)
        #expect(!chat.isNew)
        #expect(desk.calls.map(\.method) == ["message.send", "chat.open", "chat.open", "chat.open", "chat.configuration"])
        #expect(chat.transcript.isRunning)
    }

    @Test func stopAsksTheDesktopToAbort() async {
        let chat = model()
        await chat.open()
        await chat.stop()
        #expect(desk.calls.last?.method == "run.abort")
        #expect(desk.calls.last?.params == .object(["chatId": "c1"]))
    }

    @Test func theEndOfATurnReadsTheStoredAnswer() async {
        let chat = model()
        await chat.open()
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "Hello back"]))
        desk.opened = .object(["chatId": "c1", "title": "Notes", "state": "idle", "messages": .array([
            .object(["messageId": "m0", "role": "user", "text": "Hi"]),
            .object(["messageId": "m1", "role": "assistant", "text": "Hello back, stored"]),
        ])])
        chat.apply("chat.progress", .object(["chatId": "c1", "runId": "r1", "type": "run-end"]))
        #expect(await waitFor { chat.transcript.messages.last?.text == "Hello back, stored" })
        #expect(!chat.transcript.isRunning)
    }

    static func configuration(model: String, mode: String = "smart") -> JSONValue {
        .object([
            "model": .object(["label": .string(model)]), "mode": .string(mode), "reasoning": "high",
            "skills": .array([.object(["name": "release-notes", "state": "on"]), .object(["name": "broken", "state": "invalid"])]),
            "tools": .array([.object(["name": "read_file", "on": true]), .object(["name": "shell", "on": false])]),
        ])
    }

    @Test func theConfigurationNamesTheChatsModel() async {
        let chat = model()
        desk.answers["chat.configuration"] = [.success(Self.configuration(model: "claude-sonnet-4-5", mode: "ask-all"))]
        await chat.loadConfiguration()
        #expect(desk.calls.last?.method == "chat.configuration")
        #expect(desk.calls.last?.params == .object(["chatId": "c1"]))
        let configuration = chat.configuration
        #expect(configuration?.modelLabel == "claude-sonnet-4-5")
        #expect(configuration?.mode == "ask-all")
        #expect(configuration?.reasoning == "high")
        #expect(configuration?.skills.map(\.state) == ["on", "invalid"])
        #expect(configuration?.tools.map(\.on) == [true, false])
    }

    @Test func aModelWithoutLabelShowsNone() async {
        let chat = model()
        desk.answers["chat.configuration"] = [.success(Self.configuration(model: ""))]
        await chat.loadConfiguration()
        #expect(chat.configuration != nil)
        #expect(chat.configuration?.modelLabel == nil)
    }

    @Test func aFailedAnswerKeepsTheKnownConfiguration() async {
        let chat = model()
        desk.answers["chat.configuration"] = [.success(Self.configuration(model: "gpt-5")), .failure(.timedOut)]
        await chat.loadConfiguration()
        await chat.loadConfiguration()
        #expect(chat.configuration?.modelLabel == "gpt-5")
        desk.answers["chat.configuration"] = [.success(.object(["model": "not an object"]))]
        await chat.loadConfiguration()
        #expect(chat.configuration?.modelLabel == "gpt-5")
    }

    @Test func aNewChatAsksForNoConfigurationBeforeItIsSaved() async {
        let chat = model(isNew: true)
        await chat.loadConfiguration()
        #expect(desk.calls.isEmpty)
        #expect(chat.configuration == nil)
    }

    @Test func theEndOfATurnReadsTheConfigurationAgain() async {
        let chat = model()
        desk.answers["chat.configuration"] = [.success(Self.configuration(model: "claude-sonnet-4-5"))]
        await chat.open()
        await chat.loadConfiguration()
        // Switched at the desktop while the turn ran.
        desk.answers["chat.configuration"] = [.success(Self.configuration(model: "claude-opus-4-5"))]
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "Done"]))
        chat.apply("chat.progress", .object(["chatId": "c1", "runId": "r1", "type": "run-end"]))
        #expect(await waitFor { chat.configuration?.modelLabel == "claude-opus-4-5" })
    }

    @Test func theMirrorHandsAChatItsEventsWhileAttached() async {
        let mirror = DesktopMirror { [desk] method, params throws(RemoteCallError) in
            desk.calls.append((method, params))
            return try desk.answer(method).get()
        }
        let chat = mirror.chat(ChatRoute(chatId: "c1", workspaceId: "w1"))
        mirror.attach(chat)
        await chat.open()
        await mirror.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "Live"]))
        await mirror.apply("chat.delta", .object(["chatId": "c2", "runId": "r2", "text": "Another chat"]))
        #expect(chat.transcript.live?.text == "Live")
        mirror.detach(chat)
        await mirror.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": " more"]))
        #expect(chat.transcript.live?.text == "Live")
    }
}
