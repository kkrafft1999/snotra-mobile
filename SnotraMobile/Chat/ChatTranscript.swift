import Foundation

/// One message as the desktop shows it (remote-interface.md §8.1 `DisplayMessage`).
struct ChatMessage: Decodable, Identifiable, Equatable, Sendable {
    enum Role: String, Decodable, Sendable { case user, assistant }

    struct ToolLine: Decodable, Equatable, Sendable {
        /// Worded by the desktop, in its language.
        let line: String
        let tool: String?
        /// `pending`, `start` or `done`.
        var status: String
    }

    struct Origin: Decodable, Equatable, Sendable {
        /// `relay` for a phone, `local` for a client on the desktop's machine.
        let kind: String
        let client: String?
    }

    let messageId: String
    let role: Role
    var text: String
    var toolLines: [ToolLine]
    /// Images arrive as placeholders only (§6.4); their names, where the desktop kept one.
    var images: [String?]
    var origin: Origin?
    var interrupted: Bool

    var id: String { messageId }

    init(messageId: String, role: Role, text: String, toolLines: [ToolLine] = [], images: [String?] = [],
         origin: Origin? = nil, interrupted: Bool = false) {
        self.messageId = messageId
        self.role = role
        self.text = text
        self.toolLines = toolLines
        self.images = images
        self.origin = origin
        self.interrupted = interrupted
    }

    init(from decoder: any Decoder) throws {
        struct Attachment: Decodable { let name: String? }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        role = (try? container.decode(Role.self, forKey: .role)) ?? .assistant
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        toolLines = (try? container.decodeIfPresent([ToolLine].self, forKey: .toolLines)) ?? []
        images = ((try? container.decodeIfPresent([Attachment].self, forKey: .attachments)) ?? []).map(\.name)
        origin = try? container.decodeIfPresent(Origin.self, forKey: .origin)
        interrupted = (try? container.decodeIfPresent(Bool.self, forKey: .interrupted)) ?? false
    }

    private enum CodingKeys: String, CodingKey { case messageId, role, text, toolLines, attachments, origin, interrupted }
}

/// A chat as the phone holds it while it is open: the page of messages the
/// desktop sent, and the turn running now, assembled from its events
/// (remote-interface.md §8.2) — text in order, tool lines by their call.
/// A value, so that the assembly can be tested without a session.
struct ChatTranscript: Equatable, Sendable {
    /// What is known of the turn running now.
    struct LiveTurn: Equatable, Sendable {
        let runId: String
        var text = ""
        /// In the order their calls began; a call's later phases update its line.
        var toolLines: [(callIndex: Int?, line: ChatMessage.ToolLine)] = []
        var ended = false

        static func == (lhs: LiveTurn, rhs: LiveTurn) -> Bool {
            lhs.runId == rhs.runId && lhs.text == rhs.text && lhs.ended == rhs.ended
                && lhs.toolLines.map(\.callIndex) == rhs.toolLines.map(\.callIndex)
                && lhs.toolLines.map(\.line) == rhs.toolLines.map(\.line)
        }

        /// The turn as a message, for the moment between its end and the stored answer.
        var message: ChatMessage {
            ChatMessage(messageId: "live-\(runId)", role: .assistant, text: text, toolLines: toolLines.map(\.line))
        }
    }

    let chatId: String
    var title: String
    var state: DesktopMirror.ChatState
    /// Oldest first.
    var messages: [ChatMessage]
    /// The id to ask `chat.more` with, while older messages exist.
    var before: String?
    var live: LiveTurn?
    /// The approval cards of the turn running now, open or settled, in the order they came.
    var approvals: [ApprovalCard]

    init(chatId: String, title: String = "", state: DesktopMirror.ChatState = .idle,
         messages: [ChatMessage] = [], before: String? = nil, approvals: [ApprovalRequest] = []) {
        self.chatId = chatId
        self.title = title
        self.state = state
        self.messages = messages
        self.before = before
        self.approvals = approvals.map { ApprovalCard(request: $0) }
    }

    /// `chat.open`'s result.
    init(opened: JSONValue) throws(RemoteCallError) {
        struct Opened: Decodable {
            let chatId: String
            let title: String?
            let state: String?
            let messages: [ChatMessage]
            let before: String?
            let pendingApprovals: [ApprovalRequest]?
        }
        let opened = try opened.decoded(as: Opened.self)
        self.init(chatId: opened.chatId, title: opened.title ?? "",
                  state: opened.state.flatMap(DesktopMirror.ChatState.init(rawValue:)) ?? .idle,
                  messages: opened.messages, before: opened.before, approvals: opened.pendingApprovals ?? [])
    }

    /// The cards that still wait for an answer.
    var openApprovals: [ApprovalRequest] {
        approvals.filter(\.isOpen).map(\.request)
    }

    var isRunning: Bool {
        (live.map { !$0.ended } ?? false) || state != .idle
    }

    /// The assembled answer of a turn that ended, until the desktop's stored one replaces it.
    var hasProvisionalAnswer: Bool {
        messages.last?.messageId.hasPrefix("live-") == true
    }

