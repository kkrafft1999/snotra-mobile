import Foundation
import Observation

/// One chat while it is on the phone's screen: opened with `chat.open`, which
/// subscribes the connection to its events, followed live, written to with
/// `message.send` and stopped with `run.abort` (remote-interface.md §8.1).
/// Nothing of it outlives the screen.
@MainActor @Observable
final class ChatModel {
    enum Loading: Equatable {
        case loading
        case loaded
        case failed(RemoteCallError)
    }

    /// Why a message did not go out.
    enum SendRefusal: Equatable {
        /// The chat's workspace is not the one open at the desktop (`refused`).
        case otherWorkspace
        /// A turn is running in the chat, or it waits for an approval (`busy`).
        case busy
        case tooLong
        /// No provider is set up at the desktop for the chat's model (`unavailable`).
        case noProvider
        case notDelivered
    }

    /// Why an answer to an approval card did not go out.
    enum ApprovalRefusal: Equatable {
        /// The iPhone has no passcode, so nothing can be allowed from it.
        case noPasscode
        /// Face ID or the passcode was cancelled or failed.
        case notConfirmed
        /// The card is no longer open at the desktop.
        case gone
        /// The desktop does not take this answer from the phone (`refused`).
        case refused
        case notDelivered
    }

    let chatId: String
    let workspaceId: DesktopMirror.Workspace.ID
    private(set) var transcript: ChatTranscript
    private(set) var loading: Loading
    /// What the composer holds.
    var draft = ""
    private(set) var sending = false
    private(set) var stopping = false
    private(set) var loadingOlder = false
    /// A chat made with `chat.new` holds nothing at the desktop until its first question is saved.
    private(set) var isNew: Bool
    /// The cards an answer is on its way for.
    private(set) var answering: Set<String> = []
    /// What the desktop runs the chat with; nil until it answered once.
    private(set) var configuration: ChatConfiguration?

    private let call: DesktopMirror.Call
    private let presence: any UserPresence
    /// The id of a message that did not get an answer, kept with its text so that sending it again starts nothing twice.
    private var unanswered: (text: String, clientMessageId: String)?
    private var reloading = false

    init(chatId: String, workspaceId: DesktopMirror.Workspace.ID, title: String = "", isNew: Bool = false,
         presence: any UserPresence = DeviceOwnerPresence(), call: @escaping DesktopMirror.Call) {
        self.chatId = chatId
        self.workspaceId = workspaceId
        self.isNew = isNew
        self.presence = presence
        self.call = call
        transcript = ChatTranscript(chatId: chatId, title: title)
        loading = isNew ? .loaded : .loading
    }

    /// `chat.open`: the latest page, and the chat's events from now on.
    func open() async {
        guard !isNew else { return }
        do throws(RemoteCallError) {
            let snapshot = try ChatTranscript(opened: try await call("chat.open", .object(["chatId": .string(chatId), "limit": 50])))
            if case .loaded = loading { transcript.reloaded(snapshot) } else { transcript = snapshot }
            loading = .loaded
        } catch {
            if case .loaded = loading { return }
            loading = .failed(error)
        }
    }

    /// `chat.configuration`. The desktop announces no change, so this is asked
    /// again whenever the chat opens and after each turn; a failed answer
    /// keeps what was known. A chat from `chat.new` is asked too: the desktop
    /// describes what it would start with (snotra#1256), an older one answers
    /// `not-found` and nothing shows.
    func loadConfiguration() async {
        guard let answer = try? await call("chat.configuration", .object(["chatId": .string(chatId)])),
              let configuration = try? answer.decoded(as: ChatConfiguration.self) else { return }
        self.configuration = configuration
    }

    /// `chat.close`; the chat's events stop.
    func close() async {
        guard !isNew else { return }
        _ = try? await call("chat.close", .object(["chatId": .string(chatId)]))
    }

    func loadOlder() async {
        guard let before = transcript.before, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        struct Page: Decodable { let messages: [ChatMessage]; let before: String? }
        let params = JSONValue.object(["chatId": .string(chatId), "before": .string(before), "limit": 50])
        guard let page = try? await call("chat.more", params).decoded(as: Page.self) else { return }
        transcript.prepend(page.messages, before: page.before)
    }

    /// Sends the composer's text. The composer empties before the call goes
    /// out, not once the desktop answered; a message that did not go out comes
    /// back to it, unless something new was typed meanwhile.
    func sendDraft() async -> SendRefusal? {
        let text = draft
        guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        draft = ""
        let refusal = await send(text)
        if refusal != nil, draft.isEmpty { draft = text }
        return refusal
    }

    /// `message.send`; nil once the desktop accepted the turn.
    func send(_ text: String) async -> SendRefusal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return nil }
        sending = true
        defer { sending = false }
        let clientMessageId = unanswered?.text == text ? unanswered!.clientMessageId : UUID().uuidString
        unanswered = (text, clientMessageId)
        let params = JSONValue.object([
            "chatId": .string(chatId), "text": .string(text), "clientMessageId": .string(clientMessageId),
        ])
        do throws(RemoteCallError) {
            let answer = try await call("message.send", params)
            unanswered = nil
            transcript.asked(text, messageId: answer["messageId"]?.stringValue ?? "local-\(clientMessageId)")
            if isNew {
                isNew = false
                await subscribeOnceSaved()
                await loadConfiguration()
            }
            return nil
        } catch {
            switch error.reason {
            case "refused": return .otherWorkspace
            case "busy": return .busy
            case "too-large": return .tooLong
            case "unavailable": return .noProvider
            default: return .notDelivered
            }
        }
    }

    /// `run.abort` for the chat's running turn.
    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        _ = try? await call("run.abort", .object(["chatId": .string(chatId)]))
    }

    /// `approval.respond` for an open card. *Allow once* lets the agent act,
    /// so it needs Face ID or the passcode first; *deny* never loosens
    /// anything and goes out at once. Nil once the desktop took the answer.
    func respond(to requestId: String, _ answer: ApprovalRequest.Answer) async -> ApprovalRefusal? {
        guard let request = transcript.openApprovals.first(where: { $0.requestId == requestId }),
              request.offers(answer), !answering.contains(requestId) else { return nil }
        answering.insert(requestId)
        defer { answering.remove(requestId) }
        if answer == .allowOnce {
            guard presence.canConfirm else { return .noPasscode }
            let tool = request.tool
            guard await presence.confirm(String(localized: "Allow \(tool) once on your desktop")) else { return .notConfirmed }
        }
        var params: [String: JSONValue] = ["requestId": .string(requestId), "response": .string(answer.rawValue)]
        if answer == .allowOnce, let paths = request.sandboxPaths {
            params["sandboxPaths"] = .array(paths.map { .string($0) })
        }
        do throws(RemoteCallError) {
            let result = try await call("approval.respond", .object(params))
            let given = result["response"]?.stringValue.flatMap(ApprovalRequest.Answer.init(rawValue:)) ?? answer
            transcript.answered(requestId, given == .deny ? .denied : .allowed)
            return nil
        } catch {
            switch error.reason {
            case "not-found":
                // Settled elsewhere or expired; reading the chat again says which cards are still open.
                await open()
                return .gone
            case "refused": return .refused
            default: return .notDelivered
            }
        }
    }

    /// An event of the desktop for this chat. Reading the stored answer runs
    /// on its own, so that the events behind this one are not held up.
    func apply(_ method: String, _ params: JSONValue) {
        guard transcript.apply(method, params) else { return }
        Task {
            await reloadAfterTurn()
            await loadConfiguration()
        }
    }

    /// A new session, or the desktop could not deliver everything: open again (§17, `session.resync`).
    func sessionStarted() async {
        await open()
        await loadConfiguration()
    }

    /// A new chat exists at the desktop once its first question is saved; only
    /// then can it be opened, and with it its events subscribed.
    private func subscribeOnceSaved() async {
        for attempt in 0..<20 {
            do throws(RemoteCallError) {
                let snapshot = try ChatTranscript(opened: try await call("chat.open", .object(["chatId": .string(chatId), "limit": 50])))
                transcript.reloaded(snapshot)
                return
            } catch {
                guard error.reason == "not-found" else { return }
                try? await Task.sleep(for: .milliseconds(attempt < 5 ? 100 : 500))
            }
        }
    }

    /// After `run-end`: the stored answer replaces the assembled one, as soon as the desktop has stored it.
    private func reloadAfterTurn() async {
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }
        for attempt in 0..<5 {
            await open()
            guard transcript.hasProvisionalAnswer else { return }
            try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
        }
    }
}