    /// A fresh `chat.open` after a turn ended, a resync or a new session. Once
    /// the desktop has stored the answer it replaces the assembled one; until
    /// then the assembled one stays, and the caller asks again.
    mutating func reloaded(_ snapshot: ChatTranscript) {
        if !snapshot.title.isEmpty { title = snapshot.title }
        state = snapshot.state
        before = snapshot.before
        reloadApprovals(snapshot)
        let stored = messages.filter { !$0.messageId.hasPrefix("live-") }.count
        guard !hasProvisionalAnswer || snapshot.messages.count > stored else { return }
        messages = snapshot.messages
        if live?.ended == true { live = nil }
    }

    /// `chat.more`'s page, older than everything shown.
    mutating func prepend(_ page: [ChatMessage], before: String?) {
        let known = Set(messages.map(\.messageId))
        messages.insert(contentsOf: page.filter { !known.contains($0.messageId) }, at: 0)
        self.before = before
    }

    /// The desktop's open cards are the truth. A card the phone still held open
    /// that is gone there was settled while the phone was not listening; once
    /// the turn is over, the notes go with it.
    private mutating func reloadApprovals(_ snapshot: ChatTranscript) {
        let open = Set(snapshot.approvals.map(\.id))
        var cards = snapshot.state == .idle ? [] : approvals.compactMap { card -> ApprovalCard? in
            guard !open.contains(card.id) else { return nil }
            guard card.isOpen else { return card }
            return ApprovalCard(request: card.request, outcome: ApprovalOutcome(kind: .closed, by: nil))
        }
        cards.append(contentsOf: snapshot.approvals)
        approvals = cards
    }

    /// The phone's own answer, accepted by the desktop.
    mutating func answered(_ requestId: String, _ kind: ApprovalOutcome.Kind) {
        guard let index = approvals.firstIndex(where: { $0.id == requestId && $0.isOpen }) else { return }
        approvals[index].outcome = ApprovalOutcome(kind: kind, by: .thisPhone)
        waitingSettled()
    }

    private mutating func waitingSettled() {
        if state == .needsApproval && openApprovals.isEmpty { state = .running }
    }

    /// The phone's own question, shown at once (the desktop sends `chat.message` to everyone else).
    mutating func asked(_ text: String, messageId: String) {
        guard !messages.contains(where: { $0.messageId == messageId }) else { return }
        messages.append(ChatMessage(messageId: messageId, role: .user, text: text,
                                    origin: .init(kind: "relay", client: SessionHello.clientName)))
        state = .running
    }

    /// One event of the desktop for this chat; true when the chat should be read again.
    @discardableResult
    mutating func apply(_ method: String, _ params: JSONValue) -> Bool {
        switch method {
        case "chat.delta":
            guard let runId = params["runId"]?.stringValue, let text = params["text"]?.stringValue else { return false }
            beginTurn(runId)
            live?.text += text
        case "chat.tool-line":
            guard let runId = params["runId"]?.stringValue, let line = params["line"]?.stringValue, !line.isEmpty else { return false }
            beginTurn(runId)
            let callIndex = params["callIndex"]?.numberValue.map { Int($0) }
            let toolLine = ChatMessage.ToolLine(line: line, tool: params["tool"]?.stringValue,
                                                status: params["phase"]?.stringValue ?? "start")
            if let callIndex, let index = live?.toolLines.firstIndex(where: { $0.callIndex == callIndex }) {
                live?.toolLines[index].line = toolLine
            } else {
                live?.toolLines.append((callIndex, toolLine))
            }
        case "chat.progress":
            guard let runId = params["runId"]?.stringValue else { return false }
            guard params["type"]?.stringValue == "run-end" else {
                beginTurn(runId)
                return false
            }
            guard live?.runId == runId || live == nil else { return true }
            if let ended = live, !ended.text.isEmpty || !ended.toolLines.isEmpty {
                messages.append(ended.message)
            }
            live = LiveTurn(runId: runId, ended: true)
            state = .idle
            return true
        case "chat.message":
            guard let message = try? params["message"]?.decoded(as: ChatMessage.self) else { return false }
            if !messages.contains(where: { $0.messageId == message.messageId }) { messages.append(message) }
        case "chat.updated":
            if let title = params["title"]?.stringValue { self.title = title }
        case "approval.request":
            guard let request = try? params.decoded(as: ApprovalRequest.self), request.chatId == chatId else { return false }
            if let index = approvals.firstIndex(where: { $0.id == request.requestId }) {
                if approvals[index].isOpen { approvals[index] = ApprovalCard(request: request) }
            } else {
                approvals.append(ApprovalCard(request: request))
            }
            state = .needsApproval
        case "approval.resolved":
            guard let requestId = params["requestId"]?.stringValue,
                  let index = approvals.firstIndex(where: { $0.id == requestId }), approvals[index].isOpen else { return false }
            approvals[index].outcome = ApprovalOutcome(resolved: params)
            waitingSettled()
        default:
            break
        }
        return false
    }

    /// A new live turn when another run's events begin (§6.5: events for a run
    /// the phone was not told of yet belong to the chat all the same).
    private mutating func beginTurn(_ runId: String) {
        if live?.runId != runId || live?.ended == true {
            if let previous = live, !previous.ended, !previous.text.isEmpty || !previous.toolLines.isEmpty {
                messages.append(previous.message)
            }
            live = LiveTurn(runId: runId)
        }
        if state != .needsApproval { state = .running }
    }
}
